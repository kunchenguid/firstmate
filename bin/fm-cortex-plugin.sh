#!/usr/bin/env bash
# Write a private Cortex Code worker plugin carrying firstmate's lifecycle hooks.
# Usage: fm-cortex-plugin.sh <state-dir> <task-id> <busy-gen>
# Output: <state-dir>/<task-id>.cortex-plugin/, mode 700, replaced as a whole:
#   .cortex-plugin/plugin.json  the manifest Cortex requires before it loads a plugin dir
#   hooks/hooks.json            SessionStart, UserPromptSubmit, Stop, and SessionEnd hooks
# The launch passes the directory with --plugin-dir. A plugin is the only
# per-task channel Cortex 1.1.104 has for hooks: `--config <settings.json>`
# replaces ~/.snowflake/cortex/settings.json but its hooks are never read, and
# every other hook source (~/.snowflake/cortex/hooks.json, ~/.claude/ and
# ~/.cortex/ settings, the project's .claude/ and .cortex/ settings and
# settings.local.json) is a user or project file. Nothing global and nothing in
# the worktree is edited; fm-control-lib.sh and fm-teardown.sh own retirement.
# UserPromptSubmit opens a turn; Stop and SessionEnd close it. Cortex fires
# Stop on normal completion and on an Escape interrupt alike, so unlike
# Devin the control plane never has to invalidate a cancelled turn.
# The turn-end notification is raised by the generation-bound apply itself
# (--turn-ended), under the writer lock; events rejected as stale emit none.
# Cortex is not in Herdr's detection manifest (herdrdev/herdr discussion 783),
# so on Herdr (HERDR_ENV=1 and a pane id in the hook environment) each hook
# also reports the pane to Herdr as a `cortex` agent from source
# firstmate:cortex: idle on SessionStart and Stop, working on a prompt, released on exit.
# Without it Herdr answers agent_not_found, the liveness probe reads a live
# worker as dead, and the steering doorbell is skipped as to a dead endpoint.
# Outside Herdr the reporting clause is a no-op.
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
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo 'error: invalid task id' >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo 'error: state directory missing' >&2; exit 1; }
STATE=$(cd "$STATE" && pwd -P)
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
prefix="$(quote "$SCRIPT_DIR/fm-busy-event.sh") apply $(quote "$STATE") $(quote "$ID")"
suffix="--gen $(quote "$GEN") --source cortex-hook"
report() {  # <working|idle|release>
  local verb=report-agent tail="--state $1"
  if [ "$1" = release ]; then verb=release-agent; tail=; fi
  printf '%s' "if [ \"\${HERDR_ENV:-}\" = 1 ] && [ -n \"\${HERDR_PANE_ID:-}\" ]; then \"\${HERDR_BIN_PATH:-herdr}\" pane $verb \"\$HERDR_PANE_ID\" --source firstmate:cortex --agent cortex $tail >/dev/null 2>&1; fi; true"
}
start="$(report idle)"
submit="$prefix busy $suffix --event user-prompt-submit >/dev/null 2>&1 || true; $(report working)"
stop="$prefix idle $suffix --event stop --turn-ended >/dev/null 2>&1 || true; $(report idle)"
end="$prefix idle $suffix --event session-end >/dev/null 2>&1 || true; $(report release)"
final="$STATE/$ID.cortex-plugin"
umask 077
temp=$(mktemp -d "$STATE/.$ID.cortex-plugin.XXXXXX")
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/.cortex-plugin" "$temp/hooks"
jq -n --arg id "$ID" \
  '{name: "firstmate-worker", version: "1.0.0", description: ("firstmate lifecycle hooks for task " + $id)}' \
  > "$temp/.cortex-plugin/plugin.json"
jq -n --arg start "$start" --arg submit "$submit" --arg stop "$stop" --arg end "$end" '
  def hook($cmd): [{matcher: "*", hooks: [{type: "command", command: $cmd, timeout: 10}]}];
  {hooks: {SessionStart: hook($start), UserPromptSubmit: hook($submit), Stop: hook($stop), SessionEnd: hook($end)}}
' > "$temp/hooks/hooks.json"
rm -rf "$final"
mv "$temp" "$final"
trap - EXIT
