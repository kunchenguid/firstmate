#!/usr/bin/env bash
# tests/fm-task-inbox.test.sh - the per-task steering inbox
# (bin/fm-task-inbox-lib.sh) and the watcher's re-ring ladder.
#
# The inbox+doorbell design replaces typed steer payloads with durable
# sequenced records acknowledged by an atomic mv into handled/; the terminal
# carries only a constant doorbell line, and the watcher re-rings an
# unacknowledged message before escalating once as an ordinary stale wake.
# These tests pin the semantics with real processes:
#   1. A message is written durably and appears in the inbox, byte-exact
#      including newlines, with a doorbell naming the inbox glob, numeric order,
#      and handled/.
#   2. Sequencing dedups per worker lifetime: the handled mv retires a record,
#      re-acking it is a no-op, and an acknowledged sequence is never reissued.
#      The idempotent enqueue (the remote steer leg's primitive) additionally
#      dedups an exact-body re-run onto the existing record: unhandled,
#      acknowledged in handled/, or surviving only as its hidden link.
#   3. No concurrent write can lose a record: many writers at once, a
#      colliding writer publishing into the slot this writer chose, a writer
#      that hits a live holder and times out, a writer that reclaims a stale
#      lock, and acknowledgements racing a burst of writers all end with every
#      instruction intact. Publishing is a no-clobber link, so the overwrite
#      guarantee does not depend on the sequence lock at all.
#   4. A write reports the record path only when that record is on disk with the
#      instructed text; a publish that cannot be verified, or an inbox replaced
#      underneath the writer, fails the write instead of reporting delivery.
#   5. A worker that deletes unread records in its own inbox (a broad rm or a
#      tidy-up glob) does not lose them: the hidden second link restores them
#      with their age, and acknowledgement retires that link.
#   6. The re-ring ladder: within grace is quiet, past grace rings, ring
#      spacing holds, a spent budget escalates exactly once, and an
#      acknowledgement resets the ladder for the next message.
#   7. A real fm-watch.sh subprocess re-rings the doorbell for an unhandled
#      aged message on an idle pane WITHOUT waking firstmate, waits on a busy
#      pane, stays silent on a healthy/empty inbox, surfaces unwritable ladder
#      bookkeeping only while its record remains unhandled, and emits exactly
#      one stale wake once the ring budget is spent.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-inbox)
# The doorbell line canonicalizes its paths, so keep the fixture root
# canonical too (a trailing-slash TMPDIR otherwise yields a double slash).
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Run one library function against a state dir through a subshell that sources
# the production library, so the tests exercise the executable surface rather
# than re-implementing any format knowledge here.
inbox_lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

# A fake tmux for the watcher cases: capture-pane replays FM_FAKE_TMUX_CAPTURE,
# display-message yields a numeric cursor row, and every literal send-keys is
# logged to FM_SEND_LOG so a doorbell ring is observable.
make_watch_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
      if [ -n "${FM_ACK_RECORD:-}" ] && [ -f "$FM_ACK_RECORD" ]; then
        mv "$FM_ACK_RECORD" "${FM_ACK_RECORD%/*}/handled/"
      fi
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -f "$FM_FAKE_TMUX_CAPTURE" ]; then
      cat "$FM_FAKE_TMUX_CAPTURE"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  make_fake_crew_state "$fb" >/dev/null
  printf '%s\n' "$fb"
}

watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 \
    env "$@" "$WATCH" > "$out" 2>/dev/null &
}

wait_watcher_gone() {  # <pid> [limit-ticks]
  local pid=$1 limit=${2:-120} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

age_path() {  # <path>  (set mtime well past any grace under test)
  touch -t 202001010000 "$1"
}

test_write_is_durable_and_exact() {
  local state rec rec2 doorbell doorbell2 expected actual expected2 actual2 text
  state="$TMP_ROOT/write/state"; mkdir -p "$state"
  text=$'line one\nline two with  spaces\n/slash body\n\n'
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "$text") \
    || fail "inbox write failed"
  [ -f "$rec" ] || fail "inbox write printed a path that does not exist: $rec"
  case "$rec" in
    "$state/t1.inbox/001.msg") : ;;
    *) fail "first record should be 001.msg under the task inbox, got $rec" ;;
  esac
  expected="$state/expected.body"
  actual="$state/actual.body"
  printf '%s' "$text" > "$expected"
  inbox_lib "$state" fm_task_inbox_body "$rec" > "$actual" \
    || fail "record body could not be read"
  cmp -s "$expected" "$actual" \
    || fail "record body did not preserve trailing and blank-line bytes"
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "no trailing newline") \
    || fail "second inbox write failed"
  expected2="$state/expected-no-newline.body"
  actual2="$state/actual-no-newline.body"
  printf '%s' "no trailing newline" > "$expected2"
  inbox_lib "$state" fm_task_inbox_body "$rec2" > "$actual2" \
    || fail "second record body could not be read"
  cmp -s "$expected2" "$actual2" \
    || fail "record body added a trailing newline"
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  doorbell2=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec2")
  [ "$doorbell" = "$doorbell2" ] \
    || fail "every record in one inbox should ring the same drain-all doorbell"
  assert_contains "$doorbell" "$state/t1.inbox/*.msg" "doorbell should name all unhandled records"
  assert_contains "$doorbell" "numeric order" "doorbell should require ordered processing"
  assert_contains "$doorbell" "$state/t1.inbox/handled/" "doorbell should name the handled dir"
  assert_contains "$doorbell" "Firstmate instruction waiting" "doorbell should be self-describing"
  case "$doorbell" in
    *$'\n'*) fail "the doorbell must be a single line" ;;
  esac
  pass "inbox: a steer is written durably and round-trips byte-exact with a self-describing doorbell"
}

