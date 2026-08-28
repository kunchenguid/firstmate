#!/usr/bin/env bash
# Behavior tests for the one-way projection of captain calls into Reminders:
# what a sync derives from the backlog, that reruns never duplicate, that every
# new entry alerts the captain exactly once and a rerun never alerts him again,
# that a call the captain no longer owns is ticked off rather than deleted, that
# an entry without the `[fm:<task-id>]` marker is never touched, that the whole
# thing is inert until this home opts in, and that a wedged Reminders step is
# bounded instead of hanging its caller.
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
# as a SUFFIX, or as a legacy PREFIX from an entry an older version of this
# script created, never on a name or a row position - so a test that shows an
# unmarked row surviving is showing the real matching rule surviving, not a
# convenience of the fake.
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
hasMarker='function hasMarker(b,    n) { n = length(p); return (substr(b, length(b) - n + 1) == p) || (substr(b, 1, n) == p) }'
case "$verb" in
  list|detail)
    # `list` answers the task id, title, and note of every open marked entry -
    # a repeated task id IS the duplicate signal - while `detail` answers the
    # four columns that tell
    # several entries sharing a marker apart.
    awk -F'\t' -v OFS='\t' -v verb="$verb" '
      function markerId(body,    id) {
        if (body ~ /\[fm:[A-Za-z0-9._-]+\]$/) {
          id = body
          sub(/\]$/, "", id); sub(/^.*\[fm:/, "", id)
          return id
        }
        if (body ~ /^\[fm:[A-Za-z0-9._-]+\]/) {
          id = body
          sub(/\].*$/, "", id); sub(/^\[fm:/, "", id)
          return id
        }
        return ""
      }
      $1 == "0" {
        id = markerId($3)
        if (id == "") next
        # A synthetic reminder identity and age: the store never removes a row, so
        # its line number is stable within a run and earlier lines are older.
        if (verb == "list") print id, $2, $3
        else print id, "r" NR, ($4 == "1" ? "1" : "0"), NR - 1000
    }' "$store"
    ;;
  upsert-batch)
    # One process for the whole phase, exactly like the AppleScript it stands
    # in for: the payload is RS-separated records of US-separated fields, the
    # caller has already decided create or update from its own `list` read, and
    # the answer is one `<task-id>TAB<outcome>` line per INPUT record, in order.
    if [ -n "${FAKE_REMINDERS_GATE:-}" ]; then
      : > "$FAKE_REMINDERS_GATE.entered"
      while [ ! -e "$FAKE_REMINDERS_GATE.release" ]; do sleep 0.05; done
    fi
    handled=0
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      # FAKE_REMINDERS_PARTIAL stops the batch after N records with no error,
      # which is how a real batch that ran out of time looks from outside: the
      # records it never reached simply have no answer line.
      handled=$((handled + 1))
      if [ -n "${FAKE_REMINDERS_PARTIAL:-}" ] && [ "$handled" -gt "$FAKE_REMINDERS_PARTIAL" ]; then
        break
      fi
      IFS=$'\037' read -r id action name body due <<<"$rec"
      prefix="[fm:$id]"
      if [ "$action" = update ]; then
        awk -F'\t' -v OFS='\t' -v p="$prefix" -v n="$name" -v b="$body" "$hasMarker"'
          $1 == "0" && hasMarker($3) { $2 = n; $3 = b }
          { print }
        ' "$store" > "$store.tmp" && mv "$store.tmp" "$store"
        printf '%s\tupdated\n' "$id"
      else
        printf '0\t%s\t%s\t%s\n' "$name" "$body" "$due" >> "$store"
        printf '%s\tcreated\n' "$id"
      fi
    done < <(printf '%s\n' "$2" | tr '\036' '\n')
    ;;
  complete-batch)
    # Each record is `<task-id>US<reminder-id>`; a reminder id of `-`
    # means every open entry carrying that marker. A named reminder is still
    # only reachable among entries carrying the marker, so the id alone can
    # never reach an unmarked row.
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      IFS=$'\037' read -r id target <<<"$rec"
      prefix="[fm:$id]"
      awk -F'\t' -v OFS='\t' -v p="$prefix" -v t="$target" "$hasMarker"'
        $1 == "0" && hasMarker($3) && (t == "-" || ("r" NR) == t) { $1 = "1" }
        { print }
      ' "$store" > "$store.tmp" && mv "$store.tmp" "$store"
      printf '%s\tok\n' "$id"
    done < <(printf '%s\n' "$2" | tr '\036' '\n')
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
assert_contains "$OUT" "alert the captain" "status says the new entry would alert him"
[ "$(rows)" = 0 ] || fail "status must not write to the list"
OUT=$(run status 2>&1)
assert_contains "$OUT" "alert the captain" \
  "a second plan still expects to alert him, so no plan ever spent his one alert"
