#!/usr/bin/env bash
# Move an already-running task to a different dispatch-pool account after its
# current account wedges on a usage limit.
#
# Usage:
#   fm-pool-failover.sh <task-id> [--to <backend-id>] [--reason <text>]
#                                 [--from-file <agent-output>] [--no-cooldown]
#                                 [--no-respawn] [--dry-run]
#
#   --to           pin the replacement account instead of taking the next healthy
#                  one by rotation. The named account must itself be healthy.
#   --reason       cooldown reason recorded for the OLD account.
#   --from-file    file holding the agent's own output; its usage-limit signature
#                  supplies both the reason and the parsed reset time.
#   --no-cooldown  do not cool the old account down (it was not actually limited).
#   --no-respawn   do everything except relaunch; leaves the RESUME NOTE in place.
#   --dry-run      report exactly what would happen and change nothing.
#
# WHY THIS REFUSES A DIRTY WORKTREE
# A failover ABANDONS the old worktree: the old agent is killed and the worktree
# is returned to the pool, which discards anything not committed. Committed work
# is safe because it lives on the task's branch in the shared object store, and
# the replacement worker checks that branch out in its fresh worktree. So this
# script refuses outright when `git status --porcelain` reports anything, and
# that refusal is a stop-and-investigate result, never an obstacle to bypass.
# There is deliberately no --force: losing uncommitted work is exactly how work
# was lost the day this script was written.
#
# WHAT IT DOES, IN ORDER
#   1. Reads state/<id>.meta and refuses anything that is not a live pooled or
#      poolable ship/scout task.
#   2. Refuses a dirty worktree; records the task's branch and tip commit.
#   3. Cools the OLD account down so rotation stops handing it work.
#   4. Selects a healthy replacement account, excluding the old one. Accounts on
#      the task's own harness are preferred; when none is healthy the search
#      widens to every harness, and a cross-harness move drops the recorded
#      model/effort so the new harness runs on its own defaults.
#   5. Kills the old agent endpoint and re-checks that the worktree is still
#      clean (the agent may have written while being shut down). A re-check that
#      refuses stops here, having changed nothing else.
#   6. Appends a RESUME NOTE to data/<id>/brief.md naming the branch and tip,
#      then returns the old worktree to the pool.
#   7. Respawns the task on the replacement account via fm-spawn.sh --pool-backend.
#
# It never force-pushes, never touches a `main` branch, never writes inside the
# project checkout, and never prints or copies an account key.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

log() {
  printf 'fm-pool-failover: %s\n' "$*" >&2
}

die() {
  log "$*"
  exit 1
}

# Print the worktree's uncommitted changes, minus firstmate's own launch-time
# hook files (the same exclusion list fm-teardown uses: untracked artifacts
# firstmate wrote itself, not the crewmate's work). Fails only when git status
# itself cannot be read.
worktree_dirty() {
  local wt=$1 raw
  raw=$(git -C "$wt" status --porcelain 2>/dev/null) || return 1
  printf '%s\n' "$raw" | grep -vE '^\?\? (\.claude/|\.fm-grok-turnend$)' | grep -v '^[[:space:]]*$' || true
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac

ID=$1
shift
TO=
REASON=
FROM_FILE=
DO_COOLDOWN=1
DO_RESPAWN=1
DRY_RUN=0
want=
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      to) TO=$a ;;
      reason) REASON=$a ;;
      from_file) FROM_FILE=$a ;;
    esac
    want=
    continue
  fi
  case "$a" in
    --to) want=to ;;
    --to=*) TO=${a#--to=} ;;
    --reason) want=reason ;;
    --reason=*) REASON=${a#--reason=} ;;
    --from-file) want=from_file ;;
    --from-file=*) FROM_FILE=${a#--from-file=} ;;
    --no-cooldown) DO_COOLDOWN=0 ;;
    --no-respawn) DO_RESPAWN=0 ;;
    --dry-run) DRY_RUN=1 ;;
    *) die "unknown option '$a'" ;;
  esac
done
[ -z "$want" ] || die "--${want//_/-} requires a value"

META="$STATE/$ID.meta"
[ -f "$META" ] || die "no task metadata for '$ID' at $META"

meta_value() {
  sed -n "s/^$1=//p" "$META" | tail -1
}

WT=$(meta_value worktree)
PROJECT=$(meta_value project)
KIND=$(meta_value kind)
HARNESS=$(meta_value harness)
MODEL=$(meta_value model)
EFFORT=$(meta_value effort)
OLD_POOL=$(meta_value pool_backend)
RUNTIME_BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")

case "$KIND" in
  ship|scout) ;;
  secondmate) die "task '$ID' is a secondmate; a secondmate's account is pinned by its own home and is not failed over this way" ;;
  *) die "task '$ID' has an unrecognized kind '$KIND'" ;;
