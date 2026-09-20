#!/usr/bin/env bash
# tests/fm-spend-ledger.test.sh - behavior tests for bin/fm-spend-ledger.py.
#
# The ledger reads Pi session JSONL (session header + thinking_level_change +
# assistant message usage records), binds sessions to tasks by encoded worktree
# directory plus spawn epoch, folds nested subagent transcripts through the
# parent's subagent-registry.json, and writes state/<id>.spend plus the fleet
# rollup. These tests build synthetic session stores and metas and drive the
# public CLI only.
#
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER="$ROOT/bin/fm-spend-ledger.py"

# make_session_dir <root> <abs-cwd>: create the Pi session directory for a cwd.
make_session_dir() {
  local root=$1 cwd=$2 encoded
  encoded="--$(printf '%s' "${cwd#/}" | tr '/\\:' '---')--"
  mkdir -p "$root/$encoded"
  printf '%s\n' "$root/$encoded"
}

# write_session <file> <id> <cwd> <start-iso> : header line.
write_session_header() {
  printf '{"type":"session","version":3,"id":"%s","timestamp":"%s","cwd":"%s"}\n' \
    "$2" "$4" "$3" > "$1"
}

# append_message <file> <iso> <provider> <model> <totalTokens> <cost|none>
append_message() {
  local file=$1 iso=$2 provider=$3 model=$4 tokens=$5 cost=$6
  if [ "$cost" = "none" ]; then
    printf '{"type":"message","timestamp":"%s","message":{"role":"assistant","provider":"%s","model":"%s","usage":{"input":%s,"output":10,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":%s}}}\n' \
      "$iso" "$provider" "$model" "$tokens" "$tokens" >> "$file"
  else
    printf '{"type":"message","timestamp":"%s","message":{"role":"assistant","provider":"%s","model":"%s","usage":{"input":%s,"output":10,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":%s,"cost":{"input":0,"output":%s,"cacheRead":0,"cacheWrite":0,"total":%s}}}}\n' \
      "$iso" "$provider" "$model" "$tokens" "$tokens" "$cost" "$cost" >> "$file"
  fi
}

# append_effort <file> <iso> <level>
append_effort() {
  printf '{"type":"thinking_level_change","id":"x","parentId":null,"timestamp":"%s","thinkingLevel":"%s"}\n' \
    "$2" "$3" >> "$1"
}

json_field() {  # <file-or-doc> <python-expr-over-d>
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"
}

# --- fixture world -----------------------------------------------------------

TMP_ROOT=$(fm_test_tmproot fm-spend-ledger)
SESSIONS=$TMP_ROOT/sessions
STATE=$TMP_ROOT/state
mkdir -p "$SESSIONS" "$STATE"

# Two tasks reuse the same worktree across spawn generations: task-a spawned
# 2026-09-15, task-b 2026-09-18, so a Sep-16 session binds to task-a and a
# Sep-19 session binds to task-b.
EPOCH_A=$(python3 -c 'import datetime; print(int(datetime.datetime(2026,9,15,tzinfo=datetime.timezone.utc).timestamp()))')
EPOCH_B=$(python3 -c 'import datetime; print(int(datetime.datetime(2026,9,18,tzinfo=datetime.timezone.utc).timestamp()))')
fm_write_meta "$STATE/task-a.meta" \
  "endpoint_task_id=task-a" "worktree=/work/alpha" "spawn_gen=s${EPOCH_A}.1.aa" \
  "harness=pi" "kind=ship" "effort=high"
fm_write_meta "$STATE/task-b.meta" \
  "endpoint_task_id=task-b" "worktree=/work/alpha" "spawn_gen=s${EPOCH_B}.1.bb" \
  "harness=pi" "kind=ship" "effort=medium"

DIR_ALPHA=$(make_session_dir "$SESSIONS" /work/alpha)
DIR_OTHER=$(make_session_dir "$SESSIONS" /work/other)

# Session 1: task-a window, mixed lanes, effort switch mid-session, one
# cost-free record.
S1=$DIR_ALPHA/2026-09-16T10-00-00-000Z_aaaaaaaa-0000-0000-0000-000000000001.jsonl
write_session_header "$S1" "aaaaaaaa-0000-0000-0000-000000000001" /work/alpha "2026-09-16T10:00:00.000Z"
append_effort "$S1" "2026-09-16T10:00:05.000Z" high
append_message "$S1" "2026-09-16T10:01:00.000Z" openai-codex gpt-6-astra 1000 none
append_message "$S1" "2026-09-16T10:02:00.000Z" openai-codex gpt-6-astra 2000 "0.10"
append_effort "$S1" "2026-09-16T10:03:00.000Z" max
append_message "$S1" "2026-09-16T10:04:00.000Z" xai grok-4 500 "0.05"

# Session 2: predates task-a's spawn -> unattributed to it, but before task-b's
# spawn too -> unattributed entirely.
S0=$DIR_ALPHA/2026-09-10T10-00-00-000Z_aaaaaaaa-0000-0000-0000-000000000000.jsonl
write_session_header "$S0" "aaaaaaaa-0000-0000-0000-000000000000" /work/alpha "2026-09-10T10:00:00.000Z"
append_message "$S0" "2026-09-10T10:01:00.000Z" openai-codex gpt-6-astra 777 none

# Session 3: task-b window on the same worktree.
S3=$DIR_ALPHA/2026-09-19T10-00-00-000Z_bbbbbbbb-0000-0000-0000-000000000003.jsonl
write_session_header "$S3" "bbbbbbbb-0000-0000-0000-000000000003" /work/alpha "2026-09-19T10:00:00.000Z"
append_effort "$S3" "2026-09-19T10:00:05.000Z" medium
append_message "$S3" "2026-09-19T10:01:00.000Z" xai grok-4 300 "0.02"

# Nested child: lives in the OTHER dir (cannot bind itself to task-a), linked
# via task-a session's subagent registry.
CHILD=$DIR_OTHER/2026-09-16T10-05-00-000Z_cccccccc-0000-0000-0000-0000000000cc.jsonl
write_session_header "$CHILD" "cccccccc-0000-0000-0000-0000000000cc" /work/other "2026-09-16T10:05:00.000Z"
append_effort "$CHILD" "2026-09-16T10:05:05.000Z" max
append_message "$CHILD" "2026-09-16T10:06:00.000Z" openai-codex gpt-6-astra 400 "0.02"
mkdir -p "$DIR_ALPHA/artifacts/aaaaaaaa-0000-0000-0000-000000000001"
printf '{"fm-orchestrated-worker":{"sessionFile":"%s","sessionId":"cccccccc-0000-0000-0000-0000000000cc"}}\n' \
  "$CHILD" > "$DIR_ALPHA/artifacts/aaaaaaaa-0000-0000-0000-000000000001/subagent-registry.json"

# --- task view: aggregation, lane mapping, effort buckets, nested fold-in ----

OUT=$("$LEDGER" --state "$STATE" --sessions-root "$SESSIONS" task task-a)
SPEND=$STATE/task-a.spend
assert_present "$SPEND" "task-a spend file written"
assert_equals "ok" "$(json_field "$(cat "$SPEND")" "d['status']")" "task-a status"
assert_equals "3900" "$(json_field "$(cat "$SPEND")" "d['totals']['tokens']")" "task-a totals include nested"
assert_equals "2" "$(json_field "$(cat "$SPEND")" "d['totals']['sessions']")" "task-a session count"
assert_equals "1" "$(json_field "$(cat "$SPEND")" "d['totals']['nestedSessions']")" "task-a nested count"
assert_equals "3400" "$(json_field "$(cat "$SPEND")" "d['byLane']['codex']['tokens']")" "openai-codex maps to codex lane incl. nested"
assert_equals "500" "$(json_field "$(cat "$SPEND")" "d['byLane']['grok']['tokens']")" "xai maps to grok lane"
assert_equals "3000" "$(json_field "$(cat "$SPEND")" "d['byEffort']['high']['tokens']")" "effort=high bucket"
assert_equals "900" "$(json_field "$(cat "$SPEND")" "d['byEffort']['max']['tokens']")" "effort=max bucket incl. nested"
assert_equals "1000" "$(json_field "$(cat "$SPEND")" "d['totals']['unpricedTokens']")" "unpriced tokens counted"
assert_equals "partial" "$(json_field "$(cat "$SPEND")" "d['totals']['costStatus']")" "mixed cost -> partial"
assert_contains "$OUT" '"task": "task-a"' "task command prints the document"

# The pre-spawn session must not leak into task-a.
PRESPAWN=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for s in d["sessions"] if s["id"]=="aaaaaaaa-0000-0000-0000-000000000000"))' "$SPEND")
assert_equals "0" "$PRESPAWN" "pre-spawn session not bound to task-a"

