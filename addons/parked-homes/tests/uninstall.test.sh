#!/usr/bin/env bash
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/user XDG_DATA_HOME=$d/data
home=$d/home
mkdir -p "$home/bin" "$home/config"
FM_ADDONS_DIR=$(cd "$SRC/.." && pwd -P)
export FM_ADDONS_DIR
printf '#!/bin/sh\n# parked-homes/bin/fm-parked-homes-lib.sh\n' >"$home/bin/fm-parked-homes-lib.sh"
printf '# fixture parked state\n' >"$home/config/parked-homes"
before=$(find "$home" -type f -exec sha256sum {} + | sort)
"$SRC/install.sh" "$home" >/dev/null
"$SRC/uninstall.sh" "$home" >/dev/null
"$SRC/uninstall.sh" "$home" >/dev/null
after=$(find "$home" -type f -exec sha256sum {} + | sort)
[ "$after" = "$before" ] || { echo 'FAIL: verify-only install/uninstall changed home state' >&2; exit 1; }
echo 'PASS parked-homes verify-only uninstall'
