import SwiftUI
import KeyboardCore
import KeyboardHID

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var setup: SetupModel
    var body: some View {
        Form {
            Section {
                ForEach(setup.items) { item in SetupRow(item: item) }
            } header: {
                HStack {
                    Text("Checklist")
                    Spacer()
                    Button("Check again", systemImage: "arrow.clockwise") { setup.refresh(model: model) }.font(.body)
                }
            } footer: {
                Text("Each step uses a standard macOS dialog. Nothing here needs Terminal. Steps are checked again every few seconds.")
            }
            Section("Keyboard") {
                LabeledContent("In use", value: model.deviceLabel)
                Picker("Choose", selection: $model.settings.selectedDevice) {
                    Text("Automatic (wired first, then receiver)").tag(String?.none)
                    ForEach(model.devices) { Text($0.label).tag(Optional($0.id)) }
                }
                Button("Refresh keyboards", systemImage: "arrow.clockwise") { model.refreshDevices() }
            }
            Section("This app") {
                Toggle("Launch at login (menu bar only)", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Text("Recommended. Remapping runs in the background service either way; the app is only needed for per-application profiles, launching applications, and inserting text.").font(.caption).foregroundStyle(.secondary)
                Button("Export diagnostics…") { model.exportDiagnostics(setup: setup.items) }
            }
            Section("Recovery") {
                Text("Control + Option + Escape on the Razer releases the keyboard and turns remapping off until you turn it on again here. The built-in keyboard is never captured. Remove everything with make uninstall.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { setup.refresh(model: model) }
        .alert("Setup", isPresented: Binding(get: { !setup.message.isEmpty }, set: { if !$0 { setup.message = "" } })) {
            Button("OK") { setup.message = "" }
        } message: { Text(setup.message) }
    }
}

struct SetupRow: View {
    let item: SetupItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.done ? "checkmark.circle.fill" : (item.optional ? "circle" : "exclamationmark.circle.fill"))
                .foregroundStyle(item.done ? .green : (item.optional ? .secondary : .orange))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let title = item.actionTitle, let action = item.action, !item.done {
                    Button(title, action: action).buttonStyle(.borderedProminent).controlSize(.small)
                }
                if let title = item.secondaryTitle, let action = item.secondaryAction, !item.done || item.alwaysShowSecondary {
                    Button(title, action: action).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
