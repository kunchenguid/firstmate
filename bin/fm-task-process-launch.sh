#!/usr/bin/env bash
# Launch one verified worker under the durable scope owned by
# `fm-task-process-lib.sh`.
# Usage: fm-task-process-launch.sh <record> <token> <prior-token|-> <launch> <enclosure|->
# The caller must place this process in its own foreground process group.
# A real enclosure is validated as util-linux `unshare` with a user and PID
# namespace; `-` keeps portable process-group containment.
# The launcher publishes `active` before allowing the agent child to exec, stays
# alive as the immutable ownership anchor, and publishes `empty` only after the
# agent and every remaining scoped descendant have exited.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-task-process-lib.sh"

scope_agent() {
  [ "$#" -eq 5 ] || return 2
  local record token containment launch enclosure state name id agent_pid attempt actual_containment
  record=$1
  token=$2
  containment=$3
  launch=$4
  enclosure=$5
  state=${record%/*}
  name=${record##*/}
  id=${name%.process-scope}
  agent_pid=$$
  attempt=0
  actual_containment=$(fm_task_process_enclosure_containment "$enclosure") || return 1
  [ "$actual_containment" = "$containment" ] || return 1
  while [ "$attempt" -lt 200 ]; do
    if fm_task_process_scope_record_read "$state" "$id" "$token" 2>/dev/null \
       && [ "$FM_TASK_PROCESS_SCOPE_STATUS" = active ] \
       && [ "$FM_TASK_PROCESS_SCOPE_AGENT_PID" = "$agent_pid" ]; then
      if [ "$containment" = pid-namespace ]; then
        exec "$enclosure" --user --map-current-user --pid --fork \
          --kill-child=SIGKILL --mount-proc -- /bin/sh -c "$launch"
      fi
      exec /bin/sh -c "$launch"
    fi
    sleep 0.01
    attempt=$((attempt + 1))
  done
  return 1
}

if [ "${1:-}" = --scope-agent ]; then
  shift
  scope_agent "$@"
  exit $?
fi

[ "$#" -eq 5 ] || exit 2
record=$1
token=$2
prior_token=$3
launch=$4
enclosure=$5
containment=$(fm_task_process_enclosure_containment "$enclosure") || exit 1
state=${record%/*}
name=${record##*/}
id=${name%.process-scope}
if [ "$prior_token" = - ]; then
  [ ! -e "$record" ] && [ ! -L "$record" ] || exit 1
else
  fm_task_process_scope_record_read "$state" "$id" "$prior_token" || exit 1
  [ "$FM_TASK_PROCESS_SCOPE_STATUS" = empty ] || exit 1
fi
pid=$$
endpoint_pid=$(fm_task_process_parent_pid "$pid") || exit 1
case "$endpoint_pid" in ''|*[!0-9]*|0|1) exit 1 ;; esac
endpoint_identity=$(fm_task_process_identity "$endpoint_pid") || exit 1
pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || exit 1
case "$pgid" in ''|*[!0-9]*|0|1) exit 1 ;; esac
[ "$pgid" = "$pid" ] || {
  echo "error: worker launch did not receive an isolated foreground process group" >&2
  exit 1
}
fm_task_process_scope_token_valid "$token" || exit 1
fm_task_process_enclosure_validate "$enclosure" || {
  echo "error: worker launch cannot establish its required PID namespace enclosure" >&2
  exit 1
}
export FM_TASK_PROCESS_SCOPE_TOKEN=$token
anchor_identity=$(fm_task_process_identity "$pid") || exit 1
"$BASH" "$SCRIPT_DIR/fm-task-process-launch.sh" --scope-agent \
  "$record" "$token" "$containment" "$launch" "$enclosure" <&0 &
agent_pid=$!
agent_identity=$(fm_task_process_identity "$agent_pid") || {
  kill -KILL "$agent_pid" 2>/dev/null || true
  exit 1
}
agent_pgid=$(fm_task_process_pgid "$agent_pid") || {
  kill -KILL "$agent_pid" 2>/dev/null || true
  exit 1
}
[ "$agent_pgid" = "$pgid" ] || {
  kill -KILL "$agent_pid" 2>/dev/null || true
  exit 1
}
tmp=$(umask 077; mktemp "$state/.$name.XXXXXX") || {
  kill -KILL "$agent_pid" 2>/dev/null || true
  exit 1
}
scope_launch_cleanup() {
  [ -z "${tmp:-}" ] || rm -f -- "$tmp" 2>/dev/null || true
  [ -z "${agent_pid:-}" ] || kill -KILL "$agent_pid" 2>/dev/null || true
}
trap scope_launch_cleanup EXIT
{
  printf 'version=2\n'
  printf 'status=active\n'
  printf 'token=%s\n' "$token"
  printf 'containment=%s\n' "$containment"
  printf 'anchor_pid=%s\n' "$pid"
  printf 'anchor_identity=%s\n' "$anchor_identity"
  printf 'agent_pid=%s\n' "$agent_pid"
  printf 'agent_identity=%s\n' "$agent_identity"
  printf 'endpoint_pid=%s\n' "$endpoint_pid"
  printf 'endpoint_identity=%s\n' "$endpoint_identity"
  printf 'pgid=%s\n' "$pgid"
} > "$tmp"
chmod 0600 "$tmp"
mv -f -- "$tmp" "$record"
tmp=
trap - EXIT
trap ':' HUP INT TERM
launch_status=0
while :; do
  launch_status=0
  wait "$agent_pid" || launch_status=$?
  fm_task_process_identity_matches "$agent_pid" "$agent_identity" || break
done
while :; do
  snapshot=$(fm_task_process_scope_snapshot "$token" "$pgid" 1 "$pid" 1) || exit 1
  if [ -z "$snapshot" ]; then
    fm_task_process_scope_mark_empty \
      "$record" "$token" "$containment" "$endpoint_pid" "$endpoint_identity" || exit 1
    exit "$launch_status"
  fi
  sleep 0.05
done
