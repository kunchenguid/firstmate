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
#      dedups an exact-body re-run onto the existing record, handled or not.
#   3. Concurrent writers serialize on the sequence lock: no clobbered records.
#   4. The re-ring ladder: within grace is quiet, past grace rings, ring
#      spacing holds, a spent budget escalates exactly once, and an
#      acknowledgement resets the ladder for the next message. Its two other
#      stated bounds escalate too: a PROVEN composer block, which no number of
#      identical skips could ever deliver past, and the ABSOLUTE unhandled
#      bound, which holds even when nothing was ever due.
#   5. The acknowledgement-gated decision closure: a parked closure stays
#      uncommitted while its record is unread (so the decision keeps reading
#      open, which is the whole point), commits the moment the worker
#      acknowledges the record, and is then filed beside it. The sidecar
#      survives a sloppy glob sweep of the inbox root, a commit that partly
#      fails closes each key at most once when retried, the surfaced marker
#      names only the closures a pass actually failed on, a surfaced orphan
#      that could not be retired never hides a newer one, a captain-held task
#      settled through another channel counts as closed, and a hold-id
#      closure actually closes its captain-held task with the acknowledging
#      task's provenance when the real watcher commits it.
#   6. A real fm-watch.sh subprocess re-rings the doorbell for an unhandled
#      aged message on an idle pane WITHOUT waking firstmate, waits on a busy
#      pane, stays silent on a healthy/empty inbox, surfaces unwritable ladder
#      bookkeeping only while its record remains unhandled, emits exactly
#      one stale wake once the ring budget is spent, escalates an unread record
#      past the absolute bound even while the pane reads busy (saying so, so
#      recovery can tell busy-and-unread from stopped), names the decision an
#      undelivered answer is holding open, commits a deferred closure once the
#      worker acknowledges it, and surfaces a closure that cannot commit
#      exactly once instead of on every poll.
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
    FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_UNHANDLED_MAX_SECS=$FM_TEST_INBOX_BOUND_OFF \
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

# An age_path'd record is years old, so "the absolute bound is not what this
# case is about" has to mean a bound larger than that, not merely a large
# number. Kept as one named constant so no case can drift back under it.
FM_TEST_INBOX_BOUND_OFF=99999999999

# The ladder now has three bounds, and an age_path'd record is past ALL of
# them. A case about grace, spacing, or the attempt budget therefore has to say
# it is not the absolute-bound case, or `overdue` would answer first - which is
# exactly what the absolute bound is for. ladder() is that statement; the
# absolute-bound cases call fm_task_inbox_due_action directly.
ladder() {  # <state> [VAR=VALUE...] -- run due_action for t1
  local state=$1 kv
  shift
  (
    export FM_TASK_INBOX_UNHANDLED_MAX_SECS=$FM_TEST_INBOX_BOUND_OFF
    for kv in "$@"; do export "${kv?}"; done
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1
  )
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
  for i in 1 2 3 4 5 6; do
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer number $i" >/dev/null &
    pids+=($!)
  done
  for i in "${pids[@]}"; do
    wait "$i" || fail "a concurrent inbox write failed"
  done
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 6 ] || fail "6 concurrent writes should yield 6 records, got $count:"$'\n'"$(ls "$state/t1.inbox")"
  for i in 1 2 3 4 5 6; do
    grep -rqF "steer number $i" "$state/t1.inbox" \
      || fail "steer number $i was lost in the concurrent write race"
  done
  pass "inbox: concurrent writers serialize on the sequence lock and lose nothing"
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
  action=$(ladder "$state" FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0)
  [ "$action" = quiet ] || fail "a fire-and-forget record entered the re-ring ladder: $action"
  tracked=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "tracked steer")
  age_path "$tracked"
  action=$(ladder "$state" FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0)
  [ "$action" = "escalate 0 attempts $tracked" ] \
    || fail "a fire-and-forget record hid the later tracked steer: $action"
  [ -f "$fire" ] || fail "excluding fire-and-forget from escalation removed its durable record"
  pass "inbox: fire-and-forget records stay durable and outside the ladder"
}

test_ring_ladder_policy() {
  local state rec action
  state="$TMP_ROOT/ladder/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "do the thing")
  # Within grace: quiet.
  action=$(ladder "$state" FM_TASK_INBOX_GRACE_SECS=3600)
  [ "$action" = quiet ] || fail "a fresh unhandled message inside grace should be quiet, got: $action"
  # Past grace: one ring is due.
  age_path "$rec"
  action=$(ladder "$state" FM_TASK_INBOX_GRACE_SECS=60)
  [ "$action" = "ring $rec" ] || fail "an aged unhandled message should be due a ring, got: $action"
  # A just-recorded ring holds the spacing: quiet until another grace elapses.
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec"
  action=$(ladder "$state" FM_TASK_INBOX_GRACE_SECS=60)
  [ "$action" = quiet ] || fail "a ring within the spacing window should be quiet, got: $action"
  # Backdate the ladder: the next ring becomes due, and at the budget the
  # action turns into a single escalation. The 3-field write is the pre-blocked
  # -counter ladder shape, so this also pins that a ladder written by an older
  # build still reads as zero blocked skips instead of a bogus escalation.
  printf '001.msg\t1\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(ladder "$state" FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3)
  [ "$action" = "ring $rec" ] || fail "an aged ladder should ring again, got: $action"
  printf '001.msg\t3\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(ladder "$state" FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3)
  [ "$action" = "escalate 3 attempts $rec" ] || fail "a spent ring budget should escalate, got: $action"
  # Escalation fires at most once per message.
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec"
  action=$(ladder "$state" FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3)
  [ "$action" = quiet ] || fail "an escalated message should stay quiet for recovery, got: $action"
  # The acknowledgement resets the ladder: the next message starts fresh.
  mv "$rec" "$state/t1.inbox/handled/"
  action=$(ladder "$state" FM_TASK_INBOX_GRACE_SECS=60)
  [ "$action" = quiet ] || fail "a handled inbox should be quiet, got: $action"
  [ ! -e "$state/t1.inbox/.escalated" ] || fail "the ack should clear the escalation marker"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "next thing")
  age_path "$rec"
  action=$(ladder "$state" FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3)
  [ "$action" = "ring $rec" ] || fail "the next message should start a fresh ladder, got: $action"
  pass "inbox: the re-ring ladder paces by grace, escalates once, and resets on ack"
}

