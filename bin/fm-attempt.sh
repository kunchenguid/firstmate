#!/usr/bin/env bash
# The single owner of a task's DURABLE ATTEMPT COUNT and its RETRY BUDGET, so
# "should this be retried?" is arithmetic over a recorded number rather than a
# judgment made inside the worker that is failing.
#
# Nothing counted attempts before this: no state field, no metadata field. The
# only bound on repetition was a line of prose in the generated brief - "if you
# hit the same obstacle twice, stop" - which made the WORKER the arbiter of its
# own retry budget, evaluated from a context that resets on every relaunch. A
# count the worker cannot see and cannot reset replaces it.
#
# THE DURABLE RECORD. state/<id>.attempt, key=value, last assignment winning:
#
#   attempt=<n>          attempts COMMITTED for this task id so far.
#   attempt_budget=<b>   the most attempts this task id may commit.
#   terminal=<state>     written only when the budget is exhausted (below).
#   updated=<epoch>      when the record last changed.
#
# The same two numbers are published onto state/<id>.meta as attempt= and
# attempt_budget= by bin/fm-spawn.sh, so every reader that already joins on task
# metadata sees the count without learning a second file. This record is the
# authority; meta carries the readable copy.
#
# MIGRATION - AN ABSENT FIELD READS AS ATTEMPT 1. A task dispatched before this
# existed has no record and no meta field, yet it plainly had an attempt. So the
# prior count is resolved in this order: the durable record when present; else 1
# when the task's meta exists (that metadata IS the evidence of an attempt);
# else 0. A pre-existing task therefore retries at attempt 2 rather than
# restarting its budget at 1.
#
# WHAT SURVIVES A TEARDOWN. bin/fm-teardown.sh retires the record on an ordinary
# release and PRESERVES it under --force. An ordinary teardown is only reachable
# once the work landed, so the count retires with the task it measured. --force
# is the discard path: the work was thrown away, a re-dispatch of that id is a
# genuine retry, and resetting its count there would make the budget unbounded
# by simply discarding between attempts.
#
# EXHAUSTION IS A NAMED TERMINAL STATE, NOT A SILENT STOP. When the budget is
# spent, `open` and `check` refuse the next attempt, record
# terminal=budget_exhausted, and append one
# `failed: attempt budget exhausted ...` line to state/<id>.status.
#
#   budget_exhausted is CFVC-11's UNIFIED terminal-state vocabulary
#   (loopspecs/terminal-states.json), not a third vocabulary invented here: "a
#   declared bound - iterations, wall clock, context, capacity or cost - was
#   reached before the goal was met". FM_ATTEMPT_TERMINAL_STATE below is that
#   one name, and tests/fm-attempt.test.sh asserts it against that file
#   whenever the file is present.
#
#   The status append is deliberately the ONLY terminal producer here. A
#   `failed:` status line is what CFVC-12's terminal-outcome derivation reads
#   (bin/fm-wake-ledger.sh `derive`/`sweep`), so exhaustion books outcome=failed
#   through that owner instead of a second producer writing its own ledger line.
#   Before that derivation exists the append still wakes firstmate, which is the
#   part that makes the stop audible either way.
#
# SECONDMATES ARE EXEMPT. A secondmate is persistent and its relaunch is routine
# liveness recovery, run unattended at session start; counting those as retries
# would eventually refuse to bring a healthy long-lived secondmate back up.
# bin/fm-spawn.sh calls this for ship and scout kinds only.
#
# THERE IS NO RESET. A budget raised by an explicit --budget is the only way
# past an exhausted count, and it is recorded, so the override is inspectable
# afterwards. A reset verb would hand back exactly the discretion this replaces.
#
# Usage:
#   fm-attempt.sh show <id>
#       Print "attempt=<n> attempt_budget=<b>" for the resolved prior count.
#       An unknown task prints attempt=0 with the default budget.
#   fm-attempt.sh check <id> [--budget <n>]
#       Decide whether one more attempt is within budget, committing nothing.
#       Exit 0 when it is, 3 when the budget is exhausted. Called before a spawn
#       creates anything, so a refused retry allocates no worktree or endpoint.
#   fm-attempt.sh open <id> [--budget <n>]
#       Same decision, then COMMIT the increment durably and print
#       "attempt=<n> attempt_budget=<b>" for the attempt now opened. Called at
#       the moment a spawn publishes task metadata, so an attempt that never
#       reached a launch does not spend budget.
#   fm-attempt.sh retire <id>
#       Remove the record. Teardown's ordinary-release hook.
#
# --budget sets the budget for this task id from here on and is recorded; absent,
# a recorded budget stands, and an unrecorded one defaults to
# FM_ATTEMPT_BUDGET_DEFAULT (2). Two is not arbitrary: it is the same threshold
# the prose it replaces used, and the one LoopSpec's no_progress block already
# encodes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fm-wake-lib.sh owns FM_ROOT/FM_HOME/STATE resolution.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# fm-pr-lib.sh owns fm_task_id_path_safe, the task-id path-safety predicate.
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# The one unified terminal state this file may produce.
FM_ATTEMPT_TERMINAL_STATE=budget_exhausted
ATTEMPT_BUDGET_DEFAULT=${FM_ATTEMPT_BUDGET_DEFAULT:-2}
# Exit code for a refused retry, distinct from an argument error (2) so a caller
# can tell "this task is out of budget" from "you called me wrong".
ATTEMPT_EXHAUSTED_EXIT=3

