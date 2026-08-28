#!/usr/bin/env bash
# fm-treehouse-return-lib.sh - fail-closed committed-work guard for Treehouse returns.
#
# Source this library before any `treehouse return --force <worktree>` call.
# fm_treehouse_return <task-id> <worktree> is the only return wrapper it owns:
# it first verifies that HEAD is reachable from a local branch, tag, or prior
# firstmate rescue ref. Remote-tracking refs deliberately do not count because
# they can be pruned and do not retain the work on this machine.
#
# A target that is not a Git worktree has no HEAD commit to certify, so the
# guard passes it through, as does a Git worktree whose HEAD is provably unborn.
# A target bearing a .git entry that Git cannot read is different: it may hold
# committed work, so the guard refuses it.
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

# An unborn HEAD in a worktree nothing has ever been checked out or committed in
# names no commit at all, so there is no committed work for the guard to
# certify. That is a determined state, not an undeterminable one, and it is the
# only HEAD-resolution failure this returns true for: the branch HEAD points at
# must be provably absent from a ref store that answered the question in full -
# git reports a ref it holds but cannot read as a warning rather than an error,
# so any diagnostic disqualifies the answer. A ref store that cannot answer, or
# a HEAD that is not a symbolic refs/heads ref, stays a refusal so damaged
# worktrees keep failing closed.
fm_treehouse_return_head_is_unborn() {  # <worktree-path>
  local worktree_path=$1 head_ref head_log log_updates

  fm_treehouse_return_git "$worktree_path" symbolic-ref -q HEAD || return 1
  head_ref=$FM_TREEHOUSE_RETURN_GIT_OUT
  case "$head_ref" in
    refs/heads/?*) ;;
    *) return 1 ;;
  esac
  fm_treehouse_return_git "$worktree_path" for-each-ref --format='%(refname)' "$head_ref" || return 1
  [ -z "$FM_TREEHOUSE_RETURN_GIT_OUT" ] && [ -z "$FM_TREEHOUSE_RETURN_GIT_ERR" ] || return 1

  # A missing branch ref alone cannot tell "never committed here" apart from a
  # branch deleted out of band while still checked out, which does hold commits.
  # This worktree's own HEAD reflog does: it is absent only while nothing has
  # ever been checked out or committed here. Anything that leaves a HEAD reflog
  # entry - including an orphan checkout over prior history - stays a refusal.
  fm_treehouse_return_git "$worktree_path" rev-parse --git-path logs/HEAD || return 1
  head_log=$FM_TREEHOUSE_RETURN_GIT_OUT
  [ -n "$head_log" ] || return 1
  case "$head_log" in
    /*) ;;
    *) head_log="$worktree_path/$head_log" ;;
  esac
  [ ! -s "$head_log" ] || return 1

  # An absent reflog only proves nothing was committed here while this worktree
  # actually keeps one. A repository that has turned reflogs off can produce the
  # same emptiness with commits present, so that configuration refuses instead.
  fm_treehouse_return_git "$worktree_path" config --get core.logAllRefUpdates \
    && log_updates=$FM_TREEHOUSE_RETURN_GIT_OUT || log_updates=
  case $(printf '%s' "$log_updates" | tr '[:upper:]' '[:lower:]') in
    ''|true|yes|on|always|1) return 0 ;;
    *) return 1 ;;
  esac
}

fm_treehouse_return_guard() {
  local task_id=$1 worktree=$2 worktree_path head head_err refs timestamp base_ref rescue_ref update_err suffix=0

  if ! worktree_path=$(cd -P -- "$worktree" 2>/dev/null && pwd -P) || [ -z "$worktree_path" ]; then
    printf 'REFUSED: cannot determine committed-work reachability for %s: worktree directory is unavailable.\n' \
      "$worktree" >&2
    return 1
  fi

  # Teardown also has safe no-op paths over ordinary directories. They have no
  # Git HEAD (and therefore no committed work subject) for this guard to
  # certify. Do not let an enclosing repository or inherited Git environment
  # turn such a directory into one. Conversely, a .git entry proves this was
  # meant to be a Git worktree, so a failed probe is a fail-closed refusal.
  if ! fm_treehouse_return_git "$worktree_path" rev-parse --is-inside-work-tree; then
    if [ ! -e "$worktree_path/.git" ] && [ ! -L "$worktree_path/.git" ]; then
      return 0
    fi
    printf 'REFUSED: cannot determine committed-work reachability for %s: Git worktree inspection failed (%s).\n' \
      "$worktree" "$FM_TREEHOUSE_RETURN_GIT_ERR" >&2
    return 1
  fi
  if [ "$FM_TREEHOUSE_RETURN_GIT_OUT" != true ]; then
    printf 'REFUSED: cannot determine committed-work reachability for %s: Git did not identify it as a worktree.\n' \
      "$worktree" >&2
    return 1
  fi

  if ! fm_treehouse_return_git "$worktree_path" rev-parse --verify 'HEAD^{commit}'; then
    head_err=$FM_TREEHOUSE_RETURN_GIT_ERR
    fm_treehouse_return_head_is_unborn "$worktree_path" && return 0
    printf 'REFUSED: cannot determine committed-work reachability for %s: git could not resolve HEAD (%s).\n' \
      "$worktree" "$head_err" >&2
    return 1
  fi
  head=$FM_TREEHOUSE_RETURN_GIT_OUT

  # A symbolic HEAD under refs/heads is durable without any revision walk: HEAD
  # resolved above, so that branch exists and its tip IS this commit. Detached
  # HEADs and symbolic refs outside refs/heads fall through to the scan below.
  if fm_treehouse_return_git "$worktree_path" symbolic-ref -q HEAD; then
    case "$FM_TREEHOUSE_RETURN_GIT_OUT" in
      refs/heads/?*) return 0 ;;
    esac
  fi

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
