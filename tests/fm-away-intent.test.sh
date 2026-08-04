#!/usr/bin/env bash
# tests/fm-away-intent.test.sh - the deterministic away/return intent resolver
# (bin/fm-away-intent.sh) and the canonical activation it drives
# (bin/fm-away-session.sh).
#
# Coverage:
#   - the away, return and must-not-fire corpora, including third-person,
#     reported speech, and continued phrases such as "I'm back to reviewing"
#   - each pre-pattern refusal, every one paired with a NEGATIVE CONTROL: the
#     same sentence with only the refusing property removed must classify, so a
#     refusal is never confused with the pattern simply not matching
#   - canonical activation is durable, idempotent, and opens exactly one session
#     however many times the phrase is repeated
#   - restart survival: a fresh process reads the same away state, the same
#     session id, and a queued wake that was never drained
#   - the return intent leaves away mode through the existing catch-up gate
#   - the Claude prompt hook is default-off, refuses a non-primary checkout,
#     refuses operational input, never blocks a prompt, and activates only when
#     all three gates pass
#
# The canonical action runs with FM_AWAY_LAUNCH_MODE=start-native so no daemon
# terminal is created here; the terminal topology itself is owned by
# tests/fm-afk-launch.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTENT="$ROOT/bin/fm-away-intent.sh"
SESSION="$ROOT/bin/fm-away-session.sh"
TMP_ROOT=$(fm_test_tmproot fm-away-intent-tests)
trap fm_test_cleanup EXIT

# new_home <name>: an isolated FM_HOME with state/, data/ and config/.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

classify() {  # <home> <text>
  FM_HOME=$1 FM_STATE_OVERRIDE="$1/state" "$INTENT" classify --text "$2"
}

expect_class() {  # <home> <expected> <text>
  local got
  got=$(classify "$1" "$3")
  [ "$got" = "$2" ] || fail "classify '$3' -> $got, expected $2"
}

away_start() {  # <home> [extra args...]
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_AWAY_LAUNCH_MODE=start-native \
    "$SESSION" "$@"
}

# --- corpora ----------------------------------------------------------------

test_away_corpus() {
  local home t
  home=$(new_home away-corpus)
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    expect_class "$home" away "$t"
  done <<'EOF'
I have to step away for a while
I have to step away for a while, keep the PR moving
afk
afk for 2 hours
I'm stepping out
I am stepping away
I need to step away
I gotta head out
I am going to step away
I'm going afk
going afk
Stepping away for lunch
I'll be back later
I'm afk
I'm stepping out and I am back in ten minutes
EOF
  pass "every away phrasing in the corpus resolves to away intent"
}

test_return_corpus() {
  local home t
  home=$(new_home return-corpus)
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    expect_class "$home" return "$t"
  done <<'EOF'
I'm back
I am back
back
back now
back again
I'm back!
I am back, what's the status?
I've returned
EOF
  pass "every return phrasing in the corpus resolves to return intent"
}

test_must_not_fire_corpus() {
  local home t
  home=$(new_home none-corpus)
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    expect_class "$home" none "$t"
  done <<'EOF'
the worker stepped away from the plan
I think the worker stepped away
he is going afk
she stepped out for a moment
I am back to the drawing board
we are back on track
I'm back to reviewing the diff
did the daemon step out?
please document the afk skill
the captain said I have to step away, but did they?
EOF
  pass "third-person, reported and continued phrasings never resolve to intent"
}

# --- refusals, each with its negative control -------------------------------

test_operational_input_refused_with_control() {
  local home marked plain
  home=$(new_home operational-refusal)
  plain="I have to step away for a while"
  # The invisible separator plus FIRSTMATE_OP header is how firstmate's own
  # machine traffic is marked; a human never types it.
  marked=$(printf '\xE2\x81\xA3FIRSTMATE_OP: v1 away-supervisor: %s' "$plain")

  expect_class "$home" none "$marked"
  # NEGATIVE CONTROL: the identical sentence without the marker MUST classify,
  # so the refusal above is the marker doing the work, not the wording.
  expect_class "$home" away "$plain"
  pass "operational input is refused while the same sentence unmarked still resolves"
}

