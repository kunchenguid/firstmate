#!/usr/bin/env bash
# fm-discord-live.sh - bounded live Discord activation layer.
#
# Usage:
#   fm-discord-live.sh health --config <json>
#   fm-discord-live.sh setup-apply --config <json>
#   fm-discord-live.sh live-reply --config <json> --request-id <id> --text-file <f> [--nonce <n>]
#   fm-discord-live.sh live-source --config <json>
#   fm-discord-live.sh live-roundtrip --config <json> --request-id <id> --text-file <f>
#   fm-discord-live.sh live-post --config <json> --thread <id> --tag captain|main --text-file <f>
#
# Decrypts only the bot token into process memory (never stdout, disk, or
# logs), talks to Discord API v10, and reuses the core workspace config,
# receipts, cursors, and external-id inbox seam. Deletion/retirement, voice
# capture, hosted transcription, webhooks, and arbitrary guilds stay out of
# scope. Test seams: FM_DISCORD_LIVE_API_BASE and FM_DISCORD_LIVE_SOPS.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_discord_live.py" "$SCRIPT_DIR" "$@"
