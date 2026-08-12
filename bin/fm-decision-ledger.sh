#!/usr/bin/env bash
# fm-decision-ledger.sh - the decision-coverage ledger for one firstmate home.
#
# Exists because a report once stated "183 open captain decisions" while the
# authoritative fold over the same status logs returned six. Every other number in
# that family - raw needs-decision events, raw blocked events, closing events, held
# backlog rows - is a real measurement of a DIFFERENT thing, and none of them is
# "open decisions". This script is the one place those figures are produced, and it
# makes the confusion structurally impossible in two ways:
#
#   1. There is no scalar field anywhere in this output that means "open decisions"
#      on its own. The open-decision figure is `open_decision_keys`, and the script
#      refuses to emit unless it equals the length of `open_decisions[]` - an
#      enumerated row per distinct live key. Reporting 183 open decisions would
#      require producing 183 distinct keyed rows, each with an owning task and a
#      disposition. A raw event count can never satisfy that identity.
#   2. Every figure is emitted alongside `definitions`, which states in one line
#      what that figure counts and, for the raw ones, that they are not open
#      decisions. A reader cannot see the number without seeing what it measures.
#
# NO HIDDEN REMAINDER: every distinct live key carries exactly one disposition
# from the fixed vocabulary below, and the script refuses to emit a row without
# one. Nothing is dropped, capped, or summarized away.
#
# The open set is the deduplicated union of fm-classify-lib.sh's authoritative
# status_open_decisions fold and the canonical backlog's actionable captain holds.
# The two origins stay visible on every merged row and their separate figures stay
# separate, so moving a key from its status fold to its hold never hides it or turns
# the raw event counter into an open-decision figure. Per-key dispositions come from
# `fm-decision-hold.sh state`, the one classifier for a hold identity's durable state.
#
# Dispositions:
#   captain-hold-active     durably held for the captain in this home's backlog
#   captain-hold-resolved   answered, durable resolution record in the backlog
#   captain-hold-archived   answered, that record intact, archived out of the backlog
#   hold-record-invalid     a backlog row exists under the hold identity but is neither
#   orphaned-terminal-lane  no durable hold and the owning lane already finished
#   awaiting-answer         no durable hold and the lane is live - the answer is owed
#   undetermined            the backlog tool could not be consulted; carries a reason
#                           and sets complete=false, so it is disclosed, never hidden
#
# Usage: fm-decision-ledger.sh [--json]
# Output contract: `fm-decision-ledger.v1` JSON on stdout. Read-only: no locks or
# mutation. It uses the canonical bounded snapshot inventory, including its
# disclosed cross-home reads, so it never duplicates the backlog grammar. Exits
# non-zero when its own coverage invariants do not hold.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-decision-ledger.sh [--json]

Emit the fm-decision-ledger.v1 coverage record for the active FM_HOME: raw
decision events, folded distinct open keys, stale and superseded keys, and one
disposition-bearing row per distinct live key. JSON is the only format.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) : ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-decision-ledger: jq not found" >&2; exit 1; }

