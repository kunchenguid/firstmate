#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for the captain reply-shape reminder hook.
#
# Two properties matter and they fail for different reasons.
#
# 1. The reminder reaches a genuine primary home's turn and nowhere else: not a
#    crewmate's task worktree, not a no-mistakes gate agent, not a home that
#    switched it off, and not a turn taken while away mode is active.
# 2. The registration cannot wedge a captain's turn. Claude blocks and erases the
#    prompt when a UserPromptSubmit hook exits 2, and bash itself exits 2 on a
#    syntax error, so the tracked command string - not the script's own care - is
#    what has to pin the exit to 0. These cases run the REAL command string out
#    of .claude/settings.json against a sabotaged script.
#
# Whether Claude adds the printed line to model context is a vendor behavior no
# portable test can see; docs/verification/supervision.md records that evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-plainenglish-hook)

command -v jq >/dev/null 2>&1 || fail "test host must provide jq"

PAYLOAD='{"session_id":"s1","hook_event_name":"UserPromptSubmit","prompt":"what is the state of the fleet?"}'

install_hook() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  cp "$ROOT/bin/fm-plainenglish-hook.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-plainenglish-hook.sh"
}

# A primary-shaped home: plain (non-worktree) git repo, AGENTS.md, bin/, state/.
make_primary_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_hook "$dir"
}

# A genuine linked worktree - the shape bin/fm-spawn.sh hands a crewmate.
make_worktree_fixture() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/plainenglish-test-branch
  : > "$dir/AGENTS.md"
  install_hook "$dir"
}

# Run a home's hook with the event payload on stdin, setting OUT and STATUS.
# Both are globals because a command substitution would run the hook in a
# subshell and lose the exit code this suite is mostly about.
OUT=""
STATUS=0
run_hook() {  # <home-dir> [KEY=VALUE ...]
  local dir=$1
  shift
  set +e
  OUT=$(printf '%s' "$PAYLOAD" | env "$@" "$dir/bin/fm-plainenglish-hook.sh" 2>/dev/null)
  STATUS=$?
  set -e
}

PRIMARY="$TMP_ROOT/primary"
make_primary_fixture "$PRIMARY"

test_reminder_reaches_a_primary_turn() {
  local lines
  run_hook "$PRIMARY"
  expect_code 0 "$STATUS" "a primary home's reminder must exit 0"
  [ -n "$OUT" ] || fail "a primary home produced no reminder"
  lines=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
  [ "$lines" = 1 ] || fail "the reminder must be one line, got $lines"
  assert_contains "$OUT" "one paragraph" "the reminder must carry the paragraph rule"
  assert_contains "$OUT" "two sentences" "the reminder must carry the sentence rule"
  assert_contains "$OUT" "escalation" "the reminder must carry the escalation exception"
  assert_contains "$OUT" "/updatethecaptain" "the reminder must carry the worker-report exception"
  assert_contains "$OUT" "plainenglish" "the reminder must point at the skill that owns the contract"
  pass "the reminder reaches a primary turn as one line and exits 0"
}

