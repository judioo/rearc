"""check-fieldtrial-binary.py on a synthetic binary and config (security RC-0.1.0-602 T-11,
inverted for 608: the testing config must be in the binary)."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-fieldtrial-binary.py"


class CheckFieldTrialBinaryTests(unittest.TestCase):
    def run_check(self, names_in_binary):
        with tempfile.TemporaryDirectory(prefix="rearc-fieldtrial-test-") as temp:
            root = Path(temp)
            studies = [f"ReArcFixtureStudyNumber{index:03d}" for index in range(20)]
            config = {name: [{"platforms": ["mac", "windows"], "experiments": [{"name": "Enabled"}]}] for name in studies}
            config["AndroidOnlyStudyName"] = [{"platforms": ["android"], "experiments": [{"name": "Enabled"}]}]
            config["Short"] = [{"platforms": ["mac"], "experiments": [{"name": "Enabled"}]}]
            (root / "config.json").write_text(json.dumps(config))
            binary = b"\0junk\0" + b"".join(name.encode() + b"\0" for name in studies[:names_in_binary])
            # A study name inside a longer string is not the config's own copy.
            binary += b"prefix" + studies[-1].encode() + b"suffix\0"
            (root / "framework").write_bytes(binary)
            return subprocess.run([sys.executable, "-I", SCRIPT, str(root / "framework"), str(root / "config.json")],
                                  capture_output=True, text=True, timeout=60)

    def test_a_binary_with_the_testing_config_passes(self):
        result = self.run_check(20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS: 20 of 20", result.stdout)

    def test_names_used_elsewhere_alone_fail(self):
        # Build 605: the config was off and only names Chromium uses elsewhere remained.
        result = self.run_check(3)
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: 3 of 20", result.stderr)
        self.assertIn("without the field-trial testing config", result.stderr)

    def test_the_threshold_is_half(self):
        self.assertEqual(self.run_check(10).returncode, 0)
        self.assertEqual(self.run_check(9).returncode, 1)


if __name__ == "__main__":
    unittest.main()
