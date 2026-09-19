#!/usr/bin/env bash
# fm-jev-queue-triage.sh - advisory next-work signal for the ready backlog.
#
# Usage:
#   fm-jev-queue-triage.sh [--heartbeat]
#
# The watcher is the production caller: it invokes this helper at most once
# per heartbeat. The result is advisory only. This script never dispatches a
# task, never clears a hold, never auto-transitions backlog state, and never
# overrides a dependency or a time gate. A captain-held item is never placed
# in Jev state.
#
# What Jev sees (one HTTP call, via bin/fm-jev-lib.sh):
#   next  Choice {dispatch_next, blocked, needs_captain, nothing_ready}
#   task  Choice over ready task ids plus none
# State is this home's ready set only: id, title, kind, repo, blockers, and
# hold kind. Never a captain-held item, never hold_reason, never a private
# report body, and never another home's queue. Metadata is sanitized before
# building both state and Choice criteria; ids changed by sanitization are
# excluded. At most 24 items are considered, with titles capped at 80
# characters. Items are removed from the end until the state fits
# fm_jev_compact_state's cap (default 8192 bytes); this cap is on state,
# not the complete request including questions.
#
# Gate: skipped entirely (no model call, no JSONL) when the ready set is
# empty after captain-held ids are dropped. Off with no key: stderr line,
# exit 0, no JSONL. A low-confidence or failed answer still writes JSONL
# and does not recommend.
# A recommendation requires next=dispatch_next and a task from the offered
# ready ids. Both confidences must be numbers in 0..1 at or above the shared
# library floor. Recorded confidence is their minimum, or null if invalid.
#
# Records:
#   $FM_HOME/state/jev-queue-triage.jsonl   one object per attempted Jev call
#   $FM_HOME/state/jev-queue-triage.json    latest snapshot, including skips
#   $FM_HOME/state/jev-queue-triage.line    one surface line, only when a
#                                           recommendation exists; removed
#                                           otherwise
#
# JSONL fields: purpose=queue-triage, advisory=true, dispatch=false,
# status, next, task, confidence, recommendation, ready_ids, line, route,
# http, latency_ms, decide_code, ts. Secrets follow fm_jev_log_call redaction.
#
# Output: one stdout line. Exit 0 except usage (exit 2). Evaluation
# failures stay 0 so a heartbeat is never blocked.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE (replaces the state directory),
# plus the Jev library keys and JEV_* settings
# documented in bin/fm-jev-lib.sh. --heartbeat is accepted and ignored
# beyond documenting the watcher as caller. This script does not roll its
# own HTTP.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'jev-queue-triage: %s\n' "$1" >&2
  exit 2
}

STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG_PATH="$STATE_DIR/jev-queue-triage.jsonl"
SNAP_PATH="$STATE_DIR/jev-queue-triage.json"
LINE_PATH="$STATE_DIR/jev-queue-triage.line"
READY_MAX=24
TITLE_MAX=80
LIST_TIMEOUT=5

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --heartbeat)
      shift
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

unquote() {
  local s=$1
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  printf '%s' "$s"
}

truncate_title() {
  local title=$1
  if [ "${#title}" -gt "$TITLE_MAX" ]; then
    printf '%s' "${title:0:$TITLE_MAX}"
  else
    printf '%s' "$title"
  fi
}

clear_line_file() {
  rm -f "$LINE_PATH"
}

write_snapshot() {
  local json=$1 tmp
  mkdir -p "$STATE_DIR" || return 1
  tmp=$(mktemp "$STATE_DIR/jev-queue-triage.json.XXXXXX") || return 1
  if ! printf '%s\n' "$json" > "$tmp" || ! mv -f "$tmp" "$SNAP_PATH"; then
    rm -f "$tmp"
    return 1
  fi
}

write_line_file() {
  local line=$1 tmp
  mkdir -p "$STATE_DIR" || return 1
  tmp=$(mktemp "$STATE_DIR/jev-queue-triage.line.XXXXXX") || return 1
  if ! printf '%s\n' "$line" > "$tmp" || ! mv -f "$tmp" "$LINE_PATH"; then
    rm -f "$tmp"
    return 1
  fi
}

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown'
}

