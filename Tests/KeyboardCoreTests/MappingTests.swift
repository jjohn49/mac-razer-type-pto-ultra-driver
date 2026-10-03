import XCTest
@testable import KeyboardCore

final class MappingTests:XCTestCase {
    let a=Key(4), b=Key(5), shift=Key(225)
    func testPassThroughSuppressesDuplicateReports() {
        let engine=MappingEngine()
        XCTAssertEqual(engine.handle(a,down:true,now:0),[.key(a,true)])
        XCTAssertEqual(engine.handle(a,down:true,now:0),[])
        XCTAssertEqual(engine.handle(a,down:false,now:1),[.key(a,false)])
        XCTAssertEqual(engine.handle(a,down:false,now:1),[])
    }
    func testSharedModifierOwnership() {
        var p=Profile(); p.bindings=[Binding(source:a,keys:[shift,b])]
        let e=MappingEngine(profile:p)
        XCTAssertEqual(e.handle(shift,down:true,now:0),[.key(shift,true)])
        XCTAssertEqual(e.handle(a,down:true,now:0),[.key(b,true)])
        XCTAssertEqual(e.handle(a,down:false,now:1),[.key(b,false)])
        XCTAssertEqual(e.handle(shift,down:false,now:1),[.key(shift,false)])
    }
    func testLayerReleaseDoesNotChangeHeldBinding() {
        var p=Profile(); p.layerKey=Key(57)
        var binding=Binding(source:a,keys:[b]); binding.alternate=true; p.bindings=[binding]
        let e=MappingEngine(profile:p)
        XCTAssertEqual(e.handle(Key(57),down:true,now:0),[])
        XCTAssertEqual(e.handle(a,down:true,now:0),[.key(b,true)])
        XCTAssertEqual(e.handle(Key(57),down:false,now:1),[])
        XCTAssertEqual(e.handle(a,down:false,now:1),[.key(b,false)])
    }
    func macroEngine(_ mode:MacroMode) -> MappingEngine {
        var m=Macro(); m.mode=mode; m.repetitions=2
        m.steps=[.init(key:b,down:true),.init(key:b,down:false,delayMS:100)]
        var binding=Binding(source:a); binding.kind = .macro; binding.macroID=m.id
        var p=Profile(); p.macros=[m]; p.bindings=[binding]
        return MappingEngine(profile:p)
    }
    func testHeldMacroCancellationReleasesOutput() {
        let e=macroEngine(.whileHeld)
        XCTAssertEqual(e.handle(a,down:true,now:0),[.key(b,true)])
        XCTAssertEqual(e.handle(a,down:false,now:0.05),[.key(b,false)])
        XCTAssertEqual(e.tick(now:100),[])
    }
    func testToggleAndCountedPlayback() {
        let e=macroEngine(.toggle)
        _=e.handle(a,down:true,now:0); _=e.handle(a,down:false,now:0.01)
        XCTAssertEqual(e.handle(a,down:true,now:0.02),[.key(b,false)])
        XCTAssertEqual(e.tick(now:10),[])
        let counted=macroEngine(.counted)
        XCTAssertEqual(counted.handle(a,down:true,now:0),[.key(b,true)])
        XCTAssertEqual(counted.tick(now:1),[.key(b,false),.key(b,true),.key(b,false)])
        XCTAssertEqual(counted.tick(now:2),[])
    }
    func testResetAndProfileSwitchReleaseEverything() {
        let e=macroEngine(.toggle)
        _=e.handle(a,down:true,now:0); _=e.handle(shift,down:true,now:0)
        XCTAssertEqual(Set(e.setProfile(Profile()).compactMap { if case .key(let k,false)=$0 { return k }; return nil }),[b,shift])
        XCTAssertEqual(e.tick(now:100),[])
        XCTAssertEqual(e.handle(a,down:false,now:1),[])
    }
    func testTextIsOnlyEmittedOnInitialPress() {
        var p=Profile(); var binding=Binding(source:a); binding.kind = .text; binding.text="Hello"; p.bindings=[binding]
        let e=MappingEngine(profile:p)
        XCTAssertEqual(e.handle(a,down:true,now:0),[.userAction(.text,"Hello")])
        XCTAssertEqual(e.handle(a,down:true,now:0),[])
        XCTAssertEqual(e.handle(a,down:false,now:1),[])
    }
}
