#!/usr/bin/env bash
# perf-0 benchmark runner (docs/PERFORMANCE-PLAN.md §2.2, §2.5, §2.6).
#
# Usage: scripts/bench.sh [--bundle APP] [--build release|dev] [--suites ui,page,memory]
#                         [--iterations N] [--warmups N] [--launch N] [--only IDS]
#                         [--fixture items300|items500|items1000] [--seed N] [--allow-locked]
#                         [--chrome] [--out DIR] [--no-guards]
#   --bundle      app to measure (default shell/dist/release/ReArc.app; --build dev: dist/chromium)
#   --launch N    N cold launches through LaunchServices (`open -n -W`), 5 s apart
#   --chrome      also load the same page set in Google Chrome (own temporary
#                 --user-data-dir, --no-first-run; only that instance is quit)
#   --allow-locked  run with the screen locked: input goes to direct entry points and
#                 the results say so; the gate never compares them with unlocked runs
#   --no-guards   skip the load guards (never for baselines)
# Output: DIR/bench.json (schema rearc.bench/1), raw files, net log audit. Default DIR
# shell/bench/results/<run id> (git-ignored).
#
# Refuses to start (exit 75) when: load average 1 min > REARC_BENCH_MAX_LOAD1 (3.0) or
# 5 min > REARC_BENCH_MAX_LOAD5 (4.0); CPU idle < REARC_BENCH_MIN_IDLE (85) % over 5 s; a
# build, self-test, compiler or another bench is running; on battery or Low Power Mode;
# Spotlight indexing over 20 % CPU. Takes the shared input lock
# (~/Library/Caches/rearc-input.lock) for the whole run and keeps the display awake
# (caffeinate -u: without it the display link stops and no frame can be timed).
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$SHELL_DIR/.." && pwd)"
BUILD=release
APP=""
SUITES="ui,page,memory"
ITERATIONS=40
WARMUPS=3
LAUNCHES=0
ONLY=""
FIXTURE=items500
SEED=1
ALLOW_LOCKED=0
CHROME=0
OUT=""
GUARDS=1
die() { echo "bench: $*" >&2; exit 1; }
refuse() { echo "bench: refusing to run: $*" >&2; exit 75; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) APP="$2"; shift ;;
    --build) BUILD="$2"; shift ;;
    --suites) SUITES="$2"; shift ;;
    --iterations) ITERATIONS="$2"; shift ;;
    --warmups) WARMUPS="$2"; shift ;;
    --launch) LAUNCHES="$2"; shift ;;
    --only) ONLY="$2"; shift ;;
    --fixture) FIXTURE="$2"; shift ;;
    --seed) SEED="$2"; shift ;;
    --allow-locked) ALLOW_LOCKED=1 ;;
    --chrome) CHROME=1 ;;
    --out) OUT="$2"; shift ;;
    --no-guards) GUARDS=0 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[[ $BUILD == release || $BUILD == dev ]] || die "--build is release or dev"
if [[ -z $APP ]]; then
  [[ $BUILD == release ]] && APP="$SHELL_DIR/dist/release/ReArc.app" || APP="$SHELL_DIR/dist/chromium/ReArc.app"
fi
EXE="$APP/Contents/MacOS/ReArc"
[[ -x $EXE ]] || die "no bundle at $APP"

guards() {
  local load1 load5 idle
  read -r load1 load5 _ < <(sysctl -n vm.loadavg | tr -d '{}')
  awk -v a="$load1" -v m="${REARC_BENCH_MAX_LOAD1:-3.0}" 'BEGIN{exit !(a > m)}' && refuse "1-minute load average $load1 > ${REARC_BENCH_MAX_LOAD1:-3.0}"
  awk -v a="$load5" -v m="${REARC_BENCH_MAX_LOAD5:-4.0}" 'BEGIN{exit !(a > m)}' && refuse "5-minute load average $load5 > ${REARC_BENCH_MAX_LOAD5:-4.0}"
  # Brackets keep each pattern from matching this script's own command line.
  local busy=""
  pgrep -f 'siso[ ]ninja' >/dev/null && busy+=" siso-ninja"
  pgrep -x ninja >/dev/null && busy+=" ninja"
  pgrep -x siso >/dev/null && busy+=" siso"
  pgrep -f 'rearc-selftes[t]' >/dev/null && busy+=" rearc-selftest"
  pgrep -f 'run_(c_abi|.*_gates|abi_stress)[.]py' >/dev/null && busy+=" engine-gates"
  pgrep -x swift-frontend >/dev/null && busy+=" swift-frontend"
  pgrep -x clang >/dev/null && busy+=" clang"
  pgrep -x 'clang[+][+]' >/dev/null && busy+=" clang++"
  pgrep -f 'xcodebuil[d]' >/dev/null && busy+=" xcodebuild"
  pgrep -f 'ReArc --rearc-benc[h]' >/dev/null && busy+=" another-bench"
  [[ -z $busy ]] || refuse "busy:$busy"
  if pmset -g batt | grep -q "Battery Power"; then refuse "on battery"; fi
  if pmset -g | grep -Eq "lowpowermode[[:space:]]+1"; then refuse "Low Power Mode"; fi
  local mds
  mds="$(ps -Ao pcpu,comm | awk '/mds_stores/ {s+=$1} END {print s+0}')"
  awk -v a="$mds" 'BEGIN{exit !(a > 20)}' && refuse "Spotlight indexing (mds_stores ${mds}% CPU)"
  idle="$(top -l 2 -n 0 -s 5 | awk '/CPU usage/ {v=$7} END {sub("%","",v); print v}')"
  awk -v a="$idle" -v m="${REARC_BENCH_MIN_IDLE:-85}" 'BEGIN{exit !(a < m)}' && refuse "CPU idle ${idle}% < ${REARC_BENCH_MIN_IDLE:-85}%"
  echo "guards: load $load1/$load5, CPU idle ${idle}%, no builds or tests"
}

