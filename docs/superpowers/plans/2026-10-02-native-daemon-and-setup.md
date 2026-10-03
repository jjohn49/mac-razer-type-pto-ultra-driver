# Native Daemon Ownership and In-App Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make remapping work without the app open (daemon owns the configuration), move installation into the app through standard macOS dialogs, and let lighting controls run while remapping is active.

**Architecture:** The root daemon persists a `HelperConfiguration` and captures the keyboard on its own; the app pushes configuration and polls a short-lived "session" for per-app switching and user actions. The app bundle carries the helper, the output bridge, both launchd plists, and the pinned Karabiner package; `SMAppService` registers the daemons. The 90-byte control interface is never seized.

**Tech Stack:** Swift 5.9 (SwiftPM + XcodeGen), SwiftUI, ServiceManagement, IOKit HID, C++ bridge to Karabiner-DriverKit-VirtualHIDDevice 8.6.0, bash.

**Spec:** `docs/superpowers/specs/2026-10-02-native-daemon-and-setup-design.md`

## Global Constraints

- Apple Silicon, macOS 15 deployment target (raised from 14 for `defaultLaunchBehavior`), Xcode 27, ad-hoc signing by default (`SIGN_IDENTITY ?= -`).
- Karabiner package pinned: `Karabiner-DriverKit-VirtualHIDDevice-8.6.0.pkg`, SHA-256 `ff8c7fdc5e25387c7805fc7509a0fa9cf98f69ba582704f717fddcae47424387`, client protocol 7.
- Daemon configuration lives at `/Library/Application Support/ProTypeUltra/configuration.json`, root, mode 0600.
- Socket path stays `/var/run/protype-ultra.sock`. Launchd labels stay `local.protypeultra.helper` and `local.protypeultra.virtualhid`.
- Never log keystrokes. Never seize the built-in keyboard. Physical acceptance tests are recorded, not assumed.
- `make test` must pass after every task; `make build` must pass from Task 6 onward.

---

## File structure

| Path | Responsibility |
| --- | --- |
| `Sources/KeyboardCore/HelperMessages.swift` | Protocol types: `HelperConfiguration`, `HelperRequest` (tagged), `HelperReply`, `PendingActions` |
| `Sources/KeyboardCore/Profiles.swift` | Adds `Settings.remappingEnabled`; tolerant decoding |
| `Sources/KeyboardHID/Devices.swift` | Adds `HIDDevices.preferred(_:override:)`, `HIDDevices.isInputInterface(usagePairs:)`, `usagePairs(_:)` |
| `Sources/ProTypeHelper/ConfigurationStore.swift` | Load/save of the daemon configuration file |
| `Sources/ProTypeHelper/InputService.swift` | Capture, engine, session, actions (moved out of `main.swift`) |
| `Sources/ProTypeHelper/main.swift` | Socket server, timers, signals |
| `Sources/ProTypeCLI/main.swift` | `helper-status`, `configure FILE`, `enable`, `disable` |
| `App/ProTypeUltraApp.swift` | Scenes, menu bar, activation policy, app delegate |
| `App/AppModel.swift` | Settings, daemon client (configure push + session poll), hardware |
| `App/SetupModel.swift` | Setup probes and actions |
| `App/Views/KeyboardView.swift`, `MacrosView.swift`, `ProfilesView.swift`, `LightingView.swift`, `SetupView.swift` | Pages, split from the single file |
| `scripts/launchd/local.protypeultra.helper.plist`, `scripts/launchd/local.protypeultra.virtualhid.plist` | Bundle-relative daemon plists |
| `scripts/assemble-app.sh` | Copies helpers, plists, pkg into the bundle; signs |
| `scripts/install.sh`, `scripts/uninstall.sh`, `Makefile`, `project.yml` | Build/install flow |
| `README.md`, `docs/VALIDATION.md` | Updated instructions and acceptance record |

---

### Task 1: Protocol types and pending-action queue

**Files:**
- Modify: `Sources/KeyboardCore/HelperMessages.swift` (rewrite)
- Modify: `Sources/KeyboardCore/Profiles.swift:92-109` (`Settings`)
- Test: `Tests/KeyboardCoreTests/HelperMessageTests.swift` (create)

