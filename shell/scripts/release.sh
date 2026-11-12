#!/usr/bin/env bash
# Builds a release ReArc.app end to end from an already-built release engine
# (scripts/build-engine-release.sh): release shell build, bundle, version stamp, nested
# hardened-runtime signing (scripts/sign-release.sh), dSYMs, then verification: a
# LaunchServices launch to ready (scripts/check-launch.sh) and the self-test against the real
# Keychain. Optionally a signed DMG (scripts/make-dmg.sh). Notarization is opt-in (--notarize).
# The gates run on the bundle signed with ReArcReleaseVerification in its Info.plist, the only
# release bundle that takes a throwaway data dir, self-test or launch probe; the key is then
# removed and the bundle signed again, so what ships has none of those (RC-0.1.0-602 T-04, F-03).
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
#   --critical        mark the new appcast entry a critical update (requires --appcast)
#   --required-below N  mark it required for builds below N, at most this build (requires
#                     --appcast). Both: engine/docs/RELEASE.md, "Critical and required updates"
#   --notarize        notarize app before DMG and DMG before appcast (opt-in)
#   --dmg             also make the signed DMG
#   --allow-outdated-engine  override the Mac Stable/Extended security release gate
#   --previous-app PATH  the ReArc.app of the release now on the feed; a DMG needs it for the
#                     upgrade check (scripts/release/check-upgrade.sh). Also REARC_PREVIOUS_RELEASE_APP.
#   --allow-no-upgrade-check  make a DMG without the upgrade check (recorded as an override)
#   --allow-no-safe-browsing  make a DMG from an engine without a real Google API key, and
#                     skip the live list-download check (Safe Browsing may not work; warns
#                     loudly). See RELEASE.md.
#   --selftest-timeout SECONDS  watchdog for the self-test (default 300)
#   --qa              keep the verification mode in the bundle, for test launches on a throwaway
#                     REARC_DATA_DIR (a shipped bundle refuses them); never distributed, so no
#                     --dmg, --appcast or --notarize
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
ALLOW_NO_UPGRADE_CHECK=0
PREVIOUS_APP="${REARC_PREVIOUS_RELEASE_APP:-}"
APPCAST=""
CHANNEL=""
CRITICAL=0
REQUIRED_BELOW=""
NOTARIZE=0
SELFTEST_TIMEOUT=300
LAUNCH_RETRIED=0
QA=0
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
    --allow-no-upgrade-check) ALLOW_NO_UPGRADE_CHECK=1 ;;
    --previous-app) PREVIOUS_APP="$(cd "$2" && pwd)"; shift ;;
    --appcast) mkdir -p "$2"; APPCAST="$(cd "$2" && pwd)"; DMG=1; shift ;;
    --channel) CHANNEL="$2"; [[ $CHANNEL == beta ]] || die "only --channel beta is supported"; shift ;;
    --critical) CRITICAL=1 ;;
    --required-below) REQUIRED_BELOW="$2"; [[ $REQUIRED_BELOW =~ ^[1-9][0-9]{0,8}$ ]] || die "--required-below needs a build number"; shift ;;
    --notarize) NOTARIZE=1 ;;
    --selftest-timeout) SELFTEST_TIMEOUT="$2"; shift ;;
    --qa) QA=1 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[[ -z $CHANNEL || -n $APPCAST ]] || die "--channel requires --appcast DIR"