# A worker already draining its inbox can move a just-published record into
# handled/ before the writer confirms it. That is the acknowledgement, so it must
# confirm delivery: reporting the steer as undelivered invites a duplicate
# retry of an instruction the worker has already acted on.
test_acknowledged_record_is_not_a_lost_steer() {
  local state rec
  state="$TMP_ROOT/acked-while-publishing/state"; mkdir -p "$state"
  rec=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    eval "$(declare -f fm_lock_release | sed "1s/fm_lock_release/_real_fm_lock_release/")"
    fm_lock_release() {
      local inbox=${1%/.seq.lock} f
      for f in "$inbox"/*.msg; do
        [ -e "$f" ] || continue
        mv "$f" "$inbox/handled/" || return 1
      done
      _real_fm_lock_release "$@"
    }
    fm_task_inbox_write "$2" t1 "steer acknowledged while publishing"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state") \
    || fail "the enqueue refused a steer the worker had already acknowledged"
  [ "$rec" = "$state/t1.inbox/001.msg" ] \
    || fail "the enqueue should still report its own record path, got $rec"
  [ -f "$state/t1.inbox/handled/001.msg" ] || fail "the fixture did not acknowledge the record"
  inbox_lib "$state" fm_task_inbox_verify "$rec" "steer acknowledged while publishing" \
    || fail "an acknowledged record must confirm delivery"
  inbox_lib "$state" fm_task_inbox_verify "$rec" "some other instruction" \
    && fail "confirmation must still require the instructed text"
  pass "inbox: a record acknowledged while publishing is delivered, not lost"
}

# The doorbell is a worker's primary instruction, so both acknowledgement forms
# it names must run exactly where the record lives. A state path with a space is
# supported (the brief scaffold quotes the same command for that reason).
test_doorbell_acknowledgement_forms_run_for_a_quoted_state_path() {
  local state rec line rename helper
  state="$TMP_ROOT/doorbell quoted state/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "instruction one")
  inbox_lib "$state" fm_task_inbox_write "$state" t1 "instruction two" >/dev/null
  line=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  rename=$(printf '%s' "$line" | sed -n 's/.*The plain form is \(.*\)\. Where that helper path.*/\1/p')
  [ -n "$rename" ] || fail "the doorbell did not name the plain rename acknowledgement: $line"
  sh -c "${rename//NNN/001}" >/dev/null 2>&1 \
    || fail "the doorbell's rename acknowledgement does not run for a quoted state path: $rename"
  [ -f "$state/t1.inbox/handled/001.msg" ] \
    || fail "the doorbell's rename acknowledgement did not acknowledge the record"
  helper=$(printf '%s' "$line" | sed -n 's/.*Where that helper path is reachable, \(.*\) acknowledges the same way.*/\1/p')
  [ -n "$helper" ] || fail "the doorbell did not name the ack helper command: $line"
  sh -c "${helper//NNN/002}" >/dev/null 2>&1 \
    || fail "the doorbell's helper acknowledgement does not run for a quoted state path: $helper"
  [ -f "$state/t1.inbox/handled/002.msg" ] \
    || fail "the doorbell's helper acknowledgement did not acknowledge the record"
  pass "inbox: the doorbell's acknowledgement forms run for a quoted state path"
}

test_idempotent_write_dedups_exact_body() {
  local state r1 r2 r3 r4 count text
  state="$TMP_ROOT/idem/state"; mkdir -p "$state"
  text=$'re-runnable steer\nsecond line'
  r1=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent write failed"
  [ "$r1" = "$state/t1.inbox/001.msg" ] || fail "first idempotent write should create 001.msg, got $r1"
  # Re-running the same enqueue (the safe recovery after an ambiguous remote
  # transport failure) lands on the SAME record, never a duplicate.
  r2=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent re-run failed"
  [ "$r2" = "$r1" ] || fail "an identical re-run should return the existing record, got $r2"
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "an identical re-run must not enqueue a duplicate, found $count records"
  # A different body - two logical requests differ at least by their embedded
  # correlation token - still enqueues normally.
  r3=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 $'re-runnable steer\nsecond line changed') \
    || fail "idempotent write of a different body failed"
  [ "$r3" = "$state/t1.inbox/002.msg" ] || fail "a different body should enqueue a new record, got $r3"
  # A body the worker already acknowledged still dedups: the re-run reports
  # the handled record rather than re-delivering an instruction that was
  # already acted on.
  mv "$r1" "$state/t1.inbox/handled/"
  r4=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent re-run after the ack failed"
  [ "$r4" = "$state/t1.inbox/handled/001.msg" ] \
    || fail "a re-run of an acknowledged steer should land on the handled record, got $r4"
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "a re-run of an acknowledged steer must not re-enqueue it, found $count unhandled records"
  pass "inbox: the idempotent enqueue dedups an exact re-run onto the same record, handled or not"
}

test_idempotent_write_follows_concurrent_ack() {
  local state rec result count text
  state="$TMP_ROOT/idem-ack-race/state"; mkdir -p "$state"
  text="acknowledge while dedup scans"
  rec=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "race fixture write failed"
  result=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    eval "$(declare -f fm_task_inbox_body | sed "1s/fm_task_inbox_body/_original_fm_task_inbox_body/")"
    fm_task_inbox_body() {
      candidate=$1
      case "$candidate" in
        */handled/*) ;;
        *) mv "$candidate" "${candidate%/*}/handled/" || return 1
           candidate="${candidate%/*}/handled/${candidate##*/}" ;;
      esac
      _original_fm_task_inbox_body "$candidate"
    }
    fm_task_inbox_write_idempotent "$2" t1 "$3"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state" "$text") \
    || fail "idempotent enqueue failed while acknowledgement moved its candidate"
  [ "$result" = "$state/t1.inbox/handled/${rec##*/}" ] \
    || fail "dedup did not follow the concurrently acknowledged record: $result"
  count=$(find "$state/t1.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "acknowledgement racing dedup created a duplicate record"
  pass "inbox: idempotent enqueue follows a record concurrently moved to handled"
}

