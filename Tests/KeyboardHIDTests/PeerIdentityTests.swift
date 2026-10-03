import XCTest
@testable import KeyboardHID

final class PeerIdentityTests: XCTestCase {
    func testRequirementNamesTeamAndEveryIdentifier() {
        let requirement = PeerIdentity.requirement(team: "ABCDE12345")
        XCTAssertTrue(requirement.hasPrefix("anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and ("))
        for id in PeerIdentity.allowedIdentifiers { XCTAssertTrue(requirement.contains("identifier \"\(id)\"")) }
        XCTAssertFalse(PeerIdentity.allowedIdentifiers.contains("local.protypeultra.helper"), "the helper must not accept itself as a controller")
    }
    func testUntrustedSocketIsRejected() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { fds.forEach { close($0) } }
        // The test runner is not signed as the app or CLI, so it must be refused
        // whether or not a team identity is present.
        XCTAssertFalse(PeerIdentity.trusted(fd: fds[1]))
    }
}