# --- task-b binds only its own window ----------------------------------------

"$LEDGER" --state "$STATE" --sessions-root "$SESSIONS" task task-b >/dev/null
assert_equals "300" "$(json_field "$(cat "$STATE/task-b.spend")" "d['totals']['tokens']")" "task-b gets only its window"
assert_equals "1" "$(json_field "$(cat "$STATE/task-b.spend")" "d['totals']['sessions']")" "task-b one session"

# --- unknown task and unbound sessions ---------------------------------------

"$LEDGER" --state "$STATE" --sessions-root "$SESSIONS" task task-missing >/dev/null
assert_equals "unavailable" "$(json_field "$(cat "$STATE/task-missing.spend")" "d['status']")" "missing meta -> unavailable"

# --- fleet rollup ------------------------------------------------------------

"$LEDGER" --state "$STATE" --sessions-root "$SESSIONS" rollup >/dev/null
ROLLUP=$STATE/spend-rollup.json
assert_present "$ROLLUP" "rollup written"
assert_equals "4977" "$(json_field "$(cat "$ROLLUP")" "d['all']['tokens']")" "rollup totals all sessions"
assert_equals "777" "$(json_field "$(cat "$ROLLUP")" "d['unattributed']['tokens']")" "rollup unattributed tokens"
assert_equals "3900" "$(json_field "$(cat "$ROLLUP")" "d['tasks']['task-a']['tokens']")" "rollup per-task"
assert_equals "4177" "$(json_field "$(cat "$ROLLUP")" "d['byFamily']['codex']['tokens']")" "rollup codex family"
assert_equals "800" "$(json_field "$(cat "$ROLLUP")" "d['byFamily']['grok']['tokens']")" "rollup grok family"

