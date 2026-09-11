#!/usr/bin/env bash
# fm-afk-return.sh - deterministic away-mode return: the return brief and the
# catch-up gate.
#
# Usage:
#   fm-afk-return.sh          Stop away mode, render the return brief, and open/check the gate.
#   fm-afk-return.sh begin    Same as the default command.
#   fm-afk-return.sh check    Re-render the brief and close the gate only after blockers resolve.
#   fm-afk-return.sh guard    Read-only consult: exit 3 while away mode is still
#                            active, exit 4 while return catch-up is pending.
#   fm-afk-return.sh catchup-summary  Read-only catch-up projection for a reporting surface.
#
# THE RETURN BRIEF (stdout, on begin and on every check) is rendered from durable
# records, never from conversation memory: the archived away-posture record
# (bin/fm-afk-contract.sh), the supervision outcome store
# (bin/fm-branch-outcome.sh), the held set in the backlog (tasks-axi), and the
# status logs. Its order is fixed: supervisor health across the away window
# first, then every mandate clause the captain recorded, including superseded
# in-session read-backs (this release records clauses and does not execute them,
# and the brief says so), then what is
# waiting on the captain, then what was tried and failed or could not be fixed,
# then what the away session handled, then cost. The health snapshot is taken
# BEFORE the daemon shutdown so the shutdown itself cannot read as a gap.
#
# THE GATE. `blocked:` is the crewmate protocol's firstmate-actionable verb. A
# live task's open blocked event must be remediated and closed with
# `resolved [key=...]`, or explicitly reclassified in the status stream with a
# durable reason, before an ordinary captain request may proceed.
# `needs-decision:` is deliberately not part of this blocker gate. The gate
# keeps every open blocker until that blocker's own resolution is proven.
# Captain-verdict outcomes are listed under "waiting on you", but cannot exempt
# a blocker because decision-key provenance is deferred to phase 4
# (fm-afk-clauses-execute-r1). Away-window attribution uses second-resolution
# epochs; a durable sequence boundary and archive-chain identity are deferred to
# that phase as well. Replacement records carry the original entry boundary and
# superseded mandates are included as the phase-1 fail-safe.
#
# The durable state/.afk-return-catchup file is written BEFORE daemon shutdown,
# so a crash between stopping, wake presentation, and blocker handling fails
# closed. It retains the presented wake, buffered-escalation, wedge-marker,
# health, and posture-record evidence until every live open blocker is closed
# and `check` succeeds. Repeated begin/check calls are idempotent. `guard` and
# `catchup-summary` never mutate state and are suitable for ordinary read
# entrypoints such as fm-bearings-snapshot.sh. `guard` separates its two
# refusal branches by exit status so a reporting surface can keep refusing
# during an active away window while still rendering the catch-up posture as
# content; this file owns the gate format both branches read.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
GATE="$STATE/.afk-return-catchup"
LOCK="$STATE/.afk-return-catchup.lock"
RETURN_GRACE=${FM_GUARD_GRACE:-300}

# The posture-record owner: path helpers only; every read goes through its
# subcommands. It sources fm-classify-lib.sh, which has no side effects, so the
# advertised read-only guard stays literal.
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"
CONTRACT="$SCRIPT_DIR/fm-afk-contract.sh"

