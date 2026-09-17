#!/usr/bin/env bash
# Release, reconstruct, and audit Firstmate task workspaces.
#
# Usage:
#   fm-workspace.sh release <task-id>
#   fm-workspace.sh restore <task-id>
#   fm-workspace.sh audit-legacy [<legacy-root>]
#   fm-workspace.sh reclaim-legacy [<legacy-root>]
#
# `release` is the executable owner of early PR-workspace cleanup.  It accepts
# only a clean PR ship whose local HEAD is an ancestor of the exact forge head
# fetched from refs/pull/<n>/head.  Dirty/untracked files, likely ignored secret
# material, a local commit absent from that remote head, an unavailable forge,
# or an uninspectable workspace refuse before removal.  The proof is journaled
# in task metadata before cleanup, making interruption and retry idempotent.
#
# Treehouse tasks are returned and then destroyed exactly, leaving zero idle
# task worktrees.  Orca tasks close their exact terminal and remove their exact
# recorded worktree.  The task record, PR poll, branch/head/base identity, and
# backlog item remain, so merge monitoring needs no local checkout.
#
# `restore` reconstructs the latest exact PR head (including a stacked PR whose
# base is another feature branch), recreates or reuses an agent-free endpoint,
# and records workspace_state=restored.  The ordinary control-plane relaunch
# then starts a worker in that exact branch; it never rebuilds from trunk.
#
# Legacy audit/reclaim is deliberately limited to Treehouse's own conservative
# prune classifier.  Audit is dry-run.  Reclaim passes --yes but never
# --prune-orphans or any --include-* data-loss flag, so dirty, unmerged, leased,
# in-use, backing-repository-missing, or otherwise unverified work is retained.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-workspace-lib.sh
. "$SCRIPT_DIR/fm-workspace-lib.sh"

fail() { printf 'REFUSED: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }
meta_get() { fm_meta_get "$META" "$1"; }

legacy_root() {
  # Treehouse's --root names the parent whose managed pools live in .treehouse/.
  local root=${1:-${TREEHOUSE_ROOT:-${HOME:?HOME is required}}}
  case "$root" in /*) ;; *) fail "legacy Treehouse root must be absolute: $root" ;; esac
  printf '%s\n' "$root"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  audit-legacy)
    [ "$#" -le 2 ] || { usage >&2; exit 2; }
    ROOT=$(legacy_root "${2:-}")
    exec treehouse --root "$ROOT" prune --all --verbose
    ;;
  reclaim-legacy)
    [ "$#" -le 2 ] || { usage >&2; exit 2; }
    ROOT=$(legacy_root "${2:-}")
    exec treehouse --root "$ROOT" prune --all --verbose --yes
    ;;
  release|restore) ACTION=$1 ;;
  *) usage >&2; exit 2 ;;
esac

[ "$#" -eq 2 ] || { usage >&2; exit 2; }
ID=$2
fm_task_id_path_safe "$ID" || fail "invalid task id"
META="$STATE/$ID.meta"
fm_backlog_record_present "$META" "task record" "$STATE" || fail "$FM_BACKLOG_TRANSITION_ERROR"
LOCK=$(fm_meta_lock_path "$META") || fail "cannot resolve task metadata lock"
fm_lock_acquire_wait "$LOCK" || fail "cannot lock task metadata"
LOCK_HELD=1
PROJECT_LOCK=
PROJECT_LOCK_HELD=0
cleanup() {
  local rc=$?
  if [ "${PROJECT_LOCK_HELD:-0}" = 1 ]; then fm_lock_release "$PROJECT_LOCK" || true; fi
  if [ "${LOCK_HELD:-0}" = 1 ]; then fm_lock_release "$LOCK" || true; fi
  return "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_backlog_record_present "$META" "task record" "$STATE" || fail "$FM_BACKLOG_TRANSITION_ERROR"

KIND=$(meta_get kind); [ -n "$KIND" ] || KIND=ship
MODE=$(meta_get mode); [ -n "$MODE" ] || MODE=no-mistakes
BACKEND=$(fm_backend_of_meta "$META")
WT=$(meta_get worktree)
PROJ=$(meta_get project)
PR=$(meta_get pr)
WORKSPACE_STATE=$(meta_get workspace_state)
[ "$KIND" = ship ] || fail "workspace release/restore applies only to ship tasks, not $KIND"
[ "$MODE" != local-only ] || fail "local-only work is not remotely reconstructable and keeps its workspace until landing"
[ -n "$PR" ] || fail "task $ID has no recorded PR"
[ -d "$PROJ" ] || fail "recorded project is unavailable: ${PROJ:-missing}"
# Slot return, destruction, allocation, and the slot-owner claim share the one
# Treehouse project lock that bin/fm-spawn.sh and bin/fm-teardown.sh hold, so a
# slot is never claimed or dropped while another task is taking or returning it.
if [ "$BACKEND" != orca ]; then
  PROJECT_LOCK=$(fm_treehouse_project_lock_path "$PROJ") \
    || fail "cannot resolve the shared Treehouse project lock for $PROJ"
  fm_lock_acquire_wait "$PROJECT_LOCK" \
    || fail "cannot lock Treehouse slot allocation and return for $PROJ"
  PROJECT_LOCK_HELD=1
fi

pr_number() {
  local n=${PR##*/pull/}
  n=${n%%[!0-9]*}
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$n"
}

