# Native daemon ownership and in-app setup — design

Date: 2026-10-02. Status: approved by assumption (autonomous session); decisions are
listed so they can be reversed individually.

## Problem

The current build works only as "an app that drives a helper":

- The root helper (`protype-helper`) captures the keyboard only while the app sends
  a heartbeat every 250 ms carrying the whole profile. Quit the app and the keyboard
  is released within 2.5 s. Nothing survives logout or reboot.
- Installation is `make install` with `sudo`, manual approval of a system extension,
  adding the helper to Input Monitoring by pasting a path, and `launchctl kickstart`.
  On the development Mac the Karabiner driver extension is still "activated waiting
  for user", so remapping has never actually been active.
- Reading or writing lighting/idle settings pauses remapping because the helper
  seizes all three USB HID interfaces, including the control interface.
- The user must pick the keyboard in a picker before anything works.

## Goals

1. Remapping, layers, and macros work whenever the keyboard is plugged in, with the
   app closed, after reboot, and before login.
2. Setup happens inside the app through standard macOS dialogs: Installer.app for the
   pinned Karabiner package, Login Items for the background service, System Settings
   for Input Monitoring. No Terminal, no `sudo`.
3. Lighting and power controls work while remapping is active.
4. The keyboard is selected automatically; the app shows one status line that says
   what is or is not working and offers a Fix button for each missing piece.

Non-goals: Bluetooth control transport, firmware, cloud, public distribution,
Developer ID signing. These remain as in PLAN.md.

## Architecture

```
┌──────────────────────────────┐    unix socket     ┌──────────────────────────────┐
│ ProTypeUltra.app (user)      │ ─────────────────► │ protype-helper (root daemon)  │
│  • settings UI               │  configure/status  │  • owns configuration.json    │
│  • menu bar status           │  session (poll)    │  • captures keyboard inputs   │
│  • frontmost app → daemon    │ ◄───────────────── │  • MappingEngine + macros     │
│  • runs launch/text actions  │  actions/recorded  │  • spawns protype-output      │
│  • lighting via control intf │                    └──────────────┬───────────────┘
│  • SMAppService registration │                                   │ stdin/stdout
└──────────────────────────────┘                    ┌──────────────▼───────────────┐
                                                    │ protype-output (root, C++)    │
                                                    │  Karabiner virtual-HID client │
                                                    └──────────────────────────────┘
```

### Daemon owns the configuration

- New `HelperConfiguration { version, enabled, deviceID?, settings }` in
  `KeyboardCore`. The daemon persists it at
  `/Library/Application Support/ProTypeUltra/configuration.json` (root, mode 0600)
  whenever the app sends `configure`. On start the daemon loads it and, if `enabled`,
  captures as soon as virtual output is ready and the keyboard is present.
- Capture no longer depends on an app heartbeat. The app's connection only adds the
  "session" features below.
- Device selection: `deviceID == nil` means automatic. Automatic prefers the wired
  keyboard (product `0x0277`), then the receiver (`0x027B`), then Bluetooth, and
  captures exactly one physical device.
- Only input-producing interfaces are seized. The interface advertising
  `MaxFeatureReportSize == 90` (a mouse-class control interface with no keyboard
  usages) is left open for the app and CLI, so lighting works during remapping.
- Emergency stop (Control+Option+Escape on the Razer) now also writes
  `enabled = false` into the persisted configuration, so the keyboard stays released
  across daemon restarts until the user turns remapping back on in the app.
- The daemon calls `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` at startup and
  after a `kIOReturnNotPermitted` capture failure so it appears in the Input
  Monitoring list without the user adding it by path. It reports `captureDenied`
  in every status reply.

### App ↔ daemon protocol

`HelperRequest` becomes a tagged message:

| kind | payload | effect |
| --- | --- | --- |
| `status` | none | reply only |
| `configure` | `HelperConfiguration` | validate, persist, apply (stop/recapture as needed) |
| `session` | `frontmostApplicationID?`, `recording: Bool` | marks a user session alive for 2.5 s; selects the per-application profile; drains queued actions and recorded input |

`HelperReply` gains `enabled`, `captureDenied`, `deviceLabel`, `activeProfileName`,
`sessionConnected`, `helperVersion`. Existing `status`, `capturing`, `virtualReady`,
`actions`, `recorded` remain.

Rules: `configure` and `session` are accepted only from the console user. Queued
user actions (launch/text) expire after 2 s if no session drains them. When the
session expires, the daemon falls back to the selected profile and stops recording.

### App bundle carries everything; SMAppService registers the daemons

`make app` now produces a self-contained bundle:

```
ProTypeUltra.app/Contents/
  MacOS/ProTypeUltra
  Library/LaunchDaemons/local.protypeultra.helper.plist        (BundleProgram)
  Library/LaunchDaemons/local.protypeultra.virtualhid.plist    (absolute ProgramArguments, upstream daemon)
  Library/Helpers/protype-helper, protype-output, protype
  Resources/Karabiner-DriverKit-VirtualHIDDevice-8.6.0.pkg
```

