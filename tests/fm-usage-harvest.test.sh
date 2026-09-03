#!/usr/bin/env bash
# Behavior tests for the fleet usage harvester and its report reader.
# Covers claude-log request dedupe and cache folding, codex per-request delta
# sums with cwd/window matching, pi/pi-signed session parsing over the shared
# ~/.pi/agent/sessions tree, the durable spawn_gen task start that survives a
# meta rewritten after the fact, cursor/unavailable null rows, the
# no-double-append idempotency guard, the ledger report rendering including
# its refusal to present an unparseable ledger as a result, and the
# teardown integration properties that the harvest sees the status log and
# that a harvest failure never blocks teardown. Also covers the whole-task row
# scope a relaunch must not narrow, the per-line corrupt-log tolerance, and
# the rule that a source is named only after a log yields assistant usage.
# Also covers the one token convention every parser normalizes onto, the
# first-line cwd probe that rejects an unrelated sibling session before
# parsing it in full, the report's per-model grouping and column sums, the
# documented harness-switch narrowing, deterministic final-incarnation model
# attribution, the log scan that reaches the harness's closing write without
# absorbing a later occupant of the same worktree path, the teardown ordering
# that keeps that scan bound safe, the harvest of a secondmate's children
# before a forced cleanup retires them, and the scan-then-append split that
# keeps an aborted teardown from freezing a row its rerun could not correct.
# Also covers the nested remote secondmate teardown, whose append is skipped
# because the home it removed is the one holding its own ledger.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARVEST="$ROOT/bin/fm-usage-harvest.sh"
REPORT="$ROOT/bin/fm-usage-report.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-usage-harvest)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
REAL_JQ=$(command -v jq)
REAL_MKTEMP=$(command -v mktemp)

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

# Portable epoch formatters: BSD date reads an epoch with -r, GNU date with
# -d @<epoch>. Both forms are tried so the fixtures pin the same timestamps on
# macOS and on the Linux CI runners. touch -t reads its argument as LOCAL
# time, so both renderings here are local; iso_utc below is the ledger's UTC
# spelling and stays UTC.
touch_stamp() {  # <epoch> : touch -t argument
  date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S
}
iso_utc() {  # <epoch> : the harvester's ledger timestamp spelling
  date -r "$1" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
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
  FM_USAGE_PI_DIR="$TMP_ROOT/fake-pi/sessions"
  export FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_USAGE_CLAUDE_DIR FM_USAGE_CODEX_DIR
  export FM_USAGE_PI_DIR
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
  touch -t "$(touch_stamp $(( $(file_mtime_epoch "$state/$id.status") + 7200 )))" \
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
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":2,"cached_input_tokens":9,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0}}}}
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
  touch -t "$(touch_stamp $(( $(file_mtime_epoch "$home/state/$id.status") + 7200 )))" \
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
  # Codex counts cached_input_tokens inside its own input_tokens, so each event
  # contributes only the fresh remainder: (100-10) + (50-0) + max(2-9, 0).
  assert_contains "$row" '"input_tokens":140' \
    "codex input reports fresh input, never the cached tokens it already contains"
  assert_contains "$row" '"cached_input_tokens":24' \
    "codex cached folds cached+cache_write (10+5+0+9)"
  assert_contains "$row" '"output_tokens":32' "codex output sums deltas (20+11+1)"
  assert_contains "$row" '"reasoning_tokens":11' "codex reasoning sums deltas (8+3+0)"
  pass "codex harvest: cwd/window matching, delta sums, cache normalization, model capture"
}

# --- pi / pi-signed: shared session tree, cwd match, per-message usage -------

# pi_session_log <file> <cwd> : one realistic Pi session log. The session
# record carries the cwd; each assistant message record carries one request's
# usage. The second record repeats the first record's id, standing in for a
# replayed line that must not be counted twice.
pi_session_log() {  # <file> <cwd>
  cat > "$1" <<JSON
{"type":"session","version":3,"id":"sess-1","timestamp":"2026-08-31T04:46:40.383Z","cwd":"$2"}
{"type":"model_change","id":"mc1","timestamp":"2026-08-31T04:46:57.742Z","provider":"zai","modelId":"glm-5.3-flash"}
{"type":"message","id":"m1","timestamp":"2026-08-31T04:47:00.000Z","message":{"role":"assistant","provider":"zai","model":"glm-5.3-flash","usage":{"input":100,"output":20,"cacheRead":30,"cacheWrite":4,"reasoning":7,"totalTokens":150}}}
{"type":"message","id":"m1","timestamp":"2026-08-31T04:47:00.000Z","message":{"role":"assistant","provider":"zai","model":"glm-5.3-flash","usage":{"input":100,"output":20,"cacheRead":30,"cacheWrite":4,"reasoning":7,"totalTokens":150}}}
{"type":"message","id":"u1","timestamp":"2026-08-31T04:47:05.000Z","message":{"role":"user"}}
{"type":"message","id":"m2","timestamp":"2026-08-31T04:47:09.000Z","message":{"role":"assistant","provider":"zai","model":"glm-5.3-flash","usage":{"input":11,"output":3,"cacheRead":5,"cacheWrite":0,"reasoning":1,"totalTokens":19}}}
{"type":"message","id":"tr1","timestamp":"2026-08-31T04:47:11.000Z","message":{"role":"toolResult"}}
JSON
}

pi_case() {  # <task-id> <harness>
  local id=$1 harness=$2 wt="$TMP_ROOT/wt-$1"
  local data home ledger row out d1
  data=$(harvest_case "$id" "$harness" "$wt" default high)
  home=$(dirname "$data")
  export_harvest_env "$home"

  # Pi keys its session directories off the worker cwd, but the cwd recorded
  # inside the session record is what binds a log to this task, so the fixture
  # directory names are deliberately opaque here.
  d1="$FM_USAGE_PI_DIR/--encoded-match--"
  mkdir -p "$d1"
  pi_session_log "$d1/session-match.jsonl" "$wt"
  # Same window, different cwd: must be excluded.
  mkdir -p "$FM_USAGE_PI_DIR/--encoded-other--"
  pi_session_log "$FM_USAGE_PI_DIR/--encoded-other--/session-other.jsonl" /elsewhere
  # Matching cwd but outside the task window: must be excluded.
  pi_session_log "$d1/session-future.jsonl" "$wt"
  touch -t "$(touch_stamp $(( $(file_mtime_epoch "$home/state/$id.status") + 7200 )))" \
    "$d1/session-future.jsonl"
  touch -m -r "$d1/session-match.jsonl" "$home/state/$id.status"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "$harness harvest should succeed"$'\n'"$out"
  ledger="$home/data/usage-ledger.jsonl"
  [ "$(wc -l < "$ledger" | tr -d ' ')" = 1 ] || fail "$harness harvest wrote more than one row"
  row=$(cat "$ledger")
  assert_contains "$row" "\"harness\":\"$harness\"" "$harness row names the harness"
  assert_contains "$row" '"source":"pi-sessions"' "$harness row names its source"
  assert_contains "$row" '"model":"zai/glm-5.3-flash"' \
    "$harness row reports the provider-qualified log model"
  assert_contains "$row" '"input_tokens":111' \
    "$harness input sums one entry per request, replay deduped (100+11)"
  assert_contains "$row" '"cached_input_tokens":39' \
    "$harness cached folds cacheRead+cacheWrite (30+4+5+0)"
  assert_contains "$row" '"output_tokens":23' "$harness output sums per request (20+3)"
  assert_contains "$row" '"reasoning_tokens":8' "$harness reasoning sums per request (7+1)"
  assert_contains "$row" '"effort":"high"' "$harness row carries meta effort"
  pass "$harness harvest: cwd/window matching, per-request sums, replay dedupe"
}

# --- one token convention across every parser -------------------------------

