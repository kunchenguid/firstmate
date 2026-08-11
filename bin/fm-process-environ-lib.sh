#!/usr/bin/env bash

fm_process_environ_supported() {
  [ "$(uname -s 2>/dev/null)" = Linux ] && [ -d /proc ]
}

fm_process_environ() {
  local pid=$1 entry
  local -a entries=()
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_process_environ_supported || return 1
  [ -r "/proc/$pid/environ" ] || return 1
  if ! {
    while IFS= read -r -d '' entry; do
      case "$entry" in
        *$'\n'*) return 1 ;;
      esac
      entries+=("$entry")
    done < "/proc/$pid/environ"
  } 2>/dev/null; then
    return 1
  fi
  if [ "${#entries[@]}" -gt 0 ]; then
    printf '%s\n' "${entries[@]}"
  fi
  return 0
}

fm_process_env_value() {
  local pid=$1 key=$2 entry
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$key" in
    ''|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  fm_process_environ_supported || return 1
  [ -r "/proc/$pid/environ" ] || return 1
  if ! {
    while IFS= read -r -d '' entry; do
      case "$entry" in
        "$key"=*)
          printf '%s' "${entry#"$key"=}"
          return 0
          ;;
      esac
    done < "/proc/$pid/environ"
  } 2>/dev/null; then
    return 1
  fi
  return 1
}