RUN_ID="$(date -u +%Y-%m-%dT%H-%M-%SZ)-$BUILD-$(git -C "$REPO" rev-parse --short=8 HEAD)"
[[ -n $OUT ]] || OUT="$SHELL_DIR/bench/results/$RUN_ID"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
[[ $GUARDS == 0 ]] || guards

LOCK="$HOME/Library/Caches/rearc-input.lock"
until mkdir "$LOCK" 2>/dev/null; do sleep 20; done
CAFFEINATE=""
cleanup() {
  [[ -z $CAFFEINATE ]] || kill "$CAFFEINATE" 2>/dev/null || true
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
caffeinate -u -d & CAFFEINATE=$!
sleep 2

LOCKED_FLAG=()
[[ $ALLOW_LOCKED == 0 ]] || LOCKED_FLAG=(--rearc-bench-allow-locked)
COMMON=(--rearc-bench-iterations="$ITERATIONS" --rearc-bench-warmups="$WARMUPS" --rearc-bench-fixture="$FIXTURE"
        --rearc-bench-seed="$SEED" "${LOCKED_FLAG[@]}")
[[ -z $ONLY ]] || COMMON+=(--rearc-bench-only="$ONLY")

STATUS=0
if [[ -n $SUITES ]]; then
  PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/rearc-bench-profile.XXXXXX")"
  echo "bench: $APP suites=$SUITES iterations=$ITERATIONS -> $OUT"
  set +e
  "$EXE" --rearc-bench="$SUITES" --rearc-bench-out="$OUT/raw.json" --rearc-bench-dump-pages="$OUT/pages" \
    "${COMMON[@]}" --user-data-dir="$PROFILE" --log-net-log="$OUT/netlog.json" >"$OUT/bench.log" 2>&1
  STATUS=$?
  set -e
  grep -E "^\[bench" "$OUT/bench.log" | tail -n 5 || true
  rm -rf "$PROFILE"
  [[ $STATUS == 0 ]] || echo "bench: run exited $STATUS (see $OUT/bench.log)" >&2
fi

for ((i = 1; i <= LAUNCHES; i++)); do
  while pgrep -f 'rearc-bench=launch-chil[d]' >/dev/null; do sleep 1; done
  sleep 5
  PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/rearc-bench-launch.XXXXXX")"
  open -n -W "$APP" --args --rearc-bench=launch-child --rearc-bench-out="$OUT/launch-$i.json" "${COMMON[@]}" \
    --user-data-dir="$PROFILE" --log-net-log="$OUT/netlog-launch-$i.json" || echo "bench: launch $i: open failed" >&2
  rm -rf "$PROFILE"
done

if [[ $CHROME == 1 ]]; then
  [[ -d "$OUT/pages" ]] || die "--chrome needs the page set the ReArc run dumps (run with a page suite)"
  python3 -I "$SHELL_DIR/scripts/bench_chrome.py" --pages "$OUT/pages" --iterations "$(( ITERATIONS / 4 > 10 ? ITERATIONS / 4 : 10 ))" \
    --out "$OUT/chrome.json" || echo "bench: Chrome reference failed" >&2
fi

python3 -I "$SHELL_DIR/scripts/bench_finalize.py" --run "$OUT" --build "$BUILD" --bundle "$APP" --repo "$REPO" --run-id "$RUN_ID"
exit $STATUS
