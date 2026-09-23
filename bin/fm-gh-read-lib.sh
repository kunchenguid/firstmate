#!/usr/bin/env bash
# Protected-path checks for the Cursor worker GitHub read helper.
# Sourced by bin/fm-spawn.sh and bin/fm-gh-read.sh. This file is sourced by
# scripts and has no side effects on source.
#
# The helper itself (bin/native/fm-gh-read.c) is the authority-bearing part:
# it is enrolled as an Automic Vault Launcher Bundle and exposes only a closed
# read API. This library owns the one routing decision Firstmate makes about
# it: whether a Cursor ship or scout launch prepends the protected router
# PATH directory. The router sends accepted closed reads from `gh` or
# gh-axi's execFile("gh") to the enrolled helper and every other shape to the
# generic attended GitHub CLI path.
#
# The directory is routing, never authority. It is honored only when every
# path component, the `gh` router, and every hop its helper target resolves through is
# owned by root and not writable by group or others, so a same-user process
# cannot swap what a Cursor worker's `gh` reaches. An absent directory leaves
# the launch unchanged; a present directory that fails any check refuses the
# launch rather than silently falling back.
#
# FM_GH_READ_CURSOR_DIR_OVERRIDE is a test seam: it names a different
# directory and requires the current user, instead of root, to own it. It
# grants nothing, because routing to a user-owned `gh` only reaches what that
# user could already run.

FM_GH_READ_CURSOR_DIR_DEFAULT=/usr/local/libexec/fm-gh-read/cursor-path

# One lstat as "<uid> <octal-mode-bits> <type>", where the mode bits include
# the sticky bit and type is dir, link, file, or other. BSD and GNU stat need
# different syntax, chosen once per call; a fallback chain is unsafe because
# GNU `stat -f` is filesystem stat.
fm_gh_read_lstat() {  # <path>
  local out uid perms kind
  if [ "$(uname)" = Darwin ]; then
    out=$(LC_ALL=C /usr/bin/stat -f '%u %p %HT' -- "$1" 2>/dev/null) || return 1
  else
    out=$(LC_ALL=C stat -c '%u %a %F' -- "$1" 2>/dev/null) || return 1
  fi
  uid=${out%% *}
  out=${out#* }
  perms=$(printf '%o' $((8#${out%% *} & 8#7777)))
  case "${out#* }" in
  Directory | directory) kind=dir ;;
  'Symbolic Link' | 'symbolic link') kind='link' ;;
  'Regular File' | 'regular file' | 'regular empty file') kind='file' ;;
  *) kind=other ;;
  esac
  printf '%s %s %s\n' "$uid" "$perms" "$kind"
}

# Succeeds when <path> and every ancestor directory up to / are owned by
# <uid> or root and, except for symlinks whose mode is meaningless, are not
# group- or other-writable. A root-owned sticky ancestor such as /tmp is
# accepted, because the sticky bit stops other users from replacing an entry
# they do not own. Prints the first offending path on failure.
fm_gh_read_protected_chain() {  # <absolute-path> <uid>
  local path=$1 uid=$2 st owner perms kind
  case "$path" in /*) ;; *)
    printf '%s\n' "$path"
    return 1
    ;;
  esac
  while :; do
    st=$(fm_gh_read_lstat "$path") || {
      printf '%s\n' "$path"
      return 1
    }
    read -r owner perms kind <<EOF
$st
EOF
    if [ "$owner" != "$uid" ] && [ "$owner" != 0 ]; then
      printf '%s\n' "$path"
      return 1
    fi
    if [ "$kind" != link ] && [ $((8#$perms & 8#022)) -ne 0 ] &&
      ! { [ "$kind" = dir ] && [ "$owner" = 0 ] && [ "$path" != "$1" ] &&
        [ $((8#$perms & 8#1000)) -ne 0 ]; }; then
      printf '%s\n' "$path"
      return 1
    fi
    [ "$path" = / ] && return 0
    path=$(dirname -- "$path")
  done
}

# Resolve <link> hop by hop, requiring every hop and its parent chain to be
# protected, and print the final regular executable file.
fm_gh_read_resolve_protected() {  # <absolute-path> <uid>
  local path=$1 uid=$2 hops=0 target st kind bad
  while :; do
    if ! bad=$(fm_gh_read_protected_chain "$path" "$uid"); then
      printf 'not protected: %s\n' "$bad" >&2
      return 1
    fi
    st=$(fm_gh_read_lstat "$path") || return 1
    kind=${st##* }
    case "$kind" in
    file)
      [ -x "$path" ] || {
        printf 'not executable: %s\n' "$path" >&2
        return 1
      }
      printf '%s\n' "$path"
      return 0
      ;;
    link)
      hops=$((hops + 1))
      [ "$hops" -le 8 ] || {
        printf 'too many links: %s\n' "$1" >&2
        return 1
      }
      target=$(readlink -- "$path") || return 1
      case "$target" in
      /*) path=$target ;;
      *) path="$(dirname -- "$path")/$target" ;;
      esac
      ;;
    *)
      printf 'not a file or link: %s\n' "$path" >&2
      return 1
      ;;
    esac
  done
}

# The Cursor router PATH directory decision.
# Exit 0 prints the verified directory, 1 means it is absent, and 2 means it
# is present but unsafe, with the reason on stderr.
fm_gh_read_cursor_path_dir() {
  local dir uid entries st
  if [ -n "${FM_GH_READ_CURSOR_DIR_OVERRIDE:-}" ]; then
    dir=$FM_GH_READ_CURSOR_DIR_OVERRIDE
    uid=$(id -u)
  else
    dir=$FM_GH_READ_CURSOR_DIR_DEFAULT
    uid=0
  fi
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    return 1
  fi
  st=$(fm_gh_read_lstat "$dir") || {
    printf 'gh read helper directory is unreadable: %s\n' "$dir" >&2
    return 2
  }
  if [ "${st##* }" != dir ]; then
    printf 'gh read helper directory is not a real directory: %s\n' "$dir" >&2
    return 2
  fi
  if ! st=$(fm_gh_read_protected_chain "$dir" "$uid"); then
    printf 'gh read helper directory is not protected at %s\n' "$st" >&2
    return 2
  fi
  entries=$(ls -A -- "$dir" 2>/dev/null) || return 2
  if [ "$entries" != gh ]; then
    printf 'gh read helper directory must contain exactly one entry named gh: %s\n' "$dir" >&2
    return 2
  fi
  st=$(fm_gh_read_lstat "$dir/gh") || return 2
  if [ "${st##* }" != file ] || [ ! -x "$dir/gh" ]; then
    printf 'gh read router is not an executable regular file: %s/gh\n' "$dir" >&2
    return 2
  fi
  printf '%s\n' "$dir"
}
