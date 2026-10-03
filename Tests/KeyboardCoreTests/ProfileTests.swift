import XCTest
@testable import KeyboardCore

final class ProfileTests:XCTestCase {
    func testRoundTripAndUnknownVersion() throws {
        let settings=Settings()
        XCTAssertEqual(try ProfileStore.decode(JSONEncoder().encode(settings)),settings)
        var future=settings; future.version=2
        XCTAssertThrowsError(try ProfileStore.decode(JSONEncoder().encode(future)))
    }
    func testRejectsDanglingMacroAndDuplicateBindings() {
        var p=Profile(); var b=Binding(source:Key(4)); b.kind = .macro; b.macroID=UUID(); p.bindings=[b]
        XCTAssertThrowsError(try p.validate())
        p.bindings=[Binding(source:Key(4)),Binding(source:Key(4))]
        XCTAssertThrowsError(try p.validate())
    }
    func testRejectsUnbalancedMacroAndOverflowValues() {
        var p=Profile(); var m=Macro(); m.steps=[.init(key:Key(4),down:true)]; p.macros=[m]
        XCTAssertThrowsError(try p.validate())
        p.macros=[]; var b=Binding(source:Key(4)); b.dx=Int.min; p.bindings=[b]
        XCTAssertThrowsError(try p.validate())
    }
    func testAutomaticProfileFallsBackToManualSelection() {
        var s=Settings(); var p=Profile(); p.name="Editor"; p.applicationIDs=["com.example.editor"]; s.profiles.append(p)
        XCTAssertEqual(s.activeProfile(applicationID:"com.example.editor").id,p.id)
        XCTAssertEqual(s.activeProfile(applicationID:"another").id,s.selectedProfile)
        s.automaticProfiles=false
        XCTAssertEqual(s.activeProfile(applicationID:"com.example.editor").id,s.selectedProfile)
    }
}
