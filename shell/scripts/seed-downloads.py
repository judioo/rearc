#!/usr/bin/env python3
"""Seeds a throwaway ReArc data dir with a large Downloads.json (downloads at scale).

Usage: scripts/seed-downloads.py --out DIR [--source ~/Downloads] [--mode top|files] [--limit N]
       scripts/seed-downloads.py --history HISTORY_DB --from DIR/Downloads.json

  --mode top    one completed record per top-level item of SOURCE (folders get the
                total size of the files under them)
  --mode files  one record per regular file under SOURCE, recursively
  --limit N     keep the newest N records only

Records are newest first (the order ReArc keeps), each with url
https://example.com/<n>, targetPath at the real item, its size, and startedAt and
updatedAt from its modification date. Files are only stat'ed: never opened, moved,
copied or written. Prints counts only; file names never reach stdout. Never point
--out at your real ReArc data dir: launch with REARC_DATA_DIR=DIR instead.

--history adds the same records, as completed downloads, to the `downloads` table of
a Chromium History database (a throwaway profile's, with ReArc quit): Chromium replays
them at launch, which is how a long download history reaches the tray.
"""
import argparse
import datetime
import json
import os
import re
import sqlite3
import stat
import sys
import uuid


def tree_size(path):
    total = 0
    for root, dirs, files in os.walk(path, onerror=lambda _: None):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def entries(source, mode):
    """(path, size, mtime) for each item, never following symlinks."""
    if mode == "top":
        with os.scandir(source) as it:
            for entry in it:
                try:
                    info = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                size = tree_size(entry.path) if stat.S_ISDIR(info.st_mode) else info.st_size
                yield entry.path, size, info.st_mtime
    else:
        for root, dirs, files in os.walk(source, onerror=lambda _: None):
            for name in files:
                path = os.path.join(root, name)
                try:
                    info = os.lstat(path)
                except OSError:
                    continue
                if stat.S_ISREG(info.st_mode):
                    yield path, info.st_size, info.st_mtime


def iso(seconds):
    return datetime.datetime.fromtimestamp(int(seconds), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def chromium_time(stamp):
    """Microseconds since 1601-01-01 UTC."""
    moment = datetime.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    return int((moment - datetime.datetime(1601, 1, 1, tzinfo=datetime.timezone.utc)).total_seconds() * 1_000_000)


def seed_history(history, source):
    real = os.path.realpath(os.path.expanduser("~/Library/Application Support/ReArc"))
    if os.path.realpath(history).startswith(real + os.sep):
        sys.exit("seed-downloads: refusing to write into the real ReArc data dir")
    with open(source) as handle:
        records = json.load(handle)["list"]["records"]
    db = sqlite3.connect(history)
    columns = db.execute("PRAGMA table_info(downloads)").fetchall()
    if not columns:
        sys.exit("seed-downloads: no downloads table (launch ReArc on the profile once first)")
    names = [column[1] for column in columns]
    if not all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) for name in names):
        sys.exit("seed-downloads: unexpected column names in the downloads table")
    # Column names come from the table itself; every value is bound.
    insert = "INSERT INTO downloads ({}) VALUES ({})".format(
        ",".join(f'"{name}"' for name in names), ",".join("?" * len(names)))
    next_id = (db.execute("SELECT MAX(id) FROM downloads").fetchone()[0] or 0) + 1
    for offset, record in enumerate(records):
        values = {}
        for _, name, kind, _, _, _ in columns:
            kind = kind.upper()
            values[name] = b"" if "BLOB" in kind else 0 if "INT" in kind else ""
        start = chromium_time(record["startedAt"])
        values.update(id=next_id + offset, guid=record["id"], current_path=record["targetPath"],
                      target_path=record["targetPath"], start_time=start, end_time=start, last_access_time=start,
                      received_bytes=record["receivedBytes"], total_bytes=record["totalBytes"], state=1,
                      site_url="https://example.com/", tab_url=record["url"], http_method="GET")
        db.execute(insert, [values[name] for name in names])
        db.execute("INSERT INTO downloads_url_chains (id, chain_index, url) VALUES (?, 0, ?)", (next_id + offset, record["url"]))
    db.commit()
    db.close()
    print(f"seed-downloads: {len(records)} history rows")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out")
    parser.add_argument("--history")
    parser.add_argument("--from", dest="source_file")
    parser.add_argument("--source", default=os.path.expanduser("~/Downloads"))
    parser.add_argument("--mode", choices=["top", "files"], default="top")
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()
    if args.history:
        if not args.source_file:
            sys.exit("seed-downloads: --history needs --from DIR/Downloads.json")
        return seed_history(args.history, args.source_file)
    if not args.out:
        sys.exit("seed-downloads: --out DIR or --history DB")

    out = os.path.abspath(args.out)
    real = os.path.expanduser("~/Library/Application Support/ReArc")
    if os.path.realpath(out) == os.path.realpath(real):
        sys.exit("seed-downloads: refusing to write into the real ReArc data dir")
    items = sorted(entries(os.path.expanduser(args.source), args.mode), key=lambda item: item[2], reverse=True)
    if args.limit is not None:
        items = items[: args.limit]
    records = []
    for n, (path, size, mtime) in enumerate(items):
        stamp = iso(mtime)
        records.append({
            "id": str(uuid.uuid4()).upper(), "source": "chromium", "url": f"https://example.com/{n}",
            "targetPath": path, "mimeType": "", "receivedBytes": size, "totalBytes": size,
            "state": "complete", "dangerType": 0, "interruptReason": 0, "isPaused": False,
            "canResume": False, "startedAt": stamp, "updatedAt": stamp,
        })
    os.makedirs(out, exist_ok=True)
    contents = {"version": 1, "directory": os.path.expanduser(args.source), "list": {"records": records}}
    target = os.path.join(out, "Downloads.json")
    with open(target, "w") as handle:
        json.dump(contents, handle, sort_keys=True, separators=(",", ":"))
    print(f"seed-downloads: {len(records)} records, {os.path.getsize(target)} bytes")


if __name__ == "__main__":
    main()
