#!/usr/bin/env bash
# fm-agent-alive.sh - the CONFIDENT liveness of one task's harness-agent PROCESS,
# printed as a single word: alive, dead, or unknown.
#
# Usage: fm-agent-alive.sh <task-id>
#
# This is a thin command wrapper around bin/fm-backend.sh's fm_backend_agent_alive,
# which is a shell function and therefore had no way to be asked across a
# machine boundary. It exists because that question cannot be answered any other
# way for a SECONDMATE: an idle secondmate pane is healthy by design, so
# bin/fm-crew-state.sh deliberately skips the busy-pane read for kind=secondmate
# and reports `unknown - no current-state source available` for a healthy idle
# secondmate and for one whose agent has exited into a bare shell alike. The
# session-start liveness sweep needs the two told apart, and on a home that lives
# on another machine only that machine can tell them apart.
#
# It is READ-ONLY and never acts on its own answer. `unknown` is not a weaker
# `dead`: a caller that respawned on it would put a second supervisor into a
# live home. bin/fm-bootstrap.sh's sweep gates its respawn on `dead` alone, and
# this script keeps that shape by refusing to guess.
#
# A task recorded as running on another machine (host= in its metadata) is
# answered by that machine's own copy of this script over the relay, for the
# same reason bin/fm-crew-state.sh delegates: the process is over there.
#
# Exit 0 whenever an answer could be produced, including `unknown`.
# Exit 2 on a usage error, 1 when there is no such task here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

ID=${1:-}
case "$ID" in
  ''|-h|--help)
    echo "usage: fm-agent-alive.sh <task-id>" >&2
    [ -n "$ID" ] && exit 0
    exit 2
    ;;
  *[!A-Za-z0-9._-]*|.*)
    echo "error: invalid task id" >&2
    exit 2
    ;;
esac

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no metadata for $ID at $META" >&2; exit 1; }
if grep -q '^host=' "$META" 2>/dev/null; then
  exec "$SCRIPT_DIR/fm-relay-host.sh" agent-alive "$ID"
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
[ -n "$TARGET" ] || TARGET=$(fm_meta_get "$META" window)
if [ -z "$TARGET" ]; then
  printf 'unknown\n'
  exit 0
fi
# Probe the session provider this task recorded, not whichever one this process
# happens to run in.
fm_backend_bind_meta "$BACKEND" "$META" || true
VERDICT=$(fm_backend_agent_alive "$BACKEND" "$TARGET" 2>/dev/null) || VERDICT=unknown
case "$VERDICT" in
  alive|dead|unknown) ;;
  *) VERDICT=unknown ;;
esac
printf '%s\n' "$VERDICT"
