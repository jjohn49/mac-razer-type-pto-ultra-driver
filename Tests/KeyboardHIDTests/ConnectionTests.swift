import XCTest
import Darwin
import KeyboardCore
@testable import KeyboardHID

final class ConnectionTests:XCTestCase {
    func pair() throws -> [Int32] {
        var descriptors:[Int32]=[0,0]
        guard socketpair(AF_UNIX,SOCK_STREAM,0,&descriptors) == 0 else { throw RazerError.transport("socketpair") }
        descriptors.forEach(LocalConnection.configure)
        return descriptors
    }
    func testFramedProfileRoundTrip() throws {
        let fd=try pair(); defer { fd.forEach { close($0) } }
        let configuration=HelperConfiguration(enabled:false,deviceID:"example",settings:Settings())
        try LocalConnection.send(HelperRequest.configure(configuration),fd:fd[0])
        let received=try LocalConnection.receive(HelperRequest.self,fd:fd[1])
        XCTAssertEqual(received.kind,.configure)
        XCTAssertEqual(received.configuration,configuration)
    }
    func testRejectsOversizedFrameBeforeAllocatingBody() throws {
        let fd=try pair(); defer { fd.forEach { close($0) } }
        var header=UInt32(4_000_001).bigEndian
        _=withUnsafeBytes(of:&header) { Darwin.send(fd[0],$0.baseAddress,4,0) }
        XCTAssertThrowsError(try LocalConnection.receive(HelperRequest.self,fd:fd[1]))
    }
    func testClosedPeerDoesNotSignalOrHang() throws {
        let fd=try pair(); close(fd[0]); defer { close(fd[1]) }
        XCTAssertThrowsError(try LocalConnection.receive(HelperReply.self,fd:fd[1]))
        XCTAssertThrowsError(try LocalConnection.send(HelperReply(status:"test"),fd:fd[1]))
    }
    func testInvalidJSONFailsClosed() throws {
        let fd=try pair(); defer { fd.forEach { close($0) } }
        let bytes:[UInt8]=[0,0,0,1,0x7B]
        _=bytes.withUnsafeBytes { Darwin.send(fd[0],$0.baseAddress,$0.count,0) }
        XCTAssertThrowsError(try LocalConnection.receive(HelperRequest.self,fd:fd[1]))
    }
}
