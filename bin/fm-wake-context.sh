#!/usr/bin/env bash
# Present or replay one bounded machine-readable wake packet for primary harness adapters.
# The default-off path emits one ordinary-drain instruction without mutating wake state; after presentation, the exact acknowledgement still belongs to that drain.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MAX_WAKES=16
MAX_TASKS=12
MAX_STATUS_LINES=8
MAX_STATUS_CHARS=240
MAX_STATUS_FILES=64
MAX_DECISIONS=24
MAX_PACKET_BYTES=65536
BACKEND_TIMEOUT=${FM_WAKE_CONTEXT_BACKEND_TIMEOUT:-3}
COLLECTION_TIMEOUT=${FM_WAKE_CONTEXT_COLLECTION_TIMEOUT:-10}
COLLECTION_DEADLINE=0
CACHE="$STATE/.wake-context-cache"
CACHE_CURSOR="$CACHE.status-cursor"
FALLBACK_RECEIPT="$STATE/.wake-context-fallback-receipt"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

TMP_DIR=
cleanup() { [ -z "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT INT TERM

usage() {
  echo "usage: fm-wake-context.sh --present" >&2
  exit 2
}

fail_before_presentation() {
  printf 'WAKE_CONTEXT_FALLBACK: wake context unavailable before presentation: %s; run bin/fm-wake-drain.sh once.\n' "$1"
  exit 3
}

wake_context_enabled() {
  [ -f "$CONFIG/wake-context-presentation" ] \
    && [ ! -L "$CONFIG/wake-context-presentation" ]
}

replay_cached() {
  [ -e "$CACHE" ] || return 1
  [ -f "$CACHE" ] && [ ! -L "$CACHE" ] || fail_before_presentation "the replay cache is unsafe"
  printf 'Wake context packet (already presented; do not run the drain again):\n'
  cat "$CACHE"
}

stage_status_cursor() {
  local cursor="$STATE/.status-presentation-cursor" staged="$TMP_DIR/status-cursor.after"
  [ ! -e "$cursor" ] || { [ -f "$cursor" ] && [ ! -L "$cursor" ]; } || return 1
  if [ -e "$staged" ] || [ -L "$staged" ]; then
    [ -f "$staged" ] && [ ! -L "$staged" ] || return 1
    mv -f -- "$staged" "$CACHE_CURSOR"
    return
  fi
  [ -f "$CACHE_CURSOR" ] && [ ! -L "$CACHE_CURSOR" ]
}

publish_cache() { # <packet>
  local tmp="$CACHE.$$.tmp"
  stage_status_cursor || return 1
  (umask 077; printf '%s\n' "$1" > "$tmp") || return 1
  mv -f -- "$tmp" "$CACHE"
}

publish_fallback_receipt() { # <stderr>
  local ack ack_through generation tmp="$FALLBACK_RECEIPT.$$.tmp"
  ack=$(extract_ack "$1"); [ -n "$ack" ] || return 1
  ack_through=$(printf '%s' "$ack" | sed -n 's/.*--ack-through \([0-9][0-9]*\).*/\1/p')
  generation=$(printf '%s' "$ack" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/p')
  [ -n "$ack_through" ] && [ -n "$generation" ] || return 1
  jq -cn --argjson ack "$ack_through" --arg generation "$generation" \
    '{schema:"fm-wake-context-fallback.v1",replay:{ack_through:$ack,recovery_generation:$generation}}' > "$tmp" || return 1
  stage_status_cursor || return 1
  mv -f -- "$tmp" "$FALLBACK_RECEIPT"
}

meta_value() { # <file> <key>
  awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { print value }' "$1" 2>/dev/null
}

validate_queue() { # <queue>
  LC_ALL=C awk -F '\t' 'NF != 5 || $2 !~ /^[0-9]+$/ || (seen && $2 <= prior) { exit 1 } { seen=1; prior=$2 }' "$1"
}

copy_queue() { # <out>
  local queue="$STATE/.wake-queue"
  if [ -e "$queue" ] || [ -L "$queue" ]; then
    [ -f "$queue" ] && [ -r "$queue" ] && [ ! -L "$queue" ] || return 1
    cp "$queue" "$1"
  else
    : > "$1"
  fi
}

task_for_window() { # <window>
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(meta_value "$meta" window)" = "$1" ] || continue
    meta=${meta##*/}; printf '%s\n' "${meta%.meta}"
  done
}

all_task_ids() {
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    meta=${meta##*/}; printf '%s\n' "${meta%.meta}"
  done
}

task_ids_from_queue() { # <queue> <out>
  local _epoch _seq kind key _payload id check
  : > "$2.candidates"
  while IFS=$(printf '\t') read -r _epoch _seq kind key _payload; do
    case "$kind:$key" in
      signal:*.status|signal:*.turn-ended) id=${key%.status}; id=${id%.turn-ended}; printf '%s\n' "$id" ;;
      stale:*) task_for_window "$key" ;;
      heartbeat:*) all_task_ids ;;
      check:*.check.sh)
        check=${key#"$STATE"/}; check=${check%.check.sh}
        printf '%s\n' "$check"
        ;;
    esac
  done < "$1" > "$2.candidates"
  awk '!seen[$0]++ && /^[A-Za-z0-9._-]+$/' "$2.candidates" > "$2"
}

preflight() { # <queue>
  local wakes bytes
  wakes=$(wc -l < "$1" | tr -d ' ')
  bytes=$(wc -c < "$1" | tr -d ' ')
  [ "$wakes" -le "$MAX_WAKES" ] || fail_before_presentation "more than $MAX_WAKES queued notifications"
  [ "$bytes" -le "$MAX_PACKET_BYTES" ] || fail_before_presentation "queued notification bytes exceed the packet bound"
  statuses_within_bound || fail_before_presentation "status bytes exceed the packet bound"
}

statuses_within_bound() {
  local count oversized total
  count=$(find "$STATE" -maxdepth 1 -type f -name '*.status' | wc -l | tr -d ' ')
  oversized=$(find "$STATE" -maxdepth 1 -type f -name '*.status' -size +65536c -print -quit)
  total=$(find "$STATE" -maxdepth 1 -type f -name '*.status' -exec wc -c {} + | awk '$2 != "total" { sum += $1 } END { print sum + 0 }')
  [ "$count" -le "$MAX_STATUS_FILES" ] && [ -z "$oversized" ] && [ "$total" -le "$MAX_PACKET_BYTES" ]
}

write_raw_wakes() { # <queue> <ack> <out>
  awk -F '\t' -v ack="$2" '$2 <= ack' "$1" | while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    jq -cn --arg epoch "$epoch" --argjson sequence "$seq" --arg kind "$kind" \
      --arg key "$key" --arg payload "$payload" \
      '{epoch:$epoch,sequence:$sequence,kind:$kind,key:$key,payload:$payload}'
  done > "$3"
}

status_tail_json() { # <task>
  local file="$STATE/$1.status"
  [ -f "$file" ] && [ ! -L "$file" ] || { printf '[]\n'; return; }
  tail -n "$MAX_STATUS_LINES" "$file" | cut -c "1-$MAX_STATUS_CHARS" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

remaining_collection_timeout() {
  local remaining=$((COLLECTION_DEADLINE - SECONDS))
  [ "$remaining" -gt 0 ] || return 1
  printf '%s\n' "$remaining"
}

endpoint_json() { # <meta>
  local backend target remote live timeout status
  backend=$(meta_value "$1" backend); [ -n "$backend" ] || backend=tmux
  target=$(meta_value "$1" window); remote=$(meta_value "$1" remote_host)
  [ -n "$target" ] || { printf 'null\n'; return; }
  live=unknown
  if [ -z "$remote" ] && fm_backend_is_known "$backend"; then
    timeout=$(remaining_collection_timeout) || return 124
    [ "$timeout" -le "$BACKEND_TIMEOUT" ] || timeout=$BACKEND_TIMEOUT
    live=$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_run_timed "$timeout" fm_backend_agent_state "$backend" "$target" 2>/dev/null); status=$?
    [ "$status" -ne 124 ] || [ "$timeout" -eq "$BACKEND_TIMEOUT" ] || return 124
    [ "$status" -eq 0 ] || live=unknown
  fi
  jq -cn --arg backend "$backend" --arg target "$target" --arg liveness "$live" \
    '{backend:$backend,target:$target,liveness:$liveness}'
}

current_state_json() { # <task> <meta>
  local remote line timeout status
  remote=$(meta_value "$2" remote_host)
  [ -z "$remote" ] || { printf 'null\n'; return; }
  timeout=$(remaining_collection_timeout) || return 124
  line=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
    fm_run_timed "$timeout" "$SCRIPT_DIR/fm-crew-state.sh" "$1" 2>/dev/null); status=$?
  [ "$status" -ne 124 ] || return 124
  [ "$status" -eq 0 ] || line=
  jq -cn --arg line "$line" '{summary:(if $line == "" then null else $line end)}'
}

report_json() { # <task>
  local path="$FM_HOME/data/$1/report.md" bytes=0 present=false
  if [ -f "$path" ] && [ ! -L "$path" ]; then present=true; bytes=$(wc -c < "$path" | tr -d ' '); fi
  jq -cn --arg path "$path" --argjson present "$present" --argjson bytes "$bytes" \
    '{path:$path,present:$present,bytes:$bytes}'
}

write_task() { # <task> <out>
  local task=$1 meta="$STATE/$1.meta" current endpoint status report
  current=$(current_state_json "$task" "$meta") || return
  endpoint=$(endpoint_json "$meta") || return
  remaining_collection_timeout >/dev/null || return 124
  status=$(status_tail_json "$task")
  report=$(report_json "$task")
  jq -cn --arg id "$task" --argjson current "$current" --argjson endpoint "$endpoint" \
    --argjson status "$status" --argjson report "$report" \
    '{id:$id,current_state:$current,endpoint:$endpoint,status_recent:$status,report:$report}' >> "$2"
}

write_tasks() { # <ids> <out>
  local task
  : > "$2"
  while IFS= read -r task; do [ -z "$task" ] || write_task "$task" "$2"; done < "$1"
}

write_decisions() { # <out>
  local file task key verb note count=0
  : > "$1"
  for file in "$STATE"/*.status; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    task=${file##*/}; task=${task%.status}
    while IFS=$(printf '\t') read -r key verb note; do
      [ -n "$key" ] || continue
      count=$((count + 1)); [ "$count" -le "$MAX_DECISIONS" ] || return 1
      jq -cn --arg task "$task" --arg key "$key" --arg verb "$verb" --arg note "${note:0:$MAX_STATUS_CHARS}" \
        '{task:$task,key:$key,verb:$verb,note:$note}' >> "$1"
    done < <(status_open_decisions "$file")
  done
}

