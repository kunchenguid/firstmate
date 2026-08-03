#!/usr/bin/env bash
# One nonresident bounded Apple Notes check.
#
# The authenticated state check invokes this tracked entrypoint through a
# marker-owned shim.  Output means Firstmate should wake; silence means it should
# keep waiting.  The channel owner checks disabled/config state before creating a
# provider, durably captures before offering, prints only IDs/counts, and imposes
# an 8-second internal scan deadline.  The watcher supplies the outer timeout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Disabled and not-yet-installed homes are a hard no-op so merely carrying the
# local-runtime patch never creates state or invokes the dedicated bridge.
[ -f "$FM_HOME/config/apple-notes-channel.json" ] || exit 0
[ ! -e "$FM_HOME/state/apple-notes-channel/DISABLED" ] || exit 0

exec "$SCRIPT_DIR/fm-notes-channel.sh" --home "$FM_HOME" poll
