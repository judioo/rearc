import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("gate", Path(__file__).with_name("check-release-pin.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ReleasePinTests(unittest.TestCase):
    def releases(self):
        return {c: [{"channel": c, "platform": "Mac", "version": v}] for c, v in (
            ("Stable", "157.0.8103.51"), ("Extended", "156.0.8078.96"))}

    def test_latest_extended_is_supported(self):
        gate.check("156.0.8078.96", self.releases())

    def test_security_patch_behind_fails(self):
        with self.assertRaises(ValueError):
            gate.check("156.0.8078.88", self.releases())

    def test_unsupported_milestone_fails(self):
        with self.assertRaises(ValueError):
            gate.check("155.0.8000.999", self.releases())

    def test_latest_stable_is_supported(self):
        gate.check("157.0.8103.51", self.releases())

    def test_missing_or_wrong_platform_fails_closed(self):
        for entries in ([], [{"channel": "Extended", "platform": "Windows", "version": "156.0.8078.96"}]):
            releases = self.releases()
            releases["Extended"] = entries
            with self.assertRaises(ValueError):
                gate.check("156.0.8078.96", releases)

    def test_numeric_version_comparison(self):
        with self.assertRaises(ValueError):
            gate.check("156.0.8078.9", self.releases())


if __name__ == "__main__":
    unittest.main()
