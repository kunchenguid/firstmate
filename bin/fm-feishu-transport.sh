#!/usr/bin/env bash
# Start, stop, inspect, or foreground the dedicated no-Agent Feishu transport.
#
# The Node entry point owns exact argv, readiness, reconciliation, delivery,
# owner identity, and health behavior.  This wrapper only resolves the tracked
# code root and execs Node; it never evaluates message text or constructs a
# shell command from private state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_ROOT_OVERRIDE="$FM_ROOT"
export FM_HOME
exec node "$SCRIPT_DIR/fm-feishu-transport.mjs" "$@"
