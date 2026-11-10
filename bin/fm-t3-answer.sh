#!/usr/bin/env bash
# Read or answer a T3 Code worker's pending questions.
# Usage: fm-t3-answer.sh <task-id>
#        fm-t3-answer.sh <task-id> <request-id> <answers-json>
#   With only the task id, prints the thread's pending requests as JSON:
#   questions (each request id with its questions, options, and ids) and
#   approvals, the count of permission approvals T3's pending-request tools
#   cannot see or answer; those are answered only in T3 Code itself.
#   With a request id, answers that question through
#   t3_pending_request_respond; <answers-json> is a JSON object keyed by
#   question id, e.g. '{"q1":"yes"}'.
# The task must be recorded in this home with backend=t3code. An answer is
# authorized the same way any steer is: it is the supervisor's decision, never
# the worker's own. bin/backends/t3code.sh owns the transport.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -eq 1 ] || [ "$#" -eq 3 ] || usage
ID=$1
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo "error: '$ID' is not a task id" >&2; exit 2 ;; esac
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no task $ID recorded in $STATE" >&2; exit 1; }
BACKEND=$(fm_backend_of_meta "$META")
[ "$BACKEND" = t3code ] || { echo "error: $ID runs on backend=$BACKEND; only T3 Code threads have pending requests to answer" >&2; exit 1; }
THREAD=$(fm_backend_target_of_meta "$META")
[ -n "$THREAD" ] || { echo "error: $ID records no T3 thread" >&2; exit 1; }
fm_backend_source t3code || exit 1

if [ "$#" -eq 1 ]; then
  fm_backend_t3code_pending_requests "$THREAD"
  exit
fi

ANSWERS=$(mktemp "${TMPDIR:-/tmp}/fm-t3-answer.XXXXXX")
trap 'rm -f "$ANSWERS"' EXIT
printf '%s' "$3" > "$ANSWERS"
fm_backend_t3code_answer_request "$THREAD" "$2" "$ANSWERS"
echo "answered $ID request $2 on T3 thread $THREAD"
