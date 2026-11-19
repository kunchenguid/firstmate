#!/usr/bin/env bash
# tests/fm-send-inbox.test.sh - fm-send's inbox data plane.
#
# An ordinary text steer to a task recorded in this home no longer types its
# payload: fm-send appends a durable sequenced record to state/<id>.inbox/ and
# rings one constant self-describing doorbell line, best-effort. These tests
# drive the real fm-send executable over a stubbed tmux and pin:
#   1. The payload is durably recorded and never typed; only the doorbell
#      crosses the terminal, and the send exits 0 at enqueue.
#      The doorbell names the inbox once and never grows with the home's depth.
#   2. Multi-line steers are legal and round-trip byte-exact.
#   3. A re-send enqueues a NEW sequence and still never retypes a payload,
#      so the terminal can never truncate, garble, or duplicate a steer.
#   4. The composer pre-check is advisory: visibly pending text skips the ring
#      with a notice, and the steer is still durably sent (exit 0).
#   5. A failed doorbell is still a sent steer (exit 0, record durable): the
#      watcher's re-ring ladder owns delivery from the record on. A
#      fire-and-forget record whose ring did not land is owed one retry ring.
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
#  11. A crewmate or scout whose newest lifecycle status is done or failed
#      takes no new work: text needs --after-done <reason>, while --key,
#      --resolve-key, a resumed task, and a second mate pass.
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
    if [ -n "${FM_FAKE_TMUX_PANE_CMD:-}" ]; then
      for a in "$@"; do case "$a" in *pane_current_command*) printf '%s\n' "$FM_FAKE_TMUX_PANE_CMD"; exit 0 ;; esac; done
    fi
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ "${FM_FAKE_TMUX_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) printf 'fm-t1\nwin\n'; exit 0 ;;
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
  assert_contains "$typed" "Firstmate instruction waiting: list \"\$FM_TASK_INBOX\"/*.msg in your 't1.inbox' steering inbox" \
    "the doorbell should direct the worker to drain the inbox"
  case "$typed" in
  *"please rebase onto main"*) fail "the payload must never be typed:"$'\n'"$typed" ;;
  esac
  pass "fm-send inbox: the payload is recorded durably and only the doorbell is typed"
}

# A home nested deep must not lengthen the doorbell: a long line wraps past
# what a composer read can prove, so a Herdr submit reports it never reached
# the pane and every re-ring fails the same way.
test_deep_home_doorbell_stays_short() {
  local shallow deep home err rest typed shallow_typed found
  shallow=$(setup_case shallow-home)
  run_send "$shallow" "$shallow/send.err" -- t1 "please continue" || fail "the shallow-home send failed"
  shallow_typed=$(cat "$shallow/send.log")
  deep="$TMP_ROOT/deep-home"
  home="$deep/one/two/three/four/five/six/seven/eight-secondmate-homes-nest-under-long-worktree-paths"
  mkdir -p "$home/state"
  make_stubs "$deep" >/dev/null
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  err="$deep/send.err"
  env PATH="$deep/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$deep/send.log" \
    FM_SEND_SETTLE=0 "$SEND" t1 "please continue" >/dev/null 2>"$err" ||
    fail "the deep-home send failed: $(cat "$err")"
  [ -f "$home/state/t1.inbox/001.msg" ] || fail "the deep-home steer was not durably recorded"
  typed=$(cat "$deep/send.log")
  [ "$typed" = "$shallow_typed" ] ||
    fail "the doorbell should not depend on the home's depth:"$'\n'"shallow: $shallow_typed"$'\n'"deep:    $typed"
  [ "${#typed}" -le 200 ] || fail "the doorbell should stay under 200 characters, got ${#typed}: $typed"
  case "$typed" in
  *"$deep"* | *"$TMP_ROOT"*) fail "the doorbell should not carry the home's absolute path: $typed" ;;
  esac
  rest=${typed#*t1.inbox}
  [ "$rest" != "$typed" ] || fail "the doorbell should name the inbox: $typed"
  case "$rest" in
  *t1.inbox*) fail "the doorbell should name the inbox once: $typed" ;;
  esac
  found=$(cd / && FM_TASK_INBOX="$home/state/t1.inbox" bash -c 'ls "$FM_TASK_INBOX"/*.msg') ||
    fail "a shell with FM_TASK_INBOX exported could not list the deep inbox"
  [ "$found" = "$home/state/t1.inbox/001.msg" ] ||
    fail "the doorbell's list instruction did not resolve the deep inbox from an unrelated cwd: $found"
  (cd / && FM_TASK_INBOX="$home/state/t1.inbox" bash -c 'mv "$FM_TASK_INBOX"/001.msg "$FM_TASK_INBOX"/handled/') ||
    fail "the doorbell's mv instruction did not acknowledge through FM_TASK_INBOX"
  [ -f "$home/state/t1.inbox/handled/001.msg" ] || fail "the acknowledged record did not land in handled/"
  pass "fm-send inbox: a deep home rings the same short doorbell naming the inbox once"
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

