import Foundation
import Darwin
import IOKit.hid
import SystemConfiguration
import ApplicationServices
import KeyboardCore
import KeyboardHID

/// Owns the keyboard. Runs on the main run loop: IOKit callbacks and the
/// request handler both arrive there, so no locking is needed.
final class InputService {
    // Persistent state
    private(set) var configuration = HelperConfiguration(enabled: false, deviceID: nil, settings: Settings())
    // Session state (lives only while the user's app keeps polling)
    private var frontmostApplication: String?
    private var sessionSeen = -1.0
    private var recording = false
    private var pendingActions = PendingActions()
    private var recorded: [RecordedInput] = []
    // Capture state
    private var engine = MappingEngine()
    private var devices: [IOHIDDevice] = []
    private var keysByInterface: [UInt64: Set<Key>] = [:]
    private var deviceLabel: String?
    private var captureDenied = false
    private var lastDiscovery = -10.0
    private var emergency = false
    private(set) var status = "Starting"
    /// Backlight owner and hardware proxy.
    let lighting = LightingService()
    private var lastDeviceScan = -10.0
    private var lightingDeviceID: String?
    // Virtual output bridge
    private(set) var ready = false
    let output = Process()
    private let input = Pipe()
    private let replies = Pipe()
    private var replyBuffer = ""

    static let sessionLifetime = 2.5
    var capturing: Bool { !devices.isEmpty }
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var sessionAlive: Bool { now - sessionSeen < Self.sessionLifetime }

    // MARK: Lifecycle