test_handled_mv_dedups_by_sequence() {
  local state r1 r2 oldest r3
  state="$TMP_ROOT/dedup/state"; mkdir -p "$state"
  r1=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "first")
  r2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "second")
  [ "$r2" = "$state/t1.inbox/002.msg" ] || fail "second record should be 002.msg, got $r2"
  oldest=$(inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1)
  [ "$oldest" = "$r1" ] || fail "oldest unhandled should be 001, got $oldest"
  mv "$r1" "$state/t1.inbox/handled/"
  oldest=$(inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1)
  [ "$oldest" = "$r2" ] || fail "after the ack mv the oldest should advance to 002, got $oldest"
  # Re-acking the same message is a no-op: the record is already retired and
  # nothing re-lists it as unhandled.
  mv "$state/t1.inbox/001.msg" "$state/t1.inbox/handled/" 2>/dev/null \
    && fail "a second mv of an acked record should find nothing to move"
  mv "$r2" "$state/t1.inbox/handled/"
  if inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1 >/dev/null; then
    fail "a fully handled inbox should report no unhandled record"
  fi
  # An acknowledged sequence is never reissued, so a message is processed at
  # most once per worker lifetime even if every doorbell is duplicated.
  r3=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "third")
  [ "$r3" = "$state/t1.inbox/003.msg" ] || fail "a handled sequence was reissued: $r3"
  pass "inbox: the handled mv is the idempotent ack and sequences are never reissued"
}

test_concurrent_writers_never_clobber() {
  local state i pids=() count
  state="$TMP_ROOT/race/state"; mkdir -p "$state"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer number $i" >/dev/null &
    pids+=($!)
  done
  for i in "${pids[@]}"; do
    wait "$i" || fail "a concurrent inbox write failed"
  done
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 20 ] || fail "20 concurrent writes should yield 20 records, got $count:"$'\n'"$(ls "$state/t1.inbox")"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -rqF "steer number $i" "$state/t1.inbox" \
      || fail "steer number $i was lost in the concurrent write race"
  done
  pass "inbox: concurrent writers lose nothing"
}

# The overwrite guarantee itself: a writer whose chosen slot is taken by a
# colliding publisher (another home's copy of the library, a lead worker
# repairing an inbox by hand, a Fable driver copying a record in) must never
# replace that record. The shim publishes a foreign record into the slot this
# writer computed, then hands over to the real tool, so the collision lands
# exactly where a real one would.
test_colliding_writer_never_clobbers() {
  local state fakebin marker foreign rec real_ln count
  state="$TMP_ROOT/colliding-writer/state"
  fakebin="$TMP_ROOT/colliding-writer/fakebin"
  marker="$TMP_ROOT/colliding-writer/published"
  foreign="$TMP_ROOT/colliding-writer/foreign.msg"
  mkdir -p "$state" "$fakebin"
  real_ln=$(command -v ln)
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  -*) ;;
  *)
    if [ ! -e "$FM_COLLIDE_MARKER" ]; then
      : > "$FM_COLLIDE_MARKER"
      cp "$FM_COLLIDE_FOREIGN" "${2:-}"
    fi
    ;;
esac
exec "$FM_REAL_LN" "$@"
SH
  chmod +x "$fakebin/ln"
  printf 'foreign instruction, do not lose me\n' > "$foreign"

  rec=$(PATH="$fakebin:$PATH" FM_REAL_LN="$real_ln" FM_COLLIDE_MARKER="$marker" \
    FM_COLLIDE_FOREIGN="$foreign" \
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "firstmate instruction") \
    || fail "a writer gave up instead of taking the next free sequence"
  [ -f "$state/t1.inbox/001.msg" ] \
    || fail "the colliding writer's record was destroyed:"$'\n'"$(ls "$state/t1.inbox")"
  grep -qF 'foreign instruction, do not lose me' "$state/t1.inbox/001.msg" \
    || fail "the record in the contested slot is not the colliding writer's"
  [ "$rec" = "$state/t1.inbox/002.msg" ] \
    || fail "the writer should have published past the taken slot, got $rec"
  grep -qF 'firstmate instruction' "$rec" || fail "the writer's own record is missing its body"
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "expected 2 records after the collision, got $count"
  pass "inbox: a colliding writer can never overwrite an existing record"
}

# A live holder keeps the lock; a writer that cannot get it in its bounded wait
# refuses instead of writing blind, and refuses without touching the inbox.
test_writer_refuses_when_lock_wait_times_out() {
  local state holder rec rc
  state="$TMP_ROOT/lock-timeout/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "already queued")
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_task_inbox_lock_acquire "$2" || exit 1
    printf "held\n" > "$3"
    sleep 30
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state/t1.inbox/.seq.lock" "$state/held" &
  holder=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$state/held" ] && break
    sleep 0.1
  done
  [ -e "$state/held" ] || { kill "$holder" 2>/dev/null; fail "the fixture never took the sequence lock"; }
  rc=0
  FM_TASK_INBOX_LOCK_WAIT_SECS=0 bash -c '
    . "$1"
    fm_task_inbox_write "$2" t1 "steer while locked" >/dev/null 2>&1
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state" || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "a writer whose lock wait expired reported a successful write"
  [ -f "$rec" ] || fail "the queued record disappeared while the lock was contended"
  [ ! -e "$state/t1.inbox/002.msg" ] \
    || fail "a writer that never held the lock still published a record"
  pass "inbox: a writer whose lock wait expires refuses instead of writing blind"
}

