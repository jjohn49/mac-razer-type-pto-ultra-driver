import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement
import KeyboardCore
import KeyboardHID

struct SetupItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let done: Bool
    let optional: Bool
    let actionTitle: String?
    let action: (() -> Void)?
    let secondaryTitle: String?
    let secondaryAction: (() -> Void)?
    let alwaysShowSecondary: Bool
    init(id: String, title: String, detail: String, done: Bool, optional: Bool = false,
         actionTitle: String? = nil, action: (() -> Void)? = nil,
         secondaryTitle: String? = nil, secondaryAction: (() -> Void)? = nil, alwaysShowSecondary: Bool = false) {
        self.id = id; self.title = title; self.detail = detail; self.done = done; self.optional = optional
        self.actionTitle = actionTitle; self.action = action
        self.secondaryTitle = secondaryTitle; self.secondaryAction = secondaryAction; self.alwaysShowSecondary = alwaysShowSecondary
    }
}

/// The two background services the app registers from its own bundle. One
/// approval in System Settings → Login Items covers both.
enum Daemons {
    static let helper = SMAppService.daemon(plistName: "local.protypeultra.helper.plist")
    static let virtualHID = SMAppService.daemon(plistName: "local.protypeultra.virtualhid.plist")
    static var all: [SMAppService] { [virtualHID, helper] }
    static func unregisterAll() {
        for service in all { try? service.unregister() }
    }
    /// Unregister + register restarts both daemons without a password; needed after
    /// the bundle is replaced so the running helper matches the file on disk.
    static func restartAll() -> [String] {
        var problems: [String] = []
        for service in all { try? service.unregister() }
        Thread.sleep(forTimeInterval: 1)
        for service in all { do { try service.register() } catch { problems.append(error.localizedDescription) } }
        return problems
    }
}

enum Legacy {
    static let daemonPlist = "/Library/LaunchDaemons/local.protypeultra.helper.plist"
    static var present: Bool { FileManager.default.fileExists(atPath: daemonPlist) }
}

enum VirtualHID {
    static let packageIdentifier = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"
    static let requiredVersion = "8.6.0"
    static let manager = "/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager"
    static var package: URL? { Bundle.main.url(forResource: "Karabiner-DriverKit-VirtualHIDDevice-8.6.0", withExtension: "pkg") }
}

@MainActor final class SetupModel: ObservableObject {
    @Published var items: [SetupItem] = []
    @Published var summary = "Checking…"
    @Published var ready = false
    @Published var message = ""
    private var refreshing = false
    /// pkgutil and systemextensionsctl are separate programs; once both report the
    /// driver installed and active they are asked again only every minute, not on
    /// every 4-second refresh.
    private var slowProbe: (package: String?, extensionState: String?, at: Date)?

    struct Probe {
        var inApplications = false
        var packageVersion: String?
        var extensionState: String?
        var helperDaemon: SMAppService.Status = .notFound
        var virtualDaemon: SMAppService.Status = .notFound
        var inputMonitoring = false
        var accessibility = false
        var legacy = false
    }

    func refresh(model: AppModel) {
        guard !refreshing else { return }; refreshing = true
        let cached = slowProbe.flatMap { probe in
            probe.package == VirtualHID.requiredVersion && probe.extensionState?.contains("[activated enabled]") == true
                && Date().timeIntervalSince(probe.at) < 60 ? probe : nil
        }
        Task.detached(priority: .userInitiated) {
            var probe = Probe()
            probe.inApplications = Bundle.main.bundleURL.path.hasPrefix("/Applications/")
            if let cached {
                probe.packageVersion = cached.package; probe.extensionState = cached.extensionState
            } else {
                probe.packageVersion = Self.installedPackageVersion()
                probe.extensionState = Self.extensionState()
            }
            probe.helperDaemon = Daemons.helper.status
            probe.virtualDaemon = Daemons.virtualHID.status
            probe.inputMonitoring = HIDDevices.permissionGranted()
            probe.accessibility = AXIsProcessTrusted()
            probe.legacy = Legacy.present
            let result = probe
            await MainActor.run {
                if cached == nil { self.slowProbe = (result.packageVersion, result.extensionState, Date()) }
                self.build(result, model: model); self.refreshing = false
            }
        }
    }

