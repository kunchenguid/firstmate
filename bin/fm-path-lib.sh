# shellcheck shell=bash
# Shared physical-directory identity helpers. Usage: . bin/fm-path-lib.sh
#
# Two different path strings can name the SAME physical directory. `pwd -P`
# resolves symlinks, so a symlink alias collapses to one string that a plain
# compare already matches. It does NOT resolve a bind mount (Linux) or a macOS
# firmlink: `/home/x` and `/data00/home/x` bound to the same filesystem object
# survive `pwd -P` as two distinct strings while sharing one (device, inode).
# Firstmate records one alias in a task's metadata and the treehouse worktree
# inventory records the other, so a string-only compare wrongly reports the
# worktree as not treehouse-managed and refuses an otherwise-safe teardown.
# A (device, inode) identity compare closes that gap: same dev:ino is the same
# object, and two genuinely different directories never share dev:ino, so the
# match is never broadened unsafely.

# fm_dir_identity <dir>: print "<device>:<inode>" for an existing directory, or
# fail. `-L` dereferences a symlink so an alias reports its TARGET's identity
# (both BSD and GNU stat report the link's own inode without it); a real
# directory path - what teardown passes after pwd -P, and what a bind alias is -
# is unaffected by -L.
fm_dir_identity() {
  local d=$1
  [ -n "$d" ] && [ -d "$d" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    stat -L -f '%d:%i' "$d" 2>/dev/null
  else
    stat -L -c '%d:%i' "$d" 2>/dev/null
  fi
}

# fm_same_physical_dir <a> <b>: return 0 when a and b name the same directory
# object - whether by identical string, a symlink alias, or a bind/firmlink alias
# that survives pwd -P - and 1 otherwise. A missing directory never matches.
fm_same_physical_dir() {
  local a=$1 b=$2 ida idb
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  ida=$(fm_dir_identity "$a") || return 1
  idb=$(fm_dir_identity "$b") || return 1
  [ -n "$ida" ] && [ "$ida" = "$idb" ]
}
