#!/usr/bin/env bash
# tests/fm-inbox.test.sh - source classes for the captain inbox (bin/fm-inbox.sh).
#
# The 2026-11 measurement behind this suite: 131 sentry-bridge records in seven
# days, every one of them filed as though the captain had written it, burying the
# five real captain orders of 27 Oct in the same queue. These cases pin the split
# that ends it:
#   1. A captain note still files under state/inbox/ and still wakes as a
#      captain record, so the path the voice handover uses is unchanged.
#   2. Every automated class files under state/inbox-auto/, never the captain
#      queue, records its class, and wakes saying it is automated.
#   3. An unknown class refuses by name and writes nothing anywhere, because a
#      guessed class is how a machine record lands in the captain queue.
#   4. list and drain print the captain's notes first and a bounded newest tail
#      of the automated queue, with --all as the only way to print all of it.
#   5. drain --ack retires a record from whichever queue holds it, and refuses a
#      path-shaped id.
#   6. status counts the two queues separately.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INBOX_SH="$ROOT/bin/fm-inbox.sh"
TMP_ROOT=$(fm_test_tmproot fm-inbox)

make_home() {  # <name> -> echoes the home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

inbox() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$INBOX_SH" "$@"
}

notes_in() {  # <dir> -> count of staged records
  [ -d "$1" ] || { printf '0'; return 0; }
  find "$1" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

ids_of() {  # <listing output> -> the bare record ids it printed
  printf '%s\n' "$1" | grep -E '^[0-9]+-[A-Za-z0-9]+$' || true
}

only_note() {  # <dir> -> the id of the one record there
  local f
  f=$(find "$1" -maxdepth 1 -name '*.note' 2>/dev/null | head -1)
  [ -n "$f" ] || fail "expected exactly one record in $1"
  basename "$f" .note
}

# --- 1. the captain's own note ---------------------------------------------

home=$(make_home captain)
out=$(inbox "$home" note "do the thing") || fail "a plain note should queue"
assert_contains "$out" 'queued ' "note should report the id it queued"
assert_contains "$out" 'firstmate will pick this up at its next check.' \
  "a queued note should say it was announced"

[ "$(notes_in "$home/state/inbox")" = 1 ] \
  || fail "a plain note belongs in the captain queue"
[ "$(notes_in "$home/state/inbox-auto")" = 0 ] \
  || fail "a plain note must never reach the automated queue"
assert_grep 'source=text' "$home/state/inbox/$(only_note "$home/state/inbox").note" \
  "a plain note should record the text class"
assert_grep 'check: captain inbox note ' "$home/state/.wake-queue" \
  "a captain note should wake as a captain record"
pass "a captain note files in state/inbox and wakes as a captain record"

# --- 2. automated classes keep their own queue ------------------------------

home=$(make_home automated)
for class in sentry lane-tick ci; do
  inbox "$home" note --source "$class" "auto body for $class" >/dev/null \
    || fail "note --source $class should queue"
done
printf 'piped auto body\n' | inbox "$home" note --source sentry - >/dev/null \
  || fail "note --source with a stdin body should queue"

[ "$(notes_in "$home/state/inbox")" = 0 ] \
  || fail "an automated note must never reach the captain queue"
[ "$(notes_in "$home/state/inbox-auto")" = 4 ] \
  || fail "every automated note belongs in state/inbox-auto"

sentry_record=$(grep -lF 'source=sentry' "$home/state/inbox-auto/"*.note | head -1)
[ -n "$sentry_record" ] \
  || fail "an automated note should record the class that wrote it"
assert_grep 'auto body for sentry' "$sentry_record" \
  "the automated queue should hold the record body"
lane_record=$(grep -lF 'auto body for lane-tick' "$home/state/inbox-auto/"*.note | head -1)
assert_grep 'source=lane-tick' "$lane_record" \
  "a lane-tick note should record the lane-tick class"

assert_grep 'check: automated inbox note ' "$home/state/.wake-queue" \
  "an automated note should wake saying it is automated"
assert_grep ' (lane-tick) - ' "$home/state/.wake-queue" \
  "an automated wake should name its class"
assert_no_grep 'check: captain inbox note' "$home/state/.wake-queue" \
  "no automated note may wake as a captain record"
pass "every automated class lands in state/inbox-auto, never the captain queue"

# --- 3. an unknown class refuses rather than guessing ----------------------

home=$(make_home unknown)
set +e
out=$(inbox "$home" note --source bogus "misclassified" 2>&1)
code=$?
set -e
[ "$code" -ne 0 ] || fail "an unknown class should refuse"
assert_contains "$out" 'unknown note class: bogus' \
  "the refusal should name the class it did not recognize"
assert_contains "$out" 'text voice' "the refusal should name the captain classes"
assert_contains "$out" 'sentry lane-tick ci' "the refusal should name the automated classes"
[ "$(notes_in "$home/state/inbox")" = 0 ] \
  || fail "a refused class must write nothing into the captain queue"
[ "$(notes_in "$home/state/inbox-auto")" = 0 ] \
  || fail "a refused class must write nothing into the automated queue"
assert_absent "$home/state/.wake-queue" "a refused class must not wake anyone"

# The same refusal must not consume a piped body first: validating after reading
# stdin would silently eat input a caller can never re-supply.
set +e
out=$(printf 'piped body\n' | inbox "$home" note --source bogus - 2>&1)
code=$?
set -e
[ "$code" -ne 0 ] || fail "an unknown class with a stdin body should refuse"
assert_contains "$out" 'unknown note class: bogus' \
  "a stdin note with a bad class should refuse by name"
pass "an unknown class refuses by name and writes nothing"

# --- 4. captain notes print first, the automated tail is bounded -----------

home=$(make_home listing)
inbox "$home" note "captain record one" >/dev/null || fail "captain note should queue"
for i in $(seq 1 25); do
  inbox "$home" note --source ci "ci poll $i" >/dev/null || fail "automated note $i should queue"
done

# Record ids are epoch-second prefixed, so the oldest records are the first
# names in sorted order; a bounded listing is the tail of that order.
oldest=$(find "$home"/state/inbox-auto -maxdepth 1 -name '*.note' | sort | head -5 | while read -r f; do
  basename "$f" .note
done)

listing=$(inbox "$home" list) || fail "list failed"
[ "$(printf '%s\n' "$listing" | head -1)" = "$(only_note "$home/state/inbox")" ] \
  || fail "the captain record should print first: $listing"
assert_contains "$listing" '--- automated queue: 25 waiting, none of it the captain ---' \
  "the automated queue should print after the captain's notes, labelled"
assert_contains "$listing" '5 older stay on disk' \
  "a bounded listing should say how many older automated records it did not print"

bounded=$(ids_of "$listing" | tail -n +2)
[ "$(printf '%s\n' "$bounded" | grep -c .)" -eq 20 ] \
  || fail "a bounded listing should print the newest 20 automated records, got: $bounded"

for id in $oldest; do
  case " $(printf '%s' "$bounded" | tr '\n' ' ') " in
    *" $id "*) fail "the bounded listing printed an old record: $id" ;;
  esac
