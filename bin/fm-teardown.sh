#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree, release the Orca
# worktree, or retire a secondmate home; kill the recorded runtime endpoint,
# clear volatile state, and transition this home's backlog item for ship and
# scout tasks before reporting success (a secondmate teardown transitions none,
# since secondmates are not backlog items), then refresh/prune the project's
# clone for PR-based ship tasks.
# Removing state/<id>.meta and landing the backlog transition are one step, not
# two: bin/fm-backlog-transition-lib.sh owns that invariant, and both halves run
# under the task's own meta lock before this script reports success. Because the
# completion links (the PR, the report path, a local-main note) live only in the
# record being removed, the intended transition is recorded in
# state/<id>.backlog-close first, so a process killed between the halves leaves
# the next session start enough to finish it; a landed transition removes that
# record. A transition that fails is fatal and loud, preserves its pending-close
# record, and is retried by the next session start. The transition is skipped on a
# config/backlog-backend=manual home and in a home that keeps no
# data/backlog.md; those cases print the manual follow-up. An automatic-backend
# home with a backlog but no compatible tasks-axi refuses before cleanup.
# None of this loosens the landed-work gates below: the transition runs only on
# the paths that already proceed to remove the record.
# The close - and only the close - is replaced by `tasks-axi reopen` with the
# deliverable recorded while the backlog item is still an open captain call
# (bin/fm-captain-hold.sh `open` owns that predicate), because the policy holds
# the very work item a question gates and cleanup must never retire the
# captain's own question. The same pending-close record carries that intent as
# `mode=retain`, so an interrupted cleanup replays the retention rather than a
# close. "Cannot tell" refuses before any destructive step, --force does not
# lift the deferral (it authorizes discarding unlanded WORK, never the
# captain's question), and bin/fm-captain-hold.sh answer stays the only act
# that closes the call.
# REFUSES if the worktree holds work that has not LANDED, because cleanup
# hard-resets/removes the worktree and kills its processes. Work has landed when it is
# reachable from any remote-tracking branch (a fork counts as a remote, so
# upstream-contribution PRs pushed to a fork satisfy this in any mode), OR - for a
# normal ship task whose commits are not so reachable - when its PR is merged and
# GitHub reports a PR head that contains the current local work, or its content is
# already present in the up-to-date default branch. This recognizes the common
# squash-merge-then-delete-branch flow, where the branch's own commits live nowhere
# on a remote yet the change is fully in main.
# Squash merges collapse the branch's commits, so per-commit patch ids against main
# no longer match, and a pipeline rebase can leave the local worktree diverged from
# the PR head. A diverged copy is not treated as landed: path-set coverage, git
# cherry, and merge-tree containment each fail to prove content landed without also
# accepting unlanded edits to the same paths. Teardown still accepts a merged PR
# whose head contains the current local work (ancestor or equivalent patch ids),
# or a clean content-in-default tree match. Anything else refuses.
# The PR itself is resolved from the task's recorded pr= when present, or - when
# no pr= was ever recorded (e.g. a yolo-authorized merge on a repo with no PR CI,
# where the usual "checks green" fm-pr-check.sh trigger never fires) - by looking
# up a merged PR whose head branch matches the worktree's branch, fetching its head
# via refs/pull/<n>/head when the branch itself was deleted. So a missing pr= never
# by itself causes a false refusal of landed work.
# A gh lookup error falls back to the content check; if that is also inconclusive,
# teardown refuses rather than risk discarding unlanded work.
# Uncommitted changes are never landed.
# local-only projects additionally accept work merged into the local default
# branch (firstmate performs that merge after configured approval) as a fallback
# for the common case where there is no remote at all.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product. Teardown proceeds only once the report exists and the shared
# unresolved-decision completion gate verifies its captain-held inventory.
# Before destructive cleanup, teardown validates task check artifacts as
# ordinary single-link files on the state device. It refuses and preserves
# task state when that proof fails; otherwise it removes the task's check,
# trust record, PR sidecar, and publication record with the rest of the
# volatile state.
# Worktree-slot ownership (teardown-slot-collision): a treehouse pool slot is
# reused across tasks, so a stale, duplicated, or drifted worktree= record can
# name a slot a DIFFERENT live task now holds. Cleanup kills every process under
# that path and hard-resets it before returning it, so releasing a slot that is
# not genuinely this task's destroys another worker's live work. Before the first
# cleanup step, teardown verifies record exclusivity: no OTHER task record in
# this home or any locally registered Firstmate home may name the same live path
# in its worktree= or home=. One live path with two task records is the reuse
# collision itself, whichever record is stale. The recorded endpoint's exact
# task identity and the record's spawn incarnation are validated separately
# before cleanup. Its current working directory is only incidental process
# state: the same worker remains the owner after changing directory, so cwd can
# never veto teardown of that exact recorded endpoint.
# The scan and destructive return hold a project-identity lock in the local root
# Firstmate home's state directory, as resolved by bin/fm-wake-lib.sh's
# fm_firstmate_root_home; a home seeded from another machine is its own local
# root, since a lock on this filesystem cannot be held or observed across that
# boundary. Fresh Treehouse spawns for that project in
# every local Firstmate home hold the same lock from before slot allocation
# through metadata publication, closing the publication
# gap; forced secondmate teardown takes it and runs the same checks for every
# descendant Treehouse slot before touching any child.
# This refusal is not relaxed by --force: --force authorizes discarding THIS
# task's unlanded work, never another task's live work. Reconcile whichever
# record is wrong and re-run. Orca is not a pool slot and proves its path through
# require_orca_worktree_path_match instead.
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
# is the approved discard path that prevalidates child removal targets, locks each
# descendant home's task set before enumeration, and holds those locks through
# child cleanup. Contention refuses the complete forced teardown before child
# mutation. Local and remote retirement serialize their destructive phase with
# that mate's backlog-handoff lock under the registry lock. Pending handoff wake
# state is retired with the home, and local removal failure restores that state
# before preserving the route for retry. Teardown then discards child work, kills
# child runtime endpoints, and removes the retired home. Removing a leased home
# releases its durable treehouse lease so the pool slot is freed,
# never left leased forever. If the treehouse return fails, teardown leaves the
# leased home and state in place instead of hiding a still-held lease.
# Usage: fm-teardown.sh <task-id> [--force] [--legacy-record]
#   --force skips ordinary-task dirty and landed-work checks, skips scout report
#   checks, and discards secondmate child work for kind=secondmate. Only use it
#   when the captain has explicitly said to discard the work.
#   --legacy-record accepts a task record that predates the spawn_gen field:
#   teardown then proceeds only when the recorded endpoint is confirmed dead or
#   agent-less (bin/fm-backend.sh's recovery-grade classifier), and without
#   --force the worktree still passes the ordinary landed-work checks. The
#   accepted legacy incarnation is stamped into the record before its close is
#   recorded and named in the teardown line; the flag never relaxes the
#   unlanded-work refusal, which --force alone can authorize. A legacy- stamp
#   an abandoned attempt left behind never counts as a published incarnation:
#   the record still reads as a legacy record, so the endpoint gate runs again
#   and the retry still needs --legacy-record.
#
# Transient / stale worktree git lock recovery (teardown-lock-race): a crew process
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
#
# Pre-teardown cleanup sequence (runs once every landed/discard-work safety
# refusal above has already passed, and BEFORE any worktree return, branch
# delete, or backend kill below - a still-active run or a leaked process may
# own live work in that worktree):
#   Fix 1 - conclude the task's own no-mistakes run. A ship task's worktree can
#     be torn down while its no-mistakes pipeline run is still PARKED at a gate
#     (awaiting_approval/fix_review/any awaiting_agent field), with no worker
#     left to ever answer it - the run then sits there holding a fleet slot
#     indefinitely (observed 2026-08-03: runs parked 7h39m and parked at a
#     post-CI approval gate after the worker was already cleaned up). A run
#     with an autonomous step still under way (running/fixing/ci) is left
#     alone: no-mistakes drives those against its own gate-repo clone, not the
#     crew's worktree, so they are not orphaned by removing the worktree.
#     conclude_task_no_mistakes_run attributes the active-or-most-recent run to
#     THIS task only when its branch AND code identity (bin/fm-nm-run-lib.sh's
#     strict fm_nm_head_matches_worktree rule) both match this worktree, then
#     runs `no-mistakes axi abort --run <id>` for that verified run instance.
#     When the run head is absent from this copy's object store - the pipeline
#     committed its fix round in its own repo and the task copy never fetched
#     it - attribution falls to the same lib's shared
#     fm_nm_runs_status_for_worktree ledger rule, whose anchored continuation
#     recognition is the only remaining path, which refuses every row shape
#     it cannot prove, and which authorizes the abort only for an explicitly
#     active (`running`) proved continuation - a terminal newest word is
#     finished history, never an abort authorization (observed 2026-09-03: a
#     run parked at a post-CI gate after fix rounds advanced its head past
#     the submitted head stayed parked forever once the task was cleaned up).
#     A run already terminal
#     (an outcome is set) or not parked at a gate is left untouched. Idempotent:
#     an already-aborted run reads back terminal and is skipped on retry.
#   Fix 2 - reap leaked descendant processes. A backgrounded/disowned process
#     started under the worktree (or its per-task tasktmp) does not receive the
#     SIGHUP/SIGTERM that closing the backend pane sends to its own foreground
#     process group, so it survives reparented to init (observed 2026-08-03:
#     two `go test` binaries, deadlines blown past by ~100x, pinning CPU for
#     hours with no live task meta to attribute them to once teardown had
#     already removed it). reap_task_worktree_processes finds every process
#     whose CURRENT WORKING DIRECTORY is this task's own worktree or tasktmp
#     root via `lsof -a -d cwd` (cheap: bounded by process count, not by
#     walking the worktree's file tree) and sends TERM, then KILL after a short
#     grace period to any survivor whose process identity still matches. Both
#     roots are unique per task and never
#     shared, so this can never reach another task's or the primary's
#     processes. Idempotent: nothing left to find is a silent no-op.
#   Fix 3 - sweep abandoned remote job workers. A remote job worker started
#     from a worktree's own bin/ outlives that worktree's removal without
#     being reachable by Fix 2, because its working directory is wherever it
#     was launched rather than the task worktree (observed 2026-08-07: 29
#     workers at ppid 1, 1-2 days old, each still polling and appending to a
#     log in a pruned no-mistakes gate worktree). bin/fm-remote-job-reap-orphans.sh
#     owns that sweep and its safety rule; it never touches a worker whose code
#     root still exists, so the account's healthy LaunchAgent worker and every
#     live remote secondmate worker are out of scope. Best effort: a sweep
#     failure never blocks this teardown.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECONDMATE_REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
SUB_HOME_PARENT_MARKER=".fm-secondmate-parent"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-treehouse-lib.sh
. "$SCRIPT_DIR/fm-treehouse-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
if [ "$#" -lt 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "error: invalid teardown request" >&2
  exit 2
fi
ID=$1
FORCE=
LEGACY_RECORD_GIVEN=0
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=--force ;;
    --legacy-record) LEGACY_RECORD_GIVEN=1 ;;
    *)
      echo "error: invalid teardown request" >&2
      exit 2
      ;;
  esac
  shift
done
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: teardown refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Supervision lease guard: post-landing cleanup is overlap territory between
# the two Pi supervision actors; refuse while the OTHER actor holds this
# task's live lease (contract: bin/fm-lease-lib.sh; no-op in homes without
# leases).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# Role partition: forced teardown discards work, and the supervision branch
# never discards anything - only an ordinary landed-work teardown is branch
# territory (contract: bin/fm-lease-lib.sh).
if [ "$FORCE" = --force ] && [ "$(fm_lease_actor)" = branch ]; then
  echo "error: forced teardown refused - the supervision branch cannot discard work" >&2
  exit "$FM_LEASE_REFUSE_EXIT"
fi
fm_lease_guard "$ID" "teardown (fm-teardown)"

# A Treehouse slot has the managed pool's fixed <pool>/<slot>/<repo> layout.
# Require both its pool state and the same Git common directory as the recorded
# project; an ordinary linked worktree is not evidence that Treehouse owns it.
is_treehouse_pool_slot() {  # <project> <worktree>
  local project=$1 worktree=$2 slot pool state project_common slot_common
  [ -d "$project" ] && [ -d "$worktree" ] || return 1
  slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || return 1
  pool=$(dirname "$(dirname "$slot")")
  state="$pool/treehouse-state.json"
  [ -f "$state" ] && [ ! -L "$state" ] || return 1
  project_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  slot_common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  project_common=$(CDPATH='' cd -- "$project_common" 2>/dev/null && pwd -P) || return 1
  slot_common=$(CDPATH='' cd -- "$slot_common" 2>/dev/null && pwd -P) || return 1
  [ "$project_common" = "$slot_common" ]
}

META="$STATE/$ID.meta"
TREEHOUSE_PROJECT_LOCK=
TREEHOUSE_PROJECT_LOCK_HELD=0
TREEHOUSE_SLOT_LOCK_REQUIRED=0
if [ -f "$META" ] && [ ! -L "$META" ]; then
  TEARDOWN_LOCK_KIND=$(fm_meta_get "$META" kind)
  [ -n "$TEARDOWN_LOCK_KIND" ] || TEARDOWN_LOCK_KIND=ship
  TEARDOWN_LOCK_BACKEND=$(fm_meta_get "$META" backend)
  [ -n "$TEARDOWN_LOCK_BACKEND" ] || TEARDOWN_LOCK_BACKEND=tmux
  TEARDOWN_LOCK_WT=$(fm_meta_get "$META" worktree)
  TEARDOWN_LOCK_PROJECT=$(fm_meta_get "$META" project)
  if [ "$TEARDOWN_LOCK_KIND" != secondmate ] \
     && [ "$TEARDOWN_LOCK_BACKEND" != orca ] \
     && is_treehouse_pool_slot "$TEARDOWN_LOCK_PROJECT" "$TEARDOWN_LOCK_WT"; then
    TREEHOUSE_SLOT_LOCK_REQUIRED=1
    TREEHOUSE_PROJECT_LOCK=$(fm_treehouse_project_lock_path "$TEARDOWN_LOCK_PROJECT") || {
      echo "REFUSED: cannot resolve the shared Treehouse project lock for ${TEARDOWN_LOCK_PROJECT:-<missing>}; nothing was changed" >&2
      exit 1
    }
    fm_lock_try_acquire "$TREEHOUSE_PROJECT_LOCK" || {
      echo "REFUSED: another Treehouse slot allocation or return is in progress for $TEARDOWN_LOCK_PROJECT; nothing was changed" >&2
      exit 1
    }
    TREEHOUSE_PROJECT_LOCK_HELD=1
  fi
