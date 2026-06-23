#!/usr/bin/env bash
# Tear down a finished task: close the backend session, remove/return the
# worktree, clear volatile state, then refresh/prune the project's clone for
# PR-based ship tasks.
# REFUSES if the worktree holds work not on any remote, because teardown removes
# the disposable worktree and kills/archives its backend session.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the report at data/<task-id>/report.md is the work
# product - teardown proceeds once the report exists, and refuses without it.
# Usage: fm-teardown.sh <task-id> [--force]
#   --force skips teardown safety checks, including Codex App archive/worktree
#   proof. Only use it when the captain has explicitly said to discard the work.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$FM_ROOT/bin/fm-backend.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
STATE="$FM_ROOT/state"
ID=$1
FORCE=${2:-}

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
T=$(grep '^window=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
BACKEND=$(grep '^backend=' "$META" | cut -d= -f2- || true)
[ -n "$BACKEND" ] || BACKEND=tmux
ORCA_WORKTREE_ID=$(grep '^orca_worktree_id=' "$META" | cut -d= -f2- || true)
ORCA_TERMINAL=$(grep '^terminal=' "$META" | cut -d= -f2- || true)
CODEX_APP_THREAD_ID=$(grep '^thread_id=' "$META" | cut -d= -f2- || true)
CODEX_APP_ARCHIVED=$(grep '^codex_app_archived=' "$META" | cut -d= -f2- || true)
OPENCODE_SERVER_URL=$(grep '^opencode_server_url=' "$META" | cut -d= -f2- || true)
OPENCODE_SERVER_PID=$(grep '^opencode_server_pid=' "$META" | cut -d= -f2- || true)
OPENCODE_SESSION_ID=$(grep '^opencode_session_id=' "$META" | cut -d= -f2- || true)
OPENCODE_CLOSED=0

KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes

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

git_common_dir() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
}

git_origin_url() {
  git -C "$1" remote get-url origin 2>/dev/null || true
}

same_project_repo() {
  local a=$1 b=$2 a_common b_common a_origin b_origin
  a_common=$(git_common_dir "$a" || true)
  b_common=$(git_common_dir "$b" || true)
  if [ -n "$a_common" ] && [ "$a_common" = "$b_common" ]; then
    return 0
  fi
  a_origin=$(git_origin_url "$a")
  b_origin=$(git_origin_url "$b")
  [ -n "$a_origin" ] && [ "$a_origin" = "$b_origin" ]
}

if [ "$BACKEND" = codex-app ] && [ "$KIND" != scout ] && [ "$FORCE" != "--force" ]; then
  if [ -z "$WT" ]; then
    echo "REFUSED: Codex App ship task $ID has no known worktree path." >&2
    echo "Firstmate cannot prove the work is landed or safe to discard. Record the app-owned worktree path, merge/ship the work, or get the captain's explicit OK to discard, then --force." >&2
    exit 1
  fi
  if [ ! -d "$WT" ] || ! git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "REFUSED: Codex App ship task $ID has invalid worktree path: $WT" >&2
    echo "Firstmate cannot prove the work is landed or safe to discard. Record a real app-owned git worktree path, merge/ship the work, or get the captain's explicit OK to discard, then --force." >&2
    exit 1
  fi
  if ! same_project_repo "$WT" "$PROJ"; then
    echo "REFUSED: Codex App ship task $ID worktree does not belong to project $PROJ: $WT" >&2
    echo "Record the app-owned worktree for this project, merge/ship the work, or get the captain's explicit OK to discard, then --force." >&2
    exit 1
  fi
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ "$branch" != "fm/$ID" ]; then
    echo "REFUSED: Codex App ship task $ID expected worktree branch fm/$ID, got ${branch:-unknown}." >&2
    echo "Record the app-owned task worktree, merge/ship the work, or get the captain's explicit OK to discard, then --force." >&2
    exit 1
  fi
fi

if [ "$BACKEND" = codex-app ] && [ "$KIND" = scout ] && [ "$FORCE" != "--force" ]; then
  REPORT="$FM_ROOT/data/$ID/report.md"
  if [ ! -f "$REPORT" ]; then
    echo "REFUSED: scout task $ID has no report at $REPORT." >&2
    echo "The report is the work product. Have the crewmate write it (or get the captain's explicit OK to discard, then --force)." >&2
    exit 1
  fi
fi