pass "status prints the plan and touches nothing"

# --- the projection itself ----------------------------------------------------

OUT=$(run sync 2>&1)
assert_contains "$OUT" "added call-a" "sync reports the call it added"
[ "$(rows)" = 1 ] || fail "expected exactly one reminder, list holds: $(cat "$STORE")"
assert_contains "$(row_for call-a)" "Pick the exec path" "the reminder is titled with the task title"
assert_contains "$(row_for call-a)" "three ways forward" "the reminder note carries the hold reason"
assert_contains "$(row_for call-a)" "demo" "the reminder note says which project the call belongs to"
assert_contains "$(row_for call-a)" "[fm:call-a]" "the reminder note carries the task marker"
case "$(row_for call-a)" in
  *'[fm:call-a]'$'\t'*) pass "the marker sits at the end of the note, behind the sentence he reads" ;;
  *) fail "the marker must be the tail of the note, got: $(row_for call-a)" ;;
esac
case "$(row_for call-a)" in
  *$'\t'1) pass "every new call is created with a due time so Reminders raises it" ;;
  *) fail "a new call must alert the captain: $(row_for call-a)" ;;
esac
assert_contains "$OUT" "alerted the captain" "sync says it alerted him for the new call"

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

# --- a run carrying a just-registered call never stands down ------------------
#
# An ordinary projection may skip, because the lock holder is deriving the same
# set. A --fresh projection may not: the holder's snapshot predates this call,
# so skipping would leave the captain's newest call out of his list entirely.

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
FRESH_START=$(date +%s)
FRESH_OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$CONCURRENT_STORE" \
  FAKE_REMINDERS_LOG="$CONCURRENT_LOG" FM_REMINDERS_TIMEOUT_SECS=2 \
  "$REMINDERS" sync --fresh call-a 2>&1)
FRESH_RC=$?
FRESH_ELAPSED=$(( $(date +%s) - FRESH_START ))
: > "$CONCURRENT_GATE.release"
wait "$FIRST_PID" 2>/dev/null || true
[ "$FRESH_RC" -ne 0 ] \
  || fail "a run that never reached the list must not report success"
assert_contains "$FRESH_OUT" "did NOT reach the captain's list" \
  "a run that waited out its deadline says the call never reached him"
assert_contains "$FRESH_OUT" "call-a" "the undelivered call is named"
[ "$FRESH_ELAPSED" -ge 1 ] \
  || fail "a named run must wait for the lock, not stand down immediately (${FRESH_ELAPSED}s)"
[ "$FRESH_ELAPSED" -lt 30 ] \
  || fail "a named run must stop waiting at its own deadline (${FRESH_ELAPSED}s)"
pass "a run carrying a just-registered call waits for the lock and reports failure rather than exiting clean"

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

# --- a legacy leading-marker entry converts in place, never rings again --------
#
# A note written by a version of this script before the marker moved to the
# tail carries `[fm:<id>] reason` instead of `reason [fm:<id>]`. Reading must
# still recognize it, so the call it represents keeps matching the entry the
# captain already has instead of getting a silent duplicate; writing rewrites
# it to the tail form in place, on the very first sync, and that rewrite alone
# must never ring him again.

LEGACY_HOME="$TMP_ROOT/legacy-home"
mkdir -p "$LEGACY_HOME/data" "$LEGACY_HOME/state" "$LEGACY_HOME/config"
cp "$ROOT/.tasks.toml" "$LEGACY_HOME/.tasks.toml"
cat > "$LEGACY_HOME/data/backlog.md" <<'BACKLOG'
## In flight

## Queued

## Done
BACKLOG
printf '\n' > "$LEGACY_HOME/config/captain-reminders"
LEGACY_STORE="$TMP_ROOT/legacy-reminders.tsv"

