#!/usr/bin/env bash

fm_lavish_version_compatible() {  # <version-output> [allow-empty]
  local output=$1 allow_empty=${2:-0} parts major minor patch extra
  if [ -z "$output" ]; then
    [ "$allow_empty" = 1 ]
    return
  fi
  parts=$(printf '%s\n' "$output" \
    | sed -nE 's/^lavish-axi ([0-9]+)\.([0-9]+)\.([0-9]+) \(store-forward protocol 1\)$/\1 \2 \3/p')
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  [ "$major" -eq 1 ] || return 1
  [ "$minor" -ge 1 ]
}
