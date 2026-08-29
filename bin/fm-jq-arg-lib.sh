# shellcheck shell=bash
# fm-jq-arg-lib.sh - the single owner of handing large JSON payloads to jq.
# Usage: . bin/fm-jq-arg-lib.sh; fm_jq_inputs "$a" "$b" | jq -n '(input) as $a | (input) as $b | ...'
#
# Sourced, never executed.
#
#   fm_jq_inputs <json> [<json>...]
#       Writes each payload to stdout as one element of a JSON stream, in the
#       order given, for a jq filter that binds them with `input`.
#
# WHY: a jq argument carrying a whole backlog, task inventory, home summary, or
# fleet snapshot cannot ride on argv. The kernel caps a SINGLE argument at
# MAX_ARG_STRLEN - 128 KiB on Linux, independent of the far larger ARG_MAX -
# so `jq --argjson backlog "$BACKLOG_JSON"` makes execve reject the whole
# command with "Argument list too long" once a home's backlog grows past that.
# The failure is total rather than degraded: the snapshot exits non-zero and
# every view built on it, bearings included, returns nothing. It also gets
# worse the longer a fleet has been used, so it strikes the busiest homes.
# A payload that grows with the fleet - a collection of backlog records, task
# rows, secondmate records, or PR rows - belongs on stdin for that reason, even
# where a documented bound currently keeps it small, because those bounds are
# environment-overridable and the failure mode is loss of the whole command.
#
# BINDING CONTRACT: pipe fm_jq_inputs into jq and bind each payload in the same
# order with `input`. With `jq -n`, every payload is an `input`:
#
#     fm_jq_inputs "$backlog" "$tasks" \
#       | jq -n '(input) as $backlog
#                | (input) as $tasks
#                | ...'
#
# Without `-n`, jq consumes the FIRST payload as `.` and each `input` returns
# the next, which keeps a filter that already reads `.` unchanged:
#
#     fm_jq_inputs "$snapshot" "$rows" | jq '(input) as $rows | ...'
#
# `input` preserves --argjson's fail-closed behavior: an empty or malformed
# payload aborts jq non-zero rather than binding null, so a caller checking the
# exit status keeps refusing bad data instead of reporting an empty fleet.
#
# Small fixed-size values - a path, a bound, a boolean, an id, one status line -
# stay on argv with --arg/--argjson, where they are readable and cost nothing.

fm_jq_inputs() {  # <json> [<json>...]
  if [ "$#" -eq 0 ]; then
    echo "fm_jq_inputs: at least one payload is required" >&2
    return 2
  fi
  printf '%s\n' "$@"
}