read_remote_pr() {
  local row rest
  command -v gh >/dev/null 2>&1 || fail "gh is required to prove remote preservation for $PR"
  row=$(CDPATH='' cd -- "$PROJ" && gh pr view "$PR" \
    --json state,headRefOid,headRefName,baseRefName,url \
    -q '[.state,.headRefOid,.headRefName,.baseRefName,.url] | @tsv' 2>/dev/null) \
    || fail "could not read the exact remote PR head for $PR"
  REMOTE_STATE=${row%%$'\t'*}; rest=${row#*$'\t'}
  REMOTE_HEAD=${rest%%$'\t'*}; rest=${rest#*$'\t'}
  REMOTE_BRANCH=${rest%%$'\t'*}; rest=${rest#*$'\t'}
  REMOTE_BASE=${rest%%$'\t'*}
  [ "$REMOTE_STATE" != "$row" ] && [ "$REMOTE_HEAD" != "$rest" ] \
    || fail "forge returned incomplete PR reconstruction data for $PR"
  case "$REMOTE_STATE" in OPEN|MERGED) ;; *) fail "PR $PR is $REMOTE_STATE, not remotely continuable" ;; esac
  case "$REMOTE_HEAD" in [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*) ;; *) fail "forge returned an invalid PR head" ;; esac
  [ "${#REMOTE_HEAD}" -eq 40 ] || fail "forge returned a non-SHA-1 PR head"
  [ -n "$REMOTE_BRANCH" ] || fail "forge returned no PR head branch"
  case "$REMOTE_BRANCH$REMOTE_BASE" in *[$'\n\r\t']*) fail "forge returned an unsafe branch name" ;; esac
}

fetch_remote_head() {  # <worktree>
  local wt=$1 n fetched
  n=$(pr_number) || fail "only canonical GitHub pull-request URLs support early workspace release"
  git -C "$wt" remote get-url origin >/dev/null 2>&1 \
    || fail "workspace has no origin from which refs/pull/$n/head can be fetched"
  git -C "$wt" fetch --quiet origin \
    "+refs/pull/$n/head:refs/fm-workspace/pull/$n/head" \
    || fail "could not fetch the exact remote head for $PR"
  fetched=$(git -C "$wt" rev-parse --verify "refs/fm-workspace/pull/$n/head^{commit}" 2>/dev/null) \
    || fail "fetched PR head is not a commit"
  [ "$fetched" = "$REMOTE_HEAD" ] \
    || fail "PR head changed while it was being preserved (forge $REMOTE_HEAD, fetched $fetched); retry"
}

