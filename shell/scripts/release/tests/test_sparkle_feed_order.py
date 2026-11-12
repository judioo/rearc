"""A feed with items from before and after the dated version (2026.1112.726), read the way Sparkle
2.10.1 reads it: an installed build is offered the newest item by `sparkle:version` against its own
CFBundleVersion, and the critical, major-upgrade and required levels compare build numbers. The
display version (`sparkle:shortVersionString`) takes no part. No network, no app.

The comparator and the item rules are ported from Sparkle 2.10.1: SUStandardVersionComparator.m
(compareVersion:toVersion:), SUAppcastDriver.m (bestItemFromAppcastItems:, isItemNewer:) and
SPUAppcastItemStateResolver.m (isCriticalUpdate…, isMinimumAutoupdateVersionOK…). ReArc's
rearc:requiredBelow is UpdateFeedFlags.urgency(forHostBuild:) in SidebarModel."""
import unicodedata
import unittest
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REARC = "https://rearc.imara.ae/xml-namespaces/update"
ASCENDING, SAME, DESCENDING = -1, 0, 1
NUMBER, STRING, PERIOD, PUNCTUATION, WHITESPACE, DASH = range(6)


def character_type(text):
    c = text[0]
    if text == ".":
        return PERIOD
    if text == "-":
        return DASH
    if unicodedata.category(c) == "Nd":
        return NUMBER
    if c.isspace():
        return WHITESPACE
    if unicodedata.category(c).startswith("P"):
        return PUNCTUATION
    return STRING


def is_separator(kind):
    return kind in (PERIOD, PUNCTUATION, WHITESPACE)


def same_class(a, b):
    return is_separator(a) and is_separator(b) if is_separator(a) else a == b


def split(version):
    parts = []
    if not version:
        return parts
    s, old = version[0], character_type(version[0])
    for character in version[1:]:
        new = character_type(character)
        if new == DASH:
            break
        if old != new or is_separator(old):
            parts.append(s)
            s = character
        else:
            s += character
        old = new
    parts.append(s)
    return parts


def leading_numbers_and_periods(parts):
    count = 0
    for part in parts:
        if character_type(part) not in (NUMBER, PERIOD):
            break
        count += 1
    return count


def balance(a, b):
    count_a, count_b = leading_numbers_and_periods(a), leading_numbers_and_periods(b)
    short, short_count, long, long_count = (b, count_b, a, count_a) if count_a > count_b else (a, count_a, b, count_b)
    for index in range(short_count, long_count):
        short.insert(index, "." if character_type(long[index]) == PERIOD else "0")


def compare(version_a, version_b):
    """SUStandardVersionComparator compareVersion:toVersion:."""
    parts_a, parts_b = split(version_a), split(version_b)
    balance(parts_a, parts_b)
    for part_a, part_b in zip(parts_a, parts_b):
        type_a, type_b = character_type(part_a), character_type(part_b)
        if same_class(type_a, type_b):
            if type_a == NUMBER:
                if int(part_a) != int(part_b):
                    return DESCENDING if int(part_a) > int(part_b) else ASCENDING
            elif type_a == STRING and part_a != part_b:
                return DESCENDING if part_a > part_b else ASCENDING
        elif type_a != STRING and type_b == STRING:
            return DESCENDING
        elif type_a == STRING and type_b != STRING:
            return ASCENDING
        else:
            return DESCENDING if type_a == NUMBER else ASCENDING
    if len(parts_a) != len(parts_b):
        n = min(len(parts_a), len(parts_b))
        longer_a = len(parts_a) > len(parts_b)
        missing = (parts_a if longer_a else parts_b)[n]
        shorter, larger = (ASCENDING, DESCENDING) if longer_a else (DESCENDING, ASCENDING)
        return shorter if character_type(missing) == STRING else larger
    return SAME


def items(feed):
    out = []
    for item in ET.fromstring(feed).iter("item"):
        critical = item.find(f"{{{SPARKLE}}}criticalUpdate")
        out.append({
            "version": item.findtext(f"{{{SPARKLE}}}version").strip(),
            "display": item.findtext(f"{{{SPARKLE}}}shortVersionString").strip(),
            "critical": None if critical is None else critical.get(f"{{{SPARKLE}}}version"),
            "has_critical": critical is not None,
            "minimum_autoupdate": (item.findtext(f"{{{SPARKLE}}}minimumAutoupdateVersion") or "").strip(),
            "required_below": (item.findtext(f"{{{REARC}}}requiredBelow") or "").strip(),
        })
    return out


