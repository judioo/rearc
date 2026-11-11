"""check-safe-browsing.sh against a stub app and a stub `open`: no LaunchServices, no ReArc."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-safe-browsing.sh"

# Stands in for `open -n -g --env K=V --stdout F --stderr F -a APP --args ...`: runs the
# app's executable in the background with that environment, as LaunchServices would.
FAKE_OPEN = r"""#!/bin/bash
envs=(); app=""; out=/dev/null
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-g) ;;
    --env) envs+=("$2"); shift ;;
    --stdout|--stderr) out="$2"; shift ;;
    -a) app="$2"; shift ;;
    --args) shift; break ;;
  esac
  shift
done
printf 'open:%s\n' "$app" >> "$TEST_LOG"
env "${envs[@]}" "$app/Contents/MacOS/ReArc" "$@" >>"$out" 2>&1 &
exit 0
"""

# The "browser": stores a list after STUB_DELAY seconds (STUB_BYTES of it), or exits at once
# with STUB_EXIT; records that it was asked to quit.
STUB_APP = r"""#!/bin/bash
trap 'echo terminated >> "$TEST_LOG"; exit 0' TERM
printf 'args:%s\n' "$*" >> "$TEST_LOG"
printf 'data:%s\n' "$REARC_DATA_DIR" >> "$TEST_LOG"
[[ -n ${STUB_EXIT:-} ]] && exit "$STUB_EXIT"
if [[ -n ${STUB_DELAY:-} ]]; then
  sleep "$STUB_DELAY" & wait $!
  mkdir -p "$REARC_DATA_DIR/Chromium/Safe Browsing"
  head -c "${STUB_BYTES:-64}" /dev/zero > "$REARC_DATA_DIR/Chromium/Safe Browsing/UrlSoceng.store"
fi
while true; do sleep 1; done
"""


class CheckSafeBrowsingTests(unittest.TestCase):
    def run_check(self, root, timeout="4", **stub):
        tools = root / "bin"
        tools.mkdir()
        (tools / "open").write_text(FAKE_OPEN)
        app = root / "Rel ease" / "ReArc.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "MacOS" / "ReArc").write_text(STUB_APP)
        for path in [tools / "open", app / "Contents" / "MacOS" / "ReArc"]:
            path.chmod(0o755)
        log = root / "calls"
        log.touch()
        tmp = root / "tmp"
        tmp.mkdir()
        env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", TEST_LOG=str(log), TMPDIR=str(tmp),
                   REARC_SB_TIMEOUT=timeout, REARC_SB_POLL="1", REARC_SB_LAUNCH_WAIT="5", **stub)
        result = subprocess.run(["bash", SCRIPT, str(app)], capture_output=True, text=True, env=env, timeout=120)
        return result, log.read_text().splitlines(), tmp

    def test_passes_once_a_list_is_stored_and_quits_the_instance(self):
        with tempfile.TemporaryDirectory(prefix="rearc-sb-test-") as temp:
            result, calls, tmp = self.run_check(Path(temp), STUB_DELAY="2")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS: 1 list store(s)", result.stdout)
            self.assertIn("terminated", calls)
            args = next(c for c in calls if c.startswith("args:"))
            self.assertIn("--no-onboarding", args)
            data = next(c for c in calls if c.startswith("data:"))[5:]
            self.assertTrue(data.startswith(str(tmp)), "a throwaway data dir, never the user's")
            self.assertIn(f"--user-data-dir={data}/Chromium", args)
            self.assertFalse(Path(data).exists(), "removed after a pass")

    def test_fails_when_no_list_arrives_and_keeps_the_data(self):
        with tempfile.TemporaryDirectory(prefix="rearc-sb-test-") as temp:
            result, calls, _ = self.run_check(Path(temp), timeout="3", STUB_DELAY="60")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAIL: no Safe Browsing list stored", result.stderr)
            self.assertIn("terminated", calls)
            data = next(c for c in calls if c.startswith("data:"))[5:]
            self.assertTrue(Path(data).exists(), "kept for inspection")

    def test_an_empty_store_is_not_a_list(self):
        with tempfile.TemporaryDirectory(prefix="rearc-sb-test-") as temp:
            result, _, _ = self.run_check(Path(temp), timeout="4", STUB_DELAY="1", STUB_BYTES="0")
            self.assertNotEqual(result.returncode, 0)

    def test_fails_when_the_instance_exits_early(self):
        with tempfile.TemporaryDirectory(prefix="rearc-sb-test-") as temp:
            result, _, _ = self.run_check(Path(temp), timeout="10", STUB_EXIT="3")
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue("did not appear" in result.stderr or "exited before" in result.stderr, result.stderr)


if __name__ == "__main__":
    unittest.main()
