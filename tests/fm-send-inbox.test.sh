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
#  10. An empty or whitespace-only text steer is refused before anything is
#      marked, recorded, or typed - on the marked secondmate path that means
#      no marker-only record and no pending-reply expectation.
#  11. The doorbell decision on a Herdr pane with no agent registration reads
#      the pane's processes: a live harness process is rung - including one
#      sitting under the pane shell behind a tool that holds the foreground
#      process group - a shell-only pane is still never typed into, and a
#      process view that cannot tell refuses with wording that says so; the
#      record is identical in every case.
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
make_stubs() { # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/tmux" <<'SH'
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
  list-windows) printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat >"$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_case() { # <name> [harness] -> echoes case dir with home/state + t1 meta
  local name=$1 harness=${2:-claude} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=$harness"
  printf '%s\n' "$dir"
}

run_send() { # <case-dir> <err-file> [env...] -- <fm-send args...>
  local dir=$1 err=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  : >"$dir/send.log"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    FM_SEND_SETTLE=0 ${envs[@]+"${envs[@]}"} \
    "$SEND" "$@" >/dev/null 2>"$err"
}

record_body() { # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$2"
}

test_text_steer_rides_inbox() {
  local dir err rc rec body typed
  dir=$(setup_case rides)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "please rebase onto main"
  rc=$?
  expect_code 0 "$rc" "an inbox-plane steer should exit 0 at enqueue"
  rec="$dir/home/state/t1.inbox/001.msg"
  [ -f "$rec" ] || fail "the steer was not durably recorded at $rec"
  body=$(record_body _ "$rec")
  [ "$body" = "please rebase onto main" ] || fail "the recorded body differs: $body"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "Firstmate instruction waiting: list '$dir/home/state/t1.inbox'/*.msg" \
    "the doorbell should direct the worker to drain the inbox"
  case "$typed" in
  *"please rebase onto main"*) fail "the payload must never be typed:"$'\n'"$typed" ;;
  esac
  pass "fm-send inbox: the payload is recorded durably and only the doorbell is typed"
}

test_multiline_steer_is_legal() {
  local dir err rc body
  dir=$(setup_case multiline)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 $'first line\nsecond line\nthird: with punctuation'
  rc=$?
  expect_code 0 "$rc" "a multi-line steer should succeed"
  body=$(record_body _ "$dir/home/state/t1.inbox/001.msg")
  [ "$body" = $'first line\nsecond line\nthird: with punctuation' ] ||
    fail "the multi-line body did not round-trip:"$'\n'"$body"
  case "$(cat "$dir/send.log")" in
  *"second line"*) fail "a payload line leaked onto the typed channel" ;;
  esac
  pass "fm-send inbox: newlines are legal and the terminal can no longer truncate a steer"
}

test_resend_enqueues_new_sequence() {
  local dir err doorbells typed
  dir=$(setup_case resend)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "first send failed"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "second send failed"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] && [ -f "$dir/home/state/t1.inbox/002.msg" ] ||
    fail "a re-send should enqueue a new sequence:"$'\n'"$(ls "$dir/home/state/t1.inbox")"
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
  dir=$(setup_case pendingskip)
  err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- t1 "steer past a stuck composer"
  rc=$?
  expect_code 0 "$rc" "a skipped ring is still a sent steer"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  [ ! -s "$dir/send.log" ] || fail "a visibly pending composer should skip the ring:"$'\n'"$(cat "$dir/send.log")"
  assert_contains "$(cat "$err")" "watcher will re-ring" \
    "the skip notice should point at the re-ring"
  pass "fm-send inbox: a visibly pending composer skips the ring, and the steer stays durably sent"
}

test_failed_ring_is_still_sent() {
  local dir err rc
  dir=$(setup_case ringfail)
  err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_SEND_FAIL=1 -- t1 "steer into a dead pane"
  rc=$?
  expect_code 0 "$rc" "a failed doorbell must not fail the send"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  assert_contains "$(cat "$err")" "watcher will re-ring" \
    "the failed-ring notice should point at the re-ring"
  pass "fm-send inbox: a failed doorbell is still a durably sent steer"
}

