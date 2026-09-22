#!/usr/bin/env bash

fm_muse_task_binary_path() {
  local state=$1 id=$2 name=$3 suffix
  case "$name" in
  "muse-bin-$id" | "$id.muse-bin") ;;
  "muse-bin-$id+"*)
    suffix=${name#"muse-bin-$id+"}
    case "$suffix" in
    '' | *[!A-Za-z0-9]*) return 1 ;;
    esac
    ;;
  *) return 1 ;;
  esac
  printf '%s/%s\n' "$state" "$name"
}

fm_muse_cleanup_task_binaries() {
  local state=$1 id=$2 keep_name=${3:-} path name expected failed=0
  if [ -n "$keep_name" ]; then
    fm_muse_task_binary_path "$state" "$id" "$keep_name" >/dev/null || return 1
  fi
  for path in "$state/muse-bin-$id" "$state/muse-bin-$id"+* "$state/$id.muse-bin"; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    name=${path##*/}
    [ "$name" != "$keep_name" ] || continue
    expected=$(fm_muse_task_binary_path "$state" "$id" "$name") || return 1
    [ "$expected" = "$path" ] || return 1
    rm -f -- "$path" || failed=1
  done
  [ "$failed" -eq 0 ]
}
