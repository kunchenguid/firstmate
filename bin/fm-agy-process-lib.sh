#!/usr/bin/env bash
# agy (Antigravity CLI / Antigravity ACP) process identity, shared by harness
# detection and the session-lock ancestry walk. This file has no side effects
# on source.
#
# Antigravity runs under two verified shapes:
#   - the standalone Antigravity CLI binary, whose process name is exactly `agy`
#     (verified, agy 1.2.0+);
#   - T3 Code's bundled Antigravity ACP server, whose executable is named
#     `antigravity` and is invoked with `acp` as its first argument
#     (verified live on macOS, antigravity 1.5.14:
#     ~/.t3/tools/antigravity-acp/<arch>/versions/<hash>/antigravity acp ...).
# Match the exact `agy` name, or exact `antigravity` whose first argument is
# `acp`. Rebuild a space-containing executable path when ps prints argv
# space-joined, stopping before any option or separate absolute-path argument.
# Anchored throughout, so Electron Antigravity.app processes (`Antigravity`,
# `Antigravity Helper`), unrelated `magyk` commands, and plain `antigravity`
# invocations without `acp` never match.
fm_agy_acp_process_matches() {  # <comm> <args>
  local comm=${1:-} args=${2:-} i n exe
  local words=()
  case "${comm##*/}" in
    antigravity) ;;
    *) return 1 ;;
  esac
  case "$comm" in
    */*)
      case "$args" in
        "$comm acp"|"$comm acp "*) return 0 ;;
      esac
      ;;
  esac
  read -r -a words <<< "$args"
  n=${#words[@]}
  [ "$n" -ge 2 ] || return 1
  exe=${words[0]}
  i=1
  while [ "$i" -lt "$n" ] && [ "${exe##*/}" != antigravity ]; do
    case "${words[i]}" in
      -*|/*) return 1 ;;
    esac
    exe="$exe ${words[i]}"
    i=$((i + 1))
  done
  [ "${exe##*/}" = antigravity ] && [ "$i" -lt "$n" ] && [ "${words[i]}" = acp ]
}

fm_agy_process_matches() {  # <comm> <args>
  local comm=${1:-} args=${2:-}
  case "${comm##*/}" in
    agy) return 0 ;;
  esac
  fm_agy_acp_process_matches "$comm" "$args"
}

# Walk up to 16 parent hops (matching bin/fm-harness.sh and
# bin/fm-session-lock-lib.sh) and return 0 iff the nearest agy ancestor is
# antigravity acp rather than standalone agy CLI.
fm_agy_acp_in_ancestry() {  # [<pid>]
  local pid=${1:-$$} comm args
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null) || args=
    if fm_agy_acp_process_matches "$comm" "$args"; then
      return 0
    fi
    if fm_agy_process_matches "$comm" "$args"; then
      return 1
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    [ "$pid" -ge 1 ] || return 1
  done
  return 1
}