test_harness_invocations_stay_typed() {
  local dir err typed
  # A slash command must reach the harness's own parser, on any harness.
  dir=$(setup_case slash)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "/no-mistakes" || fail "a slash send should succeed"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "/no-mistakes" "the slash command should be typed literally"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a slash command must not be routed to the inbox"
  # A codex `$<skill>` invocation likewise stays typed.
  dir=$(setup_case codexskill codex)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 '$no-mistakes' || fail "a codex \$skill send should succeed"
  assert_contains "$(cat "$dir/send.log")" '$no-mistakes' "the codex \$skill should be typed literally"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a codex \$skill must not be routed to the inbox"
  # The same `$` message to a non-codex harness is plain text: inbox plane.
  dir=$(setup_case dollartext claude)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 '$5/month is cheap' || fail "a claude \$-text send should succeed"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "a non-codex \$-message should ride the inbox"
  case "$(cat "$dir/send.log")" in
  *'$5/month'*) fail "a non-codex \$-message payload was typed" ;;
  esac
  pass "fm-send planes: slash and codex \$skill invocations stay typed; plain \$-text rides the inbox"
}

test_explicit_target_stays_typed() {
  local dir err
  dir=$(setup_case explicit)
  err="$dir/send.err"
  run_send "$dir" "$err" -- sess:win "hello there" || fail "an explicit-target send should succeed"
  assert_contains "$(cat "$dir/send.log")" "hello there" \
    "an explicit backend target should receive the literal text"
  [ -z "$(find "$dir/home/state" -maxdepth 1 -name '*.inbox' -print 2>/dev/null)" ] ||
    fail "an explicit target has no task record here and must not grow an inbox"
  pass "fm-send planes: an explicit backend target keeps the typed plane"
}

test_key_path_never_touches_inbox() {
  local dir err
  dir=$(setup_case keypath)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 --key Enter || fail "a --key send should succeed"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "the --key path must never write an inbox record"
  pass "fm-send planes: the --key lifecycle path never touches the inbox"
}

test_secondmate_marker_and_enqueue_delivery() {
  local dir err body corr pr_rec delivered
  dir=$(setup_case secondmate)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  run_send "$dir" "$err" -- fm-domain "please summarize fleet health" ||
    fail "a secondmate steer should succeed"
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
  dir=$(setup_case bookkeeping-failure)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  cat >"$dir/fakebin/mv" <<'SH'
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

  run_send "$dir" "$err" FM_FAIL_DELIVERY_CONFIRM=1 -- domain "durable once"
  rc=$?
  # The durable record IS the delivery: even with the commit AND its recovery
  # marker both lost, the steer was delivered, so fm-send must not signal a
  # status that invites a resend (a nonzero would make automated callers
  # enqueue the same instruction again under a new sequence). The degradation
  # surfaces as its own distinct do-not-resend condition instead.
  expect_code 0 "$rc" "a delivered steer must not report a resend-inviting failure over lost bookkeeping"
  rec="$dir/home/state/domain.inbox/001.msg"
  [ -f "$rec" ] || fail "bookkeeping failure test did not durably enqueue the steer"
  [ "$(find "$dir/home/state/domain.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] ||
    fail "the delivered steer was duplicated:"$'\n'"$(ls "$dir/home/state/domain.inbox")"
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
  dir=$(setup_case meta-lock)
  err="$dir/send.err"
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
  [ -e "$marker" ] || {
    kill "$holder" 2>/dev/null
    fail "the metadata lock holder did not start"
  }
  run_send "$dir" "$err" FM_TASK_INBOX_LOCK_WAIT_SECS=0 -- t1 "must not hang"
  rc=$?
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  [ "$rc" -ne 0 ] || fail "metadata lock contention should fail after the bounded wait"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a lock refusal must not enqueue a record"
  assert_contains "$(cat "$err")" "metadata could not be locked" \
    "the bounded metadata lock refusal should be explicit"
  pass "fm-send inbox: metadata lock contention fails bounded without enqueue"
}

test_unwritable_inbox_fails_loudly() {
  local dir err rc
  dir=$(setup_case unwritable)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  : >"$dir/home/state/domain.inbox" # a FILE where the inbox dir must go
  run_send "$dir" "$err" -- fm-domain "this cannot be recorded"
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unwritable inbox must fail the send"
  assert_contains "$(cat "$err")" "inbox record could not be written" \
    "the failure should name the unwritable inbox"
  [ ! -s "$dir/send.log" ] || fail "a failed enqueue still typed something:"$'\n'"$(cat "$dir/send.log")"
  [ -z "$(find "$dir/home/state/pending-replies" -type f -not -name '.*' 2>/dev/null)" ] ||
    fail "a failed enqueue should discard the just-created pending-reply expectation"
  pass "fm-send inbox: an unwritable record is a loud local failure that leaves no false expectation"
}

