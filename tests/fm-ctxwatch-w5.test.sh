#!/usr/bin/env bash
# GATE w5 - a BUSY over-threshold herdr pane is NOT fired on.
#
# THIS GUARD IS LOAD-BEARING. Firing means interrupting a crewmate mid-turn with
# a checkpoint instruction and then wiping its conversation, so a busy-guard that
# does not hold destroys work rather than recycling a session. G2 pins it for
# tmux; this pins it for herdr, where the crew now lives and where the tmux
# detector cannot see anything at all.
#
# THE HERDR ANSWER IS BETTER THAN THE TMUX ONE, and the fake proves it: an agent
# record carries terminal_title beside the lifecycle field, and a title routinely
# contains the word "working" while the agent is idle. Reading agent_status is
# what separates them; a grep over the record does not.
#
# OWNERSHIP IS RE-CONFIRMED AT FIRE TIME, and on herdr the evidence is this
# home's own meta - the same discriminator fm-send, fm-peek and the watcher route
# on. A herdr pane the fleet never spawned has no meta and is never ours to
# steer, which is the last case below.
#
# Mutation (LEDGER_MUTATE=1): report the same pane idle instead of working - the
# guard then permits the fire and the "must be blocked" assertion fails, proving
# the result comes from the state read and not from a constant.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"

# shellcheck source=bin/fm-context-watch.sh
. "$ROOT/bin/fm-context-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-ctx-w5)
FB=$(fm_herdr_fake_server "$TMP_ROOT")
STATE="$TMP_ROOT/state"; mkdir -p "$STATE"
PATH="$FB:$PATH"; export PATH
export FM_STATE_OVERRIDE="$STATE"
export CALLS="$TMP_ROOT/calls"

BUSY_STATE=working
[ "${LEDGER_MUTATE:-}" = 1 ] && BUSY_STATE=idle

PANE=wZ:p1
KEY=wZ_p1

# The crewmate this home spawned onto herdr: sentinel plus the meta that records
# which surface minted the pane.
printf '{"window":"%s","tmux_target":"%s","role":"crew","total_tokens":120000,"used_pct":88,"exceeds_200k":false,"managed":true,"ts":0}' \
  "$KEY" "$PANE" > "$STATE/ctx-$KEY.json"
cat > "$STATE/ctxcrew.meta" <<META
window=$PANE
worktree=/wt
project=/p/demo
harness=claude
mux=herdr
kind=ship
META

# Sanity: eligibility does not depend on the busy state, so the guard is what
# decides below rather than the threshold.
_ctx_eligible "$STATE" "$KEY" || fail "an over-threshold crew sentinel should be eligible"

if AGENT_STATE="$BUSY_STATE" fm_ctx_can_fire "$STATE" "$KEY" "$PANE"; then
  fail "a busy herdr pane must NOT fire (busy-guard failed to hold)"
fi
pass "w5: an over-threshold BUSY herdr pane does not fire"

# The other half: the guard must not be a blanket refusal of every herdr pane.
if ! AGENT_STATE=idle fm_ctx_can_fire "$STATE" "$KEY" "$PANE"; then
  fail "an over-threshold IDLE herdr pane was refused; the guard blocks everything"
fi
pass "w5: the same pane, idle, does fire"

# Rendered text must not decide it. A title containing "working" on an idle agent
# is the everyday case, not a corner one.
if ! AGENT_STATE=idle HERDR_TITLE='start working on the parser' \
     fm_ctx_can_fire "$STATE" "$KEY" "$PANE"; then
  fail "a title containing 'working' suppressed a legitimate fire; the guard is reading rendered text"
fi
pass "w5: the busy read is the lifecycle field, not the terminal title"

# Ownership: an identical pane with no meta in this home is not ours to steer.
printf '{"window":"wQ_p9","tmux_target":"wQ:p9","role":"crew","total_tokens":120000,"used_pct":88,"exceeds_200k":false,"managed":true,"ts":0}' \
  > "$STATE/ctx-wQ_p9.json"
if AGENT_STATE=idle fm_ctx_can_fire "$STATE" wQ_p9 wQ:p9; then
  fail "a herdr pane this home never spawned was treated as ours to /clear"
fi
pass "w5: a herdr pane with no meta in this home is never fired on"

# Nothing in this gate may reach tmux: the pane is a herdr pane throughout.
if [ -s "$CALLS" ] && grep -q 'capture-pane' "$CALLS"; then
  fail "the herdr busy-guard reached for tmux capture-pane"
fi
pass "w5: the herdr fire gate never consults tmux"
