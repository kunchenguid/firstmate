#!/usr/bin/env bash
# tests/fm-send-inbox.test.sh - fm-send's inbox data plane.
#
# An ordinary text steer to a task recorded in this home no longer types its
# payload: fm-send appends a durable sequenced record to state/<id>.inbox/ and
# rings one constant self-describing doorbell line, best-effort. These tests
# drive the real fm-send executable over a stubbed tmux and pin:
#   1. The payload is durably recorded and never typed; only the doorbell
#      crosses the terminal, and the send exits 0 at enqueue.
#   2. Multi-line steers are legal and round-trip byte-exact.
#   3. A re-send enqueues a NEW sequence and still never retypes a payload,
#      so the terminal can never truncate, garble, or duplicate a steer.
#   4. The composer pre-check is advisory: visibly pending text skips the ring
#      with a notice, and the steer is still durably sent (exit 0).
#   5. A failed doorbell is still a sent steer (exit 0, record durable): the
#      watcher's re-ring ladder owns delivery from the record on.
#   6. Carve-outs keep the typed plane: a leading "/" (any harness), a leading
#      "$" to codex, an explicit backend target, and the --key path.
#   7. A marked secondmate steer carries its marker + corr token in the record
#      body, and the pending-reply expectation is marked delivered at enqueue.
#   8. Pending-reply bookkeeping failure after enqueue never reports a
#      retryable send failure that could duplicate the durable instruction.
#   9. An unwritable inbox is a real local failure: nonzero exit, nothing
#      typed, and a just-created pending-reply expectation is discarded.
#  10. A metadata lock stranded by a dead holder, or by a holder whose pid a
#      later unrelated process now owns, is reclaimed with a stderr notice
#      instead of refusing the send.
#  11. --coalesce replaces still-unhandled copies of a periodic tick (same key
#      or same body) instead of queueing them, keeps handled records and other
#      steers, and is refused where there is no local inbox to coalesce.
#  12. Replacing the oldest unhandled tick keeps the watcher's re-ring ladder:
#      the replacement inherits its age, ring count, and escalation, so a
#      worker that never drains its ticks still surfaces as stale exactly once.
#  13. Parallel sends from many processes all land as distinct intact records:
#      concurrent steers never collapse, overwrite, or drop one another.
#  14. A send whose record cannot be confirmed on disk fails loudly with the
#      path, and leaves no false pending-reply expectation behind.
# Every case below that passes a literal `$...` message quotes it on purpose
# (the point is sending an unexpanded `$` line), so SC2016 is disabled.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-inbox)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub tmux: logs literal typed text to FM_SEND_LOG and lets the submit and
# composer paths reach clean verdicts. FM_FAKE_TMUX_COMPOSER=pending renders a
# composer visibly holding text; FM_FAKE_TMUX_SEND_FAIL=1 fails send-keys.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
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
      printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ "${FM_FAKE_TMUX_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_case() {  # <name> [harness] -> echoes case dir with home/state + t1 meta
  local name=$1 harness=${2:-claude} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=$harness"
  printf '%s\n' "$dir"
}

run_send() {  # <case-dir> <err-file> [env...] -- <fm-send args...>
  local dir=$1 err=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  : > "$dir/send.log"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    FM_SEND_SETTLE=0 ${envs[@]+"${envs[@]}"} \
    "$SEND" "$@" >/dev/null 2>"$err"
}

record_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$2"
}

test_text_steer_rides_inbox() {
  local dir err rc rec body typed
  dir=$(setup_case rides); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "please rebase onto main"; rc=$?
  expect_code 0 "$rc" "an inbox-plane steer should exit 0 at enqueue"
  rec="$dir/home/state/t1.inbox/001.msg"
  [ -f "$rec" ] || fail "the steer was not durably recorded at $rec"
  body=$(record_body _ "$rec")
  [ "$body" = "please rebase onto main" ] || fail "the recorded body differs: $body"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "Firstmate instruction waiting: list $dir/home/state/t1.inbox/*.msg" \
    "the doorbell should direct the worker to drain the inbox"
  case "$typed" in
    *"please rebase onto main"*) fail "the payload must never be typed:"$'\n'"$typed" ;;
  esac
  pass "fm-send inbox: the payload is recorded durably and only the doorbell is typed"
}

