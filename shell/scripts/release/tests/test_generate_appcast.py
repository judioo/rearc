"""Release pipeline contract without accessing Keychain or building/launching apps."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "generate-appcast.sh"


class AppcastSigningTests(unittest.TestCase):
    def run_script(self, root, signed_by_generate):
        tools = root / "tools"
        tools.mkdir()
        archives = root / "archives with spaces"
        archives.mkdir()
        expected = (SCRIPT.parent / "sparkle-public-key.txt").read_text().strip()
        (tools / "generate_keys").write_text(f"#!/bin/bash\nprintf '%s' '{expected}'\n")
        signature = "<!-- sparkle-signatures:\\nedSignature: x\\n-->" if signed_by_generate else ""
        (tools / "generate_appcast").write_text(
            '#!/bin/bash\nprintf "generate:%s\\n" "$*" >> "$TEST_LOG"\n'
            'while [[ $# -gt 0 ]]; do\n'
            f'  if [[ $1 == -o ]]; then shift; printf "<rss version=\\"2.0\\"><channel/></rss>{signature}" > "$1"; fi\n'
            '  shift\ndone\n'
        )
        (tools / "sign_update").write_text(
            '#!/bin/bash\nprintf "sign:%s\\n" "$*" >> "$TEST_LOG"\n'
            'printf "<!-- sparkle-signatures:\\nedSignature: y\\n-->" >> "${@: -1}"\n'
        )
        for tool in tools.iterdir():
            tool.chmod(0o755)
        log = root / "calls"
        env = dict(os.environ, REARC_SPARKLE_TOOLS=str(tools), TEST_LOG=str(log))
        subprocess.run(["bash", SCRIPT, archives, "beta"], env=env, check=True)
        return archives, log.read_text().splitlines()

    def test_signs_with_rearc_keychain_account_when_generate_did_not(self):
        with tempfile.TemporaryDirectory(prefix="rearc-appcast-test-") as temp:
            archives, calls = self.run_script(Path(temp), signed_by_generate=False)
            self.assertEqual(len(calls), 2)
            self.assertIn("--account ReArc", calls[0])
            self.assertIn("--channel beta", calls[0])
            self.assertEqual(calls[1], f"sign:--account ReArc {archives}/appcast.xml")

    def test_keeps_the_signature_generate_appcast_embedded(self):
        # sign_update is a separate binary with its own Keychain grant; skip it when not needed.
        with tempfile.TemporaryDirectory(prefix="rearc-appcast-test-") as temp:
            archives, calls = self.run_script(Path(temp), signed_by_generate=True)
            self.assertEqual(len(calls), 1)
            self.assertIn("sparkle-signatures", (archives / "appcast.xml").read_text())

    def test_mismatched_key_stops_before_generation(self):
        with tempfile.TemporaryDirectory(prefix="rearc-appcast-test-") as temp:
            tools = Path(temp)
            for name in ["generate_appcast", "generate_keys", "sign_update"]:
                path = tools / name
                path.write_text("#!/bin/bash\necho wrong-key\n")
                path.chmod(0o755)
            result = subprocess.run(["bash", SCRIPT, temp], capture_output=True, text=True,
                                    env=dict(os.environ, REARC_SPARKLE_TOOLS=temp))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match the shipped key", result.stderr)


if __name__ == "__main__":
    unittest.main()
