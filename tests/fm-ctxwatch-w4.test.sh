#!/usr/bin/env bash
# GATE w4 - an over-threshold HERDR crewmate is checkpointed, /cleared and
# rehydrated, end to end.
#
# THE GAP THIS CLOSES, and it had no fallback at all. fm-ctx-statusline.sh
# stamped `managed:false` whenever $TMUX_PANE was unset, and the daemon
# re-confirmed its target through tmux at fire time, so after the herdr cutover
# NO crewmate could ever be selected for a compaction checkpoint: one that
# reached its context ceiling simply died with no handoff written. Every other
# herdr gap on that branch degraded to a false negative or a loud refusal; this
# one lost work.
#
# SO THIS GATE STARTS AT MEASURE, not at a planted sentinel. It runs the real
# statusLine in the environment fm-spawn.sh actually gives a herdr crewmate -
# FM_HERDR_PANE set, TMUX_PANE unset - and then walks the whole chain the
# watchdog walks: the sentinel it wrote must be managed, its key must survive a
# /clear, selection must pick it, the fire gate must permit it, the checkpoint
# must reach the pane, the FRESH handoff must gate the /clear, the /clear must go
# out over herdr, and the bootstrap must rehydrate from the handoff. A gate that
# planted its own sentinel would have gone green against the exact stamp that was
# broken.
#
# Mutation (LEDGER_MUTATE=1): never write the handoff - fire_once times out,
# issues NO /clear and returns non-zero, so the assertions fail. That is the
# property that matters most in this file: a session is never wiped before it has
# checkpointed.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"

# shellcheck source=bin/fm-context-watch.sh
. "$ROOT/bin/fm-context-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-ctx-w4)
FB=$(fm_herdr_fake_server "$TMP_ROOT")
FM="$TMP_ROOT/home"; STATE="$FM/state"; mkdir -p "$STATE" "$FM/data"
printf '(none)\n' > "$FM/data/projects.md"
printf '(none)\n' > "$FM/data/secondmates.md"
printf '\n' > "$FM/data/backlog.md"
PATH="$FB:$PATH"; export PATH
export CALLS="$TMP_ROOT/calls"
export FM_STATE_OVERRIDE="$STATE"

PANE=wZ:p1
KEY=wZ_p1
HANDOFF="$STATE/handoff-$KEY.md"

# The meta fm-spawn records for a crewmate it put on herdr.
cat > "$STATE/ctxcrew.meta" <<META
window=$PANE
worktree=$TMP_ROOT/wt
project=/p/demo
harness=claude
mux=herdr
name=demo-context-watch
kind=ship
META

# --- MEASURE: the real statusLine, in a herdr crewmate's environment ---------
#
# This is the half that was silently dead. TMUX_PANE is deliberately unset,
# because that is exactly what a herdr pane looks like.
STATUS_JSON='{"cwd":"'"$TMP_ROOT"'/wt","session_id":"s-w4","context_window":{"used_percentage":88,"current_usage":{"input_tokens":100000,"cache_creation_input_tokens":10000,"cache_read_input_tokens":10000},"exceeds_200k_tokens":false}}'
printf '%s' "$STATUS_JSON" | env -u TMUX_PANE FM_HOME="$FM" FM_STATE_OVERRIDE="$STATE" \
  FM_HERDR_PANE="$PANE" "$ROOT/bin/fm-ctx-statusline.sh" >/dev/null 2>&1 \
  || fail "the statusLine failed in a herdr crewmate's environment"

[ -e "$STATE/ctx-$KEY.json" ] \
  || fail "the sentinel was not keyed by the herdr pane id (expected ctx-$KEY.json)"
fm_ctx_sentinel_managed "$STATE/ctx-$KEY.json" \
  || fail "a fleet-spawned herdr crewmate stamped managed:false; it can never be checkpointed"
[ "$(fm_ctx_target_for "$STATE" "$KEY")" = "$PANE" ] \
  || fail "the sentinel does not carry the herdr pane as its steering target"
pass "w4: the statusLine measures a herdr crewmate as managed, keyed by its pane"

