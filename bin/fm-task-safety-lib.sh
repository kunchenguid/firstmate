#!/usr/bin/env bash
# Shared non-destructive task safety primitives.
#
# This file is the one owner for checks used before either final teardown or
# latent hibernation can release a task worktree: exact endpoint identity,
# Firstmate's narrow control-file dirty exclusions, worktree Git lock
# resolution, and cwd-scoped process discovery.
# Callers own their distinct authorization proofs.  In particular,
# fm-teardown.sh still requires landed work, while fm-latent.sh requires an
# exact open GitHub PR head protected by a Firstmate recovery ref.

fm_task_safety_validate_endpoint() {  # <meta> <task-id>
  fm_backend_validate_task_endpoint "$1" "$2"
}

# Print the first dirty status entry after excluding only Firstmate's generated
# per-worker control files.  An empty result means clean.  A Git failure is
# propagated so callers never read uncertainty as cleanliness.
fm_task_safety_dirty_first() {  # <worktree>
  local raw
  raw=$(git -C "$1" status --porcelain) || return 1
  printf '%s\n' "$raw" \
    | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' \
    | head -1 || true
}

fm_task_safety_worktree_clean() {  # <worktree>
  local dirty
  dirty=$(fm_task_safety_dirty_first "$1") || return 1
  [ -z "$dirty" ]
}

fm_task_safety_canonical_existing_dir() {  # <directory>
  [ -n "$1" ] && [ -d "$1" ] || return 1
  ( CDPATH='' cd -- "$1" && pwd -P )
}

# Absolute index.lock path for one worktree, or nonzero when it cannot be
# resolved.  The staleness decision remains in fm-lock-lib.sh.
fm_task_safety_worktree_git_lock_path() {  # <worktree>
  local dir=$1 lock abs_dir
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(fm_task_safety_canonical_existing_dir "$dir") || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

fm_task_safety_retry_wait_valid() {  # <seconds>
  [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

fm_task_safety_treehouse_index_lock_error() {  # <stderr/stdout>
  printf '%s\n' "$1" | grep -Eq "Unable to create ['\"].*index\\.lock['\"]: File exists"
}

# Print every process whose current directory is the exact root or a
# descendant.  lsof uncertainty is an error, never an empty process set.
fm_task_safety_pids_with_cwd_under() {  # <directory>
  local dir=$1 out pid path
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  dir=$(CDPATH='' cd -- "$dir" && pwd -P) || return 1
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  pid=
  while IFS= read -r line; do
    case "$line" in
      p*)
        pid=${line#p}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        ;;
      fcwd) [ -n "$pid" ] || return 1 ;;
      n*)
        [ -n "$pid" ] || return 1
        path=${line#n}
        case "$path" in
          "$dir"|"$dir"/*)
            [ "$pid" = "$$" ] || printf '%s\n' "$pid"
            ;;
        esac
        ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
}

# Only an authoritatively missing endpoint proves that termination completed.
# A dead shell, ambiguous inventory, or unreadable backend is not enough.
fm_task_safety_backend_terminated() {  # <backend> <target>
  [ "$(fm_backend_agent_state "$1" "$2")" = missing ]
}
