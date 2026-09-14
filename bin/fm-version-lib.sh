#!/usr/bin/env bash
# Shared semantic-version comparison.
set -u

tool_version_at_least() {  # <tool-or-executable> <minimum-version>
  local tool=$1 min=$2 output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  case "$tool" in
    */*) [ -x "$tool" ] || return 1 ;;
    *) command -v "$tool" >/dev/null 2>&1 || return 1 ;;
  esac
  output=$("$tool" --version 2>/dev/null) || return 1
  parts=$(printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$min"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}
