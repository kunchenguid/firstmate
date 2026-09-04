#!/usr/bin/env bash
# Ensure a project worktree follows the agent-memory file convention.
# AGENTS.md is the real project-intrinsic knowledge file; CLAUDE.md is a
# real regular file whose canonical content is the two-line @AGENTS.md pointer
# that Claude Code inlines at load time. Creates a minimal AGENTS.md skeleton
# when neither file exists, promotes a real CLAUDE.md file when it is the only
# file present (unless it is already the canonical pointer), converts a correct
# CLAUDE.md -> AGENTS.md symlink into the pointer file, and refuses to clobber
# distinct real files or wrong symlinks.
# Owns the canonical "## Maintaining this file" self-governance wording for
# project AGENTS.md files, injecting it idempotently into created skeletons,
# promoted CLAUDE.md files, and any existing AGENTS.md that still lacks it.
# Owns the canonical CLAUDE.md pointer content (the exact two-line @AGENTS.md
# form). A real-file pointer cannot follow a write into AGENTS.md, which is why
# the installer never creates a CLAUDE.md symlink.
# Refuses a case-variant real memory file such as a lowercase agents.md, so the
# pointer's @AGENTS.md import resolves to a real AGENTS.md on a case-sensitive
# filesystem (issue #389). The real-file pointer also eliminates the old
# uppercase-literal-target dangling-symlink hazard that a CLAUDE.md -> AGENTS.md
# link would have carried for that same mismatch.
# In a git repo whose index does not track CLAUDE.md, the canonical pointer it
# writes (or finds) is best-effort added to the repo's info/exclude so the
# untracked pointer never blocks fm-teardown's dirty check or leaks into a
# commit; a tracked CLAUDE.md is never excluded (see exclude_untracked_pointer).
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

# Canonical CLAUDE.md pointer: a real file, never a symlink. Byte-identical
# two-line form so a stray write clobbers only this recoverable pointer.
claude_pointer_content() {
  cat <<'EOF'
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
}

is_canonical_claude_pointer() {
  [ -f "$CLAUDE" ] && [ ! -L "$CLAUDE" ] || return 1
  claude_pointer_content | cmp -s - "$CLAUDE"
}

# Keep the untracked canonical pointer out of git's view so it never blocks
# fm-teardown's dirty check or leaks into a commit - the same requirement and
# tolerant shape as fm-spawn.sh's exclude_path for worktree-resident hooks.
# Verified empirically (git 2.50.1): inside a linked worktree,
# `git rev-parse --git-path info/exclude` resolves to the SHARED common-dir
# exclude (git treats info/ as a common path), and a per-worktree
# $GIT_DIR/info/exclude is NOT honored by git at all, so a per-worktree
# mechanism does not exist short of extensions.worktreeConfig. The shared
# exclude is deliberate and acceptable here: the line is written only for
# this fixed firstmate-owned filename, only while the repo does not track
# CLAUDE.md, and only when the file present is the canonical pointer this
# script owns; and `git add CLAUDE.md` on an excluded path refuses loudly
# with a hint naming the exclude, so tracking it later stays discoverable.
# Excluding is best-effort housekeeping: outside a git work tree, off the
# repo's top level, or on any write failure, do nothing and never fail.
exclude_untracked_pointer() {
  local top excl
  is_canonical_claude_pointer || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  # The exclude pattern is anchored to the repo root, so only write it when
  # the pointer actually lives there.
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  [ "$top" = "$DIR" ] || return 0
  # Never exclude a tracked path.
  if git ls-files --error-unmatch -- "$CLAUDE" >/dev/null 2>&1; then
    return 0
  fi
  excl=$(git rev-parse --git-path info/exclude 2>/dev/null) || return 0
  [ -n "$excl" ] || return 0
  mkdir -p "$(dirname "$excl")" 2>/dev/null || return 0
  grep -qxF "/$CLAUDE" "$excl" 2>/dev/null || echo "/$CLAUDE" >> "$excl" || return 0
}

# Write the canonical pointer as a regular file. Unlink a symlink first so the
# write cannot follow it and destroy AGENTS.md. Never overwrite a distinct real
# file; callers classify that as a conflict before invoking this.
install_claude_pointer() {
  if ! is_canonical_claude_pointer; then
    if [ -L "$CLAUDE" ]; then
      rm -- "$CLAUDE"
    elif [ -e "$CLAUDE" ]; then
      echo "error: internal: refuse to overwrite existing CLAUDE.md" >&2
      exit 1
    fi
    claude_pointer_content > "$CLAUDE"
  fi
  exclude_untracked_pointer
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
# test below, so the script would emit a CLAUDE.md pointer whose @AGENTS.md
# import dangles once the tree is checked out on a case-sensitive filesystem.
# Reading the real directory entries catches the mismatch on both filesystem
# kinds; surface it for manual reconciliation instead of writing the pointer
# against the wrong name.
for entry in *; do
  if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
    continue
  fi
  if [ "$entry" != "$AGENTS" ]; then
    case "$entry" in
      [Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd])
        echo "conflict: memory file is named $entry in $DIR but the convention is AGENTS.md; rename it to AGENTS.md so CLAUDE.md's @AGENTS.md pointer resolves portably" >&2
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
      install_claude_pointer
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer in $DIR"
      else
        echo "updated: replaced CLAUDE.md symlink with @AGENTS.md pointer in $DIR"
      fi
      exit 0
    fi
    echo "conflict: CLAUDE.md is a symlink in $DIR but does not point to AGENTS.md" >&2
    exit 1
  fi
  if [ ! -e "$CLAUDE" ]; then
    ensure_maintenance_section
    install_claude_pointer
    if [ "$MAINT_INJECTED" -eq 1 ]; then
      echo "updated: added ## Maintaining this file to AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer in $DIR"
    else
      echo "wrote: CLAUDE.md @AGENTS.md pointer in $DIR"
    fi
    exit 0
  fi
  if [ -f "$CLAUDE" ]; then
    if is_canonical_claude_pointer; then
      ensure_maintenance_section
      exclude_untracked_pointer
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md in $DIR"
      else
        echo "unchanged: AGENTS.md with CLAUDE.md @AGENTS.md pointer in $DIR"
      fi
      exit 0
    fi
    echo "conflict: both AGENTS.md and CLAUDE.md are real files in $DIR; reconcile them manually" >&2
    exit 1
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

if [ -L "$CLAUDE" ]; then
  if is_correct_claude_symlink; then
    write_skeleton
    install_claude_pointer
    echo "created: AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer in $DIR"
    exit 0
  fi
  echo "conflict: CLAUDE.md is a symlink in $DIR but AGENTS.md is missing and the link does not point to AGENTS.md" >&2
  exit 1
fi

if [ -e "$CLAUDE" ]; then
  if [ -f "$CLAUDE" ]; then
    if is_canonical_claude_pointer; then
      write_skeleton
      exclude_untracked_pointer
      echo "created: AGENTS.md and kept CLAUDE.md @AGENTS.md pointer in $DIR"
      exit 0
    fi
    mv "$CLAUDE" "$AGENTS"
    ensure_maintenance_section
    install_claude_pointer
    echo "promoted: moved CLAUDE.md to AGENTS.md and wrote CLAUDE.md @AGENTS.md pointer in $DIR"
    exit 0
  fi
  echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
  exit 1
fi

write_skeleton
install_claude_pointer
echo "created: AGENTS.md and CLAUDE.md @AGENTS.md pointer in $DIR"
