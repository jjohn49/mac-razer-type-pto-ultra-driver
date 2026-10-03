import SwiftUI
import AppKit
import Combine
import ApplicationServices
import ServiceManagement
import KeyboardCore
import KeyboardHID

@MainActor final class AppModel: ObservableObject {
    @Published var settings = Settings()
    @Published var devices: [DeviceInfo] = []
    @Published var snapshot = HardwareSnapshot()
    @Published var snapshotDate: Date?
    @Published var helper: HelperReply?
    @Published var helperError: String?
    @Published var recording = false
    @Published var message = ""
    @Published var busy = false
    @Published var recordedSteps: [MacroStep] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// True once the helper has answered (or refused) the first status request.
    @Published var initialSyncDone = false

    private var recordingHeld = Set<Key>()
    private var lastRecordedTime: Double?
    private let hardwareQueue = DispatchQueue(label: "local.protypeultra.hardware")
    private let helperQueue = DispatchQueue(label: "local.protypeultra.helper")
    private let client = HelperClient()
    private var pollInFlight = false
    private var timer: Timer?
    private var pushWork: DispatchWorkItem?
    private var loadFailed = false
    private var lastDeviceLabel: String?
    private var hardwareReadPending = false
    private var pushPending = false
    private var lastPushCompleted = -10.0
    private var subscriptions = Set<AnyCancellable>()

    init() {
        do { settings = try ProfileStore.load() } catch { loadFailed = true; message = "Cannot load settings: \(error.localizedDescription). Import a valid backup before saving." }
        refreshDevices()
        initialSync()
        // Saves and pushes whatever changes the settings, including the menu bar
        // toggle while the window is closed. Debounced so typing in a field does
        // not write a file per keystroke.
        $settings.dropFirst().removeDuplicates().debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.save() }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollSession() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    // MARK: Derived state

