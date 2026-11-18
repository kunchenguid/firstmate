#!/usr/bin/env bash
# Write a private GitHub Copilot CLI worker plugin carrying firstmate's lifecycle hooks.
# Usage: fm-copilot-plugin.sh <state-dir> <task-id> <busy-gen> [<worktree>]
# Output: <state-dir>/<task-id>.copilot-plugin/, mode 700, replaced as a whole:
#   plugin.json       the manifest Copilot reads before it loads a plugin dir
#   hooks/hooks.json  userPromptSubmitted, agentStop, and sessionEnd hooks
# With a worktree it also seeds <state-dir>/<task-id>.copilot-home/config.json,
# mode 700, kept across relaunch: the launch relocates COPILOT_HOME onto it,
# and its trustedFolders names exactly that worktree, so the folder-trust
# dialog never holds the -i prompt and no other directory is trusted. The
# the user's real ~/.copilot is never written and its user-level hooks, plugins,
# skills and MCP servers do not load (verified, copilot 1.0.105). Its
# ${COPILOT_HOME:-$HOME/.copilot}/config.json is read for exactly four keys,
# authTokens (copilot 1.0.109), the older copilotTokens, loggedInUsers and
# lastLoggedInUser, carried into the task config.json (mode 600, values never
# printed) so a host that keeps the login in that file instead of the OS
# keyring still signs in. Those keys are replaced on every seed, so a missing
# or unparsable source adds nothing and clears an earlier copy.
# The launch passes the plugin directory with --plugin-dir, which loads the
# hooks once the working directory is trusted. A plugin is the
# per-task hook channel because every other hook source is a user or project
# file (~/.copilot/hooks, .github/hooks in the worktree). Nothing global and
# nothing in the worktree is edited; fm-control-lib.sh and fm-teardown.sh own
# retirement.
# userPromptSubmitted opens a turn; agentStop and sessionEnd close it, ignoring
# the events a subagent raises (payloads carrying parentAgentId). agentStop
# does NOT fire when an interrupt cancels the turn (verified), so the record
# stays busy until the next prompt, like claude's Stop.
# The turn-end notification is raised by the generation-bound apply itself
# (--turn-ended), under the writer lock; events rejected as stale emit none.
# Herdr's own copilot integration reports the pane identity, so the hooks here
# carry no Herdr reporting.
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
WORKTREE=${4:-}
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo 'error: invalid task id' >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo 'error: state directory missing' >&2; exit 1; }
STATE=$(cd "$STATE" && pwd -P)
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
prefix="$(quote "$SCRIPT_DIR/fm-busy-event.sh") apply $(quote "$STATE") $(quote "$ID")"
suffix="--gen $(quote "$GEN") --source copilot-hook"
# A subagent fires its own userPromptSubmitted and agentStop with a parentAgentId
# (verified, copilot 1.0.105); its stop would close the parent's turn early, so
# those payloads are skipped and only the main agent's events count.
sub='grep -q '"'"'"parentAgentId":"'"'"' ||'
submit="$sub $prefix busy $suffix --event user-prompt-submit >/dev/null 2>&1 || true"
stop="$sub $prefix idle $suffix --event agent-stop --turn-ended >/dev/null 2>&1 || true"
end="$prefix idle $suffix --event session-end >/dev/null 2>&1 || true"
final="$STATE/$ID.copilot-plugin"
umask 077
temp=$(mktemp -d "$STATE/.$ID.copilot-plugin.XXXXXX")
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/hooks"
jq -n --arg id "$ID" \
  '{name: "firstmate-worker", version: "1.0.0", description: ("firstmate lifecycle hooks for task " + $id)}' \
  > "$temp/plugin.json"
jq -n --arg submit "$submit" --arg stop "$stop" --arg end "$end" '
  def hook($cmd): [{type: "command", bash: $cmd, timeoutSec: 10}];
  {version: 1, hooks: {userPromptSubmitted: hook($submit), agentStop: hook($stop), sessionEnd: hook($end)}}
' > "$temp/hooks/hooks.json"
rm -rf "$final"
mv "$temp" "$final"
trap - EXIT
[ -n "$WORKTREE" ] || exit 0
WORKTREE=$(cd "$WORKTREE" && pwd -P)
home="$STATE/$ID.copilot-home"
mkdir -p "$home"
chmod 700 "$home"
config="$home/config.json"
# Copilot rewrites this file with a // comment header, so strip it before jq.
base='{}'
[ ! -s "$config" ] || base=$(grep -v '^[[:space:]]*//' "$config" | jq -c . 2>/dev/null) || base='{}'
login='{}'
source_config="${COPILOT_HOME:-$HOME/.copilot}/config.json"
[ ! -s "$source_config" ] || login=$(grep -v '^[[:space:]]*//' "$source_config" \
  | jq -c 'with_entries(select(.key | IN("authTokens", "copilotTokens", "loggedInUsers", "lastLoggedInUser")))' 2>/dev/null) || login='{}'
printf '%s' "$base" | jq --arg wt "$WORKTREE" --argjson login "$login" 'del(.authTokens, .copilotTokens, .loggedInUsers, .lastLoggedInUser) + $login | .trustedFolders = [$wt]' > "$config.tmp"
chmod 600 "$config.tmp"
mv "$config.tmp" "$config"
