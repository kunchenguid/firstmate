#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crewmate's current state.
#
# A task status file is an append-only event log, so a live backend endpoint is
# the primary source for active work. Recognized terminal or pause events are
# used only after the endpoint is readable and idle. This keeps supervision
# local, bounded, and independent of any external review service.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
SEP=' · '

emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
[ -n "$KIND" ] || KIND=ship
[ -n "$WT" ] && [ -d "$WT" ] \
  || emit unknown none "worktree gone (torn down?)"

log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}

map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  if status_pause_is_failure "$1"; then
    echo failed
    return
  fi
  case "$(status_line_verb "$1")" in
    working) echo working ;;
    needs-decision) echo parked ;;
    blocked) echo blocked ;;
    done) printf '%s\n' "done" ;;
    failed) echo failed ;;
    *) echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_STATE=$(map_log_state "$LOG_LINE")
OPEN_DECISION=$(status_open_decisions "$LOG" | tail -1)
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
RECORDED_SCOPED_TARGET=$(fm_meta_get "$META" tmux_session_target)

[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
fm_backend_capture "$TASK_BACKEND" "$BACKEND_TARGET" 1 "$EXPECTED_LABEL" \
  "$RECORDED_SCOPED_TARGET" >/dev/null 2>&1 \
  || emit unknown none "backend target gone: $BACKEND_TARGET"

crew_endpoint_is_busy() {
  local state tail40
  state=$(fm_backend_busy_state "$TASK_BACKEND" "$BACKEND_TARGET" \
    "$EXPECTED_LABEL" 2>/dev/null)
  [ "$state" = busy ] && return 0
  tail40=$(fm_backend_capture "$TASK_BACKEND" "$BACKEND_TARGET" 40 \
    "$EXPECTED_LABEL" "$RECORDED_SCOPED_TARGET" 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

# Secondmates normally idle in their watcher. Their declared status is more
# meaningful than a terminal busy signature.
if [ "$KIND" != secondmate ] && crew_endpoint_is_busy; then
  emit working pane "harness busy"
fi

# A scout's terminal event means its one deliverable has been returned. Its
# earlier gate may remain in the append-only history, but it must not reopen a
# completed report as a pending captain decision. Persistent secondmates keep
# the full keyed fold because one concern can finish while another stays open.
if [ "$KIND" = scout ] && { [ "$LOG_STATE" = "done" ] || [ "$LOG_STATE" = "failed" ]; }; then
  emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
fi

if [ -n "$OPEN_DECISION" ]; then
  IFS=$'\t' read -r _OPEN_KEY OPEN_VERB OPEN_NOTE <<EOF
$OPEN_DECISION
EOF
  case "$OPEN_VERB" in
    needs-decision) emit parked status-log "$OPEN_NOTE" ;;
    blocked) emit blocked status-log "$OPEN_NOTE" ;;
  esac
fi

if [ "$LOG_STATE" != unknown ]; then
  emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
fi

emit unknown none "backend idle with no current-state event"