esac
[ -n "$WT" ] || die "task '$ID' has no recorded worktree; recover it with the stuck-crewmate playbook before failing it over"
[ -d "$WT" ] || die "recorded worktree for '$ID' is gone ($WT); recover it with the stuck-crewmate playbook before failing it over"
[ -n "$PROJECT" ] || die "task '$ID' has no recorded project"
[ -f "$DATA/$ID/brief.md" ] || die "task '$ID' has no brief at $DATA/$ID/brief.md"

# --- the refusal that protects unlanded work --------------------------------
git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 || die "recorded worktree for '$ID' is not a git worktree ($WT)"
DIRTY=$(worktree_dirty "$WT") \
  || die "cannot read git status in $WT; refusing to abandon a worktree whose state is unknown"
if [ -n "$DIRTY" ]; then
  log "REFUSED: worktree $WT has uncommitted changes."
  printf '%s\n' "$DIRTY" >&2
  log "A failover abandons this worktree, so those changes would be lost."
  log "Commit them on the task branch first, then re-run. There is no --force here by design."
  exit 1
fi

BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
TIP=$(git -C "$WT" rev-parse --short HEAD 2>/dev/null || true)
[ -n "$BRANCH" ] && [ "$BRANCH" != HEAD ] \
  || die "worktree $WT is not on a named branch (HEAD is detached); commit the work to a task branch before failing over"
case "$BRANCH" in
  main|master|trunk) die "worktree $WT is on '$BRANCH'; pool machinery never operates on a default branch" ;;
esac

# --- choose the replacement account -----------------------------------------
pool_call() {
  FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" "$FM_ROOT/bin/fm-pool.sh" "$@"
}

POOL_STATUS=0
if [ -n "$TO" ]; then
  POOL_OUT=$(pool_call resolve "$TO") || POOL_STATUS=$?
else
  POOL_OUT=$(pool_call select ${HARNESS:+--harness "$HARNESS"} ${OLD_POOL:+--exclude "$OLD_POOL"} --peek) || POOL_STATUS=$?
  if [ "$POOL_STATUS" = 4 ] && [ -n "$HARNESS" ]; then
    log "no healthy $HARNESS account is available; widening the search to every harness"
    POOL_STATUS=0
    POOL_OUT=$(pool_call select ${OLD_POOL:+--exclude "$OLD_POOL"} --peek) || POOL_STATUS=$?
  fi
fi
case "$POOL_STATUS" in
  0) ;;
  3) die "no dispatch pool is configured, so there is no other account to fail over to" ;;
  4) die "no healthy replacement account is available; the task stays where it is rather than moving to an exhausted account" ;;
  2) die "the dispatch pool could not be read: config/dispatch-pool.json is malformed, names an unknown backend, or jq is missing. That is a configuration error, not exhausted capacity; fix the config and re-run. The task stays where it is." ;;
  *) die "fm-pool.sh failed unexpectedly (exit $POOL_STATUS); the task stays where it is rather than moving on a result we cannot trust" ;;
esac
NEW_POOL=$(printf '%s\n' "$POOL_OUT" | sed -n 's/^backend=//p' | head -1)
[ -n "$NEW_POOL" ] || die "dispatch pool returned no replacement account"
[ "$NEW_POOL" != "$OLD_POOL" ] || die "the dispatch pool offered the same account ($NEW_POOL); nothing to fail over to"
NEW_HARNESS=$(printf '%s\n' "$POOL_OUT" | sed -n 's/^harness=//p' | head -1)
CROSS_HARNESS=0
if [ -n "$HARNESS" ] && [ -n "$NEW_HARNESS" ] && [ "$NEW_HARNESS" != "$HARNESS" ]; then
  CROSS_HARNESS=1
fi

printf 'task      %s (%s, harness=%s)\n' "$ID" "$KIND" "$HARNESS"
printf 'branch    %s at %s\n' "$BRANCH" "$TIP"
printf 'worktree  %s (clean, will be abandoned)\n' "$WT"
printf 'account   %s -> %s\n' "${OLD_POOL:-<unpooled>}" "$NEW_POOL"
[ "$CROSS_HARNESS" = 0 ] || printf 'harness   %s -> %s (recorded model/effort dropped; %s uses its own defaults)\n' \
  "$HARNESS" "$NEW_HARNESS" "$NEW_HARNESS"

if [ "$DRY_RUN" = 1 ]; then
  log "dry run: nothing changed"
  exit 0
fi

