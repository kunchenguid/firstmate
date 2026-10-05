#!/usr/bin/env bash
# Behavior tests for the supervisor-work PreToolUse guard: a firstmate
# supervisor must not do a worker's job. Drives the shipped transport and the
# shipped policy against real homes (a primary checkout, a marked secondmate
# home, a linked crewmate worktree) and checks the tracked harness registrations
# that actually call it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-supervisor-work-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervisor-work-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

# The exact incident this guard exists for: a lead that answered its worker's
# findings and then waited on the worker's pipeline inside one turn.
INCIDENT_RESPOND='cd /home/umer/firstmate/work && no-mistakes axi respond --action fix --note ok'
INCIDENT_POLL='sleep 110; no-mistakes axi run --wait'

run_in() {  # <home> <state> <command...>
  local home=$1 state=$2 rc=0
  shift 2
  : > "$OUT"; : > "$ERR"
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$CHECK" --claude "$@" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {  # <label> <home> <state> <command>
  local label=$1 home=$2 state=$3 command=$4 rc=0
  run_in "$home" "$state" --command "$command" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {  # <label> <home> <state> <command> <code>
  local label=$1 home=$2 state=$3 command=$4 code=$5 rc=0
  run_in "$home" "$state" --command "$command" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label must deny with exit 2, got $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label deny wrote stdout, which makes Claude ignore the deny: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny omitted Claude's permission decision: $(cat "$ERR")"
  jq -e --arg code "$code" '.systemMessage | startswith("[" + $code + "]")' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny lost code $code: $(jq -r '.systemMessage' "$ERR")"
}

# ---------------------------------------------------------------------------
# The rules, in a real supervisor home.
# ---------------------------------------------------------------------------

test_supervisor_may_not_drive_a_workers_no_mistakes_run() {
  expect_deny "respond for a crew-owned run" "$PRIMARY" "$STATE" "$INCIDENT_RESPOND" supervisor-no-mistakes-run
  expect_deny "run --wait for a crew-owned run" "$PRIMARY" "$STATE" "$INCIDENT_POLL" supervisor-no-mistakes-run
  expect_deny "no-mistakes axi run" "$PRIMARY" "$STATE" 'no-mistakes axi run' supervisor-no-mistakes-run
  expect_deny "wrapped in timeout" "$PRIMARY" "$STATE" 'timeout 1700 no-mistakes axi run --wait' supervisor-no-mistakes-run
  expect_deny "backgrounded" "$PRIMARY" "$STATE" 'nohup no-mistakes axi respond --action fix &' supervisor-no-mistakes-run
  # Reading a worker's run record is supervision, not the worker's job.
  expect_allow "no-mistakes axi status" "$PRIMARY" "$STATE" 'no-mistakes axi status'
  expect_allow "no-mistakes axi status --json" "$PRIMARY" "$STATE" 'no-mistakes axi status --json'
  pass "a supervisor may read a worker's run record but may never drive that run"
}

test_supervisor_may_not_sleep_or_poll_inside_a_turn() {
  expect_deny "sleep over 60s" "$PRIMARY" "$STATE" 'sleep 110' supervisor-poll-in-turn
  expect_deny "compound duration over 60s" "$PRIMARY" "$STATE" 'sleep 1m30s' supervisor-poll-in-turn
  expect_deny "unreadable duration" "$PRIMARY" "$STATE" 'sleep "$WAIT"' supervisor-poll-in-turn
  expect_deny "for loop with sleep" "$PRIMARY" "$STATE" 'for i in $(seq 10); do sleep 5; no-mistakes axi status; done' supervisor-poll-in-turn
  expect_deny "while loop with sleep" "$PRIMARY" "$STATE" 'while :; do sleep 5; done' supervisor-poll-in-turn
  expect_deny "until loop with sleep" "$PRIMARY" "$STATE" 'until [ -f done ]; do sleep 30; done' supervisor-poll-in-turn
  expect_allow "short sleep" "$PRIMARY" "$STATE" 'sleep 5'
  expect_allow "60s sleep" "$PRIMARY" "$STATE" 'sleep 60'
  expect_allow "one minute sleep" "$PRIMARY" "$STATE" 'sleep 1m'
  expect_allow "a loop with no sleep" "$PRIMARY" "$STATE" 'for f in *.log; do wc -l "$f"; done'
  # The words must be a command, not data: a supervisor edits its own docs.
  expect_allow "sleep as quoted data" "$PRIMARY" "$STATE" "git commit -m 'never sleep 90 in a turn'"
  pass "a supervisor may take a short bounded wait but never a poll loop or a long sleep"
}

test_only_a_secondmate_lead_may_not_type_into_a_pane() {
  local second="$TMP_ROOT/secondmate" rc=0
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/bin" "$second/state"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"

  expect_deny "herdr send-text" "$second" "$second/state" 'herdr pane send-text "yes"' supervisor-pane-typing
  expect_deny "herdr send-keys" "$second" "$second/state" 'herdr pane send-keys Enter' supervisor-pane-typing
  expect_deny "tmux send-keys" "$second" "$second/state" 'tmux send-keys -t worker Enter' supervisor-pane-typing
  expect_deny "the desklink incident shape" "$second" "$second/state" \
    'herdr pane send-text "go"; sleep 25; herdr pane send-keys Enter' supervisor-pane-typing
  # The primary home is exempt for now: only a secondmate lead owns workers
  # whose panes this would type into.
  expect_allow "primary send-text is exempt" "$PRIMARY" "$STATE" 'herdr pane send-text "yes"'
  expect_allow "secondmate reads panes without typing" "$second" "$second/state" 'herdr pane capture'
  rc=0
  run_in "$second" "$second/state" --command 'herdr pane send-keys Enter' || rc=$?
  [ "$rc" -eq 2 ] || fail "a marked secondmate home must be judged as a supervisor, got exit $rc"
  pass "pane typing is refused only in a secondmate lead, which must steer with fm-send instead"
}

test_a_worker_worktree_is_never_refused() {
  local child="$TMP_ROOT/child" plain="$TMP_ROOT/plain" command
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  printf '# fixture\n' > "$child/AGENTS.md"
  for command in "$INCIDENT_RESPOND" "$INCIDENT_POLL" 'sleep 110' \
                  'herdr pane send-text "yes"' 'herdr pane send-keys Enter' \
                  'for i in $(seq 10); do sleep 5; done'; do
    expect_allow "worker command: $command" "$child" "$child/state" "$command"
  done

  mkdir -p "$plain/bin"
  git -C "$plain" init -q
  printf '# fixture\n' > "$plain/AGENTS.md"
  expect_allow "non-firstmate repo" "$plain" "$plain/state" "$INCIDENT_POLL"
  pass "a ship or scout worker owns its own run, its own waits, and its own pane"
}

# ---------------------------------------------------------------------------
# The registrations that actually call it, and the transports.
# ---------------------------------------------------------------------------

test_tracked_harnesses_call_the_guard() {
  jq -e '[.hooks.PreToolUse[]?.hooks[]?.command? | type == "string" and contains("fm-supervisor-work-pretool-check.sh")] | any' \
    "$ROOT/.claude/settings.json" >/dev/null \
    || fail "the tracked Claude settings do not register the supervisor-work guard"
  local extension
  for extension in .pi/extensions/fm-primary-turnend-guard.ts .omp/extensions/fm-primary-turnend-guard.ts; do
    grep -q 'runSupervisorWorkCheck' "$ROOT/$extension" \
      || fail "$extension does not run the supervisor-work guard"
  done
  pass "Claude and the pi/omp supervisor extensions all invoke the guard"
}

test_claude_stdin_and_pi_cli_transports_both_deny() {
  local rc=0
  : > "$OUT"; : > "$ERR"
  jq -Rn --arg c "$INCIDENT_POLL" '{tool_input:{command:$c}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a Claude-shaped stdin payload must deny, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "Claude deny wrote stdout, which makes Claude ignore the deny: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  jq -Rn --arg c 'sleep 110' '{toolInput:{command:$c}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a Grok-shaped stdin payload must deny, got exit $rc: $(cat "$ERR")"
  # Without --claude the Grok decision object goes to stdout and the
  # Claude-shaped object still goes to stderr, as every shipped seatbelt does.
  jq -e '.decision == "deny" and (.reason | startswith("[supervisor-poll-in-turn]"))' "$OUT" >/dev/null \
    || fail "Grok deny object lost its decision or code: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null \
    || fail "the Grok transport must still carry the Claude deny on stderr: $(cat "$ERR")"

  rc=0
  : > "$OUT"; : > "$ERR"
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" --command "$INCIDENT_RESPOND" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "the Pi --command transport must deny, got exit $rc: $(cat "$ERR")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null \
    || fail "the Pi deny omitted the PreToolUse decision: $(cat "$ERR")"
  pass "the Claude, Grok, and Pi transports of the same policy all refuse the incident command"
}

test_malformed_transport_fails_open() {
  local rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' 'not json at all' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a malformed payload must fail open, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "malformed fail-open wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "malformed fail-open wrote stderr: $(cat "$ERR")"
  pass "a malformed payload or missing runtime never denies a supervisor command"
}

test_supervisor_may_not_drive_a_workers_no_mistakes_run
test_supervisor_may_not_sleep_or_poll_inside_a_turn
test_only_a_secondmate_lead_may_not_type_into_a_pane
test_a_worker_worktree_is_never_refused
test_tracked_harnesses_call_the_guard
test_claude_stdin_and_pi_cli_transports_both_deny
test_malformed_transport_fails_open