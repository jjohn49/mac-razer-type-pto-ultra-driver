import Foundation

/// Bumped when the app and helper can no longer talk to each other.
public let helperProtocolVersion = "2"

/// Everything the helper needs to run without the app: it is persisted by the
/// helper and applied at boot and whenever the keyboard appears.
public struct HelperConfiguration: Codable, Equatable, Sendable {
    public var version = 1
    public var enabled: Bool
    /// `nil` selects the keyboard automatically (wired, then receiver, then Bluetooth).
    public var deviceID: String?
    public var settings: Settings
    public init(enabled: Bool, deviceID: String?, settings: Settings) {
        self.enabled = enabled; self.deviceID = deviceID; self.settings = settings
    }
    public func validate() throws {
        guard version == 1 else { throw ProfileError.invalid("Unsupported helper configuration version") }
        try settings.validate()
    }
}

public struct HelperRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case status, configure, session, hardware }
    public var kind: Kind
    public var configuration: HelperConfiguration?
    public var frontmostApplication: String?
    public var recording = false
    /// `hardware`: one 90-byte Razer request to exchange on the control interface.
    public var packet: [UInt8]?
    public init(kind: Kind, configuration: HelperConfiguration? = nil, frontmostApplication: String? = nil, recording: Bool = false) {
        self.kind = kind; self.configuration = configuration
        self.frontmostApplication = frontmostApplication; self.recording = recording
    }
    public static let status = HelperRequest(kind: .status)
    public static func configure(_ configuration: HelperConfiguration) -> HelperRequest {
        HelperRequest(kind: .configure, configuration: configuration)
    }
    /// Sent by the logged-in user's app every half second while it runs. It
    /// enables per-application profiles, drains launch/text actions, and
    /// delivers recorded input. Capture itself does not depend on it.
    public static func session(frontmostApplication: String?, recording: Bool) -> HelperRequest {
        HelperRequest(kind: .session, frontmostApplication: frontmostApplication, recording: recording)
    }
    /// The helper owns the keyboard's control interface while it runs; the app and
    /// CLI send their reads and writes through it so nothing interleaves.
    public static func hardware(_ packet: [UInt8]) -> HelperRequest {
        var request = HelperRequest(kind: .hardware); request.packet = packet; return request
    }
}

public struct UserAction: Codable, Equatable, Sendable {
    public var kind: ActionKind
    public var value: String
    public init(kind: ActionKind, value: String) { self.kind = kind; self.value = value }
}

public struct RecordedInput: Codable, Equatable, Sendable {
    public var key: Key
    public var down: Bool
    public var time: Double
    public init(key: Key, down: Bool, time: Double) { self.key = key; self.down = down; self.time = time }
}

public struct HelperReply: Codable, Equatable, Sendable {
    public var status: String
    /// Set when the request was refused; the client surfaces it as an error.
    public var error: String?
    public var capturing = false
    public var virtualReady = false
    public var enabled = false
    /// The helper tried to seize the keyboard and macOS refused: Input Monitoring
    /// has not been granted to the helper.
    public var captureDenied = false
    /// Accessibility granted to the helper. On macOS 26.1+ this is the grant that
    /// permits capturing the keyboard; Input Monitoring no longer lists daemons.
    public var accessibilityTrusted = false
    /// False when the helper is not team-signed and therefore cannot verify which
    /// process is talking to it (ad-hoc builds).
    public var peerVerification = false
    public var deviceLabel: String?
    public var deviceID: String?
    public var activeProfileName = ""
    public var sessionConnected = false
    public var helperVersion = helperProtocolVersion
    public var actions: [UserAction] = []
    public var recorded: [RecordedInput] = []
    /// `hardware` reply: the 90-byte response.
    public var packet: [UInt8]?
    /// Whether the helper currently has (or can open) the control interface.
    public var hardwareAvailable = false
    public init(status: String) { self.status = status }
}

/// Launch and text actions must run in the user's session. They wait here for
/// the app to drain them and are dropped when no app is around to run them.
public struct PendingActions: Sendable {
    private struct Entry: Sendable { let action: UserAction; let time: Double }
    private var entries: [Entry] = []
    public var lifetime = 2.0
    public var limit = 64
    public init() {}
    public var count: Int { entries.count }
    public mutating func append(_ action: UserAction, now: Double) {
        expire(now: now)
        guard entries.count < limit else { return }
        entries.append(Entry(action: action, time: now))
    }
    public mutating func drain(now: Double) -> [UserAction] {
        defer { entries.removeAll() }
        return entries.filter { now - $0.time <= lifetime }.map(\.action)
    }
    public mutating func expire(now: Double) { entries.removeAll { now - $0.time > lifetime } }
}