    var profileIndex: Int { settings.profiles.firstIndex { $0.id == settings.selectedProfile } ?? 0 }
    var profile: Profile { settings.profiles[profileIndex] }
    var activeProfile: Profile { settings.activeProfile(applicationID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
    /// The keyboard the helper would pick, or has picked.
    var automaticDevice: DeviceInfo? { HIDDevices.preferred(devices, override: settings.selectedDevice) }
    var deviceLabel: String { helper?.deviceLabel ?? automaticDevice?.label ?? "No keyboard connected" }
    var canConfigure: Bool { automaticDevice?.hasControlInterface == true }
    var capturing: Bool { helper?.capturing ?? false }
    var helperStatus: String { helperError ?? helper?.status ?? "Connecting to the background service" }
    var helperConnected: Bool { helper != nil && helperError == nil }

    // MARK: Settings persistence and push

    func save() {
        guard !loadFailed else { return }
        guard (try? settings.validate()) != nil else { return }
        do { try ProfileStore.save(settings) } catch { message = error.localizedDescription }
        schedulePush()
    }
    private var configuration: HelperConfiguration {
        HelperConfiguration(enabled: settings.remappingEnabled, deviceID: settings.selectedDevice, settings: settings)
    }
    private func schedulePush() {
        pushPending = true
        pushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.pushConfiguration() } }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    func pushConfiguration() {
        guard (try? settings.validate()) != nil else { return }
        let request = HelperRequest.configure(configuration)
        helperQueue.async { [weak self, client] in
            let result = Result { try client.exchange(request) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pushPending = false
                self.lastPushCompleted = ProcessInfo.processInfo.systemUptime
                self.absorb(result)
            }
        }
    }
    /// On launch the helper's "enabled" wins (it may have been turned off by the
    /// emergency chord while the app was closed); then our settings are pushed.
    private func initialSync() {
        helperQueue.async { [weak self, client] in
            let result = Result { try client.exchange(.status) }
            DispatchQueue.main.async {
                guard let self else { return }
                if case .success(let reply) = result, reply.enabled != self.settings.remappingEnabled {
                    self.settings.remappingEnabled = reply.enabled
                    if !self.loadFailed { try? ProfileStore.save(self.settings) }
                }
                self.absorb(result)
                self.initialSyncDone = true
                self.pushConfiguration()
            }
        }
    }

    // MARK: Session poll

    func pollSession() {
        guard !pollInFlight else { return }; pollInFlight = true
        let request = HelperRequest.session(frontmostApplication: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, recording: recording)
        helperQueue.async { [weak self, client] in
            let result = Result { try client.exchange(request) }
            DispatchQueue.main.async {
                guard let self else { return }; self.pollInFlight = false
                self.absorb(result)
                if case .success(let reply) = result {
                    if self.settings.remappingEnabled { for action in reply.actions { self.perform(action) } }
                    if self.recording { self.collect(reply.recorded) }
                    // The helper owns "enabled" (emergency chord, CLI). Reflect it unless we
                    // are in the middle of pushing our own change.
                    let settled = !self.pushPending && ProcessInfo.processInfo.systemUptime - self.lastPushCompleted > 1.5
                    if settled && reply.enabled != self.settings.remappingEnabled {
                        self.settings.remappingEnabled = reply.enabled
                    }
                }
            }
        }
    }
    private func absorb(_ result: Result<HelperReply, Error>) {
        switch result {
        case .success(let reply):
            helper = reply; helperError = nil
            if reply.deviceLabel != lastDeviceLabel { lastDeviceLabel = reply.deviceLabel; refreshDevices() }
        case .failure(let error):
            helper = nil; helperError = error.localizedDescription
        }
    }

    // MARK: Devices and hardware

    func refreshDevices() {
        devices = HIDDevices.list()
        if settings.selectedDevice != nil, !devices.contains(where: { $0.id == settings.selectedDevice }) { /* keep override; it applies when that keyboard returns */ }
    }
    /// Reads over the control interface, which the helper never seizes, so
    /// remapping continues meanwhile.
    func readHardware() {
        guard !busy else { hardwareReadPending = true; return }; busy = true
        let id = automaticDevice?.id
        hardwareQueue.async { [weak self] in
            let result = Result { try Hardware.read(deviceID: id) }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot; self.snapshotDate = Date()
                    // Until the user touches lighting, mirror the keyboard's own brightness.
                    if !self.settings.lighting.managed, let raw = snapshot.readings["Brightness (raw)"], let value = UInt8(raw) { self.settings.lighting.brightness = value }
                case .failure(let error): self.message = error.localizedDescription
                }
                if self.hardwareReadPending { self.hardwareReadPending = false; self.readHardware() }
            }
        }
    }
    private var pendingCommand: RazerCommand?
    /// Writes one setting. Calls while a write is in flight are coalesced: only the
    /// latest value is sent afterwards, so a dragged slider does not queue up.
    func apply(_ command: RazerCommand) {
        guard !busy else { pendingCommand = command; return }; busy = true
        let id = automaticDevice?.id
        hardwareQueue.async { [weak self] in
            let result = Result { _ = try Hardware.session(deviceID: id).perform(command) }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                if case .failure(let error) = result { self.message = error.localizedDescription }
                if let next = self.pendingCommand { self.pendingCommand = nil; self.apply(next) }
                else if case .success = result { self.readHardware() }
            }
        }
    }

    // MARK: User-session actions

    func perform(_ action: UserAction) {
        switch action.kind {
        case .launch:
            guard action.value.hasPrefix("/"), action.value.hasSuffix(".app"),
                  Bundle(url: URL(fileURLWithPath: action.value))?.bundleIdentifier != nil else { message = "Launch action skipped: not an application bundle."; return }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: action.value), configuration: .init()) { _, error in
                if let error { DispatchQueue.main.async { self.message = error.localizedDescription } }
            }
        case .text:
            guard AXIsProcessTrusted() else { message = "Text insertion requires Accessibility permission in Setup."; return }
            guard action.value.utf16.count <= 32768 else { return }
            // Small chunks, without splitting UTF-16 surrogate pairs.
            var chunks: [[UInt16]] = [[]]
            for scalar in action.value.unicodeScalars {
                let units = Array(String(scalar).utf16)
                if chunks[chunks.count - 1].count + units.count > 20 { chunks.append([]) }
                chunks[chunks.count - 1] += units
            }
            for units in chunks where !units.isEmpty {
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                units.withUnsafeBufferPointer { pointer in
                    if let base = pointer.baseAddress { down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base); up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base) }
                }
                down?.flags = []; up?.flags = []; down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
            }
        default: break
        }
    }

    // MARK: Macro recording

    func beginRecording() {
        recordedSteps = []; recordingHeld = []; lastRecordedTime = nil; recording = true
        if !settings.remappingEnabled { settings.remappingEnabled = true }
    }
    private func collect(_ events: [RecordedInput]) {
        for event in events {
            guard recordedSteps.count < 4000 else { message = "Recording limit reached"; finishRecording(); return }
            if event.down { guard recordingHeld.insert(event.key).inserted else { continue } }
            else { guard recordingHeld.remove(event.key) != nil else { continue } }
            let delay = lastRecordedTime.map { max(0, min(60_000, Int((event.time - $0) * 1000))) } ?? 0
            recordedSteps.append(.init(key: event.key, down: event.down, delayMS: delay)); lastRecordedTime = event.time
        }
    }
    func finishRecording() {
        recording = false
        for key in recordingHeld { recordedSteps.append(.init(key: key, down: false)) }
        recordingHeld = []
        guard !recordedSteps.isEmpty else { return }
        var macro = Macro(); macro.name = "Recorded macro"; macro.steps = recordedSteps
        settings.profiles[profileIndex].macros.append(macro); save()
    }

    // MARK: Import, export, diagnostics, login item

    func importSettings() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var imported = try ProfileStore.decode(Data(contentsOf: url))
            imported.remappingEnabled = settings.remappingEnabled
            loadFailed = false; settings = imported; save(); refreshDevices()
        } catch { message = error.localizedDescription }
    }
    func exportSettings() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "ProTypeUltra-profiles.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ProfileStore.save(settings, to: url) } catch { message = error.localizedDescription }
    }
    func exportDiagnostics(setup: [SetupItem]) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "ProTypeUltra-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let checklist = setup.map { "\($0.done ? "[x]" : "[ ]") \($0.title): \($0.detail)" }.joined(separator: "\n")
        let report = """
        ProTypeUltra \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (helper protocol \(helperProtocolVersion))
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        App location: \(Bundle.main.bundlePath)
        Helper: \(helperStatus) (version \(helper?.helperVersion ?? "none"))
        Devices: \(devices.map(\.label).joined(separator: ", "))
        Selected: \(settings.selectedDevice ?? "automatic") → \(deviceLabel)
        Hardware: \(snapshot.readings)
        Errors: \(snapshot.errors)
        Setup:
        \(checklist)
        No keystrokes, macros, or profile contents are included.
        """
        do { try report.write(to: url, atomically: true, encoding: .utf8) } catch { message = error.localizedDescription }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { message = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
