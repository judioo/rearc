#!/usr/bin/env bash
# Builds the optimized, non-component ReArc engine used by release bundles, in its own
# output dir (default engine/chromium/src/out/ReArc-release-<cpu>). Never touches the dev
# output dir or any engine source. Same preflight as engine/scripts/build.sh, plus the
# release-only GN arguments that script's fixed argument set cannot carry (docs:
# engine/docs/RELEASE.md, "Engine build"):
#   dcheck_always_on=false   non-official Chromium builds default DCHECKs on
#   enable_dsyms=true        Chromium Framework.dSYM etc. for symbolicating crash reports
#   enable_stripping=true    strip the shipped binaries (symbols live in the dSYMs)
#   branding_file_path       shell/scripts/release/BRANDING (the dev BRANDING) plus your
#                            MAC_TEAM_ID (PACKAGING-MAC.md requires it for production),
#                            written to .build-release/BRANDING at build time
# The Team ID is never committed: REARC_TEAM_ID comes from the environment or the
# git-ignored shell/signing.local.env.
# Not is_official_build: see RELEASE.md (ThinLTO/PGO cost, no Google-only behavior needed).
#
# Usage: scripts/build-engine-release.sh [--target-cpu=arm64|x64] [--jobs=N] [--gen-only]
#   REARC_RELEASE_OUT  output dir relative to engine/chromium/src (default out/ReArc-release-<cpu>)
#   REARC_TEAM_ID      your ten-character Apple Team ID (or set it in shell/signing.local.env)
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$SHELL_DIR/.." && pwd)"
ENGINE_DIR="$REPO/engine"
CHROMIUM_SRC="$ENGINE_DIR/chromium/src"
BRANDING="$SHELL_DIR/scripts/release/BRANDING"
export PATH="${REARC_DEPOT_TOOLS:-$ENGINE_DIR/depot_tools}:$PATH"
export DEPOT_TOOLS_UPDATE=0
unset FORCE_MAC_TOOLCHAIN
TARGET_CPU="$(uname -m)"
[[ "$TARGET_CPU" != x86_64 ]] || TARGET_CPU=x64
BUILD_COMMAND=(autoninja)
GEN_ONLY=0

