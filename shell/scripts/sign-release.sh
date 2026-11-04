#!/usr/bin/env bash
# Release-signs an assembled, monolithic (non-component) ReArc.app the way Chromium's own
# signing pipeline does (chrome/installer/mac/signing/parts.py at the pin): every nested
# code object inside-out, hardened runtime, secure timestamps and the role-specific
# entitlements in scripts/release/entitlements, then the outer app. Verifies the result.
# Docs: engine/docs/RELEASE.md.
#
# Order: framework Libraries/*.dylib -> Helpers (Renderer, GPU, plain, Alerts and their
# Aperitif variants, crashpad handler, app_mode_loader, web_app_shortcut_copier) ->
# Chromium Framework.framework -> ReArc.app.
#
# Usage: scripts/sign-release.sh [path/to/ReArc.app]   (default dist/release/ReArc.app)
#   REARC_RELEASE_IDENTITY  "Developer ID Application: … (TEAMID)" for distribution. When unset,
#                           falls back to REARC_SIGN_IDENTITY (an Apple Development identity):
#                           everything but Gatekeeper and notarization can be verified with it.
#   REARC_TEAM_ID           Team the identity must belong to (checked on every signed object).
#   REARC_TIMESTAMP=none    offline only: no secure timestamp (notarization rejects that).
#   iCloud, as bundle-chromium.sh: REARC_ICLOUD_CONTAINER, REARC_ICLOUD_ENVIRONMENT and a
#   profile, REARC_RELEASE_PROVISIONING_PROFILE (Developer ID profile) or else
#   REARC_PROVISIONING_PROFILE (development profile, this Mac only).
# Environment wins over shell/signing.local.env, which is read the same way as by
# bundle-chromium.sh.
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$SHELL_DIR/scripts/release"
APP="${1:-$SHELL_DIR/dist/release/ReArc.app}"
die() { echo "sign-release: $*" >&2; exit 1; }
[[ -d $APP ]] || die "no app bundle at $APP"
APP="$(cd "$APP" && pwd)"

# shellcheck source=release/signing-env.sh
source "$RELEASE_DIR/signing-env.sh"
load_signing_env "$SHELL_DIR"
SIGN_IDENTITY="$(release_identity)"
TEAM_ID="$REARC_TEAM_ID"
[[ -n $SIGN_IDENTITY ]] || die "set REARC_RELEASE_IDENTITY (Developer ID Application) or REARC_SIGN_IDENTITY; release bundles are never ad-hoc signed"
[[ -n $TEAM_ID ]] || die "set REARC_TEAM_ID"
security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY" \
  || die "signing identity not found in the keychain: $SIGN_IDENTITY"
case "$SIGN_IDENTITY" in
  "Developer ID Application:"*) DISTRIBUTION=1 ;;
  *) DISTRIBUTION=0 ;;
esac
TIMESTAMP=(--timestamp)
[[ ${REARC_TIMESTAMP:-} != none ]] || TIMESTAMP=(--timestamp=none)

PLIST="$APP/Contents/Info.plist"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$PLIST")"
FRAMEWORK="$APP/Contents/Frameworks/Chromium Framework.framework"
[[ -d $FRAMEWORK ]] || die "no Chromium Framework.framework in $APP"
VERSION="$(readlink "$FRAMEWORK/Versions/Current")"
FW_DIR="$FRAMEWORK/Versions/$VERSION"
[[ -f "$FW_DIR/Chromium Framework" ]] || die "framework version $VERSION missing"
# A component dev build reexports libchrome_dll.dylib and 500+ dylibs that live outside the
# bundle; such a bundle cannot be sealed. Build with scripts/build-engine-release.sh.
if otool -L "$FW_DIR/Chromium Framework" | grep -q 'libchrome_dll'; then
  die "component (dev) engine build: release signing needs the monolithic framework (scripts/build-engine-release.sh)"
fi

FULL=restrict,library,runtime,kill
JIT=restrict,kill,runtime
RENDERER_ENT="$RELEASE_DIR/entitlements/helper-renderer.entitlements"
GPU_ENT="$RELEASE_DIR/entitlements/helper-gpu.entitlements"
signed=()
sign() { # sign PATH [codesign options…]
  local path="$1"; shift
  codesign --force --sign "$SIGN_IDENTITY" "${TIMESTAMP[@]}" "$@" "$path"
  signed+=("$path")
}

# Detritus (Finder info, resource forks) makes codesign refuse the bundle.
xattr -cr "$APP"

