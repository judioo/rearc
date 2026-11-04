#!/usr/bin/env python3
"""Regression gate for bench runs (docs/PERFORMANCE-PLAN.md §2.6).

  bench-gate.py RUN.json [--baseline BASELINE.json] [--budgets budgets.json]
  bench-gate.py RUN.json --update-baseline --reason "..." [--baseline PATH]

Refuses (exit 2) to compare runs that are not comparable: a different build
type (dev is never compared with release), machine model, display refresh
rate, schema major, screen-lock state or input delivery (posted AppKit events
vs direct entry points), or a run that is not complete. Default baseline:
shell/bench/baselines/<build>-<machine>.json, where <machine> is the model with
non-alphanumerics replaced by '-'.

A metric fails when the bootstrap 95% CI of the p50 difference lies entirely
above max(5% of the baseline p50, floor), or p95 regressed by more than
max(10%, floor). Floors: 1 ms, 1 frame, 0.5 ms/s, 2 MB. A budget miss
(budgets.json) is a warning until the metric has met its budget once in a
baseline; after that it fails. Metrics marked unstable in the baseline are
reported, never gated. Exit 0 pass, 1 regression, 2 refused.
"""
import argparse, json, pathlib, random, re, sys

FLOORS = {"ms": 1.0, "frames": 1.0, "ms/s": 0.5, "MB": 2.0}
HERE = pathlib.Path(__file__).resolve().parent
BENCH = HERE.parent / "bench"


def machine_key(run):
    return re.sub(r"[^A-Za-z0-9]+", "-", run["machine"]["model"]).strip("-")


def default_baseline(run):
    return BENCH / "baselines" / f"{run['build']['type']}-{machine_key(run)}.json"


def comparable(run, base):
    problems = []
    def check(label, a, b):
        if a != b:
            problems.append(f"{label}: run {a!r} vs baseline {b!r}")
    check("schema major", run["schema"].split("/")[-1].split(".")[0], base["schema"].split("/")[-1].split(".")[0])
    check("build type", run["build"]["type"], base["build"]["type"])
    check("machine model", run["machine"]["model"], base["machine"]["model"])
    check("display refresh", run["machine"]["display"]["refresh_hz"], base["machine"]["display"]["refresh_hz"])
    check("screen locked", run["conditions"].get("screen_locked"), base["conditions"].get("screen_locked"))
    check("input delivery", run["conditions"].get("input_delivery"), base["conditions"].get("input_delivery"))
    check("fixture", (run.get("fixture") or {}).get("sidebar"), (base.get("fixture") or {}).get("sidebar"))
    if run["build"].get("anti_throttling_switches"):
        problems.append("run used anti-throttling switches")
    if run.get("status") not in ("complete",):
        problems.append(f"run status is {run.get('status')!r}")
    return problems


def ci_of_difference(run_samples, base_samples, seed=1, rounds=1000):
    rng = random.Random(seed)
    def median(values):
        values = sorted(values)
        return values[max(0, -(-len(values) // 2) - 1)]
    diffs = sorted(median([rng.choice(run_samples) for _ in run_samples]) - median([rng.choice(base_samples) for _ in base_samples])
                   for _ in range(rounds))
    return diffs[int(rounds * 0.025)], diffs[int(rounds * 0.975) - 1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run")
    parser.add_argument("--baseline")
    parser.add_argument("--budgets", default=str(BENCH / "budgets.json"))
    parser.add_argument("--update-baseline", action="store_true")
    parser.add_argument("--reason")
    args = parser.parse_args()
    run = json.loads(pathlib.Path(args.run).read_text())
    baseline_path = pathlib.Path(args.baseline) if args.baseline else default_baseline(run)

    if args.update_baseline:
        if not args.reason:
            print("bench-gate: --update-baseline needs --reason", file=sys.stderr)
            return 2
        if run.get("status") != "complete" or run["conditions"].get("network_outside_loopback"):
            print(f"bench-gate: refusing to make a baseline from a {run.get('status')} run", file=sys.stderr)
            return 2
        if str(run["build"].get("shell_rev", "")).endswith("-dirty"):
            print("bench-gate: refusing a baseline from a dirty tree", file=sys.stderr)
            return 2
        previous = json.loads(baseline_path.read_text())["run_id"] if baseline_path.exists() else None
        run["baseline"] = {"reason": args.reason, "previous_run_id": previous}
        baseline_path.parent.mkdir(parents=True, exist_ok=True)
        baseline_path.write_text(json.dumps(run, indent=1, sort_keys=True) + "\n")
        print(f"bench-gate: baseline {baseline_path} <- {run['run_id']} (previous {previous})")
        return 0

    if not baseline_path.exists():
        print(f"bench-gate: no baseline at {baseline_path}", file=sys.stderr)
        return 2
    base = json.loads(baseline_path.read_text())
    problems = comparable(run, base)
    if problems:
        print("bench-gate: REFUSED, not comparable:\n  " + "\n  ".join(problems), file=sys.stderr)
        return 2
    budgets = json.loads(pathlib.Path(args.budgets).read_text()).get("metrics", {}) if pathlib.Path(args.budgets).exists() else {}
    unstable = set(base.get("unstable", []))
    failures, warnings, rows = [], [], []
    for key, metric in sorted(run["metrics"].items()):
        before = base["metrics"].get(key)
        if not metric.get("n") or not before or not before.get("n"):
            continue
        floor = FLOORS.get(metric["unit"], 0.0)
        low, high = ci_of_difference(metric["samples"], before["samples"])
        threshold = max(0.05 * abs(before["p50"]), floor)
        p95_limit = before["p95"] + max(0.10 * abs(before["p95"]), floor)
        regressed = low > threshold or metric["p95"] > p95_limit
        verdict = "unstable" if key in unstable else ("FAIL" if regressed else "ok")
        rows.append(f"{key:52s} p50 {before['p50']:9.2f} -> {metric['p50']:9.2f}  p95 {before['p95']:9.2f} -> {metric['p95']:9.2f}  "
                    f"CI(diff) [{low:+.2f}, {high:+.2f}]  {verdict}")
        if regressed and key not in unstable:
            failures.append(key)
        budget = budgets.get(key)
        if budget and budget.get("p50") is not None and metric["p50"] > budget["p50"]:
            met_before = before["p50"] <= budget["p50"]
            (failures if met_before else warnings).append(f"{key} over budget p50 {metric['p50']:.2f} > {budget['p50']}")
    print("\n".join(rows))
    for warning in warnings:
        print("WARN", warning)
    if failures:
        print("bench-gate: FAIL " + ", ".join(failures))
        return 1
    print(f"bench-gate: PASS ({len(rows)} metrics against {base['run_id']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
