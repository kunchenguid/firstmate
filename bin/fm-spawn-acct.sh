#!/usr/bin/env bash
# fm-spawn-acct.sh — multi-account wrapper around fm-spawn.sh.
#
# Adds a per-spawn --account axis by exporting account isolation for fm-spawn's
# canonical launch template. Isolation rides in the generated pane command, so it
# survives the Herdr/tmux pane boundary; no secret is placed on argv.
#
# Scope: config-dir accounts (claude/codex/pi/cline). api-key accounts
# (grok/cursor) are refused here (a key would land on argv) — use
# fm-account-exec.sh for a direct, non-supervised isolated launch instead.
#
# Usage:
#   fm-spawn-acct.sh <task-id> <project-dir> --account <name> [--model M] [--effort E] [passthrough flags...]
#
# Testable: set FM_SPAWN_BIN to a stub to capture the composed launch command.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"; export FM_HOME
# shellcheck source=bin/fm-account-env.sh disable=SC1091
. "$SCRIPT_DIR/fm-account-env.sh"

ACCOUNT=""; MODEL=""; EFFORT=""; POS=(); PASS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --account)   ACCOUNT=${2:-}; shift 2 ;;
    --account=*) ACCOUNT=${1#--account=}; shift ;;
    --model)     MODEL=${2:-}; shift 2 ;;
    --model=*)   MODEL=${1#--model=}; shift ;;
    --effort)    EFFORT=${2:-}; shift 2 ;;
    --effort=*)  EFFORT=${1#--effort=}; shift ;;
    *) if [ "${#POS[@]}" -lt 2 ]; then POS+=("$1"); else PASS+=("$1"); fi; shift ;;
  esac
done

[ -n "$ACCOUNT" ] || { echo "usage: fm-spawn-acct.sh <task-id> <project-dir> --account <name> [--model M] [--effort E] [flags...]" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "error: task-id (and usually project-dir) required" >&2; exit 1; }

fm_account_prepare_supervised_spawn "$ACCOUNT" || exit $?

FM_SPAWN_BIN="${FM_SPAWN_BIN:-$SCRIPT_DIR/fm-spawn.sh}"
SPAWN_ARGS=("${POS[@]}" --harness "$FM_ACCOUNT_SUPERVISED_HARNESS")
[ -z "$MODEL" ] || SPAWN_ARGS+=(--model "$MODEL")
[ -z "$EFFORT" ] || SPAWN_ARGS+=(--effort "$EFFORT")
SPAWN_ARGS+=("${PASS[@]}")
exec "$FM_SPAWN_BIN" "${SPAWN_ARGS[@]}"
