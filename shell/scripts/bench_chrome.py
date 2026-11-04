#!/usr/bin/env python3
"""Reference page loads in Google Chrome (docs/PERFORMANCE-PLAN.md §1.4, R2).

Serves the bench's dumped page set (bench.sh --chrome) on 127.0.0.1 and
loads each page in a separate Chrome instance: its own temporary
--user-data-dir, --no-first-run, the same loopback-only resolver rules as the
ReArc bench and no anti-throttling switches. Driven over
--remote-debugging-pipe (no network port). Only this instance is closed
(Browser.close, then its own pid); the user's Chrome is never touched.
Records the page's own Performance entries (TTFB, FCP, DCL, load), Chrome's
PageLoad.PaintTiming histogram and the instance's phys_footprint per process
type. Standard library only.
"""
import argparse, ctypes, json, os, pathlib, shutil, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PAGES = ["article", "images", "spa", "list"]
SNIPPET = """(() => { const n = performance.getEntriesByType('navigation')[0];
  const p = performance.getEntriesByType('paint').find(e => e.name === 'first-contentful-paint');
  return JSON.stringify({ ttfb: n ? n.responseStart : -1, dcl: n ? n.domContentLoadedEventEnd : -1,
    load: n ? n.loadEventEnd : -1, fcp: p ? p.startTime : -1, visibility: document.visibilityState }); })()"""


def server(root):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split("?", 1)[0]
            file, kind = None, "text/html; charset=utf-8"
            if path.startswith("/bench/img/") and path.endswith(".png"):
                file, kind = root / path.lstrip("/"), "image/png"
            elif path == "/bench/spa.js":
                file, kind = root / "bench/spa.js", "text/javascript; charset=utf-8"
            elif path.startswith("/bench/") and "/" not in path[len("/bench/"):]:
                file = root / ("bench/" + path[len("/bench/"):] + ".html")
            if not file or not file.is_file():
                self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
            body = file.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