# The ledger's input_tokens counts FRESH input and cached_input_tokens counts
# everything served from or written to cache, whatever the harness spelled.
# Each fixture below encodes the SAME logical request in its own harness's
# convention: 40 fresh input tokens, 60 cached ones, 7 output and 2 reasoning.
# Claude and Pi log input excluding the cache, Codex logs it including the
# cache, so every row must still report the same four numbers. A parser that
# drifted back to its harness's raw spelling fails here.
token_convention_case() {
  local wt id data home ledger row out logdir encoded d1

  id=usageconvclaude
  wt="$TMP_ROOT/.no-mistakes/wt-$id"
  data=$(harvest_case "$id" claude "$wt" default default)
  home=$(dirname "$data")
  export_harvest_env "$home"
  encoded=${wt//\//-}
  encoded=${encoded//./-}
  logdir="$FM_USAGE_CLAUDE_DIR/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/session.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgK","model":"conv-model","usage":{"input_tokens":40,"cache_read_input_tokens":50,"cache_creation_input_tokens":10,"output_tokens":7,"output_tokens_details":{"thinking_tokens":2}}}}
JSON
  touch -m -r "$logdir/session.jsonl" "$home/state/$id.status"
  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "claude convention harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"input_tokens":40,"cached_input_tokens":60,"output_tokens":7,"reasoning_tokens":2' \
    "claude reports fresh input and folded cache in the ledger's one convention"

  id=usageconvcodex
  wt="$TMP_ROOT/wt-$id"
  data=$(harvest_case "$id" codex "$wt" default high)
  home=$(dirname "$data")
  export_harvest_env "$home"
  d1="$FM_USAGE_CODEX_DIR/2026/08/29"
  mkdir -p "$d1"
  cat > "$d1/rollout-conv.jsonl" <<JSON
{"type":"session_meta","payload":{"cwd":"$wt"}}
{"type":"turn_context","payload":{"model":"conv-model"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":0,"output_tokens":7,"reasoning_output_tokens":2}}}}
JSON
  touch -m -r "$d1/rollout-conv.jsonl" "$home/state/$id.status"
  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "codex convention harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"input_tokens":40,"cached_input_tokens":60,"output_tokens":7,"reasoning_tokens":2' \
    "codex reports the same fresh input as the other parsers, cache counted once"

  id=usageconvpi
  wt="$TMP_ROOT/wt-$id"
  data=$(harvest_case "$id" pi "$wt" default high)
  home=$(dirname "$data")
  export_harvest_env "$home"
  d1="$FM_USAGE_PI_DIR/--encoded-conv--"
  mkdir -p "$d1"
  cat > "$d1/session-conv.jsonl" <<JSON
{"type":"session","version":3,"id":"sess-conv","cwd":"$wt"}
{"type":"message","id":"mc","message":{"role":"assistant","provider":"zai","model":"conv-model","usage":{"input":40,"cacheRead":50,"cacheWrite":10,"output":7,"reasoning":2,"totalTokens":97}}}
JSON
  touch -m -r "$d1/session-conv.jsonl" "$home/state/$id.status"
  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "pi convention harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"input_tokens":40,"cached_input_tokens":60,"output_tokens":7,"reasoning_tokens":2' \
    "pi reports the same fresh input and folded cache as the other parsers"
  pass "usage harvest: every parser normalizes onto one token convention"
}

# Codex's input_tokens is known to contain cached_input_tokens, and that is
# the only field the ledger subtracts from it. Whether cache_write_input_tokens
# is inside input_tokens too is untestable from real logs, which report it as
# zero everywhere, so it is folded into the cached column and left in the fresh
# input rather than being subtracted on a hunch: subtracting an uncontained
# field would under-count fresh input and the clamp would hide it.
codex_cache_write_case() {
  local id=usagecodexwrite wt="$TMP_ROOT/wt-usagecodexwrite"
  local data home row out d1
  data=$(harvest_case "$id" codex "$wt" default high)
  home=$(dirname "$data")
  export_harvest_env "$home"
  d1="$FM_USAGE_CODEX_DIR/2026/08/31"
  mkdir -p "$d1"
  cat > "$d1/rollout-write.jsonl" <<JSON
{"type":"session_meta","payload":{"cwd":"$wt"}}
{"type":"turn_context","payload":{"model":"glm-5.3"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":80,"cached_input_tokens":30,"cache_write_input_tokens":25,"output_tokens":6,"reasoning_output_tokens":2}}}}
JSON
  touch -m -r "$d1/rollout-write.jsonl" "$home/state/$id.status"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "codex cache-write harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"input_tokens":50' \
    "only the cached tokens codex counts inside input are subtracted (80-30)"
  assert_contains "$row" '"cached_input_tokens":55' \
    "cache_write is still counted in the cached column (30+25)"
  assert_contains "$row" '"output_tokens":6' "cache_write never touches the output column"
  pass "codex harvest: cache_write is folded into cached, never subtracted from input"
}

# --- candidate scanning is bound before the full parse ----------------------

# jq_trace_bin <dir> <trace-file> : a jq on PATH that records every session log
# handed to it as a FILE OPERAND before delegating to the real jq. The
# harvester's first-line cwd probe pipes its one line in on stdin, so a path in
# the trace means that whole file was parsed.
jq_trace_bin() {  # <dir> <trace-file>
  mkdir -p "$1"
  cat > "$1/jq" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *.jsonl) printf '%s\n' "\$a" >> "$2" ;;
  esac
done
exec "$REAL_JQ" "\$@"
SH
  chmod +x "$1/jq"
}

# A busy fleet leaves thousands of sibling sessions in the shared codex and pi
# trees, and the harvest runs synchronously inside teardown, so a candidate
# that the cwd binding will reject must be rejected from its first line rather
# than after a full parse of a large file.
prefilter_case() {
  local id wt data home d1 fb trace row out i

  id=usageprefiltercodex
  wt="$TMP_ROOT/wt-$id"
  data=$(harvest_case "$id" codex "$wt" default high)
  home=$(dirname "$data")
  export_harvest_env "$home"
  d1="$FM_USAGE_CODEX_DIR/2026/08/30"
  mkdir -p "$d1"
  cat > "$d1/rollout-match.jsonl" <<JSON
{"type":"session_meta","payload":{"cwd":"$wt"}}
{"type":"turn_context","payload":{"model":"glm-5.3"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"cached_input_tokens":0,"output_tokens":4,"reasoning_output_tokens":1}}}}
JSON
  # A large sibling session from another worktree in the same window.
  printf '{"type":"session_meta","payload":{"cwd":"/elsewhere"}}\n' > "$d1/rollout-sibling.jsonl"
  for i in $(seq 1 2000); do
    printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":%s,"output_tokens":1}}}}\n' "$i"
  done >> "$d1/rollout-sibling.jsonl"
  touch -m -r "$d1/rollout-match.jsonl" "$d1/rollout-sibling.jsonl"
  touch -m -r "$d1/rollout-match.jsonl" "$home/state/$id.status"

  fb="$TMP_ROOT/prefilter-fakebin"
  trace="$TMP_ROOT/prefilter-codex-trace"
  : > "$trace"
  jq_trace_bin "$fb" "$trace"
  out=$(PATH="$fb:$PATH" "$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "codex prefilter harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"input_tokens":30' "the matching codex session is still summed"
  assert_contains "$row" '"source":"codex-sessions"' "the matching codex session still names its source"
  assert_contains "$(cat "$trace")" "rollout-match.jsonl" \
    "the matching session is parsed in full"
  assert_not_contains "$(cat "$trace")" "rollout-sibling.jsonl" \
    "a sibling session from another worktree is rejected without being parsed"

  id=usageprefilterpi
  wt="$TMP_ROOT/wt-$id"
  data=$(harvest_case "$id" pi "$wt" default high)
  home=$(dirname "$data")
  export_harvest_env "$home"
  d1="$FM_USAGE_PI_DIR/--encoded-prefilter--"
  mkdir -p "$d1"
  cat > "$d1/session-match.jsonl" <<JSON
{"type":"session","version":3,"id":"sess-pf","cwd":"$wt"}
{"type":"message","id":"pf1","message":{"role":"assistant","provider":"zai","model":"glm-5.3-flash","usage":{"input":30,"output":4,"reasoning":1,"totalTokens":35}}}
JSON
  printf '{"type":"session","version":3,"id":"sess-other","cwd":"/elsewhere"}\n' \
    > "$d1/session-sibling.jsonl"
  for i in $(seq 1 2000); do
    printf '{"type":"message","id":"s%s","message":{"role":"assistant","usage":{"input":%s,"output":1}}}\n' "$i" "$i"
  done >> "$d1/session-sibling.jsonl"
  touch -m -r "$d1/session-match.jsonl" "$d1/session-sibling.jsonl"
  touch -m -r "$d1/session-match.jsonl" "$home/state/$id.status"

  trace="$TMP_ROOT/prefilter-pi-trace"
  : > "$trace"
  jq_trace_bin "$fb" "$trace"
  out=$(PATH="$fb:$PATH" "$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "pi prefilter harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"input_tokens":30' "the matching pi session is still summed"
  assert_contains "$row" '"source":"pi-sessions"' "the matching pi session still names its source"
  assert_contains "$(cat "$trace")" "session-match.jsonl" \
    "the matching pi session is parsed in full"
  assert_not_contains "$(cat "$trace")" "session-sibling.jsonl" \
    "a sibling pi session from another worktree is rejected without being parsed"
  pass "usage harvest: a non-matching sibling log is rejected before the full parse"
}

# --- spawn_gen: the task start survives a meta rewritten after the fact ------

# fm-spawn records spawn_gen=s<epoch>.<pid>.<random> once per incarnation and
# never rewrites it, while later meta writes (PR registration, busy-state
# updates) move the meta mtime forward to near the end of the task. Deriving
# the start from that mtime collapsed the window to zero and dropped every
# session log; the durable token must win.
spawn_gen_case() {
  local id=usagespawngen1 wt="$TMP_ROOT/.no-mistakes/wt-usagespawngen1"
  local data home state ledger row out base encoded logdir
  data=$(harvest_case "$id" claude "$wt" default default)
  home=$(dirname "$data")
  state="$home/state"
  export_harvest_env "$home"

  encoded=${wt//\//-}
  encoded=${encoded//./-}
  logdir="$FM_USAGE_CLAUDE_DIR/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/session.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgS","model":"claude-test","usage":{"input_tokens":42,"output_tokens":6}}}
JSON

  base=$(file_mtime_epoch "$state/$id.status")
  printf 'spawn_gen=s%s.4242.7\n' "$((base - 300))" >> "$state/$id.meta"
  # The worker's last status line lands at the end of the task; the meta is
  # then rewritten (PR registration), dragging its mtime up to the same point.
  touch -t "$(touch_stamp "$base")" "$state/$id.status"
  touch -t "$(touch_stamp "$base")" "$state/$id.meta"
  # A real request logged 200s into the task, inside the true window only.
  touch -t "$(touch_stamp $((base - 200)))" "$logdir/session.jsonl"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "spawn_gen harvest should succeed"$'\n'"$out"
  ledger="$data/usage-ledger.jsonl"
  row=$(cat "$ledger")
  assert_contains "$row" '"wall_secs":300' \
    "wall clock spans the spawn token epoch -> last status append"
  assert_contains "$row" "\"spawned_at\":\"$(iso_utc $((base - 300)))\"" \
    "spawned_at reports the spawn token epoch"
  assert_contains "$row" '"source":"claude-projects"' \
    "the durable window still covers the mid-task session log"
  assert_contains "$row" '"input_tokens":42' "the in-window request is summed"
  pass "usage harvest: spawn_gen is the durable start, immune to later meta writes"
}

# A spawn_gen token that is absent or malformed (a task spawned before the
# token existed, or a corrupt record) must fall back to the file-timestamp
# chain rather than producing a bogus start.
spawn_gen_malformed_case() {
  local id=usagespawngen2 wt="$TMP_ROOT/wt-usagespawngen2"
  local data home state ledger row out base
  data=$(harvest_case "$id" cursor "$wt" cursor-x "")
  home=$(dirname "$data")
  state="$home/state"
  export_harvest_env "$home"
  printf 'spawn_gen=not-a-token\n' >> "$state/$id.meta"
  base=$(file_mtime_epoch "$state/$id.status")
  touch -t "$(touch_stamp "$base")" "$state/$id.status"
  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "malformed spawn_gen harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" "\"completed_at\":\"$(iso_utc "$base")\"" \
    "malformed spawn_gen still reports the status-mtime end"
  assert_contains "$row" '"wall_secs":0' \
    "malformed spawn_gen falls back to the file-timestamp chain, never a bogus start"
  pass "usage harvest: a malformed spawn_gen falls back to file timestamps"
}

# A spawn token that postdates the last status append (a relaunch with no
# status line after it) must pin the start to the end, never invert the window.
spawn_gen_future_case() {
  local id=usagespawngen3 wt="$TMP_ROOT/wt-usagespawngen3"
  local data home state row out base
  data=$(harvest_case "$id" cursor "$wt" cursor-x "")
  home=$(dirname "$data")
  state="$home/state"
  export_harvest_env "$home"
  base=$(file_mtime_epoch "$state/$id.status")
  printf 'spawn_gen=s%s.1.1\n' "$((base + 600))" >> "$state/$id.meta"
  touch -t "$(touch_stamp "$base")" "$state/$id.status"
  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "future spawn_gen harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"wall_secs":0' "an impossible start never reports a negative duration"
  assert_contains "$row" "\"spawned_at\":\"$(iso_utc "$base")\"" \
    "an impossible start is pinned to the end, never postdating completed_at"
  pass "usage harvest: a start later than the end is pinned, not inverted"
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

# --- claude: the start chain on a host without usable birth time ------------

# A stat shim that reports no birth time (GNU statx unsupported returns 0 for
# %W) while still answering mtime, so the harvest has to resolve its start
# from the remaining chain rather than from the status file's birth.
# stat_shim_bin <dir> [<status-file> <birth-epoch>] : put a stat shim on PATH
# that answers mtime truthfully while controlling what the harvester reads for
# a birth time. With no birth argument every file reports no usable birth time
# (GNU statx unsupported returns 0 for %W), so the window must fall back; with
# one, only <status-file> reports <birth-epoch>. The %Y branch captures the two
# probes into separate assignments, exactly as the harvester's own
# file_mtime_epoch does, so the second read replaces the first's output instead
# of being appended to it (see bin/fm-watch.sh for why the shared-stdout
# `stat -f ... || stat -c ...` form writes a filesystem dump on Linux).
stat_shim_bin() {  # <dir> [<status-file> <birth-epoch>]
  local dir=$1 statusfile=${2:-} birth=${3:-}
  mkdir -p "$dir"
  cat > "$dir/stat" <<SH
#!/usr/bin/env bash
fmt=""; file=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -f) exit 1 ;;
    -c) fmt="\$2"; shift 2 ;;
    --) shift; file="\$1"; shift ;;
    *) file="\$1"; shift ;;
  esac
done
case "\$fmt" in
  %W)
    if [ -n "$statusfile" ] && [ "\$file" = "$statusfile" ]; then
      printf '%s\\n' "$birth"
    else
      printf '0\\n'
    fi
    ;;
  %Y)
    t=\$(/usr/bin/stat -f %m -- "\$file" 2>/dev/null) \\
      || t=\$(/usr/bin/stat -c %Y -- "\$file" 2>/dev/null) \\
      || exit 1
    printf '%s\\n' "\$t"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/stat"
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
  cat > "$logdir/session-before-meta.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgP","model":"claude-test","usage":{"input_tokens":555,"output_tokens":555}}}