# A composer-protected skip cannot deliver anything, and the composer will not
# clear itself, so burning the rest of the attempt budget on identical skips
# only buys silence. The blocked counter is what turns that into a named
# escalation, and it must not be confused with an ordinary attempt.
test_ladder_escalates_a_proven_composer_block() {
  local state rec action
  state="$TMP_ROOT/ladder-blocked/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "clear the composer")
  age_path "$rec"
  # A ring that actually landed leaves the ladder ringing, budget permitting.
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" rang
  printf '001.msg\t1\t100\t0\n' > "$state/t1.inbox/.ring-state"
  action=$(ladder "$state" FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3)
  [ "$action" = "ring $rec" ] \
    || fail "a delivered ring inside the attempt budget should keep ringing, got: $action"
  # One PROVEN composer block escalates instead, without touching the budget.
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" blocked
  action=$(ladder "$state" FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3)
  case "$action" in
    "escalate "*" blocked $rec") : ;;
    *) fail "a proven composer block should escalate by name, got: $action" ;;
  esac
  pass "inbox: a proven composer block escalates instead of spending the budget on identical skips"
}

# The absolute bound is the one the 2026-08-27 incidents needed: an unread
# instruction must stop being silent at a stated time even when no delivery
# attempt was ever due, which is exactly what a permanently busy pane produces.
test_ladder_absolute_bound_escalates_with_nothing_else_due() {
  local state rec action
  state="$TMP_ROOT/ladder-overdue/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "hard stop")
  age_path "$rec"
  # Grace far beyond the record's age would leave the ladder quiet forever, and
  # the attempt budget is untouched: only the absolute bound can speak here.
  action=$(FM_TASK_INBOX_GRACE_SECS=$FM_TEST_INBOX_BOUND_OFF FM_TASK_INBOX_RING_MAX=99 \
    FM_TASK_INBOX_UNHANDLED_MAX_SECS=900 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate 0 overdue $rec" ] \
    || fail "an unhandled record past the absolute bound should escalate, got: $action"
  # Inside the bound, the same record with the same ladder stays quiet.
  action=$(FM_TASK_INBOX_GRACE_SECS=$FM_TEST_INBOX_BOUND_OFF FM_TASK_INBOX_RING_MAX=99 \
    FM_TASK_INBOX_UNHANDLED_MAX_SECS=$FM_TEST_INBOX_BOUND_OFF \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] \
    || fail "the absolute bound must be the only thing speaking here, got: $action"
  pass "inbox: the absolute unhandled bound escalates even when no attempt was ever due"
}

# --- acknowledgement-gated decision closure ---------------------------------

# The defect this gate exists for: fm-send's doorbell is deliberately skipped
# when the composer holds pending text, so "durably enqueued" is not "the worker
# knows". A closure written at enqueue time made every downstream reader report
# a stopped worker as a moving one. The closure must therefore sit uncommitted
# until the worker's own acknowledgement, and the decision must keep reading
# open until then.
test_deferred_closure_waits_for_the_acknowledgement() {
  local state rec sidecar closed
  state="$TMP_ROOT/defer/state"; mkdir -p "$state"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/t1.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go with REST")
  sidecar=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go with REST" "api-shape" "") \
    || fail "the closure could not be parked beside its record"
  [ -f "$sidecar" ] || fail "fm_task_inbox_defer_resolution printed a path that does not exist: $sidecar"

  # Unread: nothing commits, and the decision is still open in the status log.
  closed=$(inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status") \
    || fail "committing with nothing acknowledged should be a clean no-op"
  [ -z "$closed" ] || fail "an unread answer closed a decision: $closed"
  assert_no_grep 'resolved [key=api-shape]' "$state/t1.status" \
    "an undelivered answer must not read as resolved in the durable status log"
  [ -f "$sidecar" ] || fail "the parked closure disappeared while its record was unread"
  assert_contains "$(inbox_lib "$state" fm_task_inbox_pending_answer_keys "$state" t1)" \
    "api-shape" "an unread answer should be reportable as pending by key"

  # The worker acknowledges: the closure commits, exactly once, and is filed.
  mv "$rec" "$state/t1.inbox/handled/"
  closed=$(inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status") \
    || fail "the acknowledged closure failed to commit"
  [ "$closed" = "api-shape" ] || fail "the commit should report the closed key, got: $closed"
  assert_grep 'resolved [key=api-shape]: answered: go with REST' "$state/t1.status" \
    "the acknowledged answer should close the decision in the status log"
  [ ! -e "$sidecar" ] || fail "a committed closure was left in the inbox root"
  [ -f "$state/t1.inbox/handled/${sidecar##*/}" ] \
    || fail "a committed closure should be filed beside its acknowledged record"
  [ -z "$(inbox_lib "$state" fm_task_inbox_pending_answer_keys "$state" t1)" ] \
    || fail "a committed closure is no longer pending"

  # Re-running is a no-op: no second resolved line.
  inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null \
    || fail "a repeated commit should stay clean"
  [ "$(grep -cF 'resolved [key=api-shape]' "$state/t1.status")" = 1 ] \
    || fail "the commit is not idempotent:"$'\n'"$(cat "$state/t1.status")"
  pass "inbox: a parked closure commits only at the worker's acknowledgement, once"
}

# A record that is in BOTH places is mid-move, not acknowledged. Committing
# there would close a decision on the strength of a directory race.
test_deferred_closure_needs_a_complete_acknowledgement() {
  local state rec sidecar
  state="$TMP_ROOT/defer-race/state"; mkdir -p "$state"
  printf 'blocked [key=creds]: which account\n' > "$state/t1.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "use the shared one")
  sidecar=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "use the shared one" "creds" "")
  cp "$rec" "$state/t1.inbox/handled/"
  inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null \
    || fail "a half-moved record should be a clean no-op, not an error"
  assert_no_grep 'resolved [key=creds]' "$state/t1.status" \
    "a record still present in the inbox root is not an acknowledgement"
  [ -f "$sidecar" ] || fail "the closure should still be parked"
  pass "inbox: a record present in both places is not yet an acknowledgement"
}

# A closure naming nothing would close nothing; refusing to write it keeps a
# caller's bug loud instead of parking a sidecar that never resolves anything.
test_deferred_closure_refuses_an_empty_key_set() {
  local state rec
  state="$TMP_ROOT/defer-empty/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "just a steer")
  if inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "note" "" "" 2>/dev/null; then
    fail "a closure naming no decision should be refused"
  fi
  [ ! -e "$(inbox_lib "$state" fm_task_inbox_resolution_path "$rec")" ] \
    || fail "a refused closure still wrote a sidecar"
  pass "inbox: a closure that would close nothing is refused rather than parked"
}

# The brief says `mv NNN.msg handled/`, but a worker will sometimes sweep the
# whole inbox root instead. An uncommitted closure carried into handled/ by
# that sweep would never commit, and nothing would ever say why. The sidecar
# therefore lives outside the non-dot glob, and the sweep leaves it behind.
test_deferred_closure_survives_a_glob_sweep() {
  local state rec sidecar closed
  state="$TMP_ROOT/sweep/state"; mkdir -p "$state"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/t1.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go with REST")
  sidecar=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go with REST" "api-shape" "")
  case "${sidecar##*/}" in
    .*) ;;
    *) fail "the sidecar must be a dot file so a glob sweep cannot carry it away: $sidecar" ;;
  esac
  # The sloppy acknowledgement: everything the glob sees goes into handled/.
  mv "$state/t1.inbox"/* "$state/t1.inbox/handled/" 2>/dev/null || true
  [ -f "$state/t1.inbox/handled/${rec##*/}" ] || fail "the sweep should have acknowledged the record"
  [ -f "$sidecar" ] || fail "the sweep carried the uncommitted closure into handled/"
  closed=$(inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status") \
    || fail "the swept-and-acknowledged closure failed to commit"
  [ "$closed" = "api-shape" ] || fail "the commit should report the closed key, got: $closed"
  assert_grep 'resolved [key=api-shape]: answered: go with REST' "$state/t1.status" \
    "the acknowledged answer should close the decision after a glob sweep"
  [ ! -e "$sidecar" ] || fail "the committed closure was left in the inbox root"
  [ -f "$state/t1.inbox/handled/${sidecar##*/}" ] || fail "the committed closure should be filed"
  pass "inbox: a glob sweep of the inbox root leaves the parked closure in place to commit"
}

