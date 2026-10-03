import SwiftUI
import AppKit
import KeyboardCore
import KeyboardHID

struct KeyPicker:View {
    let title:String
    @SwiftUI.Binding var key:Key
    var body:some View { Picker(title,selection:$key) { ForEach(KeyCatalog.all) { Text($0.label).tag($0) } } }
}
struct KeyboardView:View {
    @EnvironmentObject var model:AppModel
    @State private var draft=Binding(source:Key(4),keys:[Key(4)])
    @State private var editing=false
    @State private var layer=false
    let rows:[[UInt32]] = [[41,58,59,60,61,62,63,64,65,66,67,68,69],[53,30,31,32,33,34,35,36,37,38,39,45,46,42],[43,20,26,8,21,23,28,24,12,18,19,47,48,49],[57,4,22,7,9,10,11,13,14,15,51,52,40],[225,29,27,6,25,5,17,16,54,55,56,229],[224,227,226,44,230,231,101,228,80,81,82,79]]
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("Choose a key to change what it does.").font(.title2)
                Toggle("Edit alternate layer",isOn:$layer)
                ForEach(rows.indices,id:\.self) { i in
                    HStack(spacing:4) {
                        ForEach(rows[i],id:\.self) { code in
                            Button(Key(code).label) { edit(Key(code)) }
                                .font(.system(size:10)).frame(minWidth:34,minHeight:30)
                                .tint(model.profile.bindings.contains { $0.source == Key(code) && $0.alternate == layer } ? .accentColor : .gray)
                        }
                    }
                }
                HStack {
                    Button("Add any key / keypad / media binding") { edit(Key(4)) }
                    Picker("Layer trigger",selection:Binding(get:{model.profile.layerKey},set:{model.settings.profiles[model.profileIndex].layerKey=$0})) {
                        Text("None").tag(Key?.none)
                        ForEach(KeyCatalog.all.filter { $0.page == 7 }) { Text($0.label).tag(Optional($0)) }
                    }
                }
                Text("Physical Fn is firmware-controlled until its reports are verified. Use another key for the alternate layer.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.profile.bindings) { binding in
                    HStack {
                        Text("\(binding.source.label)\(binding.alternate ? " (alternate)" : "") → \(description(binding))")
                        Spacer()
                        Button("Edit") { draft=binding; editing=true }
                        Button("Remove") { model.settings.profiles[model.profileIndex].bindings.removeAll { $0.id == binding.id } }
                    }
                }
                Text("Control + Option + Escape on the Razer always releases the keyboard.").font(.caption)
            }
        }.sheet(isPresented:$editing) { BindingEditor(draft:$draft) { candidate in
            var profile=model.profile
            profile.bindings.removeAll { $0.id == candidate.id || ($0.source == candidate.source && $0.alternate == candidate.alternate) }
            profile.bindings.append(candidate)
            do { try profile.validate(); model.settings.profiles[model.profileIndex]=profile; editing=false }
            catch { model.message=error.localizedDescription }
        }.environmentObject(model) }
    }
    func edit(_ key:Key) { draft=model.profile.bindings.first { $0.source == key && $0.alternate == layer } ?? Binding(source:key,keys:[key]); draft.alternate=layer; editing=true }
    func description(_ binding:KeyboardCore.Binding)->String {
        switch binding.kind {
        case .keys: return binding.keys.map(\.label).joined(separator:" + ")
        case .text: return "Insert text"
        case .launch: return URL(fileURLWithPath:binding.text).lastPathComponent
        case .macro: return model.profile.macros.first { $0.id == binding.macroID }?.name ?? "Missing macro"
        case .pointer: return "Pointer / scroll"
        case .disabled: return "Disabled"
        }
    }
}

struct BindingEditor:View {
    @EnvironmentObject var model:AppModel
    @Environment(\.dismiss) var dismiss
    @SwiftUI.Binding var draft:KeyboardCore.Binding
    let save:(KeyboardCore.Binding)->Void
    var body:some View {
        Form {
            Text("Key assignment").font(.title2)
            KeyPicker(title:"Input",key:$draft.source)
            Toggle("Alternate layer",isOn:$draft.alternate)
            Picker("Action",selection:$draft.kind) { ForEach(ActionKind.allCases,id:\.self) { Text($0.rawValue.capitalized).tag($0) } }
            switch draft.kind {
            case .keys:
                ForEach(draft.keys.indices,id:\.self) { i in
                    HStack { KeyPicker(title:"Output \(i+1)",key:$draft.keys[i]); Button("Remove") { draft.keys.remove(at:i) } }
                }
                Button("Add output key / modifier") { if draft.keys.count < 16 { draft.keys.append(Key(4)) } }
            case .text: TextEditor(text:$draft.text).frame(height:120)
            case .launch:
                TextField("Absolute .app path",text:$draft.text)
                Button("Choose application") {
                    let panel=NSOpenPanel(); panel.directoryURL=URL(fileURLWithPath:"/Applications"); panel.allowedContentTypes=[.application]
                    if panel.runModal() == .OK { draft.text=panel.url?.path ?? "" }
                }
            case .macro:
                Picker("Macro",selection:$draft.macroID) {
                    Text("Choose").tag(UUID?.none)
                    ForEach(model.profile.macros) { Text($0.name).tag(Optional($0.id)) }
                }
            case .pointer:
                Stepper("Horizontal: \(draft.dx)",value:$draft.dx,in:-127...127)
                Stepper("Vertical: \(draft.dy)",value:$draft.dy,in:-127...127)
                Stepper("Scroll: \(draft.scroll)",value:$draft.scroll,in:-127...127)
            case .disabled: Text("This key produces no output.")
            }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save") { save(draft) }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:550)
    }
}

