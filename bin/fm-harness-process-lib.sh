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

# Return 0 only for a persistent interactive Hermes primary process.
# One-shot Hermes workers remain valid worker harnesses but cannot own the
# Firstmate primary session lock.
fm_process_is_hermes_primary() {
  local args=$1 first second token start=0 i next
  local profile='' cli=0 tui=0
  local -a words=()
  fm_process_is_hermes "$args" || return 1
  read -r -a words <<< "$args"
  first=$(basename -- "${words[0]}")
  if [ "$first" = hermes ]; then
    start=1
  else
    second=${words[1]:-}
    if [ -n "$second" ] && [ "$(basename -- "$second")" = hermes ]; then
      start=2
    elif [ "$second" = -m ] && [ "${words[2]:-}" = hermes_cli.main ]; then
      start=3
    else
      return 1
    fi
  fi

  for ((i=start; i<${#words[@]}; i++)); do
    token=${words[i]}
    case "$token" in
      -z|--oneshot|--oneshot=*) return 1 ;;
      -p|--profile)
        next=${words[i+1]:-}
        [ "$next" = firstmate ] || return 1
        profile=firstmate
        i=$((i + 1))
        ;;
      --profile=*)
        profile=${token#--profile=}
        [ "$profile" = firstmate ] || return 1
        ;;
      -m|--model|--provider|-t|--toolsets|--resume|-r|--skills|-s|--usage-file)
        [ "$((i + 1))" -lt "${#words[@]}" ] || return 1
        i=$((i + 1))
        ;;
      --model=*|--provider=*|--toolsets=*|--resume=*|--skills=*|--usage-file=*) ;;
      -c|--continue|--continue=*) ;;
      --cli) cli=1 ;;
      --tui) tui=1 ;;
      --no-restore-cwd|--worktree|-w|--accept-hooks|--yolo|--pass-session-id|--ignore-user-config|--ignore-rules|--safe-mode|--dev) ;;
      -*) ;;
      *) return 1 ;;
    esac
  done
  [ "$cli" -eq 1 ] || { [ "$profile" = firstmate ] && [ "$tui" -eq 1 ]; }
}
