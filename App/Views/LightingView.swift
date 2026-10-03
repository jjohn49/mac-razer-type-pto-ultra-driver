import SwiftUI
import KeyboardCore
import KeyboardHID

struct LightingView: View {
    @EnvironmentObject var model: AppModel
    @State private var brightness = 255.0
    @State private var dragging = false
    @State private var idle = 900
    @State private var idleWork: DispatchWorkItem?
    @State private var syncingIdle = false
    private var lighting: SwiftUI.Binding<LightingSettings> {
        SwiftUI.Binding(get: { model.settings.lighting }, set: { value in var next = value; next.managed = true; model.settings.lighting = next })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            KeyboardStatusPanel()
            Form {
                if !HIDDevices.permissionGranted() && !model.helperConnected {
                    Section {
                        Text("Reading the keyboard needs Input Monitoring for Pro Type Ultra, or the background service.")
                        HStack {
                            Button("Request") { HIDDevices.requestPermission() }
                            Button("Open Input Monitoring settings") { SetupModel.openInputMonitoring() }
                        }
                    }
                }
                Section {
                    HStack {
                        Slider(value: $brightness, in: 0...255, step: 1) { Text("Brightness") } onEditingChanged: { editing in
                            dragging = editing
                            if !editing { lighting.wrappedValue.brightness = UInt8(brightness) }
                        }
                        Text(brightness == 0 ? "Off" : "\(Int(brightness))").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                    Picker("Effect", selection: lighting.mode) {
                        Text("Static white").tag(LightingSettings.Mode.staticWhite)
                        Text("Breathing").tag(LightingSettings.Mode.breathing)
                        Text("Reactive typing").tag(LightingSettings.Mode.reactive)
                        Text("Candle").tag(LightingSettings.Mode.candle)
                    }
                    switch model.settings.lighting.mode {
                    case .reactive:
                        Slider(value: lighting.idleFraction, in: 0...1) { Text("Idle brightness") } minimumValueLabel: { Text("Off") } maximumValueLabel: { Text("Full") }
                        Stepper("Fade back over \(model.settings.lighting.fadeSeconds, specifier: "%.0f") s", value: lighting.fadeSeconds, in: 1...15, step: 1)
                        if !model.settings.remappingEnabled {
                            Label("Reactive typing needs remapping on, because that is when the background service sees keystrokes.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                        }
                    case .candle:
                        Slider(value: lighting.flicker, in: 0.05...1) { Text("Flicker") } minimumValueLabel: { Text("Calm") } maximumValueLabel: { Text("Wild") }
                    default: EmptyView()
                    }
                } header: { Text("Backlight") } footer: {
                    Text(model.settings.lighting.managed
                         ? "Kept by the background service: applied at startup, on reconnect, and with the app closed. Brightness 0 turns the backlight off."
                         : "Showing the keyboard's current setting. Change anything here and the background service will keep it from then on.")
                }
                Section {
                    Stepper("Sleep after \(idle / 60) min of inactivity", value: $idle, in: 60...900, step: 60)
                } header: { Text("Power") } footer: {
                    Text("Written to the keyboard when changed. Effects beyond static and breathing are brightness animations: this keyboard has one white zone and refuses per-key control. Breathing and the sleep timer are unverified on hardware; Bluetooth configuration is not supported yet.")
                }
            }
            .formStyle(.grouped)
            .disabled(!model.canConfigure)
        }
        .onAppear { brightness = Double(model.settings.lighting.brightness) }
        .task { if model.canConfigure && (HIDDevices.permissionGranted() || model.helperConnected) { model.readHardware() } }
        .onChange(of: model.canConfigure) { _, can in if can { model.readHardware() } }
        .onChange(of: model.settings.lighting.brightness) { _, value in if !dragging { brightness = Double(value) } }
        .onChange(of: idle) { _, value in
            guard !syncingIdle, let command = try? RazerCommand.idle(seconds: value) else { return }
            idleWork?.cancel()
            let work = DispatchWorkItem { model.apply(command) }
            idleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        .onChange(of: model.snapshot.readings) { _, values in
            syncingIdle = true
            if let s = values["Idle seconds"], let value = Int(s) { idle = value }
            DispatchQueue.main.async { syncingIdle = false }
        }
    }
}

/// Read-only facts about the connected keyboard. Deliberately not a form: nothing
/// here is a setting, so nothing here looks like one.
struct KeyboardStatusPanel: View {
    @EnvironmentObject var model: AppModel
    private struct Fact: Identifiable { let id: String; let value: String }
    private var facts: [Fact] {
        let r = model.snapshot.readings
        var facts: [Fact] = []
        if let v = r["Battery (raw, unvalidated)"] { facts.append(Fact(id: "Battery", value: "raw \(v)")) }
        if let v = r["Charging"] { facts.append(Fact(id: "Charging", value: v)) }
        if let v = r["Brightness (raw)"] { facts.append(Fact(id: "Brightness", value: "\(v) of 255")) }
        if let v = r["Idle seconds"], let s = Int(v) { facts.append(Fact(id: "Sleeps after", value: s % 60 == 0 ? "\(s / 60) min" : "\(s) s")) }
        if let v = r["Firmware"] { facts.append(Fact(id: "Firmware", value: v)) }
        if let v = r["Mode"] { facts.append(Fact(id: "Mode", value: v)) }
        return facts
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.automaticDevice?.product ?? "No keyboard").font(.title3.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small)
                } else if model.canConfigure {
                    Button { model.readHardware() } label: { Label("Read again", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
            if !facts.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 10) {
                    ForEach(facts) { fact in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fact.id).font(.caption).foregroundStyle(.secondary)
                            Text(fact.value).font(.body.monospacedDigit())
                        }
                    }
                }
            } else if !model.canConfigure {
                Text("Connect the USB cable or the receiver to read and change keyboard settings.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.snapshot.errors.keys.sorted(), id: \.self) { key in
                Label("\(key): \(model.snapshot.errors[key]!)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
    private var subtitle: String {
        guard let device = model.automaticDevice else { return "Not connected" }
        var parts = [device.transport]
        if model.capturing { parts.append("remapping active") }
        else if model.settings.remappingEnabled { parts.append("remapping starting") }
        else { parts.append("remapping off") }
        if let date = model.snapshotDate { parts.append("read at " + date.formatted(date: .omitted, time: .shortened)) }
        return parts.joined(separator: ", ")
    }
}
