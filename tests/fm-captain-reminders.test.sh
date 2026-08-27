#!/usr/bin/env bash
# Behavior tests for the one-way projection of captain calls into Reminders:
# what a sync derives from the backlog, that reruns never duplicate, that a call
# the captain no longer owns is ticked off rather than deleted, that an entry
# without the `[fm:<task-id>]` marker is never touched, that the whole thing is
# inert until this home opts in, and that a wedged Reminders step is bounded
# instead of hanging its caller.
#
# The Reminders app itself is replaced through FM_REMINDERS_EXEC by the fake
# below, so this suite runs anywhere - including CI, which has no Reminders and
# no automation authorization.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REMINDERS="$ROOT/bin/fm-captain-reminders.sh"
HOLD="$ROOT/bin/fm-captain-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-reminders)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# --- a stand-in for the Reminders app ----------------------------------------
#
# One TSV row per reminder: completed<TAB>name<TAB>body<TAB>due. It matches
# entries exactly the way the real AppleScript does - on the `[fm:<id>]` body
# prefix, never on a name or a row position - so a test that shows an unmarked
# row surviving is showing the real matching rule surviving, not a convenience
# of the fake.
STORE="$TMP_ROOT/reminders.tsv"
FAKE="$TMP_ROOT/fake-reminders.sh"
cat > "$FAKE" <<'FAKE_EOF'
#!/usr/bin/env bash
set -u
store=${FAKE_REMINDERS_STORE:?}
[ -f "$store" ] || : > "$store"
verb=$1
shift
[ -z "${FAKE_REMINDERS_LOG:-}" ] || printf '%s\n' "$verb" >> "$FAKE_REMINDERS_LOG"
if [ -n "${FAKE_REMINDERS_HANG:-}" ] \
  && { [ -z "${FAKE_REMINDERS_HANG_VERB:-}" ] || [ "$FAKE_REMINDERS_HANG_VERB" = "$verb" ]; }; then
  sleep "$FAKE_REMINDERS_HANG"
  exit 0
fi
[ -z "${FAKE_REMINDERS_FAIL:-}" ] || { printf '%s\n' "$FAKE_REMINDERS_FAIL" >&2; exit 1; }
case "$verb" in
  list)
    awk -F'\t' -v OFS='\t' '$1 == "0" && $3 ~ /^\[fm:[A-Za-z0-9._-]+\]/ {
      id = $3
      sub(/^\[fm:/, "", id)
      sub(/\].*$/, "", id)
      # A synthetic reminder identity and age: the store never removes a row, so
      # its line number is stable within a run and earlier lines are older.
      print id, "r" NR, ($4 == "1" ? "1" : "0"), NR - 1000
    }' "$store"
    ;;
  upsert)
    prefix="[fm:$2]"
    name=$3
    body=$4
    due=$5
    if [ -n "${FAKE_REMINDERS_COMPLETE_BEFORE_UPSERT:-}" ]; then
      awk -F'\t' -v OFS='\t' -v p="$prefix" 'BEGIN { n = length(p) } $1 == "0" && substr($3, 1, n) == p { $1 = "1" } { print }' "$store" > "$store.tmp" && mv "$store.tmp" "$store"
    fi
    exists=0
    if awk -F'\t' -v p="$prefix" 'BEGIN { n = length(p) }
      $1 == "0" && substr($3, 1, n) == p { found = 1 } END { exit !found }' "$store"; then
      exists=1
    fi
    if [ -n "${FAKE_REMINDERS_GATE:-}" ]; then
      : > "$FAKE_REMINDERS_GATE.entered"
      while [ ! -e "$FAKE_REMINDERS_GATE.release" ]; do sleep 0.05; done
    fi
    if [ "$exists" -eq 1 ]; then
      before=$(cat "$store")
      awk -F'\t' -v OFS='\t' -v p="$prefix" -v n="$name" -v b="$body" '
        BEGIN { len = length(p) }
        $1 == "0" && substr($3, 1, len) == p && !done { $2 = n; $3 = b; done = 1 }
        { print }
      ' "$store" > "$store.tmp" && mv "$store.tmp" "$store"
      if [ "$before" = "$(cat "$store")" ]; then printf 'unchanged\n'; else printf 'updated\n'; fi
    else
      printf '0\t%s\t%s\t%s\n' "$name" "$body" "$due" >> "$store"
      printf 'created\n'
    fi
    ;;
  complete)
    prefix="[fm:$2]"
    awk -F'\t' -v OFS='\t' -v p="$prefix" '
      BEGIN { len = length(p) }
      $1 == "0" && substr($3, 1, len) == p { $1 = "1"; n++ }
      { print }
      END { }
    ' "$store" > "$store.tmp" && mv "$store.tmp" "$store"
    printf '1\n'
    ;;
  complete-one)
    # Named reminder, but still only among entries carrying the marker: the id
    # alone can never reach an unmarked row.
    prefix="[fm:$2]"
    target=$3
    awk -F'\t' -v OFS='\t' -v p="$prefix" -v t="$target" '
      BEGIN { len = length(p) }
      $1 == "0" && substr($3, 1, len) == p && ("r" NR) == t { $1 = "1"; n++ }
      { print }
      END { }
    ' "$store" > "$store.tmp" && mv "$store.tmp" "$store"
    printf '1\n'
    ;;
  *) printf 'unknown verb %s\n' "$verb" >&2; exit 2 ;;
