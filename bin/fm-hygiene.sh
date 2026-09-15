#!/usr/bin/env bash
# bin/fm-hygiene.sh — Firstmate workspace hygiene, doctor, and conservative repair.
#
# Default is report-only. Repair and prune never delete Treehouse slots, Hermes
# pools, agent worktrees, git worktrees, task inboxes, or unlanded project
# files. The only mutations repair/prune may perform:
#   - release state/.lock when the recorded PID is dead or not a harness
#   - delete state/.watch-arm-output.* temp files
#   - delete a .lease-* whose task has neither a live meta record nor a backlog
#     in-flight/queued row
#   - `git worktree prune` (unregister already-missing worktree paths only)
#
# Usage:
#   fm-hygiene.sh               # report status (default --check)
#   fm-hygiene.sh --prune       # conservative state cleanup; never deletes worktrees
#   fm-hygiene.sh --repair      # dead-PID lock GC plus the same conservative cleanup
#   fm-hygiene.sh --doctor      # live diagnostics (Herdr, watcher, proxies, divergence)
#   fm-hygiene.sh --project <p> # inspect one registered project
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS_DIR="${PROJECTS_DIR:-$FM_HOME/projects}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

MODE="check"
TARGET_PROJECT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --prune|--clean|-p)
      MODE="prune"
      shift ;;
    --repair|-r)
      MODE="repair"
      shift ;;
    --check|--dry-run|-c)
      MODE="check"
      shift ;;
    --doctor|-d)
      MODE="doctor"
      shift ;;
    --project)
      TARGET_PROJECT="${2:-}"
      [ -n "$TARGET_PROJECT" ] || { echo "error: --project requires a name" >&2; exit 2; }
      shift 2 ;;
    -h|--help)
      echo "usage: fm-hygiene.sh [--check | --prune | --repair | --doctor] [--project <name>]"
      echo "  --check   Report worktrees, unmerged branches, and stale state (default)"
      echo "  --prune   Conservative state cleanup; never deletes worktrees or Treehouse slots"
      echo "  --repair  Dead-PID lock GC plus the same conservative cleanup"
      echo "  --doctor  Live diagnostics (Herdr, watcher, drain, proxies, origin divergence)"
      echo "  --project Target a single registered project name"
      exit 0 ;;
    *)
      echo "fm-hygiene: unknown argument '$1'" >&2
      exit 1 ;;
  esac
done

echo "==================================================================="
echo " Firstmate workspace hygiene ($MODE mode)"
echo " Home: $FM_HOME"
echo "==================================================================="

TOTAL_WORKTREES=0
TOTAL_UNMERGED_BRANCHES=0
TOTAL_EXTERNAL_POOLS=0
TOTAL_STALE_STATE_FILES=0
DEAD_LOCKS_REMOVED=0
MUTATIONS=0

mutating() {
  [ "$MODE" = "prune" ] || [ "$MODE" = "repair" ]
}

task_still_live() {  # <task-id>
  local task=$1
  [ -n "$task" ] || return 1
  [ -f "$STATE_DIR/$task.meta" ] && return 0
  if [ -f "$DATA_DIR/backlog.md" ]; then
    grep -qE -- "^- \\[ \\] ${task}( |$)" "$DATA_DIR/backlog.md" 2>/dev/null && return 0
  fi
  return 1
}

