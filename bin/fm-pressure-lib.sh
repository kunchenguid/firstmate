#!/usr/bin/env bash
# Passive host pressure and spawn-backpressure helpers.
#
# This library is substrate only.
# Nothing here changes spawn behavior unless a caller explicitly consults it.

fm_pressure_config_value() {  # <config-file> <key> [default]
  local cfg=$1 key=$2 default=${3:-} value
  [ -f "$cfg" ] || { printf '%s\n' "$default"; return 0; }
  value=$(awk -F= -v key="$key" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      k=$1
      sub(/^[[:space:]]+/, "", k)
      sub(/[[:space:]]+$/, "", k)
      if (k == key) {
        v=$0
        sub(/^[^=]*=/, "", v)
        sub(/^[[:space:]]+/, "", v)
        sub(/[[:space:]]+$/, "", v)
        found=1
      }
    }
    END { if (found) print v }
  ' "$cfg")
  printf '%s\n' "${value:-$default}"
}

fm_pressure_enabled() {  # <config-file>
  local value
  value=$(fm_pressure_config_value "$1" host-pressure off)
  case "$value" in
    on|true|yes|1) return 0 ;;
    *) return 1 ;;
  esac
}

fm_pressure_numeric_or_empty() {  # <value> <label>
  local value=$1 label=$2
  case "$value" in
    ''|*[!0-9]*)
      [ -z "$value" ] || echo "error: $label must be a non-negative integer" >&2
      [ -z "$value" ]
      ;;
    *) return 0 ;;
  esac
}

fm_pressure_now_epoch() {
  if [ -n "${FM_PRESSURE_NOW_EPOCH:-}" ]; then
    printf '%s\n' "$FM_PRESSURE_NOW_EPOCH"
  else
    date +%s
  fi
}

fm_pressure_memory_available_mb() {
  if [ -n "${FM_PRESSURE_MEMORY_AVAILABLE_MB:-}" ]; then
    printf '%s\n' "$FM_PRESSURE_MEMORY_AVAILABLE_MB"
    return 0
  fi

  if [ -r /proc/meminfo ]; then
    awk '/^MemAvailable:/ { print int($2 / 1024); found=1 } END { exit found ? 0 : 1 }' /proc/meminfo && return 0
  fi

  if command -v vm_stat >/dev/null 2>&1 && command -v sysctl >/dev/null 2>&1; then
    vm_stat | awk '
      /page size of/ {
        page=$8
        gsub(/\./, "", page)
      }
      /^Pages free:/ {
        v=$3
        gsub(/\./, "", v)
        free=v
      }
      /^Pages inactive:/ {
        v=$3
        gsub(/\./, "", v)
        inactive=v
      }
      /^Pages speculative:/ {
        v=$3
        gsub(/\./, "", v)
        speculative=v
      }
      END {
        if (page > 0) {
          print int(((free + inactive + speculative) * page) / 1048576)
        } else {
          exit 1
        }
      }
    ' && return 0
  fi

  printf 'unknown\n'
}

fm_pressure_disk_available_mb() {  # <path>
  local path=$1
  if [ -n "${FM_PRESSURE_DISK_AVAILABLE_MB:-}" ]; then
    printf '%s\n' "$FM_PRESSURE_DISK_AVAILABLE_MB"
    return 0
  fi
  df -Pk "$path" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024); found=1 } END { exit found ? 0 : 1 }' || printf 'unknown\n'
}

fm_pressure_running_tasks() {  # <state-dir>
  local state=$1 meta count
  if [ -n "${FM_PRESSURE_RUNNING_TASKS:-}" ]; then
    printf '%s\n' "$FM_PRESSURE_RUNNING_TASKS"
    return 0
  fi
  count=0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    grep -q '^window=' "$meta" 2>/dev/null || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

fm_pressure_safe_transient_candidates() {  # <home>
  local home=$1
  printf 'transient_candidate=%s\n' "${TMPDIR:-/tmp}/fm-*"
  printf 'transient_candidate=%s\n' "$home/state/.watch-triage.log"
  printf 'transient_candidate=%s\n' "$home/.no-mistakes/"
}

fm_pressure_shed_classify_command() {  # <command-line>
  local cmd=$1
  case "$cmd" in
    *"bash tests/"*.test.sh*|*"for test_script in tests/"*.test.sh*|*"bin/fm-lint.sh"*|*"shellcheck "*)
      printf 'eligible=restartable_compute\n'
      printf 'reason=validation_or_test_process\n'
      ;;
    *)
      printf 'eligible=no\n'
      printf 'reason=not_known_restartable_compute\n'
      ;;
  esac
}