JSON

  # No spawn_gen token and no usable birth time leaves the status mtime as the
  # only immutable start, so the window is the single instant [T, T]. The meta
  # is aged 100s to prove it is not a start source on any path: a window opened
  # from that mutable timestamp would swallow the pre-meta log below, and a
  # meta rewritten to AFTER the last status append would instead collapse the
  # window forward and drop the real one.
  base=$(file_mtime_epoch "$state/$id.status")
  touch -t "$(touch_stamp "$base")" "$state/$id.status"
  touch -t "$(touch_stamp $((base - 100)))" "$state/$id.meta"
  touch -t "$(touch_stamp "$base")" "$logdir/session.jsonl"
  touch -t "$(touch_stamp $((base - 50)))" "$logdir/session-before-meta.jsonl"

  fb="$TMP_ROOT/nobirth-fakebin"
  stat_shim_bin "$fb"
  out=$(PATH="$fb:$PATH" "$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "birthless claude harvest should succeed"$'\n'"$out"
  ledger="$data/usage-ledger.jsonl"
  row=$(cat "$ledger")
  assert_contains "$row" '"source":"claude-projects"' \
    "the birthless window still matches the log written at the status instant"
  assert_contains "$row" '"input_tokens":12' \
    "only the in-window request is summed, not the one predating the status mtime"
  assert_contains "$row" '"wall_secs":0' \
    "a birthless start rests on the status mtime, never on the mutable meta mtime"
  assert_contains "$row" "\"spawned_at\":\"$(iso_utc "$base")\"" \
    "spawned_at is the status mtime, not the older meta mtime"
  assert_contains "$row" "\"completed_at\":\"$(iso_utc "$base")\"" \
    "completed_at is the last status append"
  pass "claude harvest: a birthless host never falls back to the mutable meta mtime"
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

# A task id is reusable: teardown retires the task's records and a later spawn
# may take the same id. The ledger's identity is therefore the task plus its
# spawn_gen incarnation token, so a teardown rerun is still deduped while a
# genuinely new spawn earns its own row. Keyed on the id alone, the second
# incarnation's whole cost record was silently dropped.
reused_task_id_case() {
  local id=usagereuse1 wt="$TMP_ROOT/wt-usagereuse1"
  local data home state ledger out base rows
  data=$(harvest_case "$id" cursor "$wt" cursor-x "")
  home=$(dirname "$data")
  state="$home/state"
  export_harvest_env "$home"
  ledger="$data/usage-ledger.jsonl"
  base=$(file_mtime_epoch "$state/$id.status")
  printf 'spawn_gen=s%s.11.1\n' "$((base - 300))" >> "$state/$id.meta"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "first incarnation harvest should succeed"$'\n'"$out"
  assert_contains "$(cat "$ledger")" "\"spawn_gen\":\"s$((base - 300)).11.1\"" \
    "the row records the incarnation it measured"
  # Same incarnation again, as a teardown rerun does: still exactly one row.
  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "a rerun of the same incarnation should succeed"$'\n'"$out"
  [ "$(wc -l < "$ledger" | tr -d ' ')" = 1 ] \
    || fail "a rerun of the same incarnation duplicated its row"

  # The id is spawned again later, which fm-spawn records as a new spawn_gen.
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$TMP_ROOT/proj-$id" "harness=cursor" "kind=ship" "mode=no-mistakes" \
    "model=cursor-x" "effort="
  printf 'spawn_gen=s%s.22.2\n' "$base" >> "$state/$id.meta"
  printf 'working: second incarnation\n' > "$state/$id.status"
  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "second incarnation harvest should succeed"$'\n'"$out"
  [ "$(wc -l < "$ledger" | tr -d ' ')" = 2 ] \
    || fail "a reused task id did not get its own row"$'\n'"$(cat "$ledger")"
  rows=$(jq -r '.spawn_gen' "$ledger" | sort | tr '\n' ' ')
  [ "$rows" = "s$((base - 300)).11.1 s$base.22.2 " ] \
    || fail "the two incarnations are not recorded separately: [$rows]"
  [ "$(jq -r '.task' "$ledger" | sort -u)" = "$id" ] \
    || fail "the two rows do not share the reused task id"
  pass "usage harvest: a reused task id records each incarnation once"
}

# A row written before the ledger carried spawn_gen omits the key entirely, and
# a task whose meta has no spawn_gen writes null. Both read as an absent
# generation, which matches only another absent one.
legacy_ledger_row_case() {
  local id=usagelegacy1 wt="$TMP_ROOT/wt-usagelegacy1"
  local data home state ledger out base
  data=$(harvest_case "$id" cursor "$wt" cursor-x "")
  home=$(dirname "$data")
  state="$home/state"
  export_harvest_env "$home"
  ledger="$data/usage-ledger.jsonl"
  mkdir -p "$data"
  printf '%s\n' \
    "{\"task\":\"$id\",\"harness\":\"cursor\",\"model\":\"cursor-x\",\"effort\":null,\"spawned_at\":null,\"completed_at\":null,\"wall_secs\":7,\"turns\":1,\"input_tokens\":null,\"cached_input_tokens\":null,\"output_tokens\":null,\"reasoning_tokens\":null,\"source\":\"unavailable\"}" \
    > "$ledger"

  # The same generation-less task: the legacy row still blocks a re-harvest.
  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "harvest against a legacy row should succeed"$'\n'"$out"
  [ "$(wc -l < "$ledger" | tr -d ' ')" = 1 ] \
    || fail "a legacy row did not block a re-harvest of that same task"$'\n'"$(cat "$ledger")"

  # A later spawn of the same id does carry a token, so it is not blocked.
  base=$(file_mtime_epoch "$state/$id.status")
  printf 'spawn_gen=s%s.33.3\n' "$base" >> "$state/$id.meta"
  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "harvest of a new incarnation should succeed"$'\n'"$out"
  [ "$(wc -l < "$ledger" | tr -d ' ')" = 2 ] \
    || fail "a legacy row blocked a genuinely new incarnation"$'\n'"$(cat "$ledger")"
  assert_contains "$(tail -1 "$ledger")" "\"spawn_gen\":\"s$base.33.3\"" \
    "the new incarnation's row carries its own token"
  pass "usage harvest: an absent generation matches only another absent one"
}

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

# The ledger's harness field is null when a task record carries no harness=
# line, and the report must keep every later column in its own slot rather
# than shifting the model, effort and token columns one place left.
report_no_harness_case() {
  local id=usagenoharness1 wt="$TMP_ROOT/wt-usagenoharness1"
  local home ledger out fields
  home="$TMP_ROOT/home-$id"
  mkdir -p "$home/state" "$home/data"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "model=nohar-model" "effort=default"
  printf 'working: started\n' > "$home/state/$id.status"
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$HARVEST" "$id" >/dev/null 2>&1 || fail "harness-less harvest failed"
  ledger="$home/data/usage-ledger.jsonl"
  assert_contains "$(cat "$ledger")" '"harness":null' \
    "an absent harness is recorded as null, like an absent model or effort"

  out=$(FM_DATA_OVERRIDE="$home/data" "$REPORT" 2>&1)
  expect_code 0 "$?" "report of a harness-less row should succeed"$'\n'"$out"
  fields=$(printf '%s\n' "$out" | awk -v t="$id" '$1 == t {print NF"|"$3"|"$4"|"$NF}')
  [ "$fields" = "11|-|nohar-model|unavailable" ] \
    || fail "report shifted the harness-less row's columns: [$fields]"
  pass "usage report: an absent harness renders as a placeholder without shifting columns"
}

report_case() {
  local out ledger
  ledger="$TMP_ROOT/home-usageclaude1/data/usage-ledger.jsonl"
  {
    cat "$TMP_ROOT/home-usagecodex1/data/usage-ledger.jsonl"
    cat "$TMP_ROOT/home-usagepi1/data/usage-ledger.jsonl"
    cat "$TMP_ROOT/home-usagecursor1/data/usage-ledger.jsonl"
  } >> "$ledger"
  out=$(FM_DATA_OVERRIDE="$(dirname "$ledger")" "$REPORT" 2>&1)
  expect_code 0 "$?" "report should succeed"$'\n'"$out"
  assert_contains "$out" "usage ledger: $ledger (4 rows)" "report names the ledger and row count"
  assert_contains "$out" "per-model totals" "report prints per-model totals"
  assert_contains "$out" "claude-test" "report lists the claude model"
  assert_contains "$out" "glm-5.3" "report lists the codex model"
  assert_contains "$out" "zai/glm-5.3-flash" "report lists the provider-qualified pi model"
  assert_contains "$out" "usagepi1" "report lists the pi task row"
  assert_contains "$out" "usageclaude1" "report lists each task row"
  assert_contains "$out" "usagecursor1" "report lists the unavailable task row"
  assert_contains "$out" "unavailable" "report shows the unavailable source"
  # Missing ledger exits 0 with a note.
  out=$(FM_DATA_OVERRIDE="$TMP_ROOT/empty-home" "$REPORT" 2>&1)
  expect_code 0 "$?" "report without a ledger should exit 0"
  assert_contains "$out" "no usage ledger" "report names the missing ledger"
  pass "usage report: per-model totals, per-task rows, missing-ledger tolerance"
}

# The per-model section groups on the model and sums each token column, so the
# numbers themselves are the contract. A ledger written here by hand pins them
# exactly: two tasks share one model across two different harnesses, a third
# task carries another model, and a fourth is source-unavailable.
report_model_totals_case() {
  local home ledger out fields
  home="$TMP_ROOT/home-usagetotals"
  mkdir -p "$home/data"
  ledger="$home/data/usage-ledger.jsonl"
  cat > "$ledger" <<'JSON'
{"task":"agg1","harness":"claude","model":"agg-model","effort":null,"spawned_at":null,"completed_at":null,"wall_secs":100,"turns":2,"input_tokens":10,"cached_input_tokens":20,"output_tokens":30,"reasoning_tokens":4,"source":"claude-projects"}
{"task":"agg2","harness":"codex","model":"agg-model","effort":"high","spawned_at":null,"completed_at":null,"wall_secs":200,"turns":1,"input_tokens":1,"cached_input_tokens":2,"output_tokens":3,"reasoning_tokens":1,"source":"codex-sessions"}
{"task":"agg3","harness":"claude","model":"other-model","effort":null,"spawned_at":null,"completed_at":null,"wall_secs":7,"turns":1,"input_tokens":5,"cached_input_tokens":6,"output_tokens":7,"reasoning_tokens":8,"source":"claude-projects"}
{"task":"agg4","harness":"cursor","model":"agg-model","effort":null,"spawned_at":null,"completed_at":null,"wall_secs":900,"turns":1,"input_tokens":null,"cached_input_tokens":null,"output_tokens":null,"reasoning_tokens":null,"source":"unavailable"}
JSON
  out=$(FM_DATA_OVERRIDE="$home/data" "$REPORT" 2>&1)
  expect_code 0 "$?" "report of the totals ledger should succeed"$'\n'"$out"

  # model tasks input cached output reasoning wall_secs, in that order.
  fields=$(printf '%s\n' "$out" | awk '$1 == "agg-model" {print $2"|"$3"|"$4"|"$5"|"$6"|"$7}')
  [ "$fields" = "2|11|22|33|5|300" ] \
    || fail "per-model totals for agg-model are wrong: [$fields]"
  fields=$(printf '%s\n' "$out" | awk '$1 == "other-model" {print $2"|"$3"|"$4"|"$5"|"$6"|"$7}')
  [ "$fields" = "1|5|6|7|8|7" ] \
    || fail "per-model totals for other-model are wrong: [$fields]"

  # Both agg-model rows still appear per task, so the grouping folded them
  # rather than the report dropping one.
  assert_contains "$out" "agg1" "the per-task section still lists the first task"
  assert_contains "$out" "agg2" "the per-task section still lists the second task"
  assert_contains "$out" "agg4" "the per-task section still lists the unavailable task"

  # A reused task id is two incarnations, so it is two rows: the per-task
  # section lists both and the per-model section sums both rather than
  # collapsing them onto one id.
  # The LATER incarnation is written first, so a report that merely echoed
  # append order would list the runs backwards.
  cat > "$ledger" <<'JSON'
{"task":"agg9","spawn_gen":"s1000000999.2.2","harness":"claude","model":"reuse-model","effort":null,"spawned_at":"2026-02-02T02:02:02Z","completed_at":null,"wall_secs":20,"turns":2,"input_tokens":30,"cached_input_tokens":40,"output_tokens":50,"reasoning_tokens":60,"source":"claude-projects"}
{"task":"agg9","spawn_gen":"s1000000001.1.1","harness":"claude","model":"reuse-model","effort":null,"spawned_at":"2026-01-01T01:01:01Z","completed_at":null,"wall_secs":10,"turns":1,"input_tokens":3,"cached_input_tokens":4,"output_tokens":5,"reasoning_tokens":6,"source":"claude-projects"}
JSON
  out=$(FM_DATA_OVERRIDE="$home/data" "$REPORT" 2>&1)
  expect_code 0 "$?" "report of a reused task id should succeed"$'\n'"$out"
  fields=$(printf '%s\n' "$out" | awk '$1 == "reuse-model" {print $2"|"$3"|"$4"|"$5"|"$6"|"$7}')
  [ "$fields" = "2|33|44|55|66|30" ] \
    || fail "per-model totals collapsed or mis-summed a reused id: [$fields]"
  [ "$(printf '%s\n' "$out" | awk '$1 == "agg9"' | wc -l | tr -d ' ')" = 2 ] \
    || fail "the per-task section did not list both incarnations of a reused id"$'\n'"$out"
  # Each run is told apart by when it started, earliest first.
  fields=$(printf '%s\n' "$out" | awk '$1 == "agg9" {print $2}' | tr '\n' ' ')
  [ "$fields" = "2026-01-01T01:01:01Z 2026-02-02T02:02:02Z " ] \
    || fail "the reused id's runs are indistinguishable or out of order: [$fields]"
  fields=$(printf '%s\n' "$out" | awk '$1 == "agg9" {print $6}' | tr '\n' ' ')
  [ "$fields" = "3 30 " ] \
    || fail "the reused id's rows do not carry each run's own usage: [$fields]"
  pass "usage report: per-model rows group on the model and sum each column"
}

# A ledger line that jq cannot parse must fail the report loudly. Reporting
# exit 0 with a physical row count above empty sections presents a truncated
# fleet cost picture as a complete one.
report_malformed_case() {
  local home ledger out status
  home="$TMP_ROOT/home-usagemalformed"
  mkdir -p "$home/data"
  ledger="$home/data/usage-ledger.jsonl"
  printf '{"task":"usagegood1","model":"good-model","source":"claude","input_tokens":7}\n' > "$ledger"
  printf '{"task": truncated\n' >> "$ledger"

  out=$(FM_DATA_OVERRIDE="$home/data" "$REPORT" 2>&1)
  status=$?
  expect_code 1 "$status" "report of an unparseable ledger should fail"$'\n'"$out"
  assert_contains "$out" "$ledger" "the failure names the offending ledger"
  assert_not_contains "$out" "per-task rows" \
    "a failed report must not print sections it could not compute"
  assert_not_contains "$out" "2 rows" \
    "a failed report must not present a physical row count as a result"

  # The same ledger without the truncated line still reports normally, so the
  # failure is the parse error and not the new pre-render step.
  printf '{"task":"usagegood1","model":"good-model","source":"claude","input_tokens":7}\n' > "$ledger"
  out=$(FM_DATA_OVERRIDE="$home/data" "$REPORT" 2>&1)
  expect_code 0 "$?" "report of a parseable ledger should still succeed"$'\n'"$out"
  assert_contains "$out" "good-model" "the repaired ledger still renders its model row"
  pass "usage report: an unparseable ledger fails loudly instead of reporting empty sections"
}

# --- teardown integration: the harvest still sees the task status log -------

# Teardown deletes state/<id>.status when it retires the task's status
# presentation. The harvest has to run before that, or it loses both the task
# window and the turn count and every row degrades to a zero-duration,
# zero-turn, source-unavailable line.
teardown_status_case() {
  local proj wt id fb state data config out row
  id=usageharvtd2
  proj="$TMP_ROOT/td2-proj"; wt="$TMP_ROOT/td2-wt"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fb="$TMP_ROOT/td2-fakebin"
  mkdir -p "$fb"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/treehouse"
  chmod +x "$fb/tmux" "$fb/treehouse"
  state="$TMP_ROOT/td2-state"; config="$TMP_ROOT/td2-config"; data="$TMP_ROOT/td2-data"
  mkdir -p "$state" "$config" "$data/$id"
  printf 'scout findings\n' > "$data/$id/report.md"
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "harness=claude" \
    "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="
  {
    printf 'working: scouting\n'
    printf 'working: still scouting\n'
    printf 'done: report written\n'
  } > "$state/$id.status"
  # A spawn 500s before the last status append, and a meta rewritten right at
  # the end, exactly as a real PR registration leaves it.
  local base
  base=$(file_mtime_epoch "$state/$id.status")
  printf 'spawn_gen=s%s.99.3\n' "$((base - 500))" >> "$state/$id.meta"
  touch -t "$(touch_stamp "$base")" "$state/$id.meta"

  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_USAGE_CLAUDE_DIR="$TMP_ROOT/td2-fake-claude" FM_USAGE_CODEX_DIR="$TMP_ROOT/td2-fake-codex" \
    FM_USAGE_PI_DIR="$TMP_ROOT/td2-fake-pi" \
    "$TEARDOWN" "$id" 2>&1)
  expect_code 0 "$?" "teardown should succeed"$'\n'"$out"
  assert_contains "$out" "teardown $id complete" "teardown completes"
  [ ! -e "$state/$id.status" ] || fail "teardown left the status log behind"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"turns":2' \
    "the harvest counted the status log's working lines before teardown removed it"
  assert_contains "$row" '"wall_secs":500' \
    "the harvest measured the task window before teardown removed the status log"
  pass "teardown integration: the harvest runs while the status log still exists"
}

