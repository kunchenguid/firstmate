#!/usr/bin/env bash
# fm-coord.sh - on-demand shadow coordination store for one Firstmate home.
# Usage: fm-coord.sh [--db PATH] <command> [JSON]
# Commands and payload fields are owned by docs/coordination.md; --help prints the
# compact command list. JSON results are one line on stdout, errors on stderr.
# The default database is $FM_HOME/state/fm-coord.sqlite3. All callers must use
# one configured authority on local disk. This command does not dispatch, merge,
# contact a network endpoint, or enforce existing Firstmate lifecycle gates.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: fm-coord.sh [--db PATH] <init|enroll|session|area-set|migration-seed|submit|claim|amend|renew|release|check|reserve|publish-head|attach-pr|manifest-set|predecessors-set|queue-ready|queue-next|queue-synced|queue-validated|queue-checks|queue-attempt|queue-result|queue-reconcile|queue-abort|queue-operator-abort|queue-wrapper-exited|outbox|ack|inspect|view> [JSON]
Default database: $FM_HOME/state/fm-coord.sqlite3
Contract and examples: docs/coordination.md
EOF
}

if [ "${1:-}" = '--help' ] || [ "${1:-}" = '-h' ]; then
  usage
  exit 0
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
  printf 'fm-coord: sqlite3 command is required (install SQLite on macOS or Linux)\n' >&2
  exit 69
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-coord: python3 is required for the SQLite coordination command\n' >&2
  exit 69
fi
db=''
if [ "${1:-}" = '--db' ]; then
  [ "$#" -ge 3 ] || { usage >&2; exit 64; }
  db=$2
  shift 2
else
  [ -n "${FM_HOME:-}" ] || { printf 'fm-coord: FM_HOME is required without --db\n' >&2; exit 64; }
  db=$FM_HOME/state/fm-coord.sqlite3
fi
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; exit 64; }
case "$1" in
  init|enroll|session|area-set|migration-seed|submit|claim|amend|renew|release|check|reserve|publish-head|attach-pr|manifest-set|predecessors-set|queue-ready|queue-next|queue-synced|queue-validated|queue-checks|queue-attempt|queue-result|queue-reconcile|queue-abort|queue-operator-abort|queue-wrapper-exited|outbox|ack|inspect|view) ;;
  *) usage >&2; exit 64 ;;
esac
umask 077
payload='{}'
if [ "$#" -eq 2 ]; then
  payload=$2
fi
exec python3 "$(dirname "$0")/fm-coord.py" "$db" "$1" "$payload"
