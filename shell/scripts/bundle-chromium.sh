#!/usr/bin/env bash
# Builds the Chromium-enabled shell and assembles a runnable ReArc.app around
# the existing engine build output (never builds Chromium, never writes to engine/).
#
# Layout (engine/docs/C-ABI.md "Linking and startup"):
#   $DIST/ReArc.app/Contents/MacOS/ReArc                 shell executable (rpath @executable_path/../Frameworks)
#   $DIST/ReArc.app/Contents/Frameworks/Chromium Framework.framework/Versions/<ver>/
#        Chromium Framework, Helpers/*.app, Libraries/, Resources/   physical copy of the upstream framework
#   $DIST/*.dylib                                        component dylib closure; the framework's LC_RPATH
#                                                        @loader_path/../../../../../.. resolves to $DIST
#
# Usage: scripts/bundle-chromium.sh [--release] [--copy-dylibs] [--dist DIR] [--skip-build] [--selftest]
#                                   [--dev-mock-keychain] [--launch-check] [--engine-out DIR]
#   --launch-check      after assembling, launch the bundle through LaunchServices (`open`, no
#                       engine argument, with and without a link) and check it reaches ready on
#                       the Chromium path (scripts/check-launch.sh; throwaway profile).
#   REARC_CHROMIUM_OUT  engine output dir (default: engine/chromium/src/out/ReArc-dev-arm64);
#   --engine-out DIR    the same, as an option. A monolithic (non-component) engine build such
#                       as out/ReArc-release-arm64 (scripts/build-engine-release.sh) has no
#                       dylib closure: the framework is self-contained. Release-sign that bundle
#                       with scripts/sign-release.sh, or run scripts/release.sh for everything.
#   --dev-mock-keychain DEVELOPMENT ONLY, off by default, refused with --release. Marks the
#                       bundle so the shell passes Chromium's --use-mock-keychain: cookies and
#                       other Safe Storage data are then NOT encrypted with a Keychain key. It
#                       avoids Keychain authorization stalls caused by this script's ad-hoc
#                       signature on a replaced executable. Self-test log: selftest-chromium-mockkeychain.log.
#
# Signing (optional; ad-hoc when unset). Set in the environment or in the git-ignored
# shell/signing.local.env (see signing.example.env):
#   REARC_SIGN_IDENTITY  codesign identity name or SHA-1, e.g. "Apple Development: …" for local
#                        development (a stable signature keeps the Keychain "Safe Storage" grant
#                        across rebuilds), or "Developer ID Application: …" for distribution.
#   REARC_TEAM_ID        Apple Developer Team ID; the identity's certificate must belong to it.
#
# iCloud sidebar sync (optional, off when unset; docs/ICLOUD-SETUP.md):
#   REARC_ICLOUD_CONTAINER      e.g. iCloud.com.rearc.browser. Adds the iCloud/CloudKit
#                               entitlements, embeds the profile and signs the whole bundle.
#   REARC_PROVISIONING_PROFILE  development profile (.provisionprofile) for the bundle id,
#                               with the container, CloudKit and this Mac.
#   REARC_ICLOUD_ENVIRONMENT    Development (default) or Production CloudKit environment.
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$SHELL_DIR/.." && pwd)"
OUT="${REARC_CHROMIUM_OUT:-$REPO/engine/chromium/src/out/ReArc-dev-arm64}"
BRIDGE="$REPO/engine/chromium/src/chrome/browser/rearc_bridge"
# REARC_SHELL_SCRATCH: another scratch path, so parallel builds do not share one.
SCRATCH="${REARC_SHELL_SCRATCH:-$SHELL_DIR/.build-chromium}"
DIST="$SHELL_DIR/dist/chromium"
CONFIG=debug
DYLIB_MODE=symlink
BUILD=1
SELFTEST=0
DEV_MOCK_KEYCHAIN=0
LAUNCH_CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) CONFIG=release ;;
    --copy-dylibs) DYLIB_MODE=copy ;;
    --dist) DIST="$2"; shift ;;
    --engine-out) OUT="$(cd "$2" && pwd)"; shift ;;
    --skip-build) BUILD=0 ;;
    --selftest) SELFTEST=1 ;;
    --dev-mock-keychain) DEV_MOCK_KEYCHAIN=1 ;;
    --launch-check) LAUNCH_CHECK=1 ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

