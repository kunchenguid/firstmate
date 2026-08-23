#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <target> [lines=40]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
# A selector whose meta records remote_host= is a remote secondmate: its pane
# lives on that host, so the capture routes over fm-on.sh to the host-local
# capture (fm-remote-secondmate-control.sh), clamped to that command's
# 100-line cap. An unreachable host or unreadable endpoint fails loudly naming
# the host; the local backend adapters are never asked to read a remote target.
# When the target resolves to a known task id, the SAME authoritative
# current-state line bin/fm-crew-state.sh prints (both render
# bin/fm-worker-state-lib.sh's one computed projection) is also printed to
# STDERR before the capture, so an interactive reader is never left to judge
# busy-vs-hung from the raw pane text alone - while STDOUT stays exactly the
# raw capture, unchanged, for every caller that consumes it programmatically.
# A bare backend target with no task id (e.g. an explicit session:window) has
# no projection to read and prints the raw capture only. The projection is
# asked to skip its own live pane/busy probe (this script is about to make
# that exact capture itself below) so a peek never doubles a live backend
# round-trip; the run-step and status-log tiers still answer for free. For a
# resolved task id, this script makes its ONE raw capture first and passes
# that text into the projection as its precaptured-tail argument, so a
# recordless Grok crew with no status log to fall back on still gets a real
# busy/idle verdict from the SAME capture that reaches stdout, instead of an
# unresolved unknown - fm-crew-state.sh and fm-peek.sh can never structurally
# disagree, without a second live round trip.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-worker-state-lib.sh
. "$SCRIPT_DIR/fm-worker-state-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

RAW_TARGET=$1
N=${2:-40}

# shellcheck disable=SC2031 # fm_worker_state_project's STATE is local to its own subshell (bin/fm-worker-state-lib.sh), never this script's.
TASK_ID=$(fm_backend_task_id_for_selector "$RAW_TARGET" "$STATE" 2>/dev/null || true)

# shellcheck disable=SC2031 # see the disable above: not this script's STATE.
REMOTE_META=$(fm_backend_meta_for_selector "$RAW_TARGET" "$STATE" 2>/dev/null || true)
if [ -n "$REMOTE_META" ] && [ -n "$(fm_meta_get "$REMOTE_META" remote_host)" ]; then
  # The remote endpoint's own live tail lives on that host (fetched below via
  # fm-remote-secondmate-control.sh, not fm_backend_capture), so there is no
  # local capture to share with the projection here - unchanged from before.
  if [ -n "$TASK_ID" ]; then
    WORKER_STATE_RECORD=$(fm_worker_state_project "$TASK_ID" 1) && fm_worker_state_render_line "$WORKER_STATE_RECORD" >&2
  fi
  REMOTE_ID=${REMOTE_META##*/}
  REMOTE_ID=${REMOTE_ID%.meta}
  REMOTE_HOST=$(fm_meta_get "$REMOTE_META" remote_host)
  case "$N" in ''|*[!0-9]*|0) N=40 ;; esac
  [ "$N" -le 100 ] || N=100
  # shellcheck disable=SC2031 # see the disable above: not this script's FM_HOME.
  if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$REMOTE_ID" \
    fm-remote-secondmate-control.sh capture "$REMOTE_ID" "$N" < /dev/null; then
    echo "error: could not read the remote pane of $REMOTE_ID on $REMOTE_HOST (host unreachable or endpoint unreadable; the mate is not thereby dead)" >&2
    exit 1
  fi
  exit 0
fi

# shellcheck disable=SC2031 # see the disable above: not this script's STATE.
T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")

# shellcheck disable=SC2031 # see the disable above: not this script's STATE.
BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
# shellcheck disable=SC2031 # see the disable above: not this script's STATE.
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

if [ -z "$TASK_ID" ]; then
  # A bare backend target with no task id has no projection to read - print
  # the raw capture only, exactly as before.
  fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
  exit 0
fi

# Capture once, byte-exact (the `printf x`/`${RAW%x}` pair preserves however
# many trailing newlines the backend printed, which a plain $(...) would
# otherwise strip - see bin/fm-operational-input.sh's fm_operational_read_stdin
# for the same idiom), and reuse it for both the projection below and stdout,
# so a peek never pays for a second live round trip to answer both. `ec`
# preserves fm_backend_capture's own exit status across the sentinel append -
# a capture failure (e.g. a dead endpoint) must still fail this script exactly
# as the direct unwrapped call used to.
RAW=$(ec=0; fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL" || ec=$?; printf x; exit "$ec")
RAW=${RAW%x}
WORKER_STATE_RECORD=$(fm_worker_state_project "$TASK_ID" 1 "$RAW") && fm_worker_state_render_line "$WORKER_STATE_RECORD" >&2
printf '%s' "$RAW"
