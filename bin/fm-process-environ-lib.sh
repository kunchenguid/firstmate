#!/usr/bin/env bash

fm_process_environ() {
  local pid=$1 dump
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -r "/proc/$pid/environ" ] || return 1
  dump=$( { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null ) || return 1
  [ -n "$dump" ] || return 1
  printf '%s' "$dump"
}
