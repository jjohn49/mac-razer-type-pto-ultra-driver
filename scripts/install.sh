#!/bin/bash
# Copies the built app into /Applications (no administrator password needed for
# an admin user) and opens it. Every privileged step is then done from the app's
# Setup page through standard macOS dialogs.
set -euo pipefail
cd "$(dirname "$0")/.."
source="build/DerivedData/Build/Products/Release/ProTypeUltra.app"
target="/Applications/ProTypeUltra.app"
[[ -d "$source/Contents/Library/LaunchDaemons" ]] || { echo "Run make build first." >&2; exit 1; }
codesign --verify --deep --strict "$source"
if pgrep -xq ProTypeUltra; then osascript -e 'tell application "ProTypeUltra" to quit' || true; sleep 1; fi
if [[ -e "$target" && ! -w "$target" ]]; then
  echo "A previous Terminal-installed copy owns $target. Opening the new app from the build folder;"
  echo "use its Setup page to remove the old installation, then click Move to Applications."
  open "$source"; exit 0
fi
rm -rf "$target"
ditto "$source" "$target"
# Replacing a bundle in place leaves the Dock and Finder showing the old icon.
touch "$target"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target" || true
rm -rf ~/Library/Caches/com.apple.iconservices.store 2>/dev/null || true
killall Dock 2>/dev/null || true
# The background service keeps running the old binary until it is restarted
# (quitting the app does not stop it). Restart it only if it is already set up.
if pgrep -xq protype-helper; then
  "$target/Contents/MacOS/ProTypeUltra" --restart-services && echo "Restarted the background service." \
    || echo "Could not restart the background service; use Setup → Restart service."
fi
sleep 1
open "$target"
echo "Installed $target. Finish the checklist on the app's Setup page."
