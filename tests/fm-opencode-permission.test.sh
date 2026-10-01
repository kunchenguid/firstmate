#!/usr/bin/env bash
# Behavior tests for the OpenCode permission decision bridge and the Discord
# capture wake. Every case drives the real scripts through their public
# interface against a fake opencode client and a fake Discord bot; nothing here
# contacts a live OpenCode server or Discord.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
PASTE_DIR=$(command -v paste 2>/dev/null) && PASTE_DIR=$(dirname "$PASTE_DIR") || PASTE_DIR=
[ -n "$PASTE_DIR" ] && BASE_PATH="$PASTE_DIR:$BASE_PATH"

TMP_ROOT=$(fm_test_tmproot fm-opencode-permission-tests)

TASK=firstmate-perm-test-20261001
SESSION=ses_permtest0000000001
REQUEST=per_permtest000000001

# A fake `opencode` whose behavior is driven by two env vars, so each test
# states the server state it needs instead of the script knowing about tests.
#   FM_FAKE_PERM_STATE=pending   the request is live and answerable
#   FM_FAKE_PERM_STATE=gone     the server no longer reports it (expired/answered)
#   FM_FAKE_PERM_STATE=mismatch the server reports a different id or session
#   FM_FAKE_PERM_STATE=refuse   the reply POST fails
# FM_FAKE_PERM_CALLS records every invocation, so a test can prove that a
# refused decision issued no API write at all.
make_fake_opencode() {
  local home=$1
  mkdir -p "$home/fake-bin"
  cat > "$home/fake-bin/opencode" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_PERM_CALLS"
[ "${1:-}" = api ] || exit 0
state=${FM_FAKE_PERM_STATE:-pending}
case "${2:-}" in
  GET) ;;
  POST) ;;
  *) exit 0 ;;
