#!/usr/bin/env bash

fm_fake_spawn_ack_send() {
  local arg left right state_dir
  state_dir=${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME unset}/state}
  for arg in "$@"; do
    case "$arg" in
      *"printf '%s%s\n'"*)
        left=$(printf '%s\n' "$arg" | sed -n "s/.*printf '%s%s\\\\n' '\([^']*\)' '\([^']*\)'.*/\1/p")
        right=$(printf '%s\n' "$arg" | sed -n "s/.*printf '%s%s\\\\n' '\([^']*\)' '\([^']*\)'.*/\2/p")
        [ -n "$left" ] && [ -n "$right" ] || return 0
        printf '%s\n%s\n' "$left" "$right" > "$state_dir/.fake-spawn-pin-pending"
        ;;
    esac
  done
}

fm_fake_spawn_ack_capture() {
  local state_dir pending left right
  state_dir=${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME unset}/state}
  pending="$state_dir/.fake-spawn-pin-pending"
  [ -f "$pending" ] || return 0
  {
    IFS= read -r left
    IFS= read -r right
  } < "$pending"
  printf '%s%s\n' "$left" "$right"
  rm -f "$pending"
}
