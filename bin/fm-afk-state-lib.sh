#!/usr/bin/env bash

: "${AFK_FLAG_NAME:=.afk}"

afk_flag_path() {
  printf '%s/%s\n' "$1" "$AFK_FLAG_NAME"
}

afk_flag_present() {
  local flag
  flag=$(afk_flag_path "$1")
  [ -e "$flag" ] || [ -L "$flag" ]
}

afk_active() {
  [ -e "$(afk_flag_path "$1")" ]
}

afk_enter() {
  local state flag
  state=$1
  flag=$(afk_flag_path "$state")
  mkdir -p "$state"
  date '+%s' > "$flag"
}

afk_clear_flag() {
  local state flag
  state=$1
  flag=$(afk_flag_path "$state")
  afk_flag_present "$state" || return 0
  if [ -d "$flag" ] && [ ! -L "$flag" ]; then
    rmdir "$flag" 2>/dev/null || true
  else
    rm -f "$flag" 2>/dev/null || true
  fi
  ! afk_flag_present "$state"
}

afk_exit() {
  afk_clear_flag "$1"
}
