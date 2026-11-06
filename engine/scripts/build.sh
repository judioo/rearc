#!/usr/bin/env bash
# Build the stock-named framework, bundled helpers and runnable Chromium baseline.
# Usage: build.sh [--release] [--target-cpu=arm64|x64] [--jobs=N]
# --release is an optimized non-component development build, not a shipping build.
set -euo pipefail
ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROMIUM_SRC="$ENGINE_DIR/chromium/src"
DEPOT_TOOLS="${REARC_DEPOT_TOOLS:-$ENGINE_DIR/depot_tools}"
export PATH="$DEPOT_TOOLS:$PATH"
export DEPOT_TOOLS_UPDATE=0
unset FORCE_MAC_TOOLCHAIN
CONFIG=dev
TARGET_CPU="$(uname -m)"
[[ "$TARGET_CPU" != x86_64 ]] || TARGET_CPU=x64
BUILD_COMMAND=(autoninja)
die() { printf 'build.sh: error: %s\n' "$*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) CONFIG=release ;;
    --target-cpu=arm64|--target-cpu=x64) TARGET_CPU="${1#*=}" ;;
    --jobs=*) jobs="${1#*=}"; [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die 'invalid jobs'; BUILD_COMMAND+=("-j" "$jobs") ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
[[ "$(uname -s)" == Darwin ]] || die 'requires macOS'
[[ "$TARGET_CPU" == arm64 || "$TARGET_CPU" == x64 ]] || die 'unsupported CPU'
[[ -f "$ENGINE_DIR/chromium/.rearc-hooks-complete" ]] || die 'run fetch.sh, then fetch.sh --runhooks first'
xcodebuild -checkFirstLaunchStatus || die 'complete Xcode setup/agreements'
xcrun --sdk macosx --show-sdk-path >/dev/null || die 'macOS SDK missing'
cd "$CHROMIUM_SRC"
PIN="$(awk '!/^[[:space:]]*(#|$)/ {v=$0} END {gsub(/[[:space:]]/, "", v); print v}' "$ENGINE_DIR/CHROMIUM_PIN")"
BASE="$(git rev-parse "refs/tags/$PIN^{commit}")"
[[ "$(cat ../.rearc-hooks-complete)" == "$BASE" ]] || die 'hooks marker does not match pin'
git merge-base --is-ancestor "$BASE" HEAD || die 'HEAD does not descend from pin'
SOURCE_VERSION="$(git show "$BASE:chrome/VERSION" | awk -F= '{v=v sep $2; sep="."} END {print v}')"
[[ "$SOURCE_VERSION" == "$PIN" ]] || die 'unexpected chrome/VERSION'
OUT_DIR="out/ReArc-$CONFIG-$TARGET_CPU"
GN_ARGS=(
  'target_os="mac"' "target_cpu=\"$TARGET_CPU\""
  'is_chrome_branded=false' 'is_official_build=false'
  'use_system_xcode=true' 'use_remoteexec=false' 'use_siso=true'
  'chrome_pgo_phase=0' 'symbol_level=1' 'treat_warnings_as_errors=false'
)
if [[ "$CONFIG" == dev ]]; then
  GN_ARGS+=('is_debug=true' 'is_component_build=true')
else
  GN_ARGS+=('is_debug=false' 'is_component_build=false')
fi
printf '=== gn gen %s ===\nargs: %s\n' "$OUT_DIR" "${GN_ARGS[*]}"
gn gen "$OUT_DIR" --fail-on-unused-args --args="${GN_ARGS[*]}"
# chrome_framework owns chrome_framework_helpers: all eight helper variants,
# crashpad handler, app loader and resources. chrome supplies the runnable app.
TARGETS=(chrome_framework chrome)
"${BUILD_COMMAND[@]}" -C "$OUT_DIR" "${TARGETS[@]}"
FRAMEWORK="$CHROMIUM_SRC/$OUT_DIR/Chromium Framework.framework"
[[ -d "$FRAMEWORK/Versions/$PIN/Helpers" ]] || die 'expected pinned framework layout missing; inspect GN outputs'
printf '\nBuild completed: %s/%s\nFramework: %s\nHelpers: %s/Versions/%s/Helpers\n' "$CHROMIUM_SRC" "$OUT_DIR" "$FRAMEWORK" "$FRAMEWORK" "$PIN"
printf 'Keep the entire output directory: component dylibs also live outside the framework.\nNo ReArc ABI, branding, standalone packaging, signing or runtime validation is implied.\n'
