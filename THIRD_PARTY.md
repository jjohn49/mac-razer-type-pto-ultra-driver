# Third-party code and protocol references

This project is licensed GPL-2.0-or-later. Razer packet layouts are adapted from
OpenRazer's GPL-2.0-or-later driver sources (Tim Theede, Terri Cain, and contributors).

- https://github.com/openrazer/openrazer/blob/master/driver/razercommon.c
- https://github.com/openrazer/openrazer/blob/master/driver/razerchromacommon.c
- Model-specific corrections: https://github.com/openrazer/openrazer/pull/2888

The C++ output bridge uses Karabiner-DriverKit-VirtualHIDDevice by Fumihiko Takayama
under the Boost Software License 1.0. Its sources, notices, dependency lock, and
licenses are retained in the downloaded dependency. We do not modify or re-sign
the upstream DriverKit extension.

Pinned source: `ba98de7fae2d529b9debe82890765dc66246f4ff`.
Installer: `Karabiner-DriverKit-VirtualHIDDevice-8.6.0.pkg`, redistributed unmodified
inside `ProTypeUltra.app/Contents/Resources` so the app can open it in Installer.app.
SHA-256: `ff8c7fdc5e25387c7805fc7509a0fa9cf98f69ba582704f717fddcae47424387`.
Client protocol: 7. Package signature verified on 2026-10-02 against Apple trust
services: Developer ID Installer Fumihiko Takayama, team `G43BCU2T37`, notarized.

Dependency: https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice
