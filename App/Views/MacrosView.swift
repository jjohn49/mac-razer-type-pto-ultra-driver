import SwiftUI
import AppKit
import KeyboardCore
import KeyboardHID

struct MacrosView:View {
    @EnvironmentObject var model:AppModel
    @State private var draft=Macro()
    @State private var editing=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Macros").font(.title2)
            Text("Recording captures only this keyboard and temporarily suppresses typing; it turns remapping on if needed. Stop recording with the mouse. Assign a saved macro on the Keyboard page.").foregroundStyle(.secondary)
            HStack {
                Button(model.recording ? "Stop and save recording" : "Record keyboard / buttons") { if model.recording { model.finishRecording() } else { model.beginRecording() } }.disabled(!model.helperConnected && !model.recording)
                Button("Create manually") { draft=Macro(); draft.steps=[.init(key:Key(4),down:true),.init(key:Key(4),down:false,delayMS:50)]; editing=true }
                Text("\(model.recordedSteps.count) recorded steps")
            }
            List(model.profile.macros) { macro in
                HStack { Text(macro.name); Text("\(macro.steps.count) steps · \(macro.mode.rawValue)").foregroundStyle(.secondary); Spacer()
                    Button("Edit") { draft=macro; editing=true }
                    Button("Delete") {
                        model.settings.profiles[model.profileIndex].bindings.removeAll { $0.macroID == macro.id }
                        model.settings.profiles[model.profileIndex].macros.removeAll { $0.id == macro.id }
                    }
                }
            }
        }.sheet(isPresented:$editing) {
            VStack(alignment:.leading) {
                TextField("Name",text:$draft.name)
                Picker("Playback",selection:$draft.mode) { ForEach(MacroMode.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                if draft.mode == .counted { Stepper("Repeat \(draft.repetitions) times",value:$draft.repetitions,in:1...1000) }
                List {
                    ForEach(draft.steps.indices,id:\.self) { i in
                        HStack {
                            TextField("Delay ms",value:$draft.steps[i].delayMS,format:.number).frame(width:90)
                            KeyPicker(title:"Key",key:$draft.steps[i].key)
                            Toggle("Down",isOn:$draft.steps[i].down)
                            Button("↑") { if i > 0 { draft.steps.swapAt(i,i-1) } }.disabled(i == 0)
                            Button("Delete") { draft.steps.remove(at:i) }
                        }
                    }
                }
                Button("Add key press/release") { draft.steps += [.init(key:Key(4),down:true),.init(key:Key(4),down:false,delayMS:50)] }
                HStack { Button("Cancel") { editing=false }; Spacer(); Button("Save") {
                    var p=model.profile; p.macros.removeAll { $0.id == draft.id }; p.macros.append(draft)
                    do { try p.validate(); model.settings.profiles[model.profileIndex]=p; editing=false } catch { model.message=error.localizedDescription }
                } }
            }.padding(20).frame(width:740,height:480)
        }
    }
}

