"""ReArc's version from a date and a build, the RELEASES.md heading check, the DMG name and the
tag (version.py). No network; `commit` and `release` read a throwaway git repository."""
import datetime
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "version.py"
spec = importlib.util.spec_from_file_location("version", SCRIPT)
version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version)

DASH = "—"


def run(*args, cwd=None):
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *map(str, args)], capture_output=True, text=True, cwd=cwd)


def notes(*headings):
    body = "# ReArc releases\n\n    ## ReArc <VERSION> (<build>) — <YYYY-MM-DD>\n\n## Unreleased\n\n"
    return body + "".join(f"{heading}\n\n**New**\n- Something.\n\n" for heading in headings)


class DisplayVersionTests(unittest.TestCase):
    def test_date_and_build(self):
        self.assertEqual(version.display(datetime.date(2026, 11, 12), 726), "2026.1112.726")
        self.assertEqual(run("display", "--date", "2026-11-12", "--build", 726).stdout, "2026.1112.726\n")

    def test_month_and_day_keep_their_leading_zeros(self):
        self.assertEqual(version.display(datetime.date(2027, 1, 5), 741), "2027.0105.741")
        self.assertEqual(version.display(datetime.date(2027, 10, 1), 9), "2027.1001.9")

    def test_the_build_is_not_padded_unless_the_constant_says_so(self):
        self.assertEqual(version.BUILD_DIGITS, 0)
        self.assertEqual(version.display(datetime.date(2026, 11, 12), 1), "2026.1112.1")
        with mock.patch.object(version, "BUILD_DIGITS", 5):
            self.assertEqual(version.display(datetime.date(2026, 11, 12), 726), "2026.1112.00726")
            self.assertEqual(version.display(datetime.date(2026, 11, 12), 123456), "2026.1112.123456")

    def test_refuses_what_is_not_a_build_or_a_date(self):
        for build in (0, "-1", "7e2", "", "0726", "1234567890"):
            with self.subTest(build=build):
                self.assertRaises(version.VersionError, version.display, datetime.date(2026, 11, 12), build)
        for date in ("2026-13-01", "2026-02-30", "26-11-12", "2026-1-5", ""):
            with self.subTest(date=date):
                self.assertNotEqual(run("display", "--date", date, "--build", 726).returncode, 0)

    def test_a_commit_is_dated_in_dubai(self):
        # 2026-11-12 21:30 UTC is already 2026-11-13 01:30 in Dubai (UTC+4).
        late = int(datetime.datetime(2026, 11, 12, 21, 30, tzinfo=datetime.timezone.utc).timestamp())
        self.assertEqual(version.commit_date(late), datetime.date(2026, 11, 13))
        early = int(datetime.datetime(2026, 11, 12, 19, 59, tzinfo=datetime.timezone.utc).timestamp())
        self.assertEqual(version.commit_date(early), datetime.date(2026, 11, 12))
        self.assertEqual(version.RELEASE_TIME_ZONE, "Asia/Dubai")


