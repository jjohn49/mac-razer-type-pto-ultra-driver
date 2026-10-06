# Validation record

Date: 2026-10-02. Machine: Apple Silicon, macOS 27.0, Xcode 27.0.

## Verified on this keyboard

USB VID/PID: `1532:0277`. Three HID interfaces, including a 90-byte feature report.

- The production transport's asynchronous IOKit queries return firmware 1.0,
  normal mode, raw brightness 6, raw battery 0, charging true, idle timeout 900 s.
- All six responses passed packet length, command/transaction, checksum, and status
  checks. Original response fixtures are under `Tests/KeyboardCoreTests/Fixtures/`.
- Brightness round trip: raw 6 → 5 → 6. Both readbacks matched, original restored.
- Sixteen initial core tests passed. Check `make test` for the current test count.
- The C++ virtual-HID bridge compiled against the pinned headers.
- `make build` completed for the release app, CLI, helper, and output bridge.
- The release app passed `codesign --verify --deep --strict`.
- The upstream 8.6.0 package passed Apple signature and notarization validation.

## Hardware acceptance matrix

| Capability | USB | Dongle | Bluetooth |
| --- | --- | --- | --- |
| Enumeration | Verified | Implemented, untested | Discovery implemented, untested |
| Firmware/mode/brightness queries | Verified | Implemented, untested | No verified control transport |
| Charging / idle queries | Verified | Implemented, untested | No verified control transport |
| Battery percentage | Unvalidated raw value only | Unvalidated | Unvalidated |
| Brightness write/readback | Verified and restored | Untested | Unavailable until verified |
| Off/static/breathing white effects | Static verified (restored after probes); breathing pending | Untested | Unavailable until verified |
| Firmware wave (0x0F/02 effect 4) | Accepted but backlight goes dark: not rendered | — | — |
| Per-key custom frame (0x0F/03 and legacy 0x03/0B) | Refused, status 0x05 not supported | — | — |
| Helper-driven brightness animations (reactive, candle) | Implemented; visual check pending | Pending | Unavailable (no control transport) |
| Hardware reads/writes proxied through the helper during capture | Verified 2026-10-02 (`protype probe` via helper, 0.6 s for six commands) | Pending | — |
| Idle-time write | Implemented, readback check pending | Untested | Unavailable until verified |
| Remapping / virtual output | OS approvals + physical tests pending (see below) | Pending | Pending |
| In-app setup end to end (pkg, extension, Login Items, Accessibility) | Verified 2026-10-02 (see notes) | — | — |
| Service captures the keyboard, app running | Verified 2026-10-02 (status "Active on Pro Type Ultra — USB", passthrough typing) | Pending | Pending |
| Service captures with app quit / after reboot | Pending physical test | Pending | Pending |
| Lighting write during active remapping | Pending physical test | Pending | Pending |
| Emergency stop persists across service restart | Pending physical test | Pending | Pending |
| In-app setup (pkg, extension, Login Items, TCC) | Pending (needs interactive approvals) | — | — |
| Independent Fn / Fn-lock | Input investigation pending | Pending | Pending |
| Persistence after reconnect | Pending | Pending | Pending |

## 2026-10-02 rework (0.2.0): what was verified without hardware approvals

- `make test`: 22 tests pass, including the new helper protocol, pending-action
  expiry, tolerant settings decoding, automatic device preference, and
  control-interface classification.
- `make build` assembles a self-contained `ProTypeUltra.app` (helper, output bridge,
  CLI, two launchd plists, pinned 8.6.0 package); `codesign --verify --deep --strict`
  passes; both plists pass `plutil -lint`.
- The built app launches from the build folder and stays running against the
  legacy 0.1 helper (protocol mismatch is reported in the status line, not a crash).
- `ProTypeUltra --unregister` exits 0; `protype-helper` refuses to run as non-root;
  the bundled `protype list` enumerates the keyboard.
- Interface layout confirmed with `ioreg`: interfaces 0 and 1 carry keyboard,
  consumer, and system-control usages; interface 2 (mouse/pointer usages, 90-byte
  vendor feature report) is the control interface and is no longer seized.
