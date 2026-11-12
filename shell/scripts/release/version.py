#!/usr/bin/env python3
"""ReArc's version (engine/docs/RELEASE.md, "Versioning"): the one place that makes it.

    CFBundleShortVersionString  YYYY.MMDD.<build>   2026.1112.726   display only
    CFBundleVersion             <build>             726             what Sparkle compares

<build> is the commit count (`git rev-list --count`). The date is the release's: the date
in its RELEASES.md heading, which `release.sh --dmg` requires. A build that is not a
release (--qa, --worktree, development bundles) takes the date of the commit it is built
from, in RELEASE_TIME_ZONE.

  display --date YYYY-MM-DD --build N
      Prints the display version.
  commit [--repo DIR] [--revision REV]
      Prints "<display> <build>" for REV, dated by its commit (not a release).
  release [--repo DIR] [--revision REV]
      Prints "<display> <build>" for REV, dated by its entry in RELEASES.md at REV,
      which must carry the heading `## ReArc <display> — <YYYY-MM-DD>` (check-notes).
  check-notes FILE --build N
      Checks every `## ReArc` heading in FILE and prints the display version of the
      entry for build N. Entries before this format may keep the old heading,
      `## ReArc 0.1.0 (677) — 2026-11-11`; the entry for N must have the new one.
  dmg-name DISPLAY BUILD
      Prints the DMG's file name: ReArc-<display>.dmg (ReArc-<version>-<build>.dmg for
      a version from before this format).
  tag DISPLAY
      Prints the git tag of the release: v<display>.

No network. Reads git only for `commit` and `release`.
"""
import argparse
import datetime
import re
import subprocess
import sys
import zoneinfo

# Digits of <build> in the display version: 0 writes it as it is (726); 5 would make it 00726.
BUILD_DIGITS = 0
# Where the day of a commit is counted for builds that are not releases.
RELEASE_TIME_ZONE = "Asia/Dubai"
DASH = "—"

BUILD = re.compile(r"[1-9][0-9]{0,8}")
DATE = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})")
NEW_HEADING = re.compile(r"## ReArc ([0-9]{4})\.([0-9]{2})([0-9]{2})\.([0-9]{1,9}) " + DASH + r" ([0-9]{4}-[0-9]{2}-[0-9]{2})")
OLD_HEADING = re.compile(r"## ReArc ([0-9]+\.[0-9]+\.[0-9]+) \(([1-9][0-9]{0,8})\) " + DASH + r" ([0-9]{4}-[0-9]{2}-[0-9]{2})")
DISPLAY = re.compile(r"[0-9]{4}\.[0-9]{4}\.[0-9]{1,9}")


class VersionError(Exception):
    pass


def build_number(text, what="build"):
    if not BUILD.fullmatch(str(text)):
        raise VersionError(f"{what} is not a build number: {text!r}")
    return int(text)


def parse_date(text):
    match = DATE.fullmatch(text or "")
    try:
        if not match:
            raise ValueError
        return datetime.date(*map(int, match.groups()))
    except ValueError:
        raise VersionError(f"not a date (YYYY-MM-DD): {text!r}")


def display(date, build):
    """2026.1112.726 for build 726 released on 2026-11-12."""
    build = build_number(build)
    return f"{date.year:04d}.{date.month:02d}{date.day:02d}.{str(build).zfill(BUILD_DIGITS)}"


def commit_date(timestamp):
    """The day of a commit's Unix time in RELEASE_TIME_ZONE."""
    moment = datetime.datetime.fromtimestamp(int(timestamp), datetime.timezone.utc)
    return moment.astimezone(zoneinfo.ZoneInfo(RELEASE_TIME_ZONE)).date()


def headings(text):
    return [line.rstrip() for line in text.splitlines() if line.startswith("## ReArc ")]


def check_notes(text, build):
    """The display version of the entry for `build`, after checking every ReArc heading."""
    build = build_number(build)
    expected = f"## ReArc <YYYY.MMDD>.{str(build).zfill(BUILD_DIGITS)} {DASH} <YYYY-MM-DD>"
    seen = {}
    found = None
    for heading in headings(text):
        new, old = NEW_HEADING.fullmatch(heading), OLD_HEADING.fullmatch(heading)
        if new:
            year, month, day, number, dated = new.groups()
            date = parse_date(dated)
            entry = int(number)
            version = display(date, entry)
            if heading != f"## ReArc {version} {DASH} {dated}":
                raise VersionError(f"\"{heading}\": the version must be the heading's date and the build, "
                                   f"\"## ReArc {version} {DASH} {dated}\"")
        elif old:
            parse_date(old.group(3))
            entry = int(old.group(2))
            if entry == build:
                date = old.group(3)
                raise VersionError(f"\"{heading}\" has the old form; the entry for build {build} is headed "
                                   f"\"## ReArc {display(parse_date(date), build)} {DASH} {date}\"")
        else:
            raise VersionError(f"\"{heading}\" is not a release heading ({expected})")
        if entry in seen:
            raise VersionError(f"build {entry} has two entries: \"{seen[entry]}\" and \"{heading}\"")
        seen[entry] = heading
        if entry == build:
            found = version
    if found is None:
        raise VersionError(f"RELEASES.md has no \"{expected}\" entry for build {build}; commit the release notes first")
    return found


def dmg_name(version, build):
    build = build_number(build)
    if DISPLAY.fullmatch(version):
        if int(version.rsplit(".", 1)[1]) != build:
            raise VersionError(f"version {version} is not build {build}'s")
        return f"ReArc-{version}.dmg"
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        return f"ReArc-{version}-{build}.dmg"
    raise VersionError(f"not a ReArc version for build {build}: {version!r}")


def tag(version):
    if not DISPLAY.fullmatch(version):
        raise VersionError(f"not a ReArc version: {version!r}")
    return f"v{version}"


def git(repo, *args):
    result = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise VersionError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def main(argv):
    parser = argparse.ArgumentParser(description="ReArc's version")
    sub = parser.add_subparsers(dest="command", required=True)
    display_parser = sub.add_parser("display")
    display_parser.add_argument("--date", required=True)
    display_parser.add_argument("--build", required=True)
    for name in ("commit", "release"):
        source = sub.add_parser(name)
        source.add_argument("--repo", default=".")
        source.add_argument("--revision", default="HEAD")
    notes_parser = sub.add_parser("check-notes")
    notes_parser.add_argument("file")
    notes_parser.add_argument("--build", required=True)
    dmg_parser = sub.add_parser("dmg-name")
    dmg_parser.add_argument("version")
    dmg_parser.add_argument("build")
    tag_parser = sub.add_parser("tag")
    tag_parser.add_argument("version")
    args = parser.parse_args(argv)
    try:
        if args.command == "display":
            print(display(parse_date(args.date), args.build))
        elif args.command in ("commit", "release"):
            build = git(args.repo, "rev-list", "--count", args.revision).strip()
            if args.command == "commit":
                version = display(commit_date(git(args.repo, "log", "-1", "--format=%ct", args.revision).strip()), build)
            else:
                version = check_notes(git(args.repo, "show", f"{args.revision}:RELEASES.md"), build)
            print(version, build)
        elif args.command == "check-notes":
            with open(args.file, encoding="utf-8") as handle:
                print(check_notes(handle.read(), args.build))
        elif args.command == "dmg-name":
            print(dmg_name(args.version, args.build))
        else:
            print(tag(args.version))
    except (VersionError, OSError, UnicodeDecodeError) as error:
        print(f"version: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
