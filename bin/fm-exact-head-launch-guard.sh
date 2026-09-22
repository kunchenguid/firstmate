#!/usr/bin/env bash
# Pane-side exact-head launch gate. This is the last program run before a
# reviewed worker command. It writes one atomic receipt under the private launch
# directory, then returns success only when the requested HEAD and the complete
# worktree custody scan both pass at this boundary.
# Usage: fm-exact-head-launch-guard.sh <worktree> <40-hex-head> <receipt>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-exact-head-lib.sh
. "$SCRIPT_DIR/fm-exact-head-lib.sh"

worktree=${1:-}
expected=${2:-}
receipt=${3:-}

write_receipt() { # <status> <reason>
  local status=$1 reason=$2 tmp
  [ -n "$receipt" ] || return 1
  tmp="$receipt.tmp.$$"
  (umask 077 && {
    printf 'schema=fm-exact-head-launch.v1\n'
    printf 'status=%s\n' "$status"
    printf 'expected_head=%s\n' "$expected"
    printf 'reason=%s\n' "$reason"
  } >"$tmp") || return 1
  mv -f -- "$tmp" "$receipt"
}

refuse() { # <reason>
  write_receipt refused "$1" || true
  printf 'error: exact-head launch guard refused: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 3 ] || refuse invalid-arguments
case "$worktree" in /*) ;; *) refuse invalid-worktree ;; esac
case "$receipt" in /*) ;; *) refuse invalid-receipt ;; esac
case "$expected" in *[!0-9a-f]*|'') refuse invalid-expected-head ;; esac
[ "${#expected}" -eq 40 ] || refuse invalid-expected-head
[ -d "$worktree" ] || refuse missing-worktree
[ ! -e "$receipt" ] && [ ! -L "$receipt" ] || refuse receipt-already-exists

# Repository/ref resolution at the worker boundary must not inherit ambient Git
# redirection or replacement-object state from the pane shell.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE \
  GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM \
  GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
export GIT_NO_REPLACE_OBJECTS=1

actual=$(git -C "$worktree" rev-parse --verify --quiet HEAD 2>/dev/null) \
  || refuse unreadable-head
[ "$actual" = "$expected" ] || refuse head-mismatch

status=$(expected_head_worktree_status "$worktree") || refuse unreadable-worktree
[ -z "$status" ] || refuse dirty-worktree

# A ref race during the full byte scan cannot substitute another commit. Read
# HEAD again, then run the complete scan once more so a write triggered by that
# coordinate read is still rejected before the worker command begins.
actual=$(git -C "$worktree" rev-parse --verify --quiet HEAD 2>/dev/null) \
  || refuse unreadable-head
[ "$actual" = "$expected" ] || refuse head-mismatch
status=$(expected_head_worktree_status "$worktree") || refuse unreadable-worktree
[ -z "$status" ] || refuse dirty-worktree

write_receipt verified clean || refuse receipt-write-failed
