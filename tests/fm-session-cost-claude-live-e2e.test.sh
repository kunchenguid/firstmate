#!/usr/bin/env bash
# Opt-in credentialed live guard for bin/fm-session-cost.sh against the
# installed Claude Code: one short Haiku turn in an isolated folder must leave a
# transcript that `show` finds through the worktree-path mapping and measures as
# a real context size. It proves the transcript location and usage fields the
# measurement reads are still what this Claude Code version writes.
# Run it after every Claude Code upgrade; one Haiku turn is submitted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_SESSION_COST_LIVE_E2E claude jq

COST="$ROOT/bin/fm-session-cost.sh"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-session-cost-live)
WORK="$LAB/work"
HOME_DIR="$LAB/fmhome"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$WORK" "$HOME_DIR/state" "$HOME_DIR/config"
WORK=$(cd "$WORK" && pwd -P)

cleanup() {
  rm -rf "$CLAUDE_DIR/projects/$(printf '%s' "$WORK" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

fm_write_meta "$HOME_DIR/state/live.meta" "window=x:fm-live" "worktree=$WORK" \
  "harness=claude" "kind=ship" "spawn_gen=s$(( $(date +%s) - 5 )).1.1"

(cd "$WORK" && claude -p --model haiku "Reply with the single word ok." >/dev/null 2>&1) \
  || fail "claude ($CLAUDE_VERSION) could not run one headless turn"

out=$(FM_HOME="$HOME_DIR" "$COST" show --json live)
[ "$(printf '%s' "$out" | jq -r .status)" = ok ] \
  || fail "claude ($CLAUDE_VERSION): fm-session-cost found no measurable transcript: $out"
tokens=$(printf '%s' "$out" | jq -r .context_tokens)
[ "$tokens" -gt 1000 ] \
  || fail "claude ($CLAUDE_VERSION): measured context $tokens is not a real first-turn context: $out"
pass "fm-session-cost measures a real Claude $CLAUDE_VERSION transcript ($tokens tokens)"