# A lock stranded by a killed holder is reclaimed, and the reclaim still
# publishes into a free slot rather than over a record already there.
test_writer_reclaims_stale_lock_without_clobbering() {
  local state own rec
  state="$TMP_ROOT/stale-lock/state"; mkdir -p "$state/t1.inbox/handled"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "queued before the crash")
  own=$(mktemp -d "$state/t1.inbox/.seq.lock.owner.XXXXXX")
  printf '999999\n' > "$own/pid"
  ln -s "$own" "$state/t1.inbox/.seq.lock"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer after the crash") \
    || fail "a writer refused to reclaim a lock whose holder was gone"
  [ "$rec" = "$state/t1.inbox/002.msg" ] \
    || fail "the reclaimed lock published into a taken slot: $rec"
  grep -qF 'queued before the crash' "$state/t1.inbox/001.msg" \
    || fail "reclaiming the stale lock clobbered the queued record"
  pass "inbox: a reclaimed stale lock never costs a queued record"
}

# Acknowledgements run without the lock, concurrently with writers. Every
# writer must still land its own record and no sequence may be reused.
test_concurrent_acknowledgements_lose_nothing() {
  local state i pids=() count bodies=0
  state="$TMP_ROOT/ack-race/state"; mkdir -p "$state"
  inbox_lib "$state" fm_task_inbox_write "$state" t1 "seed record" >/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "racy steer $i" >/dev/null &
    pids+=($!)
  done
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    for f in "$state/t1.inbox"/*.msg; do
      [ -e "$f" ] || continue
      mv "$f" "$state/t1.inbox/handled/" 2>/dev/null || true
    done
  done
  for i in "${pids[@]}"; do
    wait "$i" || fail "a writer failed while acknowledgements were moving records"
  done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    grep -rqF "racy steer $i" "$state/t1.inbox" \
      || fail "racy steer $i was lost to a concurrent acknowledgement"
    bodies=$((bodies + 1))
  done
  count=$(find "$state/t1.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" -ge "$bodies" ] \
    || fail "fewer records survive than instructions were written ($count < $bodies)"
  pass "inbox: acknowledgements racing a burst of writers lose no instruction"
}

# A publish that cannot be confirmed, and an inbox replaced between publish and
# release, are both refusals: the enqueue never prints a path for a record that
# is not on disk carrying its text.
test_write_refuses_an_unconfirmed_record() {
  local state fakebin real_ln rc
  state="$TMP_ROOT/unconfirmed/state"
  fakebin="$TMP_ROOT/unconfirmed/fakebin"
  mkdir -p "$state" "$fakebin"
  real_ln=$(command -v ln)
  # A publish that reports success without creating the record (a lost link on
  # a replaced directory) must never read as a written steer.
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  -*) exec "$FM_REAL_LN" "$@" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/ln"
  rc=0
  PATH="$fakebin:$PATH" FM_REAL_LN="$real_ln" \
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer into a void" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a write whose record never appeared reported success"
  [ -z "$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg')" ] \
    || fail "a failed publish left a record behind"
  [ -z "$(find "$state/t1.inbox" -maxdepth 1 -name '.staging.*')" ] \
    || fail "a failed publish left its staging file behind"

  # The inbox replaced underneath a writer (retired and recreated between
  # publish and release) is the shape that once reported a send as delivered
  # with no record anywhere: the enqueue must fail instead.
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    eval "$(declare -f fm_lock_release | sed "1s/fm_lock_release/_real_fm_lock_release/")"
    fm_lock_release() {
      rm -rf "${1%/.seq.lock}"
      _real_fm_lock_release "$@"
    }
    fm_task_inbox_write "$2" t1 "steer into a retired inbox" >/dev/null
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state" || rc=$?
  [ "$rc" -ne 0 ] || fail "a write into an inbox replaced under it reported success"
  pass "inbox: an unconfirmable record fails the write instead of reporting delivery"
}

# A worker's own cleanup inside its inbox is a real loss path: a broad rm or a
# tidy-up glob deletes unread records, which the ladder used to read as "nothing
# waiting". The hidden second link must bring the instruction back, with its age
# intact so it still rings and escalates.
test_worker_deletion_is_repaired() {
  local state rec rec2 gone action
  state="$TMP_ROOT/worker-deletes/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "instruction one")
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "instruction two")
  rm -f "$state/t1.inbox/"*.msg   # the worker's cleanup: unread records, gone
  [ ! -e "$rec" ] && [ ! -e "$rec2" ] || fail "the fixture did not delete the records"
  inbox_lib "$state" fm_task_inbox_restore_unhandled "$state" t1 >/dev/null 2>&1
  grep -qF 'instruction one' "$rec" || fail "a deleted unread record was not restored"
  grep -qF 'instruction two' "$rec2" || fail "the second deleted record was not restored"
  age_path "$rec"
  action=$(inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  case "$action" in
    ring" "*|escalate" "*) ;;
    *) fail "a restored record did not reach the re-ring ladder: $action" ;;
  esac

  # Acknowledgement retires the shadow, so nothing comes back after the mv.
  mv "$rec" "$state/t1.inbox/handled/"
  mv "$rec2" "$state/t1.inbox/handled/"
  inbox_lib "$state" fm_task_inbox_restore_unhandled "$state" t1 >/dev/null 2>&1
  [ ! -e "$rec" ] || fail "an acknowledged record was resurrected by the repair pass"
  [ -z "$(find "$state/t1.inbox/.unhandled" -type f 2>/dev/null)" ] \
    || fail "the repair pass left shadow links behind after acknowledgement"
  action=$(inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a fully acknowledged inbox should be quiet, got: $action"
  pass "inbox: unread records deleted by a worker's own cleanup are restored"
}

# A worker's cleanup can leave a record's hidden link as its only remaining
# copy. That sequence is still taken, so the next enqueue must order after it: a
# reissued name would make the repair pass skip the deleted record (the name is
# present again, carrying different bytes) and the acknowledgement of the new
# record would then retire the shadow, losing the original instruction for good.
test_deleted_record_keeps_its_sequence() {
  local state first second
  state="$TMP_ROOT/deleted-keeps-seq/state"; mkdir -p "$state"
  first=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "instruction A")
  rm -f "$state/t1.inbox/"*.msg
  second=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "instruction B")
  [ "$second" != "$first" ] \
    || fail "an enqueue reused the sequence of a record that survives only as its hidden link"
  inbox_lib "$state" fm_task_inbox_restore_unhandled "$state" t1 >/dev/null 2>&1
  grep -qF 'instruction A' "$first" || fail "the deleted instruction was not restored under its own name"
  grep -qF 'instruction B' "$second" || fail "the repair pass disturbed the later instruction"
  # Acknowledging the later record must not retire the earlier one's link.
  "$ROOT/bin/fm-inbox-ack.sh" "$state" t1 "${second##*/}" >/dev/null 2>&1 \
    || fail "the ack helper refused the later record"
  inbox_lib "$state" fm_task_inbox_restore_unhandled "$state" t1 >/dev/null 2>&1
  grep -qF 'instruction A' "$first" \
    || fail "acknowledging the later record lost the instruction whose only link was hidden"
  pass "inbox: a record surviving only as its hidden link keeps its sequence"
}