test_multiline_steer_is_legal() {
  local dir err rc body
  dir=$(setup_case multiline); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 $'first line\nsecond line\nthird: with punctuation'; rc=$?
  expect_code 0 "$rc" "a multi-line steer should succeed"
  body=$(record_body _ "$dir/home/state/t1.inbox/001.msg")
  [ "$body" = $'first line\nsecond line\nthird: with punctuation' ] \
    || fail "the multi-line body did not round-trip:"$'\n'"$body"
  case "$(cat "$dir/send.log")" in
    *"second line"*) fail "a payload line leaked onto the typed channel" ;;
  esac
  pass "fm-send inbox: newlines are legal and the terminal can no longer truncate a steer"
}

test_resend_enqueues_new_sequence() {
  local dir err doorbells typed
  dir=$(setup_case resend); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "first send failed"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "second send failed"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] && [ -f "$dir/home/state/t1.inbox/002.msg" ] \
    || fail "a re-send should enqueue a new sequence:"$'\n'"$(ls "$dir/home/state/t1.inbox")"
  doorbells=$(grep -cF 'Firstmate instruction waiting' "$dir/send.log" || true)
  [ "$doorbells" = 1 ] || fail "each send rings once (the log is truncated per send), got $doorbells"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "numeric order" \
    "a newer record's doorbell should preserve inbox sequence ordering"
  case "$typed" in
    *"check the CI result"*) fail "a re-send typed the payload" ;;
  esac
  pass "fm-send inbox: a re-send is a new durable record, never a retyped payload"
}

test_pending_composer_skips_ring_advisorily() {
  local dir err rc
  dir=$(setup_case pendingskip); err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- t1 "steer past a stuck composer"; rc=$?
  expect_code 0 "$rc" "a skipped ring is still a sent steer"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  [ ! -s "$dir/send.log" ] || fail "a visibly pending composer should skip the ring:"$'\n'"$(cat "$dir/send.log")"
  assert_contains "$(cat "$err")" "watcher will re-ring" \
    "the skip notice should point at the re-ring"
  pass "fm-send inbox: a visibly pending composer skips the ring, and the steer stays durably sent"
}

test_failed_ring_is_still_sent() {
  local dir err rc
  dir=$(setup_case ringfail); err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_SEND_FAIL=1 -- t1 "steer into a dead pane"; rc=$?
  expect_code 0 "$rc" "a failed doorbell must not fail the send"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  assert_contains "$(cat "$err")" "watcher will re-ring" \
    "the failed-ring notice should point at the re-ring"
  pass "fm-send inbox: a failed doorbell is still a durably sent steer"
}

test_harness_invocations_stay_typed() {
  local dir err typed
  # A slash command must reach the harness's own parser, on any harness.
  dir=$(setup_case slash); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "/no-mistakes" || fail "a slash send should succeed"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "/no-mistakes" "the slash command should be typed literally"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a slash command must not be routed to the inbox"
  # A codex `$<skill>` invocation likewise stays typed.
  dir=$(setup_case codexskill codex); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 '$no-mistakes' || fail "a codex \$skill send should succeed"
  assert_contains "$(cat "$dir/send.log")" '$no-mistakes' "the codex \$skill should be typed literally"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a codex \$skill must not be routed to the inbox"
  # The same `$` message to a non-codex harness is plain text: inbox plane.
  dir=$(setup_case dollartext claude); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 '$5/month is cheap' || fail "a claude \$-text send should succeed"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "a non-codex \$-message should ride the inbox"
  case "$(cat "$dir/send.log")" in
    *'$5/month'*) fail "a non-codex \$-message payload was typed" ;;
  esac
  pass "fm-send planes: slash and codex \$skill invocations stay typed; plain \$-text rides the inbox"
}

