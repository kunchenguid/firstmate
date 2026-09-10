#!/usr/bin/env bash
# Read quota-axi under one candidate runner's account pin.
#
# Usage:
#   fm-quota-snapshot.sh <harness> [quota-axi args...]
#
# Dispatch intake reads capacity per account pin, never ambient
# (.agents/skills/quota-array-dispatch/SKILL.md). For a pinned runner (claude,
# pi, pi-signed) this resolves the active home's pin exactly as bin/fm-spawn.sh
# does for a worker, so an ambient CLAUDE_CONFIG_DIR never answers for it,
# refuses exactly as spawn refuses when it is missing or invalid, and
# runs quota-axi with that pin exported, so the rows quota-axi reads from that
# root describe the pinned account. Any other runner has no pin and runs
# quota-axi in the ambient environment. Arguments pass through unchanged, so
# one command serves the default TOON, the --json fallback, and `auth --json`.
#
# quota-axi reads a pin only where its README says it does: CLAUDE_CONFIG_DIR
# for the claude row, PI_CODING_AGENT_DIR for Pi's own pi:xai and
# pi:kimi-coding sources. docs/configuration.md "Account pins" owns what that
# means for a Pi candidate whose row comes from another store.
#
# Exit status: quota-axi's own; 1 when the pin refuses; 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-account-pin-lib.sh
. "$SCRIPT_DIR/fm-account-pin-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit "${1:-2}"
}

[ "$#" -ge 1 ] || usage
case "$1" in -h|--help|help) usage 0 ;; esac
harness=$1
shift
fm_control_harness_supported "$harness" || { printf 'error: unknown harness: %s\n' "$harness" >&2; exit 2; }

if var=$(fm_account_pin_var "$harness"); then
  FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
  root=$(fm_account_pin_resolve "$harness" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$FM_HOME") || exit 1
  export "$var=$root"
fi
exec quota-axi "$@"
