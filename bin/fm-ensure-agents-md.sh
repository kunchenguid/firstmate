#!/usr/bin/env bash
# Ensure a project worktree follows the agent-memory file convention.
# AGENTS.md is the real project-intrinsic knowledge file; CLAUDE.md is a
# relative symlink to it for compatibility. Creates a minimal AGENTS.md skeleton
# when neither file exists, promotes a real CLAUDE.md file when it is the only
# file present, and refuses to clobber distinct real files or wrong symlinks.
# Owns the canonical "## Maintaining this file" self-governance wording for
# project AGENTS.md files, injecting it idempotently into created skeletons,
# promoted CLAUDE.md files, and any existing AGENTS.md that still lacks it.
# Refuses a case-variant real memory file such as a lowercase agents.md, whose
# CLAUDE.md symlink would carry an uppercase literal target that dangles on a
# case-sensitive filesystem (issue #389).
# This is a worktree utility for crewmates, not a supervision script, so it does
# not call fm-guard.sh.
# Usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]
set -eu

usage() {
  echo "usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]" >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
[ "$#" -le 1 ] || { usage; exit 1; }

DIR=${1:-.}
[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)
cd "$DIR"

AGENTS=AGENTS.md
CLAUDE=CLAUDE.md

write_maintenance_section() {
  cat <<'EOF'
## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
EOF
}

write_maintenance_section_with_eol() {
  local eol=$1 line
  while IFS= read -r line; do
    printf '%s%s' "$line" "$eol"
  done < <(write_maintenance_section)
}

# Idempotently append the canonical self-governance section to AGENTS.md when it
# is absent. Sets MAINT_INJECTED=1 when it appends and 0 when the section is
# already present, so callers can report whether the file changed.
MAINT_INJECTED=0
ensure_maintenance_section() {
  MAINT_INJECTED=0
  if grep -Fqx '## Maintaining this file' "$AGENTS" ||
    grep -Fqx $'## Maintaining this file\r' "$AGENTS"; then
    return 0
  fi
  local eol=$'\n' sep=''
  if LC_ALL=C grep -q $'\r$' "$AGENTS"; then
    eol=$'\r\n'
  fi
  if [ -s "$AGENTS" ]; then
    if [ -n "$(tail -c 1 "$AGENTS")" ]; then
      sep="${eol}${eol}"
    else
      sep=$eol
    fi
  fi
  {
    printf '%s' "$sep"
    write_maintenance_section_with_eol "$eol"
  } >> "$AGENTS"
  MAINT_INJECTED=1
}

write_skeleton() {
  cat > "$AGENTS" <<'EOF'
# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
EOF
  ensure_maintenance_section
}

is_correct_claude_symlink() {
  [ -L "$CLAUDE" ] || return 1
  target=$(readlink "$CLAUDE")
  case "$target" in
    "$AGENTS"|"./$AGENTS") return 0 ;;
  esac
  [ -e "$AGENTS" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CLAUDE" "$AGENTS" <<'PY'
import os
import sys
sys.exit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)
PY
    return $?
  fi
  return 1
}

# Refuse a case-variant real memory file (issue #389). On a case-insensitive
# filesystem an existing lowercase agents.md satisfies every [ -e AGENTS.md ]
# test below, so the script would emit a CLAUDE.md symlink whose uppercase
# literal target dangles once the tree is checked out on a case-sensitive
# filesystem. Reading the real directory entries catches the mismatch on both
# filesystem kinds; surface it for manual reconciliation instead of linking blindly.
for entry in *; do
  if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
    continue
  fi
  if [ "$entry" != "$AGENTS" ]; then
    case "$entry" in
      [Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd])
        echo "conflict: memory file is named $entry in $DIR but the convention is AGENTS.md; rename it to AGENTS.md so CLAUDE.md links portably" >&2
        exit 1
        ;;
    esac
  fi
done

if [ -L "$AGENTS" ]; then
  echo "conflict: AGENTS.md is a symlink in $DIR; expected AGENTS.md to be the real file" >&2
  exit 1
fi
if [ -e "$AGENTS" ] && [ ! -f "$AGENTS" ]; then
  echo "conflict: AGENTS.md exists in $DIR but is not a regular file" >&2
  exit 1
fi

if [ -e "$AGENTS" ]; then
  if [ -L "$CLAUDE" ]; then
    if is_correct_claude_symlink; then
      ensure_maintenance_section
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md in $DIR"
      else
        echo "unchanged: AGENTS.md with CLAUDE.md -> AGENTS.md in $DIR"
      fi
      exit 0
    fi
    echo "conflict: CLAUDE.md is a symlink in $DIR but does not point to AGENTS.md" >&2
    exit 1
  fi
  if [ ! -e "$CLAUDE" ]; then
    ensure_maintenance_section
    ln -s "$AGENTS" "$CLAUDE"
    if [ "$MAINT_INJECTED" -eq 1 ]; then
      echo "updated: added ## Maintaining this file to AGENTS.md and symlinked CLAUDE.md -> AGENTS.md in $DIR"
    else
      echo "symlinked: CLAUDE.md -> AGENTS.md in $DIR"
    fi
    exit 0
  fi
  if [ -f "$CLAUDE" ]; then
    echo "conflict: both AGENTS.md and CLAUDE.md are real files in $DIR; reconcile them manually" >&2
    exit 1
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

if [ -L "$CLAUDE" ]; then
  if is_correct_claude_symlink; then
    write_skeleton
    echo "created: AGENTS.md and kept CLAUDE.md -> AGENTS.md in $DIR"
    exit 0
  fi
  echo "conflict: CLAUDE.md is a symlink in $DIR but AGENTS.md is missing and the link does not point to AGENTS.md" >&2
  exit 1
fi

if [ -e "$CLAUDE" ]; then
  if [ -f "$CLAUDE" ]; then
    mv "$CLAUDE" "$AGENTS"
    ensure_maintenance_section
    ln -s "$AGENTS" "$CLAUDE"
    echo "promoted: moved CLAUDE.md to AGENTS.md and symlinked CLAUDE.md -> AGENTS.md in $DIR"
    exit 0
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

write_skeleton
ln -s "$AGENTS" "$CLAUDE"
echo "created: AGENTS.md and CLAUDE.md -> AGENTS.md in $DIR"