fi
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
DESCENDANT_LOCK_PATHS=()
DESCENDANT_TASK_STATES=()
DESCENDANT_TASK_IDS=()
DESCENDANT_TASK_KINDS=()
DESCENDANT_TASK_HOMES=()
DESCENDANT_TREEHOUSE_LOCK_PATHS=()
teardown_release_locks() {
  local status=$? i
  if declare -F teardown_release_herdr_locks >/dev/null 2>&1; then
    teardown_release_herdr_locks || true
  fi
  for ((i=${#DESCENDANT_LOCK_PATHS[@]} - 1; i >= 0; i--)); do
    fm_lock_release "${DESCENDANT_LOCK_PATHS[$i]}" || true
  done
  DESCENDANT_LOCK_PATHS=()
  if [ -n "${HANDOFF_WAKE_RETIRE_LOCK:-}" ]; then
    fm_lock_release "$HANDOFF_WAKE_RETIRE_LOCK" || true
    HANDOFF_WAKE_RETIRE_LOCK=
  fi
  if [ -n "${LOCAL_HANDOFF_LOCK:-}" ]; then
    fm_lock_release "$LOCAL_HANDOFF_LOCK" || true
    LOCAL_HANDOFF_LOCK=
  fi
  if [ -n "${LOCAL_REGISTRY_LOCK:-}" ]; then
    fm_lock_release "$LOCAL_REGISTRY_LOCK" || true
    LOCAL_REGISTRY_LOCK=
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CONTROL_LOCK" || true
    CONTROL_LOCK_HELD=0
  fi
  if [ "$TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
    fm_lock_release "$TREEHOUSE_PROJECT_LOCK" || true
    TREEHOUSE_PROJECT_LOCK_HELD=0
  fi
  fm_lease_guard_release || true
  return "$status"
}
trap teardown_release_locks EXIT
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
# Fail closed before any fleet mutation: a no-mistakes gate agent must never tear
# down a worktree (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
FM_LOCK_LOG_PREFIX=teardown

fm_backlog_record_present "$META" "task record" "$STATE" || {
  echo "error: teardown refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
fm_backlog_record_present "$META" "task record" "$STATE" || {
  echo "error: teardown refused after locking: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
TEARDOWN_META_KIND=$(fm_meta_get "$META" kind)
[ -n "$TEARDOWN_META_KIND" ] || TEARDOWN_META_KIND=ship
TEARDOWN_CLEANUP_RECOVERY=$(fm_meta_get "$META" cleanup_recovery)
TEARDOWN_META_SPAWN_GEN=
TEARDOWN_LEGACY_PENDING=0
TEARDOWN_LEGACY_ACCEPTED=0
TEARDOWN_LEGACY_ENDPOINT=
TEARDOWN_LEGACY_RETAINED_STAMP=
TEARDOWN_LEGACY_PRESTAMP_SIZE=0
TEARDOWN_BACKLOG_APPLIES=0
TEARDOWN_BACKLOG_SKIP_REASON=
if [ "$TEARDOWN_CLEANUP_RECOVERY" != orca ]; then
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$TEARDOWN_META_KIND"; then
    TEARDOWN_BACKLOG_APPLIES=1
  else
    TEARDOWN_BACKLOG_GATE_STATUS=$?
    if [ "$TEARDOWN_BACKLOG_GATE_STATUS" -eq 2 ]; then
      echo "error: task $ID cannot be torn down because its backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      exit 1
    fi
    TEARDOWN_BACKLOG_SKIP_REASON=$FM_BACKLOG_TRANSITION_SKIP
  fi
fi
if [ "$TEARDOWN_BACKLOG_APPLIES" = 1 ]; then
  if ! fm_backlog_meta_spawn_gen "$META" "$STATE"; then
    TEARDOWN_LEGACY_GEN_COUNT=$(LC_ALL=C awk -F= '$1 == "spawn_gen" { count++ } END { print count + 0 }' "$META" 2>/dev/null || printf '0\n')
    if [ "$TEARDOWN_LEGACY_GEN_COUNT" = 0 ] && [ "$LEGACY_RECORD_GIVEN" = 1 ]; then
      # A record that predates the incarnation field: acceptance is gated later,
      # once the recorded endpoint is known, so its state can be confirmed dead
      # or agent-less before any cleanup decision is made.
      TEARDOWN_LEGACY_PENDING=1
    elif [ "$TEARDOWN_LEGACY_GEN_COUNT" = 0 ]; then
      echo "error: task $ID's record has no spawn_gen that identifies one exact incarnation ($FM_BACKLOG_TRANSITION_ERROR); refusing automatic teardown - relaunch the task to publish an unambiguous incarnation, then retry teardown, or pass --legacy-record once its recorded endpoint is confirmed dead or agent-less" >&2
      exit 1
    else
      echo "error: task $ID's record has an unreadable spawn_gen that identifies one exact incarnation ($FM_BACKLOG_TRANSITION_ERROR); refusing automatic teardown - fix the record, then retry teardown" >&2
      exit 1
    fi
  else
    case "$FM_BACKLOG_META_SPAWN_GEN" in
      legacy-*)
        # Only this teardown path mints a legacy- token; a launch publishes
        # s<epoch>.<pid>.<random>. So one still on a retained record is the
        # stamp an abandoned --legacy-record attempt could not roll back, not
        # an incarnation any spawn ever published. The record is still the
        # legacy record it was, and is treated as one: the dead-or-agent-less
        # endpoint gate runs again on the retry instead of being skipped by
        # the abandoned attempt's own stamp.
        if [ "$LEGACY_RECORD_GIVEN" != 1 ]; then
          echo "error: task $ID's record carries the legacy incarnation stamp $FM_BACKLOG_META_SPAWN_GEN left by an abandoned --legacy-record teardown, not an incarnation published by a spawn; refusing automatic teardown - relaunch the task to publish an unambiguous incarnation, then retry teardown, or pass --legacy-record once its recorded endpoint is confirmed dead or agent-less" >&2
          exit 1
        fi
        TEARDOWN_LEGACY_PENDING=1
        TEARDOWN_LEGACY_RETAINED_STAMP=$FM_BACKLOG_META_SPAWN_GEN
        ;;
    esac
  fi
  [ "$TEARDOWN_LEGACY_PENDING" = 1 ] || TEARDOWN_META_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN
fi
# Cleanup never closes a captain call (see the header). Asked here, before any
# destructive step, so "cannot tell" can refuse while everything is intact.
TEARDOWN_BACKLOG_TRANSITION=close
if [ "$TEARDOWN_BACKLOG_APPLIES" = 1 ]; then
  TEARDOWN_CAPTAIN_OPEN_STATUS=0
  TEARDOWN_CAPTAIN_OPEN_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" 2>&1) || TEARDOWN_CAPTAIN_OPEN_STATUS=$?
  case "$TEARDOWN_CAPTAIN_OPEN_STATUS" in
    0) TEARDOWN_BACKLOG_TRANSITION=retain ;;
    1) ;;
    *)
      echo "error: task $ID cannot be torn down because whether its backlog item is still held for the captain could not be read; fix that read and retry rather than risk closing a captain call with no recorded answer" >&2
      [ -z "$TEARDOWN_CAPTAIN_OPEN_OUT" ] || printf '%s\n' "$TEARDOWN_CAPTAIN_OPEN_OUT" >&2
      exit 1
      ;;
  esac
fi

REMOTE_HANDOFF_DIR_PRESENT=0
REMOTE_HANDOFF_DIR_REAL=
REMOTE_OUTBOX_PRESENT=0
REMOTE_PENDING_DIR_PRESENT=0
REMOTE_PENDING_DIR_REAL=
REMOTE_HANDOFF_LOCK=
REMOTE_REGISTRY_LOCK=
REMOTE_REPLY_LIFECYCLE_LOCK=
LOCAL_HANDOFF_LOCK=
LOCAL_REGISTRY_LOCK=
HANDOFF_WAKE_RETIRE_MARKER=
HANDOFF_WAKE_RETIRE_VALUE=
HANDOFF_WAKE_RETIRE_CORR=
HANDOFF_WAKE_RETIRE_LOCK=
HANDOFF_WAKE_RETIRE_STAGE=

handoff_wake_retire_validate() {
  local marker="$STATE/.backlog-handoff-$ID.wake-pending" value corr rec confirmation
  HANDOFF_WAKE_RETIRE_MARKER=
  HANDOFF_WAKE_RETIRE_VALUE=
  HANDOFF_WAKE_RETIRE_CORR=
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] || {
    echo "REFUSED: receiver wake state for secondmate $ID is unsafe" >&2
    return 1
  }
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
    pending|confirmed) ;;
    prepared:*)
      corr=${value#prepared:}
      corr=${corr%%:*}
      printf '%s' "$value" | grep -Eq '^prepared:[a-f0-9]{16}:[a-f0-9]{16}$' || {
        echo "REFUSED: receiver wake state for secondmate $ID is invalid" >&2
        return 1
      }
      ;;
    pending:*|confirmed:*)
      corr=${value#*:}
      printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || {
        echo "REFUSED: receiver wake state for secondmate $ID is invalid" >&2
        return 1
      }
      ;;
    *)
      echo "REFUSED: receiver wake state for secondmate $ID is invalid" >&2
      return 1
      ;;
  esac
  if [ -n "$corr" ]; then
    rec=$(fm_pending_reply_path "$STATE" "$corr")
    if [ -e "$rec" ] || [ -L "$rec" ]; then
      [ -f "$rec" ] && [ ! -L "$rec" ] \
        && [ "$(fm_pending_reply_get "$rec" task_id)" = "$ID" ] || {
        echo "REFUSED: receiver wake correlation for secondmate $ID is unsafe or belongs to another task" >&2
        return 1
      }
    fi
    confirmation=$(fm_pending_reply_delivery_confirmation_path "$STATE" "$corr")
    if [ -e "$confirmation" ] || [ -L "$confirmation" ]; then
      [ -f "$confirmation" ] && [ ! -L "$confirmation" ] || {
        echo "REFUSED: receiver wake delivery state for secondmate $ID is unsafe" >&2
        return 1
      }
    fi
    HANDOFF_WAKE_RETIRE_CORR=$corr
  fi
  HANDOFF_WAKE_RETIRE_MARKER=$marker
  HANDOFF_WAKE_RETIRE_VALUE=$value
}

handoff_wake_retire() {
  local marker=$HANDOFF_WAKE_RETIRE_MARKER corr=$HANDOFF_WAKE_RETIRE_CORR lock rec confirmation rc=0
  [ -n "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] \
    && [ "$(cat "$marker" 2>/dev/null || true)" = "$HANDOFF_WAKE_RETIRE_VALUE" ] || return 1
  if [ -n "$corr" ]; then
    lock="$STATE/.pending-reply-$corr.lock"
    fm_lock_acquire_wait "$lock" || return 1
    rec=$(fm_pending_reply_path "$STATE" "$corr")
    confirmation=$(fm_pending_reply_delivery_confirmation_path "$STATE" "$corr")
    if { [ ! -e "$rec" ] && [ ! -L "$rec" ]; } \
      || { [ -f "$rec" ] && [ ! -L "$rec" ] \
        && [ "$(fm_pending_reply_get "$rec" task_id)" = "$ID" ]; }; then
      rm -f -- "$confirmation" "$rec" "$marker" || rc=$?
    else
      rc=1
    fi
    fm_lock_release "$lock"
    return "$rc"
  fi
  rm -f -- "$marker"
}

handoff_wake_retire_stage_restore() {
  local stage=$HANDOFF_WAKE_RETIRE_STAGE marker rec confirmation name destination
  [ -n "$stage" ] || return 0
  marker="$STATE/.backlog-handoff-$ID.wake-pending"
  rec=
  confirmation=
  if [ -n "$HANDOFF_WAKE_RETIRE_CORR" ]; then
    rec=$(fm_pending_reply_path "$STATE" "$HANDOFF_WAKE_RETIRE_CORR")
    confirmation=$(fm_pending_reply_delivery_confirmation_path "$STATE" "$HANDOFF_WAKE_RETIRE_CORR")
  fi
  for name in record confirmation marker; do
    [ -e "$stage/$name" ] || continue
    case "$name" in
      record) destination=$rec ;;
      confirmation) destination=$confirmation ;;
      marker) destination=$marker ;;
    esac
    [ -n "$destination" ] && [ ! -e "$destination" ] && [ ! -L "$destination" ] \
      && mv -- "$stage/$name" "$destination" || return 1
  done
  rm -f -- "$stage/corr" || return 1
  rmdir -- "$stage" || return 1
  if [ -n "$HANDOFF_WAKE_RETIRE_LOCK" ]; then
    fm_lock_release "$HANDOFF_WAKE_RETIRE_LOCK" || return 1
    HANDOFF_WAKE_RETIRE_LOCK=
  fi
  HANDOFF_WAKE_RETIRE_STAGE=
}

handoff_wake_retire_stage_commit() {
  local stage=$HANDOFF_WAKE_RETIRE_STAGE retired
  [ -n "$stage" ] || return 0
  retired="$stage.retired.$$"
  [ ! -e "$retired" ] && [ ! -L "$retired" ] || return 1
  mv -- "$stage" "$retired" || return 1
  HANDOFF_WAKE_RETIRE_STAGE=
  if [ -n "$HANDOFF_WAKE_RETIRE_LOCK" ]; then
    fm_lock_release "$HANDOFF_WAKE_RETIRE_LOCK" || return 1
    HANDOFF_WAKE_RETIRE_LOCK=
  fi
  rm -rf -- "$retired" || echo "warning: retired receiver wake state remains at $retired" >&2
}

handoff_wake_retire_stage_recover() {
  local home=$1 stage="$STATE/.backlog-handoff-$ID.wake-retiring" corr
  [ -e "$stage" ] || [ -L "$stage" ] || return 0
  [ -d "$stage" ] && [ ! -L "$stage" ] || {
    echo "REFUSED: receiver wake retirement state for secondmate $ID is unsafe" >&2
    return 1
  }
  if [ ! -e "$stage/corr" ] && [ ! -L "$stage/corr" ]; then
    rmdir -- "$stage" 2>/dev/null && return 0
    echo "REFUSED: receiver wake retirement state for secondmate $ID is incomplete" >&2
    return 1
  fi
  [ -f "$stage/corr" ] && [ ! -L "$stage/corr" ] || {
    echo "REFUSED: receiver wake retirement state for secondmate $ID is unsafe" >&2
    return 1
  }
  corr=$(cat "$stage/corr" 2>/dev/null || true)
  [ -z "$corr" ] || printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || {
    echo "REFUSED: receiver wake retirement correlation for secondmate $ID is invalid" >&2
    return 1
  }
  local staged
  for staged in "$stage/marker" "$stage/record" "$stage/confirmation"; do
    [ ! -e "$staged" ] && [ ! -L "$staged" ] && continue
    [ -f "$staged" ] && [ ! -L "$staged" ] || {
      echo "REFUSED: receiver wake retirement state for secondmate $ID is unsafe" >&2
      return 1
    }
  done
  HANDOFF_WAKE_RETIRE_CORR=$corr
  HANDOFF_WAKE_RETIRE_STAGE=$stage
  if [ -n "$corr" ]; then
    HANDOFF_WAKE_RETIRE_LOCK="$STATE/.pending-reply-$corr.lock"
    fm_lock_acquire_wait "$HANDOFF_WAKE_RETIRE_LOCK" || return 1
  fi
  if [ -e "$home" ] || [ -L "$home" ]; then
    handoff_wake_retire_stage_restore
  else
    handoff_wake_retire_stage_commit
  fi
}

handoff_wake_retire_stage() {
  local stage="$STATE/.backlog-handoff-$ID.wake-retiring" marker=$HANDOFF_WAKE_RETIRE_MARKER
  local corr=$HANDOFF_WAKE_RETIRE_CORR rec confirmation
  [ -n "$marker" ] || return 0
  [ ! -e "$stage" ] && [ ! -L "$stage" ] || return 1
  (umask 077; mkdir -- "$stage") || return 1
  HANDOFF_WAKE_RETIRE_STAGE=$stage
  printf '%s\n' "$corr" > "$stage/corr" || { handoff_wake_retire_stage_restore || true; return 1; }
  if [ -n "$corr" ]; then
    HANDOFF_WAKE_RETIRE_LOCK="$STATE/.pending-reply-$corr.lock"
    fm_lock_acquire_wait "$HANDOFF_WAKE_RETIRE_LOCK" || {
      HANDOFF_WAKE_RETIRE_LOCK=
      handoff_wake_retire_stage_restore || true
      return 1
    }
    rec=$(fm_pending_reply_path "$STATE" "$corr")
    confirmation=$(fm_pending_reply_delivery_confirmation_path "$STATE" "$corr")
    if [ -e "$rec" ] && ! mv -- "$rec" "$stage/record"; then
      handoff_wake_retire_stage_restore || true
      return 1
    fi
    if [ -e "$confirmation" ] && ! mv -- "$confirmation" "$stage/confirmation"; then
      handoff_wake_retire_stage_restore || true
      return 1
    fi
  fi
  if ! mv -- "$marker" "$stage/marker"; then
    handoff_wake_retire_stage_restore || true
    return 1
  fi
}

remote_teardown_locks_release() {
  if [ -n "$REMOTE_REPLY_LIFECYCLE_LOCK" ]; then
    fm_lock_release "$REMOTE_REPLY_LIFECYCLE_LOCK"
    REMOTE_REPLY_LIFECYCLE_LOCK=
  fi
  if [ -n "$REMOTE_HANDOFF_LOCK" ]; then
    fm_lock_release "$REMOTE_HANDOFF_LOCK"
    REMOTE_HANDOFF_LOCK=
  fi
  if [ -n "$REMOTE_REGISTRY_LOCK" ]; then
    fm_lock_release "$REMOTE_REGISTRY_LOCK"
    REMOTE_REGISTRY_LOCK=
  fi
}

