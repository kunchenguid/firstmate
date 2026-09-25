#!/usr/bin/env bash
# Ensure the real AGENTS.md project-memory file and its self-governance guidance.
# Creates only AGENTS.md. Never creates, rewrites, removes, or retargets an
# existing CLAUDE.md. If it alone holds real knowledge, copy it into AGENTS.md;
# accept that exact copy (with optional helper-added governance) on later runs.
# Existing legacy pointers and correct links to AGENTS.md remain untouched.
# Distinct knowledge files, wrong links, non-regular files, an AGENTS.md symlink,
# and case-variant agents.md names fail closed before any project file changes.
# Owns the canonical "## Maintaining this file" wording, injected idempotently
# unless the exact heading or this exact first line already exists (LF or CRLF):
# <!-- firstmate:maintained-by-project -->
# The mark declares equivalent project-owned guidance, not permission to remove
# governance. No prose equivalence is inferred.
# This is a worktree utility, not a supervision script; it does not call fm-guard.sh.
# Usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]
set -eu

usage() {
  echo "usage: fm-ensure-agents-md.sh [repo-or-worktree-dir]" >&2
  cat >&2 <<'EOF'

Creates or updates AGENTS.md only; existing CLAUDE.md files and links are preserved.

To retain equivalent project-owned maintenance guidance without adding the
canonical section, use this exact first line of AGENTS.md (LF or CRLF):
<!-- firstmate:maintained-by-project -->
The mark declares retained guidance, not permission to remove governance.
Without the first-line mark or exact canonical heading, the helper adds the section.
EOF
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

# Idempotently append the canonical self-governance section to AGENTS.md when
# neither its heading nor the first-line project-owned mark is present. Sets
# MAINT_INJECTED=1 when it appends and 0 otherwise, for caller change reporting.
MAINT_INJECTED=0
ensure_maintenance_section() {
  local memory=${1:-$AGENTS}
  MAINT_INJECTED=0
  if grep -Fqx -e '## Maintaining this file' -e $'## Maintaining this file\r' "$memory" ||
    head -n 1 "$memory" | grep -Fqx -e '<!-- firstmate:maintained-by-project -->' \
      -e $'<!-- firstmate:maintained-by-project -->\r'; then
    return 0
  fi
  local eol=$'\n' sep=''
  if LC_ALL=C grep -q $'\r$' "$memory"; then
    eol=$'\r\n'
  fi
  if [ -s "$memory" ]; then
    if [ -n "$(tail -c 1 "$memory")" ]; then
      sep="${eol}${eol}"
    else
      sep=$eol
    fi
  fi
  {
    printf '%s' "$sep"
    write_maintenance_section_with_eol "$eol"
  } >> "$memory"
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

# Recognize the old generated pointer for safe migration, never emit a new one.
is_canonical_claude_pointer() {
  [ -f "$CLAUDE" ] && [ ! -L "$CLAUDE" ] || return 1
  cmp -s "$CLAUDE" - <<'EOF'
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
}

# An unchanged legacy copy, optionally with our appended governance, is not a
# conflict. Compare the exact normalized bytes rather than guessing equivalence.
legacy_matches_agents() {
  cmp -s "$CLAUDE" "$AGENTS" && return 0
  (
    local copy
    copy=$(mktemp) || exit 1
    trap 'rm -f -- "$copy"' EXIT
    cp -- "$CLAUDE" "$copy" || exit 1
    ensure_maintenance_section "$copy" || exit 1
    cmp -s "$copy" "$DIR/AGENTS.md"
  )
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

# Refuse ambiguous casing so the canonical project memory remains portable.
for entry in *; do
  if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
    continue
  fi
  if [ "$entry" != "$AGENTS" ]; then
    case "$entry" in
      [Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd])
        echo "conflict: memory file is named $entry in $DIR but the convention is AGENTS.md; reconcile it as AGENTS.md for portable context discovery" >&2
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

# Validate legacy inputs before creating or appending to AGENTS.md.
if [ -L "$CLAUDE" ]; then
  if ! is_correct_claude_symlink; then
    echo "conflict: CLAUDE.md is a symlink in $DIR but does not point to AGENTS.md" >&2
    exit 1
  fi
elif [ -e "$CLAUDE" ]; then
  if [ ! -f "$CLAUDE" ]; then
    echo "conflict: CLAUDE.md exists in $DIR but is not a regular file or symlink" >&2
    exit 1
  fi
  if [ -e "$AGENTS" ] && ! is_canonical_claude_pointer && ! legacy_matches_agents; then
    echo "conflict: AGENTS.md and CLAUDE.md contain distinct knowledge in $DIR; reconcile them manually" >&2
    exit 1
  fi
fi

if [ -e "$AGENTS" ]; then
  ensure_maintenance_section
  if [ "$MAINT_INJECTED" -eq 1 ]; then
    echo "updated: added ## Maintaining this file to AGENTS.md in $DIR"
  else
    echo "unchanged: AGENTS.md in $DIR"
  fi
elif [ -f "$CLAUDE" ] && [ ! -L "$CLAUDE" ] && ! is_canonical_claude_pointer; then
  cp -- "$CLAUDE" "$AGENTS"
  ensure_maintenance_section
  echo "copied: existing CLAUDE.md knowledge into AGENTS.md in $DIR; original preserved"
else
  write_skeleton
  echo "created: AGENTS.md in $DIR"
fi