test_empty_message_refused() {
  local dir err rc
  # The lived defect: an empty marked secondmate steer used to deliver a
  # marker+corr record with no body and mint a pending-reply expectation the
  # parent could never see resolved.
  dir=$(setup_case empty-marked)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  run_send "$dir" "$err" -- fm-domain
  rc=$?
  [ "$rc" -ne 0 ] || fail "an empty secondmate steer should refuse"
  assert_contains "$(cat "$err")" "nonempty message" \
    "the empty-message refusal should be explicit"
  [ ! -d "$dir/home/state/domain.inbox" ] || fail "an empty steer still wrote an inbox record"
  [ -z "$(find "$dir/home/state/pending-replies" -type f -not -name '.*' 2>/dev/null)" ] ||
    fail "an empty steer still minted a pending-reply expectation"
  [ ! -s "$dir/send.log" ] || fail "an empty steer still typed something:"$'\n'"$(cat "$dir/send.log")"

  # An explicit empty-string argument is the same refusal.
  dir=$(setup_case empty-string-arg)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 ""
  rc=$?
  [ "$rc" -ne 0 ] || fail "an explicit empty-string message should refuse"
  assert_contains "$(cat "$err")" "nonempty message" \
    "the empty-string refusal should be explicit"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "an empty-string steer still wrote an inbox record"

  # A whitespace-only message is equally contentless and refuses.
  dir=$(setup_case whitespace-only)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "   "
  rc=$?
  [ "$rc" -ne 0 ] || fail "a whitespace-only message should refuse"
  assert_contains "$(cat "$err")" "nonempty message" \
    "the whitespace-only refusal should be explicit"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a whitespace-only steer still wrote an inbox record"

  # The --key lifecycle path is unaffected: it takes no text at all.
  dir=$(setup_case keypath-after-refusal)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 --key Enter || fail "a --key send should still succeed"
  pass "fm-send: an empty or whitespace-only text steer refuses before marking, recording, or typing"
}

# A stateful fake herdr modeling one pane (session fmtest, pane w1:p2) whose
# agent registration is gone: `agent get` answers agent_not_found, as Herdr
# does when it loses a pane's binding. FM_FAKE_HERDR_PROC picks what the pane's
# own process view shows: agent (a Pi foreground process), shell (only the
# shell FM_FAKE_HERDR_SHELL_PID, a real process), other (a non-shell tool), or
# unreadable (process-info fails). Typed doorbell text is logged to
# FM_SEND_LOG.
setup_herdr_case() { # <name> -> echoes case dir with a herdr-backed t1 meta
  local dir
  dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  cat >"$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
sp=${FM_FAKE_HERDR_SHELL_PID:-4242}
case "${1:-} ${2:-}" in
  'status --json') printf '{"client":{"version":"0.9.1","protocol":22},"server":{"running":true}}\n' ;;
  'pane get') printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3" ;;
  'agent get') printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$3" ;;
  'pane process-info')
    case "${FM_FAKE_HERDR_PROC:?}" in
      agent) fg='{"pid":4243,"name":"node","argv0":"pi","argv":["pi"],"cmdline":"pi"}' ;;
      shell) fg="{\"pid\":$sp,\"name\":\"zsh\",\"argv0\":\"zsh\",\"argv\":[\"-zsh\"],\"cmdline\":\"-zsh\"}" ;;
      other) fg='{"pid":4250,"name":"less","argv0":"less","argv":["less"],"cmdline":"less"}' ;;
      *) exit 1 ;;
    esac
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_processes":[%s]}}}\n' "$sp" "$fg" ;;
  'pane read') printf 'output\n\n> \n' ;;
  'pane send-text') printf '%s\n' "$4" >>"$FM_SEND_LOG" ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/herdr"
  fm_write_meta "$dir/home/state/t1.meta" "window=fmtest:w1:p2" "backend=herdr" "kind=ship" "harness=pi"
  printf '%s\n' "$dir"
}

# Sends two steers to the herdr case and asserts the durable records are the
# ordinary ones - same schema, sequence, and exact bodies - whatever the
# doorbell decided. Leaves the second send's stderr in <dir>/send.err.
send_two_and_check_records() { # <dir> <proc> <shell-pid>
  local dir=$1 proc=$2 sp=$3 n body rc
  for n in 1 2; do
    run_send "$dir" "$dir/send.err" FM_FAKE_HERDR_PROC="$proc" FM_FAKE_HERDR_SHELL_PID="$sp" \
      FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 -- t1 "steer $n"$'\n'"second line"
    rc=$?
    expect_code 0 "$rc" "a durably recorded steer must exit 0 ($proc process view)"
    [ -f "$dir/home/state/t1.inbox/00$n.msg" ] || fail "steer $n was not recorded as 00$n.msg ($proc process view)"
    body=$(record_body _ "$dir/home/state/t1.inbox/00$n.msg")
    [ "$body" = "steer $n"$'\n'"second line" ] || fail "record 00$n.msg body changed ($proc process view): $body"
    [ "$(head -n 1 "$dir/home/state/t1.inbox/00$n.msg")" = schema=fm-task-inbox.v1 ] \
      || fail "record 00$n.msg lost its schema line ($proc process view)"
  done
}

