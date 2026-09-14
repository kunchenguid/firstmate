#!/usr/bin/env bash
# fm-progress-report.sh - render the hourly Firstmate progress report from raw records.
#
# Usage: fm-progress-report.sh
#        fm-progress-report.sh -h
#
# Allowed sources only:
#   data/quarantine.md
#   tasks-axi backlog (data/backlog.md)
#   data/telemetry/lifecycle.jsonl (plus rotated .N siblings)
#   quota-axi
#   merged pull requests for pedromuller-del/firstmate (gh-axi api, TOON envelope)
#
# Prints the rendered report only when content changed since the last post; otherwise
# exits silently. A changed render commits state/progress-report.last atomically and
# only then releases the staged report to stdout, so a retry never duplicates a post
# and a deadline never leaks output without committed state. Any malformed,
# truncated, or unavailable required source fails before state is replaced. One
# shared end-to-end deadline (FM_PROGRESS_TIMEOUT seconds) bounds every
# compatibility probe and source call.
#
# Test seams:
#   FM_PROGRESS_QUARANTINE, FM_PROGRESS_BACKLOG, FM_PROGRESS_LIFECYCLE,
#   FM_PROGRESS_LAST, FM_PROGRESS_PROGRAM, FM_PROGRESS_SLACK_MENTION,
#   FM_PROGRESS_NOW_MS, FM_PROGRESS_TASKS_AXI, FM_PROGRESS_QUOTA_FILE,
#   FM_PROGRESS_QUOTA_CMD, FM_PROGRESS_MERGED_PRS_FILE, FM_PROGRESS_GH_CMD,
#   FM_PROGRESS_REPO, FM_PROGRESS_TIMEOUT, FM_PROGRESS_TOON_CODEC_TOOL,
#   FM_PROGRESS_TEST_SEAM, FM_PROGRESS_TEST_SWAP_HOOK
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-progress-report-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-progress-report-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

QUARANTINE=${FM_PROGRESS_QUARANTINE:-$DATA/quarantine.md}
BACKLOG=${FM_PROGRESS_BACKLOG:-$DATA/backlog.md}
LIFECYCLE=${FM_PROGRESS_LIFECYCLE:-$DATA/telemetry/lifecycle.jsonl}
LAST_FILE=${FM_PROGRESS_LAST:-$STATE/progress-report.last}
PROGRAM=${FM_PROGRESS_PROGRAM:-Firstmate fork stabilization}
MENTION=${FM_PROGRESS_SLACK_MENTION:-'<@U0A7XV408AD>'}
REPO=${FM_PROGRESS_REPO:-pedromuller-del/firstmate}
TASKS_AXI=${FM_PROGRESS_TASKS_AXI:-tasks-axi}
QUOTA_CMD=${FM_PROGRESS_QUOTA_CMD:-quota-axi --json}
GH_CMD=${FM_PROGRESS_GH_CMD:-gh-axi}
COLLECT_TIMEOUT=${FM_PROGRESS_TIMEOUT:-60}
MERGED_PAGE_CAP=100
REPORT_LOCK="$STATE/.progress-report.lock"
REPORT_LOCK_HELD=0

usage() {
  cat <<'EOF'
Render the hourly Firstmate progress report from five allowed sources only:
  data/quarantine.md, tasks-axi backlog, data/telemetry/lifecycle.jsonl,
  quota-axi, and merged pull requests for pedromuller-del/firstmate.

Unsupported or unprovable metrics render as unknown. Malformed, truncated, or
unavailable required sources fail before state/progress-report.last is
replaced. Unchanged reports print nothing and leave prior state intact. Quota
percentages require the provider's aggregate all_models scope with a known
numeric observation no older than one report interval (3600 s); otherwise the
provider renders as unknown.
EOF
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  '') ;;
  *) fm_progress_die "unknown argument: $1" 2 ;;
esac

command -v jq >/dev/null 2>&1 || fm_progress_die 'jq is required' 1
command -v node >/dev/null 2>&1 || fm_progress_die 'node is required (TOON codec host)' 1
command -v perl >/dev/null 2>&1 || fm_progress_die 'perl is required (no-follow state commit)' 1