esac
FAKE_EOF
chmod +x "$FAKE"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF

axi() { (cd "$HOME_DIR" && tasks-axi "$@" >/dev/null); }

run() {  # <args...>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$STORE" \
    "$REMINDERS" "$@"
}

rows() { awk 'END { print NR }' "$STORE"; }

row_for() {  # <task-id>
  grep -F "[fm:$1]" "$STORE" 2>/dev/null || true
}

# --- inert until this home opts in -------------------------------------------

axi add call-a "Pick the exec path" --repo demo
axi hold call-a --reason "three ways forward and the worker is stopped" --kind captain

: > "$STORE"
OUT=$(run sync 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "a home that never opted in must exit 0, got $RC"
[ -z "$OUT" ] || fail "a home that never opted in must say nothing, got: $OUT"
[ "$(rows)" = 0 ] || fail "a home that never opted in must not reach the Reminders app at all"
OUT=$(run status 2>&1)
[ -z "$OUT" ] || fail "status must be silent when this home never opted in, got: $OUT"
pass "every command is a silent no-op until config/captain-reminders exists"

printf '\n' > "$HOME_DIR/config/captain-reminders"

# --- a plan that changes nothing ---------------------------------------------

OUT=$(run status 2>&1)
assert_contains "$OUT" "would add call-a" "status names the call it would add"
[ "$(rows)" = 0 ] || fail "status must not write to the list"
pass "status prints the plan and touches nothing"

# --- the projection itself ----------------------------------------------------

OUT=$(run sync 2>&1)
assert_contains "$OUT" "added call-a" "sync reports the call it added"
[ "$(rows)" = 1 ] || fail "expected exactly one reminder, list holds: $(cat "$STORE")"
assert_contains "$(row_for call-a)" "Pick the exec path" "the reminder is titled with the task title"
assert_contains "$(row_for call-a)" "three ways forward" "the reminder note carries the hold reason"
assert_contains "$(row_for call-a)" "[fm:call-a]" "the reminder note carries the task marker"
case "$(row_for call-a)" in
  *$'\t'0) pass "an unnamed call is projected without an alert" ;;
  *) fail "an unnamed call must not be given a due time: $(row_for call-a)" ;;
esac

# --- reruns are idempotent -----------------------------------------------------

BEFORE=$(cat "$STORE")
run sync >/dev/null 2>&1
run sync >/dev/null 2>&1
[ "$(rows)" = 1 ] || fail "reruns duplicated the reminder: $(cat "$STORE")"
[ "$BEFORE" = "$(cat "$STORE")" ] || fail "an unchanged rerun must not rewrite the entry"
pass "a rerun recognizes its own entry and never creates a second one"
OUT=$(run status 2>&1)
assert_contains "$OUT" "would check call-a" "status describes checking an existing entry"
assert_contains "$OUT" "only if its title or reason changed" "status limits refreshes to real drift"
assert_not_contains "$OUT" "would refresh call-a" "status does not claim an unchanged entry will be rewritten"
pass "status reports a conditional check rather than an unconditional refresh"


# --- concurrent projections serialize without waiting -------------------------

CONCURRENT_STORE="$TMP_ROOT/concurrent-reminders.tsv"
CONCURRENT_LOG="$TMP_ROOT/concurrent-reminders.log"
CONCURRENT_GATE="$TMP_ROOT/concurrent-gate"
FIRST_OUT="$TMP_ROOT/concurrent-first.out"
: > "$CONCURRENT_STORE"
: > "$CONCURRENT_LOG"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$CONCURRENT_STORE" \
  FAKE_REMINDERS_LOG="$CONCURRENT_LOG" FAKE_REMINDERS_GATE="$CONCURRENT_GATE" \
  "$REMINDERS" sync >"$FIRST_OUT" 2>&1 &
FIRST_PID=$!
attempt=0
while [ ! -e "$CONCURRENT_GATE.entered" ] && kill -0 "$FIRST_PID" 2>/dev/null \
  && [ "$attempt" -lt 100 ]; do
  sleep 0.05
  attempt=$((attempt + 1))
done
if [ ! -e "$CONCURRENT_GATE.entered" ]; then
  : > "$CONCURRENT_GATE.release"
  wait "$FIRST_PID" 2>/dev/null || true
  fail "the first concurrent projection never reached its create boundary"
fi
SECOND_OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$CONCURRENT_STORE" \
  FAKE_REMINDERS_LOG="$CONCURRENT_LOG" "$REMINDERS" sync 2>&1)
