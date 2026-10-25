#!/usr/bin/env bash
# Install or update route-change: copy it to
# ${XDG_DATA_HOME:-~/.local/share}/fm-route-change/ and link it as
# ~/.local/bin/route-change. Idempotent. Usage: install.sh [--dry-run]
# It reads its route list from the pipeline-quota-failover wrapper, so install
# (or reinstall) that add-on from the same checkout first.
set -euo pipefail
dry=0
[ "${1:-}" = --dry-run ] && dry=1
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/route-change
dest=${XDG_DATA_HOME:-$HOME/.local/share}/fm-route-change/route-change
link=$HOME/.local/bin/route-change
if [ "$dry" = 1 ]; then
  echo "dry-run: would copy $src -> $dest and link $link -> $dest"
  exit 0
fi
mkdir -p "$(dirname "$dest")" "$(dirname "$link")"
cp -p "$src" "$dest"
ln -sfn "$dest" "$link"
echo "installed $dest; run: route-change [--dry-run] <fm-home> <route>"
