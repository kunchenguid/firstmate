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
#   7. A captain note cannot be closed without naming the work it produced: the
#      ack refuses until it carries --filed (the backlog rows) or --no-actions,
#      and either one is written into the handled copy as a filed= line. The
#      2026-11 measurement behind that gate: six captain notes, one laned, five
#      gone through a bare ack. Automated notes keep the bare ack.
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

# Select by the body, not the class: this case deliberately writes two sentry
# records (the flagged note and the piped-body note), and record ids are
# <epoch-second>-<random>, so every record here shares one second and the glob
# order is decided by the random suffix. Class-only selection therefore picked
# either record at random and flaked about half the time.
sentry_record=$(grep -lF 'auto body for sentry' "$home/state/inbox-auto/"*.note | head -1)
[ -n "$sentry_record" ] \
  || fail "an automated note should record the class that wrote it"
assert_grep 'source=sentry' "$sentry_record" \
  "an automated note should record the class that wrote it"
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
assert_contains "$drain_out" 'Ack a captain note with: fm-inbox.sh drain --filed <task-id>[,...] --ack <id>...  (or --no-actions)' \
  "drain should tell the reader how to acknowledge a captain note"
assert_contains "$drain_out" 'Ack an automated note with: fm-inbox.sh drain --ack <id>...' \
  "drain should keep telling the reader how to acknowledge an automated note"
[ "$(ids_of "$drain_out" | grep -c .)" -eq 21 ] \
  || fail "drain should be bounded exactly like list, got: $drain_out"
pass "list and drain print the captain's notes first and bound the automated tail"

# --- 5. acknowledgement reaches either queue -------------------------------

home=$(make_home acking)
inbox "$home" note "captain body" >/dev/null || fail "captain note should queue"
inbox "$home" note --source sentry "automated body" >/dev/null || fail "automated note should queue"
captain_id=$(only_note "$home/state/inbox")
auto_id=$(only_note "$home/state/inbox-auto")

out=$(inbox "$home" drain --no-actions --ack "$captain_id" "$auto_id") || fail "ack failed"
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

# --- 7. a captain note cannot be closed without naming its work -------------
#
# The failure this pins: a bare ack is a `mv` that cannot fail and asks nothing,
# so a note can be retired while its work never becomes a backlog row. Measured
# 2026-11-18: six captain notes, one became a task, five evaporated.

last_line() { tail -n 1 "$1"; }

home=$(make_home laning)
inbox "$home" note "ship the laning gate" >/dev/null || fail "captain note should queue"
captain_id=$(only_note "$home/state/inbox")

# 1. A bare ack cannot close a captain note, and must leave it in the queue.
set +e
out=$(inbox "$home" drain --ack "$captain_id" 2>&1)
code=$?
set -e
[ "$code" -ne 0 ] || fail "a bare ack of a captain note should refuse"
assert_contains "$out" '--filed' "the refusal should name --filed"
assert_contains "$out" '--no-actions' "the refusal should name --no-actions"
assert_present "$home/state/inbox/$captain_id.note" \
  "a refused ack must leave the captain note in the queue"
assert_absent "$home/state/inbox/handled/$captain_id.note" \
  "a refused ack must not file the captain note as handled"
pass "a captain note refuses a bare ack and stays in the queue"

# The captain's own voice reaches the same queue through `say`, so the spoken
# path is gated too: a spoken order is an assignment, not telemetry.
voice_home=$(make_home laning-voice)
inbox "$voice_home" note --source voice "spoken order" >/dev/null || fail "voice note should queue"
voice_id=$(only_note "$voice_home/state/inbox")
set +e
out=$(inbox "$voice_home" drain --ack "$voice_id" 2>&1)
code=$?
set -e
[ "$code" -ne 0 ] || fail "a bare ack of the captain's voice note should refuse"
assert_present "$voice_home/state/inbox/$voice_id.note" \
  "a refused ack must leave the voice note in the queue"

# 2. --filed closes it and records the rows it produced.
out=$(inbox "$home" drain --filed abc123 --ack "$captain_id") || fail "a filed ack should succeed"
assert_contains "$out" "acked $captain_id" "a filed ack should acknowledge the note"
assert_present "$home/state/inbox/handled/$captain_id.note" \
  "a filed ack should move the note into handled/"
assert_absent "$home/state/inbox/$captain_id.note" \
  "a filed ack should leave the captain queue"