SECOND_RC=$?
: > "$CONCURRENT_GATE.release"
wait "$FIRST_PID" || fail "the lock-owning projection failed: $(cat "$FIRST_OUT")"
[ "$SECOND_RC" -eq 0 ] || fail "a concurrent projection must skip with exit 0, got $SECOND_RC"
[ -z "$SECOND_OUT" ] || fail "a concurrent projection must skip silently, got: $SECOND_OUT"
[ "$(awk 'END { print NR }' "$CONCURRENT_STORE")" = 1 ] \
  || fail "concurrent projections created duplicates: $(cat "$CONCURRENT_STORE")"
[ "$(grep -c '^list$' "$CONCURRENT_LOG")" = 1 ] \
  || fail "the skipped projection reached Reminders: $(cat "$CONCURRENT_LOG")"
pass "a concurrent projection skips silently and cannot duplicate an entry"

STALE_LOCK="$HOME_DIR/state/.captain-reminders.lock"
: > "$CONCURRENT_LOG"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$STATE/.captain-reminders.lock" || exit 1; kill -9 "$$"' \
  _ "$ROOT" >/dev/null 2>&1 || true
[ -L "$STALE_LOCK" ] || fail "the stale-lock fixture did not leave the helper-owned lock"
FM_LOCK_STALE_AFTER=0 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_REMINDERS_EXEC="$FAKE" \
  FAKE_REMINDERS_STORE="$CONCURRENT_STORE" FAKE_REMINDERS_LOG="$CONCURRENT_LOG" \
  "$REMINDERS" sync >/dev/null 2>&1
[ "$(grep -c '^list$' "$CONCURRENT_LOG")" = 1 ] \
  || fail "a dead lock owner blocked the next projection: $(cat "$CONCURRENT_LOG")"
[ "$(awk 'END { print NR }' "$CONCURRENT_STORE")" = 1 ] \
  || fail "stale-lock recovery duplicated the entry: $(cat "$CONCURRENT_STORE")"
pass "a projection reclaims a lock whose owner process died"

# --- a named push never stands down on lock contention ------------------------
#
# An ordinary projection may skip, because the lock holder is deriving the same
# set. A --notify projection may not: the holder's snapshot predates this call,
# so skipping would drop the one alert the caller authorized, silently.

: > "$CONCURRENT_STORE"
: > "$CONCURRENT_LOG"
rm -f "$CONCURRENT_GATE.entered" "$CONCURRENT_GATE.release"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$CONCURRENT_STORE" \
  FAKE_REMINDERS_LOG="$CONCURRENT_LOG" FAKE_REMINDERS_GATE="$CONCURRENT_GATE" \
  "$REMINDERS" sync >"$FIRST_OUT" 2>&1 &
FIRST_PID=$!
attempt=0
while [ ! -e "$CONCURRENT_GATE.entered" ] && kill -0 "$FIRST_PID" 2>/dev/null \
  && [ "$attempt" -lt 100 ]; do
  sleep 0.05
  attempt=$((attempt + 1))
done
if [ ! -e "$CONCURRENT_GATE.entered" ]; then
  : > "$CONCURRENT_GATE.release"
  wait "$FIRST_PID" 2>/dev/null || true
  fail "the lock-owning projection never reached its create boundary"
fi
NOTIFY_START=$(date +%s)
NOTIFY_OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$CONCURRENT_STORE" \
  FAKE_REMINDERS_LOG="$CONCURRENT_LOG" FM_REMINDERS_TIMEOUT_SECS=2 \
  "$REMINDERS" sync --notify call-a 2>&1)
NOTIFY_RC=$?
NOTIFY_ELAPSED=$(( $(date +%s) - NOTIFY_START ))
: > "$CONCURRENT_GATE.release"
wait "$FIRST_PID" 2>/dev/null || true
[ "$NOTIFY_RC" -ne 0 ] \
  || fail "a named push that never reached the list must not report success"
assert_contains "$NOTIFY_OUT" "NOT delivered" \
  "a named push that ran out of time says the alert was not delivered"
assert_contains "$NOTIFY_OUT" "call-a" "the undelivered alert names the call it was for"
[ "$NOTIFY_ELAPSED" -ge 1 ] \
  || fail "a named push must wait for the lock, not stand down immediately (${NOTIFY_ELAPSED}s)"
[ "$NOTIFY_ELAPSED" -lt 30 ] \
  || fail "a named push must stop waiting at its own deadline (${NOTIFY_ELAPSED}s)"
pass "a named push waits for the lock and reports an undelivered alert rather than exiting clean"

# --- a call that is not held for the captain is not projected ------------------

axi add ordinary-b "Ordinary work" --repo demo
axi add other-c "Waiting on a vendor" --repo demo
axi hold other-c --reason "upstream release is not out" --kind external
run sync >/dev/null 2>&1
[ "$(rows)" = 1 ] || fail "only captain-held tasks belong in the list: $(cat "$STORE")"
pass "ordinary work and other kinds of hold stay out of the captain's list"