    private func build(_ p: Probe, model: AppModel) {
        var items: [SetupItem] = []
        if p.legacy {
            items.append(SetupItem(id: "legacy", title: "Remove the old Terminal-installed service", detail: "A previous version installed its helper under /Library. It conflicts with the new background service and must be removed first.", done: false, actionTitle: "Remove…", action: { [weak self] in self?.removeLegacy() }))
        }
        items.append(SetupItem(id: "location", title: "App is in the Applications folder", detail: p.inApplications ? Bundle.main.bundlePath : "Background services can only be registered from /Applications.", done: p.inApplications, actionTitle: "Move to Applications", action: { [weak self] in self?.moveToApplications() }))
        let packageOK = p.packageVersion == VirtualHID.requiredVersion
        items.append(SetupItem(id: "package", title: "Virtual keyboard driver installed", detail: p.packageVersion.map { "Karabiner-DriverKit-VirtualHIDDevice \($0)" + (packageOK ? "" : " installed; \(VirtualHID.requiredVersion) is required") } ?? "Installs the signed pqrs.org virtual keyboard package (version \(VirtualHID.requiredVersion)). Installer asks for your password.", done: packageOK, actionTitle: "Install…", action: { [weak self] in self?.installPackage() }))
        let extensionOK = p.extensionState?.contains("[activated enabled]") == true
        let extensionDetail: String
        if extensionOK { extensionDetail = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice is active." }
        else if p.extensionState?.contains("waiting for user") == true { extensionDetail = "Waiting for your approval: System Settings → General → Login Items & Extensions → scroll to Driver Extensions → click ⓘ → turn on Karabiner-DriverKit-VirtualHIDDevice (pqrs.org), then enter your password. If no switch appears, click Activate again. A restart can be required." }
        else { extensionDetail = p.extensionState ?? "Activate the extension, then allow it under System Settings → General → Login Items & Extensions → Driver Extensions." }
        items.append(SetupItem(id: "extension", title: "Driver extension approved", detail: extensionDetail, done: extensionOK, actionTitle: "Activate", action: { [weak self] in self?.activateExtension() }, secondaryTitle: "Open Extensions settings", secondaryAction: { Self.openExtensions() }))
        let daemonsOK = p.helperDaemon == .enabled && p.virtualDaemon == .enabled
        let daemonDetail: String
        switch (p.helperDaemon, p.virtualDaemon) {
        case (.enabled, .enabled): daemonDetail = "Registered and allowed. Remapping runs even when this app is closed."
        case (.requiresApproval, _), (_, .requiresApproval): daemonDetail = "Allow \"Pro Type Ultra\" under System Settings → General → Login Items & Extensions → Allow in the Background."
        default: daemonDetail = "Registers the helper and the virtual keyboard service with launchd. macOS then asks you to allow them in Login Items."
        }
        items.append(SetupItem(id: "daemons", title: "Background service allowed", detail: daemonDetail, done: daemonsOK, actionTitle: daemonsOK ? nil : "Register", action: { [weak self] in self?.registerDaemons() }, secondaryTitle: daemonsOK ? "Restart service" : "Open Login Items settings", secondaryAction: { [weak self] in if daemonsOK { self?.restartDaemons() } else { SMAppService.openSystemSettingsLoginItems() } }, alwaysShowSecondary: daemonsOK))
        items.append(SetupItem(id: "inputApp", title: "Input Monitoring for Pro Type Ultra", detail: p.inputMonitoring ? "Granted. Used to read keyboard settings and record macros." : "Needed to read lighting and power settings and to record macros. Click Request, allow it, then Relaunch: macOS applies the change only to a restarted app. If the switch already looks on, turn it off and on again (each rebuild of this app needs a fresh grant).", done: p.inputMonitoring, actionTitle: p.inputMonitoring ? nil : "Request", action: { HIDDevices.requestPermission() }, secondaryTitle: "Relaunch app", secondaryAction: { [weak self] in self?.relaunch() }))
        let helperTried = model.helperConnected
        let helperOK = helperTried && model.helper?.captureDenied == false
        let helperDetail: String
        if !helperTried { helperDetail = "Waiting for the background service to start." }
        else if model.helper?.captureDenied == true { helperDetail = "macOS refused the capture. In Privacy & Security → Accessibility, turn on \"Pro Type Ultra Helper\" (on macOS 26.1 and later this grant also covers keyboard capture; daemons no longer appear under Input Monitoring). If it is not listed, click +, press Command-Shift-G, and paste the copied path, or drag ProTypeUltraHelper.app from the Finder window into the list. It retries on its own every five seconds." }
        else if model.helper?.accessibilityTrusted == false && model.settings.remappingEnabled { helperDetail = "Capturing. Accessibility is not granted to the helper yet; grant it if capture ever stops after a macOS update." }
        else if !model.settings.remappingEnabled { helperDetail = "Will be checked when remapping is turned on." }
        else { helperDetail = model.helperStatus }
        items.append(SetupItem(id: "inputHelper", title: "Keyboard capture allowed for Pro Type Ultra Helper", detail: helperDetail, done: helperOK, actionTitle: helperOK ? nil : "Reveal helper + open Accessibility", action: { Self.revealHelperForDrop() }, secondaryTitle: "Copy helper path", secondaryAction: { Self.copyHelperPath() }))
        if let helper = model.helper, !helper.peerVerification {
            items.append(SetupItem(id: "peer", title: "Helper cannot verify who controls it", detail: "This build is not signed with a team identity, so any program running as you could push a profile to the helper. Rebuild with an Apple Development or self-signed identity (see README) to enforce signed-peer checks.", done: false, optional: true))
        }
        items.append(SetupItem(id: "accessibility", title: "Accessibility (optional, for text insertion)", detail: p.accessibility ? "Granted." : "Only needed for \"Insert text\" actions. Launching applications and all remapping work without it.", done: p.accessibility, optional: true, actionTitle: p.accessibility ? nil : "Request", action: { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }))
        self.items = items
        let blocking = items.first { !$0.done && !$0.optional }
        ready = blocking == nil
        if let blocking { summary = "Next: \(blocking.title)" }
        else if model.settings.remappingEnabled { summary = model.capturing ? "Ready — remapping active on \(model.deviceLabel)" : "Ready — \(model.helperStatus)" }
        else { summary = "Ready — remapping is off" }
    }

    // MARK: Probes

    nonisolated static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    nonisolated static func installedPackageVersion() -> String? {
        guard let output = run("/usr/sbin/pkgutil", ["--pkg-info", VirtualHID.packageIdentifier]) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("version:") {
            return line.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
    nonisolated static func extensionState() -> String? {
        guard let output = run("/usr/bin/systemextensionsctl", ["list"]) else { return nil }
        guard let line = output.split(separator: "\n").first(where: { $0.contains(VirtualHID.packageIdentifier) }) else { return nil }
        if let bracket = line.range(of: "[") { return String(line[bracket.lowerBound...]) }
        return String(line)
    }

    // MARK: Actions

    func installPackage() {
        guard let package = VirtualHID.package else { message = "The installer package is missing from this app bundle. Rebuild with make build."; return }
        NSWorkspace.shared.open(package)
    }
    /// The manager's `activate` submits the request and then blocks until macOS
    /// approves it, so it is given three seconds and then stopped; the request
    /// stays pending in System Settings.
    func activateExtension() {
        guard FileManager.default.isExecutableFile(atPath: VirtualHID.manager) else { message = "The Karabiner manager is not installed. Install the driver package first."; return }
        Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: VirtualHID.manager); process.arguments = ["activate"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try? process.run()
            try? await Task.sleep(for: .seconds(3))
            if process.isRunning { process.terminate() }
            await MainActor.run { Self.openExtensions() }
        }
    }
    /// Input Monitoring changes apply to a process only after it restarts.
    func relaunch() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"\(Bundle.main.bundlePath)\""]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
    func registerDaemons() {
        var problems: [String] = []
        for service in Daemons.all {
            // A service that was never registered, or whose approval record was reset,
            // reports .notFound; unregistering first keeps launchd's database consistent.
            if service.status == .notFound { try? service.unregister() }
            do { try service.register() } catch { problems.append(error.localizedDescription) }
        }
        if Daemons.all.contains(where: { $0.status == .requiresApproval }) || !problems.isEmpty {
            SMAppService.openSystemSettingsLoginItems()
        }
        if !problems.isEmpty { message = "Allow Pro Type Ultra in Login Items, then try again. (\(problems.joined(separator: " ")))" }
    }
    func restartDaemons() {
        let problems = Daemons.restartAll()
        if !problems.isEmpty { message = problems.joined(separator: " ") }
    }
    func removeLegacy() {
        // Also removes a root-owned 0.1 app copy in /Applications (installed with sudo);
        // a copy owned by the user is left alone.
        let shell = [
            "launchctl bootout system/local.protypeultra.helper",
            "launchctl bootout system/local.protypeultra.virtualhid",
            "rm -f /Library/LaunchDaemons/local.protypeultra.helper.plist /Library/LaunchDaemons/local.protypeultra.virtualhid.plist",
            "rm -f '/Library/Application Support/ProTypeUltra/protype-helper' '/Library/Application Support/ProTypeUltra/protype-output' '/Library/Application Support/ProTypeUltra/protype'",
            "if [ -d /Applications/ProTypeUltra.app ] && [ \"$(stat -f %u /Applications/ProTypeUltra.app)\" = 0 ]; then rm -rf /Applications/ProTypeUltra.app; fi",
            "exit 0"
        ].joined(separator: "; ")
        let quoted = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(quoted)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error, let text = error[NSAppleScript.errorMessage] as? String, !text.contains("canceled") { message = text }
    }
    func moveToApplications() {
        let source = Bundle.main.bundleURL
        let target = URL(fileURLWithPath: "/Applications/ProTypeUltra.app")
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
        } catch { message = "Could not copy the app: \(error.localizedDescription). Drag it to Applications in Finder instead."; return }
        // Launch Services would just re-activate this running instance if asked to
        // open the copy now, so relaunch after this process has exited.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"\(target.path)\""]
        do { try relaunch.run() } catch { message = "Copied to Applications. Open it from there: \(error.localizedDescription)"; return }
        NSApp.terminate(nil)
    }
    static var helperAppURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Helpers/ProTypeUltraHelper.app") }
    static func revealHelperForDrop() {
        NSWorkspace.shared.activateFileViewerSelecting([helperAppURL])
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    static func copyHelperPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(helperAppURL.path, forType: .string)
    }
    static func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    static func openExtensions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}
