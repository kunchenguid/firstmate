#!/usr/bin/env bash
# fm-task-inbox-read.sh - acknowledge reading one steering message, not handling it.
# Usage: fm-task-inbox-read.sh <path/to/task.inbox/NNN.msg>
# Run only after reading the message, before acting on it. The receipt is
# idempotent; a missing record fails unless it already exists in handled/.
# bin/fm-task-inbox-lib.sh owns the receipt format and watcher policy.
set -euo pipefail

if [ "${1:-}" = --help ]; then
  printf 'Usage: %s <path/to/task.inbox/NNN.msg>\n' "${0##*/}"
  printf 'Record that you read the message before acting. Move it to handled/ only after handling.\n'
  exit 0
fi
if [ "$#" -ne 1 ]; then
  echo "error: expected one steering-message path; use --help" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
if ! fm_task_inbox_record_read "$1"; then
  printf 'error: could not record reading steering message: %s\n' "$1" >&2
  exit 1
fi
