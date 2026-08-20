#!/usr/bin/env bash

fm_brief_publication_lock_path() {
  printf '%s/.brief-%s.lock\n' "$1" "$2"
}

fm_brief_replace_staged() {
  case "${OSTYPE:-}" in
    darwin*)
      perl -e 'rename($ARGV[0], $ARGV[1]) or die "error: cannot replace $ARGV[1]: $!\n"' -- "$1" "$2" || return 1
      ;;
    linux*) mv -fT -- "$1" "$2" ;;
    *) echo "error: unsupported platform for no-follow brief replacement: ${OSTYPE:-unknown}" >&2; return 1 ;;
  esac
}

fm_brief_snapshot() {
  local source=$1 destination=$2 dir base staged
  [ -f "$source" ] || {
    echo "error: brief snapshot source is not a regular file: $source" >&2
    return 1
  }
  dir=${destination%/*}
  base=${destination##*/}
  [ -d "$dir" ] || {
    echo "error: brief snapshot directory is unavailable: $dir" >&2
    return 1
  }
  staged=$(mktemp "$dir/.$base.XXXXXX") || return 1
  if ! cp -p -- "$source" "$staged"; then
    rm -f -- "$staged"
    return 1
  fi
  if ! fm_brief_replace_staged "$staged" "$destination"; then
    rm -f -- "$staged"
    return 1
  fi
}
