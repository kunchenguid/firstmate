#!/usr/bin/env bash
# Run chrome-devtools-axi through a durable isolated session.
# Usage: fm-axi-isolated.sh <session-file> <chrome-devtools-axi command> [args...]
set -u

[ $# -ge 2 ] || {
  echo "usage: fm-axi-isolated.sh <session-file> <chrome-devtools-axi command> [args...]" >&2
  exit 1
}

SESSION_FILE=$1
shift
COMMAND=$1

[ ! -L "$SESSION_FILE" ] || {
  echo "error: session file must not be a symlink: $SESSION_FILE" >&2
  exit 1
}

session_is_valid() {
  [[ "$1" =~ ^firstmate-isolated-[A-Za-z0-9._-]{1,44}$ ]]
}

read_session() {
  local session extra
  IFS= read -r session < "$SESSION_FILE" || return 1
  IFS= read -r extra < <(sed -n '2p' "$SESSION_FILE") || true
  [ -z "$extra" ] || return 1
  session_is_valid "$session" || return 1
  printf '%s\n' "$session"
}

create_session() {
  local session tmp parent
  parent=$(dirname "$SESSION_FILE")
  mkdir -p "$parent" || return 1
  session="firstmate-isolated-$(node -e 'process.stdout.write(require("node:crypto").randomUUID())')" || return 1
  session_is_valid "$session" || return 1
  umask 077
  tmp=$(mktemp "${SESSION_FILE}.XXXXXX") || return 1
  if ! printf '%s\n' "$session" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ln "$tmp" "$SESSION_FILE" 2>/dev/null; then
    rm -f "$tmp"
    printf '%s\n' "$session"
    return 0
  fi
  rm -f "$tmp"
  read_session
}

if [ -e "$SESSION_FILE" ]; then
  SESSION=$(read_session) || {
    echo "error: invalid AXI session file: $SESSION_FILE" >&2
    exit 1
  }
else
  SESSION=$(create_session) || {
    echo "error: cannot create AXI session file: $SESSION_FILE" >&2
    exit 1
  }
fi

env -u CHROME_DEVTOOLS_AXI_AUTO_CONNECT \
  -u CHROME_DEVTOOLS_AXI_BROWSER_URL \
  -u CHROME_DEVTOOLS_AXI_USER_DATA_DIR \
  -u CHROME_DEVTOOLS_AXI_CHROME_ARGS \
  -u CHROME_DEVTOOLS_AXI_PORT \
  -u CHROME_DEVTOOLS_AXI_SESSION \
  -u CHROME_DEVTOOLS_AXI_WS_HEADERS \
  -u CHROME_DEVTOOLS_AXI_MCP_PATH \
  CHROME_DEVTOOLS_AXI_SESSION="$SESSION" \
  chrome-devtools-axi "$@"
STATUS=$?

if [ "$COMMAND" = stop ] && [ "$STATUS" -eq 0 ]; then
  rm -f "$SESSION_FILE" || exit 1
fi

exit "$STATUS"