# The documented safe recovery for an ambiguous transport failure is to re-run
# the idempotent enqueue. When the worker's cleanup already deleted the visible
# record, that re-run must land on the record that survives only as its hidden
# link: publishing a second record would hand the worker one instruction twice
# as soon as the repair pass restores the original.
test_idempotent_write_dedups_onto_a_hidden_link() {
  local state first second count text
  state="$TMP_ROOT/idem-shadow/state"; mkdir -p "$state"
  text='correlated request corr=abc'
  first=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent write failed"
  [ "$first" = "$state/t1.inbox/001.msg" ] || fail "first idempotent write should create 001.msg, got $first"
  [ -e "$state/t1.inbox/.unhandled/001" ] \
    || fail "the publish did not leave a hidden link for the unread record"
  rm -f "$state/t1.inbox/"*.msg  # the worker's cleanup, which this plane tolerates
  second=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "the idempotent re-run refused a record that survives only as its hidden link"
  [ "$second" = "$first" ] \
    || fail "the re-run should land on the original record, got $second"
  grep -qF "$text" "$first" \
    || fail "the re-run did not link the hidden record back into the inbox"
  count=$(find "$state/t1.inbox" -maxdepth 1 -type f -name '*.msg' | wc -l | tr -d '[:space:]')
  [ "$count" = 1 ] \
    || fail "the re-run published a duplicate of the deleted record, found $count records"
  inbox_lib "$state" fm_task_inbox_restore_unhandled "$state" t1 >/dev/null 2>&1
  count=$(find "$state/t1.inbox" -maxdepth 1 -type f -name '*.msg' | wc -l | tr -d '[:space:]')
  [ "$count" = 1 ] \
    || fail "the repair pass restored a duplicate beside the deduped record, found $count records"
  [ -e "$state/t1.inbox/.unhandled/001" ] \
    || fail "the original record's hidden link should still be there for the deletion repair"
  pass "inbox: an idempotent re-run dedups onto a record surviving only as its hidden link"
}

# A coalescing tick supersedes its predecessor for good: the retired record's
# shadow must go with it, or the repair pass would resurrect every old tick.
test_coalesced_superseded_record_is_not_resurrected() {
  local state first second
  state="$TMP_ROOT/coalesce-shadow/state"; mkdir -p "$state"
  first=$(inbox_lib "$state" fm_task_inbox_write_coalesced "$state" t1 "tick" tick)
  second=$(inbox_lib "$state" fm_task_inbox_write_coalesced "$state" t1 "tick" tick)
  [ ! -e "$first" ] || fail "coalescing did not retire the previous tick"
  inbox_lib "$state" fm_task_inbox_restore_unhandled "$state" t1 >/dev/null 2>&1
  [ ! -e "$first" ] || fail "the repair pass resurrected a superseded tick: $first"
  [ -f "$second" ] || fail "the surviving tick disappeared"
  pass "inbox: a superseded coalesced tick is never resurrected"
}

