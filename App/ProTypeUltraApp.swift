import SwiftUI
import AppKit
import ServiceManagement
import KeyboardCore
import KeyboardHID

/// Remembers how the app was started. Launched by macOS at login it stays in the
/// menu bar; opened by the user it behaves like a normal app with a window.
enum LaunchContext {
    static var launchedAtLogin = false
    static var showWindow: (() -> Void)?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister") {
            Daemons.unregisterAll()
            exit(0)
        }
        if CommandLine.arguments.contains("--restart-services") {
            let problems = Daemons.restartAll()
            problems.forEach { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            exit(problems.isEmpty ? 0 : 1)
        }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == keyAELaunchedAsLogInItem
        LaunchContext.launchedAtLogin = launchedAtLogin
        if launchedAtLogin { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard LaunchContext.launchedAtLogin else { return }
        DispatchQueue.main.async { NSApp.windows.filter { $0.title == "Pro Type Ultra" }.forEach { $0.close() } }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        guard !flag, let show = LaunchContext.showWindow else { return true }
        show(); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct ProTypeUltraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var setup = SetupModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        let _ = (LaunchContext.showWindow = showWindow)
        Window("Pro Type Ultra", id: "main") {
            MainView().environmentObject(model).environmentObject(setup).frame(minWidth: 900, minHeight: 620)
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                    guard let window = note.object as? NSWindow, window.title == "Pro Type Ultra" else { return }
                    if model.launchAtLogin { DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) } }
                }
        }
        .defaultLaunchBehavior(LaunchContext.launchedAtLogin ? .suppressed : .presented)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            Text(model.settings.remappingEnabled ? model.helperStatus : "Remapping is off").font(.caption)
            Text(model.deviceLabel).font(.caption)
            if let charging = model.snapshot.readings["Charging"] { Text("Charging: \(charging)").font(.caption) }
            Divider()
            Toggle("Remapping", isOn: $model.settings.remappingEnabled)
            if model.settings.profiles.count > 1 {
                Picker("Profile", selection: $model.settings.selectedProfile) {
                    ForEach(model.settings.profiles) { Text($0.name).tag($0.id) }
                }
            }
            Divider()
            Button("Settings…") { showWindow() }.keyboardShortcut(",")
            Button("Quit Pro Type Ultra") { NSApp.terminate(nil) }.keyboardShortcut("q")
            Text("Remapping keeps running after you quit.").font(.caption)
        } label: {
            Image(systemName: model.settings.remappingEnabled && model.capturing ? "keyboard.fill" : "keyboard")
        }
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum Page: String, CaseIterable, Identifiable {
    case keyboard = "Keyboard", macros = "Macros", profiles = "Profiles", lighting = "Lighting & Power", setup = "Setup"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .keyboard: return "keyboard"
        case .macros: return "record.circle"
        case .profiles: return "person.2"
        case .lighting: return "lightbulb"
        case .setup: return "checklist"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var setup: SetupModel
    @State private var page: Page? = .keyboard
    @State private var routed = false
    var body: some View {
        NavigationSplitView {
            List(Page.allCases, id: \.self, selection: $page) { page in
                Label(page.rawValue, systemImage: page.icon)
                    .badge(page == .setup && !setup.ready ? Text("!") : nil)
            }
            .navigationTitle("Pro Type Ultra")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Remapping", isOn: $model.settings.remappingEnabled).toggleStyle(.switch)
                    Label(model.settings.remappingEnabled ? (model.capturing ? "Active" : "Not active") : "Off",
                          systemImage: model.settings.remappingEnabled && model.capturing ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundStyle(model.settings.remappingEnabled && model.capturing ? .green : .secondary)
                    Text(model.deviceLabel).font(.caption).foregroundStyle(.secondary)
                    Text(setup.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                if (page ?? .keyboard) != .setup {
                    HStack {
                        Picker("Profile", selection: $model.settings.selectedProfile) {
                            ForEach(model.settings.profiles) { Text($0.name).tag($0.id) }
                        }.frame(maxWidth: 320)
                        Spacer()
                        if !setup.ready { Button("Finish setup", systemImage: "exclamationmark.circle") { page = .setup } }
                    }
                    Divider()
                }
                switch page ?? .keyboard {
                case .keyboard: KeyboardView()
                case .macros: MacrosView()
                case .profiles: ProfilesView()
                case .lighting: LightingView()
                case .setup: SetupView()
                }
            }.padding(20)
        }
        .task { setup.refresh(model: model) }
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in setup.refresh(model: model) }
        .onChange(of: setup.items.isEmpty) { _, empty in
            // First checklist result decides the landing page: unfinished setup opens Setup.
            if !empty && !routed { routed = true; if !setup.ready { page = .setup } }
        }
        .alert("Pro Type Ultra", isPresented: Binding(get: { !model.message.isEmpty }, set: { if !$0 { model.message = "" } })) {
            Button("OK") { model.message = "" }
        } message: { Text(model.message) }
    }
}