remote_recovery_paths_validate() {
  local mode=${1:-initial} handoff_dir outbox pending_dir real rec
  handoff_dir="$DATA/handoff"
  outbox="$handoff_dir/$ID.outbox.md"
  pending_dir="$STATE/pending-replies"
  if [ -e "$handoff_dir" ] || [ -L "$handoff_dir" ]; then
    [ -d "$handoff_dir" ] && [ ! -L "$handoff_dir" ] \
      || { echo "REFUSED: remote handoff recovery directory is unsafe" >&2; return 1; }
    real=$(CDPATH='' cd -- "$handoff_dir" 2>/dev/null && pwd -P) || return 1
    if [ "$mode" = initial ]; then
      REMOTE_HANDOFF_DIR_PRESENT=1
      REMOTE_HANDOFF_DIR_REAL=$real
    elif [ "$REMOTE_HANDOFF_DIR_PRESENT" -ne 1 ] || [ "$REMOTE_HANDOFF_DIR_REAL" != "$real" ]; then
      echo "REFUSED: remote handoff recovery directory changed during retirement" >&2
      return 1
    fi
  elif [ "$mode" != initial ] && [ "$REMOTE_HANDOFF_DIR_PRESENT" -ne 0 ]; then
    echo "REFUSED: remote handoff recovery directory changed during retirement" >&2
    return 1
  fi
  if [ -e "$outbox" ] || [ -L "$outbox" ]; then
    [ -f "$outbox" ] && [ ! -L "$outbox" ] \
      || { echo "REFUSED: remote backlog outbox is unsafe" >&2; return 1; }
    if [ "$mode" = initial ]; then
      REMOTE_OUTBOX_PRESENT=1
    elif [ "$REMOTE_OUTBOX_PRESENT" -ne 1 ]; then
      echo "REFUSED: remote backlog outbox changed during retirement" >&2
      return 1
    fi
  elif [ "$mode" != initial ] && [ "$REMOTE_OUTBOX_PRESENT" -ne 0 ]; then
    echo "REFUSED: remote backlog outbox changed during retirement" >&2
    return 1
  fi
  if [ -e "$pending_dir" ] || [ -L "$pending_dir" ]; then
    [ -d "$pending_dir" ] && [ ! -L "$pending_dir" ] \
      || { echo "REFUSED: pending-replies recovery directory is unsafe" >&2; return 1; }
    real=$(CDPATH='' cd -- "$pending_dir" 2>/dev/null && pwd -P) || return 1
    if [ "$mode" = initial ]; then
      REMOTE_PENDING_DIR_PRESENT=1
      REMOTE_PENDING_DIR_REAL=$real
    elif [ "$REMOTE_PENDING_DIR_PRESENT" -ne 1 ] || [ "$REMOTE_PENDING_DIR_REAL" != "$real" ]; then
      echo "REFUSED: pending-replies recovery directory changed during retirement" >&2
      return 1
    fi
    for rec in "$pending_dir"/*; do
      [ -e "$rec" ] || [ -L "$rec" ] || continue
      [ -f "$rec" ] && [ ! -L "$rec" ] \
        || { echo "REFUSED: pending-replies contains an unsafe recovery entry" >&2; return 1; }
    done
  elif [ "$mode" != initial ] && [ "$REMOTE_PENDING_DIR_PRESENT" -ne 0 ]; then
    echo "REFUSED: pending-replies recovery directory changed during retirement" >&2
    return 1
  fi
}

remote_pending_replies_cleanup() {
  local rec
  [ "$REMOTE_PENDING_DIR_PRESENT" -eq 1 ] || return 0
  (
    CDPATH='' cd -- "$STATE/pending-replies" 2>/dev/null || exit 1
    [ "$(pwd -P)" = "$REMOTE_PENDING_DIR_REAL" ] || exit 1
    for rec in ./*; do
      [ -e "$rec" ] || [ -L "$rec" ] || continue
      [ -f "$rec" ] && [ ! -L "$rec" ] || exit 1
      [ "$(fm_meta_get "$rec" task_id)" = "$ID" ] && rm -f -- "$rec"
    done
  )
}

remote_outbox_cleanup() {
  [ "$REMOTE_OUTBOX_PRESENT" -eq 1 ] || return 0
  (
    CDPATH='' cd -- "$DATA/handoff" 2>/dev/null || exit 1
    [ "$(pwd -P)" = "$REMOTE_HANDOFF_DIR_REAL" ] || exit 1
    [ -f "$ID.outbox.md" ] && [ ! -L "$ID.outbox.md" ] || exit 1
    rm -f -- "$ID.outbox.md"
  )
}

remote_secondmate_teardown() {
  local remote_host remote_root remote_home kind route_host route_root route_home out rc tmp rec phase task_id
  remote_host=$(fm_meta_get "$META" remote_host)
  [ -n "$remote_host" ] || return 3
  kind=$(fm_meta_get "$META" kind)
  [ "$kind" = secondmate ] || { echo "REFUSED: remote placement metadata is valid only for a secondmate" >&2; return 1; }
  remote_root=$(fm_meta_get "$META" remote_root)
  remote_home=$(fm_meta_get "$META" home)
  [ -n "$remote_root" ] && [ -n "$remote_home" ] || { echo "REFUSED: remote secondmate metadata is incomplete" >&2; return 1; }
  secondmate_registry_line_for_id "$SECONDMATE_REG" "$ID" || { echo "REFUSED: remote secondmate route is missing or ambiguous" >&2; return 1; }
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || { echo "REFUSED: secondmate registry route is not remote" >&2; return 1; }
  route_host=$SECONDMATE_REGISTRY_HOST
  route_root=$SECONDMATE_REGISTRY_ROOT
  route_home=$SECONDMATE_REGISTRY_HOME
  [ "$route_host" = "$remote_host" ] && [ "$route_root" = "$remote_root" ] && [ "$route_home" = "$remote_home" ] \
    || { echo "REFUSED: remote secondmate metadata does not match its registry route" >&2; return 1; }
  handoff_wake_retire_validate || return 1
  remote_recovery_paths_validate initial || return 1
  if [ "$FORCE" != --force ] && [ "$REMOTE_OUTBOX_PRESENT" -eq 1 ]; then
    echo "REFUSED: remote secondmate $ID still has a pending backlog outbox; deliver it or explicitly discard with --force" >&2
    return 1
  fi
  if [ "$FORCE" != --force ] && [ -d "$STATE/pending-replies" ]; then
    for rec in "$STATE/pending-replies"/*; do
      [ -f "$rec" ] || continue
      task_id=$(fm_meta_get "$rec" task_id)
      [ "$task_id" = "$ID" ] || continue
      phase=$(fm_meta_get "$rec" phase)
      [ "$phase" = resolved ] || {
        echo "REFUSED: remote secondmate $ID still has an unresolved routed reply" >&2
        return 1
      }
    done
  fi
  "$SCRIPT_DIR/fm-procevent-remote-reply.sh" retire-quiesce-locked "$ID" "$FORCE" >/dev/null 2>&1 || {
    echo "REFUSED: remote secondmate $ID still has an unhandled captured reply" >&2
    return 1
  }
  "$FM_ROOT/bin/fm-guard.sh" || true
  if [ "$FORCE" = --force ]; then
    if out=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh retire "$ID" --force < /dev/null 2>&1); then rc=0; else rc=$?; fi
  else
    if out=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh retire "$ID" < /dev/null 2>&1); then rc=0; else rc=$?; fi
  fi
  if [ "$rc" -ne 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    if [ "$rc" -eq 255 ]; then
      echo "error: remote retirement completion is unknown; preserving the route and local records for same-host reconciliation" >&2
    elif ! "$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm-locked "$ID" >/dev/null 2>&1; then
      echo "error: remote retirement failed and the reply source could not be re-armed" >&2
    fi
    return "$rc"
  fi
  remote_recovery_paths_validate recheck || {
    echo "error: remote home retired but local recovery paths changed; preserving the local route for retry" >&2
    return 1
  }
  "$SCRIPT_DIR/fm-procevent-remote-reply.sh" retire-finalize-locked "$ID" "$FORCE" >/dev/null 2>&1 || {
    echo "error: remote home retired but reply-source cleanup is incomplete; preserving the local route for retry" >&2
    return 1
  }
  if [ "$FORCE" = --force ]; then
    remote_outbox_cleanup || { echo "error: remote outbox cleanup failed; preserving the local route for retry" >&2; return 1; }
  fi
  remote_pending_replies_cleanup \
    || { echo "error: remote pending-reply cleanup failed; preserving the local route for retry" >&2; return 1; }
  handoff_wake_retire \
    || { echo "error: remote receiver wake cleanup failed; preserving the local route for retry" >&2; return 1; }
  tmp="$SECONDMATE_REG.tmp.$$"
  grep -vE "^- $ID( |$)" "$SECONDMATE_REG" > "$tmp" || true
  mv -f -- "$tmp" "$SECONDMATE_REG"
  status_retire_presentation_task "$STATE" "$ID" || return 1
  fm_backlog_atomic_transition remove "$STATE/$ID.meta" "task record" "$STATE" || return 1
  rm -f -- "$STATE/$ID.turn-ended"
  printf 'teardown %s complete (remote %s:%s)\n' "$ID" "$remote_host" "$remote_home"
  return 0
}

remote_secondmate_teardown_locked() {
  local rc
  [ -n "$(fm_meta_get "$META" remote_host)" ] || return 3
  REMOTE_REGISTRY_LOCK=$(secondmate_registry_lock_path "$STATE")
  fm_lock_acquire_wait "$REMOTE_REGISTRY_LOCK" || return 1
  REMOTE_HANDOFF_LOCK="$STATE/.backlog-handoff-$ID.lock"
  fm_lock_acquire_wait "$REMOTE_HANDOFF_LOCK" || {
    remote_teardown_locks_release
    return 1
  }
  REMOTE_REPLY_LIFECYCLE_LOCK=$(secondmate_reply_lifecycle_lock_path "$STATE" "$ID")
  fm_lock_acquire_wait "$REMOTE_REPLY_LIFECYCLE_LOCK" || {
    remote_teardown_locks_release
    return 1
  }
  if remote_secondmate_teardown; then rc=0; else rc=$?; fi
  remote_teardown_locks_release
  return "$rc"
}

if remote_secondmate_teardown_locked; then
  "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
  exit 0
else
  remote_teardown_rc=$?
fi
[ "$remote_teardown_rc" -eq 3 ] || exit "$remote_teardown_rc"

# This is the first cleanup authorization check. It is metadata-only and must
# complete before fm-guard, a backend command, file removal, branch deletion,
# worktree return, registry change, or process termination can run.
fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
T=$FM_BACKEND_VALIDATED_TARGET
WT=$(fm_meta_get "$META" worktree)
PROJ=$(fm_meta_get "$META" project)
T_ORCA=
[ "$BACKEND" != orca ] || T_ORCA=$T
if [ "${FM_TEARDOWN_GUARD_DONE:-0}" != 1 ]; then
  "$FM_ROOT/bin/fm-guard.sh" || true
fi
HOME_PATH=$(grep '^home=' "$META" | cut -d= -f2- || true)
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
# tasktmp is recorded by fm-spawn for tasks that set up a per-task temp root
# (/tmp/fm-<id>/); absent for tasks spawned before that change, so tolerate empty.
TASK_TMP=$(grep '^tasktmp=' "$META" | cut -d= -f2- || true)
BUSY_GEN=$(fm_meta_get "$META" busy_gen)
if [ -z "$BUSY_GEN" ]; then
  BUSY_GEN=$(cat "$STATE/$ID.busy-gen" 2>/dev/null || true)
fi
ORCA_WORKTREE_ID=$(fm_meta_get "$META" orca_worktree_id)
ORCA_PATH_MATCH_VERIFIED=0
CLEANUP_RECOVERY=$TEARDOWN_CLEANUP_RECOVERY

KIND=$TEARDOWN_META_KIND
EXPECTED_TREEHOUSE_PROJECT_LOCK=
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ] \
   && is_treehouse_pool_slot "$PROJ" "$WT"; then
  EXPECTED_TREEHOUSE_PROJECT_LOCK=$(fm_treehouse_project_lock_path "$PROJ") || {
    echo "REFUSED: cannot resolve the shared Treehouse project lock for ${PROJ:-<missing>}; nothing was changed" >&2
    exit 1
  }
  if [ "$TREEHOUSE_PROJECT_LOCK_HELD" != 1 ] \
     || [ "$TREEHOUSE_PROJECT_LOCK" != "$EXPECTED_TREEHOUSE_PROJECT_LOCK" ]; then
    echo "REFUSED: task $ID's Treehouse project identity changed while teardown acquired its locks; nothing was changed" >&2
    exit 1
  fi
elif [ "$TREEHOUSE_SLOT_LOCK_REQUIRED" = 1 ]; then
  echo "REFUSED: task $ID stopped naming a live Treehouse slot while teardown acquired its locks; nothing was changed" >&2
  exit 1
fi
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes

# A record accepted as a legacy incarnation (no spawn_gen, --legacy-record
# given) may be torn down only when its recorded endpoint is confidently gone
# or agent-less; only the recovery-grade classifier's dead and missing license
# that, and every ambiguous, unreadable, or unverified endpoint state refuses
# while the record is still intact. Acceptance resolves the incarnation token
# here; the record itself is stamped only once every landed-work refusal has
# passed, immediately before the close marker binds to it, so any refusal
# leaves the record byte-identical.
if [ "$TEARDOWN_LEGACY_PENDING" = 1 ]; then
  TEARDOWN_LEGACY_ENDPOINT=$(fm_backend_agent_state "$BACKEND" "$T")
  case "$TEARDOWN_LEGACY_ENDPOINT" in
    dead|missing) ;;
    *)
      echo "REFUSED: task $ID's record predates spawn_gen and its recorded endpoint reads '$TEARDOWN_LEGACY_ENDPOINT', not confidently dead or agent-less; --legacy-record teardown is refused while an agent may still be bound to it. Nothing was changed." >&2
      echo "Reconcile the endpoint first (bin/fm-crew-state.sh $ID), or relaunch the task to publish an unambiguous incarnation, then retry teardown." >&2
      exit 1
      ;;
  esac
  if [ -n "$TEARDOWN_LEGACY_RETAINED_STAMP" ]; then
    TEARDOWN_META_SPAWN_GEN=$TEARDOWN_LEGACY_RETAINED_STAMP
  else
    TEARDOWN_META_SPAWN_GEN="legacy-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  TEARDOWN_LEGACY_ACCEPTED=1
fi

PUBLIC_FOLLOWUP_HOME=$FM_HOME
PUBLIC_FOLLOWUP_STATE=$STATE
PUBLIC_FOLLOWUP_WORK_HOME=main
PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=0
PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE=0
PUBLIC_FOLLOWUP_RELAY_ACTIVE=0
public_followup_canonical_home() {
  local home=$1
  case "$home" in /*) ;; *) return 1 ;; esac
  CDPATH='' cd -- "$home" 2>/dev/null && pwd -P
}
public_followup_resolve_primary_home() {
  local parent=$1 child=$2 id=$3 parent_meta registry meta_home
  fm_pf_home_id_valid "secondmate:$id" || return 1
  parent=$(public_followup_canonical_home "$parent") || return 1
  child=$(public_followup_canonical_home "$child") || return 1
  [ "$parent" != "$child" ] || return 1
  parent_meta="$parent/state/$id.meta"
  [ -f "$parent_meta" ] && [ ! -L "$parent_meta" ] || return 1
  [ "$(fm_meta_get "$parent_meta" kind)" = secondmate ] || return 1
  meta_home=$(fm_meta_get "$parent_meta" home)
  meta_home=$(CDPATH='' cd -- "$meta_home" 2>/dev/null && pwd -P) || return 1
  [ "$meta_home" = "$child" ] || return 1
  registry="$parent/data/secondmates.md"
  secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key "$id" "$child" || return 1
  printf '%s\n' "$parent"
}
if [ -f "$FM_HOME/$SUB_HOME_MARKER" ]; then
  SECOND_MATE_ID=$(sed -n '1p' "$FM_HOME/$SUB_HOME_MARKER")
  # The durable parent record (written once at seeding, next to the identity
  # marker) names this home's route to its parent: "local" when they share a
  # filesystem, "remote" when the parent lives on another machine. Absent for
  # a home seeded before this record existed, which preserves today's exact
  # env-var-only behavior for that legacy home rather than guessing its route.
  PARENT_ROUTE_FILE="$FM_HOME/$SUB_HOME_PARENT_MARKER"
  PARENT_ROUTE_RECORD=absent
  PARENT_ROUTE=
  PARENT_ROUTE_HOME=
  if [ -e "$PARENT_ROUTE_FILE" ] || [ -L "$PARENT_ROUTE_FILE" ]; then
    PARENT_ROUTE_RECORD=invalid
    if fm_secondmate_parent_record_parse "$PARENT_ROUTE_FILE"; then
      PARENT_ROUTE=$FM_SECONDMATE_PARENT_ROUTE
      PARENT_ROUTE_HOME=$FM_SECONDMATE_PARENT_HOME
      PARENT_ROUTE_RECORD=valid
    fi
  fi
  if [ "$PARENT_ROUTE_RECORD" = invalid ]; then
    PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=1
  elif [ "$PARENT_ROUTE" = remote ]; then
    # The entire promised-public-reply subsystem is same-filesystem by
    # construction (bin/fm-public-followup-emit.sh header): a parent recorded
    # on another machine can never hold a delegated promise for this child, so
    # the delegated-parent path is out of scope and never refuses cleanup on
    # its own. A token committed directly to THIS home's own .env is still a
    # real, same-filesystem signal, so it is still checked - but read only
    # from the file, never from the process environment, so an unrelated
    # export in the remote host's own login shell cannot trigger it the way
    # fm_pf_relay_active's environment-wins rule would.
    if [ -f "$FM_HOME/.env" ]; then
      HOME_ENV_TOKEN=$(fmx_env_get FMX_PAIRING_TOKEN "$FM_HOME/.env")
      [ -z "$HOME_ENV_TOKEN" ] || PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE=1
    fi
    if [ "$PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE" = 1 ]; then
      PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=1
    else
      PUBLIC_FOLLOWUP_HOME=
      PUBLIC_FOLLOWUP_STATE=
    fi
  elif [ "$PARENT_ROUTE" = local ]; then
    PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=1
    PRIMARY_HOME_CANDIDATE=${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-$PARENT_ROUTE_HOME}
    PARENT_BINDINGS_MATCH=1
    if [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
      LIVE_PARENT_HOME=$(public_followup_canonical_home \
        "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME") || PARENT_BINDINGS_MATCH=0
      DURABLE_PARENT_HOME=$(public_followup_canonical_home \
        "$PARENT_ROUTE_HOME") || PARENT_BINDINGS_MATCH=0
      if [ "$PARENT_BINDINGS_MATCH" = 1 ] \
        && [ "$LIVE_PARENT_HOME" != "$DURABLE_PARENT_HOME" ]; then
        PARENT_BINDINGS_MATCH=0
      fi
    fi
    if [ "$PARENT_BINDINGS_MATCH" = 1 ] \
      && fm_pf_home_id_valid "secondmate:$SECOND_MATE_ID"; then
      PUBLIC_FOLLOWUP_WORK_HOME="secondmate:$SECOND_MATE_ID"
      if PUBLIC_FOLLOWUP_HOME=$(public_followup_resolve_primary_home \
          "$PRIMARY_HOME_CANDIDATE" "$FM_HOME" "$SECOND_MATE_ID"); then
        PUBLIC_FOLLOWUP_STATE="$PUBLIC_FOLLOWUP_HOME/state"
        PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=0
        if [ "$FORCE" != "--force" ] \
          && fm_pf_relay_active "$PUBLIC_FOLLOWUP_HOME"; then
          PUBLIC_FOLLOWUP_RELAY_ACTIVE=1
        fi
      else
        PUBLIC_FOLLOWUP_HOME=
        PUBLIC_FOLLOWUP_STATE=
      fi
    fi
  else
    # A home seeded before the durable record existed retains the legacy
    # launch-time binding behavior unchanged.
    PRIMARY_HOME_CANDIDATE=${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}
    if [ -n "$PRIMARY_HOME_CANDIDATE" ]; then
      if fm_pf_relay_active "$PRIMARY_HOME_CANDIDATE"; then
        PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE=1
      fi
    elif fm_pf_relay_active "$FM_HOME"; then
      PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE=1
    fi
    if [ "$PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE" = 1 ]; then
      PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=1
      if fm_pf_home_id_valid "secondmate:$SECOND_MATE_ID"; then
        PUBLIC_FOLLOWUP_WORK_HOME="secondmate:$SECOND_MATE_ID"
        if PUBLIC_FOLLOWUP_HOME=$(public_followup_resolve_primary_home \
            "$PRIMARY_HOME_CANDIDATE" "$FM_HOME" "$SECOND_MATE_ID"); then
          PUBLIC_FOLLOWUP_STATE="$PUBLIC_FOLLOWUP_HOME/state"
          PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=0
          if [ "$FORCE" != "--force" ] \
            && fm_pf_relay_active "$PUBLIC_FOLLOWUP_HOME"; then
            PUBLIC_FOLLOWUP_RELAY_ACTIVE=1
          fi
        else
          PUBLIC_FOLLOWUP_HOME=
          PUBLIC_FOLLOWUP_STATE=
        fi
      fi
    else
      PUBLIC_FOLLOWUP_HOME=
      PUBLIC_FOLLOWUP_STATE=
    fi
  fi
elif [ "$KIND" = secondmate ]; then
  PUBLIC_FOLLOWUP_WORK_HOME="secondmate:$ID"
  if [ "$FORCE" != "--force" ] && fm_pf_relay_active "$FM_HOME"; then
    PUBLIC_FOLLOWUP_RELAY_ACTIVE=1
  fi
elif [ "$FORCE" != "--force" ] && fm_pf_relay_active "$FM_HOME"; then
  PUBLIC_FOLLOWUP_RELAY_ACTIVE=1
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
  ORCA_WORKTREE_ID=$(require_orca_worktree_id "$META") || exit 1
  T_ORCA=$(meta_value "$META" terminal)
  [ -z "$T_ORCA" ] || T=$T_ORCA
fi

# Where a harness's firstmate-owned global turn-end registry entry lives is
# owned by bin/fm-control-lib.sh, so teardown and the control plane's relaunch
# retire the same artifact rather than each carrying its own copy of the path.
remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token_path token='' path
  token_path=$(fm_control_harness_turnend_token_path grok "$state_dir" "$id") || return 1
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  path=$(fm_control_harness_turnend_auth_path grok "$token") || return 1
  [ -n "$path" ] || return 0
  rm -f -- "$path"
}

remove_kimi_turnend_auth() {
  local state_dir=$1 id=$2 token_path token='' path
  token_path=$(fm_control_harness_turnend_token_path kimi "$state_dir" "$id") || return 1
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  path=$(fm_control_harness_turnend_auth_path kimi "$token") || return 1
  [ -n "$path" ] || return 0
  rm -f -- "$path"
}

retire_busy_state() {
  local state_dir=$1 id=$2 gen=${3:-}
  if [ -n "$gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$state_dir" "$id" --gen "$gen"
  elif [ -f "$state_dir/$id.busy-gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$state_dir" "$id" --current-gen
  fi
}

validate_pr_poll_cleanup() {
  local state_dir=$1 id=$2 state_device artifact has_artifact=0
  fm_task_id_path_safe "$id" || return 0
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ]; then
      echo "REFUSED: unsafe task PR-check artifact; preserving task state." >&2
      return 1
    fi
  done
  if [ -e "$state_dir/$id.pr-poll-retirement" ] \
    || [ -L "$state_dir/$id.pr-poll-retirement" ]; then
    fm_pr_poll_retirement_state_valid "$state_dir" "$id" || {
      echo "REFUSED: invalid PR-poll retirement receipt; preserving task state." >&2
      return 1
    }
  fi
}

remove_pr_poll_artifacts() {
  local state_dir=$1 id=$2
  validate_pr_poll_cleanup "$state_dir" "$id" || return 1
  fm_pr_poll_retirement_recover_one "$state_dir" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" || return 1
  fm_pr_poll_merge_notified_remove "$state_dir" "$id" || return 1
  rm -f "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.check-trust" || return 1
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
  local branch=$1 target view state remainder head resolved_url current landed=0
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$WT" && gh pr view "$target" --json state,headRefOid,url -q '.state + "\t" + .headRefOid + "\t" + .url' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  remainder=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  head=${remainder%%$'\t'*}
  resolved_url=${remainder#*$'\t'}
  [ "$head" != "$remainder" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  ensure_commit_object "$target" "$head" || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  if git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
    landed=1
  elif unpushed_patches_are_in_pr_head "$head"; then
    landed=1
  fi
  [ "$landed" = 1 ] || return 1
  if [ -z "$PR_URL" ]; then
    [ -n "$resolved_url" ] || return 1
    PR_URL=$resolved_url
  fi
  return 0
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

# The completion links this teardown already holds locally. A scout's
# deliverable is its report, a local-only ship lands on local main, and every
# other ship carries the PR recorded on its own record.
BACKLOG_DONE_ARGS=()
backlog_done_args() {
  local data_relative
  BACKLOG_DONE_ARGS=()
  case "$KIND" in
    scout)
      data_relative=$(fm_backlog_data_relative "$DATA") || return 1
      BACKLOG_DONE_ARGS=(--report "$data_relative/$ID/report.md")
      ;;
    *)
      if [ "$MODE" = local-only ]; then
        BACKLOG_DONE_ARGS=(--note "local main")
      elif [ -n "$PR_URL" ]; then
        BACKLOG_DONE_ARGS=(--pr "$PR_URL")
      fi
      ;;
  esac
}

# Closing the backlog item is this script's own last act on the record, not a
# printed instruction for a later turn (bin/fm-backlog-transition-lib.sh owns the
# invariant). This prints what already happened, so the follow-up wording stays
# only where a human still owes the edit.
backlog_refresh_reminder() {
  local backlog_display root
  [ "$KIND" = secondmate ] && return 0
  [ "$CLEANUP_RECOVERY" = orca ] && return 0
  if root=$(fm_backlog_root "$DATA") && [ "$(fm_tasks_axi_backend "$root")" != markdown ]; then
    backlog_display="this home's configured tasks-axi backend (data directory $DATA)"
  elif backlog_display=$(fm_backlog_file "$DATA"); then
    :
  else
    backlog_display="${DATA%/}/backlog.md"
  fi
  if [ "$BACKLOG_CLOSED" = 1 ] && [ "$BACKLOG_TRANSITION" = retain ]; then
    printf '%s\n' "Backlog: $ID stays open in $backlog_display, still held for the captain with its deliverable recorded. Relay the question and close it only with bin/fm-captain-hold.sh answer."
  elif [ "$BACKLOG_CLOSED" = 1 ]; then
    printf '%s\n' "Backlog: $ID is closed in $backlog_display. Run tasks-axi ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
  else
    printf '%s\n' "Backlog: $ID just finished ($BACKLOG_SKIP_REASON). Update $backlog_display - move $ID to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due."
  fi
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
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

retry_wait_secs_is_valid() {
  [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

STALE_WORKTREE_LOCK_AGE_SECS=${FM_STALE_WORKTREE_LOCK_AGE_SECS:-30}
# Bounded patience window for transient index.lock after killing a crew process.
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
TEARDOWN_PROCEVENT_RESTORE_FAILED=4

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
# stale git index.lock left by a killed crew process. See the script header.
teardown_treehouse_return() {
  local dir=$1 cd_dir=$2 label=$3 post_cleanup_check=${4:-} pool_home=${5:-$FM_HOME}
  local out lock attempt=0 max_retries lock_desc treehouse_root_option

  treehouse_root_option=$(fm_treehouse_root_option_for_home "$FM_ROOT" "$pool_home") || {
    echo "teardown: could not resolve the Treehouse root for $label; leaving it in place" >&2
    return 1
  }

  # Capture stdout+stderr so non-lock failures stay visible and lock failures can
  # be matched by signature even when the lock file is already gone mid-check.
  if out=$( ( cd "$cd_dir" && treehouse return${treehouse_root_option} --force "$dir" ) 2>&1 ); then
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  [ -n "$out" ] && printf '%s\n' "$out" >&2

  if ! treehouse_return_is_index_lock_error "$out"; then
    return 1
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

    if out=$( ( cd "$cd_dir" && treehouse return${treehouse_root_option} --force "$dir" ) 2>&1 ); then
      [ -n "$out" ] && printf '%s\n' "$out"
      echo "teardown: $label return succeeded on retry; lock cleared on its own" >&2
      return 0
    fi
    [ -n "$out" ] && printf '%s\n' "$out" >&2

    if ! treehouse_return_is_index_lock_error "$out"; then
      echo "teardown: $label return failed with a non-lock error after retry; aborting" >&2
      return 1
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
      if [ -n "$post_cleanup_check" ]; then
        if ! "$post_cleanup_check"; then
          echo "teardown: $label return aborted after stale-lock cleanup because safety checks failed" >&2
          return 1
        fi
      fi
      if out=$( ( cd "$cd_dir" && treehouse return${treehouse_root_option} --force "$dir" ) 2>&1 ); then
        [ -n "$out" ] && printf '%s\n' "$out"
        echo "teardown: $label return succeeded after stale-lock cleanup" >&2
        return 0
      fi
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      echo "teardown: $label return still failing after stale-lock cleanup" >&2
      return 1
    fi

    echo "teardown: $label return failed: git lock $lock_desc persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
  fi

  echo "teardown: $label return failed: git index.lock signature persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) even after the lock file disappeared" >&2
  return 1
}

validate_worktree_teardown_safety() {
  local dirty_raw dirty unpushed_raw unpushed DEFAULT unmerged_raw unmerged branch
  [ -d "$WT" ] || return 0
  [ "$FORCE" != "--force" ] || return 0
  case "$KIND" in
    secondmate|scout) return 0 ;;
  esac

  if ! dirty_raw=$(git -C "$WT" status --porcelain 2>/dev/null); then
    if worktree_safety_blocked_by_lock "uncommitted changes"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for uncommitted changes." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  dirty=$(printf '%s\n' "$dirty_raw" | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' | head -1 || true)

  if ! unpushed_raw=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    if worktree_safety_blocked_by_lock "commits not on a remote"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for commits not on a remote." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
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
      echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
    unmerged=$(printf '%s\n' "$unmerged_raw" | head -5)
    if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
      echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
      echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  elif [ -n "$dirty" ]; then
    echo "REFUSED: worktree $WT has uncommitted changes." >&2
    echo "uncommitted changes present" >&2
    echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
    return 1
  elif [ -n "$unpushed" ]; then
    branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
    if [ -z "$branch" ]; then
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$branch
    fi
    if ! work_is_landed "$branch"; then
      echo "REFUSED: worktree $WT has work not on any remote and not landed." >&2
      printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      echo "Push the branch, land its PR, or get the captain's explicit OK to discard, then --force." >&2
      return 1
    fi
  fi
}

# Fix 1 (see script header): does the active-or-most-recent no-mistakes run in
# worktree $1 belong to THIS task, and is it parked at a gate awaiting an agent
# that is about to be removed? Prints nothing; returns 0 only on a genuine
# match so the caller knows it is safe to abort - never a guess. Identity
# binds through the strict object-local head rule, with bin/fm-nm-run-lib.sh's
# shared ledger-anchored continuation rule as the only recognition for a head
# this copy cannot resolve at all.
NM_TEARDOWN_TIMEOUT=${FM_TEARDOWN_NM_TIMEOUT:-10}
case "$NM_TEARDOWN_TIMEOUT" in ''|*[!0-9]*) NM_TEARDOWN_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the parked-run
# continuation proof may scan, mirroring bin/fm-crew-state.sh's limit posture
# (generous: rows of other branches interleave freely in the real ledger).
NM_TEARDOWN_RUNS_LIMIT=${FM_TEARDOWN_NM_RUNS_LIMIT:-200}
case "$NM_TEARDOWN_RUNS_LIMIT" in ''|*[!0-9]*) NM_TEARDOWN_RUNS_LIMIT=200 ;; esac
TASK_RUN_ID=
task_status_is_own_parked_run() {  # <worktree> <axi-status-output>
  local wt=$1 out=$2 branch run_id run_branch run_head status outcome awaiting has_gate ledger
  TASK_RUN_ID=
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] || return 1
  [ -n "$out" ] || return 1
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ -n "$run_id" ] || return 1
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  [ -n "$run_branch" ] && [ "$run_branch" = "$branch" ] || return 1
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  [ -z "$outcome" ] || return 1
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  [ -n "$status" ] || return 1
  case "$status" in
    completed|failed|cancelled|passed|checks-passed|running|fixing|ci) return 1 ;;
  esac
  if ! fm_nm_head_matches_worktree "$wt" "$run_head"; then
    # The strict object-local rule rejected this run head. That rejection is
    # final when the head object resolves in this copy (diverged or rewritten
    # tips are genuine mismatches), but when the object is absent entirely -
    # the pipeline committed its fix round in its own repo and this copy
    # never fetched it - the ONE shared runs-ledger rule in
    # bin/fm-nm-run-lib.sh owns the only remaining recognition, and it prints
    # nothing for any ledger shape it cannot prove, so the run stays
    # untouched unless the ledger proves this exact continuation. Cleanup
    # consumes only an explicitly active (`running`) proved word: a terminal
    # newest row is finished history, never this parked run's abort
    # authorization (the read path classifies the same owner's answer; the
    # abort here must never fire for a run that already ended).
    [ -n "$run_head" ] || return 1
    [ -z "$(fm_nm_resolve_commit "$wt" "$run_head")" ] || return 1
    ledger=$(fm_nm_run "$wt" "$NM_TEARDOWN_TIMEOUT" runs --limit "$NM_TEARDOWN_RUNS_LIMIT")
    [ "$(fm_nm_runs_status_for_worktree "$wt" "$branch" "$ledger" "$run_head")" = running ] || return 1
  fi
  awaiting=$(printf '%s\n' "$out" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
  has_gate=$(printf '%s\n' "$out" | grep -Eq '^[[:space:]]*gate:[[:space:]]*' && echo 1 || echo 0)
  case "$status" in
    awaiting_approval|fix_review) TASK_RUN_ID=$run_id; return 0 ;;
  esac
  if [ -n "$awaiting" ] || [ "$has_gate" = 1 ]; then
    TASK_RUN_ID=$run_id
    return 0
  fi
  return 1
}

task_run_is_own_parked_run() {  # <worktree>
  local wt=$1 out
  # Accepted best-effort residual: query failures stay fail-open because making
  # no-mistakes availability a prerequisite would block ship tasks with no run.
  out=$(fm_nm_run "$wt" "$NM_TEARDOWN_TIMEOUT" axi status)
  task_status_is_own_parked_run "$wt" "$out"
}

task_status_is_terminal_run() {  # <axi-status-output> <run-id>
  local out=$1 expected_id=$2 run_id outcome
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ "$run_id" = "$expected_id" ] || return 1
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  case "$outcome" in
    cancelled|failed|passed|checks-passed) return 0 ;;
  esac
  return 1
}

task_status_is_run_not_found() {  # <status-error> <run-id>
  local actual expected
  actual=$(fm_nm_trim "$1")
  expected=$(printf 'error: "run \\"%s\\" not found"' "$2")
  [ "$actual" = "$expected" ]
}

# Abort THIS task's own parked no-mistakes run before the worker that would
# have answered its gate is removed, so no run is left orphaned holding a
# fleet slot. Only KIND=ship drives a no-mistakes validation of its own
# worktree (scouts and secondmates never do, mirroring bin/fm-crew-state.sh);
# a run not attributed to this exact branch+head is left completely alone.
conclude_task_no_mistakes_run() {  # <worktree>
  local wt=$1 out run_id
  [ "$KIND" = ship ] || return 0
  [ -d "$wt" ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  task_run_is_own_parked_run "$wt" || return 0
  run_id=$TASK_RUN_ID
  echo "teardown: no-mistakes run for $ID is parked at a gate; aborting before the worker is removed" >&2
  # Accepted best-effort residual: abort supports run-id targeting but no atomic
  # live-state condition; fully closing the resume race needs upstream compare-and-cancel.
  fm_nm_run_checked "$wt" "$NM_TEARDOWN_TIMEOUT" axi abort --run "$run_id" >/dev/null 2>&1 || true
  if out=$(fm_nm_run_bounded "$wt" "$NM_TEARDOWN_TIMEOUT" axi status --run "$run_id" 2>&1); then
    task_status_is_terminal_run "$out" "$run_id" && return 0
  elif task_status_is_run_not_found "$out" "$run_id"; then
    return 0
  fi
  echo "REFUSED: no-mistakes run for $ID is still parked after axi abort; confirm it stopped (no-mistakes axi status) or abort it manually (no-mistakes axi abort --run <id>) before retrying teardown." >&2
  return 1
}

# Fix 2 (see script header): pids of every process whose CURRENT WORKING
# DIRECTORY is exactly $1 or under it, from one bounded system-wide `lsof -a
# -d cwd` scan (never the recursive +D file-tree walk, which lsof itself
# documents as slow). Never $$ (this script's own pid). Empty output when
# nothing matches; failure means the scan could not establish a safe result.
pids_with_cwd_under() {  # <dir>
  local dir=$1 out pid path line
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  dir=$(cd "$dir" && pwd -P) || return 1
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
            [ -n "$pid" ] && [ "$pid" != "$$" ] && printf '%s\n' "$pid"
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

task_process_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value
  local -a stat_fields
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value=$(fm_nm_trim "$value")
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$value"
}

task_process_identity_matches() {  # <pid> <identity>
  local current
  current=$(task_process_identity "$1") || return 1
  [ "$current" = "$2" ]
}

task_pid_list_contains() {  # <pid-list> <pid>
  printf '%s\n' "$1" | grep -Fxq "$2"
}

task_pids_under_roots() {  # <dir>...
  TASK_PIDS=
  TASK_PIDS_FAILED_DIR=
  local dir dir_pids pids=""
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    if ! dir_pids=$(pids_with_cwd_under "$dir"); then
      TASK_PIDS_FAILED_DIR=$dir
      return 1
    fi
    pids="$pids
$dir_pids"
  done
  TASK_PIDS=$(printf '%s\n' "$pids" | grep -E '^[0-9]+$' | sort -un || true)
}

reap_task_backend_process_group() {  # <label>
  local label=$1 leader leader_start pgid current_pgid own_pgid
  if [ "$BACKEND" != tmux ]; then
    echo "warning: lsof is unavailable; cannot resolve a process-group fallback for $BACKEND task $ID" >&2
    return 0
  fi
  leader=$(tmux display-message -p -t "$T" '#{pane_pid}' 2>/dev/null) || leader=""
  case "$leader" in ''|*[!0-9]*)
    echo "warning: lsof is unavailable; cannot resolve the tmux pane process group for $ID" >&2
    return 0
    ;;
  esac
  leader_start=$(task_process_identity "$leader") || {
    echo "warning: lsof is unavailable; cannot identify the tmux pane process group for $ID" >&2
    return 0
  }
  pgid=$(ps -o pgid= -p "$leader" 2>/dev/null) || pgid=""
  pgid=$(printf '%s' "$pgid" | tr -d '[:space:]')
  case "$pgid" in ''|*[!0-9]*|0|1)
    echo "warning: lsof is unavailable; cannot resolve the tmux pane process group for $ID" >&2
    return 0
    ;;
  esac
  own_pgid=$(ps -o pgid= -p "$$" 2>/dev/null) || own_pgid=""
  own_pgid=$(printf '%s' "$own_pgid" | tr -d '[:space:]')
  if [ "$pgid" = "$own_pgid" ]; then
    echo "warning: lsof is unavailable; refusing to signal teardown's own process group for $ID" >&2
    return 0
  fi
  task_process_identity_matches "$leader" "$leader_start" || return 0
  current_pgid=$(ps -o pgid= -p "$leader" 2>/dev/null) || current_pgid=""
  current_pgid=$(printf '%s' "$current_pgid" | tr -d '[:space:]')
  [ "$current_pgid" = "$pgid" ] || return 0
  echo "teardown: reaping leaked $label process group for $ID: $pgid" >&2
  kill -TERM -- "-$pgid" 2>/dev/null || true
  sleep 1
  if task_process_identity_matches "$leader" "$leader_start" \
     && [ "$(ps -o pgid= -p "$leader" 2>/dev/null | tr -d '[:space:]')" = "$pgid" ] \
     && kill -0 -- "-$pgid" 2>/dev/null; then
    echo "teardown: force-killing leaked $label process group for $ID: $pgid" >&2
    kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
}

# Reap every process rooted (by cwd) under this task's own worktree or tasktmp
# - both unique per task and never shared - before either is removed. TERM
# first, then KILL after a short grace period for anything still alive; a
# process that exits on its own between the two passes is simply absent from
# the recheck. A missing lsof uses the backend process-group fallback; an lsof
# scan error refuses before destructive teardown.
reap_task_worktree_processes() {  # <label> <dir>...
  local label=$1 pids pid identity current_pids i pass=1 max_passes=3
  local -a tracked_pids tracked_identities remaining_pids remaining_identities
  shift
  if ! command -v lsof >/dev/null 2>&1; then
    reap_task_backend_process_group "$label"
    return 0
  fi
  while [ "$pass" -le "$max_passes" ]; do
    if ! task_pids_under_roots "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    pids=$TASK_PIDS
    [ -n "$pids" ] || return 0
    tracked_pids=()
    tracked_identities=()
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      if ! identity=$(task_process_identity "$pid"); then
        if ! task_pids_under_roots "$@"; then
          echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
          return 1
        fi
        if task_pid_list_contains "$TASK_PIDS" "$pid"; then
          echo "REFUSED: cannot verify leaked process $pid identity for $ID; preserving the worktree/tasktmp for manual inspection or retry." >&2
          return 1
        fi
        continue
      fi
      tracked_pids+=("$pid")
      tracked_identities+=("$identity")
    done <<EOF
$pids
EOF
    if [ "${#tracked_pids[@]}" -eq 0 ]; then
      pass=$((pass + 1))
      continue
    fi
    if ! task_pids_under_roots "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    current_pids=$TASK_PIDS
    echo "teardown: reaping leaked $label process(es) for $ID: $(printf '%s' "$pids" | tr '\n' ' ')" >&2
    for i in "${!tracked_pids[@]}"; do
      pid=${tracked_pids[$i]}
      identity=${tracked_identities[$i]}
      if task_pid_list_contains "$current_pids" "$pid" \
         && task_process_identity_matches "$pid" "$identity"; then
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done
    sleep 1
    if ! task_pids_under_roots "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    current_pids=$TASK_PIDS
    remaining_pids=()
    remaining_identities=()
    for i in "${!tracked_pids[@]}"; do
      pid=${tracked_pids[$i]}
      identity=${tracked_identities[$i]}
      if task_pid_list_contains "$current_pids" "$pid" \
         && task_process_identity_matches "$pid" "$identity"; then
        remaining_pids+=("$pid")
        remaining_identities+=("$identity")
      fi
    done
    if [ "${#remaining_pids[@]}" -gt 0 ]; then
      echo "teardown: force-killing leaked $label process(es) for $ID: ${remaining_pids[*]}" >&2
      if ! task_pids_under_roots "$@"; then
        echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
        return 1
      fi
      current_pids=$TASK_PIDS
      for i in "${!remaining_pids[@]}"; do
        pid=${remaining_pids[$i]}
        identity=${remaining_identities[$i]}
        if task_pid_list_contains "$current_pids" "$pid" \
           && task_process_identity_matches "$pid" "$identity"; then
          kill -KILL "$pid" 2>/dev/null || true
        fi
      done
    fi
    pass=$((pass + 1))
  done
  if ! task_pids_under_roots "$@"; then
    echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID (lsof failed); preserving the worktree/tasktmp for manual inspection or retry." >&2
    return 1
  fi
  [ -z "$TASK_PIDS" ] && return 0
  echo "REFUSED: leaked $label processes for $ID remain after $max_passes reap attempts; preserving the worktree/tasktmp for manual inspection or retry." >&2
  return 1
}

require_orca_worktree_path_match() {
  local worktree_id=$1 inspected=$2 resolved inspected_abs resolved_abs
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

# The task's own live slot, canonicalized, or empty when this record has no slot
# to release (a secondmate home, a record with no worktree=, or a path that is
# already gone). Every slot-ownership check below is scoped to that value, so a
# record with nothing live to return skips them rather than refusing.
teardown_live_slot_path() {
  [ "$KIND" != secondmate ] || return 1
  is_treehouse_pool_slot "$PROJ" "$WT" || return 1
  canonical_existing_dir "$WT"
}

collect_local_firstmate_states() {
  local record_state=$1 root home reg line child known existing i=0
  local -a homes
  TREEHOUSE_OWNER_STATES=("$record_state")
  root=$(fm_firstmate_root_home "$FM_HOME") || {
    echo "REFUSED: cannot resolve the root Firstmate home; nothing was changed" >&2
    return 1
  }
  homes=("$root")
  while [ "$i" -lt "${#homes[@]}" ]; do
    home=${homes[$i]}
    i=$((i + 1))
    known=0
    for existing in "${TREEHOUSE_OWNER_STATES[@]}"; do
      [ "$existing" != "$home/state" ] || known=1
    done
    [ "$known" = 1 ] || TREEHOUSE_OWNER_STATES+=("$home/state")
    reg="$home/data/secondmates.md"
    [ ! -e "$reg" ] && [ ! -L "$reg" ] && continue
    [ -f "$reg" ] && [ ! -L "$reg" ] || {
      echo "REFUSED: local Firstmate registry is unsafe at $reg; nothing was changed" >&2
      return 1
    }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "- "*)
          secondmate_registry_parse_line "$line" || {
            echo "REFUSED: malformed local Firstmate registry entry in $reg; nothing was changed" >&2
            return 1
          }
          [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
          child=$(canonical_existing_dir "$SECONDMATE_REGISTRY_HOME") || {
            echo "REFUSED: registered local Firstmate home is unavailable: $SECONDMATE_REGISTRY_HOME; nothing was changed" >&2
            return 1
          }
          known=0
          for existing in "${homes[@]}"; do
            [ "$existing" != "$child" ] || known=1
          done
          [ "$known" = 1 ] || homes+=("$child")
          ;;
      esac
    done < "$reg"
  done
}

require_exclusive_worktree_slot_record() {
  local record_meta=$1 record_id=$2 record_state=$3 worktree=$4
  local slot state_dir other other_id field other_path other_slot
  slot=$(canonical_existing_dir "$worktree") || return 0
  collect_local_firstmate_states "$record_state" || return 1
  for state_dir in "${TREEHOUSE_OWNER_STATES[@]}"; do
    for other in "$state_dir"/*.meta; do
      [ -f "$other" ] && [ ! -L "$other" ] || continue
      [ "$other" != "$record_meta" ] || continue
      other_id=$(basename "$other" .meta)
      for field in worktree home; do
        other_path=$(fm_meta_get "$other" "$field")
        [ -n "$other_path" ] || continue
        other_slot=$(canonical_existing_dir "$other_path") || continue
        [ "$other_slot" = "$slot" ] || continue
        echo "REFUSED: task $record_id's recorded worktree $slot is also task $other_id's recorded $field." >&2
        echo "Returning that pool slot would kill $other_id's processes and reset its copy, so nothing was changed - not even with --force." >&2
        echo "Reconcile whichever record is wrong (bin/fm-crew-state.sh $record_id; bin/fm-crew-state.sh $other_id), then re-run teardown." >&2
        return 1
      done
    done
  done
}

require_exclusive_task_worktree_slot() {
  local slot
  slot=$(teardown_live_slot_path) || return 0
  require_exclusive_worktree_slot_record "$META" "$ID" "$STATE" "$slot"
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
  if ! secondmate_registry_validate_bindings "$reg" secondmate_registry_path_key; then
    echo "REFUSED: $SECONDMATE_REGISTRY_ERROR" >&2
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*)
        secondmate_registry_parse_line "$line" || {
          echo "REFUSED: malformed secondmate registry entry: $line" >&2
          return 2
        }
        id=$SECONDMATE_REGISTRY_ID
        registered_home=$SECONDMATE_REGISTRY_HOME
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
    if [ -e "$SECONDMATE_REG" ] || [ -L "$SECONDMATE_REG" ]; then
      if ! secondmate_registry_validate_bindings "$SECONDMATE_REG" secondmate_registry_path_key "$expected_id" "$abs_home_path"; then
        case "$SECONDMATE_REGISTRY_ERROR" in
          overlapping\ secondmate\ home\ assignment:*)
            echo "REFUSED: unsafe $label removal target $home contains registered secondmate home; $SECONDMATE_REGISTRY_ERROR" >&2
            ;;
          *) echo "REFUSED: $SECONDMATE_REGISTRY_ERROR" >&2 ;;
        esac
        return 1
      fi
    fi
  fi
  validate_firstmate_operational_dirs_for_removal "$abs_home_path" "$label" || return 1
  conflict=
  if conflict=$(registered_descendant_home_for_removal "$SECONDMATE_REG" "$abs_home_path"); then
    :
  else
    conflict_rc=$?
    [ "$conflict_rc" -eq 1 ] || return 1
  fi
  if [ -z "$conflict" ]; then
    if conflict=$(registered_descendant_home_for_removal "$abs_home_path/data/secondmates.md" "$abs_home_path"); then
      :
    else
      conflict_rc=$?
      [ "$conflict_rc" -eq 1 ] || return 1
    fi
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

remove_firstmate_home() {
  local home=$1 label=$2 expected_id=${3:-} abs_home_path process_event_backup
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id") || return 1
  [ -n "$abs_home_path" ] || return 0
  process_event_backup=$(snapshot_firstmate_home_process_events "$abs_home_path" "$label") || return 1
  if ! cleanup_firstmate_home_process_events "$abs_home_path" "$label"; then
    restore_firstmate_home_process_events "$abs_home_path" "$label" "$process_event_backup" || return $?
    return 1
  fi
  if firstmate_home_has_treehouse_slot "$abs_home_path"; then
    command -v treehouse >/dev/null 2>&1 || {
      echo "error: treehouse command not found; cannot return $label $abs_home_path" >&2
      restore_firstmate_home_process_events "$abs_home_path" "$label" "$process_event_backup" || return $?
      return 1
    }
    teardown_treehouse_return "$abs_home_path" "$FM_ROOT" "$label" "" "$FM_ROOT" || {
      echo "error: treehouse return failed for $label $abs_home_path; lease may still be held" >&2
      restore_firstmate_home_process_events "$abs_home_path" "$label" "$process_event_backup" || return $?
      return 1
    }
    [ -z "$process_event_backup" ] || rm -rf -- "$process_event_backup"
    return 0
  fi
  if safe_rm_rf "$abs_home_path" "$label"; then
    [ -z "$process_event_backup" ] || rm -rf -- "$process_event_backup"
    return 0
  fi
  restore_firstmate_home_process_events "$abs_home_path" "$label" "$process_event_backup" || return $?
  return 1
}

firstmate_home_has_process_events() {
  local home=$1 path owner claim_root
  for path in "$home/state/procevent"/*.source "$home/state/procevent"/*.runner; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      return 0
    fi
  done
  claim_root=${FM_PROCEVENT_CLAIM_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/procevent-claims}
  for path in "$claim_root"/*.claim; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    IFS= read -r owner < "$path" 2>/dev/null || continue
    [ "$owner" = "$home" ] && return 0
  done
  return 1
}

snapshot_firstmate_home_process_events() {
  local home=$1 label=$2 backup path
  if ! firstmate_home_has_process_events "$home"; then
    printf '\n'
    return 0
  fi
  backup=$(umask 077; mktemp -d "${home%/*}/.fm-procevent-restore.XXXXXX") || {
    echo "REFUSED: cannot stage recoverable process-event state for $label $home" >&2
    return 1
  }
  for path in "$home/state/procevent"/*.source; do
    [ -e "$path" ] || continue
    if [ ! -f "$path" ] || [ -L "$path" ] || ! cp -p -- "$path" "$backup/"; then
      rm -rf -- "$backup"
      echo "REFUSED: cannot preserve process-event registrations for $label $home" >&2
      return 1
    fi
  done
  printf '%s\n' "$backup"
}

restore_firstmate_home_process_events() {
  local home=$1 label=$2 backup=$3 reg source tmp runner
  [ -n "$backup" ] || return 0
  [ -d "$backup" ] && [ ! -L "$backup" ] || {
    echo "error: process-event restoration failed for $label $home; recovery backup is unavailable at $backup" >&2
    return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
  }
  reg="$home/state/procevent"
  (umask 077; mkdir -p "$reg") || {
    echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
    return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
  }
  [ -d "$reg" ] && [ ! -L "$reg" ] || {
    echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
    return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
  }
  for source in "$backup"/*.source; do
    [ -e "$source" ] || continue
    [ -f "$source" ] && [ ! -L "$source" ] || {
      echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
      return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
    }
    tmp=$(umask 077; mktemp "$reg/.restore.XXXXXX") || {
      echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
      return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
    }
    if ! cp -- "$source" "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$reg/${source##*/}"; then
      rm -f -- "$tmp"
      echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
      return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
    fi
  done
  runner="$home/bin/fm-procevent.sh"
  if [ ! -f "$runner" ] || [ -L "$runner" ] || [ ! -x "$runner" ]; then
    runner="$SCRIPT_DIR/fm-procevent.sh"
  fi
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$FM_ROOT" "$runner" reconcile >/dev/null; then
    echo "error: process-event restoration could not rearm $label $home; active waits may remain retired; recover registrations from $backup" >&2
    return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
  fi
  rm -rf -- "$backup"
}

