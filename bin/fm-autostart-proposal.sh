#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-quota-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

die() { printf 'fm-autostart-proposal: %s\n' "$1" >&2; exit 2; }

# This command is part of heartbeat handling, so enforce the low-quota stop and
# compact policy even when there is no queued work to propose.
FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
  "$SCRIPT_DIR/fm-quota-stop-compact.sh" || die 'low-quota session steering failed'

ready=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
  "$SCRIPT_DIR/fm-tasks-axi.sh" ready 2>&1) || die "tasks-axi ready failed: $ready"
candidate_ids=$(printf '%s\n' "$ready" | awk '
  /^ready\[[0-9]+\]\{/ { rows=1; next }
  rows && /^[[:space:]]/ {
    sub(/^[[:space:]]+/, "")
    split($0, fields, ",")
    if (fields[1] != "") print fields[1]
    next
  }
  rows { exit }
' | paste -sd ', ' -)
[ -n "$candidate_ids" ] || exit 0

command -v quota-axi >/dev/null 2>&1 || die 'quota-axi is not on PATH'
quota=$(quota-axi --full --json 2>&1) || die "quota-axi --full --json failed: $quota"
printf '%s\n' "$quota" | fm_quota_json_valid || die 'quota-axi returned an invalid full snapshot'

headroom=()
while read -r harness provider; do
  scopes=$(printf '%s\n' "$quota" | jq -r --arg provider "$provider" '
    .providers[] | select(.provider == $provider and .state.status == "fresh")
    | .quotaSemantics.effectiveAvailability[]
    | select(.status == "known"
        and (.effectivePercentRemaining | type) == "number"
        and .effectivePercentRemaining > 0
        and .runway.status == "through_reset")
    | .scope
  ')
  while IFS= read -r scope; do
    [ -n "$scope" ] && headroom+=("$harness ($scope)")
  done <<< "$scopes"
done < <(fm_quota_single_provider_table)

[ "${#headroom[@]}" -gt 0 ] || exit 0
printf 'Proactive start proposal (advisory): ready queued task IDs: %s. Harnesses with quota headroom: %s. Review task fit and normal dispatch gates before starting.\n' \
  "$candidate_ids" "$(IFS=', '; printf '%s' "${headroom[*]}")"
