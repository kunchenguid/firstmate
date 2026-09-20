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
  # The worktree path carries a dot segment (as every firstmate home under
  # .no-mistakes does) so a slash-only encoding would resolve to the wrong
  # on-disk project directory.
  local id=usageclaude1 wt="$TMP_ROOT/.no-mistakes/wt-usageclaude1"
  local data home state ledger row
  data=$(harvest_case "$id" claude "$wt" default default)
  home=$(dirname "$data")
  state="$home/state"
  export_harvest_env "$home"

  # Claude Code encodes the project directory by mapping BOTH '/' and '.' to
  # '-', so the fixture log dir mirrors that full sanitization.
  local encoded=${wt//\//-}
  encoded=${encoded//./-}
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

# --- claude: window survives a host without usable birth time ---------------

# A stat shim that reports no birth time (GNU statx unsupported returns 0 for
# %W) while still answering mtime, so the harvest must fall back to the meta
# mtime for the window start instead of collapsing to the status mtime.
nobirth_stat_bin() {  # <dir>
  mkdir -p "$1"
  cat > "$1/stat" <<'SH'
#!/usr/bin/env bash
fmt=""; file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -f) exit 1 ;;
    -c) fmt="$2"; shift 2 ;;
    --) shift; file="$1"; shift ;;
    *) file="$1"; shift ;;
  esac
done
case "$fmt" in
  %W) printf '0\n' ;;
  %Y) /usr/bin/stat -f %m -- "$file" 2>/dev/null || /usr/bin/stat -c %Y -- "$file" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$1/stat"
}

claude_nobirth_case() {
  local id=usagenobirth1 wt="$TMP_ROOT/.no-mistakes/wt-usagenobirth1"
  local data home state ledger row out fb base
  data=$(harvest_case "$id" claude "$wt" default default)
  home=$(dirname "$data")
  state="$home/state"
  export_harvest_env "$home"

  local encoded=${wt//\//-}
  encoded=${encoded//./-}
  local logdir="$FM_USAGE_CLAUDE_DIR/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/session.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgN","model":"claude-test","usage":{"input_tokens":12,"output_tokens":8}}}
JSON

  # Pin an explicit window: status finishes at T, meta was spawned 100s earlier,
  # and the session log lands mid-window. Without the meta-mtime start fallback
  # the birthless window collapses to [T, T] and drops the earlier log.
  base=$(file_mtime_epoch "$state/$id.status")
  touch -t "$(date -r "$base" +%Y%m%d%H%M.%S)" "$state/$id.status"
  touch -t "$(date -r $((base - 100)) +%Y%m%d%H%M.%S)" "$state/$id.meta"
  touch -t "$(date -r $((base - 50)) +%Y%m%d%H%M.%S)" "$logdir/session.jsonl"

  fb="$TMP_ROOT/nobirth-fakebin"
  nobirth_stat_bin "$fb"
  cat > "$fb/date" <<'PYDATE'
#!/usr/bin/env python3
import os
import sys
import time
args = sys.argv[1:]
if "-r" in args:
    sys.exit(1)
if "-d" in args:
    epoch = int(args[args.index("-d") + 1].removeprefix("@"))
    fmt = next(arg[1:] for arg in args if arg.startswith("+"))
    print(time.strftime(fmt, time.gmtime(epoch) if "-u" in args else time.localtime(epoch)))
else:
    os.execv("/bin/date", ["date"] + args)
PYDATE
  chmod +x "$fb/date"
  out=$(TZ=America/Toronto PATH="$fb:$PATH" "$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "birthless claude harvest should succeed"$'\n'"$out"
  ledger="$data/usage-ledger.jsonl"
  row=$(cat "$ledger")
  assert_contains "$row" '"source":"claude-projects"' \
    "birthless harvest still finds the in-window log via the meta-mtime start"
  assert_contains "$row" '"input_tokens":12' "birthless harvest sums the in-window usage"
  assert_contains "$row" '"wall_secs":100' \
    "birthless window spans meta -> status instead of collapsing to zero"
  pass "claude harvest: window survives a host without usable birth time"
}

# --- remote secondmate: local logs are never harvested for remote work ------

remote_case() {
  local id=usageremote1 wt="$TMP_ROOT/wt-usageremote1"
  local data home ledger row out
  data=$(harvest_case "$id" codex "$wt" default high)
  home=$(dirname "$data")
  export_harvest_env "$home"
  # The task ran on a remote secondmate host (fm-spawn records remote_host=).
  printf 'remote_host=box.example\n' >> "$home/state/$id.meta"
  # Seed a LOCAL codex session whose cwd matches the worktree: without the
  # remote-host guard the harvest would misattribute this local session to the
  # remote task; with it, the row is honestly unavailable and its tokens null.
  local d1="$FM_USAGE_CODEX_DIR/2026/08/28"
  mkdir -p "$d1"
  cat > "$d1/rollout-localmatch.jsonl" <<JSON
{"type":"session_meta","payload":{"cwd":"$wt"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"output_tokens":400}}}}
{"type":"turn_context","payload":{"cwd":"$wt","model":"glm-5.3"}}
JSON
  touch -m -r "$d1/rollout-localmatch.jsonl" "$home/state/$id.status"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "remote harvest should succeed"$'\n'"$out"
  ledger="$home/data/usage-ledger.jsonl"
  [ "$(wc -l < "$ledger" | tr -d ' ')" = 1 ] || fail "remote harvest wrote no single row"
  row=$(cat "$ledger")
  assert_contains "$row" '"source":"unavailable"' \
    "remote task records unavailable, not a local session"
  assert_contains "$row" '"input_tokens":null' \
    "remote task tokens are null (no local misattribution)"
  pass "remote secondmate harvest: local logs are never misattributed"
}