meta_rewrite() {  # state worktree [extra owned endpoint lines...]
  local state=$1 worktree=$2 tmp line part
  shift 2
  # A released task owns no local path: Treehouse may hand the old slot to
  # another task, so no reader may find it under this record's worktree=.
  [ "$state" != released ] || worktree=
  tmp=$(mktemp "$STATE/.fm-workspace-meta.XXXXXX") || fail "cannot stage task metadata"
  # bin/fm-pr-lib.sh's identity parser accepts only PR-owned lines from pr=
  # onward, so the record's pr= tail stays last and the owned lines go before it.
  for part in head tail; do
    awk -F= -v part="$part" '
      BEGIN { split("worktree workspace_state workspace_head workspace_branch workspace_base workspace_root workspace_lease_holder workspace_released_at window endpoint_task_id backend herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id zellij_session zellij_tab_id zellij_pane_id orca_worktree_id terminal cmux_workspace_id cmux_surface_id", k, " "); for (i in k) owned[k[i]]=1 }
      $1 == "pr" { in_tail=1 }
      ($1 in owned) { next }
      (part == "tail") == (in_tail == 1)
    ' "$META" >> "$tmp" || { rm -f "$tmp"; fail "cannot preserve task metadata"; }
    [ "$part" = head ] || break
    {
      printf 'worktree=%s\n' "$worktree"
      printf 'workspace_state=%s\n' "$state"
      printf 'workspace_head=%s\n' "$REMOTE_HEAD"
      printf 'workspace_branch=%s\n' "$REMOTE_BRANCH"
      printf 'workspace_base=%s\n' "$REMOTE_BASE"
      [ -z "${WORKSPACE_ROOT:-}" ] || printf 'workspace_root=%s\n' "$WORKSPACE_ROOT"
      [ -z "${LEASE_HOLDER:-}" ] || printf 'workspace_lease_holder=%s\n' "$LEASE_HOLDER"
      if [ "$state" = released ]; then printf 'workspace_released_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
      printf 'endpoint_task_id=%s\n' "$ID"
      for line in "$@"; do printf '%s\n' "$line"; done
    } >> "$tmp" || { rm -f "$tmp"; fail "cannot stage task workspace metadata"; }
  done
  chmod 0600 "$tmp" || { rm -f "$tmp"; fail "cannot protect task workspace metadata"; }
  mv -f -- "$tmp" "$META" || { rm -f "$tmp"; fail "cannot publish task workspace metadata"; }
}

current_endpoint_lines() {
  CURRENT_ENDPOINT_LINES=("window=$(meta_get window)")
  case "$BACKEND" in
    tmux) ;;
    herdr) CURRENT_ENDPOINT_LINES+=("backend=herdr" "herdr_session=$(meta_get herdr_session)" "herdr_workspace_id=$(meta_get herdr_workspace_id)" "herdr_tab_id=$(meta_get herdr_tab_id)" "herdr_pane_id=$(meta_get herdr_pane_id)") ;;
    zellij) CURRENT_ENDPOINT_LINES+=("backend=zellij" "zellij_session=$(meta_get zellij_session)" "zellij_tab_id=$(meta_get zellij_tab_id)" "zellij_pane_id=$(meta_get zellij_pane_id)") ;;
    cmux) CURRENT_ENDPOINT_LINES+=("backend=cmux" "cmux_workspace_id=$(meta_get cmux_workspace_id)" "cmux_surface_id=$(meta_get cmux_surface_id)") ;;
    orca) CURRENT_ENDPOINT_LINES+=("backend=orca" "orca_worktree_id=$(meta_get orca_worktree_id)" "terminal=$(meta_get terminal)") ;;
  esac
}

