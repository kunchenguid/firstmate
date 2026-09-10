#!/usr/bin/env bash
# fm-discord-workspace.sh - offline owner for Firstmate's private Discord operations workspace.
#
# This script validates non-secret config, renders setup and health dry-runs,
# plans outbound replies/status/artifacts, records idempotent outbound receipts,
# links Discord-originated requests to tasks, preserves pending final follow-ups,
# and keeps live setup, posting, health, and polling outside this entry point.
# The bounded live operations are exposed by fm-discord-live.sh and the
# Discord process-event adapter; destructive retirement remains unsupported.
#
# Usage:
#   fm-discord-workspace.sh sample-config
#   fm-discord-workspace.sh config-check [--config <json>]
#   fm-discord-workspace.sh setup --dry-run [--config <json>]
#   fm-discord-workspace.sh setup --apply [--config <json>]     (offline command refuses; use fm-discord-live.sh setup-apply)
#   fm-discord-workspace.sh health [--local|--secrets|--discord|--transcription|--process-event]
#   fm-discord-workspace.sh reply --request-id <discord:guild:channel:message> --text-file <file>
#   fm-discord-workspace.sh status --profile <profile> --text-file <file> [--thread <id>]
#   fm-discord-workspace.sh artifact --profile <profile> --file <path> --purpose <tag> [--request-id <id>]
#   fm-discord-workspace.sh publish-artifact --profile <profile> --file <path> --purpose <tag> --url <https-url> --access <mode>
#   fm-discord-workspace.sh link-task <task-id> --request-id <discord:guild:channel:message>
#   fm-discord-workspace.sh followup <task-id> [--final] --text-file <file>
#   fm-discord-workspace.sh guard-work <task-id>
#   fm-discord-workspace.sh retire [--apply]
#
# The config file is local and non-secret: config/discord-workspace.json by
# default, or --config. It names exactly one operations guild, one Firstmate
# operations bot identity, captain Discord user ids, System / Firstmate, ProApplis, and Folium
# categories, exchanges and artifacts forum ids, thread allowlists, forum tag
# vocabularies, policy choices, and live polling and posting approvals. This
# offline entry point never reads .env, decrypts secret values, contacts Discord
# or Groq, or creates categories, channels, threads, tags, bots, permissions,
# or live registrations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_discord_workspace_lib.py" tool "$SCRIPT_DIR" "$@"
