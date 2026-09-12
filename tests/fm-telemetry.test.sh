#!/usr/bin/env bash
# Behavior tests for lifecycle telemetry recording and reporting.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT/bin/fm-telemetry.sh"
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