class ReleaseNotesTests(unittest.TestCase):
    def check(self, text, build):
        return version.check_notes(text, build)

    def test_the_new_heading(self):
        text = notes(f"## ReArc 2026.1112.727 {DASH} 2026-11-12", f"## ReArc 0.1.0 (726) {DASH} 2026-11-12")
        self.assertEqual(self.check(text, 727), "2026.1112.727")

    def test_older_entries_keep_the_old_heading(self):
        text = notes(f"## ReArc 2026.1114.741 {DASH} 2026-11-14", f"## ReArc 2026.1112.727 {DASH} 2026-11-12",
                     f"## ReArc 0.1.0 (726) {DASH} 2026-11-12", f"## ReArc 0.1.0 (677) {DASH} 2026-11-11")
        self.assertEqual(self.check(text, 741), "2026.1114.741")

    def test_the_build_being_made_needs_the_new_heading(self):
        text = notes(f"## ReArc 0.1.0 (727) {DASH} 2026-11-12", f"## ReArc 0.1.0 (726) {DASH} 2026-11-12")
        with self.assertRaises(version.VersionError) as raised:
            self.check(text, 727)
        self.assertIn(f"\"## ReArc 2026.1112.727 {DASH} 2026-11-12\"", str(raised.exception), "it says what to write")

    def test_the_version_must_be_the_headings_date_and_the_build(self):
        cases = {
            f"## ReArc 2026.1113.727 {DASH} 2026-11-12": "the heading's date and the build",
            f"## ReArc 2026.1112.0727 {DASH} 2026-11-12": "the heading's date and the build",
            f"## ReArc 2026.1112.728 {DASH} 2026-11-12": "no",
            f"## ReArc 2026.1112.727 - 2026-11-12": "not a release heading",
            f"## ReArc 2026.1112.727 (727) {DASH} 2026-11-12": "old form",
            f"## ReArc 2026.1131.727 {DASH} 2026-11-31": "not a date",
        }
        for heading, message in cases.items():
            with self.subTest(heading):
                with self.assertRaises(version.VersionError) as raised:
                    self.check(notes(heading), 727)
                self.assertIn(message, str(raised.exception))

    def test_padding_follows_the_constant(self):
        with mock.patch.object(version, "BUILD_DIGITS", 5):
            self.assertEqual(self.check(notes(f"## ReArc 2026.1112.00727 {DASH} 2026-11-12"), 727), "2026.1112.00727")
            self.assertRaises(version.VersionError, self.check, notes(f"## ReArc 2026.1112.727 {DASH} 2026-11-12"), 727)

    def test_a_build_has_one_entry(self):
        text = notes(f"## ReArc 2026.1112.727 {DASH} 2026-11-12", f"## ReArc 0.1.0 (727) {DASH} 2026-11-11")
        with self.assertRaises(version.VersionError) as raised:
            self.check(text, 727)
        self.assertIn("old form", str(raised.exception))
        text = notes(f"## ReArc 2026.1112.726 {DASH} 2026-11-12", f"## ReArc 0.1.0 (726) {DASH} 2026-11-12",
                     f"## ReArc 2026.1112.727 {DASH} 2026-11-12")
        with self.assertRaises(version.VersionError) as raised:
            self.check(text, 727)
        self.assertIn("two entries", str(raised.exception))

    def test_the_current_trunk_notes_pass_for_older_builds(self):
        trunk = Path(__file__).resolve().parents[4] / "RELEASES.md"
        if not trunk.exists():
            self.skipTest("no RELEASES.md")
        text = trunk.read_text(encoding="utf-8")
        newest = version.headings(text)[0]
        built = int(version.OLD_HEADING.fullmatch(newest).group(2)) if version.OLD_HEADING.fullmatch(newest) \
            else int(version.NEW_HEADING.fullmatch(newest).group(4))
        stamped = notes(f"## ReArc 2026.1112.{built + 1} {DASH} 2026-11-12") + text.split("## Unreleased", 1)[1]
        self.assertEqual(self.check(stamped, built + 1), f"2026.1112.{built + 1}", "every older heading is accepted")


class NamesTests(unittest.TestCase):
    def test_dmg_name(self):
        self.assertEqual(version.dmg_name("2026.1112.726", 726), "ReArc-2026.1112.726.dmg")
        self.assertEqual(version.dmg_name("0.1.0", 677), "ReArc-0.1.0-677.dmg", "a build from before the change")
        self.assertRaises(version.VersionError, version.dmg_name, "2026.1112.725", 726)
        self.assertRaises(version.VersionError, version.dmg_name, "../evil", 726)
        self.assertEqual(run("dmg-name", "2026.1112.726", 726).stdout, "ReArc-2026.1112.726.dmg\n")

    def test_tag(self):
        self.assertEqual(run("tag", "2026.1112.726").stdout, "v2026.1112.726\n")
        self.assertNotEqual(run("tag", "0.1.0").returncode, 0)


class GitTests(unittest.TestCase):
    def repo(self, root, date):
        env = dict(os.environ, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date, GIT_CONFIG_GLOBAL="/dev/null",
                   GIT_CONFIG_NOSYSTEM="1")
        git = lambda *args: subprocess.run(["git", "-C", root, *args], check=True, capture_output=True, env=env)
        git("init", "-q")
        git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "one")
        return git, env

    def test_commit_and_release(self):
        with tempfile.TemporaryDirectory(prefix="rearc-version-test-") as root:
            git, env = self.repo(root, "2026-11-12T22:00:00+00:00")
            Path(root, "RELEASES.md").write_text(notes(f"## ReArc 2026.1114.2 {DASH} 2026-11-14"), encoding="utf-8")
            git("add", "RELEASES.md")
            git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "notes")
            commit = run("commit", "--repo", root)
            self.assertEqual(commit.stdout, "2026.1113.2 2\n", "the commit's Dubai day, not its UTC day")
            release = run("release", "--repo", root)
            self.assertEqual(release.stdout, "2026.1114.2 2\n", "the heading's date")
            older = run("release", "--repo", root, "--revision", "HEAD~1")
            self.assertNotEqual(older.returncode, 0)


if __name__ == "__main__":
    unittest.main()
