#!/usr/bin/env bash
# Behavior tests for lifecycle telemetry recording and reporting.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/bin/fm-telemetry.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-telemetry-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-telemetry)

make_home() {
  local name=$1 home="$TMP_ROOT/$1/home"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

record() {
  local home=$1 stream=$2 payload=$3
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" bash -c \
    '. "$1"; fm_telemetry_record "$2" "$3"' _ "$LIB" "$stream" "$payload"
}

record_wait() {
  local home=$1 now=$2 task=$3 attempt=$4 owner=$5 key=$6 transition=$7
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_TELEMETRY_NOW_MS="$now" bash -c \
    '. "$1"; fm_telemetry_record_wait "$2" "$3" "$4" "$5" "$6"' \
    _ "$LIB" "$task" "$attempt" "$owner" "$key" "$transition"
}

test_append_format_and_failure_is_best_effort() {
  local home row rc err
  home=$(make_home append)
  record "$home" lifecycle '{"op":"spawn","elapsedMs":12}' || fail "telemetry append failed"
  row=$(cat "$home/data/telemetry/lifecycle.jsonl")
  printf '%s' "$row" | jq -e '
    (.ts|type=="number") and (.home|type=="string") and .op=="spawn" and .elapsedMs==12
    and has("taskId") and has("attemptId") and has("operationId") and has("homeId")' >/dev/null \
    || fail "append format omitted the lifecycle identity envelope"
  [ "$(file_mode "$home/data/telemetry/lifecycle.jsonl")" = 600 ] || fail "telemetry stream is not mode 0600"
  printf '%s\n' blocked > "$home/data/not-a-directory"
  set +e
  err=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data/not-a-directory" bash -c \
    '. "$1"; fm_telemetry_record lifecycle "{\"op\":\"ignored\"}"; exit 7' _ "$LIB" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 7 ] || fail "failing append changed caller exit code"
  [ -n "$err" ] || fail "failing append did not emit one diagnostic"
  pass "append format, private mode, and best-effort failure behavior"
}

test_lifecycle_identity_and_wait_events() {
  local home row rows
  home=$(make_home identity)
  mkdir -p "$home/state"
  printf 'telemetry_attempt=mra_fixture\n' > "$home/state/task-a.meta"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TELEMETRY_NOW_MS=90 bash -c \
    '. "$1"; ID=task-a; fm_telemetry_record lifecycle '\''{"op":"spawn","status":3}'\''' _ "$LIB" \
    || fail "attributed lifecycle append failed"
  row=$(<"$home/data/telemetry/lifecycle.jsonl")
  printf '%s' "$row" | jq -e \
    '.taskId=="task-a" and .attemptId=="mra_fixture" and (.operationId|type=="string" and length>0) and .homeId=="home" and .refusalCode=="exit-3"' \
    >/dev/null || fail "lifecycle identity envelope was incomplete: $row"

  record_wait "$home" 100 task-a mra_fixture main review open || fail "wait open append failed"
  mv "$home/data/telemetry/lifecycle.jsonl" "$home/data/telemetry/lifecycle.jsonl.1"
  record_wait "$home" 160 task-a mra_fixture main review resumed || fail "wait resume append failed"
  rows=$(jq -sc '[.[] | select(.op=="wait")]' \
    "$home/data/telemetry/lifecycle.jsonl.1" "$home/data/telemetry/lifecycle.jsonl")
  printf '%s' "$rows" | jq -e \
    'length==2 and .[0].taskId=="task-a" and .[0].attemptId=="mra_fixture" and .[0].waitOwner=="main" and .[0].waitKey=="review" and .[0].openedAt==100 and .[0].resumedAt==null and .[1].openedAt==100 and .[1].resumedAt==160' \
    >/dev/null || fail "wait transition continuity was not recorded: $rows"
  pass "lifecycle rows carry identity and wait events preserve open-to-resume continuity"
}

test_rotation() {
  local home stream
  home=$(make_home rotation)
  stream="$home/data/telemetry/lifecycle.jsonl"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_TELEMETRY_MAX_BYTES=100 \
    bash -c '. "$1"; p="{\"op\":\"x\",\"n\":12345678901234567890}"; fm_telemetry_record lifecycle "$p"; fm_telemetry_record lifecycle "$p"' _ "$LIB" \
    || fail "rotation append failed"
  [ -f "$stream.1" ] || fail "rotation did not create .1"
  [ ! -f "$stream.2" ] || fail "rotation kept more than one rotated stream"
  pass "size-bounded telemetry rotation keeps one prior stream"
}

test_cli_surfaces() {
  local home out
  home=$(make_home cli)
  printf '# scorecard\nK1: startup\nK11: excluded\nK13: liveness\n' > "$home/data/stability-scorecard-2026-09-11.md"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$CLI" scorecard) || fail "scorecard command failed"
  assert_contains "$out" 'K1: startup | telemetry=unmeasured' "scorecard did not mark an empty stream unmeasured"
  assert_contains "$out" 'K13: liveness | telemetry=unmeasured' "scorecard did not print K13"
  assert_not_contains "$out" 'K11' "scorecard printed excluded K11"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$CLI" -h) || fail "telemetry help failed"
  assert_contains "$out" 'stats' "telemetry help omitted stats"
  pass "tail, help, and scorecard surfaces expose bounded telemetry"
}

test_wake_drain_records_attributed_fold() {
  local dir state home data fakebin counter out err sequence generation row scorecard
  dir=$(make_case telemetry-drain)
  state="$dir/state"
  home="$dir/home"
  data="$home/data"
  fakebin="$dir/fakebin"
  counter="$dir/date-count"
  out="$dir/drain.out"
  err="$dir/drain.err"
  mkdir -p "$data"
  printf '# scorecard\nK2: wake drain\n' > "$data/stability-scorecard-2026-09-11.md"
  record "$home" lifecycle '{"op":"spawn","elapsedMs":1}'
  scorecard=$(FM_HOME="$home" FM_DATA_OVERRIDE="$data" "$CLI" scorecard) || fail "scorecard rejected legacy lifecycle data"
  assert_contains "$scorecard" 'K2: wake drain | telemetry=unmeasured' "scorecard treated an unattributed row as K2 data"
  cat > "$fakebin/date" <<'SH'
#!/usr/bin/env bash
n=$(cat "${FM_FAKE_DATE_COUNTER}" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s\n' "$n" > "$FM_FAKE_DATE_COUNTER"
printf '%s\n' "$n"
SH
  chmod +x "$fakebin/date"
  printf 'working: telemetry fixture\n' > "$state/fixture.status"
  append_wake "$state" check fixture 'check: telemetry fixture' || fail "fixture wake append failed"
  PATH="$fakebin:$PATH" FM_FAKE_DATE_COUNTER="$counter" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" \
    "$DRAIN" > "$out" 2> "$err" || fail "wake drain failed"
  row=$(jq -c 'select(.op == "wake-drain" and .actor == "present")' "$data/telemetry/lifecycle.jsonl")
  printf '%s' "$row" | jq -e '.mode == "main" and (.foldMs | type == "number" and . > 0)' >/dev/null \
    || fail "wake drain telemetry omitted mode or a positive foldMs: $row"
  scorecard=$(FM_HOME="$home" FM_DATA_OVERRIDE="$data" "$CLI" scorecard) || fail "scorecard failed after wake drain"
  assert_contains "$scorecard" 'K2: wake drain | telemetry=measured' "scorecard did not recognize the attributed drain row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  PATH="$fakebin:$PATH" FM_FAKE_DATE_COUNTER="$counter" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" \
    "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" || fail "wake acknowledgement failed"
  jq -e 'select(.op == "wake-drain" and .actor == "ack" and .mode == "main")' "$data/telemetry/lifecycle.jsonl" >/dev/null \
    || fail "wake acknowledgement telemetry omitted actor or mode"
  pass "wake drain telemetry attributes presentation and acknowledgement with a measurable fold"
}

test_status_wait_emitters() {
  local home rows status
  home=$(make_home status-waits)
  printf 'telemetry_attempt=attempt-status\n' > "$home/state/task-status.meta"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TELEMETRY_NOW_MS=100 bash -c \
    '. "$1"; . "$2"; fm_telemetry_record_status_line "$3" "$3/task-status.status" "blocked [key=review]: waiting for MAIN"' \
    _ "$LIB" "$ROOT/bin/fm-classify-lib.sh" "$home/state"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TELEMETRY_NOW_MS=175 bash -c \
    '. "$1"; . "$2"; fm_telemetry_record_status_line "$3" "$3/task-status.status" "working [key=review]: resumed after review"' \
    _ "$LIB" "$ROOT/bin/fm-classify-lib.sh" "$home/state"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TELEMETRY_NOW_MS=200 bash -c \
    '. "$1"; . "$2"; fm_telemetry_record_status_line "$3" "$3/task-status.status" "blocked [key=pending-reply-abcd]: escalated"' \
    _ "$LIB" "$ROOT/bin/fm-classify-lib.sh" "$home/state"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TELEMETRY_NOW_MS=250 bash -c \
    '. "$1"; . "$2"; fm_telemetry_record_status_line "$3" "$3/task-status.status" "resolved [key=pending-reply-abcd]: answered"' \
    _ "$LIB" "$ROOT/bin/fm-classify-lib.sh" "$home/state"
  rows=$(jq -sc '[.[] | select(.op=="wait")]' "$home/data/telemetry/lifecycle.jsonl")
  printf '%s' "$rows" | jq -e '
    length==4 and .[0].waitOwner=="main" and .[0].openedAt==100
    and .[1].waitOwner=="main" and .[1].openedAt==100 and .[1].resumedAt==175
    and .[2].waitOwner=="secondmate" and .[2].openedAt==200
    and .[3].waitOwner=="secondmate" and .[3].openedAt==200 and .[3].resumedAt==250' \
    >/dev/null || fail "status wait emitters lost a blocked/escalated-to-resumed transition: $rows"

  status="$home/state/task-status.status"
  printf 'blocked [key=self-announced]: waiting\n' > "$status"
  record_wait "$home" 300 task-status attempt-status main self-announced open
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TELEMETRY_NOW_MS=350 bash -c '
      . "$1"; . "$2"; . "$3"
      fm_wake_status_mark_current "$4" "$5"
      fm_wake_status_append_self_announced "$4" "$5" "resolved [key=self-announced]: answered"
    ' _ "$LIB" "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$status" \
    || fail "self-announced status append failed"
  jq -e '[select(.op=="wait" and .waitKey=="self-announced" and .resumedAt!=null)]
    | length==1 and .[0].openedAt==300 and .[0].resumedAt==350' \
    "$home/data/telemetry/lifecycle.jsonl" >/dev/null \
    || fail "self-announced status append did not emit exactly one resumed wait"
  pass "status wait emitters record blocked-to-resumed continuity"
}

test_watcher_status_wait_emitter() {
  local home fakebin status out pid i=0
  home=$(make_home watcher-status)
  fakebin="$home/fakebin"
  status="$home/state/task-watch.status"
  out="$home/watch.out"
  mkdir -p "$fakebin" "$home/root"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: none · telemetry fixture\n'
SH
  chmod +x "$fakebin/tmux" "$fakebin/fm-crew-state.sh"
  printf 'telemetry_attempt=attempt-watch\nwindow=test:fm-task-watch\nkind=ship\nharness=pi\n' \
    > "$home/state/task-watch.meta"
  printf 'blocked [key=review]: waiting\n' > "$status"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" \
    FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "watcher did not surface the blocked status: $(<"$out")"
  fi
  wait "$pid" || fail "watcher status scan failed: $(<"$out")"
  jq -e 'select(.op=="wait" and .taskId=="task-watch" and .attemptId=="attempt-watch"
    and .waitOwner=="main" and .waitKey=="review"
    and (.openedAt|type)=="number" and .resumedAt==null)' \
    "$home/data/telemetry/lifecycle.jsonl" >/dev/null \
    || fail "watcher status scan emitted no attributed wait"
  pass "watcher status scanning emits attributed wait telemetry"
}

test_wait_scorecard_metrics() {
  local home out
  home=$(make_home wait-scorecard)
  printf '# scorecard\nK16: median wait on MAIN per seat\nK17: lock wait per spawn\n' \
    > "$home/data/stability-scorecard-2026-09-11.md"
  record_wait "$home" 100 task-a attempt-a main review open
  record_wait "$home" 200 task-a attempt-a main review resumed
  record_wait "$home" 300 task-b attempt-b main decision open
  record_wait "$home" 600 task-b attempt-b main decision resumed
  mv "$home/data/telemetry/lifecycle.jsonl" "$home/data/telemetry/lifecycle.jsonl.2"
  record "$home" lifecycle '{"op":"spawn","taskId":"task-a","attemptId":"attempt-a","lockWaitMs":10}'
  mv "$home/data/telemetry/lifecycle.jsonl" "$home/data/telemetry/lifecycle.jsonl.1"
  record "$home" lifecycle '{"op":"relaunch","taskId":"task-b","attemptId":"attempt-b","lockWaitMs":30}'
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$CLI" scorecard) \
    || fail "wait scorecard command failed"
  assert_contains "$out" 'K16: median wait on MAIN per seat | telemetry=measured medianMs=200 seats=2' \
    "K16 did not report the median of per-seat MAIN wait totals"
  assert_contains "$out" 'K17: lock wait per spawn | telemetry=measured totalMs=40 spawns=2 perSpawnMs=20' \
    "K17 did not report lock wait per spawn"
  pass "scorecard reports K16 MAIN wait and K17 lock wait"
}

test_stats_math() {
  local home out
  home=$(make_home stats)
  record "$home" lifecycle '{"op":"spawn","elapsedMs":10}'
  record "$home" lifecycle '{"op":"spawn","elapsedMs":20}'
  record "$home" lifecycle '{"op":"spawn","elapsedMs":30}'
  record "$home" lifecycle '{"op":"spawn","elapsedMs":40}'
  record "$home" lifecycle '{"op":"spawn","elapsedMs":50}'
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$CLI" stats lifecycle --since 24h) \
    || fail "stats command failed"
  printf '%s' "$out" | jq -e '.[0].op=="spawn" and .[0].count==5 and .[0].median==30 and .[0].p90==50' >/dev/null \
    || fail "stats median/p90 math was wrong: $out"
  pass "stats reports count, median, and p90"
}

test_append_format_and_failure_is_best_effort
test_lifecycle_identity_and_wait_events
test_rotation
test_stats_math
test_status_wait_emitters
test_watcher_status_wait_emitter
test_wait_scorecard_metrics
test_cli_surfaces
test_wake_drain_records_attributed_fold