# --- teardown integration: harvest failure never blocks teardown ------------

# A forced secondmate teardown retires that home's crewmate children and then
# removes the home itself. Those children ran on this filesystem, so their
# usage is harvestable, but only until their status log is retired with them.
# The row lands in the ledger of the home running the teardown, which is the
# one that outlives the child home.
teardown_child_case() {
  local id=usageharvsm1 child=usageharvsmchild1 fb state data config smhome out row
  local wt encoded logdir now
  fb="$TMP_ROOT/sm-fakebin"
  mkdir -p "$fb"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/treehouse"
  chmod +x "$fb/tmux" "$fb/treehouse"
  state="$TMP_ROOT/sm-state"; config="$TMP_ROOT/sm-config"; data="$TMP_ROOT/sm-data"
  smhome="$TMP_ROOT/sm-home"
  mkdir -p "$state" "$config" "$data" "$smhome/state" "$smhome/data" "$smhome/config"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  mkdir -p "$TMP_ROOT/sm-proj"
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$smhome" "project=$TMP_ROOT/sm-proj" \
    "home=$smhome" "kind=secondmate" "mode=no-mistakes"
  printf 'working: routing\n' > "$state/$id.status"

  # The child crewmate task inside that secondmate home, with its own claude
  # session log. Its worktree is already gone, as it is by teardown time.
  wt="$TMP_ROOT/.no-mistakes/wt-$child"
  fm_write_meta "$smhome/state/$child.meta" \
    "window=firstmate:fm-$child" "worktree=$wt" "project=$TMP_ROOT/sm-proj" "harness=claude" \
    "kind=ship" "mode=no-mistakes" "model=default" "effort=default"
  {
    printf 'working: started\n'
    printf 'done: landed\n'
  } > "$smhome/state/$child.status"
  encoded=${wt//\//-}
  encoded=${encoded//./-}
  logdir="$TMP_ROOT/sm-fake-claude/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/session.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgSM","model":"claude-child","usage":{"input_tokens":23,"output_tokens":4}}}
JSON
  now=$(date +%s)
  printf 'spawn_gen=s%s.77.1\n' "$((now - 300))" >> "$smhome/state/$child.meta"
  touch -t "$(touch_stamp $((now - 30)))" "$smhome/state/$child.status"
  touch -t "$(touch_stamp $((now - 20)))" "$logdir/session.jsonl"

  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_USAGE_CLAUDE_DIR="$TMP_ROOT/sm-fake-claude" FM_USAGE_CODEX_DIR="$TMP_ROOT/sm-fake-codex" \
    FM_USAGE_PI_DIR="$TMP_ROOT/sm-fake-pi" \
    "$TEARDOWN" "$id" --force 2>&1)
  expect_code 0 "$?" "forced secondmate teardown should succeed"$'\n'"$out"
  [ ! -e "$smhome/state/$child.status" ] \
    || fail "the child's status log outlived the forced cleanup"
  row=$(grep -F "\"task\":\"$child\"" "$data/usage-ledger.jsonl" 2>/dev/null || true)
  [ -n "$row" ] || fail "the secondmate's child task left no ledger row"$'\n'"$out"
  assert_contains "$row" '"source":"claude-projects"' \
    "the child row is harvested from the child's own session log"
  assert_contains "$row" '"input_tokens":23' "the child row carries the child's usage"
  assert_contains "$row" '"turns":1' \
    "the child row is read from the child home's own status log"
  pass "teardown integration: a secondmate's children are harvested before they retire"
}

