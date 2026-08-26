#!/usr/bin/env bash
# Shared process-identity predicates for harness detection and session-lock
# ownership.
# This file is sourced by fm-harness.sh and fm-session-lock-lib.sh and has no
# side effects.

fm_hermes_marker_pid() {  # <state> <root>
  local state=$1 root=$2 marker version digest pid marker_root extra
  marker="$state/.hermes-primary-plugin-loaded"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  version=$(sed -n '1p' "$marker" 2>/dev/null) || return 1
  pid=$(sed -n '2p' "$marker" 2>/dev/null) || return 1
  marker_root=$(sed -n '3p' "$marker" 2>/dev/null) || return 1
  extra=$(sed -n '4p' "$marker" 2>/dev/null) || return 1
  case "$version" in sha256:*) digest=${version#sha256:} ;; *) return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  case "$digest" in *[!0-9a-fA-F]*) return 1 ;; esac
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$marker_root" = "$root" ] && [ -z "$extra" ] || return 1
  printf '%s\n' "$pid"
}

fm_process_is_hermes_primary_pid() {  # <pid> <state> <root>
  local pid=$1 state=$2 root=$3 marker_pid comm base
  marker_pid=$(fm_hermes_marker_pid "$state" "$root") || return 1
  [ "$pid" = "$marker_pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  base=$(basename -- "$comm")
  case "$base" in
    hermes|python|python[0-9]|python[0-9].[0-9]|python[0-9].[0-9][0-9]) return 0 ;;
  esac
  return 1
}

fm_hermes_primary_ancestry_pid() {  # <state> <root>
  local state=$1 root=$2 pid=$$ parent
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    if fm_process_is_hermes_primary_pid "$pid" "$state" "$root"; then
      printf '%s\n' "$pid"
      return 0
    fi
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
    case "$parent" in ''|*[!0-9]*) return 1 ;; esac
    [ "$parent" -gt 1 ] || return 1
    pid=$parent
  done
  return 1
}

fm_hermes_primary_session_matches() {  # <state> <root>
  local state=$1 root=$2 pid lock_pid
  pid=$(fm_hermes_primary_ancestry_pid "$state" "$root") || return 1
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(sed -n '1p' "$state/.lock" 2>/dev/null) || return 1
  [ "$lock_pid" = "$pid" ]
}

fm_hermes_worker_policy_enabled() {  # <home>
  local home=$1 path value extra
  path="$home/state/.hermes-primary-worker-policy"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  value=$(sed -n '1p' "$path" 2>/dev/null) || return 1
  extra=$(sed -n '2p' "$path" 2>/dev/null) || return 1
  [ "$value" = pi-herdr-v1 ] && [ -z "$extra" ]
}
