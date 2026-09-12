#!/usr/bin/env bash
# Shared executable contract for command-level mutation guards.
#
# This library is deliberately side-effect free. Commands own the locks and
# mutation boundaries; this file owns only the immutable v1 capability table,
# its exact proof serializer, and optional caller-binding comparisons.

FM_COMMAND_GUARD_SCHEMA='fm-command-guard-proof.v1'
readonly FM_COMMAND_GUARD_SCHEMA

declare -ar FM_COMMAND_GUARD_TABLE=(
  'send|spawn-generation|FM_SEND_EXPECTED_SPAWN_GEN'
  'send|endpoint|FM_SEND_EXPECTED_ENDPOINT'
  'send|remote-host|FM_SEND_EXPECTED_REMOTE_HOST'
  'control|spawn-generation|FM_CONTROL_EXPECTED_SPAWN_GEN'
)

fm_command_guard_supported_command() {  # <command>
  case "$1" in
    send|control) return 0 ;;
    *) return 1 ;;
  esac
}

fm_command_guard_table_row() {  # <command> <guard>
  local command=$1 guard=$2 row row_command row_guard
  for row in "${FM_COMMAND_GUARD_TABLE[@]}"; do
    IFS='|' read -r row_command row_guard _ <<< "$row"
    if [ "$row_command" = "$command" ] && [ "$row_guard" = "$guard" ]; then
      printf '%s' "$row"
      return 0
    fi
  done
  return 1
}

fm_command_guard_has() {  # <command> <guard>
  fm_command_guard_table_row "$1" "$2" >/dev/null
}

fm_command_guard_expected_env() {  # <command> <guard>
  local row
  row=$(fm_command_guard_table_row "$1" "$2") || return 1
  printf '%s' "${row##*|}"
}

fm_command_guard_emit() {  # <command>
  local command=$1 row row_command row_guard first=1
  fm_command_guard_supported_command "$command" || return 1
  printf '{"schema":"%s","command":"%s","verified":true,"guards":[' \
    "$FM_COMMAND_GUARD_SCHEMA" "$command"
  for row in "${FM_COMMAND_GUARD_TABLE[@]}"; do
    IFS='|' read -r row_command row_guard _ <<< "$row"
    [ "$row_command" = "$command" ] || continue
    if [ "$first" = 0 ]; then
      printf ','
    fi
    printf '"%s"' "$row_guard"
    first=0
  done
  printf ']}\n'
}

fm_command_guard_probe_preflight() {  # <home> <state-dir>
  local home=$1 state=$2 meta
  [ -d "$home" ] && [ -r "$home" ] && [ -x "$home" ] || return 1
  [ -d "$state" ] && [ -r "$state" ] && [ -x "$state" ] || return 1
  for meta in "$state"/*.meta; do
    if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
      continue
    fi
    [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || return 1
  done
}

fm_command_guard_check_optional() {  # <command> <guard> <current-value>
  local command=$1 guard=$2 current=$3 env_name expected
  fm_command_guard_expected_env "$command" "$guard" >/dev/null || return 2
  env_name=$(fm_command_guard_expected_env "$command" "$guard") || return 2
  expected=${!env_name-}
  [ -n "$expected" ] || return 0
  [ -n "$current" ] && [ "$current" = "$expected" ]
}