# The log scan reaches the harvest instant, and what keeps that bound safe is
# that teardown harvests while the task still holds its pooled worktree. A
# treehouse shim writes the NEXT occupant's session log into the same encoded
# project directory at the moment the worktree is returned to the pool, which
# is exactly the reachable window a harvest running after the return would
# absorb: those tokens must not appear in this task's row. The second run
# proves the harvest stays best effort in its new position, where a failure
# could otherwise abort teardown before the worktree is ever returned.
# One teardown harvests every task in every home it recurses through, and a
# task id is unique only within its own home's state directory. A secondmate
# child whose own home holds a grandchild with the SAME id therefore stages two
# different rows, and the recursion into that nested home runs between the
# outer child's scan and its append. Keyed on the id alone, the grandchild's
# row overwrites the outer child's staged file, the identity guard then finds
# the grandchild's row already present and skips, and the outer child's
# measured usage is lost while its records retire.
teardown_nested_child_case() {
  local id=usageharvsm2 child=usageharvsmshared fb state data config smhome gchome out
  local wt gwt encoded logdir now rows
  fb="$TMP_ROOT/nest-fakebin"
  mkdir -p "$fb"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/treehouse"
  chmod +x "$fb/tmux" "$fb/treehouse"
  state="$TMP_ROOT/nest-state"; config="$TMP_ROOT/nest-config"; data="$TMP_ROOT/nest-data"
  smhome="$TMP_ROOT/nest-home"; gchome="$TMP_ROOT/nest-home-inner"
  mkdir -p "$state" "$config" "$data" "$smhome/state" "$smhome/data" "$smhome/config" \
    "$gchome/state" "$gchome/data" "$gchome/config" "$TMP_ROOT/nest-proj"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '%s\n' "$child" > "$gchome/.fm-secondmate-home"
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$smhome" "project=$TMP_ROOT/nest-proj" \
    "home=$smhome" "kind=secondmate" "mode=no-mistakes"
  printf 'working: routing\n' > "$state/$id.status"

  now=$(date +%s)
  # The outer child is itself a secondmate, so the cleanup recurses into its
  # home between that child's scan and its append.
  wt="$TMP_ROOT/.no-mistakes/wt-outer-$child"
  fm_write_meta "$smhome/state/$child.meta" \
    "window=firstmate:fm-$child" "worktree=$wt" "project=$TMP_ROOT/nest-proj" \
    "harness=claude" "home=$gchome" "kind=secondmate" "mode=no-mistakes" \
    "model=default" "effort=default"
  printf 'spawn_gen=s%s.81.1\n' "$((now - 400))" >> "$smhome/state/$child.meta"
  printf 'working: outer child\n' > "$smhome/state/$child.status"

  # The grandchild shares the outer child's task id, which is legal because it
  # lives in a different home's state directory.
  gwt="$TMP_ROOT/.no-mistakes/wt-inner-$child"
  fm_write_meta "$gchome/state/$child.meta" \
    "window=firstmate:fm-$child" "worktree=$gwt" "project=$TMP_ROOT/nest-proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "model=default" "effort=default"
  printf 'spawn_gen=s%s.82.2\n' "$((now - 300))" >> "$gchome/state/$child.meta"
  printf 'working: grandchild\n' > "$gchome/state/$child.status"

  encoded=${wt//\//-}
  encoded=${encoded//./-}
  logdir="$TMP_ROOT/nest-fake-claude/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/session.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgOUT","model":"claude-outer","usage":{"input_tokens":41,"output_tokens":5}}}
JSON
  touch -t "$(touch_stamp $((now - 20)))" "$logdir/session.jsonl"
  encoded=${gwt//\//-}
  encoded=${encoded//./-}
  logdir="$TMP_ROOT/nest-fake-claude/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/session.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgIN","model":"claude-inner","usage":{"input_tokens":77,"output_tokens":6}}}
JSON
  touch -t "$(touch_stamp $((now - 20)))" "$logdir/session.jsonl"
  touch -t "$(touch_stamp $((now - 30)))" "$smhome/state/$child.status"
  touch -t "$(touch_stamp $((now - 30)))" "$gchome/state/$child.status"

  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_USAGE_CLAUDE_DIR="$TMP_ROOT/nest-fake-claude" FM_USAGE_CODEX_DIR="$TMP_ROOT/nest-fake-codex" \
    FM_USAGE_PI_DIR="$TMP_ROOT/nest-fake-pi" \
    "$TEARDOWN" "$id" --force 2>&1)
  expect_code 0 "$?" "nested forced secondmate teardown should succeed"$'\n'"$out"
  rows=$(grep -cF "\"task\":\"$child\"" "$data/usage-ledger.jsonl" 2>/dev/null || true)
  [ "$rows" = 2 ] \
    || fail "the two same-named tasks did not both reach the ledger: [$rows]"$'\n'"$(cat "$data/usage-ledger.jsonl" 2>/dev/null)"$'\n'"$out"
  assert_contains "$(cat "$data/usage-ledger.jsonl")" '"input_tokens":41' \
    "the outer child's own usage survived the recursion into the nested home"
  assert_contains "$(cat "$data/usage-ledger.jsonl")" '"input_tokens":77' \
    "the grandchild's own usage is recorded too"
  pass "teardown integration: a nested home's same-named task cannot overwrite its parent's row"
}

# The nested host-local teardown of a remote secondmate runs on the far host
# with its state and data overridden into that home's own parent-route
# directories (bin/fm-remote-secondmate-control.sh retire owns those paths), so
# the home it removes is the one holding its own ledger. The append phase must
# be skipped there: the harvester creates its data directory on append, so
# appending after the removal resurrects the home that was just retired. The
# surviving parent teardown is what records such a task. The scan still stages
# a row, so the skip shows only as the home staying gone.
teardown_remote_nested_home_case() {
  local id=usageharvself1 fb home state data config wt out encoded logdir now
  fb="$TMP_ROOT/self-fakebin"
  mkdir -p "$fb"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"
  chmod +x "$fb/tmux"
  home="$TMP_ROOT/self-home"; config="$TMP_ROOT/self-config"
  state="$home/state/parent-route"; data="$home/data/.parent-route"
  mkdir -p "$state" "$data" "$config" "$TMP_ROOT/self-proj"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  wt="$TMP_ROOT/.no-mistakes/wt-$id"
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$TMP_ROOT/self-proj" \
    "harness=claude" "home=$home" "kind=secondmate" "mode=no-mistakes" \
    "model=default" "effort=default"
  now=$(date +%s)
  printf 'spawn_gen=s%s.91.1\n' "$((now - 400))" >> "$state/$id.meta"
  printf 'working: nested remote secondmate\n' > "$state/$id.status"
  touch -t "$(touch_stamp $((now - 30)))" "$state/$id.status"

  # A real log, so the scan stages a non-empty row and only the append is
  # skipped.
  encoded=${wt//\//-}
  encoded=${encoded//./-}
  logdir="$TMP_ROOT/self-fake-claude/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/session.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgSELF","model":"claude-self","usage":{"input_tokens":31,"output_tokens":4}}}
JSON
  touch -t "$(touch_stamp $((now - 20)))" "$logdir/session.jsonl"

  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_USAGE_CLAUDE_DIR="$TMP_ROOT/self-fake-claude" FM_USAGE_CODEX_DIR="$TMP_ROOT/self-fake-codex" \
    FM_USAGE_PI_DIR="$TMP_ROOT/self-fake-pi" \
    "$TEARDOWN" "$id" --force 2>&1)
  expect_code 0 "$?" "nested remote secondmate teardown should succeed"$'\n'"$out"
  [ ! -e "$home" ] \
    || fail "the append resurrected the retired secondmate home: [$(find "$home" | tr '\n' ' ')]"$'\n'"$out"
  pass "teardown integration: the append never resurrects the home holding its own ledger"
}

teardown_pool_order_case() {
  local proj wt id fb state data config out row occupant thlog encoded logdir base
  id=usageharvpool1
  proj="$TMP_ROOT/pool-proj"; wt="$TMP_ROOT/pool-wt"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  encoded=${wt//\//-}
  encoded=${encoded//./-}
  logdir="$TMP_ROOT/pool-fake-claude/$encoded"
  mkdir -p "$logdir"
  occupant="$logdir/session-next-occupant.jsonl"
  thlog="$TMP_ROOT/pool-treehouse.log"
  fb="$TMP_ROOT/pool-fakebin"
  mkdir -p "$fb"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"
  cat > "$fb/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$thlog"
case "\$1" in
  return)
    # The pool hands this slot to another task, which starts writing its own
    # session log under the same encoded project directory.
    printf '%s\\n' '{"type":"assistant","message":{"id":"msgOC","model":"next-occupant-model","usage":{"input_tokens":999,"output_tokens":999}}}' \\
      > "$occupant"
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux" "$fb/treehouse"
  state="$TMP_ROOT/pool-state"; config="$TMP_ROOT/pool-config"; data="$TMP_ROOT/pool-data"
  mkdir -p "$state" "$config" "$data/$id"
  printf 'scout findings\n' > "$data/$id/report.md"
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "harness=claude" \
    "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="
  {
    printf 'working: scouting\n'
    printf 'done: report written\n'
  } > "$state/$id.status"
  cat > "$logdir/session-own.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgOWN","model":"claude-own","usage":{"input_tokens":31,"output_tokens":6}}}
