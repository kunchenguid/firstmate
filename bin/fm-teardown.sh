#!/usr/bin/env bash
# Tear down a finished task: return the Treehouse worktree, close the recorded
# Herdr endpoint, clear volatile state, and transition this home's backlog item
# for ship and scout tasks before reporting success, then refresh/prune the
# project's clone for PR-based ship tasks.
# Accepted/archived tasks close only the exact recorded pane and archive their
# resource record independently of copy disposal. Shared, primary, dirty,
# unintegrated or unverified copies stay; reports/status/outcomes stay outside
# the disposable copy. Historical journal/UI/continuation/short binding checks
# do not admit this completed path. The detailed legacy contract below applies
# to records without an accepted/archived goal.
# Removing state/<id>.meta and landing the backlog transition are one step, not
# two: bin/fm-backlog-transition-lib.sh owns that invariant, and both halves run
# under the task's own meta lock before this script reports success. Because the
# completion links (the PR, the report path, a local-main note) live only in the
# record being removed, the intended transition is recorded in
# state/<id>.backlog-close first, so a process killed between the halves leaves
# the next session start enough to finish it; a landed close removes that record.
# A close that fails is fatal and loud, preserves its pending-close record, and
# is retried by the next session start. The transition always addresses the
# named canonical `data/<id>/task.json` record; legacy backlog configuration
# neither redirects nor suppresses it, and retained backlog bytes stay inert.
# None of this loosens the landed-work gates below: the transition runs only on
# the paths that already proceed to remove the record.
# The original task must be MAIN-accepted through compact progress or explicitly
# archived before cleanup.
# A partial report, completed decision inventory, --force, or --endpoint-only
# cannot retire an open goal's resources. This is checked under the meta lock
# before endpoint, directory, slot or task-record effects; legacy records keep
# their existing completion and ownership checks.
# The close - and only the close - is replaced by `tasks-axi reopen` with the
# deliverable recorded while the backlog item is still an open captain call
# (bin/fm-captain-hold.sh `open` owns that predicate), because the policy holds
# the very work item a question gates and cleanup must never retire the
# captain's own question.
# NOTE: this uses `open`'s silent default and depends only on its unchanged
# 0/1/2 exit-code contract. The optional `--identity` output that bin/fm-watch.sh
# asks for prints only on an exit 0 and changes nothing read here.
# The same pending-close record carries that intent as
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
# this home may name the same live path in its worktree= or home=. One live path
# with two task records is the reuse
# collision itself, whichever record is stale.
# That scan alone cannot prove THIS record is the current owner, because the task
# that took the slot next may leave no record it can reach - its own worker may
# have exited and its record been cleaned up, or it may live in a home this
# machine does not register - which is how a released-then-reassigned slot was
# returned out from under a live worker (observed 2026-09-07). So teardown also
# reads the slot's own owner claim, written by bin/fm-spawn.sh at the moment the
# slot is taken and dropped here once it is genuinely returned; bin/fm-wake-lib.sh
# owns the claim, its location, and its states. A claim naming another task is
# proof of reassignment: the slot is no longer this task's, so teardown warns,
# names the claimant, and then finishes only this task's own cleanup - endpoint,
# status, records, checks, backlog - while every step that would read or touch
# that slot is skipped: no process kill under it, no dirty or landed-work
# inspection of it, no branch or hook removal in it, no Treehouse return, and
# never the other task's claim. Skipping the inspection discards nothing of this
# task's: whatever unlanded work it had in that slot was already destroyed when
# the pool handed the slot on. Refusing instead would strand the record, because
# bin/fm-backend.sh's endpoint validation refuses an empty or missing worktree=
# unconditionally, so there is no line an operator could clear to get past it.
# A claim that cannot be read, or an absent claim beside a live recorded slot,
# proves no ownership and refuses; inspect, repair, or conservatively migrate
# the exact task and execution generation at the printed path before retrying.
# A recorded directory that is already absent has no slot to return and skips
# this proof without gaining authority over another path.
# Why Treehouse's own state cannot answer this for crewmate slots, and why the
# claim file sits on top of it, is owned by bin/fm-wake-lib.sh's slot-owner
# claim comment.
# The recorded endpoint's exact task identity and the record's spawn incarnation
# are validated separately
# before cleanup. Its current working directory is only incidental process
# state: the same worker remains the owner after changing directory, so cwd can
# never veto teardown of that exact recorded endpoint.
# The scan and destructive return hold a project-identity lock in this
# Firstmate home's state directory. Fresh Treehouse spawns for that project
# hold the same lock from before slot allocation through metadata publication,
# closing the publication gap.
# These refusals are not relaxed by --force: --force authorizes discarding THIS
# task's unlanded work, never another task's live work. Nothing of this task's
# own is removed by a refusal; reconcile whichever record is wrong and re-run.
# Retired backend and worktree ownership records refuse before cleanup;
# an old provider-owned copy is never returned through Treehouse.
# A Herdr presentation journal never authorizes cleanup by itself. Teardown
# requires matching ordinary endpoint metadata plus the structural journal and
# matching session-continuity evidence, closes only the
# exact task pane, and never calls `workspace close`. It retires the journal
# only when pane closure is confirmed; otherwise the journal stays quarantined
# for manual inspection.
# Projected closes share the presentation-order lock, refuse to close the
# captain's active tab, and restore the exact response-derived pre-close tab
# if Herdr's last-pane cleanup focuses an unrelated neighboring workspace.
# Historical secondmate records are unsupported and refuse before any cleanup,
# preserving their homes and records for manual inspection.
# Usage: fm-teardown.sh <task-id> [--force] [--legacy-record]
#   fm-teardown.sh <task-id> --copy-only --expect-spawn-gen <generation>
# Copy-only is MAIN-owned post-retirement follow-through from the existing
# cleanup receipt. Exact canonical path/device/inode, home/task/generation and
# current sharing/pool ownership/content checks precede disposal. It never
# recreates metadata or repeats endpoint/business effects. Missing historical
# bindings and uncertain attempts require readback; no path override or force.
#   --force skips ordinary-task dirty and landed-work checks and skips scout
#   report checks. Only use it when the captain has explicitly said to discard
#   the work.
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
#   2. Other return failures do not enter this lock-retry loop. The path-alias
#      recovery below is the only separately handled non-lock failure.
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
# Treehouse path-alias recovery is owned by teardown_treehouse_return.
# Treehouse 2.0.1 and 2.1.1 compare a return path byte-for-byte with their managed
# path, while a backend cwd probe can report the same directory through a physical
# symlink or bind-mount path.
# Only after Treehouse returns its exact unmanaged-path error does teardown enumerate
# public `treehouse status` slot names and resolve each through
# `treehouse enter --print-path`.
# It retries exactly one managed path only when Bash `test -ef` proves that existing
# directory has the same device and inode as the already-inspected worktree.
# Missing, changed, non-equivalent, or multiply-matched paths still refuse without
# weakening dirty-work or landed-work checks.
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
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
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
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
if [ "$#" -lt 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "error: invalid teardown request" >&2
  exit 2
fi
ID=$1
FORCE=
LEGACY_RECORD_GIVEN=0
ENDPOINT_ONLY=0
COPY_ONLY=0
ENDPOINT_EXPECTED_GEN=
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=--force ;;
    --legacy-record) LEGACY_RECORD_GIVEN=1 ;;
    --endpoint-only) ENDPOINT_ONLY=1 ;;
    --copy-only) COPY_ONLY=1 ;;
    --expect-spawn-gen) [ "$#" -ge 2 ] || exit 2; ENDPOINT_EXPECTED_GEN=$2; shift ;;
    *)
      echo "error: invalid teardown request" >&2
      exit 2
      ;;
  esac
  shift
