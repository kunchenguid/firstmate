#!/usr/bin/env bash
set -u

MODE=${1:-}
shift || exit 2

path_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

validate_control() {
  [ -d "$CONTROL" ] && [ -O "$CONTROL" ] && [ ! -L "$CONTROL" ] || return 1
  [ "$(path_mode "$CONTROL")" = 700 ] || return 1
  for path in "$CAPTURE" "$LIVE"; do
    [ -f "$path" ] && [ -O "$path" ] && [ ! -L "$path" ] || return 1
    [ "$(path_mode "$path")" = 600 ] || return 1
  done
}

clear_busy() {
  printf '\r\033[2K'
}

cleanup_control() {
  rm -f "$CAPTURE" "$LIVE"
  rmdir "$CONTROL" 2>/dev/null || true
}

case "$MODE" in
  marker)
    [ "$#" -eq 1 ] || exit 2
    CONTROL=$1
    CAPTURE="$CONTROL/capture"
    LIVE="$CONTROL/live"
    validate_control || exit 1
    trap clear_busy EXIT INT TERM
    BOOTSTRAP_PID=
    for _ in $(seq 1 50); do
      BOOTSTRAP_PID=$(sed -n 's/^bootstrap=//p' "$LIVE" | tail -1)
      case "$BOOTSTRAP_PID" in
        ''|*[!0-9]*) ;;
        *) break ;;
      esac
      sleep 0.02
    done
    case "$BOOTSTRAP_PID" in
      ''|*[!0-9]*) exit 1 ;;
    esac
    while kill -0 "$BOOTSTRAP_PID" 2>/dev/null; do
      printf '\r\360\237\214\221 · Kimi prompt bootstrap'
      sleep 0.1
    done
    ;;
  finish)
    [ "$#" -ge 3 ] || exit 2
    KIMI_STATUS=$1
    BIN=$2
    CONTROL=$3
    shift 3
    MODEL_ARGS=()
    if [ "${1:-}" = --model ]; then
      [ "$#" -eq 2 ] || exit 2
      MODEL_ARGS=(--model "$2")
      shift 2
    fi
    [ "$#" -eq 0 ] || exit 2
    CAPTURE="$CONTROL/capture"
    LIVE="$CONTROL/live"
    [ -x "$BIN" ] || exit 1
    validate_control || exit 1
    trap cleanup_control EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$KIMI_STATUS" -ne 0 ]; then
      cat "$CAPTURE" >&2
      exit "$KIMI_STATUS"
    fi
    cat "$CAPTURE"
    SESSION_ID=$(sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p' "$CAPTURE" | tail -1)
    [ -n "$SESSION_ID" ] || {
      echo "error: kimi prompt bootstrap did not emit session_id" >&2
      exit 1
    }
    cleanup_control
    trap - EXIT INT TERM
    exec "$BIN" --auto "${MODEL_ARGS[@]}" -S "$SESSION_ID"
    ;;
  *)
    exit 2
    ;;
esac
