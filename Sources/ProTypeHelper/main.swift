import Foundation
import Darwin
import KeyboardCore
import KeyboardHID

guard geteuid() == 0 else { fputs("Run this helper through its launch daemon (register it from the app).\n", stderr); exit(1) }
signal(SIGPIPE, SIG_IGN)
let service = InputService()
do { try service.start() } catch { fputs("\(error)\n", stderr); exit(1) }

let listener = socket(AF_UNIX, SOCK_STREAM, 0)
guard listener >= 0 else { exit(1) }
unlink(LocalConnection.path)
var address = LocalConnection.address()
let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard bound == 0, chmod(LocalConnection.path, 0o666) == 0, listen(listener, 4) == 0 else { exit(1) }

DispatchQueue.global(qos: .userInitiated).async {
    let slots = DispatchSemaphore(value: 8)
    while true {
        let client = accept(listener, nil, nil)
        if client < 0 { continue }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid >= 501 else { close(client); continue }
        guard slots.wait(timeout: .now()) == .success else { close(client); continue }
        LocalConnection.configure(client)
        let peerUID = uid
        // Checked once per connection: the peer must be the signed app or CLI. Builds
        // without a team identity cannot verify and fall back to the user check only.
        let peerTrusted = !PeerIdentity.enforced || PeerIdentity.trusted(fd: client)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { close(client); slots.signal() }
            do {
                while true {
                    let request = try LocalConnection.receive(HelperRequest.self, fd: client)
                    var result: Result<HelperReply, Error>!
                    if request.kind == .hardware {
                        // Takes ~100 ms on the wire; runs on the lighting queue, never on main.
                        result = Result {
                            guard peerUID == InputService.consoleUID() else { throw RazerError.unavailable("Only the logged-in user can control the helper") }
                            guard peerTrusted else { throw RazerError.unavailable("Only the signed Pro Type Ultra app or CLI can control the helper") }
                            guard let packet = request.packet, packet.count == 90 else { throw RazerError.invalidRequest }
                            var reply = HelperReply(status: service.status)
                            reply.packet = try service.lighting.exchange(packet)
                            return reply
                        }
                    } else {
                        DispatchQueue.main.sync {
                            result = Result {
                                switch request.kind {
                                case .status:
                                    return service.reply()
                                case .configure, .session:
                                    guard peerUID == InputService.consoleUID() else { throw RazerError.unavailable("Only the logged-in user can control the helper") }
                                    guard peerTrusted else { throw RazerError.unavailable("Only the signed Pro Type Ultra app or CLI can control the helper") }
                                    return try service.handle(request)
                                case .hardware:
                                    throw RazerError.invalidRequest
                                }
                            }
                        }
                    }
                    let reply: HelperReply
                    switch result! {
                    case .success(let value): reply = value
                    case .failure(let failure):
                        var refused = HelperReply(status: service.status); refused.error = failure.localizedDescription; reply = refused
                    }
                    try LocalConnection.send(reply, fd: client)
                }
            } catch { /* Expected on app termination; no input data is logged. */ }
        }
    }
}

// Event callbacks handle keystrokes immediately. This timer advances macros,
// expires the app session, and discovers the keyboard; it slows down while idle.
let timer = DispatchSource.makeTimerSource(queue: .main)
var fastTimer = false
timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
timer.setEventHandler {
    service.tick()
    let fast = service.capturing
    if fast != fastTimer {
        fastTimer = fast
        timer.schedule(deadline: .now(), repeating: fast ? .milliseconds(5) : .milliseconds(100), leeway: fast ? .milliseconds(1) : .milliseconds(10))
    }
}
timer.resume()

signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let shutdown = { service.shutdown(); close(listener); unlink(LocalConnection.path); exit(0) }
termination.setEventHandler(handler: shutdown); interrupt.setEventHandler(handler: shutdown)
termination.resume(); interrupt.resume()
RunLoop.main.run()
