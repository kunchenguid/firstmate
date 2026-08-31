#!/usr/bin/env bash
# Behavior tests for the fleet usage harvester and its report reader.
# Covers claude-log request dedupe and cache folding, codex per-request delta
# sums with cwd/window matching, pi/pi-signed session parsing over the shared
# ~/.pi/agent/sessions tree, the durable spawn_gen task start that survives a
# meta rewritten after the fact, cursor/unavailable null rows, the
# no-double-append idempotency guard, the ledger report rendering, and the
# teardown integration properties that the harvest sees the status log and
# that a harvest failure never blocks teardown. Also covers the whole-task row
# scope a relaunch must not narrow, the per-line corrupt-log tolerance, and
# the rule that a source is named only after a log yields assistant usage.
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
  assert_contains "$row" '"input_tokens":150' "codex input sums per-request deltas (100+50)"
  assert_contains "$row" '"cached_input_tokens":15' "codex cached folds cached+cache_write (10+5+0)"
  assert_contains "$row" '"output_tokens":31' "codex output sums deltas (20+11)"
  assert_contains "$row" '"reasoning_tokens":11' "codex reasoning sums deltas (8+3)"
  pass "codex harvest: cwd/window matching, delta sums, model capture"
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

# --- claude: window survives a host without usable birth time ---------------

# A stat shim that reports no birth time (GNU statx unsupported returns 0 for
# %W) while still answering mtime, so the harvest must fall back to the meta
# mtime for the window start instead of collapsing to the status mtime.
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

  # Pin an explicit window: status finishes at T, meta was spawned 100s earlier,
  # and the session log lands mid-window. Without the meta-mtime start fallback
  # the birthless window collapses to [T, T] and drops the earlier log.
  base=$(file_mtime_epoch "$state/$id.status")
  touch -t "$(touch_stamp "$base")" "$state/$id.status"
  touch -t "$(touch_stamp $((base - 100)))" "$state/$id.meta"
  touch -t "$(touch_stamp $((base - 50)))" "$logdir/session.jsonl"

  fb="$TMP_ROOT/nobirth-fakebin"
  stat_shim_bin "$fb"
  out=$(PATH="$fb:$PATH" "$HARVEST" "$id" 2>&1)
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
  fields=$(printf '%s\n' "$out" | awk -v t="$id" '$1 == t {print NF"|"$2"|"$3"|"$NF}')
  [ "$fields" = "10|-|nohar-model|unavailable" ] \
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
spawn_gen_case
spawn_gen_malformed_case
spawn_gen_future_case
relaunch_scope_case
relaunch_birthless_case
corrupt_line_case
nonobject_line_case
missing_model_case
no_usage_case
cursor_case
remote_case
race_case
lock_bound_case
report_case
report_no_harness_case
teardown_status_case
teardown_case
