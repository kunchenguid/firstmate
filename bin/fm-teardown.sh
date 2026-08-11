#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree or retire a
# secondmate home, kill the session-provider endpoint, clear volatile state, refresh/prune
# the project's clone for PR-based ship tasks, then print a backlog-refresh
# reminder.
# REFUSES if the worktree holds work that has not LANDED, because treehouse return
# hard-resets the worktree and kills its processes. Work has landed when it is
# reachable from any remote-tracking branch (a fork counts as a remote, so
# upstream-contribution PRs pushed to a fork satisfy this in any mode), OR - for a
# normal ship task whose commits are not so reachable - when its PR is merged and
# GitHub reports a PR head that contains the current local work, or its content is
# already present in the up-to-date default branch. This recognizes the common
# squash-merge-then-delete-branch flow, where the branch's own commits live nowhere
# on a remote yet the change is fully in main.
# A gh lookup error falls back to the content check; if that is also inconclusive,
# teardown refuses rather than risk discarding unlanded work.
# Uncommitted changes are never landed.
# local-only projects additionally accept work merged into the local default
# branch (firstmate performs that merge on the captain's approval) as a fallback
# for the common case where there is no remote at all.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product. Teardown proceeds only once the report exists and the shared
# unresolved-decision completion gate verifies its captain-held inventory.
# Before destructive cleanup, teardown validates task check artifacts and any
# matching quarantine entries as ordinary single-link files on the state
# device. It refuses and preserves task state when that proof fails; otherwise
# it removes the task's check, trust record, PR sidecar, publication record,
# retirement receipt, and quarantine entries with the rest of the volatile state.
# Orca tasks use the same safety checks, then close the recorded terminal and
# remove the recorded worktree through `orca worktree rm`; teardown never guesses
# an Orca target from ambient CLI state.
# A Herdr presentation journal never authorizes cleanup. Teardown still closes
# only the exact task pane from ordinary endpoint metadata and never calls
# `workspace close`. It retires the non-authoritative journal only when a
# read-only token correlation agrees with that endpoint and pane closure is
# confirmed. Otherwise the journal stays quarantined for manual inspection.
# Projected closes share the presentation-order lock, refuse to close the
# captain's active tab, and restore the exact response-derived pre-close tab
# if Herdr's last-pane cleanup focuses an unrelated neighboring workspace.
# Secondmates (kind=secondmate in meta) are retired explicitly. Normal
# teardown refuses while their home has in-flight crewmate meta files; --force
# is the approved discard path that prevalidates child removal targets, discards
# child work, kills child windows, and removes the retired home. Removing a
# leased home releases its durable treehouse lease so the pool slot is freed,
# never left leased forever. If the treehouse return fails, teardown leaves the
# leased home and state in place instead of hiding a still-held lease.
# A pending return is recorded as slot_returning=1 before the return runs so a
# crash can never hide a half-returned slot. That mark is cleared again whenever
# the return provably did not take effect (the slot is still a linked worktree
# stamped for this task), so an ordinary failure stays retryable; when that
# cannot be proved teardown prints the exact manual recovery instead.
# A spawn that leased a slot but never resolved its path records
# slot_lease_state=unresolved with the lease holder rather than a fabricated
# worktree: teardown then retires the endpoint and records, returns nothing, and
# prints the reclaim instruction for the still-held lease.
# Worktree disposal never trusts a recorded worktree= as current ownership.
# Before returning a pooled slot, bin/fm-slot-owner-lib.sh checks other metadata,
# the private owner stamp, and live declared agents. A conflict retains the
# directory and retires its lease; --force does not waive another task's claim.
# A contested secondmate home refuses teardown and preserves every record.
# A `treehouse return` failure that reports an existing git `index.lock` is
# retried because that lock can be transient; other return failures still stop
# teardown. FM_TREEHOUSE_RETURN_LOCK_RETRIES controls additional attempts
# (default 3) and FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS controls the whole-
# second wait between them (default 1).
# Usage: fm-teardown.sh <task-id> [--force]
#   --force skips ordinary-task dirty and landed-work checks, skips scout report
#   checks, and discards secondmate child work for kind=secondmate. Only use it
#   when the captain has explicitly said to discard the work.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "teardown" || exit 1
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECONDMATE_REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-tool-path-lib.sh
. "$SCRIPT_DIR/fm-tool-path-lib.sh"
fm_normalize_tool_path
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-task-identity-lib.sh
. "$SCRIPT_DIR/fm-task-identity-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-slot-owner-lib.sh
. "$SCRIPT_DIR/fm-slot-owner-lib.sh"
if [ "$#" -lt 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "error: invalid teardown request" >&2
  exit 2
fi
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
FORCE=${2:-}
FORCE_RETIRE_STAGED=0
FORCE_RETIRE_SOURCE=

TEARDOWN_TASK_LOCK="$STATE/.spawn-$ID.lock"
TEARDOWN_TASK_LOCK_HELD=0
teardown_release_task_lock() {
  if [ "$TEARDOWN_TASK_LOCK_HELD" = 1 ]; then
    fm_lock_release "$TEARDOWN_TASK_LOCK" || return 1
    TEARDOWN_TASK_LOCK_HELD=0
  fi
}
if ! fm_lock_acquire_wait "$TEARDOWN_TASK_LOCK"; then
  echo "error: could not acquire the task lifecycle lock for $ID" >&2
  exit 1
fi
TEARDOWN_TASK_LOCK_HELD=1
trap 'teardown_release_task_lock || true' EXIT

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
T=$(grep '^window=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
BACKEND=$(fm_backend_of_meta "$META")
fm_backend_validate "$BACKEND" || exit 1
HOME_PATH=$(grep '^home=' "$META" | cut -d= -f2- || true)
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
# tasktmp is recorded by fm-spawn for tasks that set up a per-task temp root;
# absent for tasks spawned before that change, so tolerate empty.
TASK_TMP=$(grep '^tasktmp=' "$META" | cut -d= -f2- || true)

teardown_meta_identity() {
  local meta=$1
  if command -v shasum >/dev/null 2>&1; then
    awk '!/^slot_(returned|returning)=/' "$meta" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    awk '!/^slot_(returned|returning)=/' "$meta" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

TEARDOWN_META_IDENTITY=$(teardown_meta_identity "$META") || {
  echo "error: could not establish metadata identity for $ID" >&2
  exit 1
}
teardown_meta_identity_matches() {
  [ -f "$META" ] || return 1
  [ "$(teardown_meta_identity "$META")" = "$TEARDOWN_META_IDENTITY" ]
}

validated_task_tmp_cleanup_path() {
  local recorded=$1 expected parent base suffix marker expected_marker marker_content
  [ -n "$recorded" ] || return 0
  case "$ID" in
    ''|*[!A-Za-z0-9._-]*)
      echo "REFUSED: unsafe task id $ID for task temp cleanup" >&2
      return 1
      ;;
  esac
  case "$recorded" in
    /*) ;;
    *)
      echo "REFUSED: unsafe tasktmp $recorded for task $ID" >&2
      return 1
      ;;
  esac
  parent=${recorded%/*}
  base=${recorded##*/}
  [ -n "$parent" ] && [ "$parent" != "$recorded" ] || {
    echo "REFUSED: unsafe tasktmp $recorded for task $ID" >&2
    return 1
  }
  case "$base" in
    "fm-$ID".*) suffix=${base#"fm-$ID".} ;;
    *)
      echo "REFUSED: unsafe tasktmp $recorded for task $ID" >&2
      return 1
      ;;
  esac
  case "$suffix" in
    ''|*[!A-Za-z0-9_-]*)
      echo "REFUSED: unsafe tasktmp $recorded for task $ID" >&2
      return 1
      ;;
  esac
  parent=$(cd "$parent" 2>/dev/null && pwd -P) || {
    echo "REFUSED: unsafe tasktmp $recorded for task $ID" >&2
    return 1
  }
  expected="$parent/$base"
  if [ "$recorded" != "$expected" ]; then
    echo "REFUSED: unsafe tasktmp $recorded for task $ID (expected $expected)" >&2
    return 1
  fi
  if [ -e "$expected" ] || [ -L "$expected" ]; then
    [ -d "$expected" ] && [ ! -L "$expected" ] && [ -O "$expected" ] || {
      echo "REFUSED: unsafe tasktmp $recorded for task $ID" >&2
      return 1
    }
    marker="$expected/.fm-tasktmp-owner"
    [ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] || {
      echo "REFUSED: tasktmp ownership marker is missing for $ID" >&2
      return 1
    }
    expected_marker=$(printf 'task=%s\npath=%s' "$ID" "$expected")
    marker_content=$(cat "$marker" 2>/dev/null || true)
    [ "$marker_content" = "$expected_marker" ] || {
      echo "REFUSED: tasktmp ownership marker does not match $ID" >&2
      return 1
    }
  fi
  printf '%s\n' "$expected"
}

KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes
TASK_TMP_CLEANUP=$(validated_task_tmp_cleanup_path "$TASK_TMP") || exit 1
HOME_CHILD_LOCK_HELD=0
HOME_CHILD_LOCK_PATH=
teardown_release_home_child_lock() {
  if [ "$HOME_CHILD_LOCK_HELD" = 1 ]; then
    fm_lock_release "$HOME_CHILD_LOCK_PATH" || return 1
    HOME_CHILD_LOCK_HELD=0
  fi
}
if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  if [ -d "$HOME_PATH" ]; then
    HOME_CHILD_LOCK_PATH=$(fm_config_inherit_lock_path "$HOME_PATH") || {
      echo "error: could not resolve the per-home teardown lock for $ID" >&2
      exit 1
    }
    if ! fm_lock_acquire_wait "$HOME_CHILD_LOCK_PATH"; then
      echo "error: could not acquire the per-home teardown lock for $ID" >&2
      exit 1
    fi
    HOME_CHILD_LOCK_HELD=1
  fi
fi
trap 'teardown_release_task_lock || true; teardown_release_home_child_lock || true' EXIT

validate_direct_pr_state_cleanup() {
  local artifact mode
  for artifact in "$STATE/$ID.direct-pr-lease" "$STATE/$ID.direct-pr-lease.tmp"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ -L "$artifact" ] || [ ! -f "$artifact" ] || [ ! -O "$artifact" ]; then
      echo "REFUSED: unsafe direct-PR task state $artifact; preserving task state." >&2
      return 1
    fi
    if [ "$artifact" = "$STATE/$ID.direct-pr-lease" ]; then
      mode=$(fm_pr_file_mode "$artifact") || return 1
      if [ "$mode" != 600 ]; then
        echo "REFUSED: unsafe direct-PR task state $artifact; preserving task state." >&2
        return 1
      fi
    fi
  done
}

DIRECT_PR_REF_GIT_DIR=
validate_direct_pr_ref_cleanup() {
  local candidate prefix ref refs
  [ "$MODE" = direct-PR ] || return 0
  for candidate in "$WT" "$PROJ"; do
    [ -d "$candidate" ] || continue
    git -C "$candidate" rev-parse --git-dir >/dev/null 2>&1 || continue
    DIRECT_PR_REF_GIT_DIR=$(git -C "$candidate" rev-parse --path-format=absolute --git-common-dir) || return 1
    break
  done
  [ -n "$DIRECT_PR_REF_GIT_DIR" ] || return 0
  prefix="refs/firstmate/direct-pr/$ID"
  refs=$(git --git-dir="$DIRECT_PR_REF_GIT_DIR" for-each-ref --format='%(refname)' "$prefix/") || return 1
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      "$prefix/base"|"$prefix/feature") ;;
      *)
        echo "REFUSED: ambiguous direct-PR private ref namespace $prefix; preserving task state." >&2
        return 1
        ;;
    esac
  done <<EOF
$refs
EOF
}

cleanup_direct_pr_refs() {
  local prefix refs
  [ -n "$DIRECT_PR_REF_GIT_DIR" ] || return 0
  prefix="refs/firstmate/direct-pr/$ID"
  {
    printf 'delete %s\n' "$prefix/base"
    printf 'delete %s\n' "$prefix/feature"
  } | git --git-dir="$DIRECT_PR_REF_GIT_DIR" update-ref --stdin || return 1
  refs=$(git --git-dir="$DIRECT_PR_REF_GIT_DIR" for-each-ref --format='%(refname)' "$prefix/") || return 1
  [ -z "$refs" ]
}

TREEHOUSE_RETURN_LOCK_RETRIES=${FM_TREEHOUSE_RETURN_LOCK_RETRIES:-3}
TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=${FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS:-1}
case "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS" in
  ''|*[!0-9]*)
    echo "teardown: invalid transient-lock retry wait '$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
    TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1
    ;;
esac

treehouse_return_is_index_lock_error() {
  printf '%s\n' "$1" | grep -Fq 'index.lock' && printf '%s\n' "$1" | grep -Fq 'File exists'
}

teardown_treehouse_return() {
  local dir=$1 cd_dir=$2 label=$3 out attempt=0 retries
  retries=$TREEHOUSE_RETURN_LOCK_RETRIES
  case "$retries" in ''|*[!0-9]*) retries=3 ;; esac
  while :; do
    if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
      [ -n "$out" ] && printf '%s\n' "$out"
      return 0
    fi
    [ -n "$out" ] && printf '%s\n' "$out" >&2
    if ! treehouse_return_is_index_lock_error "$out" || [ "$attempt" -ge "$retries" ]; then
      return 1
    fi
    attempt=$(( attempt + 1 ))
    echo "teardown: $label return hit a transient git index lock; retrying ($attempt/$retries)" >&2
    sleep "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"
  done
}

meta_value() {
  local meta=$1 key=$2
  grep "^$key=" "$meta" | cut -d= -f2- || true
}

TOP_SLOT_LEASE_STATE=$(meta_value "$META" slot_lease_state)
TOP_SLOT_LEASE_HOLDER=$(meta_value "$META" slot_lease_holder)
TOP_SLOT_WT_CANDIDATE=$(meta_value "$META" slot_worktree_candidate)
TOP_SLOT_UNRESOLVED_LEASE=0
if [ "$KIND" != secondmate ] && [ -z "$WT" ] \
   && [ "$TOP_SLOT_LEASE_STATE" = unresolved ]; then
  TOP_SLOT_UNRESOLVED_LEASE=1
fi

# A record that never resolved a slot path has no worktree identity to assert
# and no slot it could mis-address. Refusing it here would hide the reclaim
# instruction the operator actually needs behind an unrelated identity
# mismatch, and would leave an aborted spawn's record permanently unretirable.
if [ "$KIND" = ship ] && [ "$FORCE" != "--force" ] \
   && [ "$TOP_SLOT_UNRESOLVED_LEASE" != 1 ]; then
  fm_assert_task_branch_matches_meta "$ID" "$META" "REFUSED" || exit 1
fi

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

TOP_SLOT_RETURNED=
TOP_SLOT_RETURNING=
TOP_SLOT_RETURNED=$(meta_value "$META" slot_returned)
TOP_SLOT_RETURNING=$(meta_value "$META" slot_returning)