die() { printf 'build-engine-release: error: %s\n' "$*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-cpu=arm64|--target-cpu=x64) TARGET_CPU="${1#*=}" ;;
    --jobs=*) jobs="${1#*=}"; [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die 'invalid jobs'; BUILD_COMMAND+=("-j" "$jobs") ;;
    --gen-only) GEN_ONLY=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
OUT_DIR="${REARC_RELEASE_OUT:-out/ReArc-release-$TARGET_CPU}"
[[ "$OUT_DIR" != out/ReArc-dev-* ]] || die "refusing to write the dev output dir $OUT_DIR"

[[ "$(uname -s)" == Darwin ]] || die 'requires macOS'
[[ -f "$ENGINE_DIR/chromium/.rearc-hooks-complete" ]] || die 'run engine/scripts/fetch.sh, then fetch.sh --runhooks first'
[[ -f "$BRANDING" ]] || die "missing $BRANDING"
team="${REARC_TEAM_ID:-}"
if [[ -z "$team" && -f "$SHELL_DIR/signing.local.env" ]]; then
  team="$(sed -n 's/^REARC_TEAM_ID="\{0,1\}\([A-Z0-9]*\)"\{0,1\}$/\1/p' "$SHELL_DIR/signing.local.env" | tail -1)"
fi
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || die "set REARC_TEAM_ID (environment or shell/signing.local.env) to your ten-character Team ID"
! grep -q '^MAC_TEAM_ID=' "$BRANDING" || die "$BRANDING must not carry a MAC_TEAM_ID; set REARC_TEAM_ID instead"
GENERATED_BRANDING="$SHELL_DIR/.build-release/BRANDING"
mkdir -p "$(dirname "$GENERATED_BRANDING")"
{ cat "$BRANDING"; printf 'MAC_TEAM_ID=%s\n' "$team"; } > "$GENERATED_BRANDING"
bundle_id="$(sed -n 's/^MAC_BUNDLE_ID=//p' "$BRANDING")"
dev_bundle_id="$(sed -n 's/^MAC_BUNDLE_ID=//p' "$CHROMIUM_SRC/chrome/app/theme/chromium/BRANDING")"
[[ "$bundle_id" == "$dev_bundle_id" ]] || die "release MAC_BUNDLE_ID $bundle_id differs from the overlay's $dev_bundle_id"
xcodebuild -checkFirstLaunchStatus || die 'complete Xcode setup/agreements'
xcrun --sdk macosx --show-sdk-path >/dev/null || die 'macOS SDK missing'

cd "$CHROMIUM_SRC"
PIN="$(awk '!/^[[:space:]]*(#|$)/ {v=$0} END {gsub(/[[:space:]]/, "", v); print v}' "$ENGINE_DIR/CHROMIUM_PIN")"
BASE="$(git rev-parse "refs/tags/$PIN^{commit}")"
[[ "$(cat ../.rearc-hooks-complete)" == "$BASE" ]] || die 'hooks marker does not match pin'
git merge-base --is-ancestor "$BASE" HEAD || die 'HEAD does not descend from pin'
SOURCE_VERSION="$(git show "$BASE:chrome/VERSION" | awk -F= '{v=v sep $2; sep="."} END {print v}')"
[[ "$SOURCE_VERSION" == "$PIN" ]] || die 'unexpected chrome/VERSION'

GN_ARGS=(
  'target_os="mac"' "target_cpu=\"$TARGET_CPU\""
  'is_chrome_branded=false' 'is_official_build=false'
  'use_system_xcode=true' 'use_remoteexec=false' 'use_siso=true'
  'chrome_pgo_phase=0' 'symbol_level=1' 'treat_warnings_as_errors=false'
  'generate_about_credits=true'
  'is_debug=false' 'is_component_build=false' 'dcheck_always_on=false'
  'enable_dsyms=true' 'enable_stripping=true'
  "branding_file_path=\"$GENERATED_BRANDING\""
)
printf '=== gn gen %s (overlay %s) ===\nargs: %s\n' "$OUT_DIR" "$(git rev-parse --short=10 HEAD)" "${GN_ARGS[*]}"
gn gen "$OUT_DIR" --fail-on-unused-args --args="${GN_ARGS[*]}"
[[ $GEN_ONLY == 0 ]] || exit 0
"${BUILD_COMMAND[@]}" -C "$OUT_DIR" chrome_framework chrome
FRAMEWORK="$CHROMIUM_SRC/$OUT_DIR/Chromium Framework.framework"
[[ -d "$FRAMEWORK/Versions/$PIN/Helpers" ]] || die 'expected pinned framework layout missing'
[[ ! -e "$CHROMIUM_SRC/$OUT_DIR/libchrome_dll.dylib" ]] || die 'component output found; expected a monolithic framework'
# A monolithic framework exports only chrome/app/framework.exports; every ABI function the
# headers declare must be in it (tab/060), or the shell fails to link.
missing="$(comm -23 \
  <(grep -ohE '\bReArc[A-Za-z0-9_]+[[:space:]]*\(' chrome/browser/rearc_bridge/rearc_engine_abi.h \
      chrome/browser/rearc_bridge/rearc_engine_entry_mac.h | sed -E 's/[[:space:](]//g; s/^/_/' | sort -u) \
  <(nm -gU "$FRAMEWORK/Versions/$PIN/Chromium Framework" | awk '{print $3}' | sort -u))"
[[ -z "$missing" ]] || die "framework does not export these ABI functions (add them to chrome/app/framework.exports and framework.order): $(tr '\n' ' ' <<<"$missing")"
printf '\nRelease engine built: %s/%s (overlay %s)\n' "$CHROMIUM_SRC" "$OUT_DIR" "$(git rev-parse HEAD)"