done

every=$(ids_of "$(inbox "$home" list --all)")
[ "$(printf '%s\n' "$every" | grep -c .)" -eq 26 ] \
  || fail "--all should print the captain record and all 25 automated ones, got: $every"
for id in $oldest; do
  case " $(printf '%s' "$every" | tr '\n' ' ') " in
    *" $id "*) ;;
    *) fail "--all should still print the old record $id" ;;
  esac
done

drain_out=$(inbox "$home" drain) || fail "drain failed"
assert_contains "$drain_out" 'Ack with: fm-inbox.sh drain --ack <id>...' \
  "drain should keep telling the reader how to acknowledge"
[ "$(ids_of "$drain_out" | grep -c .)" -eq 21 ] \
  || fail "drain should be bounded exactly like list, got: $drain_out"
pass "list and drain print the captain's notes first and bound the automated tail"

# --- 5. acknowledgement reaches either queue -------------------------------

home=$(make_home acking)
inbox "$home" note "captain body" >/dev/null || fail "captain note should queue"
inbox "$home" note --source sentry "automated body" >/dev/null || fail "automated note should queue"
captain_id=$(only_note "$home/state/inbox")
auto_id=$(only_note "$home/state/inbox-auto")

out=$(inbox "$home" drain --ack "$captain_id" "$auto_id") || fail "ack failed"
assert_contains "$out" "acked $captain_id" "the captain record should acknowledge"
assert_contains "$out" "acked $auto_id" "the automated record should acknowledge"
assert_present "$home/state/inbox/handled/$captain_id.note" \
  "an acknowledged captain note belongs in its handled/ directory"
assert_present "$home/state/inbox-auto/handled/$auto_id.note" \
  "an acknowledged automated note belongs in its handled/ directory"
assert_absent "$home/state/inbox/$captain_id.note" \
  "an acknowledged captain note should leave the queue"
assert_absent "$home/state/inbox-auto/$auto_id.note" \
  "an acknowledged automated note should leave the queue"

out=$(inbox "$home" drain --ack "$captain_id") || fail "re-acking should be a no-op"
assert_contains "$out" "already-acked $captain_id" "re-acking should report already-acked"

set +e
out=$(inbox "$home" drain --ack '../inbox/escape' 2>&1)
code=$?
set -e
[ "$code" -ne 0 ] || fail "a path-shaped id should refuse"
assert_contains "$out" 'not a note id' "the refusal should say the id is not a note id"
pass "drain --ack retires a record from either queue and refuses a path-shaped id"

# --- 6. status counts the queues separately -------------------------------

home=$(make_home status)
out=$(inbox "$home" status) || fail "status failed"
assert_contains "$out" '0 note(s) waiting for firstmate' \
  "an empty home should report no captain notes"
assert_not_contains "$out" 'automated note(s) waiting' \
  "an empty automated queue should not print a line of its own"

inbox "$home" note "captain body" >/dev/null || fail "captain note should queue"
inbox "$home" note --source ci "automated body" >/dev/null || fail "automated note should queue"
out=$(inbox "$home" status) || fail "status failed with records"
assert_contains "$out" '1 note(s) waiting for firstmate' \
  "status should count the captain record"
assert_contains "$out" '1 automated note(s) waiting, none of it the captain' \
  "status should count the automated record separately"
pass "status counts the captain and automated queues separately"

printf 'all fm-inbox source-class cases passed\n'
