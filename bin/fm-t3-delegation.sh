#!/usr/bin/env bash
# fm-t3-delegation.sh - shell helpers for the T3 main-thread Firstmate lead workflow.
#
# These commands prepare and consume durable delegation records.
# They validate JSON the lead passes in from T3 MCP tools and update Firstmate task state.
# They never call T3 MCP tools themselves.
#
# Usage:
#   fm-t3-delegation.sh enabled
#   fm-t3-delegation.sh record-intent --client-request-id <id> --task-id <id> \
#       --parent-thread-id <uuid> --kind <ship|scout|steer|review|research> \
#       [--mode <no-mistakes|direct-PR|local-only>] [--yolo on|off] \
#       [--project <path>] [--base-branch <branch>] [--branch-prefix fm/] \
#       [--ship-branch <branch>] [--source-worktree <path>] [--isolation-required on|off]
#   fm-t3-delegation.sh bind-dispatch --client-request-id <id> --parent-thread-id <uuid> --json <file>
#   fm-t3-delegation.sh import-status --client-request-id <id> --parent-thread-id <uuid> --json <file> [--notify]
#   fm-t3-delegation.sh cancel-bind --client-request-id <id> --parent-thread-id <uuid> [--json <file>]
#   fm-t3-delegation.sh list --parent-thread-id <uuid> [--outstanding]
#   fm-t3-delegation.sh recover --parent-thread-id <uuid>
#   fm-t3-delegation.sh assert-isolated --project <path> --worktree <path>
#   fm-t3-delegation.sh record-isolated-worktree --client-request-id <id> --worktree <path> \
#       --project <path>
#   fm-t3-delegation.sh show --client-request-id <id>
#   fm-t3-delegation.sh worktree-brief --task-id <id> --project <path> --branch <branch> \
#       [--base-branch <branch>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
# shellcheck source=bin/fm-t3-delegation-lib.sh
. "$SCRIPT_DIR/fm-t3-delegation-lib.sh"

