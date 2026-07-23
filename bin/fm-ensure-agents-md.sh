#!/usr/bin/env bash
# Ensure a project worktree follows the agent-memory file convention.
# AGENTS.md is the real project-intrinsic knowledge file; CLAUDE.md is a
# real regular file whose canonical content is the two-line @AGENTS.md pointer
# that Claude Code inlines at load time. Creates a minimal AGENTS.md skeleton
# when neither file exists, promotes a real CLAUDE.md file when it is the only
# file present (unless it is already a pointer), converts a correct
# CLAUDE.md -> AGENTS.md symlink into the pointer file, and refuses to clobber
# distinct real files or wrong symlinks.
# A real CLAUDE.md that only includes AGENTS.md is the same convention expressed
# without the canonical comment line, so it is accepted and left untouched
# rather than refused; see claude_md_is_pointer_only for exactly what still
# counts as real content.
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

# Write the canonical pointer as a regular file. Unlink a symlink first so the
# write cannot follow it and destroy AGENTS.md. Never overwrite a distinct real
# file; callers classify that as a conflict before invoking this.
install_claude_pointer() {
  if is_canonical_claude_pointer; then
    return 0
  fi
  if [ -L "$CLAUDE" ]; then
    rm -- "$CLAUDE"
  elif [ -e "$CLAUDE" ]; then
    echo "error: internal: refuse to overwrite existing CLAUDE.md" >&2
    exit 1
  fi
  claude_pointer_content > "$CLAUDE"
}

# Decide whether a real CLAUDE.md file is the captain's pointer-only convention
# rather than a second competing memory file. A pointer-only CLAUDE.md carries no
# knowledge of its own: every line is either blank or an "@AGENTS.md" include, and
# at least one include is present.
#
# The rule tolerates exactly the incidental bytes an editor or a checkout adds
# without changing meaning: a leading UTF-8 byte-order mark, CRLF line endings, a
# missing final newline, blank lines, and leading or trailing whitespace on the
# include line. Everything else - prose, a heading, an HTML comment, a second
# include of another file - counts as real content and keeps the refusal, because
# a human wrote it to be read and merging it away would lose it. Erring strict is
# the safe direction here: the fallback is the existing explicit refusal, which
# asks a human to reconcile, and never touches either file.
claude_md_is_pointer_only() {
  local line first=1 saw_include=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" -eq 1 ]; then
      first=0
      line=${line#$'\xef\xbb\xbf'}
    fi
    line=${line%$'\r'}
    # Trim leading and trailing spaces and tabs.
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    case "$line" in
      "@$AGENTS"|"@./$AGENTS") saw_include=1 ;;
      *) return 1 ;;
    esac
  done < "$CLAUDE"
  [ "$saw_include" -eq 1 ]
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
    # Either form of pointer is the convention, not a conflict: AGENTS.md holds
    # the content and CLAUDE.md only includes it. Proceed against AGENTS.md and
    # leave the pointer exactly as the project wrote it.
    # Both predicates are needed and neither subsumes the other. The canonical
    # check matches the exact two-line file this script writes, comment line
    # included; claude_md_is_pointer_only accepts a project that wrote the bare
    # include itself, and deliberately rejects a comment as real content, so it
    # would refuse this script's own canonical pointer on its own.
    if is_canonical_claude_pointer || claude_md_is_pointer_only; then
      ensure_maintenance_section
      if [ "$MAINT_INJECTED" -eq 1 ]; then
        echo "updated: added ## Maintaining this file to AGENTS.md in $DIR"
      else
        echo "unchanged: AGENTS.md with CLAUDE.md @AGENTS.md pointer in $DIR"
      fi
      exit 0
    fi
    echo "conflict: both AGENTS.md and CLAUDE.md are real files with their own content in $DIR; reconcile them manually" >&2
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
