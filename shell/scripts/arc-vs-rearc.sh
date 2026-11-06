#!/usr/bin/env bash
# Arc vs ReArc, timed from outside (docs/ARC-VS-REARC-BENCH.md): posts the same
# keys to real Arc and to ReArc and times each one's window pixels.
#
# Usage: scripts/arc-vs-rearc.sh [--dry-run] [--apps arc,rearc] [--scenarios LIST]
#          [--iterations N] [--warmups N] [--pause-ms MS] [--pre-quiet-ms MS] [--bundle APP]
#          [--out DIR] [--keep-frames DIR] [--restart-arc] [--arc-space NAME] [--arc-sidebar S]
#          [--channel-threshold N] [--area-threshold F] [--stride N] [--quiet-ms MS]
#          [--timeout-ms MS] [--region SCENARIO=REGION] [--sidebar-fraction F]
#          [--capture-scale F] [--lock-wait S] [--keep-data] [--no-match-size]
#          [--no-guards] [--no-build]
#
#   --dry-run       check only, safe while the user works: Screen Recording and
#                   Accessibility for the host process, the gate and lock, both
#                   apps and their windows, Arc's Demo space; print the plan. Posts
#                   no input, captures nothing, starts or activates no app.
#   --apps          arc,rearc (default both, in that order)
#   --scenarios     any of space_switch (⌃n and ⌥⌘←/→ there and back), tab_switch
#                   (⌘2/⌘1), tab_switcher (⌃Tab twice), sidebar_toggle (⌘S hide/show),
#                   new_tab (⌘T, Esc), open_location (⌘L, Esc), little_arc (⌥⌘N, ⌘W)
#   --iterations N  measured iterations per scenario (20); --warmups N first (3)
#   --pause-ms MS   pause before each key (600); --pre-quiet-ms MS the window must
#                   have been still this long before a key is posted (300)
#   --bundle APP    ReArc bundle (shell/dist/release/ReArc.app). It runs as a new
#                   instance on a throwaway REARC_DATA_DIR seeded with two spaces of
#                   five local pages; --keep-data keeps that directory
#   --out DIR       results (shell/bench/results/arc-vs-rearc-<UTC time>-<sha>/, git-ignored):
#                   results.json, results.md, rearc.log
#   --keep-frames DIR  also save the captured frames of the measured window as PNGs
#                   (target window only; default: no frames are saved)
#   --restart-arc   quit Arc (never forced) and start it again first. Without it Arc
#                   is never quit; it is started if it is not running
#   --arc-space NAME  Arc's space to run in (Demo), selected by ⌃n when it is one
#                   of the first nine, else by its Spaces menu item over Accessibility
#   --arc-sidebar S auto (default: the View menu's Show/Hide Sidebar title), visible or
#                   hidden: Arc's sidebar at the start. A hidden one is shown with ⌘S
#                   for the run (checked by its pixels) and hidden again at the end
#   --channel-threshold N  a pixel changed when a channel moved more than N (24)
#   --area-threshold F  a frame changed when more than F of the pixels did (0.002)
#   --stride N      compare every Nth pixel each way (2); --capture-scale F capture
#                   size as a fraction of the window's points (0.5)
#   --quiet-ms MS   settled: the change followed by MS without one (150)
#   --timeout-ms MS give up on a key after MS (3000)
#   --region SCENARIO=REGION  diff ack/settled in window (default), sidebar, content
#                   or x0,y0,x1,y1 (fractions of the window, origin top left)
#   --sidebar-fraction F  the sidebar column's share of the window width (0.22);
#                   *.content metrics diff x >= F
#   --lock-wait S   wait up to S seconds for the input lock (600)
#   --no-match-size leave ReArc's window size alone (default: set it to Arc's)
#   --no-guards     skip the load guards (bench.sh's; never for numbers you keep)
#   --no-build      use the last release build of the tool
#
# Refuses (exit 75) without the gate file ~/Library/Caches/rearc-input-allowed, with
# the screen locked, or when the input lock ~/Library/Caches/rearc-input.lock stays
# taken; exit 77 without Screen Recording or Accessibility. A real run also runs the
# load guards (see bench-guards.sh), takes the input lock for the whole run (removed
# on exit, errors and signals) and keeps the display awake with caffeinate -u.
# Capture is ScreenCaptureKit with a single-window filter on the target app's
# browser window: never the display, never another app. Frames stay in memory.
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$SHELL_DIR/.." && pwd)"
die() { echo "arc-vs-rearc: $*" >&2; exit 1; }
refuse() { echo "arc-vs-rearc: refusing to run: $*" >&2; exit 75; }

