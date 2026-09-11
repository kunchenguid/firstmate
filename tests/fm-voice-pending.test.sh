#!/usr/bin/env bash
# tests/fm-voice-pending.test.sh - the Claude primary's tracked UserPromptSubmit
# hook presents pending captain voice notes, read-only, at the start of a
# captain-message turn. Portable tests/ regression driving the real tracked
# command from .claude/settings.json the way Claude Code would: CLAUDE_PROJECT_DIR
# set to a primary-shaped checkout, a Claude-shaped payload on stdin, and the
# hook fired as a child of a fake harness (a bash symlink named "claude") whose
# pid holds the fixture home's session lock, the way the sibling Claude hook
# tests establish the lock-owning session. The incident this pins: on
# 2026-09-10 a captain text message started a turn that never ran the drain, so
# eleven queued spoken turns were never seen. The presenter must print the same
# VOICE section the drain prints, it must change nothing - the queue stays
# byte-identical and state/ gains no file - and it must stay silent in a
# session that does not own the home's lock.
# shellcheck disable=SC2016 # single quotes are deliberate: $$ and $FM_* expand inside the fake harness child
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-voice-pending-tests)
SETTINGS="$ROOT/.claude/settings.json"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

VOICE_ID='vc-9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'
VOICE_KEY="inbox:$VOICE_ID"
TYPED_KEY='inbox:1757000000-typed1'
CLAUDE_PAYLOAD='{"session_id":"sess-claude","hook_event_name":"UserPromptSubmit","prompt":"what is the status?"}'

command -v jq >/dev/null 2>&1 || fail "test host must provide jq"

# The hook resolves its own root from its location, so each scenario carries a
# copy of the presenter and the libraries it sources under its own bin/.
install_presenter() {  # <dir>
  local script
  mkdir -p "$1/bin"
  for script in fm-voice-pending.sh fm-primary-scope-lib.sh \
      fm-session-lock-lib.sh fm-cursor-lib.sh fm-wake-lib.sh; do
    cp "$ROOT/bin/$script" "$1/bin/$script"
  done
  chmod +x "$1/bin/fm-voice-pending.sh"
}

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/.
make_primary_dir() {  # <dir>
  mkdir -p "$1"
  git init -q "$1"
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --allow-empty -m init
  : > "$1/AGENTS.md"
  install_presenter "$1"
}

# A genuine linked git worktree, the shape every crew and scout task worktree
# on firstmate itself has.
make_crewmate_worktree_dir() {  # <base> <dir>
  fm_git_worktree "$1" "$2" fm/voice-pending-test-branch
  : > "$2/AGENTS.md"
  install_presenter "$2"
}

# Run the tracked UserPromptSubmit command the way Claude Code would: as a child
# of the fake harness, which first writes its own pid into <state>/.lock so the
# hook fires inside the session that owns the home's fleet lock. With keep-lock
# the harness leaves whatever <state>/.lock already names in place, so the hook
# fires inside a session that does not own the lock. The harness runs the hook
# as a child and exits with its status instead of letting bash exec the hook
# into the harness pid, which would leave the lock naming a non-harness process.
# wake-helpers.sh exports FM_ROOT_OVERRIDE for the drain's tangle check; the
# hook must resolve its root from CLAUDE_PROJECT_DIR alone, as it does live.
run_hook() {  # <project-dir> <state> <payload> <stdout-file> <stderr-file> [keep-lock]
  local cmd
  cmd=$(jq -r '.hooks["UserPromptSubmit"][0].hooks[0].command' "$SETTINGS")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no UserPromptSubmit hook command in $SETTINGS"
  printf '%s' "$3" | env -u FM_ROOT_OVERRIDE -u FM_HOME -u GROK_AGENT -u GROK_HOOK_EVENT \
    CLAUDE_PROJECT_DIR="$1" FM_STATE_OVERRIDE="$2" FM_HOOK_COMMAND="$cmd" FM_HARNESS_LOCK="${6:-own}" \
    "$FAKE_CLAUDE" -c '
      [ "$FM_HARNESS_LOCK" = keep-lock ] || printf "%s\n" "$$" > "$FM_STATE_OVERRIDE/.lock"
      sh -c "$FM_HOOK_COMMAND"
      exit $?
    ' > "$4" 2> "$5"
}