[[ $CRITICAL == 0 && -z $REQUIRED_BELOW || -n $APPCAST ]] || die "--critical and --required-below require --appcast DIR"
[[ $QA == 0 || ( $DMG == 0 && $NOTARIZE == 0 ) ]] || die "--qa makes a test bundle that is never distributed: no --dmg, --appcast or --notarize"
# A feed is published only from a fully gated run (security RC-0.1.0-544 N-04).
OVERRIDES=()
[[ $ALLOW_OUTDATED_ENGINE == 0 ]] || OVERRIDES+=(allow-outdated-engine)
[[ $ALLOW_NO_SAFE_BROWSING == 0 ]] || OVERRIDES+=(allow-no-safe-browsing)
[[ $ALLOW_NO_UPGRADE_CHECK == 0 ]] || OVERRIDES+=(allow-no-upgrade-check)
[[ $VERIFY == 1 ]] || OVERRIDES+=(no-verify)
[[ -z $APPCAST || ${#OVERRIDES[@]} == 0 ]] || die "--appcast refuses a build with gate overrides (${OVERRIDES[*]}); make it without them"
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
  # The engine must run with the feature set existing profiles were written under: Chromium's
  # field-trial testing config, as builds 500 to 564 and 608 had (RELEASE.md, "Engine build").
  grep -q 'BUILDFLAG_INTERNAL_FIELDTRIAL_TESTING_ENABLED() (1)' "$OUT/gen/components/variations/service/buildflags.h" 2>/dev/null \
    || die "the release engine was built without Chromium's field-trial testing config, which changes storage formats under existing profiles; rebuild it (scripts/build-engine-release.sh)"
  # The header is what the build asked for; the framework is what ships (RC-0.1.0-602 T-11).
  python3 -I "$SHELL_DIR/scripts/release/check-fieldtrial-binary.py" \
    "$OUT/Chromium.app/Contents/Frameworks/Chromium Framework.framework/Chromium Framework" \
    "$REPO/engine/chromium/src/testing/variations/fieldtrial_testing_config.json" \
    || die "the release engine binary lacks Chromium's field-trial testing config, which changes storage formats under existing profiles; rebuild it (scripts/build-engine-release.sh)"
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
# Checked before the build: builds from this one on must not count as required.
[[ -z $REQUIRED_BELOW ]] || (( REQUIRED_BELOW <= BUILD_NUMBER )) \
  || die "--required-below $REQUIRED_BELOW is above this build ($BUILD_NUMBER)"
ENGINE_VERSION="$(plutil -extract CFBundleShortVersionString raw "$OUT/Chromium.app/Contents/Info.plist")"
OVERLAY="$(git -C "$REPO/engine/chromium/src" rev-parse HEAD)"
plutil -replace CFBundleShortVersionString -string "$MARKETING" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
plutil -replace ReArcEngineVersion -string "$ENGINE_VERSION" "$PLIST"
plutil -replace ReArcSourceRevision -string "$REVISION$SUFFIX" "$PLIST"
plutil -replace ReArcEngineRevision -string "$OVERLAY" "$PLIST"
# Verification mode for the gates below only; step 5c removes it before anything ships.
plutil -remove ReArcReleaseVerification "$PLIST" 2>/dev/null || true
VERIFICATION_BUNDLE=0
if [[ $VERIFY == 1 || $DMG == 1 || $QA == 1 ]]; then
  plutil -insert ReArcReleaseVerification -bool true "$PLIST"
  VERIFICATION_BUNDLE=1
fi
# The gates this build skipped, inside the signed bundle, so a DMG made with an override can
# be told from a gated one (N-04). Absent when nothing was skipped.
plutil -remove ReArcReleaseGateOverrides "$PLIST" 2>/dev/null || true
if [[ ${#OVERRIDES[@]} -gt 0 ]]; then
  plutil -insert ReArcReleaseGateOverrides -array "$PLIST"
  for override in "${OVERRIDES[@]}"; do plutil -insert ReArcReleaseGateOverrides -string "$override" -append "$PLIST"; done
  echo "==> WARNING: gate overrides recorded in Info.plist ReArcReleaseGateOverrides: ${OVERRIDES[*]}" >&2
fi
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
  # system assesses the new code; one retry tells that apart from a real failure. Only that
  # failure (status 2: both probes ready, then the watchdog) is retried, and the crash-report
  # baseline is taken once, so a crash in the first attempt still fails (RC-0.1.0-564 S-10).
  CRASH_BASELINE="$DIST/crash-baseline.txt"
  rm -f "$CRASH_BASELINE"
  launch_check() {
    set +e
    "$SHELL_DIR/scripts/check-launch.sh" --crash-baseline "$CRASH_BASELINE" "$APP" 2>&1 | tee -a "$DIST/check-launch.log"
    local status=${PIPESTATUS[0]}
    set -e
    return "$status"
  }
  : >"$DIST/check-launch.log"
  launch_status=0
  launch_check || launch_status=$?
  if [[ $launch_status == 2 ]]; then
    echo "==> launch check: teardown watchdog only; RETRYING once" | tee -a "$DIST/check-launch.log"
    LAUNCH_RETRIED=1
    launch_status=0
    launch_check || launch_status=$?
  fi
  [[ $launch_status == 0 ]] || die "launch check failed (log $DIST/check-launch.log)"
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
#     Runs for every DMG, --no-verify included; only --allow-no-safe-browsing skips it. It checks
#     that the phishing and malware lists are stored, not that a warning page shows (T-11).
if [[ $DMG == 1 ]]; then
  if [[ $ALLOW_NO_SAFE_BROWSING == 1 ]]; then
    echo "==> WARNING: --allow-no-safe-browsing: Safe Browsing list downloads were NOT checked" >&2
  else
    "$SHELL_DIR/scripts/release/check-safe-browsing-lists.sh" "$APP" 2>&1 | tee "$DIST/check-safe-browsing-lists.log" \
      || die "Safe Browsing stored no phishing and malware lists (log $DIST/check-safe-browsing-lists.log); pass --allow-no-safe-browsing only for a build that is not distributed"
  fi
fi

# 5c. Upgrade check: a profile made by the previous release must open in this build. Build 602
#     passed everything above and aborted at launch on every existing profile.
if [[ $DMG == 1 ]]; then
  if [[ $ALLOW_NO_UPGRADE_CHECK == 1 ]]; then
    echo "==> WARNING: --allow-no-upgrade-check: opening a previous release's profile was NOT checked" >&2
  else
    [[ -n $PREVIOUS_APP && -d $PREVIOUS_APP ]] \
      || die "a DMG needs --previous-app PATH (the ReArc.app of the release now on the feed) for the upgrade check, or --allow-no-upgrade-check for a build that is not distributed"
    # REARC_UPGRADE_PROFILES: extra saved data directories of older builds, colon-separated.
    IFS=: read -r -a upgrade_profiles <<<"${REARC_UPGRADE_PROFILES:-}"
    "$SHELL_DIR/scripts/release/check-upgrade.sh" "$APP" "$PREVIOUS_APP" ${upgrade_profiles[@]+"${upgrade_profiles[@]}"} 2>&1 \
      | tee "$DIST/check-upgrade.log" || die "the upgrade check failed (log $DIST/check-upgrade.log)"
    # Opening is not enough: 605 opened every older profile and read its site data as empty.
    "$SHELL_DIR/scripts/release/check-upgrade-data.py" "$PREVIOUS_APP" "$APP" 2>&1 \
      | tee "$DIST/check-upgrade-data.log" || die "stored site data did not survive the upgrade (log $DIST/check-upgrade-data.log)"
    # REARC_UPGRADE_DATA_PROFILES: data directories saved with check-upgrade-data.py --keep
    # (for example a chain that ran 605), colon-separated; this build must read back what each
    # chain stored last.
    IFS=: read -r -a data_profiles <<<"${REARC_UPGRADE_DATA_PROFILES:-}"
    n=0
    for profile in ${data_profiles[@]+"${data_profiles[@]}"}; do
      n=$((n + 1))
      "$SHELL_DIR/scripts/release/check-upgrade-data.py" --profile "$profile" "$APP" 2>&1 \
        | tee "$DIST/check-upgrade-data-$n.log" || die "stored site data in $profile did not survive the upgrade (log $DIST/check-upgrade-data-$n.log)"
    done
  fi
fi

# 5d. The shipped bundle: without the verification key, signed again (Info.plist is sealed by
#     the signature). Its code is the code the gates ran; it takes no REARC_DATA_DIR,
#     --user-data-dir, self-test or launch probe (RC-0.1.0-602 T-04, F-03).
if [[ $QA == 1 ]]; then
  echo "==> --qa: the bundle keeps its verification mode; it takes REARC_DATA_DIR and must never be distributed" >&2
elif [[ $VERIFICATION_BUNDLE == 1 ]]; then
  plutil -remove ReArcReleaseVerification "$PLIST"
  echo "==> removing verification mode and signing the shipped bundle again"
  "$SHELL_DIR/scripts/sign-release.sh" "$APP" 2>&1 | tee "$DIST/sign-release-shipped.log"
fi
if [[ $QA == 0 ]] && plutil -extract ReArcReleaseVerification raw "$PLIST" >/dev/null 2>&1; then
  die "the bundle still has ReArcReleaseVerification; it must never ship"
fi

# 6. Optional notarization, DMG and local appcast. Never uploads.
if [[ $NOTARIZE == 1 ]]; then "$SHELL_DIR/scripts/notarize.sh" "$APP"; fi
if [[ $DMG == 1 ]]; then
  "$SHELL_DIR/scripts/make-dmg.sh" "$APP"
fi

if [[ $NOTARIZE == 1 && $DMG == 1 ]]; then
  "$SHELL_DIR/scripts/notarize.sh" "$DIST/ReArc-$MARKETING-$BUILD_NUMBER.dmg"
fi
if [[ -n $APPCAST ]]; then
  cp "$DIST/ReArc-$MARKETING-$BUILD_NUMBER.dmg" "$APPCAST/ReArc-$MARKETING-$BUILD_NUMBER.dmg"
  levels=(--version "$BUILD_NUMBER")
  [[ $CRITICAL == 0 ]] || levels+=(--critical)
  [[ -z $REQUIRED_BELOW ]] || levels+=(--required-below "$REQUIRED_BELOW")
  "$SHELL_DIR/scripts/release/generate-appcast.sh" "$APPCAST" "$CHANNEL" "${levels[@]}"
fi

# Summary: what this run did not check in full (overrides are also in Info.plist).
[[ ${#OVERRIDES[@]} == 0 ]] || echo "==> NOTE: gate overrides: ${OVERRIDES[*]} (Info.plist ReArcReleaseGateOverrides)"
[[ $LAUNCH_RETRIED == 0 ]] || echo "==> NOTE: the launch check was RETRIED after a teardown-watchdog failure"
