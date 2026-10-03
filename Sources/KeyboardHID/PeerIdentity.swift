import Foundation
import Darwin
import Security
import KeyboardCore

/// Decides which processes may control the helper. A process is trusted when it is
/// signed by the same team as the helper with one of the known identifiers, so a
/// program merely running as the logged-in user cannot push a profile that types.
/// Without a team identity (ad-hoc builds) nothing can be proven, and that fact
/// is reported so the app can warn.
public enum PeerIdentity {
    public static let allowedIdentifiers = ["local.protypeultra.app", "local.protypeultra.cli"]

    /// The team that signed the running process, if any.
    public static let ownTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// True when peers can be verified at all.
    public static var enforced: Bool { ownTeam != nil }

    public static func requirement(team: String, identifiers: [String] = allowedIdentifiers) -> String {
        let ids = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(ids))"
    }

    /// Verifies the process on the other end of a Unix socket.
    public static func trusted(fd: Int32) -> Bool {
        guard let team = ownTeam else { return false }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement(team: team) as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }
}