# A pane the fleet never spawned inherits no pin, so it must stay unmanaged - the
# opt-in-by-construction property the tmux session name used to provide.
printf '%s' "$STATUS_JSON" | env -u TMUX_PANE -u FM_HERDR_PANE FM_HOME="$FM" \
  FM_STATE_OVERRIDE="$STATE" FM_CTX_WINDOW=adhocpane "$ROOT/bin/fm-ctx-statusline.sh" >/dev/null 2>&1 || true
if fm_ctx_sentinel_managed "$STATE/ctx-adhocpane.json"; then
  fail "an ad-hoc pane with no fleet pin was stamped managed; the watchdog could /clear the captain's own session"
fi
pass "w4: a pane the fleet never spawned is not managed"

# --- SELECT + GATE ----------------------------------------------------------
fm_ctx_select "$STATE" | grep -qx "$KEY" \
  || fail "the herdr crewmate was not selected for restart"
AGENT_STATE=idle fm_ctx_can_fire "$STATE" "$KEY" "$PANE" \
  || fail "the fire gate refused an idle, over-threshold, fleet-owned herdr pane"
pass "w4: selection and the fire gate both admit the herdr crewmate"

# --- FIRE: checkpoint -> fresh handoff -> /clear -----------------------------
#
# The checkpoint delivery is stubbed to something observable (as G4 does) so the
# assertion is about the wiring rather than about a composer. The /clear is NOT
# stubbed: it must go out over herdr, and that is asserted below.
# shellcheck disable=SC2016
export FM_CTX_SEND_CMD='printf "%s\n" "$2" >> '"$TMP_ROOT"'/sent.txt; true'
export FM_CTX_HANDOFF_POLL=0.2 FM_CTX_HANDOFF_TIMEOUT=6

# A STALE handoff from a prior cycle is present from the start: the freshness
# guard (G9) must still hold on the herdr path, or a /clear wipes a live turn.
printf '# stale leave-off\nGoal: OLD-HANDOFF\n' > "$HANDOFF"
touch -t 202001010000 "$HANDOFF"

if [ "${LEDGER_MUTATE:-}" != 1 ]; then
  ( sleep 0.6; printf '# Leave-off\nGoal: W4-HANDOFF-OK\nFrontier: resume\n' > "$HANDOFF" ) &
fi

if AGENT_STATE=idle fm_ctx_fire_once "$STATE" "$KEY"; then fired=0; else fired=1; fi

grep -q 'CONTEXT CHECKPOINT' "$TMP_ROOT/sent.txt" 2>/dev/null \
  || fail "the checkpoint instruction never reached the herdr pane"
grep -q "handoff-$KEY.md" "$TMP_ROOT/sent.txt" 2>/dev/null \
  || fail "the checkpoint did not name the handoff path for this pane"
[ "$fired" = 0 ] || fail "fire_once must succeed once a FRESH handoff exists (returned non-zero)"

grep -qF "agent prompt $PANE /clear" "$CALLS" \
  || fail "/clear was not delivered over herdr (calls: $(tr '\n' '|' < "$CALLS"))"
grep -q 'send-keys' "$CALLS" && fail "/clear fell back to blind keystrokes"
pass "w4: checkpoint reached the pane and /clear was issued over herdr"

# --- REHYDRATE --------------------------------------------------------------
[ -e "$HANDOFF" ] || fail "the handoff must remain for the bootstrap to consume"
out=$(printf '%s' '{"source":"clear","cwd":"/tmp/x","session_id":"s-w4"}' \
  | env -u TMUX_PANE FM_HOME="$FM" FM_CTX_WINDOW="$KEY" FM_CTX_ROLE=crew \
    "$ROOT/bin/fm-captain-bootstrap.sh")
printf '%s' "$out" | grep -q 'W4-HANDOFF-OK' \
  || fail "the rehydrate did not inject the handoff after /clear"
pass "w4: e2e - measure -> select -> checkpoint -> handoff -> /clear -> rehydrate, all on herdr"
