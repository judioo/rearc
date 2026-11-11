"""Release pipeline contract without accessing Keychain or building/launching apps."""
import base64
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "generate-appcast.sh"
VERIFY = Path(__file__).resolve().parents[1] / "verify-appcast.sh"


def openssl():
    for candidate in [os.environ.get("REARC_OPENSSL"), "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl",
                      shutil.which("openssl")]:
        if candidate and os.access(candidate, os.X_OK):
            version = subprocess.run([candidate, "version"], capture_output=True, text=True).stdout
            if version.startswith("OpenSSL ") and int(version.split()[1].split(".")[0]) >= 3:
                return candidate
    return None


OPENSSL = openssl()

# Appends a Sparkle signature block over the file's current bytes, as Sparkle does.
SIGN = r"""sign_feed() {
  local feed="$1" length sig
  length=$(wc -c < "$feed" | tr -d ' ')
  sig=$("$OPENSSL" pkeyutl -sign -inkey "$TEST_KEY" -rawin -in "$feed" | base64)
  [[ -n ${TEST_BAD_SIGNATURE:-} ]] && sig="$TEST_BAD_SIGNATURE"
  printf '<!-- sparkle-signatures:\nedSignature: %s\nlength: %s\n-->\n' "$sig" "$length" >> "$feed"
}
"""


@unittest.skipIf(OPENSSL is None, "needs OpenSSL 3 for Ed25519")
class AppcastSigningTests(unittest.TestCase):
    def tools(self, root, signed_by_generate, sign_update_signs=True):
        tools = root / "tools"
        tools.mkdir()
        key = root / "test-key.pem"
        subprocess.run([OPENSSL, "genpkey", "-algorithm", "ed25519", "-out", str(key)], check=True)
        der = subprocess.run([OPENSSL, "pkey", "-in", str(key), "-pubout", "-outform", "DER"],
                             capture_output=True, check=True).stdout
        public = base64.b64encode(der[-32:]).decode()
        (root / "public-key.txt").write_text(public + "\n")
        (tools / "generate_keys").write_text(f"#!/bin/bash\nprintf '%s' '{public}'\n")
        (tools / "generate_appcast").write_text(
            '#!/bin/bash\n' + SIGN + 'printf "generate:%s\\n" "$*" >> "$TEST_LOG"\n'
            'while [[ $# -gt 0 ]]; do\n'
            '  if [[ $1 == -o ]]; then shift; printf "<rss version=\\"2.0\\"><channel/></rss>" > "$1"; '
            + ('sign_feed "$1"; ' if signed_by_generate else '') + 'fi\n'
            '  shift\ndone\n'
        )
        (tools / "sign_update").write_text(
            '#!/bin/bash\n' + SIGN + 'printf "sign:%s\\n" "$*" >> "$TEST_LOG"\n'
            + ('sign_feed "${@: -1}"\n' if sign_update_signs else '')
        )
        for tool in tools.iterdir():
            tool.chmod(0o755)
        return tools, key

    def run_script(self, root, signed_by_generate, sign_update_signs=True, bad_signature=None):
        tools, key = self.tools(root, signed_by_generate, sign_update_signs)
        archives = root / "archives with spaces"
        archives.mkdir()
        log = root / "calls"
        log.touch()
        env = dict(os.environ, REARC_SPARKLE_TOOLS=str(tools), TEST_LOG=str(log), TEST_KEY=str(key), OPENSSL=OPENSSL,
                   REARC_OPENSSL=OPENSSL, REARC_SPARKLE_PUBLIC_KEY_FILE=str(root / "public-key.txt"))
        if bad_signature:
            env["TEST_BAD_SIGNATURE"] = bad_signature
        result = subprocess.run(["bash", SCRIPT, archives, "beta"], env=env, capture_output=True, text=True)
        return result, archives, log.read_text().splitlines()

    def test_signs_with_rearc_keychain_account_when_generate_did_not(self):
        with tempfile.TemporaryDirectory(prefix="rearc-appcast-test-") as temp:
            result, archives, calls = self.run_script(Path(temp), signed_by_generate=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(calls), 2)
            self.assertIn("--account ReArc", calls[0])
            self.assertIn("--channel beta", calls[0])
            self.assertTrue(calls[1].startswith("sign:--account ReArc "), calls[1])
            self.assertIn("sparkle-signatures", (archives / "appcast.xml").read_text())

    def test_keeps_the_signature_generate_appcast_embedded(self):
        # sign_update is a separate binary with its own Keychain grant; skip it when not needed.
        with tempfile.TemporaryDirectory(prefix="rearc-appcast-test-") as temp:
            result, archives, calls = self.run_script(Path(temp), signed_by_generate=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(calls), 1)
            self.assertIn("sparkle-signatures", (archives / "appcast.xml").read_text())

    def test_a_bad_signature_fails_and_writes_no_feed(self):
        with tempfile.TemporaryDirectory(prefix="rearc-appcast-test-") as temp:
            junk = base64.b64encode(b"\0" * 64).decode()
            result, archives, _ = self.run_script(Path(temp), signed_by_generate=True, bad_signature=junk)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not verify", result.stderr)
            self.assertFalse((archives / "appcast.xml").exists(), "no unsigned or unverified feed in the upload folder")

    def test_a_failed_signing_writes_no_feed(self):
        with tempfile.TemporaryDirectory(prefix="rearc-appcast-test-") as temp:
            result, archives, _ = self.run_script(Path(temp), signed_by_generate=False, sign_update_signs=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((archives / "appcast.xml").exists())

    def test_verify_refuses_appended_content_and_another_key(self):
        with tempfile.TemporaryDirectory(prefix="rearc-appcast-test-") as temp:
            root = Path(temp)
            result, archives, _ = self.run_script(root, signed_by_generate=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            feed = archives / "appcast.xml"
            public = (root / "public-key.txt").read_text().strip()
            env = dict(os.environ, REARC_OPENSSL=OPENSSL)
            ok = subprocess.run(["bash", VERIFY, feed, public], env=env, capture_output=True, text=True)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            shipped = subprocess.run(["bash", VERIFY, feed], env=env, capture_output=True, text=True)
            self.assertNotEqual(shipped.returncode, 0, "the test key is not the shipped key")
            feed.write_text(feed.read_text() + "<item>injected</item>\n")
            tampered = subprocess.run(["bash", VERIFY, feed, public], env=env, capture_output=True, text=True)
            self.assertNotEqual(tampered.returncode, 0)

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
