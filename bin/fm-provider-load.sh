#!/usr/bin/env bash
# fm-provider-load.sh - live crewmate/scout/secondmate lanes per billing provider
# against each provider's configured concurrency cap, for dispatch intake.
#
# Usage:
#   fm-provider-load.sh
#
# Read-only: it acquires no lock, mutates nothing, and never starts, stops, or
# steers an agent. It reads this home's state/<id>.meta records, resolves each
# lane's provider from its recorded harness and model (the model string wins;
# see bin/fm-provider-lib.sh), and prints one line per provider that currently
# carries a live lane:
#
#   provider-load: <provider> <used>/<cap>
#
# A lane whose recorded endpoint is provably dead or missing does not count, so
# a cleared seat is visible before the next dispatch. With no live lane it prints
#   provider-load: no live lanes
# The cap is `providerCaps.<provider>` from config/crew-dispatch.json, else
# `providerCaps.default`, else the fallback in bin/fm-provider-lib.sh; that tool
# is the single owner of the counting and cap rules.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE select the home
# and its state/config directories, exactly as the other bin/ scripts do.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-provider-lib.sh
. "$SCRIPT_DIR/fm-provider-lib.sh"

counts=$(fm_provider_lane_counts "$STATE" "$CONFIG")
if [ -z "$counts" ]; then
  printf 'provider-load: no live lanes\n'
  exit 0
fi
while read -r provider used cap; do
  [ -n "$provider" ] || continue
  printf 'provider-load: %s %s/%s\n' "$provider" "$used" "$cap"
done <<EOF
$counts
EOF