ARGS=()
DRY=0
GUARDS=1
BUILD=1
HAVE_OUT=0
HAVE_BUNDLE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) sed -n '2,59p' "$0"; exit 0 ;;
    --dry-run) DRY=1; ARGS+=("$1") ;;
    --no-guards) GUARDS=0 ;;
    --no-build) BUILD=0 ;;
    --restart-arc|--keep-data|--no-match-size) ARGS+=("$1") ;;
    --out) HAVE_OUT=1; [[ $# -ge 2 ]] || die "$1 needs a value"; ARGS+=("$1" "$2"); shift ;;
    --bundle) HAVE_BUNDLE=1; [[ $# -ge 2 ]] || die "$1 needs a value"; ARGS+=("$1" "$2"); shift ;;
    --*) [[ $# -ge 2 ]] || die "$1 needs a value"; ARGS+=("$1" "$2"); shift ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

BIN="$SHELL_DIR/.build/release/arc-vs-rearc"
if [[ $BUILD == 1 ]]; then
  BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/arc-vs-rearc-build.XXXXXX")"
  if ! swift build --package-path "$SHELL_DIR" -c release --product arc-vs-rearc >"$BUILD_LOG" 2>&1; then
    tail -n 40 "$BUILD_LOG" >&2
    die "build failed (full log $BUILD_LOG)"
  fi
  rm -f "$BUILD_LOG"
fi
[[ -x $BIN ]] || die "no $BIN (drop --no-build)"

REV="$(git -C "$REPO" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
[[ $HAVE_BUNDLE == 1 ]] || ARGS+=(--bundle "$SHELL_DIR/dist/release/ReArc.app")
[[ $HAVE_OUT == 1 ]] || ARGS+=(--out "$SHELL_DIR/bench/results/arc-vs-rearc-$(date -u +%Y-%m-%dT%H-%M-%SZ)-$REV")

if [[ $DRY == 1 ]]; then
  exec "$BIN" "${ARGS[@]}"
fi

[[ -e "$HOME/Library/Caches/rearc-input-allowed" ]] || refuse "no input gate ~/Library/Caches/rearc-input-allowed"
if [[ $GUARDS == 1 ]]; then
  source "$SHELL_DIR/scripts/bench-guards.sh"
  bench_guards
fi

CAFFEINATE=""
CHILD=""
cleanup() {
  [[ -z $CAFFEINATE ]] || kill "$CAFFEINATE" 2>/dev/null || true
}
forward() {
  # The tool releases the input lock and quits its ReArc on SIGTERM.
  [[ -z $CHILD ]] || kill -TERM "$CHILD" 2>/dev/null || true
}
trap cleanup EXIT
trap forward INT TERM HUP
# Without a lit display there are no frames to time.
caffeinate -u -d & CAFFEINATE=$!

set +e
REARC_REVISION="$REV" "$BIN" "${ARGS[@]}" & CHILD=$!
wait "$CHILD"; STATUS=$?
# A trapped signal interrupts the first wait; wait again for the tool's cleanup.
if kill -0 "$CHILD" 2>/dev/null; then wait "$CHILD"; STATUS=$?; fi
set -e
exit $STATUS
