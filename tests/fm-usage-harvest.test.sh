#!/usr/bin/env bash
# Behavior tests for the fleet usage harvester and its report reader.
# Covers claude-log request dedupe and cache folding, codex per-request delta
# sums with cwd/window matching, cursor/unavailable null rows, the
# no-double-append idempotency guard, the ledger report rendering, and the
# teardown integration property that a harvest failure never blocks teardown.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARVEST="$ROOT/bin/fm-usage-harvest.sh"
REPORT="$ROOT/bin/fm-usage-report.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-usage-harvest)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

file_mtime_epoch() {  # <file>
  local t
  t=$(stat -f %m -- "$1" 2>/dev/null) || t=$(stat -c %Y -- "$1" 2>/dev/null) || return 1
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$t"
}
file_birth_epoch() {  # <file>
  local t
  t=$(stat -f %B -- "$1" 2>/dev/null) || t=$(stat -c %W -- "$1" 2>/dev/null) || return 1
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  [ "$t" -ge 1000000000 ] 2>/dev/null || return 1
  printf '%s' "$t"
}

# harvest_case <id> <harness> [model] [effort] : create a home with one task
# whose worktree is $TMP_ROOT/wt-<id>, status and meta included, and echo the
# data dir. Exports the FM_USAGE_* fixture dirs per case.
harvest_case() {  # <id> <harness> <worktree> [model] [effort]
  local id=$1 harness=$2 wt=$3
  local home="$TMP_ROOT/home-$id"
  mkdir -p "$home/state" "$home/data"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$TMP_ROOT/proj-$id" "harness=$harness" "kind=ship" "mode=no-mistakes" \
    "model=${4:-default}" "effort=${5:-default}"
  {
    printf 'working: started\n'
    printf 'working: halfway\n'
    printf 'done: finished the task\n'
  } > "$home/state/$id.status"
  printf '%s\n' "$home/data"
}
export_harvest_env() {  # <home-data>
  FM_STATE_OVERRIDE="$1/state"
  FM_DATA_OVERRIDE="$1/data"
  FM_USAGE_CLAUDE_DIR="$TMP_ROOT/fake-claude/projects"
  FM_USAGE_CODEX_DIR="$TMP_ROOT/fake-codex/sessions"
  export FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_USAGE_CLAUDE_DIR FM_USAGE_CODEX_DIR
}

# --- claude: request dedupe, cache folding, encoding resolution, window -----