# Parse a tasks-axi identity table whose header names the columns in braces.
# Emits TSV: id<TAB>kind<TAB>repo<TAB>title. Title is the remainder after the
# first four comma-separated identity fields.
parse_identity_rows() {
  local prefix=$1
  awk -v prefix="$prefix" '
    $0 ~ "^" prefix "\\[" { p=1; next }
    p && $0 ~ /^[[:space:]]/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      if (line == "") next
      n = split(line, parts, ",")
      if (n < 5) next
      id = parts[1]
      kind = parts[3]
      repo = parts[4]
      title = parts[5]
      for (i = 6; i <= n; i++) title = title "," parts[i]
      gsub(/^"/, "", title)
      gsub(/"$/, "", title)
      printf "%s\t%s\t%s\t%s\n", id, kind, repo, title
      next
    }
    p { p=0 }
  '
}

# Held listing with --fields hold_kind. Last comma field is hold_kind; first
# is id. Emits ids whose hold_kind is captain.
parse_captain_held_ids() {
  awk '
    /^tasks\[/ { p=1; next }
    p && $0 ~ /^[[:space:]]/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      if (line == "") next
      n = split(line, parts, ",")
      if (n < 1) next
      id = parts[1]
      kind = parts[n]
      gsub(/^"/, "", kind)
      gsub(/"$/, "", kind)
      if (kind == "captain") print id
      next
    }
    p { p=0 }
  '
}

has_key() {
  local typesafe_key openrouter_key
  typesafe_key=${TYPESAFE_API_KEY:-}
  openrouter_key=${OPENROUTER_API_KEY:-}
  if [ -z "$typesafe_key" ]; then
    typesafe_key=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
  fi
  if [ -z "$openrouter_key" ]; then
    openrouter_key=$(fmx_env_get OPENROUTER_API_KEY "$FM_HOME/.env")
  fi
  [ -n "$typesafe_key" ] || [ -n "$openrouter_key" ]
}

skip_empty() {
  local snap
  snap=$(jq -nc --arg ts "$(iso_now)" '{
    purpose: "queue-triage",
    advisory: true,
    dispatch: false,
    status: "skipped",
    next: null,
    task: null,
    confidence: null,
    recommendation: null,
    ready_ids: [],
    line: null,
    ts: $ts
  }') || snap='{"purpose":"queue-triage","advisory":true,"dispatch":false,"status":"skipped"}'
  write_snapshot "$snap" || true
  clear_line_file
  printf 'jev-queue-triage: skipped\n'
  exit 0
}

collect_ready_json() {
  local ready_out held_out ready_rc held_rc rows captain_ids id kind repo title
  local json='[]' count=0 skip_id updated clean_id
  ready_rc=0
  ready_out=$(fm_run_timed "$LIST_TIMEOUT" "$SCRIPT_DIR/fm-tasks-axi.sh" ready 2>/dev/null) || ready_rc=$?
  if [ "$ready_rc" -eq 124 ]; then
    printf '[]'
    return 0
  fi
  held_rc=0
  held_out=$(fm_run_timed "$LIST_TIMEOUT" "$SCRIPT_DIR/fm-tasks-axi.sh" list --state held --fields hold_kind 2>/dev/null) || held_rc=$?
  captain_ids=''
  if [ "$held_rc" -ne 124 ]; then
    captain_ids=$(printf '%s\n' "$held_out" | parse_captain_held_ids)
  fi
  rows=$(printf '%s\n' "$ready_out" | parse_identity_rows ready)
  while IFS=$(printf '\t') read -r id kind repo title; do
    [ -n "$id" ] || continue
    skip_id=0
    if [ -n "$captain_ids" ]; then
      case $'\n'"$captain_ids"$'\n' in
        *$'\n'"$id"$'\n'*) skip_id=1 ;;
      esac
    fi
    [ "$skip_id" -eq 0 ] || continue
    title=$(unquote "$title")
    title=$(fm_jev_compact_state "$title") || continue
    title=$(truncate_title "$title")
    kind=$(unquote "$kind")
    kind=$(fm_jev_compact_state "$kind") || continue
    repo=$(unquote "$repo")
    repo=$(fm_jev_compact_state "$repo") || continue
    clean_id=$(fm_jev_compact_state "$id") || continue
    [ "$clean_id" = "$id" ] || continue
    updated=$(jq -c --arg id "$id" --arg kind "$kind" --arg repo "$repo" --arg title "$title" \
      '. + [{id: $id, kind: $kind, repo: $repo, title: $title, blocked_by: "none", hold_kind: "none"}]' \
      <<<"$json") || continue
    json=$updated
    count=$((count + 1))
    [ "$count" -lt "$READY_MAX" ] || break
  done <<EOF
$rows
EOF
  printf '%s' "$json"
}

build_state() {
  local items=$1
  printf '%s\n' \
    'Ready set for this home only.' \
    'Advisory next-work signal.' \
    'Never dispatch.' \
    'Never clear a hold.' \
    'Never touch a captain-held item.'
  printf '%s' "$items" | jq -r '.[] | "id=\(.id) kind=\(.kind) repo=\(.repo) blockers=\(.blocked_by) hold_kind=\(.hold_kind) title=\(.title)"'
}

shrink_items() {
  local items=$1
  printf '%s' "$items" | jq -c 'if length > 0 then .[:-1] else . end'
}

if ! command -v jq >/dev/null 2>&1; then
  printf 'jev-queue-triage: jq required\n' >&2
  skip_empty
fi

mkdir -p "$STATE_DIR" || die "could not create $STATE_DIR"

items=$(collect_ready_json)
ready_n=$(printf '%s' "$items" | jq 'length')
case "$ready_n" in
  ''|0) skip_empty ;;
esac

if ! has_key; then
  snap=$(jq -nc --arg ts "$(iso_now)" --argjson ids "$(printf '%s' "$items" | jq -c '[.[].id]')" '{
    purpose: "queue-triage",
    advisory: true,
    dispatch: false,
    status: "off",
    next: null,
    task: null,
    confidence: null,
    recommendation: null,
    ready_ids: $ids,
    line: null,
    ts: $ts
  }') || snap='{"purpose":"queue-triage","status":"off","advisory":true,"dispatch":false}'
  write_snapshot "$snap" || true
  clear_line_file
  printf 'jev-queue-triage: off\n' >&2
  exit 0
fi

compacted=
state=
while :; do
  state=$(build_state "$items")
  if compacted=$(fm_jev_compact_state "$state"); then
    break
  fi
  next=$(shrink_items "$items")
  if [ "$next" = "$items" ] || [ "$(printf '%s' "$next" | jq 'length')" -eq 0 ]; then
    skip_empty
  fi
  items=$next
done

criteria_next='{"dispatch_next":"A ready item should be dispatched next. Name it in the task question.","blocked":"Ready items exist but something outside this set blocks dispatch.","needs_captain":"A captain decision is required before dispatching from this set.","nothing_ready":"Nothing in this set should start now."}'
criteria_task=$(printf '%s' "$items" | jq -c '
  (map({key: .id, value: (.title + " (" + .kind + ", " + .repo + ")")}) | from_entries)
  + {none: "No task. Use when next is not dispatch_next."}
') || die "failed to build task criteria"

questions=$(jq -nc --argjson next_c "$criteria_next" --argjson task_c "$criteria_task" '{
  next: {
    type: "choice",
    instructions: "Pick the next-work signal for this ready set. Advisory only. Never dispatch, never clear a hold, never touch a captain-held item.",
    criteria: $next_c
  },
  task: {
    type: "choice",
    instructions: "If next is dispatch_next, pick that task id. Otherwise pick none.",
    criteria: $task_c
  }
}') || die "jq is required"

decide_code=0
response=
if response_file=$(mktemp "$STATE_DIR/jev-queue-triage.response.XXXXXX"); then
  trap 'rm -f "$response_file"' EXIT
  fm_jev_decide "$compacted" "$questions" > "$response_file" || decide_code=$?
  response=$(cat "$response_file")
  rm -f "$response_file"
  trap - EXIT
else
  decide_code=2
fi

status=error
next_choice=
task_choice=
confidence=
recommendation=
line=
ready_ids_json=$(printf '%s' "$items" | jq -c '[.[].id]')

if [ "$decide_code" -eq 0 ] && [ -n "$response" ]; then
  next_choice=$(printf '%s' "$response" | jq -r '.answers.next.choice // empty')
  task_choice=$(printf '%s' "$response" | jq -r '.answers.task.choice // empty')
  confidence=$(printf '%s' "$response" | jq -r '
    [.answers.next.confidence, .answers.task.confidence]
    | if all(.[]; type == "number" and . >= 0 and . <= 1) then min else empty end
  ')
  case "$next_choice" in
    dispatch_next|blocked|needs_captain|nothing_ready) ;;
    *) next_choice= ;;
  esac
  if [ "$next_choice" = dispatch_next ] \
    && [ -n "$task_choice" ] && [ "$task_choice" != none ] \
    && printf '%s' "$ready_ids_json" | jq -e --arg id "$task_choice" 'index($id) != null' >/dev/null \
    && [ -n "$confidence" ] \
    && fm_jev_choice_confidence_ok "$confidence"; then
    recommendation=$task_choice
    status=clear
    line=$(printf 'JEV QUEUE TRIAGE (advisory, never dispatch): dispatch_next task=%s confidence=%s' \
      "$recommendation" "$confidence")
  else
    status=no-recommendation
  fi
else
  status=error
fi

payload=$(jq -nc \
  --arg ts "$(iso_now)" \
  --arg status "$status" \
  --arg next "${next_choice:-}" \
  --arg task "${task_choice:-}" \
  --arg confidence "$confidence" \
  --arg recommendation "$recommendation" \
  --arg line "$line" \
  --arg route "${FM_JEV_LAST_ROUTE:-}" \
  --arg http "${FM_JEV_LAST_HTTP:-}" \
  --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
  --argjson ready_ids "$ready_ids_json" \
  --argjson decide_code "$decide_code" \
  '{
    purpose: "queue-triage",
    advisory: true,
    dispatch: false,
    status: $status,
    next: (if $next == "" then null else $next end),
    task: (if $task == "" then null else $task end),
    confidence: (try ($confidence | tonumber) catch null),
    recommendation: (if $recommendation == "" then null else $recommendation end),
    ready_ids: $ready_ids,
    line: (if $line == "" then null else $line end),
    route: $route,
    http: $http,
    latency_ms: (try ($latency | tonumber) catch null),
    decide_code: $decide_code,
    ts: $ts
  }') || die "failed to render log payload"

fm_jev_log_call "$payload" "$LOG_PATH" || true
write_snapshot "$payload" || true
if [ -n "$line" ]; then
  write_line_file "$line" || true
  printf '%s\n' "$line"
else
  clear_line_file
  printf 'jev-queue-triage: no-recommendation\n'
fi
exit 0
