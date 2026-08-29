#!/usr/bin/env bash
# G9: stale-handoff safety. fm_ctx_fire_once must NOT issue /clear just because a
# handoff-<key>.md left over from a PRIOR cycle is already on disk — doing so would
# wipe the crewmate's CURRENT turn and rehydrate from the old doc, silently losing
# live work. The fire cycle baselines the existing handoff mtime and only accepts a
# handoff written AFTER the checkpoint. Disposable scratch pane (never a real session).
#
# Normal: a STALE handoff exists at fire time and NO fresh one is written -> the cycle
# must time out, issue NO /clear, return non-zero, and leave the stale handoff intact.
# Mutation (LEDGER_MUTATE=1): a FRESH handoff IS written after the checkpoint -> the
# cycle now legitimately fires /clear and returns 0, so the "must not clear" assertion
# fails — proving the gate keys off handoff FRESHNESS, not mere presence.
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

command -v tmux >/dev/null 2>&1 || { pass "G9 stale-handoff (skipped: no tmux)"; exit 0; }

# shellcheck source=bin/fm-context-watch.sh disable=SC1091
. "$ROOT/bin/fm-context-watch.sh"

STATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-ctx-g9.XXXXXX")
SESS="fmctxg9-$$"
cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; rm -rf "$STATE"; }
trap cleanup EXIT

tmux new-session -d -s "$SESS" -x 200 -y 50 2>/dev/null || { pass "G9 stale-handoff (skipped: tmux new-session failed)"; exit 0; }
PANE=$(tmux display-message -p -t "$SESS" '#{pane_id}')
[ -n "$PANE" ] || fail "no scratch pane id"

KEY=g9win
HANDOFF="$STATE/handoff-$KEY.md"
printf '{"window":"%s","tmux_target":"%s","role":"captain","total_tokens":195000,"used_pct":98,"exceeds_200k":false,"managed":true,"ts":0}' \
  "$KEY" "$PANE" > "$STATE/ctx-$KEY.json"

# Plant a STALE handoff from a "prior cycle" and backdate its mtime well into the past
# so a fresh write is unambiguously newer (second-resolution mtime safe).
printf '# OLD leave-off\nGoal: STALE-DO-NOT-USE\n' > "$HANDOFF"
touch -t 202001010000 "$HANDOFF"

# shellcheck disable=SC2016
export FM_CTX_SEND_CMD='tmux send-keys -t "$1" -l "checkpoint-instruction-sent" ; tmux send-keys -t "$1" Enter ; true'
export FM_STATE_OVERRIDE="$STATE" FM_CTX_HANDOFF_POLL=0.2 FM_CTX_HANDOFF_TIMEOUT=3

# Mutation: a FRESH handoff IS written after the checkpoint (the crewmate checkpoints).
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  ( sleep 0.6; printf '# FRESH leave-off\nGoal: FRESH-OK\n' > "$HANDOFF" ) &
fi

if fm_ctx_fire_once "$STATE" "$KEY"; then fired=0; else fired=1; fi
sleep 0.3
pane_dump=$(tmux capture-pane -p -t "$PANE" -S -50 2>/dev/null || true)

# The checkpoint instruction must always reach the pane (the cycle did try).
printf '%s' "$pane_dump" | grep -q 'checkpoint-instruction-sent' || fail "checkpoint instruction never reached the pane"

# Normal (no fresh handoff): must NOT clear, must return non-zero, stale handoff intact.
[ "$fired" = 1 ] || fail "fire_once must NOT succeed on a stale pre-existing handoff (it cleared on stale work)"
printf '%s' "$pane_dump" | grep -q '/clear' && fail "/clear was issued on a STALE handoff (crewmate's live turn would be wiped)"
[ -e "$STATE/.ctx-fired-$KEY" ] && fail "cooldown marked despite no fresh checkpoint"
grep -q 'STALE-DO-NOT-USE' "$HANDOFF" || fail "stale handoff was unexpectedly altered"

pass "G9 stale-handoff: a pre-existing stale handoff does NOT trigger /clear; only a fresh post-checkpoint handoff does"
