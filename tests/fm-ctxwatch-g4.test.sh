#!/usr/bin/env bash
# G4: end-to-end on a DISPOSABLE scratch tmux pane (never a real session).
# Cross the threshold via a planted sentinel -> fm_ctx_fire_once sends the
# checkpoint instruction into the pane -> the handoff file appears (we STUB the
# session's response by creating it) -> /clear is issued into the pane -> the
# bootstrap rehydrates from the handoff. Mutation (LEDGER_MUTATE=1): never create
# the handoff -> fire_once times out, issues NO /clear, returns non-zero -> assert
# fails (proving the gate observes the real checkpoint->clear wiring).
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

command -v tmux >/dev/null 2>&1 || { pass "G4 e2e (skipped: no tmux)"; exit 0; }

# shellcheck source=bin/fm-context-watch.sh
. "$ROOT/bin/fm-context-watch.sh"

FM=$(mktemp -d "${TMPDIR:-/tmp}/fm-ctx-g4.XXXXXX")
STATE="$FM/state"; mkdir -p "$STATE" "$FM/data"
printf '(none)\n' > "$FM/data/projects.md"; printf '(none)\n' > "$FM/data/secondmates.md"; printf '\n' > "$FM/data/backlog.md"
SESS="fmctxg4-$$"
cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; rm -rf "$FM"; }
trap cleanup EXIT

tmux new-session -d -s "$SESS" -x 200 -y 50 2>/dev/null || { pass "G4 e2e (skipped: tmux new-session failed)"; exit 0; }
PANE=$(tmux display-message -p -t "$SESS" '#{pane_id}')
[ -n "$PANE" ] || fail "no scratch pane id"

KEY=g4win
HANDOFF="$STATE/handoff-$KEY.md"
printf '{"window":"%s","tmux_target":"%s","role":"captain","total_tokens":195000,"used_pct":98,"exceeds_200k":false,"ts":0}' \
  "$KEY" "$PANE" > "$STATE/ctx-$KEY.json"

# Use a deterministic, observable send (echo into the bash pane) instead of the
# claude-composer-aware fm-send.sh, so the scratch bash pane shows the text. The
# $1/$2 are expanded by _ctx_send's `eval`, not this assignment — intentional.
# shellcheck disable=SC2016
export FM_CTX_SEND_CMD='tmux send-keys -t "$1" -l "checkpoint-instruction-sent" ; tmux send-keys -t "$1" Enter ; true'
export FM_STATE_OVERRIDE="$STATE" FM_CTX_HANDOFF_POLL=0.2 FM_CTX_HANDOFF_TIMEOUT=6

# STUB the target session's checkpoint response: after a beat, write the handoff
# (unless mutating, where the session "fails to checkpoint").
if [ "${LEDGER_MUTATE:-}" != 1 ]; then
  ( sleep 0.6; printf '# Leave-off\nGoal: E2E-HANDOFF-OK\nFrontier: resume\n' > "$HANDOFF" ) &
fi

if fm_ctx_fire_once "$STATE" "$KEY"; then
  fired=0
else
  fired=1
fi

sleep 0.4
pane_dump=$(tmux capture-pane -p -t "$PANE" -S -50 2>/dev/null || true)

# Assert the checkpoint instruction reached the pane.
printf '%s' "$pane_dump" | grep -q 'checkpoint-instruction-sent' || fail "checkpoint instruction never reached the pane"

# Assert /clear was issued (only when the handoff appeared).
[ "$fired" = 0 ] || fail "fire_once must succeed once the handoff exists (returned non-zero)"
printf '%s' "$pane_dump" | grep -q '/clear' || fail "/clear was not issued into the pane"

# Assert rehydrate from the archived... the handoff still on disk drives the boot.
# (fire_once leaves the handoff in place; the bootstrap archives it on inject.)
[ -e "$HANDOFF" ] || fail "handoff should remain for the bootstrap to consume"
out=$(printf '%s' '{"source":"clear","cwd":"/tmp/x","session_id":"s4"}' \
  | FM_HOME="$FM" FM_CTX_WINDOW="$KEY" FM_CTX_ROLE=captain "$ROOT/bin/fm-captain-bootstrap.sh")
printf '%s' "$out" | grep -q 'E2E-HANDOFF-OK' || fail "rehydrate did not inject the handoff after /clear"

pass "G4 e2e: checkpoint -> handoff -> /clear -> rehydrate wiring proven on scratch pane"
