#!/usr/bin/env bash
# fm-brief-inherit-lib.sh - shared worker-instruction inheritance for briefs. Source only.
#
# The fork's brief seam sources this when the add-on checkout is present and calls:
#   fm_brief_inherit_shared <config-dir> <kind>   (bin/fm-brief.sh)
#   fm_brief_inherit_config                       (bin/fm-config-inherit-lib.sh)
# With the add-on absent the seam lines are no-ops: only config/brief-include.md applies.

# owner-rules add-on: run its lane check when owner-rules/install.sh wrote config/owner-rules.
# Marker without the lib is an error, so a moved add-ons clone cannot silently drop the rules.
fm_brief_inherit_owner_rules() {
  local lib=${BASH_SOURCE[0]%/*}/../../owner-rules/bin/fm-owner-rules-lib.sh
  [ -f "$1/owner-rules" ] || return 0
  [ -f "$lib" ] || { echo "error: $1/owner-rules is installed but $lib is missing" >&2; exit 1; }
  # shellcheck disable=SC1090 # the add-on lib is found at run time
  . "$lib" && fm_owner_rules_check "${DATA:-}" "${ID:-}" "${MODE:-}" "$2"
}

# Prepend config/brief-include-shared.md to BRIEF_INCLUDE_BODY, which already holds the
# home-local include. Same rules as the local include: a present path that is not a readable
# regular file, or text carrying its own delivery-contract line, stops the scaffold.
fm_brief_inherit_shared() {
  local config=$1 kind=$2 file body
  fm_brief_inherit_owner_rules "$config" "$kind"
  [ "$kind" != secondmate ] || return 0
  file=$config/brief-include-shared.md
  { [ -e "$file" ] || [ -L "$file" ]; } || return 0
  { [ -f "$file" ] && body=$(cat "$file" 2>/dev/null); } || {
    echo "error: $file must be a readable regular file" >&2
    exit 1
  }
  if printf '%s\n' "$body" | grep -q '^Delivery contract: mode='; then
    echo "error: $file must not carry a 'Delivery contract: mode=' line; the delivery mode is a per-task --mode decision" >&2
    exit 1
  fi
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || return 0
  BRIEF_INCLUDE_BODY="${body}${BRIEF_INCLUDE_BODY:+$'\n'}${BRIEF_INCLUDE_BODY:-}"
}

# Declare the shared include inheritable, so config-push, bootstrap convergence and the
# remote push propagate its exact bytes (or its absence) to secondmate homes.
fm_brief_inherit_config() {
  case " ${FM_INHERITABLE_CONFIG:-} " in
    *" brief-include-shared.md "*) ;;
    *) FM_INHERITABLE_CONFIG="${FM_INHERITABLE_CONFIG:+$FM_INHERITABLE_CONFIG }brief-include-shared.md" ;;
  esac
}
