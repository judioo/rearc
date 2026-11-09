#!/usr/bin/env bash
# Uses the tools from Sparkle's pinned 2.10.1 distribution. Private keys stay in Keychain.
set -euo pipefail
DIR="${1:?usage: generate-appcast.sh ARCHIVES_DIR [beta]}"
CHANNEL="${2:-}"
TOOLS="${REARC_SPARKLE_TOOLS:?set REARC_SPARKLE_TOOLS to the bin directory from Sparkle 2.10.1}"
[[ -x "$TOOLS/generate_appcast" && -x "$TOOLS/generate_keys" ]] || { echo 'Sparkle tools missing' >&2; exit 1; }
PUBLIC_KEY="$TOOLS/generate_keys"
EXPECTED="$(tr -d '[:space:]' <"$(dirname "$0")/sparkle-public-key.txt")"
ACTUAL="$("$PUBLIC_KEY" --account ReArc -p)"
[[ $ACTUAL == "$EXPECTED" ]] || { echo 'Keychain ReArc public key does not match the shipped key' >&2; exit 1; }
ARGS=(--account ReArc --download-url-prefix "${REARC_UPDATE_DOWNLOAD_URL:-https://rearc.net/updates/}")
[[ -z $CHANNEL ]] || ARGS+=(--channel "$CHANNEL")
"$TOOLS/generate_appcast" "${ARGS[@]}" "$DIR"