cleanup_firstmate_home_process_events() {
  local home=$1 label=$2 runner="$1/bin/fm-procevent.sh"
  firstmate_home_has_process_events "$home" || return 0
  if [ ! -f "$runner" ] || [ -L "$runner" ] || [ ! -x "$runner" ]; then
    echo "REFUSED: $label $home has process-event state but no sweep-capable bin/fm-procevent.sh; restore the home script and rerun teardown" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$runner" sweep-home; then
    echo "REFUSED: process-event cleanup is incomplete for $label $home; preserving the home, lease, and retirement records for retry" >&2
    return 1
  fi
  if firstmate_home_has_process_events "$home"; then
    echo "REFUSED: process-event state remains for $label $home after its bounded sweep; preserving the home, lease, and retirement records for retry" >&2
    return 1
  fi
}

preflight_firstmate_home_process_events() {
  local home=$1 label=$2 runner="$1/bin/fm-procevent.sh"
  firstmate_home_has_process_events "$home" || return 0
  if [ ! -f "$runner" ] || [ -L "$runner" ] || [ ! -x "$runner" ]; then
    echo "REFUSED: $label $home has process-event state but no sweep-capable bin/fm-procevent.sh; restore the home script and rerun teardown" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$runner" sweep-home --preflight >/dev/null; then
    echo "REFUSED: process-event cleanup cannot safely proceed for $label $home; preserving the home, lease, and retirement records for retry" >&2
    return 1
  fi
}

