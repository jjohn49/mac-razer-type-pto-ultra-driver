import SwiftUI
import AppKit
import KeyboardCore
import KeyboardHID

struct ProfilesView:View {
    @EnvironmentObject var model:AppModel
    var body:some View {
        Form {
            TextField("Profile name",text:$model.settings.profiles[model.profileIndex].name)
            Toggle("Switch automatically by application",isOn:$model.settings.automaticProfiles)
            TextField("Application bundle IDs (comma-separated)",text:Binding(get:{model.profile.applicationIDs.joined(separator:", ")},set:{ value in model.settings.profiles[model.profileIndex].applicationIDs=value.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty } }))
            Text("Active: \(model.activeProfile.name)").foregroundStyle(.secondary)
            HStack {
                Button("New profile") { var p=Profile(); p.name="New profile"; model.settings.profiles.append(p); model.settings.selectedProfile=p.id }
                Button("Duplicate") { var p=model.profile; p.id=UUID(); p.name += " copy"; p.applicationIDs=[]; model.settings.profiles.append(p); model.settings.selectedProfile=p.id }
                Button("Delete profile") { let id=model.settings.selectedProfile; model.settings.selectedProfile=model.settings.profiles.first { $0.id != id }!.id; model.settings.profiles.removeAll { $0.id == id } }.disabled(model.settings.profiles.count == 1)
            }
            HStack { Button("Import profiles") { model.importSettings() }; Button("Export profiles") { model.exportSettings() } }
            Text("Settings are local to this Mac. Remapping and macros keep running when this app is closed; switching profiles by application needs the app running (launch at login keeps it in the menu bar).").foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