# --- content drift updates in place, never delete-and-recreate -----------------

axi update call-a --title "Pick the exec path (narrowed)"
axi hold call-a --reason "narrowed to A or C; the worker is still stopped" --kind captain
OUT=$(run sync 2>&1)
assert_contains "$OUT" "refreshed call-a" "sync reports the entry it refreshed"
[ "$(rows)" = 1 ] || fail "a content change must update in place, not add a row"
assert_contains "$(row_for call-a)" "narrowed to A or C" "the note follows the new hold reason"
assert_contains "$(row_for call-a)" "(narrowed)" "the title follows the new task title"
pass "a changed title or reason updates the existing entry in place"

# --- an unmarked entry is never touched ----------------------------------------

printf '0\tPick the exec path\tthe captain wrote this himself\t0\n' >> "$STORE"
printf '0\tcall-a\t\t0\n' >> "$STORE"
CAPTAINS_OWN=$(grep -c 'captain wrote this himself' "$STORE")
axi unhold call-a
run sync >/dev/null 2>&1
assert_contains "$(cat "$STORE")" $'0\tPick the exec path\tthe captain wrote this himself\t0' \
  "an unmarked reminder is left exactly as the captain wrote it"
assert_contains "$(cat "$STORE")" $'0\tcall-a\t\t0' \
  "an unmarked reminder is not matched by a name that looks like a task id"
[ "$(grep -c 'captain wrote this himself' "$STORE")" = "$CAPTAINS_OWN" ] \
  || fail "an unmarked reminder was duplicated or removed"
pass "entries without the marker are never renamed, rewritten, or completed"

# --- closing a call ticks the entry off and never deletes it -------------------

assert_contains "$(row_for call-a)" "narrowed to A or C" "the closed call's entry survives"
case "$(row_for call-a)" in
  1$'\t'*) pass "a call the captain no longer holds is marked completed, not deleted" ;;
  *) fail "expected the entry to be completed, got: $(row_for call-a)" ;;
esac

# --- a re-held call gets a fresh entry rather than reopening the old one --------

axi hold call-a --reason "reopened after the worker reported back" --kind captain
run sync >/dev/null 2>&1
assert_contains "$(row_for call-a)" "reopened after the worker" "a re-held call is projected again"
[ "$(printf '%s\n' "$(row_for call-a)" | grep -c .)" = 2 ] \
  || fail "expected the completed entry plus a fresh one, got: $(row_for call-a)"
pass "re-holding a closed call adds a new entry and leaves the completed one alone"

# --- pushing is by name only ---------------------------------------------------

axi unhold call-a
run sync >/dev/null 2>&1
axi add call-d "Approve the migration window" --repo demo
axi hold call-d --reason "nothing ships until this is settled" --kind captain
OUT=$(run sync --notify call-d 2>&1)
assert_contains "$OUT" "alerted the captain" "a named call reports that it alerted the captain"
case "$(row_for call-d)" in
  *$'\t'1) pass "a named call is created with a due time so Reminders raises it" ;;
  *) fail "expected a due time on the named call, got: $(row_for call-d)" ;;
esac
OUT=$(run sync --notify call-d 2>&1)
assert_not_contains "$OUT" "alerted the captain" "a rerun does not re-alert a call already projected"
OUT=$(FAKE_REMINDERS_COMPLETE_BEFORE_UPSERT=1 run sync --notify call-d 2>&1)
ACTIVE_CALL_D=$(row_for call-d | grep '^0' || true)
assert_contains "$OUT" "alerted the captain" "a named call completed after listing still alerts its replacement"
case "$ACTIVE_CALL_D" in
  *$'\t'1) pass "a replacement created after a stale list snapshot keeps its due time" ;;
  *) fail "the replacement lost its due time: $(row_for call-d)" ;;
esac

OUT=$(run sync --notify not-a-real-task 2>&1)
assert_contains "$OUT" "nothing to alert for not-a-real-task" \
  "a named task that is not a captain call is reported rather than silently dropped"
pass "an alert happens only when the caller names the call, and only on first projection"

# --- a long reason is bounded and says so --------------------------------------

LONG=$(awk 'BEGIN { while (i++ < 1200) printf "x" }')
axi add call-e "Long one" --repo demo
axi hold call-e --reason "$LONG" --kind captain
run sync >/dev/null 2>&1
assert_contains "$(row_for call-e)" "Firstmate 会话" "an over-long reason points back to the Firstmate session"
assert_not_contains "$(row_for call-e)" "on the task" "the captain-facing notice does not point at an internal task"
NOTE_LEN=$(row_for call-e | awk -F'\t' '{ print length($3) }')
[ "$NOTE_LEN" -lt 1000 ] || fail "an over-long reason must be bounded, note is $NOTE_LEN characters"
pass "an unusually long reason is bounded and points back to the session"