esac
path=${3:-}
case "$path" in
  */permission/*/reply)
    [ "$state" = refuse ] && { echo '{"_tag":"InvalidRequestError","message":"refused"}' >&2; exit 1; }
    [ "$state" = gone ] && { echo 'not found' >&2; exit 1; }
    printf '{"data":{"id":"%s","effect":"allow"}}\n' "$FM_FAKE_PERM_REQUEST"
    ;;
  */permission/*)
    case "$state" in
      gone) echo 'not found' >&2; exit 1 ;;
      mismatch) printf '{"id":"per_someoneelse","sessionID":"ses_someoneelse","action":"external_directory","resources":["/tmp/x"]}\n' ;;
      *) printf '{"id":"%s","sessionID":"%s","action":"external_directory","resources":["/tmp/fake-probe/*"],"save":["/tmp/fake-probe/*"],"metadata":{}}\n' \
           "$FM_FAKE_PERM_REQUEST" "$FM_FAKE_PERM_SESSION" ;;
    esac
    ;;
esac
SH
  chmod +x "$home/fake-bin/opencode"
}

# A task record plus a busy generation, which is what makes a decide's
# generation check meaningful rather than vacuous.
arm_task() {  # <home>
  local home=$1
  mkdir -p "$home/state"
  chmod 700 "$home/state"
  printf 'g1.1.1\n' > "$home/state/$TASK.busy-gen"
  chmod 600 "$home/state/$TASK.busy-gen"
}

# perm_env <home> <fake-state> -> the env assignments for the script under test.
# Passed through `env` rather than exported, so the assignments are scoped to
# exactly one invocation and never reach the rest of the suite.
perm_env() {
  local home=$1 state=$2
  printf '%s\n' \
    "FM_FAKE_PERM_STATE=$state" \
    "FM_FAKE_PERM_REQUEST=$REQUEST" \
    "FM_FAKE_PERM_SESSION=$SESSION" \
    "FM_FAKE_PERM_CALLS=$home/state/opencode-calls.log" \
    "PATH=$home/fake-bin:$BASE_PATH" \
    "FM_HOME=$home" \
    "FM_STATE_OVERRIDE=$home/state"
}

# run_perm <home> <fake-state> <subcommand> [args...]: run the script under
# test against a fake opencode whose server state this test states.
run_perm() {
  local home=$1 state=$2
  shift 2
  local -a assigns=()
  mapfile -t assigns < <(perm_env "$home" "$state")
  env "${assigns[@]}" "$ROOT/bin/fm-opencode-permission.sh" "$@"
}

test_ask_records_only_a_server_confirmed_request() {
  local home out rc record
  home="$TMP_ROOT/ask-confirmed"; arm_task "$home"
  make_fake_opencode "$home"
  out=$(run_perm "$home" pending \
    ask "$TASK" "$SESSION" "$REQUEST" 2>"$home/err"); rc=$?
  expect_code 0 "$rc" "ask exit"
  assert_equals "perm-$REQUEST" "$out" "ask prints the decision key"

  record="$home/state/$TASK.opencode-permission/$REQUEST.json"
  assert_present "$record" "request record written"
  assert_equals "pending" "$(jq -r '.state' "$record")" "record starts pending"
  assert_equals "$SESSION" "$(jq -r '.session_id' "$record")" "record binds the session"
  assert_equals "g1.1.1" "$(jq -r '.generation' "$record")" "record captures the task generation"
  assert_equals "/tmp/fake-probe/*" "$(jq -r '.resources[0]' "$record")" "record captures the resource"
  assert_equals "/tmp/fake-probe/*" "$(jq -r '.save[0]' "$record")" "record captures the save pattern"
  pass "ask records only a request the live server confirms"
}

test_ask_refuses_a_request_the_server_does_not_confirm() {
  local home out rc record
  home="$TMP_ROOT/ask-gone"; arm_task "$home"
  make_fake_opencode "$home"
  out=$(run_perm "$home" gone \
    ask "$TASK" "$SESSION" "$REQUEST" 2>"$home/err"); rc=$?
  [ "$rc" -ne 0 ] || fail "ask must fail when the server reports no request"
  assert_absent "$home/state/$TASK.opencode-permission/$REQUEST.json" "no record for an unconfirmed request"
  assert_contains "$(cat "$home/err")" "refusing" "refusal names itself as a refusal"
  pass "ask refuses a request the server does not report"
}

test_ask_refuses_a_mismatched_identity() {
  local home rc
  home="$TMP_ROOT/ask-mismatch"; arm_task "$home"
  make_fake_opencode "$home"
  run_perm "$home" mismatch \
    ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>"$home/err"; rc=$?
  [ "$rc" -ne 0 ] || fail "ask must fail when the server reports a different identity"
  assert_absent "$home/state/$TASK.opencode-permission/$REQUEST.json" "no record for a mismatched identity"
  pass "ask refuses when the server's id or session is not the requested one"
}

test_ask_refuses_without_a_task_generation() {
  local home rc
  home="$TMP_ROOT/ask-nogen"; mkdir -p "$home/state"; chmod 700 "$home/state"
  make_fake_opencode "$home"
  run_perm "$home" pending \
    ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>"$home/err"; rc=$?
  [ "$rc" -ne 0 ] || fail "ask must fail when the task has no current generation"
  assert_absent "$home/state/$TASK.opencode-permission/$REQUEST.json" "no record without a generation to check later"
  pass "ask refuses when the task generation is unreadable, so a later answer cannot be proven current"
}

test_decide_applies_once_and_refuses_a_replay() {
  local home first record calls
  home="$TMP_ROOT/decide-once"; arm_task "$home"
  make_fake_opencode "$home"
  run_perm "$home" pending \
    ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>&1
  first=$(run_perm "$home" pending \
    decide "$TASK" "$REQUEST" once 2>"$home/err"); rc=$?
  expect_code 0 "$rc" "first decide exit"
  assert_contains "$first" "applied once" "first decide reports the applied decision"

  record="$home/state/$TASK.opencode-permission/$REQUEST.json"
  assert_equals "replied" "$(jq -r '.state' "$record")" "record closes as replied"
  assert_equals "once" "$(jq -r '.decision' "$record")" "record carries the decision as the receipt"

  # The replay runs against a server that would happily answer again, so a
  # non-refusal here would be a second real grant.
  run_perm "$home" pending \
    decide "$TASK" "$REQUEST" always >"$home/replay.out" 2>"$home/err2"; rc=$?
  [ "$rc" -ne 0 ] || fail "a replayed decide must be refused"
  assert_contains "$(cat "$home/err2")" "already" "replay refusal names the spent state"
  assert_equals "once" "$(jq -r '.decision' "$record")" "a refused replay does not overwrite the applied decision"
  pass "decide applies the captain's answer once and refuses the replay without granting again"
}

test_decide_refuses_an_expired_request_without_writing() {
  local home rc record calls_after
  home="$TMP_ROOT/decide-expired"; arm_task "$home"
  make_fake_opencode "$home"
  run_perm "$home" pending \
    ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>&1
  : > "$home/state/opencode-calls.log"
  run_perm "$home" gone \
    decide "$TASK" "$REQUEST" always >/dev/null 2>"$home/err"; rc=$?
  [ "$rc" -ne 0 ] || fail "decide must fail when the request is no longer pending"
  record="$home/state/$TASK.opencode-permission/$REQUEST.json"
  assert_equals "pending" "$(jq -r '.state' "$record")" "an expired request stays pending, never consumed"
  calls_after=$(grep -c reply "$home/state/opencode-calls.log" 2>/dev/null || true)
  assert_equals "0" "$calls_after" "no reply POST was issued for an expired request"
  pass "decide refuses an expired request and issues no API write"
}

test_decide_refuses_a_stale_task_generation() {
  local home rc record
  home="$TMP_ROOT/decide-stale-gen"; arm_task "$home"
  make_fake_opencode "$home"
  run_perm "$home" pending \
    ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>&1
  # The task was relaunched: a new generation means a different run.
  printf 'g2.2.2\n' > "$home/state/$TASK.busy-gen"
  run_perm "$home" pending \
    decide "$TASK" "$REQUEST" once >/dev/null 2>"$home/err"; rc=$?
  [ "$rc" -ne 0 ] || fail "decide must fail for a stale task generation"
  record="$home/state/$TASK.opencode-permission/$REQUEST.json"
  assert_equals "pending" "$(jq -r '.state' "$record")" "a stale-generation request stays pending"
  assert_contains "$(cat "$home/err")" "generation" "refusal names the generation mismatch"
  pass "decide refuses an answer to a task generation that has moved on"
}

test_decide_refuses_a_foreign_task() {
  local home other rc record
  home="$TMP_ROOT/decide-foreign"; arm_task "$home"
  make_fake_opencode "$home"
  run_perm "$home" pending \
    ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>&1
  other=some-other-task-20261001
  printf 'g1.1.1\n' > "$home/state/$other.busy-gen"
  # Another task id addresses its own record directory, so this task's request
  # is simply not there to be answered.
  run_perm "$home" pending \
    decide "$other" "$REQUEST" once >/dev/null 2>"$home/err"; rc=$?
  [ "$rc" -ne 0 ] || fail "another task must not be able to answer this request"
  assert_contains "$(cat "$home/err")" "no permission request record" "the foreign task id reaches no record"
  record="$home/state/$TASK.opencode-permission/$REQUEST.json"
  assert_equals "pending" "$(jq -r '.state' "$record")" "the owning task's request stays pending"

  # And a record planted under a foreign task's directory is still refused on
  # the task binding it carries, so copying a record cannot move a decision.
  mkdir -p "$home/state/$other.opencode-permission"
  cp "$record" "$home/state/$other.opencode-permission/$REQUEST.json"
  run_perm "$home" pending \
    decide "$other" "$REQUEST" once >/dev/null 2>"$home/err2"; rc=$?
  [ "$rc" -ne 0 ] || fail "a copied record must not be answerable under another task id"
  assert_contains "$(cat "$home/err2")" "belongs to task" "the refusal names the task the record actually belongs to"
  pass "one task's request cannot be answered by another task id, and a copied record is refused on its own binding"
}

test_decide_refuses_an_unknown_decision() {
  local home rc record
  home="$TMP_ROOT/decide-bad-decision"; arm_task "$home"
  make_fake_opencode "$home"
  run_perm "$home" pending \
    ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>&1
  run_perm "$home" pending \
    decide "$TASK" "$REQUEST" yes >/dev/null 2>"$home/err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a decision outside the server's enum must be refused"
  record="$home/state/$TASK.opencode-permission/$REQUEST.json"
  assert_equals "pending" "$(jq -r '.state' "$record")" "an unusable decision leaves the request pending"
  pass "decide refuses a decision outside once/always/reject without granting"
}

test_decide_records_a_consumed_receipt_when_the_server_refuses() {
  local home rc record
  home="$TMP_ROOT/decide-server-refusal"; arm_task "$home"
  make_fake_opencode "$home"
  run_perm "$home" pending \
    ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>&1
  run_perm "$home" refuse \
    decide "$TASK" "$REQUEST" always >/dev/null 2>"$home/err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a server refusal must surface as a failure"
  record="$home/state/$TASK.opencode-permission/$REQUEST.json"
  assert_equals "consumed" "$(jq -r '.state' "$record")" "the spent answer stays consumed, not retryable"
  assert_equals "always" "$(jq -r '.decision' "$record")" "the receipt records what the captain chose"
  assert_contains "$(jq -r '.apply_error' "$record")" "refused" "the receipt carries the server's exact refusal"
  pass "a server refusal leaves a consumed receipt naming the error, and never grants"
}

test_settle_closes_the_record_without_an_api_write() {
  local home out rc record calls
  home="$TMP_ROOT/settle"; arm_task "$home"
  make_fake_opencode "$home"
  run_perm "$home" pending \
    ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>&1
  : > "$home/state/opencode-calls.log"
  out=$(run_perm "$home" pending \
    settle "$TASK" "$REQUEST" reject 2>"$home/err"); rc=$?
  expect_code 0 "$rc" "settle exit"
  record="$home/state/$TASK.opencode-permission/$REQUEST.json"
  assert_equals "replied" "$(jq -r '.state' "$record")" "settle closes the record"
  assert_equals "reject" "$(jq -r '.decision' "$record")" "settle records the decision"
  calls=$(grep -c reply "$home/state/opencode-calls.log" 2>/dev/null || true)
  assert_equals "0" "$calls" "settle issues no reply POST of its own"
  # And a decided record can no longer be decided, whatever asked first.
  run_perm "$home" pending \
    decide "$TASK" "$REQUEST" always >/dev/null 2>"$home/err2" \
    && fail "a settled request must not be decidable again"
  pass "settle closes the audit record on an externally applied decision and posts nothing"
}

test_ask_is_idempotent_and_keeps_the_original_record() {
  local home record
  home="$TMP_ROOT/ask-idempotent"; arm_task "$home"
  make_fake_opencode "$home"
  run_perm "$home" pending \
    ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>&1
  record="$home/state/$TASK.opencode-permission/$REQUEST.json"
  local before after
  before=$(cat "$record")
  run_perm "$home" pending \
    ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>&1
  after=$(cat "$record")
  assert_equals "$before" "$after" "a repeated ask leaves the captured identity untouched"
  pass "a repeated ask for the same request does not rewrite its record"
}

test_ask_retries_a_push_that_failed_and_leaves_the_record_untouched() {
  # A notification that fails once must not be lost: the second ask for the
  # same request has to retry it, or the captain never sees the decision and
  # the worker stays blocked.
  local home record pushes before after
  home="$TMP_ROOT/ask-retry-push"; arm_task "$home"
  make_fake_opencode "$home"
  pushes="$home/state/notifier-calls.log"
  mkdir -p "$home/shadow"
  cp "$ROOT/bin/fm-opencode-permission.sh" "$home/shadow/fm-opencode-permission.sh"
  cp "$ROOT/bin/fm-busy-lib.sh" "$home/shadow/fm-busy-lib.sh"
  cat > "$home/shadow/fm-discord-notify.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_NOTIFIER_CALLS"
[ "${FM_FAKE_NOTIFIER_FAIL:-0}" = 1 ] && exit 1
exit 0
SH
  chmod +x "$home/shadow/fm-opencode-permission.sh" "$home/shadow/fm-discord-notify.sh"
  : > "$pushes"
  record="$home/state/$TASK.opencode-permission/$REQUEST.json"

  mapfile -t assigns < <(perm_env "$home" pending)
  env "${assigns[@]}" "FM_FAKE_NOTIFIER_CALLS=$pushes" FM_FAKE_NOTIFIER_FAIL=1 \
    "$home/shadow/fm-opencode-permission.sh" ask "$TASK" "$SESSION" "$REQUEST" \
    >/dev/null 2>"$home/first.err"
  assert_equals "1" "$(wc -l < "$pushes" | tr -d ' ')" "the first ask attempted the push"
  assert_present "$record" "the record survives a failed push, so the decision is retryable"
  assert_contains "$(cat "$home/first.err")" "push failed" "a failed push is reported as actionable"

  before=$(cat "$record")
  env "${assigns[@]}" "FM_FAKE_NOTIFIER_CALLS=$pushes" \
    "$home/shadow/fm-opencode-permission.sh" ask "$TASK" "$SESSION" "$REQUEST" \
    >/dev/null 2>"$home/second.err"
  after=$(cat "$record")
  assert_equals "2" "$(wc -l < "$pushes" | tr -d ' ')" "the repeated ask retried the captain push"
  assert_equals "$before" "$after" "the retry left the captured record bytes untouched"
  pass "a failed captain push is retried on the next ask without rewriting the record"
}

test_the_question_shows_every_resource_and_remembered_path() {
  # Approving a request grants every resource it names, so the question must
  # show all of them. A path can contain spaces, so a space-joined rendering
  # would misstate the boundary between two entries.
  local home summary
  home="$TMP_ROOT/ask-multiple-resources"; arm_task "$home"
  make_fake_opencode "$home"
  cat > "$home/fake-bin/opencode" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_PERM_CALLS"
printf '{"id":"%s","sessionID":"%s","action":"external_directory","resources":["/private/a","/private/b","/tmp/dir with space/x"],"save":["/private/a","/tmp/dir with space/x"],"metadata":{}}\n' \
  "$FM_FAKE_PERM_REQUEST" "$FM_FAKE_PERM_SESSION"
SH
  chmod +x "$home/fake-bin/opencode"
  calls="$home/state/notifier-calls.log"
  mkdir -p "$home/shadow"
  cp "$ROOT/bin/fm-opencode-permission.sh" "$home/shadow/fm-opencode-permission.sh"
  cp "$ROOT/bin/fm-busy-lib.sh" "$home/shadow/fm-busy-lib.sh"
  cat > "$home/shadow/fm-discord-notify.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_NOTIFIER_CALLS"
SH
  chmod +x "$home/shadow/fm-opencode-permission.sh" "$home/shadow/fm-discord-notify.sh"
  mapfile -t assigns < <(perm_env "$home" pending)
  env "${assigns[@]}" "FM_FAKE_NOTIFIER_CALLS=$calls" \
    "$home/shadow/fm-opencode-permission.sh" ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>&1
  summary=$(cat "$calls")
  assert_contains "$summary" '/private/a' "the first resource is shown"
  assert_contains "$summary" '/private/b' "the last resource is shown too, not only the first"
  assert_contains "$summary" '/tmp/dir with space/x' "a resource containing a space is shown whole"
  assert_contains "$summary" 'resources=["/private/a","/private/b","/tmp/dir with space/x"]' \
    "the full resource list is shown with its element boundaries intact"
  assert_contains "$summary" 'these paths: ["/private/a","/tmp/dir with space/x"]' \
    "the complete remember scope is shown with its boundaries intact"
  case "$summary" in
    *$'\n'*) fail "the pushed summary must stay one line" ;;
  esac
  pass "the captain is shown every resource and every remembered path, boundaries intact"
}

test_concurrent_decides_post_exactly_once() {
  local home record posts
  home="$TMP_ROOT/decide-concurrent"; arm_task "$home"
  make_fake_opencode "$home"
  run_perm "$home" pending ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>&1
  # A slow reply so both decides are inside the read-check-consume window
  # together, which is the only way a record-state check alone can be raced.
  cat > "$home/fake-bin/opencode" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_PERM_CALLS"
case "${3:-}" in
  */reply) sleep 1; printf '{"data":{"id":"%s","effect":"allow"}}\n' "$FM_FAKE_PERM_REQUEST" ;;
  *) printf '{"id":"%s","sessionID":"%s","action":"external_directory","resources":["/tmp/fake-probe/*"],"save":["/tmp/fake-probe/*"],"metadata":{}}\n' \
       "$FM_FAKE_PERM_REQUEST" "$FM_FAKE_PERM_SESSION" ;;
