#!/usr/bin/env bash
# fm-captain-inbox.sh - narrow Captain's Inbox reader and read-state updater.
#
# Usage:
#   fm-captain-inbox.sh list
#   fm-captain-inbox.sh mark <ci_v1_message_id> read|unread
#
# Reads only the effective Firstmate home's private Captain's Inbox contract.
# It accepts no path arguments and delegates atomic JSON updates to Node's
# dependency-free standard-library implementation in fm-captain-inbox.mjs.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec node "$SCRIPT_DIR/fm-captain-inbox.mjs" "$@"