`scripts/assemble-app.sh` copies the SwiftPM and clang outputs in, writes the plists,
and signs nested binaries then the app (identity from `SIGN_IDENTITY`, default `-`).
`make install` copies the app to `/Applications` without `sudo` (admin-writable) and
opens it. The upstream example in the pinned dependency uses exactly this layout with
ad-hoc signing, so this is known to work for a daemon with an absolute program path.

### Setup page becomes a checklist

Each row shows a live status and a single action:

1. App is in `/Applications` — "Move to Applications" (copies and relaunches).
2. Virtual keyboard driver package installed (`pkgutil --pkg-info
   org.pqrs.Karabiner-DriverKit-VirtualHIDDevice` is 8.6.0) — "Install…" opens the
   bundled `.pkg` in Installer.app.
3. Driver extension approved (`systemextensionsctl list` shows
   `org.pqrs.Karabiner-DriverKit-VirtualHIDDevice` `[activated enabled]`) —
   "Activate" runs the Manager's `activate`, then "Open Extensions settings".
4. Background service registered and approved (`SMAppService.daemon(...).status ==
   .enabled` for both plists) — "Register", then "Open Login Items settings".
5. Input Monitoring for the app (`IOHIDCheckAccess`) — "Request" / "Open settings".
6. Input Monitoring for the helper (daemon reports `captureDenied == false` once it
   has tried) — "Open settings".
7. Accessibility, optional, for text insertion — "Request".
8. Launch at login (toggle, `SMAppService.mainApp`), recommended on.
9. Legacy install present (`/Library/LaunchDaemons/local.protypeultra.helper.plist`
   exists outside the bundle) — "Remove old installation" via an administrator
   prompt (`osascript … with administrator privileges`).

A summary line at the top: "Ready — remapping active on Pro Type Ultra (USB)" or
the first unmet step.

### App behaviour

- Launched as a login item: menu bar only (accessory activation policy). Launched
  by the user: regular app with the window. "Show settings" from the menu bar
  switches to regular; closing the last window returns to accessory when launch at
  login is enabled.
- Menu bar: status, remapping toggle, profile picker, charging/battery line when
  known, Settings, Quit. Quitting the app no longer stops remapping; the menu says so.
- Keyboard picker is replaced by an automatic status; an "Advanced" disclosure keeps
  the manual override.
- Lighting & Power reads automatically when the page appears and when the keyboard
  connects; writes remain explicit (Apply buttons) but no longer pause remapping.
- Saving settings sends `configure` immediately (debounced 200 ms) and the heartbeat
  becomes a 500 ms `session` poll.

### CLI

`protype helper-status` prints the richer reply. New `protype configure FILE`
pushes a settings JSON for scripting, and `protype enable|disable` toggles remapping.
Hardware commands are unchanged and now work while remapping is active.

## Error handling

- Daemon: a missing or invalid `configuration.json` means "disabled, automatic
  device"; the file is rewritten on the next `configure`. Virtual output loss or
  device removal releases everything, as today. Capture denied is reported, retried
  every 5 s, and never spins.
- App: every Setup probe runs off the main thread and tolerates missing tools. A
  daemon that does not answer shows "Background service not running" with the
  Login Items button rather than a generic socket error.

## Testing

- `KeyboardCoreTests`: configuration round-trip, protocol message decoding of every
  kind, automatic device preference ordering (pure function over `DeviceInfo`),
  action expiry.
- `KeyboardHIDTests`: interface classification (`isInputInterface`) from usage pairs
  and feature-report size, using recorded property dictionaries from this keyboard.
- Build: `make build` produces the assembled bundle; `codesign --verify --deep
  --strict` passes; `plutil -lint` on both plists.
- Physical acceptance (recorded in `docs/VALIDATION.md`, must be run by a person
  because they need System Settings approvals): daemon registered and approved;
  extension approved; A→B works with the app quit; survives reboot; lighting write
  during remapping; emergency stop persists; legacy removal.

## Decisions taken without asking

| Decision | Alternative rejected | Why |
| --- | --- | --- |
| Daemon persists config, captures without app | Keep app heartbeat | Core of "native support" |
| Lighting stays in the app over the unseized control interface | Route through daemon | Keeps hardware controls working with no daemon installed; smaller change |
| Both daemons registered via SMAppService | Helper spawns upstream daemon | Matches upstream guidance; one Login Items approval covers both |
| Dock app that becomes menu-bar-only when launched at login | Always menu-bar-only | Keeps discoverability for first-run setup |
| Pkg opened in Installer.app | `installer` via admin prompt | Native dialog, shows the upstream signature |
