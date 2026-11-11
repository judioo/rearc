#!/usr/bin/env bash
# Builds a release ReArc.app end to end from an already-built release engine
# (scripts/build-engine-release.sh): release shell build, bundle, version stamp, nested
# hardened-runtime signing (scripts/sign-release.sh), dSYMs, then verification: a
# LaunchServices launch to ready (scripts/check-launch.sh) and the self-test against the real
# Keychain. Optionally a signed DMG (scripts/make-dmg.sh). Notarization is opt-in (--notarize).
# Docs: engine/docs/RELEASE.md.
#
# Usage: scripts/release.sh [--engine-out DIR] [--dist DIR] [--worktree] [--no-verify] [--dmg]
#   --engine-out DIR  release engine output (default engine/chromium/src/out/ReArc-release-arm64)
#   --dist DIR        output (default shell/dist/release): ReArc.app, symbols/, logs, the DMG
#   --worktree        build the shell from the working tree instead of the committed HEAD;
#                     the version is then marked "-dirty" when shell/ has local changes
#   --no-verify       skip the launch check and self-test
#   --appcast DIR     make DMG and generate signed appcast locally in DIR (no upload)
#   --channel beta    tag new appcast entries beta (requires --appcast)
#   --notarize        notarize app before DMG and DMG before appcast (opt-in)
#   --dmg             also make the signed DMG
#   --allow-outdated-engine  override the Mac Stable/Extended security release gate
#   --allow-no-safe-browsing  make a DMG from an engine without a real Google API key, and
#                     skip the live list-download check (Safe Browsing may not work; warns
#                     loudly). See RELEASE.md.
#   --selftest-timeout SECONDS  watchdog for the self-test (default 300)
# Signing settings: see sign-release.sh (REARC_RELEASE_IDENTITY, REARC_TEAM_ID, iCloud).
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$SHELL_DIR/.." && pwd)"
LIVE_SHELL="$SHELL_DIR"
OUT="$REPO/engine/chromium/src/out/ReArc-release-arm64"
DIST="$SHELL_DIR/dist/release"
FROM_HEAD=1
VERIFY=1
DMG=0
ALLOW_OUTDATED_ENGINE=0
ALLOW_NO_SAFE_BROWSING=0
APPCAST=""
CHANNEL=""
NOTARIZE=0
SELFTEST_TIMEOUT=300
die() { echo "release: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine-out) OUT="$(cd "$2" && pwd)"; shift ;;
    --dist) mkdir -p "$2"; DIST="$(cd "$2" && pwd)"; shift ;;
    --worktree) FROM_HEAD=0 ;;
    --no-verify) VERIFY=0 ;;
    --dmg) DMG=1 ;;
    --allow-outdated-engine) ALLOW_OUTDATED_ENGINE=1 ;;
    --allow-no-safe-browsing) ALLOW_NO_SAFE_BROWSING=1 ;;
    --appcast) mkdir -p "$2"; APPCAST="$(cd "$2" && pwd)"; DMG=1; shift ;;
    --channel) CHANNEL="$2"; [[ $CHANNEL == beta ]] || die "only --channel beta is supported"; shift ;;
    --notarize) NOTARIZE=1 ;;
    --selftest-timeout) SELFTEST_TIMEOUT="$2"; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[[ -z $CHANNEL || -n $APPCAST ]] || die "--channel requires --appcast DIR"
[[ -z $APPCAST || $APPCAST != "$DIST" && $APPCAST != "$DIST/"* ]] || die "appcast archives must live outside the dist directory (which is replaced)"
[[ $DIST != "$SHELL_DIR/dist/icloud"* && $DIST != "$SHELL_DIR/dist/chromium"* ]] \
  || die "refusing to write $DIST (development bundles live there)"
[[ -d "$OUT/Chromium.app" ]] || die "no release engine at $OUT (scripts/build-engine-release.sh)"
[[ ! -e "$OUT/libchrome_dll.dylib" ]] || die "$OUT is a component (dev) build"
if [[ $DMG == 1 ]]; then
  # ${a[@]+...}: an empty array is "unbound" under set -u in macOS bash 3.2.
  pin_gate=()
  [[ $ALLOW_OUTDATED_ENGINE == 0 ]] || pin_gate+=(--allow-outdated-engine)
  python3 "$REPO/engine/scripts/check-release-pin.py" ${pin_gate[@]+"${pin_gate[@]}"}
  # Safe Browsing needs a real Google API key in the engine (RELEASE.md, "Safe Browsing key").
  key_gate=()
  [[ $ALLOW_NO_SAFE_BROWSING == 0 ]] || key_gate+=(--allow-no-safe-browsing)
  python3 "$REPO/engine/scripts/google-api-keys.py" check "$OUT" ${key_gate[@]+"${key_gate[@]}"} \
    || die "the release engine has no real Google API key, so Safe Browsing cannot work; rebuild it with the key (RELEASE.md) or pass --allow-no-safe-browsing"
  # The engine must not run Chromium's field-trial testing config (RELEASE.md, "Engine build").
  grep -q 'BUILDFLAG_INTERNAL_FIELDTRIAL_TESTING_ENABLED() (0)' "$OUT/gen/components/variations/service/buildflags.h" 2>/dev/null \
    || die "the release engine was built with Chromium's field-trial testing config; rebuild it with disable_fieldtrial_testing_config=true (scripts/build-engine-release.sh)"
  pinned="$(awk '!/^[[:space:]]*(#|$)/ {v=$0} END {print v}' "$REPO/engine/CHROMIUM_PIN")"
  built="$(plutil -extract CFBundleShortVersionString raw "$OUT/Chromium.app/Contents/Info.plist")"
  [[ "$built" == "$pinned" ]] || die "engine output $built does not match CHROMIUM_PIN $pinned; rebuild the release engine"