check_git_repo() {
  local repo_path="$1"
  local repo_name="$2"

  [ -d "$repo_path/.git" ] || [ -f "$repo_path/.git" ] || return 0

  local wt_count=0
  local unmerged_count=0
  local default_branch
  default_branch=$(git -C "$repo_path" symbolic-ref --short HEAD 2>/dev/null || echo "main")

  local wt_list
  wt_list=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null || true)
  if [ -n "$wt_list" ]; then
    wt_count=$(printf '%s\n' "$wt_list" | grep -c "^worktree " || true)
  fi

  local branches
  branches=$(git -C "$repo_path" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null || true)
  local unmerged_list=""
  local b diff_count
  for b in $branches; do
    case "$b" in
      main|master|"$default_branch") continue ;;
    esac
    diff_count=$(git -C "$repo_path" rev-list --count "$default_branch..$b" 2>/dev/null || echo "0")
    if [ "${diff_count:-0}" -gt 0 ] 2>/dev/null; then
      unmerged_count=$((unmerged_count + 1))
      unmerged_list="$unmerged_list $b($diff_count)"
    fi
  done

  TOTAL_WORKTREES=$((TOTAL_WORKTREES + wt_count))
  TOTAL_UNMERGED_BRANCHES=$((TOTAL_UNMERGED_BRANCHES + unmerged_count))

  if [ "$wt_count" -gt 1 ] || [ "$unmerged_count" -gt 0 ]; then
    printf "[-] %-28s | Worktrees: %-2d | Unmerged branches: %-2d\n" "$repo_name" "$wt_count" "$unmerged_count"
    if [ -n "$unmerged_list" ]; then
      printf "    Unmerged: %s\n" "$unmerged_list"
    fi
    if [ "$wt_count" -gt 1 ]; then
      git -C "$repo_path" worktree list 2>/dev/null | sed 's/^/    WT: /'
    fi
  else
    printf "[+] %-28s | Clean (1 main worktree, 0 unmerged branches)\n" "$repo_name"
  fi

  if mutating; then
    # git worktree prune only drops records whose directories are already gone.
    git -C "$repo_path" worktree prune 2>/dev/null || true
  fi
}

echo ""
echo "--- 1. Firstmate home and registered projects ---"

declare -a PROJ_PATHS=()

if [ -n "$TARGET_PROJECT" ]; then
  if [ -e "$PROJECTS_DIR/$TARGET_PROJECT" ]; then
    PROJ_PATHS+=("$PROJECTS_DIR/$TARGET_PROJECT")
  else
    echo "error: registered project '$TARGET_PROJECT' not found under $PROJECTS_DIR" >&2
    echo "hygiene scans firstmate/projects only; it does not adopt ~/Desktop/projects." >&2
    exit 1
  fi
else
  check_git_repo "$FM_HOME" "firstmate-home"
  if [ -d "$PROJECTS_DIR" ]; then
    for p in "$PROJECTS_DIR"/*; do
      [ -e "$p" ] || continue
      PROJ_PATHS+=("$p")
    done
  fi
  # Opt-in extra roots only. Default must not scan the Desktop/projects zoo.
  if [ -n "${FM_HYGIENE_SCAN_ROOTS:-}" ]; then
    IFS=':' read -r -a extra_roots <<< "$FM_HYGIENE_SCAN_ROOTS"
    for parent_dir in "${extra_roots[@]}"; do
      [ -d "$parent_dir" ] || continue
      for p in "$parent_dir"/*; do
        [ -d "$p/.git" ] || [ -f "$p/.git" ] || continue
        PROJ_PATHS+=("$p")
      done
    done
  fi
fi

for proj in "${PROJ_PATHS[@]+"${PROJ_PATHS[@]}"}"; do
  pname="$(basename "$proj")"
  check_git_repo "$proj" "$pname"
done

echo ""
echo "--- 2. External pools (advisory only; never deleted) ---"

report_pool_dir() {  # <label> <path>
  local label=$1 path=$2
  [ -d "$path" ] || return 0
  TOTAL_EXTERNAL_POOLS=$((TOTAL_EXTERNAL_POOLS + 1))
  printf "[!] %s (preserved): %s\n" "$label" "$path"
}

HERMES_WTS="${HOME}/.hermes/company-os-manager/worktrees"
if [ -d "$HERMES_WTS" ]; then
  for wt in "$HERMES_WTS"/*; do
    [ -d "$wt" ] || continue
    report_pool_dir "Hermes CompanyOS worktree" "$wt"
  done
fi

for parent_dir in "${HOME}/Desktop/projects" "${HOME}/projects"; do
  AGENT_WTS="$parent_dir/.agent-worktrees"
  [ -d "$AGENT_WTS" ] || continue
  for dir in "$AGENT_WTS"/*/*; do
    [ -d "$dir" ] || continue
    report_pool_dir "Desktop agent worktree" "$dir"
  done
done

