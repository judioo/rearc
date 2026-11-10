import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("keys", Path(__file__).with_name("google-api-keys.py"))
keys = importlib.util.module_from_spec(spec)
spec.loader.exec_module(keys)


class GoogleKeyTests(unittest.TestCase):
    def test_missing_and_placeholder_keys_fail(self):
        for key in ("", "dummytoken", "AIza", "not-a-key"):
            self.assertFalse(keys.real_key(key))

    def test_load_external_assignments_and_environment_override(self):
        with tempfile.TemporaryDirectory(prefix="rearc-keys-") as temp:
            root = Path(temp)
            file = root / "keys.gn"
            file.write_text('# External test fixture\ngoogle_api_key = "file-value"\ngoogle_default_client_id = "client"\n')
            with patch.dict(os.environ, {"REARC_GOOGLE_API_KEYS_FILE": str(file), "google_api_key": "env-value"}, clear=True):
                self.assertEqual(keys.credentials(root / "repo"), {"google_api_key": "env-value", "google_default_client_id": "client"})

    def test_in_repo_file_is_rejected_including_symlinks(self):
        with tempfile.TemporaryDirectory(prefix="rearc-keys-") as temp:
            root = Path(temp)
            file = root / "repo/keys.gn"
            file.parent.mkdir()
            file.write_text('google_api_key = "fixture"\n')
            link = root / "outside.gn"
            link.symlink_to(file)
            with patch.dict(os.environ, {"REARC_GOOGLE_API_KEYS_FILE": str(link)}, clear=True):
                with self.assertRaises(ValueError):
                    keys.credentials(file.parent)

    def test_other_gn_code_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="rearc-keys-") as temp:
            root = Path(temp)
            file = root / "keys.gn"
            for text in ('import("secrets.gn")', 'google_api_key = exec_script("tool")'):
                file.write_text(text)
                with patch.dict(os.environ, {"REARC_GOOGLE_API_KEYS_FILE": str(file)}, clear=True):
                    with self.assertRaises(ValueError):
                        keys.credentials(root / "repo")

    def test_binary_key_check_spans_blocks(self):
        with tempfile.TemporaryDirectory(prefix="rearc-keys-") as temp:
            file = Path(temp) / "binary"
            file.write_bytes(b"x" * (1024 * 1024 - 3) + b"a-test-key" + b"x")
            self.assertTrue(keys.contains(file, b"a-test-key"))
            self.assertFalse(keys.contains(file, b"absent"))


if __name__ == "__main__":
    unittest.main()