usage() {
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

append_evidence() {  # <kind> <text> <file>
  local kind=$1 text=$2 file=$3 clean record
  [ -n "$text" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    clean=$(printf '%s' "$line" | clean_field)
    record=$(printf 'evidence\t%s\t%s' "$kind" "$clean")
    grep -Fqx "$record" "$file" 2>/dev/null || printf '%s\n' "$record" >> "$file"
  done <<EOF
$text
EOF
}

remove_evidence() {  # <kind> <text> <file>
  local kind=$1 text=$2 file=$3 record pending
  record=$(printf 'evidence\t%s\t%s' "$kind" "$text")
  pending=$(mktemp "$(dirname "$file")/.afk-return-evidence-filter.XXXXXX") || return 1
  grep -Fvx "$record" "$file" > "$pending" 2>/dev/null || true
  mv "$pending" "$file"
}

remove_evidence_prefix() {  # <kind> <text-prefix> <file>
  local kind=$1 text=$2 file=$3 prefix pending
  prefix=$(printf 'evidence\t%s\t%s' "$kind" "$text")
  pending=$(mktemp "$(dirname "$file")/.afk-return-evidence-filter.XXXXXX") || return 1
  awk -v prefix="$prefix" 'index($0, prefix) != 1 { print }' "$file" > "$pending" 2>/dev/null || true
  mv "$pending" "$file"
}

preserve_evidence() {  # <destination>
  local destination=$1
  [ -f "$GATE" ] || return 0
  grep -E '^(evidence|window|contract|superseded)'"$(printf '\t')" "$GATE" >> "$destination" 2>/dev/null || true
}

append_superseded_record() {  # <path> <file>
  local path=$1 file=$2 row
  row=$(printf 'superseded\t%s' "$path")
  grep -Fqx "$row" "$file" 2>/dev/null || printf '%s\n' "$row" >> "$file"
}

remove_superseded_record() {  # <path> <file>
  local path=$1 file=$2 row pending
  row=$(printf 'superseded\t%s' "$path")
  pending=$(mktemp "$(dirname "$file")/.afk-return-superseded-filter.XXXXXX") || return 1
  grep -Fvx "$row" "$file" > "$pending" 2>/dev/null || true
  mv "$pending" "$file"
}

# The epoch the away window started at, from the gate's retained contract row,
# else from the live record (before it is archived), else from the legacy away
# flag's own timestamp, else unknown (empty).
gate_contract_epoch() {
  awk -F '\t' '$1 == "contract" { print $2; exit }' "$GATE" 2>/dev/null || true
}

gate_window_epoch() {
  awk -F '\t' '$1 == "window" || $1 == "contract" { print $2; exit }' "$GATE" 2>/dev/null || true
}

window_start_epoch() {
  local epoch flag
  epoch=$(gate_window_epoch)
  case "$epoch" in ''|*[!0-9]*) epoch= ;; esac
  if [ -z "$epoch" ] && fm_afk_contract_present "$STATE"; then
    epoch=$("$CONTRACT" field entered_epoch 2>/dev/null || true)
  fi
  if [ -z "$epoch" ] && [ -f "$STATE/.afk" ]; then
    flag=$(head -1 "$STATE/.afk" 2>/dev/null || true)
    case "$flag" in ''|*[!0-9]*) ;; *) epoch=$flag ;; esac
  fi
  case "$epoch" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$epoch" ;; esac
}

# Reads the store through its owner so a malformed store refuses rather than
# misleads.
STORE_ROWS=
store_rows_load() {  # <since-epoch>
  local since=$1 raw
  STORE_ROWS=
  [ -s "$STATE/branch-outcomes.jsonl" ] || return 0
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  raw=$("$SCRIPT_DIR/fm-branch-outcome.sh" list --recent 1000000 2>/dev/null) \
    || return 1
  STORE_ROWS=$(printf '%s\n' "$raw" | jq -r --argjson since "$since" \
    'select(.epoch >= $since) | [.seq, .task, .verdict, (.statusEndpoint // 0), (.summary // "")] | @tsv' 2>/dev/null) \
    || { STORE_ROWS=; return 1; }
}

STATUS_SCAN_ERROR=
status_path_readable() {
  [ -f "$1" ] && [ -r "$1" ] && [ ! -L "$1" ]
}

scan_open_blockers() {  # -> tab-separated blocker rows
  local meta id status key verb summary clean_summary open
  STATUS_SCAN_ERROR=
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta")
    id=${id%.meta}
    status="$STATE/$id.status"
    if ! status_path_readable "$status"; then
      STATUS_SCAN_ERROR=$status
      return 1
    fi
    if ! open=$(status_open_decisions "$status"); then
      STATUS_SCAN_ERROR=$status
      return 1
    fi
    while IFS="$(printf '\t')" read -r key verb summary; do
      [ "$verb" = blocked ] || continue
      clean_summary=$(printf '%s' "$summary" | clean_field)
      printf 'blocker\t%s\t%s\t%s\n' "$id" "$key" "$clean_summary"
    done <<EOF
$open
EOF
  done
}

