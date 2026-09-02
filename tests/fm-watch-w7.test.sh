#!/usr/bin/env bash
# GATE w7 - away-mode escalates a wedged HERDR crewmate instead of dropping it.
#
# WHY THIS GATE HAD TO LAND IN THE SAME CHANGE as the watcher's sensor swap.
# AGENTS.md said so, and it was right: `window_for_task` enumerated
# `tmux list-windows -a` for `:fm-` names, and the stale recheck reads an empty
# result as "task torn down, nothing to escalate". A herdr pane id (`wZ:p1`)
# carries no task id at all - the old name-strip returned `p1` - so every marker
# filed for a herdr crewmate pointed at a task that does not exist. That path was
# DORMANT only because fm-watch could never emit a stale wake for a herdr pane.
# The moment it can, the away-mode daemon starts silently discarding exactly the
# wedges the captain went away trusting it to catch.
#
# THE MAPPING IS THE META, both ways, because that is the record fm-spawn writes
# and the one fm-send, fm-peek and the watcher already route on. The tmux
# enumeration stays as the fallback for a draining window whose meta this home
# does not hold.
#
# Mutation (LEDGER_MUTATE=1): report the wedged herdr agent as `working` - a
# correct daemon then clears the marker as a resumed crewmate and escalates
# nothing, so the escalation assertion fails. That proves the escalation comes
# from the routed busy read rather than from the marker merely being old.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# shellcheck disable=SC2034  # read by make_supercase in tests/wake-helpers.sh
TMP_ROOT=$(fm_test_tmproot fm-watch-w7)

# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"

WEDGED=idle
[ "${LEDGER_MUTATE:-}" = 1 ] && WEDGED=working

herdr_case() {  # <name> -> dir with both fakes
  local dir; dir=$(make_supercase "$1")
  fm_herdr_fake_server "$dir" >/dev/null
  printf '%s\n' "$dir"
}

write_meta() {  # <state> <id> <window> <mux>
  cat > "$1/$2.meta" <<META
window=$3
worktree=/wt
project=/p/demo
harness=claude
mux=$4
kind=ship
META
}

# The mapping, both directions, for a target with no id encoded in it.
test_the_meta_maps_a_herdr_pane_to_its_task_both_ways() {
  local dir state
  dir=$(herdr_case w7map); state="$dir/state"
  write_meta "$state" wedged-k3 wZ:p1 herdr
  [ "$(FM_STATE_OVERRIDE="$state" window_to_task wZ:p1)" = wedged-k3 ] \
    || fail "a herdr pane did not map back to its task through the meta"
  [ "$(FM_STATE_OVERRIDE="$state" window_for_task wedged-k3)" = wZ:p1 ] \
    || fail "a task did not map forward to its herdr pane through the meta"
  pass "w7: a herdr pane and its task map to each other through the meta"
}

test_a_persistent_wedge_on_herdr_escalates() {
  local dir state key
  dir=$(herdr_case w7wedge); state="$dir/state"
  write_meta "$state" pers-w7 wZ:p1 herdr
  printf 'working: building\n' > "$state/pers-w7.status"
  key=$(printf '%s' pers-w7 | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  PATH="$dir/fakebin:$PATH" AGENT_STATE="$WEDGED" FM_STATE_OVERRIDE="$state" \
    FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] \
    || fail "a persistent wedge on a herdr pane was dropped instead of escalated"
  grep -F 'wZ:p1' "$state/.subsuper-escalations" >/dev/null \
    || fail "the escalation does not name the herdr pane"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "the stale marker was not cleared after escalating"
  pass "w7: a wedged herdr crewmate is escalated, not silently dropped"
}

# The other direction: a crewmate that resumed must clear its marker quietly,
# and that decision has to be made with herdr verbs. A tmux capture-pane aimed
# at a pane id resolves to nothing, which reads as "not busy" and would escalate
# a perfectly healthy, working crewmate straight to the captain.
test_a_resumed_herdr_crewmate_clears_quietly() {
  local dir state key
  dir=$(herdr_case w7resumed); state="$dir/state"
  write_meta "$state" res-w7 wZ:p1 herdr
  printf 'working: building\n' > "$state/res-w7.status"
  key=$(printf '%s' res-w7 | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  PATH="$dir/fakebin:$PATH" AGENT_STATE=working FM_STATE_OVERRIDE="$state" \
    FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] && fail "a working herdr crewmate was escalated as a wedge"
  [ -e "$state/.subsuper-stale-$key" ] && fail "the resumed crewmate's marker was not cleared"
  pass "w7: a working herdr crewmate clears its marker without waking the captain"
}

# THE DRAIN. A pre-cutover window still maps and still escalates.
test_a_draining_tmux_window_still_escalates() {
  local dir state key
  dir=$(herdr_case w7drain); state="$dir/state"
  printf 'working: building\n' > "$state/pers-w8.status"
  printf 'idle prompt $\n' > "$dir/pane.txt"
  key=$(printf '%s' pers-w8 | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW='sess:fm-pers-w8' \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_STATE_OVERRIDE="$state" \
    FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] \
    || fail "a draining tmux window stopped escalating its wedge"
  pass "w7: a pre-cutover tmux window still escalates through the enumeration fallback"
}

test_the_meta_maps_a_herdr_pane_to_its_task_both_ways
test_a_persistent_wedge_on_herdr_escalates
test_a_resumed_herdr_crewmate_clears_quietly
test_a_draining_tmux_window_still_escalates
