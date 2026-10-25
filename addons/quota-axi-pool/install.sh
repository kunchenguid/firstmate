#!/usr/bin/env bash
# Install as ~/.local/bin/quota-axi; record prior quota-axi as upstream. Usage: install.sh [--dry-run]
set -euo pipefail
dry=0; [ "${1:-}" = --dry-run ] && dry=1
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/bin/quota-axi-pool
[ -f "$src" ] || { echo "install.sh: missing $src" >&2; exit 1; }
dest_dir=${XDG_DATA_HOME:-$HOME/.local/share}/fm-quota-axi-pool
dest=$dest_dir/quota-axi-pool
link=$HOME/.local/bin/quota-axi
upstream_file=$dest_dir/upstream
link_target_file=$dest_dir/link-target
saved=; [ -r "$upstream_file" ] && saved=$(head -n 1 "$upstream_file")
saved_link=; [ -r "$link_target_file" ] && saved_link=$(head -n 1 "$link_target_file")
dest_real=$(readlink -f "$dest" 2>/dev/null || printf '%s\n' "$dest")

ours=0
if [ -L "$link" ] || [ -e "$link" ]; then
  link_real=$(readlink -f "$link" 2>/dev/null || printf '%s\n' "$link")
  [ "$link_real" = "$dest_real" ] && ours=1
fi

real=; orig_link=
if [ "$ours" = 1 ]; then
  real=${saved:-}
  orig_link=${saved_link:-}
else
  if [ -L "$link" ]; then
    real=$(readlink -f "$link" 2>/dev/null || true)
    orig_link=$(readlink -- "$link")
  elif [ -e "$link" ]; then
    echo "install.sh: $link exists and is not a symlink (refusing; left unchanged)" >&2
    exit 1
  else
    current=
    command -v quota-axi >/dev/null 2>&1 && current=$(command -v quota-axi)
    if [ -n "$current" ]; then
      cur_real=$(readlink -f "$current" 2>/dev/null || printf '%s\n' "$current")
      if [ "$cur_real" != "$dest_real" ]; then
        real=$cur_real
        orig_link=$current
      fi
    fi
    [ -n "$real" ] || real=${saved:-}
    [ -n "$orig_link" ] || orig_link=${saved_link:-}
  fi
fi

if [ -z "$real" ] || [ ! -x "$real" ]; then
  echo "install.sh: no upstream quota-axi found (refusing; left $link unchanged)" >&2
  exit 1
fi
# Never record our wrapper as upstream.
real_resolved=$(readlink -f "$real" 2>/dev/null || printf '%s\n' "$real")
if [ "$real_resolved" = "$dest_real" ]; then
  echo "install.sh: resolved upstream is our wrapper (refusing; left $link unchanged)" >&2
  exit 1
fi

if [ "$dry" = 1 ]; then
  echo "dry-run: copy $src -> $dest; link $link; upstream=$real; link-target=${orig_link:-unset}"
  exit 0
fi
mkdir -p "$dest_dir" "$(dirname "$link")"
install -m 755 "$src" "$dest"
printf '%s\n' "$real" >"$upstream_file"
[ -n "$orig_link" ] && printf '%s\n' "$orig_link" >"$link_target_file"
ln -sfn "$dest" "$link"
echo "installed $dest; linked $link (upstream=$real)"
