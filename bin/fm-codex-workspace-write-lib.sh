#!/usr/bin/env bash
# Narrow Codex workspace-write grants for linked task worktrees.
#
# Codex launches under -s workspace-write; the task worktree grant alone does
# not cover linked Git metadata. A linked worktree keeps its refs, objects, and
# index outside that root (the shared common Git directory and the
# per-worktree admin directory), and the brief's status and instruction-inbox
# writes land in the owning Firstmate home, so those operations need additional
# grants when the paths are outside existing writable roots. fm-spawn composes these roots
# as repeatable --add-dir flags, which add to an operator's own roots instead
# of replacing them, and pre-creates the grant paths before launch. The added
# roots cover the shared object store and this task's worktree admin, report
# directory, status file, inbox, and exact branch ref/reflog transactions: never the
# home, the state or data roots, the whole common Git directory, a ref
# namespace, sibling worktrees, or credentials.

# Resolve and print the nine writable roots, one absolute path per line.
fm_codex_workspace_write_roots() {  # <worktree> <task-data-dir> <task-status> <task-inbox> <task-id>
  local worktree=$1 task_data=$2 task_status=$3 task_inbox=$4 task_id=$5
  local common git_dir ref reflog
  case "$task_id" in ''|.|..|-*|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  worktree=$(cd "$worktree" 2>/dev/null && pwd -P) || return 1
  task_data="$(cd "$(dirname "$task_data")" 2>/dev/null && pwd -P)/$(basename "$task_data")" || return 1
  task_status="$(cd "$(dirname "$task_status")" 2>/dev/null && pwd -P)/$(basename "$task_status")" || return 1
  task_inbox="$(cd "$(dirname "$task_inbox")" 2>/dev/null && pwd -P)/$(basename "$task_inbox")" || return 1
  common=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  git_dir=$(git -C "$worktree" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  # A crew always receives a linked worktree. Refuse a plain checkout rather
  # than broadening this task-local grant to its whole common Git directory.
  case "$git_dir" in "$common"/worktrees/*) ;; *) return 1 ;; esac
  ref="$common/refs/heads/fm/$task_id"
  reflog="$common/logs/refs/heads/fm/$task_id"
  printf '%s\n' "$common/objects" "$git_dir" "$task_data" "$task_status" \
    "$task_inbox" "$ref" "$ref.lock" "$reflog" "$reflog.lock"
}

# Pre-create every grant path that must exist before Codex resolves --add-dir.
# Git creates the ref and reflog files themselves; their parents must already
# exist because the exact-file roots do not authorize creating directories.
# Refuses symlinked grant paths rather than authorizing the link target.
fm_codex_workspace_write_prepare() {  # <worktree> <task-data-dir> <task-status> <task-inbox> <task-id>
  local roots root inbox common
  roots=$(fm_codex_workspace_write_roots "$@") || return 1
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$root" in "$common/refs/"*|"$common/logs/"*) continue ;; esac
    case "$root" in
      *.status) : >> "$root" || return 1 ;;
      *) mkdir -p "$root" || return 1 ;;
    esac
    [ ! -L "$root" ] || return 1
  done <<< "$roots"
  # The acknowledgement move needs the handled/ directory to exist. It is
  # resolved the same way the roots resolve the inbox path.
  inbox="$(cd "$(dirname "$4")" 2>/dev/null && pwd -P)/$(basename "$4")" || return 1
  mkdir -p "$inbox/handled" || return 1
  [ ! -L "$inbox/handled" ] || return 1
  mkdir -p "$common/refs/heads/fm" "$common/logs/refs/heads/fm" || return 1
  [ ! -L "$common/refs/heads/fm" ] && [ ! -L "$common/logs/refs/heads/fm" ] || return 1
}
