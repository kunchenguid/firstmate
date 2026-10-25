#!/usr/bin/env bash
# parked-homes install.sh - verify the parked-homes wiring for one firstmate
# home. It changes nothing: the add-on works through the fork's shim sourcing
# this checkout, so the only install state is (1) this checkout reachable from
# the home, (2) the fork hooks merged, (3) config/parked-homes readable.
#
# Usage: install.sh [--dry-run] <fm-home>
set -u

die() { echo "parked-homes install: $*" >&2; exit 1; }

home=${1:-${FM_HOME:-}}
[ -n "$home" ] && [ -d "$home" ] || die "usage: install.sh <fm-home>"
home=$(cd "$home" && pwd) || die "cannot read $home"
FM_HOME=$home

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
lib="$here/parked-homes/bin/fm-parked-homes-lib.sh"
[ -f "$lib" ] || die "this checkout is missing parked-homes/bin/fm-parked-homes-lib.sh (run from the firstmate-addons checkout)"

status=0
say() { printf '%s\n' "$*"; }
bad() { printf 'MISSING: %s\n' "$*"; status=1; }

addons="${FM_ADDONS_DIR:-$home/projects/firstmate-addons}"
if [ -f "$addons/parked-homes/bin/fm-parked-homes-lib.sh" ]; then
  same=0
  [ "$(cat "$addons/parked-homes/bin/fm-parked-homes-lib.sh" 2>/dev/null)" = "$(cat "$lib")" ] && same=1
  say "add-on checkout: $addons (lib $([ "$same" = 1 ] && echo matches || echo DIFFERS-FROM-this-checkout))"
else
  bad "add-on checkout reachable at $addons/parked-homes (set FM_ADDONS_DIR or update projects/firstmate-addons)"
fi

if [ -f "$home/bin/fm-parked-homes-lib.sh" ] &&
   grep -q "parked-homes/bin/fm-parked-homes-lib.sh" "$home/bin/fm-parked-homes-lib.sh"; then
  say "fork shim: $home/bin/fm-parked-homes-lib.sh present"
else
  bad "fork shim at $home/bin/fm-parked-homes-lib.sh (merge the parked-homes fork PR first)"
fi

file="$home/config/parked-homes"
if [ -f "$file" ]; then
  say "parked file: $file"
  grep -Ev '^[[:space:]]*(#|$)' "$file" | sed 's/^/  parked: /'
else
  say "parked file: $file absent (nothing is parked)"
fi

[ "$status" = 0 ] && say "wiring complete" || say "wiring incomplete"
exit "$status"
