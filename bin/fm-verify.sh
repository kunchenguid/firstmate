#!/usr/bin/env bash
# Canonical deterministic repository verification for local work and CI.
#
# This command intentionally runs no model and no behavioral test corpus.
# Targeted and full behavioral validation remain explicit fm-test-run.sh calls.
# Usage: fm-verify.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

[ "$#" -eq 0 ] || {
  echo "error: fm-verify.sh accepts no arguments" >&2
  exit 2
}

cd "$FM_ROOT"
"$FM_ROOT/bin/fm-lint.sh" --full

if ! { [ -f CLAUDE.md ] && [ ! -L CLAUDE.md ] && grep -qxF '@AGENTS.md' CLAUDE.md; }; then
  echo "error: CLAUDE.md must point to AGENTS.md" >&2
  exit 1
fi
[ -L .claude/skills ] && [ "$(readlink .claude/skills)" = ../.agents/skills ] || {
  echo "error: .claude/skills must point to ../.agents/skills" >&2
  exit 1
}

tracked_private=$(git ls-files -- data state config projects .no-mistakes)
if [ -n "$tracked_private" ]; then
  echo "error: private fleet paths are tracked:" >&2
  printf '%s\n' "$tracked_private" >&2
  exit 1
fi

echo "verified: canonical repository checks passed"
