#!/usr/bin/env bash
# Accept a new cloud kick: compare state/cloud-kick.md to state/cloud-kick.done and
# queue one check wake when the kick changed.
#
# Usage:
#   fm-cloud-annahme.sh
#
# Silent success when the bridge is not configured or the kick is unchanged.
# Supervisor checkpoints (empty wake queue, turn-end) call this directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-cloud-lib.sh
. "$SCRIPT_DIR/fm-cloud-lib.sh"

fm_cloud_annahme_try