# A partial commit must be safe to retry: the status key closed on the first
# attempt, the captain-held close did not, and every later poll retries the
# same sidecar. Each key closes at most once, and once the failure has been
# surfaced the retry is quiet - no second error, no failed exit - so a
# permanently failing close can neither grow the status log nor wake firstmate
# on every poll. The hold id names no task in an isolated home, so the intake
# refuses it deterministically whether or not tasks-axi is installed.
test_commit_retries_close_each_key_once_and_surface_once() {
  local home state rec sidecar err rc
  home="$TMP_ROOT/partial"; state="$home/state"; mkdir -p "$state" "$home/data"
  err="$home/commit.err"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/t1.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go with REST")
  sidecar=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go with REST" "api-shape" "no-such-hold")
  mv "$rec" "$state/t1.inbox/handled/"

  rc=0
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a closure whose captain-held close failed should report the failure"
  assert_contains "$(cat "$err")" "captain-held tasks could not be closed" \
    "the failure should name what could not be closed"
  [ "$(grep -cF 'resolved [key=api-shape]' "$state/t1.status")" = 1 ] \
    || fail "the status key should have closed once on the first attempt"
  [ -f "$sidecar" ] || fail "an uncommittable closure must stay parked for the retry"

  rc=0
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "an unsurfaced failure should still report on the retry"
  [ "$(grep -cF 'resolved [key=api-shape]' "$state/t1.status")" = 1 ] \
    || fail "the retry appended the status key's closing line again:"$'\n'"$(cat "$state/t1.status")"

  # The caller surfaced the failure; from here the retry is quiet.
  inbox_lib "$state" fm_task_inbox_record_commit_escalated "$state" t1 \
    || fail "could not mark the failed closure as surfaced"
  rc=0
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] || fail "a surfaced failure must retry quietly instead of failing every poll"
  [ ! -s "$err" ] || fail "a surfaced failure must not repeat its diagnostic on every poll:"$'\n'"$(cat "$err")"
  [ "$(grep -cF 'resolved [key=api-shape]' "$state/t1.status")" = 1 ] \
    || fail "the quiet retry appended the status key's closing line again"
  [ -f "$sidecar" ] || fail "the quiet retry must keep the closure parked as evidence"
  pass "inbox: a partly failed commit closes each key once and is surfaced once"
}

