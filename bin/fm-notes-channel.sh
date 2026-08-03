#!/usr/bin/env bash
# Guarded Apple Notes channel owner.
#
# Usage:
#   fm-notes-channel.sh [--home PATH] init-fake --fixture PATH
#   fm-notes-channel.sh [--home PATH] init-production --app PATH --executable-sha256 HASH --designated-requirement REQUIREMENT
#   fm-notes-channel.sh [--home PATH] pair-production [--request-automation]
#   fm-notes-channel.sh [--home PATH] record-pairing --binding-hash HASH  # reviewed bridge JSON on stdin
#   fm-notes-channel.sh [--home PATH] enable --mode outbound-test|read-only|bounded-bidirectional
#   fm-notes-channel.sh [--home PATH] doctor|status|scan|poll|reconcile|verify-audit|provider-log
#   fm-notes-channel.sh [--home PATH] claim|show MESSAGE_ID
#   fm-notes-channel.sh [--home PATH] acknowledge MESSAGE_ID --classification ENUM
#   fm-notes-channel.sh [--home PATH] prepare-outbound-test
#   fm-notes-channel.sh [--home PATH] publish LOGICAL_ID
#   fm-notes-channel.sh [--home PATH] install-definitions --runtime-root PATH
#   fm-notes-channel.sh [--home PATH] uninstall-definitions
#   fm-notes-channel.sh [--home PATH] disable --emergency
#
# This wrapper owns no policy of its own.  fm-notes-channel-impl.py is the one
# owner of the fixed schema, state machine, provider boundary, path checks,
# operation flags, and exact help.  Production is disabled until exact helper
# identity plus a captain-reviewed fixed-tree pairing have been recorded and an
# explicit bounded mode is enabled.  doctor, status, install/uninstall, disable,
# and local reconcile send zero Apple Events.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-notes-channel-impl.py" "$@"
