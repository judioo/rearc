"""check-launch.sh against a stub app and a stub `open`: exit statuses and the crash baseline (S-10)."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "check-launch.sh"

# `open -n -W --env K=V -a APP --stderr LOG --stdout LOG [URL] --args ...`, run in the foreground.
FAKE_OPEN = r"""#!/bin/bash
envs=(); app=""; out=/dev/null; link=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-W|-g) ;;
    --env) envs+=("$2"); shift ;;
    --stdout|--stderr) out="$2"; shift ;;
    -a) app="$2"; shift ;;
    --args) shift; break ;;
    *) link="$1" ;;
  esac
  shift
done
env "${envs[@]}" STUB_LINK="$link" "$app/Contents/MacOS/ReArc" "$@" >>"$out" 2>&1
"""

STUB_APP = r"""#!/bin/bash
for arg in "$@"; do [[ $arg == --rearc-launch-probe=* ]] && result="${arg#*=}"; done
printf 'ready=1 engine=chromium source=infoPlist links=%s\n' "$STUB_LINK" > "$result"
if [[ -n ${STUB_CRASH:-} ]]; then
  printf '{"procPath" : "\\/Users\\/USER\\/x\\/ReArc.app\\/Contents\\/Frameworks\\/Chromium Helper"}' \
    > "$REARC_TEST_REPORTS/Chromium Helper (Renderer)-$RANDOM.ips"
fi
if [[ -n ${STUB_DUMP:-} ]]; then
  mkdir -p "$REARC_CRASHPAD_DIRS/completed"
  printf 'MDMP /Applications/%s/Contents/Frameworks/x' "$STUB_DUMP" > "$REARC_CRASHPAD_DIRS/completed/$RANDOM.dmp"
fi
if [[ -n ${STUB_WATCHDOG:-} ]]; then echo "Teardown watchdog expired"; exit 1; fi
echo "launch probe: ReArcEngineRun returned 0, shutdown ok"
"""

SHIPPED_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>ReArcRelease</key><true/>%s</dict></plist>
"""


class CheckLaunchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rearc-launch-test-")
        root = Path(self.temp.name)
        tools = root / "bin"
        tools.mkdir()
        (tools / "open").write_text(FAKE_OPEN)
        self.app = root / "ReArc.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        (self.app / "Contents" / "MacOS" / "ReArc").write_text(STUB_APP)
        for path in [tools / "open", self.app / "Contents" / "MacOS" / "ReArc"]:
            path.chmod(0o755)
        self.reports = root / "reports"
        self.reports.mkdir()
        (self.reports / "Chromium Helper (Renderer)-old.ips").write_text("ReArc.app")
        self.baseline = root / "baseline.txt"
        tmp = root / "tmp"
        tmp.mkdir()
        self.crashpad = root / "Crashpad"
        self.env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", TMPDIR=str(tmp),
                        REARC_CRASH_REPORTS=str(self.reports), REARC_TEST_REPORTS=str(self.reports),
                        REARC_CRASHPAD_DIRS=str(self.crashpad))

    def tearDown(self):
        self.temp.cleanup()

    def run_check(self, **stub):
        return subprocess.run(["bash", SCRIPT, "--crash-baseline", str(self.baseline), str(self.app)],
                              capture_output=True, text=True, env=dict(self.env, **stub), timeout=60)

    def test_a_clean_launch_passes_despite_old_reports(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_watchdog_alone_is_status_2(self):
        self.assertEqual(self.run_check(STUB_WATCHDOG="1").returncode, 2)

    def test_a_crash_in_the_first_attempt_fails_the_retry(self):
        first = self.run_check(STUB_WATCHDOG="1", STUB_CRASH="1")
        self.assertEqual(first.returncode, 1, "a crash is never only the watchdog")
        retry = self.run_check()
        self.assertEqual(retry.returncode, 1, "the baseline was taken before the first attempt")
        self.assertIn("new crash report", retry.stderr)

    def test_a_shipped_bundle_is_refused_before_anything_launches(self):
        # RC-0.1.0-602 T-04: it ignores the probe and the profile, so it would open the real data.
        (self.app / "Contents" / "Info.plist").write_text(SHIPPED_PLIST % "")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("shipped release bundle", result.stderr)
        self.assertFalse(self.baseline.exists(), "refused before the crash baseline or any launch")
        (self.app / "Contents" / "Info.plist").write_text(SHIPPED_PLIST % "<key>ReArcReleaseVerification</key><true/>")
        self.assertEqual(self.run_check().returncode, 0, "the bundle release.sh is verifying runs")

    def test_a_helper_minidump_in_crashpad_fails(self):
        # RC-0.1.0-602 T-11: renderer and GPU crashes go to Crashpad, not DiagnosticReports.
        result = self.run_check(STUB_DUMP="ReArc.app")
        self.assertEqual(result.returncode, 1)
        self.assertIn("new Chromium crash dump", result.stderr)

    def test_another_chromiums_minidump_is_ignored(self):
        self.assertEqual(self.run_check(STUB_DUMP="Chromium.app").returncode, 0)

    def test_other_browsers_helper_reports_are_ignored(self):
        self.run_check()  # writes the baseline
        (self.reports / "Chromium Helper (GPU)-x.ips").write_text('"procPath" : "\\/x\\/Chromium.app\\/y"')
        self.assertEqual(self.run_check().returncode, 0)


if __name__ == "__main__":
    unittest.main()
