#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree, release the Orca
# worktree, or retire a secondmate home; kill the recorded runtime endpoint,
# clear volatile state, refresh/prune the project's clone for PR-based ship
# tasks, then print a backlog-refresh reminder for ship and scout teardowns
# (a secondmate teardown prints none, since secondmates are not backlog items).
# REFUSES if the worktree holds work that has not LANDED, because cleanup
# hard-resets/removes the worktree and kills its processes. Work has landed when it is
# reachable from any remote-tracking branch (a fork counts as a remote, so
# upstream-contribution PRs pushed to a fork satisfy this in any mode), OR - for a
# normal ship task whose commits are not so reachable - when its PR is merged and
# GitHub reports a PR head that contains the current local work, or its content is
# already present in the up-to-date default branch. This recognizes the common
# squash-merge-then-delete-branch flow, where the branch's own commits live nowhere
# on a remote yet the change is fully in main.
# The PR itself is resolved from the task's recorded pr= when present, or - when
# no pr= was ever recorded (e.g. a yolo-authorized merge on a repo with no PR CI,
# where the usual "checks green" fm-pr-check.sh trigger never fires) - by looking
# up a merged PR whose head branch matches the worktree's branch, fetching its head
# via refs/pull/<n>/head when the branch itself was deleted. So a missing pr= never
# by itself causes a false refusal of landed work.
# A gh lookup error falls back to the content check; if that is also inconclusive,
# teardown refuses rather than risk discarding unlanded work.
# Origin-backed content checks hold the shared checkout lock and require bounded
# remote HEAD probes before and after fetch to agree before comparing trees.
# Every authorized Treehouse return is process-tree bounded by
# FM_TREEHOUSE_RETURN_TIMEOUT while holding the same common checkout mutation
# lock across its retry and stale-index-lock recovery sequence.
# Uncommitted changes are never landed.
# Ordinary teardown first proves that metadata names the exact registered project,
# worktree, and task lease, then quiesces the endpoint before its final safety checks.
# Each locked Treehouse return repeats repository, lease, and landed-work checks
# immediately before the destructive return command.
# A cleanly unleased Treehouse slot means an operator already returned it.
# Teardown still repeats the landed-work proof under the checkout lock, skips a
# second return, and clears only the orphaned task bookkeeping.
# Only the explicit patterns in teardown_path_is_known_tool_artifact are excluded
# from non-ignored dirty-work detection.
# Git-ignored files do not block reclaim and are not preserved as scratch.
# Before returning a leased worktree, teardown reports their directory-collapsed
# count and deduplicated top-level paths without inventorying or archiving them.
# --preserve-scratch first proves committed work landed, captures tracked diffs
# and non-ignored untracked payloads under data/<task-id>/scratch/, then cleans
# and repeats the ordinary safety proof before reclaim proceeds.
# local-only projects additionally accept work merged into the local default
# branch (firstmate performs that merge on the captain's approval) as a fallback
# for the common case where there is no remote at all.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product. A pre-cutover scout proceeds once that report exists; a task carrying
# report_required=1 must satisfy the shared completion and publication contract
# owned by docs/report-stack.md before teardown discards the scratch worktree.
# Orca tasks use the same safety checks, then close the recorded terminal, prove
# the handle stale, and remove the recorded worktree under its checkout lock;
# teardown never substitutes the shared window alias for a missing terminal.
# Secondmates (kind=secondmate in meta) are retired explicitly. Teardown proves
# the home clean and every ref and reflog commit landed. Without --force it also
# proves the child-secondmate registry empty before quiescing the endpoint, so a
# known refusal never stops a live supervisor; the same proof is repeated after
# quiescence. It still refuses while the home has in-flight crewmate meta files.
# --force authorizes recursive retirement only after every child passes the same
# endpoint, identity, cleanliness, stash, and landed-work proofs. A retiring
# project's linked worktrees are admitted only when attributable to registered
# child metadata. Project retirement also rejects symlinked operational
# directories, mount boundaries, rewritten history, and landing authorities whose
# complete Git object storage or network transport may depend on the retiring home
# or local machine. Removing a leased home releases its durable treehouse lease so
# the pool slot is freed,
# never left leased forever. If the treehouse return fails, teardown leaves the
# leased home and state in place instead of hiding a still-held lease.
# Usage: fm-teardown.sh <task-id> [--force] [--preserve-scratch]
#   --force permits recursive kind=secondmate retirement. It never bypasses
#   dirty, untracked, stash, landed-work, endpoint, identity, or report proofs.
#   --preserve-scratch permits a ship/scout teardown to preserve tracked diffs
#   and non-ignored untracked files under data/<task-id>/scratch/ before cleaning.
#   Ignored files remain exempt and are summarized before a leased return.
#   Committed work must still pass the ordinary landed-work proof first.
#
# Transient / stale worktree git lock recovery (teardown-lock-race): a crewmate process
# killed mid-git-operation can leave a .git/worktrees/<wt>/index.lock (or, for a
# non-linked worktree, .git/index.lock) that makes `treehouse return --force` fail
# with Unable to create '...index.lock': File exists. That lock is usually transient
# (the dying process finishes or exits within seconds) and must never be force-deleted
# while a live git process might still own it - the fix is patience, not rm.
#
# On that failure signature only, teardown_treehouse_return:
#   1. Retries up to FM_TREEHOUSE_RETURN_LOCK_RETRIES times (default 3), waiting
#      FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS (default 1s; falls back to the older
#      FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS name when the new one is unset) between
#      attempts. Retries key off the error text, not whether the lock file still
#      exists after the failed attempt - a lock that self-clears mid-check still
#      deserves a retry of the return.
#   2. Other treehouse return failures still abort immediately and loudly (no retry).
#   3. If every retry still hits the lock signature and the lock remains, it is removed
#      and the return tried once more ONLY when the lock is provably stale per
#      bin/fm-lock-lib.sh's fm_lock_is_provably_stale, passing the worktree dir as the
#      companion directory and FM_STALE_WORKTREE_LOCK_AGE_SECS (default 30s) as the age
#      threshold. That shared proof owns the exact lsof-holder, mtime-age, and fail-safe
#      rules.
#   4. If retries exhaust and the lock is not provably stale, teardown fails as loudly
#      as a normal return failure and notes that the lock persisted across the retry
#      window. A missing `lsof`, or a lock that fails any stale check, is treated as
#      NOT provably stale (fail safe): the lock is left untouched.
# The same proof is used when non-force safety inspection cannot run because the lock
# is present; teardown clears only a provably stale lock, then re-runs the safety
# checks before any destructive return. Teardown output notes every wait, retry, and
# removal so the operator can see what happened.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# Same canonical resolution every other script uses (fm-spawn, fm-bootstrap,
# fm-home-seed, fm-fleet-sync, fm-fleet-snapshot, fm-checkout-refresh): with
# FM_HOME set, `projects/` is an operational dir of the HOME, not of the repo.
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CHECKOUT_STATE_BASE="${FM_CHECKOUT_REFRESH_STATE_BASE:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/checkout-refresh}"
SECONDMATE_REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-checkout-lock-lib.sh
. "$SCRIPT_DIR/fm-checkout-lock-lib.sh"
CHECKOUT_LOCK_ROOT=$(fm_checkout_lock_root "$CHECKOUT_STATE_BASE")
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-process-tree-lib.sh
. "$SCRIPT_DIR/fm-process-tree-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never tear
# down a worktree (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
FM_LOCK_LOG_PREFIX=teardown
"$FM_ROOT/bin/fm-guard.sh" || true
TEARDOWN_UPSTREAM_TIMEOUT=${FM_CHECKOUT_REFRESH_PROBE_TIMEOUT:-15}
case "$TEARDOWN_UPSTREAM_TIMEOUT" in
  ''|*[!0-9]*|0)
    echo "error: FM_CHECKOUT_REFRESH_PROBE_TIMEOUT must be a positive integer" >&2
    exit 2
    ;;
esac
[ "$#" -ge 1 ] || {
  echo "usage: fm-teardown.sh <task-id> [--force] [--preserve-scratch]" >&2
  exit 2
}
ID=$1
shift
FORCE=
PRESERVE_SCRATCH=0
for option in "$@"; do
  case "$option" in
    --force)
      [ -z "$FORCE" ] || {
        echo "error: duplicate teardown option: --force" >&2
        exit 2
      }
      FORCE=--force
      ;;
    --preserve-scratch)
      [ "$PRESERVE_SCRATCH" -eq 0 ] || {
        echo "error: duplicate teardown option: --preserve-scratch" >&2
        exit 2
      }
      PRESERVE_SCRATCH=1
      ;;
    *)
      echo "error: unknown teardown option: $option" >&2
      exit 2
      ;;
  esac
done

META="$STATE/$ID.meta"

require_safe_task_metadata() {
  local state_root meta_parent
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
    echo "error: task state must be a real directory: $STATE" >&2
    return 1
  }
  [ -f "$META" ] && [ ! -L "$META" ] && [ -r "$META" ] || {
    echo "error: task metadata must be a real readable file for $ID at $META" >&2
    return 1
  }
  state_root=$(cd "$STATE" 2>/dev/null && pwd -P) || return 1
  meta_parent=$(cd "$(dirname "$META")" 2>/dev/null && pwd -P) || return 1
  [ "$state_root" = "$meta_parent" ] && [ "$(basename "$META")" = "$ID.meta" ] || {
    echo "error: task metadata identity does not match requested task $ID" >&2
    return 1
  }
}

require_safe_task_metadata || exit 1
TEARDOWN_ACCOUNT_LOCKS=('')
MANAGED_ACCOUNT_LOCK=
ACCOUNT_DELETE_LOCK=
SECONDMATE_HOME_LIFECYCLE_LOCK=
SECONDMATE_REGISTRY_LOCK=
PREPARED_REGISTRY_PATH=
PREPARED_REGISTRY_BACKUP=
PREPARED_REGISTRY_ID=
PREPARED_REGISTRY_HOME=
PREPARED_REGISTRY_LOCK=

release_teardown_account_locks() {
  local lock
  for lock in "${TEARDOWN_ACCOUNT_LOCKS[@]}"; do
    [ -n "$lock" ] || continue
    fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true
  done
}
trap release_teardown_account_locks EXIT

managed_account_meta() {
  [ -n "$(fm_meta_get "$1" account_profile)" ] || [ "$(fm_meta_get "$1" account_rollback_cleanup)" = pending ]
}

MANAGED_ACCOUNT=0
PRELOCK_KIND=$(fm_meta_get "$META" kind)
[ -n "$PRELOCK_KIND" ] || PRELOCK_KIND=ship
if [ "$PRELOCK_KIND" = secondmate ]; then
  PRELOCK_HOME=$(fm_meta_get "$META" home)
  [ -n "$PRELOCK_HOME" ] || PRELOCK_HOME=$(fm_meta_get "$META" worktree)
  SECONDMATE_HOME_LIFECYCLE_LOCK=$(fm_secondmate_home_lifecycle_lock_acquire "$CHECKOUT_LOCK_ROOT" "$PRELOCK_HOME") || {
    echo "error: secondmate home lifecycle identity is missing, redirected, or uninspectable for $ID" >&2
    exit 1
  }
  TEARDOWN_ACCOUNT_LOCKS+=("$SECONDMATE_HOME_LIFECYCLE_LOCK")
fi
ACCOUNT_DELETE_LOCK=$(fm_account_lifecycle_lock_acquire "$STATE" "$ID") || exit 1
TEARDOWN_ACCOUNT_LOCKS+=("$ACCOUNT_DELETE_LOCK")
require_safe_task_metadata || { echo "error: task metadata changed while teardown waited for $ID" >&2; exit 1; }
if managed_account_meta "$META"; then
  MANAGED_ACCOUNT=1
  managed_account_meta "$META" || { echo "error: managed task metadata changed while teardown waited for $ID" >&2; exit 1; }
fi
WT=$(grep '^worktree=' "$META" | cut -d= -f2- || true)
T=$(grep '^window=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
BACKEND=$(fm_backend_of_meta "$META")
if [ "$BACKEND" = orca ]; then
  T_ORCA=$(grep '^terminal=' "$META" | tail -1 | cut -d= -f2- || true)
  T=$T_ORCA
  fm_backend_source orca || exit 1
  fm_backend_orca_authority_capabilities_check || exit 1
fi
HOME_PATH=$(grep '^home=' "$META" | cut -d= -f2- || true)
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
# tasktmp is recorded by fm-spawn for tasks that set up a per-task temp root
# (/tmp/fm-<id>/); absent for tasks spawned before that change, so tolerate empty.
TASK_TMP=$(grep '^tasktmp=' "$META" | cut -d= -f2- || true)
if [ -n "$TASK_TMP" ] && [ "$TASK_TMP" != "/tmp/fm-$ID" ]; then
  echo "REFUSED: unsafe task temp path in metadata for $ID: $TASK_TMP" >&2
  exit 1
fi
ORCA_WORKTREE_ID=$(fm_meta_get "$META" orca_worktree_id)
ORCA_PATH_MATCH_VERIFIED=0
DIRECT_SPAWN_CLEANUP=$(fm_meta_get "$META" direct_spawn_cleanup)
DIRECT_SPAWN_ENDPOINT=$(fm_meta_get "$META" direct_spawn_endpoint)
DIRECT_SPAWN_BACKUP=$(fm_meta_get "$META" direct_spawn_backup)
DIRECT_SPAWN_ARTIFACTS=$(fm_meta_get "$META" direct_spawn_artifacts)
case "$DIRECT_SPAWN_CLEANUP" in
  '')
    [ -z "$DIRECT_SPAWN_ENDPOINT" ] || {
      echo "error: direct_spawn_endpoint metadata exists without pending cleanup for $ID" >&2
      exit 1
    }
    ;;
  pending)
    case "$DIRECT_SPAWN_ENDPOINT" in
      ''|not-created) ;;
      *) echo "error: invalid direct_spawn_endpoint metadata for $ID" >&2; exit 1 ;;
    esac
    ;;
  *) echo "error: invalid direct_spawn_cleanup metadata for $ID" >&2; exit 1 ;;
esac
if [ "$DIRECT_SPAWN_ENDPOINT" = not-created ]; then
  [ -z "$T" ] \
    && [ -z "$(fm_meta_get "$META" tmux_window_id)" ] \
    && [ -z "$(fm_meta_get "$META" tmux_session_target)" ] \
    && [ -z "$(fm_meta_get "$META" herdr_session)" ] \
    && [ -z "$(fm_meta_get "$META" herdr_workspace_id)" ] \
    && [ -z "$(fm_meta_get "$META" herdr_tab_id)" ] \
    && [ -z "$(fm_meta_get "$META" herdr_pane_id)" ] \
    && [ -z "$(fm_meta_get "$META" zellij_session)" ] \
    && [ -z "$(fm_meta_get "$META" zellij_tab_id)" ] \
    && [ -z "$(fm_meta_get "$META" zellij_pane_id)" ] \
    && [ -z "$(fm_meta_get "$META" cmux_workspace_id)" ] \
    && [ -z "$(fm_meta_get "$META" cmux_surface_id)" ] || {
      echo "error: never-created endpoint metadata for $ID contains an endpoint identity" >&2
      exit 1
    }
fi
SPAWN_NEVER_LAUNCHED=0
if [ "$DIRECT_SPAWN_CLEANUP" = pending ] && [ "$DIRECT_SPAWN_ENDPOINT" = not-created ]; then
  SPAWN_NEVER_LAUNCHED=1
fi
ORCA_CLEANUP_PENDING_COUNT=$(grep -c '^orca_cleanup_pending=' "$META" 2>/dev/null || true)
ORCA_CLEANUP_PENDING=0
if [ "$ORCA_CLEANUP_PENDING_COUNT" -ne 0 ]; then
  if [ "$ORCA_CLEANUP_PENDING_COUNT" -ne 1 ] \
    || [ "$(fm_meta_get "$META" orca_cleanup_pending)" != 1 ] \
    || [ "$BACKEND" != orca ]; then
    echo "error: invalid Orca cleanup quarantine metadata for $ID" >&2
    exit 1
  fi
  case "$(fm_meta_get "$META" orca_cleanup_phase)" in
    spawn-preparing|spawn-abort) ;;
    *)
      echo "error: invalid Orca cleanup quarantine phase for $ID" >&2
      exit 1
      ;;
  esac
  [ "$(fm_meta_get "$META" orca_expected_task)" = "fm-$ID" ] || {
    echo "error: Orca cleanup quarantine is not bound to requested task $ID" >&2
    exit 1
  }
  if [ -z "$ORCA_WORKTREE_ID" ]; then
    [ "$(fm_meta_get "$META" orca_discovery_label)" = "fm-$ID" ] \
      && [ -n "$(fm_meta_get "$META" orca_provider_scope)" ] || {
        echo "error: Orca cleanup quarantine discovery authority is unavailable for $ID" >&2
        exit 1
      }
  fi
  ORCA_CLEANUP_PENDING=1
fi

KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
[ "$KIND" = "$PRELOCK_KIND" ] || {
  echo "error: task kind changed while teardown waited for lifecycle ownership" >&2
  exit 1
}
if [ "$PRESERVE_SCRATCH" -eq 1 ] && [ "$KIND" = secondmate ]; then
  echo "error: --preserve-scratch is supported only for ship and scout worktrees" >&2
  exit 2
fi
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes
REPORT_GATED=0
REPORT_REQUIRED_COUNT=$(grep -c '^report_required=' "$META" 2>/dev/null || true)
if [ "$BACKEND" = orca ] && [ "$REPORT_REQUIRED_COUNT" -ne 0 ]; then
  echo "error: invalid report_required metadata for legacy Orca task $ID; the marker must be absent" >&2
  exit 1
elif [ "$REPORT_REQUIRED_COUNT" -gt 0 ]; then
  if [ "$REPORT_REQUIRED_COUNT" -ne 1 ] || [ "$(fm_meta_get "$META" report_required)" != 1 ]; then
    echo "error: invalid report_required metadata for $ID; refusing teardown" >&2
    exit 1
  fi
  if [ "$KIND" != secondmate ]; then
    REPORT_GATED=1
  fi
fi

managed_endpoint_is_gone() {  # <backend> <target> <expected-label> [probe-home] [recorded-scoped-target]
  local backend=$1 target=$2 expected=$3 probe_home=${4:-} recorded_scoped_target=${5:-}
  local attempt state last=unknown
  [ -n "$target" ] || return 2
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if [ -n "$probe_home" ]; then
      state=$(unset FM_ROOT_OVERRIDE; FM_HOME="$probe_home" FM_ROOT="$probe_home" fm_backend_target_state "$backend" "$target" "$expected" "$recorded_scoped_target" 2>/dev/null)
    else
      state=$(fm_backend_target_state "$backend" "$target" "$expected" "$recorded_scoped_target" 2>/dev/null)
    fi
    case "$state" in
      absent) return 0 ;;
      present) last=present ;;
      unknown) last=unknown ;;
      *) last=unknown ;;
    esac
    sleep 0.1
  done
  [ "$last" != unknown ] || return 2
  return 1
}

managed_endpoint_blocker() {  # <status> <task> [restored]
  local status=$1 task=$2 restored=${3:-} qualifier=
  [ -z "$restored" ] || qualifier='restored '
  if [ "$status" -eq 2 ]; then
    echo "error: ${qualifier}managed endpoint state for $task is unknown; retaining its Agent Fleet lease and metadata" >&2
  else
    echo "error: ${qualifier}managed endpoint for $task is still alive; retaining its Agent Fleet lease and metadata" >&2
  fi
}

teardown_backend_target_of_meta() {
  local meta=$1 backend
  backend=$(fm_backend_of_meta "$meta")
  if [ "$backend" = orca ]; then
    fm_meta_get "$meta" terminal || true
    return 0
  else
    fm_backend_target_of_meta "$meta"
  fi
}

quiesce_authoritative_orca_endpoint() {
  local target=$1 worktree_id=$2 expected_label=$3 state
  [ -n "$worktree_id" ] || return 1
  if [ -n "$target" ]; then
    state=$(fm_backend_target_state orca "$target" "$expected_label" "$worktree_id")
    case "$state" in
      present|absent) ;;
      *) return 1 ;;
    esac
  fi
  fm_backend_quiesce_worktree_terminals orca "$worktree_id" "$expected_label" "$target"
}

quiesce_secondmate_endpoint() {
  local endpoint_home probe_home='' endpoint_status
  endpoint_home=$(fm_backend_endpoint_home "$BACKEND" "$KIND" "$FM_HOME" "$HOME_PATH")
  [ "$endpoint_home" = "$FM_HOME" ] || probe_home=$endpoint_home
  if managed_endpoint_is_gone "$BACKEND" "$T" "fm-$ID" "$probe_home" "$(meta_value "$META" tmux_session_target)"; then
    return 0
  fi
  if [ -n "$T" ]; then
    if [ -n "$probe_home" ]; then
      ( unset FM_ROOT_OVERRIDE; FM_HOME="$probe_home" FM_ROOT="$probe_home" fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" "$(meta_value "$META" tmux_session_target)" ) 2>/dev/null || {
        echo "error: failed to stop secondmate endpoint for $ID; refusing child cleanup" >&2
        return 1
      }
    else
      fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" "$(meta_value "$META" tmux_session_target)" 2>/dev/null || {
        echo "error: failed to stop secondmate endpoint for $ID; refusing child cleanup" >&2
        return 1
      }
    fi
  fi
  if managed_endpoint_is_gone "$BACKEND" "$T" "fm-$ID" "$probe_home" "$(meta_value "$META" tmux_session_target)"; then
    return 0
  fi
  endpoint_status=$?
  if [ "$endpoint_status" -eq 2 ]; then
    echo "error: secondmate endpoint state for $ID is unknown; refusing child cleanup" >&2
  else
    echo "error: secondmate endpoint for $ID is still alive; refusing child cleanup" >&2
  fi
  return 1
}

quiesce_child_endpoint() {
  local meta=$1 task=$2 owner_home=$3 child_home=${4:-}
  local backend target kind endpoint_home probe_home='' endpoint_status scoped_target
  backend=$(fm_backend_of_meta "$meta")
  target=$(teardown_backend_target_of_meta "$meta")
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  endpoint_home=$(fm_backend_endpoint_home "$backend" "$kind" "$owner_home" "$child_home")
  [ "$endpoint_home" = "$FM_HOME" ] || probe_home=$endpoint_home
  scoped_target=$(meta_value "$meta" tmux_session_target)
  [ "$backend" != orca ] || scoped_target=$(meta_value "$meta" orca_worktree_id)
  if [ "$backend" = orca ]; then
    quiesce_authoritative_orca_endpoint "$target" "$scoped_target" "fm-$task" || {
      echo "error: child Orca endpoint authority or quiescence is unproven for $task" >&2
      return 1
    }
    return 0
  fi
  if managed_endpoint_is_gone "$backend" "$target" "fm-$task" "$probe_home" "$scoped_target"; then
    return 0
  else
    endpoint_status=$?
  fi
  if [ "$endpoint_status" -eq 2 ]; then
    echo "error: child endpoint identity or state for $task is unknown; refusing destructive cleanup" >&2
    return 1
  fi
  [ -n "$target" ] || {
    echo "error: child endpoint identity for $task is missing; refusing destructive cleanup" >&2
    return 1
  }
  if [ -n "$probe_home" ]; then
    ( unset FM_ROOT_OVERRIDE; FM_HOME="$probe_home" FM_ROOT="$probe_home" fm_backend_kill "$backend" "$target" "$(meta_value "$meta" zellij_tab_id)" "fm-$task" "$(meta_value "$meta" tmux_session_target)" ) 2>/dev/null || {
      echo "error: failed to stop child endpoint for $task; refusing destructive cleanup" >&2
      return 1
    }
  else
    ( unset FM_ROOT_OVERRIDE; FM_HOME="$owner_home" FM_ROOT="$owner_home" fm_backend_kill "$backend" "$target" "$(meta_value "$meta" zellij_tab_id)" "fm-$task" "$(meta_value "$meta" tmux_session_target)" ) 2>/dev/null || {
      echo "error: failed to stop child endpoint for $task; refusing destructive cleanup" >&2
      return 1
    }
  fi
  if managed_endpoint_is_gone "$backend" "$target" "fm-$task" "$probe_home" "$scoped_target"; then
    return 0
  fi
  endpoint_status=$?
  if [ "$endpoint_status" -eq 2 ]; then
    echo "error: child endpoint state for $task is unknown; refusing destructive cleanup" >&2
  else
    echo "error: child endpoint for $task is still alive; refusing destructive cleanup" >&2
  fi
  return 1
}

