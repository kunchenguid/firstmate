#!/usr/bin/env bash
# Ensure a project worktree follows the agent-memory file convention.
# AGENTS.md is the real project-intrinsic knowledge file; CLAUDE.md and GEMINI.md
# are relative symlinks to it for compatibility. Creates a minimal AGENTS.md
# skeleton when neither file exists, promotes a real CLAUDE.md or GEMINI.md file
# when it is the only file present, and refuses to clobber distinct real files
# or wrong symlinks.
# Owns the canonical "## Maintaining this file" self-governance wording for
# project AGENTS.md files, appending it to created skeletons and promoted
# compatibility files that lack it.
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

write_maintenance_section() {
  cat <<'EOF'
## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
EOF
}

ensure_maintenance_section() {
  if grep -Fqx '## Maintaining this file' "$AGENTS"; then
    return 0
  fi
  sep=''
  if [ -s "$AGENTS" ]; then
    if [ -n "$(tail -c 1 "$AGENTS")" ]; then
      sep=$'\n\n'
    else
      sep=$'\n'
    fi
  fi
  {
    printf '%s' "$sep"
    write_maintenance_section
  } >> "$AGENTS"
}

write_skeleton() {
  cat > "$AGENTS" <<'EOF'
# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
EOF
  ensure_maintenance_section
}

is_correct_symlink() {
  local link_file=$1
  [ -L "$link_file" ] || return 1
  local target
  target=$(readlink "$link_file")
  case "$target" in
    "$AGENTS"|"./$AGENTS") return 0 ;;
  esac
  [ -e "$AGENTS" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$link_file" "$AGENTS" <<'PY'
import os
import sys
sys.exit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)
PY
    return $?
  fi
  return 1
}

if [ -L "$AGENTS" ]; then
  echo "conflict: AGENTS.md is a symlink in $DIR; expected AGENTS.md to be the real file" >&2
  exit 1
fi
if [ -e "$AGENTS" ] && [ ! -f "$AGENTS" ]; then
  echo "conflict: AGENTS.md exists in $DIR but is not a regular file" >&2
  exit 1
fi

if [ -e "$AGENTS" ]; then
  changed=false
  for file in CLAUDE.md GEMINI.md; do
    if [ -L "$file" ]; then
      if ! is_correct_symlink "$file"; then
        echo "conflict: $file is a symlink in $DIR but does not point to AGENTS.md" >&2
        exit 1
      fi
    elif [ ! -e "$file" ]; then
      ln -s "$AGENTS" "$file"
      echo "symlinked: $file -> AGENTS.md in $DIR"
      changed=true
    elif [ -f "$file" ]; then
      echo "conflict: both AGENTS.md and $file are real files in $DIR; reconcile them manually" >&2
      exit 1
    else
      echo "conflict: $file exists in $DIR but is not a regular file or symlink" >&2
      exit 1
    fi
  done
  if [ "$changed" = false ]; then
    echo "unchanged: AGENTS.md with compatibility symlinks -> AGENTS.md in $DIR"
  fi
  exit 0
fi

# AGENTS.md does not exist.
# Let's check for any real regular files to promote.
real_files=()
for file in CLAUDE.md GEMINI.md; do
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    real_files+=("$file")
  elif [ -e "$file" ] && [ ! -L "$file" ]; then
    echo "conflict: $file exists in $DIR but is not a regular file or symlink" >&2
    exit 1
  fi
done

if [ "${#real_files[@]}" -gt 1 ]; then
  echo "conflict: multiple real compatibility files (${real_files[*]}) exist in $DIR without AGENTS.md; reconcile them manually" >&2
  exit 1
fi

if [ "${#real_files[@]}" -eq 1 ]; then
  promote_src="${real_files[0]}"
  mv "$promote_src" "$AGENTS"
  ensure_maintenance_section
  for file in CLAUDE.md GEMINI.md; do
    if [ -e "$file" ] && [ ! -L "$file" ]; then
      echo "conflict: $file is a real file in $DIR; cannot overwrite" >&2
      exit 1
    fi
    if [ -L "$file" ]; then
      if ! is_correct_symlink "$file"; then
        echo "conflict: $file is a symlink in $DIR but does not point to AGENTS.md" >&2
        exit 1
      fi
    else
      ln -s "$AGENTS" "$file"
    fi
  done
  echo "promoted: moved $promote_src to AGENTS.md and symlinked compatibility files -> AGENTS.md in $DIR"
  exit 0
fi

# No real files to promote.
# Let's check for correct symlinks first, to see if we can keep them.
for file in CLAUDE.md GEMINI.md; do
  if [ -L "$file" ] && ! is_correct_symlink "$file"; then
    echo "conflict: $file is a symlink in $DIR but AGENTS.md is missing and the link does not point to AGENTS.md" >&2
    exit 1
  fi
done

write_skeleton
for file in CLAUDE.md GEMINI.md; do
  if [ ! -e "$file" ]; then
    ln -s "$AGENTS" "$file"
  fi
done
echo "created: AGENTS.md and compatibility symlinks -> AGENTS.md in $DIR"
exit 0