def offer(feed, host_version):
    """What an install with CFBundleVersion `host_version` is offered, or None."""
    best = None
    for candidate in items(feed):
        if best is None or compare(best["version"], candidate["version"]) == ASCENDING:
            best = candidate
    if best is None or compare(host_version, best["version"]) != ASCENDING:
        return None
    critical = best["has_critical"] and (best["critical"] is None or compare(host_version, best["critical"]) == ASCENDING)
    major = bool(best["minimum_autoupdate"]) and compare(host_version, best["minimum_autoupdate"]) == ASCENDING
    required = bool(best["required_below"]) and int(host_version) < int(best["required_below"])
    return {"version": best["version"], "display": best["display"], "critical": critical, "major_upgrade": major,
            "required": required}


def item(version, display, levels=""):
    dmg = f"ReArc-{display}.dmg" if display.startswith("20") else f"ReArc-{display}-{version}.dmg"
    return f"""        <item>
            <title>{display}</title>
            <sparkle:version>{version}</sparkle:version>
            <sparkle:shortVersionString>{display}</sparkle:shortVersionString>
{levels}            <enclosure url="https://rearc.imara.ae/updates/{dmg}" length="1" type="application/octet-stream" sparkle:edSignature="eA=="/>
        </item>
"""


def mixed_feed(newest_levels="", newest_display="2026.1114.741"):
    # generate_appcast writes the newest first; Sparkle does not depend on the order.
    return f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:rearc="{REARC}" xmlns:sparkle="{SPARKLE}" version="2.0">
    <channel>
        <title>ReArc</title>
{item(677, "0.1.0")}{item(741, newest_display, newest_levels)}{item(726, "2026.1112.726")}{item(608, "0.1.0")}    </channel>
</rss>
"""


LEVELS = """            <sparkle:criticalUpdate sparkle:version="700"></sparkle:criticalUpdate>
            <sparkle:minimumAutoupdateVersion>650</sparkle:minimumAutoupdateVersion>
            <rearc:requiredBelow>690</rearc:requiredBelow>
"""


class ComparatorTests(unittest.TestCase):
    def test_build_numbers_compare_as_numbers(self):
        self.assertEqual(compare("677", "726"), ASCENDING)
        self.assertEqual(compare("9", "10"), ASCENDING, "not as text")
        self.assertEqual(compare("1000", "999"), DESCENDING)
        self.assertEqual(compare("726", "726"), SAME)

    def test_the_port_matches_sparkles_documented_cases(self):
        self.assertEqual(compare("1.0", "1.0.0"), SAME)
        self.assertEqual(compare("1.0b1", "1.0"), ASCENDING)
        self.assertEqual(compare("1.0.1", "1.0"), DESCENDING)
        self.assertEqual(compare("1.0-beta", "1.0"), SAME, "everything from a dash is ignored")


class MixedFeedTests(unittest.TestCase):
    def test_an_old_install_is_offered_the_newest_build(self):
        for host in ("677", "608"):
            with self.subTest(host=host):
                offered = offer(mixed_feed(), host)
                self.assertEqual(offered["version"], "741")
                self.assertEqual(offered["display"], "2026.1114.741")

    def test_newer_installs_are_offered_only_newer_builds(self):
        self.assertEqual(offer(mixed_feed(), "726")["version"], "741")
        self.assertIsNone(offer(mixed_feed(), "741"))
        self.assertIsNone(offer(mixed_feed(), "742"))

    def test_the_display_version_takes_no_part(self):
        # Display strings that would sort the other way change nothing Sparkle decides.
        for display in ("0.0.1", "0.1.0", "1999.0101.741"):
            with self.subTest(display=display):
                for host in ("608", "677", "726", "741"):
                    expected = offer(mixed_feed(LEVELS), host)
                    actual = offer(mixed_feed(LEVELS, newest_display=display), host)
                    if expected:
                        expected["display"] = display
                    self.assertEqual(actual, expected)

    def test_levels_compare_build_numbers(self):
        old = offer(mixed_feed(LEVELS), "608")
        self.assertEqual((old["critical"], old["major_upgrade"], old["required"]), (True, True, True))
        recent = offer(mixed_feed(LEVELS), "677")
        self.assertEqual((recent["critical"], recent["major_upgrade"], recent["required"]), (True, False, True))
        between = offer(mixed_feed(LEVELS), "695")
        self.assertEqual((between["critical"], between["major_upgrade"], between["required"]), (True, False, False))
        current = offer(mixed_feed(LEVELS), "726")
        self.assertEqual((current["critical"], current["major_upgrade"], current["required"]), (False, False, False))


if __name__ == "__main__":
    unittest.main()