esac
SH
  chmod +x "$home/fake-bin/opencode"
  mapfile -t assigns < <(perm_env "$home" pending)
  env "${assigns[@]}" "$ROOT/bin/fm-opencode-permission.sh" decide "$TASK" "$REQUEST" once \
    > "$home/a.out" 2>"$home/a.err" &
  local a=$!
  env "${assigns[@]}" "$ROOT/bin/fm-opencode-permission.sh" decide "$TASK" "$REQUEST" always \
    > "$home/b.out" 2>"$home/b.err" &
  local b=$!
  wait "$a"; wait "$b"

  posts=$(grep -c '/reply' "$home/state/opencode-calls.log" 2>/dev/null || true)
  assert_equals "1" "$posts" "two concurrent decides issued exactly one reply POST"
  record="$home/state/$TASK.opencode-permission/$REQUEST.json"
  assert_equals "replied" "$(jq -r '.state' "$record")" "the record closed on the single applied answer"
  case "$(jq -r '.decision' "$record")" in
    once|always) ;;
    *) fail "the record does not carry one of the two racing decisions" ;;
  esac
  pass "two concurrent decides apply exactly one answer, not two grants"
}

test_the_documented_reply_derivation_reaches_the_right_request() {
  local home inbox out rc record
  home="$TMP_ROOT/documented-derivation"; arm_task "$home"
  make_fake_opencode "$home"
  run_perm "$home" pending \
    ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>&1

  # A captured decision reply, in exactly the shape bin/fm-discord-poll.js
  # writes. The next block derives its arguments the way the fmx-respond skill
  # documents, so this test fails if that documented derivation ever drifts
  # away from what the applier actually accepts.
  mkdir -p "$home/state/x-inbox"
  chmod 700 "$home/state/x-inbox"
  inbox="$home/state/x-inbox/discord-sh-1352000000000002001.json"
  jq -n --arg task "$TASK" --arg key "perm-$REQUEST" \
    '{request_id:"discord-sh-1352000000000002001", text:"Approve once",
      source:"discord-selfhosted-decision", channel_id:"1000000000000000001",
      message_id:"1352000000000002001",
      decision:{task_id:$task, key:$key, trigger:"perm-ask",
                options:["Approve once","Approve once and remember this","Reject the request"]}}' \
    > "$inbox"
  chmod 600 "$inbox"

  local decision_task decision_key request_id decision
  decision_task=$(jq -r '.decision.task_id' "$inbox")
  decision_key=$(jq -r '.decision.key' "$inbox")
  request_id=${decision_key#perm-}
  # The captain chose "Approve once", which the skill maps to `once`.
  decision=once

  out=$(run_perm "$home" pending decide "$decision_task" "$request_id" "$decision" 2>"$home/err"); rc=$?
  expect_code 0 "$rc" "the documented derivation reaches the right request"
  assert_contains "$out" "applied once" "the derived invocation applied the captain's choice"
  record="$home/state/$TASK.opencode-permission/$REQUEST.json"
  assert_equals "replied" "$(jq -r '.state' "$record")" "the derived invocation closed the real record"
  pass "the derivation the skill documents turns a captured reply into the right applied answer"
}

