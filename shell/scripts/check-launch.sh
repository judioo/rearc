#!/usr/bin/env bash
# Launches the Chromium bundle the way Finder, the Dock and other apps do (LaunchServices,
# through `open`), with no engine argument and no REARC_ENGINE, and checks that it reaches
# `ready` on the Chromium path. Two launches: plain, and with a link (the GetURL Apple
# Event other apps send). Each runs `--rearc-launch-probe` on a throwaway profile and never
# builds the sidebar, so the user's data is untouched; `-n` starts a separate instance, so
# a ReArc that is already running is left alone.
#
# Usage: scripts/check-launch.sh [--crash-baseline FILE] [path/to/ReArc.app]
#   (default bundle: dist/chromium/ReArc.app)
#   --crash-baseline FILE  crash reports that existed before; written when FILE is missing.
#                          release.sh takes it once, so a crash from a first attempt still
#                          fails a retry (security RC-0.1.0-564 S-10).
# Exit status: 0 pass; 2 when the only failure was the teardown watchdog after both probes
# reached ready (the one case release.sh retries); 1 for anything else.
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE=""
if [[ ${1:-} == --crash-baseline ]]; then BASELINE="${2:?--crash-baseline needs a file}"; shift 2; fi
APP="$(cd "$(dirname "${1:-$SHELL_DIR/dist/chromium/ReArc.app}")" && pwd)/$(basename "${1:-ReArc.app}")"
[[ -d $APP ]] || { echo "check-launch: no bundle at $APP" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rearc-launch-check.XXXXXX")"
LINK="http://127.0.0.1:9/rearc-launch-check"
REPORTS="${REARC_CRASH_REPORTS:-$HOME/Library/Logs/DiagnosticReports}"
# The app and its helpers (which keep Chromium's names) and crashpad.
reports() { ls "$REPORTS" 2>/dev/null | grep -E '^(ReArc|Chromium Helper|chrome_crashpad_handler)' || true; }
[[ -n $BASELINE ]] || BASELINE="$WORK/crash-baseline"
[[ -f $BASELINE ]] || reports >"$BASELINE"
failed=0
watchdog=0

probe() {
  local name="$1"; shift
  local result="$WORK/$name.txt" log="$WORK/$name.log"
  # The probe quits by itself after ready. `open -W` can keep waiting after the app
  # exited (first launch of a freshly signed copy), so the probe's own log decides.
  open -n -W --env REARC_RELEASE_VERIFICATION=1 -a "$APP" --stderr "$log" --stdout "$log" "$@" \
    --args --rearc-launch-probe="$result" --user-data-dir="$WORK/profile-$name" &
  local opener=$! waited=0
  while (( waited < 120 )); do
    grep -q "launch probe: ReArcEngineRun returned" "$log" 2>/dev/null && break
    kill -0 "$opener" 2>/dev/null || break
    sleep 1; waited=$((waited + 1))
  done
  if ! grep -q "launch probe: ReArcEngineRun returned 0, shutdown ok" "$log" 2>/dev/null; then
    echo "check-launch: $name: the probe did not shut down cleanly within ${waited}s (log $log)" >&2
    if grep -q "Teardown watchdog expired" "$log" 2>/dev/null; then
      # Seen 2026-11-10: a firewall holding the network service's sockets stalls its exit.
      echo "check-launch: $name: teardown watchdog fired; if a network filter (Little Snitch) is" \
        "asking about this copy's helpers, the network service cannot exit: see RELEASE.md" >&2
      watchdog=1
    else
      failed=1
    fi
  fi
  kill "$opener" 2>/dev/null || true
  wait "$opener" 2>/dev/null || true
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
# New reports since the baseline: ReArc's own, or a helper's from a ReArc.app (paths in
# reports are anonymised, but the bundle name stays).
while IFS= read -r report; do
  [[ -n $report ]] || continue
  if [[ $report == ReArc* ]] || grep -q 'ReArc\.app' "$REPORTS/$report" 2>/dev/null; then
    echo "check-launch: new crash report $REPORTS/$report" >&2
    failed=1
  fi
done < <(reports | grep -vxF -f "$BASELINE" || true)
if [[ $failed == 0 && $watchdog == 0 ]]; then
  echo "check-launch: PASS ($APP)"
  exit 0
fi
echo "check-launch: FAIL ($APP)" >&2
[[ $failed == 1 ]] && exit 1
exit 2
