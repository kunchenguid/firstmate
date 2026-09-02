#!/usr/bin/env bash
# fm-usage-ledger-lib.sh - the single owner of HOW firstmate's lifecycle scripts
# call the task-usage ledger.
#
# bin/fm-usage-ledger.sh owns the ledger's schema, safety, identity, and
# retention. This file owns only the call policy the lifecycle scripts share, so
# that policy is stated once instead of copied into every call site:
#
#   - The effective home is passed explicitly (home, state, and data), never
#     inherited, so a secondmate home or an override-driven test home always
#     records into its own ledger rather than resolving a different one. The
#     single exception is a caller sweeping homes its own operation deletes,
#     which passes the surviving home because a row in a deleted one would go
#     with it; bin/fm-teardown.sh's forced-retirement child sweep is that
#     caller, and docs/architecture.md owns why.
#   - Recording is INSTRUMENTATION, never a gate. A launch that already
#     succeeded, a merge that already landed, and a cleanup whose safety checks
#     already passed must not be turned into a failure because an observability
#     record could not be written. So this helper always returns 0 and reports a
#     failure as a loud stderr warning naming the concrete consequence; the
#     ledger's own diagnostic is left on stderr underneath it.
#   - The spawn record is the durable anchor. It is written first, so a task
#     that is abandoned, preserved indefinitely, or whose later enrichment fails
#     is still attributable to a harness and model.
#   - A caller whose own sequence destroys part of a task's volatile state
#     before it reaches its record captures that part first, through the same
#     owner, and passes the captured value: the final status class before the
#     log is retired, and the implementation axes before the task record is
#     deleted. A secondmate retirement needs both, because removing that home
#     takes the state directory the record sits in with it. What a capture
#     could not read is "unknown" rather than a claim the task proved nothing.
#
# Sourced by bin/fm-spawn.sh, bin/fm-teardown.sh, bin/fm-pr-check.sh,
# bin/fm-merge-local.sh, and bin/fm-merge-outcome-lib.sh. No side effects on
# source.

_FM_USAGE_LEDGER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fm_usage_ledger_record <home> <state> <data> <event> <task-id> [record args...]
# Always returns 0; see the call policy above.
fm_usage_ledger_record() {
  local home=$1 state=$2 data=$3 event=$4 task=$5
  shift 5
  if FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$_FM_USAGE_LEDGER_LIB_DIR/fm-usage-ledger.sh" record \
    --event "$event" --task "$task" "$@" >/dev/null; then
    return 0
  fi
  printf 'warning: the task-usage ledger did not record the %s event for %s; model and workflow analysis will be missing it\n' \
    "$event" "$task" >&2
  return 0
}

# fm_usage_ledger_status_class <home> <state> <data> <status-file>
# Print the status log's final class, for a caller that must read it before its
# own cleanup retires the log. Never fails; see the call policy above.
fm_usage_ledger_status_class() {
  local home=$1 state=$2 data=$3 file=$4 class
  if class=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$_FM_USAGE_LEDGER_LIB_DIR/fm-usage-ledger.sh" status-class \
    --status-file "$file"); then
    [ -n "$class" ] || class=unknown
    printf '%s\n' "$class"
    return 0
  fi
  printf 'warning: the task-usage ledger could not read the final status class from %s; the record will carry "unknown" instead of the class the task actually ended on\n' \
    "$file" >&2
  printf 'unknown\n'
}

# fm_usage_ledger_axes <home> <state> <data> <meta-file>
# Print the task record's implementation axes as the ledger's own opaque line,
# for a caller that must read them before its own cleanup deletes that record.
# Prints nothing when they could not be captured, so the caller falls back to
# naming the record itself. Never fails; see the call policy above.
fm_usage_ledger_axes() {
  local home=$1 state=$2 data=$3 file=$4 axes
  if axes=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$_FM_USAGE_LEDGER_LIB_DIR/fm-usage-ledger.sh" axes --meta "$file"); then
    printf '%s\n' "$axes"
    return 0
  fi
  printf 'warning: the task-usage ledger could not capture the implementation axes from %s; if cleanup removes that task record before the ledger reads it, the record will carry "unknown" harness, model, and incarnation instead of the ones the task ran on\n' \
    "$file" >&2
}
