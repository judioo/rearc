#!/usr/bin/env bash
# Uses the tools from Sparkle's pinned 2.10.1 distribution. Private keys stay in Keychain.
set -euo pipefail
DIR="${1:?usage: generate-appcast.sh ARCHIVES_DIR [beta]}"
CHANNEL="${2:-}"
# Default: the tools SwiftPM unpacked with the pinned Sparkle artifact during the release build.
TOOLS="${REARC_SPARKLE_TOOLS:-$(cd "$(dirname "$0")/../.." && pwd)/.build-chromium/artifacts/sparkle/Sparkle/bin}"
[[ -x "$TOOLS/generate_appcast" && -x "$TOOLS/generate_keys" && -x "$TOOLS/sign_update" ]] || { echo 'Sparkle tools missing' >&2; exit 1; }
PUBLIC_KEY="$TOOLS/generate_keys"
EXPECTED="$(tr -d '[:space:]' <"$(dirname "$0")/sparkle-public-key.txt")"
ACTUAL="$("$PUBLIC_KEY" --account ReArc -p)"
[[ $ACTUAL == "$EXPECTED" ]] || { echo 'Keychain ReArc public key does not match the shipped key' >&2; exit 1; }
FEED="$DIR/appcast.xml"
ARGS=(--account ReArc -o "$FEED" --download-url-prefix "${REARC_UPDATE_DOWNLOAD_URL:-https://rearc.imara.ae/updates/}")
[[ -z $CHANNEL ]] || ARGS+=(--channel "$CHANNEL")
"$TOOLS/generate_appcast" "${ARGS[@]}" "$DIR"
# 2.10.1 signs automatically when an archived app has SURequireSignedFeed.
# Explicitly sign as well: this also covers a feed regenerated from older
# archives during the transition. The signature is embedded in XML, keeping
# the published RSS/enclosure format compatible with existing clients.
"$TOOLS/sign_update" --account ReArc "$FEED"
"$TOOLS/sign_update" --account ReArc --verify "$FEED"
