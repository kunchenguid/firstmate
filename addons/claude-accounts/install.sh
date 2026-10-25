#!/usr/bin/env bash
# Point one Firstmate home's config/account-pool at the claude-accounts chooser, so every new Claude worker
# shares signed-in accounts in proportion to quota runway. Refuses to replace a different account-pool file.
# Usage: install.sh <fm-home>          Undo: uninstall.sh <fm-home>
set -euo pipefail
[ "$#" -eq 1 ] && [ -d "$1/config" ] || { echo "usage: install.sh <fm-home>" >&2; exit 2; }
home=$(cd "$1" && pwd -P)
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
want=$(printf 'command=%s\nstate=%s\n' "$src/bin/claude-accounts-pick" "$home/state")
file=$home/config/account-pool
if [ -e "$file" ] && [ "$(cat "$file")" != "$want" ]; then
  echo "error: $file already exists and is not the claude-accounts one; leaving it alone" >&2
  exit 1
fi
printf '%s\n' "$want" >"$file"
echo "installed: $file -> $src/bin/claude-accounts-pick"