usage() {
  LC_ALL=C awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SCRIPT_DIR/fm-attempt.sh"
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

# One key's value from a key=value file, last assignment winning. An absent file
# or key yields the empty string; every caller decides what absence means rather
# than being handed a guess.
attempt_field() {  # <file> <key>
  [ -f "$1" ] || return 0
  LC_ALL=C awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$1"
}

attempt_is_count() {  # <value>
  case "${1-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# The migration rule in one place: record, else metadata-implies-one, else none.
attempt_prior() {  # <id> -> count on stdout
  local id=$1 n rec
  rec="$STATE/$id.attempt"
  n=$(attempt_field "$rec" attempt)
  if attempt_is_count "$n"; then
    printf '%s' "$n"
    return 0
  fi
  if [ -f "$STATE/$id.meta" ]; then
    n=$(attempt_field "$STATE/$id.meta" attempt)
    attempt_is_count "$n" && [ "$n" -gt 0 ] || n=1
    printf '%s' "$n"
    return 0
  fi
  printf '0'
}

# Explicit flag wins, then the record, then the task metadata, then the default.
attempt_budget() {  # <id> <explicit-or-empty> -> budget on stdout
  local id=$1 explicit=${2-} b
  if [ -n "$explicit" ]; then
    printf '%s' "$explicit"
    return 0
  fi
  for b in \
    "$(attempt_field "$STATE/$id.attempt" attempt_budget)" \
    "$(attempt_field "$STATE/$id.meta" attempt_budget)"; do
    if attempt_is_count "$b" && [ "$b" -gt 0 ]; then
      printf '%s' "$b"
      return 0
    fi
  done
  printf '%s' "$ATTEMPT_BUDGET_DEFAULT"
}

# Whole record rewritten from the values passed, so a field can never be left
# behind from an earlier state. Written to a temp file and moved into place, so
# a concurrent reader sees either the old record or the new one.
attempt_write() {  # <id> <attempt> <budget> <terminal-or-empty>
  local id=$1 n=$2 b=$3 term=${4-} rec tmp
  rec="$STATE/$id.attempt"
  [ -d "$STATE" ] || mkdir -p "$STATE" 2>/dev/null || return 1
  tmp="$rec.tmp.$$"
  {
    printf 'attempt=%s\n' "$n"
    printf 'attempt_budget=%s\n' "$b"
    [ -z "$term" ] || printf 'terminal=%s\n' "$term"
    printf 'updated=%s\n' "$(date +%s)"
  } > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$rec" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
}

# The refusal. Recorded once per exhaustion: a second refused spawn must not
# append a second failure declaration for the same stop, because the status log
# is a wake surface and the terminal fact has not changed.
attempt_refuse() {  # <id> <prior> <budget>
  local id=$1 prior=$2 budget=$3 already
  already=$(attempt_field "$STATE/$id.attempt" terminal)
  attempt_write "$id" "$prior" "$budget" "$FM_ATTEMPT_TERMINAL_STATE" \
    || printf 'warning: could not record the exhausted attempt budget for %s\n' "$id" >&2
  if [ "$already" != "$FM_ATTEMPT_TERMINAL_STATE" ]; then
    printf '%s: attempt budget exhausted after %s of %s attempts (%s)\n' \
      failed "$prior" "$budget" "$FM_ATTEMPT_TERMINAL_STATE" \
      >> "$STATE/$id.status" 2>/dev/null \
      || printf 'warning: could not append the exhausted-budget failure for %s\n' "$id" >&2
  fi
  printf 'error: %s has spent its retry budget: %s of %s attempts used (%s). Raise it deliberately with --attempt-budget <n> if another attempt is warranted; it is recorded.\n' \
    "$id" "$prior" "$budget" "$FM_ATTEMPT_TERMINAL_STATE" >&2
}

parse_budget_flag() {  # <args...> -> sets PARSED_BUDGET
  PARSED_BUDGET=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --budget)
        [ "$#" -ge 2 ] || die "--budget needs a value"
        PARSED_BUDGET=$2
        attempt_is_count "$PARSED_BUDGET" && [ "$PARSED_BUDGET" -gt 0 ] \
          || die "--budget must be a positive integer: $PARSED_BUDGET"
        shift 2
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
}

require_id() {  # <id>
  [ -n "${1-}" ] || die "a task id is required"
  fm_task_id_path_safe "$1" || die "invalid task id: $1"
}

cmd_show() {
  local id=${1-}
  require_id "$id"
  shift
  [ "$#" -eq 0 ] || die "show takes only a task id"
  printf 'attempt=%s attempt_budget=%s\n' "$(attempt_prior "$id")" "$(attempt_budget "$id" '')"
}

cmd_check() {
  local id=${1-} prior budget
  require_id "$id"
  shift
  parse_budget_flag "$@"
  budget=$(attempt_budget "$id" "$PARSED_BUDGET")
  prior=$(attempt_prior "$id")
  if [ "$prior" -ge "$budget" ]; then
    attempt_refuse "$id" "$prior" "$budget"
    exit "$ATTEMPT_EXHAUSTED_EXIT"
  fi
  printf 'attempt=%s attempt_budget=%s\n' "$((prior + 1))" "$budget"
}

cmd_open() {
  local id=${1-} prior budget next
  require_id "$id"
  shift
  parse_budget_flag "$@"
  budget=$(attempt_budget "$id" "$PARSED_BUDGET")
  prior=$(attempt_prior "$id")
  if [ "$prior" -ge "$budget" ]; then
    attempt_refuse "$id" "$prior" "$budget"
    exit "$ATTEMPT_EXHAUSTED_EXIT"
  fi
  next=$((prior + 1))
  # A commit that cannot be made durable is refused rather than launched
  # uncounted: an attempt nobody recorded is exactly the state this replaces.
  attempt_write "$id" "$next" "$budget" '' \
    || die "could not record attempt $next for $id at $STATE/$id.attempt"
  printf 'attempt=%s attempt_budget=%s\n' "$next" "$budget"
}

cmd_retire() {
  local id=${1-}
  require_id "$id"
  shift
  [ "$#" -eq 0 ] || die "retire takes only a task id"
  rm -f -- "$STATE/$id.attempt"
}

[ "$#" -ge 1 ] || { usage; exit 2; }
SUBCOMMAND=$1
shift
case "$SUBCOMMAND" in
  show) cmd_show "$@" ;;
  check) cmd_check "$@" ;;
  open) cmd_open "$@" ;;
  retire) cmd_retire "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown subcommand: $SUBCOMMAND (show check open retire)" ;;
esac