# THE REGRESSION for the surfaced-marker overmark: the marker must name only
# the closures the commit pass actually failed on, never every closure that
# happens to be acknowledged by the time the caller writes it. A worker that
# acknowledges a second answer in the window between the pass returning and
# the marker write has not had that closure's first attempt yet; marking it
# surfaced then would retry it quietly forever, with no wake, if it then
# failed. Both hold ids name no task in an isolated home, so each commit
# refuses deterministically.
test_commit_escalation_marks_only_the_closures_that_failed() {
  local home state rec1 rec2 sidecar1 sidecar2 err rc marker
  home="$TMP_ROOT/overmark"; state="$home/state"; mkdir -p "$state" "$home/data"
  err="$home/commit.err"
  : > "$state/t1.status"
  rec1=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "first answer")
  sidecar1=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec1" "first answer" "" "no-such-hold-a")
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "second answer")
  sidecar2=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec2" "second answer" "" "no-such-hold-b")
  mv "$rec1" "$state/t1.inbox/handled/"

  rc=0
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "the first closure's failed hold close should report the failure"
  assert_contains "$(cat "$err")" "${rec1##*/}" "the first pass should name the first closure's record"

  # The window: the worker acknowledges the second answer AFTER the pass
  # returned and BEFORE the caller records what was surfaced.
  mv "$rec2" "$state/t1.inbox/handled/"
  inbox_lib "$state" fm_task_inbox_record_commit_escalated "$state" t1 \
    || fail "could not record the surfaced closure"
  marker="$state/t1.inbox/.commit-escalated"
  grep -Fxq -- "${sidecar1##*/}" "$marker" \
    || fail "the closure that failed should be marked as surfaced:"$'\n'"$(cat "$marker" 2>/dev/null)"
  if grep -Fxq -- "${sidecar2##*/}" "$marker"; then
    fail "a closure acknowledged after the pass was marked surfaced before its own first attempt:"$'\n'"$(cat "$marker")"
  fi

  # The second closure's first attempt is still loud; the first stays quiet.
  rc=0
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "the second closure's first failed attempt must still surface"
  assert_contains "$(cat "$err")" "${rec2##*/}" "the second pass should name the second closure's record"
  if grep -qF -- "${rec1##*/}" "$err"; then
    fail "an already surfaced closure repeated its diagnostic:"$'\n'"$(cat "$err")"
  fi
  inbox_lib "$state" fm_task_inbox_record_commit_escalated "$state" t1 \
    || fail "could not record the second surfaced closure"
  if ! grep -Fxq -- "${sidecar1##*/}" "$marker" || ! grep -Fxq -- "${sidecar2##*/}" "$marker"; then
    fail "both surfaced closures should now be marked:"$'\n'"$(cat "$marker")"
  fi
  rc=0
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] || fail "two surfaced failures must both retry quietly:"$'\n'"$(cat "$err")"
  [ ! -s "$err" ] || fail "a quiet retry repeated a diagnostic:"$'\n'"$(cat "$err")"
  pass "inbox: the surfaced-closure marker names only the closures the pass failed on"
}

# The filing step is the third place a commit can fail, and it is bounded the
# same way as the other two: an acknowledged closure whose status key closed
# but which cannot be filed under handled/ (the directory stopped being
# writable after the worker's ack) surfaces once, then retries quietly and
# files itself the moment the directory is writable again. Without the bound,
# a permanently unwritable handled/ re-woke firstmate and re-fed the
# captain-held tasks on every poll.
test_commit_files_quietly_when_handled_is_unwritable() {
  local home state rec sidecar err rc
  if [ "$(id -u)" = 0 ]; then
    pass "inbox: unwritable handled/ case skipped (root ignores directory permissions)"
    return 0
  fi
  home="$TMP_ROOT/unwritable-handled"; state="$home/state"; mkdir -p "$state" "$home/data"
  err="$home/commit.err"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/t1.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go with REST")
  sidecar=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go with REST" "api-shape" "")
  mv "$rec" "$state/t1.inbox/handled/"
  chmod a-w "$state/t1.inbox/handled"

  rc=0
  inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null 2>"$err" || rc=$?
  chmod u+w "$state/t1.inbox/handled" 2>/dev/null
  [ "$rc" -ne 0 ] || fail "a closure that closed its key but could not be filed should report the failure once"
  assert_contains "$(cat "$err")" "could not be filed" "the first failure should name the filing step"
  [ "$(grep -cF 'resolved [key=api-shape]' "$state/t1.status")" = 1 ] \
    || fail "the status key should have closed once before the filing failure"
  [ -f "$sidecar" ] || fail "an unfiled closure must stay parked for the retry"

  # The caller surfaced it; from here the retry is quiet even while handled/
  # stays unwritable.
  inbox_lib "$state" fm_task_inbox_record_commit_escalated "$state" t1 \
    || fail "could not mark the unfiled closure as surfaced"
  chmod a-w "$state/t1.inbox/handled"
  rc=0
  inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null 2>"$err" || rc=$?
  chmod u+w "$state/t1.inbox/handled" 2>/dev/null
  [ "$rc" -eq 0 ] || fail "a surfaced filing failure must retry quietly instead of failing every poll"
  [ ! -s "$err" ] || fail "a surfaced filing failure must not repeat its diagnostic on every poll:"$'\n'"$(cat "$err")"
  [ "$(grep -cF 'resolved [key=api-shape]' "$state/t1.status")" = 1 ] \
    || fail "the quiet retry appended the status key's closing line again"
  [ -f "$sidecar" ] || fail "the quiet retry must keep the unfiled closure parked as evidence"

  # Writable again: the quiet retry files it without closing anything twice.
  rc=0
  inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] || fail "filing should succeed once handled/ is writable again:"$'\n'"$(cat "$err")"
  [ ! -e "$sidecar" ] || fail "the closure was not filed once handled/ became writable"
  [ -f "$state/t1.inbox/handled/${sidecar##*/}" ] || fail "the filed closure should sit under handled/"
  [ "$(grep -cF 'resolved [key=api-shape]' "$state/t1.status")" = 1 ] \
    || fail "filing the closure re-closed its status key"
  pass "inbox: a closure that cannot be filed under handled/ surfaces once, retries quietly, then files"
}

# The .commit-failed handoff is what lets the caller mark a failed closure as
# surfaced. A handoff that could not be written while the inbox still existed
# used to be swallowed: the caller then found no names, marked nothing, and
# re-woke firstmate on every poll - the exact unbounded behaviour the marker
# exists to prevent. It is now the same distinct stop as any other unwritable
# marker (rc 2, named on stderr).
test_commit_surfaces_an_unwritable_failure_handoff() {
  local home state rec sidecar err rc
  home="$TMP_ROOT/handoff-unwritable"; state="$home/state"; mkdir -p "$state" "$home/data"
  err="$home/commit.err"
  : > "$state/t1.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "first answer")
  sidecar=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "first answer" "" "no-such-hold")
  mv "$rec" "$state/t1.inbox/handled/"
  # A directory squatting on the handoff path makes every write to it fail.
  mkdir "$state/t1.inbox/.commit-failed"

  rc=0
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null 2>"$err" || rc=$?
  [ "$rc" -eq 2 ] || fail "an unwritable failure handoff should return 2, got $rc:"$'\n'"$(cat "$err")"
  assert_contains "$(cat "$err")" ".commit-failed could not be written" \
    "the failure should name the handoff it could not write"
  [ -f "$sidecar" ] || fail "the closure must stay parked"
  pass "inbox: a failure handoff that cannot be written is a distinct failure, never a swallowed one"
}

