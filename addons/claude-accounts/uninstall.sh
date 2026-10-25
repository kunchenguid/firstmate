#!/usr/bin/env bash
# Remove the config/account-pool that install.sh wrote, only when it still names the claude-accounts chooser.
# Usage: uninstall.sh <fm-home>
set -euo pipefail
[ "$#" -eq 1 ] || { echo "usage: uninstall.sh <fm-home>" >&2; exit 2; }
file=$1/config/account-pool
[ -e "$file" ] || { echo "nothing to remove: $file"; exit 0; }
grep -q '^command=.*/claude-accounts/bin/claude-accounts-pick$' "$file" || { echo "error: $file is not the claude-accounts one; leaving it alone" >&2; exit 1; }
rm -f -- "$file"
echo "removed: $file"
