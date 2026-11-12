#!/usr/bin/env python3
"""ReArc's update levels in a Sparkle feed (docs/FEATURE-SPECS/UPDATE-NOTICE.md §3).

Critical is Sparkle's own <sparkle:criticalUpdate/> (generate_appcast
--critical-update-version). Required is ReArc's marker, in its own namespace:

    <rss xmlns:rearc="https://rearc.imara.ae/xml-namespaces/update" ...>
      <item> ... <sparkle:version>700</sparkle:version>
                 <rearc:requiredBelow>690</rearc:requiredBelow> ... </item>

"Required for builds below 690". Sparkle keeps an element outside its namespace
under its prefixed name with its text, so the prefix must be `rearc` and the
build is the element's text. Older ReArc builds ignore the element.

  stamp FEED --version BUILD --required-below N
      Insert the marker into the item for BUILD, in place: only the new line and
      the namespace declaration change, every other byte stays. FEED must be
      unsigned (generate-appcast.sh cuts the signature block off first and signs
      after).
  check FEED [--version BUILD [--display-version V]] [--critical] [--required-below N]
      Every ReArc marker in the feed is well formed (one per item, a build number
      at most the item's own, the `rearc` prefix on ReArc's namespace, nothing
      else in that namespace), and every item's sparkle:shortVersionString is
      digits and dots (version.py: 2026.1112.726 carries the item's own build;
      items from before that keep 0.1.0). With --version, the item for BUILD
      exists and carries exactly the flags given; with --display-version, it
      shows V and its enclosure is ReArc-V.dmg.

Reads only the bytes before a Sparkle signature block. No network, no Keychain.
"""
import argparse
import re
import sys
import xml.etree.ElementTree as ET

NAMESPACE = "https://rearc.imara.ae/xml-namespaces/update"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
PREFIX = "rearc"
MARKER = "requiredBelow"
SIGNATURE = b"<!-- sparkle-signatures:\n"
BUILD = re.compile(r"[1-9][0-9]{0,8}")
# Display only, so only its shape is checked: ReArc reads no decision from it.
SHORT_VERSION = re.compile(r"[0-9]{1,9}(\.[0-9]{1,9}){0,3}")
DATED_VERSION = re.compile(r"[0-9]{4}\.[0-9]{4}\.([0-9]{1,9})")


class FeedError(Exception):
    pass


def content(data):
    """The feed without its signature block (Sparkle's SPUExtractAppcastContent)."""
    at = data.rfind(SIGNATURE)
    return data if at < 0 else data[:at]


def build(text, what):
    if not BUILD.fullmatch(text or ""):
        raise FeedError(f"{what} is not a build number: {text!r}")
    return int(text)


def items(text):
    return list(re.finditer(r"<item\b[^>]*>.*?</item>", text, re.S))


def stamp(data, version, below):
    if SIGNATURE in data:
        raise FeedError("the feed is signed; stamp it before signing")
    version, below = build(version, "--version"), build(below, "--required-below")
    if below > version:
        raise FeedError(f"--required-below {below} is above the new build {version}; builds from {version} on would never see it")
    text = data.decode("utf-8")
    line = re.compile(r"^([ \t]*)<sparkle:version>\s*" + str(version) + r"\s*</sparkle:version>[ \t]*$", re.M)
    matches = [(m, line.search(m.group(0))) for m in items(text)]
    matches = [(m, v) for m, v in matches if v]
    if len(matches) != 1:
        raise FeedError(f"expected one item for build {version}, found {len(matches)}")
    item, version_line = matches[0]
    if f"{PREFIX}:{MARKER}" in item.group(0):
        raise FeedError(f"the item for build {version} already has a {PREFIX}:{MARKER}")
    at = item.start() + version_line.end()
    text = text[:at] + f"\n{version_line.group(1)}<{PREFIX}:{MARKER}>{below}</{PREFIX}:{MARKER}>" + text[at:]
    root = re.search(r"<rss\b[^>]*>", text)
    if not root:
        raise FeedError("no <rss> element")
    declared = re.search(r'\sxmlns:' + PREFIX + r'="([^"]*)"', root.group(0))
    if declared and declared.group(1) != NAMESPACE:
        raise FeedError(f"xmlns:{PREFIX} is declared for another namespace: {declared.group(1)!r}")
    if not declared:
        at = root.start() + len("<rss")
        text = text[:at] + f' xmlns:{PREFIX}="{NAMESPACE}"' + text[at:]
    stamped = text.encode("utf-8")
    check(stamped, version=str(version), critical=None, required_below=str(below))
    return stamped


