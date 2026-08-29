#!/usr/bin/env bash
# L1: wake-drain loop observability. A drain of queued records appends one
# parseable JSON line (with items_found) to loop-run-log.md and stamps
# STATE.md's Last run; FM_LOOP_LOG=0 disables both; an unwritable log target
# never perturbs the drain contract (output + exit code).
# Mutation (LEDGER_MUTATE=1): the instrumented drain runs with FM_LOOP_LOG=0
# while the test still asserts the log line appears - a correct guard writes
# nothing, failing the assertions.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-loop-l1)
HOME_DIR="$TMP/home"; S="$HOME_DIR/state"
mkdir -p "$S"
printf '# state\n\nLast run: never\n' > "$HOME_DIR/STATE.md"
: > "$HOME_DIR/loop-run-log.md"

drain() {  # runs the drain against this home; extra env via prefix
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$S" \
    "$ROOT/bin/fm-wake-drain.sh"
}

# 1. instrumented drain: two queued records -> output intact, one JSON line, stamp
# (queue record format: epoch \t seq \t kind \t key \t payload - see fm-wake-lib)
printf '1700000000\t1\tsignal\tfm-alpha\tstatus\n1700000001\t2\tcheck\tfm-beta\tmerged\n' > "$S/.wake-queue"
MUTATE_ENV=1
[ "${LEDGER_MUTATE:-}" = 1 ] && MUTATE_ENV=0
out=$(FM_LOOP_LOG=$MUTATE_ENV FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$S" \
  "$ROOT/bin/fm-wake-drain.sh"); code=$?
expect_code 0 "$code" "drain must exit 0"
assert_contains "$out" "fm-alpha" "drain output carries the first record"
lines=$(grep -c '"run_id"' "$HOME_DIR/loop-run-log.md" || true)
[ "$lines" = 1 ] || fail "exactly one run-log JSON line expected (got: $lines)"
python3 - "$HOME_DIR/loop-run-log.md" <<'PY' || fail "run-log line must be valid JSON with items_found=2"
import json, sys
line = [l for l in open(sys.argv[1]) if l.startswith('{')][-1]
d = json.loads(line)
assert d["items_found"] == 2, d
assert d["pattern"] == "firstmate-watch", d
assert d["outcome"] == "report-only", d
PY
assert_no_grep "Last run: never" "$HOME_DIR/STATE.md" "STATE.md must be stamped"
assert_grep "Last run: 20" "$HOME_DIR/STATE.md" "stamp is a timestamp"

# 2. FM_LOOP_LOG=0 leaves both untouched
printf '1700000002\t3\tstale\tfm-gamma\tquiet\n' > "$S/.wake-queue"
before=$(cat "$HOME_DIR/loop-run-log.md")
stamp_before=$(grep '^Last run:' "$HOME_DIR/STATE.md")
out=$(FM_LOOP_LOG=0 FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$S" \
  "$ROOT/bin/fm-wake-drain.sh"); code=$?
expect_code 0 "$code" "disabled drain must still exit 0"
assert_contains "$out" "fm-gamma" "disabled drain output intact"
[ "$(cat "$HOME_DIR/loop-run-log.md")" = "$before" ] || fail "FM_LOOP_LOG=0 must not touch the run log"
[ "$(grep '^Last run:' "$HOME_DIR/STATE.md")" = "$stamp_before" ] || fail "FM_LOOP_LOG=0 must not restamp STATE.md"

# 3. unwritable log target never perturbs the drain (log path is a directory)
rm -f "$HOME_DIR/loop-run-log.md"; mkdir -p "$HOME_DIR/loop-run-log.md"
printf '1700000003\t4\tsignal\tfm-delta\tstatus\n' > "$S/.wake-queue"
out=$(drain); code=$?
expect_code 0 "$code" "drain must survive an unwritable log target"
assert_contains "$out" "fm-delta" "drain output intact despite log failure"

# 4. observability anchors to the DRAINED QUEUE's home, never a foreign FM_HOME
# (regression: the wake-queue suite drains a temp state dir without FM_HOME and
# must not leak run-log churn into the repo)
OTHER="$TMP/other-home"; mkdir -p "$OTHER/state"
printf '# s\nLast run: never\n' > "$OTHER/STATE.md"; : > "$OTHER/loop-run-log.md"
printf '1700000004\t5\tsignal\tfm-echo\tstatus\n' > "$OTHER/state/.wake-queue"
out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$OTHER/state" \
  "$ROOT/bin/fm-wake-drain.sh"); code=$?
expect_code 0 "$code" "cross-home drain must exit 0"
assert_grep '"run_id"' "$OTHER/loop-run-log.md" "log lands in the drained queue's home"
assert_no_grep "Last run: never" "$OTHER/STATE.md" "stamp lands in the drained queue's home"

# 5. secondmate homes skip loop observability entirely
SM="$TMP/sm-home"; mkdir -p "$SM/state"
touch "$SM/.fm-secondmate-home"
printf '# s\nLast run: never\n' > "$SM/STATE.md"; : > "$SM/loop-run-log.md"
printf '1700000005\t6\tsignal\tfm-foxtrot\tstatus\n' > "$SM/state/.wake-queue"
out=$(FM_ROOT_OVERRIDE='' FM_HOME="$SM" FM_STATE_OVERRIDE="$SM/state" \
  "$ROOT/bin/fm-wake-drain.sh"); code=$?
expect_code 0 "$code" "secondmate drain must exit 0"
assert_contains "$out" "fm-foxtrot" "secondmate drain output intact"
[ ! -s "$SM/loop-run-log.md" ] || fail "secondmate home must not accrue run-log entries"
assert_grep "Last run: never" "$SM/STATE.md" "secondmate STATE.md must not be stamped"

pass "L1 drain instrumentation"
