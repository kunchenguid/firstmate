#!/usr/bin/env bash
# Credentialed GitHub Copilot CLI primary guard. Opt in with FM_COPILOT_PRIMARY_LIVE=1.
# FM_COPILOT_MODEL optionally chooses a catalog model id (default: the account's own).
# Runs the real copilot binary headless (`copilot -p`) in a scratch plain checkout of
# the working tree that carries the tracked .github/hooks/firstmate-primary.json, with
# a relocated COPILOT_HOME that trusts only that checkout, and asks the model to run a
# persistent `cd projects/foo`. The preToolUse denial proves together that Copilot
# loaded the registration, that the hook saw primary scope in its own environment, and
# that Copilot honoured the deny object. It spends one tiny prompt of the caller's own
# Copilot quota and edits nothing under ~/.copilot or the repository.
# tests/fm-copilot-primary.test.sh is the portable regression; run this after every
# Copilot upgrade (docs/verification/copilot.md "Native primary hooks").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_COPILOT_PRIMARY_LIVE copilot jq tar git

VERSION="copilot $(copilot --version 2>/dev/null | head -1)"
fail() { printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2; exit 1; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-copilot-primary-live.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
trap 'rm -rf "$LAB"' EXIT
CLONE="$LAB/clone"
FM_LAB_HOME="$LAB/home"
STATE="$LAB/state"

# A plain (non-worktree) checkout of the CURRENT working tree, so the guard tests the
# code under review rather than whatever is committed.
mkdir -p "$CLONE" "$STATE"
(cd "$ROOT" && tar --exclude=.git --exclude=state --exclude=projects --exclude=node_modules -cf - .) \
  | (cd "$CLONE" && tar -xf -) || fail 'could not stage the working tree into the scratch checkout'
git init -q "$CLONE"
[ "$(git -C "$CLONE" rev-parse --git-dir)" = .git ] || fail 'the scratch checkout must be a plain checkout for primary scope to match'
[ -f "$CLONE/.github/hooks/firstmate-primary.json" ] || fail 'the working tree ships no .github/hooks/firstmate-primary.json; there is nothing to verify'
mkdir -p "$CLONE/projects/foo"
"$ROOT/bin/fm-lab-home.sh" create "$FM_LAB_HOME" >/dev/null || fail 'could not create the lab home'

# The worker-plugin writer also seeds a COPILOT_HOME that carries the login and trusts
# only the scratch checkout.
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" live) || fail 'busy arm failed'
"$ROOT/bin/fm-copilot-plugin.sh" "$STATE" live "$gen" "$CLONE" || fail 'could not seed the Copilot home'

model_args=()
[ -z "${FM_COPILOT_MODEL:-}" ] || model_args=(--model "$FM_COPILOT_MODEL")
out=$(cd "$CLONE" && env -i HOME="$HOME" PATH="$PATH" FM_HOME="$FM_LAB_HOME" COPILOT_HOME="$STATE/live.copilot-home" \
  timeout 240 copilot -p 'Run exactly this shell command with your bash tool and report its output or any error verbatim: cd projects/foo && pwd' \
  --allow-all --no-auto-update ${model_args[@]+"${model_args[@]}"} 2>&1) || fail "copilot -p failed: $out"
case "$out" in
  *'Denied by preToolUse hook: [persistent-cd]'*) ;;
  *) fail "the persistent cd was not denied by the registered preToolUse hook: $out" ;;
esac
echo "ok - $VERSION: the tracked preToolUse hook denied a persistent cd in a primary checkout [persistent-cd]"
