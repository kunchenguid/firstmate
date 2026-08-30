#!/usr/bin/env bash
# tests/fm-brief-done-signal.test.sh - guard for the terminal-status
# reinforcement in the briefs scaffolded by bin/fm-brief.sh.
#
# Observed live on 2026-07-28: four consecutive crewmates finished their work,
# wrote their deliverable, printed a closing summary to the pane, and stopped -
# none appended the mandatory `done:` line. With no terminal status the only
# evidence firstmate has is an idle pane whose hash stopped changing, which is
# by design indistinguishable from a wedge (bin/fm-watch.sh:913-927 says so in
# as many words), so the watcher wedge-escalates a finished task forever.
#
# The `done:` append is the one step of the brief with no deterministic
# enforcement: the first action and the worktree-isolation check are both hard
# STOP gates, the last action was a bare instruction in a list. This test pins
# the reinforcement that states the consequence at the point of the risk.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-done-signal-tests)
mkdir -p "$TMP_ROOT"

# scaffold <id> <flag...>: run fm-brief.sh against a throwaway data/state pair
# and echo the path of the brief it wrote.
scaffold() {  # <id> [args...] -> brief path
  local id=$1
  shift
  FM_DATA_OVERRIDE="$TMP_ROOT/data" FM_STATE_OVERRIDE="$TMP_ROOT/state" \
    "$ROOT/bin/fm-brief.sh" "$id" "$@" >/dev/null \
    || fail "fm-brief.sh failed to scaffold $id"
  printf '%s\n' "$TMP_ROOT/data/$id/brief.md"
}

# assert_done_reinforcement <brief> <label>: the brief must name the pane
# summary as a non-signal, name the consequence, and place the append last.
assert_done_reinforcement() {  # <brief> <label>
  local brief=$1 label=$2
  assert_grep 'pane summary is NOT a completion signal' "$brief" \
    "$label brief must state that a pane summary does not signal completion"
  assert_grep 'possible wedge' "$brief" \
    "$label brief must state the consequence of a missing terminal status: escalation as a possible wedge"
  assert_grep "task's last action" "$brief" \
    "$label brief must place the status append as the task's last action"
  pass "$label brief: terminal-status append is reinforced at the status protocol"
}

test_scout_brief_reinforces_the_done_append() {
  local brief
  brief=$(scaffold scout-task alpha --scout)
  assert_done_reinforcement "$brief" scout
}

# The ship half of fm-brief.sh builds its delivery-mode Definition of done with
# `DOD=$(cat <<EOF ... EOF\n)`, which bash 3.2 (the system bash on macOS) cannot
# parse - a heredoc inside a command substitution. That is pre-existing and
# equally true at HEAD; the scout half still runs because bash parses a script
# incrementally and scout exits before reaching it. Report the skip rather than
# failing a developer's local run on a limitation this change did not introduce.
test_ship_brief_reinforces_the_done_append() {
  local brief
  if ! bash -n "$ROOT/bin/fm-brief.sh" 2>/dev/null; then
    pass "skip: this bash ($BASH_VERSION) cannot parse fm-brief.sh's ship half (heredoc in command substitution)"
    return 0
  fi
  brief=$(scaffold ship-task alpha)
  assert_done_reinforcement "$brief" ship
}

# Static companion, so the ship scaffold stays covered on a bash that cannot run
# it: both scaffolds carry rule 4, and each copy must carry the reinforcement.
test_both_scaffolds_carry_the_reinforcement() {
  local rules reinforcements
  rules=$(grep -c 'Report status by appending one line' "$ROOT/bin/fm-brief.sh")
  reinforcements=$(grep -c 'pane summary is NOT a completion signal' "$ROOT/bin/fm-brief.sh")
  [ "$reinforcements" -eq "$rules" ] || fail \
    "every status-protocol block in bin/fm-brief.sh must carry the terminal-status reinforcement (blocks: $rules, reinforced: $reinforcements)"
  [ "$rules" -ge 2 ] || fail \
    "expected a status-protocol block in both the scout and ship scaffolds of bin/fm-brief.sh, found $rules"
  pass "bin/fm-brief.sh: all $rules status-protocol blocks reinforce the terminal-status append"
}

test_scout_brief_reinforces_the_done_append
test_ship_brief_reinforces_the_done_append
test_both_scaffolds_carry_the_reinforcement