# Ignored project-local secret or runtime material is not reconstructable from
# the remote, so it refuses release.  Generated dependency, build, and cache
# trees are reconstructable and routinely bundle test keys and credentials
# modules, so nothing below them counts.
likely_ignored_secret_present() {  # <worktree>
  local wt=$1 path base
  while IFS= read -r -d '' path; do
    case "/$path" in
      */node_modules/*|*/bower_components/*|*/.pnpm-store/*|*/.yarn/*) continue ;;
      */.venv/*|*/venv/*|*/virtualenv/*|*/.virtualenvs/*|*/site-packages/*|*/__pycache__/*|*/.tox/*|*/.nox/*|*/*.egg-info/*) continue ;;
      */build/*|*/dist/*|*/out/*|*/target/*|*/.build/*|*/.next/*|*/.nuxt/*|*/.svelte-kit/*|*/.turbo/*|*/.parcel-cache/*) continue ;;
      */.dart_tool/*|*/.gradle/*|*/Pods/*|*/DerivedData/*) continue ;;
      */.cache/*|*/cache/*|*/.mypy_cache/*|*/.pytest_cache/*|*/.ruff_cache/*) continue ;;
    esac
    base=${path##*/}
    case "$base" in
      .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*credential*|*secret*) return 0 ;;
      *.sqlite|*.sqlite3|*.db|*.log|*.pid|*.tfstate|*.tfstate.*) return 0 ;;
    esac
  done < <(git -C "$wt" ls-files --others --ignored --exclude-standard -z 2>/dev/null)
  return 1
}

release_treehouse() {
  local root holder
  root=$(fm_workspace_meta_root "$META" "$WT") \
    || fail "cannot identify the Treehouse root that owns $WT"
  holder=$(meta_get workspace_lease_holder)
  WORKSPACE_ROOT=$root
  LEASE_HOLDER=$holder
  current_endpoint_lines
  meta_rewrite releasing "$WT" "${CURRENT_ENDPOINT_LINES[@]}"
  if ! fm_workspace_treehouse_return "$root" "$PROJ" "$WT" "$holder"; then
    fail "Treehouse return failed for $WT; remote proof is recorded and retry is safe, but the local workspace was retained"
  fi
  fm_treehouse_slot_owner_release "$WT" "$ID"
  if ! fm_workspace_treehouse_destroy_idle "$root" "$WT"; then
    current_endpoint_lines
    meta_rewrite reclaim-pending "$WT" "${CURRENT_ENDPOINT_LINES[@]}"
    fail "Treehouse returned $WT but exact idle-workspace destruction failed; retry release to reclaim it"
  fi
  current_endpoint_lines
  meta_rewrite released "$WT" "${CURRENT_ENDPOINT_LINES[@]}"
}

release_orca() {
  local terminal wid
  terminal=$(meta_get terminal); wid=$(meta_get orca_worktree_id)
  [ -n "$terminal" ] && [ -n "$wid" ] || fail "Orca metadata is incomplete"
  WORKSPACE_ROOT=; LEASE_HOLDER=
  meta_rewrite releasing "$WT" "window=$(meta_get window)" "backend=orca" "orca_worktree_id=$wid" "terminal=$terminal"
  fm_backend_kill orca "$terminal" || fail "could not close Orca terminal $terminal"
  meta_rewrite reclaim-pending "$WT" "window=$(meta_get window)" "backend=orca" "orca_worktree_id=$wid" "terminal=$terminal"
  fm_backend_remove_worktree orca "$wid" || fail "could not remove Orca worktree $wid"
  meta_rewrite released "$WT" "window=$(meta_get window)" "backend=orca" "orca_worktree_id=$wid" "terminal=$terminal"
}

# An interrupted release may have completed `treehouse return` before dying in
# `releasing`.  Return leaves the slot clean and detached at a trunk commit that
# need not be an ancestor of the PR head, so re-proving containment there would
# refuse forever.  The journaled proof already covers the task's work; such a
# slot only needs the same exact destroy a reclaim-pending record gets.
interrupted_return_completed() {
  [ "$BACKEND" != orca ] && [ -d "$WT" ] || return 1
  [ -n "$(meta_get workspace_head)" ] && [ -n "$(meta_get workspace_branch)" ] || return 1
  git -C "$WT" rev-parse --verify -q HEAD >/dev/null 2>&1 || return 1
  ! git -C "$WT" symbolic-ref -q HEAD >/dev/null 2>&1 || return 1
  [ -n "$(git -C "$WT" for-each-ref --count=1 --contains HEAD refs/remotes 2>/dev/null)" ] || return 1
  [ -z "$(git -C "$WT" status --porcelain --untracked-files=all 2>/dev/null || echo unreadable)" ] || return 1
  ! likely_ignored_secret_present "$WT"
}