test_length_cap_refused_with_control() {
  local home filler at_cap over_cap
  home=$(new_home length-refusal)
  # "I have to step away" is 5 words; pad to exactly the cap and one past it.
  filler=$(awk 'BEGIN { for (i = 0; i < 55; i++) printf "word " }')
  at_cap="I have to step away $filler"
  over_cap="I have to step away $filler extra"

  expect_class "$home" away "$at_cap"
  expect_class "$home" none "$over_cap"
  pass "a message one word over the cap is refused while the same message at the cap resolves"
}

test_code_fence_refused_with_control() {
  local home plain fenced
  home=$(new_home fence-refusal)
  plain="afk"
  # shellcheck disable=SC2016 # A literal code fence, not an expansion.
  fenced=$(printf '```\nafk\n```')
  expect_class "$home" none "$fenced"
  expect_class "$home" away "$plain"
  pass "fenced content is refused while the same text unfenced resolves"
}

test_ambiguous_message_is_never_guessed() {
  local home
  home=$(new_home ambiguous)
  # Both an away and a present-tense return pattern fire; guessing either way
  # would be wrong. ("I am back in ten minutes" is not ambiguous - it is a
  # future return, so it stays a departure; the away corpus pins that.)
  expect_class "$home" none "I'm afk but I am back now"
  pass "a message matching both away and return resolves to none rather than a guess"
}

# --- canonical activation ---------------------------------------------------

test_activation_is_durable_and_idempotent() {
  local home first second activations sessions
  home=$(new_home activation)

  first=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_AWAY_LAUNCH_MODE=start-native \
    "$INTENT" apply --text "I have to step away for a while")
  [ "$first" = away ] || fail "apply did not report an away activation: $first"
  [ -e "$home/state/.afk" ] || fail "activation left no durable away flag"
  [ -f "$home/state/.away-session" ] || fail "activation left no durable session record"

  # Repeating the phrase, twice more, must stay one session.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_AWAY_LAUNCH_MODE=start-native \
    "$INTENT" apply --text "I have to step away for a while" >/dev/null
  second=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_AWAY_LAUNCH_MODE=start-native \
    "$INTENT" apply --text "afk")
  [ "$second" = away ] || fail "a repeated phrase did not stay an away activation"

  sessions=$(find "$home/state/away" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$sessions" = 1 ] || fail "repeating the phrase opened $sessions sessions, expected 1"
  activations=$(away_start "$home" ledger activation | grep -c . || true)
  [ "$activations" = 1 ] || fail "repeating the phrase logged $activations activations, expected 1"

  pass "repeating the phrase is harmless: one durable activation, one session"
}

test_state_and_wakes_survive_restart() {
  local home id_before id_after queued
  home=$(new_home restart)
  away_start "$home" start --intent "afk" >/dev/null
  id_before=$(away_start "$home" id)
  [ -n "$id_before" ] || fail "no session id was recorded"

  # An actionable wake that nothing has drained yet.
  printf '%s\t1\tsignal\tfmtest\t%s/state/fmtest.status\n' "$(date +%s)" "$home" \
    >> "$home/state/.wake-queue"

  # A restart is a new process reading only durable state.
  id_after=$(away_start "$home" id)
  [ "$id_after" = "$id_before" ] || fail "session id changed across a restart: $id_before -> $id_after"
  [ -e "$home/state/.afk" ] || fail "the away flag did not survive a restart"
  queued=$(grep -c . "$home/state/.wake-queue")
  [ "$queued" = 1 ] || fail "the queued wake did not survive a restart"

  pass "restart loses neither away state nor an undrained actionable wake"
}

test_return_intent_leaves_away_mode() {
  local home out
  home=$(new_home return-intent)
  away_start "$home" start --intent "afk" >/dev/null
  [ -e "$home/state/.afk" ] || fail "setup did not enter away mode"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_AWAY_LAUNCH_MODE=start-native \
    "$INTENT" apply --text "I'm back" 2>&1) || fail "return intent failed: $out"
  [ ! -e "$home/state/.afk" ] || fail "return intent left the away flag in place"
  [ ! -f "$home/state/.away-session" ] || fail "return intent left the session record open"
  # The ledger survives the transition: it is evidence, not runtime state.
  find "$home/state/away" -name ledger | grep -q . || fail "the session ledger was destroyed on return"

  pass "return intent leaves away mode through the existing gate and keeps the evidence"
}

# --- Claude prompt hook -----------------------------------------------------

