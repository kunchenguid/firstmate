#!/usr/bin/env bash

fm_process_environ() {
  local pid=$1 dump parsed
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ -r "/proc/$pid/environ" ]; then
    dump=$( { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null ) || return 1
    [ -n "$dump" ] || return 1
    printf '%s' "$dump"
    return 0
  fi
  command -v ps >/dev/null 2>&1 || return 1
  dump=$(ps eww -p "$pid" -o command= 2>/dev/null) || return 1
  [ -n "$dump" ] || return 1
  parsed=$(printf '%s\n' "$dump" | awk '
    {
      line = $0
      while (match(line, /(^|[[:space:]])(FM_[A-Za-z0-9_]+|STATE)=/)) {
        key_start = RSTART
        if (substr(line, key_start, 1) == " ") key_start++
        token = substr(line, key_start, RLENGTH - (key_start - RSTART))
        key = substr(token, 1, length(token) - 1)
        rest = substr(line, RSTART + RLENGTH)
        if (match(rest, /[[:space:]](FM_[A-Za-z0-9_]+|STATE)=/)) {
          value = substr(rest, 1, RSTART - 1)
          line = substr(rest, RSTART + 1)
        } else {
          value = rest
          line = ""
        }
        print key "=" value
      }
    }
  ')
  if [ -n "$parsed" ]; then
    printf '%s' "$parsed"
  else
    printf '%s' '__FM_PROCESS_ENV__=unavailable'
  fi
}
