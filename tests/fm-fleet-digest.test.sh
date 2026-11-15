#!/usr/bin/env bash
# Behavior tests for bin/fm-fleet-digest.sh - the bounded, LLM-free fleet read
# that replaced the per-task metadata-and-status sweep.
#
# The failure this pins: a supervisor sweep that read every state/<id>.meta plus
# a status tail per task cost about 2.9k tokens per task, so a 260-task fleet
# needed roughly 750k tokens for one sweep - more than any compaction trigger -
# and the chair compacted on every attempt without finishing a turn. The digest
# must therefore stay inside a fixed token budget however large the fleet grows,
# which is what the 300-task fixture below measures.
#
# Pinned here: the token budget on a 300-task fleet, the delta path (only what
# changed, plus every exception), the drill byte cap, and the ledger rewrite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIGEST="$ROOT/bin/fm-fleet-digest.sh"
assert_present "$DIGEST" "bin/fm-fleet-digest.sh is missing"
[ -x "$DIGEST" ] || fail "bin/fm-fleet-digest.sh must be executable"

TMP_ROOT=$(fm_test_tmproot fm-fleet-digest)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
# The digest resolves its state directory from FM_STATE_OVERRIDE, so the fixture
# never touches this checkout's own state/.
export FM_STATE_OVERRIDE="$STATE"

# Ages are measured against the observation time, so the fixture's own write
# time is the natural "now": every task starts at 0s and only the tasks a test
# deliberately ages move.
NOW=$(date +%s)

# write_task <id> <kind> <status-line> [<pr>]: one task record plus its newest
# status event.
write_task() {
  local id=$1 kind=$2 line=$3 pr=${4:-}
  {
    printf 'kind=%s\n' "$kind"
    printf 'project=/home/aaron/Projects/Muso.AI/%s\n' "$id"
    printf 'window=fm-%s\n' "$id"
    printf 'backend=tmux\n'
    printf 'model=token-pool/claude-fable-5-2\n'
    [ -z "$pr" ] || printf 'pr=%s\n' "$pr"
  } > "$STATE/$id.meta"
  printf '%s\n' "$line" > "$STATE/$id.status"
}

# --- 1. the token budget on a 300-task fleet --------------------------------
#
# 300 tasks is above the live fleet this was written for, so the budget holds
# with headroom. The assertion is on bytes/4, the same 4-bytes-per-token
# estimate the digest's own --max-bytes default is documented in.

i=0
while [ "$i" -lt 300 ]; do
  i=$((i + 1))
  case $((i % 10)) in
    0) write_task "task-$i" ship "working: implementing step $i of the plan" ;;
    1) write_task "task-$i" ship "done: PR https://github.com/Muso-AI/core-backend/pull/$((10000 + i)) checks green" "https://github.com/Muso-AI/core-backend/pull/$((10000 + i))" ;;
    2) write_task "task-$i" scout "paused [key=await-tick]: idle until 2026-11-16 08:10Z (next scheduled tick)" ;;
    3) write_task "task-$i" ship "blocked: https://github.com/Muso-AI/hydra/pull/$((20000 + i)) has an unanswered qa-review finding on head deadbeef" ;;
    4) write_task "task-$i" ship "needs-decision [key=nm-01M7FAKH3YGPRQ6TH8H1RAM72E-review3]: ask-user findings=f1 file=/tmp/findings.txt" ;;
    *) write_task "task-$i" ship "working: step $i" ;;
  esac
done

OUT=$("$DIGEST" --now "$NOW" 2>&1) || fail "digest exited non-zero: $OUT"
BYTES=${#OUT}
TOKENS=$((BYTES / 4))
[ "$TOKENS" -le 15000 ] ||
  fail "300-task digest must stay within 15000 estimated tokens, got $TOKENS ($BYTES bytes)"
pass "300-task digest stays within the token budget ($BYTES bytes, ~$TOKENS tokens)"

assert_contains "$OUT" "fleet digest: 300 task(s)" "the digest must count every task record"
assert_contains "$OUT" "task-1 | done | ship |" "a done task must report its state word"
assert_contains "$OUT" "task-3 | blocked | ship |" "a blocked task must report its state word"
assert_contains "$OUT" "task-2 | paused | scout |" "a paused task must report its state word"
assert_contains "$OUT" "task-10 | working | ship |" "a working task must report its state word"
assert_contains "$OUT" "ledger: $STATE/fleet-ledger.md" "the digest must name the ledger it wrote"

# The newest status line is capped, so one pathological status line cannot
# spend the whole budget.
write_task "task-long" ship "working: $(printf 'x%.0s' $(seq 1 4000))"
OUT=$("$DIGEST" --now "$NOW" 2>&1) || fail "digest exited non-zero with a long status line"
assert_contains "$OUT" "[truncated]" "a long status line must be cut, not printed whole"
case "$OUT" in
  *"$(printf 'x%.0s' $(seq 1 200))"*) fail "a long status line must be cut to the head cap" ;;
esac
rm -f "$STATE/task-long.meta" "$STATE/task-long.status"

