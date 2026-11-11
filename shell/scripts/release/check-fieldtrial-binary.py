#!/usr/bin/env python3
"""Release gate (security RC-0.1.0-602 T-11): the shipped engine binary carries no copy of
Chromium's field-trial testing config.

The build flag in the generated header says what the build asked for; this checks what the
framework holds. With the config compiled in, the binary contains the name of every study the
config lists for macOS as its own NUL-terminated string (build 564 had all of them). Without
it, only names that Chromium uses elsewhere remain (feature names, mostly: about a quarter in
build 602). The gate fails when more than half are present.

Usage: check-fieldtrial-binary.py FRAMEWORK_BINARY fieldtrial_testing_config.json [--max-share 0.5]
"""
import argparse
import json
import mmap
import sys


def mac_study_names(config):
    names = []
    for name, entries in config.items():
        platforms = {p for entry in entries if isinstance(entry, dict) for p in entry.get("platforms", [])}
        if "mac" in platforms and len(name) >= 12:
            names.append(name)
    return sorted(set(names))


def present(binary_path, names):
    found = []
    with open(binary_path, "rb") as handle, mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as data:
        for name in names:
            # Its own C string: NUL on both sides.
            if data.find(b"\0" + name.encode() + b"\0") != -1:
                found.append(name)
    return found


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("config")
    parser.add_argument("--max-share", type=float, default=0.5)
    args = parser.parse_args(argv)
    with open(args.config, encoding="utf-8") as handle:
        names = mac_study_names(json.load(handle))
    if not names:
        print("check-fieldtrial-binary: the config lists no macOS study; cannot check", file=sys.stderr)
        return 1
    found = present(args.binary, names)
    share = len(found) / len(names)
    line = f"{len(found)} of {len(names)} macOS study names from the testing config are in {args.binary} ({share:.0%})"
    if share > args.max_share:
        print(f"check-fieldtrial-binary: FAIL: {line}; the engine was built with the field-trial testing config", file=sys.stderr)
        return 1
    print(f"check-fieldtrial-binary: PASS: {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