# Identity proof before any recorded path is inspected or touched.  A returned
# slot goes back to the pool, so by the time an interrupted release is retried
# another task may hold and have claimed the same path.  That path is no longer
# this task's: the journaled proof completes the release without touching it.
require_release_slot_identity() {
  [ "$BACKEND" != orca ] && [ -d "$WT" ] || return 0
  fm_treehouse_slot_owner_state "$WT" "$ID"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    mine|absent) return 0 ;;
    other)
      case "$WORKSPACE_STATE" in
        releasing|reclaim-pending)
          REMOTE_HEAD=$(meta_get workspace_head)
          REMOTE_BRANCH=$(meta_get workspace_branch)
          REMOTE_BASE=$(meta_get workspace_base)
          [ -n "$REMOTE_HEAD" ] && [ -n "$REMOTE_BRANCH" ] \
            || fail "slot $WT now belongs to task $FM_TREEHOUSE_SLOT_OWNER_ID and this record kept no reconstruction identity"
          WORKSPACE_ROOT=$(meta_get workspace_root)
          LEASE_HOLDER=$(meta_get workspace_lease_holder)
          current_endpoint_lines
          meta_rewrite released "" "${CURRENT_ENDPOINT_LINES[@]}"
          printf 'workspace %s released; its returned slot now belongs to task %s and was left untouched\n' "$ID" "$FM_TREEHOUSE_SLOT_OWNER_ID"
          exit 0
          ;;
      esac
      fail "recorded workspace $WT is claimed by task $FM_TREEHOUSE_SLOT_OWNER_ID, not $ID; nothing was touched"
      ;;
  esac
  fail "recorded workspace $WT carries an unreadable slot-owner claim, so it cannot be proved to be $ID's; nothing was touched"
}

if [ "$ACTION" = release ]; then
  [ "$WORKSPACE_STATE" = released ] || require_release_slot_identity
  if [ "$WORKSPACE_STATE" = releasing ] && interrupted_return_completed; then
    WORKSPACE_STATE=reclaim-pending
  fi
  case "$WORKSPACE_STATE" in
    released)
      printf 'workspace %s already released\n' "$ID"
      exit 0
      ;;
    reclaim-pending)
      read_remote_pr
      if [ "$BACKEND" = orca ]; then
        WID=$(meta_get orca_worktree_id)
        [ -n "$WID" ] || fail "Orca reclaim record has no worktree identity"
        fm_backend_remove_worktree orca "$WID" \
          || fail "exact Orca worktree removal still fails for $WID"
      else
        WORKSPACE_ROOT=$(fm_workspace_meta_root "$META" "$WT") || fail "cannot identify retained Treehouse root"
        LEASE_HOLDER=$(meta_get workspace_lease_holder)
        fm_treehouse_slot_owner_release "$WT" "$ID"
        fm_workspace_treehouse_destroy_idle "$WORKSPACE_ROOT" "$WT" \
          || fail "exact idle-workspace destruction still fails for $WT"
      fi
      current_endpoint_lines
      meta_rewrite released "$WT" "${CURRENT_ENDPOINT_LINES[@]}"
      printf 'workspace %s released and reclaimed\n' "$ID"
      exit 0
      ;;
    releasing)
      if [ ! -d "$WT" ]; then
        REMOTE_HEAD=$(meta_get workspace_head)
        REMOTE_BRANCH=$(meta_get workspace_branch)
        REMOTE_BASE=$(meta_get workspace_base)
        [ -n "$REMOTE_HEAD" ] && [ -n "$REMOTE_BRANCH" ] \
          || fail "interrupted release removed its workspace without retaining reconstruction identity"
        WORKSPACE_ROOT=$(meta_get workspace_root)
        LEASE_HOLDER=$(meta_get workspace_lease_holder)
        current_endpoint_lines
        meta_rewrite released "$WT" "${CURRENT_ENDPOINT_LINES[@]}"
        printf 'workspace %s recovered its completed interrupted release\n' "$ID"
        exit 0
      fi
      ;;
    active|'') ;;
    *) fail "task $ID workspace is '$WORKSPACE_STATE', not active or released" ;;
  esac
  [ -d "$WT" ] || fail "recorded workspace is missing before remote-preservation proof: ${WT:-missing}"
  [ "$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null)" = "$WT" ] \
    || fail "recorded workspace is not an inspectable worktree root: $WT"
  DIRTY=$(git -C "$WT" status --porcelain --untracked-files=all 2>/dev/null) \
    || fail "cannot inspect $WT for dirty files"
  [ -z "$DIRTY" ] || fail "workspace $WT has dirty or untracked files; commit or preserve them before cleanup"
  likely_ignored_secret_present "$WT" \
    && fail "workspace $WT contains ignored secret-like material; preserve or remove it explicitly before cleanup"
  read_remote_pr
  fetch_remote_head "$WT"
  LOCAL_HEAD=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || fail "cannot resolve local HEAD"
  git -C "$WT" merge-base --is-ancestor "$LOCAL_HEAD" "$REMOTE_HEAD" 2>/dev/null \
    || fail "local HEAD $LOCAL_HEAD is not contained in remote PR head $REMOTE_HEAD; cleanup would lose unique commits"
  case "$BACKEND" in
    orca) release_orca ;;
    tmux|herdr|zellij|cmux) release_treehouse ;;
    *) fail "backend $BACKEND has no workspace release contract" ;;
  esac
  TASKTMP=$(meta_get tasktmp)
  case "$TASKTMP" in "/tmp/fm-$ID"|"${TMPDIR:-/tmp}/fm-$ID") rm -rf -- "$TASKTMP" ;; esac
  printf 'workspace %s released; remote head %s branch %s base %s\n' "$ID" "$REMOTE_HEAD" "$REMOTE_BRANCH" "$REMOTE_BASE"
  exit 0
