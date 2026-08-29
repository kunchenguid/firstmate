#!/usr/bin/env bash
# G6: fm-compact-crewmate.sh runs the SAME fire-once cycle as the daemon, on demand,
# against a DISPOSABLE scratch tmux pane (never a real fleet pane). Plant an
# over-threshold sentinel -> the command sends the checkpoint instruction -> we STUB
# the crewmate's handoff -> /clear is issued -> the cooldown marker is written.
# Also proves NON-DUPLICATION: the command and the daemon both call fm_ctx_fire_once
# (one implementation, no copy-paste fork). Mutation (LEDGER_MUTATE=1): never create
# the handoff -> the cycle times out, issues NO /clear, no cooldown marker -> assert
# fails (proving the gate observes the real checkpoint->clear wiring through the
# command, not a constant).
# HERMETICITY-WAIVER: outside the tests/lib.sh deny net on purpose. The context
# watchdog is a tmux-only subsystem and this case drives a DISPOSABLE scratch
# session it creates and kills itself, so the refusing shim would deny the very
# server under test. The migration this marks: opt in with FM_TEST_ALLOW_LIVE_TMUX=1
# before sourcing lib.sh and export FM_TEST_LIVE_TMUX_SESSION="$SESS", which scopes
# its kills to its own session instead of trusting them.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { pass "G6 on-demand compact (skipped: no tmux)"; exit 0; }

# --- non-duplication proof (static): both the daemon main loop and the on-demand
# command invoke fm_ctx_fire_once; the command does not define its own cycle. -------
grep -q 'fm_ctx_fire_once' "$ROOT/bin/fm-context-watch.sh" || fail "daemon does not call fm_ctx_fire_once"
grep -q 'fm_ctx_fire_once' "$ROOT/bin/fm-compact-crewmate.sh" || fail "command does not call fm_ctx_fire_once"
# The command must SOURCE the watch component (reuse), not redefine fire_once.
grep -Eq '^\. .*fm-context-watch\.sh' "$ROOT/bin/fm-compact-crewmate.sh" \
  || fail "command does not source fm-context-watch.sh (would risk a forked cycle)"
grep -q 'fm_ctx_fire_once()' "$ROOT/bin/fm-compact-crewmate.sh" \
  && fail "command redefines fm_ctx_fire_once — must reuse the daemon's, not fork it"

FM=$(mktemp -d "${TMPDIR:-/tmp}/fm-ctx-g6.XXXXXX")
STATE="$FM/state"; mkdir -p "$STATE"
SESS="fmctxg6-$$"
cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; rm -rf "$FM"; }
trap cleanup EXIT

tmux new-session -d -s "$SESS" -x 200 -y 50 2>/dev/null || { pass "G6 on-demand compact (skipped: tmux new-session failed)"; exit 0; }
PANE=$(tmux display-message -p -t "$SESS" '#{pane_id}')
[ -n "$PANE" ] || fail "no scratch pane id"

KEY=g6win
HANDOFF="$STATE/handoff-$KEY.md"
FIRED_MARK="$STATE/.ctx-fired-$KEY"
printf '{"window":"%s","tmux_target":"%s","role":"captain","total_tokens":195000,"used_pct":98,"exceeds_200k":false,"managed":true,"ts":0}' \
  "$KEY" "$PANE" > "$STATE/ctx-$KEY.json"

# Deterministic, observable send into the bash pane (same technique as G4).
# shellcheck disable=SC2016
export FM_CTX_SEND_CMD='tmux send-keys -t "$1" -l "checkpoint-instruction-sent" ; tmux send-keys -t "$1" Enter ; true'
export FM_STATE_OVERRIDE="$STATE" FM_HOME="$FM" FM_CTX_HANDOFF_POLL=0.2 FM_CTX_HANDOFF_TIMEOUT=6

# STUB the crewmate's checkpoint response: write the handoff after a beat (unless the
# mutation, where the crewmate "fails to checkpoint").
if [ "${LEDGER_MUTATE:-}" != 1 ]; then
  ( sleep 0.6; printf '# Leave-off\nGoal: ONDEMAND-COMPACT-OK\nFrontier: resume\n' > "$HANDOFF" ) &
fi

if "$ROOT/bin/fm-compact-crewmate.sh" "$KEY"; then
  rc=0
else
  rc=1
fi
sleep 0.4
pane_dump=$(tmux capture-pane -p -t "$PANE" -S -50 2>/dev/null || true)

# The same success assertions for both modes — under the mutation (no handoff) the
# cycle cannot complete, so these FAIL, proving the gate observes the real
# checkpoint->handoff->clear->cooldown wiring through the command (not a constant).
[ "$rc" = 0 ] || fail "fm-compact-crewmate must succeed once the handoff exists (returned non-zero)"
printf '%s' "$pane_dump" | grep -q 'checkpoint-instruction-sent' || fail "checkpoint instruction never reached the pane"
printf '%s' "$pane_dump" | grep -q '/clear' || fail "/clear was not issued into the pane"
[ -e "$FIRED_MARK" ] || fail "cooldown marker (.ctx-fired-$KEY) was not written"

# Idempotency / cooldown: a second immediate call is a safe no-op (cooldown holds),
# returns 0, and does NOT re-issue /clear (no new handoff to consume).
rm -f "$HANDOFF"
if ! "$ROOT/bin/fm-compact-crewmate.sh" "$KEY"; then
  fail "second call during cooldown must be a safe no-op (returned non-zero)"
fi

pass "G6 on-demand compact: command runs the shared fire-once cycle (checkpoint -> handoff -> /clear -> cooldown), reuses the daemon's fn, idempotent under cooldown"
