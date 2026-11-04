# shellcheck shell=bash
# iCloud (CloudKit) signing opt-in shared by bundle-chromium.sh and bundle-webkit-dev.sh.
# Sourced, never run. See docs/ICLOUD-SETUP.md.
#
# Off unless REARC_ICLOUD_CONTAINER is set (environment or shell/signing.local.env). When
# off, bundles carry no iCloud entitlement and no ReArcICloudContainer marker, and the app
# shows "iCloud sync unavailable in this build". When on, the bundle gets:
#   - Contents/embedded.provisionprofile (the development profile you downloaded),
#   - the iCloud/CloudKit entitlements, merged into scripts/ReArc.entitlements,
#   - Info.plist ReArcICloudContainer = the container, which the shell checks against
#     its signed entitlements before it creates anything CloudKit.
# iCloud entitlements are restricted: macOS kills an app at launch unless an embedded
# profile allows them for this Mac, so the profile is checked first and the build stops
# on any mismatch.

# icloud_prepare APP BUNDLE_ID PROFILE BASE_ENTITLEMENTS OUT_ENTITLEMENTS
# Needs SIGN_IDENTITY and TEAM_ID. Writes OUT_ENTITLEMENTS; embeds the profile and marker.
icloud_prepare() {
  local app="$1" bundle_id="$2" profile="$3" base="$4" out="$5"
  local container="$REARC_ICLOUD_CONTAINER"
  local environment="${REARC_ICLOUD_ENVIRONMENT:-Development}"
  [[ -n ${SIGN_IDENTITY:-} ]] || die "REARC_ICLOUD_CONTAINER needs REARC_SIGN_IDENTITY (an Apple Development identity); ad-hoc signatures cannot carry iCloud"
  [[ -n ${TEAM_ID:-} ]] || die "REARC_ICLOUD_CONTAINER needs REARC_TEAM_ID"
  [[ -n $profile ]] || die "REARC_ICLOUD_CONTAINER needs a provisioning profile path (see docs/ICLOUD-SETUP.md)"
  [[ -f $profile ]] || die "provisioning profile not found: $profile"
  [[ $environment == Development || $environment == Production ]] || die "REARC_ICLOUD_ENVIRONMENT must be Development or Production"

  local decoded
  decoded="$(mktemp "${TMPDIR:-/tmp}/rearc-profile.XXXXXX")"
  security cms -D -i "$profile" >"$decoded" 2>/dev/null || { rm -f "$decoded"; die "cannot decode provisioning profile $profile"; }
  local pb=/usr/libexec/PlistBuddy
  local app_id
  app_id="$($pb -c "Print :Entitlements:com.apple.application-identifier" "$decoded" 2>/dev/null || true)"
  if [[ $app_id != "$TEAM_ID.$bundle_id" && $app_id != "$TEAM_ID.*" ]]; then
    rm -f "$decoded"
    die "profile is for '$app_id', not $TEAM_ID.$bundle_id"
  fi
  if ! $pb -c "Print :Entitlements:com.apple.developer.icloud-container-identifiers" "$decoded" 2>/dev/null \
      | sed -E 's/^[[:space:]]+//' | grep -qxF "$container"; then
    rm -f "$decoded"
    die "profile does not include iCloud container $container (enable it for the App ID, then regenerate the profile)"
  fi
  if ! $pb -c "Print :Entitlements:com.apple.developer.icloud-services" "$decoded" 2>/dev/null \
      | sed -E 's/^[[:space:]]+//' | grep -qE '^(CloudKit|\*)$'; then
    rm -f "$decoded"
    die "profile does not allow the CloudKit service"
  fi
  # Development profiles list the Macs they run on; launching elsewhere is killed by macOS.
  if $pb -c "Print :ProvisionedDevices" "$decoded" >/dev/null 2>&1; then
    local udid
    udid="$(system_profiler SPHardwareDataType 2>/dev/null | sed -n 's/.*Provisioning UDID: //p')"
    if [[ -n $udid ]] && ! $pb -c "Print :ProvisionedDevices" "$decoded" | sed -E 's/^[[:space:]]+//' | grep -qxF "$udid"; then
      rm -f "$decoded"
      die "this Mac ($udid) is not in the profile's devices; register it and regenerate the profile"
    fi
  fi
  local expires
  expires="$(plutil -extract ExpirationDate raw -o - "$decoded" 2>/dev/null || true)"
  local has_environment=0
  $pb -c "Print :Entitlements:com.apple.developer.icloud-container-environment" "$decoded" >/dev/null 2>&1 && has_environment=1
  rm -f "$decoded"

  cp "$base" "$out"
  $pb -c "Add :com.apple.application-identifier string $TEAM_ID.$bundle_id" "$out" >/dev/null
  $pb -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$out" >/dev/null
  $pb -c "Add :com.apple.developer.icloud-container-identifiers array" "$out" >/dev/null
  $pb -c "Add :com.apple.developer.icloud-container-identifiers:0 string $container" "$out" >/dev/null
  $pb -c "Add :com.apple.developer.icloud-services array" "$out" >/dev/null
  $pb -c "Add :com.apple.developer.icloud-services:0 string CloudKit" "$out" >/dev/null
  # Only when the profile grants it; an entitlement the profile lacks gets the app killed.
  if [[ $has_environment == 1 ]]; then
    $pb -c "Add :com.apple.developer.icloud-container-environment string $environment" "$out" >/dev/null
  fi
  plutil -lint "$out" >/dev/null

  cp "$profile" "$app/Contents/embedded.provisionprofile"
  plutil -replace ReArcICloudContainer -string "$container" "$app/Contents/Info.plist"
  echo "==> iCloud: container $container (${environment}), profile expires ${expires:-unknown}"
}

# icloud_verify EXECUTABLE: the signed entitlements carry the container.
icloud_verify() {
  codesign -d --entitlements - --xml "$1" 2>/dev/null | grep -qF "$REARC_ICLOUD_CONTAINER" \
    || die "signed executable lacks the iCloud entitlement for $REARC_ICLOUD_CONTAINER"
  echo "==> iCloud entitlements signed into $(basename "$1")"
}