# Every file under <state> with its content hash, except the session lock the
# fake harness itself writes, so a test can prove the hook neither created nor
# modified anything there, the recovery marker included.
state_manifest() {  # <state>
  (cd "$1" && find . -type f ! -path ./.lock | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(hash_text "$(cat "$f")")"
  done)
}

assert_silent() {  # <case-name> <status> <stdout-file> <stderr-file>
  expect_code 0 "$2" "$1: hook exit status"
  [ ! -s "$3" ] || fail "$1: hook printed to stdout: $(cat "$3")"
  [ ! -s "$4" ] || fail "$1: hook printed to stderr: $(cat "$4")"
}

test_voice_note_behind_ordinary_wake_is_presented_alone_and_read_only() {
  local dir state out err status before_queue before_manifest drain_out drain_err
  dir="$TMP_ROOT/primary-voice"
  make_primary_dir "$dir"
  state="$TMP_ROOT/primary-voice-state"
  mkdir -p "$state"
  out="$dir/hook.out"; err="$dir/hook.err"
  append_wake "$state" check "$TYPED_KEY" "check: captain inbox note 1757000000-typed1 - typed note" \
    || fail "ordinary check wake append failed"
  append_wake "$state" check "$VOICE_KEY" "check: captain inbox note $VOICE_ID - I hear you" \
    || fail "voice check wake append failed"
  before_queue="$dir/queue.before"
  cp "$state/.wake-queue" "$before_queue"
  before_manifest=$(state_manifest "$state")

  run_hook "$dir" "$state" "$CLAUDE_PAYLOAD" "$out" "$err"; status=$?
  expect_code 0 "$status" "primary-voice: hook exit status"
  [ ! -s "$err" ] || fail "primary-voice: hook printed to stderr: $(cat "$err")"
  case "$(sed -n 1p "$out")" in
    "VOICE: the captain spoke - 1 voice note(s) below;"*) ;;
    *) fail "primary-voice: first line is not the VOICE heading for one note: $(cat "$out")" ;;
  esac
  [ "$(awk -F '\t' 'NR == 2 && NF == 5 { print $4 }' "$out")" = "$VOICE_KEY" ] \
    || fail "primary-voice: second line is not the voice row: $(cat "$out")"
  [ "$(wc -l < "$out" | tr -d ' ')" = 2 ] || fail "primary-voice: more than the heading and the voice row was printed: $(cat "$out")"
  if grep -F -- "$TYPED_KEY" "$out" >/dev/null; then
    fail "primary-voice: the ordinary wake was presented by the voice hook: $(cat "$out")"
  fi

  cmp -s "$before_queue" "$state/.wake-queue" || fail "primary-voice: the hook changed state/.wake-queue"
  [ "$(state_manifest "$state")" = "$before_manifest" ] \
    || fail "primary-voice: the hook created or changed a file under state/ (a claim, the recovery marker, or the queue lock): $(ls -A "$state")"
  assert_absent "$state/.main-eligible-rows" "primary-voice: the hook claimed rows"
  assert_absent "$state/.wake-queue.lock" "primary-voice: the hook took the queue lock"

  # The same rows the drain presents: run the real drain over the untouched
  # queue and compare its VOICE section with what the hook printed.
  drain_out="$dir/drain.out"; drain_err="$dir/drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" || fail "drain failed: $(cat "$drain_err")"
  cmp -s "$out" <(sed '/^OTHER WAKES/,$d' "$drain_out") \
    || fail "primary-voice: hook output differs from the drain's VOICE section: $(cat "$out") vs $(cat "$drain_out")"
  pass "a pending voice note behind an ordinary wake is presented alone under VOICE, read-only, matching the drain"
}