# --- deferred calls leave the list until their date ----------------------------

axi add call-future "Revisit the launch plan" --repo demo
axi hold call-future --reason "captain will revisit this later" --kind captain
run sync >/dev/null 2>&1
axi hold call-future --reason "captain will revisit this later" --kind captain --until 2999-01-01
run sync >/dev/null 2>&1
case "$(row_for call-future)" in
  1$'\t'*) pass "a future captain deferral is removed from the live projection" ;;
  *) fail "a future captain deferral stayed live: $(row_for call-future)" ;;
esac

axi add call-due "Decide the overdue launch plan" --repo demo
axi hold call-due --reason "captain decision is due again" --kind captain --until 2000-01-01
run sync >/dev/null 2>&1
assert_contains "$(row_for call-due)" "captain decision is due again" \
  "a due captain deferral is projected despite tasks-axi's expired held bit"
pass "captain deferrals stay hidden before their date and return when due"
# --- a wedged Reminders step is bounded, never a hang --------------------------

TIMEOUT_STORE="$TMP_ROOT/timeout-reminders.tsv"
TIMEOUT_LOG="$TMP_ROOT/timeout-reminders.log"
: > "$TIMEOUT_STORE"
: > "$TIMEOUT_LOG"
START=$(date +%s)
OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$TIMEOUT_STORE" \
  FAKE_REMINDERS_LOG="$TIMEOUT_LOG" FAKE_REMINDERS_HANG=60 \
  FAKE_REMINDERS_HANG_VERB=upsert FM_REMINDERS_TIMEOUT_SECS=6 \
  "$REMINDERS" sync 2>&1)
RC=$?
ELAPSED=$(( $(date +%s) - START ))
# Bounded well under the 60s wedge, but not so tight that the backlog read - one
# tasks-axi subprocess per open task - can be what expires on a loaded machine.
[ "$ELAPSED" -lt 25 ] || fail "a wedged Reminders step held the caller for ${ELAPSED}s"
[ "$RC" -ne 0 ] || fail "a wedged Reminders step must be reported as a failure"
[ ! -e "$HOME_DIR/state/.captain-reminders.lock" ] && [ ! -L "$HOME_DIR/state/.captain-reminders.lock" ] \
  || fail "an unwrapped session-start-style timeout left the projection lock held"
[ "$(grep -c '^list$' "$TIMEOUT_LOG")" = 1 ] || fail "the deadline test did not list once: $(cat "$TIMEOUT_LOG")"
[ "$(grep -c '^upsert$' "$TIMEOUT_LOG")" = 1 ] || fail "the whole deadline allowed repeated wedged upserts: $(cat "$TIMEOUT_LOG")"
assert_not_contains "$(cat "$TIMEOUT_LOG")" "complete" "no further Reminders calls run after the deadline"
assert_contains "$OUT" "3 entries were left unprocessed" "the caller is told the exact unprocessed remainder"
assert_contains "$OUT" "Automation" "the caller is told where to approve the automation prompt"
pass "a wedged multi-entry sync stops at one whole-command deadline (${ELAPSED}s)"


# --- an unreadable backlog snapshot touches no reminders ----------------------

REAL_TASKS_AXI=$(command -v tasks-axi)
BROKEN_BIN="$TMP_ROOT/broken-tasks-bin"
mkdir -p "$BROKEN_BIN"
cat > "$BROKEN_BIN/tasks-axi" <<'BROKEN_EOF'
#!/usr/bin/env bash
case "${FAKE_TASKS_AXI_MODE:-}:${1:-}" in
  malformed-list:list)
    printf '%s\n' 'count: 1' 'tasks[1]{id,state,kind,repo,title}:' '  malformed row'
    exit 0
    ;;
  fail-show:show) exit 9 ;;
  hang-list:list|hang-show:show) sleep 60; exit 0 ;;
esac
exec "${REAL_TASKS_AXI:?}" "$@"
BROKEN_EOF
chmod +x "$BROKEN_BIN/tasks-axi"

