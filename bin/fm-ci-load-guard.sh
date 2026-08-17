#!/usr/bin/env bash
# fm-ci-load-guard.sh - admit or validate CI against a shared-host load ceiling.
#
# Usage:
#   fm-ci-load-guard.sh check [--max-load N] [--load-file PATH]
#   fm-ci-load-guard.sh wait [--max-load N] [--timeout SECONDS] [--poll SECONDS] [--load-file PATH]
#
# The first one-minute load-average field is authoritative.
# `check` fails immediately above the ceiling.
# `wait` admits only after load falls to the ceiling or below and fails when the
# bounded timeout expires.
set -eu

MODE=${1:-}
[ -n "$MODE" ] || {
  printf 'usage: fm-ci-load-guard.sh check|wait [options]\n' >&2
  exit 2
}
shift

MAX_LOAD=12
TIMEOUT=900
POLL=15
LOAD_FILE=/proc/loadavg

while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-load)
      [ "$#" -ge 2 ] || { printf 'fm-ci-load-guard.sh: --max-load needs a value\n' >&2; exit 2; }
      MAX_LOAD=$2
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || { printf 'fm-ci-load-guard.sh: --timeout needs a value\n' >&2; exit 2; }
      TIMEOUT=$2
      shift 2
      ;;
    --poll)
      [ "$#" -ge 2 ] || { printf 'fm-ci-load-guard.sh: --poll needs a value\n' >&2; exit 2; }
      POLL=$2
      shift 2
      ;;
    --load-file)
      [ "$#" -ge 2 ] || { printf 'fm-ci-load-guard.sh: --load-file needs a path\n' >&2; exit 2; }
      LOAD_FILE=$2
      shift 2
      ;;
    *)
      printf 'fm-ci-load-guard.sh: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "$MODE" in
  check|wait) ;;
  *) printf 'fm-ci-load-guard.sh: mode must be check or wait\n' >&2; exit 2 ;;
esac
[[ "$MAX_LOAD" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  printf 'fm-ci-load-guard.sh: max load must be a non-negative number\n' >&2
  exit 2
}
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { printf 'fm-ci-load-guard.sh: timeout must be a non-negative integer\n' >&2; exit 2; }
[[ "$POLL" =~ ^[1-9][0-9]*$ ]] || { printf 'fm-ci-load-guard.sh: poll must be a positive integer\n' >&2; exit 2; }

started=$(date +%s)
while :; do
  if ! IFS=' ' read -r load _ <"$LOAD_FILE"; then
    printf 'fm-ci-load-guard.sh: cannot read load evidence: %s\n' "$LOAD_FILE" >&2
    exit 1
  fi
  if [[ ! "$load" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf 'fm-ci-load-guard.sh: malformed one-minute load evidence: %s\n' "$load" >&2
    exit 1
  fi
  if awk -v current="$load" -v maximum="$MAX_LOAD" 'BEGIN { exit !(current <= maximum) }'; then
    printf 'fm-ci-load-guard.sh: admissible one-minute load %s <= %s\n' "$load" "$MAX_LOAD"
    exit 0
  fi
  if [ "$MODE" = check ]; then
    printf 'fm-ci-load-guard.sh: inadmissible one-minute load %s > %s\n' "$load" "$MAX_LOAD" >&2
    exit 1
  fi
  now=$(date +%s)
  if [ $((now - started)) -ge "$TIMEOUT" ]; then
    printf 'fm-ci-load-guard.sh: load stayed above %s for %ss (last %s)\n' "$MAX_LOAD" "$TIMEOUT" "$load" >&2
    exit 1
  fi
  sleep "$POLL"
done
