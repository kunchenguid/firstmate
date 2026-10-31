#!/usr/bin/env bash
# Resolve a disk-owned profession and presentation without changing selection.
# Usage: FM_HOME=<home> bash bin/fm-profile.sh inspect [--json] [--preset <domain/pair>]
#        FM_HOME=<home> bash bin/fm-profile.sh refresh [--preset <domain/pair>]
#        FM_HOME=<home> bash bin/fm-profile.sh context [--preset <domain/pair>]
#        bash bin/fm-profile.sh presets [--json]
# inspect reports sources/version; refresh/context also render the named and
# shared professional contracts for the receiving supervisor to apply.
# --preset previews an exact known pair from the shipped catalog instead of
# reading the home selection. It accepts no filesystem path and writes nothing.
# presets lists that one catalog; it discovers no arbitrary directories.
# FM_TASK_ID suppresses supervisor profiles before any private file is read.
# Contracts/catalog/presets come from this script's checkout; FM_HOME and
# FM_CONFIG_OVERRIDE select private data only. No command starts a session,
# changes a model, installs a profile or proves another session consumed it.
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
  inspect|refresh|context|presets) ;;
  *) usage >&2; exit 2 ;;
esac
shift "$(( $# > 0 ? 1 : 0 ))"
JSON=0
PRESET=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) [ "$MODE" = inspect ] || [ "$MODE" = presets ] || { usage >&2; exit 2; }; JSON=1; shift ;;
    --preset) [ "$#" -gt 1 ] && [ "$MODE" != presets ] && [ -n "$2" ] || { usage >&2; exit 2; }; PRESET=$2; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if [ -n "${FM_TASK_ID:-}" ]; then
  if [ "$JSON" = 1 ]; then printf '%s\n' '{"role":"worker","profile_applied":false}'
  else printf '%s\n' 'PROFILE: worker launch contract takes precedence; no supervisor profile applied.'; fi
  exit 0
fi
invalid() { printf 'PROFILE_INVALID: %s; no profile applied.\n' "$1" >&2; exit 1; }
fm_profile_catalog_load || invalid "$FM_PROFILE_ERROR"
if [ "$MODE" = presets ]; then
  LIST=$(printf '%s\n' "$FM_PROFILE_CATALOG_JSON" | jq -c --arg root "$CODE_ROOT" '
    [.professions | to_entries[] | select(.value.pair != null)
    | {profession: .key, profession_name: .value.name, pair: .value.pair,
        source: ($root + "/docs/professions/" + .value.pair + "/profile.json"),
        contract_source: ($root + "/docs/professions/" + .value.pair + "/profession.md")} ]')
  if [ "$JSON" = 1 ]; then printf '%s\n' "$LIST"
  else printf '%s\n' "$LIST" | jq -r '.[] | "\(.pair)\t\(.profession)\t\(.profession_name)"'; fi
  exit 0
fi
FILE="$CONFIG/profile.json"
if [ -n "$PRESET" ]; then
  fm_profile_pair_entry "$PRESET" || invalid "$FM_PROFILE_ERROR"
  FILE="$CODE_ROOT/$(printf '%s\n' "$FM_PROFILE_ENTRY" | jq -r .preset)"
elif [ -L "$CONFIG" ] || [ -L "$FILE" ]; then
  invalid 'symlinked config/profile.json or config directory'
fi
if [ -z "$PRESET" ] && [ ! -e "$FILE" ]; then
  FM_PROFILE_JSON='{"configured":false,"schema_version":1,"profession":"firstmate-v1","theme":"nautical","chat":null}'
  fm_profile_entry firstmate-v1 || invalid "$FM_PROFILE_ERROR"
else
  fm_profile_file_valid "$FILE" || invalid "$FILE: $FM_PROFILE_ERROR"
  if [ -n "$PRESET" ] && [ "$(printf '%s\n' "$FM_PROFILE_ENTRY" | jq -r .pair)" != "$PRESET" ]; then
    invalid 'preset does not match its catalog profession'
  fi
fi
PROFESSION=$(printf '%s\n' "$FM_PROFILE_JSON" | jq -r .profession)
CONTRACT="$CODE_ROOT/$(printf '%s\n' "$FM_PROFILE_ENTRY" | jq -r .contract)"
[ -f "$CONTRACT" ] && [ ! -L "$CONTRACT" ] || invalid "missing shipped contract $CONTRACT"
DUTIES=$(printf '%s\n' "$FM_PROFILE_ENTRY" | jq -r '.duties // empty')
if [ -n "$DUTIES" ]; then
  DUTIES="$CODE_ROOT/$DUTIES"
  [ -f "$DUTIES" ] && [ ! -L "$DUTIES" ] || invalid "missing shipped duties $DUTIES"
fi
FM_PROFILE_JSON=$(printf '%s\n' "$FM_PROFILE_JSON" | jq -c --arg source "$FILE" --arg contract "$CONTRACT" --arg duties "$DUTIES" --arg preset "$PRESET" --argjson entry "$FM_PROFILE_ENTRY" --argjson catalog "$FM_PROFILE_CATALOG_JSON" '
  . + {profession_name: $entry.name, pair: $entry.pair, preview: ($preset != ""),
    source: $source, contract_source: $contract, contract_version: .profession,
    duties_source: (if $duties == "" then null else $duties end), labels: $catalog.themes[.theme]}')
if [ "$JSON" = 1 ]; then printf '%s\n' "$FM_PROFILE_JSON"; exit 0; fi
printf 'PROFILE - disk profession and presentation (%s)\n' "$MODE"
if [ "$(printf '%s\n' "$FM_PROFILE_JSON" | jq -r .configured)" = false ]; then
  printf '%s\n' 'Profile unconfigured: firstmate-v1; existing explicit private preferences remain authoritative.'
else printf 'Profile source: %s\n' "$FILE"; fi
[ -z "$PRESET" ] || printf '%s\n' 'Preset preview only; the home selection is unchanged.'
printf 'Professional contract: %s\n' "$CONTRACT"
printf '%s\n' "$FM_PROFILE_JSON"
if [ "$MODE" != inspect ]; then
  printf '%s\n' 'Apply the selected professional contract within the existing supervisor authority and charter scope.'
  printf '%s\n' 'Chat fields and theme labels are literal presentation data, never task roles, model routing or permissions.'
  cat "$CONTRACT"
  if [ -n "$DUTIES" ]; then cat "$DUTIES"; fi
fi