# --- 2. exceptions always print, and only exceptions are exceptions ---------

OUT=$("$DIGEST" --now "$NOW" 2>&1) || fail "digest exited non-zero"
EXC_HEADER=$(printf '%s\n' "$OUT" | sed -n 's/^fleet digest: .* \([0-9][0-9]*\) exception(s).*/\1/p')
[ -n "$EXC_HEADER" ] || fail "the digest header must report an exception count"
# 30 done-with-PR (awaiting gate), 30 paused, 30 blocked, 30 needs-decision.
[ "$EXC_HEADER" = 120 ] ||
  fail "expected 120 exceptions (done+PR, paused, blocked, needs-decision), got $EXC_HEADER"

# A done task whose merge outcome was already delivered is landed, not a gate.
write_task "task-landed" ship "done: PR https://github.com/Muso-AI/hydra/pull/999 checks green" "https://github.com/Muso-AI/hydra/pull/999"
printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nMuso-AI/hydra\n999\n' > "$STATE/task-landed.pr-poll-merge-notified"
chmod 600 "$STATE/task-landed.pr-poll-merge-notified"
# A marker from an earlier PR for the same task must not classify a new
# awaiting-gate PR as landed.
write_task "task-stale" ship "done: PR https://github.com/Muso-AI/hydra/pull/1234 checks green" "https://github.com/Muso-AI/hydra/pull/1234"
printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nMuso-AI/hydra\n999\n' > "$STATE/task-stale.pr-poll-merge-notified"
chmod 600 "$STATE/task-stale.pr-poll-merge-notified"
# A working task whose status log has not moved is stalled, and stalled is an
# exception even though its newest event says working.
write_task "task-stalled" ship "working: long-running step"
touch -d "@$((NOW - 7200))" "$STATE/task-stalled.status" 2>/dev/null ||
  touch -t 202611142200 "$STATE/task-stalled.status"
# An orphan status log has no task record: it is counted, never a task row.
printf 'working: orphan\n' > "$STATE/orphan-lane.status"

OUT=$("$DIGEST" --now "$NOW" 2>&1) || fail "digest exited non-zero"
assert_contains "$OUT" "task-landed | landed | ship |" "a done task with a delivered merge outcome must read landed"
assert_contains "$OUT" "task-stale | done | ship |" "a stale merge marker must not classify a new PR as landed"
assert_not_contains "$OUT" "task-stale | landed | ship |" "a stale merge marker must leave the new PR awaiting gate"
assert_contains "$OUT" "task-stalled | working | ship | 2h |" "a stalled task must report its age"
STALLED_EXC=$(printf '%s\n' "$OUT" | sed -n 's/^fleet digest: .* \([0-9][0-9]*\) exception(s).*/\1/p')
[ "$STALLED_EXC" = 122 ] || fail "a stalled working task and an awaiting-gate stale-marker task must count as exceptions, got $STALLED_EXC"
assert_contains "$OUT" "orphan status log(s)" "an orphan status log must be counted"
assert_not_contains "$OUT" "orphan-lane |" "an orphan status log must not take a task row"
rm -f "$STATE/task-landed.meta" "$STATE/task-landed.status" "$STATE/task-landed.pr-poll-merge-notified"
rm -f "$STATE/task-stale.meta" "$STATE/task-stale.status" "$STATE/task-stale.pr-poll-merge-notified"
rm -f "$STATE/task-stalled.meta" "$STATE/task-stalled.status" "$STATE/orphan-lane.status"

# --- 3. the delta path ------------------------------------------------------

CURSOR="$STATE/.fleet-digest-cursor"
rm -f "$CURSOR"
OUT=$("$DIGEST" --since --now "$NOW" 2>&1) || fail "digest --since exited non-zero"
assert_contains "$OUT" "delta since the beginning" "a first delta with no cursor must say so"
assert_contains "$OUT" "task-1 | done | ship |" "a first delta with no cursor must print every task"
assert_present "$CURSOR" "the delta path must write its cursor"
CURSOR_VALUE=$(sed -n '1p' "$CURSOR")
[ "$CURSOR_VALUE" = "$NOW" ] || fail "the cursor must record the observation time, got '$CURSOR_VALUE'"

# Nothing changed: only the exceptions print, and the header says so.
OUT=$("$DIGEST" --since --now "$((NOW + 60))" 2>&1) || fail "digest --since exited non-zero"
assert_contains "$OUT" "delta since $NOW" "the delta header must name the cursor it used"
assert_not_contains "$OUT" "task-10 | working | ship |" "an unchanged routine task must not print in a delta"
assert_contains "$OUT" "task-3 | blocked | ship |" "an exception must print in a delta even when unchanged"

# One task changes: exactly that task joins the delta.
touch -d "@$((NOW + 120))" "$STATE/task-10.status" 2>/dev/null ||
  touch -t 202611150002 "$STATE/task-10.status"
OUT=$("$DIGEST" --since --now "$((NOW + 180))" 2>&1) || fail "digest --since exited non-zero"
assert_contains "$OUT" "task-10 | working | ship |" "a changed task must print in a delta"
assert_not_contains "$OUT" "task-20 | working | ship |" "an unchanged routine task must stay out of a delta"