test_ask_records_a_resource_containing_a_comma_verbatim() {
  # A delimiter round trip between the server's list and the record would
  # silently narrow or widen the scope the captain is shown and the applier
  # later checks, so the list is carried as JSON.
  local home record calls
  home="$TMP_ROOT/ask-comma"; arm_task "$home"
  make_fake_opencode "$home"
  cat > "$home/fake-bin/opencode" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_PERM_CALLS"
printf '{"id":"%s","sessionID":"%s","action":"external_directory","resources":["/tmp/a,b/*","/tmp/plain/*"],"save":["/tmp/a,b/*"],"metadata":{}}\n' \
  "$FM_FAKE_PERM_REQUEST" "$FM_FAKE_PERM_SESSION"
SH
  chmod +x "$home/fake-bin/opencode"
  run_perm "$home" pending ask "$TASK" "$SESSION" "$REQUEST" >/dev/null 2>"$home/err"
  record="$home/state/$TASK.opencode-permission/$REQUEST.json"
  assert_equals "/tmp/a,b/*" "$(jq -r '.resources[0]' "$record")" "a comma-bearing resource is stored verbatim"
  assert_equals "2" "$(jq -r '.resources | length' "$record")" "the resource list keeps its own boundaries"
  assert_equals "/tmp/plain/*" "$(jq -r '.resources[1]' "$record")" "the following resource is not merged into the first"
  assert_equals "/tmp/a,b/*" "$(jq -r '.save[0]' "$record")" "a comma-bearing save pattern is stored verbatim"
  pass "a resource or save pattern containing a comma is recorded and shown verbatim"
}