def check(data, version=None, critical=False, required_below=None, display_version=None):
    """`critical` None: either way."""
    text = content(data).decode("utf-8")
    try:
        root = ET.fromstring(text)
    except ET.ParseError as error:
        raise FeedError(f"the feed is not well-formed XML: {error}")
    # Sparkle reads the marker by its prefixed name: ReArc's namespace must be `rearc`.
    for prefix, uri in re.findall(r'\sxmlns:([A-Za-z_][\w.-]*)="([^"]*)"', text):
        if (uri == NAMESPACE) != (prefix == PREFIX):
            raise FeedError(f"xmlns:{prefix}={uri!r}: ReArc's namespace is xmlns:{PREFIX}={NAMESPACE!r}")
    found = {}
    for item in root.iter("item"):
        item_version = item.findtext(f"{{{SPARKLE}}}version")
        markers = []
        for child in item.iter():
            if child.tag.startswith(f"{{{NAMESPACE}}}"):
                name = child.tag.split("}", 1)[1]
                if name != MARKER:
                    raise FeedError(f"unknown ReArc element {PREFIX}:{name} in the item for {item_version!r}")
                if child not in list(item):
                    raise FeedError(f"{PREFIX}:{MARKER} must be a direct child of its item ({item_version!r})")
                markers.append(child)
        if len(markers) > 1:
            raise FeedError(f"the item for {item_version!r} has {len(markers)} {PREFIX}:{MARKER} elements")
        if markers:
            if len(markers[0]):
                raise FeedError(f"{PREFIX}:{MARKER} holds elements in the item for {item_version!r}")
            below = build((markers[0].text or "").strip(), f"{PREFIX}:{MARKER} in the item for {item_version!r}")
            own = build((item_version or "").strip(), "the marked item's sparkle:version")
            if below > own:
                raise FeedError(f"{PREFIX}:{MARKER} {below} is above its item's own build {own}")
        short = item.findtext(f"{{{SPARKLE}}}shortVersionString")
        if short is not None:
            short = short.strip()
            if len(short) > 24 or not SHORT_VERSION.fullmatch(short):
                raise FeedError(f"the item for {item_version!r} has a sparkle:shortVersionString that is not a version: {short[:40]!r}")
            dated = DATED_VERSION.fullmatch(short)
            if dated and int(dated.group(1)) != build((item_version or "").strip(), "a dated item's sparkle:version"):
                raise FeedError(f"the item for {item_version!r} shows {short}, another build's version")
        if item_version is not None:
            enclosure = item.find("enclosure")
            found[item_version.strip()] = (item.find(f"{{{SPARKLE}}}criticalUpdate") is not None,
                                           markers[0].text.strip() if markers else None,
                                           short, enclosure.get("url") if enclosure is not None else None)
    if version is not None:
        if version not in found:
            raise FeedError(f"no item for build {version}")
        is_critical, below, short, url = found[version]
        if critical is not None and is_critical != critical:
            raise FeedError(f"the item for build {version} is {'' if is_critical else 'not '}critical")
        if below != required_below:
            raise FeedError(f"the item for build {version} is required below {below}, expected {required_below}")
        if display_version is not None:
            if short != display_version:
                raise FeedError(f"the item for build {version} shows {short!r}, expected {display_version!r}")
            if (url or "").rsplit("/", 1)[-1] != f"ReArc-{display_version}.dmg":
                raise FeedError(f"the item for build {version} downloads {url!r}, expected ReArc-{display_version}.dmg")
    elif display_version is not None:
        raise FeedError("--display-version needs --version")
    return found


def main(argv):
    parser = argparse.ArgumentParser(description="ReArc's update levels in a Sparkle feed")
    sub = parser.add_subparsers(dest="command", required=True)
    stamp_parser = sub.add_parser("stamp")
    stamp_parser.add_argument("feed")
    stamp_parser.add_argument("--version", required=True)
    stamp_parser.add_argument("--required-below", required=True)
    check_parser = sub.add_parser("check")
    check_parser.add_argument("feed")
    check_parser.add_argument("--version")
    check_parser.add_argument("--critical", action="store_true")
    check_parser.add_argument("--required-below")
    check_parser.add_argument("--display-version")
    args = parser.parse_args(argv)
    try:
        with open(args.feed, "rb") as handle:
            data = handle.read()
        if args.command == "stamp":
            stamped = stamp(data, args.version, args.required_below)
            with open(args.feed, "wb") as handle:
                handle.write(stamped)
            print(f"appcast-marker: build {args.version} is required below {args.required_below}")
        else:
            check(data, version=args.version, critical=args.critical, required_below=args.required_below,
                  display_version=args.display_version)
            print(f"appcast-marker: {args.feed} markers are well formed")
    except (FeedError, OSError, UnicodeDecodeError) as error:
        print(f"appcast-marker: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