FAILURE_STORE="$TMP_ROOT/failure-reminders.tsv"
FAILURE_LOG="$TMP_ROOT/failure-reminders.log"
printf '0\tStale read\t[fm:stale-read] old reason\t0\n' > "$FAILURE_STORE"
for mode in hang-list hang-show; do
  BEFORE=$(cat "$FAILURE_STORE")
  : > "$FAILURE_LOG"
  START=$(date +%s)
  OUT=$(PATH="$BROKEN_BIN:$PATH" REAL_TASKS_AXI="$REAL_TASKS_AXI" FAKE_TASKS_AXI_MODE="$mode" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$FAILURE_STORE" \
    FAKE_REMINDERS_LOG="$FAILURE_LOG" FM_REMINDERS_TIMEOUT_SECS=2 \
    "$REMINDERS" sync 2>&1)
  RC=$?
  ELAPSED=$(( $(date +%s) - START ))
  [ "$ELAPSED" -lt 10 ] || fail "$mode backlog read held the caller for ${ELAPSED}s"
  [ "$RC" -ne 0 ] || fail "$mode backlog timeout reported success"
  assert_contains "$OUT" "backlog snapshot was left incomplete" \
    "$mode timeout names the incomplete snapshot"
  [ "$BEFORE" = "$(cat "$FAILURE_STORE")" ] || fail "$mode backlog timeout changed reminders"
  [ ! -s "$FAILURE_LOG" ] || fail "$mode backlog timeout reached Reminders: $(cat "$FAILURE_LOG")"
done
pass "list and show reads share the whole projection deadline"

for mode in malformed-list fail-show; do
  BEFORE=$(cat "$FAILURE_STORE")
  : > "$FAILURE_LOG"
  OUT=$(PATH="$BROKEN_BIN:$PATH" REAL_TASKS_AXI="$REAL_TASKS_AXI" FAKE_TASKS_AXI_MODE="$mode" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$FAILURE_STORE" \
    FAKE_REMINDERS_LOG="$FAILURE_LOG" "$REMINDERS" sync 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail "$mode backlog failure reported success"
  assert_contains "$OUT" "could not read or parse the captain backlog snapshot" \
    "$mode backlog failure names the abandoned snapshot"
  [ "$BEFORE" = "$(cat "$FAILURE_STORE")" ] || fail "$mode backlog failure changed reminders"
  [ ! -s "$FAILURE_LOG" ] || fail "$mode backlog failure reached Reminders: $(cat "$FAILURE_LOG")"
done
pass "failed and malformed backlog reads abort before touching Reminders"

# --- a genuinely empty captain backlog completes stale entries ----------------

axi unhold call-d
axi unhold call-e
axi unhold call-due
axi unhold call-future
printf '0\tAnswered call\t[fm:empty-stale] old reason\t0\n' >> "$STORE"
OUT=$(run sync 2>&1)
assert_contains "$OUT" "ticked off empty-stale" "an empty captain snapshot still completes stale entries"
case "$(row_for empty-stale)" in
  1$'\t'*) pass "a genuinely empty captain snapshot completes stale marked entries" ;;
  *) fail "an empty captain snapshot did not complete its stale entry: $(row_for empty-stale)" ;;
esac
# --- a refused authorization reads as instructions, not an error number ---------

OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$STORE" \
  FAKE_REMINDERS_FAIL="execution error: Not authorized to send Apple events to Reminders. (-1743)" \
  "$REMINDERS" sync 2>&1)
assert_contains "$OUT" "has not authorized" "a refused authorization is named in plain words"
assert_contains "$OUT" "System Settings" "a refused authorization says where to approve it"
pass "a refused authorization prints what to do about it"

# --- a home with no Reminders app at all ---------------------------------------

NOT_MAC="$TMP_ROOT/not-mac"
mkdir -p "$NOT_MAC"
printf '#!/usr/bin/env bash\nprintf "Linux\\n"\n' > "$NOT_MAC/uname"
chmod +x "$NOT_MAC/uname"
OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  PATH="$NOT_MAC:$PATH" "$REMINDERS" sync 2>&1)
RC=$?
[ "$RC" -eq 0 ] || fail "a host without osascript must exit 0, got $RC"
assert_contains "$OUT" "needs macOS" "a host without osascript says so in one line"
pass "a host that cannot run the projection skips it cleanly"

# --- the hold and answer paths keep the projection current ---------------------

hold_cmd() {  # <args...>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$STORE" \
    "$HOLD" "$@"
}

ID=$(hold_cmd hold call-f --title "Choose the rollout order" --repo demo \
  --reason "two workers are idle until this is settled" --notify 2>/dev/null)
[ "$ID" = call-f ] || fail "hold must still print only the task id, got: $ID"
assert_contains "$(row_for call-f)" "Choose the rollout order" "creating a captain call projects it"
case "$(row_for call-f)" in
  *$'\t'1) pass "a hold raised with --notify alerts the captain" ;;
  *) fail "expected --notify to set a due time, got: $(row_for call-f)" ;;
esac

printf 'Go with the second order.\n' > "$TMP_ROOT/decision.txt"
hold_cmd answer call-f --decision-file "$TMP_ROOT/decision.txt" >/dev/null 2>&1
case "$(row_for call-f)" in
  1$'\t'*) pass "answering a captain call ticks its entry off" ;;
  *) fail "expected the answered call's entry to be completed, got: $(row_for call-f)" ;;
esac

# --- a broken projection never breaks the hold ---------------------------------

OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$STORE" \
  FAKE_REMINDERS_FAIL="execution error: something went wrong" \
  "$HOLD" hold call-g --title "Still a real captain call" --repo demo \
  --reason "the projection is broken but this call is not" 2>/dev/null)
