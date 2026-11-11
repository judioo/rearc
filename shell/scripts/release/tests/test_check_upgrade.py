"""check-upgrade.sh: which bundles it will launch (security RC-0.1.0-602 T-04). No real app runs."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-upgrade.sh"
PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>ReArcRelease</key><true/><key>CFBundleVersion</key><string>%s</string>%s</dict></plist>
"""
VERIFY = "<key>ReArcReleaseVerification</key><true/>"


class CheckUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rearc-upgrade-test-")
        self.root = Path(self.temp.name)
        tools = self.root / "bin"
        tools.mkdir()
        self.log = self.root / "calls"
        self.log.touch()
        # `open` and the signer only record what they were asked; nothing launches.
        for name in ["open", "sign"]:
            (tools / name).write_text(f'#!/bin/bash\nprintf "{name}:%s\\n" "$*" >> "$TEST_LOG"\n')
            (tools / name).chmod(0o755)
        (self.root / "tmp").mkdir()
        self.env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", TEST_LOG=str(self.log),
                        TMPDIR=str(self.root / "tmp"), REARC_UPGRADE_SIGN=str(tools / "sign"), REARC_UPGRADE_SETTLE_SECONDS="0")

    def tearDown(self):
        self.temp.cleanup()

    def app(self, name, build, extra=""):
        app = self.root / name / "ReArc.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "MacOS" / "ReArc").write_text("#!/bin/bash\n")
        (app / "Contents" / "MacOS" / "ReArc").chmod(0o755)
        (app / "Contents" / "Info.plist").write_text(PLIST % (build, extra))
        return app

    def run_check(self, new, previous):
        return subprocess.run(["bash", SCRIPT, str(new), str(previous)], capture_output=True, text=True, env=self.env, timeout=120)

    def test_a_shipped_new_bundle_is_refused(self):
        result = self.run_check(self.app("new", "700"), self.app("old", "605"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("shipped release bundle", result.stderr)
        self.assertEqual(self.log.read_text(), "")

    def test_an_older_previous_release_is_launched_as_it_is(self):
        # 608, the hotfix, is the last shipped build that honours REARC_DATA_DIR.
        for build in ["564", "605", "608"]:
            self.log.write_text("")
            old = self.app(f"old-{build}", build)
            self.run_check(self.app(f"new-{build}", "700", VERIFY), old)
            calls = self.log.read_text()
            self.assertIn(f"open:-n -g {old} --env REARC_DATA_DIR=", calls, build)
            self.assertNotIn("sign:", calls, build)
            self.assertNotIn("REARC_RELEASE_VERIFICATION", calls, "no self-test or probe here")

    def test_the_cut_off_is_shared_with_the_stored_data_check(self):
        helper = SCRIPT.parent / "upgrade-bundles.sh"
        self.assertIn("LAST_DATA_DIR_BUILD=608", helper.read_text())
        for script in [SCRIPT, SCRIPT.parent / "check-upgrade-data.py"]:
            text = script.read_text()
            self.assertIn("upgrade-bundles.sh", text, script.name)
            self.assertNotRegex(text, r"-gt 6[0-9][0-9]|> 6[0-9][0-9]", f"{script.name} decides no cut-off of its own")

    def test_a_development_bundle_is_launched_as_it_is(self):
        old = self.app("old", "900")
        (old / "Contents" / "Info.plist").write_text(PLIST.replace("<key>ReArcRelease</key><true/>", "") % ("900", ""))
        self.run_check(self.app("new", "901", VERIFY), old)
        self.assertNotIn("sign:", self.log.read_text())

    def test_a_shipped_previous_release_gets_a_signed_verification_copy(self):
        old = self.app("old", "609")
        self.run_check(self.app("new", "700", VERIFY), old)
        calls = self.log.read_text().splitlines()
        sign = next(c for c in calls if c.startswith("sign:"))
        copy = sign[len("sign:"):]
        self.assertNotEqual(copy, str(old))
        self.assertTrue(any(c.startswith(f"open:-n -g {copy} ") for c in calls), calls)
        self.assertNotIn("ReArcReleaseVerification", (old / "Contents" / "Info.plist").read_text(), "the original is untouched")


if __name__ == "__main__":
    unittest.main()
