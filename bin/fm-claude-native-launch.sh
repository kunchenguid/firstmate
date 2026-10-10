#!/usr/bin/env bash
# Launch a Claude worker with a private native-control channel prepared by
# fm-spawn. Usage: fm-claude-native-launch.sh <channel> [claude arguments...]
# Only config/claude-native-control=on on Herdr selects this wrapper.
# exec binds the advertised PID to Claude without replacing the pane's shell.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$ROOT/.claude/mods/firstmate-native-control"
export FM_CLAUDE_NATIVE_CHANNEL=$1
shift
export FM_CLAUDE_NATIVE_PID=$$
python3 "$MOD/bridge.py" boot "$FM_CLAUDE_NATIVE_CHANNEL" "$$"
export CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1
exec claude --plugin-dir "$MOD" "$@"
