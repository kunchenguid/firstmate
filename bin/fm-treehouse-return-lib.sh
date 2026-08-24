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
# the rescue ref, it refuses without calling Treehouse and exits
# FM_TREEHOUSE_RETURN_GUARD_REFUSED; committed work that could not be certified
# must never be discarded, so callers must preserve the worktree on that status.

fm_treehouse_return_task_id_safe() {
  local id=${1-}
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  git check-ref-format "refs/firstmate/rescue/$id/task" >/dev/null 2>&1
}

# Run git against exactly the given worktree: repository discovery is capped at
# its parent so a missing or damaged .git pointer cannot silently resolve an
# enclosing repository, and every inherited repository override is cleared so
# an ambient GIT_DIR (which skips discovery entirely) or GIT_NAMESPACE cannot
# point the reachability check at another repository's refs. Stdout and stderr
# are captured separately so diagnostics printed by a damaged ref store never
# masquerade as command output.
FM_TREEHOUSE_RETURN_GIT_OUT=
FM_TREEHOUSE_RETURN_GIT_ERR=
fm_treehouse_return_git() {  # <worktree> <git args...>
  local worktree=$1 errfile rc
  shift
  FM_TREEHOUSE_RETURN_GIT_OUT=
  FM_TREEHOUSE_RETURN_GIT_ERR=
  if ! errfile=$(mktemp "${TMPDIR:-/tmp}/fm-treehouse-return.XXXXXX" 2>/dev/null); then
    FM_TREEHOUSE_RETURN_GIT_ERR='could not create a temporary file to capture git diagnostics'
    return 125
  fi
  FM_TREEHOUSE_RETURN_GIT_OUT=$(GIT_CEILING_DIRECTORIES=$(dirname -- "$worktree") \
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_NAMESPACE \
      -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
      git -C "$worktree" "$@" 2>"$errfile")
  rc=$?
  FM_TREEHOUSE_RETURN_GIT_ERR=$(cat "$errfile" 2>/dev/null)
  rm -f -- "$errfile"
  return "$rc"
}

fm_treehouse_return_guard() {
  local task_id=$1 worktree=$2 worktree_path head refs timestamp base_ref rescue_ref update_err suffix=0

  if ! worktree_path=$(cd -P -- "$worktree" 2>/dev/null && pwd -P) || [ -z "$worktree_path" ]; then
    printf 'REFUSED: cannot determine committed-work reachability for %s: worktree directory is unavailable.\n' \
      "$worktree" >&2
    return 1
  fi

  if ! fm_treehouse_return_git "$worktree_path" rev-parse --verify 'HEAD^{commit}'; then
    printf 'REFUSED: cannot determine committed-work reachability for %s: git could not resolve HEAD (%s).\n' \
      "$worktree" "$FM_TREEHOUSE_RETURN_GIT_ERR" >&2
    return 1
  fi
  head=$FM_TREEHOUSE_RETURN_GIT_OUT

  if ! fm_treehouse_return_git "$worktree_path" for-each-ref --contains="$head" --format='%(refname)' \
    refs/heads refs/tags refs/firstmate/rescue; then
    printf 'REFUSED: cannot determine committed-work reachability for %s at %s: git ref scan failed (%s).\n' \
      "$worktree" "$head" "$FM_TREEHOUSE_RETURN_GIT_ERR" >&2
    return 1
  fi
  refs=$FM_TREEHOUSE_RETURN_GIT_OUT
  [ -z "$refs" ] || return 0

  if ! fm_treehouse_return_task_id_safe "$task_id"; then
    printf 'REFUSED: cannot rescue committed work at %s for %s because task id %s is unsafe for a rescue ref.\n' \
      "$head" "$worktree" "${task_id:-<empty>}" >&2
    return 1
  fi

  if ! timestamp=$(date -u +%Y%m%dT%H%M%SZ 2>&1); then
    printf 'REFUSED: cannot create a rescue ref for %s at %s: timestamp generation failed (%s).\n' \
      "$worktree" "$head" "$timestamp" >&2
    return 1
  fi
  base_ref="refs/firstmate/rescue/$task_id/$timestamp"
  rescue_ref=$base_ref

  while :; do
    if fm_treehouse_return_git "$worktree_path" update-ref "$rescue_ref" "$head" ''; then
      printf 'RESCUED: committed work at %s had no durable ref; created %s before returning %s.\n' \
        "$head" "$rescue_ref" "$worktree"
      return 0
    fi
    update_err=$FM_TREEHOUSE_RETURN_GIT_ERR

    if fm_treehouse_return_git "$worktree_path" show-ref --verify --quiet "$rescue_ref"; then
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
      "$rescue_ref" "$worktree" "$head" "$update_err" >&2
    return 1
  done
}

# Exit status reserved for a guard refusal, so callers can tell "the committed
# work here was never certified" apart from an ordinary Treehouse failure and
# keep the worktree instead of reclaiming its slot.
FM_TREEHOUSE_RETURN_GUARD_REFUSED=3

fm_treehouse_return() {
  local task_id=$1 worktree=$2 rc

  fm_treehouse_return_guard "$task_id" "$worktree" \
    || return "$FM_TREEHOUSE_RETURN_GUARD_REFUSED"

  treehouse return --force "$worktree" && return 0
  rc=$?
  [ "$rc" -ne "$FM_TREEHOUSE_RETURN_GUARD_REFUSED" ] || rc=1
  return "$rc"
}