JSON
  base=$(file_mtime_epoch "$state/$id.status")
  printf 'spawn_gen=s%s.55.2\n' "$((base - 500))" >> "$state/$id.meta"
  touch -t "$(touch_stamp $((base - 100)))" "$logdir/session-own.jsonl"

  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_USAGE_CLAUDE_DIR="$TMP_ROOT/pool-fake-claude" FM_USAGE_CODEX_DIR="$TMP_ROOT/pool-fake-codex" \
    FM_USAGE_PI_DIR="$TMP_ROOT/pool-fake-pi" \
    "$TEARDOWN" "$id" 2>&1)
  expect_code 0 "$?" "pool-order teardown should succeed"$'\n'"$out"
  [ -f "$occupant" ] || fail "the treehouse shim never returned the worktree to the pool"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"source":"claude-projects"' "the task's own log was harvested"
  assert_contains "$row" '"input_tokens":31' \
    "the next occupant of the returned worktree is not summed into this row"
  assert_contains "$row" '"model":"claude-own"' \
    "the next occupant's model does not become this task's model"

  # Failure mode one, on the FAR side of the return: the append cannot write.
  # It proves the append is best effort; it says nothing about the return,
  # which has already happened by then.
  id=usageharvpool2
  proj="$TMP_ROOT/pool2-proj"; wt="$TMP_ROOT/pool2-wt"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  : > "$thlog"
  data="$TMP_ROOT/pool2-data"
  # The ledger path is a directory, so every append fails.
  mkdir -p "$data/$id" "$data/usage-ledger.jsonl"
  printf 'scout findings\n' > "$data/$id/report.md"
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "harness=claude" \
    "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="
  printf 'working: scouting\n' > "$state/$id.status"
  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_USAGE_CLAUDE_DIR="$TMP_ROOT/pool-fake-claude" FM_USAGE_CODEX_DIR="$TMP_ROOT/pool-fake-codex" \
    FM_USAGE_PI_DIR="$TMP_ROOT/pool-fake-pi" \
    "$TEARDOWN" "$id" 2>&1)
  expect_code 0 "$?" "teardown must survive a failing append"$'\n'"$out"
  assert_contains "$out" "warning: usage harvest for $id failed" \
    "a failing append warns rather than aborting teardown"

  # Failure mode two, on the NEAR side of the return: the SCAN itself fails,
  # because staging cannot be created. This is the half that can actually block
  # the worktree return, so it is the half that has to be proven.
  id=usageharvpool3
  proj="$TMP_ROOT/pool3-proj"; wt="$TMP_ROOT/pool3-wt"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  thlog="$TMP_ROOT/pool3-treehouse.log"
  : > "$thlog"
  fb="$TMP_ROOT/pool3-fakebin"
  mkdir -p "$fb"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"
  cat > "$fb/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$thlog"
exit 0
SH
  # Only the usage-staging directory fails to be created; every other mktemp
  # caller in teardown is passed through untouched.
  cat > "$fb/mktemp" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in *fm-usage-stage.XXXXXX) exit 1 ;; esac
done
exec "$REAL_MKTEMP" "\$@"
SH
  chmod +x "$fb/tmux" "$fb/treehouse" "$fb/mktemp"
  data="$TMP_ROOT/pool3-data"
  mkdir -p "$data/$id"
  printf 'scout findings\n' > "$data/$id/report.md"
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "harness=claude" \
    "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="
  printf 'working: scouting\n' > "$state/$id.status"
  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_USAGE_CLAUDE_DIR="$TMP_ROOT/pool-fake-claude" FM_USAGE_CODEX_DIR="$TMP_ROOT/pool-fake-codex" \
    FM_USAGE_PI_DIR="$TMP_ROOT/pool-fake-pi" \
    "$TEARDOWN" "$id" 2>&1)
  expect_code 0 "$?" "teardown must survive a failing scan"$'\n'"$out"
  assert_contains "$out" "warning: usage harvest for $id failed" \
    "a failing scan warns rather than aborting teardown"
  grep -q '^return' "$thlog" \
    || fail "a failing scan blocked the worktree return"$'\n'"$(cat "$thlog")"
  [ ! -s "$data/usage-ledger.jsonl" ] || fail "a failing scan still produced a row"
  pass "teardown integration: neither harvest phase can block the worktree return"
}

# Teardown's refusals exit while deliberately retaining the task's records so
# the operator can rerun, and the ledger's idempotency guard means a row
# written before those refusals could never be corrected by that rerun. So an
# aborted teardown must leave no row at all, and the rerun must MEASURE the
# task again rather than replay whatever the aborted attempt had computed.
teardown_refusal_case() {
  local proj wt id fb state data config out status row encoded logdir base failflag tmp
  id=usageharvrefuse1
  proj="$TMP_ROOT/refuse-proj"; wt="$TMP_ROOT/refuse-wt"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  encoded=${wt//\//-}
  encoded=${encoded//./-}
  logdir="$TMP_ROOT/refuse-fake-claude/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/session.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgRF","model":"claude-refuse","usage":{"input_tokens":17,"output_tokens":2}}}
JSON
  # The worktree return refuses while this flag exists, which is one of
  # teardown's fail-closed exits.
  failflag="$TMP_ROOT/refuse-treehouse-fails"
  : > "$failflag"
  fb="$TMP_ROOT/refuse-fakebin"
  mkdir -p "$fb"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"
  cat > "$fb/treehouse" <<SH
#!/usr/bin/env bash
if [ "\$1" = return ] && [ -e "$failflag" ]; then
  echo "treehouse: pool return refused" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$fb/tmux" "$fb/treehouse"
  state="$TMP_ROOT/refuse-state"; config="$TMP_ROOT/refuse-config"; data="$TMP_ROOT/refuse-data"
  mkdir -p "$state" "$config" "$data/$id"
  printf 'scout findings\n' > "$data/$id/report.md"
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "harness=claude" \
    "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="
  printf 'working: scouting\n' > "$state/$id.status"
  base=$(file_mtime_epoch "$state/$id.status")
  printf 'spawn_gen=s%s.66.1\n' "$((base - 400))" >> "$state/$id.meta"
  touch -t "$(touch_stamp $((base - 100)))" "$logdir/session.jsonl"

  # Teardown gets its own TMPDIR so the staging directory it creates for the
  # scan phase is observable: it must not outlive the run, aborted or not.
  tmp="$TMP_ROOT/refuse-tmp"
  mkdir -p "$tmp"
  out=$(PATH="$fb:$PATH" TMPDIR="$tmp" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_USAGE_CLAUDE_DIR="$TMP_ROOT/refuse-fake-claude" FM_USAGE_CODEX_DIR="$TMP_ROOT/refuse-fake-codex" \
    FM_USAGE_PI_DIR="$TMP_ROOT/refuse-fake-pi" \
    "$TEARDOWN" "$id" 2>&1)
  status=$?
  expect_code 1 "$status" "a refused worktree return must abort teardown"$'\n'"$out"
  [ -f "$state/$id.status" ] \
    || fail "the refusal did not retain the task's status log for a rerun"$'\n'"$out"
  [ ! -s "$data/usage-ledger.jsonl" ] \
    || fail "an aborted teardown left a ledger row: $(cat "$data/usage-ledger.jsonl")"
  [ -z "$(find "$tmp" -maxdepth 1 -name 'fm-usage-stage.*' -print -quit)" ] \
    || fail "an aborted teardown leaked its usage staging directory"

  # The task keeps working before the operator reruns teardown, so a rerun that
  # replayed the aborted attempt's row would report the old turn count.
  printf 'working: resumed\n' >> "$state/$id.status"
  touch -t "$(touch_stamp "$base")" "$state/$id.status"
  rm -f "$failflag"
  out=$(PATH="$fb:$PATH" TMPDIR="$tmp" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_USAGE_CLAUDE_DIR="$TMP_ROOT/refuse-fake-claude" FM_USAGE_CODEX_DIR="$TMP_ROOT/refuse-fake-codex" \
    FM_USAGE_PI_DIR="$TMP_ROOT/refuse-fake-pi" \
    "$TEARDOWN" "$id" 2>&1)
  expect_code 0 "$?" "the rerun should complete once the return succeeds"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  [ "$(wc -l < "$data/usage-ledger.jsonl" | tr -d ' ')" = 1 ] \
    || fail "the rerun wrote more than one row"$'\n'"$row"
  assert_contains "$row" '"turns":2' \
    "the rerun re-measured the task instead of replaying the aborted attempt"
  assert_contains "$row" '"input_tokens":17' "the rerun's row carries the task's usage"
  assert_contains "$row" '"source":"claude-projects"' "the rerun's row names its source"
  [ -z "$(find "$tmp" -maxdepth 1 -name 'fm-usage-stage.*' -print -quit)" ] \
    || fail "a completed teardown leaked its usage staging directory"
  pass "teardown integration: an aborted teardown writes no row and the rerun re-measures"
}

# A scan that fails after its staging directory exists must produce exactly one
# diagnostic: without a gate on the staged row the append phase runs against a
# file that was never written, printing its own error and a second warning for
# one underlying failure.
teardown_single_diagnostic_case() {
  local proj wt id fb state data config out
  id=usageharvonewarn1
  proj="$TMP_ROOT/onewarn-proj"; wt="$TMP_ROOT/onewarn-wt"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fb="$TMP_ROOT/onewarn-fakebin"
  mkdir -p "$fb"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/treehouse"
  # The staging directory is created read-only, so it exists for the append
  # gate to see while the scan's own write into it fails.
  cat > "$fb/mktemp" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *fm-usage-stage.XXXXXX)
      d=\$("$REAL_MKTEMP" "\$@") || exit 1
      chmod 500 "\$d"
      printf '%s\\n' "\$d"
      exit 0
      ;;
  esac
done
exec "$REAL_MKTEMP" "\$@"
SH
  chmod +x "$fb/tmux" "$fb/treehouse" "$fb/mktemp"
  state="$TMP_ROOT/onewarn-state"; config="$TMP_ROOT/onewarn-config"; data="$TMP_ROOT/onewarn-data"
  mkdir -p "$state" "$config" "$data/$id"
  printf 'scout findings\n' > "$data/$id/report.md"
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "harness=claude" \
    "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="
  printf 'working: scouting\n' > "$state/$id.status"

  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_USAGE_CLAUDE_DIR="$TMP_ROOT/onewarn-fake-claude" FM_USAGE_CODEX_DIR="$TMP_ROOT/onewarn-fake-codex" \
    FM_USAGE_PI_DIR="$TMP_ROOT/onewarn-fake-pi" \
    "$TEARDOWN" "$id" 2>&1)
  expect_code 0 "$?" "teardown must survive a scan that cannot stage"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | grep -c "warning: usage harvest for $id failed")" = 1 ] \
    || fail "one failed scan produced more than one warning"$'\n'"$out"
  assert_not_contains "$out" "no staged usage row" \
    "the append ran against a staging file the scan never wrote"
  pass "teardown integration: one failed scan yields exactly one diagnostic"
}

# The staging directory is removed in teardown's exit trap, which runs under
# set -eu, so a removal that fails must not become the run's own exit status:
# teardown is fail-closed machinery whose callers read a non-zero exit as a
# refusal that retained the task's records.
teardown_stage_cleanup_failure_case() {
  local proj wt id fb state data config out tmp holder status
  id=usageharvstagerm1
  proj="$TMP_ROOT/stagerm-proj"; wt="$TMP_ROOT/stagerm-wt"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fb="$TMP_ROOT/stagerm-fakebin"
  mkdir -p "$fb"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/treehouse"
  tmp="$TMP_ROOT/stagerm-tmp"
  holder="$tmp/holder"
  mkdir -p "$holder"
  # The staging directory itself stays writable, so the scan stages its row and
  # the append reads it back normally, but its PARENT is not, so removing the
  # staging directory at exit fails.
  cat > "$fb/mktemp" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *fm-usage-stage.XXXXXX)
      mkdir -p "$holder/fm-usage-stage.pinned" || exit 1
      chmod 500 "$holder"
      printf '%s\\n' "$holder/fm-usage-stage.pinned"
      exit 0
      ;;
  esac
