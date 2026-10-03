# Pro Type Ultra for Mac — build recipe

## Goal and architecture

Build a native Mac app for the Razer Pro Type Ultra's keyboard-specific Synapse features: remapping, macros, profiles, alternate layers, lighting, and supported power controls.

Use a SwiftUI app, a Swift hardware service, and a privileged input helper using Karabiner's signed virtual-HID component. Do not write a USB driver: read-only configuration queries have already succeeded through Apple's existing HID driver.

Initial target: this Apple Silicon Mac running macOS 27. Test the actual keyboard over USB, dongle, and Bluetooth. Keep profiles local. Firmware flashing, Razer cloud services, and public distribution are excluded.

Follow the steps in order. Pass each checkpoint before depending on its behavior.

## 1. Prepare the project

- Create a SwiftUI app named `ProTypeUltra`, a `KeyboardCore` Swift package, a hardware-access module, a diagnostic CLI, and a privileged `InputHelper`.
- Bridge the helper to Karabiner's virtual-HID client using C++.
- Store settings in `~/Library/Application Support/ProTypeUltra/`.
- Provide `make build`, `make test`, and explicit installation/removal instructions.

**Checkpoint:** The app launches and core tests run.

## 2. Reproduce the hardware probe

Use `IOHIDManager` to match vendor `0x1532`, wired product `0x0277`, and the interface advertising `MaxFeatureReportSize == 90`. Open nonexclusively using `IOHIDDeviceOpen(device, 0)`. Input Monitoring permission is required.

Construct a zero-filled 90-byte request:

| Byte | Meaning |
| --- | --- |
| 1 | `0x1F`, the verified wired transaction identifier |
| 5 | Argument length |
| 6 | Command class |
| 7 | Command ID |
| 8 onward | Arguments |
| 88 | XOR of bytes 2 through 87 |

Send a feature report using `IOHIDDeviceSetReport`, **report ID 0**. Wait 80 ms, then retrieve 90 bytes using `IOHIDDeviceGetReport`. Report ID 0 is not USB interface number 2.

| Reading | Class / ID | Request argument length | Arguments | Observed result, 2026-10-02 |
| --- | --- | --- | --- | --- |
| Firmware | `00 / 81` | 2 | Zero-filled | `01 00` |
| Device mode | `00 / 84` | 2 | Zero-filled | Normal; response argument length 1 |
| Brightness | `0F / 84` | 3 | `01 05 00` | Raw 6; scale not physically validated |
| Battery | `07 / 80` | 2 | Zero-filled | Raw 0; percentage interpretation unverified |
| Charging | `07 / 84` | 2 | Zero-filled | Charging |
| Idle timeout | `07 / 83` | 2 | Zero-filled | 900 seconds |

All six original queries returned status `0x02`, matching commands and transactions, and valid checksums. No settings were changed during the probe.

Validate response length, checksum, command, transaction, and status. Permit command-specific response argument lengths. Save observed responses as fixtures.

**Checkpoint:** The CLI reproduces successful reads on the physical keyboard.

## 3. Implement hardware settings

- Serialize exchanges on a worker queue. Add bounded timeouts and busy-response retries; never block input callbacks.
- Use the [OpenRazer Pro Type Ultra contribution](https://github.com/openrazer/openrazer/pull/2888) and referenced packet constructors for brightness and white off/static/breathing effects. Preserve applicable licensing and attribution.
- For each setting: read the original value where supported, apply one change, read it back where supported, confirm the physical result, restore the original setting, and repeat after reconnect.
- Investigate idle-time writes separately. Do not present battery as a percentage until validated.
- Track verified, unavailable, and unverified capabilities per connection.

**Checkpoint:** Every enabled control has a recorded hardware test or is explicitly marked unverified.

## 4. Make one remapping work

- Pin the [Karabiner virtual-HID component](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice) and matching client headers.
- Verify virtual output on macOS 27 before exclusively capturing physical input.
- Capture only the selected Razer interfaces. Forward unchanged input first, then map one ordinary key.
- Confirm exactly one output press/release, without duplication or generated-input feedback.
- Establish output before capture; release capture whenever output fails. Keep the built-in keyboard untouched.
- Authenticate app-to-helper communication. Execute application-launch and text actions in the logged-in user's process, never as root.
- Stop the helper and confirm ordinary typing returns.

**Checkpoint:** Remapping works and helper failure does not leave the keyboard captured without working output.

## 5. Build the behavior engine

Add in this order:

1. Key/modifier remaps, shortcuts, media controls, mouse actions, disabled keys, text insertion, and application launching.
2. An alternate layer activated by a configurable key.
3. Explicit macro recording/editing, delays, repeat counts, hold-repeat, toggle playback, and emergency cancellation.
4. Named profiles, foreground-application switching, and import/export using versioned JSON.

Release generated held keys and cancel macros on disconnect or profile changes. Test Fn alone, F1, Fn+F1, and Fn+Esc. Use physical Fn as a layer trigger only if its independent state is observable; always support an ordinary-key trigger.

**Checkpoint:** Event-sequence tests verify presses, releases, modifier ownership, repetition, and cancellation.

## 6. Add the interface and wireless support

- Add Keyboard, Macros, Profiles, Lighting & Power, and Diagnostics pages.
- Include connection status, permission guidance, pause, and launch at login.
- Test dongle product `0x027B` independently. Discover Bluetooth identifiers from the paired keyboard rather than assuming USB identifiers or commands apply.
- Reuse the mapping engine across connections. Explain when a hardware setting requires USB or dongle access.

**Checkpoint:** Publish a USB/dongle/Bluetooth feature matrix grounded in physical tests.

## 7. Finish and deliver

- Test reconnect, sleep/wake, cable and dongle connected together, permission loss, helper termination, secure input, and macro cancellation.
- Test malformed responses, unsupported commands, busy responses, timeouts, and invalid imported profiles.
- Measure mapping latency and idle CPU use.
- Deliver reproducible source/build commands, passing automated tests, local installation/removal instructions, diagnostics without ordinary typing logs, and a verified feature matrix with remaining limitations.

**Completion rule:** Simulated tests do not establish hardware support. A feature is complete only after its physical acceptance test passes. If hardware or an OS approval is unavailable, identify the blocked test explicitly rather than claiming full parity.

## Status after the 2026-10-02 rework

Steps 1–3 are built and the hardware reads/writes in step 3 are verified over USB.
Steps 4–7 are implemented with the architecture changed from "app drives helper"
to "service owns the keyboard": the helper persists its configuration under
`/Library/Application Support/ProTypeUltra/configuration.json`, captures without
the app, leaves the 90-byte control interface unseized, and is registered from the
app bundle with `SMAppService` together with the upstream virtual-HID daemon.
Installation happens on the app's Setup page through Installer.app, Login Items,
and System Settings. Physical acceptance for steps 4–7 is still pending the
interactive approvals listed in `docs/VALIDATION.md`.