# hook_home <name>: an FM_HOME that is ALSO a plain git checkout shaped like a
# primary firstmate root, which is what the hook's scope gate requires.
hook_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/bin"
  git init -q -b main "$home"
  : > "$home/AGENTS.md"
  printf '%s\n' "$home"
}

run_hook() {  # <home> <prompt>
  printf '{"prompt":%s}' "$(printf '%s' "$2" | jq -Rs .)" \
    | FM_HOME="$1" FM_ROOT_OVERRIDE="$1" FM_STATE_OVERRIDE="$1/state" \
      FM_CONFIG_OVERRIDE="$1/config" FM_AWAY_LAUNCH_MODE=start-native \
      "$INTENT" hook --claude
}

test_hook_is_default_off() {
  local home out rc
  home=$(hook_home hook-default-off)
  out=$(run_hook "$home" "I have to step away for a while"); rc=$?
  [ "$rc" -eq 0 ] || fail "the hook exited $rc instead of never blocking a prompt"
  [ -z "$out" ] || fail "the default-off hook produced output: $out"
  [ ! -e "$home/state/.afk" ] || fail "the default-off hook activated away mode"
  pass "the prompt hook does nothing until the home opts in"
}

test_hook_activates_when_enabled() {
  local home out rc
  home=$(hook_home hook-enabled)
  : > "$home/config/away-intent"
  out=$(run_hook "$home" "I have to step away for a while"); rc=$?
  [ "$rc" -eq 0 ] || fail "the hook exited $rc instead of 0"
  [ -e "$home/state/.afk" ] || fail "the enabled hook did not activate away mode"
  case "$out" in *"Away mode is active"*) : ;; *) fail "the hook printed no confirmation: $out" ;; esac
  pass "the prompt hook resolves a captain's own words into the canonical action"
}

test_hook_ignores_a_non_primary_checkout() {
  local home out
  # A linked task worktree is a crewmate's pane, not the captain's session.
  home="$TMP_ROOT/hook-worktree"
  mkdir -p "$home/state" "$home/config" "$home/bin"
  : > "$home/AGENTS.md"
  local origin="$TMP_ROOT/hook-worktree-origin"
  git init -q -b main "$origin"
  git -C "$origin" commit -q --allow-empty -m init
  rm -rf "$home/.git"
  git -C "$origin" worktree add -q --detach "$home/checkout"
  mkdir -p "$home/checkout/state" "$home/checkout/config" "$home/checkout/bin"
  : > "$home/checkout/AGENTS.md"
  : > "$home/checkout/config/away-intent"

  out=$(run_hook "$home/checkout" "I have to step away for a while")
  [ -z "$out" ] || fail "the hook acted from a linked task worktree: $out"
  [ ! -e "$home/checkout/state/.afk" ] || fail "the hook activated away mode from a worker's worktree"
  pass "the prompt hook refuses to act from a crewmate's linked worktree"
}

test_hook_ignores_operational_input() {
  local home out marked
  home=$(hook_home hook-operational)
  : > "$home/config/away-intent"
  marked=$(printf '\xE2\x81\xA3FIRSTMATE_OP: v1 away-supervisor: I have to step away for a while')
  out=$(run_hook "$home" "$marked")
  [ -z "$out" ] || fail "the hook acted on operational input: $out"
  [ ! -e "$home/state/.afk" ] || fail "operational input activated away mode through the hook"
  # NEGATIVE CONTROL: the same home, the same words, unmarked, does activate.
  run_hook "$home" "I have to step away for a while" >/dev/null
  [ -e "$home/state/.afk" ] || fail "the control prompt failed to activate, so the refusal proves nothing"
  pass "the prompt hook refuses machine traffic while the same words from the captain still work"
}

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_away_corpus
test_return_corpus
test_must_not_fire_corpus
test_operational_input_refused_with_control
test_length_cap_refused_with_control
test_code_fence_refused_with_control
test_ambiguous_message_is_never_guessed
test_activation_is_durable_and_idempotent
test_state_and_wakes_survive_restart
test_return_intent_leaves_away_mode
test_hook_is_default_off
test_hook_activates_when_enabled
test_hook_ignores_a_non_primary_checkout
test_hook_ignores_operational_input

echo "# fm-away-intent.test.sh: all assertions passed"