monitoring_json() {
  local beat age=null marker
  beat=$(stat -f %m "$STATE/.last-watcher-beat" 2>/dev/null || stat -c %Y "$STATE/.last-watcher-beat" 2>/dev/null || true)
  case "$beat" in ''|*[!0-9]*) ;; *) age=$(( $(date +%s) - beat )) ;; esac
  marker=$(cat "$STATE/.watcher-down" 2>/dev/null || true)
  jq -cn --argjson beacon_age_seconds "$age" --arg recovery "$marker" \
    '{beacon_age_seconds:$beacon_age_seconds,recovery:(if $recovery == "" then null else $recovery end)}'
}

extract_ack() { # <stderr>
  sed -n 's|^WAKE_ACK_REQUIRED: after handling completes run \(bin/fm-wake-drain\.sh --ack-through [0-9][0-9]* --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*\)$|\1|p' "$1" | tail -1
}

bounds_json() {
  jq -cn --argjson wakes "$MAX_WAKES" --argjson tasks "$MAX_TASKS" --argjson lines "$MAX_STATUS_LINES" \
    --argjson chars "$MAX_STATUS_CHARS" --argjson files "$MAX_STATUS_FILES" --argjson bytes "$MAX_PACKET_BYTES" \
    '{max_wakes:$wakes,max_tasks:$tasks,max_status_lines:$lines,max_status_chars:$chars,max_status_files:$files,max_packet_bytes:$bytes}'
}

