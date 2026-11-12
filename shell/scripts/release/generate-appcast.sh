#!/usr/bin/env bash
# Uses the tools from Sparkle's pinned 2.10.1 distribution. Private keys stay in Keychain.
#
# Usage: generate-appcast.sh ARCHIVES_DIR [CHANNEL] [--critical] [--required-below N --version BUILD]
#                            [--display-version V]
#   CHANNEL               beta, or empty for the default channel
#   --critical            new items are Sparkle critical updates for every older build
#                         (<sparkle:criticalUpdate/>; no skipping, ReArc's notice says why)
#   --required-below N    the item for BUILD is required for builds below N
#                         (<rearc:requiredBelow>N</rearc:requiredBelow>, appcast-marker.py);
#                         N is at most BUILD. Display only for now (UPDATE-NOTICE.md §5).
#   --version BUILD       the new item's sparkle:version (needed by --required-below)
#   --display-version V   the new item must show V (sparkle:shortVersionString, the app's
#                         CFBundleShortVersionString) and download ReArc-V.dmg; needs --version
set -euo pipefail
USAGE="usage: generate-appcast.sh ARCHIVES_DIR [CHANNEL] [--critical] [--required-below N --version BUILD] [--display-version V]"
DIR="${1:?$USAGE}"
shift
CHANNEL=""
if [[ $# -gt 0 && $1 != --* ]]; then CHANNEL="$1"; shift; fi
CRITICAL=0
REQUIRED_BELOW=""
VERSION=""
DISPLAY_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --critical) CRITICAL=1 ;;
    --required-below) REQUIRED_BELOW="${2:?$USAGE}"; shift ;;
    --version) VERSION="${2:?$USAGE}"; shift ;;
    --display-version) DISPLAY_VERSION="${2:?$USAGE}"; shift ;;
    *) echo "$USAGE" >&2; exit 64 ;;
  esac
  shift
done
build_number() { [[ $1 =~ ^[1-9][0-9]{0,8}$ ]]; }
if [[ -n $REQUIRED_BELOW ]]; then
  build_number "$REQUIRED_BELOW" || { echo "--required-below needs a build number, not '$REQUIRED_BELOW'" >&2; exit 64; }
  build_number "$VERSION" || { echo "--required-below needs --version BUILD (the new item's build)" >&2; exit 64; }
  (( REQUIRED_BELOW <= VERSION )) || { echo "--required-below $REQUIRED_BELOW is above the new build $VERSION" >&2; exit 64; }
fi
[[ -z $VERSION ]] || build_number "$VERSION" || { echo "--version needs a build number, not '$VERSION'" >&2; exit 64; }
[[ -z $DISPLAY_VERSION || -n $VERSION ]] || { echo "--display-version needs --version BUILD" >&2; exit 64; }
MARKER="$(dirname "$0")/appcast-marker.py"
# Default: the tools SwiftPM unpacked with the pinned Sparkle artifact during the release build.
TOOLS="${REARC_SPARKLE_TOOLS:-$(cd "$(dirname "$0")/../.." && pwd)/.build-chromium/artifacts/sparkle/Sparkle/bin}"
[[ -x "$TOOLS/generate_appcast" && -x "$TOOLS/generate_keys" && -x "$TOOLS/sign_update" ]] || { echo 'Sparkle tools missing' >&2; exit 1; }
VERIFY="$(dirname "$0")/verify-appcast.sh"
PUBLIC_KEY="$TOOLS/generate_keys"
EXPECTED="$(tr -d '[:space:]' <"${REARC_SPARKLE_PUBLIC_KEY_FILE:-$(dirname "$0")/sparkle-public-key.txt}")"
ACTUAL="$("$PUBLIC_KEY" --account ReArc -p)"
[[ $ACTUAL == "$EXPECTED" ]] || { echo 'Keychain ReArc public key does not match the shipped key' >&2; exit 1; }
FEED="$DIR/appcast.xml"
# Generate and sign a copy; the upload folder gets appcast.xml only once its signature
# verifies against the shipped public key (security RC-0.1.0-564 S-09). generate_appcast
# keeps the items of the feed at its output path, so the copy starts from the current one.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rearc-appcast.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
NEW="$WORK/appcast.xml"
[[ ! -f $FEED ]] || cp "$FEED" "$NEW"
ARGS=(--account ReArc -o "$NEW" --download-url-prefix "${REARC_UPDATE_DOWNLOAD_URL:-https://rearc.imara.ae/updates/}")
[[ -z $CHANNEL ]] || ARGS+=(--channel "$CHANNEL")
# An empty version: critical coming from any older build.
[[ $CRITICAL == 0 ]] || ARGS+=(--critical-update-version "")
"$TOOLS/generate_appcast" "${ARGS[@]}" "$DIR"
SIGN_ARGS=(--account ReArc)
if [[ -n $REQUIRED_BELOW ]]; then
  # The marker is ReArc's, so generate_appcast cannot write it: cut its signature block
  # off, stamp the new item in place, then sign again below. Everything before the block
  # stays byte for byte (appcast-marker.py only inserts), and so does the stamped feed
  # through signing: the signing warning generate_appcast embedded is kept, and
  # --disable-signing-warning stops sign_update from re-serializing a feed without one.
  python3 -I - "$NEW" <<'PY'
import sys
path = sys.argv[1]
data = open(path, "rb").read()
at = data.rfind(b"<!-- sparkle-signatures:\n")
open(path, "wb").write(data if at < 0 else data[:at])
PY
  python3 -I "$MARKER" stamp "$NEW" --version "$VERSION" --required-below "$REQUIRED_BELOW"
  cp "$NEW" "$WORK/stamped.xml"
  SIGN_ARGS+=(--disable-signing-warning)
fi
# 2.10.1 signs automatically when an archived app has SURequireSignedFeed. Sign
# explicitly only when it did not (a feed regenerated from older archives, or stamped
# above): sign_update is a separate binary, so it needs its own Keychain grant. The
# signature is embedded in the XML, keeping the published RSS/enclosure format compatible
# with existing clients.
if ! grep -q '<!-- sparkle-signatures:' "$NEW"; then
  "$TOOLS/sign_update" "${SIGN_ARGS[@]}" "$NEW"
fi
if [[ -f $WORK/stamped.xml ]]; then
  stamped_size="$(wc -c <"$WORK/stamped.xml" | tr -d ' ')"
  head -c "$stamped_size" "$NEW" | cmp -s - "$WORK/stamped.xml" \
    || { echo 'signing changed the stamped feed; nothing was written' >&2; exit 1; }
fi
# Public key only: no Keychain read, so no prompt. It also checks every ReArc marker.
"$VERIFY" "$NEW" "$EXPECTED" || { echo 'appcast.xml does not verify against the shipped key; nothing was written' >&2; exit 1; }
if [[ -n $VERSION ]]; then
  CHECK=(--version "$VERSION")
  [[ $CRITICAL == 0 ]] || CHECK+=(--critical)
  [[ -z $REQUIRED_BELOW ]] || CHECK+=(--required-below "$REQUIRED_BELOW")
  [[ -z $DISPLAY_VERSION ]] || CHECK+=(--display-version "$DISPLAY_VERSION")
  python3 -I "$MARKER" check "$NEW" "${CHECK[@]}" \
    || { echo "the item for build $VERSION does not carry the flags asked for; nothing was written" >&2; exit 1; }
fi
mv -f "$NEW" "$FEED"
echo "appcast: $FEED signed and verified"