teardown_meta_set_slot_state() {
  local meta=$1 state=$2 dir tmp rc
  [ -f "$meta" ] || return 1
  dir=$(dirname "$meta")
  tmp=$(mktemp "$dir/.$(basename "$meta").slot-state.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  grep -vE '^slot_(returned|returning)=' "$meta" > "$tmp" || {
    rc=$?
    if [ "$rc" -ne 1 ]; then
      rm -f "$tmp"
      return 1
    fi
  }
  if [ "$state" != none ]; then
    printf 'slot_%s=1\n' "$state" >> "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

teardown_meta_mark_slot_returning() {
  teardown_meta_set_slot_state "$1" returning
}

teardown_meta_mark_slot_returned() {
  teardown_meta_set_slot_state "$1" returned
}

teardown_meta_clear_slot_state() {
  teardown_meta_set_slot_state "$1" none
}

# The pending-return mark is written BEFORE `treehouse return` so a crash can
# never hide a half-returned slot. That must not make it a one-way door: every
# caller that fails past the mark either proves the return did not take effect
# and clears it, or prints the exact manual recovery for the operator.
teardown_slot_returning_recovery_line() {  # <meta> <worktree> <task-id>
  echo "teardown: RECOVERY: run 'treehouse list' and confirm whether ${2:-the recorded slot} is still leased to $3. If it is, delete the 'slot_returning=1' line from $1 and re-run teardown; if the slot was already returned, replace that line with 'slot_returned=1'. docs/worker-isolation.md owns the manual reclaim path." >&2
}

# Retire the task branch only once the slot is provably back in the pool.
# Detaching and deleting it BEFORE the return would strip the very identity
# fm_assert_task_branch_matches_meta checks, so a retryable return failure
# would come back as an unrelated identity mismatch on the next attempt.
teardown_retire_task_branch() {  # <worktree> <project> <branch>
  local wt=$1 proj=$2 branch=$3 current
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 0
  if [ -d "$wt" ] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    current=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    if [ "$current" = "$branch" ]; then
      git -C "$wt" checkout --detach -q 2>/dev/null || return 0
    fi
    git -C "$wt" branch -D "$branch" >/dev/null 2>&1 || true
    return 0
  fi
  [ -n "$proj" ] && [ -d "$proj" ] || return 0
  git -C "$proj" branch -D "$branch" >/dev/null 2>&1 || true
}

# A return provably did not take effect when the slot is still a linked
# worktree carrying THIS task's own ownership stamp: nothing was handed back to
# the pool, so the lease is still held here and teardown stays retryable.
# Anything less keeps the mark and prints the manual recovery instead.
teardown_slot_return_recover() {  # <meta> <worktree> <task-id> <label>
  local meta=$1 wt=$2 id=$3 label=$4
  if fm_slot_stamp_record "$wt" >/dev/null 2>&1 \
     && [ "$FM_SLOT_STAMP_TASK" = "$id" ] \
     && teardown_meta_clear_slot_state "$meta"; then
    echo "teardown: $label $wt was not returned and its lease is still held by $id; teardown can be retried" >&2
    return 0
  fi
  teardown_slot_returning_recovery_line "$meta" "$wt" "$id"
  return 1
}

if [ "$TOP_SLOT_RETURNING" = 1 ]; then
  echo "REFUSED: durable return for $ID is incomplete; preserving task state and lease" >&2
  teardown_slot_returning_recovery_line "$META" "$WT" "$ID"
  exit 1
fi

teardown_meta_backup_create() {
  local meta=$1 dir
  TEARDOWN_META_BACKUP=
  [ -f "$meta" ] || return 1
  dir=$(dirname "$meta")
  TEARDOWN_META_BACKUP=$(mktemp "$dir/.$(basename "$meta").recovery.XXXXXX") || return 1
  chmod 600 "$TEARDOWN_META_BACKUP" || {
    rm -f "$TEARDOWN_META_BACKUP"
    TEARDOWN_META_BACKUP=
    return 1
  }
  if ! cp -p "$meta" "$TEARDOWN_META_BACKUP"; then
    rm -f "$TEARDOWN_META_BACKUP"
    TEARDOWN_META_BACKUP=
    return 1
  fi
}

teardown_meta_backup_restore() {
  local meta=$1
  [ -n "${TEARDOWN_META_BACKUP:-}" ] || return 1
  mv "$TEARDOWN_META_BACKUP" "$meta" || return 1
  TEARDOWN_META_BACKUP=
}

teardown_meta_backup_discard() {
  if [ -n "${TEARDOWN_META_BACKUP:-}" ]; then
    rm -f "$TEARDOWN_META_BACKUP" || return 1
    TEARDOWN_META_BACKUP=
  fi
}

teardown_cleanup_returned_slot() {
  local wt=$1 id=$2 expected_home=${3:-$FM_HOME} lock_path
  [ -e "$wt" ] || [ -L "$wt" ] || return 0
  fm_slot_stamp_path "$wt" >/dev/null 2>&1 || return 0
  fm_slot_lock_acquire "$wt" || return 1
  lock_path=$FM_SLOT_LOCK_PATH
  if ! fm_slot_stamp_clear_after_return "$wt" "$id" "$expected_home"; then
    fm_slot_lock_release "$lock_path" || true
    return 1
  fi
  fm_slot_lock_release "$lock_path"
}

teardown_acquire_herdr_presentation_lock() {
  local target=$1 session lock attempt=0
  fm_backend_herdr_parse_target "$target" || return 1
  session=$FM_BACKEND_HERDR_SESSION
  lock=$(fm_backend_herdr_presentation_session_lock_path "$session") || return 1
  if [ "${HERDR_PRESENTATION_LOCK_HELD:-0}" = 1 ]; then
    [ "$HERDR_PRESENTATION_LOCK_PATH" = "$lock" ]
    return
  fi
  while [ "$attempt" -lt 50 ]; do
    if fm_lock_try_acquire "$lock"; then
      HERDR_PRESENTATION_LOCK_PATH=$lock
      HERDR_PRESENTATION_LOCK_HELD=1
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

teardown_release_herdr_presentation_lock() {
  if [ "${HERDR_PRESENTATION_LOCK_HELD:-0}" = 1 ]; then
    fm_lock_release "$HERDR_PRESENTATION_LOCK_PATH" || return 1
    HERDR_PRESENTATION_LOCK_HELD=0
  fi
}

teardown_herdr_endpoint_focus_safe() {
  local target=$1 session pane state close_status=1 acquired_here=0
  fm_backend_source herdr || return 1
  fm_backend_herdr_parse_target "$target" || return 1
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  state=$(fm_backend_herdr_pane_agent_state "$session" "$pane")
  [ "$state" = dead ] && return 0
  if [ "${HERDR_PRESENTATION_LOCK_HELD:-0}" != 1 ]; then
    teardown_acquire_herdr_presentation_lock "$target" || return 1
    acquired_here=1
  fi
  if fm_backend_herdr_projection_teardown_close "$session" "$pane"; then
    close_status=0
  else
    close_status=$?
  fi
  if [ "$acquired_here" = 1 ]; then
    teardown_release_herdr_presentation_lock || close_status=1
  fi
  return "$close_status"
}

teardown_backend_endpoint() {
  local backend=$1 target=$2
  case "$backend" in
    herdr) teardown_herdr_endpoint_focus_safe "$target" ;;
    *) fm_backend_kill "$backend" "$target" ;;
  esac
}

teardown_file_inode() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%i' "$1" 2>/dev/null
  else
    stat -c '%i' "$1" 2>/dev/null
  fi
}

teardown_file_digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

