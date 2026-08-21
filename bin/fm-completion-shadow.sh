#!/usr/bin/env bash
# Record and read observation-only comparisons between current crew state and
# completion/process-exit receipts.
#
# Usage:
#   fm-completion-shadow.sh record <task-id>
#   fm-completion-shadow.sh read [<task-id>] [--disagreements]
#
# `read` is the documented inspection path. Each ledger row names the harness,
# backend, trigger, independently validated completion and process observations,
# shadow verdict, current fm-crew-state verdict, and match/different result.
# Recording and reading are inert: this script never invokes lifecycle control,
# forge mutation, merge, teardown, or cleanup.
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

CMD=${1:-}
case "$CMD" in record|read) shift ;; *) usage ;; esac

if [ "$CMD" = read ]; then
  ID=
  DISAGREEMENTS=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --disagreements) DISAGREEMENTS=1 ;;
      -h|--help) usage ;;
      *) [ -z "$ID" ] || usage; ID=$1 ;;
    esac
    shift
  done
  if [ -n "$ID" ]; then
    fm_pr_task_id_valid "$ID" || usage
    FILES=("$STATE/$ID.completion-shadow")
  else
    FILES=("$STATE"/*.completion-shadow)
  fi
  for file in "${FILES[@]}"; do
    [ -f "$file" ] || continue
    if [ "$DISAGREEMENTS" -eq 1 ]; then
      grep ' comparison=different$' "$file" 2>/dev/null || true
    else
      cat "$file"
    fi
  done
  exit 0
fi

ID=${1:-}
[ $# -eq 1 ] || usage
fm_pr_task_id_valid "$ID" || usage
META="$STATE/$ID.meta"
[ -f "$META" ] || exit 1
KIND=$(fm_meta_get "$META" kind)
[ "$KIND" != secondmate ] || exit 0
SPAWN_GEN=$(fm_backend_meta_exact_value "$META" spawn_gen) || exit 1
HARNESS=$(fm_meta_get "$META" harness)
BACKEND=$(fm_backend_of_meta "$META")
case "$HARNESS" in claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|muse) : ;; *) HARNESS=unknown ;; esac
case "$BACKEND" in tmux|herdr|zellij|orca|cmux) : ;; *) BACKEND=unknown ;; esac

COMPLETION=absent
COMPLETION_OUTCOME=
if [ -e "$STATE/$ID.completion-receipt" ] || [ -L "$STATE/$ID.completion-receipt" ]; then
  if fm_completion_receipt_load "$STATE/$ID.completion-receipt" "$ID" "$SPAWN_GEN"; then
    COMPLETION=$FM_COMPLETION_OUTCOME
    COMPLETION_OUTCOME=$FM_COMPLETION_OUTCOME
  else
    COMPLETION=invalid-or-stale
  fi
fi
PROCESS=absent
if [ -e "$STATE/$ID.process-exit-receipt" ] || [ -L "$STATE/$ID.process-exit-receipt" ]; then
  if fm_process_exit_receipt_load "$STATE/$ID.process-exit-receipt" "$ID" "$SPAWN_GEN"; then
    if [ "$FM_PROCESS_EXIT_WAIT_STATUS" -eq 0 ]; then PROCESS=exited-zero; else PROCESS=exited-nonzero; fi
  else
    PROCESS=invalid-or-stale
  fi
fi

if [ "$PROCESS" = exited-zero ] || [ "$PROCESS" = exited-nonzero ]; then
  if [ "$COMPLETION" = "done" ] || [ "$COMPLETION" = "failed" ]; then
    SHADOW=worker-stopped
  else
    SHADOW=abnormal-exit
  fi
elif [ "$COMPLETION" = "done" ] || [ "$COMPLETION" = "failed" ]; then
  SHADOW=ready
else
  SHADOW=running
fi

CREW_STATE_BIN=${FM_SHADOW_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}
CURRENT_OUT=$(FM_CREW_STATE_NM_TIMEOUT=${FM_SHADOW_NM_TIMEOUT:-1} "$CREW_STATE_BIN" "$ID" 2>/dev/null || true)
CURRENT=$(printf '%s\n' "$CURRENT_OUT" | sed -n 's/^state: \([^ ·][^ ·]*\).*/\1/p' | head -n 1)
case "$CURRENT" in working|parked|done|blocked|paused|failed|unknown) : ;; *) CURRENT=unavailable ;; esac
COMPARISON=no-comparison
if [ -n "$COMPLETION_OUTCOME" ]; then
  if [ "$CURRENT" = "$COMPLETION_OUTCOME" ]; then COMPARISON=match; else COMPARISON=different; fi
elif [ "$SHADOW" = abnormal-exit ]; then
  COMPARISON=different
fi

TRIGGER=${FM_SHADOW_TRIGGER:-manual}
case "$TRIGGER" in completion|process-exit|manual) : ;; *) TRIGGER=manual ;; esac
LINE="v1 epoch=$(date +%s) task=$ID spawn_gen=$SPAWN_GEN harness=$HARNESS backend=$BACKEND trigger=$TRIGGER completion=$COMPLETION process=$PROCESS shadow=$SHADOW current=$CURRENT comparison=$COMPARISON"
DEST="$STATE/$ID.completion-shadow"
LOCK="$DEST.lock"
fm_lock_acquire_wait "$LOCK"
OLD_UMASK=$(umask)
umask 077
printf '%s\n' "$LINE" >> "$DEST"
umask "$OLD_UMASK"
fm_lock_release "$LOCK"