# THE REGRESSION for a global-text dedupe: the idempotence check must be
# scoped to THIS sidecar's own identity, never to whether matching text
# already exists anywhere in the status log. A key legitimately reopened
# (needs-decision [key=K] again after an earlier resolved [key=K]) and
# answered a second time with IDENTICAL wording - routine for a short answer
# like "fix them all" repeated on a repeated step key - must still close on
# its own sidecar's commit. A dedupe keyed on "does this exact closing line
# already exist in the status log" cannot tell that apart from a retry of the
# SAME sidecar's own earlier append, and silently orphans the reopened
# decision forever.
test_reopened_key_with_identical_answer_closes_again() {
  local home state rec1 rec2 out
  home="$TMP_ROOT/reopened"; state="$home/state"; mkdir -p "$state" "$home/data"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/t1.status"
  rec1=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go with REST")
  inbox_lib "$state" fm_task_inbox_defer_resolution "$rec1" "go with REST" "api-shape" "" >/dev/null \
    || fail "could not park the first closure"
  mv "$rec1" "$state/t1.inbox/handled/"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null \
    || fail "the first closure should commit cleanly"
  [ "$(grep -cF 'resolved [key=api-shape]: answered: go with REST' "$state/t1.status")" = 1 ] \
    || fail "the first answer did not close:"$'\n'"$(cat "$state/t1.status")"

  # The decision is reopened under the same key and answered again, verbatim.
  printf 'needs-decision [key=api-shape]: confirm REST for the v2 endpoint too\n' >> "$state/t1.status"
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go with REST")
  inbox_lib "$state" fm_task_inbox_defer_resolution "$rec2" "go with REST" "api-shape" "" >/dev/null \
    || fail "could not park the reopened closure"
  mv "$rec2" "$state/t1.inbox/handled/"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status") \
    || fail "the reopened key's closure should commit cleanly too"
  assert_contains "$out" "api-shape" "the reopened key should report as closed"
  [ "$(grep -cF 'resolved [key=api-shape]: answered: go with REST' "$state/t1.status")" = 2 ] \
    || fail "a reopened key answered identically must close again, not be silently skipped as already-closed:"$'\n'"$(cat "$state/t1.status")"
  pass "inbox: a key reopened and answered identically closes again instead of reading as already-closed"
}

# The absolute-bound overdue timing must be independent of this ladder cause,
# whose header now states "~1 grace period plus one poll interval": confirms
# the blocked escalation fires on the poll immediately after the first
# composer-blocked skip, not after a second full grace period.
test_blocked_escalation_fires_one_poll_after_first_skip() {
  local state rec out
  state="$TMP_ROOT/blocked-timing/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "hello")
  FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_BLOCKED_MAX=1 \
    inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" blocked >/dev/null \
    || fail "could not record the composer-blocked skip"
  sleep 1.1
  out=$(FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_BLOCKED_MAX=1 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  case "$out" in
    "escalate "*" blocked "*) ;;
    *) fail "one skipped attempt past grace should already escalate as blocked, matching the corrected ~1 grace + 1 poll timing claim: $out" ;;
  esac
  pass "inbox: the blocked bound escalates on the very next poll after the first skipped attempt"
}