preflight_firstmate_home_process_event_tree() {
  local home=$1 label=$2 sub_state child_meta child_kind child_home child_wt child_id
  sub_state="$home/state"
  if [ -d "$sub_state" ]; then
    for child_meta in "$sub_state"/*.meta; do
      [ -e "$child_meta" ] || continue
      child_kind=$(meta_value "$child_meta" kind)
      [ "$child_kind" = secondmate ] || continue
      child_id=$(basename "$child_meta" .meta)
      child_wt=$(meta_value "$child_meta" worktree)
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      preflight_firstmate_home_process_event_tree "$child_home" "child firstmate home for $child_id" || return 1
    done
  fi
  preflight_firstmate_home_process_events "$home" "$label"
}

collect_descendant_task_locks() {
  local home=$1 sub_state child_meta child_id child_kind child_wt child_home task_set_lock
  local -a child_ids
  sub_state="$home/state"
  if [ -L "$sub_state" ]; then
    echo "REFUSED: secondmate home $home has a symbolic-link state path at $sub_state; forced teardown changed nothing" >&2
    return 1
  fi
  if [ -e "$sub_state" ] && [ ! -d "$sub_state" ]; then
    echo "REFUSED: secondmate home $home has a non-directory state path at $sub_state; forced teardown changed nothing" >&2
    return 1
  fi
  if ! mkdir -p -- "$sub_state"; then
    echo "REFUSED: secondmate home $home state directory could not be established at $sub_state; forced teardown changed nothing" >&2
    return 1
  fi
  if [ -L "$sub_state" ] || [ ! -d "$sub_state" ]; then
    echo "REFUSED: secondmate home $home state path is not a safe directory at $sub_state; forced teardown changed nothing" >&2
    return 1
  fi
  # Freeze this home's task SET before reading it. Everything below locks the
  # tasks that exist right now, but the later cleanup re-enumerates, so without
  # this a fresh spawn could publish a record into the gap and be mutated
  # without ever having been lifecycle-locked (bin/fm-wake-lib.sh's
  # fm_task_set_lock_path owns why). Taken per home, parent before child, and
  # held until this teardown exits.
  task_set_lock=$(fm_task_set_lock_path "$sub_state") || {
    echo "REFUSED: secondmate home $home has an invalid task-set lock path; forced teardown changed nothing" >&2
    return 1
  }
  if ! fm_lock_try_acquire "$task_set_lock"; then
    echo "REFUSED: secondmate home $home is publishing a task right now (task-set lock is held); forced teardown changed nothing" >&2
    return 1
  fi
  DESCENDANT_LOCK_PATHS+=("$task_set_lock")
  child_ids=()
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_ids+=("$(basename "$child_meta" .meta)")
  done
  [ "${#child_ids[@]}" -gt 0 ] || return 0
  while IFS= read -r child_id; do
    child_meta="$sub_state/$child_id.meta"
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_home=
    if [ "$child_kind" = secondmate ]; then
      child_wt=$(meta_value "$child_meta" worktree)
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
    fi
    DESCENDANT_TASK_STATES+=("$sub_state")
    DESCENDANT_TASK_IDS+=("$child_id")
    DESCENDANT_TASK_KINDS+=("$child_kind")
    DESCENDANT_TASK_HOMES+=("$child_home")
    [ "$child_kind" != secondmate ] \
      || collect_descendant_task_locks "$child_home" \
      || return 1
  done < <(printf '%s\n' "${child_ids[@]}" | LC_ALL=C sort)
}

preflight_descendant_task_locks() {
  local home=$1 i state task_id meta control_lock meta_lock kind child_wt child_home
  DESCENDANT_TASK_STATES=()
  DESCENDANT_TASK_IDS=()
  DESCENDANT_TASK_KINDS=()
  DESCENDANT_TASK_HOMES=()
  DESCENDANT_TREEHOUSE_LOCK_PATHS=()
  collect_descendant_task_locks "$home" || return 1
  # Acquisition order, which every other holder of these locks must match so
  # they cannot cycle: each home's task-set lock first (parent home before child
  # home, during collection above), then per-task locks in that same
  # parent-before-child preorder, sorted by id within each home, each control
  # lock before its matching metadata lock. No child lock holder ever reaches
  # back for a parent lock. bin/fm-spawn.sh takes the same task-set lock before
  # its own per-task locks when it publishes a fresh record.
  for ((i=0; i < ${#DESCENDANT_TASK_IDS[@]}; i++)); do
    state=${DESCENDANT_TASK_STATES[$i]}
    task_id=${DESCENDANT_TASK_IDS[$i]}
    meta="$state/$task_id.meta"
    control_lock="$state/.control-$task_id.lock"
    meta_lock=$(fm_meta_lock_path "$meta") || {
      echo "REFUSED: descendant task $task_id has an invalid metadata lock path; forced teardown changed nothing" >&2
      return 1
    }
    if ! fm_lock_try_acquire "$control_lock"; then
      echo "REFUSED: descendant task $task_id has a lifecycle action in flight (control lock is held); forced teardown changed nothing" >&2
      return 1
    fi
    DESCENDANT_LOCK_PATHS+=("$control_lock")
    if ! fm_lock_try_acquire "$meta_lock"; then
      echo "REFUSED: descendant task $task_id has a metadata update in flight (metadata lock is held); forced teardown changed nothing" >&2
      return 1
    fi
    DESCENDANT_LOCK_PATHS+=("$meta_lock")
    [ -f "$meta" ] || {
      echo "REFUSED: descendant task $task_id changed while forced teardown acquired its locks; forced teardown changed nothing" >&2
      return 1
    }
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    [ "$kind" = "${DESCENDANT_TASK_KINDS[$i]}" ] || {
      echo "REFUSED: descendant task $task_id changed kind while forced teardown acquired its locks; forced teardown changed nothing" >&2
      return 1
    }
    if [ "$kind" = secondmate ]; then
      child_wt=$(meta_value "$meta" worktree)
      child_home=$(meta_value "$meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      [ "$child_home" = "${DESCENDANT_TASK_HOMES[$i]}" ] || {
        echo "REFUSED: descendant task $task_id changed home while forced teardown acquired its locks; forced teardown changed nothing" >&2
        return 1
      }
    fi
  done
}

preflight_descendant_treehouse_slots() {
  local i state task_id meta kind backend target worktree project lock_path held
  for ((i=0; i < ${#DESCENDANT_TASK_IDS[@]}; i++)); do
    state=${DESCENDANT_TASK_STATES[$i]}
    task_id=${DESCENDANT_TASK_IDS[$i]}
    meta="$state/$task_id.meta"
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    backend=$(fm_backend_of_meta "$meta")
    worktree=$(meta_value "$meta" worktree)
    project=$(meta_value "$meta" project)
    if [ "$kind" = secondmate ] || [ "$backend" = orca ]; then
      continue
    fi
    if ! is_treehouse_pool_slot "$project" "$worktree"; then
      continue
    fi
    lock_path=$(fm_treehouse_project_lock_path "$project") || {
      echo "REFUSED: cannot resolve the shared Treehouse project lock for child $task_id; forced teardown changed nothing" >&2
      return 1
    }
    held=0
    [ "$TREEHOUSE_PROJECT_LOCK_HELD" != 1 ] || [ "$TREEHOUSE_PROJECT_LOCK" != "$lock_path" ] || held=1
    for target in "${DESCENDANT_TREEHOUSE_LOCK_PATHS[@]}"; do
      [ "$target" != "$lock_path" ] || held=1
    done
    if [ "$held" = 0 ]; then
      fm_lock_try_acquire "$lock_path" || {
        echo "REFUSED: another Treehouse slot allocation or return is in progress for child $task_id; forced teardown changed nothing" >&2
        return 1
      }
      DESCENDANT_TREEHOUSE_LOCK_PATHS+=("$lock_path")
      DESCENDANT_LOCK_PATHS+=("$lock_path")
    fi
  done
  for ((i=0; i < ${#DESCENDANT_TASK_IDS[@]}; i++)); do
    state=${DESCENDANT_TASK_STATES[$i]}
    task_id=${DESCENDANT_TASK_IDS[$i]}
    meta="$state/$task_id.meta"
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    backend=$(fm_backend_of_meta "$meta")
    worktree=$(meta_value "$meta" worktree)
    project=$(meta_value "$meta" project)
    if [ "$kind" = secondmate ] || [ "$backend" = orca ]; then
      continue
    fi
    if ! is_treehouse_pool_slot "$project" "$worktree"; then
      continue
    fi
    fm_backend_validate_task_endpoint "$meta" "$task_id" || return 1
    require_exclusive_worktree_slot_record "$meta" "$task_id" "$state" "$worktree" || return 1
  done
}

validate_firstmate_home_children_removal() {
  local home=$1 sub_state child_meta child_id child_wt child_proj child_kind child_home child_backend child_orca_worktree_id
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    fm_backend_validate_task_endpoint "$child_meta" "$child_id" || return 1
    validate_pr_poll_cleanup "$sub_state" "$child_id" || return 1
    child_wt=$(meta_value "$child_meta" worktree)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_backend=$(fm_backend_of_meta "$child_meta")
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      validate_firstmate_home_for_removal "$child_home" "child firstmate home" "$child_id" >/dev/null || return 1
      validate_firstmate_home_children_removal "$child_home" || return 1
    elif [ "$child_backend" = orca ]; then
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        child_proj=$(meta_value "$child_meta" project)
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        require_orca_worktree_path_match "$child_orca_worktree_id" "$child_wt" || return 1
      fi
    elif [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
      child_proj=$(meta_value "$child_meta" project)
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
    fi
  done
}

TEARDOWN_HERDR_LOCK_RECORDS=
teardown_release_herdr_locks() {
  local lock_session lock_path
  [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ] || return 0
  while IFS=$'\t' read -r lock_session lock_path; do
    [ -n "$lock_path" ] || continue
    fm_lock_release "$lock_path" || true
  done <<FMEOF
$TEARDOWN_HERDR_LOCK_RECORDS
FMEOF
  TEARDOWN_HERDR_LOCK_RECORDS=
}

teardown_herdr_session_lock_held() {  # <session>
  local session=$1 lock_session lock_path
  [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ] || return 1
  while IFS=$'\t' read -r lock_session lock_path; do
    [ "$lock_session" != "$session" ] || return 0
  done <<FMEOF
$TEARDOWN_HERDR_LOCK_RECORDS
FMEOF
  return 1
}

teardown_herdr_require_prerequisites() {  # <task-id>
  local task_id=$1 prerequisite adapter
  adapter="$FM_BACKEND_LIB_DIR/backends/herdr.sh"
  if [ ! -r "$adapter" ] || ! fm_backend_source herdr; then
    echo "error: herdr teardown prerequisites are unavailable for $task_id; nothing was changed - restore the adapter and rerun teardown" >&2
    return 1
  fi
  for prerequisite in \
    fm_backend_herdr_parse_target \
    fm_backend_herdr_pane_presence_state \
    fm_backend_herdr_workspace_presence_state \
    fm_backend_herdr_endpoint_confirmed_gone \
    fm_backend_herdr_explicit_close_pane_confirmed \
    fm_backend_herdr_presentation_session_lock_path; do
    if ! declare -F "$prerequisite" >/dev/null 2>&1; then
      echo "error: herdr teardown prerequisites are unavailable for $task_id; nothing was changed - restore the adapter and rerun teardown" >&2
      return 1
    fi
  done
  if ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
  fi
  if ! declare -F fm_lock_try_acquire >/dev/null 2>&1 \
    || ! declare -F fm_lock_release >/dev/null 2>&1; then
    echo "error: herdr teardown lock machinery is unavailable for $task_id; nothing was changed - restore the lock support and rerun teardown" >&2
    return 1
  fi
}

teardown_herdr_preflight_target() {  # <target> <task-id>
  local target=$1 task_id=$2 session pane presence lock_path verified_lock_path lock_session held_path attempt
  teardown_herdr_require_prerequisites "$task_id" || return 1
  if ! fm_backend_herdr_parse_target "$target"; then
    echo "error: herdr endpoint $target for $task_id could not be parsed exactly; nothing was changed - repair the endpoint metadata and rerun teardown" >&2
    return 1
  fi
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane")
  case "$presence" in
    dead|present) ;;
    *)
      echo "error: herdr endpoint $target for $task_id has ambiguous structured presence; nothing was changed - restore reliable endpoint inspection and rerun teardown" >&2
      return 1
      ;;
  esac
  if ! lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session"); then
    echo "error: herdr session presentation lock could not be resolved for $task_id; nothing was changed - rerun teardown once the session is reachable and unambiguous" >&2
    return 1
  fi
  if [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ]; then
    while IFS=$'\t' read -r lock_session held_path; do
      if [ "$lock_session" = "$session" ]; then
        if [ "$held_path" != "$lock_path" ]; then
          echo "error: herdr session presentation lock changed during preflight for $task_id; nothing was changed - rerun teardown once session identity is stable" >&2
          return 1
        fi
        return 0
      fi
    done <<FMEOF
$TEARDOWN_HERDR_LOCK_RECORDS
FMEOF
  fi
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    if fm_lock_try_acquire "$lock_path"; then
      if ! verified_lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session") \
        || [ "$verified_lock_path" != "$lock_path" ]; then
        fm_lock_release "$lock_path" || true
        echo "error: herdr session presentation lock changed during preflight for $task_id; nothing was changed - rerun teardown once session identity is stable" >&2
        return 1
      fi
      if [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ]; then
        TEARDOWN_HERDR_LOCK_RECORDS="$TEARDOWN_HERDR_LOCK_RECORDS
$session	$lock_path"
      else
        TEARDOWN_HERDR_LOCK_RECORDS="$session	$lock_path"
      fi
      return 0
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  echo "error: herdr session presentation lock is contended for $task_id; nothing was changed - rerun teardown once the contention clears" >&2
  return 1
}

preflight_firstmate_home_herdr_children() {  # <home>
  local home=$1 sub_state child_meta child_id child_backend child_target child_kind child_home child_wt
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    fm_backend_validate_task_endpoint "$child_meta" "$child_id" || return 1
    child_backend=$FM_BACKEND_VALIDATED_BACKEND
    child_target=$FM_BACKEND_VALIDATED_TARGET
    if [ "$child_backend" = herdr ]; then
      teardown_herdr_preflight_target "$child_target" "$child_id" || return 1
    fi
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    if [ "$child_kind" = secondmate ]; then
      child_wt=$(meta_value "$child_meta" worktree)
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      preflight_firstmate_home_herdr_children "$child_home" || return 1
    fi
  done
}

cleanup_firstmate_home_children() {
  local home=$1 sub_state child_meta child_id child_t child_wt child_proj child_kind child_home child_backend child_orca_worktree_id child_return_rc child_busy_gen
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    child_wt=$(meta_value "$child_meta" worktree)
    child_proj=$(meta_value "$child_meta" project)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_backend=$(fm_backend_of_meta "$child_meta")
    if [ "$child_backend" = orca ]; then
      child_t=$(meta_value "$child_meta" terminal)
    else
      child_t=$(fm_backend_target_of_meta "$child_meta")
    fi
    if [ "$child_backend" = orca ] && [ "$child_kind" != secondmate ]; then
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      fi
    fi
    if [ -n "$child_t" ]; then
      if [ "$child_backend" = herdr ]; then
        fm_backend_herdr_parse_target "$child_t" || return 1
        if ! teardown_herdr_session_lock_held "$FM_BACKEND_HERDR_SESSION"; then
          echo "error: herdr session presentation lock is not held for child $child_id; retaining that child's durable identity records and stopping forced cleanup" >&2
          return 1
        fi
        fm_backend_herdr_kill_serialized "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" 2>/dev/null || true
        if ! fm_backend_herdr_endpoint_confirmed_gone "$child_t"; then
          echo "error: herdr pane $child_t for child $child_id is not confirmed gone; retaining that child's durable identity records and stopping forced cleanup" >&2
          return 1
        fi
      elif [ "$child_backend" = zellij ]; then
        # Zellij titles are scoped by the owning home tag, so forced secondmate
        # cleanup must verify child tabs as that child home, not the parent.
        ( unset FM_ROOT_OVERRIDE; FM_HOME=$home FM_ROOT=$home fm_backend_kill "$child_backend" "$child_t" "$(meta_value "$child_meta" zellij_tab_id)" "fm-$child_id" ) 2>/dev/null || true
      else
        fm_backend_kill "$child_backend" "$child_t" "$(meta_value "$child_meta" zellij_tab_id)" "fm-$child_id" 2>/dev/null || true
      fi
    fi
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      if [ -n "$child_home" ] && [ -d "$child_home" ]; then
        cleanup_firstmate_home_children "$child_home" || return $?
        remove_firstmate_home "$child_home" "child firstmate home" "$child_id" || return $?
      fi
    elif [ "$child_backend" = orca ]; then
      if [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" \
          "$child_wt/.fm-grok-turnend" "$child_wt/.fm-kimi-turnend"
      fi
      fm_backend_remove_worktree "$child_backend" "$child_orca_worktree_id" || return 1
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" \
        "$child_wt/.opencode/plugins/fm-busy-state.js" \
        "$child_wt/.fm-grok-turnend" "$child_wt/.fm-kimi-turnend"
      if [ -n "$child_proj" ] && [ -d "$child_proj" ] && command -v treehouse >/dev/null 2>&1; then
        if teardown_treehouse_return "$child_wt" "$child_proj" "child worktree" "" "$home"; then
          :
        else
          child_return_rc=$?
          if [ "$child_return_rc" -eq "$TEARDOWN_TREEHOUSE_LOCK_REFUSED" ]; then
            return "$child_return_rc"
          fi
          safe_rm_rf_child_worktree "$child_wt" "$child_proj"
        fi
      else
        safe_rm_rf_child_worktree "$child_wt" "$child_proj"
      fi
    fi
    remove_grok_turnend_auth "$sub_state" "$child_id" || return 1
    remove_kimi_turnend_auth "$sub_state" "$child_id" || return 1
    remove_pr_poll_artifacts "$sub_state" "$child_id" || return 1
    child_busy_gen=$(meta_value "$child_meta" busy_gen)
    if [ -z "$child_busy_gen" ]; then
      child_busy_gen=$(cat "$sub_state/$child_id.busy-gen" 2>/dev/null || true)
    fi
    retire_busy_state "$sub_state" "$child_id" "$child_busy_gen" || return 1
    status_retire_presentation_task "$sub_state" "$child_id" || return 1
    fm_backlog_atomic_transition remove "$sub_state/$child_id.meta" "task record" "$sub_state" || return 1
    rm -f "$sub_state/$child_id.turn-ended" \
      "$sub_state/$child_id.pi-ext.ts" "$sub_state/$child_id.omp-ext.ts" \
      "$sub_state/$child_id.grok-turnend-token" "$sub_state/$child_id.kimi-turnend-token" \
      "$sub_state/$child_id.muse-session" "$sub_state/$child_id.muse-session-current" \
      "$sub_state/$child_id.cursor-session" "$sub_state/$child_id.reconcile-nudged" \
      "$sub_state/.$child_id.branch-outcome-index"
  done
}

remove_secondmate_registry_entry() {
  local id=$1 tmp lock rc=0 acquired=0
  [ -f "$SECONDMATE_REG" ] || return 0
  lock=$(secondmate_registry_lock_path "$STATE")
  if [ "$LOCAL_REGISTRY_LOCK" != "$lock" ]; then
    fm_lock_acquire_wait "$lock" || return 1
    acquired=1
  fi
  tmp="$SECONDMATE_REG.tmp.$$"
  grep -vE "^- $id( |$)" "$SECONDMATE_REG" > "$tmp" || true
  mv "$tmp" "$SECONDMATE_REG" || rc=$?
  [ "$acquired" -eq 0 ] || fm_lock_release "$lock"
  return "$rc"
}

require_exclusive_task_worktree_slot || exit 1

validate_pr_poll_cleanup "$STATE" "$ID" || exit 1

if [ "$KIND" = secondmate ]; then
  LOCAL_REGISTRY_LOCK=$(secondmate_registry_lock_path "$STATE")
  fm_lock_acquire_wait "$LOCAL_REGISTRY_LOCK" || exit 1
  LOCAL_HANDOFF_LOCK="$STATE/.backlog-handoff-$ID.lock"
  fm_lock_acquire_wait "$LOCAL_HANDOFF_LOCK" || exit 1
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  handoff_wake_retire_stage_recover "$HOME_PATH" || exit 1
  handoff_wake_retire_validate || exit 1
  validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" >/dev/null || exit 1
  if [ "$FORCE" = "--force" ]; then
    validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
    preflight_descendant_task_locks "$HOME_PATH" || exit 1
    validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
    preflight_descendant_treehouse_slots || exit 1
    if [ "$BACKEND" = herdr ]; then
      teardown_herdr_preflight_target "$T" "$ID" || exit 1
    fi
    preflight_firstmate_home_herdr_children "$HOME_PATH" || exit 1
  fi
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" != "--force" ]; then
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

if [ "$KIND" = secondmate ]; then
  preflight_firstmate_home_process_event_tree "$HOME_PATH" "secondmate home" || exit 1
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" = "--force" ]; then
  cleanup_firstmate_home_children "$HOME_PATH" || exit $?
fi

if [ "$KIND" = scout ] && [ "$FORCE" != "--force" ]; then
  REPORT="$DATA/$ID/report.md"
  if [ ! -f "$REPORT" ]; then
    echo "REFUSED: scout task $ID has no report at $REPORT." >&2
    echo "The report is the work product. Have the crewmate write it, or use --force after explicit discard approval." >&2
    exit 1
  fi
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" verify "$ID" >/dev/null; then
    echo "REFUSED: scout task $ID has not passed the captain-call completion gate." >&2
    echo "Inventory its report and any visual review through bin/fm-captain-hold.sh before teardown." >&2
    exit 1
  fi
fi

# A public commitment is not kept until its final reply lands in the ORIGINAL
# thread, and this cleanup removes the task records that make the promise
# reconcilable. Refuse while this home still owes a public reply for exactly this
# work. Both gates live in bin/fm-public-followup-lib.sh, so a home that never
# opted into the myfirstmate relay runs one [ -f ] test and nothing else here.
if [ "$FORCE" != "--force" ] && [ "$PUBLIC_FOLLOWUP_PARENT_UNRESOLVED" = 1 ]; then
  echo "REFUSED: cannot resolve the primary home for marked secondmate $SECOND_MATE_ID; refusing cleanup without its durable parent binding." >&2
  exit 1
fi
if [ "$FORCE" != "--force" ] \
  && [ -n "$PUBLIC_FOLLOWUP_STATE" ] \
  && [ "$PUBLIC_FOLLOWUP_RELAY_ACTIVE" = 1 ] \
  && fm_pf_has_registrations "$PUBLIC_FOLLOWUP_STATE"; then
  if ! PUBLIC_FOLLOWUP_BLOCKING=$(FM_HOME="$PUBLIC_FOLLOWUP_HOME" FM_STATE_OVERRIDE="$PUBLIC_FOLLOWUP_STATE" \
      "$SCRIPT_DIR/fm-public-followup.sh" guard-work "$PUBLIC_FOLLOWUP_WORK_HOME" "$ID" 2>/dev/null); then
    echo "REFUSED: task $ID still owes a public reply through the myfirstmate relay." >&2
    printf '%s\n' "$PUBLIC_FOLLOWUP_BLOCKING" >&2
    echo "Deliver it with bin/fm-public-followup.sh deliver <obligation-id>, waive it with tasks-axi public-followup waive, or use --force after explicit discard approval." >&2
    exit 1
  fi
fi

# Non-blocking: a delivered public loop is not a teardown refusal (guard-work
# already passed), but tearing down a ship whose PR merged while a loop is still
# open with nothing owed is the moment the drop is detectable.
if [ "$KIND" = ship ] && [ -n "$PR_URL" ] \
    && [ -n "$PUBLIC_FOLLOWUP_STATE" ] \
    && [ "${PUBLIC_FOLLOWUP_RELAY_ACTIVE:-0}" = 1 ] \
    && fm_pf_has_delivered_open_loops "$PUBLIC_FOLLOWUP_STATE"; then
  echo "warning: an open public loop with nothing owed is still recorded in the consent-holding home while cleaning up ship task $ID. Hand it on with bin/fm-public-followup.sh rechain or close it with retire --reason." >&2
fi

# Non-blocking: the legacy Relay link is not guarded as a refusal.
X_REQUEST=$(grep '^x_request=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
if [ -n "$X_REQUEST" ]; then
  echo "warning: task $ID still carries an unreconciled Relay request link ($X_REQUEST) on its task record." >&2
fi

if [ "$BACKEND" = orca ] && [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$FORCE" != "--force" ]; then
  if ! inspectable_git_worktree "$WT"; then
    echo "REFUSED: Orca ship task $ID has no inspectable git worktree at ${WT:-<missing>}." >&2
    echo "Cannot verify dirty or unlanded work; restore the worktree path or get explicit OK to discard, then --force." >&2
    exit 1
  fi
  require_orca_worktree_path_match "$ORCA_WORKTREE_ID" "$WT" || exit 1
  ORCA_PATH_MATCH_VERIFIED=1
fi

if [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  if validate_worktree_teardown_safety; then
    :
  else
    safety_rc=$?
    if [ "$safety_rc" -eq "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED" ]; then
      cleanup_stale_lock_for_safety_check "$WT" || exit 1
      validate_worktree_teardown_safety || exit 1
    else
      exit 1
    fi
  fi
fi

# A Herdr close may reposition shared workspace order, so the whole
# destructive sequence below (worktree return, pane close, record removal)
# runs under the named-session presentation lock, acquired BEFORE anything is
# returned or erased: a contended lock refuses here while the isolated copy,
# every durable record, and the endpoint are all still intact for a plain
# rerun. An unresolvable lock path (for example an unreachable server) also
# refuses before any destructive step.
TEARDOWN_HERDR_SESSION=
TEARDOWN_HERDR_PANE=
if [ "$BACKEND" = herdr ]; then
  teardown_herdr_preflight_target "$T" "$ID" || exit 1
  fm_backend_herdr_parse_target "$T" || exit 1
  TEARDOWN_HERDR_SESSION=$FM_BACKEND_HERDR_SESSION
  TEARDOWN_HERDR_PANE=$FM_BACKEND_HERDR_PANE
fi

BACKLOG_CLOSED=0
BACKLOG_TRANSITION=$TEARDOWN_BACKLOG_TRANSITION
BACKLOG_TRANSITION_FLAGS=()
[ "$BACKLOG_TRANSITION" = close ] || BACKLOG_TRANSITION_FLAGS=(--retain)
BACKLOG_SKIP_REASON=
if [ "$TEARDOWN_BACKLOG_APPLIES" = 1 ]; then
  backlog_done_args || {
    echo "error: the pending backlog $BACKLOG_TRANSITION for $ID is not replayable; refusing destructive teardown" >&2
    exit 1
  }
# Roll the accepted legacy incarnation's stamp back to the record's exact
# pre-stamp bytes. Uses perl - already in the teardown lifecycle's curated PATH
# (truncate is not, and is absent on stock macOS) - and verifies the restored
# size before reporting success, so a rollback that cannot be proven complete
# is reported as not rolled back.
teardown_legacy_stamp_rollback() {
  [ "$TEARDOWN_LEGACY_PRESTAMP_SIZE" -gt 0 ] 2>/dev/null || return 1
  perl -e 'truncate($ARGV[0], $ARGV[1]) or exit 1' -- \
    "$META" "$TEARDOWN_LEGACY_PRESTAMP_SIZE" || return 1
  [ "$(wc -c < "$META" | tr -d ' ')" = "$TEARDOWN_LEGACY_PRESTAMP_SIZE" ]
}

  # The accepted legacy incarnation is stamped under the meta lock already
  # held, right before the close marker binds to it: every refusal above leaves
  # the record byte-identical, and every later replay reads the same stamped
  # token the marker carries. A failed close-marker write rolls the stamp back
  # to the record's pre-stamp bytes, so a retried teardown re-runs the
  # dead-or-agent-less endpoint gate instead of sailing past it on a stamp the
  # abandoned attempt left behind.
  if [ "$TEARDOWN_LEGACY_ACCEPTED" = 1 ] && [ -z "$TEARDOWN_LEGACY_RETAINED_STAMP" ]; then
    TEARDOWN_LEGACY_PRESTAMP_SIZE=$(wc -c < "$META" | tr -d ' ')
    TEARDOWN_LEGACY_STAMP_FAILED=
    if [ -s "$META" ] && [ -n "$(tail -c 1 -- "$META" 2>/dev/null)" ]; then
      printf '\n' >> "$META" || TEARDOWN_LEGACY_STAMP_FAILED=newline
    fi
    if [ -z "$TEARDOWN_LEGACY_STAMP_FAILED" ]; then
      printf 'spawn_gen=%s\n' "$TEARDOWN_META_SPAWN_GEN" >> "$META" \
        || TEARDOWN_LEGACY_STAMP_FAILED=append
    fi
    if [ -z "$TEARDOWN_LEGACY_STAMP_FAILED" ] \
       && ! fm_backlog_meta_spawn_gen "$META" "$STATE"; then
      TEARDOWN_LEGACY_STAMP_FAILED=validate
    fi
    if [ -n "$TEARDOWN_LEGACY_STAMP_FAILED" ]; then
      teardown_legacy_stamp_rollback \
        || echo "error: the legacy incarnation stamp on $ID's record could not be rolled back; re-run teardown with --legacy-record after reconciling its endpoint" >&2
      if [ "$TEARDOWN_LEGACY_STAMP_FAILED" = validate ]; then
        echo "error: the stamped legacy incarnation does not validate for $ID ($FM_BACKLOG_TRANSITION_ERROR); refusing destructive teardown" >&2
      else
        echo "error: could not stamp the accepted legacy incarnation into task $ID's record; refusing destructive teardown" >&2
      fi
      exit 1
    fi
  fi
  BACKLOG_CLOSED=1
  META_SPAWN_GEN=$TEARDOWN_META_SPAWN_GEN
  if ! fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$META_SPAWN_GEN" \
      "${BACKLOG_TRANSITION_FLAGS[@]+"${BACKLOG_TRANSITION_FLAGS[@]}"}" \
      "${BACKLOG_DONE_ARGS[@]+"${BACKLOG_DONE_ARGS[@]}"}"; then
    if [ "$TEARDOWN_LEGACY_ACCEPTED" = 1 ] && [ -z "$TEARDOWN_LEGACY_RETAINED_STAMP" ] \
       && teardown_legacy_stamp_rollback; then
      echo "error: the pending backlog $BACKLOG_TRANSITION for $ID could not be recorded ($FM_BACKLOG_TRANSITION_ERROR); the accepted legacy incarnation was rolled back, retaining every durable task record" >&2
    else
      echo "error: the pending backlog $BACKLOG_TRANSITION for $ID could not be recorded ($FM_BACKLOG_TRANSITION_ERROR); retaining every durable task record" >&2
      if [ "$TEARDOWN_LEGACY_ACCEPTED" = 1 ] && [ -z "$TEARDOWN_LEGACY_RETAINED_STAMP" ]; then
        echo "error: the legacy incarnation stamp on $ID's record could not be rolled back; re-run teardown with --legacy-record after reconciling its endpoint" >&2
      fi
    fi
    exit 1
  fi
else
  if [ "$CLEANUP_RECOVERY" = orca ]; then
    BACKLOG_SKIP_REASON="Orca cleanup recovery is not a launched backlog worker"
  else
    BACKLOG_SKIP_REASON=$TEARDOWN_BACKLOG_SKIP_REASON
  fi
fi

# Every landed/discard-work refusal above has now passed (or --force skipped
# them). Fix 1 and Fix 2 (see script header) run here, unconditionally on
# --force, and before ANY destructive step below - a still-parked run or a
# leaked process can own live work in this exact worktree. Not for
# kind=secondmate: a secondmate home's own runtime lifecycle is owned by the
# dedicated process-event and firstmate-home removal machinery further below,
# not by task-worktree cleanup.
if [ "$KIND" != secondmate ]; then
  conclude_task_no_mistakes_run "$WT"
  reap_task_worktree_processes worktree "$WT" "$TASK_TMP"
fi

# Fix 3 (see script header): sweep remote job workers abandoned by an already
# pruned code root. Best effort - a sweep failure never blocks this teardown.
"$SCRIPT_DIR/fm-remote-job-reap-orphans.sh" >&2 || true

# Best-effort: drop the local task branch so the shared repo does not accumulate refs.
if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
  if [ "$ORCA_PATH_MATCH_VERIFIED" != 1 ]; then
    require_orca_worktree_path_match_if_present "$ORCA_WORKTREE_ID" "$WT" || exit 1
    ORCA_PATH_MATCH_VERIFIED=1
  fi
  if [ -d "$WT" ]; then
    branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    if [ "$branch" != "HEAD" ]; then
      if git -C "$WT" checkout --detach -q 2>/dev/null; then
        git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" \
      "$WT/.opencode/plugins/fm-busy-state.js" \
      "$WT/.fm-grok-turnend" "$WT/.fm-kimi-turnend"
  fi
  [ -z "$T_ORCA" ] || fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" 2>/dev/null || true
  fm_backend_remove_worktree "$BACKEND" "$ORCA_WORKTREE_ID"
elif [ -d "$WT" ] && [ "$KIND" != secondmate ]; then
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if [ "$branch" != "HEAD" ]; then
    if git -C "$WT" checkout --detach -q 2>/dev/null; then
      git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
    fi
  fi
  # Remove our hook file so a reused pool worktree cannot fire signals for a dead task.
  rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" \
    "$WT/.fm-grok-turnend" "$WT/.fm-kimi-turnend"
  # Kills remaining processes in the worktree (including the agent), resets, returns
  # to pool. treehouse resolves the pool from the working directory, so run it from
  # the project. teardown_treehouse_return tolerates transient and stale git locks
  # left by a killed crew process; see the script header for retry and stale-lock proof.
  post_lock_cleanup_check=
  if [ "$FORCE" != "--force" ] && [ "$KIND" != scout ] && [ "$KIND" != secondmate ]; then
    post_lock_cleanup_check=validate_worktree_teardown_safety
  fi
  teardown_treehouse_return "$WT" "$PROJ" "worktree" "$post_lock_cleanup_check" || {
    echo "error: treehouse return failed for worktree $WT; teardown aborted" >&2
    exit 1
  }
fi

HERDR_PRESENTATION_JOURNAL="$STATE/$ID.herdr-presentation"
HERDR_PRESENTATION_RETIRE_CANDIDATE=0
HERDR_PRESENTATION_SESSION=
HERDR_PRESENTATION_PANE=
if [ "$BACKEND" = herdr ] \
   && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  fm_backend_source herdr || true
  HERDR_PRESENTATION_SESSION=$(meta_value "$META" herdr_session)
  HERDR_PRESENTATION_WORKSPACE=$(meta_value "$META" herdr_workspace_id)
  HERDR_PRESENTATION_PANE=$(meta_value "$META" herdr_pane_id)
  if [ -n "$HERDR_PRESENTATION_SESSION" ] \
     && [ -n "$HERDR_PRESENTATION_WORKSPACE" ] \
     && [ -n "$HERDR_PRESENTATION_PANE" ] \
     && [ "$T" = "$HERDR_PRESENTATION_SESSION:$HERDR_PRESENTATION_PANE" ] \
     && fm_backend_herdr_projection_endpoint_matches_journal \
       "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_WORKSPACE" \
       "$HERDR_PRESENTATION_JOURNAL" "$ID"; then
    HERDR_PRESENTATION_RETIRE_CANDIDATE=1
  fi
fi

if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
  # The presentation lock was acquired before the worktree return above; a
  # contended lock already refused this teardown while everything was intact.
  if teardown_herdr_session_lock_held "$HERDR_PRESENTATION_SESSION"; then
    # stderr is deliberately NOT discarded here. This is the highest-frequency
    # projected-close call site, and the helper's only stderr output is a real
    # warning - unverifiable workspace.move support, a refused focus-unsafe
    # close, an unconfirmed repositioned-workspace removal, or a failed exact
    # restore.
    # Swallowing them left a wrong active workspace with no operator-visible
    # signal at all. The close stays non-fatal exactly as before: the presence
    # gate below is what decides whether any durable record may be removed.
    fm_backend_herdr_projection_close_pane_focus_preserving \
      "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_PANE" || true
  else
    echo "warning: herdr presentation focus lock unavailable; refusing a concurrent focus-unsafe pane close" >&2
  fi
elif [ "$BACKEND" = herdr ]; then
  if teardown_herdr_session_lock_held "$TEARDOWN_HERDR_SESSION"; then
    fm_backend_herdr_kill_serialized "$TEARDOWN_HERDR_SESSION" "$TEARDOWN_HERDR_PANE" 2>/dev/null || true
  else
    echo "warning: herdr session presentation lock path is unavailable; skipping the pane close rather than closing unlocked" >&2
  fi
elif [ "$BACKEND" != orca ]; then
  fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" 2>/dev/null || true
fi
if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
  if [ "$(fm_backend_herdr_pane_agent_state "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_PANE")" = dead ]; then
    rm -f "$HERDR_PRESENTATION_JOURNAL"
  else
    echo "warning: exact herdr task-pane close could not be confirmed for $ID; retaining the presentation journal and attempting no workspace cleanup" >&2
  fi
elif [ "$BACKEND" = herdr ] \
     && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  echo "warning: herdr presentation journal for $ID remains quarantined; no workspace cleanup was attempted" >&2
fi
# A refused, skipped, or failed Herdr close must never erase a live task's
# durable endpoint identity: unless the exact pane is confirmed gone, retain
# every record and stop before any removal below so a later rerun can retry
# the locked close. Only a structured not-found proves the pane gone; unknown
# presence, missing or malformed endpoint identity, and missing confirmation
# machinery all refuse.
if [ "$BACKEND" = herdr ]; then
  fm_backend_source herdr || true
  if ! declare -F fm_backend_herdr_endpoint_confirmed_gone >/dev/null 2>&1; then
    echo "error: herdr endpoint confirmation is unavailable for $ID; retaining every durable task record" >&2
    exit 1
  fi
  if ! fm_backend_herdr_endpoint_confirmed_gone "$T"; then
    echo "error: herdr pane $T for $ID is not confirmed gone after its close was refused, skipped, or failed; retaining every durable task record - rerun teardown once the close can run under the session lock" >&2
    exit 1
  fi
fi
if [ "$KIND" != secondmate ]; then
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-inactive-reconcile.sh" report "$ID"; then
    echo "error: $ID's final outcome has not reached the parent channel; retaining every durable task record so a rerun can retry the delivery" >&2
    exit 1
  fi
fi
if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  handoff_wake_retire_stage \
    || { echo "error: receiver wake cleanup could not be staged; preserving the secondmate home and route" >&2; exit 1; }
  if remove_firstmate_home "$HOME_PATH" "secondmate home" "$ID"; then
    :
  else
    rc=$?
    handoff_wake_retire_stage_restore \
      || echo "error: receiver wake restoration failed; recovery state remains at $HANDOFF_WAKE_RETIRE_STAGE" >&2
    exit "$rc"
  fi
  handoff_wake_retire_stage_commit \
    || { echo "error: receiver wake cleanup failed; preserving the secondmate route for retry" >&2; exit 1; }
  remove_secondmate_registry_entry "$ID"
fi
remove_grok_turnend_auth "$STATE" "$ID" || exit 1
remove_kimi_turnend_auth "$STATE" "$ID" || exit 1
fm_backend_clear_transition "$BACKEND" "$STATE" "$T" || true
# Remove the per-task temp root (/tmp/fm-<id>/, incl. its gotmp/) recorded by spawn.
# Read before the state-file rm below; empty (pre-fix tasks without tasktmp=) is a no-op.
[ -n "$TASK_TMP" ] && rm -rf "$TASK_TMP"
remove_pr_poll_artifacts "$STATE" "$ID" || exit 1
retire_busy_state "$STATE" "$ID" "$BUSY_GEN" || exit 1
status_retire_presentation_task "$STATE" "$ID" || exit 1
rm -f "$STATE/$ID.turn-ended" \
  "$STATE/$ID.pi-ext.ts" "$STATE/$ID.omp-ext.ts" "$STATE/$ID.grok-turnend-token" \
  "$STATE/$ID.kimi-turnend-token" "$STATE/$ID.muse-session" \
  "$STATE/$ID.muse-session-current" "$STATE/$ID.cursor-session" \
  "$STATE/$ID.control-relaunch" "$STATE/$ID.control-relaunch.meta-prior" \
  "$STATE/$ID.control-relaunch.brief-prior" "$STATE/$ID.control-relaunch.note" \
  "$STATE/$ID.reconcile-nudged" "$STATE/$ID.gemini-settings.json" \
  "$STATE/.$ID.branch-outcome-index"
# The steering inbox (bin/fm-task-inbox-lib.sh) is runtime state for the
# retired endpoint; teardown only runs after landing is confirmed, so any
# leftover unhandled steer here is moot rather than unlanded work.
rm -rf "$STATE/$ID.inbox"
# The record is gone, so the backlog must not still show this task in flight
# when teardown reports success. Still under this task's meta lock, so a steer
# racing the same id stays serialized exactly as it was before. A captain-held
# row takes the retain transition here instead of the close: same record, same
# ordering, the row returns to Queued with its deliverable recorded.
if [ "$BACKLOG_CLOSED" = 1 ]; then
  BACKLOG_CLOSE_MARKER=$(fm_backlog_close_marker_path "$STATE" "$ID") || exit 1
  if ! fm_backlog_atomic_transition "$BACKLOG_TRANSITION" "$STATE/$ID.meta" "$BACKLOG_CLOSE_MARKER" \
      "$DATA" "$ID" "$STATE" "${BACKLOG_DONE_ARGS[@]+"${BACKLOG_DONE_ARGS[@]}"}"; then
    fm_lock_release "$META_LOCK"
    META_LOCK_HELD=0
    if [ "$BACKLOG_TRANSITION" = retain ]; then
      echo "error: $ID's endpoint and local copy are cleaned up, but its captain-held backlog item could not be returned to Queued atomically ($FM_BACKLOG_TRANSITION_ERROR); the pending retention is recorded and the next session start retries it" >&2
    else
      echo "error: $ID's endpoint and local copy are cleaned up, but its backlog item could not be closed atomically ($FM_BACKLOG_TRANSITION_ERROR); the pending close is recorded and the next session start retries it" >&2
    fi
    exit 1
  fi
elif [ "$KIND" = secondmate ] && [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; then
  # A nested remote retirement can keep its route record inside the home being
  # removed. remove_firstmate_home above already performed that physical
  # deletion; do not turn its confirmed absence into a false cleanup failure.
  :
else
  if ! fm_backlog_atomic_transition remove "$STATE/$ID.meta" "task record" "$STATE"; then
    fm_lock_release "$META_LOCK"
    META_LOCK_HELD=0
    echo "error: $ID's endpoint and local copy are cleaned up, but its task record could not be removed ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
fi
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0
if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
# A secondmate retirement may remove the home containing an overridden control
# state directory. Do not let the side-band refresh recreate that retired home.
if [ -d "$STATE" ]; then
  "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
fi
if [ "$TEARDOWN_LEGACY_ACCEPTED" = 1 ]; then
  echo "teardown $ID complete (window $T, worktree $WT, legacy record accepted without spawn_gen: endpoint $TEARDOWN_LEGACY_ENDPOINT, incarnation $TEARDOWN_META_SPAWN_GEN)"
else
  echo "teardown $ID complete (window $T, worktree $WT)"
fi
backlog_refresh_reminder
