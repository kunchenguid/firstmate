#!/usr/bin/env bash
# Inspect the live process evidence for one remote Herdr secondmate without
# changing its home, endpoint, session, or process state.
#
# Usage: fm-remote-harness-diagnostic.sh <secondmate-id>
#
# The command is intended for bin/fm-on.sh.  It reads the host-local remote
# endpoint record, asks Herdr for the pane's shell and foreground process IDs,
# then prints each candidate's bounded parent chain through the shared session
# lock matcher.  It never accepts an identity, writes a lock, or signals a
# process; bin/fm-session-lock-lib.sh remains the only matcher owner.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONTROL_STATE="$FM_HOME/state/parent-route"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ "$#" -eq 1 ] || { usage; exit 2; }
ID=$1
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac

META="$CONTROL_STATE/$ID.meta"
fm_backend_validate_task_endpoint "$META" "$ID" 2>/dev/null \
  || die "remote secondmate endpoint metadata is invalid"
[ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] \
  || die "remote secondmate endpoint is not on the Herdr backend"
TARGET=$FM_BACKEND_VALIDATED_TARGET
fm_backend_source herdr || die "could not load the Herdr backend adapter"
fm_backend_herdr_parse_target "$TARGET" || die "remote Herdr endpoint target is invalid: $TARGET"
SESSION=$FM_BACKEND_HERDR_SESSION
PANE=$FM_BACKEND_HERDR_PANE

INFO=$(fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE" 2>/dev/null) \
  || die "could not read Herdr process information for pane $PANE in session $SESSION"
SHELL_PID=$(printf '%s' "$INFO" | jq -er \
  '.result.process_info.shell_pid | select(type == "number" and . > 1) | floor' 2>/dev/null) \
  || die "Herdr did not report a valid pane shell PID"
FOREGROUND=$(printf '%s' "$INFO" | jq -r \
  '.result.process_info.foreground_processes[]?.pid | select(type == "number" and . > 1) | floor' 2>/dev/null) \
  || die "Herdr did not report foreground process IDs"
HARNESS=$(fm_meta_get "$META" harness)

printf 'schema=fm-remote-harness-diagnostic.v1 id=%q target=%q harness=%q session=%q pane=%q shell_pid=%s\n' \
  "$ID" "$TARGET" "$HARNESS" "$SESSION" "$PANE" "$SHELL_PID"
printf 'source=herdr-pane-process-info foreground_pids=%q\n' "${FOREGROUND//$'\n'/ }"

PIDS="$SHELL_PID"
while IFS= read -r pid; do
  case "$pid" in ''|*[!0-9]*|0|1) continue ;; esac
  case " $PIDS " in *" $pid "*) ;; *) PIDS="$PIDS $pid" ;; esac
done <<EOF
$FOREGROUND
EOF

for pid in $PIDS; do
  printf 'candidate_pid=%s\n' "$pid"
  fm_harness_ancestry_diagnostic "$pid"
done