# --- cool the old account down ----------------------------------------------
if [ "$DO_COOLDOWN" = 1 ] && [ -n "$OLD_POOL" ]; then
  cooldown_args=("$OLD_POOL")
  [ -z "$REASON" ] || cooldown_args+=(--reason "$REASON")
  if [ -n "$FROM_FILE" ]; then
    cooldown_args+=(--from-file "$FROM_FILE")
  fi
  COOLDOWN_STATUS=0
  pool_call cooldown "${cooldown_args[@]}" || COOLDOWN_STATUS=$?
  if [ "$COOLDOWN_STATUS" != 0 ] && [ -n "$FROM_FILE" ]; then
    # The evidence file carried no signature fm-pool.sh recognizes, so it wrote no
    # cooldown at all. Leaving the old account fully healthy is the worst possible
    # outcome - the next rotation hands it the very next crewmate - and it is
    # strictly worse than the same failover run without --from-file. Fall back to
    # the default interval that evidence-free path would have applied.
    log "no usable usage-limit signature in $FROM_FILE; cooling $OLD_POOL down for the default interval instead"
    fallback_args=("$OLD_POOL")
    [ -z "$REASON" ] || fallback_args+=(--reason "$REASON")
    COOLDOWN_STATUS=0
    pool_call cooldown "${fallback_args[@]}" || COOLDOWN_STATUS=$?
  fi
  if [ "$COOLDOWN_STATUS" != 0 ]; then
    # A cooldown that could not be recorded must not abort the move; the point of
    # this script is getting the task onto a working account.
    log "could not record a cooldown for $OLD_POOL; continuing with the failover"
  fi
fi

# --- abandon the old endpoint and worktree ----------------------------------
if [ -n "$TARGET" ]; then
  fm_backend_kill "$RUNTIME_BACKEND" "$TARGET" 2>/dev/null \
    || log "could not kill the old endpoint $TARGET; continuing"
fi
DIRTY=$(worktree_dirty "$WT") \
  || die "cannot re-read git status in $WT after killing the old agent; the worktree was NOT abandoned"
if [ -n "$DIRTY" ]; then
  log "REFUSED: worktree $WT gained uncommitted changes between the first check and the old agent's shutdown."
  printf '%s\n' "$DIRTY" >&2
  die "the worktree was NOT abandoned so that work is preserved; commit it on '$BRANCH', then re-run"
fi

# --- append the RESUME NOTE --------------------------------------------------
#
# Same shape as every other firstmate recovery note: it overrides the brief's
# Setup step, states plainly that committed work is safe and where it lives, and
# gives the exact recovery commands.
#
# Written only AFTER the post-kill clean re-check has passed, because everything
# it asserts - fresh worktree, new account, work safe on the branch - is only
# true once the move is actually going ahead. The re-check refusal leaves the
# brief untouched, exactly like the pre-kill refusal does.
#
# The template is piped STRAIGHT to the brief rather than captured in `$(...)`:
# the note contains backticks, and a backtick inside a quoted heredoc nested in a
# command substitution makes bash resume command-substitution parsing and choke
# on the next apostrophe. Appending directly sidesteps that entirely.
TODAY=$(date +%Y-%m-%d)
sed \
  -e "s|@@DATE@@|$TODAY|g" \
  -e "s|@@OLD@@|${OLD_POOL:-the previous account}|g" \
  -e "s|@@NEW@@|$NEW_POOL|g" \
  -e "s|@@BRANCH@@|$BRANCH|g" \
  -e "s|@@TIP@@|$TIP|g" >> "$DATA/$ID/brief.md" <<'NOTE_TEMPLATE'

# RESUME NOTE (@@DATE@@, from firstmate - read this FIRST, it overrides Setup step 1 and every earlier RESUME NOTE)
Your previous run was moved to a different agent account because @@OLD@@ ran out of capacity mid-task; that run is dead.
**Your work is safe** - every commit you made is on branch `@@BRANCH@@`, tip `@@TIP@@`. Only uncommitted changes would have been at risk, and there were none.
You are now running on account @@NEW@@ in a FRESH worktree. After the isolation check, recover instead of branching:
```
git checkout @@BRANCH@@
```
If the branch is briefly held by the old worktree, wait 30s and retry once; if it still fails, append `blocked:` and stop.
Re-run this project's build and tests to confirm the recovered state before continuing.
Nothing about the task, its acceptance criteria, or any decision already made has changed - do not re-litigate settled work, just pick up where you left off.
NOTE_TEMPLATE
log "appended a RESUME NOTE to $DATA/$ID/brief.md"

if command -v treehouse >/dev/null 2>&1; then
  if ! ( cd "$FM_ROOT" && treehouse return --force "$WT" ) >/dev/null 2>&1; then
    log "could not return the old worktree $WT to the pool; the replacement may need to wait for the branch"
  fi
else
  log "treehouse not found; leaving the old worktree $WT in place"
fi

if [ "$DO_RESPAWN" = 0 ]; then
  log "--no-respawn: task $ID is prepared for relaunch on $NEW_POOL but was not started"
  exit 0
fi

# --- respawn on the replacement account -------------------------------------
spawn_args=("$ID" "$PROJECT" --pool-backend "$NEW_POOL")
[ "$KIND" != scout ] || spawn_args+=(--scout)
[ "$RUNTIME_BACKEND" = tmux ] || spawn_args+=(--backend "$RUNTIME_BACKEND")
if [ "$CROSS_HARNESS" = 0 ]; then
  [ -z "$MODEL" ] || [ "$MODEL" = default ] || spawn_args+=(--model "$MODEL")
  [ -z "$EFFORT" ] || [ "$EFFORT" = default ] || spawn_args+=(--effort "$EFFORT")
fi
exec "$FM_ROOT/bin/fm-spawn.sh" "${spawn_args[@]}"