# The reminder is read-only: a hook that writes into a captain's home would make
# every turn a state mutation.
test_reminder_writes_nothing() {
  local before after
  before=$(find "$PRIMARY/state" "$PRIMARY" -maxdepth 2 | LC_ALL=C sort)
  run_hook "$PRIMARY"
  after=$(find "$PRIMARY/state" "$PRIMARY" -maxdepth 2 | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "the hook changed the home's files"
  pass "the hook writes nothing into the home"
}

test_off_switch() {
  local config="$PRIMARY/config"
  mkdir -p "$config"

  printf 'off\n' > "$config/plainenglish"
  run_hook "$PRIMARY" "FM_CONFIG_OVERRIDE=$config"
  expect_code 0 "$STATUS" "the off switch must still exit 0"
  [ -z "$OUT" ] || fail "off must silence the reminder, got: $OUT"

  # Whitespace and case are stripped like every other scalar config item.
  printf '  OFF  \n' > "$config/plainenglish"
  run_hook "$PRIMARY" "FM_CONFIG_OVERRIDE=$config"
  [ -z "$OUT" ] || fail "a padded uppercase off must silence the reminder, got: $OUT"

  printf 'on\n' > "$config/plainenglish"
  run_hook "$PRIMARY" "FM_CONFIG_OVERRIDE=$config"
  [ -n "$OUT" ] || fail "on must keep the reminder"

  # Absence is the default, and a value nobody recognizes keeps the default
  # rather than turning the reminder off by accident.
  : > "$config/plainenglish"
  run_hook "$PRIMARY" "FM_CONFIG_OVERRIDE=$config"
  [ -n "$OUT" ] || fail "an empty config file must keep the reminder"
  printf 'quiet\n' > "$config/plainenglish"
  run_hook "$PRIMARY" "FM_CONFIG_OVERRIDE=$config"
  [ -n "$OUT" ] || fail "an unrecognized value must keep the reminder"
  rm -f "$config/plainenglish"
  run_hook "$PRIMARY" "FM_CONFIG_OVERRIDE=$config"
  [ -n "$OUT" ] || fail "an absent config file must keep the reminder"

  pass "config/plainenglish=off silences the reminder and every other value keeps it"
}

# Away mode is the case where an UNMARKED line is the hazard. The sub-supervisor
# daemon delivers its marked away-supervisor messages into the primary's pane,
# which is a prompt submission, so this hook fires on that turn; anything
# unmarked it printed would read as the captain returning and drop the fleet out
# of supervision. The marked message is built by the protocol's own owner rather
# than hand-written so the case cannot drift from the real wire form.
test_silent_while_away() {
  local marked payload
  # shellcheck source=bin/fm-operational-input.sh
  . "$ROOT/bin/fm-operational-input.sh"
  fm_operational_input_encode away-supervisor \
    'Supervisor escalate (1 event): a worker is waiting on a decision.' marked ||
    fail "could not build a marked away-supervisor message"
  payload=$(jq -nc --arg prompt "$marked" \
    '{session_id:"s1",hook_event_name:"UserPromptSubmit",prompt:$prompt}')

  run_away_hook() {
    set +e
    OUT=$(printf '%s' "$payload" | "$PRIMARY/bin/fm-plainenglish-hook.sh" 2>/dev/null)
    STATUS=$?
    set -e
  }

  : > "$PRIMARY/state/.afk"
  run_away_hook
  expect_code 0 "$STATUS" "an away-mode turn must exit 0"
  [ -z "$OUT" ] || fail "away mode must add nothing unmarked to the turn, got: $OUT"

  # Scoped to away mode, not permanent: the same daemon-shaped turn reminds again
  # once the flag is gone.
  rm -f "$PRIMARY/state/.afk"
  run_away_hook
  expect_code 0 "$STATUS" "the turn after away mode must exit 0"
  [ -n "$OUT" ] || fail "the reminder must return once away mode ends"

  pass "the reminder is silent while away mode is active and returns after it"
}

test_inert_outside_a_primary_home() {
  local worktree="$TMP_ROOT/crew-worktree"
  make_worktree_fixture "$TMP_ROOT/crew-base" "$worktree"
  run_hook "$worktree"
  expect_code 0 "$STATUS" "a crewmate worktree must exit 0"
  [ -z "$OUT" ] || fail "a crewmate worktree must see no reminder, got: $OUT"

  # A secondmate home is a marked linked worktree that still operates a fleet,
  # so it keeps the reminder its own captain-facing reports need.
  printf 'sm-plainenglish-1\n' > "$worktree/.fm-secondmate-home"
  run_hook "$worktree"
  [ -n "$OUT" ] || fail "a marked secondmate home must keep the reminder"
  rm -f "$worktree/.fm-secondmate-home"

  # A home with no state directory is not a firstmate home this hook knows.
  rm -rf "$worktree/state"
  run_hook "$worktree"
  [ -z "$OUT" ] || fail "a home with no durable state must see no reminder, got: $OUT"

  pass "the reminder is inert in a crewmate worktree and live in a secondmate home"
}

test_inert_for_a_gate_agent() {
  set +e
  OUT=$(printf '%s' "$PAYLOAD" | env -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE=1 \
    "$PRIMARY/bin/fm-plainenglish-hook.sh" 2>/dev/null)
  STATUS=$?
  set -e
  expect_code 0 "$STATUS" "a gate agent must exit 0"
  [ -z "$OUT" ] || fail "a no-mistakes gate agent must see no reminder, got: $OUT"
  pass "the reminder is inert for a no-mistakes gate agent"
}

test_transport_failures_stay_silent_and_zero() {
  # No payload at all: the hook needs nothing from stdin, so it still reminds.
  set +e
  OUT=$("$PRIMARY/bin/fm-plainenglish-hook.sh" </dev/null 2>/dev/null)
  STATUS=$?
  set -e
  expect_code 0 "$STATUS" "an empty payload must exit 0"
  [ -n "$OUT" ] || fail "an empty payload must still produce the reminder"

  # A payload that is not the expected shape changes nothing either.
  set +e
  OUT=$(printf 'not json at all' | "$PRIMARY/bin/fm-plainenglish-hook.sh" 2>/dev/null)
  STATUS=$?
  set -e
  expect_code 0 "$STATUS" "a malformed payload must exit 0"
  [ -n "$OUT" ] || fail "a malformed payload must still produce the reminder"

  pass "the hook ignores the payload shape and exits 0 either way"
}

# The registration, not the script, is what guarantees a captain's turn survives
# a broken hook. Each case replaces the script with a specific failure and runs
# the tracked command string exactly as Claude would.
test_broken_hook_cannot_block_a_turn() {
  local cmd dir saboteur
  cmd=$(jq -r '.hooks.UserPromptSubmit[].hooks[].command' "$ROOT/.claude/settings.json")
  [ -n "$cmd" ] || fail "no UserPromptSubmit entry is registered in .claude/settings.json"
  case "$cmd" in
    *fm-plainenglish-hook.sh*) : ;;
    *) fail "the registered UserPromptSubmit entry does not invoke fm-plainenglish-hook.sh: $cmd" ;;
  esac

  dir="$TMP_ROOT/sabotage"
  make_primary_fixture "$dir"
  saboteur="$dir/bin/fm-plainenglish-hook.sh"

  run_registered() {
    set +e
    OUT=$(printf '%s' "$PAYLOAD" | env CLAUDE_PROJECT_DIR="$dir" bash -c "$cmd" 2>/dev/null)
    STATUS=$?
    set -e
  }

  # Unparseable source: bash exits 2, the one code that would erase the prompt.
  printf '#!/usr/bin/env bash\nif [ then fi done )\n' > "$saboteur"
  chmod +x "$saboteur"
  run_registered
  expect_code 0 "$STATUS" "a syntax-broken hook must not block the turn"

  # A hook that deliberately returns the blocking code.
  printf '#!/usr/bin/env bash\necho boom >&2\nexit 2\n' > "$saboteur"
  chmod +x "$saboteur"
  run_registered
  expect_code 0 "$STATUS" "a hook that exits 2 must not block the turn"

  # A half-installed home where the script is missing entirely.
  rm -f "$saboteur"
  run_registered
  expect_code 0 "$STATUS" "a missing hook script must not block the turn"

  # And the intact script through the same registered path still reminds.
  cp "$ROOT/bin/fm-plainenglish-hook.sh" "$saboteur"
  chmod +x "$saboteur"
  run_registered
  expect_code 0 "$STATUS" "the intact hook must exit 0 through the registration"
  assert_contains "$OUT" "two sentences" "the intact hook must remind through the registration"

  pass "the registered command survives a syntax error, an exit 2, and a missing script"
}

test_reminder_reaches_a_primary_turn
test_reminder_writes_nothing
test_off_switch
test_silent_while_away
test_inert_outside_a_primary_home
test_inert_for_a_gate_agent
test_transport_failures_stay_silent_and_zero
test_broken_hook_cannot_block_a_turn
