"""check-upgrade-data.py against a stub `open` that plays the browser: no LaunchServices, no ReArc.

The stub fetches the probe page the way a launched build would, checks the page is armed for
this run's label only, and reports what its store holds (a file in REARC_DATA_DIR) before
storing the new label, as the page does in local storage, IndexedDB, a cookie and Cache Storage.
"""
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-upgrade-data.py"
PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>%s<key>CFBundleVersion</key><string>%s</string>%s</dict></plist>
"""
RELEASE = "<key>ReArcRelease</key><true/>"
VERIFY = "<key>ReArcReleaseVerification</key><true/>"

# open -n -g -a APP --env K=V ... URL
FAKE_OPEN = r"""#!/usr/bin/env python3
import os, sys, urllib.parse, urllib.request
args = sys.argv[1:]
app = args[args.index("-a") + 1]
env = dict(a.split("=", 1) for i, a in enumerate(args) if i and args[i - 1] == "--env")
url = args[-1]
with open(os.environ["TEST_LOG"], "a") as log:
    log.write(f"open:{app} env:{','.join(sorted(env))}\n")
label = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["run"][0]
page = urllib.request.urlopen(url).read().decode()
if f"if (run !== '{label}') return;" not in page:
    sys.exit("the probe page is not armed for this run")
store = os.path.join(env["REARC_DATA_DIR"], "stub-store")
found = open(store).read() if os.path.exists(store) else "(none)"
values = {k: found for k in ("ls", "idb", "ck", "cache")}
if app in os.environ.get("STUB_LOSSY", ""):  # 605: local storage and IndexedDB read empty
    values["ls"] = values["idb"] = "(none)"
base = url.split("/probe.html")[0]
urllib.request.urlopen(base + "/report?" + urllib.parse.urlencode(dict(values, run=label))).read()
with open(store, "w") as f:
    f.write(label)
"""


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class CheckUpgradeDataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rearc-upgrade-data-test-")
        self.root = Path(self.temp.name)
        tools = self.root / "bin"
        tools.mkdir()
        (tools / "open").write_text(FAKE_OPEN)
        (tools / "sign").write_text('#!/bin/bash\nprintf "sign:%s\\n" "$*" >> "$TEST_LOG"\n')
        for tool in ["open", "sign"]:
            (tools / tool).chmod(0o755)
        self.log = self.root / "calls"
        self.log.touch()
        (self.root / "tmp").mkdir()
        self.env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", TEST_LOG=str(self.log),
                        TMPDIR=str(self.root / "tmp"), REARC_UPGRADE_SIGN=str(tools / "sign"),
                        REARC_UPGRADE_DATA_SETTLE="0", REARC_UPGRADE_DATA_PORT=str(free_port()))

    def tearDown(self):
        self.temp.cleanup()

    def app(self, name, build, keys=RELEASE):
        app = self.root / name / "ReArc.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "MacOS" / "ReArc").write_text("#!/bin/bash\n")
        (app / "Contents" / "MacOS" / "ReArc").chmod(0o755)
        (app / "Contents" / "Info.plist").write_text(PLIST % (keys, build, ""))
        return app

    def run_check(self, *args, **env):
        return subprocess.run([sys.executable, "-B", SCRIPT, "--timeout", "20", *map(str, args)],
                              capture_output=True, text=True, env=dict(self.env, **env), timeout=120)

    def opened(self):
        return [line.split()[0][len("open:"):] for line in self.log.read_text().splitlines() if line.startswith("open:")]

    def test_shipped_608_and_564_are_launched_as_they_are(self):
        new = self.app("new", "700", RELEASE + VERIFY)
        for build in ["564", "608"]:
            self.log.write_text("")
            old = self.app(f"rc{build}", build)
            result = self.run_check(old, new)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.opened(), [str(old), str(old), str(new)])
            self.assertIn("-> PASS", result.stdout)
            self.assertNotIn("sign:", self.log.read_text())

    def test_no_release_verification_variable_is_passed(self):
        # The verification bundle is told by its Info.plist; the variable only enables the
        # self-test and launch probe, which this check does not use.
        self.run_check(self.app("old", "608"), self.app("new", "700", RELEASE + VERIFY))
        self.assertIn("env:REARC_DATA_DIR\n", self.log.read_text())

    def test_a_later_shipped_previous_release_runs_as_a_signed_verification_copy(self):
        old = self.app("old", "609")
        new = self.app("new", "700", RELEASE + VERIFY)
        result = self.run_check(old, new)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        signed = next(line for line in self.log.read_text().splitlines() if line.startswith("sign:"))[len("sign:"):]
        self.assertNotEqual(signed, str(old))
        self.assertEqual(self.opened(), [signed, signed, str(new)])
        self.assertNotIn("ReArcReleaseVerification", (old / "Contents" / "Info.plist").read_text(), "the original is untouched")

    def test_a_shipped_new_build_after_608_is_refused_before_anything_launches(self):
        result = self.run_check(self.app("old", "608"), self.app("new", "700"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("shipped release bundle", result.stderr)
        self.assertEqual(self.opened(), [])

    def test_a_build_that_reads_site_data_as_empty_fails(self):
        lossy = self.app("rc605", "605")
        result = self.run_check(self.app("rc564", "564"), lossy, STUB_LOSSY=str(lossy))
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: lost ls, idb", result.stdout)

    def test_a_kept_profile_must_read_back_what_its_chain_stored_last(self):
        # A profile that ran 564 then 605, saved for later releases (REARC_UPGRADE_DATA_PROFILES).
        kept = self.root / "ran605"
        lossy = self.app("rc605", "605")
        self.run_check("--keep", kept, self.app("rc564", "564"), lossy, STUB_LOSSY=str(lossy))
        label = (kept / ".rearc-upgrade-data-label").read_text().strip()
        self.assertTrue(label.startswith("r3b605-"), label)
        new = self.app("new", "700", RELEASE + VERIFY)
        result = self.run_check("--profile", kept, new)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"ls={label}", result.stdout)
        self.assertIn("-> PASS", result.stdout)
        lossy_new = self.app("lossy-new", "701", RELEASE + VERIFY)
        result = self.run_check("--profile", kept, lossy_new, STUB_LOSSY=str(lossy_new))
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"expected {label}", result.stdout)


if __name__ == "__main__":
    unittest.main()