class Pipe:
    """CDP over --remote-debugging-pipe: NUL-terminated JSON on fds 3 (in) and 4 (out)."""

    def __init__(self, args):
        to_child_r, self.to_child = os.pipe()
        self.from_child, from_child_w = os.pipe()
        def setup():
            os.dup2(to_child_r, 3)
            os.dup2(from_child_w, 4)
        self.proc = subprocess.Popen(args, preexec_fn=setup, pass_fds=(3, 4), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.close(to_child_r)
        os.close(from_child_w)
        self.buffer = b""
        self.next_id = 0
        self.events = []

    def send(self, method, params=None, session=None, timeout=30):
        self.next_id += 1
        message = {"id": self.next_id, "method": method, "params": params or {}}
        if session:
            message["sessionId"] = session
        os.write(self.to_child, json.dumps(message).encode() + b"\0")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            reply = self.read(deadline)
            if reply is None:
                break
            if reply.get("id") == self.next_id:
                if "error" in reply:
                    raise RuntimeError(f"{method}: {reply['error']}")
                return reply.get("result", {})
            self.events.append(reply)
        raise TimeoutError(method)

    def read(self, deadline):
        while b"\0" not in self.buffer:
            import select
            ready, _, _ = select.select([self.from_child], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                return None
            chunk = os.read(self.from_child, 1 << 20)
            if not chunk:
                return None
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\0", 1)
        return json.loads(line)

    def wait_event(self, method, session, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for index, event in enumerate(self.events):
                if event.get("method") == method and event.get("sessionId") == session:
                    return self.events.pop(index)
            event = self.read(deadline)
            if event is None:
                return None
            self.events.append(event)
        return None


class RusageInfoV4(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins", "ri_wired_size",
        "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime", "ri_proc_exit_abstime",
        "ri_child_user_time", "ri_child_system_time", "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups",
        "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread", "ri_diskio_byteswritten",
        "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance", "ri_cpu_time_qos_background",
        "ri_cpu_time_qos_utility", "ri_cpu_time_qos_legacy", "ri_cpu_time_qos_user_initiated",
        "ri_cpu_time_qos_user_interactive", "ri_billed_system_time", "ri_serviced_system_time",
        "ri_logical_writes", "ri_lifetime_max_phys_footprint", "ri_instructions", "ri_cycles",
        "ri_billed_energy", "ri_serviced_energy", "ri_interval_max_phys_footprint", "ri_runnable_time")]


def footprint(pid):
    lib = ctypes.CDLL("/usr/lib/libproc.dylib")
    info = RusageInfoV4()
    if lib.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(4), ctypes.byref(info)) != 0:
        return None
    return info.ri_phys_footprint


def process_tree(root_pid):
    out = subprocess.run(["ps", "-Ao", "pid=,ppid=,args="], capture_output=True, text=True).stdout
    rows = [line.split(None, 2) for line in out.splitlines() if line.strip()]
    children, args = {}, {}
    for row in rows:
        if len(row) < 3:
            continue
        pid, ppid = int(row[0]), int(row[1])
        children.setdefault(ppid, []).append(pid)
        args[pid] = row[2]
    tree, stack = [], [root_pid]
    while stack:
        pid = stack.pop()
        tree.append(pid)
        stack += children.get(pid, [])
    def kind(pid):
        a = args.get(pid, "")
        if pid == root_pid: return "browser"
        if "--type=renderer" in a: return "extension" if "--extension-process" in a else "renderer"
        if "--type=gpu-process" in a: return "gpu"
        if "--type=utility" in a: return "utility"
        return "other"
    return [(pid, kind(pid)) for pid in tree]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pages", required=True)
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    if not os.path.exists(CHROME):
        print("bench_chrome: Google Chrome is not installed", file=sys.stderr)
        return 1
    version = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString",
                              "/Applications/Google Chrome.app/Contents/Info.plist"], capture_output=True, text=True).stdout.strip()
    httpd = server(pathlib.Path(args.pages))
    base = f"http://127.0.0.1:{httpd.server_port}"
    profile = tempfile.mkdtemp(prefix="rearc-bench-chrome-")
    netlog = pathlib.Path(args.out).with_name("netlog-chrome.json")
    chrome = Pipe([CHROME, f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
                   "--remote-debugging-pipe", "--disable-background-networking", "--disable-component-update",
                   "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost",
                   "--window-size=1440,900", "--window-position=20,40", f"--log-net-log={netlog}", "about:blank"])
    result = {"browser": "Google Chrome", "version": version, "pages": {}, "memory": {}, "histograms": {},
              "switches": "no anti-throttling switches; loopback-only resolver rules", "pid": chrome.proc.pid}
    try:
        browser_version = chrome.send("Browser.getVersion")
        result["product"] = browser_version.get("product")
        for page in PAGES:
            samples = {"ttfb": [], "fcp": [], "dcl": [], "load": []}
            visibility = set()
            for i in range(args.iterations + 1):
                target = chrome.send("Target.createTarget", {"url": "about:blank"})["targetId"]
                session = chrome.send("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]
                chrome.send("Page.enable", session=session)
                chrome.send("Page.navigate", {"url": f"{base}/bench/{page}?n={i}"}, session=session)
                loaded = chrome.wait_event("Page.loadEventFired", session, 20)
                time.sleep(1.0)
                value = chrome.send("Runtime.evaluate", {"expression": SNIPPET, "returnByValue": True}, session=session)
                timings = json.loads(value["result"]["value"])
                visibility.add(timings.pop("visibility"))
                if i > 0 and loaded:
                    for key, sample in timings.items():
                        if sample is not None and sample >= 0:
                            samples[key].append(round(sample, 3))
                if page == PAGES[-1] and i == args.iterations:
                    for pid, kind in process_tree(chrome.proc.pid):
                        size = footprint(pid)
                        if size:
                            result["memory"][kind] = result["memory"].get(kind, 0) + size / 2**20
                    result["memory"]["total"] = sum(v for k, v in result["memory"].items() if k != "total")
                chrome.send("Target.closeTarget", {"targetId": target})
            result["pages"][page] = {"samples": samples, "visibility": sorted(visibility), "first_visit_excluded": True}
        for name in ("PageLoad.PaintTiming.NavigationToFirstContentfulPaint", "PageLoad.DocumentTiming.NavigationToLoadEventFired"):
            try:
                result["histograms"][name] = chrome.send("Browser.getHistogram", {"name": name}).get("histogram")
            except RuntimeError as error:
                result["histograms"][name] = {"error": str(error)}
    finally:
        try:
            chrome.send("Browser.close", timeout=10)
        except Exception:
            pass
        try:
            chrome.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            chrome.proc.terminate()  # only the instance this script started
            chrome.proc.wait(timeout=10)
        httpd.shutdown()
        shutil.rmtree(profile, ignore_errors=True)
    pathlib.Path(args.out).write_text(json.dumps(result, indent=1, sort_keys=True) + "\n")
    print(f"bench_chrome: {version}, {sum(len(p['samples']['load']) for p in result['pages'].values())} loads -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
