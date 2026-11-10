#!/usr/bin/env python3
"""Fail closed unless the pin is current on a supported Mac release channel."""
import argparse
import json
from pathlib import Path
import re
import sys
import urllib.request


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", value):
        raise ValueError("invalid Chromium version")
    return tuple(map(int, value.split(".")))


def check(pin, releases):
    pinned = version(pin)
    current = []
    for channel in ("Stable", "Extended"):
        entries = releases[channel]
        if not entries or any(e.get("platform") != "Mac" or e.get("channel") != channel for e in entries):
            raise ValueError(f"missing or invalid Mac {channel} release data")
        current.append(max(version(e["version"]) for e in entries))
    supported = [v for v in current if v[0] == pinned[0]]
    if not supported or pinned < max(supported):
        latest = ", ".join(".".join(map(str, v)) for v in current)
        raise ValueError(f"Chromium pin {pin} is behind a supported Mac security release (Stable / Extended: {latest})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pin", type=Path, default=Path(__file__).resolve().parents[1] / "CHROMIUM_PIN")
    parser.add_argument("--allow-outdated-engine", action="store_true")
    args = parser.parse_args()
    try:
        pin = [s.strip() for s in args.pin.read_text().splitlines() if s.strip() and not s.lstrip().startswith("#")][-1]
        releases = {}
        for channel in ("Stable", "Extended"):
            url = f"https://chromiumdash.appspot.com/fetch_releases?channel={channel}&platform=Mac&num=1"
            with urllib.request.urlopen(url, timeout=30) as response:
                releases[channel] = json.load(response)
        check(pin, releases)
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        if args.allow_outdated_engine:
            print(f"\n*** WARNING: ENGINE SECURITY RELEASE GATE OVERRIDDEN: {error} ***\n", file=sys.stderr)
            return 0
        print(f"release pin gate: {error}; update the engine or explicitly pass --allow-outdated-engine", file=sys.stderr)
        return 1
    print(f"release pin gate: Chromium {pin} is current on its supported Mac channel")
    return 0


if __name__ == "__main__":
    sys.exit(main())