legacy_axi() { (cd "$LEGACY_HOME" && tasks-axi "$@" >/dev/null); }
legacy_run() {  # <args...>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LEGACY_HOME" FM_CONFIG_OVERRIDE="$LEGACY_HOME/config" \
    FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$LEGACY_STORE" \
    "$REMINDERS" "$@"
}
legacy_row() {  # <task-id>
  grep -F "[fm:$1]" "$LEGACY_STORE" 2>/dev/null || true
}
legacy_note() {  # <task-id>
  legacy_row "$1" | awk -F'\t' '{ print $3 }'
}

legacy_axi add legacy-a "Renew the certificate" --repo demo
legacy_axi hold legacy-a --reason "still waiting on him" --kind captain

{
  printf '0\tRenew the certificate\t[fm:legacy-a] still waiting on him\t0\n'
  printf '0\tThe captain wrote this himself\tno marker at all\t0\n'
} > "$LEGACY_STORE"

OUT=$(legacy_run sync 2>&1)
assert_not_contains "$OUT" "alerted the captain" \
  "converting a legacy leading-marker entry must not ring him again"
[ "$(legacy_row legacy-a | grep -c .)" = 1 ] \
  || fail "converting the legacy entry must not create a duplicate: $(legacy_row legacy-a)"
case "$(legacy_note legacy-a)" in
  *'[fm:legacy-a]') pass "the legacy leading-marker entry is rewritten to the trailing form in place" ;;
  *) fail "expected the note rewritten to the trailing marker form, got: $(legacy_note legacy-a)" ;;
esac
assert_contains "$(cat "$LEGACY_STORE")" $'0\tThe captain wrote this himself\tno marker at all\t0' \
  "converting the legacy entry never touches an entry the captain wrote himself"

BEFORE=$(cat "$LEGACY_STORE")
OUT=$(legacy_run sync 2>&1)
[ -z "$OUT" ] || fail "a further sync of a converted entry must be a no-op, got: $OUT"
[ "$BEFORE" = "$(cat "$LEGACY_STORE")" ] || fail "a further sync rewrote an already-converted entry"
pass "a further sync of a converted entry is a no-op"

legacy_axi unhold legacy-a
legacy_run sync >/dev/null 2>&1
case "$(legacy_row legacy-a)" in
  1$'\t'*) pass "a converted entry is still ticked off automatically once no longer waiting on him" ;;
  *) fail "the converted entry was not completed once no longer held: $(legacy_row legacy-a)" ;;
esac

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

# --- every new call alerts, and only ever once ---------------------------------

axi unhold call-a
run sync >/dev/null 2>&1
axi add call-d "Approve the migration window" --repo demo
axi hold call-d --reason "nothing ships until this is settled" --kind captain
OUT=$(run sync --fresh call-d 2>&1)
assert_contains "$OUT" "alerted the captain" "a new call reports that it alerted the captain"
case "$(row_for call-d)" in
  *$'\t'1) pass "a new call is created with a due time so Reminders raises it" ;;
  *) fail "expected a due time on the new call, got: $(row_for call-d)" ;;
esac
OUT=$(run sync --fresh call-d 2>&1)
assert_not_contains "$OUT" "alerted the captain" "a rerun does not re-alert a call already projected"

# The captain ticks his entry off while the call is still open. Every query here
# filters on `completed is false`, so the projection cannot see what he did and
# restates the call - but the durable record of who has already been rung must
# keep that restatement silent.
awk -F'\t' -v OFS='\t' '$3 ~ /\[fm:call-d\]$/ && $1 == "0" { $1 = "1" } { print }' "$STORE" \
  > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
OUT=$(run sync --fresh call-d 2>&1)
ACTIVE_CALL_D=$(row_for call-d | grep '^0' || true)
assert_contains "$OUT" "added call-d" "a call ticked off while still open is restated"
assert_not_contains "$OUT" "alerted the captain" \
  "restating a call the captain has already read must not alert him again"
case "$ACTIVE_CALL_D" in
  *$'\t'0) pass "an entry recreated after the captain ticked it off stays silent" ;;
  *) fail "the replacement rang the captain a second time: $(row_for call-d)" ;;
esac

OUT=$(run sync --fresh not-a-real-task 2>&1)
assert_contains "$OUT" "nothing to project for not-a-real-task" \
  "a named task that is not a captain call is reported rather than silently dropped"