claude_case() {
  local id=usageclaude1 wt="$TMP_ROOT/wt-usageclaude1"
  local data home state ledger row
  data=$(harvest_case "$id" claude "$wt" default default)
  home=$(dirname "$data")
  state="$home/state"
  export_harvest_env "$home"

  # The encoded directory is the worktree path with every '/' turned into '-'.
  local encoded=${wt//\//-}
  local logdir="$FM_USAGE_CLAUDE_DIR/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/session-a.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgA","model":"claude-test","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":30,"output_tokens_details":{"thinking_tokens":5}}}}
{"type":"assistant","message":{"id":"msgA","model":"claude-test","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":30,"output_tokens_details":{"thinking_tokens":5}}}}
{"type":"assistant","message":{"id":"msgB","model":"claude-test","usage":{"input_tokens":7,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":9}}}
{"type":"user","message":{"role":"user"}}
{"type":"assistant","message":{"id":"msgC"}}
JSON
  # A request logged outside the task window (future mtime) must be excluded,
  # as must a session in a differently encoded sibling directory.
  cat > "$logdir/session-future.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgX","model":"claude-test","usage":{"input_tokens":999,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":999}}}
JSON
  touch -t "$(date -r $(( $(file_mtime_epoch "$state/$id.status") + 7200 )) +%Y%m%d%H%M.%S)" \
    "$logdir/session-future.jsonl"
  mkdir -p "$FM_USAGE_CLAUDE_DIR/wrong-encoded-dir"
  printf '%s\n' '{"type":"assistant","message":{"id":"msgY","model":"claude-test","usage":{"input_tokens":777,"output_tokens":777}}}' \
    > "$FM_USAGE_CLAUDE_DIR/wrong-encoded-dir/other.jsonl"
  # Seal the window: the status end mtime must not predate the in-window
  # session log, or the log correctly falls outside birth -> end.
  touch -m -r "$logdir/session-a.jsonl" "$state/$id.status"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "claude harvest should succeed"$'\n'"$out"
  ledger="$data/usage-ledger.jsonl"
  [ -f "$ledger" ] || fail "claude harvest wrote no ledger"
  [ "$(wc -l < "$ledger" | tr -d ' ')" = 1 ] || fail "claude harvest wrote more than one ledger line"
  row=$(cat "$ledger")
  assert_contains "$row" '"task":"usageclaude1"' "claude row names the task"
  assert_contains "$row" '"harness":"claude"' "claude row names the harness"
  assert_contains "$row" '"model":"claude-test"' "claude row captures the log model"
  assert_contains "$row" '"source":"claude-projects"' "claude row names its source"
  assert_contains "$row" '"input_tokens":17' "claude input tokens dedupe per request (10+7)"
  assert_contains "$row" '"cached_input_tokens":120' "claude cached folds read+creation (100+20+0+0)"
  assert_contains "$row" '"output_tokens":39' "claude output tokens (30+9)"
  assert_contains "$row" '"reasoning_tokens":5' "claude reasoning captures thinking tokens"
  assert_contains "$row" '"turns":2' "claude turn estimate counts working: lines"
  assert_contains "$row" '"effort":null' "default effort renders null"
  # Wall seconds is birth -> status mtime on this platform; assert the
  # computed value equals an independent read of the same file facts.
  local end birth wall_expected
  end=$(file_mtime_epoch "$state/$id.status")
  birth=$(file_birth_epoch "$state/$id.status" || file_mtime_epoch "$state/$id.status")
  wall_expected=$((end - birth))
  [ "$wall_expected" -lt 0 ] && wall_expected=0
  assert_contains "$row" "\"wall_secs\":$wall_expected" \
    "claude wall seconds equals status birth -> last-mtime window"

  # Idempotency: a second harvest must not append a duplicate row.
  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "second claude harvest should exit 0"$'\n'"$out"
  [ "$(wc -l < "$ledger" | tr -d ' ')" = 1 ] \
    || fail "second claude harvest double-appended"
  pass "claude harvest: per-request dedupe, cache folding, encoding, window, idempotency"
}

# --- codex: cwd match, window match, delta sums, model capture --------------

codex_case() {
  local id=usagecodex1 wt="$TMP_ROOT/wt-usagecodex1"
  local data home ledger row out
  data=$(harvest_case "$id" codex "$wt" default high)
  home=$(dirname "$data")
  export_harvest_env "$home"

  local d1="$FM_USAGE_CODEX_DIR/2026/08/28"
  mkdir -p "$d1"
  cat > "$d1/rollout-match.jsonl" <<JSON
{"timestamp":"2026-08-28T15:13:03.851Z","ordinal":0,"type":"session_meta","payload":{"session_id":"s1","cwd":"$wt"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":10,"cache_write_input_tokens":5,"output_tokens":20,"reasoning_output_tokens":8},"last_token_usage":{"input_tokens":100,"cached_input_tokens":10,"cache_write_input_tokens":5,"output_tokens":20,"reasoning_output_tokens":8}}}}
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":11,"reasoning_output_tokens":3}}}}
{"type":"turn_context","payload":{"cwd":"$wt","model":"glm-5.3"}}
JSON
  # Same window but a different cwd: must be excluded.
  cat > "$d1/rollout-othercwd.jsonl" <<JSON
{"type":"session_meta","payload":{"cwd":"/elsewhere"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":888,"output_tokens":888}}}}
{"type":"turn_context","payload":{"model":"glm-5.3"}}
JSON
  # Matching cwd but outside the window: must be excluded.
  cat > "$d1/rollout-future.jsonl" <<JSON
{"type":"session_meta","payload":{"cwd":"$wt"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":999,"output_tokens":999}}}}
JSON
  touch -t "$(date -r $(( $(file_mtime_epoch "$home/state/$id.status") + 7200 )) +%Y%m%d%H%M.%S)" \
    "$d1/rollout-future.jsonl"
  touch -m -r "$d1/rollout-match.jsonl" "$home/state/$id.status"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "codex harvest should succeed"$'\n'"$out"
  ledger="$home/data/usage-ledger.jsonl"
  row=$(cat "$ledger")
  assert_contains "$row" '"harness":"codex"' "codex row names the harness"
  assert_contains "$row" '"model":"glm-5.3"' "codex row captures the turn_context model"
  assert_contains "$row" '"effort":"high"' "codex row carries meta effort"
  assert_contains "$row" '"source":"codex-sessions"' "codex row names its source"
  assert_contains "$row" '"input_tokens":150' "codex input sums per-request deltas (100+50)"
  assert_contains "$row" '"cached_input_tokens":15' "codex cached folds cached+cache_write (10+5+0)"
  assert_contains "$row" '"output_tokens":31' "codex output sums deltas (20+11)"
  assert_contains "$row" '"reasoning_tokens":11' "codex reasoning sums deltas (8+3)"
  pass "codex harvest: cwd/window matching, delta sums, model capture"
}

# --- cursor: unavailable logs render nulls ----------------------------------

cursor_case() {
  local id=usagecursor1 wt="$TMP_ROOT/wt-usagecursor1"
  local data home ledger row out
  data=$(harvest_case "$id" cursor "$wt" cursor-grok-4.5-high "")
  home=$(dirname "$data")
  export_harvest_env "$home"
  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "cursor harvest should succeed"$'\n'"$out"
  ledger="$home/data/usage-ledger.jsonl"
  row=$(cat "$ledger")
  assert_contains "$row" '"model":"cursor-grok-4.5-high"' "cursor row falls back to meta model"
  assert_contains "$row" '"input_tokens":null' "cursor input tokens are null"
  assert_contains "$row" '"cached_input_tokens":null' "cursor cached tokens are null"
  assert_contains "$row" '"output_tokens":null' "cursor output tokens are null"
  assert_contains "$row" '"reasoning_tokens":null' "cursor reasoning tokens are null"
  assert_contains "$row" '"source":"unavailable"' "cursor row marks source unavailable"
  pass "cursor harvest: unavailable source renders null token fields"
}

# --- report: per-model totals and per-task rows -----------------------------

report_case() {
  local out ledger
  ledger="$TMP_ROOT/home-usageclaude1/data/usage-ledger.jsonl"
  cat "$TMP_ROOT/home-usagecodex1/data/usage-ledger.jsonl" >> "$ledger"
  cat "$TMP_ROOT/home-usagecursor1/data/usage-ledger.jsonl" >> "$ledger"
  out=$(FM_DATA_OVERRIDE="$(dirname "$ledger")" "$REPORT" 2>&1)
  expect_code 0 "$?" "report should succeed"$'\n'"$out"
  assert_contains "$out" "usage ledger: $ledger (3 rows)" "report names the ledger and row count"
  assert_contains "$out" "per-model totals" "report prints per-model totals"
  assert_contains "$out" "claude-test" "report lists the claude model"
  assert_contains "$out" "glm-5.3" "report lists the codex model"
  assert_contains "$out" "usageclaude1" "report lists each task row"
  assert_contains "$out" "usagecursor1" "report lists the unavailable task row"
  assert_contains "$out" "unavailable" "report shows the unavailable source"
  # Missing ledger exits 0 with a note.
  out=$(FM_DATA_OVERRIDE="$TMP_ROOT/empty-home" "$REPORT" 2>&1)
  expect_code 0 "$?" "report without a ledger should exit 0"
  assert_contains "$out" "no usage ledger" "report names the missing ledger"
  pass "usage report: per-model totals, per-task rows, missing-ledger tolerance"
}

# --- teardown integration: harvest failure never blocks teardown ------------

teardown_case() {
  local proj wt id fb state data config out
  id=usageharvtd1
  proj="$TMP_ROOT/td-proj"; wt="$TMP_ROOT/td-wt"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fb="$TMP_ROOT/td-fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/tmux" "$fb/treehouse"
  state="$TMP_ROOT/td-state"; config="$TMP_ROOT/td-config"; data="$TMP_ROOT/td-data"
  mkdir -p "$state" "$config" "$data/$id"
  printf 'scout findings\n' > "$data/$id/report.md"
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "harness=claude" \
    "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="
  printf 'working: scouting\n' > "$state/$id.status"
  # The ledger path being a directory forces every append to fail.
  mkdir -p "$data/usage-ledger.jsonl"
  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_USAGE_CLAUDE_DIR="$TMP_ROOT/td-fake-claude" FM_USAGE_CODEX_DIR="$TMP_ROOT/td-fake-codex" \
    "$TEARDOWN" "$id" 2>&1)
  expect_code 0 "$?" "teardown must succeed even when the harvest fails"$'\n'"$out"
  assert_contains "$out" "warning: usage harvest for $id failed" \
    "teardown warns one line when the harvest fails"
  assert_contains "$out" "teardown $id complete" \
    "teardown completes after a harvest failure"
  pass "teardown integration: harvest failure is non-fatal"
}

claude_case
codex_case
cursor_case
report_case
teardown_case