fi

# restore
case "$WORKSPACE_STATE" in
  restored|active)
    [ -d "$WT" ] || fail "task says workspace is $WORKSPACE_STATE but $WT is missing"
    printf 'workspace %s already available at %s\n' "$ID" "$WT"
    exit 0
    ;;
  released) ;;
  *) fail "task $ID workspace is '$WORKSPACE_STATE', not released" ;;
esac
read_remote_pr
ALLOCATED=
restore_cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -n "${ALLOCATED:-}" ]; then
    if [ "$BACKEND" = orca ]; then
      [ -z "${NEW_TERMINAL:-}" ] || fm_backend_kill orca "$NEW_TERMINAL" >/dev/null 2>&1 || true
      [ -z "${NEW_ORCA_ID:-}" ] || fm_backend_remove_worktree orca "$NEW_ORCA_ID" >/dev/null 2>&1 || true
    else
      fm_workspace_treehouse_return "$WORKSPACE_ROOT" "$PROJ" "$ALLOCATED" "$LEASE_HOLDER" >/dev/null 2>&1 || true
      fm_treehouse_slot_owner_release "$ALLOCATED" "$ID" || true
      fm_workspace_treehouse_destroy_idle "$WORKSPACE_ROOT" "$ALLOCATED" >/dev/null 2>&1 || true
    fi
  fi
  cleanup
  return "$rc"
}
trap restore_cleanup EXIT

