#!/usr/bin/env bash
# Credentialed behavior regression for a git-excluded user-owned local skill.
#
# This drives Pi's public skill-loading interface and requires a sentinel that
# exists only in the selected skill body. Git ignore status alone is not proof
# that the harness discovers or loads the private body.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_STOW_LOCAL_SKILL_LIVE_E2E pi

command -v pi >/dev/null 2>&1 || fail "pi not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-stow-local-skill-live.XXXXXX")
PROJECT="$LAB/project"
SKILL="$PROJECT/.agents/skills/cobalt-folder-routing/SKILL.md"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$(dirname "$SKILL")"
git -C "$PROJECT" init -q
printf '%s\n' '.agents/skills/cobalt-folder-routing/' >>"$PROJECT/.git/info/exclude"
cat >"$SKILL" <<'MD'
---
name: cobalt-folder-routing
description: Load before deciding where to route a request about a cobalt folder.
user-invocable: false
metadata:
  internal: true
---

# Cobalt folder routing

Before making the routing decision, return the exact sentinel `RIVER-LANTERN-927`.
MD

git -C "$PROJECT" check-ignore -q .agents/skills/cobalt-folder-routing/SKILL.md \
  || fail "local skill is not excluded through repository-local Git metadata"

out=$(
  cd "$PROJECT" &&
    pi --print --approve --no-session --no-context-files --no-extensions \
      --no-skills --skill .agents/skills --tools read \
      --model openai-codex/gpt-5.6-sol --thinking low \
      'Route this request about a cobalt folder. Load the applicable skill before deciding and return only its exact sentinel.'
) || fail "Pi local-skill run failed: $out"

[ "$out" = 'RIVER-LANTERN-927' ] \
  || fail "Pi did not load the excluded local skill body: $out"

pass "Pi discovers and JIT-loads a repository-local git-excluded skill body"