pass "every call alerts him on its first projection and never again"

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
  FAKE_REMINDERS_HANG_VERB=upsert-batch FM_REMINDERS_TIMEOUT_SECS=6 \
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
[ "$(grep -c '^upsert-batch$' "$TIMEOUT_LOG")" = 1 ] || fail "the whole deadline allowed repeated wedged upserts: $(cat "$TIMEOUT_LOG")"
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
printf '0\tStale read\told reason [fm:stale-read]\t0\n' > "$FAILURE_STORE"
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
printf '0\tAnswered call\told reason [fm:empty-stale]\t0\n' >> "$STORE"
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
  --reason "two workers are idle until this is settled" 2>/dev/null)
[ "$ID" = call-f ] || fail "hold must still print only the task id, got: $ID"
assert_contains "$(row_for call-f)" "Choose the rollout order" "creating a captain call projects it"
case "$(row_for call-f)" in
  *$'\t'1) pass "registering a captain call alerts him, with no flag to remember" ;;
  *) fail "expected a registered call to set a due time, got: $(row_for call-f)" ;;
esac

# The old per-call urgency flag is still accepted so a caller carrying it cannot
# lose a captain call to a usage error; it simply decides nothing any more.
ID=$(hold_cmd hold call-f2 --title "Approve the vendor swap" --repo demo \
  --reason "the old contract lapses on Friday" --notify 2>/dev/null)
[ "$ID" = call-f2 ] || fail "hold must still accept the retired flag, got: $ID"
case "$(row_for call-f2)" in
  *$'\t'1) pass "the retired urgency flag is accepted and changes nothing" ;;
  *) fail "the retired flag changed the outcome: $(row_for call-f2)" ;;
esac
hold_cmd answer call-f2 --decision-file <(printf 'Swap it.\n') >/dev/null 2>&1

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
  awk -F'\t' -v m="[fm:$1]" 'BEGIN { n = length(m) } $1 == "0" && substr($3, length($3) - n + 1) == m' "$CONVERGE_STORE"
}
all_marked() {  # <task-id>
  awk -F'\t' -v m="[fm:$1]" 'BEGIN { n = length(m) } substr($3, length($3) - n + 1) == m' "$CONVERGE_STORE"
}

axi add dup-a "Duplicated call" --repo demo
axi hold dup-a --reason "two entries exist for this one call" --kind captain
{
  printf '0\tDuplicated call\ttwo entries exist for this one call [fm:dup-a]\t0\n'
  printf '0\tThe captain wrote this himself\tno marker at all\t0\n'
  printf '0\tDuplicated call\ttwo entries exist for this one call [fm:dup-a]\t1\n'
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
  printf '0\tDuplicated call\ttwo entries exist for this one call [fm:dup-a]\told\t0\n'
  printf '0\tDuplicated call\ttwo entries exist for this one call [fm:dup-a]\t0\n'
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
printf '0\tRead one\tsingle pre-existing entry（项目：demo） [fm:read-one]\t0\n' > "$READ_STORE"
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
  printf '0\tRead one\tsingle pre-existing entry（项目：demo） [fm:read-one]\t0\n'
  printf '0\tRead two\tsecond pre-existing entry（项目：demo） [fm:read-two]\t0\n'
  printf '0\tStale one\tno longer held [fm:read-three]\t0\n'
} > "$READ_STORE"
OUT=$(read_run sync 2>&1)
assert_contains "$OUT" "ticked off read-three" \
  "a many-entry read still ticks off the one call no longer held for the captain"
assert_not_contains "$OUT" "added read-one" "a many-entry read must not re-add an entry already present"
assert_not_contains "$OUT" "added read-two" "a many-entry read must not re-add an entry already present"
[ "$(awk -F'\t' '$1 == "0"' "$READ_STORE" | awk 'END { print NR }')" = 2 ] \
  || fail "a many-entry read left the wrong number of open entries: $(cat "$READ_STORE")"
pass "a list read starting with several pre-existing open entries reconciles all of them correctly in one pass"

# --- several calls landing at once, and one of them answered ------------------
#
# The whole reason this list exists: several pieces of work finish close
# together, each raising something only the captain can settle, and the one that
# needs him gets buried in the session. Each call must arrive as its OWN entry
# with its OWN alert, answering one must clear only that one, and no later sync
# may rebuild what he has cleared or ring him for what he has already read.

MULTI_HOME="$TMP_ROOT/multi-home"
mkdir -p "$MULTI_HOME/data" "$MULTI_HOME/state" "$MULTI_HOME/config"
cp "$ROOT/.tasks.toml" "$MULTI_HOME/.tasks.toml"
cat > "$MULTI_HOME/data/backlog.md" <<'BACKLOG'
## In flight