teardown_grok_real_directory() {
  local path=$1 parent
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  [ "$path" = / ] && return 0
  parent=${path%/*}
  [ -n "$parent" ] || parent=/
  teardown_grok_real_directory "$parent"
}

teardown_grok_registry_read() {
  local state_dir=$1 id=$2 file line token= dir= inode= digest= count=0
  local state_real auth_file actual_inode actual_digest
  file="$state_dir/$id.grok-turnend-token"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    count=$((count + 1))
    case "$line" in
      token=*) [ -z "$token" ] || return 1; token=${line#token=} ;;
      dir=*) [ -z "$dir" ] || return 1; dir=${line#dir=} ;;
      inode=*) [ -z "$inode" ] || return 1; inode=${line#inode=} ;;
      digest=*) [ -z "$digest" ] || return 1; digest=${line#digest=} ;;
      *) return 1 ;;
    esac
  done < "$file" || return 1
  [ "$count" = 4 ] || return 1
  case "$token" in
    fm.????????????) ;;
    *) return 1 ;;
  esac
  case "$token" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$dir" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$dir" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$inode" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#digest}" = 64 ] || return 1
  case "$digest" in *[!0-9a-f]*) return 1 ;; esac
  teardown_grok_real_directory "$dir" || return 1
  auth_file="$dir/$token"
  [ -f "$auth_file" ] && [ ! -L "$auth_file" ] || return 1
  actual_inode=$(teardown_file_inode "$auth_file") || return 1
  [ "$actual_inode" = "$inode" ] || return 1
  actual_digest=$(teardown_file_digest "$auth_file") || return 1
  [ "$actual_digest" = "$digest" ] || return 1
  state_real=$(cd "$state_dir" && pwd -P) || return 1
  printf '%s\n' "$state_real/$id.turn-ended" | cmp -s - "$auth_file" || return 1
  GROK_REGISTRY_TOKEN=$token
  GROK_REGISTRY_AUTH_DIR=$dir
  GROK_REGISTRY_AUTH_FILE=$auth_file
}

teardown_grok_pointer_valid() {
  local worktree=$1 state_dir=$2 id=$3 pointer
  pointer="$worktree/.fm-grok-turnend"
  if [ ! -e "$pointer" ] && [ ! -L "$pointer" ]; then
    return 0
  fi
  [ -f "$pointer" ] && [ ! -L "$pointer" ] || return 1
  teardown_grok_registry_read "$state_dir" "$id" || return 1
  printf 'token=%s\n' "$GROK_REGISTRY_TOKEN" | cmp -s - "$pointer"
}

remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 file
  file="$state_dir/$id.grok-turnend-token"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 0
  fi
  teardown_grok_registry_read "$state_dir" "$id" || return 1
  rm -f -- "$GROK_REGISTRY_AUTH_FILE"
}

validate_pr_poll_cleanup() {
  local state_dir=$1 id=$2 quarantine state_device artifact presentation meta expected_url has_artifact=0
  fm_task_id_path_safe "$id" || return 0
  quarantine="$state_dir/.pr-check-quarantine"
  if [ "$id" = _noncanonical ] \
    && { [ -e "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.pending-noncanonical" ] \
      || [ -e "$quarantine/_noncanonical.diagnostic.noncanonical" ] \
      || [ -L "$quarantine/_noncanonical.diagnostic.noncanonical" ]; }; then
    echo "REFUSED: legacy PR-check quarantine migration is incomplete; preserving task state." >&2
    return 1
  fi
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.pr-poll-replacement" \
    "$state_dir/$id.pr-presentation" \
    "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  if [ -e "$quarantine" ] || [ -L "$quarantine" ]; then
    has_artifact=1
  fi
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.pr-poll-replacement" \
    "$state_dir/$id.pr-presentation" \
    "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ]; then
      echo "REFUSED: unsafe task PR-check artifact; preserving task state." >&2
      return 1
    fi
  done
  presentation="$state_dir/$id.pr-presentation"
  if [ -e "$presentation" ] || [ -L "$presentation" ]; then
    meta="$state_dir/$id.meta"
    fm_pr_metadata_identity_parse "$meta" && expected_url=$FM_PR_META_URL || {
      echo "REFUSED: task metadata cannot identify its PR-presentation receipt; preserving task state." >&2
      return 1
    }
    fm_pr_presentation_cleanup_parse "$presentation" \
      && [ "$FM_PR_PRESENTATION_URL" = "$expected_url" ] || {
        echo "REFUSED: invalid or foreign PR-presentation receipt; preserving task state." >&2
        return 1
      }
  fi
  if [ -e "$state_dir/$id.pr-poll-retirement" ] \
    || [ -L "$state_dir/$id.pr-poll-retirement" ]; then
    fm_pr_poll_retirement_state_valid "$state_dir" "$id" || {
      echo "REFUSED: invalid PR-poll retirement receipt; preserving task state." >&2
      return 1
    }
  fi
  if [ -e "$state_dir/$id.pr-poll-replacement" ] \
    || [ -L "$state_dir/$id.pr-poll-replacement" ]; then
    fm_pr_poll_replacement_parse "$state_dir/$id.pr-poll-replacement" \
      && fm_pr_poll_replacement_receipt_valid "$state_dir" "$id" \
        "$FM_PR_REPLACE_EXPECTED_HEAD" || {
          echo "REFUSED: invalid PR-poll replacement receipt; preserving task state." >&2
          return 1
        }
  fi
  [ -e "$quarantine" ] || [ -L "$quarantine" ] || return 0
  if [ ! -d "$state_dir" ] || [ -L "$state_dir" ] \
    || [ ! -d "$quarantine" ] || [ -L "$quarantine" ]; then
    echo "REFUSED: unsafe PR-check quarantine path $quarantine; preserving task state." >&2
    return 1
  fi
  if [ "$(fm_pr_file_device "$quarantine")" != "$state_device" ] \
    || [ "$(fm_pr_file_mode "$quarantine")" != 700 ]; then
    echo "REFUSED: PR-check quarantine is not on the task state device; preserving task state." >&2
    return 1
  fi
  for artifact in "$quarantine/$id."*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if ! fm_pr_private_file_valid "$artifact" 600 "$state_device"; then
      echo "REFUSED: unsafe task quarantine entry; preserving task state." >&2
      return 1
    fi
  done
}

remove_pr_poll_artifacts() {
  local state_dir=$1 id=$2 quarantine artifact
  validate_pr_poll_cleanup "$state_dir" "$id" || return 1
  fm_pr_poll_retirement_recover_one "$state_dir" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" || return 1
  rm -f "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.pr-poll-replacement" \
    "$state_dir/$id.pr-presentation" \
    "$state_dir/$id.check-trust" || return 1
  if fm_task_id_path_safe "$id"; then
    quarantine="$state_dir/.pr-check-quarantine"
    if [ -d "$quarantine" ] && [ ! -L "$quarantine" ]; then
      for artifact in "$quarantine/$id."*; do
        [ -e "$artifact" ] || [ -L "$artifact" ] || continue
        rm -f -- "$artifact" || return 1
      done
      rmdir "$quarantine" 2>/dev/null || true
    fi
  fi
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

# Is the branch's content already present in the up-to-date default branch? Fetches
# first, then 3-way merges the default branch with HEAD: when HEAD introduces nothing
# the default branch does not already contain (e.g. its change landed via squash) the
# merged tree equals the default branch's tree. This isolates branch-only changes, so
# unrelated commits the default branch gained past the merge-base do not count as
# "added". Returns non-zero when inconclusive (no default ref, or a merge conflict),
# so the caller refuses rather than guesses.
content_in_default() {
  local name ref default_tree merged_tree
  name=$(default_branch) || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
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

firstmate_home_has_treehouse_slot() {
  local home=$1
  worktree_registered_for_project "$FM_ROOT" "$home"
}

validate_removal_target() {
  local target=$1 label=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(removal_target_abs_path "$target")
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

registered_descendant_home_for_removal() {
  local reg=$1 target=$2 line id registered_home registered_abs
  [ -f "$reg" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "- "*)
        id=${line#- }
        id=${id%% *}
        registered_home=$(printf '%s\n' "$line" | registry_home_for_line)
        [ -n "$registered_home" ] || continue
        registered_abs=$(removal_target_abs_path "$registered_home" 2>/dev/null || true)
        [ -n "$registered_abs" ] || continue
        [ "$registered_abs" = "$target" ] && continue
        if path_is_ancestor_of "$target" "$registered_abs"; then
          printf '%s\t%s\n' "$id" "$registered_abs"
          return 0
        fi
        ;;
    esac
  done < "$reg"
  return 1
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
  done
}

validate_child_worktree_for_removal() {
  local target=$1 project=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(validate_removal_target "$target" "child worktree") || return 1
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
  if ! worktree_registered_for_project "$project" "$target"; then
    echo "REFUSED: unsafe child worktree removal target $target is not a git worktree for ${project:-the recorded project}" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

safe_rm_rf() {
  local target=$1 label=$2
  validate_removal_target "$target" "$label" >/dev/null || return 1
  rm -rf -- "$target"
}

safe_rm_rf_child_worktree() {
  local target=$1 project=$2
  validate_child_worktree_for_removal "$target" "$project" >/dev/null || return 1
  rm -rf -- "$target"
}

validate_firstmate_home_for_removal() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path marker_id conflict child_id child_home
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
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
  fi
  validate_firstmate_operational_dirs_for_removal "$abs_home_path" "$label" || return 1
  conflict=$(registered_descendant_home_for_removal "$SECONDMATE_REG" "$abs_home_path" || true)
  if [ -z "$conflict" ]; then
    conflict=$(registered_descendant_home_for_removal "$abs_home_path/data/secondmates.md" "$abs_home_path" || true)
  fi
  if [ -n "$conflict" ]; then
    IFS=$'\t' read -r child_id child_home <<EOF
$conflict
EOF
    echo "REFUSED: unsafe $label removal target $home contains registered secondmate home $child_home for $child_id" >&2
    return 1
  fi
  printf '%s\n' "$abs_home_path"
}

TEARDOWN_SLOT_RETAINED=0
TEARDOWN_SLOT_RETAIN_VERDICT=
slot_release_allowed() {  # <state-dir> <task-id> <worktree> <stamp-home> <label> <retire|refuse> [endpoint-state] [backend] [target] [worker-home] [role]
  local state=$1 id=$2 wt=$3 stamp_home=$4 label=$5 disposition=$6
  local endpoint_state=${7:-closed} backend=${8:-} target=${9:-}
  local worker_home=${10:-$stamp_home} role=${11:-crewmate} verdict
  TEARDOWN_SLOT_RETAIN_VERDICT=
  case "$disposition" in
    retire|refuse) ;;
    *)
      echo "error: slot gate for $label $wt was asked for an unknown disposition '$disposition'" >&2
      return 1
      ;;
  esac
  verdict=$(fm_slot_disposal_verdict "$state" "$id" "$wt" "$stamp_home" \
    "$worker_home" "$role" "$endpoint_state" "$backend" "$target")
  [ "$verdict" = dispose ] && return 0
  TEARDOWN_SLOT_RETAINED=1
  TEARDOWN_SLOT_RETAIN_VERDICT=$verdict
  echo "teardown: $label $wt lease RETAINED, not returned to the pool: ${verdict#retain: }" >&2
  echo "teardown: the directory is left untouched on disk; --force does not waive this ownership gate." >&2
  if [ "$disposition" = retire ]; then
    echo "teardown: once nothing references the slot, tearing down its remaining holder releases it; docs/worker-isolation.md owns manual reclaim." >&2
  else
    echo "teardown: refusing to continue for $label $wt and leaving every record for $id in place." >&2
  fi
  return 1
}

remove_firstmate_home() {  # <home> <label> [expected-id] [state-dir] [home-scope]
  local home=$1 label=$2 expected_id=${3:-} state_scope=${4:-$STATE} home_scope=${5:-$FM_HOME} abs_home_path meta_id meta_path lock_path
  [ -n "$home" ] || return 0
  meta_id=$expected_id
  [ -n "$meta_id" ] || meta_id=$ID
  meta_path="$state_scope/$meta_id.meta"
  if [ "$(meta_value "$meta_path" slot_returning)" = 1 ]; then
    echo "error: durable return for $label $home is incomplete; preserving task state" >&2
    teardown_slot_returning_recovery_line "$meta_path" "$home" "${expected_id:-$ID}"
    return 1
  fi
  if [ "$(meta_value "$meta_path" slot_returned)" = 1 ]; then
    teardown_cleanup_returned_slot "$home" "${expected_id:-$ID}" "$home_scope" || {
      echo "error: could not clear the ownership stamp for returned $label $home; preserving task state" >&2
      return 1
    }
    return 0
  fi
  if [ ! -e "$home" ] && [ ! -L "$home" ]; then
    # A home that is already gone is only a lease hazard when it was a pooled
    # slot. git keeps the worktree registration of a slot whose directory was
    # removed (it lists as prunable), so that registration - not the missing
    # directory - is the evidence of record. A plain-clone secondmate home
    # never drew a slot and has nothing to return, and refusing it forever
    # would make such a home permanently unretirable. An unresolvable path
    # still fails closed.
    if [ ! -d "$(dirname "$home")" ] || firstmate_home_has_treehouse_slot "$home"; then
      slot_release_allowed "$state_scope" "${expected_id:-$ID}" "$home" \
        "$home_scope" "$label" refuse unknown "" "" "$home" secondmate || return 1
      return 1
    fi
    return 0
  fi
  abs_home_path=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id") || return 1
  [ -n "$abs_home_path" ] || return 0
  if firstmate_home_has_treehouse_slot "$abs_home_path"; then
    command -v treehouse >/dev/null 2>&1 || {
      echo "error: treehouse command not found; cannot return $label $abs_home_path" >&2
      return 1
    }
    fm_slot_lock_acquire "$abs_home_path" || {
      echo "error: could not serialize return for $label $abs_home_path; preserving task state" >&2
      return 1
    }
    lock_path=$FM_SLOT_LOCK_PATH
    if ! slot_release_allowed "$state_scope" "${expected_id:-$ID}" "$abs_home_path" \
      "$home_scope" "$label" refuse closed "" "" "$abs_home_path" secondmate; then
      fm_slot_lock_release "$lock_path" || true
      return 1
    fi
    teardown_meta_mark_slot_returning "$meta_path" || {
      fm_slot_lock_release "$lock_path" || true
      echo "error: could not record pending return for $label $abs_home_path; preserving task state" >&2
      return 1
    }
    teardown_treehouse_return "$abs_home_path" "$FM_ROOT" "$label" || {
      echo "error: treehouse return failed for $label $abs_home_path; lease may still be held" >&2
      teardown_slot_return_recover "$meta_path" "$abs_home_path" \
        "${expected_id:-$ID}" "$label" || true
      fm_slot_lock_release "$lock_path" || true
      return 1
    }
    teardown_meta_mark_slot_returned "$meta_path" || {
      fm_slot_lock_release "$lock_path" || true
      echo "error: could not record successful return for $label $abs_home_path; preserving task state" >&2
      teardown_slot_returning_recovery_line "$meta_path" "$abs_home_path" "${expected_id:-$ID}"
      return 1
    }
    fm_slot_stamp_clear_after_return "$abs_home_path" "${expected_id:-$ID}" "$home_scope" || {
      fm_slot_lock_release "$lock_path" || true
      echo "error: could not clear the ownership stamp for $label $abs_home_path; preserving task state" >&2
      return 1
    }
    fm_slot_lock_release "$lock_path" || return 1
    return 0
  fi
  safe_rm_rf "$abs_home_path" "$label"
}

validate_firstmate_home_children_removal() {
  local home=$1 sub_state child_meta child_id child_backend child_wt child_proj child_kind child_home
  local child_slot_returned child_slot_returning child_slot_path
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    validate_pr_poll_cleanup "$sub_state" "$child_id" || return 1
    child_backend=$(validate_child_backend "$child_id" "$child_meta") || return 1
    child_wt=$(meta_value "$child_meta" worktree)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_slot_returned=$(meta_value "$child_meta" slot_returned)
    child_slot_returning=$(meta_value "$child_meta" slot_returning)
    if [ "$child_slot_returning" = 1 ]; then
      child_slot_path=$(meta_value "$child_meta" home)
      [ -n "$child_slot_path" ] || child_slot_path=$child_wt
      echo "REFUSED: child $child_id has an incomplete durable return; preserving child state." >&2
      teardown_slot_returning_recovery_line "$child_meta" "$child_slot_path" "$child_id"
      return 1
    fi
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      if [ "$child_slot_returned" != 1 ] && { [ -z "$child_home" ] || { [ ! -e "$child_home" ] && [ ! -L "$child_home" ]; }; }; then
        slot_release_allowed "$sub_state" "$child_id" "$child_home" "$home" \
          "child firstmate home" refuse unknown "$child_backend" "" "$home" secondmate \
          || return 1
      fi
      if [ "$child_slot_returned" != 1 ]; then
        validate_firstmate_home_for_removal "$child_home" "child firstmate home" "$child_id" >/dev/null || return 1
      fi
      if ! fm_pending_reply_task_force_retirable "$sub_state" "$child_id"; then
        echo "REFUSED: child secondmate $child_id has a pending reply that has not reached escalation." >&2
        return 1
      fi
      if [ "$child_slot_returned" != 1 ]; then
        validate_firstmate_home_children_removal "$child_home" || return 1
      fi
    elif [ -n "$child_wt" ] && [ "$child_slot_returned" != 1 ]; then
      [ -d "$child_wt" ] || {
        slot_release_allowed "$sub_state" "$child_id" "$child_wt" "$home" \
          "child worktree" refuse unknown "$child_backend" "" "$home" crewmate \
          || return 1
      }
      child_proj=$(meta_value "$child_meta" project)
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
    fi
  done
}

validate_child_backend() {
  local child_id=$1 child_meta=$2 child_backend
  child_backend=$(fm_backend_of_meta "$child_meta")
  if ! fm_backend_validate "$child_backend" >/dev/null 2>&1; then
    echo "REFUSED: child $child_id uses unsupported backend '$child_backend'; refusing force teardown" >&2
    return 1
  fi
  printf '%s\n' "$child_backend"
}

teardown_remove_child_home_locked() {
  local child_home=$1 child_id=$2 state_scope=$3 home_scope=$4 lock_path
  lock_path=$(fm_config_inherit_lock_path "$child_home") || return 1
  fm_lock_acquire_wait "$lock_path" || return 1
  (
    trap 'fm_lock_release "$lock_path" || true' EXIT
    cleanup_firstmate_home_children "$child_home" || exit 1
    remove_firstmate_home "$child_home" "child firstmate home" "$child_id" \
      "$state_scope" "$home_scope" || exit 1
  )
}

cleanup_firstmate_home_children() {
  local home=$1 sub_state child_meta child_id child_backend child_t child_wt child_proj child_kind child_home
  local child_retire_staged child_retire_source child_resolved_handoff child_slot_retain_verdict
  local child_slot_returned child_slot_returning child_slot_lock_path child_slot_path
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_backend=$(validate_child_backend "$child_id" "$child_meta") || return 1
    child_t=$(meta_value "$child_meta" window)
    child_wt=$(meta_value "$child_meta" worktree)
    child_proj=$(meta_value "$child_meta" project)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_slot_returned=$(meta_value "$child_meta" slot_returned)
    child_slot_returning=$(meta_value "$child_meta" slot_returning)
    if [ "$child_slot_returning" = 1 ]; then
      child_slot_path=$(meta_value "$child_meta" home)
      [ -n "$child_slot_path" ] || child_slot_path=$child_wt
      echo "REFUSED: child $child_id has an incomplete durable return; preserving child state" >&2
      teardown_slot_returning_recovery_line "$child_meta" "$child_slot_path" "$child_id"
      return 1
    fi
    child_retire_staged=0
    child_retire_source=
    child_resolved_handoff=0
    child_slot_retain_verdict=
    if [ -n "$child_wt" ] && [ "$child_slot_returned" != 1 ]; then
      teardown_grok_pointer_valid "$child_wt" "$sub_state" "$child_id" || {
        echo "REFUSED: child $child_id has an unsafe Grok turn-end pointer; preserving child state" >&2
        return 1
      }
    fi
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      if [ "$child_slot_returned" != 1 ] && { [ -z "$child_home" ] || { [ ! -e "$child_home" ] && [ ! -L "$child_home" ]; }; }; then
        slot_release_allowed "$sub_state" "$child_id" "$child_home" "$home" \
          "child firstmate home" refuse unknown "$child_backend" "$child_t" "$home" secondmate \
          || return 1
      fi
    elif [ -n "$child_wt" ] && [ "$child_slot_returned" != 1 ] && [ ! -d "$child_wt" ]; then
      slot_release_allowed "$sub_state" "$child_id" "$child_wt" "$home" \
        "child worktree" refuse unknown "$child_backend" "$child_t" "$home" crewmate \
        || return 1
    fi
    if [ "$child_kind" = secondmate ]; then
      child_retire_source=$(fm_pending_reply_source_identity "$sub_state") || return 1
      if fm_pending_reply_task_has_open "$sub_state" "$child_id"; then
        if ! fm_pending_reply_stage_force_retire_task "$sub_state" "$child_id" "$STATE"; then
          echo "REFUSED: could not stage pending replies for child secondmate $child_id." >&2
          return 1
        fi
        child_retire_staged=1
      fi
      if ! fm_pending_reply_handoff_resolved_task_history \
        "$sub_state" "$child_id" "$STATE" "$child_retire_source" child_resolved_handoff; then
        echo "REFUSED: could not hand off resolved reply history for child secondmate $child_id." >&2
        return 1
      fi
      [ "$child_resolved_handoff" = 0 ] || child_retire_staged=1
    fi
    if [ -n "$child_t" ] && [ "$child_slot_returned" != 1 ]; then
      if ! teardown_backend_endpoint "$child_backend" "$child_t" 2>/dev/null; then
        echo "REFUSED: could not kill child $child_id window $child_t; refusing to delete child state" >&2
        return 1
      fi
    fi
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      if [ "$child_slot_returned" = 1 ] && [ -n "$child_home" ]; then
        teardown_cleanup_returned_slot "$child_home" "$child_id" "$home" || return 1
      elif [ -n "$child_home" ] && [ -d "$child_home" ]; then
        # Nested homes belong to their immediate parent home's state and stamp
        # scope, not to the top-level primary.
        teardown_remove_child_home_locked "$child_home" "$child_id" "$sub_state" "$home" || return 1
      fi
      if [ "$child_retire_staged" = 1 ] \
         && ! fm_pending_reply_finalize_force_retire_task \
           "$sub_state" "$child_id" "$STATE" "$child_retire_source"; then
        echo "REFUSED: could not hand off pending replies for child secondmate $child_id." >&2
        return 1
      fi
    elif [ -n "$child_wt" ]; then
      if [ "$child_slot_returned" = 1 ]; then
        teardown_cleanup_returned_slot "$child_wt" "$child_id" "$home" || {
          echo "error: could not clear the ownership stamp for returned child $child_id; preserving child state" >&2
          return 1
        }
      elif slot_release_allowed "$sub_state" "$child_id" "$child_wt" "$home" "child worktree" retire; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        [ -n "$child_proj" ] && [ -d "$child_proj" ] && command -v treehouse >/dev/null 2>&1 || {
          echo "REFUSED: cannot prove durable return for child worktree $child_wt; preserving child state" >&2
          return 1
        }
        fm_slot_lock_acquire "$child_wt" || {
          echo "error: could not serialize return for child worktree $child_wt; preserving child state" >&2
          return 1
        }
        child_slot_lock_path=$FM_SLOT_LOCK_PATH
        if ! slot_release_allowed "$sub_state" "$child_id" "$child_wt" "$home" "child worktree" retire; then
          child_slot_retain_verdict=$TEARDOWN_SLOT_RETAIN_VERDICT
          fm_slot_lock_release "$child_slot_lock_path" || true
        else
          rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js"
          [ ! -e "$child_wt/.fm-grok-turnend" ] || rm -f -- "$child_wt/.fm-grok-turnend"
          teardown_meta_mark_slot_returning "$child_meta" || {
            fm_slot_lock_release "$child_slot_lock_path" || true
            echo "error: could not record pending return for child worktree $child_wt; preserving child state" >&2
            return 1
          }
          if ! teardown_treehouse_return "$child_wt" "$child_proj" "child worktree"; then
            echo "error: treehouse return failed for child worktree $child_wt; lease may still be held" >&2
            teardown_slot_return_recover "$child_meta" "$child_wt" "$child_id" "child worktree" || true
            fm_slot_lock_release "$child_slot_lock_path" || true
            return 1
          fi
          teardown_meta_mark_slot_returned "$child_meta" || {
            fm_slot_lock_release "$child_slot_lock_path" || true
            echo "error: could not record successful return for child worktree $child_wt; preserving child state" >&2
            teardown_slot_returning_recovery_line "$child_meta" "$child_wt" "$child_id"
            return 1
          }
          fm_slot_stamp_clear_after_return "$child_wt" "$child_id" "$home" || {
            fm_slot_lock_release "$child_slot_lock_path" || true
            echo "error: could not clear the ownership stamp for child worktree $child_wt; preserving child state" >&2
            return 1
          }
          fm_slot_lock_release "$child_slot_lock_path" || return 1
        fi
      else
        child_slot_retain_verdict=$TEARDOWN_SLOT_RETAIN_VERDICT
      fi
    fi
    remove_grok_turnend_auth "$sub_state" "$child_id" || {
      echo "REFUSED: could not prove child $child_id Grok registry ownership; preserving child state" >&2
      return 1
    }
    remove_pr_poll_artifacts "$sub_state" "$child_id" || return 1
    if [ -n "$child_slot_retain_verdict" ]; then
      teardown_meta_backup_create "$child_meta" || {
        echo "error: could not preserve recovery metadata for child $child_id" >&2
        return 1
      }
    fi
    if ! rm -f "$sub_state/$child_id.status" "$sub_state/$child_id.turn-ended" \
      "$sub_state/$child_id.meta" "$sub_state/$child_id.pi-ext.ts" \
      "$sub_state/$child_id.grok-turnend-token"; then
      if [ -n "$child_slot_retain_verdict" ]; then
        teardown_meta_backup_restore "$child_meta" || true
      fi
      return 1
    fi
    if [ -n "$child_slot_retain_verdict" ]; then
      fm_slot_lock_acquire "$child_wt" || {
        teardown_meta_backup_restore "$child_meta" || true
        echo "error: could not serialize ownership cleanup for child $child_id; preserving child state" >&2
        return 1
      }
      child_slot_lock_path=$FM_SLOT_LOCK_PATH
      if ! fm_slot_stamp_relinquish "$child_wt" "$child_id" "$child_slot_retain_verdict"; then
        fm_slot_lock_release "$child_slot_lock_path" || true
        teardown_meta_backup_restore "$child_meta" || true
        echo "error: could not relinquish the ownership stamp for child $child_id; preserving child state" >&2
        return 1
      fi
      if ! fm_slot_lock_release "$child_slot_lock_path"; then
        teardown_meta_backup_restore "$child_meta" || true
        return 1
      fi
      teardown_meta_backup_discard || true
    fi
  done
}

remove_secondmate_registry_entry() {
  local id=$1 tmp
  [ -f "$SECONDMATE_REG" ] || return 0
  tmp="$SECONDMATE_REG.tmp.$$"
  grep -vE "^- $id( |$)" "$SECONDMATE_REG" > "$tmp" || true
  mv "$tmp" "$SECONDMATE_REG"
}

if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  if [ "$TOP_SLOT_RETURNED" != 1 ]; then
    validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" >/dev/null || exit 1
    if [ "$FORCE" = "--force" ]; then
      validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
    fi
  fi
  if fm_pending_reply_task_has_open "$STATE" "$ID"; then
    FORCE_RETIRE_SOURCE=$(fm_pending_reply_source_identity "$STATE") || exit 1
    if [ "$FORCE" = "--force" ] \
       && fm_pending_reply_stage_force_retire_task "$STATE" "$ID"; then
      FORCE_RETIRE_STAGED=1
    else
      echo "REFUSED: secondmate $ID still has an open pending reply in $STATE/pending-replies." >&2
      echo "Wait for a correlated report or escalation before captain-approved forced teardown." >&2
      exit 1
    fi
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" != "--force" ] \
   && [ "$TOP_SLOT_RETURNED" != 1 ]; then
  SUB_STATE="$HOME_PATH/state"
  if [ -d "$SUB_STATE" ]; then
    for child_meta in "$SUB_STATE"/*.meta; do
      [ -e "$child_meta" ] || continue
      echo "REFUSED: secondmate $ID still has in-flight work in $SUB_STATE." >&2
      echo "Found $(basename "$child_meta"). Let that home finish or explicitly discard with --force." >&2
      exit 1
    done
  fi
fi

if [ -d "$WT" ] && [ "$FORCE" != "--force" ] \
   && [ "$TOP_SLOT_RETURNED" != 1 ]; then
  if [ "$KIND" = secondmate ]; then
    :
  elif [ "$KIND" = scout ]; then
    # Scout worktrees are scratch by contract, but only once the deliverable exists.
    REPORT="$DATA/$ID/report.md"
    if [ ! -f "$REPORT" ]; then
      echo "REFUSED: scout task $ID has no report at $REPORT." >&2
      echo "The report is the work product. Have the crewmate write it (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
  else
    # The fm-spawn hook file is ours, never work product; ignore it in the dirty check.
    dirty=$(git -C "$WT" status --porcelain 2>/dev/null | grep -vE '^\?\? (\.claude/|\.fm-grok-turnend$)' | head -1 || true)
    # Reachability test: is HEAD reachable from ANY remote-tracking branch? Empty
    # means the work is already pushed (a fork is a remote too, so upstream-
    # contribution PRs pushed to a fork pass here). Non-empty does NOT prove the work
    # is unlanded: a squash or rebase merge rewrites the branch into a new commit on
    # the default branch, and a repo that auto-deletes the head branch on merge also
    # drops its remote-tracking ref - so a merged-and-deleted branch trips this test
    # while being fully landed. We therefore treat reachability as a fast accept, not
    # the sole verdict, and fall through to a landed-work check before refusing.
    unpushed=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null | head -5 || true)
    if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
      # local-only ships have no remote in the common case, so the "on a remote"
      # test above is expected to be non-empty. The work is safe once it is merged
      # into the local default branch (firstmate does that merge on the captain's
      # approval). Refuse until then.
      DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; exit 1; }
      unmerged=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null | head -5 || true)
      if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
        echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
        [ -n "$dirty" ] && echo "uncommitted changes present" >&2
        [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
        echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
        exit 1
      fi
    elif [ -n "$dirty" ]; then
      # Uncommitted changes are never landed and the reset would discard them; always
      # refuse, regardless of whether the committed work itself has landed.
      echo "REFUSED: worktree $WT has uncommitted changes." >&2
      echo "uncommitted changes present" >&2
      echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    elif [ -n "$unpushed" ]; then
      # Commits not reachable from any remote. Before refusing, recognize LANDED work:
      # a merged PR whose head contains the current local work, or content already in
      # the up-to-date default branch. On a gh lookup error work_is_landed falls back
      # to the content check, and if that is also inconclusive it returns false - so
      # we never silently allow teardown of possibly-unlanded work; only genuinely
      # unlanded work is refused.
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      if ! work_is_landed "$branch"; then
        echo "REFUSED: worktree $WT has work not on any remote and not landed." >&2
        printf 'unpushed commits:\n%s\n' "$unpushed" >&2
        echo "Push the branch, land its PR, or get the captain's explicit OK to discard, then --force." >&2
        exit 1
      fi
    fi
  fi
fi

validate_pr_poll_cleanup "$STATE" "$ID" || exit 1
validate_direct_pr_state_cleanup || exit 1
validate_direct_pr_ref_cleanup || exit 1

HERDR_PRESENTATION_JOURNAL="$STATE/$ID.herdr-presentation"
HERDR_PRESENTATION_RETIRE_CANDIDATE=0
HERDR_PRESENTATION_WORKSPACE=
  if [ "$TOP_SLOT_RETURNED" != 1 ] && [ "$BACKEND" = herdr ]; then
  fm_backend_source herdr || {
    echo "REFUSED: could not load Herdr teardown support for $ID; preserving task state and worktree" >&2
    exit 1
  }
  fm_backend_herdr_parse_target "$T" || {
    echo "REFUSED: invalid Herdr target $T for $ID; preserving task state and worktree" >&2
    exit 1
  }
fi
if [ "$TOP_SLOT_RETURNED" != 1 ] && [ "$BACKEND" = herdr ] \
   && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  HERDR_META_SESSION=$(meta_value "$META" herdr_session)
  HERDR_PRESENTATION_WORKSPACE=$(meta_value "$META" herdr_workspace_id)
  HERDR_META_PANE=$(meta_value "$META" herdr_pane_id)
  if [ -n "$HERDR_META_SESSION" ] \
     && [ -n "$HERDR_PRESENTATION_WORKSPACE" ] \
     && [ -n "$HERDR_META_PANE" ] \
     && [ "$T" = "$HERDR_META_SESSION:$HERDR_META_PANE" ]; then
    if fm_backend_herdr_projection_endpoint_matches_journal \
      "$HERDR_META_SESSION" "$HERDR_PRESENTATION_WORKSPACE" \
      "$HERDR_PRESENTATION_JOURNAL" "$ID"; then
      HERDR_PRESENTATION_RETIRE_CANDIDATE=1
    fi
  fi
fi

# Prove pooled-slot occupancy against the exact task endpoint before closing it.
# A live endpoint must provide stable pid/start-time/cwd/identity proof. Once the
# endpoint is gone, a complete same-user process census catches reparented or
# undeclared workers; an incomplete proof retains the lease.
teardown_slot_endpoint_state() {
  local backend=$1 target=$2 state
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)
  case "$state" in
    dead|missing|no-agent) printf 'closed' ;;
    alive) printf 'live' ;;
    *) printf 'unknown' ;;
  esac
}

TOP_SLOT_RELEASE_AUTHORIZED=0
TOP_SLOT_RETAIN_VERDICT=
TOP_SLOT_ENDPOINT_STATE=closed
TOP_SLOT_LOCK_HELD=0
TOP_SLOT_LOCK_PATH=
HERDR_PRESENTATION_LOCK_HELD=0
HERDR_PRESENTATION_LOCK_PATH=
teardown_release_top_slot_lock() {
  if [ "$TOP_SLOT_LOCK_HELD" = 1 ]; then
    fm_slot_lock_release "$TOP_SLOT_LOCK_PATH" || return 1
    TOP_SLOT_LOCK_HELD=0
  fi
}
trap 'teardown_release_task_lock || true; teardown_release_top_slot_lock || true; teardown_release_home_child_lock || true; teardown_release_herdr_presentation_lock || true' EXIT
if [ "$TOP_SLOT_RETURNED" != 1 ] && [ "$BACKEND" = herdr ]; then
  teardown_acquire_herdr_presentation_lock "$T" || {
    echo "REFUSED: could not acquire the Herdr presentation lock for $ID; preserving task state and worktree" >&2
    exit 1
  }
fi
if [ "$KIND" != secondmate ]; then
  if [ "$TOP_SLOT_RETURNED" = 1 ]; then
    if fm_slot_stamp_path "$WT" >/dev/null 2>&1; then
      fm_slot_lock_acquire "$WT" || {
        echo "error: could not serialize cleanup for returned worktree $WT; preserving task state" >&2
        exit 1
      }
      TOP_SLOT_LOCK_PATH=$FM_SLOT_LOCK_PATH
      TOP_SLOT_LOCK_HELD=1
    fi
    TOP_SLOT_RELEASE_AUTHORIZED=1
  elif [ "$TOP_SLOT_UNRESOLVED_LEASE" = 1 ]; then
    # A spawn that leased a pooled slot but never resolved its path recorded the
    # lease holder instead of a fabricated worktree. There is no slot to gate,
    # prove, or return here: the lease stays held (fail-closed) and traceable,
    # while the endpoint and records still retire so one aborted spawn cannot
    # make the task permanently untearable.
    TEARDOWN_SLOT_RETAINED=1
    echo "teardown: task $ID never resolved a pooled slot path; its durable treehouse lease is RETAINED, not returned." >&2
    echo "teardown: RECLAIM: run 'treehouse list' to find the slot leased to ${TOP_SLOT_LEASE_HOLDER:-$ID}${TOP_SLOT_WT_CANDIDATE:+ (spawn saw candidate path $TOP_SLOT_WT_CANDIDATE)} and return it with 'treehouse return --force <slot>'; docs/worker-isolation.md owns the reclaim path." >&2
  else
    if fm_slot_stamp_path "$WT" >/dev/null 2>&1; then
      fm_slot_lock_acquire "$WT" || {
        echo "error: could not serialize teardown for worktree $WT; preserving task state" >&2
        exit 1
      }
      TOP_SLOT_LOCK_PATH=$FM_SLOT_LOCK_PATH
      TOP_SLOT_LOCK_HELD=1
    fi
    # The endpoint is proved from the backend, not from the recorded worktree.
    # A worktree that is already gone still retains its lease through the
    # verdict below; assuming an unknown endpoint for it would only make such a
    # task permanently untearable.
    TOP_SLOT_ENDPOINT_STATE=$(teardown_slot_endpoint_state "$BACKEND" "$T")
    if slot_release_allowed "$STATE" "$ID" "$WT" "$FM_HOME" \
      "worktree" retire "$TOP_SLOT_ENDPOINT_STATE" "$BACKEND" "$T" \
      "$FM_HOME" crewmate; then
      TOP_SLOT_RELEASE_AUTHORIZED=1
    else
      TOP_SLOT_RETAIN_VERDICT=$TEARDOWN_SLOT_RETAIN_VERDICT
    fi
    if [ "$TOP_SLOT_ENDPOINT_STATE" = unknown ]; then
      slot_release_allowed "$STATE" "$ID" "$WT" "$FM_HOME" \
        "worktree" refuse "$TOP_SLOT_ENDPOINT_STATE" "$BACKEND" "$T" \
        "$FM_HOME" crewmate || {
        echo "REFUSED: exact endpoint occupancy for $ID could not be proved; preserving task state, worktree, and lease" >&2
        exit 1
      }
    fi
  fi
fi

if [ "$BACKEND" = herdr ]; then
  # Same resume gate as the other endpoint branches: a prior run that already
  # returned the slot also already closed this pane, so re-closing it would
  # refuse on a pane that is legitimately gone and leave the task unfinishable.
  if [ "$TOP_SLOT_RETURNED" != 1 ] && ! teardown_herdr_endpoint_focus_safe "$T"; then
    echo "REFUSED: exact focus-safe Herdr task-pane close could not be confirmed for $ID; preserving task state and worktree" >&2
    exit 1
  fi
  if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
    rm -f "$HERDR_PRESENTATION_JOURNAL"
  elif [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; then
    echo "warning: herdr presentation journal for $ID remains quarantined; no workspace cleanup was attempted" >&2
  fi
elif [ "$TOP_SLOT_RETURNED" != 1 ] && [ "$BACKEND" != orca ]; then
  if ! teardown_backend_endpoint "$BACKEND" "$T" 2>/dev/null; then
    echo "REFUSED: could not kill task $ID window $T; refusing to delete task state or worktree" >&2
    exit 1
  fi
fi

if [ "$KIND" != secondmate ] \
   && [ "$TOP_SLOT_RETURNED" != 1 ] \
   && [ "$TOP_SLOT_RELEASE_AUTHORIZED" -eq 1 ]; then
  if ! slot_release_allowed "$STATE" "$ID" "$WT" "$FM_HOME" \
    "worktree" retire closed "" "" "$FM_HOME" crewmate; then
    TOP_SLOT_RETAIN_VERDICT=$TEARDOWN_SLOT_RETAIN_VERDICT
    TOP_SLOT_RELEASE_AUTHORIZED=0
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" = "--force" ]; then
  if ! cleanup_firstmate_home_children "$HOME_PATH"; then
    echo "REFUSED: child cleanup failed for secondmate $ID; preserving parent state and home" >&2
    exit 1
  fi
fi

# Ownership gate first. A retained lease leaves the slot untouched while the
# rest of teardown retires this task's endpoint and records.
if [ "$KIND" != secondmate ] \
   && [ "$TOP_SLOT_RELEASE_AUTHORIZED" -eq 1 ]; then
  if [ "$TOP_SLOT_RETURNED" = 1 ]; then
    fm_slot_stamp_clear_after_return "$WT" "$ID" "$FM_HOME" || {
      echo "error: could not clear the ownership stamp for returned worktree $WT; preserving task state" >&2
      exit 1
    }
  elif [ -d "$WT" ]; then
    teardown_grok_pointer_valid "$WT" "$STATE" "$ID" || {
      echo "REFUSED: task $ID has an unsafe Grok turn-end pointer; preserving task state and worktree" >&2
      exit 1
    }
    TOP_TASK_BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    # Remove our hook file so a reused pool worktree cannot fire signals for a dead task.
    rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js"
    [ ! -e "$WT/.fm-grok-turnend" ] || rm -f -- "$WT/.fm-grok-turnend"
    teardown_meta_mark_slot_returning "$META" || {
      echo "error: could not record pending return for worktree $WT; preserving task state" >&2
      exit 1
    }
    teardown_treehouse_return "$WT" "$PROJ" "worktree" || {
      echo "error: treehouse return failed for worktree $WT; teardown aborted" >&2
      teardown_slot_return_recover "$META" "$WT" "$ID" "worktree" || true
      exit 1
    }
    teardown_meta_identity_matches || {
      echo "error: task metadata changed during teardown for $ID; preserving task state" >&2
      exit 1
    }
    teardown_meta_mark_slot_returned "$META" || {
      echo "error: could not record successful return for worktree $WT; preserving task state" >&2
      teardown_slot_returning_recovery_line "$META" "$WT" "$ID"
      exit 1
    }
    TOP_SLOT_RETURNED=1
    teardown_retire_task_branch "$WT" "$PROJ" "$TOP_TASK_BRANCH"
    fm_slot_stamp_clear_after_return "$WT" "$ID" "$FM_HOME" || {
      echo "error: could not clear the ownership stamp for worktree $WT; preserving task state" >&2
      exit 1
    }
  fi
fi

if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  remove_firstmate_home "$HOME_PATH" "secondmate home" "$ID" || exit 1
  if [ "$FORCE_RETIRE_STAGED" = 1 ] \
     && ! fm_pending_reply_finalize_force_retire_task \
       "$STATE" "$ID" "$STATE" "$FORCE_RETIRE_SOURCE"; then
    echo "error: secondmate $ID was removed but its pending-reply handoff could not be finalized" >&2
    exit 1
  fi
  remove_secondmate_registry_entry "$ID"
fi
remove_grok_turnend_auth "$STATE" "$ID" || {
  echo "REFUSED: could not prove task $ID Grok registry ownership; preserving task state" >&2
  exit 1
}
# Remove the per-task temp root recorded by spawn.
# Read before the state-file rm below; empty (pre-fix tasks without tasktmp=) is a no-op.
[ -n "$TASK_TMP_CLEANUP" ] && rm -rf -- "$TASK_TMP_CLEANUP"
remove_pr_poll_artifacts "$STATE" "$ID" || exit 1
cleanup_direct_pr_refs || {
  echo "REFUSED: transactional direct-PR private ref cleanup failed for $ID; preserving task state" >&2
  exit 1
}
if [ -n "$TOP_SLOT_RETAIN_VERDICT" ]; then
  teardown_meta_identity_matches || {
    echo "error: task metadata changed during teardown for $ID; preserving task state" >&2
    exit 1
  }
  teardown_meta_backup_create "$META" || {
    echo "error: could not preserve recovery metadata for $ID" >&2
    exit 1
  }
fi
teardown_meta_identity_matches || {
  [ -z "${TEARDOWN_META_BACKUP:-}" ] || teardown_meta_backup_discard || true
  echo "error: task metadata changed during teardown for $ID; preserving task state" >&2
  exit 1
}
if ! rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.meta" \
  "$STATE/$ID.pi-ext.ts" "$STATE/$ID.grok-turnend-token" \
  "$STATE/$ID.direct-pr-lease" "$STATE/$ID.direct-pr-lease.tmp"; then
  if [ -n "$TOP_SLOT_RETAIN_VERDICT" ]; then
    teardown_meta_backup_restore "$META" || true
  fi
  echo "error: could not remove task records for $ID; ownership evidence was preserved" >&2
  exit 1
fi
if [ -n "$TOP_SLOT_RETAIN_VERDICT" ]; then
  # A slot whose directory is gone has no stamp to serialize against; demanding
  # a lock on it would strand the record this teardown already retired.
  if [ "$TOP_SLOT_LOCK_HELD" != 1 ] && fm_slot_stamp_path "$WT" >/dev/null 2>&1; then
    fm_slot_lock_acquire "$WT" || {
      teardown_meta_backup_restore "$META" || true
      echo "error: could not serialize ownership cleanup for $ID; preserving task state" >&2
      exit 1
    }
    TOP_SLOT_LOCK_PATH=$FM_SLOT_LOCK_PATH
    TOP_SLOT_LOCK_HELD=1
  fi
  if ! fm_slot_stamp_relinquish "$WT" "$ID" "$TOP_SLOT_RETAIN_VERDICT"; then
    teardown_meta_backup_restore "$META" || true
    echo "error: could not relinquish the ownership stamp for $ID; preserving task state" >&2
    exit 1
  fi
  teardown_meta_backup_discard || true
fi
teardown_release_top_slot_lock || {
  echo "error: could not release the ownership lock for $ID" >&2
  exit 1
}
teardown_release_herdr_presentation_lock || {
  echo "error: could not release the Herdr presentation lock for $ID" >&2
  exit 1
}
if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
if [ "$TOP_SLOT_UNRESOLVED_LEASE" = 1 ]; then
  echo "teardown $ID complete (window $T, no pooled slot path was ever resolved - its treehouse lease is still held by ${TOP_SLOT_LEASE_HOLDER:-$ID} and needs the reclaim above)"
elif [ "$TEARDOWN_SLOT_RETAINED" = 1 ]; then
  echo "teardown $ID complete (window $T, worktree $WT retained on disk - its lease was retired, not returned)"
else
  echo "teardown $ID complete (window $T, worktree $WT)"
fi
backlog_refresh_reminder
