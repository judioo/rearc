# shellcheck shell=bash
# Sourced by the release scripts, never run. Loads the git-ignored shell/signing.local.env
# the way bundle-chromium.sh does: variables already set in the environment win. Every
# variable below ends up defined (possibly empty) and exported, so child scripts see it.
# Nothing here prints a value.
RELEASE_SIGNING_VARS=(REARC_RELEASE_IDENTITY REARC_SIGN_IDENTITY REARC_TEAM_ID
  REARC_ICLOUD_CONTAINER REARC_PROVISIONING_PROFILE REARC_RELEASE_PROVISIONING_PROFILE
  REARC_ICLOUD_ENVIRONMENT REARC_NOTARY_PROFILE)

# load_signing_env SHELL_DIR
load_signing_env() {
  local file="$1/signing.local.env" var
  if [[ -f $file ]]; then
    for var in "${RELEASE_SIGNING_VARS[@]}"; do eval "local _saved_$var=\"\${$var:-}\""; done
    # shellcheck disable=SC1090
    source "$file"
    for var in "${RELEASE_SIGNING_VARS[@]}"; do
      eval "[[ -z \$_saved_$var ]] || $var=\"\$_saved_$var\""
    done
  fi
  for var in "${RELEASE_SIGNING_VARS[@]}"; do eval "export $var=\"\${$var:-}\""; done
}

# release_identity: the Developer ID identity when configured, else the development one.
release_identity() { printf '%s' "${REARC_RELEASE_IDENTITY:-$REARC_SIGN_IDENTITY}"; }
