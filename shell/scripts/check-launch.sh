#!/usr/bin/env bash
# Launches the Chromium bundle the way Finder, the Dock and other apps do (LaunchServices,
# through `open`), with no engine argument and no REARC_ENGINE, and checks that it reaches
# `ready` on the Chromium path. Two launches: plain, and with a link (the GetURL Apple
# Event other apps send). Each runs `--rearc-launch-probe` on a throwaway profile and never
# builds the sidebar, so the user's data is untouched; `-n` starts a separate instance, so
# a ReArc that is already running is left alone.
#
# Usage: scripts/check-launch.sh [path/to/ReArc.app]   (default: dist/chromium/ReArc.app)
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(cd "$(dirname "${1:-$SHELL_DIR/dist/chromium/ReArc.app}")" && pwd)/$(basename "${1:-ReArc.app}")"
[[ -d $APP ]] || { echo "check-launch: no bundle at $APP" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rearc-launch-check.XXXXXX")"
LINK="http://127.0.0.1:9/rearc-launch-check"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
crashes() { ls "$REPORTS" 2>/dev/null | grep -c '^ReArc-' || true; }
before="$(crashes)"
failed=0

probe() {
  local name="$1"; shift
  local result="$WORK/$name.txt" log="$WORK/$name.log"
  # `open -W` returns when the app exits; the probe quits by itself after ready.
  open -n -W -a "$APP" --stderr "$log" --stdout "$log" "$@" \
    --args --rearc-launch-probe="$result" --user-data-dir="$WORK/profile-$name" &
  local opener=$! waited=0
  while kill -0 "$opener" 2>/dev/null && (( waited < 120 )); do sleep 1; waited=$((waited + 1)); done
  if kill -0 "$opener" 2>/dev/null; then
    echo "check-launch: $name: still running after ${waited}s (log $log)" >&2
    failed=1
    return
  fi
  wait "$opener" || true
  local line; line="$(cat "$result" 2>/dev/null || true)"
  echo "check-launch: $name: ${line:-no probe result} (log $log)"
  [[ $line == *"ready=1 engine=chromium source=infoPlist"* ]] || failed=1
  if [[ $name == link && $line != *"links=$LINK"* ]]; then
    echo "check-launch: link: the GetURL event did not reach the Chromium path" >&2
    failed=1
  fi
}

probe plain
probe link "$LINK"
after="$(crashes)"
if [[ $after != "$before" ]]; then
  echo "check-launch: new ReArc crash report(s) in $REPORTS" >&2
  failed=1
fi
if [[ $failed == 0 ]]; then
  echo "check-launch: PASS ($APP)"
else
  echo "check-launch: FAIL ($APP)" >&2
fi
exit "$failed"