test_explicit_target_stays_typed() {
  local dir err
  dir=$(setup_case explicit); err="$dir/send.err"
  run_send "$dir" "$err" -- sess:win "hello there" || fail "an explicit-target send should succeed"
  assert_contains "$(cat "$dir/send.log")" "hello there" \
    "an explicit backend target should receive the literal text"
  [ -z "$(find "$dir/home/state" -maxdepth 1 -name '*.inbox' -print 2>/dev/null)" ] \
    || fail "an explicit target has no task record here and must not grow an inbox"
  pass "fm-send planes: an explicit backend target keeps the typed plane"
}

test_key_path_never_touches_inbox() {
  local dir err
  dir=$(setup_case keypath); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 --key Enter || fail "a --key send should succeed"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "the --key path must never write an inbox record"
  pass "fm-send planes: the --key lifecycle path never touches the inbox"
}

test_secondmate_marker_and_enqueue_delivery() {
  local dir err body corr pr_rec delivered
  dir=$(setup_case secondmate); err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  run_send "$dir" "$err" -- fm-domain "please summarize fleet health" \
    || fail "a secondmate steer should succeed"
  body=$(record_body _ "$dir/home/state/domain.inbox/001.msg")
  case "$body" in
    "$FM_FROMFIRST_MARK"corr=*) : ;;
    *) fail "the recorded body lost the from-firstmate marker/corr framing:"$'\n'"$body" ;;
  esac
  corr=$(printf '%s' "$body" | grep -oE 'corr=[a-f0-9]{16}' | head -1 | cut -d= -f2)
  [ -n "$corr" ] || fail "no corr token in the recorded body"
  pr_rec="$dir/home/state/pending-replies/$corr"
  [ -f "$pr_rec" ] || fail "no pending-reply expectation was recorded at $pr_rec"
  delivered=$(grep '^delivered_epoch=' "$pr_rec" | cut -d= -f2)
  [ -n "$delivered" ] || fail "enqueue IS delivery: delivered_epoch should be set at enqueue time:"$'\n'"$(cat "$pr_rec")"
  case "$(cat "$dir/send.log")" in
    *"summarize fleet health"*) fail "the marked payload was typed" ;;
  esac
  pass "fm-send inbox: a secondmate steer records marker+corr in the body and is delivered at enqueue"
}

test_post_enqueue_bookkeeping_failure_is_not_retryable() {
  local dir err rc rec body
  dir=$(setup_case bookkeeping-failure); err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
source_arg=${@: -2:1}
target_arg=${@: -1}
if [ "${FM_FAIL_DELIVERY_CONFIRM:-0}" = 1 ] \
  && grep -q '^confirmed=' "$source_arg" 2>/dev/null; then
  # Simulate losing both the delivery commit and its prepared recovery marker.
  rm -f "$target_arg"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$dir/fakebin/mv"

  run_send "$dir" "$err" FM_FAIL_DELIVERY_CONFIRM=1 -- domain "durable once"; rc=$?
  # The durable record IS the delivery: even with the commit AND its recovery
  # marker both lost, the steer was delivered, so fm-send must not signal a
  # status that invites a resend (a nonzero would make automated callers
  # enqueue the same instruction again under a new sequence). The degradation
  # surfaces as its own distinct do-not-resend condition instead.
  expect_code 0 "$rc" "a delivered steer must not report a resend-inviting failure over lost bookkeeping"
  rec="$dir/home/state/domain.inbox/001.msg"
  [ -f "$rec" ] || fail "bookkeeping failure test did not durably enqueue the steer"
  [ "$(find "$dir/home/state/domain.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the delivered steer was duplicated:"$'\n'"$(ls "$dir/home/state/domain.inbox")"
  body=$(record_body _ "$rec")
  case "$body" in
    "$FM_FROMFIRST_MARK"corr=*) : ;;
    *) fail "bookkeeping failure test lost the secondmate marker: $body" ;;
  esac
  assert_contains "$(cat "$err")" "reply-tracking-degraded" \
    "lost bookkeeping should surface as its own distinct degraded condition"
  assert_contains "$(cat "$err")" "do not resend" \
    "the degraded condition should give explicit do-not-resend guidance"
  assert_contains "$(cat "$err")" "durably recorded at" \
    "the degraded condition should name the already-delivered record"
  pass "fm-send inbox: lost reply bookkeeping never invites a resend, and the delivered steer is never duplicated"
}