test_herdr_lost_binding_live_agent_is_rung() {
  local dir typed
  dir=$(setup_herdr_case herdr-lost-binding-live)
  send_two_and_check_records "$dir" agent 4242
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "Firstmate instruction waiting: list '$dir/home/state/t1.inbox'/*.msg" \
    "a live Pi process with no Herdr registration must still be rung"
  assert_not_contains "$(cat "$dir/send.err")" "doorbell not typed" \
    "a live agent with a lost registration must not be reported as unreached"
  pass "fm-send inbox: a live agent whose Herdr registration is missing is rung"
}

test_herdr_lost_binding_foreground_tool_is_rung() {
  local dir sleep_bin shell_pid harness_pid waited typed
  dir=$(setup_herdr_case herdr-lost-binding-foreground-tool)
  # A real process tree standing in for the live worker: the pane shell with a
  # harness child, while the pane's foreground process group holds a tool the
  # worker is running (`less`), so only the descendant walk can see the harness.
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  bash -c 'exec -a pi "$1" 300 & printf "%s\n" "$!" >"$2"; exec "$1" 300' \
    _ "$sleep_bin" "$dir/harness.pid" &
  shell_pid=$!
  waited=0
  while [ ! -s "$dir/harness.pid" ]; do
    [ "$waited" -lt 100 ] || fail "the fake harness child never reported its pid"
    "$sleep_bin" 0.05
    waited=$((waited + 1))
  done
  harness_pid=$(cat "$dir/harness.pid")
  send_two_and_check_records "$dir" other "$shell_pid"
  kill "$harness_pid" "$shell_pid" 2>/dev/null || true
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "Firstmate instruction waiting: list '$dir/home/state/t1.inbox'/*.msg" \
    "a live harness under the pane shell must be rung even while a tool holds the foreground group"
  assert_not_contains "$(cat "$dir/send.err")" "doorbell not typed" \
    "a live worker running a tool must not be reported as unreached"
  pass "fm-send inbox: a live agent behind a foreground tool with a lost Herdr registration is rung"
}

test_herdr_exited_agent_is_not_typed() {
  local dir sleep_bin shell_pid err
  dir=$(setup_herdr_case herdr-lost-binding-exited)
  # A real, childless process stands in for the pane's shell, so the
  # descendant walk proves the pane shell-only against the real process table.
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  "$sleep_bin" 300 &
  shell_pid=$!
  send_two_and_check_records "$dir" shell "$shell_pid"
  kill "$shell_pid" 2>/dev/null || true
  [ ! -s "$dir/send.log" ] || fail "a shell-only pane was typed into:"$'\n'"$(cat "$dir/send.log")"
  err=$(cat "$dir/send.err")
  assert_contains "$err" "doorbell not typed because the agent in fmtest:w1:p2 has exited" \
    "an exited agent should keep the exited refusal"
  assert_contains "$err" "t1.inbox/002.msg" "the refusal should name the durable record"
  pass "fm-send inbox: an agent proven exited is still never typed into and keeps its durable record"
}

test_herdr_indeterminate_refuses_honestly() {
  local dir proc err
  for proc in unreadable other; do
    dir=$(setup_herdr_case "herdr-lost-binding-$proc")
    send_two_and_check_records "$dir" "$proc" 4242
    [ ! -s "$dir/send.log" ] || fail "an indeterminate ($proc) pane was typed into:"$'\n'"$(cat "$dir/send.log")"
    err=$(cat "$dir/send.err")
    assert_contains "$err" "could not tell whether the agent in fmtest:w1:p2 is still running" \
      "an indeterminate ($proc) refusal should say it could not tell"
    assert_not_contains "$err" "has exited" \
      "an indeterminate ($proc) refusal must not assert the agent exited"
    assert_contains "$err" "t1.inbox/002.msg" "the refusal should name the durable record"
  done
  pass "fm-send inbox: an indeterminate process view refuses without claiming the agent exited"
}

test_text_steer_rides_inbox
test_multiline_steer_is_legal
test_herdr_lost_binding_live_agent_is_rung
test_herdr_lost_binding_foreground_tool_is_rung
test_herdr_exited_agent_is_not_typed
test_herdr_indeterminate_refuses_honestly
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
test_empty_message_refused
