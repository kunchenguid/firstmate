#!/usr/bin/env bash
# tests/fm-send-inbox.test.sh - fm-send's inbox data plane.
#
# An ordinary text steer to a task recorded in this home no longer types its
# payload: fm-send appends a durable sequenced record to state/<id>.inbox/ and
# rings one constant self-describing doorbell line, best-effort. These tests
# drive the real fm-send executable over a stubbed Herdr CLI and pin:
#   1. The payload is durably recorded and never typed; only the doorbell
#      crosses the terminal, and the send exits 0 at enqueue.
#   2. Multi-line steers are legal and round-trip byte-exact.
#   3. A re-send enqueues a NEW sequence and still never retypes a payload,
#      so the terminal can never truncate, garble, or duplicate a steer.
#   4. Composer rendering is not read before native prompt submission.
#   5. A failed doorbell is still a sent steer (exit 0, record durable): the
#      watcher's re-ring ladder owns delivery from the record on.
#   6. Carve-outs use direct native prompts: a leading "/" (any harness), a
#      leading "$" to codex, and an explicit backend target; --key remains a
#      separate literal-key path.
#   7. An unwritable inbox is a real local failure: nonzero exit and nothing
#      typed.
#   8. An empty or whitespace-only text steer is refused before anything is
#      recorded or typed.
# Every case below that passes a literal `$...` message quotes it on purpose
# (the point is sending an unexpanded `$` line), so SC2016 is disabled.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-inbox)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub Herdr CLI: logs literal typed text to FM_SEND_LOG and lets the submit and
# composer paths reach clean verdicts. FM_FAKE_HERDR_COMPOSER=pending renders a
# composer visibly holding text; FM_FAKE_HERDR_SEND_FAIL=1 fails pane sends.
make_stubs() { # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  fm_test_fake_herdr_send "$fb"
  cat >"$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_case() { # <name> [harness] -> echoes case dir with home/state + t1 meta
  local name=$1 harness=${2:-pi} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:w1:p-t1" "backend=herdr" "kind=ship" "harness=$harness"
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

test_pending_composer_does_not_gate_native_prompt() {
  local dir err rc
  dir=$(setup_case pendingskip)
  err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_HERDR_COMPOSER=pending -- t1 "steer past a stuck composer"
  rc=$?
  expect_code 0 "$rc" "composer rendering must not gate a native prompt"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  assert_contains "$(cat "$dir/send.log")" 'Firstmate instruction waiting' \
    "the native prompt should be submitted without a composer read"
  assert_not_contains "$(cat "$err")" 'composer' \
    "composer-independent submission must not report a composer gate"
  pass "fm-send inbox: composer rendering does not gate native prompt submission"
}

test_failed_ring_is_still_sent() {
  local dir err rc
  dir=$(setup_case ringfail)
  err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_HERDR_SEND_FAIL=1 -- t1 "steer into a dead pane"
  rc=$?
  expect_code 0 "$rc" "a failed doorbell must not fail the send"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  assert_contains "$(cat "$err")" "watcher will re-ring" \
    "the failed-ring notice should point at the re-ring"
  pass "fm-send inbox: a failed doorbell is still a durably sent steer"
}

test_uncertain_ring_persists_recovery_before_suppression() {
  local dir err rc record
  dir=$(setup_case uncertain-marker-failure)
  err="$dir/send.err"
  mkdir -p "$dir/home/state/t1.inbox/.escalated"
  run_send "$dir" "$err" FM_FAKE_HERDR_TIMEOUT=1 -- t1 "retain the uncertain steer"
  rc=$?
  expect_code 0 "$rc" "an uncertain doorbell must keep the durable enqueue contract"
  record="$dir/home/state/t1.inbox/001.msg"
  [ -f "$record" ] || fail "the uncertain steer lost its durable inbox record"
  grep -F "$record" "$dir/home/state/.wake-queue" >/dev/null \
    || fail "marker failure occurred before the uncertainty wake was durable"
  assert_contains "$(cat "$err")" 'uncertainty wake was queued' \
    "marker failure did not report the durable recovery path"

  dir=$(setup_case uncertain-wake-failure)
  err="$dir/send.err"
  mkdir "$dir/home/state/.wake-queue"
  run_send "$dir" "$err" FM_FAKE_HERDR_TIMEOUT=1 -- t1 "retain after wake failure"
  rc=$?
  expect_code 0 "$rc" "a wake persistence failure must not revoke the durable steer"
  record="$dir/home/state/t1.inbox/001.msg"
  [ -f "$record" ] || fail "wake persistence failure lost the durable inbox record"
  [ ! -e "$dir/home/state/t1.inbox/.escalated" ] \
    || fail "wake persistence failure suppressed recovery before a wake existed"
  assert_contains "$(cat "$err")" 'uncertainty wake could not be queued' \
    "wake persistence failure was not reported"
  pass "fm-send uncertainty keeps recovery durable before suppressing replay"
}

test_transcript_variants_are_never_opened_by_send() {
  local variant dir err rc marker transcript body
  for variant in missing unreadable huge malformed; do
    dir=$(setup_case "no-transcript-read-$variant" codex)
    err="$dir/send.err"
    marker="$dir/python-called"
    transcript="$dir/vendor.jsonl"
    printf 'busy_gen=g1\n' >> "$dir/home/state/t1.meta"
    case "$variant" in
      missing) : ;;
      unreadable) mkdir "$transcript" ;;
      huge) truncate -s 67108864 "$transcript" ;;
      malformed) printf '{not json}\n' > "$transcript" ;;
    esac
    printf '{"version":1,"gen":"g1","harness":"codex","cwd":"%s","sessions":"%s","backend":"herdr","target":"sess:w1:p-t1","bound":{"path":"%s"}}\n' \
      "$dir" "$dir" "$transcript" > "$dir/home/state/t1.busy-session"
    cat > "$dir/fakebin/python3" <<SH
