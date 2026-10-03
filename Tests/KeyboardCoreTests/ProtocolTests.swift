import XCTest
@testable import KeyboardCore

final class ProtocolTests:XCTestCase {
    func response(_ command:RazerCommand, args:[UInt8], status:UInt8=2) throws -> [UInt8] {
        var bytes=try command.packet(transaction:0x1F)
        bytes[0]=status; bytes[5]=UInt8(args.count)
        for i in 8..<88 { bytes[i]=0 }
        bytes.replaceSubrange(8..<(8+args.count),with:args)
        bytes[88]=RazerCommand.checksum(bytes)
        return bytes
    }
    func testObservedFirmwareAndMode() throws {
        let url=Bundle.module.url(forResource:"wired-readings",withExtension:"json",subdirectory:"Fixtures")!
        let fixtures=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:url))
        for (name,command) in [("firmware",RazerCommand.firmware),("mode",.mode),("brightness",.brightness),("battery",.battery),("charging",.charging),("idle",.idle)] {
            let bytes=fixtures[name]!.split(separator:" ").map { UInt8($0,radix:16)! }
            XCTAssertNoThrow(try command.decode(bytes,transaction:0x1F))
        }
        XCTAssertEqual(try RazerCommand.mode.decode(response(.mode,args:[0]),transaction:0x1F),[0])
    }
    func testBrightnessRequestAndValidation() throws {
        let request=try RazerCommand.brightness.packet(transaction:0x1F)
        XCTAssertEqual(Array(request.prefix(11)),[0,31,0,0,0,3,15,132,1,5,0])
        XCTAssertEqual(request[88],0x8C)
        var reply=try response(.brightness,args:[1,5,6])
        XCTAssertEqual(try RazerCommand.brightness.decode(reply,transaction:0x1F),[1,5,6])
        reply[10] ^= 1
        XCTAssertThrowsError(try RazerCommand.brightness.decode(reply,transaction:0x1F))
        XCTAssertThrowsError(try RazerCommand.brightness.decode(Array(reply.prefix(89)),transaction:0x1F))
        XCTAssertThrowsError(try RazerCommand.brightness.decode(response(.brightness,args:[1,5]),transaction:0x1F))
        XCTAssertThrowsError(try RazerCommand.brightness.decode(response(.brightness,args:[1,5,6]),transaction:0x9F))
        XCTAssertThrowsError(try RazerCommand.brightness.decode(response(.firmware,args:[1,0]),transaction:0x1F))
    }
    func testBusyRetriesAreBoundedAndUnsupportedIsNotRetried() throws {
        let transport=FakeTransport()
        transport.replies=[try response(.firmware,args:[],status:1),try response(.firmware,args:[1,0])]
        let session=RazerSession(transport:transport,wait:{_ in})
        XCTAssertEqual(try session.perform(.firmware),[1,0]); XCTAssertEqual(transport.calls,2)
        transport.replies=Array(repeating:try response(.firmware,args:[],status:1),count:3)
        XCTAssertThrowsError(try session.perform(.firmware)); XCTAssertEqual(transport.calls,5)
        transport.replies=[try response(.firmware,args:[],status:5)]
        XCTAssertThrowsError(try session.perform(.firmware)); XCTAssertEqual(transport.calls,6)
    }
    func testTransportErrorIsNotRetried() {
        let t=FakeTransport()
        XCTAssertThrowsError(try RazerSession(transport:t,wait:{_ in}).perform(.firmware))
        XCTAssertEqual(t.calls,1)
    }
    func testIdleBoundariesAndModelSpecificLighting() throws {
        XCTAssertThrowsError(try RazerCommand.idle(seconds:59))
        XCTAssertThrowsError(try RazerCommand.idle(seconds:901))
        XCTAssertEqual(try RazerCommand.idle(seconds:900).arguments,[3,132])
        XCTAssertEqual(RazerCommand.effect(.staticWhite).arguments,[1,5,1,0,1,1,255,255,255])
        XCTAssertEqual(RazerCommand.effect(.breathing).arguments,[1,5,2,1,1,1,255,255,255])
    }
}
final class FakeTransport:ReportTransport {
    var replies:[[UInt8]]=[]
    var calls=0
    func exchange(_ request:[UInt8]) throws -> [UInt8] {
        calls += 1
        guard !replies.isEmpty else { throw RazerError.transport("timeout") }
        return replies.removeFirst()
    }

    func testProxyForwardsOnlyKnownCommands() throws {
        for command in [RazerCommand.firmware, .mode, .brightness, .battery, .charging, .idle, .brightness(7), try .idle(seconds: 120), .effect(.breathing)] {
            XCTAssertTrue(ProxyPolicy.permits(try command.packet(transaction: 0x1F)), "\(command.commandClass)/\(command.id)")
        }
        // Device-mode write (can enter firmware-update mode) and arbitrary classes are refused.
        XCTAssertFalse(ProxyPolicy.permits(try RazerCommand(0x00, 0x04, [3, 0]).packet(transaction: 0x1F)))
        XCTAssertFalse(ProxyPolicy.permits(try RazerCommand(0x0F, 0x03, [0, 0, 0, 0]).packet(transaction: 0x1F)))
        var corrupted = try RazerCommand.firmware.packet(transaction: 0x1F); corrupted[88] ^= 1
        XCTAssertFalse(ProxyPolicy.permits(corrupted))
        XCTAssertFalse(ProxyPolicy.permits([UInt8](repeating: 0, count: 89)))
    }
}
