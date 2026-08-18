#!/usr/bin/env bash
# Build FirstMate's private, canonical dashboard record at
# ${FM_HOME}/data/dashboard.json.
#
# Usage: fm-dashboard.sh refresh
#        fm-dashboard.sh show
#
# `refresh` is the sole writer. It reads the canonical backlog through
# fm-fleet-snapshot.sh and its current-state owner, then atomically replaces the
# 0600 record. A consumer must only read dashboard.json. Schema version 1 has
# `generated_at`, `projection`, and `technical`. `projection` has exactly
# `empty_text`, `needs_you[]`, and `in_progress[]`. An in-progress row has
# `{id,name,phase,active_seconds}` where phase is Building or Checking. A
# needs-you row has `{id,name,kind,summary,slack_thread_url}`. `technical.tasks`
# retains each active task's stable identity, observed state, active-time
# checkpoint, provenance, and resolved stop; `technical.reconciliation` names
# the canonical state sources. All technical fields are private and additive.
#
# The active-time accumulator consumes the compact canonical checkpoint. This
# excludes every paused interval and persists work time across restarts.
# `FM_DASHBOARD_NOW` supplies a deterministic epoch for tests; production uses
# date +%s.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$DATA/dashboard.json"
MAX_SNAPSHOT_BYTES=${FM_DASHBOARD_MAX_SNAPSHOT_BYTES:-1048576}
MAX_RECORD_BYTES=${FM_DASHBOARD_MAX_RECORD_BYTES:-1048576}

usage() {
  sed -n '2,23p' "$0" | sed 's/^# //'
}

case "${1:-refresh}" in
  refresh|show) ACTION=${1:-refresh} ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-dashboard: jq not found" >&2; exit 1; }

mode_of() {
  if [ "$(uname -s)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}
owner_of() {
  if [ "$(uname -s)" = Darwin ]; then stat -f %u "$1"; else stat -c %u "$1"; fi
}
valid_record() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(mode_of "$1" 2>/dev/null || true)" = 600 ]
}
valid_private_data_dir() {
  local mode owner group other
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || return 1
  owner=$(owner_of "$DATA" 2>/dev/null || true)
  [ "$owner" = "$(id -u)" ] || return 1
  mode=$(mode_of "$DATA" 2>/dev/null || true)
  case "$mode" in [0-7][0-7][0-7]) ;; *) return 1 ;; esac
  group=${mode#?}; group=${group%?}
  other=${mode#??}
  case "$group$other" in *[2367]*) return 1 ;; esac
}
prepare_data() {
  if [ -e "$DATA" ] || [ -L "$DATA" ]; then
    valid_private_data_dir || { echo "fm-dashboard: unsafe data directory" >&2; return 1; }
  else
    (umask 077; mkdir -p "$DATA") || return 1
    valid_private_data_dir || { echo "fm-dashboard: unsafe data directory" >&2; return 1; }
  fi
}

prepare_data || exit 1
if [ "$ACTION" = "show" ]; then
  valid_record "$RECORD" || { echo "fm-dashboard: no valid dashboard record" >&2; exit 1; }
  cat "$RECORD"
  exit 0
fi

NOW=${FM_DASHBOARD_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) echo "fm-dashboard: FM_DASHBOARD_NOW must be an epoch" >&2; exit 2 ;; esac
case "$MAX_SNAPSHOT_BYTES" in ''|*[!0-9]*|0) echo "fm-dashboard: FM_DASHBOARD_MAX_SNAPSHOT_BYTES must be a positive integer" >&2; exit 2 ;; esac
case "$MAX_RECORD_BYTES" in ''|*[!0-9]*|0) echo "fm-dashboard: FM_DASHBOARD_MAX_RECORD_BYTES must be a positive integer" >&2; exit 2 ;; esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
LOCK="$DATA/.dashboard.lock"
fm_lock_acquire_wait "$LOCK"
SNAPSHOT_FILE=
cleanup() {
  [ -z "$SNAPSHOT_FILE" ] || rm -f -- "$SNAPSHOT_FILE"
  fm_lock_release "$LOCK" || true
}
trap cleanup EXIT HUP INT TERM