## Queued

## Done
BACKLOG
printf '\n' > "$MULTI_HOME/config/captain-reminders"
MULTI_STORE="$TMP_ROOT/multi-reminders.tsv"
: > "$MULTI_STORE"

multi_hold() {  # <args...>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$MULTI_HOME" FM_STATE_OVERRIDE="$MULTI_HOME/state" \
    FM_DATA_OVERRIDE="$MULTI_HOME/data" FM_CONFIG_OVERRIDE="$MULTI_HOME/config" \
    FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$MULTI_STORE" \
    "$HOLD" "$@"
}
multi_run() {  # <args...>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$MULTI_HOME" FM_CONFIG_OVERRIDE="$MULTI_HOME/config" \
    FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$MULTI_STORE" \
    "$REMINDERS" "$@"
}
multi_row() {  # <task-id>
  grep -F "[fm:$1]" "$MULTI_STORE" 2>/dev/null || true
}
multi_open() {  # <task-id>
  multi_row "$1" | grep '^0' || true
}

multi_hold hold pick-db --title "Choose which database the invoicing service uses" \
  --repo billing --reason "两个方案都能跑，价钱差一倍，需要你选一个" >/dev/null 2>&1
multi_hold hold sign-key --title "Renew the signing certificate" \
  --repo mobile --reason "证书周五过期，续期需要你本人登录苹果账号" >/dev/null 2>&1

[ "$(multi_open pick-db | grep -c .)" = 1 ] \
  || fail "the first call is not exactly one open entry: $(multi_row pick-db)"
[ "$(multi_open sign-key | grep -c .)" = 1 ] \
  || fail "the second call is not exactly one open entry: $(multi_row sign-key)"
case "$(multi_open pick-db)" in
  *$'\t'1) ;;
  *) fail "the first call did not alert him: $(multi_open pick-db)" ;;
esac
case "$(multi_open sign-key)" in
  *$'\t'1) ;;
  *) fail "the second call did not alert him: $(multi_open sign-key)" ;;
esac
assert_contains "$(multi_open sign-key)" "证书周五过期" "each entry carries its own sentence"
assert_contains "$(multi_open sign-key)" "mobile" "each entry says which project it belongs to"
pass "two calls raised together arrive as two separate entries, each with its own alert"

printf '选方案 B。\n' > "$TMP_ROOT/multi-decision.txt"
multi_hold answer pick-db --decision-file "$TMP_ROOT/multi-decision.txt" >/dev/null 2>&1
case "$(multi_row pick-db)" in
  1$'\t'*) ;;
  *) fail "the answered call was not ticked off: $(multi_row pick-db)" ;;
esac
[ "$(multi_open sign-key | grep -c .)" = 1 ] \
  || fail "answering one call disturbed the other: $(multi_row sign-key)"
pass "answering one call ticks off only that call and leaves the rest of his list alone"

# He clears the remaining entry himself in Reminders while the call is still
# open, and deletes another outright. Neither may come back ringing.
awk -F'\t' -v OFS='\t' '$3 ~ /\[fm:sign-key\]$/ { $1 = "1" } { print }' "$MULTI_STORE" \
  > "$MULTI_STORE.tmp" && mv "$MULTI_STORE.tmp" "$MULTI_STORE"
OUT=$(multi_run sync 2>&1)
assert_not_contains "$OUT" "alerted the captain" \
  "a call restated after he cleared it must not ring again"
case "$(multi_open sign-key)" in
  *$'\t'0) ;;
  *) fail "the restated entry rang him a second time: $(multi_open sign-key)" ;;
esac
grep -v -F "[fm:sign-key]" "$MULTI_STORE" > "$MULTI_STORE.tmp" && mv "$MULTI_STORE.tmp" "$MULTI_STORE"
OUT=$(multi_run sync 2>&1)
assert_not_contains "$OUT" "alerted the captain" \
  "a call restated after he deleted its entry must not ring again"
case "$(multi_open sign-key)" in
  *$'\t'0) ;;
  *) fail "a deleted entry came back ringing: $(multi_open sign-key)" ;;
esac
OUT=$(multi_run sync 2>&1)
assert_not_contains "$OUT" "alerted the captain" "a further rerun still rings nothing"
[ "$(multi_open sign-key | grep -c .)" = 1 ] \
  || fail "reruns left more than one open entry: $(multi_row sign-key)"
