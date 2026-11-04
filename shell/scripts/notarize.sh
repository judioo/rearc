#!/usr/bin/env bash
# Notarizes and staples a Developer ID signed ReArc.app or DMG. Docs: engine/docs/RELEASE.md.
#
# Prerequisites, done once by the account holder (this script never sees Apple ID
# credentials; it only names a keychain profile):
#   1. A "Developer ID Application" certificate for team <TEAM_ID> in the login keychain,
#      and the bundle/DMG signed with it (REARC_RELEASE_IDENTITY, scripts/release.sh --dmg).
#   2. xcrun notarytool store-credentials rearc-notary --apple-id <apple-id> --team-id <TEAM_ID>
#      (prompts for an app-specific password and stores it in the keychain).
#
# Usage: scripts/notarize.sh PATH   (.dmg, .zip, or .app: an app is zipped with ditto first)
#   REARC_NOTARY_PROFILE  keychain profile name (default rearc-notary)
# Recommended order: notarize and staple the .app, then make the DMG from the stapled app,
# then notarize and staple the DMG, so both carry tickets offline.
set -euo pipefail

SHELL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "notarize: $*" >&2; exit 1; }
[[ $# == 1 ]] || die "usage: scripts/notarize.sh PATH(.app|.dmg|.zip)"
TARGET="$1"
[[ -e $TARGET ]] || die "no such file: $TARGET"
# shellcheck source=release/signing-env.sh
source "$SHELL_DIR/scripts/release/signing-env.sh"
load_signing_env "$SHELL_DIR"
PROFILE="${REARC_NOTARY_PROFILE:-rearc-notary}"

# Notarization rejects anything but a Developer ID signature with a secure timestamp and,
# for code, the hardened runtime. Check locally first instead of spending a submission.
check_signed() {
  local info
  info="$(codesign -dvv "$1" 2>&1)" || die "$1 is not signed"
  grep -q '^Authority=Developer ID Application:' <<<"$info" \
    || die "$1 is not signed with a Developer ID Application certificate ($(sed -n 's/^Authority=//p' <<<"$info" | head -1)); create one, set REARC_RELEASE_IDENTITY and rebuild"
  grep -q '^Timestamp=' <<<"$info" || die "$1 has no secure timestamp"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rearc-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
case "$TARGET" in
  *.app|*.app/)
    TARGET="${TARGET%/}"
    check_signed "$TARGET"
    codesign --verify --deep --strict "$TARGET"
    codesign -dvv "$TARGET" 2>&1 | grep -q 'flags=.*runtime' || die "$TARGET lacks the hardened runtime"
    SUBMIT="$WORK/$(basename "$TARGET" .app).zip"
    ditto -c -k --keepParent "$TARGET" "$SUBMIT"
    STAPLE="$TARGET" ;;
  *.dmg)
    check_signed "$TARGET"
    SUBMIT="$TARGET"; STAPLE="$TARGET" ;;
  *.zip)
    SUBMIT="$TARGET"; STAPLE="" ;;
  *) die "unsupported file type: $TARGET" ;;
esac

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || die "keychain profile '$PROFILE' missing or invalid; run: xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id <TEAM_ID>"

echo "==> submitting $(basename "$SUBMIT") (profile $PROFILE); waiting for the result"
RESULT="$WORK/submit.plist"
set +e
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait --output-format plist >"$RESULT"
set -e
ID="$(plutil -extract id raw "$RESULT" 2>/dev/null || true)"
STATUS="$(plutil -extract status raw "$RESULT" 2>/dev/null || true)"
echo "==> submission ${ID:-?}: ${STATUS:-unknown}"
if [[ $STATUS != Accepted ]]; then
  [[ -z $ID ]] || xcrun notarytool log "$ID" --keychain-profile "$PROFILE" || true
  die "notarization did not succeed (${STATUS:-no status})"
fi
if [[ -n $STAPLE ]]; then
  xcrun stapler staple "$STAPLE"
  xcrun stapler validate "$STAPLE"
  case "$STAPLE" in
    *.dmg) spctl -a -t open --context context:primary-signature -vv "$STAPLE" ;;
    *) spctl -a -t exec -vv "$STAPLE" ;;
  esac
fi
echo "==> notarized${STAPLE:+ and stapled}: $TARGET"