# Liveness before send: a crewmate whose endpoint has a bare shell (agent exited)
# or whose window is gone has nobody to read a record, so the send refuses with a
# clear message and queues nothing. A second mate, an explicit opt-in, and an
# endpoint whose liveness is merely unclear keep the durable record.
test_notice_flag_bundles_and_supersedes() {
  local dir err corr1 rec names pr1
  dir=$(setup_case notice-bundle)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  run_send "$dir" "$err" -- domain --notice restart-demo "restart notice one" ||
    fail "a notice steer should succeed"
  rec="$dir/home/state/domain.inbox/001.msg"
  [ -f "$rec" ] || fail "the first notice was not recorded"
  grep -q '^priority=notice$' "$rec" || fail "the first notice record lost priority=notice"
  grep -q '^notice-kind=restart-demo$' "$rec" || fail "the first notice record lost its kind"
  corr1=$(record_body _ "$rec" | grep -oE 'corr=[a-f0-9]{16}' | head -1 | cut -d= -f2)
  [ -f "$dir/home/state/pending-replies/$corr1" ] || fail "first notice minted no expectation"
  run_send "$dir" "$err" -- domain --notice restart-demo "restart notice two" ||
    fail "a second same-kind notice steer should succeed"
  rec="$dir/home/state/domain.inbox/002.msg"
  grep -q '^bundle=1$' "$rec" || fail "the second notice should carry bundle=1, got:"$'\n'"$(grep '^bundle=' "$rec" || true)"
  [ -f "$dir/home/state/domain.inbox/bundled/001.msg" ] \
    || fail "the collapsed notice should have moved to bundled/"
  names=$(find "$dir/home/state/domain.inbox" -maxdepth 1 -name '*.msg' | sed 's|.*/||' | tr '\n' ' ')
  [ "$names" = "002.msg " ] || fail "the root listing should hold only the bundle record, got: $names"
  pr1="$dir/home/state/pending-replies/$corr1"
  [ "$(grep '^phase=' "$pr1" | cut -d= -f2)" = resolved ] \
    || fail "the bundled record's expectation should resolve, got:"$'\n'"$(cat "$pr1")"
  grep -q '^resolved_via=helper$' "$pr1" \
    || fail "the supersession should record resolved_via=helper"
  grep -q '^superseded_by=002.msg$' "$pr1" \
    || fail "the supersession should name the bundle record that replaced it"
  assert_contains "$(cat "$err")" "bundled 1 earlier unhandled notice(s) into 002.msg" \
    "the operator should be told what the bundle collapsed"
  pass "fm-send inbox: --notice bundles same-kind notices and supersedes their expectations"
}

test_priority_flag_sets_the_reading_class() {
  local dir err rec
  dir=$(setup_case priority-flags)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 --priority captain "relay from the captain" ||
    fail "a captain-priority steer should succeed"
  rec="$dir/home/state/t1.inbox/001.msg"
  grep -q '^priority=captain$' "$rec" || fail "--priority captain lost its header"
  run_send "$dir" "$err" -- t1 "ordinary steer" ||
    fail "an ordinary steer should still succeed"
  rec="$dir/home/state/t1.inbox/002.msg"
  ! grep -q '^priority=' "$rec" || fail "a default steer must not grow a priority header"
  run_send "$dir" "$err" -- t1 --priority=main "explicit main" ||
    fail "an explicit --priority=main steer should succeed"
  rec="$dir/home/state/t1.inbox/003.msg"
  ! grep -q '^priority=' "$rec" || fail "--priority main must stay headerless like every legacy record"
  pass "fm-send inbox: --priority sets the reading class and defaults stay headerless"
}

