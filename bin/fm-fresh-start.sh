#!/usr/bin/env bash
# fm-fresh-start.sh - the stow skill's half of the daily fresh start.
#
# Usage: fm-fresh-start.sh attest <nonce>
#
# The daily fresh start (bin/fm-fresh-start-lib.sh owns the steps) submits
# `/stow daily-fresh-start <nonce>` to the primary. The stow skill runs this
# command as its last action only when its completion receipt declares the
# session safe to reset (.agents/skills/stow/SKILL.md "Completion receipt").
# It records that attestation for the waiting save attempt; the clear step
# requires it. It refuses (exit 1) unless the record is a save waiting on
# exactly this nonce, and exits 2 on a usage error. It types nothing and
# clears nothing itself.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-fresh-start-lib.sh
. "$SCRIPT_DIR/fm-fresh-start-lib.sh"

if [ "$#" -ne 2 ] || [ "$1" != attest ]; then
  echo "usage: fm-fresh-start.sh attest <nonce>" >&2
  exit 2
fi
if ! fm_fresh_start_attest "$STATE" "$2"; then
  echo "fm-fresh-start: no save is waiting on nonce $2; nothing was recorded" >&2
  exit 1
fi
echo "fm-fresh-start: recorded that this session is safe to reset; the daily fresh start may clear it on a later idle moment"