# THE REGRESSION for a worker that `rm`s its acknowledged record instead of
# moving it into handled/ (a contract violation, but not literally prevented):
# the sidecar is then bound to a record in neither the inbox root nor
# handled/, so the ladder's normal .msg-based scan can never see it and the
# closure would otherwise never commit and never escalate - a third silent
# failure state this whole change exists to eliminate.
test_orphaned_sidecar_escalates_instead_of_going_silent() {
  local home state rec out
  home="$TMP_ROOT/orphaned"; state="$home/state"; mkdir -p "$state" "$home/data"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/t1.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go with REST")
  inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go with REST" "api-shape" "" >/dev/null \
    || fail "could not park the closure"
  rm -f "$rec"

  out=$(inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  case "$out" in
    "escalate "*" orphaned "*) ;;
    *) fail "an orphaned sidecar (rm'd record, neither pending nor acknowledged) must escalate, not read as quiet: $out" ;;
  esac
  assert_not_contains "$(cat "$state/t1.status")" "resolved [key=api-shape]" \
    "an orphaned sidecar's answer must never silently commit on its own"

  # Escalates exactly once: the marker suppresses a repeat on the next poll,
  # and the surfaced orphan is retired out of the inbox root so it stops
  # reading as a pending answer for its keys.
  local orphan_path=${out##* } pending
  inbox_lib "$state" fm_task_inbox_record_orphan_escalated "$state" t1 "$orphan_path" \
    || fail "could not record the orphan escalation marker"
  out=$(inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$out" = quiet ] || fail "a surfaced orphan must not re-escalate on every poll: $out"
  [ ! -e "$orphan_path" ] || fail "a surfaced orphan was left in the inbox root, where it still reads as pending"
  [ -f "$state/t1.inbox/handled/orphaned/001.resolve" ] \
    || fail "a surfaced orphan should be set aside under handled/orphaned/:"$'\n'"$(ls -laR "$state/t1.inbox")"
  pending=$(inbox_lib "$state" fm_task_inbox_pending_answer_keys "$state" t1)
  [ -z "$pending" ] || fail "a retired orphan must not feed the pending-answer set: $pending"

  # Firstmate settles it by hand; the SAME key later reopens for real. That
  # fresh decision has no answer in flight, and the retired orphan must not
  # make it read as already answered, nor escalate again on its behalf.
  printf 'resolved [key=api-shape]: answered: go with REST (closed by hand)\n' >> "$state/t1.status"
  printf 'needs-decision [key=api-shape]: pick again for v2\n' >> "$state/t1.status"
  out=$(inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$out" = quiet ] || fail "a retired orphan re-escalated when its key was reopened afresh: $out"
  pending=$(inbox_lib "$state" fm_task_inbox_pending_answer_keys "$state" t1)
  [ -z "$pending" ] || fail "a reopened key was wrongly reported as already answered by a retired orphan: $pending"
  pass "inbox: an orphaned sidecar (record rm'd instead of moved) escalates once, is retired, and never shadows a reopened key"
}

# THE REGRESSION for a surfaced orphan that could not be retired: its marker
# is written first, and if the move into handled/orphaned/ then fails the
# sidecar stays in the inbox root. The scan must skip it by its marker, so it
# neither re-escalates nor hides a newer orphan behind it on every later poll.
test_surfaced_orphan_left_in_root_never_shadows_a_newer_orphan() {
  local home state rec1 rec2 sidecar1 sidecar2 out
  home="$TMP_ROOT/orphan-shadow"; state="$home/state"; mkdir -p "$state" "$home/data"
  printf 'needs-decision [key=first]: pick\nneeds-decision [key=second]: pick\n' > "$state/t1.status"
  rec1=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "answer one")
  sidecar1=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec1" "answer one" "first" "")
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "answer two")
  sidecar2=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec2" "answer two" "second" "")
  rm -f "$rec1"
  # Marker written, retirement failed: the surfaced orphan is still in the root.
  printf '%s\n' "${sidecar1##*/}" > "$state/t1.inbox/.orphan-escalated"
  out=$(inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$out" = quiet ] || fail "a surfaced orphan must not re-escalate while it waits for retirement: $out"

  rm -f "$rec2"
  out=$(inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$out" = "escalate 0 orphaned $sidecar2" ] \
    || fail "a newer orphan was hidden behind a surfaced one still in the root: $out"
  pass "inbox: a surfaced orphan that could not be retired never shadows a newer orphan"
}

# A captain-held task the sidecar answers, driven through the REAL watcher in
# the environment it runs under (an FM_HOME with its own backlog): the
# acknowledgement must close the task through the one keyed-answer intake,
# recording that the answer came from a firstmate answer this task
# acknowledged. Line format, provenance, and the watcher-side environment are
# all exercised here; a regression in any of them fails this case.
test_watcher_closes_the_captain_held_task_with_its_provenance() {
  local dir home state out log pid rec sidecar show i=0
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass "inbox: (skipped: tasks-axi not found) the watcher closes a captain-held task with provenance"
    return 0
  fi
  dir=$(setup_watch_case hold-close)
  home="$dir/home"; state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  make_hold_home "$home"
  (cd "$home" && tasks-axi add gated-work "Gated work" --kind ship --repo sample --body 'Gated work plan.' >/dev/null) \
    || fail "could not create the work item to hold"
  PATH="$home/holdbin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" hold gated-work --reason "captain go needed" >/dev/null \
    || fail "could not hold the work item for the captain"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go ahead")
  sidecar=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go ahead" "" "gated-work")
  # The worker has already acknowledged; the watcher's own poll commits.
  mv "$rec" "$state/t1.inbox/handled/"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config"
  pid=$!
  while [ "$i" -lt 100 ]; do
    [ -e "$sidecar" ] || break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -e "$sidecar" ] || fail "the watcher never committed the acknowledged hold closure:"$'\n'"$(cat "$out")"
  [ -f "$state/t1.inbox/handled/${sidecar##*/}" ] || fail "the committed closure should be filed"
  show=$(cd "$home" && tasks-axi show gated-work --full)
  assert_contains "$show" "state: done" "the acknowledged answer did not close the captain-held task"
  assert_contains "$show" "Resolution mode: answered" "the close did not record its path"
  assert_contains "$show" "Answer: go ahead" "the close did not record the answer the worker acknowledged"
  assert_contains "$show" "Captain answered this call through a firstmate answer acknowledged by t1." \
    "the close did not record the acknowledging task as its provenance"
  [ ! -s "$state/.wake-queue" ] || fail "a clean hold close must not wake firstmate:"$'\n'"$(cat "$state/.wake-queue")"
  pass "inbox: the watcher's commit closes the captain-held task with the acknowledging task's provenance"
}

# The captain can settle a held task through another channel - chat, a direct
# answer, or closing the backlog item - during the window before the worker
# acknowledges the delivered answer. That is a closed decision, not a failed
# commit: the closure files itself and nothing escalates.
test_commit_treats_a_hold_settled_elsewhere_as_closed() {
  local home state rec sidecar err rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass "inbox: (skipped: tasks-axi not found) a hold settled elsewhere counts as closed"
    return 0
  fi
  home="$TMP_ROOT/settled-elsewhere"; state="$home/state"; err="$home/commit.err"
  make_hold_home "$home"
  mkdir -p "$state"
  (cd "$home" && tasks-axi add gated-work "Gated work" --kind ship --repo sample --body 'Gated work plan.' >/dev/null) \
    || fail "could not create the work item to hold"
  PATH="$home/holdbin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" hold gated-work --reason "captain go needed" >/dev/null \
    || fail "could not hold the work item for the captain"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go ahead")
  sidecar=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go ahead" "" "gated-work")
  # The captain settles it directly while the answer is still unread.
  printf 'Captain said go in chat.\n' > "$home/direct.txt"
  PATH="$home/holdbin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" answer gated-work --decision-file "$home/direct.txt" >/dev/null \
    || fail "could not settle the held task directly"
  mv "$rec" "$state/t1.inbox/handled/"
  rc=0
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" t1 "$state/t1.status" >/dev/null 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] || fail "a hold already settled by the captain was reported as a failed close:"$'\n'"$(cat "$err")"
  [ ! -e "$sidecar" ] || fail "the closure for a settled hold should have been filed"
  [ -f "$state/t1.inbox/handled/${sidecar##*/}" ] || fail "the closure for a settled hold should be filed under handled/"
  pass "inbox: a captain-held task settled through another channel counts as closed, not failed"
}

# An isolated FM_HOME with its own tasks-axi backlog, so a captain-held task
# can be created and closed here without touching any real home; the tool
# stubs fm-captain-hold's hold path expects live beside it.
make_hold_home() {  # <home>
  local home=$1 fb
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fb="$home/holdbin"
  mkdir -p "$fb"
  fm_fake_exit0 "$fb" tmux treehouse no-mistakes gh gh-axi
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

# The absolute bound, end to end through a real watcher: a permanently busy
# pane must not be able to hold an unread instruction in silence. The doorbell
# is still never typed into a busy pane - that fail-safe is unchanged.
test_watcher_escalates_overdue_on_busy_pane() {
  local dir state out log pid rec
  dir=$(setup_watch_case busy-overdue)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  printf 'some output\nBUSYTOKEN active\n' > "$dir/busy.capture"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "unload the model now")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$dir/busy.capture" \
    FM_BUSY_REGEX=BUSYTOKEN FM_TASK_INBOX_RING_MAX=99 \
    FM_TASK_INBOX_UNHANDLED_MAX_SECS=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "a busy pane held an unread instruction past the absolute bound in silence"; }
  [ ! -s "$log" ] || fail "the doorbell must still never be typed into a busy pane:"$'\n'"$(cat "$log")"
  grep -qF 'unread firstmate instruction' "$state/.wake-queue" \
    || fail "the absolute bound should queue a stale wake:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF 'has been unhandled for over' "$state/.wake-queue" \
    || fail "the wake should name the absolute bound it crossed:"$'\n'"$(cat "$state/.wake-queue")"
  grep -qF 'while the pane reads busy' "$state/.wake-queue" \
    || fail "the wake should say the pane read busy, so recovery does not treat a long tool call as a stopped worker:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a busy pane no longer holds an unread instruction in silence forever"
}

# The same bound on an idle pane says so too: the verdict is what lets
# recovery triage the two shapes differently.
test_watcher_overdue_on_idle_pane_says_idle() {
  local dir state out log pid rec
  dir=$(setup_watch_case idle-overdue)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "unload the model now")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99 FM_TASK_INBOX_UNHANDLED_MAX_SECS=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "an idle pane held an unread instruction past the absolute bound in silence"; }
  grep -qF 'while the pane reads idle' "$state/.wake-queue" \
    || fail "the wake should say the pane read idle:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  pass "watcher: the absolute bound names an idle pane as idle"
}

