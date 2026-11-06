# The load guards bench.sh and arc-vs-rearc.sh run before a measurement
# (docs/PERFORMANCE-PLAN.md §2.2). Source it, define refuse() (print, exit 75),
# then call bench_guards. Thresholds: REARC_BENCH_MAX_LOAD1 (3.0),
# REARC_BENCH_MAX_LOAD5 (4.0), REARC_BENCH_MIN_IDLE (85) % CPU idle over 5 s.
bench_guards() {
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