fi

# shellcheck source=release/signing-env.sh
source "$SHELL_DIR/scripts/release/signing-env.sh"
load_signing_env "$SHELL_DIR"
[[ -n "$(release_identity)" ]] || die "no signing identity (REARC_RELEASE_IDENTITY or REARC_SIGN_IDENTITY)"

# 1. Source: the committed shell/ at HEAD, so uncommitted work never ships. The stage keeps
#    unchanged files' timestamps (rsync --checksum), so the release build stays incremental.
REVISION="$(git -C "$REPO" rev-parse HEAD)"
# A distributable build needs its entry in the committed RELEASES.md (RELEASE.md, "Release notes").
if [[ $DMG == 1 ]]; then
  marketing="$(tr -d '[:space:]' <"$LIVE_SHELL/scripts/release/VERSION")"
  build="$(git -C "$REPO" rev-list --count "$REVISION")"
  git -C "$REPO" show "$REVISION:RELEASES.md" 2>/dev/null | grep -qF "## ReArc $marketing ($build)" \
    || die "RELEASES.md at HEAD has no \"## ReArc $marketing ($build) — <date>\" entry; commit the release notes first"
fi
SUFFIX=""
if [[ $FROM_HEAD == 1 ]]; then
  STAGE="${REARC_RELEASE_STAGE:-$SHELL_DIR/dist/.release-src}"
  EXPORT="$(mktemp -d "${TMPDIR:-/tmp}/rearc-release-export.XXXXXX")"
  git -C "$REPO" archive HEAD shell | tar -x -C "$EXPORT"
  mkdir -p "$STAGE/shell"
  rsync -rlp --checksum --delete --exclude /.build-chromium/ "$EXPORT/shell/" "$STAGE/shell/"
  rm -rf "$EXPORT"
  ln -sfn "$REPO/engine" "$STAGE/engine"
  SHELL_DIR="$STAGE/shell"
  echo "==> shell source: HEAD ${REVISION:0:10} (staged in $STAGE)"
else
  [[ -z "$(git -C "$REPO" status --porcelain -- shell)" ]] || SUFFIX="-dirty"
  echo "==> shell source: working tree at ${REVISION:0:10}${SUFFIX}"
fi

# 2. Release shell build + bundle. iCloud entitlements are added by sign-release.sh, which
#    signs every code object again; the bundle step only signs the executable.
START=$SECONDS
REARC_ICLOUD_CONTAINER="" "$SHELL_DIR/scripts/bundle-chromium.sh" --release --engine-out "$OUT" --dist "$DIST"
APP="$DIST/ReArc.app"
PLIST="$APP/Contents/Info.plist"

