#!/usr/bin/env bash
# Serialized native candidate-pool admissions; never creates endpoints.
# Usage: fm-dispatch-pool.sh <validate|default|inspect|probe|reserve|verify|finish|bind>
#          <config-file> <state-dir> [task-id|kind] [pool|receipt]
#          [fresh|pinned|exhausted|replay|launched|failed] [terminal-evidence]
# validate/default/probe are read-only. reserve persists smooth weighted
# round-robin scores and a task/generation receipt before launch. Failed launch
# consumes its slot; replay retains the same candidate, never a second draw.
# bind reads a native Codex notification on stdin and preserves turn-ended.
# finish records native delivery outcome. One atomic native state file owns
# scores, receipts and audit events; the shared Firstmate lock serializes writers.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) sed -n '2,12s/^# \{0,1\}//p' "$0"; exit 0 ;;
  validate|default|probe) exec node "$SCRIPT_DIR/fm-dispatch-pool.js" "$@" ;;
esac
[ -n "${3:-}" ] && [ -d "$3" ] && [ ! -L "$3" ] || { echo 'error: pool state directory required' >&2; exit 1; }
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
pool_lock="$3/.dispatch-pools.lock"
fm_lock_acquire_wait "$pool_lock"
trap 'fm_lock_release "$pool_lock"' EXIT
node "$SCRIPT_DIR/fm-dispatch-pool.js" "$@"