die() { echo "bundle-chromium: $*" >&2; exit 1; }

# Local, never-committed signing settings. Environment variables take precedence.
if [[ -f "$SHELL_DIR/signing.local.env" ]]; then
  _identity="${REARC_SIGN_IDENTITY:-}" _team="${REARC_TEAM_ID:-}"
  _container="${REARC_ICLOUD_CONTAINER:-}" _profile="${REARC_PROVISIONING_PROFILE:-}" _environment="${REARC_ICLOUD_ENVIRONMENT:-}"
  # shellcheck disable=SC1091
  source "$SHELL_DIR/signing.local.env"
  REARC_SIGN_IDENTITY="${_identity:-${REARC_SIGN_IDENTITY:-}}"
  REARC_TEAM_ID="${_team:-${REARC_TEAM_ID:-}}"
  REARC_ICLOUD_CONTAINER="${_container:-${REARC_ICLOUD_CONTAINER:-}}"
  REARC_PROVISIONING_PROFILE="${_profile:-${REARC_PROVISIONING_PROFILE:-}}"
  REARC_ICLOUD_ENVIRONMENT="${_environment:-${REARC_ICLOUD_ENVIRONMENT:-}}"
fi
REARC_ICLOUD_CONTAINER="${REARC_ICLOUD_CONTAINER:-}"
# shellcheck source=icloud-signing.sh
source "$SHELL_DIR/scripts/icloud-signing.sh"
SIGN_IDENTITY="${REARC_SIGN_IDENTITY:-}"
TEAM_ID="${REARC_TEAM_ID:-}"
if [[ -n $SIGN_IDENTITY ]]; then
  security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY" \
    || die "signing identity not found in the keychain: $SIGN_IDENTITY"
fi

# The mock keychain disables real cookie encryption; it must never reach a release bundle.
# (Release builds of the shell also ignore the Info.plist marker.)
[[ $DEV_MOCK_KEYCHAIN == 1 && $CONFIG == release ]] && die "--dev-mock-keychain is development-only and cannot be combined with --release"

[[ -d "$OUT/Chromium.app" ]] || die "no Chromium.app in $OUT (build the engine first; this script never does)"
# Component dev builds reexport libchrome_dll.dylib and need the dylib closure next to the
# app; non-component builds put everything in Chromium Framework.
if [[ -f "$OUT/libchrome_dll.dylib" ]]; then
  COMPONENT=1
else
  COMPONENT=0
  otool -L "$OUT/Chromium.app/Contents/Frameworks/Chromium Framework.framework/Chromium Framework" | grep -q libchrome_dll \
    && die "no libchrome_dll.dylib in $OUT, but its framework needs it (incomplete component build)"
fi
for header in rearc_engine_abi.h rearc_engine_entry_mac.h module.modulemap; do
  [[ -f "$BRIDGE/$header" ]] || die "missing $BRIDGE/$header"
done
# Like engine/tests/run_c_abi.py, don't package a tree that is being rebuilt, but only
# a build of THIS out dir blocks: a release build in out/ReArc-release-* doesn't block a
# dev bundle and vice versa. siso's -C is relative to chromium/src or absolute, so match
# the dir name after -C. The bracket keeps the pattern from matching a wrapper whose own
# argv quotes it.
OUT_NAME="$(basename "$OUT")"
if pgrep -fl "siso[ ]ninja.* -C ([^ ]*/)?${OUT_NAME}( |/|\$)" >/dev/null 2>&1; then
  die "a Chromium build (siso ninja) of $OUT_NAME is running; wait for it to finish"
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw "$OUT/Chromium.app/Contents/Info.plist")"
FRAMEWORK_REL="Contents/Frameworks/Chromium Framework.framework"
[[ -d "$OUT/Chromium.app/$FRAMEWORK_REL/Versions/$VERSION" ]] || die "framework version $VERSION missing"