test_discord_capture_enqueues_a_durable_wake() {
  local home wake_rows
  home="$TMP_ROOT/discord-wake"
  mkdir -p "$home/state/x-inbox" "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-inbox" "$home/state/x-context"
  mkdir -p "$home/fake-bin"
  # Reuse the connector's own fetch seam: a bot mention the poll captures.
  cat > "$home/fake-bin/node" <<'SH'
#!/usr/bin/env bash
set -u
exec "$FM_TEST_REAL_NODE" --input-type=module -e '
  import { pathToFileURL } from "node:url";
  const script = process.argv[1];
  const messages = JSON.parse(process.env.FM_DISCORD_FAKE_MESSAGES || "[]");
  globalThis.fetch = async (url) => {
    if (url === "https://discord.com/api/v10/users/@me") return Response.json({ id: "9000000000000000001" });
    if (url.includes("/channels/")) return Response.json(messages);
    return new Response("not found", { status: 404 });
  };
  await import(pathToFileURL(script).href);
' "$1"
SH
  chmod +x "$home/fake-bin/node"

  # Run the poll the way an operator-run or LaunchAgent-run ingress does: its
  # stdout goes to a log, so only a durable wake can reach a session.
  FM_TEST_REAL_NODE=$(command -v node) \
  FM_DISCORD_FAKE_MESSAGES='[{"id":"1352000000000000199","channel_id":"1000000000000000001","guild_id":"1000000000000000000","author":{"username":"captain"},"mentions":[{"id":"9000000000000000001"}],"content":"<@9000000000000000001> yes","attachments":[]}]' \
  PATH="$home/fake-bin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DISCORD_BOT_TOKEN="fake-test-token" \
  FM_DISCORD_CHANNEL_ID="1000000000000000001" FM_DISCORD_EXCLUDE_CHANNELS="1551134713727426570" \
  "$ROOT/bin/fm-discord-poll.sh" > "$home/ingress.log" 2>"$home/ingress.err"

  wake_rows=$(awk -F '\t' 'NF >= 5 && $3 == "check" && $4 == "discord-discord-sh-1352000000000000199"' \
    "$home/state/.wake-queue" 2>/dev/null | wc -l | tr -d ' ')
  assert_equals "1" "$wake_rows" "capture enqueued exactly one durable check wake for the captured reply"
  # The stdout contract is unchanged, so the watcher's own dispatch still works.
  assert_contains "$(cat "$home/ingress.log")" "x-mention discord-sh-1352000000000000199" "stdout wake line is preserved"
  pass "a capture that reaches no watcher still enqueues a durable wake, and the stdout contract is unchanged"
}

