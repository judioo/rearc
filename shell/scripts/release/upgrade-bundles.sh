#!/usr/bin/env bash
# Which bundles the upgrade checks (check-upgrade.sh, check-upgrade-data.py) may launch on a
# throwaway REARC_DATA_DIR, and how. The one place that knows which shipped builds take one.
#
# A shipped release bundle (ReArcRelease without ReArcReleaseVerification in its signed
# Info.plist) refuses REARC_DATA_DIR and --user-data-dir (security RC-0.1.0-602 T-04), so it
# would only ever start on the person's own data. Shipped builds up to LAST_DATA_DIR_BUILD
# predate that and honour REARC_DATA_DIR as they are.
#
# Usage:
#   upgrade-bundles.sh new APP
#     Exits 1 when APP is a shipped bundle after LAST_DATA_DIR_BUILD: the new build is never
#     copied or signed again, so it must be the bundle release.sh is verifying.
#   upgrade-bundles.sh previous APP WORK_DIR
#     Prints the bundle to launch for APP. A shipped APP after LAST_DATA_DIR_BUILD is copied
#     into WORK_DIR/previous-app-<build>, given the verification key and signed again with the
#     release identity (sign-release.sh, or REARC_UPGRADE_SIGN); the original is untouched.
set -euo pipefail

# The last shipped build that honours REARC_DATA_DIR: 608 (hotfix-605-storage) has none of the
# T-04 work. Raise it only for a shipped build that also lacks it.
LAST_DATA_DIR_BUILD=608

die() { echo "upgrade-bundles: $*" >&2; exit 1; }

key() { plutil -extract "$2" raw "$1/Contents/Info.plist" 2>/dev/null || true; }

# A shipped bundle that refuses REARC_DATA_DIR.
refuses_data_dir() {
  local build
  build="$(key "$1" CFBundleVersion)"
  [[ $build =~ ^[0-9]+$ ]] || build=0
  [[ "$(key "$1" ReArcRelease)" == true && "$(key "$1" ReArcReleaseVerification)" != true ]] \
    && (( build > LAST_DATA_DIR_BUILD ))
}

case "${1:-}" in
  new)
    [[ $# == 2 ]] || die "usage: upgrade-bundles.sh new APP"
    if refuses_data_dir "$2"; then
      echo "$2 is a shipped release bundle, which refuses REARC_DATA_DIR; run this on the bundle release.sh is verifying" >&2
      exit 1
    fi
    ;;
  previous)
    [[ $# == 3 ]] || die "usage: upgrade-bundles.sh previous APP WORK_DIR"
    app="$2" work="$3"
    if ! refuses_data_dir "$app"; then
      echo "$app"
      exit 0
    fi
    build="$(key "$app" CFBundleVersion)"
    copy="$work/previous-app-$build/ReArc.app"
    echo "upgrade-bundles: $app (build $build) refuses REARC_DATA_DIR; making a verification copy of it" >&2
    rm -rf "$(dirname "$copy")"
    mkdir -p "$(dirname "$copy")"
    cp -Rc "$app" "$copy" 2>/dev/null || cp -R "$app" "$copy"
    plutil -insert ReArcReleaseVerification -bool true "$copy/Contents/Info.plist"
    sign="${REARC_UPGRADE_SIGN:-$(cd "$(dirname "$0")/.." && pwd)/sign-release.sh}"
    "$sign" "$copy" >"$work/sign-previous-$build.log" 2>&1 \
      || die "signing the verification copy failed (log $work/sign-previous-$build.log)"
    echo "$copy"
    ;;
  *) die "usage: upgrade-bundles.sh new APP | previous APP WORK_DIR" ;;
esac
