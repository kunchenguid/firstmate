#!/usr/bin/env bash
# Resolve the Claude Code session ID (and derived resume URL) for a
# firstmate/crewmate home's actively written transcript, for the section-7
# FirstMate/crew identification blocks in docs/evidence-preservation-lifecycle.md
# (yagakeerthikiran/agentlab-shared-memory).
#
# Prefers CLAUDE_CODE_SESSION_ID from the calling process's own environment
# (authoritative and free: set by the running Claude Code harness for its own
# session). Falls back to the newest top-level *.jsonl transcript file under
# ~/.claude/projects/<slug-of-home>/ (Claude Code's own project-transcript
# layout: an absolute cwd path with every '/' and '.' replaced by '-'), which
# is "actively written" in the sense of most-recently-modified; a nested
# subagent-transcript directory of the same name is deliberately not
# descended into.
# FM_CLAUDE_PROJECTS_DIR overrides the projects root for tests.
#
# Usage: fm-session-id.sh [<home-dir>]
#   <home-dir> defaults to FM_HOME, then the caller's cwd.
# Prints, on success:
#   session_id=<uuid>
#   resume_url=https://claude.ai/code/session_<uuid>
# and exits 0. On failure, prints:
#   session_id=UNAVAILABLE
#   reason=<why>
# and exits 1.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

HOME_DIR=${1:-${FM_HOME:-$(pwd)}}
PROJECTS_DIR=${FM_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}

unavailable() {
  printf 'session_id=UNAVAILABLE\n'
  printf 'reason=%s\n' "$1"
  exit 1
}

if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  printf 'session_id=%s\n' "$CLAUDE_CODE_SESSION_ID"
  printf 'resume_url=https://claude.ai/code/session_%s\n' "$CLAUDE_CODE_SESSION_ID"
  exit 0
fi

HOME_ABS=$(CDPATH='' cd -- "$HOME_DIR" 2>/dev/null && pwd -P) || {
  unavailable "home directory cannot be resolved: $HOME_DIR"
}
SLUG=$(printf '%s' "$HOME_ABS" | sed 's/[\/.]/-/g')
TRANSCRIPT_DIR="$PROJECTS_DIR/$SLUG"

[ -d "$TRANSCRIPT_DIR" ] || {
  unavailable "no CLAUDE_CODE_SESSION_ID in environment and no transcript directory at $TRANSCRIPT_DIR"
}

# Portable newest-mtime pick: `find -printf` is a GNU extension BSD/macOS find
# lacks, so mtimes are read one file at a time instead (bin/fm-lock-lib.sh's
# fm_lock_path_mtime owns the same GNU/BSD stat(1) split).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}
NEWEST=
NEWEST_MTIME=-1
for f in "$TRANSCRIPT_DIR"/*.jsonl; do
  [ -f "$f" ] || continue
  m=$(file_mtime "$f") || continue
  case "$m" in ''|*[!0-9]*) continue ;; esac
  if [ "$m" -gt "$NEWEST_MTIME" ]; then
    NEWEST_MTIME=$m
    NEWEST=$f
  fi
done
[ -n "$NEWEST" ] || {
  unavailable "no CLAUDE_CODE_SESSION_ID in environment and no *.jsonl transcript found under $TRANSCRIPT_DIR"
}

SESSION_ID=$(basename "$NEWEST" .jsonl)
printf 'session_id=%s\n' "$SESSION_ID"
printf 'resume_url=https://claude.ai/code/session_%s\n' "$SESSION_ID"
