#!/usr/bin/env python3
"""Upgrade check for stored site data: what one build stores, the next must read back.

Build 605 opened every older profile without crashing and read its local storage and
IndexedDB as empty (the engine had switched storage format). check-upgrade.sh only sees
crashes, so this check stores a value in local storage, IndexedDB, a cookie and Cache
Storage with one build and reads all four back with the next.

Usage: check-upgrade-data.py APP [APP ...] [--profile DIR] [--keep DIR]
  The apps run in order on one throwaway data directory. Each opens a loopback page that
  reports what it finds and then stores its own run label. The first app runs twice, so
  it is also checked against itself. Every run after the first must read the label of the
  run before it in all four stores.
  --profile DIR  start from a copy of this data directory instead of an empty one. A
                 directory saved with --keep records the label its chain stored last, and
                 the first run must read it back (for example a profile that ran 605).
  --keep DIR     leave the data directory here afterwards (for a later chain)
The last app is the new build and runs as it is: after build 608 that must be the bundle
release.sh is verifying, since a shipped bundle refuses REARC_DATA_DIR (security RC-0.1.0-602
T-04). An earlier, shipped app that refuses it runs as a verification copy, signed again
(upgrade-bundles.sh, as check-upgrade.sh).
Apps open in the background (`open -g`); nothing takes the keyboard focus.
"""
import argparse
import http.server
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

PORT = int(os.environ.get("REARC_UPGRADE_DATA_PORT", "18765"))
STORES = ("ls", "idb", "ck", "cache")
BUNDLES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "upgrade-bundles.sh")
# Beside the data in a --keep directory: the label the chain stored last.
LABEL_FILE = ".rearc-upgrade-data-label"
PAGE = b"""<!doctype html><meta charset="utf-8"><title>ReArc upgrade probe</title><script>
(async () => {
  const run = new URLSearchParams(location.search).get('run');
  // A window restored from an earlier run loads its old address again. It must stay inert:
  // only the page of the run now in progress may read, store or report.
  if (run !== '__CURRENT__') return;
  const found = {run};
  try { found.ls = localStorage.getItem('k'); } catch (e) { found.ls = 'error'; }
  const db = await new Promise(resolve => {
    const open = indexedDB.open('probe', 1);
    open.onupgradeneeded = () => open.result.createObjectStore('s');
    open.onsuccess = () => resolve(open.result);
    open.onerror = () => resolve(null);
  });
  found.idb = db ? await new Promise(resolve => {
    const get = db.transaction('s').objectStore('s').get('k');
    get.onsuccess = () => resolve(get.result === undefined ? null : get.result);
    get.onerror = () => resolve('error');
  }) : 'error';
  const cookie = document.cookie.split('; ').find(c => c.startsWith('k='));
  found.ck = cookie ? cookie.slice(2) : null;
  try {
    const hit = await (await caches.open('probe')).match('/k');
    found.cache = hit ? await hit.text() : null;
  } catch (e) { found.cache = 'error'; }
  localStorage.setItem('k', run);
  if (db) await new Promise(resolve => {
    const tx = db.transaction('s', 'readwrite');
    tx.objectStore('s').put(run, 'k');
    tx.oncomplete = resolve; tx.onerror = resolve;
  });
  document.cookie = 'k=' + run + '; max-age=31536000; path=/';
  try { await (await caches.open('probe')).put('/k', new Response(run)); } catch (e) {}
  await fetch('/report?' + new URLSearchParams(Object.fromEntries(
    Object.entries(found).map(([k, v]) => [k, v === null ? '(none)' : String(v)]))));
})();
</script>"""

reports = {}
arrived = threading.Condition()
current = {"run": ""}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/probe.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Cache-Control", "no-store")
            page = PAGE.replace(b"__CURRENT__", current["run"].encode())
            self.send_header("Content-Length", str(len(page)))
            self.end_headers()
            self.wfile.write(page)
            return
        if url.path == "/report":
            query = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
            with arrived:
                reports.setdefault(query.get("run", "?"), query)
                arrived.notify_all()
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


def build(app):
    plist = os.path.join(app, "Contents", "Info.plist")
    return subprocess.run(["plutil", "-extract", "CFBundleVersion", "raw", plist],
                          capture_output=True, text=True).stdout.strip() or "?"


def pids(app):
    out = subprocess.run(["pgrep", "-f", os.path.join(app, "Contents", "MacOS", "ReArc")],
                         capture_output=True, text=True).stdout.split()
    return [int(p) for p in out]


