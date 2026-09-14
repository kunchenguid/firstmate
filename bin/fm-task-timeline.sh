#!/usr/bin/env bash
# fm-task-timeline.sh - per-task timeline record checkpoints and read-only view.
#
# Usage:
#   fm-task-timeline.sh checkpoint dispatch <task-id> [--relaunch]
#   fm-task-timeline.sh checkpoint cleanup <task-id>
#   fm-task-timeline.sh build <task-id> [--json]
#   fm-task-timeline.sh --help
#
# bin/fm_task_timeline.py owns the fm-task-timeline.v1 record schema
# (data/<task-id>/timeline.json), the two checkpoint writers, and the phase
# arithmetic; read its module docstring for the contract. This wrapper only
# resolves python3 and passes the home through.
#
# Callers:
#   bin/fm-spawn.sh runs `checkpoint dispatch` after state/<id>.meta is committed
#   (with --relaunch on a relaunch); bin/fm-teardown.sh runs `checkpoint cleanup`
#   after every refusal gate has passed and before its first destructive step.
#   Both checkpoints exit 0 on failure after printing one `warning:` line, so a
#   missing python3 or an unwritable data/<id>/ never blocks a spawn or teardown.
#   `build` is what the bridge console's `t` key renders; it only reads.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE select the home;
# FM_TIMELINE_NM_TIMEOUT bounds each no-mistakes call (seconds, default 10).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  --help|-h|'')
    usage
    [ -n "${1:-}" ] || exit 2
    exit 0
    ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  case "$1" in
    checkpoint)
      echo "warning: timeline ${2:-} checkpoint for ${3:-?} not written: python3 not found" >&2
      exit 0
      ;;
  esac
  echo "error: python3 not found" >&2
  exit 1
fi

exec python3 "$SCRIPT_DIR/fm_task_timeline.py" "$@"