NOW=${FM_LEDGER_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
HOLD="$SCRIPT_DIR/fm-decision-hold.sh"
SNAPSHOT="$SCRIPT_DIR/fm-fleet-snapshot.sh"

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# One pass over every status log for the RAW event counts and the set of keys ever
# opened. These are event measurements, deliberately kept separate from the fold,
# but they are not a second reading of what a decision line IS: every candidate is
# classified by status_line_decision_transition, which answers with the fold's own
# verdict, so a line the fold declines to treat as a transition can never be
# counted here as a decision opened and then silently superseded.
# The grep is a pure cost filter, never a parser: a line whose verb is one of the
# four must contain that verb as a literal substring, so the filter can only drop
# lines the accessor below would reject anyway.
raw_needs_decision=0
raw_blocked=0
raw_resolved=0
raw_captain_held=0
opened_pairs=''
resolve_verb=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
held_verb=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
for f in "$STATE"/*.status; do
  [ -e "$f" ] || continue
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
  task=$(basename "$f"); task="${task%.status}"
  while IFS= read -r line || [ -n "$line" ]; do
    case "${line//[[:space:]]/}" in '') continue ;; esac
    transition=$(status_line_decision_transition "$line") || continue
    key=${transition%%	*}
    verb=${transition#*	}
    case "$verb" in
      needs-decision) raw_needs_decision=$((raw_needs_decision + 1)) ;;
      blocked) raw_blocked=$((raw_blocked + 1)) ;;
      "$resolve_verb") raw_resolved=$((raw_resolved + 1)); continue ;;
      "$held_verb") raw_captain_held=$((raw_captain_held + 1)); continue ;;
      *) continue ;;
    esac
    opened_pairs="${opened_pairs}${task}	${key}
"
  done <<EOF
$(grep -F -e needs-decision -e blocked -e "$resolve_verb" -e "$held_verb" "$f" || true)
EOF
done
opened_distinct=$(printf '%s' "$opened_pairs" | sed '/^$/d' | LC_ALL=C sort -u | grep -c '' || true)
OPENED_ROWS=$(printf '%s' "$opened_pairs" | jq -R -s '
  [split("\n")[] | select(length > 0) | split("\t") | {task:.[0], key:.[1]}] | unique')

# The authoritative status fold. scan_open_decisions prints
# "<task>\t<key>\t<verb>\t<note>".
OPEN=$(scan_open_decisions "$STATE")
status_open_count=$(printf '%s\n' "$OPEN" | grep -c . || true)

LEDGER_SECONDMATES=${FM_LEDGER_SECONDMATES:-20}
LEDGER_SECONDMATE_TIMEOUT=${FM_LEDGER_SECONDMATE_TIMEOUT:-8}
LEDGER_SECONDMATE_MAX_BYTES=${FM_LEDGER_SECONDMATE_MAX_BYTES:-262144}
for bound in LEDGER_SECONDMATES LEDGER_SECONDMATE_TIMEOUT LEDGER_SECONDMATE_MAX_BYTES; do
  value=${!bound}
  case "$value" in
    ''|*[!0-9]*|0)
      echo "fm-decision-ledger: $bound must be a positive integer" >&2
      exit 1
      ;;
  esac
done

# The canonical snapshot owns the backlog grammar and actionability predicate.
# Its bounded cross-home read is preferable to a divergent second parser; child
# unavailability is disclosed by the snapshot and never removes main-home holds.
SNAPSHOT_JSON=$(FM_SNAPSHOT_SECONDMATES="$LEDGER_SECONDMATES" \
  FM_SNAPSHOT_SECONDMATE_TIMEOUT="$LEDGER_SECONDMATE_TIMEOUT" \
  FM_SNAPSHOT_SECONDMATE_MAX_BYTES="$LEDGER_SECONDMATE_MAX_BYTES" \
  "$SNAPSHOT" --json) || {
  echo "fm-decision-ledger: canonical captain-hold inventory unavailable" >&2
  exit 1
}
HOLD_TSV=$(printf '%s' "$SNAPSHOT_JSON" | jq -er '
  if .backlog.present != true then error("canonical backlog unavailable")
  elif (.backlog.records | type) != "array" then error("canonical backlog records unavailable")
  else .backlog.records[]
    | select(.structured == true and .captain_actionable == true)
    | [ .id, (.body_lines[]? | select(startswith("Origin: ")) | ltrimstr("Origin: ")),
        (.body_lines[]? | select(startswith("Decision key: ")) | ltrimstr("Decision key: ")),
        (.title // "captain decision pending") ]
    | @tsv
  end') || {
  echo "fm-decision-ledger: canonical captain-hold inventory unavailable" >&2
  exit 1
}
HOLD_INPUT=''
while IFS=$'\t' read -r hold_id task key summary; do
  [ -n "$hold_id" ] || continue
  hold_state=undetermined
  case "$task" in ''|*[!A-Za-z0-9._-]*) ;; *)
    case "$key" in ''|*[!A-Za-z0-9._-]*) ;; *)
      hold_state=$("$HOLD" state "$task" "$key" 2>/dev/null | awk -F'\t' 'NR == 1 { print $2 }') ;;
    esac
  esac
  [ -n "$hold_state" ] || hold_state=undetermined
  HOLD_INPUT="${HOLD_INPUT}${hold_id}"$'\t'"${task}"$'\t'"${key}"$'\t'"${summary}"$'\t'"${hold_state}"$'\n'
done <<EOF
$HOLD_TSV
EOF
HOLD_ROWS=$(printf '%s' "$HOLD_INPUT" | jq -R -s '
  [ split("\n")[] | select(length > 0) | split("\t")
    | {hold_id:.[0], task:(if .[1] == "" then null else .[1] end),
       key:(if .[2] == "" then null else .[2] end), summary:(.[3] // "captain decision pending"),
       state:(.[4] // "undetermined")} ]') || {
  echo "fm-decision-ledger: local captain-hold records could not be read" >&2
  exit 1
}
active_hold_count=$(printf '%s' "$HOLD_ROWS" | jq 'length')

# Per-key disposition. Keys are grouped by task so the hold classifier is invoked
# once per owning lane rather than once per key.
ROWS=''
stale_count=0
undetermined_count=0
current_task=''
task_keys=''
task_states=''

lane_terminal() {  # <task>
  local task=$1
  local meta="$STATE/$task.meta"
  local kind last verb
  kind=$(meta_value "$meta" kind)
  [ "$kind" != secondmate ] || return 1
  last=$(last_status_line "$STATE/$task.status")
  verb=$(status_line_verb "$last")
  case "$verb" in
    done|failed) return 0 ;;
  esac
  return 1
}

load_task_states() {  # <task> <newline-separated "key\tverb\tnote" records>
  local task=$1 keys=$2 k
  local -a args=()
  while IFS=$'\t' read -r k _ _; do
    [ -n "$k" ] || continue
    args+=("$k")
  done <<EOF
$keys
EOF
  task_states=''
  [ "${#args[@]}" -gt 0 ] || return 0
  task_states=$("$HOLD" state "$task" "${args[@]}" 2>/dev/null) || task_states=''
}

state_for_key() {  # <key>
  local key=$1 found
  found=$(printf '%s\n' "$task_states" \
    | awk -F'\t' -v k="$key" '$1 == k { print $2; exit }')
  [ -n "$found" ] || found=undetermined
  printf '%s' "$found"
}

emit_task_rows() {  # uses current_task/task_keys/task_states
  local key verb note hold_state disposition detail
  [ -n "$current_task" ] || return 0
  while IFS=$'\t' read -r key verb note; do
    [ -n "$key" ] || continue
    hold_state=$(state_for_key "$key")
    detail=''
    case "$hold_state" in
      held) disposition=captain-hold-active ;;
      resolved) disposition=captain-hold-resolved ;;
      archived) disposition=captain-hold-archived ;;
      invalid) disposition=hold-record-invalid ;;
      absent)
        if lane_terminal "$current_task"; then
          disposition=orphaned-terminal-lane
          stale_count=$((stale_count + 1))
        else
          disposition=awaiting-answer
        fi
        ;;
      *)
        disposition=undetermined
        detail='backlog tool unavailable; hold state could not be classified'
        undetermined_count=$((undetermined_count + 1))
        ;;
    esac
    ROWS="${ROWS}${current_task}	${key}	${verb}	${disposition}	${detail}	${note}
"
  done <<EOF
$task_keys
EOF
}

while IFS=$'\t' read -r task key verb note; do
  [ -n "$task" ] || continue
  note=${note//	/ }
  if [ "$task" != "$current_task" ]; then
    if [ -n "$current_task" ]; then
      load_task_states "$current_task" "$task_keys"
      emit_task_rows
    fi
    current_task=$task
    task_keys=''
  fi
  task_keys="${task_keys}${key}	${verb}	${note}
"
done <<EOF
$OPEN
EOF
if [ -n "$current_task" ]; then
  load_task_states "$current_task" "$task_keys"
  emit_task_rows
fi

superseded=$((opened_distinct - status_open_count))
[ "$superseded" -ge 0 ] || superseded=0
complete=true
[ "$undetermined_count" -eq 0 ] || complete=false

LEDGER=$(printf '%s' "$ROWS" | jq -R -s \
  --arg home "$FM_HOME" \
  --arg now "$NOW" \
  --argjson needs_decision "$raw_needs_decision" \
  --argjson blocked "$raw_blocked" \
  --argjson resolved "$raw_resolved" \
  --argjson captain_held "$raw_captain_held" \
  --argjson opened_distinct "$opened_distinct" \
  --argjson superseded "$superseded" \
  --argjson stale "$stale_count" \
  --argjson status_open "$status_open_count" \
  --argjson active_holds "$active_hold_count" \
  --argjson holds "$HOLD_ROWS" \
  --argjson opened "$OPENED_ROWS" \
  --argjson complete "$complete" '
  def trunc($n): if (length > $n) then (.[:$n] + "…") else . end;
  [ split("\n")[] | select(length > 0) | split("\t")
    | {task:.[0], key:.[1], verb:.[2], disposition:.[3],
       detail:(.[4] // ""), summary:((.[5] // "") | trunc(160)),
       hold_id:(.[0] + "-decision-" + .[1]), origins:["folded-status-key"],
       current_sources:["folded-status-key"]} ] as $status_rows
  | ($holds | map(. as $hold |
      if (.task | type) == "string" and (.task | length) > 0
         and (.key | type) == "string" and (.key | length) > 0 then
        {task, key, verb:"captain-hold",
         disposition:(if .state == "held" then "captain-hold-active"
                      elif .state == "invalid" or .state == "absent" or .state == "resolved" or .state == "archived" then "hold-record-invalid"
                      else "undetermined" end),
         detail:(if .state == "held" then ""
                 elif .state == "invalid" or .state == "absent" or .state == "resolved" or .state == "archived" then "active captain hold record is not durably held"
                 else "backlog tool unavailable; hold state could not be classified" end),
         summary:(.summary | trunc(160)), hold_id, current_sources:["captain-hold"],
         origins:((if any($opened[]; .task == $hold.task and .key == $hold.key)
                   then ["folded-status-key"] else [] end) + ["captain-hold"])}
      else
        {task:null, key:.hold_id, verb:"captain-hold", disposition:"undetermined",
         detail:"active captain hold has no readable Origin and Decision key record",
         summary:(.summary | trunc(160)), hold_id:.hold_id, origins:["captain-hold"],
         current_sources:["captain-hold"]}
      end
    )) as $hold_rows
  | ($status_rows + $hold_rows
     | group_by(.hold_id)
     | map(reduce .[] as $row ({};
         . as $existing
         | ($existing * $row)
         | .origins = (($existing.origins // []) + ($row.origins // []) | unique)
         | .current_sources = (($existing.current_sources // []) + ($row.current_sources // []) | unique)
         | .detail = ($row.detail // "")
       ))) as $rows
  | {
      schema: "fm-decision-ledger.v1",
      home: $home,
      generated: $now,
      complete: ($complete and ($rows | all(.disposition != "undetermined"))),
      raw_decision_events: {
        needs_decision: $needs_decision,
        blocked: $blocked,
        opening_total: ($needs_decision + $blocked),
        resolved: $resolved,
        captain_held: $captain_held,
        closing_total: ($resolved + $captain_held)
      },
      keys_opened_distinct: $opened_distinct,
      keys_superseded: $superseded,
      keys_stale: $stale,
      status_open_decision_keys: $status_open,
      captain_holds_active: $active_holds,
      open_decision_keys: ($rows | length),
      open_decisions: $rows,
      definitions: {
        raw_decision_events: "counts of individual status EVENT lines the fold treats as decision transitions; a lane can open, close, and reopen the same decision many times. These are not open decisions and must never be reported as any number of them.",
        keys_opened_distinct: "distinct task+key decisions ever opened, however many events each took.",
        keys_superseded: "distinct keys that were opened and have since been closed.",
        keys_stale: "open keys whose owning lane already finished; they are still counted open and still carry a disposition.",
        status_open_decision_keys: "distinct still-open keys from fm-classify-lib.sh status_open_decisions. This is a folded status-key figure, not a raw event count.",
        captain_holds_active: "actionable captain backlog rows with -decision- hold identities. This is a held-backlog-row figure, not a status-key or raw-event count.",
        open_decision_keys: "the deduplicated union of folded status keys and actionable captain holds. Always equal to the length of open_decisions; current_sources keeps the source figures derivable while origins preserves historical lineage.",
        open_decisions: "one row per distinct live decision identity, each with a disposition, current_sources, and origins. No key or captain hold is omitted, capped, or left blank.",
        complete: "false when any row is undetermined, so a partially classified ledger can never read as a fully accounted one."
      }
    }') || { echo "fm-decision-ledger: ledger assembly failed" >&2; exit 1; }

# The coverage invariants, enforced before anything is published. A figure that is
# not backed by an enumerated, disposition-bearing row for every live key never
# reaches a reader.
printf '%s' "$LEDGER" | jq -e '
  def known: ["captain-hold-active","captain-hold-resolved","captain-hold-archived",
              "hold-record-invalid","orphaned-terminal-lane","awaiting-answer","undetermined"];
  if .open_decision_keys != (.open_decisions | length) then
    error("open_decision_keys does not equal the enumerated open_decisions rows")
  elif (.open_decisions | any(.disposition == null or .disposition == "")) then
    error("a live decision key carries no disposition")
  elif (.open_decisions | any(.disposition as $d | (known | index($d)) == null)) then
    error("a live decision key carries a disposition outside the fixed vocabulary")
  elif (.open_decisions | any(.disposition == "undetermined" and (.detail // "") == "")) then
    error("an undetermined disposition carries no reason")
  elif (.open_decisions | any((.origins | type) != "array" or (.origins | length) == 0)) then
    error("a live decision identity carries no origin")
  elif (.open_decisions | any((.current_sources | type) != "array" or (.current_sources | length) == 0)) then
    error("a live decision identity carries no current source")
  elif .status_open_decision_keys != ([.open_decisions[] | select(.current_sources | index("folded-status-key"))] | length) then
    error("status_open_decision_keys does not equal its enumerated current-source rows")
  elif .captain_holds_active != ([.open_decisions[] | select(.current_sources | index("captain-hold"))] | length) then
    error("captain_holds_active does not equal its enumerated current-source rows")
  elif .keys_stale != ([.open_decisions[] | select((.current_sources | index("folded-status-key")) and .disposition == "orphaned-terminal-lane")] | length) then
    error("keys_stale does not equal its enumerated current-source rows")
  elif (.complete == true and (.open_decisions | any(.disposition == "undetermined"))) then
    error("a ledger with undetermined rows claims completeness")
  elif .keys_opened_distinct < .status_open_decision_keys then
    error("more status keys are open than were ever opened")
  else . end' >/dev/null \
  || { echo "fm-decision-ledger: coverage invariants failed; refusing to emit" >&2; exit 1; }

printf '%s\n' "$LEDGER"