TREEHOUSE_DIR="${HOME}/.treehouse"
if [ -d "$TREEHOUSE_DIR" ]; then
  for pool in "$TREEHOUSE_DIR"/*; do
    [ -d "$pool" ] || continue
    pname="$(basename "$pool")"
    case "$pname" in
      firstmate-*|tic-tac-toe-*|habit-tracker-*|repo-*|project-*)
        for slot in "$pool"/[0-9]*; do
          [ -d "$slot" ] || continue
          report_pool_dir "Treehouse slot" "$slot"
        done
        ;;
    esac
  done
fi

if [ "$TOTAL_EXTERNAL_POOLS" -eq 0 ]; then
  echo "[+] No external Treehouse/Hermes/agent pool slots found under \$HOME."
else
  echo "    These paths are never removed by hygiene. Use treehouse return or firstmate teardown."
fi

echo ""
echo "--- 3. State directory ($STATE_DIR) ---"

if [ -d "$STATE_DIR" ]; then
  if [ -f "$STATE_DIR/.lock" ]; then
    lock_pid=$(cat "$STATE_DIR/.lock" 2>/dev/null || true)
    if [ -n "$lock_pid" ]; then
      if ! kill -0 "$lock_pid" 2>/dev/null || ! fm_harness_pid_alive "$lock_pid"; then
        TOTAL_STALE_STATE_FILES=$((TOTAL_STALE_STATE_FILES + 1))
        printf "[!] Dead/stale session lock detected (PID: %s)\n" "$lock_pid"
        if mutating; then
          if fm_session_lock_gc "$STATE_DIR"; then
            DEAD_LOCKS_REMOVED=1
            MUTATIONS=$((MUTATIONS + 1))
            echo "    Repaired: removed dead session lock."
          fi
        fi
      else
        printf "[+] Session lock held by live harness PID %s\n" "$lock_pid"
      fi
    fi
  else
    echo "[+] No session lock file."
  fi

  shopt -s nullglob
  for lease in "$STATE_DIR"/.lease-*; do
    [ -f "$lease" ] || continue
    task_id="$(basename "$lease")"
    task_id="${task_id#.lease-}"
    if task_still_live "$task_id"; then
      continue
    fi
    TOTAL_STALE_STATE_FILES=$((TOTAL_STALE_STATE_FILES + 1))
    printf "[!] Stale task lease: %s\n" "$lease"
    if mutating; then
      rm -f -- "$lease"
      MUTATIONS=$((MUTATIONS + 1))
      echo "    Removed stale lease (no meta, not in backlog)."
    fi
  done

  for tmp_out in "$STATE_DIR"/.watch-arm-output.*; do
    [ -f "$tmp_out" ] || continue
    TOTAL_STALE_STATE_FILES=$((TOTAL_STALE_STATE_FILES + 1))
    printf "[!] Temporary watcher output: %s\n" "$tmp_out"
    if mutating; then
      rm -f -- "$tmp_out"
      MUTATIONS=$((MUTATIONS + 1))
    fi
  done

  for inbox in "$STATE_DIR"/*.inbox; do
    [ -d "$inbox" ] || continue
    task_id="$(basename "$inbox" .inbox)"
    if task_still_live "$task_id"; then
      continue
    fi
    TOTAL_STALE_STATE_FILES=$((TOTAL_STALE_STATE_FILES + 1))
    printf "[!] Stale task inbox (preserved): %s\n" "$inbox"
  done

  for busy in "$STATE_DIR"/*.busy-*; do
    [ -f "$busy" ] || continue
    task_id="$(basename "$busy")"
    task_id="${task_id%%.*}"
    if task_still_live "$task_id"; then
      continue
    fi
    TOTAL_STALE_STATE_FILES=$((TOTAL_STALE_STATE_FILES + 1))
    printf "[!] Stale busy marker (preserved): %s\n" "$busy"
  done
  shopt -u nullglob
fi

if [ "$TOTAL_STALE_STATE_FILES" -eq 0 ]; then
  echo "[+] State directory is clean."
fi

if [ "$MODE" = "doctor" ]; then
  echo ""
  echo "--- 4. System & subsystem doctor ---"

  if command -v herdr >/dev/null 2>&1; then
    if herdr workspace list >/dev/null 2>&1; then
      echo "[+] Herdr multiplexer: connected"
    else
      echo "[-] Herdr multiplexer: daemon unreachable"
    fi
  else
    echo "[-] Herdr multiplexer: 'herdr' not found on PATH"
  fi

  if [ -f "$STATE_DIR/.watcher-down" ]; then
    echo "[-] Watcher: down ($(tr '\n' ' ' < "$STATE_DIR/.watcher-down"))"
  elif [ -f "$STATE_DIR/.last-watcher-beat" ]; then
    echo "[+] Watcher: last beat recorded at $(date -r "$STATE_DIR/.last-watcher-beat" 2>/dev/null || echo unknown)"
  else
    echo "[-] Watcher: no beat file and no downtime marker"
  fi

  if command -v pgrep >/dev/null 2>&1 && pgrep -f 'fm-watch([.]sh)?([[:space:]]|$)' >/dev/null 2>&1; then
    echo "[+] Watcher process: live"
  else
    echo "[-] Watcher process: not running"
  fi

  if command -v pgrep >/dev/null 2>&1 && pgrep -f 'fm-wake-drain[.]sh' >/dev/null 2>&1; then
    echo "[!] Wake drain: process still running (inspect; orphan drains must be killed, not left looping)"
  else
    echo "[+] Wake drain: no live fm-wake-drain.sh"
  fi

  if command -v no-mistakes >/dev/null 2>&1; then
    if no-mistakes daemon status >/dev/null 2>&1; then
      echo "[+] No-Mistakes daemon: connected"
    else
      echo "[-] No-Mistakes daemon: inactive"
    fi
  else
    echo "[-] No-Mistakes daemon: 'no-mistakes' not found on PATH"
  fi

  if command -v curl >/dev/null 2>&1 && curl -s -m 2 http://127.0.0.1:8320/v1/models >/dev/null 2>&1; then
    echo "[+] Local broker (127.0.0.1:8320): connected"
  else
    echo "[-] Local broker (127.0.0.1:8320): unreachable"
  fi

  if command -v curl >/dev/null 2>&1 && curl -s -m 2 http://127.0.0.1:8317/v1/models >/dev/null 2>&1; then
    echo "[+] CLIProxyAPI (127.0.0.1:8317): connected"
  else
    echo "[-] CLIProxyAPI (127.0.0.1:8317): unreachable"
  fi

  if git -C "$FM_ROOT" rev-parse --abbrev-ref HEAD >/dev/null 2>&1; then
    local_branch=$(git -C "$FM_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
    if git -C "$FM_ROOT" rev-parse --verify origin/main >/dev/null 2>&1; then
      ahead=$(git -C "$FM_ROOT" rev-list --count origin/main..HEAD 2>/dev/null || echo "?")
      behind=$(git -C "$FM_ROOT" rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
      echo "[!] Firstmate git: branch $local_branch, ahead $ahead / behind $behind vs origin/main"
    else
      echo "[!] Firstmate git: branch $local_branch (origin/main not available)"
    fi
    dirty=$(git -C "$FM_ROOT" status --porcelain 2>/dev/null || true)
    if [ -n "$dirty" ]; then
      echo "[!] Firstmate git: working tree is dirty; repair/prune will not reset it"
    fi
  fi
fi

echo ""
echo "==================================================================="
echo " Hygiene scan summary:"
echo " Total worktrees:             $TOTAL_WORKTREES"
echo " Unmerged feature branches:   $TOTAL_UNMERGED_BRANCHES"
echo " External pool slots:         $TOTAL_EXTERNAL_POOLS (never deleted)"
echo " Stale runtime state files:   $TOTAL_STALE_STATE_FILES"
echo " Conservative mutations:      $MUTATIONS"
if [ "$DEAD_LOCKS_REMOVED" -eq 1 ]; then
  echo " Repaired dead locks:         1"
fi
if [ "$MODE" = "check" ] && { [ "$TOTAL_STALE_STATE_FILES" -gt 0 ] || [ "$TOTAL_EXTERNAL_POOLS" -gt 0 ]; }; then
  echo ""
  echo " Run 'firstmate repair' for dead locks and leftover temp/lease files."
  echo " External pools and inboxes are never removed by this command."
fi
echo "==================================================================="