RC=$?
[ "$RC" -eq 0 ] || fail "a failing projection must not fail the hold, got $RC"
[ "$OUT" = call-g ] || fail "a failing projection must not pollute the hold's own output, got: $OUT"
HELD=$( (cd "$HOME_DIR" && tasks-axi show call-g --full) | sed -n 's/^  hold_kind: //p')
[ "$HELD" = captain ] || fail "the captain hold itself must still be recorded, got: $HELD"
pass "a failing projection leaves the captain hold intact and its output clean"

# --- a batch of answers projects once, not once per answer ---------------------
#
# `answers` closes each key by re-entering `answer`, so an unsuppressed
# projection would cost the batch its whole per-run bound once per key - on the
# supervision path, with a wedged Reminders app.

BATCH_LOG="$TMP_ROOT/batch-reminders.log"
: > "$BATCH_LOG"
for id in batch-a batch-b batch-c; do
  hold_cmd hold "$id" --title "Batch call $id" --repo demo \
    --reason "batched captain call $id" >/dev/null 2>&1
done
: > "$BATCH_LOG"
BATCH_OUT=$(printf 'batch-a\tyes\t\nbatch-b\tyes\t\nbatch-c\tyes\t\n' |
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$STORE" FAKE_REMINDERS_LOG="$BATCH_LOG" \
  "$HOLD" answers --any-origin --source "test batch" 2>&1)
assert_contains "$BATCH_OUT" "closed=3" "the batch closed every captain call it was given"
[ "$(grep -c '^list$' "$BATCH_LOG")" = 1 ] \
  || fail "a batch of 3 answers ran $(grep -c '^list$' "$BATCH_LOG") projections instead of 1"
for id in batch-a batch-b batch-c; do
  case "$(row_for "$id")" in
    1$'\t'*) ;;
    *) fail "the single batch projection did not tick off $id, got: $(row_for "$id")" ;;
  esac
done
pass "a batch of answers projects exactly once and still ticks off every entry"

# --- an unreadable switch is not an empty one ----------------------------------

if [ "$(id -u)" -eq 0 ]; then
  echo "skip: running as root, an unreadable file cannot be simulated"
else
  UNREADABLE_LOG="$TMP_ROOT/unreadable-reminders.log"
  : > "$UNREADABLE_LOG"
  printf 'Captain Calls\n' > "$HOME_DIR/config/captain-reminders"
  chmod 000 "$HOME_DIR/config/captain-reminders"
  if head -1 "$HOME_DIR/config/captain-reminders" >/dev/null 2>&1; then
    echo "skip: this filesystem ignores the unreadable mode"
  else
    OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$STORE" \
      FAKE_REMINDERS_LOG="$UNREADABLE_LOG" "$REMINDERS" sync 2>&1)
    RC=$?
    [ "$RC" -ne 0 ] || fail "an unreadable switch must not report a successful projection"
    assert_contains "$OUT" "could not be read" "an unreadable switch says so"
    assert_not_contains "$OUT" "added " "an unreadable switch projects nothing"
    [ ! -s "$UNREADABLE_LOG" ] \
      || fail "an unreadable switch reached Reminders: $(cat "$UNREADABLE_LOG")"
    pass "an unreadable switch fails before touching Reminders instead of taking the default list"
  fi
  chmod 644 "$HOME_DIR/config/captain-reminders"
fi
printf '\n' > "$HOME_DIR/config/captain-reminders"
: > "$STORE"
run sync >/dev/null 2>&1
[ "$(rows)" -gt 0 ] || fail "an empty switch file must still select the default list"
pass "an empty switch file still selects the default list"

# --- several entries sharing one marker converge to one ------------------------
#
# Creating an entry cannot be made atomic with checking for one at the Reminders
# boundary, so a duplicate is possible under concurrency. The projection settles
# it on the next pass instead: exactly one open entry survives per marker, and
# which one survives is decided by an explicit rule, not by scan order.

CONVERGE_STORE="$TMP_ROOT/converge-reminders.tsv"
converge_run() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$CONVERGE_STORE" "$REMINDERS" "$@"
}
open_marked() {  # <task-id>
  awk -F'\t' -v m="[fm:$1]" 'BEGIN { n = length(m) } $1 == "0" && substr($3, 1, n) == m' "$CONVERGE_STORE"
}
all_marked() {  # <task-id>
  awk -F'\t' -v m="[fm:$1]" 'BEGIN { n = length(m) } substr($3, 1, n) == m' "$CONVERGE_STORE"
}

axi add dup-a "Duplicated call" --repo demo
axi hold dup-a --reason "two entries exist for this one call" --kind captain
{
  printf '0\tDuplicated call\t[fm:dup-a] two entries exist for this one call\t0\n'
  printf '0\tThe captain wrote this himself\tno marker at all\t0\n'
  printf '0\tDuplicated call\t[fm:dup-a] two entries exist for this one call\t1\n'
} > "$CONVERGE_STORE"
OUT=$(converge_run sync 2>&1)
[ "$(open_marked dup-a | awk 'END { print NR }')" = 1 ] \
  || fail "convergence left $(open_marked dup-a | awk 'END { print NR }') open entries for dup-a"