done
[ "$ENDPOINT_ONLY" != 1 ] || { [ -n "$ENDPOINT_EXPECTED_GEN" ] && [ -z "$FORCE" ] && [ "$LEGACY_RECORD_GIVEN" = 0 ]; } || exit 2
[ "$COPY_ONLY" != 1 ] || { [ -n "$ENDPOINT_EXPECTED_GEN" ] && [ "$ENDPOINT_ONLY" = 0 ] && [ -z "$FORCE" ] && [ "$LEGACY_RECORD_GIVEN" = 0 ]; } || exit 2
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: teardown refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-teardown-worktree-lib.sh
. "$SCRIPT_DIR/fm-teardown-worktree-lib.sh"

BACKLOG_DONE_ARGS=()
# The completion links this teardown already holds locally. A scout's
# deliverable is its report, a local-only ship lands on local main, and every
# other ship carries the PR recorded on its own record.
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
  local backlog_display="${DATA%/}/$ID/task.json"
  if [ "$BACKLOG_CLOSED" = 1 ] && [ "$BACKLOG_TRANSITION" = retain ]; then
    printf '%s\n' "Task: $ID stays open in $backlog_display, still held for the captain with its deliverable recorded. Relay the question and close it only with bin/fm-captain-hold.sh answer."
  elif [ "$BACKLOG_CLOSED" = 1 ]; then
    printf '%s\n' "Task: $ID is closed in $backlog_display. Run bin/fm-tasks-axi.sh ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
  else
    printf '%s\n' "Task: $ID just finished ($BACKLOG_SKIP_REASON). Update $backlog_display, then re-scan Queued and dispatch only work whose blockers are gone and date is due."
  fi
}

