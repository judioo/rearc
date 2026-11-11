#!/usr/bin/env bash
# Verifies a Sparkle feed's embedded EdDSA signature with the public key alone (no Keychain,
# unlike `sign_update --verify`, which reads the private key). The feed ends with
#   <!-- sparkle-signatures:\nedSignature: BASE64\nlength: N\n-->
# and the signature covers the first N bytes, which must be everything before that block.
# Needs OpenSSL 3 or later (Ed25519 with -rawin); macOS's LibreSSL cannot, so
# REARC_OPENSSL, then Homebrew's, then the one on PATH are tried.
#
# Usage: scripts/release/verify-appcast.sh FEED [BASE64_PUBLIC_KEY]
#   (default key: sparkle-public-key.txt next to this script)
set -euo pipefail
FEED="${1:?usage: verify-appcast.sh FEED [BASE64_PUBLIC_KEY]}"
KEY="${2:-$(tr -d '[:space:]' <"$(dirname "$0")/sparkle-public-key.txt")}"
fail() { echo "verify-appcast: $*" >&2; exit 1; }
[[ -f $FEED ]] || fail "no feed at $FEED"

OPENSSL=""
for candidate in "${REARC_OPENSSL:-}" /opt/homebrew/bin/openssl /usr/local/bin/openssl "$(command -v openssl || true)"; do
  [[ -n $candidate && -x $candidate ]] || continue
  if "$candidate" version 2>/dev/null | grep -Eq '^OpenSSL ([3-9]|[1-9][0-9])\.'; then OPENSSL="$candidate"; break; fi
done
[[ -n $OPENSSL ]] || fail "needs OpenSSL 3 or later for Ed25519 (brew install openssl, or set REARC_OPENSSL)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rearc-verify-appcast.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Exactly one block, at the end, holding the signature and the signed length.
[[ "$(grep -c '<!-- sparkle-signatures:' "$FEED")" == 1 ]] || fail "expected exactly one signature block"
signature="$(sed -n 's/^edSignature: *\([A-Za-z0-9+/=]*\) *$/\1/p' "$FEED")"
length="$(sed -n 's/^length: *\([0-9][0-9]*\) *$/\1/p' "$FEED")"
[[ -n $signature && -n $length ]] || fail "the signature block has no edSignature or length"
size="$(wc -c <"$FEED" | tr -d ' ')"
(( length > 0 && length < size )) || fail "signed length $length does not fit the feed ($size bytes)"
tail -c +"$((length + 1))" "$FEED" >"$WORK/rest"
head -c 24 "$WORK/rest" | grep -q '^<!-- sparkle-signatures:' \
  || fail "the signed length $length does not end where the signature block starts"
[[ "$(grep -c '^-->$' "$WORK/rest")" == 1 && "$(tail -n 1 "$WORK/rest")" == "-->" ]] \
  || fail "the signature block is unterminated or followed by more content"

head -c "$length" "$FEED" >"$WORK/signed"
printf '%s' "$signature" | base64 -D >"$WORK/sig" 2>/dev/null || fail "edSignature is not base64"
[[ "$(wc -c <"$WORK/sig" | tr -d ' ')" == 64 ]] || fail "edSignature is not an Ed25519 signature"
{ printf '302a300506032b6570032100' | xxd -r -p; printf '%s' "$KEY" | base64 -D; } >"$WORK/key.der"
[[ "$(wc -c <"$WORK/key.der" | tr -d ' ')" == 44 ]] || fail "the public key is not an Ed25519 key"
"$OPENSSL" pkeyutl -verify -pubin -inkey "$WORK/key.der" -keyform DER -rawin -in "$WORK/signed" -sigfile "$WORK/sig" >/dev/null 2>&1 \
  || fail "the signature does not verify against the public key"
echo "verify-appcast: $FEED verifies ($length signed bytes)"