if [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  if [ "$KIND" = scout ]; then
    # Scout worktrees are scratch by contract, but only once the deliverable exists.
    REPORT="$FM_ROOT/data/$ID/report.md"
    if [ ! -f "$REPORT" ]; then
      echo "REFUSED: scout task $ID has no report at $REPORT." >&2
      echo "The report is the work product. Have the crewmate write it (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
  elif [ "$MODE" = local-only ]; then
    # local-only ships have no remote, so the "on a remote" test never passes.
    # The work is safe once it is merged into the local default branch (firstmate
    # does that merge on the captain's approval). Refuse until then.
    DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; exit 1; }
    dirty=$(git -C "$WT" status --porcelain 2>/dev/null | grep -vE '^\?\? (\.claude/|\.opencode/plugins/fm-turn-end\.js$)' | head -1 || true)
    unmerged=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null | head -5 || true)
    if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
      echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
      echo "Merge the branch into local $DEFAULT first (bin/fm-merge-local.sh after the captain approves), or get the captain's explicit OK to discard, then --force." >&2
      exit 1
    fi
  else
    # The fm-spawn hook file is ours, never work product; ignore it in the dirty check.
    dirty=$(git -C "$WT" status --porcelain 2>/dev/null | grep -vE '^\?\? (\.claude/|\.opencode/plugins/fm-turn-end\.js$)' | head -1 || true)
    unpushed=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null | head -5 || true)
    if [ -n "$dirty" ] || [ -n "$unpushed" ]; then
      echo "REFUSED: worktree $WT has work not on any remote." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unpushed" ] && printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      echo "Push the branch (or get the captain's explicit OK to discard, then --force)." >&2
      exit 1
    fi
  fi
fi

if [ "$BACKEND" = codex-app ] && [ -n "$CODEX_APP_THREAD_ID" ] && [ "$CODEX_APP_ARCHIVED" != 1 ] && [ "$FORCE" != "--force" ]; then
  echo "REFUSED: Codex App thread $CODEX_APP_THREAD_ID is not marked archived." >&2
  echo "Use set_thread_archived(threadId=$CODEX_APP_THREAD_ID, archived=true), then run: bin/fm-codex-app mark-archived $ID" >&2
  exit 1
fi

# Best-effort: drop the local task branch so the shared repo does not accumulate refs.
if [ -d "$WT" ]; then
  branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if [ "$branch" != "HEAD" ]; then
    if git -C "$WT" checkout --detach -q 2>/dev/null; then
      git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
    fi
  fi
  # Remove our hook file so a reused pool worktree cannot fire signals for a dead task.
  rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js"
  case "$BACKEND" in
    tmux)
      # Kills remaining processes in the worktree (including the agent), resets, returns
      # to pool. treehouse resolves the pool from the working directory, so run it from
      # the project.
      ( cd "$PROJ" && treehouse return --force "$WT" )
      ;;
    orca)
      if [ -n "$ORCA_TERMINAL" ]; then
        orca terminal close --terminal "$ORCA_TERMINAL" --json >/dev/null 2>&1 || true
      fi
      if [ -n "$ORCA_WORKTREE_ID" ]; then
        orca worktree rm --worktree "id:$ORCA_WORKTREE_ID" --force --json >/dev/null
      else
        orca worktree rm --worktree "path:$WT" --force --json >/dev/null
      fi
      ;;
    codex-app)
      case "$WT" in
        "$FM_ROOT/state/codex-app-worktrees/"*) git -C "$PROJ" worktree remove --force "$WT" >/dev/null ;;
        *) : ;; # App-owned worktrees are managed by Codex App, not this shell helper.
      esac
      ;;
    opencode-server)
      if [ -n "$OPENCODE_SERVER_URL" ] && [ -n "$OPENCODE_SESSION_ID" ]; then
        "$FM_ROOT/bin/fm-opencode-server" close "$OPENCODE_SERVER_URL" "$OPENCODE_SESSION_ID" "$OPENCODE_SERVER_PID" >/dev/null 2>&1 || true
        OPENCODE_CLOSED=1
      fi
      case "$WT" in
        "$FM_ROOT/state/opencode-server-worktrees/"*) git -C "$PROJ" worktree remove --force "$WT" >/dev/null ;;
        *) echo "REFUSED: OpenCode server worktree is not firstmate-owned: $WT" >&2; exit 1 ;;
      esac
      ;;
    *) echo "REFUSED: unknown backend '$BACKEND' for task $ID." >&2; exit 1 ;;
  esac
fi

if [ "$BACKEND" = tmux ]; then
  tmux kill-window -t "$T" 2>/dev/null || true
fi
if [ "$BACKEND" = opencode-server ] && [ "$OPENCODE_CLOSED" != 1 ] && [ ! -d "$WT" ] && [ -n "$OPENCODE_SERVER_URL" ] && [ -n "$OPENCODE_SESSION_ID" ]; then
  "$FM_ROOT/bin/fm-opencode-server" close "$OPENCODE_SERVER_URL" "$OPENCODE_SESSION_ID" "$OPENCODE_SERVER_PID" >/dev/null 2>&1 || true
fi
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.check.sh" "$STATE/$ID.meta" "$STATE/$ID.pi-ext.ts" \
  "$STATE/$ID.codex-app.env" "$STATE/$ID.codex-app.log" "$STATE/$ID.codex-app.capture" "$STATE/$ID.codex-app-send."* \
  "$STATE/$ID.opencode-server.log" "$STATE/$ID.opencode-server.capture"
if [ "$KIND" != scout ] && [ "$MODE" != local-only ]; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
echo "teardown $ID complete (backend $BACKEND, window $T, worktree $WT)"