# 3. Version stamp (RELEASE.md, "Versioning"). The engine framework keeps its own version.
MARKETING="$(tr -d '[:space:]' <"$LIVE_SHELL/scripts/release/VERSION")"
[[ $MARKETING =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "scripts/release/VERSION must be MAJOR.MINOR.PATCH"
BUILD_NUMBER="$(git -C "$REPO" rev-list --count "$REVISION")"
ENGINE_VERSION="$(plutil -extract CFBundleShortVersionString raw "$OUT/Chromium.app/Contents/Info.plist")"
OVERLAY="$(git -C "$REPO/engine/chromium/src" rev-parse HEAD)"
plutil -replace CFBundleShortVersionString -string "$MARKETING" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
plutil -replace ReArcEngineVersion -string "$ENGINE_VERSION" "$PLIST"
plutil -replace ReArcSourceRevision -string "$REVISION$SUFFIX" "$PLIST"
plutil -replace ReArcEngineRevision -string "$OVERLAY" "$PLIST"
echo "==> version $MARKETING ($BUILD_NUMBER), engine Chromium $ENGINE_VERSION overlay ${OVERLAY:0:10}"

# 4. Sign (inside-out, hardened runtime, timestamps), then keep the symbols.
"$SHELL_DIR/scripts/sign-release.sh" "$APP" 2>&1 | tee "$DIST/sign-release.log"
# Only the dSYMs of code that ships (the out dir also has host build tools'), plus the shell's.
mkdir -p "$DIST/symbols"
FW_DIR="$APP/Contents/Frameworks/Chromium Framework.framework/Versions/$ENGINE_VERSION"
for shipped in "$FW_DIR/Chromium Framework" "$FW_DIR/Libraries/"*.dylib "$FW_DIR/Helpers/"*; do
  dsym="$OUT/$(basename "$shipped" .app).dSYM"
  [[ -e $dsym ]] && cp -cR "$dsym" "$DIST/symbols/"
done
SHELL_DSYM="$(swift build --package-path "$SHELL_DIR" --scratch-path "${REARC_SHELL_SCRATCH:-$SHELL_DIR/.build-chromium}" -c release --show-bin-path)/rearc.dSYM"
[[ -e $SHELL_DSYM ]] && cp -cR "$SHELL_DSYM" "$DIST/symbols/ReArc.dSYM"
echo "==> $(find "$DIST/symbols" -maxdepth 1 -name '*.dSYM' | wc -l | tr -d ' ') dSYMs in $DIST/symbols"
echo "==> bundle ready in $((SECONDS - START))s: $APP ($(du -sh "$APP" | cut -f1))"

# 5. Verification: LaunchServices launch to ready, then the self-test on the real Keychain
#    (no --use-mock-keychain; release shells ignore the dev marker anyway).
if [[ $VERIFY == 1 ]]; then
  # The first launch of a freshly signed copy can outlast the teardown watchdog while the
  # system assesses the new code; one retry tells that apart from a real failure.
  "$SHELL_DIR/scripts/check-launch.sh" "$APP" 2>&1 | tee "$DIST/check-launch.log" \
    || { echo "==> launch check failed; retrying once"; "$SHELL_DIR/scripts/check-launch.sh" "$APP" 2>&1 | tee -a "$DIST/check-launch.log"; } \
    || die "launch check failed twice"
  LOG="$DIST/selftest-release.log"
  PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/rearc-release-selftest.XXXXXX")"
  echo "==> self-test, real Keychain (log: $LOG, watchdog ${SELFTEST_TIMEOUT}s)"
  t0=$SECONDS
  REARC_RELEASE_VERIFICATION=1 MallocNanoZone=0 "$APP/Contents/MacOS/ReArc" --rearc-selftest --user-data-dir="$PROFILE" >"$LOG" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && (( SECONDS - t0 < SELFTEST_TIMEOUT )); do sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    # A stall here is most likely a Keychain authorization prompt for "ReArc Safe Storage".
    sample "$pid" 5 -file "$DIST/selftest-stall-sample.txt" >/dev/null 2>&1 || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    die "self-test still running after ${SELFTEST_TIMEOUT}s (Keychain prompt?); sample in $DIST/selftest-stall-sample.txt"
  fi
  set +e; wait "$pid"; status=$?; set -e
  echo "exit status: $status (${SECONDS}s total, $((SECONDS - t0))s self-test)" >>"$LOG"
  grep -E "^\[selftest|SELFTEST|ABI-GAP" "$LOG" | tail -n 20 || true
  [[ $status == 0 ]] || die "self-test failed with status $status (log $LOG)"
  echo "==> self-test passed in $((SECONDS - t0))s"
fi

# 5b. Safe Browsing must actually download its lists (security RC-0.1.0-544 F-02): a key that
#     is present but refused, or a list protocol Google does not serve, ships silent otherwise.
#     Runs for every DMG, --no-verify included; only --allow-no-safe-browsing skips it.
if [[ $DMG == 1 ]]; then
  if [[ $ALLOW_NO_SAFE_BROWSING == 1 ]]; then
    echo "==> WARNING: --allow-no-safe-browsing: Safe Browsing list downloads were NOT checked" >&2
  else
    "$SHELL_DIR/scripts/release/check-safe-browsing.sh" "$APP" 2>&1 | tee "$DIST/check-safe-browsing.log" \
      || die "Safe Browsing stored no lists (log $DIST/check-safe-browsing.log); pass --allow-no-safe-browsing only for a build that is not distributed"
  fi
fi

# 6. Optional notarization, DMG and local appcast. Never uploads.
if [[ $NOTARIZE == 1 ]]; then "$SHELL_DIR/scripts/notarize.sh" "$APP"; fi
if [[ $DMG == 1 ]]; then
  "$SHELL_DIR/scripts/make-dmg.sh" "$APP"
fi

if [[ $NOTARIZE == 1 && $DMG == 1 ]]; then
  "$SHELL_DIR/scripts/notarize.sh" "$DIST/ReArc-$MARKETING.dmg"
fi
if [[ -n $APPCAST ]]; then
  # The versioned archive name prevents marketing-version repeats overwriting old builds.
  cp "$DIST/ReArc-$MARKETING.dmg" "$APPCAST/ReArc-$MARKETING-$BUILD_NUMBER.dmg"
  "$SHELL_DIR/scripts/release/generate-appcast.sh" "$APPCAST" "$CHANNEL"
fi