# shellcheck disable=SC2329 # invoked from the worker subshell's EXIT trap
release_report_lock() {
  if [ "$REPORT_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$REPORT_LOCK" || true
    REPORT_LOCK_HELD=0
  fi
}

fm_progress_run_timed() {
  fm_run_timed "$COLLECT_TIMEOUT" "$@" || {
    local rc=$?
    if [ "$rc" -eq 124 ]; then
      fm_progress_die "collection timed out after ${COLLECT_TIMEOUT}s" 1
    fi
    return "$rc"
  }
}

# Decode one axi TOON document with the official codec bundled beside any
# installed axi tool. The codec host is a real axi install, never the
# (possibly overridden) collection command.
fm_progress_toon_codec_host() {
  local host
  if [ -n "${FM_PROGRESS_TOON_CODEC_TOOL:-}" ]; then
    host=$(command -v "$FM_PROGRESS_TOON_CODEC_TOOL") \
      || fm_progress_die "TOON codec host not found: $FM_PROGRESS_TOON_CODEC_TOOL" 1
  else
    host=$(command -v gh-axi || command -v tasks-axi || command -v quota-axi) \
      || fm_progress_die 'no axi tool on PATH to host the TOON codec' 1
  fi
  printf '%s\n' "$host"
}

fm_progress_toon_decode() { # TOON on stdin, JSON on stdout
  node "$SCRIPT_DIR/fm-toon-decode.mjs" "$(fm_progress_toon_codec_host)" \
    || fm_progress_die 'TOON decode failed' 1
}

# Extract exactly one table (header plus its indented rows) from axi tool
# output; anything else, including count and help lines, is envelope framing.
fm_progress_axi_table() { # <table-name>
  awk -v h="$1" '
    $0 ~ "^" h "\\[[0-9]+\\][{]" { if (t) exit 1; t = 1; print; next }
    t && /^[[:space:]]/ { print; next }
    t { exit }
    END { if (!t) exit 1 }
  '
}

# A zero-row listing is exactly `count: 0`, the one exact supported summary
# line for the requested collection, whitelisted scalar lines, and an optional
# help block; anything else, including a truncation marker in any form, is a
# malformed envelope.
fm_progress_axi_zero_listing() { # <table-name> <exact-summary> <raw-file>
  awk -v summary="$2" '
    NR == 1 { if ($0 != "count: 0") exit 1; next }
    NR == 2 { if ($0 != summary) exit 1; next }
    /^help\[/ { help = 1; next }
    help && /^[[:space:]]/ { next }
    /^ready_public_followups: [0-9]+ / { next }
    { exit 1 }
    END { if (NR < 2) exit 1 }
  ' "$3"
}

fm_progress_load_quarantine() {
  fm_progress_read_file "$QUARANTINE" 'quarantine' > "$INPUT_DIR/quarantine.md"
}

fm_progress_tasks_decode() { # <table-name> <exact-zero-summary> <out-file> <tasks-axi args...>
  local table=$1 zero_summary=$2 out=$3
  shift 3
  if ! fm_progress_run_timed "$TASKS_AXI" "$@" > "$INPUT_DIR/$table.raw" 2>"$INPUT_DIR/$table.err"; then
    fm_progress_die "backlog $table listing failed (tasks-axi exited nonzero)" 1
  fi
  if ! fm_progress_axi_table "$table" < "$INPUT_DIR/$table.raw" > "$INPUT_DIR/$table.toon"; then
    if fm_progress_axi_zero_listing "$table" "$zero_summary" "$INPUT_DIR/$table.raw"; then
      jq -n --arg t "$table" '{($t): []}' > "$out"
      return 0
    fi
    fm_progress_die "backlog $table listing has no $table table" 1
  fi
  fm_progress_toon_decode < "$INPUT_DIR/$table.toon" > "$out"
  jq -e --arg t "$table" 'has($t) and (.[$t] | type) == "array"' "$out" >/dev/null \
    || fm_progress_die "backlog $table listing decoded to a non-array" 1
}

fm_progress_load_backlog() {
  fm_progress_read_file "$BACKLOG" 'backlog' > "$INPUT_DIR/backlog.md"
  if ! fm_tasks_axi_backend_available "$CONFIG"; then
    fm_progress_die 'tasks-axi backend is unavailable or incompatible' 1
  fi
  fm_progress_tasks_decode tasks 'tasks: 0 in_flight tasks in this backlog' "$INPUT_DIR/in-flight.json" \
    list --file "$INPUT_DIR/backlog.md" --state in_flight \
    --fields blocked_by,hold_kind,hold_reason,hold_until
  fm_progress_tasks_decode ready 'ready: 0 unblocked queued tasks' "$INPUT_DIR/ready.json" \
    ready --file "$INPUT_DIR/backlog.md"
  fm_progress_tasks_decode tasks 'tasks: 0 queued tasks in this backlog' "$INPUT_DIR/queued.json" \
    list --file "$INPUT_DIR/backlog.md" --state queued \
    --fields blocked_by,hold_kind,hold_reason,hold_until
}

# Append every complete line beyond the consumed byte offset of one lifecycle
# stream to the delta file and print the new consumed offset. A trailing
# partial line is left unconsumed for the next run.
fm_progress_lifecycle_delta() { # <path> <offset> <delta-out>
  local path=$1 offset=$2 delta=$3 size last_partial
  size=$(wc -c < "$path" | tr -d ' ')
  case "$size" in ''|*[!0-9]*) fm_progress_die "lifecycle size is unreadable: $path" 1 ;; esac
  if [ "$offset" -gt "$size" ]; then
    fm_progress_die "lifecycle stream shrank beneath the consumed cursor: $path" 1
  fi
  if [ "$offset" -eq "$size" ]; then
    printf '%s\n' "$size"
    return 0
  fi
  tail -c +"$((offset + 1))" -- "$path" > "$INPUT_DIR/delta.raw" \
    || fm_progress_die "lifecycle delta read failed: $path" 1
  if [ "$(tail -c 1 -- "$path" | od -An -tx1 | tr -d ' ')" = "0a" ]; then
    # File ends with a newline: every delta line is complete.
    cat "$INPUT_DIR/delta.raw" >> "$delta"
    printf '%s\n' "$size"
  else
    # Hold the trailing partial line for the next run.
    awk 'NR > 1 { print prev } { prev = $0 }' "$INPUT_DIR/delta.raw" >> "$delta"
    last_partial=$(tail -n 1 "$INPUT_DIR/delta.raw" | wc -c | tr -d ' ')
    printf '%s\n' $((size - last_partial))
  fi
}

fm_progress_load_lifecycle() {
  local cursor_json entry_offset devino size f
  : > "$INPUT_DIR/lifecycle.delta"
  : > "$INPUT_DIR/lifecycle.cursor.json"
  cursor_json=$(fm_progress_read_state lifecycle_cursor '')
  if [ -z "$cursor_json" ]; then
    cursor_json='{"v":1,"files":{},"seen":[]}'
  fi
  jq -e '.v == 1 and (.files | type) == "object" and (.seen | type) == "array"' <<< "$cursor_json" >/dev/null \
    || fm_progress_die 'stored lifecycle cursor is malformed' 1

  local seeded=true
  if [ "$(jq '.files | length' <<< "$cursor_json")" = 0 ] && [ -z "$(fm_progress_read_state lifecycle_seeded '')" ]; then
    seeded=false
  fi

  for f in "$LIFECYCLE" "$LIFECYCLE".[0-9]*; do
    [ -e "$f" ] || continue
    fm_progress_read_file "$f" 'lifecycle telemetry' > /dev/null
    devino=$(fm_progress_dir_token "$f")
    size=$(wc -c < "$f" | tr -d ' ')
    if [ "$seeded" = false ]; then
      entry_offset=$size
    else
      # Offsets follow the stable file identity (device:inode), so a rotation
      # rename keeps the consumed position attached to the same stream.
      entry_offset=$(jq -r --arg k "$devino" '.files[$k].o // empty' <<< "$cursor_json")
      entry_offset=${entry_offset:-0}
    fi
    fm_progress_lifecycle_delta "$f" "${entry_offset:-0}" "$INPUT_DIR/lifecycle.delta" > "$INPUT_DIR/delta.offset"
    jq -n --arg k "$devino" \
      --argjson o "$(cat "$INPUT_DIR/delta.offset")" --argjson s "$size" \
      '{($k): {o: $o, s: $s}}' >> "$INPUT_DIR/lifecycle.cursor.json"
  done
  printf '%s\n' "$seeded" > "$INPUT_DIR/lifecycle.seeded"
  printf '%s\n' "$cursor_json" > "$INPUT_DIR/lifecycle.cursor.prior.json"
}

fm_progress_load_quota() {
  if [ -n "${FM_PROGRESS_QUOTA_FILE:-}" ]; then
    fm_progress_read_file "$FM_PROGRESS_QUOTA_FILE" 'quota snapshot' > "$INPUT_DIR/quota.json"
    fm_quota_json_valid < "$INPUT_DIR/quota.json" || fm_progress_die 'quota snapshot is malformed' 1
    return 0
  fi
  if ! fm_progress_run_timed sh -c "$QUOTA_CMD" > "$INPUT_DIR/quota.json" 2>"$INPUT_DIR/quota.err"; then
    fm_progress_die 'quota snapshot is unavailable (quota command exited nonzero)' 1
  fi
  fm_quota_json_valid < "$INPUT_DIR/quota.json" || fm_progress_die 'quota snapshot is malformed' 1
}

fm_progress_merged_decode() { # reads TOON on stdin, validates a bare array
  fm_progress_toon_decode | jq -e 'if type == "array" then . else error("merged pull request coverage is not an array") end' \
    || fm_progress_die 'merged pull request coverage is truncated or malformed' 1
}

fm_progress_load_merged_prs() {
  local page rows count
  if [ -n "${FM_PROGRESS_MERGED_PRS_FILE:-}" ]; then
    fm_progress_read_file "$FM_PROGRESS_MERGED_PRS_FILE" 'merged pull requests' > "$INPUT_DIR/merged-prs.toon"
    fm_progress_merged_decode < "$INPUT_DIR/merged-prs.toon" > "$INPUT_DIR/merged-prs.json"
    return 0
  fi
  : > "$INPUT_DIR/merged-pages.jsonl"
  page=1
  while [ "$page" -le "$MERGED_PAGE_CAP" ]; do
    if ! fm_progress_run_timed "$GH_CMD" api \
      "repos/$REPO/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$page" \
      --jq '[.[] | {number, url: .html_url, mergedAt: .merged_at, title}]' \
      > "$INPUT_DIR/merged-page.toon" 2>"$INPUT_DIR/merged-page.err"; then
      fm_progress_die 'merged pull request listing failed (gh-axi exited nonzero)' 1
    fi
    rows=$(fm_progress_merged_decode < "$INPUT_DIR/merged-page.toon")
    count=$(jq 'length' <<< "$rows") || fm_progress_die 'merged pull request page is malformed' 1
    jq -c '.[]' <<< "$rows" >> "$INPUT_DIR/merged-pages.jsonl" \
      || fm_progress_die 'merged pull request page is malformed' 1
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
  [ "$page" -le "$MERGED_PAGE_CAP" ] \
    || fm_progress_die "merged pull request pagination exceeded the $MERGED_PAGE_CAP page bound" 1
  jq -s '.' "$INPUT_DIR/merged-pages.jsonl" > "$INPUT_DIR/merged-prs.json" \
    || fm_progress_die 'merged pull request coverage is malformed' 1
}

fm_progress_read_state() {
  local key=$1 default=$2
  if [ -f "$LAST_FILE" ] && [ ! -L "$LAST_FILE" ]; then
    awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$LAST_FILE" 2>/dev/null \
      || printf '%s\n' "$default"
  else
    printf '%s\n' "$default"
  fi
}

fm_progress_build_json() {
  local now_ms now_epoch last_epoch seen_ids_json merged_reported_json cursor_json
  now_ms=$(fm_progress_now_ms)
  now_epoch=$(fm_progress_now_epoch)
  last_epoch=$(fm_progress_read_state post_epoch 0)
  cursor_json=$(cat "$INPUT_DIR/lifecycle.cursor.prior.json")
  seen_ids_json=$(jq -c '.seen' <<< "$cursor_json")
  merged_reported_json=$(fm_progress_read_state merged_reported '' | jq -R 'split(",") | map(select(length > 0) | tonumber)')
  case "$last_epoch" in ''|*[!0-9]*) fm_progress_die 'stored last-post timestamp is malformed' 1 ;; esac
  if [ "$now_epoch" -lt "$last_epoch" ]; then
    fm_progress_die "clock rollback: now ${now_epoch} is before the last post ${last_epoch}" 1
  fi

  jq -n \
    --arg program "$PROGRAM" \
    --arg mention "$MENTION" \
    --arg repo "$REPO" \
    --argjson now_ms "$now_ms" \
    --argjson now_epoch "$now_epoch" \
    --argjson last_epoch "$last_epoch" \
    --argjson seen_ids "$seen_ids_json" \
    --argjson merged_reported "$merged_reported_json" \
    --rawfile quarantine "$INPUT_DIR/quarantine.md" \
    --slurpfile in_flight "$INPUT_DIR/in-flight.json" \
    --slurpfile ready "$INPUT_DIR/ready.json" \
    --slurpfile queued "$INPUT_DIR/queued.json" \
    --rawfile lifecycle_delta "$INPUT_DIR/lifecycle.delta" \
    --slurpfile quota "$INPUT_DIR/quota.json" \
    --slurpfile merged_prs "$INPUT_DIR/merged-prs.json" \
    -f "$SCRIPT_DIR/fm-progress-report.jq" > "$INPUT_DIR/report.json" \
    || fm_progress_die 'report model build failed' 1
  jq -e 'type == "object"' "$INPUT_DIR/report.json" >/dev/null \
    || fm_progress_die 'report model build produced no object' 1
}