# 1. Public headers + module map in a private include dir (C-ABI.md: "Expose the two
#    public headers and module map in an include directory").
INCLUDE="$SCRATCH/include"
mkdir -p "$INCLUDE"
for header in rearc_engine_abi.h rearc_engine_entry_mac.h module.modulemap; do
  cp "$BRIDGE/$header" "$INCLUDE/$header"
done

# 2. Build with the Chromium module enabled, in its own scratch path so the
#    WebKit-only .build cache is never mixed with it.
export REARC_CHROMIUM_OUT="$OUT" REARC_ENGINE_INCLUDE="$INCLUDE"
SWIFT_ARGS=(--package-path "$SHELL_DIR" --scratch-path "$SCRATCH" -c "$CONFIG" --product rearc)
if [[ $BUILD == 1 ]]; then
  echo "==> swift build (${CONFIG}, Chromium ${VERSION})"
  swift build "${SWIFT_ARGS[@]}"
fi
BIN="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)/rearc"
[[ -x "$BIN" ]] || die "missing build product $BIN"

# 3. App bundle: physical (APFS clone) copy of the upstream app so helper bundles,
#    Info.plists, LSUIElement, entitlements and framework-relative paths are preserved.
APP="$DIST/ReArc.app"
echo "==> assembling $APP"
rm -rf "$DIST"
mkdir -p "$DIST"
cp -cR "$OUT/Chromium.app" "$APP"
rm -f "$APP/Contents/MacOS/Chromium"
cp "$BIN" "$APP/Contents/MacOS/ReArc"
# SwiftPM resource bundles (the onboarding voice) go in Contents/Resources, where the code
# looks for them; at the bundle root they would break the signature's seal.
for res in "$(dirname "$BIN")"/*.bundle; do
  [[ -d $res ]] && cp -R "$res" "$APP/Contents/Resources/"
done
# SwiftPM provides the pinned binary artifact for Chromium builds in both configurations.
SPARKLE="$(dirname "$BIN")/Sparkle.framework"
[[ -d $SPARKLE ]] || SPARKLE="$(find "$SCRATCH/artifacts" -type d -name Sparkle.framework -print -quit)"
[[ -d $SPARKLE ]] || die "Sparkle.framework missing from SwiftPM artifacts"
cp -R "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
PLIST="$APP/Contents/Info.plist"
if [[ $CONFIG == release ]]; then
  plutil -replace ReArcRelease -bool YES "$PLIST"
  plutil -replace SUFeedURL -string "${REARC_APPCAST_URL:-https://rearc.imara.ae/updates/appcast.xml}" "$PLIST"
  plutil -replace SUPublicEDKey -string "$(tr -d '[:space:]' <"$SHELL_DIR/scripts/release/sparkle-public-key.txt")" "$PLIST"
  for key in SUEnableAutomaticChecks SUAllowsAutomaticUpdates SUAutomaticallyUpdate SURequireSignedFeed SUVerifyUpdateBeforeExtraction; do
    plutil -replace "$key" -bool YES "$PLIST"
  done
  plutil -replace SUScheduledCheckInterval -integer 86400 "$PLIST"
else
  plutil -remove ReArcRelease "$PLIST" 2>/dev/null || true
fi

plutil -replace CFBundleExecutable -string ReArc "$PLIST"
plutil -replace CFBundleName -string ReArc "$PLIST"
plutil -replace CFBundleDisplayName -string ReArc "$PLIST"
# Match Package.swift so generated appcasts cannot offer this shell to older macOS.
plutil -replace LSMinimumSystemVersion -string 14.0.0 "$PLIST"
# The principal class stays Chromium's BrowserCrApplication, whose +initialize needs the
# command line only ChromeMain sets up, so this bundle must never start the WebKit path.
# Launches without an engine choice (Finder, the Dock, `open`, links from other apps)
# read this key; LSEnvironment would cover LaunchServices launches only.
plutil -replace ReArcDefaultEngine -string chromium "$PLIST"
# A browser: LaunchServices offers it as the default for web links, and other apps'
# http/https links arrive as GetURL Apple Events (ExternalLinkRouter). Set explicitly so
# the bundle never depends on what the engine's own plist declares.
plutil -replace CFBundleURLTypes -json \
  '[{"CFBundleURLName":"Web site URL","CFBundleTypeRole":"Viewer","CFBundleURLSchemes":["http","https"]}]' "$PLIST"
# Usage strings macOS shows when a page the user allowed asks for the camera, microphone
# or location (TCC). Without them the request is denied silently.
plutil -replace NSCameraUsageDescription -string "A website you allowed wants to use your camera." "$PLIST"
plutil -replace NSMicrophoneUsageDescription -string "A website you allowed wants to use your microphone." "$PLIST"
plutil -replace NSLocationUsageDescription -string "A website you allowed wants to know your location." "$PLIST"
plutil -replace NSLocationWhenInUseUsageDescription -string "A website you allowed wants to know your location." "$PLIST"
# The ReArc icon instead of Chromium's. CFBundleIconName (the AppIcon in Assets.car) wins
# over CFBundleIconFile on macOS, so it is removed; Assets.car itself stays for its other
# assets. Before signing, so the seal covers the icon and Info.plist.
cp "$SHELL_DIR/Resources/ReArc.icns" "$APP/Contents/Resources/ReArc.icns"
# Settings › Icon's alternates (AppIconChoice), sealed with the rest.
rm -rf "$APP/Contents/Resources/AppIcons"
cp -R "$SHELL_DIR/Resources/AppIcons" "$APP/Contents/Resources/AppIcons"
# About ReArc's sting (media/out/deliver/rearc-sting-path, 720 px, plays once).
cp "$SHELL_DIR/Resources/AboutSting.gif" "$APP/Contents/Resources/AboutSting.gif"
plutil -replace CFBundleIconFile -string ReArc "$PLIST"
plutil -remove CFBundleIconName "$PLIST" 2>/dev/null || true
if [[ $DEV_MOCK_KEYCHAIN == 1 ]]; then
  plutil -replace ReArcDevUseMockKeychain -bool YES "$PLIST"
  echo "==> DEVELOPMENT bundle: --use-mock-keychain enabled (cookies are not Keychain-encrypted)"
fi
# Only the replaced browser executable is re-signed; it is the process that reads the
# "ReArc Safe Storage" Keychain item. Nested framework/helper code keeps the engine
# build's signatures. Ad-hoc: the identity changes on every build, so macOS may ask again
# for Safe Storage access. With REARC_SIGN_IDENTITY the designated requirement (bundle id
# + certificate) is stable, so one "Always Allow" survives rebuilds. Distribution still
# needs a Developer ID identity, hardened runtime, full nested signing and notarization.
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$PLIST")"
if [[ -n $REARC_ICLOUD_CONTAINER ]]; then
  # Restricted entitlements: profile, marker and entitlements first, then the whole
  # bundle is signed so its seal covers Info.plist and embedded.provisionprofile.
  ENTITLEMENTS="$SCRATCH/ReArc.icloud.entitlements"
  icloud_prepare "$APP" "$BUNDLE_ID" "${REARC_PROVISIONING_PROFILE:-}" "$SHELL_DIR/scripts/ReArc.entitlements" "$ENTITLEMENTS"
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none \
    --entitlements "$ENTITLEMENTS" "$APP"
  actual_team="$(codesign -dv "$APP/Contents/MacOS/ReArc" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ $actual_team == "$TEAM_ID" ]] || die "signed with team '$actual_team', expected REARC_TEAM_ID=$TEAM_ID"
  icloud_verify "$APP/Contents/MacOS/ReArc"
  echo "==> signed ReArc.app with iCloud: $SIGN_IDENTITY (team $TEAM_ID, id $BUNDLE_ID)"
elif [[ -n $SIGN_IDENTITY ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none \
    --entitlements "$SHELL_DIR/scripts/ReArc.entitlements" "$APP/Contents/MacOS/ReArc"
  if [[ -n $TEAM_ID ]]; then
    actual_team="$(codesign -dv "$APP/Contents/MacOS/ReArc" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ $actual_team == "$TEAM_ID" ]] || die "signed with team '$actual_team', expected REARC_TEAM_ID=$TEAM_ID"
  fi
  echo "==> signed ReArc executable: $SIGN_IDENTITY (team ${TEAM_ID:-unchecked}, id $BUNDLE_ID)"
else
  codesign --force --sign - --entitlements "$SHELL_DIR/scripts/ReArc.entitlements" "$APP/Contents/MacOS/ReArc" 2>/dev/null
  echo "==> ad-hoc signed ReArc executable (set REARC_SIGN_IDENTITY for a stable signature)"
fi

# 4. Dylib closure next to the app (where the framework's rpath points), component builds only.
count=0
if [[ $COMPONENT == 1 ]]; then
  for lib in "$OUT"/*.dylib; do
    name="$(basename "$lib")"
    if [[ $DYLIB_MODE == copy ]]; then cp -c "$lib" "$DIST/$name"; else ln -s "$lib" "$DIST/$name"; fi
    count=$((count + 1))
  done
  echo "==> ${DYLIB_MODE} ${count} dylibs into $DIST"
else
  echo "==> monolithic engine build: no dylib closure outside the bundle"
fi

# 5. Verify every @rpath dependency of the executable, framework and closure resolves.
FW_VERSION_DIR="$APP/$FRAMEWORK_REL/Versions/$VERSION"
missing=0
check_deps() {
  local image="$1"
  while read -r dep; do
    case "$dep" in
      @rpath/Chromium\ Framework.framework/*) [[ -e "$APP/Contents/Frameworks/${dep#@rpath/}" ]] || { echo "unresolved $dep (from $image)"; missing=1; } ;;
      @rpath/Sparkle.framework/*) [[ -e "$APP/Contents/Frameworks/${dep#@rpath/}" ]] || { echo "unresolved $dep (from $image)"; missing=1; } ;;
      @rpath/*) local leaf="${dep#@rpath/}"
        [[ -e "$DIST/$leaf" || -e "$FW_VERSION_DIR/Libraries/$leaf" ]] || { echo "unresolved $dep (from $image)"; missing=1; } ;;
    esac
  done < <(otool -L "$image" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility.*$//')
}
check_deps "$APP/Contents/MacOS/ReArc"
check_deps "$FW_VERSION_DIR/Chromium Framework"
for lib in "$DIST"/*.dylib "$FW_VERSION_DIR/Libraries"/*.dylib; do [[ -e $lib ]] && check_deps "$lib"; done
[[ $missing == 0 ]] || die "dylib closure incomplete"
echo "==> dylib closure resolves (executable, framework, ${count} dylibs)"

cat <<EOF

ReArc.app (Chromium ${VERSION}) assembled:
  $APP
Run the Chromium engine:
  "$APP/Contents/MacOS/ReArc" --rearc-engine=chromium      (or REARC_ENGINE=chromium)
Run the self-test:
  "$APP/Contents/MacOS/ReArc" --rearc-selftest
EOF

if [[ $LAUNCH_CHECK == 1 ]]; then
  "$SHELL_DIR/scripts/check-launch.sh" "$APP"
fi

if [[ $SELFTEST == 1 ]]; then
  if [[ $DEV_MOCK_KEYCHAIN == 1 ]]; then
    LOG="$SHELL_DIR/selftest-chromium-mockkeychain.log"
  else
    LOG="$SHELL_DIR/selftest-chromium.log"
  fi
  PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/rearc-selftest-profile.XXXXXX")"
  echo "==> self-test (log: $LOG)"
  set +e
  # LSEnvironment's MallocNanoZone=0 only applies to LaunchServices launches.
  # Debug engines' test-only client-certificate store reads net/data (ABI 1.41; mock keychain runs only).
  CERTS="$REPO/engine/chromium/src/net/data/ssl/certificates"
  if [[ $DEV_MOCK_KEYCHAIN == 1 && -f "$CERTS/client_root_ca.pem" ]]; then
    export REARC_SELFTEST_CLIENT_CERT_DIR="$CERTS"
  fi
  REARC_RELEASE_VERIFICATION=1 MallocNanoZone=0 "$APP/Contents/MacOS/ReArc" --rearc-selftest --user-data-dir="$PROFILE" >"$LOG" 2>&1
  status=$?
  set -e
  echo "exit status: $status" >>"$LOG"
  grep -E "^\[selftest|SELFTEST|ABI-GAP|^\[ReArc/Chromium\]" "$LOG" || true
  echo "==> self-test exit status $status"
  exit "$status"
fi
