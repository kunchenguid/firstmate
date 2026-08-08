#!/usr/bin/env bash
# Private fleet sentinel. Consumes the shared fm-fleet-capacity.v1 object and
# retains ONLY cadence, the authoritative candidate query, logging, and
# notification policy. It never classifies attempts and never recounts
# capacity. Invoked by the away-mode daemon heartbeat fleet review and by the
# attended refill path; it starts no scheduler or daemon of its own.
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"

# --- cadence resolution (config/refill-sentinel schema, Task 14) ------------
# The home-local gitignored config/refill-sentinel (one per home) owns the
# sentinel cadence: its first non-comment, non-empty line is a positive
# integer in seconds (comments start with '#'; example content: `600`).
# Precedence: FM_REFILL_SENTINEL_CADENCE_SECS (env, when valid) > the config
# file's value when present and valid > 600. The sentinel only RESOLVES and
# REPORTS the active cadence (log line + verbose output) so the wiring is
# verifiable; it never schedules itself - the away-mode daemon heartbeat fleet
# review invokes it at that cadence.
FM_REFILL_SENTINEL_CADENCE_SECS="${FM_REFILL_SENTINEL_CADENCE_SECS:-}"

fm_refill_sentinel_cadence() {  # -> seconds
  local file value
  if [ -n "$FM_REFILL_SENTINEL_CADENCE_SECS" ]; then
    case "$FM_REFILL_SENTINEL_CADENCE_SECS" in
      ''|0|*[!0-9]*) : ;;  # invalid env: fall through to config, then default
      *) printf '%s\n' "$FM_REFILL_SENTINEL_CADENCE_SECS"; return 0 ;;
    esac
  fi
  file="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/refill-sentinel"
  if [ -f "$file" ]; then
    value=$(awk '{ sub(/^[[:space:]]+/, ""); if ($0 != "" && $0 !~ /^#/) { print; exit } }' "$file" 2>/dev/null || true)
    case "$value" in
      ''|0|*[!0-9]*) : ;;  # absent or invalid value: fall back to the default
      *) printf '%s\n' "$value"; return 0 ;;
    esac
  fi
  printf '%s\n' 600
}
FM_REFILL_SENTINEL_CADENCE_SECS=$(fm_refill_sentinel_cadence)
FM_REFILL_SENTINEL_LOG="${FM_REFILL_SENTINEL_LOG:-$FM_HOME/state/refill-sentinel.log}"
FM_REFILL_TARGET_PRODUCTIVE="${FM_REFILL_TARGET_PRODUCTIVE:-6}"
FM_REFILL_RESERVED_CEILING="${FM_REFILL_RESERVED_CEILING:-10}"

# refill_candidates_json: the authoritative candidate query (read-only; br
# reads pass --no-auto-flush so the tracked .beads/issues.jsonl export is
# never rewritten by the sentinel). Safe when br is absent or the project is
# not a clone: any non-array answer becomes an empty candidate set.
refill_candidates_json() {
  (cd "${FM_REFILL_PROJECT:-/home/holu/decision-os}" && br ready --json --no-auto-flush 2>/dev/null) \
    | jq -c '[.[] | select(.status == "open") | {id,priority,created_at}]' 2>/dev/null || echo '[]'
}

# guard the log directory so a fresh home or fixture never loses the record
[ -d "$(dirname "$FM_REFILL_SENTINEL_LOG")" ] || mkdir -p "$(dirname "$FM_REFILL_SENTINEL_LOG")" 2>/dev/null || true

cap=$(fm_capacity_project)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
alert=$(echo "$cap" | jq -r '
  if (.aggregate.refill_safe | not) then "REFILL-ALERT: projection unsafe (reconciliation_required=\(.aggregate.reconciliation_required) alert_only=\(.aggregate.alert_only))"
  elif (.aggregate.productive_count < '"$FM_REFILL_TARGET_PRODUCTIVE"') and
       (.aggregate.reserved_ownership_count < '"$FM_REFILL_RESERVED_CEILING"') then
    "REFILL-ALERT: productive \(.aggregate.productive_count) below target \('"$FM_REFILL_TARGET_PRODUCTIVE"')"
  else "" end')
candidates=$(refill_candidates_json)
printf '%s %s\n' "$now" "sentinel: cadence=$FM_REFILL_SENTINEL_CADENCE_SECS ${alert:-refill-safe} candidates=$(echo "$candidates" | jq 'length')" \
  >> "$FM_REFILL_SENTINEL_LOG" 2>/dev/null || true
if [ -n "${FM_REFILL_SENTINEL_VERBOSE:-}" ]; then
  # consume-only note: prints aggregate values read from the object, never a
  # recount or a re-classification of rows
  printf '%s\n' "sentinel: consumed aggregate cadence=$FM_REFILL_SENTINEL_CADENCE_SECS refill_safe=$(echo "$cap" | jq -r '.aggregate.refill_safe') productive=$(echo "$cap" | jq -r '.aggregate.productive_count') reserved=$(echo "$cap" | jq -r '.aggregate.reserved_ownership_count') alert_only=$(echo "$cap" | jq -r '.aggregate.alert_only') reconciliation=$(echo "$cap" | jq -r '.aggregate.reconciliation_required')"
fi
[ -n "$alert" ] || exit 0
printf '%s\n' "$alert"
exit 1
