# Pro Type Ultra for macOS

A native settings app, background service, and hardware CLI for the Razer Pro Type
Ultra. Built for Apple Silicon; developed on macOS 27 with Xcode 27. This is
independent software, not an official Razer driver. See [PLAN.md](PLAN.md) for the
build recipe and [docs/VALIDATION.md](docs/VALIDATION.md) for what has been tested.

Remapping, layers, and macros run in a background service that owns the keyboard
whenever it is plugged in: with the app closed, after logout, and after a reboot.
The app is where you configure things; it does not have to stay open.

## Build

Install Xcode and its command-line tools, XcodeGen, CMake, and ripgrep. For an
existing Homebrew installation: `brew install xcodegen cmake ripgrep`.

```sh
make test
make build
```

The first bridge build downloads the pinned Karabiner virtual-HID sources. `make
build` produces one self-contained bundle at
`build/DerivedData/Build/Products/Release/ProTypeUltra.app` containing the app,
the background helper, the virtual-output bridge, the `protype` CLI, both launchd
property lists, and the pinned virtual-HID installer package.

The build signs with the first "Apple Development" identity in your keychain so
macOS privacy approvals and launchd's code requirement survive rebuilds. With no
identity it falls back to ad-hoc signing, which must be re-approved after every
build (and launchd refuses to start a re-signed service until it is re-registered:
use **Restart service** on the Setup page). Override with `SIGN_IDENTITY="name"`.

## Install

```sh
make install
```

This copies the app to `/Applications` (no administrator password; `/Applications`
is writable by admin users) and opens it. The app's **Setup** page is a checklist;
every step uses a standard macOS dialog:

1. **Virtual keyboard driver** — opens the pinned, Apple-notarized
   `Karabiner-DriverKit-VirtualHIDDevice-8.6.0.pkg` in Installer.app.
2. **Driver extension** — activates it and takes you to System Settings → General →
   Login Items & Extensions → Driver Extensions to allow **pqrs.org**.
3. **Background service** — registers the helper and the virtual keyboard service
   with launchd from inside the app bundle. Allow **Pro Type Ultra** under Login
   Items → Allow in the Background. One toggle covers both services.
4. **Input Monitoring** for the app (reading keyboard settings, recording macros).
   After allowing it, click **Relaunch app**: macOS applies this permission only to
   a restarted process.
5. **Keyboard capture for Pro Type Ultra Helper** — the helper asks for
   **Accessibility**. On macOS 26.1 and later background services are no longer
   listed under Input Monitoring, and an Accessibility grant also covers keyboard
   capture (the same change Karabiner-Elements made). If the helper is not listed,
   click **+**, press Command-Shift-G, and paste
   `/Applications/ProTypeUltra.app/Contents/Library/Helpers/ProTypeUltraHelper.app`.
6. **Accessibility for the app** — optional, only for "Insert text" actions.
7. **Launch at login** — recommended. When launched at login the app lives in the
   menu bar only. It is needed for switching profiles by application and for
   launching applications or inserting text, because those must run in your user
   session; everything else runs in the background service.

If a copy from version 0.1 was installed with `make install` under sudo, the
checklist starts with **Remove the old Terminal-installed service**, which asks for
an administrator password once.

The keyboard is chosen automatically: wired first, then the receiver, then
Bluetooth. An override is available on the Setup page.

## Use

- **Keyboard:** select a key, choose its action, and Save. Add output keys to build
  a chord. The additional-key picker covers keypad, media, and mouse-button usages.
- **Alternate layer:** choose an ordinary trigger key. Physical Fn is not treated
  as independently remappable until verified.
- **Macros:** record (only when requested; recording suppresses typing and turns
  remapping on) or create key-down/up steps by hand. Every press needs a release.
- **Profiles:** assign application bundle IDs for automatic switching. Import and
  export versioned JSON. Profile changes cancel running macros and release outputs.
- **Lighting & Power:** readings sit in a status panel; controls apply as you change
  them and are kept by the background service (applied at startup, on reconnect, and
  with the app closed). Effects: static white, the firmware's breathing, **Reactive
  typing** (brightens on each keypress and fades back; needs remapping on) and
  **Candle** (gentle flicker). The keyboard has a single white zone and refuses
  per-key frames, so spatial effects such as wave or checkerboard are not possible
  on this hardware. Battery is shown raw, not as a percentage.
- **Menu bar:** status, the remapping switch, the profile, and Settings.

Quitting the app does not stop remapping. Turn remapping off with the switch, or
press **Control + Option + Escape** on the Razer: that releases the keyboard and
keeps it released until you turn remapping on again in the app.

## Command line

The CLI is inside the bundle at `Contents/Library/Helpers/protype` (the helper itself
is `Contents/Library/Helpers/ProTypeUltraHelper.app`; also at
`.build/release/protype` after `make build`). Hardware commands need Input
Monitoring for the hosting terminal and work while remapping is active.

```sh
protype list                        # connected Razer keyboards
protype probe                       # firmware, mode, brightness, battery, charging, idle
protype helper-status               # what the background service is doing
protype enable | disable            # turn remapping on or off
protype configure settings.json     # push a settings file to the service
protype roundtrip-brightness        # changes one raw step, then restores
protype effect staticWhite          # changes real hardware
protype idle 900                    # changes real hardware
protype watch 10                    # explicit 10-second input diagnostic
```

Add `--device ID` from `list` if cable and receiver are both connected.

## Remove

```sh
make uninstall
```

This unregisters the background services, removes the app and any legacy launch
daemons, and preserves your profiles in `~/Library/Application Support/ProTypeUltra`
and the shared Karabiner component (its own uninstaller is printed at the end).

## Security model

- The helper runs as root and accepts configuration only from processes signed by
  the same team as the helper with the app's or CLI's identifier, checked against
  the peer's audit token on every connection. A program merely running as you
  cannot push a profile that types. Ad-hoc builds cannot verify peers; the Setup
  page shows a warning and only the logged-in-user check applies.
- Status queries are answered for any local user; they contain state strings and
  the active profile name only. Hardware reads and writes from the app and CLI go
  through the helper (same signed-peer rule), which owns the keyboard's control
  interface so animations and manual changes never interleave on the wire.
- Reactive typing records only the time of the last keypress, never which key.
- Launch actions open application bundles only, as your user. Text actions run as
  your user through Accessibility. Macro and text contents are stored in plain
  text (mode 0600) in your settings and in the helper's root-only copy; do not put
  passwords in them.
- Everything typed on the Razer passes through the helper, as with any remapper.
  Normal operation never logs it; recording is explicit and diagnostics exclude it.
- The virtual-HID package is pinned by SHA-256 and checked against Apple's
  notarization before install. The helper and bridge are hardened-runtime binaries
  with library validation.

## Verification

`make test` covers packet validation, bounded busy retries, macro timing and
cancellation, modifier ownership, profile switching, invalid imports, the helper
protocol, automatic device preference, and control-interface classification. It does
not replace physical hardware tests; [docs/VALIDATION.md](docs/VALIDATION.md)
records what has been tested and what remains.

Diagnostic export excludes keystrokes, profile contents, and macro text. Normal
operation never logs typing.

GPL-2.0-or-later. See [LICENSE](LICENSE) and [THIRD_PARTY.md](THIRD_PARTY.md).