def run(app, data, label, timeout):
    before = set(pids(app))
    current["run"] = label
    # REARC_DATA_DIR only: the release verification variable enables the self-test and launch
    # probe, which this check does not use.
    subprocess.run(["open", "-n", "-g", "-a", app, "--env", f"REARC_DATA_DIR={data}",
                    f"http://127.0.0.1:{PORT}/probe.html?run={label}"], check=True)
    deadline = time.time() + timeout
    with arrived:
        while label not in reports and time.time() < deadline:
            arrived.wait(timeout=1)
    # Cookies reach the disk every 30 seconds; give every store time before the app quits.
    time.sleep(int(os.environ.get("REARC_UPGRADE_DATA_SETTLE", "35")))
    for pid in set(pids(app)) - before:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for _ in range(40):
        if not set(pids(app)) - before:
            break
        time.sleep(0.5)
    else:
        for pid in set(pids(app)) - before:
            os.kill(pid, signal.SIGKILL)
    time.sleep(1)
    return reports.get(label)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("apps", nargs="+")
    parser.add_argument("--profile")
    parser.add_argument("--keep")
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()
    apps = [os.path.abspath(a) for a in args.apps]
    for app in apps:
        if not os.access(os.path.join(app, "Contents", "MacOS", "ReArc"), os.X_OK):
            sys.exit(f"check-upgrade-data: no ReArc.app at {app}")
    if subprocess.run([BUNDLES, "new", apps[-1]]).returncode != 0:
        sys.exit("check-upgrade-data: the new build must be the bundle release.sh is verifying")
    # The path a process runs under (pids() matches on it): /var is a link to /private/var.
    work = os.path.realpath(tempfile.mkdtemp(prefix="rearc-upgrade-data."))
    try:
        launchable = {}
        for app in apps[:-1]:
            if app not in launchable:
                made = subprocess.run([BUNDLES, "previous", app, work], stdout=subprocess.PIPE, text=True)
                if made.returncode != 0:
                    sys.exit(f"check-upgrade-data: no launchable copy of {app}")
                launchable[app] = made.stdout.strip()
        launchable[apps[-1]] = apps[-1]
        sys.exit(check(args, apps, launchable, work))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def check(args, apps, launchable, work):
    try:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError as error:
        print(f"check-upgrade-data: port {PORT} is busy ({error}); the origin must not change between runs", file=sys.stderr)
        return 1
    threading.Thread(target=server.serve_forever, daemon=True).start()

    data = os.path.join(work, "data")
    previous = None
    if args.profile:
        shutil.copytree(args.profile, data, symlinks=True, ignore=shutil.ignore_patterns(LABEL_FILE))
        try:
            with open(os.path.join(args.profile, LABEL_FILE)) as saved:
                previous = saved.read().strip() or None
        except FileNotFoundError:
            pass
    else:
        os.makedirs(data)
        with open(os.path.join(data, "sidebar.json"), "w") as seed:
            seed.write('{"version":1,"spaces":[],"profiles":[]}\n')  # an existing install: no onboarding

    order = apps if args.profile else [apps[0]] + apps
    # The chain's own tag keeps its labels apart from those of a chain kept in --profile.
    tag = format(int(time.time()) % 0xFFFFFF, "x")
    chain = [(app, f"r{i + 1}b{build(app)}-{tag}") for i, app in enumerate(order)]
    failed = False
    last = previous
    print(f"check-upgrade-data: data {data}")
    for app, label in chain:
        found = run(launchable[app], data, label, args.timeout)
        if found is None:
            print(f"check-upgrade-data: FAIL: build {build(app)} never reported for run {label} (page did not load)")
            failed = True
            break
        values = " ".join(f"{k}={found.get(k, '?')}" for k in STORES)
        if previous is None:
            verdict = "start" if not args.profile else "read"
        else:
            lost = [k for k in STORES if found.get(k) != previous]
            verdict = "PASS" if not lost else f"FAIL: lost {', '.join(lost)} (expected {previous})"
            failed = failed or bool(lost)
        print(f"check-upgrade-data: build {build(app)} run {label}: {values}  -> {verdict}")
        previous = last = label
    if args.keep:
        shutil.rmtree(args.keep, ignore_errors=True)
        shutil.copytree(data, args.keep, symlinks=True)
        if last:
            with open(os.path.join(args.keep, LABEL_FILE), "w") as saved:
                saved.write(last + "\n")
    server.shutdown()
    server.server_close()
    return 1 if failed else 0


if __name__ == "__main__":
    main()
