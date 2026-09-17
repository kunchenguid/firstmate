#!/usr/bin/env bash
# shellcheck disable=SC2034 # Error and legacy-session globals are outputs for sourcing callers.
# Shared validation and naming for Herdr sessions used by remote second mates.
#
# Herdr 0.9.0 accepts session names of at most 64 bytes containing only ASCII
# letters, numbers, dots, underscores, and dashes, except the path components
# "." and "..". Remote second mates additionally refuse "default" because that
# session belongs to the remote account's interactive work.
#
# A missing per-route session remains the legacy fm-remote lane.

FM_REMOTE_HERDR_LEGACY_SESSION=fm-remote
FM_HERDR_SESSION_ERROR=

fm_herdr_session_validate() { # <session>
  local session=${1:-}
  FM_HERDR_SESSION_ERROR=
  if [ -z "$session" ]; then
    FM_HERDR_SESSION_ERROR="Herdr session name cannot be empty"
    return 1
  fi
  if [ "${#session}" -gt 64 ]; then
    FM_HERDR_SESSION_ERROR="Herdr session name cannot be longer than 64 bytes"
    return 1
  fi
  case "$session" in
    .|..)
      FM_HERDR_SESSION_ERROR="Herdr session name cannot be . or .."
      return 1
      ;;
    *[!A-Za-z0-9._-]*)
      FM_HERDR_SESSION_ERROR="Herdr session name may contain only ASCII letters, numbers, dots, underscores, and dashes"
      return 1
      ;;
  esac
  return 0
}

fm_remote_herdr_session_validate() { # <session>
  fm_herdr_session_validate "$1" || return 1
  if [ "$1" = default ]; then
    FM_HERDR_SESSION_ERROR="remote second mates cannot use Herdr's interactive default session"
    return 1
  fi
  return 0
}

fm_remote_herdr_session_or_legacy() { # [session]
  local session=${1:-$FM_REMOTE_HERDR_LEGACY_SESSION}
  fm_remote_herdr_session_validate "$session" || return 1
  printf '%s\n' "$session"
}

fm_remote_herdr_launch_agent_label() { # <session>
  fm_remote_herdr_session_validate "$1" || return 1
  printf 'dev.firstmate.herdr.%s\n' "$1"
}