usage() {
  sed -n '2,/${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

require_enabled() {
  fm_t3_delegation_enabled || {
    printf 'fm-t3-delegation: T3 main-thread lead mode is not enabled for this home\n' >&2
    printf 'Create config/t3-main-thread-lead or set FM_T3_MAIN_THREAD_LEAD=on\n' >&2
    exit 1
  }
}

CMD=${1:-}
shift || true

case "$CMD" in
  -h | --help | '')
    usage
    exit 0
    ;;
  enabled)
    if fm_t3_delegation_enabled; then
      printf 'on\n'
      exit 0
    fi
    printf 'off\n'
    exit 1
    ;;
  record-intent)
    require_enabled
    CLIENT_REQUEST_ID='' TASK_ID='' PARENT_THREAD_ID='' KIND='' MODE='' YOLO=off PROJECT=''
    BASE_BRANCH='' BRANCH_PREFIX=fm/ SHIP_BRANCH='' SOURCE_WORKTREE='' ISOLATION=on
    while [ $# -gt 0 ]; do
      case "$1" in
        --client-request-id) CLIENT_REQUEST_ID=$2; shift 2 ;;
        --task-id) TASK_ID=$2; shift 2 ;;
        --parent-thread-id) PARENT_THREAD_ID=$2; shift 2 ;;
        --kind) KIND=$2; shift 2 ;;
        --mode) MODE=$2; shift 2 ;;
        --yolo) YOLO=$2; shift 2 ;;
        --project) PROJECT=$2; shift 2 ;;
        --base-branch) BASE_BRANCH=$2; shift 2 ;;
        --branch-prefix) BRANCH_PREFIX=$2; shift 2 ;;
        --ship-branch) SHIP_BRANCH=$2; shift 2 ;;
        --source-worktree) SOURCE_WORKTREE=$2; shift 2 ;;
        --isolation-required) ISOLATION=$2; shift 2 ;;
        *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
      esac
    done
    [ -n "$CLIENT_REQUEST_ID" ] && [ -n "$TASK_ID" ] && [ -n "$PARENT_THREAD_ID" ] && [ -n "$KIND" ] || {
      printf 'record-intent requires --client-request-id, --task-id, --parent-thread-id, --kind\n' >&2
      exit 2
    }
    iso_json=true
    [ "$ISOLATION" = off ] && iso_json=false
    fm_t3_delegation_record_intent "$CLIENT_REQUEST_ID" "$TASK_ID" "$PARENT_THREAD_ID" "$KIND" \
      "$MODE" "$YOLO" "$PROJECT" "$BASE_BRANCH" "$BRANCH_PREFIX" "$SOURCE_WORKTREE" \
      "$iso_json" "$SHIP_BRANCH"
    ;;
  bind-dispatch)
    require_enabled
    CLIENT_REQUEST_ID='' PARENT_THREAD_ID='' JSON=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --client-request-id) CLIENT_REQUEST_ID=$2; shift 2 ;;
        --parent-thread-id) PARENT_THREAD_ID=$2; shift 2 ;;
        --json) JSON=$2; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$CLIENT_REQUEST_ID" ] && [ -n "$PARENT_THREAD_ID" ] && [ -f "$JSON" ] || exit 2
    fm_t3_delegation_bind_dispatch "$CLIENT_REQUEST_ID" "$PARENT_THREAD_ID" "$JSON"
    ;;
  import-status)
    require_enabled
    CLIENT_REQUEST_ID='' PARENT_THREAD_ID='' JSON='' NOTIFY=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --client-request-id) CLIENT_REQUEST_ID=$2; shift 2 ;;
        --parent-thread-id) PARENT_THREAD_ID=$2; shift 2 ;;
        --json) JSON=$2; shift 2 ;;
        --notify) NOTIFY=1; shift ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$CLIENT_REQUEST_ID" ] && [ -n "$PARENT_THREAD_ID" ] && [ -f "$JSON" ] || exit 2
    out=$(fm_t3_delegation_import_status "$CLIENT_REQUEST_ID" "$PARENT_THREAD_ID" "$JSON") || exit 1
    printf '%s\n' "$out"
    if [ "$NOTIFY" -eq 1 ]; then
      task=$(printf '%s' "$out" | jq -r '.taskId')
      fm_t3_delegation_publish_supervision "$task" "$out" || exit 1
    fi
    ;;
  cancel-bind)
    require_enabled
    CLIENT_REQUEST_ID='' PARENT_THREAD_ID='' JSON=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --client-request-id) CLIENT_REQUEST_ID=$2; shift 2 ;;
        --parent-thread-id) PARENT_THREAD_ID=$2; shift 2 ;;
        --json) JSON=$2; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$CLIENT_REQUEST_ID" ] && [ -n "$PARENT_THREAD_ID" ] || exit 2
    path=$(fm_t3_delegation_record_path "$CLIENT_REQUEST_ID")
    [ -f "$path" ] || exit 1
    rec_parent=$(jq -r '.parentThreadId // empty' "$path")
    [ "$rec_parent" = "$PARENT_THREAD_ID" ] || exit 1
    if [ -n "$JSON" ] && [ -f "$JSON" ]; then
      fm_t3_delegation_import_status "$CLIENT_REQUEST_ID" "$PARENT_THREAD_ID" "$JSON" >/dev/null || true
    fi
    now=$(fm_t3_delegation_now)
    o=$(jq --argjson now "$now" '.phase = "cancelled" | .outcomeKind = "failure" | .updatedAt = $now' "$path")
    fm_t3_delegation_atomic_write "$path" "$o"
    printf '%s\n' "$o"
    ;;
  list)
    require_enabled
    PARENT_THREAD_ID='' OUTSTANDING=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --parent-thread-id) PARENT_THREAD_ID=$2; shift 2 ;;
        --outstanding) OUTSTANDING=1; shift ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$PARENT_THREAD_ID" ] || exit 2
    fm_t3_delegation_home_state
    [ -d "$FM_T3_RECORD_DIR" ] || exit 0
    for f in "$FM_T3_RECORD_DIR"/*.json; do
      [ -f "$f" ] || continue
      if [ "$OUTSTANDING" -eq 1 ]; then
        jq -r --arg p "$PARENT_THREAD_ID" \
          'select(.parentThreadId == $p) | select(.phase != "completed" and .phase != "failed" and .phase != "cancelled" and .phase != "interrupted") | @json' "$f"
      else
        jq -r --arg p "$PARENT_THREAD_ID" 'select(.parentThreadId == $p) | @json' "$f"
      fi
    done
    ;;
  recover)
    require_enabled
    PARENT_THREAD_ID=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --parent-thread-id) PARENT_THREAD_ID=$2; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$PARENT_THREAD_ID" ] || exit 2
    printf 'Recover outstanding T3 delegations for parentThreadId=%s\n' "$PARENT_THREAD_ID"
    printf 'For each line below, call task_status on t3TaskId and import-status with the result.\n'
    fm_t3_delegation_list_outstanding "$PARENT_THREAD_ID"
    ;;
  assert-isolated)
    PROJECT='' WORKTREE=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --project) PROJECT=$2; shift 2 ;;
        --worktree) WORKTREE=$2; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$PROJECT" ] && [ -n "$WORKTREE" ] || exit 2
    if fm_t3_worktree_isolated "$PROJECT" "$WORKTREE"; then
      printf 'isolated\n'
      exit 0
    fi
    printf 'refused: %s\n' "${FM_T3_WT_REASON:-unknown}" >&2
    exit 1
    ;;
  record-isolated-worktree)
    require_enabled
    CLIENT_REQUEST_ID='' WORKTREE='' PROJECT=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --client-request-id) CLIENT_REQUEST_ID=$2; shift 2 ;;
        --worktree) WORKTREE=$2; shift 2 ;;
        --project) PROJECT=$2; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$CLIENT_REQUEST_ID" ] && [ -n "$WORKTREE" ] && [ -n "$PROJECT" ] || exit 2
    path=$(fm_t3_delegation_record_path "$CLIENT_REQUEST_ID")
    [ -f "$path" ] || exit 1
    iso_req=$(jq -r '.isolationRequired // false' "$path")
    if [ "$iso_req" = true ]; then
      fm_t3_worktree_isolated "$PROJECT" "$WORKTREE" || exit 1
    fi
    fm_t3_delegation_set_isolated_worktree "$CLIENT_REQUEST_ID" "$WORKTREE"
    ;;
  show)
    CLIENT_REQUEST_ID=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --client-request-id) CLIENT_REQUEST_ID=$2; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$CLIENT_REQUEST_ID" ] || exit 2
    fm_t3_delegation_read "$CLIENT_REQUEST_ID" || exit 1
    ;;
  worktree-brief)
    TASK_ID='' PROJECT='' BRANCH='' BASE_BRANCH=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --task-id) TASK_ID=$2; shift 2 ;;
        --project) PROJECT=$2; shift 2 ;;
        --branch) BRANCH=$2; shift 2 ;;
        --base-branch) BASE_BRANCH=$2; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$TASK_ID" ] && [ -n "$PROJECT" ] && [ -n "$BRANCH" ] || exit 2
    cat <<EOF
Before editing tracked project files for task ${TASK_ID}, acquire an isolated git worktree:
- Call t3_thread_launch with workspaceStrategy type worktree (or existing_worktree once created).
- baseRef: ${BASE_BRANCH:-main default branch}
- branch: ${BRANCH}
After the worktree exists, run:
  bin/fm-t3-delegation.sh record-isolated-worktree --client-request-id <id> --project ${PROJECT} --worktree <absolute-path>
  bin/fm-t3-delegation.sh assert-isolated --project ${PROJECT} --worktree <absolute-path>
Research-only scouts may stay on the shared copy when isolationRequired is off.
EOF
    ;;
  *)
    printf 'unknown command: %s\n' "$CMD" >&2
    usage >&2
    exit 2
    ;;
esac
