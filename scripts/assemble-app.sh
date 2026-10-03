#!/bin/bash
# Turns the Xcode-built app into a self-contained bundle: helper app, output bridge,
# CLI, both launchd plists, and the pinned virtual-HID installer package.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-build/DerivedData/Build/Products/Release/ProTypeUltra.app}"
# Same rule as the Makefile: a stable identity keeps privacy approvals and launchd's
# code requirement valid across rebuilds; ad-hoc only when nothing is available.
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')}"
identity="${identity:--}"
echo "Signing with: $identity"
version="$(defaults read "$PWD/$app/Contents/Info.plist" CFBundleShortVersionString)"
package=".deps/virtualhid/dist/Karabiner-DriverKit-VirtualHIDDevice-8.6.0.pkg"
printf '%s  %s\n' ff8c7fdc5e25387c7805fc7509a0fa9cf98f69ba582704f717fddcae47424387 "$package" | shasum -a 256 --check --status
helpers="$app/Contents/Library/Helpers"
daemons="$app/Contents/Library/LaunchDaemons"
# The helper is its own application bundle (like Karabiner's daemon) so that
# System Settings → Input Monitoring lists it by name and the + button can pick it.
helperapp="$helpers/ProTypeUltraHelper.app"
rm -rf "$helperapp" "$helpers/protype-helper" "$helpers/protype-output"
mkdir -p "$helperapp/Contents/MacOS" "$daemons" "$app/Contents/Resources"
install -m 755 .build/release/protype-helper build/protype-output "$helperapp/Contents/MacOS/"
install -m 755 .build/release/protype "$helpers/"
cat > "$helperapp/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.protypeultra.helper</string>
  <key>CFBundleName</key><string>Pro Type Ultra Helper</string>
  <key>CFBundleDisplayName</key><string>Pro Type Ultra Helper</string>
  <key>CFBundleExecutable</key><string>protype-helper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSBackgroundOnly</key><true/>
  <key>NSInputMonitoringUsageDescription</key><string>Captures the Razer keyboard so your mappings, layers, and macros apply.</string>
</dict></plist>
PLIST
printf 'APPL????' > "$helperapp/Contents/PkgInfo"
# Same icon for the helper so System Settings lists it recognisably.
iconset="build/ProTypeUltra.iconset"; rm -rf "$iconset"; mkdir -p "$iconset" "$helperapp/Contents/Resources"
cp App/Assets.xcassets/AppIcon.appiconset/icon_*.png "$iconset/"
iconutil -c icns "$iconset" -o "$helperapp/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$helperapp/Contents/Info.plist"
install -m 644 scripts/launchd/local.protypeultra.helper.plist scripts/launchd/local.protypeultra.virtualhid.plist "$daemons/"
install -m 644 "$package" "$app/Contents/Resources/"
plutil -lint "$daemons"/*.plist "$helperapp/Contents/Info.plist" > /dev/null
codesign --force --sign "$identity" --identifier local.protypeultra.output "$helperapp/Contents/MacOS/protype-output"
codesign --force --sign "$identity" --options runtime "$helperapp"
codesign --force --sign "$identity" --identifier local.protypeultra.cli "$helpers/protype"
codesign --force --sign "$identity" --options runtime "$app"
codesign --verify --deep --strict "$app"
echo "Assembled $app"