#!/usr/bin/env bash
touch '$marker'
exit 97
SH
    chmod +x "$dir/fakebin/python3"
    run_send "$dir" "$err" -- t1 "transcript-independent $variant"
    rc=$?
    expect_code 0 "$rc" "$variant transcript must not gate ordinary send"
    [ ! -e "$marker" ] || fail "$variant transcript caused the send chain to invoke its reader"
    body=$(record_body _ "$dir/home/state/t1.inbox/001.msg")
    [ "$body" = "transcript-independent $variant" ] || fail "$variant case changed durable text"
    assert_contains "$(cat "$dir/send.log")" 'Firstmate instruction waiting' \
      "$variant transcript case did not reach the native prompt"
  done
  pass "fm-send inbox: missing, unreadable, huge, and malformed transcripts are never opened before native submission"
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
  dir=$(setup_case dollartext pi)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1 '$5/month is cheap' || fail "a pi \$-text send should succeed"
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
  run_send "$dir" "$err" -- sess:w1:p-win "hello there" || fail "an explicit-target send should succeed"
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
  : >"$dir/home/state/t1.inbox" # a FILE where the inbox dir must go
  run_send "$dir" "$err" -- t1 "this cannot be recorded"
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unwritable inbox must fail the send"
  assert_contains "$(cat "$err")" "inbox record could not be written" \
    "the failure should name the unwritable inbox"
  [ ! -s "$dir/send.log" ] || fail "a failed enqueue still typed something:"$'\n'"$(cat "$dir/send.log")"
  pass "fm-send inbox: an unwritable ordinary-task record is a loud local failure"
}

test_empty_message_refused() {
  local dir err rc
  dir=$(setup_case empty-omitted)
  err="$dir/send.err"
  run_send "$dir" "$err" -- t1
  rc=$?
  [ "$rc" -ne 0 ] || fail "an omitted ordinary-task message should refuse"
  assert_contains "$(cat "$err")" "nonempty message" \
    "the empty-message refusal should be explicit"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "an empty steer still wrote an inbox record"
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

test_text_steer_rides_inbox
test_multiline_steer_is_legal
test_resend_enqueues_new_sequence
test_pending_composer_does_not_gate_native_prompt
test_failed_ring_is_still_sent
test_uncertain_ring_persists_recovery_before_suppression
test_transcript_variants_are_never_opened_by_send
test_harness_invocations_stay_typed
test_explicit_target_stays_typed
test_key_path_never_touches_inbox
test_meta_lock_contention_fails_bounded
test_unwritable_inbox_fails_loudly
test_empty_message_refused

test_goal_action_replay() {
  local dir payload
  dir=$(setup_case goal-action)
  mkdir -p "$dir/home/data/t1"
  printf 'Deliver all requested artifacts' > "$dir/home/data/t1/brief.md"
  printf 'spawn_gen=s1\n' >> "$dir/home/state/t1.meta"
  payload='Please finish the remaining artifact'
  printf '%s' "$payload" > "$dir/home/data/t1/next.txt"
  FM_HOME="$dir/home" python3 "$ROOT/bin/fm-task-lifecycle.py" init t1 >/dev/null || fail 'init goal'
  python3 - "$dir/home" <<'PY'
import json,sys,hashlib,pathlib
h=pathlib.Path(sys.argv[1]);d=json.loads((h/'data/t1/lifecycle.json').read_text())
d['next_action']={'id':'t1.g1.a1','kind':'steer','phase':'prepared','expected_execution_generation':'s1',
'payload_ref':'data/t1/next.txt','payload_sha256':hashlib.sha256((h/'data/t1/next.txt').read_bytes()).hexdigest(),
'receipt_ref':None,'attempts':0,'attempt_limit':2,'recheck_at':'2000-01-01T00:00:00Z','deadline':'2099-01-01T00:00:00Z'}
d['next_action_seq']=2
p=h/'candidate.json';p.write_text(json.dumps(d));p.chmod(0o600)
PY
  FM_HOME="$dir/home" "$ROOT/bin/fm-task-state.sh" reconcile t1 --expected-revision 1 --record "$dir/home/candidate.json" >/dev/null || fail 'prepare action'
  run_send "$dir" "$dir/error" -- t1 --action-id t1.g1.a1 --expected-generation s1 "$payload" || fail "send goal: $(cat "$dir/error")"
  grep -Fx 'execution_generation=s1' "$dir/home/state/t1.inbox/001.msg" >/dev/null || fail 'goal action receipt omitted its execution generation'
  mv "$dir/home/state/t1.inbox/001.msg" "$dir/home/state/t1.inbox/handled/"
  run_send "$dir" "$dir/error" -- t1 --action-id t1.g1.a1 --expected-generation s1 "$payload" || fail "replay confirmed goal: $(cat "$dir/error")"
  [ ! -e "$dir/home/state/t1.inbox/002.msg" ] || fail 'duplicate action enqueued'
  if run_send "$dir" "$dir/error" -- t1 --action-id t1.g1.a1 --expected-generation s1 changed; then fail 'action collision accepted'; fi
  jq -e '.next_action.phase=="confirmed" and .next_action.attempts==1' "$dir/home/data/t1/lifecycle.json" >/dev/null || fail 'missing action receipt'
  pass 'goal action replay finds handled receipt; changed body refuses; one actual enqueue'
}
test_goal_action_replay