- Later the same evening, interactively: SMAppService registered both daemons from
  `/Applications` and the user approved them in Login Items; the Driver Extension was
  approved under Login Items & Extensions → Driver Extensions; the helper captured
  the keyboard once it was allowed. Findings that changed the design:
  - launchd refused to spawn the helper via `BundleProgram` once it lived in a
    nested `.app` (exit 78 EX_CONFIG); an absolute `ProgramArguments` path to
    `/Applications/ProTypeUltra.app/...` works, as in the upstream example.
  - launchd also refuses to spawn a re-signed binary (EX_CONFIG) until the service is
    re-registered; the app's **Restart service** button does that.
  - On this macOS (27.0) daemons never appeared under Input Monitoring and could not
    be added there. Packaging the helper as `ProTypeUltraHelper.app` and requesting
    **Accessibility** (as Karabiner-Elements 16 does) made it listable; the
    Accessibility grant alone let `IOHIDDeviceOpen(seize)` succeed.
  - Ad-hoc signatures invalidate every privacy grant on rebuild; the build now uses
    the Apple Development identity found in the keychain.
  - Peer verification: the team-signed CLI is accepted (`protype enable` applied);
    a byte-identical copy re-signed ad-hoc is refused with "Only the signed Pro Type
    Ultra app or CLI can control the helper" while its status query still works.

## 2026-10-05/06 fixes (found while adding Linux support)

- Receiver through the helper: requests chose the wired transaction (0x1F) because
  the receiver's label also says USB; it refuses that with status 0x04. The product
  ID now decides. Verified 2026-10-05: `protype probe` through the installed helper
  returns readings with only the receiver connected.
- Idle CPU (was about 15% of a core all the time): the helper's 5 ms timer now runs
  only while a macro plays; the app republishes the helper's reply only when it
  changes; Setup runs `pkgutil` and `systemextensionsctl` at most once a minute once
  the driver is active. Measured 2026-10-06: about 0.3% idle, about 3% while typing
  with reactive lighting.
- Reactive lighting faded about a second into holding a key; it now stays up while
  any key is held and fades from the release. Checked by hand 2026-10-06.
- `make install` restarts the background service if it is running, so an update
  takes effect without Setup → Restart service.

## Manual acceptance recipe

1. Close other remappers. Run `make install`, complete every row of the app's Setup
   checklist, and leave remapping off.
2. Map A → B. Enable remapping. In a blank text document press/release A once:
   exactly one B must appear. Hold/release Shift+A and check no stuck modifier.
3. Hold physical Shift, trigger a macro that also holds/releases Shift, then release
   the macro. Physical Shift must remain effective until you release it.
4. Test the alternate layer; release its trigger before the mapped key and verify
   the mapped output still receives its release.
5. Exercise once, counted, hold, and toggle macros. Switch profiles mid-macro and
   confirm every generated key releases. Use emergency stop during a toggle macro.
6. Quit the app: remapping must continue. Then, in separate tests, terminate the
   helper (`sudo launchctl kickstart -k system/local.protypeultra.helper`), stop the
   upstream virtual-HID service, and unplug the keyboard. Confirm ordinary keyboard
   access returns and the built-in keyboard is unaffected. Reboot with remapping on
   and confirm A → B works at the login window and after login without opening the app.
6a. With remapping active, open Lighting & Power and apply a brightness change.
   Remapping must stay active and the readback must match.
6b. Press Control + Option + Escape on the Razer. Typing must return to normal, the
   app must show remapping off, and `sudo launchctl kickstart -k
   system/local.protypeultra.helper` must not recapture until remapping is turned on.
7. Reconnect, sleep/wake, and test secure-input contexts. Record limitations rather
   than treating synthetic-event acceptance as universal.
8. Test Fn alone, F1, Fn+F1, Fn+Esc using `protype watch 15`. This explicit diagnostic
   prints usages; do not type private information during its capture window.
9. Test brightness/effects visibly and inspect idle readback. Restore original
   values, then repeat after reconnect to determine persistence.
10. Repeat with only the dongle connected, then Bluetooth. Finally connect cable
    and receiver simultaneously and confirm selection prevents duplicate input.

No physical test is marked passed merely because a simulated test passed.
