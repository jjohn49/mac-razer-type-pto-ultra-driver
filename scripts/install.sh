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
open "$target"
echo "Installed $target. Finish the checklist on the app's Setup page."