**Interfaces:**
- Produces:
  - `struct HelperConfiguration: Codable, Equatable, Sendable { version: Int = 1; enabled: Bool; deviceID: String?; settings: Settings; func validate() throws }`
  - `struct HelperRequest: Codable, Sendable { kind: Kind; configuration: HelperConfiguration?; frontmostApplication: String?; recording: Bool }` with `enum Kind: String { status, configure, session }` and factories `.status`, `.configure(_:)`, `.session(frontmostApplication:recording:)`
  - `struct HelperReply: Codable, Sendable { status, capturing, virtualReady, enabled, captureDenied, deviceLabel: String?, activeProfileName, sessionConnected, helperVersion, actions, recorded }`
  - `struct PendingActions { mutating func append(_:now:); mutating func drain(now:) -> [UserAction]; var count }` with `lifetime = 2.0`, `limit = 64`
  - `Settings.remappingEnabled: Bool` (default false; absent key decodes as false)
  - `public let helperProtocolVersion = "2"`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import KeyboardCore

final class HelperMessageTests: XCTestCase {
    func testConfigurationRoundTrip() throws {
        var settings = Settings(); settings.remappingEnabled = true
        let configuration = HelperConfiguration(enabled: true, deviceID: "631:USB:1", settings: settings)
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(HelperConfiguration.self, from: data)
        XCTAssertEqual(decoded, configuration)
        XCTAssertNoThrow(try decoded.validate())
    }
    func testConfigurationRejectsUnknownVersion() throws {
        var configuration = HelperConfiguration(enabled: false, deviceID: nil, settings: Settings())
        configuration.version = 2
        XCTAssertThrowsError(try configuration.validate())
    }
    func testRequestKindsDecode() throws {
        for request in [HelperRequest.status, .configure(HelperConfiguration(enabled: true, deviceID: nil, settings: Settings())), .session(frontmostApplication: "com.apple.Safari", recording: true)] {
            let decoded = try JSONDecoder().decode(HelperRequest.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(decoded.kind, request.kind)
            XCTAssertEqual(decoded.frontmostApplication, request.frontmostApplication)
            XCTAssertEqual(decoded.recording, request.recording)
            XCTAssertEqual(decoded.configuration, request.configuration)
        }
    }
    func testSettingsWithoutRemappingKeyDecodesDisabled() throws {
        let json = #"{"version":1,"profiles":[{"id":"6B1A3C0E-0000-4000-8000-000000000001","name":"Default","applicationIDs":[],"bindings":[],"macros":[]}],"selectedProfile":"6B1A3C0E-0000-4000-8000-000000000001","automaticProfiles":true}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.remappingEnabled)
        XCTAssertNil(settings.selectedDevice)
    }
    func testPendingActionsExpireAndCap() {
        var queue = PendingActions()
        queue.append(UserAction(kind: .launch, value: "/Applications/Safari.app"), now: 0)
        queue.append(UserAction(kind: .text, value: "hi"), now: 1.5)
        XCTAssertEqual(queue.drain(now: 2.5).map(\.value), ["hi"])   // first expired (2 s lifetime)
        XCTAssertEqual(queue.count, 0)
        for i in 0..<100 { queue.append(UserAction(kind: .text, value: "\(i)"), now: 10) }
        XCTAssertEqual(queue.count, 64)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HelperMessageTests`
Expected: compile errors (`HelperConfiguration`, `PendingActions`, `remappingEnabled` undefined).

- [ ] **Step 3: Implement**

`Sources/KeyboardCore/HelperMessages.swift`:

```swift
import Foundation

public let helperProtocolVersion = "2"

/// Everything the daemon needs to run without the app.
public struct HelperConfiguration: Codable, Equatable, Sendable {
    public var version = 1
    public var enabled: Bool
    public var deviceID: String?
    public var settings: Settings
    public init(enabled: Bool, deviceID: String?, settings: Settings) { self.enabled = enabled; self.deviceID = deviceID; self.settings = settings }
    public func validate() throws {
        guard version == 1 else { throw ProfileError.invalid("Unsupported configuration version") }
        try settings.validate()
    }
}

public struct HelperRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case status, configure, session }
    public var kind: Kind
    public var configuration: HelperConfiguration?
    public var frontmostApplication: String?
    public var recording = false
    public init(kind: Kind, configuration: HelperConfiguration? = nil, frontmostApplication: String? = nil, recording: Bool = false) {
        self.kind = kind; self.configuration = configuration; self.frontmostApplication = frontmostApplication; self.recording = recording
    }
    public static let status = HelperRequest(kind: .status)
    public static func configure(_ configuration: HelperConfiguration) -> HelperRequest { .init(kind: .configure, configuration: configuration) }
    public static func session(frontmostApplication: String?, recording: Bool) -> HelperRequest { .init(kind: .session, frontmostApplication: frontmostApplication, recording: recording) }
}

public struct UserAction: Codable, Equatable, Sendable { /* unchanged */ }
public struct RecordedInput: Codable, Sendable { /* unchanged */ }

public struct HelperReply: Codable, Sendable {
    public var status: String
    public var capturing = false
    public var virtualReady = false
    public var enabled = false
    public var captureDenied = false
    public var deviceLabel: String?
    public var activeProfileName = ""
    public var sessionConnected = false
    public var helperVersion = helperProtocolVersion
    public var actions: [UserAction] = []
    public var recorded: [RecordedInput] = []
    public init(status: String) { self.status = status }
}

/// Launch/text actions wait for a user session to run them; stale ones are dropped.
public struct PendingActions: Sendable {
    private struct Entry { let action: UserAction; let time: Double }
    private var entries: [Entry] = []
    public var lifetime = 2.0
    public var limit = 64
    public init() {}
    public var count: Int { entries.count }
    public mutating func append(_ action: UserAction, now: Double) {
        entries.removeAll { now - $0.time > lifetime }
        guard entries.count < limit else { return }
        entries.append(Entry(action: action, time: now))
    }
    public mutating func drain(now: Double) -> [UserAction] {
        defer { entries.removeAll() }
        return entries.filter { now - $0.time <= lifetime }.map(\.action)
    }
    public mutating func expire(now: Double) { entries.removeAll { now - $0.time > lifetime } }
}
```

`Settings` in `Profiles.swift`: add `public var remappingEnabled = false` and a custom `init(from:)` using `decodeIfPresent` for `remappingEnabled`, `selectedDevice`, `automaticProfiles` (keep synthesized encoder).

- [ ] **Step 4: Run tests** — `swift test` — all pass (existing tests untouched).

---

### Task 2: Device preference and interface classification

**Files:**
- Modify: `Sources/KeyboardHID/Devices.swift`
- Test: `Tests/KeyboardHIDTests/DeviceSelectionTests.swift` (create)

**Interfaces:**
- Produces:
  - `HIDDevices.preferred(_ devices: [DeviceInfo], override: String?) -> DeviceInfo?`
  - `HIDDevices.isInputInterface(usagePairs: [(page: UInt32, usage: UInt32)]) -> Bool`
  - `HIDDevices.usagePairs(_ d: IOHIDDevice) -> [(page: UInt32, usage: UInt32)]`
  - `HIDDevices.inputInterfaces(for id: String) -> [IOHIDDevice]`

- [ ] **Step 1: Failing tests**

```swift
import XCTest
@testable import KeyboardHID

final class DeviceSelectionTests: XCTestCase {
    let usb = DeviceInfo(id: "631:USB:1", product: "Pro Type Ultra", productID: 0x277, transport: "USB", interfaces: 3, hasControlInterface: true)
    let dongle = DeviceInfo(id: "635:USB:2", product: "Pro Type Ultra", productID: 0x27B, transport: "USB", interfaces: 3, hasControlInterface: true)
    let bluetooth = DeviceInfo(id: "9:Bluetooth:x", product: "Pro Type Ultra", productID: 9, transport: "Bluetooth", interfaces: 1, hasControlInterface: false)
    func testPrefersWiredThenReceiverThenBluetooth() {
        XCTAssertEqual(HIDDevices.preferred([bluetooth, dongle, usb], override: nil)?.id, usb.id)
        XCTAssertEqual(HIDDevices.preferred([bluetooth, dongle], override: nil)?.id, dongle.id)
        XCTAssertEqual(HIDDevices.preferred([bluetooth], override: nil)?.id, bluetooth.id)
        XCTAssertNil(HIDDevices.preferred([], override: nil))
    }
    func testOverrideWinsWhenPresentAndFallsBackWhenAbsent() {
        XCTAssertEqual(HIDDevices.preferred([usb, dongle], override: dongle.id)?.id, dongle.id)
        XCTAssertEqual(HIDDevices.preferred([usb], override: "missing")?.id, usb.id)
    }
    func testControlInterfaceIsNotInput() {
        XCTAssertTrue(HIDDevices.isInputInterface(usagePairs: [(1, 6)]))
        XCTAssertTrue(HIDDevices.isInputInterface(usagePairs: [(1, 6), (12, 1), (1, 0x80), (1, 0)]))
        XCTAssertFalse(HIDDevices.isInputInterface(usagePairs: [(1, 2), (1, 1)]))   // interface 2 on this keyboard
        XCTAssertFalse(HIDDevices.isInputInterface(usagePairs: []))
    }
}
```

- [ ] **Step 2: Run** — compile failure.
- [ ] **Step 3: Implement** in `Devices.swift`:

```swift
public static func preferred(_ devices: [DeviceInfo], override: String?) -> DeviceInfo? {
    if let override, let chosen = devices.first(where: { $0.id == override }) { return chosen }
    func rank(_ d: DeviceInfo) -> Int { d.productID == 0x0277 ? 0 : d.productID == 0x027B ? 1 : 2 }
    return devices.sorted { (rank($0), $0.id) < (rank($1), $1.id) }.first
}
public static func isInputInterface(usagePairs: [(page: UInt32, usage: UInt32)]) -> Bool {
    usagePairs.contains { ($0.page == 1 && [6, 7, 0x80].contains($0.usage)) || ($0.page == 12 && $0.usage == 1) }
}
public static func usagePairs(_ d: IOHIDDevice) -> [(page: UInt32, usage: UInt32)] {
    let pairs = IOHIDDeviceGetProperty(d, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Int]] ?? []
    return pairs.compactMap { p in guard let page = p[kIOHIDDeviceUsagePageKey], let usage = p[kIOHIDDeviceUsageKey] else { return nil }; return (UInt32(page), UInt32(usage)) }
}
public static func inputInterfaces(for id: String) -> [IOHIDDevice] {
    enumerate().filter { identity($0) == id && isInputInterface(usagePairs: usagePairs($0)) }
}
```

- [ ] **Step 4: Run** `swift test` — pass.

---

### Task 3: Daemon configuration store

**Files:**
- Create: `Sources/ProTypeHelper/ConfigurationStore.swift`
- Test: none unit-level beyond `HelperConfiguration` round trip (file I/O is thin); verified by `protype configure` in Task 5.

**Interfaces:**
- Produces: `enum ConfigurationStore { static var url: URL; static func load() -> HelperConfiguration; static func save(_:) throws }`

- [ ] **Step 1: Implement**

```swift
import Foundation
import KeyboardCore

