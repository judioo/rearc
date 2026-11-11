#!/usr/bin/env bash
# Uses the tools from Sparkle's pinned 2.10.1 distribution. Private keys stay in Keychain.
set -euo pipefail
DIR="${1:?usage: generate-appcast.sh ARCHIVES_DIR [beta]}"
CHANNEL="${2:-}"
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
"$TOOLS/generate_appcast" "${ARGS[@]}" "$DIR"
# 2.10.1 signs automatically when an archived app has SURequireSignedFeed. Sign
# explicitly only when it did not (a feed regenerated from older archives): sign_update
# is a separate binary, so it needs its own Keychain grant. The signature is embedded in
# the XML, keeping the published RSS/enclosure format compatible with existing clients.
if ! grep -q '<!-- sparkle-signatures:' "$NEW"; then
  "$TOOLS/sign_update" --account ReArc "$NEW"
fi
# Public key only: no Keychain read, so no prompt.
"$VERIFY" "$NEW" "$EXPECTED" || { echo 'appcast.xml does not verify against the shipped key; nothing was written' >&2; exit 1; }
mv -f "$NEW" "$FEED"
echo "appcast: $FEED signed and verified"