[ "$(multi_open pick-db | grep -c .)" = 0 ] \
  || fail "an answered call came back into his list: $(multi_row pick-db)"
pass "clearing or deleting an entry never earns him a repeat alert, and an answered call never returns"

# --- the whole projection costs a fixed number of Reminders calls -------------
#
# The reason this matters is not tidiness. Waking the Reminders app costs
# seconds, so a projection that spent one call per entry cost seconds per entry
# and was abandoned at its own deadline before it wrote anything - and being
# abandoned on this path means the captain silently stops being told what is
# waiting on him. Doubling the number of calls waiting on him must therefore
# not change how many times the Reminders app is entered.

SCALE_HOME="$TMP_ROOT/scale-home"
mkdir -p "$SCALE_HOME/data" "$SCALE_HOME/state" "$SCALE_HOME/config"
cp "$ROOT/.tasks.toml" "$SCALE_HOME/.tasks.toml"
cat > "$SCALE_HOME/data/backlog.md" <<'BACKLOG'
## In flight

## Queued

## Done
BACKLOG
printf '\n' > "$SCALE_HOME/config/captain-reminders"
SCALE_STORE="$TMP_ROOT/scale-reminders.tsv"
SCALE_LOG="$TMP_ROOT/scale-reminders.log"

scale_axi() { (cd "$SCALE_HOME" && tasks-axi "$@" >/dev/null); }
scale_run() {  # <args...>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SCALE_HOME" FM_CONFIG_OVERRIDE="$SCALE_HOME/config" \
    FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$SCALE_STORE" \
    FAKE_REMINDERS_LOG="$SCALE_LOG" "$REMINDERS" "$@"
}
scale_calls() { awk 'END { print NR + 0 }' "$SCALE_LOG"; }

scale_hold() {  # <count> <prefix>
  local i=1
  while [ "$i" -le "$1" ]; do
    scale_axi add "$2-$i" "Scale call $2-$i" --repo demo
    scale_axi hold "$2-$i" --reason "scale call $2-$i" --kind captain
    i=$((i + 1))
  done
}

: > "$SCALE_STORE"
scale_hold 3 few
: > "$SCALE_LOG"
scale_run sync >/dev/null 2>&1
FEW_CALLS=$(scale_calls)
[ "$(awk -F'\t' '$1 == "0"' "$SCALE_STORE" | awk 'END { print NR }')" = 3 ] \
  || fail "the three-call sync did not project every call: $(cat "$SCALE_STORE")"

scale_hold 9 many
: > "$SCALE_LOG"
scale_run sync >/dev/null 2>&1
MANY_CALLS=$(scale_calls)
[ "$(awk -F'\t' '$1 == "0"' "$SCALE_STORE" | awk 'END { print NR }')" = 12 ] \
  || fail "the twelve-call sync did not project every call: $(cat "$SCALE_STORE")"
[ "$MANY_CALLS" = "$FEW_CALLS" ] \
  || fail "Reminders calls grew with the entry count: $FEW_CALLS for 3 calls, $MANY_CALLS for 12"
[ "$FEW_CALLS" -le 3 ] \
  || fail "a plain sync entered Reminders $FEW_CALLS times; it should read once and write once per phase"
pass "a 12-call projection enters Reminders exactly as often as a 3-call one ($MANY_CALLS calls)"

# Ticking off a whole set of answered calls is one call too.
for i in 1 2 3; do scale_axi unhold "few-$i"; done
: > "$SCALE_LOG"
scale_run sync >/dev/null 2>&1
[ "$(scale_calls)" -le 3 ] \
  || fail "ticking off three answered calls entered Reminders $(scale_calls) times"
for i in 1 2 3; do
  case "$(grep -F "[fm:few-$i]" "$SCALE_STORE")" in
    1$'\t'*) ;;
    *) fail "few-$i was not ticked off: $(grep -F "[fm:few-$i]" "$SCALE_STORE")" ;;
  esac
done
pass "a set of answered calls is ticked off in one Reminders call, not one per entry"

# --- a batch that stops half way loses no call its one alert ------------------
#
# A batch either answers a record or it does not. A record with no answer must
# be treated as never written: counting it as done would cost that call the one
# alert this whole capability exists to raise, while re-trying it costs at worst
# a second look at an entry that already exists.

