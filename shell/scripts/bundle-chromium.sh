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
#   REARC_CHROMIUM_OUT  engine output dir (default: engine/chromium/src/out/ReArc-dev-arm64)
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$SHELL_DIR/.." && pwd)"
OUT="${REARC_CHROMIUM_OUT:-$REPO/engine/chromium/src/out/ReArc-dev-arm64}"
BRIDGE="$REPO/engine/chromium/src/chrome/browser/rearc_bridge"
SCRATCH="$SHELL_DIR/.build-chromium"
DIST="$SHELL_DIR/dist/chromium"
CONFIG=debug
DYLIB_MODE=symlink
BUILD=1
SELFTEST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) CONFIG=release ;;
    --copy-dylibs) DYLIB_MODE=copy ;;
    --dist) DIST="$2"; shift ;;
    --skip-build) BUILD=0 ;;
    --selftest) SELFTEST=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

die() { echo "bundle-chromium: $*" >&2; exit 1; }

[[ -d "$OUT/Chromium.app" ]] || die "no Chromium.app in $OUT (build the engine first; this script never does)"
[[ -f "$OUT/libchrome_dll.dylib" ]] || die "no libchrome_dll.dylib in $OUT (component build output expected)"
for header in rearc_engine_abi.h rearc_engine_entry_mac.h module.modulemap; do
  [[ -f "$BRIDGE/$header" ]] || die "missing $BRIDGE/$header"
done
# Same gate as engine/tests/run_c_abi.py: don't package a tree that is being rebuilt.
if pgrep -fl "siso ninja" >/dev/null 2>&1; then
  die "a Chromium build (siso ninja) is running; wait for it to finish"
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
PLIST="$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string ReArc "$PLIST"
plutil -replace CFBundleName -string ReArc "$PLIST"
plutil -replace CFBundleDisplayName -string ReArc "$PLIST"
codesign --force --sign - "$APP/Contents/MacOS/ReArc" 2>/dev/null

# 4. Dylib closure next to the app (where the framework's rpath points).
count=0
for lib in "$OUT"/*.dylib; do
  name="$(basename "$lib")"
  if [[ $DYLIB_MODE == copy ]]; then cp -c "$lib" "$DIST/$name"; else ln -s "$lib" "$DIST/$name"; fi
  count=$((count + 1))
done
echo "==> ${DYLIB_MODE} ${count} dylibs into $DIST"

# 5. Verify every @rpath dependency of the executable, framework and closure resolves.
FW_VERSION_DIR="$APP/$FRAMEWORK_REL/Versions/$VERSION"
missing=0
check_deps() {
  local image="$1"
  while read -r dep; do
    case "$dep" in
      @rpath/Chromium\ Framework.framework/*) [[ -e "$APP/Contents/Frameworks/${dep#@rpath/}" ]] || { echo "unresolved $dep (from $image)"; missing=1; } ;;
      @rpath/*) local leaf="${dep#@rpath/}"
        [[ -e "$DIST/$leaf" || -e "$FW_VERSION_DIR/Libraries/$leaf" ]] || { echo "unresolved $dep (from $image)"; missing=1; } ;;
    esac
  done < <(otool -L "$image" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility.*$//')
}
check_deps "$APP/Contents/MacOS/ReArc"
check_deps "$FW_VERSION_DIR/Chromium Framework"
for lib in "$DIST"/*.dylib; do check_deps "$lib"; done
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

if [[ $SELFTEST == 1 ]]; then
  LOG="$SHELL_DIR/selftest-chromium.log"
  PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/rearc-selftest-profile.XXXXXX")"
  echo "==> self-test (log: $LOG)"
  set +e
  # LSEnvironment's MallocNanoZone=0 only applies to LaunchServices launches.
  MallocNanoZone=0 "$APP/Contents/MacOS/ReArc" --rearc-selftest --user-data-dir="$PROFILE" >"$LOG" 2>&1
  status=$?
  set -e
  echo "exit status: $status" >>"$LOG"
  grep -E "^\[selftest|SELFTEST|ABI-GAP|^\[ReArc/Chromium\]" "$LOG" || true
  echo "==> self-test exit status $status"
  exit "$status"
fi