# --- concurrency: the ledger lock keeps the append idempotent ---------------

race_case() {
  local id=usagerace1 wt="$TMP_ROOT/wt-usagerace1"
  local data home ledger p1 p2
  data=$(harvest_case "$id" cursor "$wt" cursor-x "")
  home=$(dirname "$data")
  export_harvest_env "$home"
  ledger="$home/data/usage-ledger.jsonl"
  # Two concurrent harvests with a widened check-to-append window: the ledger
  # lock must serialize them so exactly one row is appended. Without the lock
  # both pass the existence check and each append, yielding two rows.
  FM_USAGE_HARVEST_APPEND_DELAY=1 "$HARVEST" "$id" >/dev/null 2>&1 &
  p1=$!
  FM_USAGE_HARVEST_APPEND_DELAY=1 "$HARVEST" "$id" >/dev/null 2>&1 &
  p2=$!
  wait "$p1"; wait "$p2"
  [ -f "$ledger" ] || fail "concurrent harvest wrote no ledger"
  [ "$(wc -l < "$ledger" | tr -d ' ')" = 1 ] \
    || fail "concurrent harvests appended more than one row"
  pass "usage harvest: concurrent harvests append exactly one row"
}

# A held ledger lock must never block the (teardown-synchronous) harvest
# forever: the acquire is bounded, so a second harvest whose lock-wait is
# shorter than the holder's critical section gives up best-effort (non-zero,
# no duplicate row) instead of hanging until the holder releases.
lock_bound_case() {
  local id=usagelockbound1 wt="$TMP_ROOT/wt-usagelockbound1"
  local data home ledger p1 rc
  data=$(harvest_case "$id" cursor "$wt" cursor-x "")
  home=$(dirname "$data")
  export_harvest_env "$home"
  ledger="$home/data/usage-ledger.jsonl"
  # Holder keeps the lock across a 4s critical section.
  FM_USAGE_HARVEST_APPEND_DELAY=4 "$HARVEST" "$id" >/dev/null 2>&1 &
  p1=$!
  # Let the holder acquire before the bounded harvester starts spinning.
  sleep 1
  rc=0
  FM_USAGE_LEDGER_LOCK_WAIT=1 "$HARVEST" "$id" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "bounded harvest returned 0 while the ledger lock was held"
  wait "$p1"
  [ "$(wc -l < "$ledger" | tr -d ' ')" = 1 ] \
    || fail "bounded give-up appended a duplicate row"
  pass "usage harvest: a held ledger lock bounds the acquire, no hang or dup"
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

usage_recovery_case() {
  local harness=$1 mode=$2 id="recovery-$1-$2"
  local wt="$TMP_ROOT/wt-$id" data home logdir encoded log out source
  data=$(harvest_case "$id" "$harness" "$wt" fallback-model)
  home=$(dirname "$data")
  export_harvest_env "$home"
  if [ "$harness" = claude ]; then
    encoded=${wt//\//-}
    encoded=${encoded//./-}
    logdir="$FM_USAGE_CLAUDE_DIR/$encoded"
    source=claude-projects
  else
    logdir="$FM_USAGE_CODEX_DIR/$id"
    source=codex-sessions
  fi
  mkdir -p "$logdir"
  log="$logdir/session.jsonl"
  printf '%s\n' '{broken' > "$log"
  if [ "$harness" = codex ]; then
    jq -cn --arg cwd "$wt" '{type:"session_meta",payload:{cwd:$cwd}}' >> "$log"
  fi
  if [ "$mode" != unavailable ]; then
    if [ "$harness" = claude ]; then
      printf '%s\n' '{"type":"assistant","message":{"id":"one","usage":{"input_tokens":12,"cache_read_input_tokens":3,"cache_creation_input_tokens":4,"output_tokens":8,"output_tokens_details":{"thinking_tokens":2}}}}' >> "$log"
    else
      printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":12,"cached_input_tokens":3,"cache_write_input_tokens":4,"output_tokens":8,"reasoning_output_tokens":2}}}}' >> "$log"
    fi
    printf '%s\n' '{broken middle' >> "$log"
    if [ "$harness" = claude ]; then
      printf '%s\n' '{"type":"assistant","message":{"id":"two","usage":{"input_tokens":5,"output_tokens":6}}}' >> "$log"
    else
      printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5,"output_tokens":6}}}}' >> "$log"
    fi
  else
    printf '%s\n' '{"type":"assistant","message":{"model":"unused-model"}}' >> "$log"
  fi
  printf '%s\n' '{broken tail' >> "$log"
  touch -m -r "$log" "$home/state/$id.status"
  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "$harness $mode harvest succeeds: $out"
  if [ "$mode" = unavailable ]; then
    jq -e '.source == "unavailable" and .model == "fallback-model"
      and ([.input_tokens,.cached_input_tokens,.output_tokens,.reasoning_tokens] == [null,null,null,null])' \
      "$data/usage-ledger.jsonl" >/dev/null || fail "$harness missing usage must be unavailable"
  else
    jq -e --arg source "$source" '.source == $source and .model == "fallback-model"
      and ([.input_tokens,.cached_input_tokens,.output_tokens,.reasoning_tokens] == [17,7,14,2])' \
      "$data/usage-ledger.jsonl" >/dev/null || fail "$harness preserves valid usage and absent model fields"
  fi
  pass "$harness $mode: malformed lines and missing models"
}

