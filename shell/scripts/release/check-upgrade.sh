#!/usr/bin/env bash
# Upgrade check: a profile made by the previous release must open in the new build.
#
# Build 602 passed every other check and aborted at launch on every profile an earlier build
# had made: its engine no longer had a feature the old engine had recorded in the profile.
# The launch check and the self-test use fresh profiles, so only an upgrade shows this.
#
# Usage: scripts/release/check-upgrade.sh NEW_APP PREVIOUS_APP [PROFILE_DIR ...]
#   PREVIOUS_APP makes a profile first (launched in the background on a throwaway data
#   directory, left to settle, then quit). NEW_APP then opens a copy of that profile, and of
#   each extra PROFILE_DIR (saved data directories of older builds), and must stay up for
#   REARC_UPGRADE_SECONDS (default 45) without a new ReArc crash report.
#   Pass "-" as PREVIOUS_APP to test only the PROFILE_DIRs.
# Nothing takes the keyboard focus (`open -g`). The user's own data is never opened.
#
# NEW_APP must be the bundle release.sh is verifying (ReArcReleaseVerification in its signed
# Info.plist): a shipped bundle refuses REARC_DATA_DIR (security RC-0.1.0-602 T-04). Builds up
# to 605 honour REARC_DATA_DIR as shipped; a later shipped PREVIOUS_APP is copied, given the
# verification key and signed again with the release identity (sign-release.sh, or
# REARC_UPGRADE_SIGN), and the copy makes the profile.
set -euo pipefail

die() { echo "check-upgrade: $*" >&2; exit 1; }
[[ $# -ge 2 ]] || die "usage: check-upgrade.sh NEW_APP PREVIOUS_APP|- [PROFILE_DIR ...]"
NEW="$(cd "$1" && pwd)"; PREVIOUS="$2"; shift 2
[[ -x "$NEW/Contents/MacOS/ReArc" ]] || die "no ReArc.app at $NEW"
SETTLE="${REARC_UPGRADE_SETTLE_SECONDS:-40}"
STAY="${REARC_UPGRADE_SECONDS:-45}"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
SIGN="${REARC_UPGRADE_SIGN:-$(cd "$(dirname "$0")/.." && pwd)/sign-release.sh}"
# A release bundle without the verification key: it starts only on the person's own data.
shipped() {
  [[ "$(plutil -extract ReArcRelease raw "$1/Contents/Info.plist" 2>/dev/null || true)" == true \
    && "$(plutil -extract ReArcReleaseVerification raw "$1/Contents/Info.plist" 2>/dev/null || true)" != true ]]
}
shipped "$NEW" && die "$NEW is a shipped release bundle, which refuses REARC_DATA_DIR; run this on the bundle release.sh is verifying"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rearc-upgrade.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
crashes() { ls "$REPORTS" 2>/dev/null | grep -c '^ReArc-' || true; }

# A data directory with a sidebar is an existing install: no first-run onboarding.
seed() {
  mkdir -p "$1"
  cat >"$1/sidebar.json" <<'JSON'
{"version":1,"spaces":[],"profiles":[]}
JSON
}

# Launches APP on DATA in the background and prints its pid ("" when it never appeared).
launch() {
  local app="$1" data="$2" pid="" i
  open -n -g "$app" --env REARC_DATA_DIR="$data" --env REARC_RELEASE_VERIFICATION=1
  for i in $(seq 1 20); do
    pid="$(pgrep -f "$app/Contents/MacOS/ReArc" | head -1 || true)"
    [[ -n $pid ]] && break
    sleep 0.5
  done
  echo "$pid"
}

quit() {
  local pid="$1" i
  kill -TERM "$pid" 2>/dev/null || return 0
  for i in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.5; done
  kill -KILL "$pid" 2>/dev/null || true
}

PROFILES=()
if [[ $PREVIOUS != - ]]; then
  PREVIOUS="$(cd "$PREVIOUS" && pwd)"
  [[ -x "$PREVIOUS/Contents/MacOS/ReArc" ]] || die "no ReArc.app at $PREVIOUS"
  if shipped "$PREVIOUS" && [[ "$(plutil -extract CFBundleVersion raw "$PREVIOUS/Contents/Info.plist" 2>/dev/null || echo 0)" -gt 605 ]]; then
    echo "check-upgrade: $PREVIOUS refuses REARC_DATA_DIR; making a verification copy of it"
    mkdir -p "$WORK/previous-app"
    cp -Rc "$PREVIOUS" "$WORK/previous-app/ReArc.app" 2>/dev/null || cp -R "$PREVIOUS" "$WORK/previous-app/ReArc.app"
    PREVIOUS="$WORK/previous-app/ReArc.app"
    plutil -insert ReArcReleaseVerification -bool true "$PREVIOUS/Contents/Info.plist"
    "$SIGN" "$PREVIOUS" >"$WORK/sign-previous.log" 2>&1 || die "signing the verification copy failed (log $WORK/sign-previous.log)"
  fi
  made="$WORK/previous"
  seed "$made"
  echo "check-upgrade: making a profile with $(plutil -extract CFBundleVersion raw "$PREVIOUS/Contents/Info.plist") ($PREVIOUS), ${SETTLE}s"
  pid="$(launch "$PREVIOUS" "$made")"
  [[ -n $pid ]] || die "the previous release did not start"
  sleep "$SETTLE"
  kill -0 "$pid" 2>/dev/null || die "the previous release exited while making the profile"
  quit "$pid"
  [[ -d "$made/Chromium" ]] || die "the previous release wrote no Chromium profile under $made"
  PROFILES+=("$made")
fi
for extra in "$@"; do
  [[ -d "$extra" ]] || die "no profile directory at $extra"
  PROFILES+=("$extra")
done
[[ ${#PROFILES[@]} -gt 0 ]] || die "nothing to test: give a previous app or a profile directory"

failed=0
n=0
for profile in "${PROFILES[@]}"; do
  n=$((n + 1))
  copy="$WORK/open-$n"
  cp -Rc "$profile" "$copy" 2>/dev/null || cp -R "$profile" "$copy"
  before="$(crashes)"
  pid="$(launch "$NEW" "$copy")"
  alive=0
  if [[ -n $pid ]]; then
    alive=1
    for _ in $(seq 1 "$STAY"); do
      sleep 1
      kill -0 "$pid" 2>/dev/null || { alive=0; break; }
    done
  fi
  [[ $alive == 1 ]] && quit "$pid"
  sleep 2
  after="$(crashes)"
  if [[ $alive == 1 && $after == "$before" ]]; then
    echo "check-upgrade: PASS: $profile opened and stayed up ${STAY}s"
  else
    echo "check-upgrade: FAIL: $profile (stayed up: $alive, new crash reports: $((after - before)))" >&2
    failed=1
  fi
done
exit "$failed"
