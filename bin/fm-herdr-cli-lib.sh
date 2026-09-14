#!/usr/bin/env bash
# Shared Herdr argv transport. Every call explicitly selects <session> before
# the first -- separator, or at the end when no separator exists. Never rely
# on HERDR_SESSION alone: older clients can silently choose the default server.
# Caller authorization and allowed operations belong to the backend/lab owner.
fm_herdr_scoped_cli() { # <session> <herdr arguments...>
  local session=$1 arg inserted=0
  local args=()
  shift
  for arg in "$@"; do
    if [ "$arg" = -- ] && [ "$inserted" -eq 0 ]; then
      args+=(--session "$session")
      inserted=1
    fi
    args+=("$arg")
  done
  [ "$inserted" -eq 1 ] || args+=(--session "$session")
  HERDR_SESSION="$session" herdr "${args[@]}"
}
