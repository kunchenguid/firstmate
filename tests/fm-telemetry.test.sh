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

test_append_format_and_failure_is_best_effort() {
  local home row rc err
  home=$(make_home append)
  record "$home" lifecycle '{"op":"spawn","elapsedMs":12}' || fail "telemetry append failed"
  row=$(cat "$home/data/telemetry/lifecycle.jsonl")
  printf '%s' "$row" | jq -e '(.ts|type=="number") and (.home|type=="string") and .op=="spawn" and .elapsedMs==12' >/dev/null \
    || fail "append format was not a content-free JSON object"
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
test_rotation
test_stats_math
test_cli_surfaces
test_wake_drain_records_attributed_fold