# The reported incident, end to end: the composer holds pending text, so every
# doorbell is skipped, and the record carries an answered decision. The stale
# wake must name BOTH - the fixable condition and the decision it is holding
# open - because "unread firstmate instruction" alone cost a supervision turn
# to diagnose twice in one afternoon.
test_watcher_escalates_blocked_composer_and_names_the_decision() {
  local dir state out log pid rec
  dir=$(setup_watch_case blocked-composer)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n' > "$dir/pending.capture"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/t1.status"
  # The open decision is pre-existing history here, not a new event: prime its
  # seen marker so the watcher exits through the escalation under test rather
  # than through an unrelated signal wake for the fixture's own first line.
  prime_status_seen "$state" "$state/t1.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go with REST")
  inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go with REST" "api-shape" "" >/dev/null
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$dir/pending.capture" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "a permanently blocked composer never escalated"; }
  [ ! -s "$log" ] || fail "a visibly pending composer must not be rung:"$'\n'"$(cat "$log")"
  grep -qF 'composer visibly holds pending text' "$state/.wake-queue" \
    || fail "the wake should name the composer block and its remedy:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF 'api-shape' "$state/.wake-queue" \
    || fail "the wake should name the decision the unread answer is holding open:"$'\n'"$(cat "$state/.wake-queue")"
  assert_no_grep 'resolved [key=api-shape]' "$state/t1.status" \
    "an escalated, still-unread answer must not have closed its decision"
  pass "watcher: a blocked doorbell escalates by name and says which decision stays open"
}

# An orphaned sidecar through the real watcher: the wake names the violation
# and the orphan's own keys as something to settle by hand, and does NOT tell
# the reader to wait for an acknowledgement that can never come. The orphan is
# then set aside under handled/orphaned/ rather than left to read as pending.
test_watcher_escalates_an_orphan_for_hand_closure() {
  local dir state out log pid rec sidecar
  dir=$(setup_watch_case orphan)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/t1.status"
  prime_status_seen "$state" "$state/t1.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go with REST")
  sidecar=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go with REST" "api-shape" "")
  rm -f "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "an orphaned sidecar never escalated through the watcher"; }
  grep -qF 'steering-inbox contract violation' "$state/.wake-queue" \
    || fail "the wake should name the contract violation:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF 'decision key(s) api-shape' "$state/.wake-queue" \
    || fail "the wake should name the orphan's own decision key:"$'\n'"$(cat "$state/.wake-queue")"
  grep -qF 'closed by hand' "$state/.wake-queue" \
    || fail "the wake should say the closure must be settled by hand:"$'\n'"$(cat "$state/.wake-queue")"
  if grep -qF 'until the worker acknowledges' "$state/.wake-queue"; then
    fail "an orphan's wake must not tell the reader to wait for an acknowledgement that cannot come:"$'\n'"$(cat "$state/.wake-queue")"
  fi
  [ ! -e "$sidecar" ] || fail "the surfaced orphan was left in the inbox root"
  [ -f "$state/t1.inbox/handled/orphaned/${sidecar##*/.}" ] \
    || fail "the surfaced orphan should be set aside under handled/orphaned/:"$'\n'"$(ls -laR "$state/t1.inbox")"
  assert_no_grep 'resolved [key=api-shape]' "$state/t1.status" \
    "an orphaned answer must never close its decision on its own"
  pass "watcher: an orphaned closure is surfaced for hand closure by name, then set aside"
}

# The other half of the same contract: once the worker acknowledges, the real
# watcher is what turns the parked closure into the closing resolved line.
test_watcher_commits_the_closure_on_acknowledgement() {
  local dir state out log pid rec i=0
  dir=$(setup_watch_case commit-closure)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/t1.status"
  prime_status_seen "$state" "$state/t1.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go with REST")
  inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go with REST" "api-shape" "" >/dev/null
  age_path "$rec"
  # The doorbell stub acknowledges the record the moment it is rung.
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_ACK_RECORD="$rec" FM_TASK_INBOX_RING_MAX=99
  pid=$!
  while [ "$i" -lt 100 ]; do
    grep -qF 'resolved [key=api-shape]' "$state/t1.status" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  assert_grep 'resolved [key=api-shape]: answered: go with REST' "$state/t1.status" \
    "the watcher should close the decision once the worker acknowledged the answer"
  [ ! -e "$(inbox_lib "$state" fm_task_inbox_resolution_path "$rec")" ] \
    || fail "the committed closure was left parked in the inbox root"
  pass "watcher: the worker's acknowledgement is what commits the answered decision"
}