done
exec "$REAL_MKTEMP" "\$@"
SH
  chmod +x "$fb/tmux" "$fb/treehouse" "$fb/mktemp"
  state="$TMP_ROOT/stagerm-state"; config="$TMP_ROOT/stagerm-config"; data="$TMP_ROOT/stagerm-data"
  mkdir -p "$state" "$config" "$data/$id"
  printf 'scout findings\n' > "$data/$id/report.md"
  fm_write_meta "$state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$proj" "harness=claude" \
    "kind=scout" "mode=no-mistakes" "yolo=off" \
    "decisions_reviewed=1" "decision_keys="
  printf 'working: scouting\n' > "$state/$id.status"

  out=$(PATH="$fb:$PATH" TMPDIR="$tmp" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_USAGE_CLAUDE_DIR="$TMP_ROOT/stagerm-fake-claude" FM_USAGE_CODEX_DIR="$TMP_ROOT/stagerm-fake-codex" \
    FM_USAGE_PI_DIR="$TMP_ROOT/stagerm-fake-pi" \
    "$TEARDOWN" "$id" 2>&1)
  status=$?
  chmod 700 "$holder" 2>/dev/null || true
  expect_code 0 "$status" \
    "a staging cleanup failure must not fail an otherwise complete teardown"$'\n'"$out"
  assert_contains "$out" "teardown $id complete" "teardown still reports completion"
  [ -s "$data/usage-ledger.jsonl" ] \
    || fail "the completed run appended no row"$'\n'"$out"
  pass "teardown integration: a failing staging cleanup cannot flip the exit status"
}

# The harvester removes its own ref directory in its exit trap, under the same
# set -eu rules, so a removal that fails must not report a harvest that
# actually appended its row as a failure teardown would warn about.
harvest_refdir_cleanup_failure_case() {
  local id=usageharvrefdir1 wt="$TMP_ROOT/.no-mistakes/wt-usageharvrefdir1"
  local data home fb tmp holder out status
  data=$(harvest_case "$id" claude "$wt" claude-meta-model default)
  home=$(dirname "$data")
  export_harvest_env "$home"
  fb="$TMP_ROOT/refdir-fakebin"
  tmp="$TMP_ROOT/refdir-tmp"
  holder="$tmp/holder"
  mkdir -p "$fb" "$holder"
  # The ref directory is writable, so the window refs are stamped as usual, but
  # its parent is not, so removing it at exit fails.
  cat > "$fb/mktemp" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *fm-usage-harvest.XXXXXX)
      mkdir -p "$holder/fm-usage-harvest.pinned" || exit 1
      chmod 500 "$holder"
      printf '%s\\n' "$holder/fm-usage-harvest.pinned"
      exit 0
      ;;
  esac
done
exec "$REAL_MKTEMP" "\$@"
SH
  chmod +x "$fb/mktemp"

  out=$(PATH="$fb:$PATH" TMPDIR="$tmp" "$HARVEST" "$id" 2>&1)
  status=$?
  chmod 700 "$holder" 2>/dev/null || true
  expect_code 0 "$status" \
    "a ref-directory cleanup failure must not report a successful harvest as failed"$'\n'"$out"
  assert_contains "$(cat "$data/usage-ledger.jsonl")" "\"task\":\"$id\"" \
    "the harvest that reported success appended its row"
  pass "usage harvest: a failing ref-directory cleanup cannot flip the exit status"
}

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
  [ -z "$(find "$data" -maxdepth 1 -name 'usage-ledger.jsonl.tmp.*' -print -quit)" ] \
    || fail "a failed harvest left a ledger work file in the data dir"
  pass "teardown integration: harvest failure is non-fatal and leaves no work file"
}

# --- row scope: a relaunch must not narrow the window -----------------------

