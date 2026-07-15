# shellcheck shell=bash

fm_axi_version_parts() {
  local output
  command -v chrome-devtools-axi >/dev/null 2>&1 || return 1
  output=$(chrome-devtools-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_axi_isolated_sessions_supported() {
  local parts major minor patch rest
  parts=$(fm_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  major=${parts%% *}
  rest=${parts#* }
  minor=${rest%% *}
  patch=${rest##* }

  [ "$major" -gt 0 ] && return 0
  [ "$major" -eq 0 ] && [ "$minor" -gt 1 ] && return 0
  [ "$major" -eq 0 ] && [ "$minor" -eq 1 ] && [ "$patch" -ge 26 ] && return 0
  return 1
}
