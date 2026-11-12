"""Critical and required updates in the feed (UPDATE-NOTICE.md §3): appcast-marker.py on its own,
and generate-appcast.sh --critical / --required-below with stub Sparkle tools. No Keychain, no
network, no app."""
import base64
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_generate_appcast import OPENSSL, SIGN  # noqa: E402

RELEASE = Path(__file__).resolve().parents[1]
MARKER = RELEASE / "appcast-marker.py"
GENERATE = RELEASE / "generate-appcast.sh"
VERIFY = RELEASE / "verify-appcast.sh"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REARC = "https://rearc.imara.ae/xml-namespaces/update"

# A feed as generate_appcast 2.10.1 writes it (pretty-printed, sign warning first), with the
# previous release and the new one.
FEED = """<?xml version="1.0" standalone="yes"?>
<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires re-signing this file with generate_appcast or sign_update! The signed signature will be embedded at the end of this file.
-->
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>ReArc</title>
        <item>
            <title>0.1.0</title>
            <pubDate>Thu, 12 Nov 2026 10:00:00 +0000</pubDate>
            <sparkle:version>{version}</sparkle:version>
            <sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
{critical}            <enclosure url="https://rearc.imara.ae/updates/ReArc-0.1.0-{version}.dmg" length="123" type="application/octet-stream" sparkle:edSignature="c2lnbmF0dXJl"/>
        </item>
        <item>
            <title>0.1.0</title>
            <pubDate>Wed, 11 Nov 2026 10:00:00 +0000</pubDate>
            <sparkle:version>677</sparkle:version>
            <sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>
            <enclosure url="https://rearc.imara.ae/updates/ReArc-0.1.0-677.dmg" length="122" type="application/octet-stream" sparkle:edSignature="b2xk"/>
        </item>
    </channel>
</rss>
"""


def feed(version=700, critical=False):
    line = "            <sparkle:criticalUpdate></sparkle:criticalUpdate>\n" if critical else ""
    return FEED.format(version=version, critical=line)


def run(*args, env=None):
    return subprocess.run([sys.executable, "-I", str(MARKER), *map(str, args)], capture_output=True, text=True, env=env)


def sparkle_view(data):
    """What Sparkle reads of each item: its Sparkle-namespace and plain RSS children."""
    root = ET.fromstring(data)
    return [[(child.tag, child.text, sorted(child.attrib.items())) for child in item
             if not child.tag.startswith(f"{{{REARC}}}")] for item in root.iter("item")]