# fm-spawn rewrites spawn_gen on every relaunch but only ever appends to
# state/<id>.status, so turns always span the whole task. A row therefore
# spans the whole task too: the start is the earliest durable first-spawn
# witness, and a later relaunch token must not shorten wall_secs or drop the
# first incarnation's session logs.
relaunch_scope_case() {
  local id=usagerelaunch1 wt="$TMP_ROOT/.no-mistakes/wt-usagerelaunch1"
  local data home state row out base encoded logdir fb
  data=$(harvest_case "$id" claude "$wt" default default)
  home=$(dirname "$data")
  state="$home/state"
  export_harvest_env "$home"

  encoded=${wt//\//-}
  encoded=${encoded//./-}
  logdir="$FM_USAGE_CLAUDE_DIR/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/first-incarnation.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgR1","model":"claude-test","usage":{"input_tokens":21,"output_tokens":4}}}
JSON

  # The task is born at base, runs for 600s, and is relaunched 300s in, which
  # rewrites spawn_gen with the relaunch epoch. The birth time is pinned by a
  # stat shim so the case asserts the harvester's rule rather than the
  # runner's filesystem support for birth times.
  base=$(file_mtime_epoch "$state/$id.status")
  printf 'spawn_gen=s%s.4242.9\n' "$((base + 300))" >> "$state/$id.meta"
  touch -t "$(touch_stamp $((base + 600)))" "$state/$id.status"
  touch -t "$(touch_stamp $((base + 600)))" "$state/$id.meta"
  # A request logged by the FIRST incarnation, before the relaunch token.
  touch -t "$(touch_stamp $((base + 100)))" "$logdir/first-incarnation.jsonl"

  fb="$TMP_ROOT/relaunch-fakebin"
  stat_shim_bin "$fb" "$state/$id.status" "$base"
  out=$(PATH="$fb:$PATH" "$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "relaunch-scope harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"wall_secs":600' \
    "wall seconds span the whole task, not the last incarnation"
  assert_contains "$row" "\"spawned_at\":\"$(iso_utc "$base")\"" \
    "spawned_at reports the first spawn, not the relaunch"
  assert_contains "$row" '"turns":2' "turns count the whole task's working lines"
  assert_contains "$row" '"input_tokens":21' \
    "the first incarnation's usage is inside the whole-task window"
  assert_contains "$row" '"source":"claude-projects"' \
    "a pre-relaunch session log is still matched"
  pass "usage harvest: a relaunch never narrows the row below the turn count's span"
}

# The one documented condition under which a row narrows below the whole task:
# a filesystem with no birth time leaves spawn_gen as the only durable start,
# and a relaunch has already rewritten it, so wall_secs covers the final
# incarnation while turns still cover the whole task.
relaunch_birthless_case() {
  local id=usagerelaunch2 wt="$TMP_ROOT/wt-usagerelaunch2"
  local data home state row out base fb
  data=$(harvest_case "$id" cursor "$wt" cursor-x "")
  home=$(dirname "$data")
  state="$home/state"
  export_harvest_env "$home"
  base=$(file_mtime_epoch "$state/$id.status")
  printf 'spawn_gen=s%s.4242.9\n' "$((base + 300))" >> "$state/$id.meta"
  touch -t "$(touch_stamp $((base + 600)))" "$state/$id.status"
  touch -t "$(touch_stamp $((base + 600)))" "$state/$id.meta"

  fb="$TMP_ROOT/relaunch-nobirth-fakebin"
  stat_shim_bin "$fb"
  out=$(PATH="$fb:$PATH" "$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "birthless relaunch harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"wall_secs":300' \
    "a birthless host narrows a relaunched row to the final incarnation"
  assert_contains "$row" "\"spawned_at\":\"$(iso_utc $((base + 300)))\"" \
    "the relaunch token is the only durable start left"
  assert_contains "$row" '"turns":2' \
    "turns still span the whole task, as the narrowing condition states"
  pass "usage harvest: the birthless relaunch narrowing matches the stated contract"
}

# fm-spawn's --relaunch may switch the harness, and it rewrites the meta with
# only the new incarnation's harness. The token fields then cover the final
# harness alone, while wall_secs and turns still span the whole task. This case
# pins that documented narrowing from both sides: a widened scan that summed
# the earlier harness's log, and a scan narrowed to the final incarnation's
# window, would each change a number asserted here.
harness_switch_case() {
  local id=usageharnessswitch wt="$TMP_ROOT/.no-mistakes/wt-usageharnessswitch"
  local data home state row out base encoded logdir d1
  data=$(harvest_case "$id" codex "$wt" default high)
  home=$(dirname "$data")
  state="$home/state"
  export_harvest_env "$home"

  base=$(file_mtime_epoch "$state/$id.status")
  printf 'spawn_gen=s%s.4242.3\n' "$((base - 600))" >> "$state/$id.meta"
  touch -t "$(touch_stamp "$base")" "$state/$id.status"

  # The first incarnation ran under claude and left its own session log inside
  # the task window, at the encoded project directory the claude parser reads.
  encoded=${wt//\//-}
  encoded=${encoded//./-}
  logdir="$FM_USAGE_CLAUDE_DIR/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/first-harness.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgH","model":"claude-test","usage":{"input_tokens":700,"output_tokens":70}}}
JSON
  touch -t "$(touch_stamp $((base - 500)))" "$logdir/first-harness.jsonl"

  # The task was relaunched onto codex, which is what the meta records.
  d1="$FM_USAGE_CODEX_DIR/2026/09/01"
  mkdir -p "$d1"
  cat > "$d1/rollout-second.jsonl" <<JSON
{"type":"session_meta","payload":{"cwd":"$wt"}}
{"type":"turn_context","payload":{"model":"glm-5.3"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":9,"cached_input_tokens":0,"output_tokens":3,"reasoning_output_tokens":1}}}}
JSON
  touch -t "$(touch_stamp $((base - 100)))" "$d1/rollout-second.jsonl"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "harness-switch harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"source":"codex-sessions"' \
    "the row names the final incarnation's harness tree"
  assert_contains "$row" '"input_tokens":9' \
    "tokens cover the final harness only, never the earlier harness's log"
  assert_contains "$row" '"output_tokens":3' \
    "the earlier harness's output is not summed either"
  assert_contains "$row" '"wall_secs":600' \
    "wall seconds still span the whole task across the harness switch"
  assert_contains "$row" '"turns":2' \
    "turns still count the whole task's working lines"
  pass "usage harvest: a harness switch narrows the tokens only, as documented"
}

# A relaunch onto another model on the SAME harness leaves both incarnations'
# logs in the window, and the row has one model field. It must be the final
# incarnation's, chosen by WHEN the log was written rather than by its name:
# real claude logs are UUID-named, so path order says nothing about
# incarnation order. The newer log is deliberately named so it sorts EARLIER
# than the older one, so a path-ordered scan, or a first-log-wins rule,
# reports the superseded model and fails here.
model_final_incarnation_case() {
  local id=usagemodelfinal wt="$TMP_ROOT/.no-mistakes/wt-usagemodelfinal"
  local data home state row out base encoded logdir
  data=$(harvest_case "$id" claude "$wt" meta-fallback-model default)
  home=$(dirname "$data")
  state="$home/state"
  export_harvest_env "$home"

  encoded=${wt//\//-}
  encoded=${encoded//./-}
  logdir="$FM_USAGE_CLAUDE_DIR/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/session-b-written-first.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgM1","model":"first-incarnation-model","usage":{"input_tokens":5,"output_tokens":1}}}
JSON
  cat > "$logdir/session-a-written-last.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgM2","model":"final-incarnation-model","usage":{"input_tokens":7,"output_tokens":2}}}
JSON

  base=$(file_mtime_epoch "$state/$id.status")
  printf 'spawn_gen=s%s.4242.4\n' "$((base - 600))" >> "$state/$id.meta"
  touch -t "$(touch_stamp "$base")" "$state/$id.status"
  touch -t "$(touch_stamp $((base - 400)))" "$logdir/session-b-written-first.jsonl"
  touch -t "$(touch_stamp $((base - 100)))" "$logdir/session-a-written-last.jsonl"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "model-attribution harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"model":"final-incarnation-model"' \
    "the row reports the chronologically last incarnation's model"
  assert_contains "$row" '"input_tokens":12' \
    "both incarnations' usage is still summed on one harness (5+7)"
  assert_contains "$row" '"output_tokens":3' "both incarnations' output is summed (1+2)"
  pass "usage harvest: the model is the final incarnation's, whatever the scan order"
}

# The crewmate appends its last status line from inside an agent turn, so the
# harness writes that turn's tool result and its closing assistant entry to the
# session log AFTER the append returns. Matching logs against the status mtime
# therefore rejected the whole file and reported a task whose usage was sitting
# on disk as unavailable. The scan reaches the harvest instant instead. What
# keeps that bound safe is teardown ordering rather than the harvester alone,
# so the next occupant of a reused worktree path is covered by
# teardown_pool_order_case rather than here.
closing_write_case() {
  local id=usageclosingwrite wt="$TMP_ROOT/.no-mistakes/wt-usageclosingwrite"
  local data home state row out now encoded logdir
  data=$(harvest_case "$id" claude "$wt" default default)
  home=$(dirname "$data")
  state="$home/state"
  export_harvest_env "$home"

  encoded=${wt//\//-}
  encoded=${encoded//./-}
  logdir="$FM_USAGE_CLAUDE_DIR/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/session-closing.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msgW","model":"claude-test","usage":{"input_tokens":41,"output_tokens":3}}}
JSON

  now=$(date +%s)
  printf 'spawn_gen=s%s.4242.5\n' "$((now - 600))" >> "$state/$id.meta"
  touch -t "$(touch_stamp $((now - 60)))" "$state/$id.status"
  touch -t "$(touch_stamp $((now - 5)))" "$logdir/session-closing.jsonl"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "closing-write harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"source":"claude-projects"' \
    "a log flushed after the last status append is still matched"
  assert_contains "$row" '"input_tokens":41' \
    "the closing write's usage is summed"
  assert_contains "$row" '"output_tokens":3' "the closing write's output is summed"
  assert_contains "$row" "\"completed_at\":\"$(iso_utc $((now - 60)))\"" \
    "completed_at still rests on the last status append"
  assert_contains "$row" '"wall_secs":540' \
    "wall seconds still measure spawn to last status append, not the harvest"
  pass "usage harvest: the log scan covers the harness's closing write"
}

# --- corrupt lines: one bad line costs that line, not the file --------------

# Pi's session logs are append-only, so a truncated tail line is a realistic
# state. The cwd binding lives in the same parse as the usage, so an
# all-or-nothing parser would report the whole task as unavailable.
corrupt_line_case() {
  local id=usagecorrupt1 wt="$TMP_ROOT/wt-usagecorrupt1"
  local data home row out d1
  data=$(harvest_case "$id" pi "$wt" default high)
  home=$(dirname "$data")
  export_harvest_env "$home"
  d1="$FM_USAGE_PI_DIR/--encoded-corrupt--"
  mkdir -p "$d1"
  cat > "$d1/session-corrupt.jsonl" <<JSON
{"type":"session","id":"sess-c","cwd":"$wt"}
{"type":"message","id":"c1","message":{"role":"assistant","provider":"zai","model":"glm-5.3-flash","usage":{"input":40,"output":6,"cacheRead":2,"cacheWrite":1,"reasoning":3}}}
{"type":"message","id":"c2","message":{"role":"assistant","usage":{"in
{"type":"message","id":"c3","message":{"role":"assistant","provider":"zai","model":"glm-5.3-flash","usage":{"input":9,"output":2,"cacheRead":0,"cacheWrite":0,"reasoning":1}}}
JSON
  touch -m -r "$d1/session-corrupt.jsonl" "$home/state/$id.status"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "corrupt-line harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"source":"pi-sessions"' \
    "a corrupt line does not cost the file's cwd binding"
  assert_contains "$row" '"input_tokens":49' "the valid records around a corrupt line are summed (40+9)"
  assert_contains "$row" '"cached_input_tokens":3' "cached folds across the corrupt line (2+1)"
  assert_contains "$row" '"output_tokens":8' "output sums across the corrupt line (6+2)"
  assert_contains "$row" '"reasoning_tokens":4' "reasoning sums across the corrupt line (3+1)"
  pass "usage harvest: a corrupt log line costs that line, not the file"
}

# --- a usage record without a model must not shift the token fields ---------

# The parser hands the loop a model field that can be empty. An empty field
# must stay in its own slot, or the counts land in the wrong ledger columns
# and the model string is reported as a token count.
# A line that parses to valid JSON but is not an object must be skipped like
# any other corrupt line, rather than aborting the parse and costing the file
# its cwd binding along with all of its usage.
nonobject_line_case() {
  local id=usagenonobj1 wt="$TMP_ROOT/wt-usagenonobj1"
  local data home row out d1
  data=$(harvest_case "$id" pi "$wt" default high)
  home=$(dirname "$data")
  export_harvest_env "$home"
  d1="$FM_USAGE_PI_DIR/--encoded-nonobj--"
  mkdir -p "$d1"
  cat > "$d1/session-nonobj.jsonl" <<JSON
{"type":"session","id":"sess-o","cwd":"$wt"}
"just a string"
{"type":"message","id":"o1","message":{"role":"assistant","provider":"zai","model":"glm-5.3-flash","usage":{"input":12,"output":3,"cacheRead":1,"cacheWrite":0,"reasoning":2}}}
[1,2,3]
5
{"type":"message","id":"o2","message":{"role":"assistant","provider":"zai","model":"glm-5.3-flash","usage":{"input":8,"output":1,"cacheRead":0,"cacheWrite":0,"reasoning":0}}}
JSON
  touch -m -r "$d1/session-nonobj.jsonl" "$home/state/$id.status"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "non-object-line harvest should succeed"$'
'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"source":"pi-sessions"' \
    "a non-object line does not cost the file's cwd binding"
  assert_contains "$row" '"input_tokens":20' \
    "records around a scalar or array line are still summed (12+8)"
  assert_contains "$row" '"output_tokens":4' "output sums across the non-object lines (3+1)"
  pass "usage harvest: a valid non-object log line is skipped, not fatal"
}

missing_model_case() {
  local id=usagenomodel1 wt="$TMP_ROOT/wt-usagenomodel1"
  local data home row out d1
  data=$(harvest_case "$id" pi "$wt" pi-meta-model high)
  home=$(dirname "$data")
  export_harvest_env "$home"
  d1="$FM_USAGE_PI_DIR/--encoded-nomodel--"
  mkdir -p "$d1"
  cat > "$d1/session-nomodel.jsonl" <<JSON
{"type":"session","id":"sess-n","cwd":"$wt"}
{"type":"message","id":"n1","message":{"role":"assistant","usage":{"input":100,"output":30,"cacheRead":20,"cacheWrite":5,"reasoning":7}}}
JSON
  touch -m -r "$d1/session-nomodel.jsonl" "$home/state/$id.status"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "model-less harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"model":"pi-meta-model"' \
    "a log with no model falls back to the meta model, never to a token count"
  assert_contains "$row" '"input_tokens":100' "input stays in its own field"
  assert_contains "$row" '"cached_input_tokens":25' "cached stays in its own field (20+5)"
  assert_contains "$row" '"output_tokens":30' "output stays in its own field"
  assert_contains "$row" '"reasoning_tokens":7' "reasoning stays in its own field"
  pass "usage harvest: an absent log model never shifts the token fields"
}

# --- source names assert a parsed match, for every harness alike ------------

# An in-window log that yields no assistant usage must report source
# "unavailable" with null token fields under claude exactly as under codex
# and pi, so the source enum means the same thing across harnesses.
no_usage_case() {
  local id=usagenousage1 wt="$TMP_ROOT/.no-mistakes/wt-usagenousage1"
  local data home row out encoded logdir
  data=$(harvest_case "$id" claude "$wt" claude-meta-model default)
  home=$(dirname "$data")
  export_harvest_env "$home"
  encoded=${wt//\//-}
  encoded=${encoded//./-}
  logdir="$FM_USAGE_CLAUDE_DIR/$encoded"
  mkdir -p "$logdir"
  cat > "$logdir/session-nousage.jsonl" <<'JSON'
{"type":"user","message":{"role":"user"}}
{"type":"assistant","message":{"id":"msgNU"}}
JSON
  touch -m -r "$logdir/session-nousage.jsonl" "$home/state/$id.status"

  out=$("$HARVEST" "$id" 2>&1)
  expect_code 0 "$?" "no-usage harvest should succeed"$'\n'"$out"
  row=$(cat "$data/usage-ledger.jsonl")
  assert_contains "$row" '"source":"unavailable"' \
    "an in-window log that yields no usage is not a source"
  assert_contains "$row" '"input_tokens":null' "no parsed usage renders null input tokens"
  assert_contains "$row" '"cached_input_tokens":null' "no parsed usage renders null cached tokens"
  assert_contains "$row" '"output_tokens":null' "no parsed usage renders null output tokens"
  assert_contains "$row" '"reasoning_tokens":null' "no parsed usage renders null reasoning tokens"
  assert_contains "$row" '"model":"claude-meta-model"' "the row still reports the meta model"
  pass "usage harvest: a source is named only after a log yields assistant usage"
}

claude_case
claude_nobirth_case
codex_case
pi_case usagepi1 pi
pi_case usagepisigned1 pi-signed
token_convention_case
codex_cache_write_case
prefilter_case
spawn_gen_case
spawn_gen_malformed_case
spawn_gen_future_case
relaunch_scope_case
relaunch_birthless_case
harness_switch_case
model_final_incarnation_case
closing_write_case
corrupt_line_case
nonobject_line_case
missing_model_case
no_usage_case
cursor_case
remote_case
reused_task_id_case
legacy_ledger_row_case
race_case
lock_bound_case
report_case
report_model_totals_case
report_no_harness_case
report_malformed_case
teardown_status_case
teardown_child_case
teardown_nested_child_case
teardown_remote_nested_home_case
teardown_pool_order_case
teardown_refusal_case
teardown_single_diagnostic_case
teardown_stage_cleanup_failure_case
harvest_refdir_cleanup_failure_case
teardown_case
