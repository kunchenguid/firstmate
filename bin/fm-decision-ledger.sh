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
# The open set itself is NOT recomputed here. It comes from fm-classify-lib.sh's
# authoritative status_open_decisions fold, through its scan_open_decisions
# wrapper, so this surface can never drift from the fold every other consumer uses.
# Per-key dispositions come from `fm-decision-hold.sh state`, the one classifier
# for a hold identity's durable state.
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
# Output contract: `fm-decision-ledger.v1` JSON on stdout. Read-only: no locks, no
# mutation, no network. Exits non-zero when its own coverage invariants do not hold.
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

# The authoritative fold. scan_open_decisions prints "<task>\t<key>\t<verb>\t<note>".
OPEN=$(scan_open_decisions "$STATE")

# Per-key disposition. Keys are grouped by task so the hold classifier is invoked
# once per owning lane rather than once per key.
ROWS=''
open_count=0
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
  open_count=$((open_count + 1))
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

superseded=$((opened_distinct - open_count))
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
  --argjson complete "$complete" '
  def trunc($n): if (length > $n) then (.[:$n] + "…") else . end;
  [ split("\n")[] | select(length > 0) | split("\t")
    | {task:.[0], key:.[1], verb:.[2], disposition:.[3],
       detail:(.[4] // ""), summary:((.[5] // "") | trunc(160))} ] as $rows
  | {
      schema: "fm-decision-ledger.v1",
      home: $home,
      generated: $now,
      complete: $complete,
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
      open_decision_keys: ($rows | length),
      open_decisions: $rows,
      definitions: {
        raw_decision_events: "counts of individual status EVENT lines the fold treats as decision transitions; a lane can open, close, and reopen the same decision many times. These are not open decisions and must never be reported as any number of them.",
        keys_opened_distinct: "distinct task+key decisions ever opened, however many events each took.",
        keys_superseded: "distinct keys that were opened and have since been closed.",
        keys_stale: "open keys whose owning lane already finished; they are still counted open and still carry a disposition.",
        open_decision_keys: "the authoritative open-decision count: distinct still-open keys from fm-classify-lib.sh status_open_decisions. Always equal to the length of open_decisions.",
        open_decisions: "one row per distinct open key, each with a disposition. No key is omitted, capped, or left blank.",
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
  elif (.complete == true and (.open_decisions | any(.disposition == "undetermined"))) then
    error("a ledger with undetermined rows claims completeness")
  elif .keys_opened_distinct < .open_decision_keys then
    error("more keys are open than were ever opened")
  else . end' >/dev/null \
  || { echo "fm-decision-ledger: coverage invariants failed; refusing to emit" >&2; exit 1; }

printf '%s\n' "$LEDGER"
