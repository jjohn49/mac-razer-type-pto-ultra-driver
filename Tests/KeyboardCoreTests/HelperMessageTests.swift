import XCTest
@testable import KeyboardCore

final class HelperMessageTests: XCTestCase {
    func testConfigurationRoundTrip() throws {
        var settings = Settings(); settings.remappingEnabled = true
        let configuration = HelperConfiguration(enabled: true, deviceID: "631:USB:1", settings: settings)
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(HelperConfiguration.self, from: data)
        XCTAssertEqual(decoded, configuration)
        XCTAssertNoThrow(try decoded.validate())
    }
    func testConfigurationRejectsUnknownVersion() throws {
        var configuration = HelperConfiguration(enabled: false, deviceID: nil, settings: Settings())
        configuration.version = 2
        XCTAssertThrowsError(try configuration.validate())
    }
    func testRequestKindsDecode() throws {
        let requests: [HelperRequest] = [
            .status,
            .configure(HelperConfiguration(enabled: true, deviceID: nil, settings: Settings())),
            .session(frontmostApplication: "com.apple.Safari", recording: true)
        ]
        for request in requests {
            let decoded = try JSONDecoder().decode(HelperRequest.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(decoded.kind, request.kind)
            XCTAssertEqual(decoded.frontmostApplication, request.frontmostApplication)
            XCTAssertEqual(decoded.recording, request.recording)
            XCTAssertEqual(decoded.configuration, request.configuration)
        }
    }
    func testReplyRoundTripKeepsNewFields() throws {
        var reply = HelperReply(status: "Active")
        reply.capturing = true; reply.enabled = true; reply.captureDenied = false
        reply.deviceLabel = "Pro Type Ultra — USB"; reply.activeProfileName = "Default"; reply.sessionConnected = true
        let decoded = try JSONDecoder().decode(HelperReply.self, from: JSONEncoder().encode(reply))
        XCTAssertEqual(decoded.deviceLabel, reply.deviceLabel)
        XCTAssertEqual(decoded.activeProfileName, "Default")
        XCTAssertTrue(decoded.sessionConnected)
        XCTAssertEqual(decoded.helperVersion, helperProtocolVersion)
    }
    func testSettingsWithoutRemappingKeyDecodesDisabled() throws {
        let json = #"{"version":1,"profiles":[{"id":"6B1A3C0E-0000-4000-8000-000000000001","name":"Default","applicationIDs":[],"bindings":[],"macros":[]}],"selectedProfile":"6B1A3C0E-0000-4000-8000-000000000001","automaticProfiles":true}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.remappingEnabled)
        XCTAssertNil(settings.selectedDevice)
        XCTAssertNoThrow(try settings.validate())
    }
    func testLightingDefaultsAndValidation() throws {
        let json = #"{"version":1,"profiles":[{"id":"6B1A3C0E-0000-4000-8000-000000000001","name":"Default","applicationIDs":[],"bindings":[],"macros":[]}],"selectedProfile":"6B1A3C0E-0000-4000-8000-000000000001"}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.lighting, LightingSettings())
        XCTAssertFalse(settings.lighting.managed)
        var bad = settings; bad.lighting.fadeSeconds = 0
        XCTAssertThrowsError(try bad.validate())
        var round = settings; round.lighting.mode = .candle; round.lighting.managed = true
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(round))
        XCTAssertEqual(decoded.lighting, round.lighting)
    }
    func testPendingActionsExpireAndCap() {
        var queue = PendingActions()
        queue.append(UserAction(kind: .launch, value: "/Applications/Safari.app"), now: 0)
        queue.append(UserAction(kind: .text, value: "hi"), now: 1.5)
        XCTAssertEqual(queue.drain(now: 2.5).map(\.value), ["hi"])
        XCTAssertEqual(queue.count, 0)
        for i in 0..<100 { queue.append(UserAction(kind: .text, value: "\(i)"), now: 10) }
        XCTAssertEqual(queue.count, 64)
        queue.expire(now: 20)
        XCTAssertEqual(queue.count, 0)
    }
}