[ "$(last_line "$home/state/inbox/handled/$captain_id.note")" = 'filed=abc123' ] \
  || fail "the handled copy should end with the rows the note produced, got: $(last_line "$home/state/inbox/handled/$captain_id.note")"
pass "a captain note acks with --filed and records the backlog rows it produced"

# 3. --no-actions closes it and records that decision, with several ids named.
home=$(make_home laning-none)
inbox "$home" note "no work here" >/dev/null || fail "captain note should queue"
none_id=$(only_note "$home/state/inbox")
out=$(inbox "$home" drain --no-actions --ack "$none_id") || fail "a --no-actions ack should succeed"
assert_contains "$out" "acked $none_id" "a --no-actions ack should acknowledge the note"
[ "$(last_line "$home/state/inbox/handled/$none_id.note")" = 'filed=none:--no-actions' ] \
  || fail "a --no-actions ack should record that the note needed no work"
pass "a captain note acks with --no-actions and records that it needed no work"

home=$(make_home laning-many)
inbox "$home" note "two rows" >/dev/null || fail "captain note should queue"
many_id=$(only_note "$home/state/inbox")
inbox "$home" drain --filed abc123,def456 --ack "$many_id" >/dev/null \
  || fail "a multi-row ack should succeed"
[ "$(last_line "$home/state/inbox/handled/$many_id.note")" = 'filed=abc123,def456' ] \
  || fail "a multi-row ack should record every id it named"

# 4. An automated note is telemetry and keeps the bare ack.
home=$(make_home laning-auto)
inbox "$home" note --source ci "ci poll" >/dev/null || fail "automated note should queue"
auto_id=$(only_note "$home/state/inbox-auto")
out=$(inbox "$home" drain --ack "$auto_id") || fail "an automated note should still ack with no flags"
assert_contains "$out" "acked $auto_id" "an automated note should acknowledge"
assert_present "$home/state/inbox-auto/handled/$auto_id.note" \
  "an acknowledged automated note belongs in its handled/ directory"
assert_no_grep 'filed=' "$home/state/inbox-auto/handled/$auto_id.note" \
  "an automated note must not gain a filing stamp: telemetry is not an assignment"
pass "an automated note still acks with no flags and gains no filing stamp"

# 5. One ack naming both a captain and an automated record treats them
#    independently: the captain record is stamped, the automated one is not.
home=$(make_home laning-mixed)
inbox "$home" note "captain body" >/dev/null || fail "captain note should queue"
inbox "$home" note --source lane-tick "automated body" >/dev/null || fail "automated note should queue"
mixed_captain=$(only_note "$home/state/inbox")
mixed_auto=$(only_note "$home/state/inbox-auto")
out=$(inbox "$home" drain --filed abc123 --ack "$mixed_captain" "$mixed_auto") \
  || fail "a mixed ack should succeed"
assert_contains "$out" "acked $mixed_captain" "the captain record should acknowledge"
assert_contains "$out" "acked $mixed_auto" "the automated record should acknowledge"
[ "$(last_line "$home/state/inbox/handled/$mixed_captain.note")" = 'filed=abc123' ] \
  || fail "a mixed ack should stamp the captain record"
assert_no_grep 'filed=' "$home/state/inbox-auto/handled/$mixed_auto.note" \
  "a mixed ack must not stamp the automated record"
pass "a mixed ack stamps the captain record and leaves the automated one alone"

# 6. --filed without a value is refused rather than recorded as an empty filing.
home=$(make_home laning-empty)
inbox "$home" note "needs a row" >/dev/null || fail "captain note should queue"
empty_id=$(only_note "$home/state/inbox")
set +e
out=$(inbox "$home" drain --filed --ack "$empty_id" 2>&1)
code=$?
set -e
[ "$code" -ne 0 ] || fail "--filed with no value at all should refuse"
assert_contains "$out" '--filed needs at least one backlog task id' \
  "the refusal should say --filed needs a task id, not name the next flag as one"
set +e
out=$(inbox "$home" drain --filed "" --ack "$empty_id" 2>&1)
code=$?
set -e
[ "$code" -ne 0 ] || fail "--filed with an empty value should refuse"
assert_contains "$out" '--filed needs at least one backlog task id' \
  "the refusal should say --filed needs a task id"
assert_present "$home/state/inbox/$empty_id.note" \
  "a refused empty filing must leave the captain note in the queue"
pass "--filed with an empty value is refused and files nothing"

printf 'all fm-inbox source-class cases passed\n'