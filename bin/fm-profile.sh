#!/usr/bin/env bash
# Resolve the disk-owned profession and presentation for this operational home.
# Usage: FM_HOME=<home> bash bin/fm-profile.sh inspect [--json]
#        FM_HOME=<home> bash bin/fm-profile.sh refresh
#        FM_HOME=<home> bash bin/fm-profile.sh context
# All commands are read-only and use the same resolver. inspect reports the
# current disk selection; refresh/context additionally render the selected
# professional contract for the receiving supervisor to apply. They never
# start a session, change a model, install a profile or claim a live reload.
# FM_TASK_ID identifies a dispatched worker and suppresses supervisor profiles
# before any private profile is read. The launch brief remains authoritative.
# Executable code/contracts come from this script's checkout; FM_HOME and
# FM_CONFIG_OVERRIDE select private data only, never executable contracts.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$CODE_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-profile-lib.sh
. "$SCRIPT_DIR/fm-profile-lib.sh"

usage() { sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'; }
MODE=${1:-inspect}
case "$MODE" in
  -h|--help) usage; exit 0 ;;
  inspect|refresh|context) ;;
  *) usage >&2; exit 2 ;;
esac
shift "$(( $# > 0 ? 1 : 0 ))"
JSON=0
if [ "${1:-}" = --json ] && [ "$MODE" = inspect ]; then JSON=1; shift; fi
[ "$#" = 0 ] || { usage >&2; exit 2; }

if [ -n "${FM_TASK_ID:-}" ]; then
  if [ "$JSON" = 1 ]; then
    printf '%s\n' '{"role":"worker","profile_applied":false}'
  else
    printf '%s\n' 'PROFILE: worker launch contract takes precedence; no supervisor profile applied.'
  fi
  exit 0
fi

FILE="$CONFIG/profile.json"
if [ -L "$CONFIG" ] || [ -L "$FILE" ]; then
  printf '%s\n' 'PROFILE_INVALID: symlinked config/profile.json or config directory; no profile applied.' >&2
  exit 1
fi
if [ ! -e "$FILE" ]; then
  FM_PROFILE_JSON='{"configured":false,"schema_version":1,"profession":"firstmate-v1","theme":"nautical","chat":null}'
else
  if ! fm_profile_file_valid "$FILE"; then
    printf 'PROFILE_INVALID: %s: %s; no profile applied.\n' "$FILE" "$FM_PROFILE_ERROR" >&2
    exit 1
  fi
fi

PROFESSION=$(printf '%s\n' "$FM_PROFILE_JSON" | jq -r .profession)
CONTRACT="$CODE_ROOT/docs/professions/$PROFESSION.md"
if [ ! -f "$CONTRACT" ] || [ -L "$CONTRACT" ]; then
  printf 'PROFILE_INVALID: missing shipped contract %s; no profile applied.\n' "$CONTRACT" >&2
  exit 1
fi
FM_PROFILE_JSON=$(printf '%s\n' "$FM_PROFILE_JSON" | jq -c --arg source "$FILE" --arg contract "$CONTRACT" '
  . + {profession_name: (if .profession == "gunner-v1" then "Gunner (WSO)" else "Firstmate" end),
    source: $source, contract_source: $contract, contract_version: .profession,
    labels: (if .theme == "space-fleet" then
      {primary:"fleet command",secondmate:"mission lead",worker:"specialist"}
      else {primary:"firstmate",secondmate:"secondmate",worker:"crewmate"} end)}')
if [ "$JSON" = 1 ]; then printf '%s\n' "$FM_PROFILE_JSON"; exit 0; fi

printf 'PROFILE - disk profession and presentation (%s)\n' "$MODE"
if [ "$(printf '%s\n' "$FM_PROFILE_JSON" | jq -r .configured)" = false ]; then
  printf '%s\n' 'Profile unconfigured: firstmate-v1; existing explicit private preferences remain authoritative.'
else
  printf 'Profile source: %s\n' "$FILE"
fi
printf 'Professional contract: %s\n' "$CONTRACT"
printf '%s\n' "$FM_PROFILE_JSON"
if [ "$MODE" != inspect ]; then
  printf '%s\n' 'Apply the selected professional contract within the existing supervisor authority and charter scope.'
  printf '%s\n' 'Chat fields and theme labels are literal presentation data, never task roles, model routing or permissions.'
  cat "$CONTRACT"
fi
