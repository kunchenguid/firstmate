#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the inside-a-turn progress
# signal that bin/fm-spawn.sh wires onto PreToolUse and PostToolUse.
#
# Why it must be live: the verdict comes from something the vendor emits - that
# Claude Code fires a tool-boundary hook at all, and fires it INSIDE the turn
# rather than only at its end. A stub can only confirm the assumption already
# written into the stub, and the portable regression
# (tests/fm-busy-adapter-wiring.test.sh) deliberately drives the generated hook
# command itself, so it pins the command and not the harness that must run it.
# What rides on it: bin/fm-watch.sh bounds a busy pane on the age of the newest
# observed activity (FM_BUSY_TURN_MAX_SECS). Claude's only end-of-turn signal is
# Stop, and an autonomous crewmate ends no turn until the whole job is done, so
# without a tool-boundary signal that bound crosses while the crew is healthy and
# then re-escalates it as a possible wedge every FM_STALE_ESCALATE_SECS.
#
# The whole wiring under test is the REAL one: a real bin/fm-spawn.sh run against
# a fake tmux pane writes the settings and arms the real busy generation, then
# real Claude runs in that worktree. Only the pane is faked; no live fleet home,
# worktree, or session is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_CLAUDE_TOOL_PROGRESS_LIVE_E2E claude jq perl

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_VERSION=$(claude --version)
ID=claude-tool-progress
# Long enough that the tool call's own window dominates process startup on a
# loaded runner, so the in-turn observation below is a real window rather than a
# race the test could win by accident.
PROBE_SLEEP=25

TMP_ROOT=$(fm_test_tmproot fm-claude-tool-progress-live)
LAB="$TMP_ROOT/lab"
HOME_DIR="$LAB/home"
PROJ="$LAB/project"
WT="$LAB/wt"
TRANSCRIPT="$LAB/claude.out"

CLAUDE_PID=
cleanup() {
  [ -z "$CLAUDE_PID" ] || kill "$CLAUDE_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$LAB"
FAKEBIN=$(make_spawn_fakebin "$LAB/fake" claude)
fm_test_spawn_home "$HOME_DIR" claude
fm_git_worktree "$PROJ" "$WT" wt-claude-tool-progress
fm_test_spawn_brief "$HOME_DIR" "$ID"

SPAWN_OUT=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$ID" "$PROJ" --mode no-mistakes --yolo off) \
  || fail "claude spawn failed: $SPAWN_OUT"

STATE="$HOME_DIR/state"
SETTINGS="$WT/.claude/settings.local.json"
assert_present "$SETTINGS" "spawn did not write the claude hook settings"
jq -e '.hooks.PreToolUse and .hooks.PostToolUse' "$SETTINGS" >/dev/null \
  || fail "spawn did not wire the tool-boundary hooks"
assert_present "$STATE/$ID.busy-gen" "spawn did not arm a busy generation"
rm -f "$STATE/$ID.progress" "$STATE/$ID.turn-ended"

# The probe waits through perl rather than through `sleep`, because Claude Code
# blocks a foreground `sleep` outright and the run would then exercise no tool
# boundary at all (observed live, Claude Code 2.1.236).
PROMPT='Use the Bash tool exactly once to run this exact command, then reply with exactly DONE and stop: perl -e '"'"'sleep '"$PROBE_SLEEP"'; print "PROBE\n"'"'"'. Use no other tool and run no other command.'

(
  cd "$WT" || exit 1
  CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
    claude -p "$PROMPT" --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' \
    --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 &
CLAUDE_PID=$!

# The property under test is not "a marker appears eventually" - Stop would
# produce one of those too. It is that the marker appears WHILE the turn is
# still open, which is the only thing that keeps the busy-age bound fresh
# during a long turn. So the observation is taken before turn-ended exists.
# The loop ends on its two real conditions only - the turn closing, or the
# session exiting. A tick cap would just add a false negative that blames a
# vendor regression whenever the first boundary lands later than the cap.
IN_TURN=0
while :; do
  if [ -e "$STATE/$ID.progress" ] && [ ! -e "$STATE/$ID.turn-ended" ]; then
    IN_TURN=1
    break
  fi
  [ ! -e "$STATE/$ID.turn-ended" ] || break
  kill -0 "$CLAUDE_PID" 2>/dev/null || break
  sleep 0.5
done

wait "$CLAUDE_PID" || fail "credentialed Claude tool-progress session failed: $(tail -20 "$TRANSCRIPT")"
CLAUDE_PID=

# The streamed transcript is the only place a tool call is visible; `claude -p`
# alone prints the final assistant text, in which a model that ran nothing and a
# model that ran the probe both just say DONE.
grep -q '"name":"Bash"' "$TRANSCRIPT" \
  || fail "Claude $CLAUDE_VERSION never issued a tool call, so no tool boundary was exercised: $(tail -5 "$TRANSCRIPT")"
[ "$IN_TURN" = 1 ] \
  || fail "Claude $CLAUDE_VERSION fired no tool-boundary progress inside the open turn; the busy-age bound would age from Stop alone"
assert_present "$STATE/$ID.progress" "the progress marker did not survive the turn"
assert_present "$STATE/$ID.turn-ended" "Stop did not touch the turn-end notification marker"
[ ! "$STATE/$ID.progress" -nt "$STATE/$ID.turn-ended" ] \
  || fail "the progress marker was written after the turn ended, so it is not an inside-a-turn signal"

printf 'ok - Claude %s fires tool-boundary progress inside an open turn, so the busy-age bound ages from observed activity rather than from Stop\n' \
  "$CLAUDE_VERSION"
