#!/usr/bin/env bash
# Short-poll of Discord API for a pending self-hosted Discord mention.
#
# Inert by default: a HARD no-op (exit 0, no output) unless FM_DISCORD_BOT_TOKEN
# is configured (from the home's .env or environment).
# The watcher invokes this trusted repository script directly after
# state/discord-watch.check.sh matches the expected byte-static identity shim.
#
# Its contract: output "x-mention <request_id>" => wake firstmate, silence => keep sleeping.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

fm_discord_load_config
[ -n "${FM_DISCORD_TOKEN:-}" ] || exit 0

command -v node >/dev/null 2>&1 || { printf 'x-mode-error missing node for self-hosted Discord\n'; exit 0; }

export FM_HOME FM_ROOT FM_STATE_OVERRIDE="$STATE"
export FM_DISCORD_BOT_TOKEN="$FM_DISCORD_TOKEN"
export FM_DISCORD_CHANNELS="${FM_DISCORD_CHANNELS:-}"
export FM_DISCORD_EXCLUDES="${FM_DISCORD_EXCLUDES:-1551134713727426570}"
export FM_DISCORD_ALLOW_DMS="${FM_DISCORD_DMS:-true}"

exec node "$SCRIPT_DIR/fm-discord-poll.js"