test_ask_pushes_the_captain_decision_through_the_existing_notifier() {
  local home calls summary
  local -a assigns
  home="$TMP_ROOT/ask-pushes-decision"; arm_task "$home"
  make_fake_opencode "$home"
  calls="$home/state/notifier-calls.log"
  # Shadow ONLY the notifier, by running the real script from a copy whose
  # sibling notifier is a recorder. The script under test stays the real one.
  mkdir -p "$home/shadow"
  cp "$ROOT/bin/fm-opencode-permission.sh" "$home/shadow/fm-opencode-permission.sh"
  cp "$ROOT/bin/fm-busy-lib.sh" "$home/shadow/fm-busy-lib.sh"
  cat > "$home/shadow/fm-discord-notify.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_NOTIFIER_CALLS"
SH
  chmod +x "$home/shadow/fm-opencode-permission.sh" "$home/shadow/fm-discord-notify.sh"

  mapfile -t assigns < <(perm_env "$home" pending)
  env "${assigns[@]}" "FM_FAKE_NOTIFIER_CALLS=$calls" \
    "$home/shadow/fm-opencode-permission.sh" ask "$TASK" "$SESSION" "$REQUEST" \
    > "$home/out" 2>"$home/err"
  assert_equals "perm-$REQUEST" "$(cat "$home/out")" "ask reports the decision key"
  assert_present "$calls" "the captain decision was pushed"
  summary=$(cat "$calls")
  assert_contains "$summary" "perm-ask $TASK perm-$REQUEST" "the push uses the perm-ask trigger and the perm- key"
  assert_contains "$summary" "action=external_directory" "the question states the action"
  assert_contains "$summary" 'resources=["/tmp/fake-probe/*"]' "the question states the complete resource list"
  assert_contains "$summary" "would save" "the question states the proposed remember scope"
  assert_contains "$summary" "Recommendation:" "the question states a recommendation"
  assert_contains "$summary" "Approve once|Approve once and remember this|Reject the request" \
    "the question offers exactly the three installed-API decisions"
  pass "the ask reaches the existing notifier with the action, resource, save scope, and a recommendation"
}

