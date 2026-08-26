#!/usr/bin/env bash
# Shared process-identity predicates for harness detection and session-lock
# ownership.
# This file is sourced by fm-harness.sh and fm-session-lock-lib.sh and has no
# side effects.

# Return 0 only when the argv text belongs to the real Hermes executable.
# Hermes sets its process name to "hermes", so comm alone is not enough.
fm_process_is_hermes() {
  local args=$1 first second third
  local -a words=()
  read -r -a words <<< "$args"
  [ "${#words[@]}" -gt 0 ] || return 1
  first=$(basename -- "${words[0]}")
  [ "$first" = hermes ] && return 0

  case "$first" in
    python|python[0-9]|python[0-9].[0-9]|python[0-9].[0-9][0-9])
      second=${words[1]:-}
      third=${words[2]:-}
      [ -n "$second" ] && [ "$(basename -- "$second")" = hermes ] && return 0
      [ "$second" = -m ] && [ "$third" = hermes_cli.main ] && return 0
      ;;
  esac
  return 1
}

# Return 0 only for the persistent classic-CLI shape emitted by the supported
# wrapper. ps exposes flattened argv, so this predicate deliberately checks
# stable structural flags rather than trying to reconstruct quoted arguments.
fm_process_is_hermes_primary() {
  local args=" $1 "
  fm_process_is_hermes "$1" || return 1
  case "$args" in *' --cli '*) ;; *) return 1 ;; esac
  case "$args" in *' --no-restore-cwd '*) ;; *) return 1 ;; esac
  case "$args" in
    *' -z '*|*' --oneshot '*|*' --oneshot='*|*' --tui '*|*' --safe-mode '*|\
    *' --ignore-user-config '*|*' --ignore-rules '*|*' --worktree '*|*' -w '*|\
    *' --in '*|*' --in='*|*' --profile '*|*' --profile='*|*' -p '*) return 1 ;;
  esac
  return 0
}
