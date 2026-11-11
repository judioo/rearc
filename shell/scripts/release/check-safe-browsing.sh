#!/usr/bin/env bash
# Release gate for Safe Browsing (security RC-0.1.0-544 F-02): launches a ReArc.app the way a
# user does (LaunchServices, `open -n -g`: a separate instance, never activated) on a throwaway
# data dir, waits for Chromium's first list update to store lists in
# <data>/Chromium/Safe Browsing/*.store, then quits that instance. Exits non-zero when no list
# arrives in time: a key Google refuses or a list protocol it does not serve (the 544/564
# failure) leaves the folder empty while Settings would say "on".
#
# The instance runs with --no-onboarding, its own REARC_DATA_DIR (so iCloud sync stays off) and
# networking on. A ReArc that is already running is left alone; only the launched process is
# signalled, found by its executable path and its data dir.
#
# Usage: scripts/release/check-safe-browsing.sh path/to/ReArc.app
#   REARC_SB_TIMEOUT  seconds to wait for lists (default 360; Chromium's first update runs
#                     60 to 300 s after launch)
#   REARC_SB_POLL     seconds between checks (default 5)
#   REARC_SB_LAUNCH_WAIT  seconds for the launched process to appear (default 60)
set -euo pipefail

die() { echo "check-safe-browsing: $*" >&2; exit 1; }
[[ $# == 1 ]] || die "usage: $0 path/to/ReArc.app"
[[ -d $1 ]] || die "no bundle at $1"
APP="$(cd "$1" && pwd)"
EXE="$APP/Contents/MacOS/ReArc"
[[ -x $EXE ]] || die "no executable at $EXE"
# A shipped release bundle ignores REARC_DATA_DIR, --user-data-dir and the verification modes
# (RC-0.1.0-602 T-04): launched here it would open the person's own profile. Only the bundle
# scripts/release.sh is verifying (ReArcReleaseVerification in its signed Info.plist) takes them.
plist="$APP/Contents/Info.plist"
if [[ "$(plutil -extract ReArcRelease raw "$plist" 2>/dev/null || true)" == true \
  && "$(plutil -extract ReArcReleaseVerification raw "$plist" 2>/dev/null || true)" != true ]]; then
  echo "check-safe-browsing: $APP is a shipped release bundle, which has no verification mode; run this on the bundle release.sh is verifying" >&2
  exit 1
fi
TIMEOUT="${REARC_SB_TIMEOUT:-360}"
POLL="${REARC_SB_POLL:-5}"
LAUNCH_WAIT="${REARC_SB_LAUNCH_WAIT:-60}"
DATA="$(mktemp -d "${TMPDIR:-/tmp}/rearc-safe-browsing.XXXXXX")"
PROFILE="$DATA/Chromium"
LISTS="$PROFILE/Safe Browsing"
LOG="$DATA/rearc.log"

# The launched instance's pid: its own executable, started with this run's data dir.
instance() {
  ps -axo pid=,command= | grep -F -- "$EXE" | grep -F -- "--user-data-dir=$PROFILE" \
    | awk 'NR == 1 { print $1 }'
}

# Non-empty list stores, as SafeBrowsingStatus counts them.
stores() {
  [[ -d $LISTS ]] || { echo 0; return; }
  find "$LISTS" -maxdepth 1 -type f -name '*.store' -size +0 | wc -l | tr -d ' '
}

pid=""
quit() {
  [[ -n $pid ]] || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  local waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < 60 )); do sleep 1; waited=$((waited + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    echo "check-safe-browsing: instance $pid did not quit within 60s; killing it" >&2
    kill -KILL "$pid" 2>/dev/null || true
  fi
  pid=""
}
trap quit EXIT

echo "check-safe-browsing: launching $APP (data $DATA, waiting up to ${TIMEOUT}s for lists)"
open -n -g --env REARC_DATA_DIR="$DATA" --stdout "$LOG" --stderr "$LOG" -a "$APP" \
  --args --no-onboarding --user-data-dir="$PROFILE"

waited=0
while [[ -z $pid ]] && (( waited < LAUNCH_WAIT )); do
  pid="$(instance)"
  [[ -n $pid ]] || { sleep 1; waited=$((waited + 1)); }
done
[[ -n $pid ]] || die "the launched instance did not appear within ${LAUNCH_WAIT}s (log $LOG)"

start=$SECONDS
count=0
while (( SECONDS - start < TIMEOUT )); do
  count="$(stores)"
  (( count > 0 )) && break
  kill -0 "$pid" 2>/dev/null || die "the instance exited before any list arrived (log $LOG)"
  sleep "$POLL"
done
elapsed=$((SECONDS - start))
quit

if (( count > 0 )); then
  echo "check-safe-browsing: PASS: $count list store(s) after ${elapsed}s"
  rm -rf "$DATA"
  exit 0
fi
echo "check-safe-browsing: FAIL: no Safe Browsing list stored after ${elapsed}s;" \
  "the engine's list updates are failing (data kept in $DATA, log $LOG)" >&2
exit 1