emit_fallback() { # <stdout> <stderr>
  [ -n "$(extract_ack "$2")" ] || {
    printf 'WAKE_CONTEXT_FALLBACK: wake context unavailable before presentation: wake drain did not complete; run bin/fm-wake-drain.sh once.\n'
    return 1
  }
  publish_fallback_receipt "$2" || {
    printf 'WAKE_CONTEXT_FALLBACK: durable acknowledgement receipt unavailable; acknowledgement withheld.\n'
    return 1
  }
  printf 'WAKE_CONTEXT_PRESENTED: durable presentation complete; do not run bin/fm-wake-drain.sh again.\n'
  printf 'Wake context packet could not be built after the durable presentation.\n'
  printf 'Handle the durable human presentation below and use its exact acknowledgement command.\n\n'
  cat "$1"
  cat "$2" >&2
}

project_presentation() { # <input> <output>
  awk -v keep="$MAX_STATUS_LINES" '
    function flush(    first) {
      if (!unread) return
      first = count - keep + 1
      if (first < 1) first = 1
      if (count > keep) printf "UNREAD STATUS: %d older line(s) omitted from wake packet\n", count - keep
      for (; first <= count; first++) print lines[first]
      delete lines; count = 0; unread = 0
    }
    /^UNREAD STATUS \(/ { flush(); unread = 1; print; next }
    unread && /^(OPEN DECISIONS|RECORD DIVERGENCE)/ { flush() }
    unread { lines[++count] = $0; next }
    { print }
    END { flush() }
  ' "$1" > "$2"
}

compose_packet() { # <ack> <generation> <additional> <drain-out> <drain-err>
  local monitoring bounds
  monitoring=$(monitoring_json); bounds=$(bounds_json)
  jq -cn --slurpfile raw "$TMP_DIR/raw.jsonl" --slurpfile tasks "$TMP_DIR/tasks.jsonl" \
    --slurpfile decisions "$TMP_DIR/decisions.jsonl" --argjson monitoring "$monitoring" --argjson bounds "$bounds" \
    --arg ack "$1" --arg generation "$2" --argjson additional "$3" --rawfile presentation_out "$4" --rawfile presentation_err "$5" \
    '{schema:"fm-wake-context.v1",bounds:$bounds,reason_queue:$raw,presentation:{stdout:$presentation_out,stderr:$presentation_err},tasks:$tasks,open_decisions:$decisions,monitoring:$monitoring,ambiguity:{null_means_unknown:true,status_recent_is_bounded_tail:true},replay:{ack_through:($ack | capture("--ack-through (?<value>[0-9]+)").value | tonumber),recovery_generation:$generation,additional_pending:$additional},ack:{after_handling:$ack}}'
}

build_packet() { # <queue> <tasks> <drain-out> <drain-err>
  local ack_command additional=false packet ack_through generation bytes
  remaining_collection_timeout >/dev/null || return 124
  ack_command=$(extract_ack "$4"); [ -n "$ack_command" ] || return 1
  ack_through=$(printf '%s' "$ack_command" | sed -n 's/.*--ack-through \([0-9][0-9]*\).*/\1/p')
  generation=$(printf '%s' "$ack_command" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/p')
  [ -n "$ack_through" ] && [ -n "$generation" ] || return 1
  statuses_within_bound || return 1
  write_raw_wakes "$1" "$ack_through" "$TMP_DIR/raw.jsonl" || return 1
  write_tasks "$2" "$TMP_DIR/tasks.jsonl" || return 1
  write_decisions "$TMP_DIR/decisions.jsonl" || return 1
  remaining_collection_timeout >/dev/null || return 124
  [ "$(awk -F '\t' -v ack="$ack_through" '$2 > ack { found=1 } END { print found+0 }' "$1")" -eq 0 ] || additional=true
  project_presentation "$3" "$TMP_DIR/drain.projected" || return 1
  packet=$(compose_packet "$ack_command" "$generation" "$additional" "$TMP_DIR/drain.projected" "$4") || return 1
  bytes=$(printf '%s' "$packet" | wc -c | tr -d ' '); [ "$bytes" -le "$MAX_PACKET_BYTES" ] || return 1
  publish_cache "$packet" || return 1
  printf 'Wake context packet (already presented; do not run the drain again):\n%s\n' "$packet"
}

finish_presentation() {
  copy_queue "$TMP_DIR/queue" || { emit_fallback "$TMP_DIR/drain.out" "$TMP_DIR/drain.err"; return 1; }
  validate_queue "$TMP_DIR/queue" || { emit_fallback "$TMP_DIR/drain.out" "$TMP_DIR/drain.err"; return 1; }
  preflight "$TMP_DIR/queue" || { emit_fallback "$TMP_DIR/drain.out" "$TMP_DIR/drain.err"; return 1; }
  task_ids_from_queue "$TMP_DIR/queue" "$TMP_DIR/task-ids"
  [ "$(wc -l < "$TMP_DIR/task-ids" | tr -d ' ')" -le "$MAX_TASKS" ] \
    || { emit_fallback "$TMP_DIR/drain.out" "$TMP_DIR/drain.err"; return 1; }
  build_packet "$TMP_DIR/queue" "$TMP_DIR/task-ids" "$TMP_DIR/drain.out" "$TMP_DIR/drain.err" \
    || { emit_fallback "$TMP_DIR/drain.out" "$TMP_DIR/drain.err"; return 1; }
}

normalize_timeouts() {
  case "$BACKEND_TIMEOUT" in
    ''|*[!0-9]*) BACKEND_TIMEOUT=3 ;;
    *)
      BACKEND_TIMEOUT=$(printf '%s' "$BACKEND_TIMEOUT" | sed 's/^0*//')
      [ -n "$BACKEND_TIMEOUT" ] || BACKEND_TIMEOUT=3
      ;;
  esac
  case "$COLLECTION_TIMEOUT" in
    ''|*[!0-9]*) COLLECTION_TIMEOUT=10 ;;
    *)
      COLLECTION_TIMEOUT=$(printf '%s' "$COLLECTION_TIMEOUT" | sed 's/^0*//')
      [ -n "$COLLECTION_TIMEOUT" ] || COLLECTION_TIMEOUT=10
      ;;
  esac
}