fm_progress_render() {
  jq -r -f "$SCRIPT_DIR/fm-progress-report-render.jq" "$INPUT_DIR/report.json" \
    || fm_progress_die 'report render failed' 1
}

# Fingerprint the rendered body with the deliberate display clock masked and
# the per-interval delta VALUES replaced by their coverage state, so a
# recovery between unknown and valid coverage always re-posts while routine
# delta drain stays suppressed. Every other rendered field participates.
fm_progress_material_fingerprint() { # <body> <header_time> <coverage-marker>
  local body=$1 header_time=$2 marker=$3
  [ -n "$body" ] || fm_progress_die 'cannot fingerprint an empty report' 1
  printf '%s\n' "$body" | awk -v t="$header_time" -v m="$marker" \
    'NR == 1 { gsub(t, "<display-clock>") } /^\*Since last report:\*/ { print m; next } { print }' \
    | fm_progress_sha256
}

fm_progress_new_cursor_json() {
  local prior=$1 poisoned=$2 seen_json=$3
  if [ "$poisoned" = true ]; then
    printf '%s\n' "$prior"
    return 0
  fi
  jq -cn --slurpfile parts "$INPUT_DIR/lifecycle.cursor.json" --argjson seen "$seen_json" \
    '{v: 1, files: ($parts | add // {}), seen: $seen}'
}