quiesce_managed_account_endpoint() {  # <meta> <task> [probe-home]
  local meta=$1 task=$2 probe_home=${3:-} meta_state lock profile backend target zellij_tab tmux_session_target endpoint_status
  meta_state=$(dirname "$meta")
  lock=$(fm_account_meta_lock_acquire "$meta_state" "$task") || return 1
  [ -f "$meta" ] || {
    echo "error: managed metadata for $task disappeared during teardown" >&2
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    return 1
  }
  profile=$(fm_meta_get "$meta" account_profile)
  if [ -z "$profile" ] && [ "$(fm_meta_get "$meta" account_rollback_cleanup)" != pending ]; then
    echo "error: managed metadata for $task changed during teardown" >&2
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    return 1
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(teardown_backend_target_of_meta "$meta")
  zellij_tab=$(fm_meta_get "$meta" zellij_tab_id)
  tmux_session_target=$(fm_meta_get "$meta" tmux_session_target)
  [ -n "$tmux_session_target" ] || tmux_session_target=$(fm_meta_get "$meta" window)
  fm_account_meta_lock_release "$lock" || return 1
  if [ "$backend" = orca ]; then
    tmux_session_target=$(fm_meta_get "$meta" orca_worktree_id)
    quiesce_authoritative_orca_endpoint "$target" "$tmux_session_target" "fm-$task" || {
      echo "error: managed Orca endpoint authority or quiescence is unproven for $task" >&2
      return 1
    }
    return 0
  fi
  if managed_endpoint_is_gone "$backend" "$target" "fm-$task" "$probe_home" "$tmux_session_target"; then
    return 0
  fi
  if [ -n "$target" ]; then
    if [ -n "$probe_home" ]; then
      ( unset FM_ROOT_OVERRIDE; FM_HOME="$probe_home" FM_ROOT="$probe_home" fm_backend_kill "$backend" "$target" "$zellij_tab" "fm-$task" "$tmux_session_target" ) 2>/dev/null || {
        echo "error: failed to stop managed endpoint for $task; retaining its Agent Fleet lease and metadata" >&2
        return 1
      }
    else
      fm_backend_kill "$backend" "$target" "$zellij_tab" "fm-$task" "$tmux_session_target" 2>/dev/null || {
        echo "error: failed to stop managed endpoint for $task; retaining its Agent Fleet lease and metadata" >&2
        return 1
      }
    fi
  fi
  if managed_endpoint_is_gone "$backend" "$target" "fm-$task" "$probe_home" "$tmux_session_target"; then
    return 0
  else
    endpoint_status=$?
  fi
  managed_endpoint_blocker "$endpoint_status" "$task"
  return 1
}

reconcile_managed_account_rollback() {  # <meta> <task> [data-dir]
  local meta=$1 task=$2 owner_data=${3:-$DATA} rollback_backup
  [ "$(fm_meta_get "$meta" account_rollback_cleanup)" = pending ] || return 0
  rollback_backup=$(fm_meta_get "$meta" account_rollback_backup)
  fm_account_cleanup_rollback "$meta" "$owner_data" "$task" || {
    echo "error: failed to clean rolled-back Agent Fleet state for $task; retaining metadata for retry" >&2
    return 1
  }
  if [ -n "$rollback_backup" ]; then
    echo "error: rolled-back Agent Fleet state for $task was restored; rerun teardown against the restored task generation" >&2
    return 2
  fi
}

release_managed_account() {  # <meta> <task> [probe-home] [held-lock] [data-dir]
  local meta=$1 task=$2 probe_home=${3:-} lifecycle_lock=${4:-} owner_data=${5:-$DATA} profile account_task meta_state lock
  MANAGED_ACCOUNT_LOCK=
  profile=$(fm_meta_get "$meta" account_profile)
  [ -n "$profile" ] || [ "$(fm_meta_get "$meta" account_rollback_cleanup)" = pending ] || return 0
  meta_state=$(dirname "$meta")
  if [ -z "$lifecycle_lock" ]; then
    lifecycle_lock=$(fm_account_lifecycle_lock_acquire "$meta_state" "$task") || return 1
    TEARDOWN_ACCOUNT_LOCKS+=("$lifecycle_lock")
  fi
  quiesce_managed_account_endpoint "$meta" "$task" "$probe_home" || return 1
  lock=$(fm_account_meta_lock_acquire "$meta_state" "$task") || return 1
  [ -f "$meta" ] || {
    echo "error: managed metadata for $task disappeared during teardown" >&2
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    return 1
  }
  profile=$(fm_meta_get "$meta" account_profile)
  if [ -z "$profile" ] && [ "$(fm_meta_get "$meta" account_rollback_cleanup)" != pending ]; then
    echo "error: managed metadata for $task changed during teardown" >&2
    fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true
    return 1
  fi
  account_task=$(fm_meta_get "$meta" account_task)
  [ -n "$account_task" ] || account_task=$task
  fm_account_meta_lock_release "$lock" || return 1
  if [ "$(fm_meta_get "$meta" account_rollback_cleanup)" = pending ]; then
    reconcile_managed_account_rollback "$meta" "$task" "$owner_data" || return $?
    profile=$(fm_meta_get "$meta" account_profile)
    if [ -z "$profile" ]; then
      return 0
    fi
  fi
  if [ "$(fm_meta_get "$meta" account_task)" != "$account_task" ]; then
    echo "error: managed task generation changed during teardown for $task" >&2
    return 1
  fi
  fm_account_release "$account_task" --force || {
    echo "error: failed to release Agent Fleet lease for $task; retaining metadata for retry" >&2
    return 1
  }
  fm_account_session_remove "$account_task" || {
    echo "error: failed to remove Agent Fleet session mapping for $task; retaining metadata for retry" >&2
    return 1
  }
  fm_account_cleanup_predecessor_serialized "$meta" "$owner_data" "$task" || {
    echo "error: failed to clean predecessor Agent Fleet state for $task; retaining metadata for retry" >&2
    return 1
  }
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

LIVE_DEFAULT_BRANCH=
LIVE_DEFAULT_TIP=
LIVE_DEFAULT_OUTPUT=
probe_live_origin_default() {
  local line ref status
  LIVE_DEFAULT_BRANCH=
  LIVE_DEFAULT_TIP=
  if fm_run_bounded_capture --combine-stderr LIVE_DEFAULT_OUTPUT "$TEARDOWN_UPSTREAM_TIMEOUT" \
      git -C "$WT" ls-remote --symref origin HEAD; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 0 ] && fm_process_tree_cleanup_verified || return 1
  while IFS= read -r line; do
    case "$line" in
      "ref: refs/heads/"*$'\t'"HEAD")
        ref=${line#ref: refs/heads/}
        LIVE_DEFAULT_BRANCH=${ref%$'\t'HEAD}
        ;;
      *$'\t'"HEAD")
        LIVE_DEFAULT_TIP=${line%$'\t'HEAD}
        ;;
    esac
  done <<EOF
$LIVE_DEFAULT_OUTPUT
EOF
  [ -n "$LIVE_DEFAULT_BRANCH" ] \
    && [ -n "$LIVE_DEFAULT_TIP" ] \
    && git check-ref-format --branch "$LIVE_DEFAULT_BRANCH" >/dev/null 2>&1
}

meta_value() {
  local meta=$1 key=$2
  fm_meta_get "$meta" "$key"
}

require_orca_worktree_id() {
  local meta=$1 id
  id=$(meta_value "$meta" orca_worktree_id)
  if [ -z "$id" ]; then
    echo "error: missing orca_worktree_id in $meta; cannot remove Orca worktree" >&2
    return 1
  fi
  printf '%s\n' "$id"
}

require_orca_task_metadata_identity() {
  local meta=$1 expected_id=$2 window_count expected_count discovery_count scope_count provider_count provider_task
  window_count=$(grep -c '^window=' "$meta" 2>/dev/null || true)
  if [ "$window_count" -ne 1 ] || [ "$(meta_value "$meta" window)" != "fm-$expected_id" ]; then
    echo "error: Orca metadata is not bound to requested task $expected_id" >&2
    return 1
  fi
  expected_count=$(grep -c '^orca_expected_task=' "$meta" 2>/dev/null || true)
  if [ "$expected_count" -ne 0 ] \
    && { [ "$expected_count" -ne 1 ] || [ "$(meta_value "$meta" orca_expected_task)" != "fm-$expected_id" ]; }; then
    echo "error: Orca metadata expected-task authority drifted for $expected_id" >&2
    return 1
  fi
  discovery_count=$(grep -c '^orca_discovery_label=' "$meta" 2>/dev/null || true)
  if [ "$discovery_count" -ne 0 ] \
    && { [ "$discovery_count" -ne 1 ] || [ "$(meta_value "$meta" orca_discovery_label)" != "fm-$expected_id" ]; }; then
    echo "error: Orca metadata discovery-label authority drifted for $expected_id" >&2
    return 1
  fi
  scope_count=$(grep -c '^orca_provider_scope=' "$meta" 2>/dev/null || true)
  if [ "$scope_count" -ne 0 ] \
    && { [ "$scope_count" -ne 1 ] \
      || [ "$(meta_value "$meta" orca_provider_scope)" != "repo-path:$(meta_value "$meta" project)" ]; }; then
    echo "error: Orca metadata provider scope is unavailable for $expected_id" >&2
    return 1
  fi
  provider_count=$(grep -c '^orca_provider_task=' "$meta" 2>/dev/null || true)
  provider_task=$(meta_value "$meta" orca_provider_task)
  if [ "$provider_count" -ne 0 ] \
    && { [ "$provider_count" -ne 1 ] || { [ -n "$provider_task" ] && [ "$provider_task" != "fm-$expected_id" ]; }; }; then
    echo "error: Orca metadata provider-task authority drifted for $expected_id" >&2
    return 1
  fi
}

require_orca_terminal() {
  local meta=$1 terminal
  terminal=$(meta_value "$meta" terminal)
  if [ -z "$terminal" ]; then
    echo "error: missing terminal in $meta; cannot close Orca terminal" >&2
    return 1
  fi
  printf '%s\n' "$terminal"
}

if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
  ORCA_WORKTREE_ID=$(meta_value "$META" orca_worktree_id)
  if [ "$ORCA_CLEANUP_PENDING" != 1 ] && [ -z "$ORCA_WORKTREE_ID" ]; then
    ORCA_WORKTREE_ID=$(require_orca_worktree_id "$META") || exit 1
  fi
  T_ORCA=$(meta_value "$META" terminal)
  if [ "$ORCA_CLEANUP_PENDING" != 1 ] && [ -z "$T_ORCA" ]; then
    T_ORCA=$(require_orca_terminal "$META") || exit 1
  fi
  [ -z "$T_ORCA" ] || T=$T_ORCA
fi

remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token hooks_dir
  token=$(cat "$state_dir/$id.grok-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

# Resolve the PR number for a worktree branch via gh-axi. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup failure,
# so the caller treats it as "no PR found" (fail-safe).
pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$WT" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

ensure_commit_object() {
  local target=$1 commit=$2 n
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(pr_number_from_target "$target") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null
}

patch_id_for_commit() {
  local commit=$1
  git -C "$WT" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

unpushed_patches_are_in_pr_head() {
  local pr_head=$1 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$WT" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$WT" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          patch_id_for_commit "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$WT" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(patch_id_for_commit "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the recorded pr= URL first, then from the branch name, and asks GitHub
# for both the PR state and head. Returns non-zero when the PR is not merged, the
# current work is not contained in the PR head, no PR is found, or any gh error
# occurs - the caller then falls back to the content check.
pr_is_merged() {
  local branch=$1 target view state head current
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$WT" && gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  head=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  ensure_commit_object "$target" "$head" || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null && return 0
  unpushed_patches_are_in_pr_head "$head"
}

# Is the branch's content already present in the up-to-date default branch?
# Origin-backed proof holds the common checkout lock across probe, fetch,
# unchanged branch-and-tip re-probe, and tree comparison.
content_matches_ref() {
  local ref=$1 default_tree merged_tree
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  if [ "$merged_tree" != "$default_tree" ]; then
    echo "teardown: task content is not present in authoritative $ref; retaining $WT" >&2
    return 1
  fi
  return 0
}

content_in_origin_default() {
  local initial_branch initial_tip ref fetched fetch_output reason fetch_status
  if ! probe_live_origin_default; then
    reason=$(printf '%s\n' "$LIVE_DEFAULT_OUTPUT" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p')
    echo "teardown: cannot prove the live origin default for $PROJ${reason:+: $reason}; retaining $WT" >&2
    return 1
  fi
  initial_branch=$LIVE_DEFAULT_BRANCH
  initial_tip=$LIVE_DEFAULT_TIP
  if fm_run_bounded_capture --combine-stderr fetch_output "$TEARDOWN_UPSTREAM_TIMEOUT" \
      git -C "$WT" fetch --quiet origin \
      "+refs/heads/$initial_branch:refs/remotes/origin/$initial_branch"; then
    fetch_status=0
  else
    fetch_status=$?
  fi
  if [ "$fetch_status" -ne 0 ] || ! fm_process_tree_cleanup_verified; then
    reason=$(printf '%s\n' "$fetch_output" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p')
    echo "teardown: cannot fetch live origin/$initial_branch for landing proof${reason:+: $reason}; retaining $WT" >&2
    return 1
  fi
  if ! probe_live_origin_default; then
    reason=$(printf '%s\n' "$LIVE_DEFAULT_OUTPUT" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p')
    echo "teardown: cannot re-prove the live origin default after fetch${reason:+: $reason}; retaining $WT" >&2
    return 1
  fi
  if [ "$LIVE_DEFAULT_BRANCH" != "$initial_branch" ] || [ "$LIVE_DEFAULT_TIP" != "$initial_tip" ]; then
    echo "teardown: live origin default changed during landing proof ($initial_branch@$initial_tip -> $LIVE_DEFAULT_BRANCH@$LIVE_DEFAULT_TIP); retaining $WT" >&2
    return 1
  fi
  ref="refs/remotes/origin/$initial_branch"
  fetched=$(git -C "$WT" rev-parse --quiet --verify "$ref^{commit}" 2>/dev/null) || {
    echo "teardown: cannot inspect fetched live origin/$initial_branch; retaining $WT" >&2
    return 1
  }
  if [ "$fetched" != "$initial_tip" ]; then
    echo "teardown: fetched origin/$initial_branch does not match live origin HEAD; retaining $WT" >&2
    return 1
  fi
  content_matches_ref "$ref"
}

content_in_default() {
  local name ref
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    fm_checkout_lock_run "$WT" "$CHECKOUT_LOCK_ROOT" content_in_origin_default
    return
  fi
  name=$(default_branch) || return 1
  if git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  content_matches_ref "$ref"
}

# Has the worktree's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current local work is contained in the PR head, OR the content is already in the
# default branch (fallback, which also covers the no-PR and gh-error paths). False
# only for genuinely unlanded work.
work_is_landed() {
  local branch=$1
  pr_is_merged "$branch" && return 0
  content_in_default
}

backlog_refresh_reminder() {
  local pr done_cmd report_path
  [ "$KIND" = secondmate ] && return 0
  if [ "$SPAWN_NEVER_LAUNCHED" = 1 ]; then
    printf '%s\n' "Backlog: $ID never launched. Retry its spawn or move it back to a ready state; no report was required for this cleanup."
    return 0
  fi
  if fm_tasks_axi_backend_available "$CONFIG"; then
    case "$KIND" in
      scout)
        report_path="data/$ID/report.md"
        done_cmd="tasks-axi done $ID --report $report_path"
        ;;
      *)
        if [ "$MODE" = local-only ]; then
          done_cmd="tasks-axi done $ID --note \"local main\""
        else
          pr=$PR_URL
          if [ -n "$pr" ]; then
            done_cmd="tasks-axi done $ID --pr $pr"
          else
            done_cmd="tasks-axi done $ID --pr PR_URL"
          fi
        fi
        ;;
    esac
    printf '%s\n' "Backlog: $ID just finished. Run $done_cmd, then run tasks-axi ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
  else
    printf '%s\n' "Backlog: $ID just finished. Update data/backlog.md - move $ID to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due."
  fi
}

registry_home_for_line() {
  sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p'
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

removal_target_abs_path() {
  local target=$1
  if [ -d "$target" ]; then
    cd "$target" && pwd -P
  else
    cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")"
  fi
}

worktree_registered_for_project() {
  local project=$1 target=$2 abs_target listed line listed_abs
  [ -n "$project" ] || return 1
  [ -d "$project" ] || return 1
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || return 1
  abs_target=$(removal_target_abs_path "$target")
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_abs=$(removal_target_abs_path "${line#worktree }" 2>/dev/null || true)
        [ "$listed_abs" = "$abs_target" ] && return 0
        ;;
    esac
  done <<EOF
$listed
EOF
  return 1
}

inspectable_git_worktree() {
  local target=$1 top
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  top=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  [ -d "$top" ] || return 1
  git -C "$top" rev-parse --git-dir >/dev/null 2>&1
}

canonical_existing_dir() {
  local target=$1
  fm_checkout_trusted_dir "$target"
}

exact_git_worktree_root() {
  local target=$1 canonical top canonical_top
  canonical=$(canonical_existing_dir "$target") || return 1
  top=$(git -C "$canonical" rev-parse --show-toplevel 2>/dev/null) || return 1
  canonical_top=$(canonical_existing_dir "$top") || return 1
  [ "$canonical" = "$canonical_top" ] || return 1
  fm_checkout_validate_git_metadata "$canonical" >/dev/null || return 1
  printf '%s\n' "$canonical"
}

treehouse_state_for_worktree() {
  local worktree=$1 slot pool state
  slot=$(canonical_existing_dir "$(dirname "$worktree")") || return 1
  pool=$(canonical_existing_dir "$(dirname "$slot")") || return 1
  state="$pool/treehouse-state.json"
  [ -f "$state" ] && [ ! -L "$state" ] || return 1
  printf '%s\n' "$state"
}

treehouse_task_lease_state() {
  local worktree=$1 expected_holder=$2 state
  state=$(treehouse_state_for_worktree "$worktree") || {
    echo "error: cannot resolve authoritative Treehouse state for $worktree" >&2
    return 1
  }
  python3 - "$state" "$worktree" "$expected_holder" <<'PY'
import json
import os
import sys

state_path, expected_path, expected_holder = sys.argv[1:]
try:
    with open(state_path, encoding="utf-8") as stream:
        state = json.load(stream)
    worktrees = state["worktrees"]
    if not isinstance(worktrees, list):
        raise TypeError("worktrees must be an array")
    matches = []
    for entry in worktrees:
        if not isinstance(entry, dict):
            continue
        path = entry.get("path")
        if not isinstance(path, str) or not path:
            continue
        if os.path.realpath(path) == expected_path:
            matches.append(entry)
    if len(matches) != 1:
        raise ValueError("expected exactly one matching worktree entry")
    entry = matches[0]
    if entry.get("destroying") is True:
        raise ValueError("worktree is already being destroyed")
    if entry.get("leased") is True:
        if entry.get("lease_holder") != expected_holder:
            raise ValueError(
                f"lease holder is {entry.get('lease_holder')!r}, "
                f"expected {expected_holder!r}"
            )
        print("leased")
    elif entry.get("leased") in (None, False) and entry.get("lease_holder") in (
        None,
        "",
    ):
        print("returned")
    else:
        raise ValueError("worktree lease state is neither owned nor cleanly returned")
except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
    print(
        f"error: Treehouse ownership for {expected_path} is unprovable: {error}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

require_treehouse_task_lease() {
  local state
  state=$(treehouse_task_lease_state "$1" "$2") || return 1
  [ "$state" = leased ] || {
    echo "error: Treehouse ownership for $1 is unprovable: worktree is not durably leased" >&2
    return 1
  }
}

TREEHOUSE_TARGET_ALREADY_RETURNED=0
require_treehouse_task_lease_or_returned() {
  local state
  TREEHOUSE_TARGET_ALREADY_RETURNED=0
  state=$(treehouse_task_lease_state "$1" "$2") || return 1
  case "$state" in
    leased) ;;
    returned) TREEHOUSE_TARGET_ALREADY_RETURNED=1 ;;
    *) return 1 ;;
  esac
}

require_treehouse_return_authority() {
  local worktree=$1 project=$2 worktree_root project_root worktree_common project_common
  worktree_root=$(exact_git_worktree_root "$worktree") || return 1
  project_root=$(exact_git_worktree_root "$project") || return 1
  worktree_common=$(fm_checkout_git_common_dir "$worktree_root") || return 1
  project_common=$(fm_checkout_git_common_dir "$project_root") || return 1
  [ "$worktree_common" = "$project_common" ] || {
    echo "error: Treehouse return target $worktree_root does not belong to $project_root" >&2
    return 1
  }
  worktree_registered_for_project "$project_root" "$worktree_root" || {
    echo "error: Treehouse return target $worktree_root is not registered to $project_root" >&2
    return 1
  }
  require_treehouse_task_lease "$worktree_root" "$3"
}

validate_teardown_target_identity() {
  local project_root worktree_root project_common worktree_common
  [ "$KIND" != secondmate ] || return 0
  require_safe_task_metadata || return 1
  project_root=$(exact_git_worktree_root "$PROJ") || {
    echo "error: teardown project metadata is not an exact inspectable repository root: ${PROJ:-<missing>}" >&2
    return 1
  }
  worktree_root=$(exact_git_worktree_root "$WT") || {
    echo "error: teardown worktree metadata is not an exact inspectable repository root: ${WT:-<missing>}" >&2
    return 1
  }
  [ "$project_root" != "$worktree_root" ] || {
    echo "error: teardown worktree metadata resolves to the primary project root: $worktree_root" >&2
    return 1
  }
  project_common=$(fm_checkout_git_common_dir "$project_root") || return 1
  worktree_common=$(fm_checkout_git_common_dir "$worktree_root") || return 1
  [ "$project_common" = "$worktree_common" ] || {
    echo "error: teardown worktree does not belong to the recorded project: $worktree_root" >&2
    return 1
  }
  if [ "$BACKEND" = orca ]; then
    require_orca_task_metadata_identity "$META" "$ID" || return 1
    require_orca_worktree_path_match "$ORCA_WORKTREE_ID" "$worktree_root" || return 1
    ORCA_PATH_MATCH_VERIFIED=1
    return 0
  fi
  worktree_registered_for_project "$project_root" "$worktree_root" || {
    echo "error: teardown worktree is not registered to the recorded project: $worktree_root" >&2
    return 1
  }
  require_treehouse_task_lease_or_returned "$worktree_root" "firstmate-$ID"
}

retry_wait_secs_is_valid() {
  [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

STALE_WORKTREE_LOCK_AGE_SECS=${FM_STALE_WORKTREE_LOCK_AGE_SECS:-30}
# Bounded patience window for transient index.lock after killing a crewmate process.
# New knobs are preferred; FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS remains an alias
# for the per-attempt wait so existing tests and operators keep working.
TREEHOUSE_RETURN_LOCK_RETRIES=${FM_TREEHOUSE_RETURN_LOCK_RETRIES:-3}
TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=${FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS:-${FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS:-1}}
if ! retry_wait_secs_is_valid "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"; then
  echo "teardown: invalid treehouse return lock retry wait '$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1
fi
# Compatibility alias used by the safety-check wait path and older call sites.
STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS
TEARDOWN_TREEHOUSE_LOCK_REFUSED=2
TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED=3

# True when treehouse/git stderr shows the transient index.lock "File exists" race.
# Other return failures must not enter the retry path.
treehouse_return_is_index_lock_error() {
  local text=$1
  printf '%s\n' "$text" | grep -Eq "Unable to create ['\"].*index\\.lock['\"]: File exists"
}

# Absolute path to the git index lock for a worktree/repo dir, or empty when it
# cannot be resolved (dir missing or not a git worktree at all).
worktree_git_lock_path() {
  local dir=$1 lock abs_dir
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(canonical_existing_dir "$dir") || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# The lock-staleness proof (lsof holder check, mtime age, fail-safe defaults)
# is owned by bin/fm-lock-lib.sh's fm_lock_is_provably_stale, sourced above.
# Teardown passes the worktree dir as the companion directory and its own
# STALE_WORKTREE_LOCK_AGE_SECS threshold.

worktree_safety_blocked_by_lock() {
  local reason=$1 lock
  lock=$(worktree_git_lock_path "$WT") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  echo "teardown: cannot inspect worktree $WT for $reason while git lock $lock is present; checking whether the lock is stale" >&2
  return 0
}

cleanup_stale_lock_for_safety_check() {
  local dir=$1 lock
  lock=$(worktree_git_lock_path "$dir") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 0

  echo "teardown: worktree safety check blocked by git lock $lock; waiting ${STALE_WORKTREE_LOCK_RETRY_WAIT_SECS}s and retrying (owning process may be exiting)" >&2
  sleep "$STALE_WORKTREE_LOCK_RETRY_WAIT_SECS"

  if [ ! -e "$lock" ]; then
    echo "teardown: worktree safety check lock cleared on its own; retrying safety checks" >&2
    return 0
  fi

  if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
    rm -f "$lock"
    echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying worktree safety checks" >&2
    return 0
  fi

  echo "teardown: worktree safety check blocked by git lock $lock that is not provably stale (may belong to a live process); leaving it in place" >&2
  return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
}

# Return a worktree/home via `treehouse return --force`, tolerating a transient or
# stale git index.lock left by a killed crewmate process. See the script header.
teardown_treehouse_return_locked() {
  local dir=$1 cd_dir=$2 label=$3 expected_holder=$4 post_cleanup_check=${5:-} post_return_cleanup=${6:-}
  local out lock attempt=0 max_retries lock_desc return_status return_branch=

  require_treehouse_return_authority "$dir" "$cd_dir" "$expected_holder" || {
    echo "teardown: $label return aborted because Treehouse task ownership changed" >&2
    return 1
  }
  if [ -n "$post_cleanup_check" ] && ! "$post_cleanup_check" "$dir" "$cd_dir" "$expected_holder"; then
    echo "teardown: $label return aborted because the final locked safety check failed" >&2
    return 1
  fi
  require_treehouse_return_authority "$dir" "$cd_dir" "$expected_holder" || {
    echo "teardown: $label return aborted because Treehouse task ownership changed during final safety checks" >&2
    return 1
  }
  if [ -n "$post_return_cleanup" ]; then
    return_branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || {
      echo "teardown: $label return aborted because the task branch cannot be inspected under lock" >&2
      return 1
    }
  fi
  validate_removal_tree_boundaries "$dir" "$label" || return 1
  if out=$(fm_checkout_treehouse_return_locked "$dir" "$CHECKOUT_LOCK_ROOT" "$cd_dir" 2>&1); then
    [ -n "$out" ] && printf '%s\n' "$out"
    if [ -n "$post_return_cleanup" ]; then
      "$post_return_cleanup" "$return_branch" "$dir" "$cd_dir" || return 1
    fi
    return 0
  else
    return_status=$?
  fi
  [ -n "$out" ] && printf '%s\n' "$out" >&2
  if fm_checkout_treehouse_return_requires_retention "$return_status"; then
    return "$return_status"
  fi

  if ! treehouse_return_is_index_lock_error "$out"; then
    return "$return_status"
  fi

  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ]; then
    lock_desc=$lock
  else
    lock_desc="index.lock"
  fi

  max_retries=$TREEHOUSE_RETURN_LOCK_RETRIES
  case "$max_retries" in ''|*[!0-9]*) max_retries=3 ;; esac

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$(( attempt + 1 ))
    echo "teardown: $label return failed with transient git lock ($lock_desc); waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${max_retries})" >&2
    sleep "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"

    if ! require_treehouse_return_authority "$dir" "$cd_dir" "$expected_holder"; then
      echo "teardown: $label return aborted because Treehouse task ownership changed" >&2
      return 1
    fi
    if [ -n "$post_cleanup_check" ] && ! "$post_cleanup_check" "$dir" "$cd_dir" "$expected_holder"; then
      echo "teardown: $label return aborted because the final locked safety check failed" >&2
      return 1
    fi
    if ! require_treehouse_return_authority "$dir" "$cd_dir" "$expected_holder"; then
      echo "teardown: $label return aborted because Treehouse task ownership changed during final safety checks" >&2
      return 1
    fi
    validate_removal_tree_boundaries "$dir" "$label" || return 1
    if out=$(fm_checkout_treehouse_return_locked "$dir" "$CHECKOUT_LOCK_ROOT" "$cd_dir" 2>&1); then
      [ -n "$out" ] && printf '%s\n' "$out"
      if [ -n "$post_return_cleanup" ]; then
        "$post_return_cleanup" "$return_branch" "$dir" "$cd_dir" || return 1
      fi
      echo "teardown: $label return succeeded on retry; lock cleared on its own" >&2
      return 0
    else
      return_status=$?
    fi
    [ -n "$out" ] && printf '%s\n' "$out" >&2
    if fm_checkout_treehouse_return_requires_retention "$return_status"; then
      return "$return_status"
    fi

    if ! treehouse_return_is_index_lock_error "$out"; then
      echo "teardown: $label return failed with a non-lock error after retry; aborting" >&2
      return "$return_status"
    fi
  done

  # Refresh lock path after the patience window; it may have appeared, moved, or
  # cleared while we waited.
  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    lock_desc=$lock
    if fm_lock_is_provably_stale "$lock" "$dir" "$STALE_WORKTREE_LOCK_AGE_SECS"; then
      rm -f "$lock"
      echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying $label return" >&2
      if ! require_treehouse_return_authority "$dir" "$cd_dir" "$expected_holder"; then
        echo "teardown: $label return aborted after stale-lock cleanup because Treehouse task ownership changed" >&2
        return 1
      fi
      if [ -n "$post_cleanup_check" ]; then
        if ! "$post_cleanup_check" "$dir" "$cd_dir" "$expected_holder"; then
          echo "teardown: $label return aborted after stale-lock cleanup because safety checks failed" >&2
          return 1
        fi
      fi
      if ! require_treehouse_return_authority "$dir" "$cd_dir" "$expected_holder"; then
        echo "teardown: $label return aborted after stale-lock cleanup because Treehouse task ownership changed during safety checks" >&2
        return 1
      fi
      validate_removal_tree_boundaries "$dir" "$label" || return 1
      if out=$(fm_checkout_treehouse_return_locked "$dir" "$CHECKOUT_LOCK_ROOT" "$cd_dir" 2>&1); then
        [ -n "$out" ] && printf '%s\n' "$out"
        if [ -n "$post_return_cleanup" ]; then
          "$post_return_cleanup" "$return_branch" "$dir" "$cd_dir" || return 1
        fi
        echo "teardown: $label return succeeded after stale-lock cleanup" >&2
        return 0
      else
        return_status=$?
      fi
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      echo "teardown: $label return still failing after stale-lock cleanup" >&2
      if fm_checkout_treehouse_return_requires_retention "$return_status"; then
        return "$return_status"
      fi
      return "$return_status"
    fi

    echo "teardown: $label return failed: git lock $lock_desc persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
  fi

  echo "teardown: $label return failed: git index.lock signature persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) even after the lock file disappeared" >&2
  return 1
}

teardown_treehouse_return() {
  local dir=$1
  fm_checkout_lock_run "$dir" "$CHECKOUT_LOCK_ROOT" teardown_treehouse_return_locked "$@"
}

cleanup_returned_worktree() {
  local branch=$1 worktree=$2 project=$3
  if [ "$branch" != "HEAD" ]; then
    git -C "$project" branch -D "$branch" >/dev/null 2>&1 || true
  fi
  remove_worktree_compatibility_artifacts "$worktree" "returned worktree"
}

teardown_path_is_known_tool_artifact() {
  local path=$1
  case "$path" in
    .claude/settings.local.json|.opencode/plugins/fm-turn-end.js|.fm-grok-turnend)
      return 0
      ;;
    .watchman-cookie-*)
      case "$path" in
        */*) return 1 ;;
        *) return 0 ;;
      esac
      ;;
  esac
  return 1
}

first_actionable_dirty_status() {
  local line path
  while IFS= read -r line; do
    case "$line" in
      '?? '*)
        path=${line#?? }
        teardown_path_is_known_tool_artifact "$path" && continue
        ;;
    esac
    printf '%s\n' "$line"
    return 0
  done
}

validate_worktree_stash_absent() {
  local stash_list
  stash_list=$(git -C "$WT" stash list 2>/dev/null) || {
    echo "REFUSED: cannot inspect worktree $WT for retained stash history." >&2
    return 1
  }
  [ -z "$stash_list" ] || {
    echo "REFUSED: worktree $WT has retained stash history." >&2
    return 1
  }
}

validate_worktree_committed_landing() {
  local unpushed_raw unpushed DEFAULT unmerged_raw unmerged branch
  if ! unpushed_raw=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    if worktree_safety_blocked_by_lock "commits not on a remote"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for commits not on a remote." >&2
    echo "Restore the git index state, then retry teardown." >&2
    return 1
  fi
  unpushed=$(printf '%s\n' "$unpushed_raw" | head -5)

  if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
    DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; return 1; }
    if ! unmerged_raw=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null); then
      if worktree_safety_blocked_by_lock "commits not on $DEFAULT"; then
        return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
      fi
      echo "REFUSED: cannot inspect worktree $WT for commits not on $DEFAULT." >&2
      echo "Restore the git index state, then retry teardown." >&2
      return 1
    fi
    unmerged=$(printf '%s\n' "$unmerged_raw" | head -5)
    if [ -n "$unmerged" ]; then
      echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
      printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
      echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push it to a fork or remote, then retry teardown." >&2
      return 1
    fi
  elif [ -n "$unpushed" ]; then
    branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
    if [ -z "$branch" ]; then
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$branch
    fi
    if ! work_is_landed "$branch"; then
      echo "REFUSED: worktree $WT has work not on any remote and not landed." >&2
      printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      echo "Push the branch or land its PR, then retry teardown." >&2
      return 1
    fi
  fi
}

validate_worktree_teardown_safety() {
  local dirty_raw dirty
  [ -d "$WT" ] || return 0
  case "$KIND" in
    secondmate) return 0 ;;
  esac
  validate_worktree_stash_absent || return 1

  if ! dirty_raw=$(git -C "$WT" status --porcelain=v1 --untracked-files=all 2>/dev/null); then
    if worktree_safety_blocked_by_lock "uncommitted changes"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for uncommitted changes." >&2
    echo "Restore the git index state, then retry teardown." >&2
    return 1
  fi
  dirty=$(printf '%s\n' "$dirty_raw" | first_actionable_dirty_status || true)

  validate_worktree_committed_landing || return $?
  if [ -n "$dirty" ]; then
    echo "REFUSED: worktree $WT has uncommitted changes." >&2
    echo "uncommitted changes present" >&2
    if [ "$PRESERVE_SCRATCH" -eq 1 ]; then
      echo "The requested scratch preservation did not complete; the worktree is unchanged." >&2
    else
      echo "Retry with --preserve-scratch to capture the diff and untracked files before cleaning, or commit and land them first." >&2
    fi
    return 1
  fi
}

summarize_ignored_worktree_paths() {
  local summary
  summary=$(
    set -o pipefail
    git -C "$WT" ls-files --others --ignored --exclude-standard \
      --directory --no-empty-directory -z -- |
      python3 -c '
import json
import sys

entries = [
    item.decode("utf-8", "surrogateescape")
    for item in sys.stdin.buffer.read().split(b"\0")
    if item
]
top_level = sorted(
    {
        entry.rstrip("/").split("/", 1)[0]
        for entry in entries
        if entry.rstrip("/")
    }
)
print(
    "teardown: ignored worktree summary: "
    f"count={len(entries)}; top-level={json.dumps(top_level, ensure_ascii=True)}"
)
'
  ) || {
    echo "REFUSED: cannot summarize ignored files in worktree $WT." >&2
    return 1
  }
  printf '%s\n' "$summary"
}

validate_worktree_teardown_safety_and_summarize_ignored() {
  validate_worktree_teardown_safety || return 1
  summarize_ignored_worktree_paths
}

filter_preservable_untracked_paths() {
  local source=$1 destination=$2 path
  while IFS= read -r -d '' path; do
    teardown_path_is_known_tool_artifact "$path" && continue
    printf '%s\0' "$path"
  done < "$source" > "$destination"
}

capture_worktree_scratch() {
  local task_dir scratch_root capture_dir all_untracked
  [ -d "$DATA" ] || mkdir -p "$DATA" || return 1
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || {
    echo "REFUSED: scratch data root is not a real directory: $DATA" >&2
    return 1
  }
  task_dir="$DATA/$ID"
  [ -e "$task_dir" ] || mkdir "$task_dir" || return 1
  [ -d "$task_dir" ] && [ ! -L "$task_dir" ] || {
    echo "REFUSED: task report directory is not a real directory: $task_dir" >&2
    return 1
  }
  scratch_root="$task_dir/scratch"
  [ -e "$scratch_root" ] || mkdir "$scratch_root" || return 1
  [ -d "$scratch_root" ] && [ ! -L "$scratch_root" ] || {
    echo "REFUSED: task scratch path is not a real directory: $scratch_root" >&2
    return 1
  }
  capture_dir="$scratch_root/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  [ ! -e "$capture_dir" ] || {
    echo "REFUSED: scratch capture path already exists: $capture_dir" >&2
    return 1
  }
  umask 077
  mkdir "$capture_dir" || return 1
  all_untracked="$capture_dir/.all-untracked.paths"

  git -C "$WT" status --porcelain=v1 --untracked-files=all \
    > "$capture_dir/status.txt" || return 1
  git -C "$WT" diff --binary --full-index HEAD -- \
    > "$capture_dir/tracked.patch" || return 1
  git -C "$WT" diff --binary --full-index --cached -- \
    > "$capture_dir/staged.patch" || return 1
  git -C "$WT" diff --binary --full-index -- \
    > "$capture_dir/unstaged.patch" || return 1
  git -C "$WT" ls-files --others --exclude-standard -z -- \
    > "$all_untracked" || return 1
  filter_preservable_untracked_paths \
    "$all_untracked" "$capture_dir/untracked.paths" || return 1
  rm -f "$all_untracked"

  python3 - "$WT" "$capture_dir" <<'PY'
import hashlib
import json
import os
import stat
import sys
import tarfile

root, capture = sys.argv[1:]
with open(os.path.join(capture, "untracked.paths"), "rb") as stream:
    paths = [item.decode("utf-8", "surrogateescape") for item in stream.read().split(b"\0") if item]

def snapshot(path):
    metadata = os.lstat(path)
    record = {
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "mode": metadata.st_mode,
        "size": metadata.st_size,
    }
    if stat.S_ISREG(metadata.st_mode):
        digest = hashlib.sha256()
        with open(path, "rb", buffering=0) as stream:
            opened = os.fstat(stream.fileno())
            if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                raise OSError(f"untracked file identity changed: {path}")
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        record["sha256"] = digest.hexdigest()
    elif stat.S_ISLNK(metadata.st_mode):
        record["target"] = os.readlink(path)
    return record

manifest = []
archive_path = os.path.join(capture, "untracked.tar")
with tarfile.open(archive_path, "w", dereference=False) as archive:
    for relative in paths:
        normalized = os.path.normpath(relative)
        if (
            not relative
            or os.path.isabs(relative)
            or normalized == os.pardir
            or normalized.startswith(os.pardir + os.sep)
        ):
            raise OSError(f"unsafe untracked path: {relative!r}")
        source = os.path.join(root, relative)
        before = snapshot(source)
        archive.add(source, arcname=relative, recursive=False)
        after = snapshot(source)
        if before != after:
            raise OSError(f"untracked file changed during capture: {relative}")
        manifest.append({"path": relative, **before})

with open(os.path.join(capture, "untracked.txt"), "w", encoding="utf-8") as stream:
    for relative in paths:
        stream.write(json.dumps(relative, ensure_ascii=False) + "\n")
with open(os.path.join(capture, "untracked-manifest.json"), "w", encoding="utf-8") as stream:
    json.dump(manifest, stream, indent=2, ensure_ascii=False)
    stream.write("\n")
PY
  capture_preserved_tracked_snapshot "$capture_dir" || return 1
  verify_preserved_tracked_capture "$capture_dir" || return 1
  : > "$capture_dir/capture-complete"
  PRESERVED_SCRATCH_CAPTURE=$capture_dir
}

capture_preserved_tracked_snapshot() {
  local capture_dir=$1
  git -C "$WT" ls-files --stage -v -z -- \
    > "$capture_dir/tracked-index.snapshot" || return 1
  git -C "$WT" ls-files -z -- \
    > "$capture_dir/tracked.paths" || return 1
  python3 - "$WT" "$capture_dir/tracked.paths" \
    "$capture_dir/tracked-manifest.json" <<'PY'
import hashlib
import json
import os
import stat
import sys

root, paths_file, manifest_file = sys.argv[1:]
with open(paths_file, "rb") as stream:
    paths = [
        item.decode("utf-8", "surrogateescape")
        for item in stream.read().split(b"\0")
        if item
    ]

def snapshot(relative):
    path = os.path.join(root, relative)
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return {"path": relative, "missing": True}
    record = {
        "path": relative,
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "mode": metadata.st_mode,
        "size": metadata.st_size,
    }
    if stat.S_ISREG(metadata.st_mode):
        digest = hashlib.sha256()
        with open(path, "rb", buffering=0) as stream:
            opened = os.fstat(stream.fileno())
            if (opened.st_dev, opened.st_ino) != (
                metadata.st_dev,
                metadata.st_ino,
            ):
                raise OSError(f"tracked file identity changed: {relative}")
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        record["sha256"] = digest.hexdigest()
    elif stat.S_ISLNK(metadata.st_mode):
        record["target"] = os.readlink(path)
    return record

with open(manifest_file, "w", encoding="utf-8") as stream:
    json.dump([snapshot(path) for path in paths], stream, indent=2)
    stream.write("\n")
PY
}

verify_preserved_tracked_index_snapshot() {
  local capture_dir=$1 current_index
  current_index="$capture_dir/.tracked-index.current"
  git -C "$WT" ls-files --stage -v -z -- > "$current_index" || return 1
  cmp -s "$capture_dir/tracked-index.snapshot" "$current_index" || {
    rm -f "$current_index"
    echo "REFUSED: tracked index changed after scratch capture." >&2
    return 1
  }
  rm -f "$current_index"
}

verify_preserved_tracked_snapshot() {
  local capture_dir=$1
  verify_preserved_tracked_index_snapshot "$capture_dir" || return 1
  python3 - "$WT" "$capture_dir/tracked-manifest.json" <<'PY' || return 1
import hashlib
import json
import os
import stat
import sys

root, manifest_file = sys.argv[1:]
with open(manifest_file, encoding="utf-8") as stream:
    manifest = json.load(stream)

def snapshot(relative):
    path = os.path.join(root, relative)
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return {"path": relative, "missing": True}
    record = {
        "path": relative,
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "mode": metadata.st_mode,
        "size": metadata.st_size,
    }
    if stat.S_ISREG(metadata.st_mode):
        digest = hashlib.sha256()
        with open(path, "rb", buffering=0) as stream:
            opened = os.fstat(stream.fileno())
            if (opened.st_dev, opened.st_ino) != (
                metadata.st_dev,
                metadata.st_ino,
            ):
                raise OSError(f"tracked file identity changed: {relative}")
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        record["sha256"] = digest.hexdigest()
    elif stat.S_ISLNK(metadata.st_mode):
        record["target"] = os.readlink(path)
    return record

for expected in manifest:
    if snapshot(expected["path"]) != expected:
        raise OSError(
            f"tracked working-tree file changed after capture: "
            f"{expected['path']}"
        )
PY
  verify_preserved_tracked_index_snapshot "$capture_dir"
}

verify_preserved_tracked_capture() {
  local capture_dir=$1 candidate patch
  for patch in tracked staged unstaged; do
    candidate="$capture_dir/.$patch.current"
    case "$patch" in
      tracked)
        git -C "$WT" diff --binary --full-index HEAD -- > "$candidate" \
          || return 1
        ;;
      staged)
        git -C "$WT" diff --binary --full-index --cached -- > "$candidate" \
          || return 1
        ;;
      unstaged)
        git -C "$WT" diff --binary --full-index -- > "$candidate" \
          || return 1
        ;;
    esac
    cmp -s "$capture_dir/$patch.patch" "$candidate" || {
      rm -f "$candidate"
      echo "REFUSED: tracked work changed during scratch capture." >&2
      return 1
    }
    rm -f "$candidate"
  done
  verify_preserved_tracked_snapshot "$capture_dir"
}

verify_preserved_untracked_snapshot() {
  local capture_dir=$1
  python3 - "$WT" "$capture_dir/untracked-manifest.json" <<'PY'
import hashlib
import json
import os
import stat
import sys

root, manifest_path = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as stream:
    manifest = json.load(stream)
for expected in manifest:
    path = os.path.join(root, expected["path"])
    metadata = os.lstat(path)
    actual = {
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "mode": metadata.st_mode,
        "size": metadata.st_size,
    }
    if stat.S_ISREG(metadata.st_mode):
        digest = hashlib.sha256()
        with open(path, "rb", buffering=0) as stream:
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        actual["sha256"] = digest.hexdigest()
    elif stat.S_ISLNK(metadata.st_mode):
        actual["target"] = os.readlink(path)
    comparison = {key: expected[key] for key in actual}
    if actual != comparison:
        raise OSError(f"untracked file changed after capture: {expected['path']}")
PY
}

clean_preserved_worktree_scratch() {
  local capture_dir=$1 path
  [ -f "$capture_dir/capture-complete" ] || return 1
  verify_preserved_untracked_snapshot "$capture_dir" || return 1
  verify_preserved_tracked_snapshot "$capture_dir" || return 1
  git -C "$WT" reset --hard HEAD >/dev/null || return 1
  while IFS= read -r -d '' path; do
    git -C "$WT" clean -fd -- "$path" >/dev/null || return 1
  done < "$capture_dir/untracked.paths"
}

prepare_preserved_worktree_scratch_locked() {
  local dirty_raw dirty
  validate_teardown_target_identity || return 1
  [ "$TREEHOUSE_TARGET_ALREADY_RETURNED" -eq 0 ] || {
    echo "REFUSED: --preserve-scratch cannot mutate an already-returned Treehouse worktree." >&2
    return 1
  }
  validate_worktree_stash_absent || return 1
  dirty_raw=$(git -C "$WT" status --porcelain=v1 --untracked-files=all 2>/dev/null) || {
    echo "REFUSED: cannot inspect worktree $WT before scratch preservation." >&2
    return 1
  }
  dirty=$(printf '%s\n' "$dirty_raw" | first_actionable_dirty_status || true)
  [ -n "$dirty" ] || return 0
  validate_worktree_committed_landing || return 1
  PRESERVED_SCRATCH_CAPTURE=
  capture_worktree_scratch || {
    echo "REFUSED: failed to capture worktree scratch; no cleanup was attempted." >&2
    return 1
  }
  clean_preserved_worktree_scratch "$PRESERVED_SCRATCH_CAPTURE" || {
    echo "REFUSED: preserved scratch but could not safely clean the worktree." >&2
    echo "Scratch capture: $PRESERVED_SCRATCH_CAPTURE" >&2
    return 1
  }
  validate_worktree_teardown_safety || {
    echo "REFUSED: worktree changed after scratch preservation; retaining it." >&2
    echo "Scratch capture: $PRESERVED_SCRATCH_CAPTURE" >&2
    return 1
  }
  echo "teardown: preserved worktree scratch at $PRESERVED_SCRATCH_CAPTURE"
}

prepare_preserved_worktree_scratch() {
  fm_checkout_lock_run \
    "$WT" "$CHECKOUT_LOCK_ROOT" prepare_preserved_worktree_scratch_locked
}

validate_child_worktree_landed_state() {
  local child_meta=$1 child_id=$2 child_worktree=$3 child_project=$4
  local stash_list
  local WT=$child_worktree PROJ=$child_project ID=$child_id KIND=ship FORCE=
  local MODE PR_URL TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=
  MODE=$(meta_value "$child_meta" mode)
  [ -n "$MODE" ] || MODE=no-mistakes
  PR_URL=$(meta_value "$child_meta" pr)
  stash_list=$(git -C "$WT" stash list 2>/dev/null) || {
    echo "REFUSED: child worktree stash state is uninspectable at $WT" >&2
    return 1
  }
  [ -z "$stash_list" ] || {
    echo "REFUSED: child worktree has retained stash history at $WT" >&2
    return 1
  }
  validate_worktree_teardown_safety
}

CHILD_RETURN_META=
CHILD_RETURN_ID=
validate_child_worktree_return_safety() {
  local child_worktree=$1 child_project=$2
  [ -n "$CHILD_RETURN_META" ] && [ -n "$CHILD_RETURN_ID" ] || return 1
  validate_child_worktree_landed_state "$CHILD_RETURN_META" "$CHILD_RETURN_ID" "$child_worktree" "$child_project"
}

require_orca_worktree_path_match() {
  local worktree_id=$1 inspected=$2 resolved inspected_abs resolved_abs
  fm_backend_source orca || return 1
  fm_backend_orca_authority_capabilities_check || return 1
  resolved=$(fm_backend_worktree_path orca "$worktree_id") || {
    echo "REFUSED: cannot resolve Orca worktree id $worktree_id to a path; preserving metadata." >&2
    return 1
  }
  inspected_abs=$(canonical_existing_dir "$inspected") || {
    echo "REFUSED: cannot canonicalize inspected worktree ${inspected:-<missing>}; preserving metadata." >&2
    return 1
  }
  resolved_abs=$(canonical_existing_dir "$resolved") || {
    echo "REFUSED: Orca worktree id $worktree_id resolved to uninspectable path ${resolved:-<missing>}; preserving metadata." >&2
    return 1
  }
  if [ "$resolved_abs" != "$inspected_abs" ]; then
    echo "REFUSED: Orca worktree id $worktree_id resolves to $resolved_abs, not inspected worktree $inspected_abs." >&2
    echo "Cannot verify dirty or unlanded work for the worktree Orca would remove; preserving metadata." >&2
    return 1
  fi
}

require_orca_worktree_path_match_if_present() {
  local worktree_id=$1 inspected=$2
  [ -n "$inspected" ] && [ -e "$inspected" ] || return 0
  require_orca_worktree_path_match "$worktree_id" "$inspected"
}

firstmate_home_has_treehouse_slot() {
  local home=$1 expected_source=${2:-$FM_ROOT}
  worktree_registered_for_project "$expected_source" "$home"
}

validate_removal_target() {
  local target=$1 label=$2 abs_target abs_home abs_root
  [ -n "$target" ] || {
    echo "REFUSED: missing $label removal target" >&2
    return 1
  }
  abs_target=$(fm_checkout_trusted_dir "$target") || {
    echo "REFUSED: missing, redirected, or uninspectable $label removal target $target" >&2
    return 1
  }
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    :
  else
    abs_home=
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  case "$abs_target" in
    ''|/) echo "REFUSED: unsafe $label removal target $target" >&2; return 1 ;;
  esac
  if [ -n "$abs_home" ] && [ "$abs_target" = "$abs_home" ]; then
    echo "REFUSED: unsafe $label removal target $target is the active firstmate home" >&2
    return 1
  fi
  if [ "$abs_target" = "$abs_root" ]; then
    echo "REFUSED: unsafe $label removal target $target is the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_target" "$abs_home"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_target" "$abs_root"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_home" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

secondmate_registry_for_source() {
  local source=$1 source_root root
  source_root=$(exact_git_worktree_root "$source") || return 1
  root=$(exact_git_worktree_root "$FM_ROOT") || return 1
  if [ "$source_root" = "$root" ]; then
    printf '%s\n' "$SECONDMATE_REG"
  else
    printf '%s/data/secondmates.md\n' "$source_root"
  fi
}

require_registered_secondmate_home() {
  local reg=$1 expected_id=$2 expected_home=$3 registered expected_key registered_key
  if ! registered=$(fm_secondmate_registry_query "$reg" query "$expected_id" home); then
    if [ "$reg" = "$PREPARED_REGISTRY_PATH" ] \
      && [ "$expected_id" = "$PREPARED_REGISTRY_ID" ] \
      && [ "$expected_home" = "$PREPARED_REGISTRY_HOME" ] \
      && [ -n "$PREPARED_REGISTRY_BACKUP" ] \
      && fm_account_lifecycle_lock_owned "$PREPARED_REGISTRY_LOCK"; then
      registered=$(fm_secondmate_registry_query "$PREPARED_REGISTRY_BACKUP" query "$expected_id" home) || return 1
    else
      echo "REFUSED: secondmate registry is malformed, duplicated, redirected, or missing $expected_id at $reg" >&2
      return 1
    fi
  fi
  expected_key=$(fm_checkout_stable_path_key "$expected_home" directory 0 24) || return 1
  registered_key=$(fm_checkout_stable_path_key "$registered" directory 0 24) || return 1
  [ "$expected_key" = "$registered_key" ] || {
    echo "REFUSED: secondmate registry home for $expected_id does not match $expected_home" >&2
    return 1
  }
}

secondmate_state_metadata() {
  local home=$1 state
  state="$home/state"
  command -v python3 >/dev/null 2>&1 || {
    echo "REFUSED: python3 is required to inspect secondmate child state" >&2
    return 1
  }
  python3 - "$home" "$state" <<'PY'
import os
import stat
import sys

home, state_path = sys.argv[1:]
try:
    if os.path.islink(state_path):
        raise OSError("state directory must not be a symlink")
    metadata = os.stat(state_path)
    permissions = stat.S_IMODE(metadata.st_mode)
    if not stat.S_ISDIR(metadata.st_mode):
        raise NotADirectoryError(state_path)
    if not permissions & 0o444 or not permissions & 0o111:
        raise PermissionError("state directory is unreadable")
    home_root = os.path.realpath(home)
    state_root = os.path.realpath(state_path)
    if state_root != os.path.join(home_root, "state"):
        raise OSError("state directory resolves outside its secondmate home")
    with os.scandir(state_path) as entries:
        for entry in sorted(entries, key=lambda item: item.name):
            metadata = entry.stat(follow_symlinks=False)
            if not entry.name.endswith(".meta"):
                continue
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise OSError(f"unsafe child metadata entry: {entry.path}")
            if not stat.S_IMODE(metadata.st_mode) & 0o444:
                raise PermissionError(f"unreadable child metadata entry: {entry.path}")
            if any(character in entry.path for character in ("\n", "\r")):
                raise OSError("child metadata path contains unsupported control characters")
            print(entry.path)
except OSError as error:
    print(
        f"REFUSED: secondmate child state is unprovable at {state_path}: {error}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

require_empty_secondmate_state() {
  local home=$1 child_metas
  child_metas=$(secondmate_state_metadata "$home") || return 1
  [ -z "$child_metas" ] || {
    echo "REFUSED: secondmate child metadata appeared before home removal at $home/state" >&2
    return 1
  }
}

validate_firstmate_operational_dirs_for_removal() {
  local home=$1 label=$2 name dir abs_home abs_dir
  abs_home=$(removal_target_abs_path "$home")
  for name in data state config projects; do
    dir="$home/$name"
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name path $dir is not a directory" >&2
      return 1
    else
      abs_dir=
    fi
    if [ -z "$abs_dir" ] || ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
    # Refuse a symlinked operational directory outright, even one resolving inside
    # the home. Teardown is destructive and proves what it deletes by exact physical
    # identity - canonical paths and device:inode checks - and a symlink is precisely
    # what makes the logical path differ from the physical target it would delete.
    # secondmate_state_metadata already refuses any symlinked state directory for
    # that reason; this closes the same hole for the other three instead of
    # permitting a hazardous degree of freedom nothing asks for.
    if [ -L "$dir" ]; then
      echo "REFUSED: unsafe $label $name path $dir is a symlink to $abs_dir; teardown removes only physical directories it can prove by identity" >&2
      return 1
    fi
  done
}

validate_child_worktree_for_removal() {
  local target=$1 project=$2 abs_target abs_project abs_home abs_root target_common project_common
  [ -n "$target" ] && [ -e "$target" ] || {
    echo "REFUSED: missing child worktree removal target ${target:-<empty>}" >&2
    return 1
  }
  abs_target=$(validate_removal_target "$target" "child worktree") || return 1
  abs_target=$(exact_git_worktree_root "$abs_target") || {
    echo "REFUSED: unsafe child worktree removal target $target is not an exact Git root" >&2
    return 1
  }
  abs_project=$(exact_git_worktree_root "$project") || {
    echo "REFUSED: child project metadata $project is not an exact Git root" >&2
    return 1
  }
  [ "$abs_target" != "$abs_project" ] || {
    echo "REFUSED: child worktree removal target resolves to its backing project root: $abs_target" >&2
    return 1
  }
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    if path_is_ancestor_of "$abs_home" "$abs_target"; then
      echo "REFUSED: unsafe child worktree removal target $target is inside the active firstmate home" >&2
      return 1
    fi
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe child worktree removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  target_common=$(fm_checkout_git_common_dir "$abs_target") || return 1
  project_common=$(fm_checkout_git_common_dir "$abs_project") || return 1
  if [ "$target_common" != "$project_common" ] \
      || ! worktree_registered_for_project "$abs_project" "$abs_target"; then
    echo "REFUSED: unsafe child worktree removal target $target is not a git worktree for $abs_project" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

validate_removal_tree_boundaries() {
  local target=$1 label=$2
  removal_tree_operation "$target" "$label" validate
}

removal_tree_boundary_token() {
  local target=$1 label=$2
  validate_removal_tree_boundaries "$target" "$label" || return 1
  fm_checkout_tree_boundary_token "$target"
}

removal_tree_operation() {
  local target=$1 label=$2 operation=$3
  FM_REMOVAL_BOUNDARY_LABEL=$label python3 - "$target" "$operation" <<'PY'
import os
import stat
import sys

raw_root = sys.argv[1]
operation = sys.argv[2]
label = os.environ["FM_REMOVAL_BOUNDARY_LABEL"]
if not raw_root or "\x00" in raw_root or "\n" in raw_root or "\r" in raw_root:
    print(f"REFUSED: {label} removal target is empty or malformed", file=sys.stderr)
    raise SystemExit(1)
root = os.path.normpath(os.path.abspath(raw_root))
injected = ""
if os.environ.get("FM_ACCOUNT_ROUTING_TEST_LAB") == "firstmate-account-routing-test-lab-v1":
    injected = os.environ.get("FM_TEARDOWN_TEST_MOUNT_PATH", "")
    if injected:
        injected = os.path.realpath(injected)

def mountinfo_paths():
    paths = set()
    path = "/proc/self/mountinfo"
    if not os.path.exists(path):
        return paths
    with open(path, "r", encoding="utf-8") as stream:
        for line in stream:
            fields = line.rstrip("\n").split()
            if len(fields) < 5:
                raise OSError("malformed mount table")
            value = fields[4]
            for encoded, decoded in (
                ("\\040", " "),
                ("\\011", "\t"),
                ("\\012", "\n"),
                ("\\134", "\\"),
            ):
                value = value.replace(encoded, decoded)
            paths.add(os.path.realpath(value))
    return paths

def identity(metadata):
    return metadata.st_dev, metadata.st_ino

try:
    if operation not in ("validate", "remove") or root == os.path.sep:
        raise OSError("invalid removal operation")
    current = os.path.sep
    for component in root.split(os.path.sep):
        if not component:
            continue
        current = os.path.join(current, component)
        metadata = os.lstat(current)
        if stat.S_ISLNK(metadata.st_mode):
            raise OSError(f"redirected path component {current}")
    parent = os.path.dirname(root)
    name = os.path.basename(root)
    parent_flags = os.O_RDONLY | os.O_DIRECTORY
    directory_flags = parent_flags
    if hasattr(os, "O_NOFOLLOW"):
        parent_flags |= os.O_NOFOLLOW
        directory_flags |= os.O_NOFOLLOW
    parent_fd = os.open(parent, parent_flags)
    parent_metadata = os.fstat(parent_fd)
    try:
        root_metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        os.close(parent_fd)
        raise OSError("removal root disappeared")
    if stat.S_ISLNK(root_metadata.st_mode) or not stat.S_ISDIR(root_metadata.st_mode):
        os.close(parent_fd)
        raise OSError("removal root is not a real directory")
    root_fd = os.open(name, directory_flags, dir_fd=parent_fd)
    opened_root_metadata = os.fstat(root_fd)
    if identity(root_metadata) != identity(opened_root_metadata):
        os.close(root_fd)
        os.close(parent_fd)
        raise OSError("removal root identity changed")
    root_device = root_metadata.st_dev
    mounted_paths = mountinfo_paths()

    def reject_boundary(path, metadata, is_root=False):
        canonical = os.path.realpath(path)
        if canonical == injected:
            raise OSError(f"mounted path {canonical}")
        if metadata.st_dev != root_device:
            raise OSError(f"filesystem device boundary at {canonical}")
        if canonical in mounted_paths or os.path.ismount(canonical):
            raise OSError(f"mount boundary at {canonical}")
        if is_root and metadata.st_dev != parent_metadata.st_dev:
            raise OSError(f"removal root filesystem boundary at {canonical}")

    def traverse(directory_fd, path):
        reject_boundary(path, os.fstat(directory_fd))
        for entry in sorted(os.listdir(directory_fd)):
            metadata = os.stat(entry, dir_fd=directory_fd, follow_symlinks=False)
            entry_path = os.path.join(path, entry)
            if stat.S_ISLNK(metadata.st_mode):
                if operation == "remove":
                    current = os.stat(entry, dir_fd=directory_fd, follow_symlinks=False)
                    if identity(current) != identity(metadata):
                        raise OSError(f"symlink identity changed at {entry_path}")
                    os.unlink(entry, dir_fd=directory_fd)
                continue
            if stat.S_ISDIR(metadata.st_mode):
                child_fd = os.open(entry, directory_flags, dir_fd=directory_fd)
                try:
                    opened = os.fstat(child_fd)
                    if identity(metadata) != identity(opened):
                        raise OSError(f"directory identity changed at {entry_path}")
                    reject_boundary(entry_path, opened)
                    traverse(child_fd, entry_path)
                    if operation == "remove":
                        current = os.stat(entry, dir_fd=directory_fd, follow_symlinks=False)
                        if identity(current) != identity(opened):
                            raise OSError(f"directory identity changed at {entry_path}")
                        os.rmdir(entry, dir_fd=directory_fd)
                finally:
                    os.close(child_fd)
                continue
            reject_boundary(entry_path, metadata)
            if operation == "remove":
                current = os.stat(entry, dir_fd=directory_fd, follow_symlinks=False)
                if identity(current) != identity(metadata):
                    raise OSError(f"entry identity changed at {entry_path}")
                os.unlink(entry, dir_fd=directory_fd)

    try:
        reject_boundary(root, opened_root_metadata, True)
        traverse(root_fd, root)
        if operation == "remove":
            current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if identity(current) != identity(opened_root_metadata):
                raise OSError("removal root identity changed before release")
            reject_boundary(root, current, True)
            os.rmdir(name, dir_fd=parent_fd)
    finally:
        os.close(root_fd)
        os.close(parent_fd)
except OSError as error:
    print(
        f"REFUSED: {label} removal crosses an untrusted filesystem boundary: {error}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

safe_rm_rf() {
  local target=$1 label=$2 canonical
  canonical=$(validate_removal_target "$target" "$label") || return 1
  removal_tree_operation "$canonical" "$label" remove
}

safe_rm_rf_child_worktree() {
  local target=$1 project=$2 canonical
  canonical=$(validate_child_worktree_for_removal "$target" "$project") || return 1
  removal_tree_operation "$canonical" "child worktree" remove
}

safe_remove_task_tmp() {
  local target=$1 base
  [ -n "$target" ] || return 0
  [ "$target" = "/tmp/fm-$ID" ] || return 1
  base=$(python3 - <<'PY'
import os
import stat

base = os.path.realpath("/tmp")
if base not in ("/tmp", "/private/tmp"):
    raise SystemExit(1)
current = os.path.sep
for component in base.split(os.path.sep):
    if not component:
        continue
    current = os.path.join(current, component)
    metadata = os.lstat(current)
    if stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(1)
if not stat.S_ISDIR(os.lstat(base).st_mode):
    raise SystemExit(1)
print(base)
PY
  ) || return 1
  removal_tree_operation "$base/fm-$ID" "task temp root" remove
}

remove_worktree_compatibility_artifacts() {
  local target=$1 label=$2
  FM_COMPATIBILITY_CLEANUP_LABEL=$label python3 - "$target" <<'PY'
import os
import stat
import sys

root = os.path.normpath(os.path.abspath(sys.argv[1]))
label = os.environ["FM_COMPATIBILITY_CLEANUP_LABEL"]
if not sys.argv[1] or root == os.path.sep:
    raise SystemExit(1)
try:
    current = os.path.sep
    for component in root.split(os.path.sep):
        if not component:
            continue
        current = os.path.join(current, component)
        metadata = os.lstat(current)
        if stat.S_ISLNK(metadata.st_mode):
            raise OSError(f"redirected path component {current}")
except FileNotFoundError:
    raise SystemExit(0)
flags = os.O_RDONLY | os.O_DIRECTORY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
root_fd = os.open(root, flags)
try:
    for relative in (
        ".claude/settings.local.json",
        ".opencode/plugins/fm-turn-end.js",
        ".fm-grok-turnend",
    ):
        parts = relative.split("/")
        directory_fd = os.dup(root_fd)
        try:
            for component in parts[:-1]:
                try:
                    child = os.open(component, flags, dir_fd=directory_fd)
                except FileNotFoundError:
                    break
                os.close(directory_fd)
                directory_fd = child
            else:
                try:
                    metadata = os.stat(
                        parts[-1],
                        dir_fd=directory_fd,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    continue
                if stat.S_ISDIR(metadata.st_mode):
                    raise OSError(f"compatibility artifact is a directory: {relative}")
                os.unlink(parts[-1], dir_fd=directory_fd)
        finally:
            os.close(directory_fd)
except OSError as error:
    print(f"REFUSED: {label} compatibility cleanup is unsafe: {error}", file=sys.stderr)
    raise SystemExit(1)
finally:
    os.close(root_fd)
PY
}

repository_remote_identity() {
  local repository=$1 remote=$2 candidate
  case "$remote" in
    file://*) candidate=${remote#file://} ;;
    /*|./*|../*) candidate=$remote ;;
    *) printf 'remote:%s\n' "$remote"; return 0 ;;
  esac
  case "$candidate" in
    /*) ;;
    *) candidate="$repository/$candidate" ;;
  esac
  candidate=$(canonical_existing_dir "$candidate") || return 1
  printf 'path:%s\n' "$candidate"
}

validate_firstmate_home_repository_identity() {
  local home=$1 expected_source=$2 home_root source_root home_common source_common home_origin source_origin
  local home_identity source_identity source_path_identity
  home_root=$(exact_git_worktree_root "$home") || {
    echo "REFUSED: secondmate home repository identity is uninspectable at $home" >&2
    return 1
  }
  source_root=$(exact_git_worktree_root "$expected_source") || return 1
  home_common=$(fm_checkout_git_common_dir "$home_root") || return 1
  source_common=$(fm_checkout_git_common_dir "$source_root") || return 1
  [ "$home_common" != "$source_common" ] || return 0
  home_origin=$(git -C "$home_root" remote get-url origin 2>/dev/null) || {
    echo "REFUSED: secondmate home origin identity is unavailable at $home_root" >&2
    return 1
  }
  home_identity=$(repository_remote_identity "$home_root" "$home_origin") || return 1
  source_path_identity="path:$source_root"
  source_identity=
  if source_origin=$(git -C "$source_root" remote get-url origin 2>/dev/null); then
    source_identity=$(repository_remote_identity "$source_root" "$source_origin") || return 1
  fi
  if [ "$home_identity" != "$source_path_identity" ] && [ "$home_identity" != "$source_identity" ]; then
    echo "REFUSED: secondmate home repository identity does not match $source_root" >&2
    return 1
  fi
}

validate_secondmate_home_landed_state() {
  local home=$1 expected_source=$2 dirty unsafe branch default source_default_ref source_default_tip
  local refs ref tip live_output live_branch live_tip cached_tip stash_list home_common source_common live_status reflog_tips
  git_history_rewrite_state_is_clean "$home" "secondmate home repository" || return 1
  git_history_rewrite_state_is_clean "$expected_source" "secondmate top-level source repository" || return 1
  dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "$home" status --porcelain=v1 --untracked-files=all 2>/dev/null) || {
    echo "REFUSED: secondmate home cleanliness is uninspectable at $home" >&2
    return 1
  }
  unsafe=$(printf '%s\n' "$dirty" | awk '
    $0 == "?? .claude/settings.local.json" { next }
    $0 == "?? .opencode/plugins/fm-turn-end.js" { next }
    $0 == "?? .fm-grok-turnend" { next }
    $0 != "" { print }
  ')
  [ -z "$unsafe" ] || {
    echo "REFUSED: secondmate home has unlanded changes at $home" >&2
    printf '%s\n' "$unsafe" >&2
    return 1
  }
  if git -C "$expected_source" remote get-url origin >/dev/null 2>&1; then
    if run_secondmate_remote_probe \
        live_output "$expected_source" "$home" --symref origin HEAD; then
      live_status=0
    else
      live_status=$?
    fi
    fm_process_tree_cleanup_verified || {
      echo "REFUSED: secondmate home upstream probe cleanup is unverified for $expected_source" >&2
      return 1
    }
    [ "$live_status" -eq 0 ] || {
      echo "REFUSED: secondmate home live upstream default is uninspectable from $expected_source" >&2
      return 1
    }
    live_branch=$(printf '%s\n' "$live_output" | sed -n 's/^ref: refs\/heads\/\([^[:space:]]*\)[[:space:]]*HEAD$/\1/p' | head -1)
    live_tip=$(printf '%s\n' "$live_output" | awk '$2 == "HEAD" && $1 != "ref:" { print $1; exit }')
    [ -n "$live_branch" ] && [ -n "$live_tip" ] || {
      echo "REFUSED: secondmate home live upstream default identity is malformed" >&2
      return 1
    }
    default=$live_branch
    source_default_ref="refs/remotes/origin/$default"
    cached_tip=$(git -C "$expected_source" rev-parse "$source_default_ref^{commit}" 2>/dev/null) || return 1
    [ "$cached_tip" = "$live_tip" ] || {
      echo "REFUSED: secondmate home source default is stale against live origin/$default" >&2
      return 1
    }
  elif git -C "$expected_source" show-ref --verify --quiet refs/heads/main; then
    default=main
    source_default_ref=refs/heads/main
  elif git -C "$expected_source" show-ref --verify --quiet refs/heads/master; then
    default=master
    source_default_ref=refs/heads/master
  else
    echo "REFUSED: secondmate home default branch is unprovable from $expected_source" >&2
    return 1
  fi
  if branch=$(git -C "$home" symbolic-ref --quiet --short HEAD 2>/dev/null); then
    [ "$branch" = "$default" ] || {
      echo "REFUSED: secondmate home is on non-default branch $branch at $home" >&2
      return 1
    }
  fi
  source_default_tip=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$expected_source" rev-parse "$source_default_ref^{commit}" 2>/dev/null) || {
    echo "REFUSED: secondmate home authoritative default tip is uninspectable at $expected_source" >&2
    return 1
  }
  home_common=$(fm_checkout_git_common_dir "$home") || return 1
  source_common=$(fm_checkout_git_common_dir "$expected_source") || return 1
  refs=
  stash_list=$(git -C "$home" stash list 2>/dev/null) || {
    echo "REFUSED: secondmate home stash state is uninspectable at $home" >&2
    return 1
  }
  [ -z "$stash_list" ] || {
    echo "REFUSED: secondmate home has retained stash history at $home" >&2
    return 1
  }
  if [ "$home_common" != "$source_common" ]; then
    refs=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$home" for-each-ref --format='%(refname)' 2>/dev/null) || {
      echo "REFUSED: secondmate home refs are uninspectable at $home" >&2
      return 1
    }
  fi
  reflog_tips=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$home" reflog --all --format='%H' 2>/dev/null) || {
    echo "REFUSED: secondmate home reflogs are uninspectable at $home" >&2
    return 1
  }
  refs=$(printf 'HEAD\n%s\n%s\n' "$refs" "$reflog_tips")
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    tip=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$home" rev-parse "$ref^{commit}" 2>/dev/null) || {
      echo "REFUSED: secondmate home ref $ref cannot be resolved to a commit" >&2
      return 1
    }
    if ! GIT_NO_REPLACE_OBJECTS=1 git -C "$expected_source" \
        cat-file -e "$tip^{commit}" 2>/dev/null \
        || ! GIT_NO_REPLACE_OBJECTS=1 git -C "$expected_source" \
          merge-base --is-ancestor "$tip" "$source_default_tip" 2>/dev/null; then
      echo "REFUSED: secondmate home ref $ref has commits not proven in authoritative $default" >&2
      return 1
    fi
  done <<EOF
$refs
EOF
}

exact_git_repository_root() {
  local repository=$1 container=${2:-$1} bare git_dir common metadata top container_git
  bare=$(git -C "$repository" rev-parse --is-bare-repository 2>/dev/null) || return 1
  if [ "$bare" = true ]; then
    git_dir=$(git -C "$repository" rev-parse --absolute-git-dir 2>/dev/null) || return 1
    git_dir=$(fm_checkout_trusted_dir "$git_dir") || return 1
    [ "$git_dir" = "$repository" ] || return 1
    printf '%s\n' "$repository"
  elif exact_git_worktree_root "$repository" >/dev/null 2>&1; then
    exact_git_worktree_root "$repository"
  else
    top=$(git -C "$repository" rev-parse --show-toplevel 2>/dev/null) || return 1
    top=$(fm_checkout_trusted_dir "$top") || return 1
    [ "$top" = "$repository" ] || return 1
    metadata="$repository/.git"
    [ -f "$metadata" ] && [ ! -L "$metadata" ] || return 1
    git_dir=$(git -C "$repository" rev-parse --absolute-git-dir 2>/dev/null) || return 1
    git_dir=$(fm_checkout_trusted_dir "$git_dir") || return 1
    common=$(git -C "$repository" rev-parse --git-common-dir 2>/dev/null) || return 1
    case "$common" in /*) ;; *) common="$repository/$common" ;; esac
    common=$(fm_checkout_trusted_dir "$common") || return 1
    [ "$git_dir" = "$common" ] || return 1
    container=$(fm_checkout_trusted_dir "$container") || return 1
    container_git=$(git -C "$container" rev-parse --absolute-git-dir 2>/dev/null) || return 1
    container_git=$(fm_checkout_trusted_dir "$container_git") || return 1
    case "$common/" in "$container_git/modules/"*) ;; *) return 1 ;; esac
    printf '%s\n' "$repository"
  fi
}

git_history_rewrite_state_is_clean() {
  local repository=$1 label=$2 grafts replacements status
  [ -z "${GIT_REPLACE_REF_BASE:-}" ] || {
    echo "REFUSED: $label uses an ambient replacement-ref namespace" >&2
    return 1
  }
  grafts=$(git -C "$repository" rev-parse --git-path info/grafts 2>/dev/null) || return 1
  case "$grafts" in /*) ;; *) grafts="$repository/$grafts" ;; esac
  if [ -e "$grafts" ] || [ -L "$grafts" ]; then
    echo "REFUSED: $label uses local grafted history at $grafts" >&2
    return 1
  fi
  if replacements=$(git -C "$repository" for-each-ref --format='%(refname)' refs/replace 2>/dev/null); then
    [ -z "$replacements" ] || {
      echo "REFUSED: $label uses replacement refs" >&2
      return 1
    }
  else
    status=$?
    [ "$status" -eq 0 ] || return 1
  fi
}

secondmate_network_remote_identity() {
  local repository=$1 url=$2 transport=$3 host=$4 user=$5 port=$6
  local ssh_output ssh_status resolved_host effective_user effective_port
  local proxy_command proxy_jump local_command remote_command permit_local
  local resolution resolution_status config_output config_status config_key
  local -a ssh_args
  case "$host" in
    ''|-*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  [ -z "${GIT_SSH_COMMAND+x}" ] \
    && [ -z "${GIT_SSH+x}" ] \
    && [ -z "${GIT_SSH_VARIANT+x}" ] \
    && [ -z "${GIT_PROXY_COMMAND+x}" ] \
    && [ -z "${GIT_CONFIG_COUNT+x}" ] \
    && [ -z "${GIT_CONFIG_PARAMETERS+x}" ] || return 1
  for config_key in core.sshCommand ssh.variant core.gitProxy http.proxy \
      remote.origin.proxy remote.origin.uploadpack remote.origin.receivepack; do
    if config_output=$(git -C "$repository" config --get-all "$config_key" 2>/dev/null); then
      [ -z "$config_output" ] || return 1
    else
      config_status=$?
      [ "$config_status" -eq 1 ] || return 1
    fi
  done
  if config_output=$(git -C "$repository" config --get-regexp \
      '^(http\..*\.proxy|http\.proxy|remote\..*\.(proxy|uploadpack|receivepack))$' \
      2>/dev/null); then
    [ -z "$config_output" ] || return 1
  else
    config_status=$?
    [ "$config_status" -eq 1 ] || return 1
  fi
  if config_output=$(git -C "$repository" config --get-regexp \
      '^url\..*\.[iI]nstead[Oo]f$' 2>/dev/null); then
    [ -z "$config_output" ] || return 1
  else
    config_status=$?
    [ "$config_status" -eq 1 ] || return 1
  fi
  resolved_host=$host
  case "$transport" in
  ssh|git+ssh)
    [ -x /usr/bin/ssh ] || return 1
    ssh_args=(-G)
    [ -z "$user" ] || ssh_args+=(-l "$user")
    [ -z "$port" ] || ssh_args+=(-p "$port")
    ssh_args+=("$host")
    if fm_run_bounded_capture --combine-stderr ssh_output "$TEARDOWN_UPSTREAM_TIMEOUT" \
        /usr/bin/ssh "${ssh_args[@]}"; then
      ssh_status=0
    else
      ssh_status=$?
    fi
    fm_process_tree_cleanup_verified || return 1
    [ "$ssh_status" -eq 0 ] || return 1
    [ "$(printf '%s\n' "$ssh_output" | awk '$1 == "hostname" { count++ } END { print count + 0 }')" -eq 1 ] \
      || return 1
    resolved_host=$(printf '%s\n' "$ssh_output" | awk '$1 == "hostname" { print $2; exit }')
    effective_user=$(printf '%s\n' "$ssh_output" | awk '$1 == "user" { print $2; exit }')
    effective_port=$(printf '%s\n' "$ssh_output" | awk '$1 == "port" { print $2; exit }')
    proxy_command=$(printf '%s\n' "$ssh_output" | awk '$1 == "proxycommand" { $1=""; sub(/^ /, ""); print; exit }')
    proxy_jump=$(printf '%s\n' "$ssh_output" | awk '$1 == "proxyjump" { print $2; exit }')
    local_command=$(printf '%s\n' "$ssh_output" | awk '$1 == "localcommand" { $1=""; sub(/^ /, ""); print; exit }')
    remote_command=$(printf '%s\n' "$ssh_output" | awk '$1 == "remotecommand" { $1=""; sub(/^ /, ""); print; exit }')
    permit_local=$(printf '%s\n' "$ssh_output" | awk '$1 == "permitlocalcommand" { print $2; exit }')
    [ -z "$user" ] || [ "$effective_user" = "$user" ] || return 1
    [ -z "$port" ] || [ "$effective_port" = "$port" ] || return 1
    [ -z "$proxy_command" ] || [ "$proxy_command" = none ] || return 1
    [ -z "$proxy_jump" ] || [ "$proxy_jump" = none ] || return 1
    [ -z "$local_command" ] || [ "$local_command" = none ] || return 1
    [ -z "$remote_command" ] || [ "$remote_command" = none ] || return 1
    [ -z "$permit_local" ] || [ "$permit_local" = no ] || return 1
    ;;
  http) effective_port=${port:-80} ;;
  https) effective_port=${port:-443} ;;
  git) effective_port=${port:-9418} ;;
  *) return 1 ;;
  esac
  case "$resolved_host" in
    ''|-*|*[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  case "$effective_port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if fm_run_bounded_capture --combine-stderr resolution "$TEARDOWN_UPSTREAM_TIMEOUT" \
      python3 - "$resolved_host" <<'PY'
import ipaddress
import os
import re
import socket
import subprocess
import sys

host = sys.argv[1].lower().rstrip(".")

def addresses(name):
    values = set()
    for result in socket.getaddrinfo(name, None, socket.AF_UNSPEC, socket.SOCK_STREAM):
        value = result[4][0].split("%", 1)[0]
        values.add(ipaddress.ip_address(value))
    return values

def local_interface_addresses():
    values = set()
    commands = (
        ("/sbin/ifconfig",),
        ("/usr/sbin/ifconfig",),
        ("/usr/sbin/ip", "-o", "addr", "show"),
        ("/sbin/ip", "-o", "addr", "show"),
    )
    output = None
    for command in commands:
        if not os.path.isfile(command[0]) or not os.access(command[0], os.X_OK):
            continue
        completed = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
        if completed.returncode == 0:
            output = completed.stdout
            break
    if output is None:
        raise OSError("local interface inventory unavailable")
    for match in re.findall(r"\binet6?\s+(?:addr:)?([0-9A-Fa-f:.]+)(?:%[^\s]+)?", output):
        try:
            values.add(ipaddress.ip_address(match))
        except ValueError:
            pass
    if not values:
        raise OSError("local interface inventory is empty")
    return values

try:
    local_names = {
        "localhost",
        socket.gethostname().lower().rstrip("."),
        socket.getfqdn().lower().rstrip("."),
    }
    if host in local_names:
        raise OSError("remote hostname names this machine")
    injected = os.environ.get("FM_TEARDOWN_TEST_NETWORK_ADDRESSES", "")
    if (
        os.environ.get("FM_ACCOUNT_ROUTING_TEST_LAB")
        == "firstmate-account-routing-test-lab-v1"
        and injected
    ):
        remote = {
            ipaddress.ip_address(value.strip())
            for value in injected.split(",")
            if value.strip()
        }
    else:
        remote = addresses(host)
    local = local_interface_addresses()
    for name in tuple(local_names):
        if not name:
            continue
        try:
            local.update(addresses(name))
        except OSError:
            pass
    if not remote:
        raise OSError("remote hostname has no addresses")
    for address in remote:
        if (
            address.is_loopback
            or address.is_link_local
            or address.is_unspecified
            or address.is_multicast
            or address in local
        ):
            raise OSError("remote hostname resolves to local or ephemeral storage")
    print(",".join(sorted(str(address) for address in remote)))
except (OSError, ValueError, socket.gaierror, subprocess.SubprocessError):
    raise SystemExit(1)
PY
  then
    resolution_status=0
  else
    resolution_status=$?
  fi
  fm_process_tree_cleanup_verified || return 1
  [ "$resolution_status" -eq 0 ] && [ -n "$resolution" ] || return 1
  printf 'network\t%s\t%s\t%s\t%s\t%s\n' \
    "$transport" "$url" "$resolved_host" "$effective_port" "$resolution"
}

validate_surviving_object_graph_bound() {
  local repository=$1 objects=$2 retiring_home=$3 label=$4
  FM_SURVIVING_REPOSITORY_LABEL=$label python3 - "$repository" "$objects" "$retiring_home" <<'PY'
import os
import stat
import subprocess
import sys
import time

repository, initial, retiring_home = map(os.path.realpath, sys.argv[1:])
label = os.environ["FM_SURVIVING_REPOSITORY_LABEL"]
held = []
visited = set()

def confined(path):
    try:
        return os.path.commonpath((retiring_home, path)) == retiring_home
    except ValueError:
        return False

def retain(path, expected_directory, hold_file=False):
    metadata = os.lstat(path)
    if stat.S_ISLNK(metadata.st_mode):
        raise OSError(f"redirected object storage entry: {path}")
    if expected_directory and not stat.S_ISDIR(metadata.st_mode):
        raise OSError(f"object storage directory is not a directory: {path}")
    if not expected_directory and not stat.S_ISREG(metadata.st_mode):
        raise OSError(f"object storage entry is not a regular file: {path}")
    flags = os.O_RDONLY
    if expected_directory:
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    opened = os.fstat(descriptor)
    expected = (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IFMT(metadata.st_mode),
        metadata.st_size,
    )
    actual = (
        opened.st_dev,
        opened.st_ino,
        stat.S_IFMT(opened.st_mode),
        opened.st_size,
    )
    if expected != actual:
        os.close(descriptor)
        raise OSError(f"object storage identity changed at {path}")
    if confined(os.path.realpath(path)):
        os.close(descriptor)
        raise OSError(f"object storage depends on retiring home: {path}")
    if not expected_directory and not hold_file:
        os.close(descriptor)
        descriptor = None
    held.append((path, descriptor, expected))
    return descriptor, opened

def inspect(objects):
    objects = os.path.normpath(objects)
    directory, metadata = retain(objects, True)
    held_index = len(held) - 1
    identity = (metadata.st_dev, metadata.st_ino)
    if identity in visited:
        os.close(directory)
        held.pop()
        return
    visited.add(identity)
    object_device = metadata.st_dev
    for name in sorted(os.listdir(directory)):
        path = os.path.join(objects, name)
        item = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if item.st_dev != object_device:
            raise OSError(f"object storage crosses a filesystem boundary: {path}")
        if stat.S_ISLNK(item.st_mode):
            raise OSError(f"redirected object storage entry: {path}")
        if stat.S_ISDIR(item.st_mode):
            inspect(path)
        elif stat.S_ISREG(item.st_mode):
            retain(path, False)
        else:
            raise OSError(f"unsafe object storage entry: {path}")
    alternates = os.path.join(objects, "info", "alternates")
    http_alternates = os.path.join(objects, "info", "http-alternates")
    if os.path.lexists(http_alternates):
        raise OSError(f"HTTP alternates are not durable proof: {http_alternates}")
    if not os.path.lexists(alternates):
        if objects != initial:
            os.close(directory)
            held[held_index] = (objects, None, held[held_index][2])
        return
    alternate_fd, _ = retain(alternates, False, True)
    with os.fdopen(os.dup(alternate_fd), "r", encoding="utf-8") as stream:
        entries = [line.rstrip("\n") for line in stream]
    if not entries or any(not entry or "\x00" in entry for entry in entries):
        raise OSError(f"malformed alternates file: {alternates}")
    for entry in entries:
        if entry.startswith('"') or entry.endswith('"'):
            raise OSError(f"quoted alternates are ambiguous: {alternates}")
        candidate = entry if os.path.isabs(entry) else os.path.join(objects, entry)
        inspect(os.path.realpath(candidate))
    if objects != initial:
        os.close(directory)
        held[held_index] = (objects, None, held[held_index][2])

def verify_retained():
    for path, descriptor, expected in held:
        metadata = os.lstat(path)
        current = (
            metadata.st_dev,
            metadata.st_ino,
            stat.S_IFMT(metadata.st_mode),
            metadata.st_size,
        )
        retained = expected
        if descriptor is not None:
            opened = os.fstat(descriptor)
            retained = (
                opened.st_dev,
                opened.st_ino,
                stat.S_IFMT(opened.st_mode),
                opened.st_size,
            )
        if current != expected or retained != expected or stat.S_ISLNK(metadata.st_mode):
            raise OSError(f"object storage identity changed during graph proof: {path}")

def run(arguments, input_data=None):
    environment = os.environ.copy()
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    completed = subprocess.run(
        ["git", "-C", repository, *arguments],
        check=False,
        input=input_data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
    )
    verify_retained()
    return completed

try:
    inspect(initial)
    marker = os.environ.get("FM_TEARDOWN_TEST_OBJECT_SCAN_MARKER", "")
    release = os.environ.get("FM_TEARDOWN_TEST_OBJECT_SCAN_RELEASE", "")
    scan_root = os.environ.get("FM_TEARDOWN_TEST_OBJECT_SCAN_ROOT", "")
    if (
        os.environ.get("FM_ACCOUNT_ROUTING_TEST_LAB")
        == "firstmate-account-routing-test-lab-v1"
        and marker
        and release
        and scan_root
        and initial == os.path.realpath(scan_root)
    ):
        with open(marker, "w", encoding="utf-8"):
            pass
        deadline = time.monotonic() + 10
        while not os.path.exists(release):
            if time.monotonic() >= deadline:
                raise OSError("object storage test mutation did not release")
            time.sleep(0.01)
    verify_retained()
    revision_arguments = ["rev-list", "--objects", "--missing=print", "--all", "--reflog"]
    head = run(["rev-parse", "--verify", "HEAD^{object}"])
    if head.returncode == 0:
        revision_arguments.append("HEAD")
    objects = run(revision_arguments)
    if objects.returncode != 0:
        raise OSError("reachable objects cannot be enumerated")
    object_ids = []
    for line in objects.stdout.splitlines():
        if not line:
            continue
        if line.startswith("?"):
            raise OSError(f"promised object is missing: {line[1:].split()[0]}")
        object_id = line.split(" ", 1)[0]
        if not object_id:
            raise OSError("malformed reachable-object inventory")
        object_ids.append(object_id)
    if not object_ids:
        raise OSError("reachable-object inventory is empty")
    checked = run(
        ["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
        "\n".join(object_ids) + "\n",
    )
    if checked.returncode != 0:
        raise OSError("reachable objects cannot be inspected")
    records = checked.stdout.splitlines()
    if len(records) != len(object_ids):
        raise OSError("reachable-object inspection is incomplete")
    for requested, record in zip(object_ids, records):
        fields = record.split()
        if (
            len(fields) != 3
            or fields[0] != requested
            or fields[1] in ("missing", "promisor")
            or not fields[2].isdigit()
        ):
            raise OSError(f"reachable object is unavailable: {requested}")
    checked = run(["fsck", "--full", "--strict", "--no-dangling"])
    if checked.returncode != 0:
        raise OSError("required Git objects are incomplete")
    verify_retained()
except (OSError, UnicodeError, subprocess.SubprocessError) as error:
    print(f"REFUSED: {label} complete object graph is unavailable: {error}", file=sys.stderr)
    raise SystemExit(1)
finally:
    for _, descriptor, _ in reversed(held):
        if descriptor is not None:
            os.close(descriptor)
PY
}

validate_surviving_repository_authority_locked() {
  local repository=$1 retiring_home=$2 repository_container=${3:-$1}
  local label=${4:-repository} common git_dir objects listed records path kind canonical
  local allowed_retiring_worktree=${5:-} listed_common bare_repository count=0 refs ref
  local shallow partial_status
  [ "$(exact_git_repository_root "$repository" "$repository_container")" = "$repository" ] \
    || return 1
  git_history_rewrite_state_is_clean "$repository" "$label" || return 1
  [ -z "${GIT_OBJECT_DIRECTORY:-}" ] \
    && [ -z "${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}" ] || {
      echo "REFUSED: $label uses ambient Git object storage that cannot be proven durable" >&2
      return 1
    }
  common=$(git -C "$repository" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in /*) ;; *) common="$repository/$common" ;; esac
  common=$(fm_checkout_trusted_dir "$common") || return 1
  git_dir=$(git -C "$repository" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  git_dir=$(fm_checkout_trusted_dir "$git_dir") || return 1
  objects=$(git -C "$repository" rev-parse --git-path objects 2>/dev/null) || return 1
  case "$objects" in /*) ;; *) objects="$repository/$objects" ;; esac
  objects=$(fm_checkout_trusted_dir "$objects") || return 1
  for path in "$common" "$git_dir" "$objects"; do
    case "$path/" in
      "$retiring_home/"*)
        echo "REFUSED: $label Git storage depends on the retiring home at $path" >&2
        return 1
        ;;
    esac
  done
  shallow=$(git -C "$repository" rev-parse --is-shallow-repository 2>/dev/null) || return 1
  [ "$shallow" = false ] || {
    echo "REFUSED: $label is shallow and does not prove a complete surviving object graph" >&2
    return 1
  }
  if git -C "$repository" config --get extensions.partialClone >/dev/null 2>&1; then
    echo "REFUSED: $label uses promisor or partial-clone object semantics" >&2
    return 1
  else
    partial_status=$?
    [ "$partial_status" -eq 1 ] || return 1
  fi
  if git -C "$repository" config --get-regexp \
      '^remote\..*\.(promisor|partialclonefilter)$' >/dev/null 2>&1; then
    echo "REFUSED: $label uses promisor or partial-clone object semantics" >&2
    return 1
  else
    partial_status=$?
    [ "$partial_status" -eq 1 ] || return 1
  fi
  FM_SURVIVING_OBJECTS_LABEL=$label python3 - "$objects" "$retiring_home" <<'PY' || return 1
import os
import stat
import sys

initial, retiring_home = map(os.path.realpath, sys.argv[1:])
label = os.environ["FM_SURVIVING_OBJECTS_LABEL"]
visited = set()

def confined_to_retiring_home(path):
    try:
        return os.path.commonpath((retiring_home, path)) == retiring_home
    except ValueError:
        return False

def trusted_directory(path):
    path = os.path.normpath(path)
    if not os.path.isabs(path):
        raise OSError("object directory is not absolute")
    current = os.path.sep
    for component in path.split(os.path.sep):
        if not component:
            continue
        current = os.path.join(current, component)
        metadata = os.lstat(current)
        if stat.S_ISLNK(metadata.st_mode):
            raise OSError(f"redirected object path {current}")
    metadata = os.lstat(path)
    if not stat.S_ISDIR(metadata.st_mode) or os.path.realpath(path) != path:
        raise OSError(f"unsafe object directory {path}")
    return path

def inspect(objects):
    objects = trusted_directory(objects)
    metadata = os.lstat(objects)
    identity = (metadata.st_dev, metadata.st_ino)
    if identity in visited:
        return
    visited.add(identity)
    if confined_to_retiring_home(objects):
        raise OSError(f"object directory depends on retiring home: {objects}")
    object_device = metadata.st_dev
    pending = [objects]
    while pending:
        current = pending.pop()
        with os.scandir(current) as entries:
            for entry in entries:
                entry_metadata = entry.stat(follow_symlinks=False)
                if stat.S_ISLNK(entry_metadata.st_mode):
                    raise OSError(f"redirected object storage entry: {entry.path}")
                if entry_metadata.st_dev != object_device:
                    raise OSError(f"object storage crosses a filesystem boundary: {entry.path}")
                canonical = os.path.realpath(entry.path)
                if confined_to_retiring_home(canonical):
                    raise OSError(f"object storage entry depends on retiring home: {entry.path}")
                if stat.S_ISDIR(entry_metadata.st_mode):
                    if canonical != entry.path:
                        raise OSError(f"redirected object storage directory: {entry.path}")
                    pending.append(entry.path)
                elif not stat.S_ISREG(entry_metadata.st_mode):
                    raise OSError(f"unsafe object storage entry: {entry.path}")
    info = os.path.join(objects, "info")
    alternates = os.path.join(info, "alternates")
    http_alternates = os.path.join(info, "http-alternates")
    if os.path.lexists(http_alternates):
        raise OSError(f"HTTP alternates are not durable proof: {http_alternates}")
    if not os.path.lexists(alternates):
        return
    metadata = os.lstat(alternates)
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise OSError(f"unsafe alternates file: {alternates}")
    with open(alternates, "r", encoding="utf-8") as stream:
        entries = [line.rstrip("\n") for line in stream]
    if not entries or any(not entry or "\x00" in entry for entry in entries):
        raise OSError(f"malformed alternates file: {alternates}")
    for entry in entries:
        if entry.startswith('"') or entry.endswith('"'):
            raise OSError(f"quoted alternates are ambiguous: {alternates}")
        candidate = entry if os.path.isabs(entry) else os.path.join(objects, entry)
        inspect(os.path.realpath(candidate))

try:
    inspect(initial)
except (OSError, UnicodeError) as error:
    print(f"REFUSED: {label} object storage is not independently durable: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
  bare_repository=$(git -C "$repository" rev-parse --is-bare-repository 2>/dev/null) || return 1
  listed=$(git -C "$repository" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || {
    echo "REFUSED: $label linked-worktree graph is uninspectable at $repository" >&2
    return 1
  }
  records=$(printf '%s\n' "$listed" | awk '
    function emit() {
      if (path != "") printf "%s\t%s\n", path, is_bare ? "bare" : "worktree"
      path = ""
      is_bare = 0
    }
    /^worktree / { emit(); path = substr($0, 10); next }
    /^bare$/ { is_bare = 1; next }
    /^$/ { emit() }
    END { emit() }
  ') || return 1
  while IFS=$'\t' read -r path kind; do
    [ -n "$path" ] || continue
    canonical=$(fm_checkout_trusted_dir "$path") || {
      echo "REFUSED: $label linked worktree is missing or redirected at $path" >&2
      return 1
    }
    case "$canonical/" in
      "$retiring_home/"*)
        if [ -z "$allowed_retiring_worktree" ] \
            || [ "$canonical" != "$allowed_retiring_worktree" ]; then
          echo "REFUSED: $label linked-worktree graph depends on the retiring home at $canonical" >&2
          return 1
        fi
        ;;
    esac
    case "$kind" in
      bare)
        [ "$canonical" = "$common" ] || return 1
        if [ "$bare_repository" = true ]; then
          [ "$canonical" = "$repository" ] || return 1
          count=$((count + 1))
        fi
        ;;
      worktree)
        if [ "$canonical" = "$repository" ] \
            || { [ -f "$repository/.git" ] && [ "$canonical" = "$common" ]; }; then
          count=$((count + 1))
        else
          listed_common=$(fm_checkout_git_common_dir "$canonical") || return 1
          [ "$listed_common" = "$common" ] || return 1
        fi
        ;;
      *) return 1 ;;
    esac
  done <<EOF
$records
EOF
  [ "$count" -eq 1 ] || {
    echo "REFUSED: $label worktree identity is ambiguous at $repository" >&2
    return 1
  }
  refs=$(git -C "$repository" for-each-ref --format='%(refname)' 2>/dev/null) || {
    echo "REFUSED: $label refs are uninspectable at $repository" >&2
    return 1
  }
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    git -C "$repository" cat-file -e "$ref^{object}" 2>/dev/null || {
      echo "REFUSED: $label ref $ref depends on unavailable objects" >&2
      return 1
    }
  done <<EOF
$refs
EOF
  validate_surviving_object_graph_bound \
    "$repository" "$objects" "$retiring_home" "$label"
}

validate_surviving_repository_authority() {
  local repository=$1 container=${3:-$1} bare
  bare=$(git -C "$repository" rev-parse --is-bare-repository 2>/dev/null) || return 1
  if [ "$bare" = true ]; then
    validate_surviving_repository_authority_locked "$@"
    return
  fi
  # Serialize on the enclosing CONTAINER checkout, not on the nested repository
  # itself. The proof below is read-only; the lock exists so a concurrent checkout
  # mutation cannot invalidate it, and the container is the checkout that
  # enumeration walked and whose mutation is the hazard. It is also the only shape
  # that can be keyed: a submodule's .git is a gitlink FILE whose absolute git dir
  # IS its common dir (verified with git 2.50.1: <super>/.git/modules/<path>), and
  # `git worktree list` run inside one reports that git dir rather than the working
  # tree, so fm_checkout_validate_git_metadata's registered-worktree assertion can
  # never hold for it and the lock identity was simply unresolvable - which refused
  # every retirement of a home whose project carries a submodule. For a top-level
  # repository the container IS the repository, so that path is unchanged.
  fm_checkout_lock_run "$container" "$CHECKOUT_LOCK_ROOT" \
    validate_surviving_repository_authority_locked "$@"
}

secondmate_remote_identity() {
  local repository=$1 retiring_home=$2 url raw_urls parsed kind transport host user port path
  local canonical bare git_dir url_count
  raw_urls=$(git -C "$repository" config --get-all remote.origin.url 2>/dev/null) || return 1
  url_count=$(printf '%s\n' "$raw_urls" | awk 'NF { count++ } END { print count + 0 }') || return 1
  [ "$url_count" -eq 1 ] || return 1
  url=$(printf '%s\n' "$raw_urls" | sed -n '1p') || return 1
  [ "$(git -C "$repository" remote get-url origin 2>/dev/null)" = "$url" ] || return 1
  [ -n "$url" ] || return 1
  parsed=$(python3 - "$url" "$repository" <<'PY'
import ipaddress
import os
import re
import sys
import urllib.parse

url, repository = sys.argv[1:]

def loopback(host):
    normalized = host.lower().rstrip(".")
    if normalized == "localhost":
        return True
    try:
        return ipaddress.ip_address(normalized).is_loopback
    except ValueError:
        return False

try:
    if re.match(r"^[A-Za-z]:", url):
        raise ValueError
    if "://" in url:
        parsed = urllib.parse.urlparse(url)
        scheme = parsed.scheme.lower()
        host = parsed.hostname or ""
        if scheme == "file":
            if host and not loopback(host):
                raise ValueError
            path = urllib.parse.unquote(parsed.path)
            if not os.path.isabs(path):
                raise ValueError
            print("local\t" + path)
        elif scheme in ("ssh", "git+ssh", "git", "http", "https"):
            if loopback(host):
                if scheme not in ("ssh", "git+ssh", "git"):
                    raise ValueError
                path = urllib.parse.unquote(parsed.path)
                if not os.path.isabs(path):
                    raise ValueError
                print("local\t" + path)
            elif host:
                print(
                    "network\t"
                    + scheme
                    + "\t"
                    + host
                    + "\t"
                    + (parsed.username or "-")
                    + "\t"
                    + (str(parsed.port) if parsed.port is not None else "-")
                    + "\t"
                    + url
                )
            else:
                raise ValueError
        else:
            raise ValueError
    else:
        scp = re.match(r"^(?:([^@/:]+)@)?([^/:]+):(.+)$", url)
        if scp:
            user, host, path = scp.groups()
            if loopback(host):
                if not os.path.isabs(path):
                    raise ValueError
                print("local\t" + path)
            else:
                print("network\tssh\t" + host + "\t" + (user or "-") + "\t-\t" + url)
        else:
            path = url if os.path.isabs(url) else os.path.join(repository, url)
            print("local\t" + path)
except (OSError, ValueError):
    raise SystemExit(1)
PY
  ) || return 1
  IFS=$'\t' read -r kind transport host user port path <<EOF
$parsed
EOF
  if [ "$kind" = network ]; then
    [ "$user" != - ] || user=
    [ "$port" != - ] || port=
    secondmate_network_remote_identity \
      "$repository" "$path" "$transport" "$host" "$user" "$port"
    return $?
  fi
  [ "$kind" = local ] || return 1
  path=$transport
  canonical=$(fm_checkout_trusted_dir "$path") || return 1
  bare=$(git -C "$canonical" rev-parse --is-bare-repository 2>/dev/null) || return 1
  if [ "$bare" = true ]; then
    git_dir=$(git -C "$canonical" rev-parse --absolute-git-dir 2>/dev/null) || return 1
    git_dir=$(fm_checkout_trusted_dir "$git_dir") || return 1
    [ "$git_dir" = "$canonical" ] || return 1
  else
    [ "$(exact_git_worktree_root "$canonical")" = "$canonical" ] || return 1
  fi
  case "$canonical/" in
    "$retiring_home/"*) return 1 ;;
  esac
  validate_surviving_repository_authority \
    "$canonical" "$retiring_home" "$canonical" "secondmate project landing authority" \
    || return 1
  printf 'local\t%s\n' "$canonical"
}

secondmate_pinned_git_url() {
  python3 - "$1" "$2" <<'PY'
import ipaddress
import sys
import urllib.parse

url, address = sys.argv[1:]
parsed = urllib.parse.urlsplit(url)
if parsed.scheme.lower() != "git" or not parsed.hostname:
    raise SystemExit(1)
ip = ipaddress.ip_address(address)
host = f"[{ip}]" if ip.version == 6 else str(ip)
port = f":{parsed.port}" if parsed.port is not None else ""
user = f"{parsed.username}@" if parsed.username else ""
print(urllib.parse.urlunsplit((parsed.scheme, user + host + port, parsed.path, parsed.query, parsed.fragment)))
PY
}

run_secondmate_remote_probe() {
  local output_name=$1 repository=$2 retiring_home=$3 identity kind transport url bound_host bound_port addresses
  local pinned pinned_url curl_address ssh_command index
  local -a probe_args
  shift 3
  identity=$(secondmate_remote_identity "$repository" "$retiring_home") || return 1
  IFS=$'\t' read -r kind transport url bound_host bound_port addresses <<EOF
$identity
EOF
  probe_args=("$@")
  if [ "$kind" = local ]; then
    fm_run_bounded_capture --combine-stderr "$output_name" "$TEARDOWN_UPSTREAM_TIMEOUT" \
      git -C "$repository" ls-remote "${probe_args[@]}"
    return
  fi
  [ "$kind" = network ] && [ -n "$addresses" ] || return 1
  pinned=${addresses%%,*}
  case "$transport" in
    ssh|git+ssh)
      ssh_command="/usr/bin/ssh -oHostName=$pinned -oHostKeyAlias=$bound_host"
      fm_run_bounded_capture --combine-stderr "$output_name" "$TEARDOWN_UPSTREAM_TIMEOUT" \
        /usr/bin/env -u GIT_SSH -u GIT_SSH_COMMAND -u GIT_SSH_VARIANT \
        "GIT_SSH_COMMAND=$ssh_command" GIT_SSH_VARIANT=ssh \
        git -C "$repository" ls-remote "${probe_args[@]}"
      ;;
    http|https)
      curl_address=$pinned
      case "$curl_address" in *:*) curl_address="[$curl_address]" ;; esac
      fm_run_bounded_capture --combine-stderr "$output_name" "$TEARDOWN_UPSTREAM_TIMEOUT" \
        /usr/bin/env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
        -u ALL_PROXY -u all_proxy -u NO_PROXY -u no_proxy \
        git -C "$repository" \
          -c "http.curloptResolve=$bound_host:$bound_port:$curl_address" \
          ls-remote "${probe_args[@]}"
      ;;
    git)
      pinned_url=$(secondmate_pinned_git_url "$url" "$pinned") || return 1
      for index in "${!probe_args[@]}"; do
        [ "${probe_args[index]}" != origin ] || probe_args[index]=$pinned_url
      done
      fm_run_bounded_capture --combine-stderr "$output_name" "$TEARDOWN_UPSTREAM_TIMEOUT" \
        git -C "$repository" ls-remote "${probe_args[@]}"
      ;;
    *) return 1 ;;
  esac
}

prepare_secondmate_remote_authority() {
  local repository=$1 retiring_home=$2 identity kind transport url bound_host bound_port addresses authority state_root
  local object_format fetch_status pinned pinned_url curl_address ssh_command
  identity=$(secondmate_remote_identity "$repository" "$retiring_home") || return 1
  IFS=$'\t' read -r kind transport url bound_host bound_port addresses <<EOF
$identity
EOF
  if [ "$kind" = local ]; then
    printf 'local\t%s\n' "$transport"
    return 0
  fi
  [ "$kind" = network ] && [ -n "$transport" ] && [ -n "$url" ] || return 1
  pinned=${addresses%%,*}
  [ -n "$pinned" ] || return 1
  state_root=$(fm_checkout_trusted_dir "$STATE") || return 1
  authority=$(mktemp -d "$state_root/.remote-authority.XXXXXX") || return 1
  object_format=$(git -C "$repository" rev-parse --show-object-format 2>/dev/null) || {
    removal_tree_operation "$authority" "remote authority proof" remove || true
    return 1
  }
  git init --quiet --bare --object-format="$object_format" "$authority" >/dev/null 2>&1 || {
    removal_tree_operation "$authority" "remote authority proof" remove || true
    return 1
  }
  case "$transport" in
    ssh|git+ssh)
      ssh_command="/usr/bin/ssh -oHostName=$pinned -oHostKeyAlias=$bound_host"
      if /usr/bin/env -u GIT_SSH -u GIT_SSH_COMMAND -u GIT_SSH_VARIANT \
          -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS \
          GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
          "GIT_SSH_COMMAND=$ssh_command" GIT_SSH_VARIANT=ssh \
          git -C "$authority" fetch --quiet --force --no-tags --no-recurse-submodules \
            "$url" '+refs/heads/*:refs/heads/*'; then
        fetch_status=0
      else
        fetch_status=$?
      fi
      ;;
    http|https)
      curl_address=$pinned
      case "$curl_address" in *:*) curl_address="[$curl_address]" ;; esac
      if /usr/bin/env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
          -u ALL_PROXY -u all_proxy -u NO_PROXY -u no_proxy \
          -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS \
          GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
          git -C "$authority" -c http.proxy= -c http.followRedirects=false \
            -c "http.curloptResolve=$bound_host:$bound_port:$curl_address" \
            fetch --quiet --force --no-tags --no-recurse-submodules \
            "$url" '+refs/heads/*:refs/heads/*'; then
        fetch_status=0
      else
        fetch_status=$?
      fi
      ;;
    git)
      pinned_url=$(secondmate_pinned_git_url "$url" "$pinned") || fetch_status=1
      if [ -z "${pinned_url:-}" ]; then
        fetch_status=1
      elif /usr/bin/env -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS \
          GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
          git -C "$authority" fetch --quiet --force --no-tags --no-recurse-submodules \
            "$pinned_url" '+refs/heads/*:refs/heads/*'; then
        fetch_status=0
      else
        fetch_status=$?
      fi
      ;;
    *) fetch_status=1 ;;
  esac
  if [ "$fetch_status" -ne 0 ] \
      || ! validate_surviving_repository_authority \
        "$authority" "$retiring_home" "$authority" "network landing authority"; then
    removal_tree_operation "$authority" "remote authority proof" remove || true
    return 1
  fi
  printf 'network\t%s\n' "$authority"
}

cleanup_secondmate_remote_authority() {
  local kind=$1 authority=$2
  [ "$kind" != network ] || removal_tree_operation "$authority" "remote authority proof" remove
}

enumerate_secondmate_project_repositories() {
  python3 - "$1" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
root = os.path.realpath(root)
repositories = {"."}
visited = set()
symlink_targets = set()

def confined(path):
    try:
        return os.path.commonpath((root, path)) == root
    except ValueError:
        return False

def walk(current, ancestors):
    metadata = os.lstat(current)
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise OSError("unsafe project directory")
    identity = (metadata.st_dev, metadata.st_ino)
    if identity in ancestors:
        raise OSError("project directory cycle")
    if identity in visited:
        return
    visited.add(identity)
    relative = os.path.relpath(current, root)
    if relative != ".":
        git_marker = os.path.join(current, ".git")
        if os.path.lexists(git_marker):
            marker = os.lstat(git_marker)
            if stat.S_ISLNK(marker.st_mode) or not (
                stat.S_ISDIR(marker.st_mode) or stat.S_ISREG(marker.st_mode)
            ):
                raise OSError("unsafe git marker")
            repositories.add(relative)
        else:
            head = os.path.join(current, "HEAD")
            config = os.path.join(current, "config")
            objects = os.path.join(current, "objects")
            refs = os.path.join(current, "refs")
            if all(os.path.exists(path) for path in (head, config, objects, refs)):
                if not os.path.isfile(head) or not os.path.isfile(config):
                    raise OSError("unsafe bare repository")
                if not os.path.isdir(objects) or not os.path.isdir(refs):
                    raise OSError("unsafe bare repository")
                repositories.add(relative)
                return
    with os.scandir(current) as entries:
        ordered = sorted(entries, key=lambda entry: entry.name)
    for entry in ordered:
        if entry.name == ".git":
            continue
        path = entry.path
        entry_metadata = os.lstat(path)
        if stat.S_ISLNK(entry_metadata.st_mode):
            target_metadata = os.stat(path)
            if not stat.S_ISDIR(target_metadata.st_mode):
                continue
            target = os.path.realpath(path)
            if not confined(target):
                raise OSError("escaping project directory symlink")
            target_identity = (target_metadata.st_dev, target_metadata.st_ino)
            if target_identity in ancestors or target_identity == identity:
                raise OSError("project directory symlink cycle")
            symlink_targets.add(target_identity)
            continue
        if stat.S_ISDIR(entry_metadata.st_mode):
            walk(path, ancestors | {identity})

try:
    walk(root, set())
    if not symlink_targets.issubset(visited):
        raise OSError("unaccounted project directory symlink")
    for repository in sorted(repositories):
        print(repository)
except OSError:
    raise SystemExit(1)
PY
}

# registered_child_project_worktrees: the canonical worktree path of every child
# REGISTERED in <retiring-home>'s own state whose recorded project resolves to
# <repository>, one per line. This is the only thing that may vouch for a linked
# worktree of a secondmate's project clone (see
# validate_secondmate_repository_worktree_graph). Attribution is deliberately
# narrow: a child must record BOTH a worktree and a project, the project must
# resolve to exactly this repository, and both paths are canonicalized before
# comparison, so an arbitrary or unattributable worktree can never be admitted.
# Fails closed - an unenumerable state directory is an error, never an empty set.
registered_child_project_worktrees() {  # <retiring-home> <repository>
  local home=$1 repository=$2 metas meta child_worktree child_project canonical
  metas=$(secondmate_state_metadata "$home") || return 1
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    child_worktree=$(meta_value "$meta" worktree)
    child_project=$(meta_value "$meta" project)
    [ -n "$child_worktree" ] && [ -n "$child_project" ] || continue
    child_project=$(fm_checkout_trusted_dir "$child_project" 2>/dev/null) || continue
    [ "$child_project" = "$repository" ] || continue
    canonical=$(fm_checkout_trusted_dir "$child_worktree" 2>/dev/null) || continue
    printf '%s\n' "$canonical"
  done <<EOF
$metas
EOF
}

validate_secondmate_repository_worktree_graph() {
  local repository=$1 retiring_home=$2 repository_container=${3:-$1}
  local common listed records path kind canonical count=0 bare_repository container_git submodule_admin=0
  local registered_worktrees
  bare_repository=$(git -C "$repository" rev-parse --is-bare-repository 2>/dev/null) || return 1
  common=$(git -C "$repository" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in /*) ;; *) common="$repository/$common" ;; esac
  common=$(fm_checkout_trusted_dir "$common") || return 1
  case "$common/" in
    "$retiring_home/"*) ;;
    *)
      echo "REFUSED: secondmate project repository is a linked worktree owned outside the retiring home at $repository" >&2
      return 1
      ;;
  esac
  if [ -f "$repository/.git" ] && [ ! -L "$repository/.git" ]; then
    container_git=$(git -C "$repository_container" rev-parse --absolute-git-dir 2>/dev/null) || return 1
    container_git=$(fm_checkout_trusted_dir "$container_git") || return 1
    case "$common/" in "$container_git/modules/"*) submodule_admin=1 ;; esac
  fi
  listed=$(git -C "$repository" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || {
    echo "REFUSED: secondmate project linked-worktree graph is uninspectable at $repository" >&2
    return 1
  }
  # A secondmate holds its project CLONES under home/projects while its crewmates'
  # worktrees live outside in the Treehouse pool as LINKED worktrees of those
  # clones - the ordinary running state of any secondmate with live crewmates. So
  # this graph admits a linked worktree that a REGISTERED child of this home owns,
  # and nothing else. It stays a pre-destruction guard: an unregistered, foreign,
  # or unattributable worktree still refuses retirement here, before anything is
  # removed.
  registered_worktrees=$(registered_child_project_worktrees "$retiring_home" "$repository") || {
    echo "REFUSED: secondmate child registration is unprovable while proving linked-worktree ownership at $repository" >&2
    return 1
  }
  records=$(printf '%s\n' "$listed" | awk '
    function emit() {
      if (path != "") {
        printf "%s\t%s\n", path, is_bare ? "bare" : "worktree"
      }
      path = ""
      is_bare = 0
    }
    /^worktree / {
      emit()
      path = substr($0, 10)
      next
    }
    /^bare$/ {
      is_bare = 1
      next
    }
    /^$/ {
      emit()
    }
    END {
      emit()
    }
  ') || return 1
  while IFS=$'\t' read -r path kind; do
    [ -n "$path" ] || continue
    canonical=$(fm_checkout_trusted_dir "$path") || {
      echo "REFUSED: secondmate project linked worktree is missing or redirected from $repository" >&2
      return 1
    }
    case "$kind" in
      bare)
        [ "$canonical" = "$common" ] || {
          echo "REFUSED: secondmate project bare worktree identity drifted at $canonical" >&2
          return 1
        }
        if [ "$bare_repository" = true ]; then
          [ "$canonical" = "$repository" ] || return 1
          count=$((count + 1))
        fi
        ;;
      worktree)
        if [ "$canonical" = "$repository" ]; then
          count=$((count + 1))
        elif [ "$submodule_admin" -eq 1 ] && [ "$canonical" = "$common" ]; then
          count=$((count + 1))
        elif [ -n "$registered_worktrees" ] \
          && printf '%s\n' "$registered_worktrees" | grep -qxF -- "$canonical"; then
          :
        else
          echo "REFUSED: secondmate project common Git directory owns another linked worktree at $canonical" >&2
          return 1
        fi
        ;;
      *) return 1 ;;
    esac
  done <<EOF
$records
EOF
  [ "$count" -eq 1 ] || {
    echo "REFUSED: secondmate project linked-worktree ownership is ambiguous at $repository" >&2
    return 1
  }
}

validate_secondmate_declared_submodules() {
  local repository=$1 container=${2:-$1} modules entries status key path submodule
  modules="$repository/.gitmodules"
  [ -e "$modules" ] || [ -L "$modules" ] || return 0
  [ -f "$modules" ] && [ ! -L "$modules" ] && [ -r "$modules" ] || return 1
  if entries=$(git -C "$repository" config --file .gitmodules \
      --get-regexp '^submodule\..*\.path$' 2>/dev/null); then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 0 ] && [ -n "$entries" ] || return 1
  while read -r key path; do
    [ -n "$key" ] && [ -n "$path" ] || return 1
    submodule=$(fm_checkout_lexical_path "$repository/$path") || return 1
    case "$submodule/" in
      "$repository/"*) ;;
      *) return 1 ;;
    esac
    [ "$(exact_git_repository_root "$submodule" "$container")" = "$submodule" ] || return 1
  done <<EOF
$entries
EOF
}

validate_secondmate_project_repository_landed_state() {
  local repository=$1 source_repository=$2 retiring_home=$3 repository_container=${4:-$1}
  local source_container=${5:-$2} dirty refs ref tip reflog_tips
  local remote_tips remote_tip landed repository_identity source_identity bare stash_status
  local authority_record authority_kind authority cleanup_status=0
  [ "$(exact_git_repository_root "$repository" "$repository_container")" = "$repository" ] || {
    echo "REFUSED: secondmate project repository is not an exact repository root at $repository" >&2
    return 1
  }
  [ "$(exact_git_repository_root "$source_repository" "$source_container")" = "$source_repository" ] || {
    echo "REFUSED: registered source project repository is not an exact repository root at $source_repository" >&2
    return 1
  }
  validate_surviving_repository_authority \
    "$source_repository" "$retiring_home" "$source_container" \
    "registered source project repository" || return 1
  git_history_rewrite_state_is_clean "$repository" "secondmate project repository" || return 1
  validate_secondmate_repository_worktree_graph \
    "$repository" "$retiring_home" "$repository_container" || return 1
  validate_secondmate_declared_submodules "$repository" "$repository_container" || {
    echo "REFUSED: secondmate project submodule state is uninspectable at $repository" >&2
    return 1
  }
  bare=$(git -C "$repository" rev-parse --is-bare-repository 2>/dev/null) || return 1
  if [ "$bare" != true ]; then
    dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "$repository" status --porcelain=v1 --untracked-files=all 2>/dev/null) || {
      echo "REFUSED: secondmate project clone cleanliness is uninspectable at $repository" >&2
      return 1
    }
    [ -z "$dirty" ] || {
      echo "REFUSED: secondmate project clone has unlanded changes at $repository" >&2
      return 1
    }
  fi
  if git -C "$repository" show-ref --verify --quiet refs/stash 2>/dev/null; then
    echo "REFUSED: secondmate project repository has retained stash history at $repository" >&2
    return 1
  else
    stash_status=$?
  fi
  [ "$stash_status" -eq 1 ] || {
    echo "REFUSED: secondmate project repository stash state is uninspectable at $repository" >&2
    return 1
  }
  repository_identity=$(secondmate_remote_identity "$repository" "$retiring_home") || {
    echo "REFUSED: secondmate project remote identity is unsafe or does not survive home removal at $repository" >&2
    return 1
  }
  source_identity=$(secondmate_remote_identity "$source_repository" "$retiring_home") || {
    echo "REFUSED: registered source project remote identity is unsafe or unreadable at $source_repository" >&2
    return 1
  }
  [ "$repository_identity" = "$source_identity" ] || {
    echo "REFUSED: secondmate project origin drifted from its registered source at $repository" >&2
    return 1
  }
  authority_record=$(prepare_secondmate_remote_authority "$repository" "$retiring_home") || {
    echo "REFUSED: secondmate project remote authority graph is incomplete or uninspectable at $repository" >&2
    return 1
  }
  IFS=$'\t' read -r authority_kind authority <<EOF
$authority_record
EOF
  remote_tips=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$authority" \
    for-each-ref --format='%(objectname)' refs/heads 2>/dev/null) || {
    cleanup_secondmate_remote_authority "$authority_kind" "$authority" || true
    return 1
  }
  [ -n "$remote_tips" ] || {
    cleanup_secondmate_remote_authority "$authority_kind" "$authority" || true
    echo "REFUSED: secondmate project repository has no live remote branches at $repository" >&2
    return 1
  }
  refs=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$repository" for-each-ref --format='%(refname)' 2>/dev/null) || {
    cleanup_secondmate_remote_authority "$authority_kind" "$authority" || true
    echo "REFUSED: secondmate project repository refs are uninspectable at $repository" >&2
    return 1
  }
  reflog_tips=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$repository" reflog --all --format='%H' 2>/dev/null) || {
    cleanup_secondmate_remote_authority "$authority_kind" "$authority" || true
    echo "REFUSED: secondmate project repository reflogs are uninspectable at $repository" >&2
    return 1
  }
  refs=$(printf 'HEAD\n%s\n%s\n' "$refs" "$reflog_tips")
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    [ "$ref" != refs/stash ] || continue
    tip=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$repository" rev-parse "$ref^{commit}" 2>/dev/null) || {
      cleanup_secondmate_remote_authority "$authority_kind" "$authority" || true
      echo "REFUSED: secondmate project repository ref $ref is uninspectable at $repository" >&2
      return 1
    }
    landed=0
    while IFS= read -r remote_tip; do
      [ -n "$remote_tip" ] || continue
      if GIT_NO_REPLACE_OBJECTS=1 git -C "$authority" cat-file -e "$tip^{commit}" 2>/dev/null \
          && GIT_NO_REPLACE_OBJECTS=1 git -C "$authority" \
            merge-base --is-ancestor "$tip" "$remote_tip" 2>/dev/null; then
        landed=1
        break
      fi
    done <<EOF
$remote_tips
EOF
    [ "$landed" -eq 1 ] || {
      cleanup_secondmate_remote_authority "$authority_kind" "$authority" || true
      echo "REFUSED: secondmate project repository ref $ref is not proven on a live remote branch at $repository" >&2
      return 1
    }
  done <<EOF
$refs
EOF
  cleanup_secondmate_remote_authority "$authority_kind" "$authority" || cleanup_status=$?
  [ "$cleanup_status" -eq 0 ] || {
    echo "REFUSED: remote authority proof cleanup could not be completed safely" >&2
    return 1
  }
}

validate_secondmate_project_clones() {
  local home=$1 registry=$2 expected_id=$3 expected_source=$4 projects_root source_projects_root
  local source_projects_candidate
  local expected listed project clone source_clone repositories relative repository source_repository
  if ! expected=$(fm_secondmate_registry_query "$registry" query "$expected_id" projects); then
    if [ "$registry" = "$PREPARED_REGISTRY_PATH" ] \
        && [ "$expected_id" = "$PREPARED_REGISTRY_ID" ] \
        && [ "$home" = "$PREPARED_REGISTRY_HOME" ] \
        && [ -n "$PREPARED_REGISTRY_BACKUP" ] \
        && fm_account_lifecycle_lock_owned "$PREPARED_REGISTRY_LOCK"; then
      expected=$(fm_secondmate_registry_query \
        "$PREPARED_REGISTRY_BACKUP" query "$expected_id" projects) || return 1
    else
      echo "REFUSED: secondmate project registration is unprovable for $expected_id" >&2
      return 1
    fi
  fi
  projects_root=$(fm_checkout_trusted_dir "$home/projects") || {
    echo "REFUSED: secondmate projects directory is missing, redirected, or unreadable at $home/projects" >&2
    return 1
  }
  listed=$(python3 - "$projects_root" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
try:
    with os.scandir(root) as entries:
        for entry in sorted(entries, key=lambda item: item.name):
            metadata = entry.stat(follow_symlinks=False)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise OSError("unsafe project entry")
            print(entry.name)
except OSError:
    raise SystemExit(1)
PY
  ) || {
    echo "REFUSED: secondmate project clones cannot be safely enumerated at $projects_root" >&2
    return 1
  }
  if [ -n "$expected" ]; then
    expected=$(printf '%s\n' "$expected" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort) || return 1
  fi
  listed=$(printf '%s\n' "$listed" | sed '/^$/d' | sort) || return 1
  [ "$listed" = "$expected" ] || {
    echo "REFUSED: secondmate project clones do not exactly match the registration for $expected_id" >&2
    return 1
  }
  # When the source IS this firstmate's own repo, its projects live wherever THIS
  # home puts them, exactly as the registry lookup above resolves through $DATA
  # rather than "$expected_source/data". Requiring FM_PROJECTS_OVERRIDE to be set
  # here meant that with FM_HOME pointing at a home outside the repo - the
  # documented multi-home layout - teardown looked for the parent's clones in the
  # repo root, found nothing, and refused to retire any secondmate.
  # A source that is NOT this repo is a foreign home, so it keeps its own layout.
  if [ "$expected_source" = "$FM_ROOT" ]; then
    source_projects_candidate=$PROJECTS
  else
    source_projects_candidate="$expected_source/projects"
  fi
  source_projects_root=$(fm_checkout_trusted_dir "$source_projects_candidate") || {
    echo "REFUSED: registered source projects are unavailable or redirected at $source_projects_candidate" >&2
    return 1
  }
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    clone=$(fm_checkout_trusted_dir "$projects_root/$project") || return 1
    source_clone=$(fm_checkout_trusted_dir "$source_projects_root/$project") || {
      echo "REFUSED: registered source project is unavailable or redirected for $project" >&2
      return 1
    }
    validate_removal_tree_boundaries "$clone" "secondmate project clone" || return 1
    repositories=$(enumerate_secondmate_project_repositories "$clone") || {
      echo "REFUSED: nested project repositories cannot be safely enumerated at $clone" >&2
      return 1
    }
    while IFS= read -r relative; do
      [ -n "$relative" ] || continue
      if [ "$relative" = . ]; then
        repository=$clone
        source_repository=$source_clone
      else
        repository=$(fm_checkout_trusted_dir "$clone/$relative") || return 1
        source_repository=$(fm_checkout_trusted_dir "$source_clone/$relative") || {
          echo "REFUSED: nested project repository has no registered source counterpart at $clone/$relative" >&2
          return 1
        }
      fi
      validate_secondmate_project_repository_landed_state \
        "$repository" "$source_repository" "$home" "$clone" "$source_clone" || return 1
    done <<EOF
$repositories
EOF
  done <<EOF
$listed
EOF
}

validate_firstmate_home_for_removal() {
  local home=$1 label=$2 expected_id=${3:-} expected_source=${4:-$FM_ROOT} expected_registry=${5:-} expected_project
  local abs_home_path metadata_home_root marker_id source_authority=${7:-1}
  expected_project=${6:-$home}
  [ -n "$home" ] && [ -e "$home" ] || {
    echo "REFUSED: missing $label removal target ${home:-<empty>}" >&2
    return 1
  }
  abs_home_path=$(validate_removal_target "$home" "$label") || return 1
  if [ ! -f "$abs_home_path/$SUB_HOME_MARKER" ]; then
    echo "REFUSED: unsafe $label removal target $home is not a seeded secondmate home" >&2
    return 1
  fi
  if [ -n "$expected_id" ]; then
    marker_id=$(cat "$abs_home_path/$SUB_HOME_MARKER" 2>/dev/null || true)
    if [ "$marker_id" != "$expected_id" ]; then
      echo "REFUSED: unsafe $label removal target $home is marked for secondmate ${marker_id:-unknown}, expected $expected_id" >&2
      return 1
    fi
    [ -n "$expected_registry" ] || expected_registry=$(secondmate_registry_for_source "$expected_source") || return 1
    require_registered_secondmate_home "$expected_registry" "$expected_id" "$abs_home_path" || return 1
  fi
  metadata_home_root=$(exact_git_worktree_root "$expected_project") || {
    echo "REFUSED: secondmate project metadata is not an exact repository root: ${expected_project:-<missing>}" >&2
    return 1
  }
  [ "$metadata_home_root" = "$abs_home_path" ] || {
    echo "REFUSED: secondmate project metadata resolves to $metadata_home_root, not registered home $abs_home_path" >&2
    return 1
  }
  validate_firstmate_home_repository_identity "$abs_home_path" "$expected_source" || return 1
  # The operational-directory proof is the most specific statement available about a
  # structurally broken home, and it is read-only, so it speaks before the proofs
  # below - all of which also read the home's state directory and would otherwise
  # answer first with a vaguer reason for the same underlying fault.
  validate_firstmate_operational_dirs_for_removal "$abs_home_path" "$label" || return 1
  if [ "$source_authority" -eq 1 ]; then
    validate_surviving_repository_authority \
      "$expected_source" "$abs_home_path" "$expected_source" \
      "secondmate top-level source repository" "$abs_home_path" || return 1
  fi
  if [ -n "$expected_id" ] && firstmate_home_has_treehouse_slot "$abs_home_path" "$expected_source"; then
    require_treehouse_task_lease "$abs_home_path" "$expected_id" || return 1
  fi
  # Structural proofs run BEFORE the landed-state (cleanliness) proof. Every proof
  # here is read-only and every one of them already runs before any destruction, so
  # this only decides which refusal an operator is shown first - not whether any
  # check happens. It matters because a structural violation manifests as untracked
  # content: an operational directory symlinked out of the home, or a nested home
  # inside it, both surface to `git status` as untracked paths, so the cleanliness
  # proof used to answer first and report "has unlanded changes: ?? state" for a
  # problem that has nothing to do with unlanded work. The more specific proof now
  # speaks first. Each still returns non-zero on its own failure, so a home with
  # both a structural violation and genuinely unlanded work is still refused.
  if [ -n "$expected_id" ]; then
    validate_secondmate_project_clones \
      "$abs_home_path" "$expected_registry" "$expected_id" "$expected_source" || return 1
  fi
  validate_secondmate_home_landed_state "$abs_home_path" "$expected_source" || return 1
  secondmate_state_metadata "$abs_home_path" >/dev/null || return 1
  fm_secondmate_registry_query "$abs_home_path/data/secondmates.md" validate >/dev/null || {
    echo "REFUSED: child secondmate registry is malformed or uninspectable at $abs_home_path/data/secondmates.md" >&2
    return 1
  }
  printf '%s\n' "$abs_home_path"
}

remove_explicit_firstmate_home_locked() {
  local home=$1 label=$2 expected_id=$3 expected_source=$4 expected_registry=${5:-} expected_project validated
  expected_project=${6:-$home}
  validated=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id" "$expected_source" "$expected_registry" "$expected_project") || return 1
  [ "$validated" = "$home" ] || return 1
  require_empty_secondmate_state "$home" || return 1
  firstmate_home_has_treehouse_slot "$home" "$expected_source" && {
    echo "error: $label became a Treehouse worktree before explicit removal" >&2
    return 1
  }
  safe_rm_rf "$home" "$label"
}

validate_treehouse_firstmate_home_locked() {
  validate_firstmate_home_for_removal "$1" "secondmate home" "$3" "$2" >/dev/null \
    && require_empty_secondmate_state "$1"
}

remove_firstmate_home() {
  local home=$1 label=$2 expected_id=${3:-} expected_source=${4:-$FM_ROOT} expected_registry=${5:-} expected_project abs_home_path
  expected_project=${6:-$home}
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id" "$expected_source" "$expected_registry" "$expected_project") || return 1
  [ -n "$abs_home_path" ] || return 0
  if firstmate_home_has_treehouse_slot "$abs_home_path" "$expected_source"; then
    command -v treehouse >/dev/null 2>&1 || {
      echo "error: treehouse command not found; cannot return $label $abs_home_path" >&2
      return 1
    }
    teardown_treehouse_return "$abs_home_path" "$expected_source" "$label" "$expected_id" \
      validate_treehouse_firstmate_home_locked || {
      echo "error: treehouse return failed for $label $abs_home_path; lease may still be held" >&2
      return 1
    }
    return 0
  fi
  fm_checkout_lock_run "$abs_home_path" "$CHECKOUT_LOCK_ROOT" \
    remove_explicit_firstmate_home_locked "$abs_home_path" "$label" "$expected_id" "$expected_source" "$expected_registry" "$expected_project"
}

validate_registered_secondmate_children() {
  local home=$1 entries child_id child_home _child_projects child_meta meta_kind meta_home
  entries=$(fm_secondmate_registry_query "$home/data/secondmates.md" list) || {
    echo "REFUSED: registered secondmate children are unprovable at $home/data/secondmates.md" >&2
    return 1
  }
  while IFS=$'\t' read -r child_id child_home _child_projects; do
    [ -n "$child_id" ] || continue
    child_meta="$home/state/$child_id.meta"
    [ -f "$child_meta" ] && [ ! -L "$child_meta" ] && [ -r "$child_meta" ] || {
      echo "REFUSED: registered secondmate $child_id has no inspectable child metadata; preserving $child_home" >&2
      return 1
    }
    meta_kind=$(meta_value "$child_meta" kind)
    [ "$meta_kind" = secondmate ] || {
      echo "REFUSED: registered secondmate $child_id has mismatched child metadata" >&2
      return 1
    }
    meta_home=$(meta_value "$child_meta" home)
    [ -n "$meta_home" ] || meta_home=$(meta_value "$child_meta" worktree)
    meta_home=$(canonical_existing_dir "$meta_home") || return 1
    child_home=$(canonical_existing_dir "$child_home") || return 1
    [ "$meta_home" = "$child_home" ] || {
      echo "REFUSED: registered secondmate $child_id home does not match child metadata" >&2
      return 1
    }
  done <<EOF
$entries
EOF
}

require_empty_secondmate_registry() {
  local home=$1 entries
  entries=$(fm_secondmate_registry_query "$home/data/secondmates.md" list) || {
    echo "REFUSED: child secondmate registry is unprovable at $home/data/secondmates.md" >&2
    return 1
  }
  [ -z "$entries" ] || {
    echo "REFUSED: secondmate home still registers child homes; preserving $home" >&2
    return 1
  }
}

validate_firstmate_home_children_removal() {
  local home=$1 sub_state child_metas child_meta child_id child_wt child_proj child_kind child_home child_backend child_orca_worktree_id
  sub_state="$home/state"
  child_metas=$(secondmate_state_metadata "$home") || return 1
  validate_registered_secondmate_children "$home" || return 1
  while IFS= read -r child_meta; do
    [ -n "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_wt=$(meta_value "$child_meta" worktree)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_home=
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
    fi
    child_backend=$(fm_backend_of_meta "$child_meta")
    if [ "$child_kind" = secondmate ]; then
      child_proj=$(meta_value "$child_meta" project)
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      validate_firstmate_home_for_removal "$child_home" "child firstmate home" "$child_id" "$home" "$home/data/secondmates.md" "$child_proj" >/dev/null || return 1
      validate_firstmate_home_children_removal "$child_home" || return 1
    elif [ "$child_backend" = orca ]; then
      require_orca_task_metadata_identity "$child_meta" "$child_id" || return 1
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        child_proj=$(meta_value "$child_meta" project)
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        require_orca_worktree_path_match "$child_orca_worktree_id" "$child_wt" || return 1
        validate_child_worktree_landed_state "$child_meta" "$child_id" "$child_wt" "$child_proj" || return 1
      fi
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      child_proj=$(meta_value "$child_meta" project)
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      require_treehouse_task_lease "$(canonical_existing_dir "$child_wt")" "firstmate-$child_id" || return 1
      validate_child_worktree_landed_state "$child_meta" "$child_id" "$child_wt" "$child_proj" || return 1
    else
      echo "error: retained child metadata for $child_id because its Treehouse worktree is missing or uninspectable" >&2
      return 1
    fi
  done <<EOF
$child_metas
EOF
}

remove_child_orca_worktree_locked() {
  local child_worktree=$1 child_project=$2 child_worktree_id=$3 child_id=$4 child_meta=$5 branch=HEAD boundary_token
  validate_child_worktree_for_removal "$child_worktree" "$child_project" >/dev/null || return 1
  require_orca_worktree_path_match "$child_worktree_id" "$child_worktree" || return 1
  fm_backend_quiesce_worktree_terminals orca "$child_worktree_id" "fm-$child_id" "$(meta_value "$child_meta" terminal)" || return 1
  validate_child_worktree_landed_state "$child_meta" "$child_id" "$child_worktree" "$child_project" || return 1
  validate_removal_tree_boundaries "$child_worktree" "child Orca worktree" || return 1
  require_orca_worktree_path_match "$child_worktree_id" "$child_worktree" || return 1
  branch=$(git -C "$child_worktree" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
  boundary_token=$(removal_tree_boundary_token "$child_worktree" "child Orca worktree") || return 1
  fm_backend_remove_worktree_bound \
    orca "$child_worktree_id" "$child_worktree" "$boundary_token" || return 1
  if [ "$branch" != "HEAD" ]; then
    git -C "$child_project" branch -D "$branch" >/dev/null 2>&1 || true
  fi
  remove_worktree_compatibility_artifacts "$child_worktree" "removed child Orca worktree"
}

cleanup_firstmate_home_children() {
  local home=$1 sub_state child_metas child_meta child_id child_wt child_proj child_kind child_prelock_kind child_home child_home_after child_home_lock child_registry_lock child_backend child_orca_worktree_id child_return_rc child_account_lock child_endpoint_home remaining_child_metas child_registry_prepared child_registry_update child_registry_backup
  sub_state="$home/state"
  child_metas=$(secondmate_state_metadata "$home") || return 1
  while IFS= read -r child_meta; do
    [ -n "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    [ -f "$child_meta" ] && [ ! -L "$child_meta" ] && [ -r "$child_meta" ] \
      || { echo "error: child metadata is unsafe for $child_id" >&2; return 1; }
    child_wt=$(meta_value "$child_meta" worktree)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_prelock_kind=$child_kind
    child_home=
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      [ -d "$child_home" ] || {
        echo "error: retained child secondmate metadata for $child_id because its home is missing or uninspectable" >&2
        return 1
      }
      child_home_lock=$(fm_secondmate_home_lifecycle_lock_acquire "$CHECKOUT_LOCK_ROOT" "$child_home") || return 1
      TEARDOWN_ACCOUNT_LOCKS+=("$child_home_lock")
    fi
    child_account_lock=$(fm_account_lifecycle_lock_acquire "$sub_state" "$child_id") || return 1
    TEARDOWN_ACCOUNT_LOCKS+=("$child_account_lock")
    [ -f "$child_meta" ] && [ ! -L "$child_meta" ] && [ -r "$child_meta" ] \
      || { echo "error: child metadata changed while teardown waited for $child_id" >&2; return 1; }
    if managed_account_meta "$child_meta"; then
      if [ ! -f "$child_meta" ] || ! managed_account_meta "$child_meta"; then
        echo "error: managed child metadata changed while teardown waited for $child_id" >&2
        return 1
      fi
    fi
    child_proj=$(meta_value "$child_meta" project)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    [ "$child_kind" = "$child_prelock_kind" ] \
      || { echo "error: child kind changed while teardown waited for $child_id" >&2; return 1; }
    if [ "$child_kind" = secondmate ]; then
      child_home_after=$(meta_value "$child_meta" home)
      [ -n "$child_home_after" ] || child_home_after=$(meta_value "$child_meta" worktree)
      [ "$child_home_after" = "$child_home" ] \
        || { echo "error: child secondmate home changed while teardown waited for $child_id" >&2; return 1; }
      [ -f "$child_meta" ] && [ ! -L "$child_meta" ] && [ -r "$child_meta" ] || {
        echo "error: child metadata changed while teardown waited for secondmate home $child_id" >&2
        return 1
      }
    fi
    child_backend=$(fm_backend_of_meta "$child_meta")
    if [ "$child_backend" = orca ] && [ "$child_kind" != secondmate ]; then
      require_orca_task_metadata_identity "$child_meta" "$child_id" || return 1
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      fi
    fi
    if [ "$child_kind" != secondmate ] && [ "$child_backend" != orca ]; then
      if [ -z "$child_wt" ] || [ ! -d "$child_wt" ]; then
        echo "error: retained child metadata for $child_id because its Treehouse worktree is missing or uninspectable" >&2
        return 1
      fi
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      require_treehouse_task_lease "$(canonical_existing_dir "$child_wt")" "firstmate-$child_id" || return 1
    fi
    if managed_account_meta "$child_meta"; then
      child_endpoint_home=$(fm_backend_endpoint_home "$child_backend" "$child_kind" "$home" "$child_home")
      release_managed_account "$child_meta" "$child_id" "$child_endpoint_home" "$child_account_lock" "$home/data" || return 1
      child_account_lock=$MANAGED_ACCOUNT_LOCK
    else
      quiesce_child_endpoint "$child_meta" "$child_id" "$home" "$child_home" || return 1
    fi
    if [ "$child_kind" = secondmate ]; then
      if [ -n "$child_home" ] && [ -d "$child_home" ]; then
        # Preserve the nested cleanup's own status: the retry-able checkout
        # conditions below (75 contention, 76 unverified process cleanup, 124
        # timeout, 127 Treehouse unavailable, or the return command's own status)
        # are how an operator tells "retry this" from a safety refusal, and
        # flattening them all to 1 would erase that distinction at every level.
        cleanup_firstmate_home_children "$child_home" || return $?
        child_registry_lock=$(fm_secondmate_registry_lock_acquire "$CHECKOUT_LOCK_ROOT" "$home/data/secondmates.md") || return 1
        TEARDOWN_ACCOUNT_LOCKS+=("$child_registry_lock")
        validate_firstmate_home_for_removal "$child_home" "child firstmate home" "$child_id" "$home" "$home/data/secondmates.md" "$child_proj" >/dev/null || return 1
        remaining_child_metas=$(secondmate_state_metadata "$child_home") || return 1
        [ -z "$remaining_child_metas" ] || return 1
        child_registry_prepared=$(prepare_secondmate_registry_removal "$child_id" "$child_home" "$home/data/secondmates.md" "$child_registry_lock") || return 1
        IFS=$'\t' read -r child_registry_update child_registry_backup <<EOF
$child_registry_prepared
EOF
        PREPARED_REGISTRY_PATH="$home/data/secondmates.md"
        PREPARED_REGISTRY_BACKUP=$child_registry_backup
        PREPARED_REGISTRY_ID=$child_id
        PREPARED_REGISTRY_HOME=$child_home
        PREPARED_REGISTRY_LOCK=$child_registry_lock
        activate_secondmate_registry_removal "$home/data/secondmates.md" "$child_registry_lock" "$child_registry_update" || {
          rm -f "$child_registry_update" "$child_registry_backup"
          return 1
        }
        remove_firstmate_home "$child_home" "child firstmate home" "$child_id" "$home" "$home/data/secondmates.md" "$child_proj" || {
          rollback_secondmate_registry_removal "$home/data/secondmates.md" "$child_registry_lock" "$child_registry_backup"
          PREPARED_REGISTRY_PATH=
          PREPARED_REGISTRY_BACKUP=
          PREPARED_REGISTRY_ID=
          PREPARED_REGISTRY_HOME=
          PREPARED_REGISTRY_LOCK=
          return 1
        }
        rm -f "$child_registry_backup"
        PREPARED_REGISTRY_PATH=
        PREPARED_REGISTRY_BACKUP=
        PREPARED_REGISTRY_ID=
        PREPARED_REGISTRY_HOME=
        PREPARED_REGISTRY_LOCK=
        fm_account_lifecycle_lock_release "$child_registry_lock" || return 1
        child_registry_lock=
      fi
    elif [ "$child_backend" = orca ]; then
      if [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        fm_checkout_lock_run "$child_wt" "$CHECKOUT_LOCK_ROOT" \
          remove_child_orca_worktree_locked "$child_wt" "$child_proj" "$child_orca_worktree_id" "$child_id" "$child_meta" || return 1
      else
        echo "error: child Orca worktree identity for $child_id is unavailable; refusing provider removal" >&2
        return 1
      fi
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      if [ -n "$child_proj" ] && [ -d "$child_proj" ]; then
        if ! command -v treehouse >/dev/null 2>&1; then
          echo "error: retained child worktree $child_wt because Treehouse is unavailable; install or restore treehouse, then retry teardown" >&2
          return "$FM_CHECKOUT_TREEHOUSE_RETURN_UNAVAILABLE_STATUS"
        fi
        CHILD_RETURN_META=$child_meta
        CHILD_RETURN_ID=$child_id
        if teardown_treehouse_return "$child_wt" "$child_proj" "child worktree" \
            "firstmate-$child_id" validate_child_worktree_return_safety cleanup_returned_worktree; then
          :
        else
          child_return_rc=$?
          case "$child_return_rc" in
            "$FM_CHECKOUT_LOCK_CONTENTION_STATUS")
              echo "error: retained child worktree $child_wt because its common checkout mutation lock is busy" >&2
              ;;
            "$FM_CHECKOUT_TREEHOUSE_RETURN_TIMEOUT_STATUS")
              echo "error: retained child worktree $child_wt because its Treehouse return timed out" >&2
              ;;
            *)
              echo "error: retained child worktree $child_wt because its locked Treehouse return failed (status $child_return_rc); resolve the Treehouse failure, then retry teardown" >&2
              ;;
          esac
          return "$child_return_rc"
        fi
        CHILD_RETURN_META=
        CHILD_RETURN_ID=
      else
        validate_child_worktree_landed_state "$child_meta" "$child_id" "$child_wt" "$child_proj" || return 1
        safe_rm_rf_child_worktree "$child_wt" "$child_proj"
      fi
    fi
    remove_grok_turnend_auth "$sub_state" "$child_id"
    rm -f "$sub_state/$child_id.status" "$sub_state/$child_id.turn-ended" "$sub_state/$child_id.check.sh" "$sub_state/$child_id.meta" "$sub_state/$child_id.pi-ext.ts" "$sub_state/$child_id.grok-turnend-token"
    [ -z "$child_account_lock" ] || fm_account_lifecycle_lock_release "$child_account_lock" >/dev/null 2>&1 || true
  done <<EOF
$child_metas
EOF
}

prepare_secondmate_registry_removal() {
  local id=$1 home=$2 reg=$3 registry_lock=$4 tmp backup reg_dir
  fm_account_lifecycle_lock_owned "$registry_lock" || return 1
  require_registered_secondmate_home "$reg" "$id" "$home" || return 1
  fm_account_safe_file_destination "$reg" || return 1
  reg_dir=$(dirname "$reg")
  tmp=$(mktemp "$reg_dir/.secondmates.XXXXXX") || return 1
  backup=$(mktemp "$reg_dir/.secondmates-backup.XXXXXX") || {
    rm -f "$tmp"
    return 1
  }
  if ! fm_account_system_perl - "$reg" "$tmp" "$backup" "$id" <<'PERL'
    my ($source, $destination, $backup, $expected) = @ARGV;
    open my $input, q{<}, $source or exit 1;
    open my $output, q{>}, $destination or exit 1;
    open my $saved, q{>}, $backup or exit 1;
    my $removed = 0;
    while (my $line = <$input>) {
      print {$saved} $line or exit 1;
      if ($line =~ /^- ([A-Za-z0-9][A-Za-z0-9._-]*) / && $1 eq $expected) {
        ++$removed;
        next;
      }
      print {$output} $line or exit 1;
    }
    close $output or exit 1;
    close $saved or exit 1;
    exit 1 if $removed != 1;
PERL
  then
    rm -f "$tmp" "$backup"
    return 1
  fi
  printf '%s\t%s\n' "$tmp" "$backup"
}

activate_secondmate_registry_removal() {
  local reg=$1 registry_lock=$2 tmp=$3
  fm_account_lifecycle_lock_owned "$registry_lock" || return 1
  [ -f "$tmp" ] && [ ! -L "$tmp" ] || return 1
  fm_account_safe_file_destination "$reg" || return 1
  mv "$tmp" "$reg"
}

rollback_secondmate_registry_removal() {
  local reg=$1 registry_lock=$2 backup=$3
  fm_account_lifecycle_lock_owned "$registry_lock" || return 1
  [ -f "$backup" ] && [ ! -L "$backup" ] || return 1
  fm_account_safe_file_destination "$reg" || return 1
  mv "$backup" "$reg"
}

validate_pending_orca_worktree_identity() {
  local project_root worktree_root project_common worktree_common recorded_root
  require_safe_task_metadata || return 1
  require_orca_task_metadata_identity "$META" "$ID" || return 1
  project_root=$(exact_git_worktree_root "$PROJ") || {
    echo "error: quarantined Orca project is not an exact repository root: ${PROJ:-<missing>}" >&2
    return 1
  }
  worktree_root=$(exact_git_worktree_root "$WT") || {
    echo "error: quarantined Orca worktree is not an exact repository root: ${WT:-<missing>}" >&2
    return 1
  }
  project_common=$(fm_checkout_git_common_dir "$project_root") || return 1
  worktree_common=$(fm_checkout_git_common_dir "$worktree_root") || return 1
  [ "$project_common" = "$worktree_common" ] || {
    echo "error: quarantined Orca worktree does not belong to the recorded project" >&2
    return 1
  }
  if [ -n "$(meta_value "$META" worktree)" ] && [ -e "$(meta_value "$META" worktree)" ]; then
    recorded_root=$(exact_git_worktree_root "$(meta_value "$META" worktree)") || return 1
    [ "$recorded_root" = "$worktree_root" ] || {
      echo "error: quarantined Orca worktree path drifted from retained metadata" >&2
      return 1
    }
  fi
  require_orca_worktree_path_match "$ORCA_WORKTREE_ID" "$worktree_root"
}

pending_orca_endpoint_absent() {
  local state
  if [ -n "$T" ]; then
    state=$(fm_backend_target_state orca "$T" "fm-$ID" "$ORCA_WORKTREE_ID")
    case "$state" in
      absent) ;;
      present) ;;
      *)
        echo "error: quarantined Orca terminal identity or state is unproven for $ID" >&2
        return 1
        ;;
    esac
  fi
  fm_backend_quiesce_worktree_terminals orca "$ORCA_WORKTREE_ID" "fm-$ID" "$T"
}

remove_pending_orca_worktree_locked() {
  local boundary_token
  validate_pending_orca_worktree_identity || return 1
  pending_orca_endpoint_absent || return 1
  validate_worktree_teardown_safety || return 1
  validate_pending_orca_worktree_identity || return 1
  validate_removal_tree_boundaries "$WT" "quarantined Orca worktree" || return 1
  validate_pending_orca_worktree_identity || return 1
  boundary_token=$(removal_tree_boundary_token "$WT" "quarantined Orca worktree") || return 1
  fm_backend_remove_worktree_bound \
    orca "$ORCA_WORKTREE_ID" "$WT" "$boundary_token"
}

if [ "$ORCA_CLEANUP_PENDING" = 1 ]; then
  [ "$KIND" != secondmate ] || {
    echo "error: Orca cleanup quarantine cannot describe a secondmate" >&2
    exit 1
  }
  if [ -z "$ORCA_WORKTREE_ID" ]; then
    echo "error: quarantined Orca worktree id remains unavailable for $ID; refusing to close an unscoped terminal and retaining metadata for provider-assisted recovery by recorded project and task label" >&2
    exit 1
  fi
  WT=$(fm_backend_worktree_path orca "$ORCA_WORKTREE_ID") || {
    echo "error: quarantined Orca worktree path remains unprovable for $ID" >&2
    exit 1
  }
  validate_pending_orca_worktree_identity || exit 1
  pending_orca_endpoint_absent || exit 1
  fm_checkout_lock_run "$WT" "$CHECKOUT_LOCK_ROOT" remove_pending_orca_worktree_locked || exit 1
  remove_grok_turnend_auth "$STATE" "$ID"
  fm_backend_clear_transition "$BACKEND" "$STATE" "$T" || true
  safe_remove_task_tmp "$TASK_TMP" || exit 1
  rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.check.sh" "$STATE/$ID.meta" "$STATE/$ID.pi-ext.ts" "$STATE/$ID.grok-turnend-token"
  [ -z "$ACCOUNT_DELETE_LOCK" ] || fm_account_lifecycle_lock_release "$ACCOUNT_DELETE_LOCK" >/dev/null 2>&1 || true
  ACCOUNT_DELETE_LOCK=
  echo "teardown $ID complete (Orca cleanup quarantine cleared)"
  exit 0
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  [ "$PRELOCK_KIND" = secondmate ] && [ "$PRELOCK_HOME" = "$HOME_PATH" ] || {
    echo "error: secondmate home identity changed while teardown waited for lifecycle ownership" >&2
    exit 1
  }
  validate_firstmate_home_for_removal \
    "$HOME_PATH" "secondmate home" "$ID" "$FM_ROOT" "$SECONDMATE_REG" "$PROJ" 0 \
    >/dev/null || exit 1
  if [ "$FORCE" = "--force" ]; then
    validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
  else
    # Prove the home registers no child homes BEFORE stopping its endpoint. Stopping
    # a supervisor is irreversible - it cannot be un-stopped and its in-flight context
    # is gone - so a read-only proof that gates it must run first, or an operator loses
    # a live secondmate to a teardown that was always going to refuse. The same proof
    # still runs at its original place below, so nothing is skipped.
    # Non-force only, deliberately: on the --force path cleanup_firstmate_home_children
    # removes child registry entries before the later check, so that check legitimately
    # observes post-cleanup state and hoisting it there would change what it observes,
    # not merely when it runs.
    require_empty_secondmate_registry "$HOME_PATH" || exit 1
  fi
  quiesce_secondmate_endpoint || exit 1
  if [ "$FORCE" = "--force" ]; then
    validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
  else
    SUB_STATE="$HOME_PATH/state"
    CHILD_METAS=$(secondmate_state_metadata "$HOME_PATH") || exit 1
    if [ -n "$CHILD_METAS" ]; then
      child_meta=${CHILD_METAS%%$'\n'*}
      echo "REFUSED: secondmate $ID still has in-flight work in $SUB_STATE." >&2
      echo "Found $(basename "$child_meta"). Let that home finish, or use --force to retire only after every child is proven landed and quiescent." >&2
      exit 1
    fi
  fi
fi

if [ "$KIND" = scout ] && [ "$SPAWN_NEVER_LAUNCHED" != 1 ]; then
  REPORT="$DATA/$ID/report.md"
  if [ ! -f "$REPORT" ]; then
    echo "REFUSED: scout task $ID has no report at $REPORT." >&2
    echo "The report is the work product. Have the crewmate write it, then retry teardown." >&2
    exit 1
  fi
fi

[ "$KIND" = secondmate ] || validate_teardown_target_identity || exit 1

PROBE_HOME=
ENDPOINT_HOME=$(fm_backend_endpoint_home "$BACKEND" "$KIND" "$FM_HOME" "$HOME_PATH")
[ "$ENDPOINT_HOME" = "$FM_HOME" ] || PROBE_HOME=$ENDPOINT_HOME

quiesce_task_endpoint() {
  local endpoint_status zellij_tab scoped_target
  if [ "$MANAGED_ACCOUNT" = 1 ]; then
    quiesce_managed_account_endpoint "$META" "$ID" "$PROBE_HOME"
    return $?
  fi
  zellij_tab=$(meta_value "$META" zellij_tab_id)
  scoped_target=$(meta_value "$META" tmux_session_target)
  [ "$BACKEND" != orca ] || scoped_target=$ORCA_WORKTREE_ID
  if [ "$BACKEND" = orca ]; then
    quiesce_authoritative_orca_endpoint "$T" "$ORCA_WORKTREE_ID" "fm-$ID" || {
      echo "error: task Orca endpoint authority or quiescence is unproven for $ID; retaining metadata" >&2
      return 1
    }
    return 0
  fi
  if managed_endpoint_is_gone "$BACKEND" "$T" "fm-$ID" "$PROBE_HOME" "$scoped_target"; then
    return 0
  else
    endpoint_status=$?
  fi
  if [ "$endpoint_status" -eq 2 ]; then
    echo "error: task endpoint identity or state for $ID is unknown; retaining metadata" >&2
    return 1
  fi
  if [ -n "$T" ]; then
    if [ -n "$PROBE_HOME" ]; then
      ( unset FM_ROOT_OVERRIDE; FM_HOME="$PROBE_HOME" FM_ROOT="$PROBE_HOME" fm_backend_kill "$BACKEND" "$T" "$zellij_tab" "fm-$ID" "$(meta_value "$META" tmux_session_target)" ) 2>/dev/null || {
        echo "error: failed to stop task endpoint for $ID; retaining metadata" >&2
        return 1
      }
    else
      fm_backend_kill "$BACKEND" "$T" "$zellij_tab" "fm-$ID" "$(meta_value "$META" tmux_session_target)" 2>/dev/null || {
        echo "error: failed to stop task endpoint for $ID; retaining metadata" >&2
        return 1
      }
    fi
  fi
  if managed_endpoint_is_gone "$BACKEND" "$T" "fm-$ID" "$PROBE_HOME" "$scoped_target"; then
    return 0
  else
    endpoint_status=$?
  fi
  if [ "$endpoint_status" -eq 2 ]; then
    echo "error: task endpoint state for $ID is unknown; retaining metadata" >&2
  else
    echo "error: task endpoint for $ID is still alive; retaining metadata" >&2
  fi
  return 1
}

quiesce_retained_direct_spawn_endpoint() {
  local endpoint_status zellij_tab
  zellij_tab=$(meta_value "$META" zellij_tab_id)
  if [ -n "$T" ]; then
    if [ -n "$PROBE_HOME" ]; then
      ( unset FM_ROOT_OVERRIDE; FM_HOME="$PROBE_HOME" FM_ROOT="$PROBE_HOME" fm_backend_kill "$BACKEND" "$T" "$zellij_tab" "fm-$ID" "$(meta_value "$META" tmux_session_target)" ) 2>/dev/null || true
    else
      fm_backend_kill "$BACKEND" "$T" "$zellij_tab" "fm-$ID" "$(meta_value "$META" tmux_session_target)" 2>/dev/null || true
    fi
  fi
  if managed_endpoint_is_gone "$BACKEND" "$T" "fm-$ID" "$PROBE_HOME" "$(meta_value "$META" tmux_session_target)"; then
    return 0
  else
    endpoint_status=$?
  fi
  if [ "$endpoint_status" -eq 2 ]; then
    echo "error: retained direct-spawn endpoint state for $ID is unknown; retaining its worktree and metadata" >&2
  else
    echo "error: retained direct-spawn endpoint for $ID is still alive; retaining its worktree and metadata" >&2
  fi
  return 1
}

post_quiescence_safety_refusal() {
  [ "$KIND" != secondmate ] || return 0
  echo "The task endpoint has already been shut down; the worktree and task metadata are preserved for a safe retry." >&2
}

if [ "$DIRECT_SPAWN_CLEANUP" = pending ]; then
  if [ "$DIRECT_SPAWN_ENDPOINT" != not-created ]; then
    quiesce_retained_direct_spawn_endpoint || exit 1
  fi
  validate_teardown_target_identity || { post_quiescence_safety_refusal; exit 1; }
elif [ "$KIND" != secondmate ]; then
  quiesce_task_endpoint || exit 1
  validate_teardown_target_identity || { post_quiescence_safety_refusal; exit 1; }
fi

if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
  if ! inspectable_git_worktree "$WT"; then
    echo "REFUSED: Orca task $ID has no inspectable git worktree at ${WT:-<missing>}." >&2
    echo "Cannot verify dirty or unlanded work; restore the worktree path, then retry teardown." >&2
    post_quiescence_safety_refusal
    exit 1
  fi
  require_orca_worktree_path_match "$ORCA_WORKTREE_ID" "$WT" || { post_quiescence_safety_refusal; exit 1; }
  ORCA_PATH_MATCH_VERIFIED=1
fi

if [ "$PRESERVE_SCRATCH" -eq 1 ] && [ -d "$WT" ]; then
  [ "$TREEHOUSE_TARGET_ALREADY_RETURNED" -eq 0 ] || {
    echo "REFUSED: --preserve-scratch cannot mutate an already-returned Treehouse worktree." >&2
    post_quiescence_safety_refusal
    exit 1
  }
  prepare_preserved_worktree_scratch || {
    post_quiescence_safety_refusal
    exit 1
  }
fi

if [ -d "$WT" ]; then
  if validate_worktree_teardown_safety; then
    :
  else
    safety_rc=$?
    if [ "$safety_rc" -eq "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED" ]; then
      cleanup_stale_lock_for_safety_check "$WT" || { post_quiescence_safety_refusal; exit 1; }
      validate_worktree_teardown_safety || { post_quiescence_safety_refusal; exit 1; }
    else
      post_quiescence_safety_refusal
      exit 1
    fi
  fi
fi

# Report-gated tasks restore any pending rollback generation and fail closed on
# their machine-global completion report before lease release or worktree removal.
if [ "$REPORT_GATED" = 1 ] && [ "$SPAWN_NEVER_LAUNCHED" != 1 ]; then
  if [ "$MANAGED_ACCOUNT" = 1 ]; then
    reconcile_managed_account_rollback "$META" "$ID" "$DATA" || exit $?
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$FM_ROOT/bin/fm-report-stack.mjs" publish "$ID" || exit 1
fi

if [ "$MANAGED_ACCOUNT" = 1 ]; then
  release_managed_account "$META" "$ID" "$PROBE_HOME" "$ACCOUNT_DELETE_LOCK" || exit 1
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" = "--force" ]; then
  cleanup_firstmate_home_children "$HOME_PATH" || exit $?
fi

[ "$KIND" = secondmate ] || validate_teardown_target_identity || exit 1

remove_orca_worktree_locked() {
  local branch=HEAD boundary_token
  validate_teardown_target_identity || return 1
  fm_backend_quiesce_worktree_terminals orca "$ORCA_WORKTREE_ID" "fm-$ID" "$T" || return 1
  validate_worktree_teardown_safety || return 1
  validate_teardown_target_identity || return 1
  validate_removal_tree_boundaries "$WT" "Orca worktree" || return 1
  validate_teardown_target_identity || return 1
  if [ -d "$WT" ]; then
    branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
  fi
  boundary_token=$(removal_tree_boundary_token "$WT" "Orca worktree") || return 1
  fm_backend_remove_worktree_bound \
    "$BACKEND" "$ORCA_WORKTREE_ID" "$WT" "$boundary_token" || return 1
  if [ "$branch" != "HEAD" ]; then
    git -C "$PROJ" branch -D "$branch" >/dev/null 2>&1 || true
  fi
  remove_worktree_compatibility_artifacts "$WT" "removed Orca worktree"
}

validate_returned_worktree_bookkeeping_locked() {
  validate_teardown_target_identity || return 1
  [ "$TREEHOUSE_TARGET_ALREADY_RETURNED" -eq 1 ] || {
    echo "error: Treehouse lease state changed before returned-worktree bookkeeping" >&2
    return 1
  }
  validate_worktree_teardown_safety || return 1
  validate_teardown_target_identity || return 1
  [ "$TREEHOUSE_TARGET_ALREADY_RETURNED" -eq 1 ] || {
    echo "error: Treehouse lease state changed during returned-worktree bookkeeping" >&2
    return 1
  }
}

if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
  if [ "$ORCA_PATH_MATCH_VERIFIED" != 1 ]; then
    require_orca_worktree_path_match_if_present "$ORCA_WORKTREE_ID" "$WT" || exit 1
    ORCA_PATH_MATCH_VERIFIED=1
  fi
  fm_checkout_lock_run "$WT" "$CHECKOUT_LOCK_ROOT" remove_orca_worktree_locked || exit 1
elif [ -d "$WT" ] && [ "$KIND" != secondmate ]; then
  if [ "$TREEHOUSE_TARGET_ALREADY_RETURNED" -eq 1 ]; then
    fm_checkout_lock_run \
      "$WT" "$CHECKOUT_LOCK_ROOT" validate_returned_worktree_bookkeeping_locked \
      || exit 1
    echo "teardown: worktree lease was already returned; landed-work proof passed and bookkeeping will be cleared"
  else
    # Kills remaining processes in the worktree (including the agent), resets,
    # and returns it to the pool. Treehouse resolves the pool from the working
    # directory, so run it from the project.
    # teardown_treehouse_return tolerates transient and stale git locks left by
    # a killed crewmate process; see the script header for the retry proof.
    post_lock_cleanup_check=validate_worktree_teardown_safety_and_summarize_ignored
    teardown_treehouse_return "$WT" "$PROJ" "worktree" "firstmate-$ID" "$post_lock_cleanup_check" cleanup_returned_worktree || {
      echo "error: treehouse return failed for worktree $WT; teardown aborted" >&2
      exit 1
    }
  fi
fi

if [ "$DIRECT_SPAWN_CLEANUP" = pending ] && [ -n "$DIRECT_SPAWN_BACKUP" ]; then
  case "$DIRECT_SPAWN_BACKUP" in
    ".$ID.meta.rollback."*) ;;
    *) echo "error: invalid direct spawn metadata backup for $ID; retaining cleanup state" >&2; exit 1 ;;
  esac
  direct_spawn_backup_path="$STATE/$DIRECT_SPAWN_BACKUP"
  [ -f "$direct_spawn_backup_path" ] && [ ! -L "$direct_spawn_backup_path" ] || {
    echo "error: direct spawn metadata backup is unavailable for $ID; retaining cleanup state" >&2
    exit 1
  }
  [ -n "$DIRECT_SPAWN_ARTIFACTS" ] || {
    echo "error: direct spawn artifact backup is unavailable for $ID; retaining cleanup state" >&2
    exit 1
  }
  direct_spawn_restore_lock=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
  if ! fm_account_restore_artifacts "$STATE" "$ID" "$DIRECT_SPAWN_ARTIFACTS" "$TASK_TMP" 1 \
    || ! fm_account_meta_merge_extensions "$META" "$direct_spawn_backup_path" \
    || ! fm_account_safe_file_destination "$META" \
    || ! mv "$direct_spawn_backup_path" "$META"; then
    fm_account_meta_lock_release "$direct_spawn_restore_lock" >/dev/null 2>&1 || true
    echo "error: failed to restore prior task state for $ID; retaining direct spawn cleanup metadata" >&2
    exit 1
  fi
  if ! rm -rf "${STATE:?}/${DIRECT_SPAWN_ARTIFACTS:?}"; then
    fm_account_meta_lock_release "$direct_spawn_restore_lock" >/dev/null 2>&1 || true
    echo "error: failed to remove restored direct spawn artifact backup for $ID" >&2
    exit 1
  fi
  fm_account_meta_lock_release "$direct_spawn_restore_lock" || exit 1
  fm_backend_clear_transition "$BACKEND" "$STATE" "$T" || true
  [ -z "$ACCOUNT_DELETE_LOCK" ] || fm_account_lifecycle_lock_release "$ACCOUNT_DELETE_LOCK" >/dev/null 2>&1 || true
  echo "cleaned failed direct spawn for $ID and restored the prior task generation"
  exit 0
fi
if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  SECONDMATE_REGISTRY_LOCK=$(fm_secondmate_registry_lock_acquire "$CHECKOUT_LOCK_ROOT" "$SECONDMATE_REG") || exit 1
  TEARDOWN_ACCOUNT_LOCKS+=("$SECONDMATE_REGISTRY_LOCK")
  validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" "$FM_ROOT" "$SECONDMATE_REG" "$PROJ" >/dev/null || exit 1
  FINAL_CHILD_METAS=$(secondmate_state_metadata "$HOME_PATH") || exit 1
  [ -z "$FINAL_CHILD_METAS" ] || {
    echo "error: secondmate $ID gained child state before its final removal boundary" >&2
    exit 1
  }
  require_empty_secondmate_registry "$HOME_PATH" || exit 1
  SECONDMATE_REGISTRY_PREPARED=$(prepare_secondmate_registry_removal "$ID" "$HOME_PATH" "$SECONDMATE_REG" "$SECONDMATE_REGISTRY_LOCK") || exit 1
  IFS=$'\t' read -r SECONDMATE_REGISTRY_UPDATE SECONDMATE_REGISTRY_BACKUP <<EOF
$SECONDMATE_REGISTRY_PREPARED
EOF
  PREPARED_REGISTRY_PATH=$SECONDMATE_REG
  PREPARED_REGISTRY_BACKUP=$SECONDMATE_REGISTRY_BACKUP
  PREPARED_REGISTRY_ID=$ID
  PREPARED_REGISTRY_HOME=$HOME_PATH
  PREPARED_REGISTRY_LOCK=$SECONDMATE_REGISTRY_LOCK
  activate_secondmate_registry_removal "$SECONDMATE_REG" "$SECONDMATE_REGISTRY_LOCK" "$SECONDMATE_REGISTRY_UPDATE" || {
    rm -f "$SECONDMATE_REGISTRY_UPDATE" "$SECONDMATE_REGISTRY_BACKUP"
    exit 1
  }
  remove_firstmate_home "$HOME_PATH" "secondmate home" "$ID" "$FM_ROOT" "$SECONDMATE_REG" "$PROJ" || {
    rollback_secondmate_registry_removal "$SECONDMATE_REG" "$SECONDMATE_REGISTRY_LOCK" "$SECONDMATE_REGISTRY_BACKUP"
    exit 1
  }
  rm -f "$SECONDMATE_REGISTRY_BACKUP"
  PREPARED_REGISTRY_PATH=
  PREPARED_REGISTRY_BACKUP=
  PREPARED_REGISTRY_ID=
  PREPARED_REGISTRY_HOME=
  PREPARED_REGISTRY_LOCK=
fi
remove_grok_turnend_auth "$STATE" "$ID"
fm_backend_clear_transition "$BACKEND" "$STATE" "$T" || true
# Remove the per-task temp root (/tmp/fm-<id>/, incl. its gotmp/) recorded by spawn.
# Read before the state-file rm below; empty (pre-fix tasks without tasktmp=) is a no-op.
[ -z "$TASK_TMP" ] || safe_remove_task_tmp "$TASK_TMP" || exit 1
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.check.sh" "$STATE/$ID.meta" "$STATE/$ID.pi-ext.ts" "$STATE/$ID.grok-turnend-token"
[ -z "$ACCOUNT_DELETE_LOCK" ] || fm_account_lifecycle_lock_release "$ACCOUNT_DELETE_LOCK" >/dev/null 2>&1 || true
if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
echo "teardown $ID complete (window $T, worktree $WT)"
backlog_refresh_reminder
