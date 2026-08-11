#!/usr/bin/env bash

fm_process_ps_environ() {
  local pid=$1 command dump rest
  command=$(ps ww -o command= -p "$pid" 2>/dev/null) || return 1
  dump=$(ps eww -o command= -p "$pid" 2>/dev/null) || return 1
  case "$command" in
    ''|*$'\n'*) return 1 ;;
  esac
  case "$dump" in
    ''|*$'\n'*) return 1 ;;
  esac
  case "$dump" in
    "$command"*) rest=${dump#"$command"} ;;
    *) return 1 ;;
  esac
  case "$rest" in
    [[:space:]]*) rest=${rest#"${rest%%[![:space:]]*}"} ;;
    *) return 1 ;;
  esac
  [ -n "$rest" ] || return 1
  printf '%s' "$rest"
}

fm_process_ps_environ_records() {
  local pid=$1 dump
  dump=$(fm_process_ps_environ "$pid") || return 1
  printf '%s\n' "$dump" | awk '
    {
      if (NR != 1 || $0 !~ /^[A-Za-z_][A-Za-z0-9_]*=/) exit 1
      rest = $0
      while (match(rest, /[[:space:]][[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/)) {
        record = substr(rest, 1, RSTART - 1)
        if (record !~ /^[A-Za-z_][A-Za-z0-9_]*=/) exit 1
        print record
        rest = substr(rest, RSTART)
        sub(/^[[:space:]]+/, "", rest)
      }
      if (rest !~ /^[A-Za-z_][A-Za-z0-9_]*=/) exit 1
      print rest
    }
  '
}

fm_process_environ() {
  local pid=$1 entry records
  local -a entries=()
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ -r "/proc/$pid/environ" ]; then
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
    [ "${#entries[@]}" -gt 0 ] || return 1
    printf '%s\n' "${entries[@]}"
    return 0
  fi
  records=$(fm_process_ps_environ_records "$pid") || return 1
  [ -n "$records" ] || return 1
  printf '%s\n' "$records"
}

fm_process_env_value() {
  local pid=$1 key=$2 entry records value
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$key" in
    ''|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  if [ -r "/proc/$pid/environ" ]; then
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
  fi
  records=$(fm_process_ps_environ_records "$pid") || return 1
  value=$(printf '%s\n' "$records" | awk -v key="$key" '
    index($0, key "=") == 1 {
      found++
      candidate = substr($0, length(key) + 2)
    }
    END {
      if (found != 1) exit 1
      printf "%s", candidate
    }
  ') || return 1
  printf '%s' "$value"
}