write_pending_seed() {  # <window-epoch> <contract-epoch>  Fail-closed marker before any lifecycle mutation.
  local window_epoch=$1 contract_epoch=$2 pending started
  mkdir -p "$STATE" || return 1
  started=$(awk -F '\t' '$1 == "started" { print $2; exit }' "$GATE" 2>/dev/null || true)
  [ -n "$started" ] || started=$(date +%s)
  pending=$(mktemp "$STATE/.afk-return-catchup.pending.XXXXXX") || return 1
  {
    printf 'schema\tfm-afk-return.v1\n'
    printf 'started\t%s\n' "$started"
    printf 'phase\tstopping-and-draining\n'
    [ -z "$window_epoch" ] || printf 'window\t%s\n' "$window_epoch"
    [ -z "$contract_epoch" ] || printf 'contract\t%s\n' "$contract_epoch"
    preserve_evidence /dev/stdout | grep -Ev "^(window|contract)$(printf '\t')" || true
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$GATE"
}

write_gate() {  # <evidence-file> <blockers-file>
  local evidence=$1 blockers=$2 pending started window_epoch contract_epoch
  pending=$(mktemp "$STATE/.afk-return-catchup.pending.XXXXXX") || return 1
  started=$(awk -F '\t' '$1 == "started" { print $2; exit }' "$GATE" 2>/dev/null || true)
  [ -n "$started" ] || started=$(date +%s)
  window_epoch=$(gate_window_epoch)
  contract_epoch=$(gate_contract_epoch)
  {
    printf 'schema\tfm-afk-return.v1\n'
    printf 'started\t%s\n' "$started"
    printf 'phase\tblocked\n'
    [ -z "$window_epoch" ] || printf 'window\t%s\n' "$window_epoch"
    [ -z "$contract_epoch" ] || printf 'contract\t%s\n' "$contract_epoch"
    grep -Ev "^(window|contract)$(printf '\t')" "$evidence" 2>/dev/null || true
    cat "$blockers" 2>/dev/null || true
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$GATE"
}

print_evidence() {  # <file>
  local file=$1 kind text
  while IFS="$(printf '\t')" read -r tag kind text; do
    [ "$tag" = evidence ] || continue
    printf 'catch-up %s: %s\n' "$kind" "$text"
  done < "$file"
}

print_blockers() {  # <file>
  local file=$1 tag id key summary
  while IFS="$(printf '\t')" read -r tag id key summary; do
    [ "$tag" = blocker ] || continue
    printf 'firstmate-actionable blocker: %s [key=%s] %s\n' "$id" "$key" "$summary"
  done < "$file"
}

clear_delivery_artifacts() {
  rm -f \
    "$STATE/.subsuper-escalations" \
    "$STATE/.subsuper-escalations.since" \
    "$STATE/.subsuper-inject-wedged"
}

# The lifecycle retention reasons the gate kept, one per line, empty when the
# gate was retained for open blockers alone.
gate_retention_reasons() {  # <file>
  local file=$1 tag kind text
  while IFS="$(printf '\t')" read -r tag kind text; do
    [ "$tag" = evidence ] && [ "$kind" = lifecycle ] || continue
    printf '%s\n' "$text"
  done < "$file"
}

gate_has_blockers() {  # <file>
  grep -q "^blocker$(printf '\t')" "$1" 2>/dev/null
}

# Read-only catch-up projection for a reporting surface such as
# fm-bearings-snapshot.sh: one tab-separated line
# `<open-blocker-count><TAB><first-retention-reason>`, and exit 1 when no gate
# is open. The reason field is empty when open blockers alone hold the gate.
catchup_summary() {
  local count reason
  [ -e "$GATE" ] || return 1
  count=$(grep -c "^blocker$(printf '\t')" "$GATE" 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  reason=$(gate_retention_reasons "$GATE" | head -1)
  printf '%s\t%s\n' "$count" "$reason"
}

return_guard() {
  local reasons
  if [ -e "$STATE/.afk" ] || fm_afk_contract_present "$STATE"; then
    printf 'fm-afk-return: away mode is still active; run bin/fm-afk-return.sh before ordinary captain work\n' >&2
    return 3
  fi
  if [ -e "$GATE" ]; then
    if gate_has_blockers "$GATE"; then
      printf 'fm-afk-return: return catch-up is pending; remediate or durably reclassify every listed blocker, then run bin/fm-afk-return.sh check\n' >&2
      print_blockers "$GATE" >&2
    else
      # No blocker row exists, so naming "every listed blocker" would ask for
      # something the gate does not list. Name the lifecycle retention reason
      # that actually holds it instead.
      printf 'fm-afk-return: return catch-up is pending with no open blocker; clear the retention reason below, then run bin/fm-afk-return.sh check\n' >&2
      reasons=$(gate_retention_reasons "$GATE")
      if [ -n "$reasons" ]; then
        printf '%s\n' "$reasons" | while IFS= read -r text; do
          printf 'catch-up retained: %s\n' "$text" >&2
        done
      else
        printf 'catch-up retained: the durable gate recorded no retention reason\n' >&2
      fi
    fi
    return 4
  fi
  return 0
}

# --- supervisor health, snapshotted before anything is shut down ------------

health_snapshot() {  # <evidence-file>
  local evidence=$1 beat_age lines=""
  beat_age=$(fm_path_age "$STATE/.last-watcher-beat")
  if [ -e "$STATE/.watcher-down" ]; then
    lines="GAP: watcher downtime was detected during the away window (recovery marker present)"
  fi
  if [ -e "$STATE/.afk" ] && ! fm_afk_daemon_owns_supervision "$STATE"; then
    lines="$lines
GAP: the away daemon was not running at return (the away flag stood with no live daemon)"
  fi
  if [ "$beat_age" -ge "$RETURN_GRACE" ]; then
    lines="$lines
GAP: the watcher beat was ${beat_age}s old at return (grace ${RETURN_GRACE}s)"
  fi
  if [ -s "$STATE/.subsuper-inject-wedged" ]; then
    lines="$lines
delivery wedged: $(head -1 "$STATE/.subsuper-inject-wedged" 2>/dev/null || true)"
  fi
  if [ -z "$(printf '%s' "$lines" | tr -d '[:space:]')" ]; then
    lines="supervision ran through the away window with no detected gap (watcher beat ${beat_age}s old at return)"
  fi
  append_evidence health "$lines" "$evidence"
}

# --- the return brief -------------------------------------------------------

format_duration() {  # <seconds>
  local s=$1
  case "$s" in ''|*[!0-9]*) printf 'unknown'; return ;; esac
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
  elif [ "$s" -ge 60 ]; then printf '%dm' $((s / 60))
  else printf '%ds' "$s"; fi
}

epoch_to_iso() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$1"
}

strip_axi_help() {
  awk '/^help\[/ { skip = 1; next } skip && /^  / { next } { skip = 0; print }'
}

MANDATE_COUNT=0
HELD_READ_FAILED=0
HELD_READ_PATH=
render_mandate_record() {  # <record> [superseded-time]
  local record=$1 superseded=${2:-} id action object when stop text missing suffix="" words flag
  [ -z "$superseded" ] || suffix=" - superseded at $superseded"
  while IFS="$(printf '\t')" read -r id action object when stop; do
    [ -n "$id" ] || continue
    MANDATE_COUNT=$((MANDATE_COUNT + 1))
    printf '  - %s. %s ' "$id" "$action"
    fm_afk_contract_unescape "$object"
    printf ' when '
    fm_afk_contract_unescape "$when"
    if [ "$stop" != - ]; then
      printf ' stop '
      fm_afk_contract_unescape "$stop"
    fi
    flag=$("$CONTRACT" flags --path "$record" | awk -F '\t' -v id="$id" '$1 == id { print $2 }')
    [ -z "$flag" ] || printf " - flagged: names '%s', a never-set concept that is never pre-authorizable" "$flag"
    printf '%s - recorded, not executed by this release\n' "$suffix"
  done <<EOF
$("$CONTRACT" clauses --path "$record")
EOF
  while IFS="$(printf '\t')" read -r id text missing; do
    [ -n "$id" ] || continue
    MANDATE_COUNT=$((MANDATE_COUNT + 1))
    printf '  - %s. "' "$id"
    fm_afk_contract_unescape "$text"
    printf '"%s - refused at entry: missing %s\n' "$suffix" "$missing"
  done <<EOF
$("$CONTRACT" refused --path "$record")
EOF
  words=$("$CONTRACT" words --path "$record"; printf x)
  words=${words%x}
  if [ -n "$words" ]; then
    if [ -n "$superseded" ]; then
      printf '  your words superseded at %s:\n' "$superseded"
    else
      printf '  your words at entry:\n'
    fi
    printf '%s' "$words" | sed 's/^/    /'
    case "$words" in *$'\n') ;; *) printf '\n' ;; esac
  fi
}