# --- predict: weekly window calibration --------------------------------------

NOW_EPOCH=$(python3 -c 'import time; print(int(time.time()))')
RESETS=$(python3 -c 'import sys,datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1])+86400, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$NOW_EPOCH")
cat > "$STATE/quota.json" <<EOF
{"schema":"quota-axi.v5","providers":[
 {"provider":"codex","windows":[{"id":"weekly","kind":"weekly","resetsAt":"$RESETS","percentRemaining":40,"pace":{"burnMultiple":2.0}}],"availability":[]},
 {"provider":"daily","windows":[{"id":"daily","kind":"daily","resetsAt":"$RESETS","percentRemaining":40,"pace":{"burnMultiple":2.0}}],"availability":[]},
 {"provider":"unmeasured","windows":[],"availability":[]}
 ]}
EOF
PREDICT=$("$LEDGER" --state "$STATE" --sessions-root "$SESSIONS" predict --quota "$STATE/quota.json")
# Window covers the last 7 days: sessions S1 (3000 codex) + CHILD (400 codex)
# fall inside; S0 (777, Sep 10) is outside; consumed=60 -> 3400/60 per point.
assert_equals "ok" "$(json_field "$PREDICT" "d['status']")" "predict status"
assert_equals "3400" "$(json_field "$PREDICT" "d['providers']['codex']['windowTokens']")" "predict window tokens"
assert_equals "60.0" "$(json_field "$PREDICT" "d['providers']['codex']['percentConsumed']")" "predict percent consumed"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert abs(d["providers"]["codex"]["tokensPerPoint"] - 3400/60) < 0.01, d' "$PREDICT" \
  || fail "predict tokensPerPoint"
assert_not_contains "$PREDICT" '"unmeasured"' "predict invents no row for unmeasured provider"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert "daily" not in d["providers"], d["providers"]' "$PREDICT" \
  || fail "predict calibrated a non-weekly window"

# --- malformed quota and missing sessions root --------------------------------

echo 'not json' > "$STATE/quota-bad.json"
PREDICT_BAD=$("$LEDGER" --state "$STATE" --sessions-root "$SESSIONS" predict --quota "$STATE/quota-bad.json")
assert_equals "unavailable" "$(json_field "$PREDICT_BAD" "d['status']")" "malformed quota -> unavailable"

EMPTY=$TMP_ROOT/empty-sessions
mkdir -p "$EMPTY"
"$LEDGER" --state "$STATE" --sessions-root "$EMPTY" task task-a >/dev/null
assert_equals "empty" "$(json_field "$(cat "$STATE/task-a.spend")" "d['status']")" "no sessions -> empty not zero-fabricated"

pass "spend ledger: parsing, lanes, effort, nested transcripts, task binding, rollup, predict, malformed inputs"
