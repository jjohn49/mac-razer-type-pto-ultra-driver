import Foundation
import Darwin
import KeyboardCore

/// A bounded local protocol. Server authorizes the peer with getpeereid.
public enum LocalConnection {
    public static let path = "/var/run/protype-ultra.sock"
    public static func address() -> sockaddr_un {
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of:&addr.sun_path) { dest in
            for (i,b) in (path.utf8 + [0]).enumerated() { dest[i] = b }
        }
        return addr
    }
    public static func configure(_ fd:Int32) {
        var noSigPipe:Int32 = 1
        setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSigPipe,socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec:2,tv_usec:0)
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
    }
    public static func send<T:Encodable>(_ value:T, fd:Int32) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 4_000_000 else { throw RazerError.transport("Helper message too large") }
        var length = UInt32(data.count).bigEndian
        var packet = Data(bytes:&length,count:4); packet.append(data)
        try packet.withUnsafeBytes { raw in
            var offset=0
            while offset < raw.count {
                let sent = Darwin.send(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset,0)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw RazerError.transport("Helper connection closed") }
                offset += sent
            }
        }
    }
    private static func read(_ count:Int,fd:Int32) throws -> Data {
        var data = Data(count:count)
        try data.withUnsafeMutableBytes { raw in
            var offset=0
            while offset < count {
                let n=recv(fd,raw.baseAddress!.advanced(by:offset),count-offset,0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw RazerError.transport("Helper connection closed or timed out") }
                offset += n
            }
        }
        return data
    }
    public static func receive<T:Decodable>(_ type:T.Type,fd:Int32) throws -> T {
        let header = try read(4,fd:fd)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0 && length <= 4_000_000 else { throw RazerError.transport("Invalid helper frame") }
        return try JSONDecoder().decode(type,from:read(length,fd:fd))
    }
}
public final class HelperClient: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var fd:Int32 = -1
    public init() {}
    deinit { disconnect() }
    public func disconnect() { lock.lock(); defer { lock.unlock() }; if fd >= 0 { Darwin.close(fd); fd = -1 } }
    public func exchange(_ request:HelperRequest) throws -> HelperReply {
        lock.lock(); defer { lock.unlock() }
        do {
            if fd < 0 {
                fd = socket(AF_UNIX,SOCK_STREAM,0)
                guard fd >= 0 else { throw RazerError.transport("Cannot create helper connection") }
                LocalConnection.configure(fd)
                var addr=LocalConnection.address()
                let result=withUnsafePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                guard result == 0 else { throw RazerError.unavailable("Input helper is not installed or running. See Setup.") }
                var uid:uid_t=0; var gid:gid_t=0
                guard getpeereid(fd,&uid,&gid) == 0, uid == 0 else { throw RazerError.transport("Helper is not owned by root") }
            }
            try LocalConnection.send(request,fd:fd)
            let reply = try LocalConnection.receive(HelperReply.self,fd:fd)
            if let error = reply.error { throw RazerError.unavailable(error) }
            return reply
        } catch { disconnect(); throw error }
    }
}