# The blessed acknowledgement path (bin/fm-inbox-ack.sh): it retires the record
# and its hidden link together, tolerates a re-run after a lost reply, and
# refuses anything that is not a sequence, so a worker never has to hand-roll a
# move or a cleanup inside its own inbox.
test_ack_helper_acknowledges_safely() {
  local state rec out rc
  state="$TMP_ROOT/ack-helper/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "instruction to acknowledge")
  out=$("$ROOT/bin/fm-inbox-ack.sh" "$state" t1 001) \
    || fail "the ack helper refused a real record"
  assert_contains "$out" "acknowledged" "the ack helper should report the acknowledgement"
  [ ! -e "$rec" ] || fail "the ack helper left the record in the inbox root"
  [ -f "$state/t1.inbox/handled/001.msg" ] || fail "the ack helper did not move the record into handled/"
  [ -z "$(find "$state/t1.inbox/.unhandled" -type f 2>/dev/null)" ] \
    || fail "the ack helper left the record's hidden link behind"
  out=$("$ROOT/bin/fm-inbox-ack.sh" "$state" t1 001) \
    || fail "a repeated acknowledgement should be a harmless no-op"
  assert_contains "$out" "already acknowledged" "a repeated acknowledgement should say so"
  rc=0
  "$ROOT/bin/fm-inbox-ack.sh" "$state" t1 007 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the ack helper acknowledged a record that does not exist"
  rc=0
  "$ROOT/bin/fm-inbox-ack.sh" "$state" t1 'handled/001.msg.bak' >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the ack helper accepted a name that is not a sequence"
  [ -f "$state/t1.inbox/handled/001.msg" ] \
    || fail "a refused acknowledgement disturbed an acknowledged record"
  pass "inbox: the ack helper acknowledges records without hand-rolled inbox handling"
}

# The blocked-then-acknowledged case: a worker that already deleted the visible
# record still gets to acknowledge it, from the hidden link, instead of being
# told the record never existed. The acknowledgement must also retire the link,
# otherwise the repair pass hands the worker its own handled instruction again.
test_acknowledge_from_the_hidden_link_only() {
  local state rec out rc
  state="$TMP_ROOT/ack-shadow/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "instruction to acknowledge")
  rm -f "$rec"                    # the worker's cleanup took the visible name
  [ -e "$state/t1.inbox/.unhandled/001" ] || fail "the fixture lost the hidden link"
  out=$(inbox_lib "$state" fm_task_inbox_acknowledge "$state" t1 001) \
    || fail "acknowledging a record that survives only as its hidden link was refused"
  assert_contains "$out" "acknowledged" "a shadow-only acknowledgement should report success"
  grep -qF 'instruction to acknowledge' "$state/t1.inbox/handled/001.msg" \
    || fail "the acknowledged record did not reach handled/ with its text"
  [ -z "$(find "$state/t1.inbox/.unhandled" -type f 2>/dev/null)" ] \
    || fail "acknowledging from the hidden link left that link behind"
  inbox_lib "$state" fm_task_inbox_restore_unhandled "$state" t1 >/dev/null 2>&1
  [ ! -e "$state/t1.inbox/001.msg" ] \
    || fail "an acknowledged record was restored after the acknowledgement"
  rc=0
  inbox_lib "$state" fm_task_inbox_acknowledge "$state" t1 042 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "acknowledging a record that never existed should fail"
  rc=0
  inbox_lib "$state" fm_task_inbox_acknowledge "$state" t1 'nope' >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the acknowledge operation accepted a name that is not a sequence"
  pass "inbox: a record the worker already deleted can still be acknowledged, from its hidden link"
}

# The repair must not only protect records published by this version: a record
# queued by an earlier one has no hidden link, so the repair pass adopts it and
# the deletion it suffers afterwards is repairable.
test_repair_adopts_records_queued_without_a_link() {
  local state rec action
  state="$TMP_ROOT/adopt/state"; mkdir -p "$state/t1.inbox/handled"
  # A record as an earlier version left it: no hidden link anywhere.
  printf 'schema=fm-task-inbox.v1\nat=2020-01-01T00:00:00Z\n--\nolder unread instruction\n' \
    > "$state/t1.inbox/007.msg"
  rec="$state/t1.inbox/007.msg"
  age_path "$rec"
  [ ! -e "$state/t1.inbox/.unhandled/007" ] || fail "the fixture already had a link"
  action=$(inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ -e "$state/t1.inbox/.unhandled/007" ] \
    || fail "the repair pass did not adopt a pre-existing unread record"
  case "$action" in ring" "*|escalate" "*) ;; *) fail "the adopted record is not on the ladder: $action" ;; esac
  rm -f "$rec"                    # now the same cleanup hits the adopted record
  inbox_lib "$state" fm_task_inbox_restore_unhandled "$state" t1 >/dev/null 2>&1
  grep -qF 'older unread instruction' "$rec" \
    || fail "an adopted pre-existing record was not repaired after deletion"
  pass "inbox: the repair adopts unread records queued before it existed"
}

# A coalesced tick the worker already deleted survives only as its hidden link.
# The supersession sweep must retire that link, or the repair pass resurrects a
# tick its replacement already covered.
test_coalesce_retires_a_deleted_superseded_tick() {
  local state root shadow
  state="$TMP_ROOT/coalesce-shadow/state"; mkdir -p "$state"
  inbox_lib "$state" fm_task_inbox_write_coalesced "$state" t1 "tick one" tick >/dev/null 2>&1
  rm -f "$state/t1.inbox/"*.msg  # the worker's cleanup, before the next tick
  inbox_lib "$state" fm_task_inbox_write_coalesced "$state" t1 "tick two" tick >/dev/null 2>&1
  inbox_lib "$state" fm_task_inbox_restore_unhandled "$state" t1 >/dev/null 2>&1
  root=$(find "$state/t1.inbox" -maxdepth 1 -type f -name '*.msg' | wc -l | tr -d '[:space:]')
  [ "$root" = 1 ] || fail "a superseded tick was resurrected beside its replacement ($root records)"
  grep -qF 'tick two' "$state/t1.inbox/"*.msg || fail "the surviving record is not the replacement tick"
  shadow=$(find "$state/t1.inbox/.unhandled" -type f | wc -l | tr -d '[:space:]')
  [ "$shadow" = 1 ] || fail "the superseded tick's hidden link survived supersession ($shadow links)"
  pass "inbox: coalescing retires a superseded tick whose visible record was already deleted"
}