W="fm-$ID"
ENDPOINT_LINES=()
if [ "$BACKEND" = orca ]; then
  fm_backend_source orca || fail "Orca backend is unavailable"
  RAW=$(fm_backend_orca_worktree_create "$PROJ" "$W") \
    || fail "could not reconstruct Orca worktree${RAW:+; Orca kept unremovable worktree ${RAW%%$'\t'*}, remove it before retrying}"
  NEW_ORCA_ID=${RAW%%$'\t'*}; REST=${RAW#*$'\t'}; NEW_WT=${REST%%$'\t'*}; NEW_TERMINAL=${REST#*$'\t'}
  [ "$NEW_TERMINAL" != "$REST" ] || NEW_TERMINAL=
  ALLOCATED=${NEW_WT:-$NEW_ORCA_ID}
  [ "$NEW_ORCA_ID" != "$RAW" ] && [ -n "$NEW_WT" ] || fail "Orca returned incomplete worktree identity"
  [ -n "$NEW_TERMINAL" ] || NEW_TERMINAL=$(fm_backend_orca_terminal_create "$NEW_ORCA_ID" "$W") \
    || fail "could not create reconstructed Orca terminal"
  WORKSPACE_ROOT=; LEASE_HOLDER=
  ENDPOINT_LINES=("window=$W" "backend=orca" "orca_worktree_id=$NEW_ORCA_ID" "terminal=$NEW_TERMINAL")
else
  WORKSPACE_ROOT=$(meta_get workspace_root)
  [ -n "$WORKSPACE_ROOT" ] || WORKSPACE_ROOT=$(fm_workspace_root_for_home "$FM_HOME") \
    || fail "cannot resolve this home's workspace root"
  fm_workspace_prepare_root "$WORKSPACE_ROOT" || fail "cannot prepare workspace root $WORKSPACE_ROOT"
  LEASE_HOLDER=$(fm_workspace_lease_holder "$ID" "$FM_HOME") || fail "cannot resolve workspace lease holder"
  NEW_WT=$(CDPATH='' cd -- "$PROJ" && treehouse --root "$WORKSPACE_ROOT" get --lease --lease-holder "$LEASE_HOLDER") \
    || fail "could not allocate reconstructed workspace from $WORKSPACE_ROOT"
  [ -n "$NEW_WT" ] && [ -d "$NEW_WT" ] || fail "Treehouse did not return a reconstructed workspace"
  ALLOCATED=$NEW_WT
  fm_treehouse_slot_owner_claim "$NEW_WT" "$ID" "$FM_HOME" \
    || fail "could not claim reconstructed Treehouse slot $NEW_WT for task $ID"
fi

[ -z "$(git -C "$NEW_WT" status --porcelain --untracked-files=all 2>/dev/null)" ] \
  || fail "reconstructed workspace is not clean"
fetch_remote_head "$NEW_WT"
git -C "$NEW_WT" checkout --detach -q "$REMOTE_HEAD" || fail "could not detach reconstructed workspace at $REMOTE_HEAD"
if git -C "$NEW_WT" show-ref --verify --quiet "refs/heads/$REMOTE_BRANCH"; then
  git -C "$NEW_WT" branch -f "$REMOTE_BRANCH" "$REMOTE_HEAD" >/dev/null \
    || fail "could not move local branch $REMOTE_BRANCH to remote PR head"
else
  git -C "$NEW_WT" branch "$REMOTE_BRANCH" "$REMOTE_HEAD" \
    || fail "could not create local branch $REMOTE_BRANCH"
fi
git -C "$NEW_WT" checkout -q "$REMOTE_BRANCH" || fail "could not check out reconstructed branch $REMOTE_BRANCH"
[ "$(git -C "$NEW_WT" rev-parse HEAD)" = "$REMOTE_HEAD" ] || fail "reconstructed branch is not at exact PR head"

if [ "$BACKEND" != orca ]; then
  fm_backend_source "$BACKEND" || fail "backend $BACKEND is unavailable"
  OLD_TARGET=$(fm_backend_target_of_meta "$META")
  if [ -n "$OLD_TARGET" ] && fm_backend_target_exists "$BACKEND" "$OLD_TARGET" "$W"; then
    NEW_TARGET=$OLD_TARGET
    case "$BACKEND" in
      tmux) ENDPOINT_LINES=("window=$NEW_TARGET") ;;
      herdr) ENDPOINT_LINES=("window=$NEW_TARGET" "backend=herdr" "herdr_session=$(meta_get herdr_session)" "herdr_workspace_id=$(meta_get herdr_workspace_id)" "herdr_tab_id=$(meta_get herdr_tab_id)" "herdr_pane_id=$(meta_get herdr_pane_id)") ;;
      zellij) ENDPOINT_LINES=("window=$NEW_TARGET" "backend=zellij" "zellij_session=$(meta_get zellij_session)" "zellij_tab_id=$(meta_get zellij_tab_id)" "zellij_pane_id=$(meta_get zellij_pane_id)") ;;
      cmux) ENDPOINT_LINES=("window=$NEW_TARGET" "backend=cmux" "cmux_workspace_id=$(meta_get cmux_workspace_id)" "cmux_surface_id=$(meta_get cmux_surface_id)") ;;
    esac
  else
    case "$BACKEND" in
      tmux)
        SES=$(fm_backend_tmux_container_ensure)
        fm_backend_tmux_create_task "$SES" "$W" "$NEW_WT" >/dev/null || fail "could not recreate tmux endpoint"
        NEW_TARGET="$SES:$W"; ENDPOINT_LINES=("window=$NEW_TARGET")
        ;;
      herdr)
        C=$(FM_HOME="$FM_HOME" fm_backend_herdr_container_ensure "$NEW_WT" launcher-home) || fail "could not recreate Herdr container"
        CONTAINER=${C%%$'\t'*}; SEEDED=${C#*$'\t'}; IDS=$(FM_HOME="$FM_HOME" fm_backend_herdr_create_task "$CONTAINER" "$W" "$NEW_WT" "$SEEDED") || fail "could not recreate Herdr endpoint"
        read -r TAB PANE <<EOF
$IDS
EOF
        SES=${CONTAINER%%:*}; WS=${CONTAINER#*:}; NEW_TARGET="$SES:$PANE"
        ENDPOINT_LINES=("window=$NEW_TARGET" "backend=herdr" "herdr_session=$SES" "herdr_workspace_id=$WS" "herdr_tab_id=$TAB" "herdr_pane_id=$PANE")
        ;;
      zellij)
        SES=$(fm_backend_zellij_container_ensure) || fail "could not recreate Zellij container"
        IDS=$(fm_backend_zellij_create_task "$SES" "$W" "$NEW_WT") || fail "could not recreate Zellij endpoint"
        read -r TAB PANE <<EOF
$IDS
EOF
        NEW_TARGET="$SES:$PANE"; ENDPOINT_LINES=("window=$NEW_TARGET" "backend=zellij" "zellij_session=$SES" "zellij_tab_id=$TAB" "zellij_pane_id=$PANE")
        ;;
      cmux)
        fm_backend_cmux_container_ensure || fail "could not ensure cmux"
        IDS=$(fm_backend_cmux_create_task "$W" "$NEW_WT") || fail "could not recreate cmux endpoint"
        read -r WS SURFACE <<EOF
