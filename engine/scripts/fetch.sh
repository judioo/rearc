#!/usr/bin/env bash
# Sync only by default. Hooks and overlay application are explicit later stages.
# Usage: fetch.sh [--sync | --runhooks | --apply-overlay]
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROMIUM_ROOT="$ENGINE_DIR/chromium"
DEPOT_TOOLS="${REARC_DEPOT_TOOLS:-$ENGINE_DIR/depot_tools}"
SRC_URL="https://chromium.googlesource.com/chromium/src.git"
MODE="${1:---sync}"
log() { printf '\n=== %s | %s ===\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { printf 'fetch.sh: error: %s\n' "$*" >&2; exit 1; }
[[ $# -le 1 ]] || die 'expected at most one stage argument'
case "$MODE" in --sync|--runhooks|--apply-overlay) ;; *) die "unknown stage: $MODE" ;; esac
PIN="$(awk '!/^[[:space:]]*(#|$)/ {v=$0} END {gsub(/[[:space:]]/, "", v); print v}' "$ENGINE_DIR/CHROMIUM_PIN")"
[[ "$PIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'invalid CHROMIUM_PIN'
[[ "$(uname -s)" == Darwin ]] || die 'requires macOS'
xcode-select -p >/dev/null || die 'install full Xcode and select its Developer directory'
if [[ "$MODE" != --sync ]]; then
  xcodebuild -checkFirstLaunchStatus || die 'complete Xcode first-launch setup/agreements before hooks/build (sync can proceed without them)'
fi
xcrun --sdk macosx --show-sdk-path >/dev/null || die 'macOS SDK missing'

[[ -x "$DEPOT_TOOLS/gclient" ]] || die "install depot_tools at $DEPOT_TOOLS first (see docs/FETCH-STATUS.md)"
export PATH="$DEPOT_TOOLS:$PATH"
export DEPOT_TOOLS_UPDATE=0
export GIT_TERMINAL_PROMPT=0
export PYTHONUNBUFFERED=1
# Public Chromium uses system Xcode; do not request Google's internal toolchain.
unset FORCE_MAC_TOOLCHAIN
log "Chromium $PIN; stage $MODE; depot_tools $(git -C "$DEPOT_TOOLS" rev-parse HEAD)"

mkdir -p "$CHROMIUM_ROOT"
cd "$CHROMIUM_ROOT"
# Atomic directory lock also prevents accidentally running two resumptions.
mkdir .rearc-fetch.lock 2>/dev/null || die "another stage may be running; inspect $CHROMIUM_ROOT/.rearc-fetch.lock/pid before removing a stale lock"
printf '%s\n' "$$" > .rearc-fetch.lock/pid
trap 'rm -f "$CHROMIUM_ROOT/.rearc-fetch.lock/pid"; rmdir "$CHROMIUM_ROOT/.rearc-fetch.lock" 2>/dev/null || true' EXIT

if [[ "$MODE" == --sync ]]; then
  # Compare rather than replace a configuration that might belong to someone else.
  cat > .gclient.rearc-expected <<'GCLIENT'
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {"checkout_pgo_profiles": False},
  },
]
target_os = ["mac"]
target_os_only = True
GCLIENT
  if [[ -f .gclient ]]; then
    cmp -s .gclient .gclient.rearc-expected || die '.gclient differs from the engine configuration; inspect it manually'
    rm .gclient.rearc-expected
  else
    mv .gclient.rearc-expected .gclient
  fi
  if [[ ! -d src/.git ]]; then
    [[ ! -e src ]] || die 'src exists without its own .git; refusing to adopt it'
    mkdir src
    git -C src init
    git -C src remote add origin "$SRC_URL"
  fi
  [[ "$(git -C src remote get-url origin)" == "$SRC_URL" ]] || die 'unexpected src origin'
  git -C src diff --quiet && git -C src diff --cached --quiet || die 'src has tracked changes; preserve/resolve them before syncing'
  if git -C src rev-parse --verify HEAD >/dev/null 2>&1; then
    EXPECTED="$(git -C src rev-parse --verify "refs/tags/$PIN^{commit}")" || die 'existing checkout has no pinned tag; rebase manually'
    [[ "$(git -C src rev-parse HEAD)" == "$EXPECTED" ]] || die 'src HEAD differs from the pin (possibly an overlay); rebase manually'
  else
    log "Shallow fetch of refs/tags/$PIN (large download; progress below)"
    git -C src fetch --progress --no-tags --depth=1 origin "refs/tags/$PIN:refs/tags/$PIN"
    git -C src checkout --detach "refs/tags/$PIN"
  fi
  REVISION="$(git -C src rev-parse HEAD)"
  log "gclient sync at $REVISION; shallow dependencies; hooks deferred"
  gclient sync --nohooks --no-history --revision "src@$REVISION" --jobs=8
  [[ "$(git -C src rev-parse HEAD)" == "$REVISION" ]] || die 'sync changed src HEAD'
  printf '%s\n' "$REVISION" > .rearc-sync-complete
  log 'Sync complete. Next: engine/scripts/fetch.sh --runhooks, then --apply-overlay, then engine/scripts/build.sh'
  exit 0
fi

[[ -f .rearc-sync-complete && -d src/.git ]] || die 'no completed sync; run fetch.sh first'
BASE="$(cat .rearc-sync-complete)"
[[ "$(git -C src rev-parse "refs/tags/$PIN^{commit}")" == "$BASE" ]] || die 'pin changed; sync/rebase manually'
[[ "$(git -C src rev-parse HEAD)" == "$BASE" ]] || die 'HEAD differs from synced base; preserve local commits and rebase manually'
git -C src diff --quiet && git -C src diff --cached --quiet || die 'src has tracked changes'

if [[ "$MODE" == --runhooks ]]; then
  log 'gclient runhooks (public tools and local Xcode)'
  gclient runhooks
  printf '%s\n' "$BASE" > .rearc-hooks-complete
  log 'Hooks complete. Next: engine/scripts/fetch.sh --apply-overlay'
  exit 0
fi

[[ -f .rearc-hooks-complete && "$(cat .rearc-hooks-complete)" == "$BASE" ]] || die 'run --runhooks first'
cd src
# Stage additive paths explicitly; never sweep checkout/dependency files with add -A.
if [[ -d "$ENGINE_DIR/overlay" ]]; then
  while IFS= read -r -d '' file; do
    rel="${file#"$ENGINE_DIR/overlay/"}"
    if git ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || [[ -e "$rel" || -L "$rel" ]]; then
      die "overlay collides with existing path: $rel"
    fi
    mkdir -p "$(dirname "$rel")"
    cp "$file" "$rel"
    git add -- "$rel"
  done < <(find "$ENGINE_DIR/overlay" -type f -print0)
fi
applied=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$line" ]] || continue
  [[ "$line" != /* && "$line" != *..* ]] || die "invalid series path: $line"
  patch="$ENGINE_DIR/patches/$line"
  [[ -f "$patch" ]] || die "missing patch: $patch"
  git apply --3way --index "$patch" || die "patch failed: $line; resolve the index manually; do not rerun sync over it"
  applied=$((applied + 1))
done < "$ENGINE_DIR/patches/series"
if ! git diff --cached --quiet; then
  git -c user.name='ReArc Overlay' -c user.email='rearc-overlay@localhost' commit -m "rearc overlay @ $PIN"
fi
log "Applied $applied patches. Empty series means stock Chromium, with no ReArc bridge or lifecycle implementation."