test_meta_lock_contention_fails_bounded() {
  local dir err rc holder marker lock i
  dir=$(setup_case meta-lock); err="$dir/send.err"
  marker="$dir/meta-lock-held"
  lock="$dir/home/state/.meta-t1.lock"
  bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    touch "$3"
    sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$marker" &
  holder=$!
  i=0
  while [ ! -e "$marker" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$marker" ] || { kill "$holder" 2>/dev/null; fail "the metadata lock holder did not start"; }
  run_send "$dir" "$err" FM_TASK_INBOX_LOCK_WAIT_SECS=0 -- t1 "must not hang"; rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  [ "$rc" -ne 0 ] || fail "metadata lock contention should fail after the bounded wait"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a lock refusal must not enqueue a record"
  assert_contains "$(cat "$err")" "metadata could not be locked" \
    "the bounded metadata lock refusal should be explicit"
  pass "fm-send inbox: metadata lock contention fails bounded without enqueue"
}

test_unwritable_inbox_fails_loudly() {
  local dir err rc
  dir=$(setup_case unwritable); err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  : > "$dir/home/state/domain.inbox"   # a FILE where the inbox dir must go
  run_send "$dir" "$err" -- fm-domain "this cannot be recorded"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unwritable inbox must fail the send"
  assert_contains "$(cat "$err")" "inbox record could not be written" \
    "the failure should name the unwritable inbox"
  [ ! -s "$dir/send.log" ] || fail "a failed enqueue still typed something:"$'\n'"$(cat "$dir/send.log")"
  [ -z "$(find "$dir/home/state/pending-replies" -type f -not -name '.*' 2>/dev/null)" ] \
    || fail "a failed enqueue should discard the just-created pending-reply expectation"
  pass "fm-send inbox: an unwritable record is a loud local failure that leaves no false expectation"
}

# A stranded metadata lock: the owner record names a dead pid, or a live pid
# whose process started after the record was written (pid reuse).
strand_meta_lock() {  # <lock> <pid> [record-mtime]
  local lock=$1 pid=$2 when=${3:-} owner
  owner=$(mktemp -d "$lock.owner.XXXXXX")
  printf '%s\n' "$pid" > "$owner/pid"
  [ -z "$when" ] || touch -t "$when" "$owner/pid" "$owner"
  ln -s "$owner" "$lock"
}

test_stranded_meta_lock_is_reclaimed() {
  local dir err rc lock dead reuser
  dir=$(setup_case stranded-dead); err="$dir/send.err"
  lock="$dir/home/state/.meta-t1.lock"
  sh -c 'exit 0' & dead=$!; wait "$dead"
  strand_meta_lock "$lock" "$dead"
  run_send "$dir" "$err" FM_TASK_INBOX_LOCK_WAIT_SECS=0 -- t1 "after a dead holder"; rc=$?
  expect_code 0 "$rc" "a dead holder's metadata lock should be reclaimed, not refuse the send"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the reclaimed send did not record its steer"
  assert_contains "$(cat "$err")" "reclaimed stale lock" "a reclaim should leave a stderr notice"

  dir=$(setup_case stranded-reused); err="$dir/send.err"
  lock="$dir/home/state/.meta-t1.lock"
  sleep 30 & reuser=$!
  # Record written in 2020: the live pid cannot be its holder.
  strand_meta_lock "$lock" "$reuser" 202001010000
  run_send "$dir" "$err" FM_TASK_INBOX_LOCK_WAIT_SECS=0 -- t1 "after a recycled pid"; rc=$?
  kill "$reuser" 2>/dev/null; wait "$reuser" 2>/dev/null
  expect_code 0 "$rc" "a lock whose pid now names a younger unrelated process should be reaped"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the reaped send did not record its steer"
  assert_contains "$(cat "$err")" "reason=reused" "the reap notice should name pid reuse"
  pass "fm-send inbox: a metadata lock stranded by a dead or recycled holder pid is reclaimed with a notice"
}

test_coalesce_replaces_unhandled_ticks() {
  local dir err rc inbox tick count body
  dir=$(setup_case coalesce); err="$dir/send.err"
  inbox="$dir/home/state/t1.inbox"
  tick="Scheduled tick: run one cycle"
  # Two copies queued before the sender marked its ticks, one handled copy,
  # and an unrelated steer between them.
  run_send "$dir" "$err" -- t1 "$tick" || fail "fixture tick 1 failed"
  run_send "$dir" "$err" -- t1 "a real instruction" || fail "fixture steer failed"
  run_send "$dir" "$err" -- t1 "$tick" || fail "fixture tick 2 failed"
  run_send "$dir" "$err" -- t1 "$tick" || fail "fixture tick 3 failed"
  mv "$inbox/001.msg" "$inbox/handled/"
  run_send "$dir" "$err" -- t1 --coalesce tick "$tick"; rc=$?
  expect_code 0 "$rc" "a coalescing tick should send"
  assert_contains "$(cat "$err")" "coalesced 2 superseded" "the coalesce should report what it replaced"
  [ -f "$inbox/005.msg" ] || fail "the coalescing tick should take a fresh sequence:"$'\n'"$(ls "$inbox")"
  [ ! -e "$inbox/003.msg" ] && [ ! -e "$inbox/004.msg" ] \
    || fail "unhandled identical ticks were not replaced:"$'\n'"$(ls "$inbox")"
  [ -f "$inbox/002.msg" ] || fail "an unrelated steer must survive coalescing"
  [ -f "$inbox/handled/001.msg" ] || fail "a handled record must never be touched"
  # A later tick with the same key but new wording still replaces the marked one.
  run_send "$dir" "$err" -- t1 --coalesce tick "Scheduled tick v2"; rc=$?
  expect_code 0 "$rc" "a second coalescing tick should send"
  [ ! -e "$inbox/005.msg" ] || fail "a same-key record was not replaced"
  count=$(find "$inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "expected the steer plus one tick, found $count:"$'\n'"$(ls "$inbox")"
  body=$(record_body _ "$inbox/006.msg")
  [ "$body" = "Scheduled tick v2" ] || fail "the surviving tick body differs: $body"
  pass "fm-send inbox: --coalesce replaces unhandled same-key or same-body ticks instead of queueing them"
}

inbox_ladder() {  # <fn> <args...>
  env FM_TASK_INBOX_GRACE_SECS=90 FM_TASK_INBOX_RING_MAX=3 \
    bash -c '. "$1"; . "$2"; shift 2; "$@"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

test_coalesce_keeps_reringing_ladder() {
  local dir err state inbox action
  dir=$(setup_case coalesce-ladder); err="$dir/send.err"
  state="$dir/home/state"; inbox="$state/t1.inbox"
  run_send "$dir" "$err" -- t1 --coalesce tick "tick" || fail "first coalescing tick failed"
  touch -t 202001010000 "$inbox/001.msg"
  # The watcher spent the whole ring budget on the first, never-drained tick.
  inbox_ladder fm_task_inbox_record_ring "$state" t1 "$inbox/001.msg"
  inbox_ladder fm_task_inbox_record_ring "$state" t1 "$inbox/001.msg"
  inbox_ladder fm_task_inbox_record_ring "$state" t1 "$inbox/001.msg"
  run_send "$dir" "$err" -- t1 --coalesce tick "tick" || fail "second coalescing tick failed"
  [ ! -e "$inbox/001.msg" ] && [ -f "$inbox/002.msg" ] \
    || fail "the second tick should replace the first:"$'\n'"$(ls "$inbox")"
  action=$(inbox_ladder fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $inbox/002.msg 3" ] \
    || fail "a replaced tick restarted the re-ring ladder instead of escalating: $action"
  inbox_ladder fm_task_inbox_record_escalated "$state" t1 "$inbox/002.msg" \
    || fail "recording the escalation failed"
  run_send "$dir" "$err" -- t1 --coalesce tick "tick" || fail "third coalescing tick failed"
  [ -f "$inbox/003.msg" ] || fail "the third tick should replace the second:"$'\n'"$(ls "$inbox")"
  action=$(inbox_ladder fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "an already-escalated stuck worker was escalated again: $action"
  pass "fm-send inbox: a coalesced replacement keeps the oldest tick's age, ring count, and escalation"
}

# Several senders steer one task at the same moment (firstmate plus lead workers
# on the same host). Every instruction must survive as its own record.
# An idempotent steer that dedups onto a record the worker already acknowledged
# was delivered and acted on: there is nothing left to announce, so the send must
# succeed without typing a doorbell that asks the worker to acknowledge it again.
test_already_acknowledged_steer_is_not_rung_again() {
  local dir err rc inbox
  dir=$(setup_case already-acked); err="$dir/send.err"
  inbox="$dir/home/state/t1.inbox"
  run_send "$dir" "$err" FM_SEND_IDEMPOTENT=1 -- t1 "steer that was already handled"; rc=$?
  expect_code 0 "$rc" "the first idempotent steer should send"
  [ -f "$inbox/001.msg" ] || fail "the first steer was not recorded"
  mv "$inbox/001.msg" "$inbox/handled/"
  : > "$dir/send.log"
  run_send "$dir" "$err" FM_SEND_IDEMPOTENT=1 -- t1 "steer that was already handled"; rc=$?
  expect_code 0 "$rc" "a dedup onto an acknowledged record is still a delivered steer"
  [ -z "$(ls "$inbox"/*.msg 2>/dev/null)" ] \
    || fail "the dedup wrote a new record instead of landing on the acknowledged one"
  [ ! -s "$dir/send.log" ] \
    || fail "an already-acknowledged steer was rung again:"$'\n'"$(cat "$dir/send.log")"
  assert_contains "$(cat "$err")" "already delivered and acknowledged" \
    "the send should say the steer was already handled"
  pass "fm-send inbox: an already-acknowledged steer is never rung again"
}

test_parallel_sends_never_lose_a_record() {
  local dir err i pids=() rc=0 inbox count
  dir=$(setup_case parallel); err="$dir/send.err"
  inbox="$dir/home/state/t1.inbox"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    run_send "$dir" "$err.$i" -- t1 "parallel steer $i keep-me" &
    pids+=($!)
  done
  for i in "${pids[@]}"; do
    wait "$i" || rc=$((rc + 1))
  done
  [ "$rc" = 0 ] || fail "$rc parallel sends failed"
  count=$(find "$inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 12 ] || fail "12 parallel sends should yield 12 records, got $count:"$'\n'"$(ls "$inbox")"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    grep -rqF "parallel steer $i keep-me" "$inbox" \
      || fail "parallel steer $i was lost"
  done
  pass "fm-send inbox: parallel sends all land as distinct intact records"
}

# The record is the delivery: a send whose record vanishes between the enqueue
# and the send's own confirmation - a replaced, retired, or reaped inbox - must
# refuse, never report a durable steer that is not there. The record is
# published for real (so the enqueue and its own verification succeed) and is
# then removed while the send releases its task metadata lock, the last moment
# before the send confirms the record itself.
test_unconfirmed_record_fails_the_send() {
  local dir err rc real_rm
  dir=$(setup_case unconfirmed); err="$dir/send.err"
  real_rm=$(command -v rm)
  cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  case "$a" in
    *"$FM_UNCONFIRMED_LOCK"*/role) "$FM_REAL_RM" -f "$FM_UNCONFIRMED_RECORD" 2>/dev/null || true ;;
  esac
done
exec "$FM_REAL_RM" "$@"
SH
  chmod +x "$dir/fakebin/rm"
  run_send "$dir" "$err" \
    FM_REAL_RM="$real_rm" FM_UNCONFIRMED_LOCK='.meta-t1.lock' \
    FM_UNCONFIRMED_RECORD="$dir/home/state/t1.inbox/001.msg" \
    -- t1 "steer that vanishes before the confirmation"; rc=$?
  [ "$rc" -ne 0 ] || fail "a send whose record vanished under it reported success"
  assert_contains "$(cat "$err")" "steer not sent to t1" \
    "the refusal should say the steer was not sent"
  assert_contains "$(cat "$err")" "is not on disk carrying the instructed text" \
    "the refusal should name the missing record rather than report delivery"
  assert_contains "$(cat "$err")" "$dir/home/state/t1.inbox" \
    "the refusal should name the inbox whose record could not be confirmed"
  [ ! -e "$dir/home/state/t1.inbox/001.msg" ] || fail "the fixture did not remove the record"
  [ ! -s "$dir/send.log" ] || fail "a refused send still typed something:"$'\n'"$(cat "$dir/send.log")"
  [ -z "$(find "$dir/home/state/pending-replies" -type f -not -name '.*' 2>/dev/null)" ] \
    || fail "an unconfirmed record should discard the just-created pending-reply expectation"
  pass "fm-send inbox: an unconfirmable record fails the send instead of reporting delivery"
}

test_coalesce_refusals() {
  local dir err rc
  dir=$(setup_case coalesce-refuse); err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  run_send "$dir" "$err" -- t1 --coalesce 'bad key' "tick"; rc=$?
  [ "$rc" -ne 0 ] || fail "an invalid coalesce key should be refused"
  run_send "$dir" "$err" -- t1 --coalesce tick "/compact"; rc=$?
  [ "$rc" -ne 0 ] || fail "coalescing typed-plane text should be refused"
  run_send "$dir" "$err" -- fm-domain --coalesce tick "tick"; rc=$?
  [ "$rc" -ne 0 ] || fail "coalescing to a secondmate should be refused"
  assert_contains "$(cat "$err")" "--coalesce refused" "the refusal should be explicit"
  run_send "$dir" "$err" -- sess:fm-t1 --coalesce tick "tick"; rc=$?
  [ "$rc" -ne 0 ] || fail "coalescing to an explicit backend target should be refused"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a refused coalesce must not enqueue anything"
  [ ! -s "$dir/send.log" ] || fail "a refused coalesce typed something"
  pass "fm-send inbox: --coalesce is refused where no local task inbox can coalesce"
}

# A PR-event producer such as the pr-flow job delivers an informational event
# (a QA finding, NO-GO, or conflict) to the crew that owns the pull request at
# the moment it appears. It must reach that crew's durable record without ever
# climbing the inbox re-ring ladder into a firstmate escalation, which is what
# the explicit fire-and-forget delivery mode is for.
test_crewmate_fire_and_forget_records_and_dedups() {
  local dir err rc inbox delivery rec body action
  dir=$(setup_case fire-and-forget); err="$dir/send.err"
  inbox="$dir/home/state/t1.inbox"
  delivery=9f2c1a4b7d3e5061
  run_send "$dir" "$err" -- t1 --fire-and-forget "$delivery" \
    'pr-flow: https://github.com/Muso-AI/H-DevOps/pull/1 has a qa-review finding: no test covers the retry'; rc=$?
  expect_code 0 "$rc" "a fired delivery to an ordinary crew should enqueue"
  rec="$inbox/001.msg"
  [ -f "$rec" ] || fail "the fired delivery was not recorded at $rec"
  [ "$(find "$inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the fired delivery enqueued more than one record:"$'\n'"$(ls "$inbox")"
  body=$(record_body _ "$rec")
  [ "$body" = 'pr-flow: https://github.com/Muso-AI/H-DevOps/pull/1 has a qa-review finding: no test covers the retry' ] \
    || fail "the recorded body differs: $body"
  case "$body" in
    *corr=*) fail "a crewmate fired delivery must not carry a reply expectation: $body" ;;
  esac
  inbox_ladder fm_task_inbox_is_fire_and_forget "$rec" \
    || fail "the record does not carry the fire-and-forget delivery mode, so the watcher would escalate it"
  action=$(inbox_ladder fm_task_inbox_due_action "$dir/home/state" t1)
  [ "$action" = quiet ] || fail "a fired delivery entered the re-ring ladder: $action"
  assert_contains "$(cat "$dir/send.log")" "Firstmate instruction waiting" \
    "a fired delivery should still ring its doorbell once"
  # The producer owns once-ness per event, so a blind retry after an uncertain
  # outcome must land on the record already present instead of queueing a
  # second copy the crew would act on twice.
  run_send "$dir" "$err" -- t1 --fire-and-forget "$delivery" \
    'pr-flow: https://github.com/Muso-AI/H-DevOps/pull/1 has a qa-review finding: no test covers the retry'; rc=$?
  expect_code 0 "$rc" "a retried fired delivery should succeed"
  [ "$(find "$inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the same fired delivery was recorded twice:"$'\n'"$(ls "$inbox")"
  # Ordinary steers are untouched: the same bytes without the flag are a
  # deliberate new instruction.
  run_send "$dir" "$err" -- t1 'pr-flow: https://github.com/Muso-AI/H-DevOps/pull/1 has a qa-review finding: no test covers the retry' \
    || fail "an ordinary steer after a fired delivery should succeed"
  [ "$(find "$inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 2 ] \
    || fail "an ordinary steer was collapsed onto the fired record:"$'\n'"$(ls "$inbox")"
  pass "fm-send inbox: an explicit fire-and-forget delivery to a crew is durable, off the re-run ladder, and idempotent"
}

test_fire_and_forget_requires_a_home_task() {
  local dir err rc
  dir=$(setup_case fire-and-forget-refuse); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 --fire-and-forget XYZ 'event'; rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed fire-and-forget delivery id should be refused"
  assert_contains "$(cat "$err")" "16 lowercase hex" "the refusal should name the delivery-id format"
  run_send "$dir" "$err" -- sess:fm-t1 --fire-and-forget 0123456789abcdef 'event'; rc=$?
  [ "$rc" -ne 0 ] || fail "fire-and-forget to an explicit backend target should be refused"
  assert_contains "$(cat "$err")" "requires a recorded task selector" \
    "the refusal should name the missing task record"
  [ ! -d "$dir/home/state/t1.inbox" ] \
    || fail "a refused fire-and-forget must not enqueue anything"
  [ ! -s "$dir/send.log" ] || fail "a refused fire-and-forget typed something"
  pass "fm-send inbox: --fire-and-forget needs a recorded task and a well-formed delivery id"
}

test_text_steer_rides_inbox
test_multiline_steer_is_legal
test_resend_enqueues_new_sequence
test_pending_composer_skips_ring_advisorily
test_failed_ring_is_still_sent
test_harness_invocations_stay_typed
test_explicit_target_stays_typed
test_key_path_never_touches_inbox
test_secondmate_marker_and_enqueue_delivery
test_post_enqueue_bookkeeping_failure_is_not_retryable
test_meta_lock_contention_fails_bounded
test_unwritable_inbox_fails_loudly
test_parallel_sends_never_lose_a_record
test_unconfirmed_record_fails_the_send
test_already_acknowledged_steer_is_not_rung_again
test_stranded_meta_lock_is_reclaimed
test_coalesce_replaces_unhandled_ticks
test_coalesce_keeps_reringing_ladder
test_coalesce_refusals
test_crewmate_fire_and_forget_records_and_dedups
test_fire_and_forget_requires_a_home_task
