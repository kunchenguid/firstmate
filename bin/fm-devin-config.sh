#!/usr/bin/env bash
# Write a private Devin worker config, preserving user settings and hooks.
# Usage: fm-devin-config.sh <state-dir> <task-id> <busy-gen> [<user-config>]
# The default source is ~/.config/devin/config.json (Devin's --config default).
# An absent source starts from {}; unreadable or malformed sources refuse.
# Output: <state-dir>/<task-id>.devin-config.json, mode 600, atomically replaced.
# No project or user config is edited. fm-control-lib.sh owns retirement.
# Two settings are forced for every worker. read_config_from.claude=false,
# because Devin otherwise runs every Claude Code hook it finds (~/.claude and
# the project's .claude/settings*.json), including Herdr's hook that reports
# the pane as a Claude agent; it also drops Devin's CLAUDE.md, .claude/skills,
# and Claude MCP imports, while AGENTS.md and .agents/skills still load.
# attribution=false, because Devin otherwise adds a Co-Authored-By: Devin
# trailer and a Generated with Devin line to commits and PRs.
# UserPromptSubmit opens a turn; Stop and SessionEnd close it. Devin 3000.11.1
# emits no Stop on double-Escape cancellation, so fm-control invalidates its
# state to unknown after delivering that interrupt, never fabricating idle.
# Turn-end touches follow a successful generation-bound apply; events
# rejected as stale emit no notification.
set -eu
case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -eu/{ /^#/s/^# \{0,1\}//p; }' "$0"
    exit 0
    ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE=${1:?state directory required}
ID=${2:?task id required}
GEN=${3:?busy generation required}
SOURCE=${4:-$HOME/.config/devin/config.json}
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo 'error: invalid task id' >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo 'error: state directory missing' >&2; exit 1; }
STATE=$(cd "$STATE" && pwd -P)
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
prefix="$(quote "$SCRIPT_DIR/fm-busy-event.sh") apply $(quote "$STATE") $(quote "$ID")"
suffix="--gen $(quote "$GEN") --source devin-hook"
submit="$prefix busy $suffix --event user-prompt-submit >/dev/null 2>&1 || true"
stop="$prefix idle $suffix --event stop >/dev/null 2>&1 && touch $(quote "$STATE/$ID.turn-ended"); true"
end="$prefix idle $suffix --event session-end >/dev/null 2>&1 || true"
if [ ! -e "$SOURCE" ] && [ ! -L "$SOURCE" ]; then SOURCE=/dev/null; fi
umask 077
temp=$(mktemp "$STATE/.$ID.devin-config.XXXXXX")
trap 'rm -f "$temp"' EXIT
jq -s --arg submit "$submit" --arg stop "$stop" --arg end "$end" '
  (if length == 0 then {} elif length == 1 then .[0] else error("expected one config object") end) |
  if type != "object" then error("expected config object") else . end |
  .attribution = false |
  .read_config_from = ((.read_config_from // {}) + {claude: false}) |
  .hooks = (.hooks // {}) |
  def hook($cmd): {hooks: [{type: "command", command: $cmd, timeout: 10}]};
  .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [hook($submit)]) |
  .hooks.Stop = ((.hooks.Stop // []) + [hook($stop)]) |
  .hooks.SessionEnd = ((.hooks.SessionEnd // []) + [hook($end)])
' "$SOURCE" > "$temp"
mv "$temp" "$STATE/$ID.devin-config.json"