enum ConfigurationStore {
    static let directory = URL(fileURLWithPath: "/Library/Application Support/ProTypeUltra")
    static var url: URL { directory.appendingPathComponent("configuration.json") }
    /// Invalid or missing file means "disabled, automatic device"; it is rewritten on the next configure.
    static func load() -> HelperConfiguration {
        guard let data = try? Data(contentsOf: url), data.count <= 4_000_000,
              let configuration = try? JSONDecoder().decode(HelperConfiguration.self, from: data),
              (try? configuration.validate()) != nil else { return HelperConfiguration(enabled: false, deviceID: nil, settings: Settings()) }
        return configuration
    }
    static func save(_ configuration: HelperConfiguration) throws {
        try configuration.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
```

- [ ] **Step 2: Build** — `swift build` passes.

---

### Task 4: Daemon rewrite — daemon owns capture

**Files:**
- Create: `Sources/ProTypeHelper/InputService.swift` (moved + rewritten from `main.swift`)
- Modify: `Sources/ProTypeHelper/main.swift` (server loop only)

**Interfaces:**
- Consumes: Task 1 types, Task 2 `preferred`/`inputInterfaces`, Task 3 store.
- Produces: `InputService.handle(_ request: HelperRequest, uid: uid_t) throws -> HelperReply`, `tick()`, `shutdown()`.

Behaviour (from spec):
- `start()` loads configuration, spawns `protype-output` (same directory as the helper), calls `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`.
- `handle(.status)` → reply. `handle(.configure)` → validate, persist, `apply()`. `handle(.session)` → `sessionSeen = now`, `frontmostApplication`, `recording`; drains `pendingActions` and `recorded`.
- `desiredProfile = configuration.settings.activeProfile(applicationID: sessionAlive ? frontmostApplication : nil)`; when it differs from `engine.profile`, `emit(engine.setProfile(_))`.
- `tick()` every 5 ms while capturing, 100 ms idle: expire session (2.5 s) → clear recording/frontmost; `guard configuration.enabled, !emergency else { stop if capturing; return }`; `guard ready else { stop("Virtual output unavailable") }`; discover every 1 s (5 s after denial): `preferred(HIDDevices.list(), override: configuration.deviceID)` → `inputInterfaces(for:)` → seize each; on `kIOReturnNotPermitted` set `captureDenied = true`, call `IOHIDRequestAccess` again; on success `captureDenied = false`, `deviceLabel = info.label`.
- Emergency chord: `emergency = true; configuration.enabled = false; try? ConfigurationStore.save(configuration); stop("Emergency stop. Turn remapping on again in the app.")`. `configure` with `enabled == true` clears `emergency`.
- Pointer passthrough branch is deleted (control interface is not seized).
- `stop(_:)` and `emit` as today. Reply builder fills every new field.

- [ ] **Step 1: Write `InputService.swift`** with the above (full code is the moved `InputService` class with the new fields: `configuration`, `frontmostApplication`, `sessionSeen`, `sessionUID`, `captureDenied`, `deviceLabel`, `pendingActions: PendingActions`, `lastDiscovery`).
- [ ] **Step 2: Rewrite `main.swift`**: identical socket server, but the per-request block becomes

```swift
result = Result {
    switch request.kind {
    case .status: return service.reply()
    case .configure, .session:
        guard peerUID == InputService.consoleUID() else { throw RazerError.unavailable("Only the logged-in user can control the helper") }
        return try service.handle(request, uid: peerUID)
    }
}
```

No owner/connection UUID; no `disconnected()` on close (the session simply expires).

- [ ] **Step 3: Build** `swift build -c release`; run `make test`.

---

### Task 5: CLI updates

**Files:**
- Modify: `Sources/ProTypeCLI/main.swift`

- [ ] **Step 1:** `helper-status` sends `.status`. Add:

```swift
case "configure":
    guard arguments.count == 2 else { throw RazerError.invalidRequest }
    let settings = try ProfileStore.decode(Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    try printJSON(HelperClient().exchange(.configure(HelperConfiguration(enabled: settings.remappingEnabled, deviceID: settings.selectedDevice, settings: settings))))
case "enable", "disable":
    let client = HelperClient()
    var settings = try ProfileStore.load(); settings.remappingEnabled = arguments[0] == "enable"
    try ProfileStore.save(settings)
    try printJSON(client.exchange(.configure(HelperConfiguration(enabled: settings.remappingEnabled, deviceID: settings.selectedDevice, settings: settings))))
```

Update the help text. Build.

---

### Task 6: Bundle layout, plists, assemble script, Makefile, install scripts

**Files:**
- Create: `scripts/launchd/local.protypeultra.helper.plist`, `scripts/launchd/local.protypeultra.virtualhid.plist`, `scripts/assemble-app.sh`
- Modify: `Makefile`, `project.yml`, `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/install-helper.sh` (delete), `.gitignore` (unchanged)

- [ ] **Step 1: Plists**

`local.protypeultra.helper.plist`:
```xml
<dict>
  <key>Label</key><string>local.protypeultra.helper</string>
  <key>BundleProgram</key><string>Contents/Library/Helpers/protype-helper</string>
  <key>AssociatedBundleIdentifiers</key><array><string>local.protypeultra.app</string></array>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardErrorPath</key><string>/var/log/protype-ultra.log</string>
</dict>
```
`local.protypeultra.virtualhid.plist`: as today but with `AssociatedBundleIdentifiers` added (absolute `ProgramArguments` kept, as in the upstream SMAppService example).

- [ ] **Step 2: `scripts/assemble-app.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/DerivedData/Build/Products/Release/ProTypeUltra.app"
identity="${SIGN_IDENTITY:--}"
helpers="$app/Contents/Library/Helpers"; daemons="$app/Contents/Library/LaunchDaemons"
mkdir -p "$helpers" "$daemons" "$app/Contents/Resources"
install -m 755 .build/release/protype-helper .build/release/protype build/protype-output "$helpers/"
install -m 644 scripts/launchd/*.plist "$daemons/"
install -m 644 .deps/virtualhid/dist/Karabiner-DriverKit-VirtualHIDDevice-8.6.0.pkg "$app/Contents/Resources/"
plutil -lint "$daemons"/*.plist
codesign --force --sign "$identity" --identifier local.protypeultra.helper "$helpers/protype-helper"
codesign --force --sign "$identity" --identifier local.protypeultra.output "$helpers/protype-output"
codesign --force --sign "$identity" --identifier local.protypeultra.cli "$helpers/protype"
codesign --force --sign "$identity" --options runtime "$app"
codesign --verify --deep --strict "$app"
```

- [ ] **Step 3: Makefile**: `build: cli bridge app`; `app:` runs xcodegen, xcodebuild, then `bash scripts/assemble-app.sh`; `install: build` → `bash scripts/install.sh` (no sudo); `uninstall:` → `sudo bash scripts/uninstall.sh`; export `SIGN_IDENTITY`.
- [ ] **Step 4: `scripts/install.sh`**: verify pkg hash, `rm -rf /Applications/ProTypeUltra.app`, `ditto` the built app there, `open /Applications/ProTypeUltra.app`, print "Finish setup in the app window".
- [ ] **Step 5: `scripts/uninstall.sh`** (sudo): `/Applications/ProTypeUltra.app/Contents/MacOS/ProTypeUltra --unregister || true`; bootout both labels; remove legacy `/Library/LaunchDaemons/local.protypeultra.*.plist`, `/Library/Application Support/ProTypeUltra`, the app, the socket. Delete `scripts/install-helper.sh`.
- [ ] **Step 6: `project.yml`**: deployment target `15.0`; add `- sdk: ServiceManagement.framework`; `INFOPLIST_KEY_NSAccessibilityUsageDescription`? (not a macOS key — skip); `MARKETING_VERSION: '0.2.0'`.
- [ ] **Step 7:** `make build` passes; `codesign --verify --deep --strict` passes; `ls` the bundle shows the layout from the spec.

---

### Task 7: AppModel — configure push and session poll

**Files:**
- Modify: `App/AppModel.swift`

**Interfaces:**
- Produces: `AppModel.helper: HelperReply?`, `AppModel.pushConfiguration()`, `AppModel.enabled` is now a computed binding over `settings.remappingEnabled`, `AppModel.deviceLabel`, `AppModel.setLaunchAtLogin(_:)`, `AppModel.launchAtLogin: Bool`.

- [ ] **Step 1:** Replace `heartbeat()` with `pollSession()` every 0.5 s sending `.session(frontmostApplication:recording:)`; on reply store `helper = reply`, run actions, collect recordings, and if `reply.enabled != settings.remappingEnabled` (daemon emergency stop) set `settings.remappingEnabled = reply.enabled` without re-pushing.
- [ ] **Step 2:** `save()` also schedules `pushConfiguration()` (200 ms debounce via `DispatchWorkItem`). `pushConfiguration()` sends `.configure(HelperConfiguration(enabled: settings.remappingEnabled, deviceID: settings.selectedDevice, settings: settings))`.
- [ ] **Step 3:** `init`: after loading settings, `initialSync()`: send `.status`; if it succeeds adopt `reply.enabled`; then push.
- [ ] **Step 4:** `readHardware()`/`apply(_:)` no longer disable remapping or send a pause. Keep `busy`.
- [ ] **Step 5:** `refreshDevices()` no longer auto-sets `selectedDevice`; add `var automaticDevice: DeviceInfo? { HIDDevices.preferred(devices, override: settings.selectedDevice) }`. Observe `NSWorkspace.didWakeNotification`/HID hot-plug by refreshing devices in the poll when `helper?.deviceLabel` changes.
- [ ] **Step 6:** Build via `make app`.

---

### Task 8: SetupModel — probes and actions

**Files:**
- Create: `App/SetupModel.swift`

**Interfaces:**
- Produces: `@MainActor final class SetupModel: ObservableObject { @Published var items: [SetupItem]; @Published var summary: String; func refresh(helper: HelperReply?) ; func moveToApplications(); func installPackage(); func activateExtension(); func registerDaemons(); func openLoginItems(); func openInputMonitoring(); func requestAccessibility(); func removeLegacy() }`
- `struct SetupItem: Identifiable { id: String; title: String; detail: String; done: Bool; actionTitle: String?; action: (() -> Void)? }`
- `enum Daemons { static let helper = SMAppService.daemon(plistName: "local.protypeultra.helper.plist"); static let virtualHID = SMAppService.daemon(plistName: "local.protypeultra.virtualhid.plist"); static func unregisterAll() }`

- [ ] **Step 1:** Probes run in `Task.detached` and publish on main:
  - `inApplications = Bundle.main.bundleURL.path.hasPrefix("/Applications/")`
  - `packageVersion` = parse `version:` line from `/usr/sbin/pkgutil --pkg-info org.pqrs.Karabiner-DriverKit-VirtualHIDDevice`
  - `extensionState` = line containing `org.pqrs.Karabiner-DriverKit-VirtualHIDDevice` in `/usr/bin/systemextensionsctl list`; `[activated enabled]` → done
  - `daemonStatus` = both `SMAppService.status`
  - `inputMonitoring = HIDDevices.permissionGranted()`; `accessibility = AXIsProcessTrusted()`
  - `helperAllowed = helper != nil && !helper.captureDenied` (with detail "Not checked yet" until the daemon has tried)
  - `legacy = FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/local.protypeultra.helper.plist")`
- [ ] **Step 2:** Actions:
  - `installPackage`: `NSWorkspace.shared.open(Bundle.main.url(forResource: "Karabiner-DriverKit-VirtualHIDDevice-8.6.0", withExtension: "pkg")!)`
  - `activateExtension`: run `/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager activate`, then `openExtensions()` = open `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`
  - `registerDaemons`: for each service: if `.notFound` try unregister; `try register()`; if any `.requiresApproval` → `SMAppService.openSystemSettingsLoginItems()`
  - `removeLegacy`: `NSAppleScript` `do shell script "launchctl bootout system/local.protypeultra.helper; launchctl bootout system/local.protypeultra.virtualhid; rm -f /Library/LaunchDaemons/local.protypeultra.helper.plist /Library/LaunchDaemons/local.protypeultra.virtualhid.plist; rm -f '/Library/Application Support/ProTypeUltra/protype-helper' '/Library/Application Support/ProTypeUltra/protype-output' '/Library/Application Support/ProTypeUltra/protype'" with administrator privileges`
  - `moveToApplications`: copy bundle to `/Applications/ProTypeUltra.app` (replace), `NSWorkspace.shared.openApplication(at:)`, then `NSApp.terminate`.
- [ ] **Step 3:** `summary`: first undone item's title, or "Ready — remapping active on <deviceLabel>" / "Ready — remapping is off".
- [ ] **Step 4:** Build.

---

### Task 9: Views split and Setup checklist UI

**Files:**
- Create: `App/Views/KeyboardView.swift`, `MacrosView.swift`, `ProfilesView.swift`, `LightingView.swift`, `SetupView.swift`
- Modify: `App/ProTypeUltraApp.swift` (remove moved views)

- [ ] **Step 1:** Move `KeyboardView`, `BindingEditor`, `KeyPicker`, `MacrosView`, `ProfilesView`, `LightingView` unchanged into their files.
- [ ] **Step 2:** `LightingView`: `.task { model.readHardware() }` on appear; remove the "pauses remapping" caption; replace with "Changes are written to the keyboard immediately and do not interrupt remapping."
- [ ] **Step 3:** `SetupView`: `List(setup.items)` rows with `Image(systemName: done ? "checkmark.circle.fill" : "exclamationmark.circle")`, title, detail, trailing `Button(actionTitle)`; a "Refresh" button; `Toggle("Launch at login")`; `Button("Export diagnostics")`; recovery caption. `.task { setup.refresh(helper: model.helper) }` and `.onReceive(model.$helper)`.
- [ ] **Step 4:** `MainView`: sidebar footer shows `setup.summary`, `Toggle("Remapping", isOn: $model.settings.remappingEnabled)`, device line `model.helper?.deviceLabel ?? model.automaticDevice?.label ?? "No keyboard connected"`. Device picker moves into a `DisclosureGroup("Advanced")` on the Setup page with "Automatic" as the nil tag. Profile picker stays in the detail header.
- [ ] **Step 5:** Build.

---

### Task 10: Scenes, menu bar, launch-at-login behaviour, `--unregister`

**Files:**
- Modify: `App/ProTypeUltraApp.swift`

- [ ] **Step 1:** `AppDelegate: NSObject, NSApplicationDelegate`:
  - `applicationWillFinishLaunching`: handle `--unregister` (call `Daemons.unregisterAll()`, `exit(0)`); detect login-item launch via `NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == keyAELaunchedAsLogInItem` → `LaunchContext.launchedAtLogin = true`, `NSApp.setActivationPolicy(.accessory)`.
  - `applicationShouldHandleReopen`: show window (`.regular`).
- [ ] **Step 2:** Scenes: `Window("Pro Type Ultra", id: "main") { MainView() }.defaultLaunchBehavior(LaunchContext.launchedAtLogin ? .suppressed : .presented)`; `MenuBarExtra` with status line, `Toggle("Remapping")`, profile `Picker`, battery/charging line if `model.snapshot.readings["Charging"]` exists, "Settings…" (`openWindow(id:"main")`, `.regular`, activate), "Quit (remapping keeps running)".
- [ ] **Step 3:** On main window close (`NSWindow.willCloseNotification` for the main window): if `SMAppService.mainApp.status == .enabled` → `.accessory`.
- [ ] **Step 4:** Build; `open build/.../ProTypeUltra.app` and confirm the window shows; `open -a ProTypeUltra --args --unregister` exits 0.

---

### Task 11: Docs and validation record

**Files:**
- Modify: `README.md`, `docs/VALIDATION.md`, `PLAN.md` (append a "Status after 2026-10-02 rework" section), `THIRD_PARTY.md` (note the pkg is now bundled in the app)

- [ ] **Step 1:** README "Install" becomes: `make install`, then follow the Setup checklist (Installer → extension approval → Login Items approval → Input Monitoring for app and helper). Remove `launchctl kickstart`, path-pasting, and "app must remain running" statements. Document `protype enable|disable|configure`.
- [ ] **Step 2:** VALIDATION: add rows "Daemon captures with app quit", "Survives reboot", "Lighting write during remapping", "Emergency stop persists", "SMAppService registration (ad-hoc)" — all "Pending physical test" with the exact steps.
- [ ] **Step 3:** Run `make test` and `make build` one final time; `codesign --verify --deep --strict`.

---

## Self-review

- Spec coverage: daemon ownership (T3, T4), auto device + unseized control interface (T2, T4), protocol (T1), bundle + SMAppService (T6, T8), checklist (T8, T9), app behaviour/menu bar (T10), lighting without pause (T7, T9), CLI (T5), docs (T11). Emergency persistence (T4). Action expiry (T1, T4).
- Types: `HelperConfiguration(enabled:deviceID:settings:)` used identically in T4, T5, T7. `HIDDevices.preferred(_:override:)` used in T4, T7. `HelperReply.captureDenied`/`deviceLabel` used in T8/T9.