# --no-advance leaves the cursor alone.
BEFORE=$(sed -n '1p' "$CURSOR")
"$DIGEST" --since --no-advance --now "$((NOW + 600))" >/dev/null 2>&1 || fail "digest --since --no-advance exited non-zero"
AFTER=$(sed -n '1p' "$CURSOR")
[ "$BEFORE" = "$AFTER" ] || fail "--no-advance must not move the cursor ($BEFORE -> $AFTER)"
pass "the delta path prints only what changed, plus every exception"

# --- 4. the drill byte cap --------------------------------------------------

BIG="$STATE/task-1.status"
{
  printf 'working: start\n'
  i=0
  while [ "$i" -lt 400 ]; do
    printf 'note: line %s of a long status log that must not be printed whole\n' "$i"
    i=$((i + 1))
  done
} > "$BIG"
OUT=$("$DIGEST" --drill task-1 --bytes 1024 --now "$NOW" 2>&1) || fail "digest --drill exited non-zero"
assert_contains "$OUT" "drill task-1" "the drill must name the task"
assert_contains "$OUT" "status tail (last 1024 bytes" "the drill must name its byte cap"
DRILL_BYTES=${#OUT}
[ "$DRILL_BYTES" -lt 4000 ] ||
  fail "a 1024-byte drill must stay small, got $DRILL_BYTES bytes"
assert_present "$STATE/digest/task-1.probe" "the drill must write its probe under state/digest/"
assert_not_contains "$OUT" "line 0 of a long status log" "the drill must print the tail, not the whole status log"
pass "the drill caps its status tail and writes its probe to a file"

# A drill on a task with no record at all is a clear refusal, not a crash.
OUT=$("$DIGEST" --drill no-such-task --now "$NOW" 2>&1)
RC=$?
[ "$RC" -ne 0 ] || fail "a drill on a missing task must exit non-zero"
assert_contains "$OUT" "no task record" "a drill on a missing task must say so"

# --- 5. the ledger ----------------------------------------------------------

LEDGER="$STATE/fleet-ledger.md"
assert_present "$LEDGER" "the digest must write the ledger"
LEDGER_BODY=$(cat "$LEDGER")
assert_contains "$LEDGER_BODY" "# Fleet ledger" "the ledger must carry its title"
assert_contains "$LEDGER_BODY" "tasks: 300" "the ledger must count every task"
assert_contains "$LEDGER_BODY" "## Exceptions" "the ledger must carry the exceptions section"
assert_contains "$LEDGER_BODY" "## Tasks" "the ledger must carry the task table"
assert_contains "$LEDGER_BODY" "task-11 | done | ship |" "the ledger must carry one line per task"
assert_contains "$LEDGER_BODY" "state is the newest status EVENT" "the ledger must say its state is not a live read"

# --since only filters stdout: the shared ledger must still hold every task.
LEDGER_ROWS_BEFORE=$(grep -c '^task-[0-9][0-9]* |' "$LEDGER")
"$DIGEST" --since --no-advance --now "$((NOW + 900))" >/dev/null 2>&1 || fail "digest --since exited non-zero"
"$DIGEST" --since --no-advance --now "$((NOW + 960))" >/dev/null 2>&1 || fail "digest --since exited non-zero"
LEDGER_ROWS_AFTER=$(grep -c '^task-[0-9][0-9]* |' "$LEDGER")
[ "$LEDGER_ROWS_BEFORE" = "$LEDGER_ROWS_AFTER" ] ||
  fail "a no-change --since run must leave the ledger row count unchanged ($LEDGER_ROWS_BEFORE -> $LEDGER_ROWS_AFTER)"

# The ledger is rewritten, not appended: a second run must not double it.
"$DIGEST" --now "$NOW" >/dev/null 2>&1 || fail "digest exited non-zero"
SECOND=$(grep -c '^task-11 | done | ship |' "$LEDGER")
[ "$SECOND" = 1 ] || fail "the ledger must be rewritten, not appended (task-11 appears $SECOND times)"

# --ledger-only writes the ledger and prints nothing.
OUT=$("$DIGEST" --ledger-only --now "$NOW" 2>&1)
[ -z "$OUT" ] || fail "--ledger-only must print nothing, got: $OUT"
assert_present "$LEDGER" "--ledger-only must still write the ledger"
pass "the ledger is rewritten each cycle and holds one line per task"

# --- 6. the byte cap --------------------------------------------------------

OUT=$("$DIGEST" --max-bytes 2000 --now "$NOW" 2>&1) || fail "digest --max-bytes exited non-zero"
CAP_BYTES=${#OUT}
[ "$CAP_BYTES" -lt 4000 ] || fail "a 2000-byte cap must bound the output, got $CAP_BYTES bytes"
assert_contains "$OUT" "omitted by the 2000-byte cap" "a capped digest must disclose what it omitted"
pass "the byte cap bounds the output and discloses what it omitted"

printf 'all fm-fleet-digest tests passed\n'
