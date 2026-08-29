#!/usr/bin/env bash
# G8: per-secondmate SCOPED watch isolation. Two secondmate homes (A and B) each have
# an over-threshold managed crewmate sentinel. A watch scoped to home A must act ONLY
# on A's crewmate and never see B's, and vice versa; an unscoped/global watch (pointed
# at a combined state dir) still sees BOTH (no regression). Scoping is FM_HOME
# re-pointing: _ctx_state_root -> $home/state, so the poll set and the singleton lock
# are per-scope. We assert at the pure-selection layer (fm_ctx_select over the resolved
# state root) — no live tmux fire needed. Mutation (LEDGER_MUTATE=1): make the scoped
# resolution ignore FM_HOME (resolve A's state for both) so B leaks into A's scope ->
# the isolation assertion fails, proving the scope actually gates the selection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-context-watch.sh disable=SC1091
. "$ROOT/bin/fm-context-watch.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-ctx-g8.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
HOME_A="$TMP/home-a"; HOME_B="$TMP/home-b"; STATE_A="$HOME_A/state"; STATE_B="$HOME_B/state"
mkdir -p "$STATE_A" "$STATE_B"

# An over-threshold, managed captain sentinel keyed per home.
plant() {  # <statedir> <key>
  printf '{"window":"%s","tmux_target":"%%9","role":"captain","total_tokens":195000,"used_pct":98,"exceeds_200k":false,"managed":true,"ts":0}' \
    "$2" > "$1/ctx-$2.json"
}
plant "$STATE_A" crewA
plant "$STATE_B" crewB

# Resolve the state root the daemon would use for a given scope home. Mirrors
# _ctx_state_root with FM_HOME=<home> and NO FM_STATE_OVERRIDE (the production path).
scoped_root() {  # <home>
  local home=$1
  if [ "${LEDGER_MUTATE:-}" = 1 ]; then home="$HOME_A"; fi   # mutation: scope ignored
  ( unset FM_STATE_OVERRIDE; FM_HOME="$home"; _ctx_state_root )
}

sel_a=$(fm_ctx_select "$(scoped_root "$HOME_A")")
sel_b=$(fm_ctx_select "$(scoped_root "$HOME_B")")

# Scope A sees crewA and NOT crewB.
printf '%s\n' "$sel_a" | grep -qx crewA || fail "scope A failed to select its own crewmate (got: $sel_a)"
printf '%s\n' "$sel_a" | grep -qx crewB && fail "scope A leaked the other secondmate's crewmate (got: $sel_a)"
# Scope B sees crewB and NOT crewA.
printf '%s\n' "$sel_b" | grep -qx crewB || fail "scope B failed to select its own crewmate (got: $sel_b)"
printf '%s\n' "$sel_b" | grep -qx crewA && fail "scope B leaked the other secondmate's crewmate (got: $sel_b)"

# No-regression: a GLOBAL/unscoped watch pointed at a combined state dir sees BOTH.
GLOBAL="$TMP/global-state"; mkdir -p "$GLOBAL"
plant "$GLOBAL" crewA
plant "$GLOBAL" crewB
sel_all=$(FM_STATE_OVERRIDE="$GLOBAL" bash -c '. "'"$ROOT"'/bin/fm-context-watch.sh"; fm_ctx_select "$(_ctx_state_root)"')
printf '%s\n' "$sel_all" | grep -qx crewA || fail "global watch must still see crewA (got: $sel_all)"
printf '%s\n' "$sel_all" | grep -qx crewB || fail "global watch must still see crewB (got: $sel_all)"

# The scoped singleton lock is per-scope: the lock path derives from each home's state
# root, so two scopes never collide on one global lock.
[ "$(scoped_root "$HOME_A")/.context-watch.lock" != "$(scoped_root "$HOME_B")/.context-watch.lock" ] \
  || { [ "${LEDGER_MUTATE:-}" = 1 ] || fail "scoped lock paths must differ per scope"; }

pass "G8 scoped watch: a per-secondmate scope acts only on its own crewmates; global still sees all"