# The doorbell must name the inbox a record belongs to even when the record is
# already in handled/ - otherwise it tells the worker to acknowledge against
# "<id>.inbox/handled.inbox", which cannot exist.
test_doorbell_names_the_inbox_for_a_handled_record() {
  local state line
  state="$TMP_ROOT/doorbell-handled/state"; mkdir -p "$state"
  inbox_lib "$state" fm_task_inbox_write "$state" t1 "instruction" >/dev/null
  inbox_lib "$state" fm_task_inbox_acknowledge "$state" t1 001 >/dev/null \
    || fail "the fixture could not acknowledge its record"
  line=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$state/t1.inbox/handled/001.msg")
  assert_not_contains "$line" "handled.inbox" \
    "the doorbell derived a nonsense inbox from a handled record"
  assert_contains "$line" "$state/t1.inbox" "the doorbell should name the inbox itself"
  pass "inbox: the doorbell names the real inbox for a record already in handled/"
}

test_writer_retries_after_a_vanished_lock_collision() {
  local state fakebin marker rec real_ln
  state="$TMP_ROOT/vanished-lock-race/state"
  fakebin="$TMP_ROOT/vanished-lock-race/fakebin"
  marker="$TMP_ROOT/vanished-lock-race/first-ln-failed"
  mkdir -p "$state" "$fakebin"
  real_ln=$(command -v ln)
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
if [ ! -e "$FM_FAKE_LN_MARKER" ]; then
  : > "$FM_FAKE_LN_MARKER"
  exit 1
fi
exec "$FM_REAL_LN" "$@"
SH
  chmod +x "$fakebin/ln"

  rec=$(PATH="$fakebin:$PATH" FM_REAL_LN="$real_ln" FM_FAKE_LN_MARKER="$marker" \
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer after collision") \
    || fail "a writer abandoned an acquisition whose competing lock had already vanished"
  [ -f "$rec" ] || fail "the retry after a vanished lock collision did not write its record"
  pass "inbox: a writer retries when a competing lock vanishes after its failed claim"
}

test_ladder_writes_ignore_vanished_inbox() {
  local state rec
  state="$TMP_ROOT/vanished/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "retired task")
  rm -rf "$state/t1.inbox"
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" \
    || fail "ring bookkeeping should ignore a concurrently removed inbox"
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec" \
    || fail "escalation bookkeeping should ignore a concurrently removed inbox"
  [ ! -e "$state/t1.inbox" ] || fail "bookkeeping recreated a retired task inbox"
  pass "inbox: ladder bookkeeping ignores a concurrently removed inbox"
}

test_fire_and_forget_records_never_enter_the_ladder() {
  local state fire tracked action
  state="$TMP_ROOT/fire-and-forget/state"; mkdir -p "$state"
  fire=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "one-shot steer" fire-and-forget)
  age_path "$fire"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a fire-and-forget record entered the re-ring ladder: $action"
  tracked=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "tracked steer")
  age_path "$tracked"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $tracked 0" ] \
    || fail "a fire-and-forget record hid the later tracked steer: $action"
  [ -f "$fire" ] || fail "excluding fire-and-forget from escalation removed its durable record"
  pass "inbox: fire-and-forget records stay durable and outside the ladder"
}

test_ring_ladder_policy() {
  local state rec action
  state="$TMP_ROOT/ladder/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "do the thing")
  # Within grace: quiet.
  action=$(FM_TASK_INBOX_GRACE_SECS=3600 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a fresh unhandled message inside grace should be quiet, got: $action"
  # Past grace: one ring is due.
  age_path "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "an aged unhandled message should be due a ring, got: $action"
  # A just-recorded ring holds the spacing: quiet until another grace elapses.
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a ring within the spacing window should be quiet, got: $action"
  # Backdate the ladder: the next ring becomes due, and at the budget the
  # action turns into a single escalation.
  printf '001.msg\t1\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "an aged ladder should ring again, got: $action"
  printf '001.msg\t3\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $rec 3" ] || fail "a spent ring budget should escalate, got: $action"
  # Escalation fires at most once per message.
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "an escalated message should stay quiet for recovery, got: $action"
  # The acknowledgement resets the ladder: the next message starts fresh.
  mv "$rec" "$state/t1.inbox/handled/"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a handled inbox should be quiet, got: $action"
  [ ! -e "$state/t1.inbox/.escalated" ] || fail "the ack should clear the escalation marker"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "next thing")
  age_path "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "the next message should start a fresh ladder, got: $action"
  pass "inbox: the re-ring ladder paces by grace, escalates once, and resets on ack"
}

setup_watch_case() {  # <name> -> echoes case dir; state in <dir>/state
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  make_watch_stubs "$dir" >/dev/null
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=grok"
  printf '%s\n' "$dir"
}

idle_capture() {  # <dir>
  printf '╭────╮\n│    │\n╰────╯\n' > "$1/idle.capture"
  printf '%s\n' "$1/idle.capture"
}