# Completed goals retire their recorded endpoint independently of disposable
# copy removal. No historical journal, agent UI, continuation or operation
# binding is an admission gate here. Shared, dirty or unlanded copies stay.
# Active/legacy tasks retain the ordinary teardown contract below.
# shellcheck source=bin/fm-cleanup-receipt-lib.sh
. "$SCRIPT_DIR/fm-cleanup-receipt-lib.sh"
teardown_completed_task() (
  local meta="$STATE/$ID.meta" lock copy project session pane other disposition=returned-or-already-absent facts
  local COPY_DISPOSITION COPY_REASON binding
  local WT PROJ KIND MODE PR_URL dirty generation backlog_status=0 captain_status=0 captain_out marker
  local copy_lock='' copy_lock_held=0
  local BACKLOG_CLOSED=0 BACKLOG_TRANSITION=close BACKLOG_SKIP_REASON=''
  local -a TASK_COMPLETED_DONE_ARGS=() TASK_COMPLETED_TRANSITION_FLAGS=()
  lock=$(fm_meta_lock_path "$meta") || exit 1
  fm_lock_acquire_wait "$lock"
  trap 'fm_lock_release "$lock"; if [ "$copy_lock_held" = 1 ]; then fm_lock_release "$copy_lock"; fi' EXIT
  fm_backend_validate_task_endpoint "$meta" "$ID" || exit 1
  [ -z "$ENDPOINT_EXPECTED_GEN" ] || [ "$(fm_meta_get "$meta" spawn_gen)" = "$ENDPOINT_EXPECTED_GEN" ] || exit 1
  KIND=$(fm_meta_get "$meta" kind)
  [ -n "$KIND" ] || KIND=ship
  [ "$KIND" != secondmate ] || {
    echo "REFUSED: task $ID is a historical secondmate record; automatic teardown is no longer supported and its home was left untouched" >&2
    exit 1
  }
  copy=$(fm_backend_meta_exact_value "$meta" worktree) || exit 1
  project=$(fm_backend_meta_exact_value "$meta" project) || exit 1
  generation=$(fm_meta_get "$meta" spawn_gen)
  fm_cleanup_completion_guard "$ID" "$generation" || exit $?
  fm_cleanup_delivery_guard "$ID" "$generation" "$meta" || exit $?
  MODE=$(fm_meta_get "$meta" mode)
  PR_URL=$(fm_meta_get "$meta" pr)
  [ -n "$MODE" ] || MODE=no-mistakes
  session=$(fm_backend_meta_exact_value "$meta" herdr_session) || exit 1
  pane=$(fm_backend_meta_exact_value "$meta" herdr_pane_id) || exit 1
  for other in "$STATE"/*.meta; do
    [ "$other" != "$meta" ] && [ -f "$other" ] && [ ! -L "$other" ] || continue
    if [ "$(fm_meta_get "$other" herdr_session)" = "$session" ] && \
       [ "$(fm_meta_get "$other" herdr_pane_id)" = "$pane" ]; then
      echo 'REFUSED: recorded endpoint is claimed by another task' >&2; exit 1
    fi
  done
  fm_backend_source herdr || exit 1
  case "$(fm_backend_herdr_pane_presence_state "$session" "$pane")" in
    present) fm_backend_herdr_explicit_close_pane_confirmed "$session" "$pane" || exit 1 ;;
    dead) ;;
    *) echo 'REFUSED: exact endpoint cannot be resolved' >&2; exit 1 ;;
  esac
  if [ "$ENDPOINT_ONLY" = 1 ]; then
    local ENDPOINT_GENERATION ENDPOINT_RECEIPT META=$meta
    ENDPOINT_GENERATION=$generation
    ENDPOINT_RECEIPT="$STATE/$ID.cleanup.json"
    # Existing phase receipts are observations, not admission checks.
    # shellcheck source=bin/fm-teardown-endpoint-lib.sh
    . "$SCRIPT_DIR/fm-teardown-endpoint-lib.sh"
    teardown_endpoint_receipt pane_close confirmed exact-pane-absent && \
      teardown_endpoint_directory_observation || echo 'warning: endpoint closed; phase evidence unavailable' >&2
    printf 'completed task pane removed: %s; copy and report retained\n' "$ID"
    exit 0
  fi
  local ENDPOINT_GENERATION ENDPOINT_RECEIPT
  ENDPOINT_GENERATION=$generation
  ENDPOINT_RECEIPT="$STATE/$ID.cleanup.json"
  # shellcheck source=bin/fm-teardown-endpoint-lib.sh
  . "$SCRIPT_DIR/fm-teardown-endpoint-lib.sh"
  teardown_endpoint_receipt pane_close confirmed exact-pane-absent || exit 1
  if [ -d "$copy" ]; then
    if binding=$(fm_cleanup_receipt copy-bind "$ID" "$generation"); then
      copy=$(printf '%s' "$binding" | jq -r '.copy.path')
      project=$(printf '%s' "$binding" | jq -r '.project.path')
      if teardown_completed_copy "$copy" "$project" "$generation"; then
        disposition=$COPY_DISPOSITION
        if [ "$disposition" = returned-or-already-absent ]; then
          teardown_endpoint_receipt directory_return confirmed "$COPY_REASON" || exit 1
        else
          teardown_endpoint_receipt directory_return retained "$COPY_REASON" || exit 1
        fi
      else
        echo 'REFUSED: copy disposal may have happened; exact readback required, endpoint remains confirmed absent' >&2
        exit 1
      fi
    else
      disposition=retained-unverified
      teardown_endpoint_receipt directory_return retained copy-identity-unreadable || exit 1
    fi
  else
    teardown_endpoint_receipt directory_return confirmed copy-already-absent || exit 1
  fi
  teardown_completed_bookkeeping "$meta" "$generation" "$disposition"

)
teardown_completed_bookkeeping() {
  local meta=$1 generation=$2 disposition=$3 facts marker captain_out captain_status=0 backlog_status=0
  local KIND MODE PR_URL WT PROJ
  local BACKLOG_CLOSED=0 BACKLOG_TRANSITION=close BACKLOG_SKIP_REASON=''
  local -a TASK_COMPLETED_DONE_ARGS=() TASK_COMPLETED_TRANSITION_FLAGS=()
  KIND=$(fm_meta_get "$meta" kind)
  MODE=$(fm_meta_get "$meta" mode)
  PR_URL=$(fm_meta_get "$meta" pr)
  WT=$(fm_meta_get "$meta" worktree)
  PROJ=$(fm_meta_get "$meta" project)
  [ -n "$KIND" ] || KIND=ship
  [ -n "$MODE" ] || MODE=no-mistakes
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
    if ! fm_backlog_meta_spawn_gen "$meta" "$STATE"; then
      echo "error: completed cleanup could not bind $ID's backlog transition to its task generation ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      exit 1
    fi
    generation=$FM_BACKLOG_META_SPAWN_GEN
    captain_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" 2>&1) || captain_status=$?
    case "$captain_status" in
      0) BACKLOG_TRANSITION=retain; TASK_COMPLETED_TRANSITION_FLAGS=(--retain) ;;
      1) ;;
      *)
        echo "error: completed cleanup could not determine whether $ID's backlog item is held for the captain" >&2
        [ -z "$captain_out" ] || printf '%s\n' "$captain_out" >&2
        exit 1
        ;;
    esac
    backlog_done_args || {
      echo "error: completed cleanup could not record $ID's deliverable" >&2
      exit 1
    }
    TASK_COMPLETED_DONE_ARGS=("${BACKLOG_DONE_ARGS[@]+"${BACKLOG_DONE_ARGS[@]}"}")
    marker=$(fm_backlog_close_marker_path "$STATE" "$ID") || exit 1
    fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$generation" \
      --cleanup-disposition "$disposition" \
      "${TASK_COMPLETED_TRANSITION_FLAGS[@]+"${TASK_COMPLETED_TRANSITION_FLAGS[@]}"}" \
      "${TASK_COMPLETED_DONE_ARGS[@]+"${TASK_COMPLETED_DONE_ARGS[@]}"}" || {
        echo "error: completed cleanup could not record its pending backlog $BACKLOG_TRANSITION ($FM_BACKLOG_TRANSITION_ERROR)" >&2
        exit 1
      }
    BACKLOG_CLOSED=1
    fm_backlog_atomic_transition remove "$meta" 'completed resource record' "$STATE" || exit 1
    fm_backlog_replay_transition "$BACKLOG_TRANSITION" "$marker" "$DATA" "$ID" "$STATE" \
      "$generation" "$disposition" "${TASK_COMPLETED_DONE_ARGS[@]+"${TASK_COMPLETED_DONE_ARGS[@]}"}" || {
        echo "error: completed cleanup finished endpoint and copy handling, but its backlog $BACKLOG_TRANSITION remains pending ($FM_BACKLOG_TRANSITION_ERROR)" >&2
        exit 1
      }
  else
    backlog_status=$?
    if [ "$backlog_status" -eq 2 ]; then
      echo "error: completed cleanup could not access $ID's backlog ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      exit 1
    fi
    BACKLOG_SKIP_REASON=$FM_BACKLOG_TRANSITION_SKIP
    fm_backlog_atomic_transition remove "$meta" 'completed resource record' "$STATE" || exit 1
  fi
  rm -f "$STATE/.$ID.branch-outcome-index"
  teardown_endpoint_receipt record_close confirmed completed-record-retired || exit 1
  facts=$(jq -cn --arg disposition "$disposition" '{taskRecordRemoved:true,endpointConfirmedGone:true,copyDisposition:$disposition,bookkeepingComplete:true}')
  fm_cleanup_receipt completion-record "$ID" "$generation" --facts "$facts" >/dev/null || {
    echo 'actionable: cleanup completed but cleanup-owner evidence could not be recorded; read back before retrying effects' >&2
    return 1
  }
  printf 'teardown %s complete (exact pane absent; copy=%s; report retained)\n' "$ID" "$disposition"
  backlog_refresh_reminder
  if [ "${FM_SUPERVISION_ACTOR:-}" = short ]; then
    # Postcondition evidence only: no pre-effect short-actor admission check.
    # shellcheck source=bin/fm-short-owner-lib.sh
    . "$SCRIPT_DIR/fm-short-owner-lib.sh"
    FM_SHORT_OWNER_ACTION=cleanup
    FM_SHORT_OWNER_ARGS=("$ID")
    fm_short_owner_receipt "$facts"
  fi
}

teardown_retained_copy() (
  local lock copy project generation readback phase absent receipt
  local ENDPOINT_GENERATION ENDPOINT_RECEIPT COPY_DISPOSITION COPY_REASON
  local copy_lock='' copy_lock_held=0 WT PROJ KIND=ship MODE=no-mistakes PR_URL=''
  # shellcheck source=bin/fm-lease-lib.sh
  . "$SCRIPT_DIR/fm-lease-lib.sh"
  fm_refuse_if_gate_agent
  [ "$(fm_lease_actor)" = main ] || { echo 'REFUSED: retained copy cleanup belongs to MAIN' >&2; exit 6; }
  fm_lease_guard "$ID" 'retained copy cleanup' || exit $?
  lock=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 1
  trap 'fm_lock_release "$lock"; if [ "$copy_lock_held" = 1 ]; then fm_lock_release "$copy_lock"; fi; fm_lease_guard_release' EXIT
  fm_lock_acquire_wait "$lock" || exit 1
  [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ] || { echo 'REFUSED: retire execution metadata before copy-only follow-through' >&2; exit 1; }
  receipt=$(jq -ce 'select(.schema=="fm-task-cleanup.v1")' "$STATE/$ID.cleanup.json") || exit 1
  generation=$(printf '%s' "$receipt" | jq -r '.spawn_gen')
  [ "$generation" = "$ENDPOINT_EXPECTED_GEN" ] || { echo 'REFUSED: retained copy generation conflict' >&2; exit 1; }
  readback=$(fm_cleanup_receipt copy-read "$ID" "$generation") || exit 1
  if printf '%s' "$receipt" | jq -e '.preservation_ref!=null' >/dev/null; then
    echo 'retained copy preservation settled; no disposal replay'; exit 0
  fi
  phase=$(printf '%s' "$readback" | jq -r '.phase.state')
  [ "$phase" != confirmed ] || { echo 'retained copy already disposed; no effects repeated'; exit 0; }
  absent=$(printf '%s' "$readback" | jq -r '.absent')
  ENDPOINT_GENERATION=$generation
  ENDPOINT_RECEIPT="$STATE/$ID.cleanup.json"
  # shellcheck source=bin/fm-teardown-endpoint-lib.sh
  . "$SCRIPT_DIR/fm-teardown-endpoint-lib.sh"
  if [ "$absent" = true ]; then
    teardown_endpoint_receipt directory_return confirmed copy-already-absent || exit 1
    echo 'retained copy confirmed absent; no effects repeated'; exit 0
  fi
  [ "$phase" != pending ] || { echo 'REFUSED: copy disposal may have happened; exact effect readback required' >&2; exit 1; }
  copy=$(printf '%s' "$readback" | jq -r '.binding.copy.path')
  project=$(printf '%s' "$readback" | jq -r '.binding.project.path')
  teardown_completed_copy "$copy" "$project" "$generation" || exit 1
  if [ "$COPY_DISPOSITION" = returned-or-already-absent ]; then
    teardown_endpoint_receipt directory_return confirmed "$COPY_REASON" || exit 1
  else
    teardown_endpoint_receipt directory_return retained "$COPY_REASON" || exit 1
  fi
  printf 'copy-only %s: %s (%s); business disposition and endpoint unchanged\n' "$ID" "$COPY_DISPOSITION" "$COPY_REASON"
)
if [ "$COPY_ONLY" = 1 ]; then teardown_retained_copy; exit $?; fi

PUBLIC_FOLLOWUP_HOME=$FM_HOME
PUBLIC_FOLLOWUP_STATE=$STATE
PUBLIC_FOLLOWUP_WORK_HOME=main
PUBLIC_FOLLOWUP_RELAY_ACTIVE=0
PUBLIC_FOLLOWUP_GUARD_CHECKED=0
if [ "$FORCE" != "--force" ] && fm_pf_relay_active "$FM_HOME"; then
  PUBLIC_FOLLOWUP_RELAY_ACTIVE=1
fi

teardown_public_followup_guard() {
  [ "$PUBLIC_FOLLOWUP_GUARD_CHECKED" = 0 ] || return 0
  PUBLIC_FOLLOWUP_GUARD_CHECKED=1
  if [ "$FORCE" != "--force" ] \
    && [ -n "$PUBLIC_FOLLOWUP_STATE" ] \
    && [ "$PUBLIC_FOLLOWUP_RELAY_ACTIVE" = 1 ] \
    && fm_pf_has_registrations "$PUBLIC_FOLLOWUP_STATE"; then
    if ! PUBLIC_FOLLOWUP_BLOCKING=$(FM_HOME="$PUBLIC_FOLLOWUP_HOME" FM_STATE_OVERRIDE="$PUBLIC_FOLLOWUP_STATE" \
        "$SCRIPT_DIR/fm-public-followup.sh" guard-work "$PUBLIC_FOLLOWUP_WORK_HOME" "$ID" 2>/dev/null); then
      echo "REFUSED: task $ID still owes a public reply through the myfirstmate relay." >&2
      printf '%s\n' "$PUBLIC_FOLLOWUP_BLOCKING" >&2
      echo "Deliver it with bin/fm-public-followup.sh deliver <obligation-id>, waive it with bin/fm-tasks-axi.sh public-followup waive, or use --force after explicit discard approval." >&2
      exit 1
    fi
  fi
}

if [ -f "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
  completed_generation=$(fm_meta_get "$STATE/$ID.meta" spawn_gen)
  if fm_cleanup_completion_guard "$ID" "$completed_generation" >/dev/null 2>&1; then
    teardown_public_followup_guard
    X_REQUEST=$(grep '^x_request=' "$STATE/$ID.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -n "$X_REQUEST" ]; then
      echo "warning: task $ID still carries an unreconciled Relay request link ($X_REQUEST) on its task record." >&2
    fi
    teardown_completed_task
    exit $?
  fi
  # Retained rich data is no longer an engine, but an exact open disposition
  # remains a safety fact when the original task row is absent. Do not let the
  # legacy no-row path turn that open history into implicit completion.
  if [ -e "$DATA/$ID/lifecycle.json" ] || [ -L "$DATA/$ID/lifecycle.json" ]; then
    fm_cleanup_completion_guard "$ID" "$completed_generation"
    exit $?
  fi
fi
# Supervision lease guard: post-landing cleanup is overlap territory between
# the two Pi supervision actors; refuse while the OTHER actor holds this
# task's live lease (contract: bin/fm-lease-lib.sh; no-op in homes without
# leases).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-short-owner-lib.sh
. "$SCRIPT_DIR/fm-short-owner-lib.sh"
trap fm_short_owner_release EXIT
fm_short_owner_enter cleanup "$ID" || exit 1
if [ "${FM_SUPERVISION_ACTOR:-}" = short ] && { [ -n "$FORCE" ] || [ "${LEGACY_RECORD_GIVEN:-0}" != 0 ]; }; then
  echo "error: short cleanup cannot discard or manufacture legacy identity" >&2
  exit 1
fi
# Role partition: forced teardown discards work, and the supervision branch
# never discards anything - only an ordinary landed-work teardown is branch
# territory (contract: bin/fm-lease-lib.sh).
if [ "$FORCE" = --force ] && [ "$(fm_lease_actor)" = branch ]; then
  echo "error: forced teardown refused - the supervision branch cannot discard work" >&2
  exit "$FM_LEASE_REFUSE_EXIT"
fi
fm_lease_guard "$ID" "teardown (fm-teardown)"

META="$STATE/$ID.meta"
TREEHOUSE_PROJECT_LOCK=
TREEHOUSE_PROJECT_LOCK_HELD=0
TREEHOUSE_SLOT_LOCK_REQUIRED=0
if [ -f "$META" ] && [ ! -L "$META" ]; then
  TEARDOWN_LOCK_KIND=$(fm_meta_get "$META" kind)
  [ -n "$TEARDOWN_LOCK_KIND" ] || TEARDOWN_LOCK_KIND=ship
  TEARDOWN_LOCK_BACKEND=$(fm_meta_get "$META" backend)
  [ -n "$TEARDOWN_LOCK_BACKEND" ] || TEARDOWN_LOCK_BACKEND=tmux
  fm_backend_validate "$TEARDOWN_LOCK_BACKEND" || {
    fm_lease_guard_release
    exit 1
  }
  TEARDOWN_LOCK_WT=$(fm_meta_get "$META" worktree)
  TEARDOWN_LOCK_PROJECT=$(fm_meta_get "$META" project)
  if [ "$ENDPOINT_ONLY" = 0 ] && fm_treehouse_pool_slot "$TEARDOWN_LOCK_PROJECT" "$TEARDOWN_LOCK_WT"; then
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
teardown_release_locks() {
  # shellcheck disable=SC2319 # EXIT trap status or explicit manual release status.
  local status=${1:-$?} i
  if [ -n "${ENDPOINT_SESSION_LOCK:-}" ]; then
    fm_lock_release "$ENDPOINT_SESSION_LOCK" || true
    ENDPOINT_SESSION_LOCK=
  fi
  fm_short_owner_release || true
  if declare -F teardown_release_herdr_locks >/dev/null 2>&1; then
    teardown_release_herdr_locks || true
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
[ "$TEARDOWN_META_KIND" != secondmate ] || {
  echo "REFUSED: task $ID is a historical secondmate record; automatic teardown is no longer supported and its home was left untouched" >&2
  exit 1
}
fm_control_require_recoverable_harness "$(fm_meta_get "$META" harness)" || exit 1
# Ordinary compact continuation retains semantic acceptance in the canonical
# per-task business and progress record.
# shellcheck source=bin/fm-task-progress-lib.sh
. "$SCRIPT_DIR/fm-task-progress-lib.sh"
fm_task_progress_completion_guard "$ID" || exit $?
ENDPOINT_PHASE_DONE=0
if [ "$ENDPOINT_ONLY" = 1 ]; then
  # This branch is before all worktree, slot, branch and record retirement
  # operations. It owns only positive endpoint identity and its receipts.
  # shellcheck source=bin/fm-teardown-endpoint-lib.sh
  . "$SCRIPT_DIR/fm-teardown-endpoint-lib.sh"
  [ -n "$ENDPOINT_EXPECTED_GEN" ] || ENDPOINT_EXPECTED_GEN=$(fm_meta_get "$META" spawn_gen)
  endpoint_rc=0
  teardown_endpoint_phase "$ENDPOINT_EXPECTED_GEN" || endpoint_rc=$?
  if [ "$endpoint_rc" = 11 ] && [ "${FM_ENDPOINT_EXIT_ATTEMPTED:-0}" != 1 ]; then
    teardown_release_locks 0
    "$SCRIPT_DIR/fm-control.sh" "$ID" exit --expect-spawn-gen "$ENDPOINT_EXPECTED_GEN" || exit 1
    if [ "$ENDPOINT_ONLY" = 1 ]; then
      FM_ENDPOINT_EXIT_ATTEMPTED=1 exec "$0" "$ID" --endpoint-only --expect-spawn-gen "$ENDPOINT_EXPECTED_GEN"
    else
      FM_ENDPOINT_EXIT_ATTEMPTED=1 exec "$0" "$ID" --expect-spawn-gen "$ENDPOINT_EXPECTED_GEN"
    fi
  fi
  [ "$endpoint_rc" = 0 ] || exit "$endpoint_rc"
  [ "$ENDPOINT_ONLY" = 0 ] || exit 0
  fm_lock_release "$ENDPOINT_SESSION_LOCK"
  ENDPOINT_SESSION_LOCK=
  ENDPOINT_PHASE_DONE=1
fi
TEARDOWN_META_SPAWN_GEN=$(fm_meta_get "$META" spawn_gen)
TEARDOWN_LEGACY_PENDING=0
TEARDOWN_LEGACY_ACCEPTED=0
TEARDOWN_LEGACY_ENDPOINT=
TEARDOWN_LEGACY_RETAINED_STAMP=
TEARDOWN_LEGACY_PRESTAMP_SIZE=0
TEARDOWN_BACKLOG_APPLIES=0
TEARDOWN_BACKLOG_SKIP_REASON=
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
if [ "$TEARDOWN_META_KIND" != secondmate ]; then
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

# This is the first cleanup authorization check. It is metadata-only and must
# complete before fm-guard, a backend command, file removal, branch deletion,
# worktree return, registry change, or process termination can run.
fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
T=$FM_BACKEND_VALIDATED_TARGET
WT=$(fm_meta_get "$META" worktree)
PROJ=$(fm_meta_get "$META" project)
if [ "${FM_SUPERVISION_ACTOR:-}" != short ] && [ "${FM_TEARDOWN_GUARD_DONE:-0}" != 1 ]; then
  "$FM_ROOT/bin/fm-guard.sh" || true
fi
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
# tasktmp is recorded by fm-spawn for tasks that set up a per-task temp root
# (/tmp/fm-<id>/); absent for tasks spawned before that change, so tolerate empty.
TASK_TMP=$(grep '^tasktmp=' "$META" | cut -d= -f2- || true)
BUSY_GEN=$(fm_meta_get "$META" busy_gen)
if [ -z "$BUSY_GEN" ]; then
  BUSY_GEN=$(cat "$STATE/$ID.busy-gen" 2>/dev/null || true)
fi

KIND=$TEARDOWN_META_KIND
EXPECTED_TREEHOUSE_PROJECT_LOCK=
if fm_treehouse_pool_slot "$PROJ" "$WT"; then
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

meta_value() {
  local meta=$1 key=$2
  fm_meta_get "$meta" "$key"
}

# Where a harness's firstmate-owned global turn-end registry entry lives is
# owned by bin/fm-control-lib.sh, so teardown and the control plane's relaunch
# retire the same artifact rather than each carrying its own copy of the path.


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
    "$state_dir/$id.merge-authority" "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.merge-authority" "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ] \
      || { [ "$artifact" = "$state_dir/$id.merge-authority" ] \
        && [ "$(fm_pr_file_mode "$artifact")" != 600 ]; }; then
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
    "$state_dir/$id.merge-authority" "$state_dir/$id.check-trust" || return 1
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
TEARDOWN_PROCEVENT_RESTORE_FAILED=4

# True when treehouse/git stderr shows the transient index.lock "File exists" race.
# Other return failures must not enter the retry path.
treehouse_return_is_index_lock_error() {
  local text=$1
  printf '%s\n' "$text" | grep -Eq "Unable to create ['\"].*index\\.lock['\"]: File exists"
}

treehouse_return_is_unmanaged_error() {
  local text=$1 dir=$2
  printf '%s\n' "$text" | grep -Fq "worktree $dir is not managed by treehouse"
}

# The lock-staleness proof (lsof holder check, mtime age, fail-safe defaults)
# is owned by bin/fm-lock-lib.sh's fm_lock_is_provably_stale, sourced above.
# Teardown passes the worktree dir as the companion directory and its own
# STALE_WORKTREE_LOCK_AGE_SECS threshold.

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
  local dir=$1 cd_dir=$2 label=$3 post_cleanup_check=${4:-}
  local out lock attempt=0 max_retries lock_desc managed_dir

  # Capture stdout+stderr so non-lock failures stay visible and lock failures can
  # be matched by signature even when the lock file is already gone mid-check.
  if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  if treehouse_return_is_unmanaged_error "$out" "$dir"; then
    if ! treehouse_managed_return_path_for_identity "$dir" "$cd_dir"; then
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      echo "REFUSED: Treehouse rejected recorded $label path $dir and did not expose exactly one managed path with the same directory identity; preserving task state." >&2
      return 1
    fi
    managed_dir=$TREEHOUSE_MANAGED_RETURN_PATH
    if [ ! -d "$dir" ] || [ ! -d "$managed_dir" ] || [ ! "$managed_dir" -ef "$dir" ]; then
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      echo "REFUSED: recorded $label path $dir or Treehouse-managed path $managed_dir changed during identity verification; preserving task state." >&2
      return 1
    fi
    echo "teardown: recorded $label path $dir and Treehouse-managed path $managed_dir have the same directory identity; retrying the exact managed path" >&2
    dir=$managed_dir
    if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
      [ -n "$out" ] && printf '%s\n' "$out"
      return 0
    fi
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

    if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
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
      if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
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
# worktree (scouts never do, mirroring bin/fm-crew-state.sh);
# a run not attributed to this exact branch+head is left completely alone.
conclude_task_no_mistakes_run() {  # <worktree>
  local wt=$1 out run_id
  [ "$KIND" = ship ] || return 0
  case "$MODE" in no-mistakes|no-mistakes-prod-only) ;; *) return 0 ;; esac
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
  echo "warning: lsof is unavailable; cannot resolve a process-group fallback for $BACKEND task $ID; preserving unverified processes" >&2
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

# The task's own live slot, canonicalized, or empty when this record has no slot
# to release (no worktree= or a path that is already gone). Every slot-ownership
# check below is scoped to that value, so a record with nothing live to return
# skips them rather than refusing.
teardown_live_slot_path() {
  fm_treehouse_pool_slot "$PROJ" "$WT" || return 1
  canonical_existing_dir "$WT"
}

require_exclusive_worktree_slot_record() {
  local record_meta=$1 record_id=$2 record_state=$3 worktree=$4
  local slot other other_id field other_path other_slot
  slot=$(canonical_existing_dir "$worktree") || return 0
  for other in "$record_state"/*.meta; do
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
}

require_exclusive_task_worktree_slot() {
  local slot
  slot=$(teardown_live_slot_path) || return 0
  require_exclusive_worktree_slot_record "$META" "$ID" "$STATE" "$slot"
}

# Positive slot ownership, read from the claim the task that took the slot wrote
# into the slot itself (bin/fm-wake-lib.sh owns the claim and its states).
#
# The record scan above proves that no OTHER task record names this slot. It
# cannot prove that THIS record is not the stale one, because the task that took
# the slot next may leave no record this scan can reach: its own worker may have
# exited and its record been cleaned up, or it may belong to a home this machine
# does not register. The claim closes that gap from the other side - it names the
# task that actually took the slot, and it is written under the same project lock
# that allocates it - so a claim naming another task is proof the slot was
# reassigned after this record was written.
#
# A claim naming another task does not refuse: it means the slot is no longer
# this task's, so the record's own cleanup proceeds and every slot step is
# skipped (see the script header for why refusing would strand the record and
# why skipping discards nothing). Returns TEARDOWN_SLOT_REASSIGNED_RC for that
# state so each caller gates its slot steps on one determination; the claimant
# stays in FM_TREEHOUSE_SLOT_OWNER_ID and FM_TREEHOUSE_SLOT_OWNER_HOME.
#
# An absent claim proves no ownership. Structured terminal cleanup may already
# have closed its positively identified endpoint before reaching this check,
# but the directory, slot and task record remain as a concrete reconciliation
# obligation until a matching generation claim exists.
TEARDOWN_SLOT_REASSIGNED_RC=3
require_owned_worktree_slot_record() {  # <task-id> <worktree> <spawn-gen>
  local record_id=$1 worktree=$2 generation=$3 marker
  case "$generation" in
    ''|.*|*[!A-Za-z0-9._-]*)
      echo "REFUSED: task $record_id has a missing or invalid execution generation; retain its cleanup obligation and the recorded slot unchanged." >&2
      return 1 ;;
  esac
  fm_treehouse_slot_owner_state "$worktree" "$record_id" "$generation"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    mine) return 0 ;;
    absent)
      marker=$(fm_treehouse_slot_owner_marker "$worktree" 2>/dev/null) || marker="beside $worktree"
      echo "REFUSED: task $record_id's recorded worktree $worktree has no slot-owner claim, so this execution cannot prove it still owns the directory or slot; retaining the cleanup obligation and changing neither - not even with --force." >&2
      echo "Reconcile or conservatively migrate the claim at $marker with this task and execution generation, then re-run teardown." >&2
      return 1
      ;;
    other)
      echo "warning: task $record_id's recorded worktree $worktree was reassigned to task $FM_TREEHOUSE_SLOT_OWNER_ID${FM_TREEHOUSE_SLOT_OWNER_HOME:+ (home $FM_TREEHOUSE_SLOT_OWNER_HOME)}, which claimed that pool slot after this record was written; that slot is no longer $record_id's, so its processes, copy, and claim are left untouched and only $record_id's own cleanup runs." >&2
      return "$TEARDOWN_SLOT_REASSIGNED_RC"
      ;;
  esac
  marker=$(fm_treehouse_slot_owner_marker "$worktree" 2>/dev/null) || marker="beside $worktree"
  echo "REFUSED: task $record_id's recorded worktree $worktree carries a slot-owner claim that cannot be bound to this execution, so the slot cannot be proved to still be this task's; nothing was changed - not even with --force." >&2
  echo "Inspect or repair the claim file at $marker (task=, home=, and spawn_gen= lines), then re-run teardown." >&2
  return 1
}

# The one ownership determination for this task's recorded slot. Every later
# step that would read or touch $WT consults teardown_owns_worktree, so a
# reassigned slot is skipped consistently rather than by each step's own guess.
TEARDOWN_SLOT_REASSIGNED=0
TEARDOWN_SLOT_REASSIGNED_TO=
TEARDOWN_SLOT_REASSIGNED_HOME=
require_owned_task_worktree_slot() {
  local slot rc=0
  slot=$(teardown_live_slot_path) || return 0
  require_owned_worktree_slot_record "$ID" "$slot" "$(fm_meta_get "$META" spawn_gen)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    "$TEARDOWN_SLOT_REASSIGNED_RC")
      if [ "${FM_SUPERVISION_ACTOR:-}" = short ]; then
        echo "REFUSED: short cleanup target was reassigned; explicit reconciliation is required" >&2
        return 1
      fi
      TEARDOWN_SLOT_REASSIGNED=1
      TEARDOWN_SLOT_REASSIGNED_TO=$FM_TREEHOUSE_SLOT_OWNER_ID
      TEARDOWN_SLOT_REASSIGNED_HOME=$FM_TREEHOUSE_SLOT_OWNER_HOME
      return 0
      ;;
  esac
  return 1
}

teardown_owns_worktree() {
  [ "$TEARDOWN_SLOT_REASSIGNED" != 1 ]
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
  local task_id=$1 prerequisite
  if ! fm_backend_source herdr; then
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

require_exclusive_task_worktree_slot || exit 1
require_owned_task_worktree_slot || exit 1

validate_pr_poll_cleanup "$STATE" "$ID" || exit 1

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
    echo "Inventory its report and any structured review through bin/fm-captain-hold.sh before teardown." >&2
    exit 1
  fi
fi

# A public commitment is not kept until its final reply lands in the ORIGINAL
# thread, and this cleanup removes the task records that make the promise
# reconcilable. Refuse while this home still owes a public reply for exactly this
# work. Both gates live in bin/fm-public-followup-lib.sh, so a home that never
# opted into the myfirstmate relay runs one [ -f ] test and nothing else here.
teardown_public_followup_guard

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

if teardown_owns_worktree && [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
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
  BACKLOG_SKIP_REASON=$TEARDOWN_BACKLOG_SKIP_REASON
fi

# Every landed/discard-work refusal above has now passed (or --force skipped
# them). Fix 1 and Fix 2 (see script header) run here, unconditionally on
# --force, and before ANY destructive step below - a still-parked run or a
# leaked process can own live work in this exact worktree.
fm_short_owner_effect || exit 1
if teardown_owns_worktree; then
  conclude_task_no_mistakes_run "$WT"
  reap_task_worktree_processes worktree "$WT" "$TASK_TMP"
else
  reap_task_worktree_processes tasktmp "$TASK_TMP"
fi

fm_short_owner_effect || exit 1
# Best-effort: drop the local task branch so the shared repo does not accumulate refs.
if ! teardown_owns_worktree; then
  :
elif [ -d "$WT" ]; then
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if [ "$branch" != "HEAD" ]; then
    if git -C "$WT" checkout --detach -q 2>/dev/null; then
      git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
    fi
  fi
  # Remove our hook file so a reused pool worktree cannot fire signals for a dead task.
  # Kills remaining processes in the worktree (including the agent), resets, returns
  # to pool. treehouse resolves the pool from the working directory, so run it from
  # the project. teardown_treehouse_return tolerates transient and stale git locks
  # left by a killed crew process; see the script header for retry and stale-lock proof.
  post_lock_cleanup_check=
  if [ "$FORCE" != "--force" ] && [ "$KIND" != scout ]; then
    post_lock_cleanup_check=validate_worktree_teardown_safety
  fi
  fm_short_owner_effect || exit 1
  teardown_treehouse_return "$WT" "$PROJ" "worktree" "$post_lock_cleanup_check" || {
    echo "error: treehouse return failed for worktree $WT; teardown aborted" >&2
    exit 1
  }
  # The slot is back in the pool, so this task's claim on it is spent. Dropping
  # it here - and only after a return that succeeded - keeps a returned slot
  # unclaimed until its next holder claims it, and leaves the claim in place
  # whenever the return did not actually happen.
  fm_treehouse_slot_owner_release "$WT" "$ID" "$(fm_meta_get "$META" spawn_gen)"
fi
if [ "$ENDPOINT_PHASE_DONE" = 1 ]; then
  if teardown_owns_worktree; then
    teardown_endpoint_receipt directory_return confirmed existing-directory-guards-passed || exit 1
  else
    teardown_endpoint_receipt directory_return retained reassigned-slot || exit 1
  fi
fi

fm_short_owner_effect || exit 1
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

if [ "$ENDPOINT_PHASE_DONE" = 1 ]; then
  : # The exact pane absence was already verified and durably receipted.
elif [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
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
fi
if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
  if [ "$(fm_backend_herdr_pane_agent_state "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_PANE")" = dead ]; then
    # Structured cleanup needs this exact binding until bookkeeping commits;
    # an interrupted retry must still prove the already-absent endpoint.
    [ "$ENDPOINT_PHASE_DONE" = 1 ] || rm -f "$HERDR_PRESENTATION_JOURNAL"
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
fm_short_owner_effect || exit 1
fm_backend_clear_transition "$BACKEND" "$STATE" "$T" || true
# Remove the per-task temp root (/tmp/fm-<id>/, incl. its gotmp/) recorded by spawn.
# Read before the state-file rm below; empty (pre-fix tasks without tasktmp=) is a no-op.
[ -n "$TASK_TMP" ] && rm -rf "$TASK_TMP"
remove_pr_poll_artifacts "$STATE" "$ID" || exit 1
retire_busy_state "$STATE" "$ID" "$BUSY_GEN" || exit 1
status_retire_presentation_task "$STATE" "$ID" || exit 1
rm -f "$STATE/$ID.turn-ended" "$STATE/$ID.progress" \
  "$STATE/$ID.pi-ext.ts" "$STATE/$ID.busy-session" \
  "$STATE/$ID.control-relaunch" "$STATE/$ID.control-relaunch.meta-prior" \
  "$STATE/$ID.control-relaunch.brief-prior" "$STATE/$ID.control-relaunch.note" \
  "$STATE/$ID.reconcile-nudged" \
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
fm_short_owner_effect || exit 1
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
else
  if ! fm_backlog_atomic_transition remove "$STATE/$ID.meta" "task record" "$STATE"; then
    fm_lock_release "$META_LOCK"
    META_LOCK_HELD=0
    echo "error: $ID's endpoint and local copy are cleaned up, but its task record could not be removed ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
fi
fm_cleanup_receipt completion-record "$ID" "$TEARDOWN_META_SPAWN_GEN" --facts \
  '{"taskRecordRemoved":true,"endpointConfirmedGone":true,"copyDisposition":"returned-or-already-absent","bookkeepingComplete":true}' >/dev/null || {
  echo 'actionable: cleanup completed but cleanup receipt recording failed; read back before retrying effects' >&2
  exit 1
}
if [ "$ENDPOINT_PHASE_DONE" = 1 ]; then
  teardown_endpoint_receipt record_close confirmed metadata-removed-report-retained || exit 1
  rm -f "$HERDR_PRESENTATION_JOURNAL"
fi
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0
if [ "${FM_SUPERVISION_ACTOR:-}" != short ] && [ "$KIND" != scout ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
if [ "$TEARDOWN_LEGACY_ACCEPTED" = 1 ]; then
  echo "teardown $ID complete (window $T, worktree $WT, legacy record accepted without spawn_gen: endpoint $TEARDOWN_LEGACY_ENDPOINT, incarnation $TEARDOWN_META_SPAWN_GEN)"
elif teardown_owns_worktree; then
  echo "teardown $ID complete (window $T, worktree $WT)"
else
  echo "teardown $ID complete (window $T; pool slot $WT left to task $TEARDOWN_SLOT_REASSIGNED_TO${TEARDOWN_SLOT_REASSIGNED_HOME:+ (home $TEARDOWN_SLOT_REASSIGNED_HOME)}, which it was reassigned to)"
fi
backlog_refresh_reminder

fm_short_owner_receipt '{"taskRecordRemoved":true,"endpointConfirmedGone":true,"copyDisposition":"returned-or-already-absent","bookkeepingComplete":true}'