$IDS
EOF
        NEW_TARGET="$WS:$SURFACE"; ENDPOINT_LINES=("window=$NEW_TARGET" "backend=cmux" "cmux_workspace_id=$WS" "cmux_surface_id=$SURFACE")
        ;;
    esac
  fi
  QWT=$(printf "%s" "$NEW_WT" | sed "s/'/'\\\\''/g")
  case "$BACKEND" in
    tmux) fm_backend_tmux_send_text_line "$NEW_TARGET" "cd -- '$QWT'" ;;
    herdr) fm_backend_herdr_send_text_line "$NEW_TARGET" "cd -- '$QWT'" ;;
    zellij) fm_backend_zellij_send_text_line "$NEW_TARGET" "cd -- '$QWT'" "$W" ;;
    cmux) fm_backend_cmux_send_text_line "$NEW_TARGET" "cd -- '$QWT'" "$W" ;;
  esac || fail "could not move reconstructed endpoint into $NEW_WT"
fi

meta_rewrite restored "$NEW_WT" "${ENDPOINT_LINES[@]}"
ALLOCATED=
printf 'workspace %s restored at %s from %s (%s -> %s)\n' "$ID" "$NEW_WT" "$REMOTE_HEAD" "$REMOTE_BRANCH" "$REMOTE_BASE"