prepare_presentation() {
  if ! fm_session_lock_owned_by_self "$STATE"; then
    printf 'WAKE_CONTEXT_READ_ONLY: this session does not own the fleet lock; wake state must remain read-only.\n'
    exit 3
  fi
  replay_cached && exit 0
  wake_context_enabled \
    || fail_before_presentation "automatic wake context is disabled until config/wake-context-presentation exists"
  [ -e "$FALLBACK_RECEIPT" ] || [ ! -e "$CACHE_CURSOR" ] \
    || rm -f -- "$CACHE_CURSOR" || fail_before_presentation "an orphaned cursor stage could not be retired"
}

preflight_presentation() {
  copy_queue "$TMP_DIR/queue" || fail_before_presentation "the wake queue could not be read safely"
  validate_queue "$TMP_DIR/queue" || fail_before_presentation "the queue is malformed"
  preflight "$TMP_DIR/queue"
}

drain_presentation() {
  if ! FM_WAKE_CONTEXT_NONMUTATING=1 FM_WAKE_CONTEXT_STATUS_CURSOR_STAGE="$TMP_DIR/status-cursor.after" \
    "$SCRIPT_DIR/fm-wake-drain.sh" > "$TMP_DIR/drain.out" 2> "$TMP_DIR/drain.err"; then
    emit_fallback "$TMP_DIR/drain.out" "$TMP_DIR/drain.err"; exit 1
  fi
}

collect_presentation() {
  preflight_presentation
  drain_presentation
  finish_presentation
}

run_collection() {
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-wake-context.XXXXXX") || exit 1
  COLLECTION_DEADLINE=$((SECONDS + COLLECTION_TIMEOUT))
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
    fm_run_timed "$COLLECTION_TIMEOUT" collect_presentation
}

finish_collection() {
  local status
  run_collection; status=$?
  if [ "$status" -eq 124 ]; then
    if [ -f "$TMP_DIR/drain.err" ] && [ -n "$(extract_ack "$TMP_DIR/drain.err")" ]; then
      emit_fallback "$TMP_DIR/drain.out" "$TMP_DIR/drain.err"
    else
      fail_before_presentation "wake context collection timed out"
    fi
  fi
  return "$status"
}

main() {
  [ "${1:-}" = --present ] && [ "$#" -eq 1 ] || usage
  normalize_timeouts
  prepare_presentation
  finish_collection
}

main "$@"
