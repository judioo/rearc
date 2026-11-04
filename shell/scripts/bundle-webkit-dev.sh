#!/usr/bin/env bash
# Wraps the WebKit-only shell (plain `swift build`, no Chromium) in a minimal
# development app bundle, dist/webkit/ReArc Dev.app. `swift run` has no bundle,
# so LaunchServices cannot offer it as the default browser or send it links
# from other apps; this bundle can (CFBundleURLTypes http/https). Its bundle id
# differs from the Chromium bundle's, so the two never shadow each other.
#
# Usage: scripts/bundle-webkit-dev.sh [--release] [--open]
#   --open  launch the bundle when done
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$SHELL_DIR/dist/webkit"
CONFIG=debug
OPEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) CONFIG=release ;;
    --open) OPEN=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

echo "==> swift build (${CONFIG}, WebKit)"
swift build --package-path "$SHELL_DIR" -c "$CONFIG" --product rearc
BIN="$(swift build --package-path "$SHELL_DIR" -c "$CONFIG" --show-bin-path)/rearc"

APP="$DIST/ReArc Dev.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ReArc"
PLIST="$APP/Contents/Info.plist"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ReArc</string>
  <key>CFBundleIdentifier</key><string>com.rearc.browser.webkit-dev</string>
  <key>CFBundleName</key><string>ReArc Dev</string>
  <key>CFBundleDisplayName</key><string>ReArc Dev</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web site URL</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null
codesign --force --sign - "$APP/Contents/MacOS/ReArc" 2>/dev/null
echo "==> $APP (ad-hoc signed; ReArc Dev > Set ReArc as Default Browser… asks macOS to register it)"
[[ $OPEN == 1 ]] && open "$APP"
exit 0