main() {
  local last_dir
  STATE=$(fm_progress_safe_dir "$STATE" 'state directory')
  if [ -n "${FM_PROGRESS_LAST:-}" ]; then
    last_dir=$(fm_progress_safe_dir "$(dirname "$LAST_FILE")" 'state marker directory')
    case "$last_dir" in
      "$STATE"|"$STATE"/*) ;;
      *) fm_progress_die "state marker override escapes the validated state root: $LAST_FILE" 1 ;;
    esac
    LAST_FILE=$last_dir/$(basename "$LAST_FILE")
  else
    LAST_FILE=$STATE/progress-report.last
  fi
  REPORT_LOCK=$STATE/.progress-report.lock
  fm_lock_acquire_wait "$REPORT_LOCK" "$COLLECT_TIMEOUT" || fm_progress_die 'report lock unavailable' 1
  REPORT_LOCK_HELD=1

  fm_progress_load_quarantine
  fm_progress_load_backlog
  fm_progress_load_quota
  fm_progress_load_merged_prs
  fm_progress_load_lifecycle
  fm_progress_build_json

  local body material_digest stored_digest now_iso coverage_marker
  local poisoned seen_json merged_reported_out new_cursor post_epoch_now
  body=$(fm_progress_render)
  [ -n "$body" ] || fm_progress_die 'rendered report is empty' 1
  coverage_marker=$(jq -r '"*Since last report:* coverage merged=" + (if .merged_invalid then "unknown" else "valid" end) + " seats=" + (if .lifecycle_poisoned then "unknown" else "valid" end)' "$INPUT_DIR/report.json")
  material_digest=$(fm_progress_material_fingerprint "$body" "$(jq -r '.header_time' "$INPUT_DIR/report.json")" "$coverage_marker")
  stored_digest=$(fm_progress_read_state material_sha256 '')

  if [ -n "$stored_digest" ] && [ "$material_digest" = "$stored_digest" ] \
    && ! jq -e '.has_delta_activity' "$INPUT_DIR/report.json" >/dev/null 2>&1; then
    exit 0
  fi

  now_iso=$(jq -r '.header_time_iso' "$INPUT_DIR/report.json")
  poisoned=$(jq -r '.lifecycle_poisoned' "$INPUT_DIR/report.json")
  seen_json=$(jq -c '.new_seen_ids' "$INPUT_DIR/report.json")
  merged_reported_out=$(jq -r '.new_merged_reported | join(",")' "$INPUT_DIR/report.json")
  new_cursor=$(fm_progress_new_cursor_json "$(cat "$INPUT_DIR/lifecycle.cursor.prior.json")" "$poisoned" "$seen_json")
  post_epoch_now=$(fm_progress_now_epoch)

  # Stage the complete report to the private result file, then commit state
  # and verify the commit. The untimed parent releases the staged report only
  # after this child exits successfully, so a deadline can never emit partial
  # output and a retry can never duplicate a post.
  printf '%s\n' "$body" > "$RESULT_FILE" || fm_progress_die 'staged report write failed' 1
  fm_progress_atomic_write "$LAST_FILE" "$(printf '%spost_ts=%s\npost_epoch=%s\nmaterial_sha256=%s\nlifecycle_cursor=%s\nmerged_reported=%s\nlifecycle_seeded=1\n' \
    "" "$now_iso" "$post_epoch_now" "$material_digest" "$new_cursor" "$merged_reported_out")"
  # The commit helper already verified inode and committed bytes before
  # reporting success; a path-based re-read here would only re-resolve what
  # the descriptor-bound commit just proved.
}

# One shared end-to-end deadline: collection, render, and the state commit run
# in a single watchdog-guarded subshell with its own process group (monitor
# mode). There is no privileged child mode to enter from outside: no argument,
# environment value, file, or descriptor changes who enforces the budget, and
# the budget clock is the shell's own SECONDS delta, which the render-clock
# test seam cannot freeze. The subshell stages the complete report to a
# private result file and commits state before exiting; only the parent
# releases the staged report after the subshell succeeds, so a deadline never
# emits partial output and a retry never duplicates a post.
WRAP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-progress-report-wrap.XXXXXX") || exit 1
trap 'rm -rf "$WRAP_DIR"' EXIT
RESULT_FILE=$WRAP_DIR/report.out

set -m
(
  trap 'release_report_lock; rm -rf "$INPUT_DIR"' EXIT
  INPUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-progress-report.XXXXXX") || exit 1
  main "$@"
) &
worker_pid=$!
deadline=$((SECONDS + COLLECT_TIMEOUT))
worker_rc=0
worker_killed=0
while kill -0 "$worker_pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    kill -TERM -"$worker_pid" 2>/dev/null || true
    worker_killed=1
    break
  fi
  sleep 1
done
wait "$worker_pid" 2>/dev/null || worker_rc=$?
set +m
if [ "$worker_killed" -eq 1 ]; then
  sleep 1
  kill -KILL -"$worker_pid" 2>/dev/null || true
  fm_progress_die "end-to-end collection exceeded the shared ${COLLECT_TIMEOUT}s deadline" 1
fi
if [ "$worker_rc" -ne 0 ]; then
  exit "$worker_rc"
fi
if [ -s "$RESULT_FILE" ]; then
  cat "$RESULT_FILE" || fm_progress_die 'staged report release failed' 1
fi
exit 0