if [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
  valid_record "$RECORD" || { echo "fm-dashboard: existing dashboard record is unsafe" >&2; exit 1; }
  [ "$(wc -c < "$RECORD" | tr -d ' ')" -le "$MAX_RECORD_BYTES" ] || { echo "fm-dashboard: existing dashboard record exceeds the bounded size" >&2; exit 1; }
  PREVIOUS=$(cat "$RECORD")
  printf '%s' "$PREVIOUS" | jq -e '.schema_version == 1 and (.technical.tasks | type == "array")' >/dev/null \
    || { echo "fm-dashboard: existing dashboard record is malformed" >&2; exit 1; }
else
  PREVIOUS='{"schema_version":1,"technical":{"tasks":[]}}'
fi

SNAPSHOT_BIN="$SCRIPT_DIR/fm-fleet-snapshot.sh"
# Test-only seam. Production always calls the canonical snapshot owner.
if [ "${FM_DASHBOARD_TESTING:-0}" = 1 ] && [ -n "${FM_DASHBOARD_TEST_SNAPSHOT_BIN:-}" ]; then
  SNAPSHOT_BIN=$FM_DASHBOARD_TEST_SNAPSHOT_BIN
fi
SNAPSHOT_FILE=$(umask 077; mktemp "$DATA/.dashboard-snapshot.XXXXXX") || exit 1
if ! FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
  "$SNAPSHOT_BIN" --json > "$SNAPSHOT_FILE"; then
  echo "fm-dashboard: canonical state reconciliation failed" >&2
  exit 1
fi
[ "$(wc -c < "$SNAPSHOT_FILE" | tr -d ' ')" -le "$MAX_SNAPSHOT_BYTES" ] || {
  echo "fm-dashboard: canonical snapshot exceeds the bounded size" >&2
  exit 1
}
SNAPSHOT=$(cat "$SNAPSHOT_FILE")
printf '%s' "$SNAPSHOT" | jq -e '.schema == "fm-fleet-snapshot.v1" and (.tasks | type == "array")' >/dev/null \
  || { echo "fm-dashboard: canonical snapshot has an unexpected schema" >&2; exit 1; }

# Keep only live metadata tasks. The snapshot has already reconciled each state
# through fm-crew-state.sh and the durable open-decision fold.
RESULT=$(jq -n \
  --argjson prior "$PREVIOUS" --argjson snapshot "$SNAPSHOT" --argjson now "$NOW" '
  def active: (.current_state.activity_state // .current_state.state) == "working";
  def clip($n): tostring | .[0:$n];
  def phase:
    if (.current_state.source == "run-step" and ((.current_state.detail // "") | test("validat|ci|check"; "i")))
    then "Checking" else "Building" end;
  def thread_url: (.x_thread_url // "" | if . == "" then null else . end);
  def genuine_stop:
    ([.hints.open_decisions[]? | select(.verb == "needs-decision")][0]) as $decision
    | ([.hints.open_decisions[]? | select(.verb == "blocked")][0]) as $blocked
    | if $decision != null and .current_state.state == "parked" then $decision
      elif $blocked != null and .current_state.state == "blocked" then $blocked
      elif .current_state.state == "unknown" and .recovery.state == "unrecoverable" then {verb:"failed",summary:"Worker recovery failed"}
      else null end;
  def prior_for($id): ($prior.technical.tasks[]? | select(.id == $id)) // {};
  def task_record:
    . as $task | (prior_for(.id)) as $old
    | ($old.active_seconds // 0) as $old_seconds
    | (.current_state.transition_at? // null) as $reported_transition
    | (.current_state.active_seconds? // null) as $checkpoint
    | (if ($checkpoint | type) == "number" and $checkpoint >= 0
       and ($reported_transition | type) == "number" and $reported_transition <= $now
       then {active:($checkpoint + (if active then (($now - $reported_transition) | if . > 0 then . else 0 end) else 0 end)),
             transition:$reported_transition,exact:true}
       else {active:$old_seconds,
             transition:(if ($reported_transition | type) == "number" and $reported_transition <= $now
                         then $reported_transition else ($old.state_transition_at // null) end),
             exact:false} end) as $timing
    | (genuine_stop) as $stop
    | {id:.id,
       name:(.backlog.title // .id | clip(160)),
       state:.current_state.state,
       activity_state:(.current_state.activity_state // .current_state.state),
       phase:(if active then phase else null end),
       active_seconds:$timing.active,
       timing_exact:$timing.exact,
       active_since:(if active and $timing.exact then $timing.transition else null end),
       state_transition_at:$timing.transition,
       observed_at:$now,
       recovery:(if .current_state.state == "unknown" then (if .recovery.state == "unrecoverable" then "unrecoverable" else "automatic-recovery-pending" end) else null end),
       provenance:{origin:(if (.x_request? // "") != "" then "slack" else "direct" end),
                   slack_thread_url:thread_url},
       stop:$stop};
  [$snapshot.tasks[]? | select(.kind != "secondmate" and .current_state.state != "done" and .current_state.state != "failed") | task_record] as $tasks
  | ($tasks | map(select(.activity_state == "working" and .timing_exact and .stop == null) | {id,name,phase,active_seconds})) as $progress
  | ($tasks | map(select(.stop != null) | {id,name,kind:.stop.verb,summary:(.stop.summary | clip(240)),slack_thread_url:.provenance.slack_thread_url})) as $needs
  | {schema_version:1,
     generated_at:$now,
     projection:{empty_text:"Nothing needs you.",needs_you:$needs,in_progress:$progress},
     technical:{tasks:$tasks,
       reconciliation:{source:"fm-fleet-snapshot.v1",state_owner:"fm-crew-state.sh",decision_owner:"fm-classify-lib.sh"}}}
') || { echo "fm-dashboard: could not build dashboard JSON" >&2; exit 1; }

TMP=$(umask 077; mktemp "$DATA/.dashboard.XXXXXX") || exit 1
if ! printf '%s\n' "$RESULT" > "$TMP" || ! chmod 600 "$TMP" || ! valid_record "$TMP"; then
  rm -f -- "$TMP"
  echo "fm-dashboard: could not prepare private record" >&2
  exit 1
fi
[ "$(wc -c < "$TMP" | tr -d ' ')" -le "$MAX_RECORD_BYTES" ] || { rm -f -- "$TMP"; echo "fm-dashboard: dashboard record exceeds the bounded size" >&2; exit 1; }
mv -f -- "$TMP" "$RECORD"
valid_record "$RECORD" || { echo 'fm-dashboard: dashboard publication failed validation' >&2; exit 1; }
