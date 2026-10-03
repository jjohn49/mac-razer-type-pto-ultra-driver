#!/bin/bash
# Removes the app, its background services, and any legacy (pre-0.2) installation.
# Profiles in ~/Library/Application Support/ProTypeUltra are preserved.
set -euo pipefail
[[ "$EUID" == 0 ]] || { echo 'Run this script with sudo.' >&2; exit 1; }
app=/Applications/ProTypeUltra.app
if [[ -x "$app/Contents/MacOS/ProTypeUltra" && -n "${SUDO_USER:-}" ]]; then
  sudo -u "$SUDO_USER" "$app/Contents/MacOS/ProTypeUltra" --unregister || true
fi
for label in local.protypeultra.helper local.protypeultra.virtualhid; do
  launchctl bootout "system/$label" 2>/dev/null || true
  rm -f "/Library/LaunchDaemons/$label.plist"
done
rm -rf '/Library/Application Support/ProTypeUltra' "$app" /var/run/protype-ultra.sock
echo 'Removed ProTypeUltra. Your profiles are preserved in ~/Library/Application Support/ProTypeUltra.'
echo 'The shared Karabiner virtual-HID component is preserved because other applications may use it.'
echo 'To remove it: bash "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/uninstall.sh"'