render_return_brief() {  # <evidence-file> <blockers-file> <since-epoch>
  local evidence=$1 blockers=$2 since=$3 now record superseded superseded_at archive_dir stamp
  local tag task key summary count routine captain live held_err last verb rows status
  now=$(date +%s)
  printf '=== Return brief'
  if [ -n "$since" ]; then
    printf ' (away %s -> %s, %s)' "$(epoch_to_iso "$since")" "$(epoch_to_iso "$now")" "$(format_duration $((now - since)))"
  fi
  printf ' ===\n'

  # 1. health, first, always.
  printf 'Supervisor health:\n'
  awk -F '\t' '$1 == "evidence" && ($2 == "health" || ($2 == "lifecycle" && ($3 ~ /^outcome store unreadable/ || $3 ~ /^status file unreadable:/ || $3 ~ /^away-posture record (unreadable|missing):/ || $3 ~ /^archived away-posture record/ || $3 ~ /^superseded away-posture record/))) { print "  - " $3 }' "$evidence"

  # 2. the mandate.
  printf 'Mandate clauses:\n'
  record=""
  MANDATE_COUNT=0
  [ -z "$since" ] || record=$("$CONTRACT" archived "$since" 2>/dev/null || true)
  if [ -n "$record" ]; then
    archive_dir=$(fm_afk_contract_archive_dir "$STATE")
    for superseded in "$archive_dir/$since-superseded-"*.afk-contract; do
      [ -f "$superseded" ] || continue
      stamp=${superseded##*/"$since"-superseded-}
      stamp=${stamp%%-*}
      stamp=${stamp%.afk-contract}
      case "$stamp" in ''|*[!0-9]*) superseded_at=unknown ;; *) superseded_at=$(epoch_to_iso "$stamp") ;; esac
      render_mandate_record "$superseded" "$superseded_at"
    done
    render_mandate_record "$record"
    [ "$MANDATE_COUNT" -gt 0 ] || printf '  (none recorded)\n'
  else
    printf '  (no away-posture record for this window; legacy away flag only)\n'
  fi

  # 3. waiting on the captain.
  printf 'Waiting on you:\n'
  count=0
  HELD_READ_FAILED=0
  HELD_READ_PATH=$(fm_backlog_file "$DATA" 2>/dev/null || printf '%s/backlog.md' "$DATA")
  if held=$(fm_backlog_row_list "$DATA" --state held --fields hold_kind,hold_reason,hold_until 2>&1); then
    rows=$(printf '%s\n' "$held" | strip_axi_help | grep -v '^count: ' | grep -v '^tasks\[0\]' || true)
    if printf '%s\n' "$held" | grep -q '^count: 0'; then
      :
    elif [ -n "$rows" ]; then
      count=$((count + 1))
      printf '  held in the backlog:\n'
      printf '%s\n' "$rows" | sed 's/^/    /'
    fi
  else
    held_err=$(printf '%s' "$held" | head -1 | clean_field)
    count=$((count + 1))
    HELD_READ_FAILED=1
    printf '  held listing unavailable: %s: %s; catch-up stays gated\n' "$HELD_READ_PATH" "$held_err"
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    task=$(basename "$meta"); task=${task%.meta}
    status="$STATE/$task.status"
    status_path_readable "$status" || continue
    while IFS="$(printf '\t')" read -r key verb summary; do
      [ "$verb" = needs-decision ] || continue
      count=$((count + 1))
      printf '  - %s [key=%s] needs your decision: %s\n' "$task" "$key" "$(printf '%s' "$summary" | clean_field)"
    done <<EOF
