#!/usr/bin/env bash
# Post firstmate's composed answer directly to Discord for a self-hosted Discord mention.
#
# Usage: fm-discord-reply.sh <request_id> <payload_file> [endpoint] [image_path]

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

fm_discord_load_config

command -v node >/dev/null 2>&1 || { echo "fm-discord-reply: node not found" >&2; exit 1; }

export FM_HOME FM_ROOT FM_STATE_OVERRIDE="$STATE"
export FM_DISCORD_BOT_TOKEN="${FM_DISCORD_TOKEN:-}"

exec node "$SCRIPT_DIR/fm-discord-reply.js" "$@"
