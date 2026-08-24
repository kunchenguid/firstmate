#!/usr/bin/env bash
# fm-kill-port.sh - free one or more local TCP ports without a fleet-wide pattern kill.
#
# Usage: fm-kill-port.sh <port> [<port> ...]
#        fm-kill-port.sh --boundary <dir> <port> [<port> ...]
#        fm-kill-port.sh --any <port> [<port> ...]
#
# Why this exists: a crewmate that reaches for `pkill -f 'wrangler dev'` cannot tell its own
# server from a sibling worktree's or the captain's, because a name pattern matches every
# checkout on the machine. This kills by PORT instead, and refuses ports whose listener lives
# outside the caller's own tree, so a wrong port number is reported rather than acted on.
#
# Boundary: the caller's git top level, else $PWD. Override with --boundary <dir>.
# A listener whose working directory is not at or under that boundary is REFUSED and named,
# and the command exits non-zero. Pass --any to kill regardless of where the listener lives;
# that flag is for an operator who has already identified the process, never a crewmate default.
#
# A port with no listener is reported and is not an error, so repeated calls are safe.
# Each listener gets TERM first, then KILL only if it is still listening after a short grace.
# Requires lsof.

set -euo pipefail

TERM_GRACE_SECONDS=2

usage() {
  cat >&2 <<'EOF'
usage: fm-kill-port.sh [--boundary <dir>] [--any] <port> [<port> ...]
  Frees local TCP ports by killing their LISTEN owner.
  Refuses a listener rooted outside the boundary (default: this git top level, else $PWD).
  --any  skip the boundary check (operator escape hatch, not a crewmate default)
EOF
}

resolve_boundary() {
  local top
  if top=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ]; then
    printf '%s\n' "$top"
    return 0
  fi
  pwd -P
}

# Absolute, symlink-resolved form of a directory, or empty when it cannot be resolved.
canonical_dir() {
  local dir=$1
  [ -d "$dir" ] || return 0
  (cd "$dir" 2>/dev/null && pwd -P) || true
}

# Working directory of a pid, or empty when it cannot be read.
pid_cwd() {
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1 || true
}

path_within() {
  local boundary=$1 path=$2
  [ -n "$boundary" ] || return 1
  [ -n "$path" ] || return 1
  [ "$boundary" = "$path" ] && return 0
  case "$path" in
    "$boundary"/*) return 0 ;;
    *) return 1 ;;
  esac
}

listeners_on() {
  lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true
}

BOUNDARY=""
SKIP_BOUNDARY=0
PORTS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --boundary)
      [ "$#" -ge 2 ] || { echo "error: --boundary needs a directory" >&2; exit 2; }
      BOUNDARY=$2
      shift 2
      ;;
    --any)
      SKIP_BOUNDARY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown flag: $1" >&2
      usage
      exit 2
      ;;
    *)
      PORTS+=("$1")
      shift
      ;;
  esac
done
while [ "$#" -gt 0 ]; do
  PORTS+=("$1")
  shift
done

if [ "${#PORTS[@]}" -eq 0 ]; then
  usage
  exit 2
fi

command -v lsof >/dev/null 2>&1 || { echo "error: lsof is required" >&2; exit 2; }

if [ "$SKIP_BOUNDARY" -eq 0 ]; then
  [ -n "$BOUNDARY" ] || BOUNDARY=$(resolve_boundary)
  BOUNDARY=$(canonical_dir "$BOUNDARY")
  [ -n "$BOUNDARY" ] || { echo "error: boundary directory does not exist" >&2; exit 2; }
fi

status=0

for port in "${PORTS[@]}"; do
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "refused: '$port' is not a TCP port number" >&2
    status=1
    continue
  fi

  pids=$(listeners_on "$port")
  if [ -z "$pids" ]; then
    echo "port $port: no listener"
    continue
  fi

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if [ "$SKIP_BOUNDARY" -eq 0 ]; then
      cwd=$(canonical_dir "$(pid_cwd "$pid")")
      if [ -z "$cwd" ]; then
        echo "refused: port $port listener pid $pid - cannot read its working directory, so ownership is unproven" >&2
        status=1
        continue
      fi
      if ! path_within "$BOUNDARY" "$cwd"; then
        echo "refused: port $port belongs to $cwd, outside $BOUNDARY - it is not yours to kill" >&2
        status=1
        continue
      fi
    fi

    if ! kill -TERM "$pid" 2>/dev/null; then
      echo "failed: port $port listener pid $pid - could not send TERM, it may still be running" >&2
      status=1
      continue
    fi
    waited=0
    while [ "$waited" -lt "$TERM_GRACE_SECONDS" ] && kill -0 "$pid" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      if kill -KILL "$pid" 2>/dev/null; then
        echo "port $port: killed pid $pid (did not exit on TERM)"
      else
        echo "failed: port $port listener pid $pid - could not send KILL after TERM grace, it may still be running" >&2
        status=1
      fi
    else
      echo "port $port: stopped pid $pid"
    fi
  done <<< "$pids"
done

exit "$status"