$(status_open_decisions "$status")
EOF
  done
  rows=$(printf '%s\n' "$STORE_ROWS" | awk -F '\t' '$3 == "captain" { printf "  - %s: %s\n", $2, $5 }')
  if [ -n "$rows" ]; then
    count=$((count + 1))
    printf '  escalated by the away session:\n'
    printf '%s\n' "$rows" | sed 's/^/  /'
  fi
  [ "$count" -gt 0 ] || printf '  (nothing)\n'

  # 4. tried and failed, or could not be fixed.
  printf 'Tried and failed, or could not be fixed:\n'
  count=0
  while IFS="$(printf '\t')" read -r tag task key summary; do
    [ "$tag" = blocker ] || continue
    count=$((count + 1))
    printf '  - %s [key=%s] still blocked, firstmate remediates before ordinary work: %s\n' "$task" "$key" "$summary"
  done < "$blockers"
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    task=$(basename "$meta"); task=${task%.meta}
    status="$STATE/$task.status"
    status_path_readable "$status" || continue
    last=$(last_status_line "$status")
    [ "$(status_line_verb "$last")" = failed ] || continue
    count=$((count + 1))
    printf '  - %s: %s\n' "$task" "$(printf '%s' "$last" | clean_field)"
  done
  [ "$count" -gt 0 ] || printf '  (nothing)\n'

  # 5. handled while away.
  printf 'Handled while away:\n'
  routine=$(printf '%s\n' "$STORE_ROWS" | awk -F '\t' '$3 == "routine" { n++ } END { print n + 0 }')
  captain=$(printf '%s\n' "$STORE_ROWS" | awk -F '\t' '$3 == "captain" { n++ } END { print n + 0 }')
  if [ "$routine" -gt 0 ]; then
    printf '  %s routine outcome(s) recorded; the latest:\n' "$routine"
    printf '%s\n' "$STORE_ROWS" | awk -F '\t' '$3 == "routine" { printf "    - %s: %s\n", $2, $5 }' | tail -5
  else
    printf '  (no routine outcomes recorded in the store for this window)\n'
  fi

  # 6. cost.
  live=0
  for meta in "$STATE"/*.meta; do [ -f "$meta" ] && live=$((live + 1)); done
  printf 'Cost: %s supervision outcome(s) recorded (%s routine, %s captain); %s task(s) live at return.\n' \
    "$((routine + captain))" "$routine" "$captain" "$live"
}

return_reconcile() {
  local evidence blockers drain_err drained wake_ack_line wake_ack_through wake_ack_generation wedge escalations lifecycle_ok=1 since contract_since superseded_record retained_record
  local archived_contract tag kind text retained_live restored_epoch
  evidence=$(mktemp "$STATE/.afk-return-evidence.XXXXXX") || return 1
  blockers=$(mktemp "$STATE/.afk-return-blockers.XXXXXX") || { rm -f "$evidence"; return 1; }
  drain_err=$(mktemp "$STATE/.afk-return-drain.XXXXXX") || { rm -f "$evidence" "$blockers"; return 1; }
  preserve_evidence "$evidence"
  since=$(gate_window_epoch)
  contract_since=$(gate_contract_epoch)

  # Health is read before the shutdown below so the shutdown cannot read as a gap;
  # a repeated begin/check keeps the first snapshot.
  grep -q "^evidence$(printf '\t')health$(printf '\t')" "$evidence" 2>/dev/null || health_snapshot "$evidence"

  while IFS="$(printf '\t')" read -r tag kind text; do
    [ "$tag" = evidence ] && [ "$kind" = lifecycle ] || continue
    case "$text" in
      'away-posture record unreadable: '*'; catch-up stays gated')
        retained_live=${text#away-posture record unreadable: }
        retained_live=${retained_live%; catch-up stays gated} ;;
      'away-posture record missing: '*'; catch-up stays gated')
        retained_live=${text#away-posture record missing: }
        retained_live=${retained_live%; catch-up stays gated} ;;
      *) continue ;;
    esac
    if [ ! -f "$retained_live" ]; then
      remove_evidence lifecycle "away-posture record unreadable: $retained_live; catch-up stays gated" "$evidence" || lifecycle_ok=0
      append_evidence lifecycle "away-posture record missing: $retained_live; catch-up stays gated" "$evidence"
      lifecycle_ok=0
    elif ! fm_afk_contract_validate "$retained_live" 1; then
      remove_evidence lifecycle "away-posture record missing: $retained_live; catch-up stays gated" "$evidence" || lifecycle_ok=0
      append_evidence lifecycle "away-posture record unreadable: $retained_live; catch-up stays gated" "$evidence"
      lifecycle_ok=0
    else
      restored_epoch=$("$CONTRACT" field entered_epoch --path "$retained_live" 2>/dev/null || true)
      case "$restored_epoch" in
        ''|*[!0-9]*) lifecycle_ok=0 ;;
        *)
          if write_pending_seed "$restored_epoch" "$restored_epoch"; then
            since=$restored_epoch
            contract_since=$restored_epoch
            remove_evidence lifecycle "away-posture record missing: $retained_live; catch-up stays gated" "$evidence" || lifecycle_ok=0
            remove_evidence lifecycle "away-posture record unreadable: $retained_live; catch-up stays gated" "$evidence" || lifecycle_ok=0
          else
            lifecycle_ok=0
          fi ;;
      esac
    fi
  done <<EOF
$(cat "$evidence")
EOF

  if [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-daemon-terminal" ] || fm_afk_contract_present "$STATE"; then
    if ! "$SCRIPT_DIR/fm-afk-launch.sh" stop; then
      lifecycle_ok=0
      append_evidence lifecycle 'away-mode shutdown failed; lifecycle state preserved for retry' "$evidence"
    fi
  fi

  drained=$("$SCRIPT_DIR/fm-wake-drain.sh" 2> "$drain_err") || {
    append_evidence lifecycle 'durable wake drain failed; retry catch-up before ordinary work' "$evidence"
    lifecycle_ok=0
    drained=""
  }
  grep -v '^WAKE_ACK_REQUIRED:' "$drain_err" >&2 || true
  wake_ack_line=$(grep '^WAKE_ACK_REQUIRED:' "$drain_err" | tail -1)
  wake_ack_through=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err" | tail -1)
  wake_ack_generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$drain_err" | tail -1)
  if [ -n "$wake_ack_line" ] && { [ -z "$wake_ack_through" ] || [ -z "$wake_ack_generation" ]; }; then
    append_evidence lifecycle 'durable wake drain returned an invalid acknowledgement; retry catch-up before ordinary work' "$evidence"
    lifecycle_ok=0
  fi
  append_evidence wake "$drained" "$evidence"

  if fm_afk_contract_present "$STATE"; then
    if ! fm_afk_contract_validate "$(fm_afk_contract_path "$STATE")" 1; then
      append_evidence lifecycle "away-posture record unreadable: $(fm_afk_contract_path "$STATE"); catch-up stays gated" "$evidence"
      lifecycle_ok=0
    else
      remove_evidence_prefix lifecycle 'away-posture record unreadable:' "$evidence" || lifecycle_ok=0
    fi
  elif [ -n "$contract_since" ]; then
    archived_contract=$("$CONTRACT" archived "$contract_since" 2>/dev/null || true)
    if [ -z "$archived_contract" ]; then
      append_evidence lifecycle "archived away-posture record missing for entered_epoch $contract_since; catch-up stays gated" "$evidence"
      lifecycle_ok=0
    elif ! fm_afk_contract_validate "$archived_contract" 1; then
      append_evidence lifecycle "archived away-posture record unreadable for entered_epoch $contract_since; catch-up stays gated" "$evidence"
      lifecycle_ok=0
    else
      remove_evidence_prefix lifecycle 'away-posture record unreadable:' "$evidence" || lifecycle_ok=0
      remove_evidence_prefix lifecycle 'archived away-posture record missing' "$evidence" || lifecycle_ok=0
      remove_evidence_prefix lifecycle 'archived away-posture record unreadable' "$evidence" || lifecycle_ok=0
    fi

    while IFS="$(printf '\t')" read -r tag retained_record; do
      [ "$tag" = superseded ] || continue
      if [ ! -f "$retained_record" ]; then
        remove_evidence lifecycle "superseded away-posture record unreadable: $retained_record; catch-up stays gated" "$evidence" || lifecycle_ok=0
        append_evidence lifecycle "superseded away-posture record missing: $retained_record; catch-up stays gated" "$evidence"
        lifecycle_ok=0
      elif ! fm_afk_contract_validate "$retained_record" 1; then
        remove_evidence lifecycle "superseded away-posture record missing: $retained_record; catch-up stays gated" "$evidence" || lifecycle_ok=0
        append_evidence lifecycle "superseded away-posture record unreadable: $retained_record; catch-up stays gated" "$evidence"
        lifecycle_ok=0
      else
        remove_evidence lifecycle "superseded away-posture record missing: $retained_record; catch-up stays gated" "$evidence" || lifecycle_ok=0
        remove_evidence lifecycle "superseded away-posture record unreadable: $retained_record; catch-up stays gated" "$evidence" || lifecycle_ok=0
        remove_superseded_record "$retained_record" "$evidence" || lifecycle_ok=0
      fi
    done <<EOF
$(cat "$evidence")
EOF

    for superseded_record in "$(fm_afk_contract_archive_dir "$STATE")/$contract_since-superseded-"*.afk-contract; do
      [ -f "$superseded_record" ] || continue
      if ! fm_afk_contract_validate "$superseded_record" 1; then
        append_superseded_record "$superseded_record" "$evidence"
        append_evidence lifecycle "superseded away-posture record unreadable: $superseded_record; catch-up stays gated" "$evidence"
        lifecycle_ok=0
      fi
    done
  fi

  if [ -s "$STATE/.subsuper-inject-wedged" ]; then
    wedge=$(head -1 "$STATE/.subsuper-inject-wedged" 2>/dev/null || true)
    append_evidence wedge "$wedge" "$evidence"
  fi
  if [ -s "$STATE/.subsuper-escalations" ]; then
    escalations=$(cat "$STATE/.subsuper-escalations" 2>/dev/null || true)
    append_evidence escalation "$escalations" "$evidence"
  fi

  if store_rows_load "$since"; then
    remove_evidence lifecycle 'outcome store unreadable, catch-up stays gated' "$evidence" || lifecycle_ok=0
  else
    append_evidence lifecycle 'outcome store unreadable, catch-up stays gated' "$evidence"
    lifecycle_ok=0
  fi
  if scan_open_blockers > "$blockers"; then
    remove_evidence_prefix lifecycle 'status file unreadable:' "$evidence" || lifecycle_ok=0
  else
    append_evidence lifecycle "status file unreadable: $STATUS_SCAN_ERROR; catch-up stays gated" "$evidence"
    lifecycle_ok=0
  fi
  render_return_brief "$evidence" "$blockers" "$since"
  if [ "$HELD_READ_FAILED" -eq 1 ]; then
    append_evidence lifecycle "held set unreadable: $HELD_READ_PATH; catch-up stays gated" "$evidence"
    lifecycle_ok=0
  else
    remove_evidence_prefix lifecycle 'held set unreadable:' "$evidence" || lifecycle_ok=0
  fi
  if [ "$lifecycle_ok" -ne 1 ] || grep -q "^blocker$(printf '\t')" "$blockers"; then
    write_gate "$evidence" "$blockers" || { rm -f "$evidence" "$blockers" "$drain_err"; return 1; }
    printf 'fm-afk-return: catch-up must finish before the captain request\n' >&2
    print_evidence "$GATE" >&2
    print_blockers "$GATE" >&2
    printf 'fm-afk-return: handle each blocker now, or close it with resolved [key=...] and append a durable reclassification reason, then run bin/fm-afk-return.sh check\n' >&2
    rm -f "$evidence" "$blockers" "$drain_err"
    return 3
  fi

  if ! print_evidence "$evidence"; then
    append_evidence lifecycle 'recovery evidence publication failed; retry catch-up before ordinary work' "$evidence"
    write_gate "$evidence" "$blockers" || { rm -f "$evidence" "$blockers" "$drain_err"; return 1; }
    printf 'fm-afk-return: recovery evidence could not be published; catch-up remains pending\n' >&2
    rm -f "$evidence" "$blockers" "$drain_err"
    return 3
  fi

  if [ -n "$wake_ack_line" ] && ! printf '%s\n' "$wake_ack_line" >&2; then
    append_evidence lifecycle 'durable wake acknowledgement command publication failed; retry catch-up before ordinary work' "$evidence"
    write_gate "$evidence" "$blockers" || { rm -f "$evidence" "$blockers" "$drain_err"; return 1; }
    rm -f "$evidence" "$blockers" "$drain_err"
    return 3
  fi

  rm -f "$GATE"
  clear_delivery_artifacts
  rm -f "$evidence" "$blockers" "$drain_err"
  printf 'fm-afk-return: catch-up clear; ordinary captain work may proceed\n'
  return 0
}

main() {
  local mode=${1:-begin} rc window_epoch contract_epoch
  case "$mode" in
    begin|check) ;;
    guard) return_guard; return ;;
    catchup-summary) catchup_summary; return ;;
    -h|--help|help) usage; return 0 ;;
    *) usage >&2; return 2 ;;
  esac

  # The mutating begin/check paths need locks, the keyed status fold, and the
  # backlog reader. `guard` returned above without sourcing fm-wake-lib.sh,
  # whose initialization creates the state directory, so the advertised
  # read-only guard is literal.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

  mkdir -p "$STATE" || return 1
  fm_lock_acquire_wait "$LOCK"
  trap 'fm_lock_release "$LOCK"' EXIT
  window_epoch=$(window_start_epoch)
  contract_epoch=$(gate_contract_epoch)
  if [ -z "$contract_epoch" ] && fm_afk_contract_present "$STATE"; then
    contract_epoch=$("$CONTRACT" field entered_epoch 2>/dev/null || true)
    case "$contract_epoch" in ''|*[!0-9]*) contract_epoch= ;; esac
  fi
  write_pending_seed "$window_epoch" "$contract_epoch" || { fm_lock_release "$LOCK"; trap - EXIT; return 1; }
  return_reconcile
  rc=$?
  fm_lock_release "$LOCK"
  trap - EXIT
  return "$rc"
}

main "$@"
