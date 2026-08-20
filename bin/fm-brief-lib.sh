#!/usr/bin/env bash

# shellcheck disable=SC2034 # Read by scripts that source this library.
FM_BRIEF_SCAFFOLD_MARKER='<!-- firstmate:generated-brief-scaffold:v1 -->'

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

fm_brief_copy_atomic() {
  local source=$1 destination=$2 dir base staged
  [ -f "$source" ] && [ ! -L "$source" ] || {
    echo "error: brief publication source is not a regular file: $source" >&2
    return 1
  }
  dir=${destination%/*}
  base=${destination##*/}
  [ -d "$dir" ] || {
    echo "error: brief publication directory is unavailable: $dir" >&2
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

fm_brief_snapshot() {
  fm_brief_copy_atomic "$@"
}

fm_brief_copy_locked() {
  local state=$1 id=$2 source=$3 destination=$4 lock status=0
  lock=$(fm_brief_publication_lock_path "$state" "$id") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  fm_brief_copy_atomic "$source" "$destination" || status=$?
  fm_lock_release "$lock" || {
    [ "$status" -ne 0 ] || status=1
  }
  return "$status"
}

fm_brief_restore_if_matches_locked() {
  local state=$1 id=$2 expected=$3 replacement=$4 destination=$5 lock status=0
  lock=$(fm_brief_publication_lock_path "$state" "$id") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  if [ -f "$destination" ] && [ ! -L "$destination" ] \
     && cmp -s "$expected" "$destination"; then
    if [ -n "$replacement" ]; then
      fm_brief_copy_atomic "$replacement" "$destination" || status=$?
    else
      rm -f -- "$destination" || status=$?
    fi
  else
    status=2
  fi
  fm_lock_release "$lock" || {
    [ "$status" -ne 0 ] || status=1
  }
  return "$status"
}
