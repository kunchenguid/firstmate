#!/usr/bin/env bash
# Retire the watcher's check and trust from a home, or with --all from every home install.sh --all reaches and remove the copy.
# Usage: uninstall.sh [--all] <fm-home>
set -euo pipefail
ALL=
[ "${1:-}" = --all ] && { ALL=--all; shift; }
[ "$#" -eq 1 ] && [ -d "$1/state" ] || { echo "usage: uninstall.sh [--all] <fm-home>" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-quota-failover
while IFS=$'\t' read -r name home; do
  [ -x "$home/bin/fm-check-unregister.sh" ] || { echo "skipped: $name: $home has no bin/fm-check-unregister.sh" >&2; continue; }
  env -u FM_STATE_OVERRIDE FM_HOME="$home" "$home/bin/fm-check-unregister.sh" quota-failover-watch >/dev/null
  echo "uninstalled: $name: quota-failover-watch from $home"
done < <("$SRC/install.sh" ${ALL:+--all} --list "$1")
[ -z "$ALL" ] || {
  rm -f -- "$DEST/quota-failover/quota-failover" "$DEST/quota-failover/check.sh" "$DEST/parked-homes/bin/fm-parked-homes-lib.sh" \
    "$DEST/account-pool/bin/fm-account-pool-lib.sh" "$DEST/account-pool/bin/fm-pool-claude-env.sh"
  rmdir -- "$DEST/quota-failover" "$DEST/parked-homes/bin" "$DEST/parked-homes" "$DEST/account-pool/bin" "$DEST/account-pool" "$DEST" \
    2>/dev/null || true
}
