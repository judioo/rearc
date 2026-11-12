#!/usr/bin/env bash
# Packages a release-signed ReArc.app (scripts/sign-release.sh) into a signed, compressed
# DMG: the app, an Applications link, the ReArc volume icon and a branded Finder background
# (scripts/release/dmg-background.swift; layout written by Chromium's
# chrome/installer/mac/generate_dsstore.py, so no Finder scripting is needed). The DMG is
# signed with the same identity as the app. Notarize it afterwards with scripts/notarize.sh.
# Docs: engine/docs/RELEASE.md.
#
# Usage: scripts/make-dmg.sh [path/to/ReArc.app] [--out FILE.dmg]
#   default app dist/release/ReArc.app; default output next to it, ReArc-<version>.dmg
#   Identity: REARC_RELEASE_IDENTITY, else REARC_SIGN_IDENTITY (env or signing.local.env).
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$SHELL_DIR/.." && pwd)"
APP="$SHELL_DIR/dist/release/ReArc.app"
DMG=""
die() { echo "make-dmg: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) DMG="$2"; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) APP="$1" ;;
  esac
  shift
done
[[ -d $APP ]] || die "no app bundle at $APP"
APP="$(cd "$APP" && pwd)"
# shellcheck source=release/signing-env.sh
source "$SHELL_DIR/scripts/release/signing-env.sh"
load_signing_env "$SHELL_DIR"
IDENTITY="$(release_identity)"
[[ -n $IDENTITY ]] || die "no signing identity (REARC_RELEASE_IDENTITY or REARC_SIGN_IDENTITY)"
codesign --verify --deep --strict "$APP" || die "$APP is not validly signed; run scripts/sign-release.sh first"
# Captured first: under pipefail, grep -q closing the pipe early would fail codesign with SIGPIPE.
app_info="$(codesign -dvv "$APP" 2>&1)"
grep -q 'flags=.*runtime' <<<"$app_info" || die "$APP lacks the hardened runtime; run scripts/sign-release.sh"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
# ReArc-2026.1112.726.dmg: the version carries the build (release/version.py dmg-name).
BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
NAME="$(python3 -I "$SHELL_DIR/scripts/release/version.py" dmg-name "$VERSION" "$BUILD")" || die "no DMG name for $VERSION ($BUILD)"
DMG="${DMG:-$(dirname "$APP")/$NAME}"
VOLUME="ReArc"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rearc-dmg.XXXXXX")"
MOUNT="$WORK/mount"
cleanup() {
  [[ -d $MOUNT ]] && hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. Staging folder. ditto keeps the signatures, extended attributes excluded.
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto --noextattr --noqtn "$APP" "$STAGE/ReArc.app"
ln -s /Applications "$STAGE/ "
cp "$SHELL_DIR/Resources/ReArc.icns" "$STAGE/.VolumeIcon.icns"
BACKGROUND=0
if swift "$SHELL_DIR/scripts/release/dmg-background.swift" "$WORK" >/dev/null 2>&1 \
    && tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" \
      -out "$STAGE/.background/background.tiff" >/dev/null 2>&1; then
  DSSTORE="$REPO/engine/chromium/src/chrome/installer/mac/generate_dsstore.py"
  # A taller window than the script's 633 x 320, icons higher: Finder keeps its own path
  # bar and status bar settings, and with both on the 320 pt window clipped the app's label.
  # dmg-background.swift draws for this geometry.
  if [[ -f $DSSTORE ]] && python3 -I "$DSSTORE" "$STAGE/.DS_Store" --volume-name "$VOLUME" \
      --app-name ReArc.app --background-image /.background/background.tiff \
      --window-height 380 --app-y 136 --link-y 136; then
    BACKGROUND=1
  fi
fi
[[ $BACKGROUND == 1 ]] || { echo "==> no Finder background (renderer or generate_dsstore.py unavailable); plain layout"; rm -rf "$STAGE/.background" "$STAGE/.DS_Store"; }

# 2. Read-write image, mark the volume icon (kHasCustomIcon), then compress.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) * 11 / 10 + 20 ))
hdiutil create -quiet -volname "$VOLUME" -fs HFS+ -srcfolder "$STAGE" -format UDRW -size "${SIZE_MB}m" "$WORK/rw.dmg"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" "$WORK/rw.dmg"
SetFile -a C "$MOUNT"
[[ $BACKGROUND == 0 ]] || SetFile -a V "$MOUNT/.background"
hdiutil detach -quiet "$MOUNT"
rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"

# 3. Sign and check.
codesign --force --sign "$IDENTITY" --timestamp --identifier "$BUNDLE_ID.dmg" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
hdiutil verify -quiet "$DMG"
echo "==> $DMG ($(du -h "$DMG" | cut -f1)), signed by: $(codesign -dvv "$DMG" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "==> Gatekeeper assessment (passes only once Developer ID signed and notarized):"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /' || true
