#!/usr/bin/env bash
# Run one supported ordinary harness as the exact child of an observation-only
# wait wrapper, then atomically publish the kernel-derived shell wait status.
#
# Usage:
#   fm-harness-run.sh --task <id> --spawn-gen <gen> --harness <name>
#     --backend <name> -- <harness-command> [args...]
#
# fm-spawn.sh places this wrapper immediately around the real harness executable
# for ordinary ship/scout workers on every backend. The child keeps the pane's
# stdin, stdout, stderr, process group, and terminal. The wrapper never interprets
# exit as task completion and never calls control, merge, teardown, or cleanup.
# Receipt publication failure is a warning only and never changes the child's
# exit status, preserving the pre-observation launch behavior.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-completion-lib.sh
. "$SCRIPT_DIR/fm-completion-lib.sh"

usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

ID=
SPAWN_GEN=
HARNESS=
BACKEND=
while [ $# -gt 0 ]; do
  case "$1" in
    --task) ID=${2-}; shift 2 || usage ;;
    --spawn-gen) SPAWN_GEN=${2-}; shift 2 || usage ;;
    --harness) HARNESS=${2-}; shift 2 || usage ;;
    --backend) BACKEND=${2-}; shift 2 || usage ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ $# -gt 0 ] || usage
fm_pr_task_id_valid "$ID" || usage
fm_completion_token_valid "$SPAWN_GEN" || usage
case "$HARNESS" in claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse) : ;; *) usage ;; esac
case "$BACKEND" in tmux|herdr|zellij|orca|cmux) : ;; *) usage ;; esac

META="$STATE/$ID.meta"
START_RECORD="$STATE/.$ID.process-start.${BASHPID:-$$}"
rm -f "$START_RECORD" 2>/dev/null || true
(
  SUB_OLD_UMASK=$(umask)
  umask 077
  CHILD_SELF=${BASHPID:-$$}
  CHILD_IDENTITY=$(fm_completion_process_identity "$CHILD_SELF" 2>/dev/null || true)
  printf 'pid=%s\nidentity=%s\n' "$CHILD_SELF" "$CHILD_IDENTITY" > "$START_RECORD"
  umask "$SUB_OLD_UMASK"
  exec "$@"
) <&0 &
CHILD_PID=$!

i=0
while [ ! -f "$START_RECORD" ] && [ "$i" -lt 100 ]; do
  kill -0 "$CHILD_PID" 2>/dev/null || break
  sleep 0.01
  i=$((i + 1))
done
PROCESS_IDENTITY=$(sed -n 's/^identity=//p' "$START_RECORD" 2>/dev/null | head -n 1 || true)

set +e
wait "$CHILD_PID"
WAIT_STATUS=$?
set -e
EXIT_EPOCH=$(date +%s)
rm -f "$START_RECORD" 2>/dev/null || true

publish_exit_receipt() {
  local lock current dest tmp old_umask
  [ -n "$PROCESS_IDENTITY" ] || return 1
  [ -f "$META" ] || return 1
  [ "$(fm_backend_meta_exact_value "$META" kind 2>/dev/null)" != secondmate ] || return 1
  lock=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$lock"
  current=$(fm_backend_meta_exact_value "$META" spawn_gen 2>/dev/null) || {
    fm_lock_release "$lock"
    return 1
  }
  if [ "$current" != "$SPAWN_GEN" ]; then
    fm_lock_release "$lock"
    return 1
  fi
  dest="$STATE/$ID.process-exit-receipt"
  tmp="$STATE/.$ID.process-exit-receipt.${BASHPID:-$$}"
  old_umask=$(umask)
  umask 077
  {
    printf 'schema=%s\n' "$FM_PROCESS_EXIT_SCHEMA"
    printf 'task_id=%s\n' "$ID"
    printf 'spawn_gen=%s\n' "$SPAWN_GEN"
    printf 'harness=%s\n' "$HARNESS"
    printf 'backend=%s\n' "$BACKEND"
    printf 'process_pid=%s\n' "$CHILD_PID"
    printf 'process_identity=%s\n' "$PROCESS_IDENTITY"
    printf 'exit_epoch=%s\n' "$EXIT_EPOCH"
    printf 'wait_status=%s\n' "$WAIT_STATUS"
  } > "$tmp" || {
    umask "$old_umask"
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  }
  umask "$old_umask"
  fm_process_exit_receipt_load "$tmp" "$ID" "$SPAWN_GEN" || {
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  }
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if ! fm_process_exit_receipt_load "$dest"; then
      rm -f "$tmp"
      fm_lock_release "$lock"
      return 1
    fi
    if [ "$FM_PROCESS_EXIT_SPAWN_GEN" = "$SPAWN_GEN" ]; then
      if ! cmp -s "$dest" "$tmp"; then
        rm -f "$tmp"
        fm_lock_release "$lock"
        return 1
      fi
      rm -f "$tmp"
      fm_lock_release "$lock"
      return 0
    fi
  fi
  mv -f "$tmp" "$dest" || {
    rm -f "$tmp"
    fm_lock_release "$lock"
    return 1
  }
  fm_lock_release "$lock"
}

if ! publish_exit_receipt; then
  printf 'warning: process-exit receipt was not published for %s spawn %s\n' "$ID" "$SPAWN_GEN" >&2
else
  FM_SHADOW_TRIGGER=process-exit "$SCRIPT_DIR/fm-completion-shadow.sh" record "$ID" >/dev/null 2>&1 || true
fi
exit "$WAIT_STATUS"