test_ask_refuses_an_unusable_identity() {
  local home rc
  home="$TMP_ROOT/ask-bad-slug"; arm_task "$home"
  make_fake_opencode "$home"
  run_perm "$home" pending \
    ask "$TASK" "$SESSION" "per/../../etc/passwd" >/dev/null 2>"$home/err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unusable request id must be refused before any path is built"
  pass "ask refuses a request id that is not a privacy-safe slug"
}

test_ask_records_only_a_server_confirmed_request
test_ask_pushes_the_captain_decision_through_the_existing_notifier
test_ask_refuses_a_request_the_server_does_not_confirm
test_ask_refuses_a_mismatched_identity
test_ask_refuses_without_a_task_generation
test_ask_refuses_an_unusable_identity
test_ask_is_idempotent_and_keeps_the_original_record
test_ask_retries_a_push_that_failed_and_leaves_the_record_untouched
test_ask_records_a_resource_containing_a_comma_verbatim
test_the_question_shows_every_resource_and_remembered_path
test_decide_applies_once_and_refuses_a_replay
test_decide_refuses_an_expired_request_without_writing
test_decide_refuses_a_stale_task_generation
test_decide_refuses_a_foreign_task
test_decide_refuses_an_unknown_decision
test_decide_records_a_consumed_receipt_when_the_server_refuses
test_settle_closes_the_record_without_an_api_write
test_concurrent_decides_post_exactly_once
test_the_documented_reply_derivation_reaches_the_right_request
test_discord_capture_enqueues_a_durable_wake
