#!/usr/bin/env bash
# Inspect and claim durable captain direct-message inbox items.
#
# Usage: identical to fm-topic-inbox.sh (list, show, claim, release, count),
# pointed at the direct-message store $FM_HOME/data/fm-telegram-dm.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_DM_LIB_DIR="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}/bin"
export FM_TOPIC_DATA_DIR="${FM_DM_DATA_DIR:-${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}/data/fm-telegram-dm}"
exec "$FM_DM_LIB_DIR/fm-topic-inbox.sh" "$@"
