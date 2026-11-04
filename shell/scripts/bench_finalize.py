#!/usr/bin/env python3
"""Turns a bench run directory into bench.json (schema rearc.bench/1).

Merges the app's raw.json, the launch children's launch-N.json and Chrome's
chrome.json; adds build details (git, GN args, signature) and machine details
(model, OS, display, power); computes p50/p95 (nearest rank), max, mean,
stdev and a bootstrap 95% CI of p50 per metric; audits the net logs for any
connection outside loopback. Standard library only.
"""
import argparse, json, math, pathlib, platform, random, re, subprocess, sys

SCHEMA = "rearc.bench/1"


def sh(*args, default=""):
    try:
        return subprocess.run(args, capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return default


def nearest_rank(sorted_values, p):
    if not sorted_values:
        return None
    k = max(0, min(len(sorted_values) - 1, math.ceil(p * len(sorted_values)) - 1))
    return sorted_values[k]


def stats(samples, seed=1):
    values = sorted(samples)
    n = len(values)
    if not n:
        return {"n": 0, "p50": None, "p95": None, "max": None, "mean": None, "stdev": None, "p50_ci95": None}
    mean = sum(values) / n
    stdev = math.sqrt(sum((v - mean) ** 2 for v in values) / (n - 1)) if n > 1 else 0.0
    rng = random.Random(seed)
    medians = sorted(nearest_rank(sorted(rng.choice(values) for _ in range(n)), 0.5) for _ in range(1000))
    return {"n": n, "p50": nearest_rank(values, 0.5), "p95": nearest_rank(values, 0.95), "max": values[-1],
            "mean": mean, "stdev": stdev, "p50_ci95": [medians[25], medians[974]]}


def outside_connects(path):
    """Non-loopback peers in a Chromium net log (as engine/tests/run_c_abi.py)."""
    text = path.read_text(errors="replace") if path.exists() else ""
    def outside(address):
        return not (address.startswith("127.") or address.startswith("[::1]") or address.startswith("::1"))
    try:
        log = json.loads(text)
    except ValueError:
        # A net log cut short at exit: fall back to addresses in the text.
        return sorted({a for a in re.findall(r'"address":"([^"]+)"', text) if outside(a)})
    names = {v: k for k, v in log["constants"]["logEventTypes"].items()}
    peers, sent, tcp = {}, set(), set()
    for event in log["events"]:
        name, source, params = names.get(event["type"]), event["source"]["id"], event.get("params", {})
        if name in ("TCP_CONNECT_ATTEMPT", "SOCKET_CONNECT", "UDP_CONNECT") and "address" in params:
            peers.setdefault(source, set()).add(params["address"])
            if name == "TCP_CONNECT_ATTEMPT":
                tcp.add(source)
        elif name == "UDP_BYTES_SENT":
            sent.add(source)
            if "address" in params:
                peers.setdefault(source, set()).add(params["address"])
    return sorted({a for s, addresses in peers.items() if s in tcp or s in sent for a in addresses if outside(a)})


def gn_args(out_dir):
    path = pathlib.Path(out_dir) / "args.gn"
    keys = ("is_debug", "is_component_build", "is_official_build", "chrome_pgo_phase", "dcheck_always_on", "symbol_level")
    found = {}
    if path.exists():
        for line in path.read_text().splitlines():
            m = re.match(r"\s*(\w+)\s*=\s*(.+?)\s*$", line)
            if m and m.group(1) in keys:
                value = m.group(2)
                found[m.group(1)] = value == "true" if value in ("true", "false") else (int(value) if value.isdigit() else value)
    return found


def machine(raw):
    display = raw.get("display") or {}
    batt = sh("pmset", "-g", "batt")
    return {
        "model": sh("sysctl", "-n", "hw.model"),
        "cpu": sh("sysctl", "-n", "machdep.cpu.brand_string"),
        "cores": int(sh("sysctl", "-n", "hw.ncpu", default="0") or 0),
        "memory_gb": round(int(sh("sysctl", "-n", "hw.memsize", default="0") or 0) / 2**30),
        "os": f"{sh('sw_vers', '-productVersion')} ({sh('sw_vers', '-buildVersion')})",
        "display": {"refresh_hz": display.get("refreshHz"), "scale": display.get("scale"), "points": display.get("points"),
                    "name": display.get("name"), "window": display.get("window")},
        "power": "battery" if "Battery Power" in batt else "ac",
        "low_power": bool(re.search(r"lowpowermode\s+1", sh("pmset", "-g"))),
        "thermal": (raw.get("conditions") or {}).get("thermal"),
    }


def build(args, raw, repo):
    app = pathlib.Path(args.bundle)
    plist = app / "Contents/Info.plist"
    def plist_value(key):
        return sh("/usr/libexec/PlistBuddy", "-c", f"Print :{key}", str(plist))
    out = repo / "engine/chromium/src/out" / ("ReArc-release-arm64" if args.build == "release" else "ReArc-dev-arm64")
    signature = sh("codesign", "-dv", "--verbose=2", str(app)) or subprocess.run(
        ["codesign", "-dv", "--verbose=2", str(app)], capture_output=True, text=True).stderr
    signed = "developer-id" if "Developer ID Application" in signature else "development" if "Apple Development" in signature else "adhoc"
    engine = raw.get("engine") or {}
    return {
        "type": args.build,
        "bundle": str(app.relative_to(repo)) if app.is_relative_to(repo) else str(app),
        "shell_rev": plist_value("ReArcSourceRevision") or raw.get("shellRevision"),
        "shell_config": raw.get("shellConfig"),
        "engine_out": str(out.relative_to(repo / "engine/chromium/src")),
        "engine_rev": sh("git", "-C", str(repo / "engine/chromium/src"), "rev-parse", "--short=10", "HEAD"),
        "chromium": engine.get("chromium"),
        "abi_minor": engine.get("abiMinor"),
        "bridge": engine.get("bridge"),
        "gn": gn_args(out),
        "signed": signed,
        "anti_throttling_switches": raw.get("antiThrottlingSwitches", False),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    run, repo = pathlib.Path(args.run), pathlib.Path(args.repo)
    raw_path = run / "raw.json"
    raw = json.loads(raw_path.read_text()) if raw_path.exists() else {}
    metrics = dict(raw.get("metrics") or {})
    launches = sorted(run.glob("launch-*.json"), key=lambda p: int(re.findall(r"\d+", p.name)[-1]))
    for path in launches:
        child = json.loads(path.read_text())
        raw.setdefault("display", child.get("display"))
        raw.setdefault("engine", child.get("engine"))
        raw.setdefault("conditions", child.get("conditions"))
        for key, metric in (child.get("metrics") or {}).items():
            merged = metrics.setdefault(key, {"unit": metric["unit"], "samples": [], "timeouts": 0, "contaminated": 0, "input": {}})
            merged["samples"] += metric["samples"]
            merged["timeouts"] += metric["timeouts"]
            for k, v in metric.get("input", {}).items():
                merged["input"][k] = merged["input"].get(k, 0) + v
    conditions = raw.get("conditions") or {}
    out_metrics = {}
    contaminated = 0
    for key in sorted(metrics):
        m = metrics[key]
        contaminated += m.get("contaminated", 0)
        entry = {"unit": m["unit"], **stats(m["samples"]), "timeouts": m.get("timeouts", 0),
                 "dropped_contaminated": m.get("contaminated", 0), "input": m.get("input", {}),
                 "samples": [round(v, 3) for v in m["samples"]]}
        out_metrics[key] = entry
    total = sum(len(m["samples"]) + m.get("contaminated", 0) for m in metrics.values())
    netlogs = sorted(run.glob("netlog*.json"))
    outside = sorted({a for p in netlogs for a in outside_connects(p)})
    chrome = json.loads((run / "chrome.json").read_text()) if (run / "chrome.json").exists() else None
    report = {
        "schema": SCHEMA,
        "run_id": args.run_id,
        "status": raw.get("status") or ("launch-only" if launches else "missing"),
        "build": build(args, raw, repo),
        "machine": machine(raw),
        "conditions": {
            "load_avg_start": conditions.get("loadAverage"),
            "load_avg_end": (raw.get("conditionsEnd") or {}).get("loadAverage"),
            "screen_locked": conditions.get("screenLocked"),
            "display_asleep_at_start": conditions.get("displayAsleep"),
            "app_active": conditions.get("appActive"),
            "memory_pressure": conditions.get("memoryPressure"),
            "input_delivery": raw.get("inputDelivery"),
            "contaminated_iterations": contaminated,
            "contaminated_fraction": contaminated / total if total else 0,
            "cpu_other_share": {k: round(sum(v) / len(v), 3) for k, v in (raw.get("cpuOtherShare") or {}).items() if v},
            "network_outside_loopback": outside,
            "net_logs": [p.name for p in netlogs],
        },
        "fixture": raw.get("fixture"),
        "metrics": out_metrics,
        "reference_chrome": chrome,
        "hangs": raw.get("hangs", []),
        "notes": raw.get("notes", []),
        "artifacts": {"log": "bench.log", "raw": "raw.json", "launches": [p.name for p in launches]},
    }
    if report["conditions"]["contaminated_fraction"] > 0.10:
        report["status"] = "invalid"
        report["notes"].append("more than 10% of iterations were contaminated by other processes' CPU")
    if outside:
        report["status"] = "invalid"
        report["notes"].append(f"connections outside loopback: {outside}")
    (run / "bench.json").write_text(json.dumps(report, indent=1, sort_keys=True) + "\n")
    print(f"bench.json: status={report['status']} metrics={len(out_metrics)} outside-loopback={outside or 'none'} -> {run / 'bench.json'}")
    for key, m in out_metrics.items():
        if m["n"]:
            print(f"  {key:52s} n={m['n']:3d} p50={m['p50']:9.2f} p95={m['p95']:9.2f} max={m['max']:9.2f} {m['unit']}"
                  f"{'  timeouts=' + str(m['timeouts']) if m['timeouts'] else ''}")
        else:
            print(f"  {key:52s} n=  0 (timeouts={m['timeouts']})")
    return 0 if report["status"] in ("complete", "launch-only") else 1


if __name__ == "__main__":
    sys.exit(main())