retirement_window_case() {
  local harness=$1 id="retirement-$1" base data home wt logdir encoded fb out
  wt="$TMP_ROOT/wt-$id"
  data=$(harvest_case "$id" "$harness" "$wt" fallback-model)
  home=$(dirname "$data")
  export_harvest_env "$home"
  base=$(date +%s)
  if [ "$harness" = claude ]; then
    encoded=${wt//\//-}
    encoded=${encoded//./-}
    logdir="$FM_USAGE_CLAUDE_DIR/$encoded"
  else
    logdir="$FM_USAGE_CODEX_DIR/$id"
  fi
  mkdir -p "$logdir"
  python3 - "$harness" "$wt" "$base" "$logdir" "$home" "$id" <<'PYFIXTURE'
import datetime
import json
import os
import pathlib
import sys
harness, wt, base, logdir, home, task = sys.argv[1:]
base = int(base)
state = pathlib.Path(home) / "state"
status = state / (task + ".status")
status.write_text(
    f"working [at={base - 100}]: started\n"
    "working: legacy continuation\n"
    f"working [at={base - 50}]: continued\n"
    f"done [at={base - 20}]: finished\n"
    "note: working: quoted text\n"
)
os.utime(status, (base - 20, base - 20))
os.utime(state / (task + ".meta"), (base, base))
def event(at, tokens):
    stamp = datetime.datetime.fromtimestamp(at, datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    if harness == "claude":
        return {"timestamp": stamp, "type": "assistant", "message": {
            "id": str(at), "model": "test-model", "usage": {"input_tokens": tokens}}}
    return {"timestamp": stamp, "type": "event_msg", "payload": {
        "type": "token_count", "info": {"last_token_usage": {"input_tokens": tokens}}}}
for name, records, mtime in [
    ("final", [event(base - 200, 999), event(base - 10, 12), event(base + 100, 999)], base + 500),
    ("early", [event(base - 70, 5)], base - 60),
]:
    if harness == "codex":
        records.insert(0, {"type": "session_meta", "payload": {"cwd": wt}})
    path = pathlib.Path(logdir) / (name + ".jsonl")
    path.write_text("".join(json.dumps(record) + "\n" for record in records))
    os.utime(path, (mtime, mtime))
PYFIXTURE
  fb="$TMP_ROOT/retirement-$harness-fakebin"
  nobirth_stat_bin "$fb"
  out=$(PATH="$fb:$PATH" "$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "$harness retirement harvest succeeds: $out"
  jq -e --argjson start "$((base - 100))" '
    .source != "unavailable" and .input_tokens == 17 and .wall_secs == 80
    and .turns == 3 and (.spawned_at | fromdateiso8601) == $start
  ' "$data/usage-ledger.jsonl" >/dev/null \
    || fail "$harness retirement includes final usage, preserves start, and counts stamped events"
  pass "$harness retirement: event window, rewritten metadata, stamped and legacy turns"
}

claude_profile_case() (
  local mode=$1 id="profile-$1" wt data home encoded profile override logdir out
  wt="$TMP_ROOT/wt-$id"
  data=$(harvest_case "$id" claude "$wt" default default)
  home=$(dirname "$data")
  export_harvest_env "$home"
  profile="$TMP_ROOT/alternate profile-$mode"
  override="$TMP_ROOT/explicit-projects-$mode"
  encoded=${wt//\//-}
  encoded=${encoded//./-}
  mkdir -p "$profile/projects/$encoded" "$override/$encoded"
  printf '%s\n' '{"type":"assistant","message":{"id":"profile","usage":{"input_tokens":12}}}' \
    > "$profile/projects/$encoded/session.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"id":"override","usage":{"input_tokens":34}}}' \
    > "$override/$encoded/session.jsonl"
  export CLAUDE_CONFIG_DIR="$profile"
  unset FM_USAGE_CLAUDE_DIR
  if [ "$mode" = override ]; then
    export FM_USAGE_CLAUDE_DIR="$override"
    logdir="$override/$encoded"
  else
    logdir="$profile/projects/$encoded"
  fi
  touch -m -r "$logdir/session.jsonl" "$home/state/$id.status"
  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "Claude $mode profile harvest succeeds: $out"
  local expected=12
  [ "$mode" != override ] || expected=34
  jq -e --argjson expected "$expected" '.source == "claude-projects" and .input_tokens == $expected' \
    "$data/usage-ledger.jsonl" >/dev/null || fail "Claude $mode profile precedence"
  pass "Claude $mode profile resolves usage logs"
)

claude_case
claude_nobirth_case
codex_case
cursor_case
remote_case
race_case
lock_bound_case
report_case
teardown_case
for harness in claude codex; do
  usage_recovery_case "$harness" recovered
  usage_recovery_case "$harness" unavailable
  retirement_window_case "$harness"
done

claude_profile_case alternate
claude_profile_case override