class MarkerTests(unittest.TestCase):
    def stamp(self, text, *args):
        with tempfile.TemporaryDirectory(prefix="rearc-marker-test-") as temp:
            path = Path(temp) / "appcast.xml"
            path.write_text(text)
            result = run("stamp", path, *args)
            return result, path.read_bytes()

    def test_stamp_adds_only_the_marker_and_the_namespace(self):
        before = feed().encode()
        result, after = self.stamp(feed(), "--version", 700, "--required-below", 690)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = before.replace(b'<rss xmlns:sparkle=', f'<rss xmlns:rearc="{REARC}" xmlns:sparkle='.encode()).replace(
            b"<sparkle:version>700</sparkle:version>\n",
            b"<sparkle:version>700</sparkle:version>\n            <rearc:requiredBelow>690</rearc:requiredBelow>\n")
        self.assertEqual(after, expected, "every other byte stays")
        item = ET.fromstring(after).find("channel/item")
        self.assertEqual(item.findtext(f"{{{REARC}}}requiredBelow"), "690")
        self.assertEqual(sparkle_view(after), sparkle_view(before), "nothing Sparkle reads changes")

    def test_stamp_refuses(self):
        cases = [
            (feed(), ("--version", 700, "--required-below", 701), "above the new build"),
            (feed(), ("--version", 800, "--required-below", 700), "expected one item"),
            (feed(), ("--version", 700, "--required-below", "soon"), "not a build number"),
            (feed() + "<!-- sparkle-signatures:\nedSignature: x\nlength: 1\n-->\n", ("--version", 700, "--required-below", 690), "signed"),
            (feed().replace("<rss ", '<rss xmlns:rearc="https://example.com/other" '), ("--version", 700, "--required-below", 690), "another namespace"),
        ]
        for text, args, message in cases:
            with self.subTest(message):
                result, after = self.stamp(text, *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(after, text.encode(), "a refused stamp writes nothing")

    def test_stamp_twice_is_refused(self):
        _, once = self.stamp(feed(), "--version", 700, "--required-below", 690)
        result, _ = self.stamp(once.decode(), "--version", 700, "--required-below", 650)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already has", result.stderr)

    def test_the_marker_survives_generate_appcasts_next_rewrite(self):
        # The next release's generate_appcast re-indents existing items (XMLDocument pretty print).
        _, stamped = self.stamp(feed(), "--version", 700, "--required-below", 690)
        reflowed = stamped.decode().replace("<rearc:requiredBelow>690</rearc:requiredBelow>",
                                            "<rearc:requiredBelow>\n                690\n            </rearc:requiredBelow>")
        self.check(reflowed, ok=True, args=("--version", 700, "--required-below", 690))

    def check(self, text, ok, args=(), message=None):
        with tempfile.TemporaryDirectory(prefix="rearc-marker-test-") as temp:
            path = Path(temp) / "appcast.xml"
            path.write_text(text)
            result = run("check", path, *args)
            if ok:
                self.assertEqual(result.returncode, 0, result.stderr)
            else:
                self.assertNotEqual(result.returncode, 0, text)
                if message:
                    self.assertIn(message, result.stderr)

    def test_check_accepts_plain_and_flagged_feeds(self):
        self.check(feed(), ok=True)
        self.check(feed(), ok=True, args=("--version", 700))
        self.check(feed(critical=True), ok=True, args=("--version", 700, "--critical"))
        self.check(feed(), ok=False, args=("--version", 700, "--critical"), message="not critical")
        self.check(feed(critical=True), ok=False, args=("--version", 700), message="is critical")
        self.check(feed(), ok=False, args=("--version", 701), message="no item")
        self.check("<rss version=\"2.0\"><channel/></rss>", ok=True)

    def test_check_refuses_malformed_markers(self):
        def marked(marker, rss=f'xmlns:rearc="{REARC}" '):
            return feed().replace("<rss ", f"<rss {rss}").replace(
                "<sparkle:version>700</sparkle:version>\n", f"<sparkle:version>700</sparkle:version>\n{marker}\n")
        self.check(marked("<rearc:requiredBelow>690</rearc:requiredBelow>"), ok=True, args=("--version", 700, "--required-below", 690))
        cases = {
            "not a build number": marked("<rearc:requiredBelow>soon</rearc:requiredBelow>"),
            "above its item": marked("<rearc:requiredBelow>701</rearc:requiredBelow>"),
            "2 rearc:requiredBelow": marked("<rearc:requiredBelow>690</rearc:requiredBelow><rearc:requiredBelow>680</rearc:requiredBelow>"),
            "unknown ReArc element": marked("<rearc:required>690</rearc:required>"),
            "ReArc's namespace is": marked("<other:requiredBelow>690</other:requiredBelow>", rss=f'xmlns:other="{REARC}" '),
            "holds elements": marked("<rearc:requiredBelow><b>690</b></rearc:requiredBelow>"),
            "direct child": marked("<title><rearc:requiredBelow>690</rearc:requiredBelow></title>"),
            "not well-formed": marked("<rearc:requiredBelow>690</rearc:requiredBelow>", rss=""),
        }
        for message, text in cases.items():
            with self.subTest(message):
                self.check(text, ok=False, message=message)


@unittest.skipIf(OPENSSL is None, "needs OpenSSL 3 for Ed25519")
class GenerateLevelsTests(unittest.TestCase):
    """generate-appcast.sh with stub generate_appcast / sign_update that sign like Sparkle."""

    def tools(self, root):
        tools = root / "tools"
        tools.mkdir()
        key = root / "test-key.pem"
        subprocess.run([OPENSSL, "genpkey", "-algorithm", "ed25519", "-out", str(key)], check=True)
        der = subprocess.run([OPENSSL, "pkey", "-in", str(key), "-pubout", "-outform", "DER"], capture_output=True, check=True).stdout
        public = base64.b64encode(der[-32:]).decode()
        (root / "public-key.txt").write_text(public + "\n")
        (root / "template.xml").write_text(FEED)
        (tools / "generate_keys").write_text(f"#!/bin/bash\nprintf '%s' '{public}'\n")
        # Writes the feed for TEST_VERSION (critical when asked) and signs it, as 2.10.1 does.
        (tools / "generate_appcast").write_text(
            "#!/bin/bash\n" + SIGN + 'printf "generate:%s\\n" "$*" >> "$TEST_LOG"\n'
            'out=""; critical=""\n'
            'while [[ $# -gt 0 ]]; do\n'
            '  case "$1" in\n'
            '    -o) out="$2"; shift ;;\n'
            '    --critical-update-version) critical=1; printf "critical-version:[%s]\\n" "$2" >> "$TEST_LOG"; shift ;;\n'
            '  esac\n'
            '  shift\n'
            'done\n'
            "python3 -I -c 'import sys; t = open(sys.argv[1]).read(); "
            'line = "            <sparkle:criticalUpdate></sparkle:criticalUpdate>\\n" if sys.argv[4] else ""; '
            "open(sys.argv[2], \"w\").write(t.format(version=sys.argv[3], critical=line))' "
            '"$TEST_TEMPLATE" "$out" "$TEST_VERSION" "$critical"\n'
            'sign_feed "$out"\n')
        (tools / "sign_update").write_text("#!/bin/bash\n" + SIGN + 'printf "sign:%s\\n" "$*" >> "$TEST_LOG"\nsign_feed "${@: -1}"\n')
        for tool in tools.iterdir():
            tool.chmod(0o755)
        return tools, key, public

    def generate(self, root, *args, version=700):
        tools, key, public = self.tools(root)
        archives = root / "archives"
        archives.mkdir()
        log = root / "calls"
        log.touch()
        env = dict(os.environ, REARC_SPARKLE_TOOLS=str(tools), TEST_LOG=str(log), TEST_KEY=str(key), OPENSSL=OPENSSL,
                   REARC_OPENSSL=OPENSSL, REARC_SPARKLE_PUBLIC_KEY_FILE=str(root / "public-key.txt"),
                   TEST_TEMPLATE=str(root / "template.xml"), TEST_VERSION=str(version))
        result = subprocess.run(["bash", GENERATE, archives, "", *map(str, args)], env=env, capture_output=True, text=True)
        return result, archives / "appcast.xml", log.read_text().splitlines(), public

    def signed_bytes(self, feed_path):
        data = feed_path.read_bytes()
        length = int(data.rsplit(b"length: ", 1)[1].split(b"\n", 1)[0])
        return data[:length]

    def test_critical_is_sparkles_own_flag(self):
        with tempfile.TemporaryDirectory(prefix="rearc-levels-test-") as temp:
            result, feed_path, calls, _ = self.generate(Path(temp), "--critical", "--version", 700)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("critical-version:[]", calls, "critical for every older build")
            self.assertEqual(len([c for c in calls if c.startswith("sign:")]), 0, "generate_appcast's own signature stands")
            item = ET.fromstring(self.signed_bytes(feed_path)).find("channel/item")
            self.assertIsNotNone(item.find(f"{{{SPARKLE}}}criticalUpdate"))
            self.assertIsNone(item.find(f"{{{REARC}}}requiredBelow"))

    def test_required_below_is_stamped_and_signed_byte_for_byte(self):
        with tempfile.TemporaryDirectory(prefix="rearc-levels-test-") as temp:
            result, feed_path, calls, public = self.generate(Path(temp), "--required-below", 690, "--version", 700)
            self.assertEqual(result.returncode, 0, result.stderr)
            signs = [c for c in calls if c.startswith("sign:")]
            self.assertEqual(len(signs), 1)
            self.assertIn("--account ReArc", signs[0])
            self.assertIn("--disable-signing-warning", signs[0], "sign_update must not re-serialize the stamped feed")
            # The signed bytes are generate_appcast's feed plus exactly the marker line and namespace.
            expected = feed(700).replace("<rss ", f'<rss xmlns:rearc="{REARC}" ').replace(
                "<sparkle:version>700</sparkle:version>\n",
                "<sparkle:version>700</sparkle:version>\n            <rearc:requiredBelow>690</rearc:requiredBelow>\n")
            signed = self.signed_bytes(feed_path)
            self.assertEqual(signed, expected.encode())
            self.assertEqual(feed_path.read_bytes().count(b"<!-- sparkle-signatures:"), 1)
            self.assertEqual(sparkle_view(signed), sparkle_view(feed(700).encode()), "an older ReArc reads the same items")
            verify = subprocess.run(["bash", VERIFY, feed_path, public], env=dict(os.environ, REARC_OPENSSL=OPENSSL),
                                    capture_output=True, text=True)
            self.assertEqual(verify.returncode, 0, verify.stderr)

    def test_verify_refuses_a_signed_feed_with_a_malformed_marker(self):
        with tempfile.TemporaryDirectory(prefix="rearc-levels-test-") as temp:
            root = Path(temp)
            result, feed_path, _, public = self.generate(root, "--required-below", 690, "--version", 700)
            self.assertEqual(result.returncode, 0, result.stderr)
            # Re-sign a feed whose marker is not a build: the signature is good, the marker is not.
            bad = self.signed_bytes(feed_path).replace(b">690<", b">soon<")
            feed_path.write_bytes(bad)
            env = dict(os.environ, TEST_KEY=str(root / "test-key.pem"), OPENSSL=OPENSSL, TEST_LOG=str(root / "calls"))
            subprocess.run(["bash", root / "tools" / "sign_update", feed_path], env=env, check=True)
            verify = subprocess.run(["bash", VERIFY, feed_path, public], env=dict(os.environ, REARC_OPENSSL=OPENSSL),
                                    capture_output=True, text=True)
            self.assertNotEqual(verify.returncode, 0)
            self.assertIn("markers are malformed", verify.stderr)

    def test_critical_and_required_together(self):
        with tempfile.TemporaryDirectory(prefix="rearc-levels-test-") as temp:
            result, feed_path, _, _ = self.generate(Path(temp), "--critical", "--required-below", 700, "--version", 700)
            self.assertEqual(result.returncode, 0, result.stderr)
            item = ET.fromstring(self.signed_bytes(feed_path)).find("channel/item")
            self.assertIsNotNone(item.find(f"{{{SPARKLE}}}criticalUpdate"))
            self.assertEqual(item.findtext(f"{{{REARC}}}requiredBelow"), "700")

    def test_bad_levels_stop_before_generation(self):
        for args in [("--required-below", 701, "--version", 700), ("--required-below", "soon", "--version", 700),
                     ("--required-below", 690), ("--version", "7a"), ("--unknown",)]:
            with self.subTest(args), tempfile.TemporaryDirectory(prefix="rearc-levels-test-") as temp:
                result, feed_path, calls, _ = self.generate(Path(temp), *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse([c for c in calls if c.startswith("generate:")], "nothing generated")
                self.assertFalse(feed_path.exists())

    def test_a_missing_item_writes_no_feed(self):
        with tempfile.TemporaryDirectory(prefix="rearc-levels-test-") as temp:
            # generate_appcast made the item for 700; the release asked for 701.
            result, feed_path, _, _ = self.generate(Path(temp), "--critical", "--version", 701, version=700)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not carry the flags", result.stderr)
            self.assertFalse(feed_path.exists())


class ReleaseFlagsTests(unittest.TestCase):
    """release.sh refuses the flags without --appcast, before building anything."""

    def test_levels_need_appcast(self):
        script = RELEASE.parent / "release.sh"
        for args in [["--critical"], ["--required-below", "690"]]:
            result = subprocess.run(["bash", script, *args], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("require --appcast", result.stderr)
        result = subprocess.run(["bash", script, "--required-below", "x"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("needs a build number", result.stderr)


if __name__ == "__main__":
    unittest.main()
