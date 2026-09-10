#!/usr/bin/env bash
# fm-procevent-discord-workspace.sh - built-in process-event adapter for Discord workspace intake.
#
# Usage:
#   fm-procevent-discord-workspace.sh arm [--dry-run] [--config <json>]
#   fm-procevent-discord-workspace.sh source [--config <json>]
#   fm-procevent-discord-workspace.sh classify <result-file>
#   fm-procevent-discord-workspace.sh silent <result-file>
#   fm-procevent-discord-workspace.sh terminal <result-file>
#   fm-procevent-discord-workspace.sh self-announcing
#   fm-procevent-discord-workspace.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-discord-workspace.sh answers <result-file>
#
# `arm` renders a dry-run registration plan. With live polling enabled in the
# workspace config, non-dry-run arm registers this adapter as the built-in
# discord-workspace process-event source; while disabled it refuses.
# `source` runs in one of two modes. Fixture mode (live polling disabled)
# reads only an offline fixture named by FM_DISCORD_WORKSPACE_FIXTURE or
# poll.fixture_file and refuses before any network call without one. Live mode
# (live polling enabled) runs one bounded live-source pass per invocation
# through the bounded live activation layer: a successful scan is silent and
# exits nonzero with no output so the runner records no-result and keeps the
# source armed, while a genuine failure prints one bounded redacted actionable
# line as a captured result. Accepted forum-post/thread messages are
# normalized into one durable fm-inbox note through fm-inbox.sh's external-id
# idempotency seam, and cursors advance only after successful handoff. The
# adapter declares self-announcing so an accepted message produces only the
# ordinary captain-inbox notification.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_discord_workspace_lib.py" procevent "$SCRIPT_DIR" "$@"