PARTIAL_HOME="$TMP_ROOT/partial-home"
mkdir -p "$PARTIAL_HOME/data" "$PARTIAL_HOME/state" "$PARTIAL_HOME/config"
cp "$ROOT/.tasks.toml" "$PARTIAL_HOME/.tasks.toml"
cat > "$PARTIAL_HOME/data/backlog.md" <<'BACKLOG'
## In flight

## Queued

## Done
BACKLOG
printf '\n' > "$PARTIAL_HOME/config/captain-reminders"
PARTIAL_STORE="$TMP_ROOT/partial-reminders.tsv"
: > "$PARTIAL_STORE"

partial_axi() { (cd "$PARTIAL_HOME" && tasks-axi "$@" >/dev/null); }
partial_run() {  # <args...>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$PARTIAL_HOME" FM_CONFIG_OVERRIDE="$PARTIAL_HOME/config" \
    FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$PARTIAL_STORE" \
    "$REMINDERS" "$@"
}
partial_row() { grep -F "[fm:$1]" "$PARTIAL_STORE" 2>/dev/null || true; }

for id in part-a part-b part-c; do
  partial_axi add "$id" "Partial call $id" --repo demo
  partial_axi hold "$id" --reason "partial call $id" --kind captain
done

OUT=$(FAKE_REMINDERS_PARTIAL=2 partial_run sync 2>&1)
RC=$?
[ "$RC" -ne 0 ] || fail "a batch that answered only part of its records must not report success"
assert_contains "$OUT" "added part-a" "the answered records are reported"
assert_contains "$OUT" "added part-b" "the answered records are reported"
assert_not_contains "$OUT" "added part-c" "a record the batch never answered is not claimed as added"
[ "$(partial_row part-c)" = "" ] || fail "part-c should not exist yet: $(partial_row part-c)"

OUT=$(partial_run sync 2>&1)
assert_contains "$OUT" "added part-c" "the unanswered call is projected on the next pass"
case "$(partial_row part-c)" in
  *$'\t'1) pass "a call the truncated batch never reached still gets its one alert" ;;
  *) fail "the retried call lost its alert: $(partial_row part-c)" ;;
esac
assert_not_contains "$OUT" "added part-a" "an already-projected call is not added again"
assert_not_contains "$OUT" "part-a) and alerted" "an already-alerted call is not rung a second time"

OUT=$(partial_run sync 2>&1)
assert_not_contains "$OUT" "alerted the captain" "a further pass rings nothing"
[ "$(awk -F'\t' '$1 == "0"' "$PARTIAL_STORE" | awk 'END { print NR }')" = 3 ] \
  || fail "the retry duplicated an entry: $(cat "$PARTIAL_STORE")"
pass "a batch cut short re-raises only what it could not confirm, and rings each call exactly once"

# --- a deadline hit mid-projection still names the exact remainder ------------
#
# Batching changed what "how many are left" is derived from, so the number the
# caller is given must still be the real count of entries this pass did not
# process - here: every call was written, and only the answered calls waiting to
# be ticked off were left.

REMAINDER_STORE="$TMP_ROOT/remainder-reminders.tsv"
: > "$REMAINDER_STORE"
partial_axi add rem-stale-a "Remainder stale a" --repo demo
partial_axi add rem-stale-b "Remainder stale b" --repo demo
{
  printf '0\tRemainder stale a\tanswered already [fm:rem-stale-a]\t0\n'
  printf '0\tRemainder stale b\tanswered already [fm:rem-stale-b]\t0\n'
} > "$REMAINDER_STORE"
OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$PARTIAL_HOME" FM_CONFIG_OVERRIDE="$PARTIAL_HOME/config" \
  FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$REMAINDER_STORE" \
  FAKE_REMINDERS_HANG=60 FAKE_REMINDERS_HANG_VERB=complete-batch \
  FM_REMINDERS_TIMEOUT_SECS=6 "$REMINDERS" sync 2>&1)
RC=$?
[ "$RC" -ne 0 ] || fail "a projection abandoned at its deadline must not report success"
assert_contains "$OUT" "2 entries were left unprocessed" \
  "the remainder counts exactly the entries the abandoned phase never reached"
pass "a deadline hit after the write phase still names the exact unprocessed remainder"

