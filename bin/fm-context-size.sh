#!/usr/bin/env bash
# Read-only conversation-size observation for one captured task metadata file.
# Usage: fm-context-size.sh <meta-file>
#        fm-context-size.sh --remote-self <secondmate-id>
# The remote form is invoked only through fm-on.sh in the selected home and
# reads that secondmate's own parent-route record, never its child inventory.
# Emits one JSON object under a three-second process-group deadline, including
# remote transport and its descendants; failure becomes an unknown observation.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
if ! fm_run_timed 3 python3 -I "$SCRIPT_DIR/fm-context-size.py" "$@"; then
  printf '%s\n' '{"status":"unknown","tokens":null,"context_window":null,"percentage":null,"over_threshold":null,"age_seconds":null,"model":null,"reason":"conversation read unavailable or timed out"}'
fi
