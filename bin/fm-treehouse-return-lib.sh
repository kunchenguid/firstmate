#!/usr/bin/env bash
# fm-treehouse-return-lib.sh - fail-closed committed-work guard for Treehouse returns.
#
# Source this library before any `treehouse return --force <worktree>` call.
# fm_treehouse_return <task-id> <worktree> is the only return wrapper it owns:
# it first verifies that HEAD is reachable from a local branch, tag, or prior
# firstmate rescue ref. Remote-tracking refs deliberately do not count because
# they can be pruned and do not retain the work on this machine.
#
# When HEAD has no durable ref, the wrapper adds
# refs/firstmate/rescue/<task-id>/<timestamp> at HEAD before it returns the
# worktree. If Git cannot resolve HEAD, enumerate the allowed refs, or create
# the rescue ref, it refuses without calling Treehouse.

fm_treehouse_return_task_id_safe() {
  local id=${1-}
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  git check-ref-format "refs/firstmate/rescue/$id/task" >/dev/null 2>&1
}

fm_treehouse_return_guard() {
  local task_id=$1 worktree=$2 head refs err timestamp base_ref rescue_ref suffix=0

  if ! fm_treehouse_return_task_id_safe "$task_id"; then
    printf 'REFUSED: cannot return %s because task id %s is unsafe for a rescue ref.\n' \
      "$worktree" "${task_id:-<empty>}" >&2
    return 1
  fi
  if [ ! -d "$worktree" ]; then
    printf 'REFUSED: cannot determine committed-work reachability for %s: worktree directory is unavailable.\n' \
      "$worktree" >&2
    return 1
  fi

  if ! head=$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>&1); then
    printf 'REFUSED: cannot determine committed-work reachability for %s: git could not resolve HEAD (%s).\n' \
      "$worktree" "$head" >&2
    return 1
  fi

  if ! refs=$(git -C "$worktree" for-each-ref --contains="$head" --format='%(refname)' \
    refs/heads refs/tags refs/firstmate/rescue 2>&1); then
    printf 'REFUSED: cannot determine committed-work reachability for %s at %s: git ref scan failed (%s).\n' \
      "$worktree" "$head" "$refs" >&2
    return 1
  fi
  [ -z "$refs" ] || return 0

  if ! timestamp=$(date -u +%Y%m%dT%H%M%SZ 2>&1); then
    printf 'REFUSED: cannot create a rescue ref for %s at %s: timestamp generation failed (%s).\n' \
      "$worktree" "$head" "$timestamp" >&2
    return 1
  fi
  base_ref="refs/firstmate/rescue/$task_id/$timestamp"
  rescue_ref=$base_ref

  while :; do
    if err=$(git -C "$worktree" update-ref "$rescue_ref" "$head" '' 2>&1); then
      printf 'RESCUED: committed work at %s had no durable ref; created %s before returning %s.\n' \
        "$head" "$rescue_ref" "$worktree"
      return 0
    fi

    if git -C "$worktree" show-ref --verify --quiet "$rescue_ref"; then
      suffix=$((suffix + 1))
      if [ "$suffix" -gt 99 ]; then
        printf 'REFUSED: cannot create a unique rescue ref for %s at %s after 100 timestamp collisions.\n' \
          "$worktree" "$head" >&2
        return 1
      fi
      rescue_ref="${base_ref}-${suffix}"
      continue
    fi

    printf 'REFUSED: cannot create rescue ref %s for %s at %s: %s.\n' \
      "$rescue_ref" "$worktree" "$head" "$err" >&2
    return 1
  done
}

fm_treehouse_return() {
  local task_id=$1 worktree=$2

  fm_treehouse_return_guard "$task_id" "$worktree" || return 1
  treehouse return --force "$worktree"
}
