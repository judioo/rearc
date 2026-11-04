#!/usr/bin/env bash
# Wraps the WebKit-only shell (plain `swift build`, no Chromium) in a minimal
# development app bundle, dist/webkit/ReArc Dev.app. `swift run` has no bundle,
# so LaunchServices cannot offer it as the default browser or send it links
# from other apps; this bundle can (CFBundleURLTypes http/https). Its bundle id
# differs from the Chromium bundle's, so the two never shadow each other.
#
# Usage: scripts/bundle-webkit-dev.sh [--release] [--open]
#   --open  launch the bundle when done
#
# Ad-hoc signed, no iCloud, unless both are set (environment or shell/signing.local.env;
# docs/ICLOUD-SETUP.md): REARC_ICLOUD_CONTAINER and REARC_WEBKIT_PROVISIONING_PROFILE, a
# development profile for com.rearc.browser.webkit-dev. Then REARC_SIGN_IDENTITY and
# REARC_TEAM_ID sign the bundle with the iCloud/CloudKit entitlements.
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$SHELL_DIR/dist/webkit"
CONFIG=debug
OPEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) CONFIG=release ;;
    --open) OPEN=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

die() { echo "bundle-webkit-dev: $*" >&2; exit 1; }
_vars=(REARC_SIGN_IDENTITY REARC_TEAM_ID REARC_ICLOUD_CONTAINER REARC_WEBKIT_PROVISIONING_PROFILE REARC_ICLOUD_ENVIRONMENT)
if [[ -f "$SHELL_DIR/signing.local.env" ]]; then
  # Environment variables take precedence over the file (bash 3.2: no associative arrays).
  for v in "${_vars[@]}"; do printf -v "_saved_$v" '%s' "${!v:-}"; done
  # shellcheck disable=SC1091
  source "$SHELL_DIR/signing.local.env"
  for v in "${_vars[@]}"; do
    saved="_saved_$v"
    if [[ -n ${!saved} ]]; then printf -v "$v" '%s' "${!saved}"; fi
  done
fi
for v in "${_vars[@]}"; do printf -v "$v" '%s' "${!v:-}"; done
SIGN_IDENTITY="$REARC_SIGN_IDENTITY"
TEAM_ID="$REARC_TEAM_ID"
ICLOUD=0
if [[ -n $REARC_ICLOUD_CONTAINER && -n $REARC_WEBKIT_PROVISIONING_PROFILE ]]; then
  ICLOUD=1
elif [[ -n $REARC_ICLOUD_CONTAINER ]]; then
  echo "==> iCloud off for this bundle: set REARC_WEBKIT_PROVISIONING_PROFILE (a profile for com.rearc.browser.webkit-dev)"
fi
# shellcheck source=icloud-signing.sh
source "$SHELL_DIR/scripts/icloud-signing.sh"

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
  <key>NSCameraUsageDescription</key><string>A website you allowed wants to use your camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>A website you allowed wants to use your microphone.</string>
  <key>NSLocationUsageDescription</key><string>A website you allowed wants to know your location.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>A website you allowed wants to know your location.</string>
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
if [[ $ICLOUD == 1 ]]; then
  ENTITLEMENTS="$SHELL_DIR/.build/ReArc.webkit-dev.icloud.entitlements"
  icloud_prepare "$APP" com.rearc.browser.webkit-dev "$REARC_WEBKIT_PROVISIONING_PROFILE" "$SHELL_DIR/scripts/ReArc.entitlements" "$ENTITLEMENTS"
  codesign --force --sign "$SIGN_IDENTITY" --identifier com.rearc.browser.webkit-dev --timestamp=none \
    --entitlements "$ENTITLEMENTS" "$APP"
  icloud_verify "$APP/Contents/MacOS/ReArc"
  echo "==> $APP (signed with iCloud; ReArc Dev > Set ReArc as Default Browser… asks macOS to register it)"
else
  codesign --force --sign - --entitlements "$SHELL_DIR/scripts/ReArc.entitlements" "$APP/Contents/MacOS/ReArc" 2>/dev/null
  echo "==> $APP (ad-hoc signed; ReArc Dev > Set ReArc as Default Browser… asks macOS to register it)"
fi
[[ $OPEN == 1 ]] && open "$APP"
exit 0
