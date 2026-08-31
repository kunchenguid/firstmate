#!/usr/bin/env bash
# Resolve whether a Codex Desktop repository task may start Firstmate directly
# or must create a visible Firstmate coordinator task first.
#
# Codex Desktop grants write access from the selected project, while globally
# discovered skills are only readable dependencies.
# Unix mode bits therefore cannot prove that another saved project is writable
# from the current task's sandbox.
# This helper compares Git identity without writing anything: a task already in
# the Firstmate repository or one of its worktrees uses that writable root as
# its session home, while every other repository routes through a Desktop-owned
# Firstmate worktree.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_FIRSTMATE="$(cd "$SCRIPT_DIR/.." && pwd -P)"
CWD_INPUT=$PWD
FIRSTMATE_INPUT=$DEFAULT_FIRSTMATE

usage() {
  cat >&2 <<'EOF'
usage: fm-desktop-entry.sh [--cwd <repository-path>] [--firstmate <firstmate-path>]

Prints one-line routing facts for the Codex Desktop host lifecycle.
This command is read-only and never starts a session or creates a Desktop task.
EOF
  exit 2
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

single_line() {
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
}

repo_top() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

git_common_dir() {
  local top=$1 common path
  common=$(git -C "$top" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) path=$common ;;
    *) path=$top/$common ;;
  esac
  CDPATH='' cd -- "$path" 2>/dev/null && pwd -P
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd) [ "$#" -ge 2 ] || usage; CWD_INPUT=$2; shift 2 ;;
    --firstmate) [ "$#" -ge 2 ] || usage; FIRSTMATE_INPUT=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

if ! single_line "$CWD_INPUT" || ! single_line "$FIRSTMATE_INPUT"; then
  die "repository paths must be single-line values"
fi
[ -d "$CWD_INPUT" ] || die "current repository path does not exist: $CWD_INPUT"
[ -d "$FIRSTMATE_INPUT" ] || die "Firstmate path does not exist: $FIRSTMATE_INPUT"

SOURCE_TOP=$(repo_top "$CWD_INPUT") \
  || die "current path is not inside a Git repository: $CWD_INPUT"
FIRSTMATE_TOP=$(repo_top "$FIRSTMATE_INPUT") \
  || die "Firstmate path is not inside a Git repository: $FIRSTMATE_INPUT"
[ -x "$FIRSTMATE_TOP/bin/fm-session-start.sh" ] \
  || die "Firstmate session entry is missing or not executable: $FIRSTMATE_TOP/bin/fm-session-start.sh"
[ -f "$FIRSTMATE_TOP/.agents/skills/firstmate-desktop/SKILL.md" ] \
  || die "Firstmate Desktop skill is missing: $FIRSTMATE_TOP/.agents/skills/firstmate-desktop/SKILL.md"

SOURCE_COMMON=$(git_common_dir "$SOURCE_TOP") \
  || die "cannot resolve current repository identity: $SOURCE_TOP"
FIRSTMATE_COMMON=$(git_common_dir "$FIRSTMATE_TOP") \
  || die "cannot resolve Firstmate repository identity: $FIRSTMATE_TOP"

if [ "$SOURCE_COMMON" = "$FIRSTMATE_COMMON" ]; then
  printf 'mode=direct\n'
  printf 'firstmate_code=%s\n' "$SOURCE_TOP"
  printf 'session_home=%s\n' "$SOURCE_TOP"
  exit 0
fi

printf 'mode=coordinator\n'
printf 'source_project=%s\n' "$SOURCE_TOP"
printf 'firstmate_code=%s\n' "$FIRSTMATE_TOP"
if [ -n "$(git -C "$FIRSTMATE_TOP" status --porcelain 2>/dev/null)" ]; then
  printf 'coordinator_starting_state=working-tree\n'
else
  printf 'coordinator_starting_state=default\n'
fi
