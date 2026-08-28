#!/usr/bin/env bash
# fm-bg-registry.sh - ledger of the long-running things a task started.
#
# Usage:
#   fm-bg-registry.sh add   <task-id> <kind> <ref> <description>...
#   fm-bg-registry.sh check <task-id>    list what is still alive; exit 0 when clean
#   fm-bg-registry.sh stop  <task-id>    kill what is still alive, then check again
#   fm-bg-registry.sh clear <task-id>    drop the ledger, only after a clean check
#   fm-bg-registry.sh --help
#
# Kinds:
#   port   <port>       a server; found with lsof, stopped with kill
#   pid    <pid>        one background process
#   docker <name>       a docker container
#   note   <label>      something that can be neither checked nor stopped
#                       (a browser session, an external job): always reported as
#                       alive so a human has to confirm it
#
# Any task that starts something long-running can use this, not just fast mode:
# a worker registers what it started, and the ledger is what a supervisor checks
# before tearing the task down.
#
# The ledger lives in $FM_HOME/state/<task-id>.bg, on firstmate's side rather
# than in the worktree, precisely because the risk being covered is a worker that
# did not clean up: a recycled worktree takes its own records with it, while
# stray processes and held ports survive with nothing left pointing at them.
#
# Environment:
#   FM_HOME   operational home whose state/ holds the ledgers.
set -euo pipefail

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
  -h | --help | help)
    usage
    exit 0
    ;;
esac

CMD=${1:-}
TASK=${2:-}
if [ -z "$CMD" ] || [ -z "$TASK" ]; then
  usage >&2
  exit 2
fi
LEDGER="$STATE/$TASK.bg"

alive() { # alive <kind> <ref>
  case "$1" in
    port) lsof -ti "tcp:$2" >/dev/null 2>&1 ;;
    pid) kill -0 "$2" 2>/dev/null ;;
    docker) [ -n "$(docker ps -q -f "name=^$2$" 2>/dev/null)" ] ;;
    note) return 0 ;;
    *) return 1 ;;
  esac
}

kill_it() { # kill_it <kind> <ref>
  local pids
  case "$1" in
    port)
      pids=$(lsof -ti "tcp:$2" 2>/dev/null || true)
      # shellcheck disable=SC2086
      [ -n "$pids" ] && kill $pids 2>/dev/null || true
      ;;
    pid) kill "$2" 2>/dev/null || true ;;
    docker) docker stop "$2" >/dev/null 2>&1 || true ;;
    note) return 1 ;;
  esac
}

case "$CMD" in
  add)
    kind=${3:?add needs a kind}
    ref=${4:?add needs a ref}
    shift 4 || true
    desc=${*:-}
    mkdir -p "$(dirname "$LEDGER")"
    # One kind+ref is one thing: replace its row rather than appending. Without
    # this, stop-then-up leaves several rows for the same ports.
    if [ -f "$LEDGER" ]; then
      tmp=$(mktemp)
      awk -F'\t' -v k="$kind" -v r="$ref" '!($2 == k && $3 == r)' "$LEDGER" >"$tmp" && mv "$tmp" "$LEDGER"
    fi
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$kind" "$ref" "$desc" >>"$LEDGER"
    echo "registered: $kind $ref  $desc"
    ;;

  check | stop)
    [ -f "$LEDGER" ] || {
      echo "no ledger for $TASK"
      exit 0
    }
    left=0
    while IFS=$'\t' read -r ts kind ref desc; do
      [ -n "${kind:-}" ] || continue
      if alive "$kind" "$ref"; then
        if [ "$CMD" = stop ] && kill_it "$kind" "$ref"; then
          sleep 1
          if alive "$kind" "$ref"; then
            echo "still there  $kind $ref  $desc"
            left=$((left + 1))
          else
            echo "stopped      $kind $ref  $desc"
          fi
        else
          echo "alive        $kind $ref  $desc  (registered $(date -r "$ts" '+%m-%d %H:%M'))"
          left=$((left + 1))
        fi
      fi
    done <"$LEDGER"
    if [ "$left" -eq 0 ]; then
      echo "nothing from this ledger is still running."
      exit 0
    fi
    echo "$left item(s) left; clear or explain them before teardown." >&2
    exit 1
    ;;

  clear)
    rm -f "$LEDGER"
    echo "ledger cleared: $TASK"
    ;;

  *)
    echo "unknown command: $CMD" >&2
    usage >&2
    exit 2
    ;;
esac
