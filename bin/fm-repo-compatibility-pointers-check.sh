#!/usr/bin/env bash
# fm-repo-compatibility-pointers-check.sh - verify this repository's two
# compatibility pointers without changing them.
#
# Usage:
#   fm-repo-compatibility-pointers-check.sh [repo-root]
#
# CLAUDE.md must be the canonical real @AGENTS.md import pointer.
# .claude/skills must remain the exact relative symlink to .agents/skills.
set -eu

ROOT=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILLS_POINTER="$ROOT/.claude/skills"

fail() {
  printf 'repo-compatibility-pointers: %s\n' "$*" >&2
  exit 1
}

"$SCRIPT_DIR/fm-ensure-agents-md.sh" --check-pointer "$ROOT" \
  || fail "CLAUDE.md does not satisfy the canonical pointer contract"

[ -L "$SKILLS_POINTER" ] \
  || fail ".claude/skills must be a symlink to ../.agents/skills"
[ "$(readlink "$SKILLS_POINTER")" = "../.agents/skills" ] \
  || fail ".claude/skills must be a symlink to ../.agents/skills"
