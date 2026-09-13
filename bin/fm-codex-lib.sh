#!/usr/bin/env bash
# Shared Codex capability probes.
set -u

FM_CODEX_MAX_EFFORT_MIN=0.151.0

fm_codex_version_at_least() {  # <executable> <minimum-version>
  local executable=$1 minimum=$2 output version major minor patch extra
  local min_major min_minor min_patch min_extra
  output=$("$executable" --version 2>/dev/null) || return 1
  version=$(printf '%s\n' "$output" \
    | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' \
    | head -n 1)
  IFS=' ' read -r major minor patch extra <<< "$version"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$minimum"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_codex_supports_max_effort() {  # <executable>
  fm_codex_version_at_least "$1" "$FM_CODEX_MAX_EFFORT_MIN"
}
