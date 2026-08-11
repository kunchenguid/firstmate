#!/usr/bin/env bash
# fm-fleet-join.sh — self-onboard THIS operator into the shared fleet (run AS YOURSELF).
#
# Points this deployment's config at the shared KB, verifies cross-uid-safe access,
# and registers you as an operator. Idempotent. It only ever writes YOUR OWN
# $FM_HOME/config and the group-writable shared KB — never another operator's home.
# The one-time root prereq (group `agents` + a group-writable shared dir) is
# documented in docs/fleet-quickstart.md and scripts/fleet-root-prereq.sh.
# It must already be done and the fleet `init`'d.
#
# Usage: fm-fleet-join.sh <operator> <scopes-csv> [accounts-csv]
#   e.g. fm-fleet-join.sh adi backend,infra,deploy claude-default,codex-default
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-fleet-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-fleet-lib.sh"

op=${1:-}; scopes=${2:-}; accounts=${3:-}
[ -n "$op" ] && [ -n "$scopes" ] || { echo "usage: fm-fleet-join.sh <operator> <scopes-csv> [accounts-csv]" >&2; exit 3; }

DIR=$(fm_fleet_dir)
fm_fleet_assert_shared "$DIR" || exit 1
if [ ! -f "$DIR/operators.md" ]; then
  echo "error: fleet not initialized at $DIR." >&2
  echo "  Once the shared group-writable dir exists (root prereq), run: fm-fleet.sh init" >&2
  exit 1
fi
# Writability probe: prove group membership + 2775 perms before registering.
probe="$DIR/.join-probe.$$"
if ! ( : > "$probe" ) 2>/dev/null; then
  echo "error: $DIR is not writable by $(id -un). Check 'agents' group membership and mode 2775 (see the root prereq)." >&2
  exit 1
fi
rm -f "$probe" 2>/dev/null || true

# Point THIS deployment at the shared fleet (own home only).
mkdir -p "$FM_HOME/config"
printf '%s\n' "$DIR" > "$FM_HOME/config/fleet-dir"

# Register self (home = own $FM_HOME; the lib refuses a foreign home).
fm_fleet_register "$DIR" "$op" "$scopes" "$FM_HOME" "$accounts" || exit 1

echo "joined fleet at $DIR as '$op' (scopes: $scopes${accounts:+, accounts: $accounts})"
echo "next:"
echo "  • wait for work (bash, 0 LLM tokens):   $SCRIPT_DIR/fm-fleet-wait.sh $op"
echo "  • or keep alive on a timer:             watch -n60 '$SCRIPT_DIR/fm-fleet.sh heartbeat $op'"
echo "  • see the fleet:                        $SCRIPT_DIR/fm-fleet.sh status"