# A closure that cannot commit is surfaced exactly once. The first poll queues
# the stale wake; a fresh watcher over the same records must stay quiet, keep
# the status log at one closing line, and leave the closure parked as
# evidence. Without that bound a permanently failing close woke firstmate on
# every poll and appended the same resolved line each time.
# The watcher's side of an unwritable failure handoff: with nothing it can
# fold into the surfaced marker, it queues the stale wake and stops with an
# error, exactly as it does for any other unwritable marker, instead of
# exiting clean and re-queuing the same wake on every later poll.
test_watcher_stops_on_an_unwritable_failure_handoff() {
  local dir home state out log pid rec rc=0
  dir=$(setup_watch_case commit-handoff)
  home="$dir/home"; state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  mkdir -p "$home/data"
  : > "$state/t1.status"
  prime_status_seen "$state" "$state/t1.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go with REST")
  inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go with REST" "" "no-such-hold" >/dev/null
  mv "$rec" "$state/t1.inbox/handled/"
  mkdir "$state/t1.inbox/.commit-failed"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data"
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "a closure that cannot commit never surfaced"; }
  wait "$pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "the watcher exited clean with no way to mark the failed closure surfaced, so it would re-wake on every poll"
  [ "$(grep -cF 'answered decision could not be closed' "$state/.wake-queue")" = 1 ] \
    || fail "the failed commit should queue exactly one stale wake:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  [ ! -e "$state/t1.inbox/.commit-escalated" ] \
    || fail "nothing could have been marked surfaced:"$'\n'"$(cat "$state/t1.inbox/.commit-escalated")"
  pass "watcher: an unwritable failure handoff stops the watcher instead of re-waking on every poll"
}

test_watcher_surfaces_a_failed_closure_once() {
  local dir home state out log pid rec sidecar queue_after_ack
  dir=$(setup_watch_case commit-fail)
  home="$dir/home"; state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  mkdir -p "$home/data"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/t1.status"
  prime_status_seen "$state" "$state/t1.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "go with REST")
  sidecar=$(inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go with REST" "api-shape" "no-such-hold")
  mv "$rec" "$state/t1.inbox/handled/"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data"
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "a closure that cannot commit never surfaced"; }
  grep -qF 'answered decision could not be closed' "$state/.wake-queue" \
    || fail "the failed commit should queue a stale wake:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  [ "$(grep -cF 'resolved [key=api-shape]' "$state/t1.status")" = 1 ] \
    || fail "the status key should have closed exactly once:"$'\n'"$(cat "$state/t1.status")"
  [ -f "$sidecar" ] || fail "an uncommittable closure must stay parked"

  # The supervising turn presents and acknowledges that wake, exactly as it
  # would; the next cycle over the same records must then be quiet, and
  # nothing may grow.
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$dir/drain.err" || true
  ack_drain_err "$state" "$dir/drain.err" >/dev/null || fail "could not acknowledge the surfaced wake"
  queue_after_ack=$(cat "$state/.wake-queue" 2>/dev/null || true)
  : > "$out"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data"
  pid=$!
  if wait_watcher_gone "$pid" 40; then
    fail "a surfaced closure failure woke firstmate again on a later poll:"$'\n'"$(cat "$out")"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  fi
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ "$(cat "$state/.wake-queue" 2>/dev/null || true)" = "$queue_after_ack" ] \
    || fail "later polls queued another wake for the same failed closure:"$'\n'"$(cat "$state/.wake-queue")"
  [ "$(grep -cF 'resolved [key=api-shape]' "$state/t1.status")" = 1 ] \
    || fail "later polls appended the closing line again:"$'\n'"$(cat "$state/t1.status")"
  [ -f "$sidecar" ] || fail "the quiet retry must keep the closure parked as evidence"
  pass "watcher: a closure that cannot commit is surfaced once, then retried quietly"
}

test_write_is_durable_and_exact
test_idempotent_write_dedups_exact_body
test_idempotent_write_follows_concurrent_ack
test_handled_mv_dedups_by_sequence
test_concurrent_writers_never_clobber
test_ladder_writes_ignore_vanished_inbox
test_fire_and_forget_records_never_enter_the_ladder
test_ring_ladder_policy
test_ladder_escalates_a_proven_composer_block
test_ladder_absolute_bound_escalates_with_nothing_else_due
test_deferred_closure_waits_for_the_acknowledgement
test_deferred_closure_needs_a_complete_acknowledgement
test_deferred_closure_refuses_an_empty_key_set
test_deferred_closure_survives_a_glob_sweep
test_commit_retries_close_each_key_once_and_surface_once
test_commit_escalation_marks_only_the_closures_that_failed
test_commit_files_quietly_when_handled_is_unwritable
test_commit_surfaces_an_unwritable_failure_handoff
test_reopened_key_with_identical_answer_closes_again
test_blocked_escalation_fires_one_poll_after_first_skip
test_orphaned_sidecar_escalates_instead_of_going_silent
test_surfaced_orphan_left_in_root_never_shadows_a_newer_orphan
test_watcher_closes_the_captain_held_task_with_its_provenance
test_commit_treats_a_hold_settled_elsewhere_as_closed
test_watcher_rerings_idle_pane_quietly
test_watcher_waits_on_busy_pane
test_watcher_quiet_on_healthy_inbox
test_watcher_ack_silences_unwritable_ladder
test_watcher_surfaces_unwritable_ladder
test_watcher_escalates_once_after_budget
test_watcher_escalates_overdue_on_busy_pane
test_watcher_overdue_on_idle_pane_says_idle
test_watcher_escalates_blocked_composer_and_names_the_decision
test_watcher_escalates_an_orphan_for_hand_closure
test_watcher_commits_the_closure_on_acknowledgement
test_watcher_surfaces_a_failed_closure_once
test_watcher_stops_on_an_unwritable_failure_handoff