    func start() throws {
        configuration = ConfigurationStore.load()
        lighting.update(configuration.settings.lighting)
        lighting.start()
        emit(engine.setProfile(desiredProfile()))
        status = configuration.enabled ? "Waiting for virtual output" : "Remapping is off"
        requestPermissions()
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let path = executable.deletingLastPathComponent().appendingPathComponent("protype-output")
        output.executableURL = path
        output.standardInput = input; output.standardOutput = replies; output.standardError = FileHandle.standardError
        output.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.ready = false; self?.stop("Virtual output stopped") } }
        replies.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.replyBuffer += text
                while let newline = self.replyBuffer.firstIndex(of: "\n") {
                    let line = String(self.replyBuffer[..<newline]); self.replyBuffer.removeSubrange(...newline)
                    if line == "READY" { self.ready = true; if !self.capturing { self.status = self.configuration.enabled ? "Virtual output ready" : "Remapping is off" } }
                    else { self.ready = false; self.stop(line) }
                }
            }
        }
        try output.run()
        let fd = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// Registers the helper in System Settings so the user can allow it. Input
    /// Monitoring stopped listing daemons on macOS 26.1; Accessibility still does,
    /// and on those systems an Accessibility grant also covers keyboard capture.
    private func requestPermissions() {
        HIDDevices.requestPermission()
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    func shutdown() {
        stop("Helper stopped")
        try? input.fileHandleForWriting.close()
    }

    // MARK: Requests

    func reply() -> HelperReply {
        var reply = HelperReply(status: status)
        reply.capturing = capturing; reply.virtualReady = ready
        reply.enabled = configuration.enabled; reply.captureDenied = captureDenied
        reply.accessibilityTrusted = AXIsProcessTrusted()
        reply.peerVerification = PeerIdentity.enforced
        reply.deviceLabel = deviceLabel ?? lightingDeviceID.flatMap { id in HIDDevices.list().first { $0.id == id }?.label }
        reply.deviceID = lightingDeviceID
        reply.hardwareAvailable = lighting.available
        reply.activeProfileName = engine.profile.name
        reply.sessionConnected = sessionAlive
        return reply
    }

    func handle(_ request: HelperRequest) throws -> HelperReply {
        switch request.kind {
        case .status:
            return reply()
        case .configure:
            guard let next = request.configuration else { throw RazerError.invalidRequest }
            try next.validate()
            try ConfigurationStore.save(next)
            apply(next)
            return reply()
        case .session:
            sessionSeen = now
            frontmostApplication = request.frontmostApplication
            if request.recording != recording { setRecording(request.recording) }
            applyProfileIfChanged()
            var reply = reply()
            reply.actions = pendingActions.drain(now: now)
            reply.recorded = recorded; recorded = []
            return reply
        case .hardware:
            throw RazerError.invalidRequest // served off the main queue in main.swift
        }
    }

    private func apply(_ next: HelperConfiguration) {
        let previous = configuration
        configuration = next
        if next.enabled && !previous.enabled { emergency = false }
        if next.deviceID != previous.deviceID || !next.enabled { stop(next.enabled ? "Applying configuration" : "Remapping is off") }
        if !next.enabled { lastDiscovery = -10 }
        if next.deviceID != previous.deviceID { lastDeviceScan = -10 }
        lighting.update(next.settings.lighting)
        applyProfileIfChanged()
    }

    private func desiredProfile() -> Profile {
        configuration.settings.activeProfile(applicationID: sessionAlive ? frontmostApplication : nil)
    }

    private func applyProfileIfChanged() {
        let wanted = desiredProfile()
        guard wanted != engine.profile else { return }
        emit(engine.setProfile(wanted))
        keysByInterface = [:]
    }

    private func setRecording(_ value: Bool) {
        emit(engine.reset()); keysByInterface = [:]; recorded = []; recording = value
    }

    // MARK: Capture

    func tick() {
        let now = now
        if !sessionAlive && (recording || frontmostApplication != nil) {
            // The app went away: back to the selected profile, no recording.
            if recording { setRecording(false) }
            frontmostApplication = nil
            applyProfileIfChanged()
        }
        pendingActions.expire(now: now)
        // The backlight is managed whether or not remapping is on, so the lighting
        // service learns about the keyboard independently of capture.
        if now - lastDeviceScan > 2 {
            lastDeviceScan = now
            let chosen = HIDDevices.preferred(HIDDevices.list(), override: configuration.deviceID)
            if chosen?.id != lightingDeviceID {
                lightingDeviceID = chosen?.id
                lighting.setDevice(chosen?.id, wireless: chosen?.productID == 0x027B)
            }
        }
        guard configuration.enabled, !emergency else { if capturing { stop("Remapping is off") }; return }
        guard ready else { if capturing { stop("Virtual output unavailable") }; return }
        if !capturing && now - lastDiscovery > (captureDenied ? 5 : 1) { lastDiscovery = now; capture() }
        if capturing && !recording { emit(engine.tick(now: now)) }
    }

    private func capture() {
        guard let chosen = HIDDevices.preferred(HIDDevices.list(), override: configuration.deviceID) else { status = "Waiting for the keyboard"; deviceLabel = nil; return }
        let interfaces = HIDDevices.inputInterfaces(for: chosen.id)
        guard !interfaces.isEmpty else { status = "No input interface on \(chosen.label)"; return }
        for d in interfaces {
            let opened = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            guard opened == kIOReturnSuccess else {
                if opened == kIOReturnNotPermitted { captureDenied = true; requestPermissions() }
                stop(opened == kIOReturnNotPermitted ? "Allow Pro Type Ultra Helper in System Settings → Privacy & Security → Accessibility" : String(format: "Cannot capture the keyboard (0x%08X)", opened))
                return
            }
            devices.append(d)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputValueCallback(d, { context, result, _, value in
                guard let context else { return }
                let service = Unmanaged<InputService>.fromOpaque(context).takeUnretainedValue()
                guard result == kIOReturnSuccess else { service.stop("Input device error"); return }
                service.inputValue(value)
            }, context)
            IOHIDDeviceRegisterRemovalCallback(d, { context, _, _ in
                if let context { Unmanaged<InputService>.fromOpaque(context).takeUnretainedValue().stop("Keyboard disconnected") }
            }, context)
            IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        captureDenied = false
        deviceLabel = chosen.label
        status = "Active on \(chosen.label)"
    }

    private func stop(_ reason: String) {
        let releases = engine.reset()
        emit(releases)
        if capturing || !releases.isEmpty { write("R") }
        for d in devices {
            IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }
        devices = []; keysByInterface = [:]; status = reason
    }

    private func inputValue(_ value: IOHIDValue) {
        guard ready, capturing else { return }
        let element = IOHIDValueGetElement(value)
        let key = Key(IOHIDElementGetUsage(element), page: IOHIDElementGetUsagePage(element))
        guard (try? Profile.validate(key)) != nil else { return }
        let n = IOHIDValueGetIntegerValue(value)
        let d = IOHIDElementGetDevice(element)
        var id: UInt64 = 0; IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(d), &id)
        let before = Set(keysByInterface.values.flatMap { $0 })
        if n != 0 { keysByInterface[id, default: []].insert(key) } else { keysByInterface[id, default: []].remove(key) }
        let after = Set(keysByInterface.values.flatMap { $0 })
        guard before.contains(key) != after.contains(key) else { return }
        let down = after.contains(key)
        if down { lighting.noteActivity() }
        if down && key == Key(41) && !after.isDisjoint(with: [Key(224), Key(228)]) && !after.isDisjoint(with: [Key(226), Key(230)]) {
            emergencyStop(); return
        }
        let now = now
        if recording {
            if recorded.count < 4096 { recorded.append(.init(key: key, down: down, time: now)) }
            return // Recording is explicit; test keys do not type into the active app.
        }
        emit(engine.handle(key, down: down, now: now))
    }

    /// Control + Option + Escape on the Razer. Persists "off" so the keyboard
    /// stays released across helper restarts until the user turns it back on.
    private func emergencyStop() {
        emergency = true
        configuration.enabled = false
        try? ConfigurationStore.save(configuration)
        stop("Emergency stop. Turn remapping on again in the app.")
    }

    // MARK: Output

    private func write(_ line: String) {
        guard output.isRunning else { ready = false; return }
        do { try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
        catch { ready = false }
    }
    private func emit(_ values: [Output]) {
        for value in values {
            switch value {
            case .key(let key, let down): write("K \(key.page) \(key.usage) \(down ? 1 : 0)")
            case .pointer(let x, let y, let scroll): write("P \(x) \(y) \(scroll)")
            case .userAction(let kind, let text): pendingActions.append(.init(kind: kind, value: text), now: now)
            }
        }
    }

    static func consoleUID() -> uid_t {
        var uid: uid_t = 0; var gid: gid_t = 0
        _ = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid)
        return uid
    }
}
