import Foundation

public enum RazerError: Error, LocalizedError, Equatable {
    case invalidRequest, malformedResponse(String), deviceStatus(UInt8), transport(String), unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid Razer command arguments."
        case .malformedResponse(let detail): return "Invalid keyboard response: \(detail)"
        case .deviceStatus(let status): return String(format: "Keyboard returned status 0x%02X.", status)
        case .transport(let message), .unavailable(let message): return message
        }
    }
}

public struct RazerCommand: Equatable, Sendable {
    public let commandClass: UInt8
    public let id: UInt8
    public let arguments: [UInt8]
    public let minimumResponseArguments: Int
    public init(_ commandClass: UInt8, _ id: UInt8, _ arguments: [UInt8], minimum: Int = 0) {
        self.commandClass = commandClass; self.id = id
        self.arguments = arguments; self.minimumResponseArguments = minimum
    }
    public func packet(transaction: UInt8) throws -> [UInt8] {
        guard arguments.count <= 80, transaction != 0 else { throw RazerError.invalidRequest }
        var data = [UInt8](repeating: 0, count: 90)
        data[1] = transaction; data[5] = UInt8(arguments.count)
        data[6] = commandClass; data[7] = id
        data.replaceSubrange(8..<(8 + arguments.count), with: arguments)
        data[88] = Self.checksum(data)
        return data
    }
    public static func checksum(_ data: [UInt8]) -> UInt8 { data[2..<88].reduce(0, ^) }
    public func decode(_ data: [UInt8], transaction: UInt8) throws -> [UInt8] {
        guard data.count == 90 else { throw RazerError.malformedResponse("expected 90 bytes") }
        guard data[88] == Self.checksum(data) else { throw RazerError.malformedResponse("checksum") }
        guard data[1] == transaction, data[6] == commandClass, data[7] == id else {
            throw RazerError.malformedResponse("transaction or command mismatch")
        }
        guard data[2] == 0, data[3] == 0, data[4] == 0, data[5] <= 80 else {
            throw RazerError.malformedResponse("invalid header")
        }
        guard data[0] == 2 else { throw RazerError.deviceStatus(data[0]) }
        guard Int(data[5]) >= minimumResponseArguments else { throw RazerError.malformedResponse("missing arguments") }
        return Array(data[8..<(8 + Int(data[5]))])
    }

    public static let firmware = RazerCommand(0, 0x81, [0, 0], minimum: 2)
    public static let mode = RazerCommand(0, 0x84, [0, 0], minimum: 1)
    public static let brightness = RazerCommand(0x0F, 0x84, [1, 5, 0], minimum: 3)
    public static let battery = RazerCommand(7, 0x80, [0, 0], minimum: 2)
    public static let charging = RazerCommand(7, 0x84, [0, 0], minimum: 2)
    public static let idle = RazerCommand(7, 0x83, [0, 0], minimum: 2)
    public static func brightness(_ value: UInt8) -> RazerCommand { .init(0x0F, 4, [1, 5, value]) }
    public static func idle(seconds: Int) throws -> RazerCommand {
        guard (60...900).contains(seconds) else { throw RazerError.invalidRequest }
        return .init(7, 3, [UInt8(seconds >> 8), UInt8(seconds & 255)])
    }
    // Packet layout follows OpenRazer, GPL-2.0-or-later; see THIRD_PARTY.md.
    public static func effect(_ effect: LightingEffect) -> RazerCommand {
        switch effect {
        case .off: return .init(0x0F, 2, [1, 5, 0, 0, 0, 0])
        case .staticWhite: return .init(0x0F, 2, [1, 5, 1, 0, 1, 1, 255, 255, 255])
        case .breathing: return .init(0x0F, 2, [1, 5, 2, 1, 1, 1, 255, 255, 255])
        }
    }
}

public enum LightingEffect: String, Codable, CaseIterable, Sendable { case off, staticWhite, breathing }

/// Commands the helper will forward on behalf of the app or CLI. Everything else,
/// in particular device-mode writes that can switch the keyboard into firmware
/// update mode, is refused regardless of who asks.
public enum ProxyPolicy {
    public static let allowed: Set<UInt16> = [
        0x0081, 0x0084,         // firmware version, device mode (read)
        0x0780, 0x0783, 0x0784, // battery, idle time, charging (read)
        0x0703,                 // idle time (write)
        0x0F84, 0x0F04, 0x0F02  // brightness read/write, effect
    ]
    public static func permits(_ packet: [UInt8]) -> Bool {
        guard packet.count == 90, packet[88] == RazerCommand.checksum(packet), packet[5] <= 80 else { return false }
        return allowed.contains(UInt16(packet[6]) << 8 | UInt16(packet[7]))
    }
}


public protocol ReportTransport: AnyObject {
    func exchange(_ request: [UInt8]) throws -> [UInt8]
    /// Write without waiting for the reply; for animations that send many frames.
    func send(_ request: [UInt8]) throws
}
public extension ReportTransport {
    func send(_ request: [UInt8]) throws { _ = try exchange(request) }
}

/// Owned by one serial worker. Only a device's BUSY response is retried.
public final class RazerSession {
    let transport: ReportTransport
    let transaction: UInt8
    let wait: (TimeInterval) -> Void
    public init(transport: ReportTransport, wireless: Bool = false, wait: @escaping (TimeInterval) -> Void = Thread.sleep) {
        self.transport = transport; transaction = wireless ? 0x9F : 0x1F; self.wait = wait
    }
    /// Fire-and-forget write; no status check, no retry. Used for animation frames.
    public func send(_ command: RazerCommand) throws {
        try transport.send(try command.packet(transaction: transaction))
    }
    public func perform(_ command: RazerCommand) throws -> [UInt8] {
        let request = try command.packet(transaction: transaction)
        for attempt in 0..<3 {
            do { return try command.decode(transport.exchange(request), transaction: transaction) }
            catch RazerError.deviceStatus(1) where attempt < 2 { wait(0.08 * Double(attempt + 1)) }
        }
        throw RazerError.deviceStatus(1)
    }
}