test_priority_and_notice_refusals() {
  local dir err rc count args flag target text
  dir=$(setup_case flag-refusals)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  for args in "--priority bogus|t1|text" \
    "--priority notice|t1|text" \
    "--priority captain --priority main|t1|text" \
    "--notice=bad:kind|t1|text" \
    "--notice kind --priority notice|t1|text"; do
    IFS='|' read -r flag target text <<<"$args"
    # shellcheck disable=SC2086
    run_send "$dir" "$err" -- "$target" $flag "$text"
    rc=$?
    [ "$rc" -ne 0 ] || fail "refusal case '$flag' unexpectedly succeeded"
    count=$(find "$dir/home/state" -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" = 0 ] || fail "refusal case '$flag' left $count records behind"
  done
  run_send "$dir" "$err" -- domain --notice kindX --fire-and-forget 0123456789abcdef0123 "text"
  rc=$?
  [ "$rc" -ne 0 ] || fail "--notice with --fire-and-forget should refuse"
  run_send "$dir" "$err" -- domain --fire-and-forget deadbeefdeadbeef --notice kindY "text"
  rc=$?
  [ "$rc" -ne 0 ] || fail "--fire-and-forget with --notice should refuse"
  count=$(find "$dir/home/state" -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" = 0 ] || fail "refusals must leave the inbox untouched"
  pass "fm-send inbox: bad --priority/--notice combinations refuse before recording"
}

test_dead_or_missing_endpoint_refuses_the_steer() {
  local dir err rc
  dir=$(setup_case dead-endpoint)
  err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_PANE_CMD=bash -- t1 "steer into an exited agent"
  rc=$?
  expect_code 1 "$rc" "a steer to a crewmate whose agent exited must refuse"
  [ ! -e "$dir/home/state/t1.inbox/001.msg" ] || fail "a refused steer was still queued"
  [ ! -s "$dir/send.log" ] || fail "a refused steer rang the endpoint:"$'\n'"$(cat "$dir/send.log")"
  assert_contains "$(cat "$err")" "is dead" "the refusal should name the dead endpoint"
  assert_contains "$(cat "$err")" "nothing was queued" "the refusal should say nothing was queued"

  # The window is gone from the session: missing, refused the same way.
  dir=$(setup_case missing-endpoint)
  err="$dir/send.err"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-gone" "kind=ship" "harness=claude"
  run_send "$dir" "$err" -- t1 "steer into a torn-down window"
  rc=$?
  expect_code 1 "$rc" "a steer to a vanished endpoint must refuse"
  [ ! -e "$dir/home/state/t1.inbox/001.msg" ] || fail "a steer to a vanished endpoint was queued"
  assert_contains "$(cat "$err")" "is missing" "the refusal should name the missing endpoint"

  # A task already torn down (no meta) cannot resolve at all and queues nothing.
  dir=$(setup_case torn-down)
  err="$dir/send.err"
  rm -f "$dir/home/state/t1.meta"
  run_send "$dir" "$err" -- t1 "steer into a torn-down task"
  rc=$?
  [ "$rc" -ne 0 ] || fail "a steer to a torn-down task exited 0"
  [ ! -e "$dir/home/state/t1.inbox/001.msg" ] || fail "a steer to a torn-down task was queued"

  # The explicit opt-in records it for recovery, as before.
  dir=$(setup_case dead-optin)
  err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_PANE_CMD=bash FM_SEND_ALLOW_DEAD=1 -- t1 "record for recovery"
  rc=$?
  expect_code 0 "$rc" "FM_SEND_ALLOW_DEAD=1 keeps the record-for-recovery path"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the opted-in steer was not recorded"

  # A second mate keeps the recovery path with no opt-in.
  dir=$(setup_case dead-secondmate)
  err="$dir/send.err"
  rm -f "$dir/home/state/t1.meta"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-t1" alpha claude
  run_send "$dir" "$err" FM_FAKE_TMUX_PANE_CMD=bash -- fm-domain "request for a dead second mate"
  rc=$?
  expect_code 0 "$rc" "a second mate steer keeps the record-for-recovery path"
  pass "fm-send inbox: a dead or missing crewmate endpoint refuses the steer without queuing it, while opt-in and second mates keep the record"
}

# Contract: a fire-and-forget record stays outside the re-ring ladder, so a
# ring that did not land at enqueue is owed exactly one retry by the watcher.
test_fire_and_forget_unlanded_ring_owes_one_retry() {
  local dir err rc
  dir=$(setup_case faf-retry)
  mkdir -p "$dir/home/config"
  : > "$dir/home/config/wait-no-turns"
  err="$dir/send.err"
  # The stub lists only window fm-t1, so the secondmate takes it over.
  rm -f "$dir/home/state/t1.meta"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-t1" alpha claude
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- \
    fm-domain --fire-and-forget 0123456789abcdef "reconcile your books"; rc=$?
  expect_code 0 "$rc" "a skipped fire-and-forget ring is still a sent steer"
  [ "$(cat "$dir/home/state/domain.inbox/.retry-ring" 2>/dev/null)" = 001.msg ] \
    || fail "a skipped fire-and-forget ring did not owe its one retry"
  assert_contains "$(cat "$err")" "the watcher will ring it once more" \
    "the skip notice should promise exactly one retry"

  run_send "$dir" "$err" -- fm-domain --fire-and-forget 1123456789abcdef "reconcile again"; rc=$?
  expect_code 0 "$rc" "a rung fire-and-forget steer should succeed"
  [ "$(cat "$dir/home/state/domain.inbox/.retry-ring" 2>/dev/null)" = 001.msg ] \
    || fail "a ring that landed must not owe a retry for its own record"

  dir=$(setup_case ordinary-no-retry)
  err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- t1 "ordinary steer"
  [ ! -e "$dir/home/state/t1.inbox/.retry-ring" ] \
    || fail "an ordinary record rides the ladder and must not owe a separate retry"
  pass "fm-send inbox: a fire-and-forget ring that did not land owes one retry ring"
}

# Without the flag a skipped fire-and-forget ring is not owed a retry.
test_fire_and_forget_retry_stays_off_without_the_flag() {
  local dir err rc
  dir=$(setup_case faf-retry-off)
  err="$dir/send.err"
  [ ! -e "$dir/home/config/wait-no-turns" ]
  rm -f "$dir/home/state/t1.meta"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-t1" alpha claude
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- \
    fm-domain --fire-and-forget 0123456789abcdef "reconcile your books"; rc=$?
  expect_code 0 "$rc" "a skipped fire-and-forget ring is still a sent steer"
  [ ! -e "$dir/home/state/domain.inbox/.retry-ring" ] \
    || fail "an absent flag still owed a fire-and-forget retry"
  assert_contains "$(cat "$err")" "the watcher will re-ring" \
    "an absent flag should keep the ordinary re-ring notice"
  pass "fm-send inbox: without config/wait-no-turns a fire-and-forget ring is not retried"
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

# One task, one worker: a finished crewmate or scout takes no new work unless
# the send names why it still belongs to that task; second mates are exempt.
test_finished_worker_takes_no_new_work() {
  local dir err rc
  dir=$(setup_case finished)
  err="$dir/send.err"
  printf 'working [at=1]: building\ndone [at=2]: PR https://example.invalid/pr/1\nresolved [key=x] [at=3]: answered\n' > "$dir/home/state/t1.status"
  run_send "$dir" "$err" -- t1 "now also implement the follow-up"
  rc=$?
  [ "$rc" -ne 0 ] || fail "new work to a finished worker should refuse"
  assert_contains "$(cat "$err")" "a finished worker takes no new work" "the refusal should name the rule"
  assert_contains "$(cat "$err")" "--after-done <conclude|promote|board|recover>" "the refusal should name the legitimate escape"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a refused steer still wrote an inbox record"
  run_send "$dir" "$err" -- t1 --after-done conclude "wrap up and stop" || fail "a conclude message to a finished worker should send"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the conclude message was not recorded"
  run_send "$dir" "$err" -- t1 --after-done more-work "x"
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown --after-done reason should refuse"
  run_send "$dir" "$err" -- t1 --key Enter || fail "a --key send is not new work"
  printf 'working [at=4]: resumed\n' >> "$dir/home/state/t1.status"
  run_send "$dir" "$err" -- t1 "a steer within the running task" || fail "a working task still takes steers"
  dir=$(setup_case finished-secondmate)
  err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  printf 'done [at=2]: idle\n' > "$dir/home/state/domain.status"
  run_send "$dir" "$err" -- fm-domain "new domain work" || fail "a persistent second mate is exempt: $(cat "$err")"
  pass "fm-send: a finished crewmate takes no new work; conclude/promote/board/recover and second mates pass"
}

test_text_steer_rides_inbox
test_deep_home_doorbell_stays_short
test_multiline_steer_is_legal
test_resend_enqueues_new_sequence
test_pending_composer_skips_ring_advisorily
test_failed_ring_is_still_sent
test_fire_and_forget_unlanded_ring_owes_one_retry
test_fire_and_forget_retry_stays_off_without_the_flag
test_harness_invocations_stay_typed
test_explicit_target_stays_typed
test_key_path_never_touches_inbox
test_secondmate_marker_and_enqueue_delivery
test_post_enqueue_bookkeeping_failure_is_not_retryable
test_meta_lock_contention_fails_bounded
test_unwritable_inbox_fails_loudly
test_empty_message_refused
test_finished_worker_takes_no_new_work
test_notice_flag_bundles_and_supersedes
test_priority_flag_sets_the_reading_class
test_priority_and_notice_refusals
test_dead_or_missing_endpoint_refuses_the_steer
