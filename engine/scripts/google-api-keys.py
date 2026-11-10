#!/usr/bin/env python3
"""Load external Google GN credentials without printing them or passing them in argv."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

NAMES = ("google_api_key", "google_default_client_id", "google_default_client_secret")


def credentials(repo):
    path = Path(os.environ.get("REARC_GOOGLE_API_KEYS_FILE", "~/.config/rearc/google-api-keys.gn")).expanduser().resolve()
    if path.is_relative_to(repo.resolve()):
        raise ValueError("Google credentials must be stored outside the repository")
    values = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            match = re.fullmatch(r'\s*(google_api_key|google_default_client_id|google_default_client_secret)\s*=\s*("(?:[^"\\]|\\.)*")\s*(?:#.*)?', line)
            if not match:
                raise ValueError("external Google GN file must contain only quoted credential assignments")
            values[match[1]] = json.loads(match[2])
    for name in NAMES:
        if name in os.environ:
            values[name] = os.environ[name]
    if any(not isinstance(v, str) or not re.fullmatch(r"[A-Za-z0-9_.:/@+\-]*", v) for v in values.values()):
        raise ValueError("invalid characters in Google credentials")
    return values


def real_key(value):
    return bool(re.fullmatch(r"AIza[A-Za-z0-9_-]{35}", value))


def contains(path, needle):
    with path.open("rb") as file:
        tail = b""
        while block := file.read(1024 * 1024):
            if needle in tail + block:
                return True
            tail = block[-len(needle):]
    return False


def check_built(src, out, gn):
    result = subprocess.run([gn, "args", str(out), "--list=google_api_key", "--short"], cwd=src,
                            capture_output=True, text=True, check=True)
    match = re.search(r'^google_api_key\s*=\s*"([^"]*)"\s*$', result.stdout, re.M)
    key = match[1] if match else ""
    if not real_key(key):
        raise ValueError("release engine GN google_api_key is absent or a placeholder (dummytoken)")
    binary = out / "Chromium Framework.framework/Chromium Framework"
    if not contains(binary, key.encode()):
        raise ValueError("release framework does not contain its configured API key; rebuild the engine")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    append = sub.add_parser("append")
    append.add_argument("args", type=Path)
    check = sub.add_parser("check")
    check.add_argument("out", type=Path)
    check.add_argument("--allow-no-safe-browsing", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    try:
        if args.command == "append":
            values = credentials(repo)
            with args.args.open("a") as file:
                for name, value in values.items():
                    file.write(f'{name} = {json.dumps(value)}\n')
            if not real_key(values.get("google_api_key", "")):
                print("*** WARNING: building without a real Google API key; Safe Browsing will not work. DMG release is blocked. ***", file=sys.stderr)
        else:
            depot = Path(os.environ.get("REARC_DEPOT_TOOLS", str(repo / "engine/depot_tools")))
            check_built(repo / "engine/chromium/src", args.out.resolve(), str(depot / "gn"))
            print("Safe Browsing credential gate: configured key is present in the release framework (service approval still required)")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        # Subprocess output and external file contents can contain credentials.
        message = str(error) if isinstance(error, ValueError) else "could not inspect Google credentials / release engine configuration"
        if args.command == "check" and args.allow_no_safe_browsing:
            print(f"\n*** WARNING: SAFE BROWSING RELEASE GATE OVERRIDDEN: {message}. PHISHING AND MALWARE PROTECTION MAY NOT WORK. ***\n", file=sys.stderr)
            return 0
        print(f"Google credential gate: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
