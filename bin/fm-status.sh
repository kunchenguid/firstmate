#!/usr/bin/env bash
# Append one timestamped, correlation-safe event to an existing Firstmate task
# status stream without copying the note anywhere else.
# Usage:
#   fm-status.sh <task-id> <verb> [--key <slug>|--corr <16-hex>] [--] [note...]
#   fm-status.sh --file <absolute-status-file> <verb> [--key <slug>|--corr <16-hex>] [--] [note...]
#
# The task-id form writes under the effective FM_HOME.
# The --file form exists for a secondmate's explicit parent-status route.
# Output stays backward compatible as "<verb> [optional-key]: <note>", followed
# by privacy-safe [at=], [run=], and [session=] correlation fields.
# FM_STATUS_NOW may provide a test-only UTC timestamp.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

STATUS_FILE=
if [ "${1:-}" = --file ]; then
  [ "$#" -ge 3 ] || { usage >&2; exit 2; }
  STATUS_FILE=$2
  case "$STATUS_FILE" in
    /*.status) : ;;
    *) echo "error: --file requires an absolute .status path" >&2; exit 2 ;;
  esac
  shift 2
else
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  ID=$1
  fm_task_id_path_safe "$ID" || { echo "error: invalid task id" >&2; exit 2; }
  STATUS_FILE="$STATE/$ID.status"
  shift
fi

VERB=$1
shift
case "$VERB" in
  [a-z]* ) ;;
  *) echo "error: invalid status verb" >&2; exit 2 ;;
esac
case "$VERB" in
  *[!a-z-]*) echo "error: invalid status verb" >&2; exit 2 ;;
esac

KEY=
CORR=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --key)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      KEY=$2
      shift 2
      ;;
    --corr)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      CORR=${2#corr=}
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done
[ -z "$KEY" ] || [ -z "$CORR" ] || { echo "error: --key and --corr are mutually exclusive" >&2; exit 2; }
case "$KEY" in
  ''|*[!A-Za-z0-9._-]*) [ -z "$KEY" ] || { echo "error: invalid status key" >&2; exit 2; } ;;
esac
case "$CORR" in
  '') ;;
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *) echo "error: --corr must be 16 hex characters" >&2; exit 2 ;;
esac

NOTE=$*
case "$NOTE" in
  *$'\n'*|*$'\r'*) echo "error: status note must be one line" >&2; exit 2 ;;
esac
[ "${#NOTE}" -le 4096 ] || { echo "error: status note exceeds 4096 characters" >&2; exit 2; }

NOW=${FM_STATUS_NOW:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}
case "$NOW" in
  ????-??-??T??:??:??Z) ;;
  *) echo "error: status timestamp must be UTC ISO-8601 seconds" >&2; exit 2 ;;
esac

safe_correlation() {
  case "$1" in
    ''|*[!A-Za-z0-9._:@+/-]*) return 1 ;;
    *) [ "${#1}" -le 256 ] ;;
  esac
}

PREFIX=$VERB
[ -z "$KEY" ] || PREFIX="$PREFIX [key=$KEY]"
[ -z "$CORR" ] || PREFIX="$PREFIX [corr=$CORR]"
SUFFIX="[at=$NOW]"
if safe_correlation "${FM_RUN_ID:-}"; then
  SUFFIX="$SUFFIX [run=$FM_RUN_ID]"
fi
if safe_correlation "${FM_SESSION_ID:-}"; then
  SUFFIX="$SUFFIX [session=$FM_SESSION_ID]"
fi

mkdir -p "$(dirname "$STATUS_FILE")"
umask 077
if [ -n "$NOTE" ]; then
  printf '%s: %s %s\n' "$PREFIX" "$NOTE" "$SUFFIX" >> "$STATUS_FILE"
else
  printf '%s: %s\n' "$PREFIX" "$SUFFIX" >> "$STATUS_FILE"
fi