# --- telling duplicates apart is asked for only when there ARE duplicates -----
#
# The extra columns that decide which of several entries sharing a marker
# survives cost a whole read each against the Reminders app. The cheap read the
# projection already does answers whether any marker repeats at all, so the
# expensive one must never be spent on a list that has no duplicates - and when
# it is spent, it must come after the calls the captain is waiting on are
# written, so a spare copy can never starve the projection's real work.

ORDER_STORE="$TMP_ROOT/order-reminders.tsv"
ORDER_LOG="$TMP_ROOT/order-reminders.log"
order_run() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$ORDER_STORE" \
    FAKE_REMINDERS_LOG="$ORDER_LOG" "$REMINDERS" "$@"
}

axi add order-a "Ordered call" --repo demo
axi hold order-a --reason "no duplicate yet" --kind captain
: > "$ORDER_STORE"
: > "$ORDER_LOG"
order_run sync >/dev/null 2>&1
assert_not_contains "$(cat "$ORDER_LOG")" "detail" \
  "a list with no repeated marker must not pay for the duplicate-only read"
pass "the duplicate-only read is never spent on a list that has no duplicates"

# Now a genuine duplicate, plus a reason change, in one pass: the refresh the
# captain needs must land, and the duplicate must be reconciled after it.
axi hold order-a --reason "the reason changed in the same pass" --kind captain
awk -F'\t' -v OFS='\t' '{ print } $1 == "0" && $3 ~ /\[fm:order-a\]$/ && !done { print; done = 1 }' \
  "$ORDER_STORE" > "$ORDER_STORE.tmp" && mv "$ORDER_STORE.tmp" "$ORDER_STORE"
[ "$(awk -F'\t' '$1 == "0" && $3 ~ /\[fm:order-a\]$/' "$ORDER_STORE" | awk 'END { print NR }')" = 2 ] \
  || fail "the duplicate fixture did not produce two open copies: $(cat "$ORDER_STORE")"
: > "$ORDER_LOG"
OUT=$(order_run sync 2>&1)
assert_contains "$(cat "$ORDER_LOG")" "detail" "a repeated marker does buy the duplicate-only read"
assert_contains "$OUT" "refreshed order-a" "the call the captain is waiting on is still refreshed"
assert_contains "$OUT" "ticked off a duplicate entry for order-a" "the duplicate is reconciled"
UPSERT_AT=$(grep -n '^upsert-batch$' "$ORDER_LOG" | head -1 | cut -d: -f1)
DETAIL_AT=$(grep -n '^detail$' "$ORDER_LOG" | head -1 | cut -d: -f1)
[ -n "$UPSERT_AT" ] && [ -n "$DETAIL_AT" ] && [ "$DETAIL_AT" -gt "$UPSERT_AT" ] \
  || fail "duplicates must be reconciled after the real work, got: $(cat "$ORDER_LOG")"
[ "$(awk -F'\t' '$1 == "0" && $3 ~ /\[fm:order-a\]$/' "$ORDER_STORE" | awk 'END { print NR }')" = 1 ] \
  || fail "convergence left the wrong number of open copies: $(cat "$ORDER_STORE")"
pass "a spare copy is reconciled after the captain's own calls, never instead of them"

# Running out of deadline on that reconciliation is reported, not a failure:
# the calls he is waiting on already landed, and the spare copy settles later.
axi hold order-a --reason "another reason change while a copy exists" --kind captain
awk -F'\t' -v OFS='\t' '{ print } $1 == "0" && $3 ~ /\[fm:order-a\]$/ && !done { print; done = 1 }' \
  "$ORDER_STORE" > "$ORDER_STORE.tmp" && mv "$ORDER_STORE.tmp" "$ORDER_STORE"
: > "$ORDER_LOG"
OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_REMINDERS_EXEC="$FAKE" FAKE_REMINDERS_STORE="$ORDER_STORE" FAKE_REMINDERS_LOG="$ORDER_LOG" \
  FAKE_REMINDERS_HANG=60 FAKE_REMINDERS_HANG_VERB=detail FM_REMINDERS_TIMEOUT_SECS=8 \
  "$REMINDERS" sync 2>&1)
RC=$?
assert_contains "$OUT" "refreshed order-a" "the refresh still lands when the duplicate read runs out of time"
assert_contains "$OUT" "no room left" "running out of time on duplicates is said plainly"
[ "$RC" -eq 0 ] || fail "a spare copy left for the next pass must not be reported as a failed projection, got $RC"
pass "no deadline left for duplicates is reported and left for the next pass, not treated as a failure"