test_ordinary_wake_alone_prints_nothing() {
  local dir state out err status
  dir="$TMP_ROOT/primary-typed"
  make_primary_dir "$dir"
  state="$TMP_ROOT/primary-typed-state"
  mkdir -p "$state"
  out="$dir/hook.out"; err="$dir/hook.err"
  append_wake "$state" check "$TYPED_KEY" "check: captain inbox note 1757000000-typed1 - typed note" \
    || fail "ordinary check wake append failed"
  run_hook "$dir" "$state" "$CLAUDE_PAYLOAD" "$out" "$err"; status=$?
  assert_silent primary-typed "$status" "$out" "$err"
  pass "an ordinary wake alone prints nothing"
}

test_crewmate_worktree_stays_inert() {
  local base dir state out err status
  base="$TMP_ROOT/crew-base"
  dir="$TMP_ROOT/crew-worktree"
  make_crewmate_worktree_dir "$base" "$dir"
  state="$TMP_ROOT/crew-worktree-state"
  mkdir -p "$state"
  out="$TMP_ROOT/crew-hook.out"; err="$TMP_ROOT/crew-hook.err"
  append_wake "$state" check "$VOICE_KEY" "check: captain inbox note $VOICE_ID - What?" \
    || fail "voice check wake append failed"
  run_hook "$dir" "$state" "$CLAUDE_PAYLOAD" "$out" "$err"; status=$?
  assert_silent crew-worktree "$status" "$out" "$err"
  pass "a child crew worktree stays inert even with a voice note pending"
}

test_lock_owned_by_another_live_session_prints_nothing() {
  local dir state out err status other owner_after before_queue
  dir="$TMP_ROOT/primary-other-lock"
  make_primary_dir "$dir"
  state="$TMP_ROOT/primary-other-lock-state"
  mkdir -p "$state"
  out="$dir/hook.out"; err="$dir/hook.err"
  append_wake "$state" check "$VOICE_KEY" "check: captain inbox note $VOICE_ID - I hear you" \
    || fail "voice check wake append failed"
  before_queue="$dir/queue.before"
  cp "$state/.wake-queue" "$before_queue"
  # Another live harness owns the home: the second session bin/fm-lock.sh
  # refuses. The trailing no-op keeps that harness process alive instead of
  # letting bash exec the sleep into a non-harness process.
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$state/.lock"
  run_hook "$dir" "$state" "$CLAUDE_PAYLOAD" "$out" "$err" keep-lock; status=$?
  owner_after=$(cat "$state/.lock")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  assert_silent primary-other-lock "$status" "$out" "$err"
  [ "$owner_after" = "$other" ] || fail "primary-other-lock: the hook replaced the other session's lock: expected $other, got $owner_after"
  cmp -s "$before_queue" "$state/.wake-queue" || fail "primary-other-lock: the hook changed state/.wake-queue"
  pass "a home whose fleet lock another live session owns prints nothing even with a voice note pending"
}

test_missing_queue_is_silent() {
  local dir state out err status
  dir="$TMP_ROOT/primary-noqueue"
  make_primary_dir "$dir"
  state="$TMP_ROOT/primary-noqueue-state"
  mkdir -p "$state"
  out="$dir/hook.out"; err="$dir/hook.err"
  run_hook "$dir" "$state" "$CLAUDE_PAYLOAD" "$out" "$err"; status=$?
  assert_silent primary-noqueue "$status" "$out" "$err"
  assert_absent "$state/.wake-queue" "primary-noqueue: the hook created the queue"
  pass "a missing queue file exits 0 with no output"
}

test_voice_note_behind_ordinary_wake_is_presented_alone_and_read_only
test_ordinary_wake_alone_prints_nothing
test_crewmate_worktree_stays_inert
test_lock_owned_by_another_live_session_prints_nothing
test_missing_queue_is_silent
