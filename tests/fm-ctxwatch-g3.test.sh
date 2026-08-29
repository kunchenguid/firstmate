#!/usr/bin/env bash
# G3: rehydrate on SessionStart. With a handoff present, the bootstrap injects it
# as additionalContext and archives it. With no handoff, behavior is unchanged:
# a captain pane still gets the captain context (regression preserved); the
# rehydrate block is absent. Mutation (LEDGER_MUTATE=1): remove the handoff before
# running — the injected output then lacks the handoff marker, failing the assert.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOT="$ROOT/bin/fm-captain-bootstrap.sh"
FM=$(mktemp -d "${TMPDIR:-/tmp}/fm-ctx-g3.XXXXXX")
trap 'rm -rf "$FM"' EXIT
mkdir -p "$FM/data" "$FM/state"
printf 'demo-proj  no-mistakes  a demo\n' > "$FM/data/projects.md"
printf '(none)\n' > "$FM/data/secondmates.md"
printf '%s\n' '- a backlog item' > "$FM/data/backlog.md"

run_boot() {  # <stdin-json>   -> stdout JSON; env: FM_CTX_WINDOW/FM_CTX_ROLE
  printf '%s' "$1" | FM_HOME="$FM" "$BOOT"
}

# --- Case 1: handoff present -> injected + archived --------------------------
KEY=g3win
HANDOFF="$FM/state/handoff-$KEY.md"
if [ "${LEDGER_MUTATE:-}" != 1 ]; then
  printf '# Leave-off\nGoal: GOAL-MARKER-XYZ\nFrontier: pick up gate G4\n' > "$HANDOFF"
fi
out=$(FM_CTX_WINDOW="$KEY" FM_CTX_ROLE=crew run_boot '{"source":"clear","cwd":"/tmp/x","session_id":"s1"}')
printf '%s' "$out" | grep -q 'GOAL-MARKER-XYZ' || fail "handoff content must be injected (got: $out)"
printf '%s' "$out" | grep -q 'Rehydrate'       || fail "rehydrate header must be present"
[ -e "$HANDOFF" ] && fail "handoff must be archived (moved) after injection"
ls "$FM/state/handoff-archive/" >/dev/null 2>&1 || fail "handoff archive dir must exist"

# --- Case 2: no handoff, crew pane -> nothing emitted (no regression) --------
out2=$(FM_CTX_WINDOW=nohandoff FM_CTX_ROLE=crew run_boot '{"source":"clear","cwd":"/tmp/x","session_id":"s2"}')
[ -z "$out2" ] || fail "crew pane with no handoff must emit nothing (got: $out2)"

# --- Case 3: normal startup, captain pane, no handoff -> captain ctx intact --
out3=$(FM_CTX_WINDOW=capnone FM_CTX_ROLE=captain run_boot '{"source":"startup","cwd":"'"$FM"'","session_id":"s3"}')
printf '%s' "$out3" | grep -q 'You are Cortana' || fail "captain bootstrap regressed (no captain context)"
printf '%s' "$out3" | grep -q 'Rehydrate'       && fail "no handoff -> must NOT inject a rehydrate block"

pass "G3 rehydrate injects+archives handoff; no-handoff path unchanged (captain ctx preserved)"