test_watcher_rerings_idle_pane_quietly() {
  local dir state out log pid rec
  dir=$(setup_watch_case rering)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  local i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'Firstmate instruction waiting' "$log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "Firstmate instruction waiting: list $state/t1.inbox/*.msg" "$log" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never re-rang the doorbell:"$'\n'"$(cat "$log")"; }
  kill -0 "$pid" 2>/dev/null \
    || fail "a healthy re-ring must not wake firstmate (watcher exited):"$'\n'"$(cat "$out")"
  [ ! -s "$state/.wake-queue" ] \
    || { kill "$pid" 2>/dev/null; fail "a healthy re-ring queued a wake:"$'\n'"$(cat "$state/.wake-queue")"; }
  # The acknowledgement silences the ladder: no further doorbells after the mv.
  mv "$rec" "$state/t1.inbox/handled/"
  sleep 2.5
  : > "$log"
  sleep 2.5
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "the watcher kept ringing after the ack:"$'\n'"$(cat "$log")"
  pass "watcher: an unhandled aged message on an idle pane re-rings without waking firstmate, and the ack silences it"
}

test_watcher_waits_on_busy_pane() {
  local dir state out log pid rec
  dir=$(setup_watch_case busywait)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  printf 'some output\nBUSYTOKEN active\n' > "$dir/busy.capture"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$dir/busy.capture" \
    FM_BUSY_REGEX=BUSYTOKEN FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "a busy pane should wait, not ring:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] || fail "a busy wait queued a wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a busy pane just waits - the record is durable and no doorbell is typed"
}

test_watcher_quiet_on_healthy_inbox() {
  local dir state out log pid
  dir=$(setup_watch_case healthy)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  mkdir -p "$state/t1.inbox/handled"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill -0 "$pid" 2>/dev/null || fail "the watcher exited on a healthy empty inbox:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "an empty inbox rang a doorbell:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] || fail "an empty inbox queued a wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a healthy or empty inbox stays completely silent"
}

test_watcher_ack_silences_unwritable_ladder() {
  local dir state out log pid rec rings i=0
  dir=$(setup_watch_case ack-unwritable-ladder)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  mkdir "$state/t1.inbox/.ring-state"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_ACK_RECORD="$rec" FM_TASK_INBOX_RING_MAX=99
  pid=$!
  while [ "$i" -lt 100 ]; do
    [ -f "$state/t1.inbox/handled/001.msg" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$state/t1.inbox/handled/001.msg" ] \
    || { kill "$pid" 2>/dev/null; fail "the doorbell stub did not acknowledge the record"; }
  sleep 2
  kill -0 "$pid" 2>/dev/null \
    || fail "the watcher escalated ladder failure after the record was acknowledged:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "acknowledgement should silence retries, got $rings doorbells:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "an acknowledged record queued a bookkeeping wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: acknowledgement silences an unwritable ladder without a stale wake"
}

test_watcher_surfaces_unwritable_ladder() {
  local dir state out log pid rec rings wakes
  dir=$(setup_watch_case unwritable-ladder)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  mkdir "$state/t1.inbox/.ring-state"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher silently retried with unwritable ladder bookkeeping"; }
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "expected one doorbell before the bookkeeping wake, got $rings:"$'\n'"$(cat "$log")"
  wakes=$(grep -cF 'steering-inbox ladder bookkeeping unwritable' "$state/.wake-queue" || true)
  [ "$wakes" = 1 ] \
    || fail "expected exactly one bookkeeping-unwritable stale wake, got $wakes:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "$state/t1.inbox/.ring-state cannot be written" "$state/.wake-queue" \
    || fail "the stale wake did not identify the unwritable ladder:"$'\n'"$(cat "$state/.wake-queue")"
  [ -f "$rec" ] || fail "the unhandled record disappeared during bookkeeping failure"
  grep -qF 'stale:' "$out" \
    || fail "the watcher should exit through the ordinary stale wake:"$'\n'"$(cat "$out")"
  pass "watcher: unwritable ladder bookkeeping surfaces a stale wake after the doorbell"
}

test_watcher_escalates_once_after_budget() {
  local dir state out log pid rec rings
  dir=$(setup_watch_case escalate)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never escalated a spent ring budget"; }
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "expected exactly 1 doorbell before escalation, got $rings:"$'\n'"$(cat "$log")"
  grep -qF 'unread firstmate instruction' "$state/.wake-queue" \
    || fail "the escalation should queue a stale wake naming the unread instruction:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "$rec" "$state/.wake-queue" \
    || fail "the stale wake should name the record path:"$'\n'"$(cat "$state/.wake-queue")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue")" = 1 ] \
    || fail "the escalation must fire exactly once:"$'\n'"$(cat "$state/.wake-queue")"
  grep -qF 'stale:' "$out" || fail "the watcher should exit through the ordinary stale wake:"$'\n'"$(cat "$out")"
  pass "watcher: a spent ring budget emits exactly one ordinary stale wake for recovery"
}

test_write_is_durable_and_exact
test_idempotent_write_dedups_exact_body
test_idempotent_write_follows_concurrent_ack
test_idempotent_write_dedups_onto_a_hidden_link
test_handled_mv_dedups_by_sequence
test_concurrent_writers_never_clobber
test_colliding_writer_never_clobbers
test_writer_refuses_when_lock_wait_times_out
test_writer_reclaims_stale_lock_without_clobbering
test_concurrent_acknowledgements_lose_nothing
test_write_refuses_an_unconfirmed_record
test_acknowledged_record_is_not_a_lost_steer
test_doorbell_acknowledgement_forms_run_for_a_quoted_state_path
test_worker_deletion_is_repaired
test_deleted_record_keeps_its_sequence
test_coalesced_superseded_record_is_not_resurrected
test_ack_helper_acknowledges_safely
test_acknowledge_from_the_hidden_link_only
test_repair_adopts_records_queued_without_a_link
test_coalesce_retires_a_deleted_superseded_tick
test_doorbell_names_the_inbox_for_a_handled_record
test_writer_retries_after_a_vanished_lock_collision
test_ladder_writes_ignore_vanished_inbox
test_fire_and_forget_records_never_enter_the_ladder
test_ring_ladder_policy
test_watcher_rerings_idle_pane_quietly
test_watcher_waits_on_busy_pane
test_watcher_quiet_on_healthy_inbox
test_watcher_ack_silences_unwritable_ladder
test_watcher_surfaces_unwritable_ladder
test_watcher_escalates_once_after_budget