case "$(open_marked dup-a)" in
  *$'\t'1) ;;
  *) fail "convergence kept the entry that will never alert: $(open_marked dup-a)" ;;
esac
[ "$(all_marked dup-a | awk 'END { print NR }')" = 2 ] \
  || fail "convergence deleted an entry instead of ticking it off"
assert_contains "$OUT" "ticked off a duplicate entry for dup-a" "convergence says what it reconciled"
assert_contains "$(cat "$CONVERGE_STORE")" $'0\tThe captain wrote this himself\tno marker at all\t0' \
  "convergence touched an entry the captain wrote himself"
pass "duplicate entries converge to the one that will alert, and are completed rather than deleted"

{
  printf '0\tDuplicated call\t[fm:dup-a] two entries exist for this one call\told\t0\n'
  printf '0\tDuplicated call\t[fm:dup-a] two entries exist for this one call\t0\n'
} > "$CONVERGE_STORE"
sed -i.bak 's/\told\t0$/\t0/' "$CONVERGE_STORE" && rm -f "$CONVERGE_STORE.bak"
converge_run sync >/dev/null 2>&1
[ "$(open_marked dup-a | awk 'END { print NR }')" = 1 ] \
  || fail "convergence left more than one open entry when neither carried an alert"
[ "$(awk -F'\t' 'NR == 1 { print $1 }' "$CONVERGE_STORE")" = 0 ] \
  || fail "convergence ticked off the older entry instead of the accidental copy"
pass "with no alert to prefer, convergence keeps the older entry and ticks off the copy"

# --- a list read that already holds several open entries in one shot ----------
#
# Every scenario above builds the list up one sync call at a time, so a `list`
# verb that only breaks once several open entries already coexist would never
# be exercised. Cover the read itself for 0, 1, and many pre-existing open
# marked entries, as the vendor read step meets them on a real run: before
# this home has ever synced, not after.

READ_HOME="$TMP_ROOT/read-home"
mkdir -p "$READ_HOME/data" "$READ_HOME/state" "$READ_HOME/config"
cp "$ROOT/.tasks.toml" "$READ_HOME/.tasks.toml"
cat > "$READ_HOME/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
printf '\n' > "$READ_HOME/config/captain-reminders"
READ_STORE="$TMP_ROOT/read-reminders.tsv"

read_axi() { (cd "$READ_HOME" && tasks-axi "$@" >/dev/null); }
read_run() {  # <args...>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$READ_HOME" FM_CONFIG_OVERRIDE="$READ_HOME/config" \
    FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$READ_STORE" \
    "$REMINDERS" "$@"
}

# 0: the list is empty on the very first read this home ever does.
: > "$READ_STORE"
OUT=$(read_run status 2>&1)
assert_contains "$OUT" "already matches the backlog" "an empty list on the first read must plan nothing to add: $OUT"
pass "a list read starting with zero open entries reports nothing to reconcile"

# 1: exactly one open marked entry already exists before this home's first sync.
read_axi add read-one "Read one" --repo demo
read_axi hold read-one --reason "single pre-existing entry" --kind captain
printf '0\tRead one\t[fm:read-one] single pre-existing entry\t0\n' > "$READ_STORE"
OUT=$(read_run sync 2>&1)
[ -z "$OUT" ] || fail "a matching pre-existing single entry must need no change, got: $OUT"
[ "$(awk 'END { print NR }' "$READ_STORE")" = 1 ] \
  || fail "a single pre-existing entry must not be duplicated: $(cat "$READ_STORE")"
pass "a list read starting with exactly one open entry recognizes it without duplicating"

# many: several open marked entries for several different calls already exist
# before this home's first sync, some still current, one stale.
read_axi add read-two "Read two" --repo demo
read_axi hold read-two --reason "second pre-existing entry" --kind captain
read_axi add read-three "Read three" --repo demo
{
  printf '0\tRead one\t[fm:read-one] single pre-existing entry\t0\n'
  printf '0\tRead two\t[fm:read-two] second pre-existing entry\t0\n'
  printf '0\tStale one\t[fm:read-three] no longer held\t0\n'
} > "$READ_STORE"
OUT=$(read_run sync 2>&1)
assert_contains "$OUT" "ticked off read-three" \
  "a many-entry read still ticks off the one call no longer held for the captain"
assert_not_contains "$OUT" "added read-one" "a many-entry read must not re-add an entry already present"
assert_not_contains "$OUT" "added read-two" "a many-entry read must not re-add an entry already present"
[ "$(awk -F'\t' '$1 == "0"' "$READ_STORE" | awk 'END { print NR }')" = 2 ] \
  || fail "a many-entry read left the wrong number of open entries: $(cat "$READ_STORE")"
pass "a list read starting with several pre-existing open entries reconciles all of them correctly in one pass"
