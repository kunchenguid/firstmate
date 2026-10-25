#!/usr/bin/env bash
# Remove PATH link and share dir files; restore prior link when recorded. Usage: uninstall.sh [--dry-run]
set -euo pipefail
dry=0; [ "${1:-}" = --dry-run ] && dry=1
dest_dir=${XDG_DATA_HOME:-$HOME/.local/share}/fm-quota-axi-pool
dest=$dest_dir/quota-axi-pool
link=$HOME/.local/bin/quota-axi
upstream_file=$dest_dir/upstream
link_target_file=$dest_dir/link-target
real=; [ -r "$upstream_file" ] && real=$(head -n 1 "$upstream_file")
orig_link=; [ -r "$link_target_file" ] && orig_link=$(head -n 1 "$link_target_file")
if [ "$dry" = 1 ]; then
  echo "dry-run: remove wrapper at $link; restore link-target=${orig_link:-none}; remove $dest_dir"
  exit 0
fi
if [ -L "$link" ]; then
  target=$(readlink -f "$link" 2>/dev/null || true)
  dest_real=$(readlink -f "$dest" 2>/dev/null || true)
  if [ "$target" = "$dest_real" ]; then
    rm -f -- "$link"
    if [ -n "$orig_link" ]; then
      ln -sfn -- "$orig_link" "$link"
    fi
  fi
fi
[ -d "$dest_dir" ] && { rm -f -- "$dest" "$upstream_file" "$link_target_file"; rmdir -- "$dest_dir" 2>/dev/null || true; }
echo "uninstalled quota-axi-pool from $link"
if [ -n "$orig_link" ]; then
  echo "restored $link -> $orig_link"
elif [ -n "$real" ] && [ -x "$real" ]; then
  echo "upstream remains at $real"
fi
