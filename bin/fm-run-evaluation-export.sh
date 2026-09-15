#!/usr/bin/env bash
# Publish the neutral, redacted Cockpit run-evaluation snapshot.
# Usage: fm-run-evaluation-export.sh
#
# The fixed source is $FM_HOME/data/run-evaluations and the fixed destination
# is $FM_HOME/state/cockpit-run-evaluation.json.
# FM_HOME, FM_ROOT_OVERRIDE, FM_DATA_OVERRIDE, and FM_STATE_OVERRIDE follow the
# established home and test override precedence.
# The command never computes scores, ranks, recommendations, or routing.
# It validates immutable governance.run-evaluation.v1 inputs, withholds unsafe
# records, projects only contract fields, validates the consumer document, and
# replaces the destination atomically at mode 0600.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "$SCRIPT_DIR/fm-run-evaluation-export.py" "$@"