# Every Mach-O in the bundle must be one this script signs on purpose.
expected_macho() {
  case "${1#"$APP/"}" in
    Contents/MacOS/ReArc) ;;
    "Contents/Frameworks/Chromium Framework.framework/Versions/$VERSION/Chromium Framework") ;;
    "Contents/Frameworks/Chromium Framework.framework/Versions/$VERSION/Libraries/"*.dylib) ;;
    "Contents/Frameworks/Chromium Framework.framework/Versions/$VERSION/Helpers/"*) ;;
    *) return 1 ;;
  esac
}
while IFS= read -r -d '' file; do
  [[ -L $file ]] && continue
  if file -b "$file" | grep -q 'Mach-O'; then
    expected_macho "$file" || die "unexpected Mach-O, not signed by this script: ${file#"$APP/"}"
  fi
done < <(find "$APP" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0)

echo "==> signing $APP"
echo "    identity: $SIGN_IDENTITY (team $TEAM_ID)$([[ $DISTRIBUTION == 1 ]] || echo ', development identity: not distributable')"
for lib in "$FW_DIR/Libraries/"*.dylib; do
  [[ -e $lib ]] || continue
  sign "$lib"
done
for helper in "$FW_DIR/Helpers/"*; do
  name="$(basename "$helper")"
  case "$name" in
    "Chromium Helper (Renderer).app"|"Chromium Helper (Aperitif Renderer).app")
      sign "$helper" --options "$JIT" --entitlements "$RENDERER_ENT" ;;
    "Chromium Helper (GPU).app"|"Chromium Helper (Aperitif GPU).app")
      sign "$helper" --options "$JIT" --entitlements "$GPU_ENT" ;;
    "Chromium Helper.app"|"Chromium Helper (Aperitif).app"|"Chromium Helper (Alerts).app"|"Chromium Helper (Aperitif Alerts).app")
      sign "$helper" --options "$FULL" ;;
    chrome_crashpad_handler|app_mode_loader)
      sign "$helper" --options "$FULL" ;;
    web_app_shortcut_copier)
      sign "$helper" --options "$FULL" --identifier "$BUNDLE_ID.web_app_shortcut_copier" ;;
    *) die "unknown helper $name; add it to sign-release.sh with Chromium's options for it" ;;
  esac
done
sign "$FRAMEWORK"

ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/rearc-release-entitlements.XXXXXX")"
trap 'rm -f "$ENTITLEMENTS"' EXIT
if [[ -n $REARC_ICLOUD_CONTAINER ]]; then
  # shellcheck source=icloud-signing.sh
  source "$SHELL_DIR/scripts/icloud-signing.sh"
  icloud_prepare "$APP" "$BUNDLE_ID" "${REARC_RELEASE_PROVISIONING_PROFILE:-$REARC_PROVISIONING_PROFILE}" \
    "$RELEASE_DIR/entitlements/app.entitlements" "$ENTITLEMENTS"
else
  cp "$RELEASE_DIR/entitlements/app.entitlements" "$ENTITLEMENTS"
  rm -f "$APP/Contents/embedded.provisionprofile"
  plutil -remove ReArcICloudContainer "$PLIST" 2>/dev/null || true
fi
sign "$APP" --options "$FULL" --identifier "$BUNDLE_ID" --entitlements "$ENTITLEMENTS"

echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
problems=0
for path in "${signed[@]}"; do
  info="$(codesign -dvv "$path" 2>&1)"
  team="$(sed -n 's/^TeamIdentifier=//p' <<<"$info")"
  [[ $team == "$TEAM_ID" ]] || { echo "  team '$team' != $TEAM_ID: $path" >&2; problems=1; }
  if [[ ${REARC_TIMESTAMP:-} != none ]] && ! grep -q '^Timestamp=' <<<"$info"; then
    echo "  no secure timestamp: $path" >&2; problems=1
  fi
  if [[ $path != *.dylib && $path != "$FRAMEWORK" ]] && ! grep -q 'flags=.*runtime' <<<"$info"; then
    echo "  no hardened runtime: $path" >&2; problems=1
  fi
done
for helper in "Chromium Helper (Renderer).app" "Chromium Helper (GPU).app"; do
  codesign -d --entitlements - --xml "$FW_DIR/Helpers/$helper" 2>/dev/null | grep -q 'com.apple.security.cs.allow-jit' \
    || { echo "  $helper lacks allow-jit" >&2; problems=1; }
done
[[ -z $REARC_ICLOUD_CONTAINER ]] || icloud_verify "$APP/Contents/MacOS/ReArc"
[[ $problems == 0 ]] || die "signature checks failed"
echo "==> ${#signed[@]} code objects signed; codesign --verify --deep --strict: pass"
echo "==> Gatekeeper assessment (spctl -a -vv; needs Developer ID and notarization to pass):"
spctl -a -vv -t exec "$APP" 2>&1 | sed 's/^/    /' || true
