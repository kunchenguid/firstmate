#!/usr/bin/env bash
# Execute one tracked Firstmate command in a configured remote secondmate home.
#
# Usage:
#   fm-on.sh [--stdin] [--bounded [--bound-extra <seconds>]] <secondmate-id|unambiguous-ssh-alias> <fm-command> [args...]
#
# Routes come only from remote records in data/secondmates.md. A record names an
# SSH config alias, remote Firstmate code root, and remote FM_HOME. A host alias
# may be used directly only when exactly one record selects it; an ambiguous
# alias is refused. The command must be a genuine executable in this checkout's
# bin/fm-*.sh namespace. No per-command table exists.
#
# argv is encoded as one NUL-delimited stream and passed through the fixed
# fm-remote-entrypoint.sh. The remote command's stdin is /dev/null by default,
# because remote staging captures stdin to EOF and an open caller stream would
# block staging indefinitely; a payload caller passes --stdin to forward its
# own stream as the job's bounded input. stdout and stderr remain separate, and
# ssh's exit status is returned unchanged. OpenSSH never receives an auto-retry
# instruction here. Exit 255 therefore means unavailable transport or unknown
# remote completion and must be reconciled by the semantic caller, never
# blindly repeated by this layer.
#
# The SSH alias keeps normal public-key and strict host-key policy in ~/.ssh.
# This command explicitly disables agent forwarding, forwarding setup, and
# configured SendEnv patterns. The shared fm-remote-job-lib.sh header owns
# the remote command's child environment contract.
#
# ServerAliveInterval/ServerAliveCountMax arm dead-peer detection so a vanished
# peer (a reboot, a dropped link) becomes a bounded ssh failure (exit 255)
# instead of an indefinite hang on a half-open TCP connection. The remote
# sshd answers keepalive probes independently of whatever the remote command
# is doing, so a legitimately long-but-alive remote command is never falsely
# killed. FM_SSH_ALIVE_INTERVAL and FM_SSH_ALIVE_COUNT_MAX override the
# defaults; the worst-case detection window is roughly interval * count.
#
# Keepalives do not bound a remote command that is alive but stuck (a full
# disk, a wedged remote job worker): sshd keeps answering while the command
# never finishes. A caller on a supervision critical path therefore opts in
# with --bounded, which runs ssh under a wall-clock bound of
# FM_REMOTE_CALL_TIMEOUT seconds (default 120) plus any --bound-extra seconds
# the remote command legitimately waits by design. A hit bound is reported as
# exit 255, the same "unavailable transport or unknown remote completion" a
# dead peer produces, with a diagnostic naming the host and the command.
# Each timeout is recorded per SSH alias in state/remote-call-timeouts/<host>
# (count, last_at, bound, command, streak). A command that exits 124 or 137 on
# its own before the bound is a normal completion, not a timeout. While a host's record is younger
# than its backoff - FM_REMOTE_CALL_BACKOFF seconds (default 60) doubled per
# further consecutive timeout, capped at FM_REMOTE_CALL_BACKOFF_MAX (default
# 900) - every --bounded call to that host fails at once with 255 without
# dialing it, so one stuck host costs a supervision cycle at most one bound
# per backoff window. Any --bounded call that completes without hitting the
# bound clears the record. Calls without --bounded keep the unbounded
# behavior above and never consult or change the record. bin/fm-watch.sh
# turns a record whose count reaches FM_REMOTE_CALL_WAKE_AFTER into one wake.
#
# Per-host backoff alone still lets several stuck hosts each spend a bound in
# one supervision cycle. The watcher therefore names a per-cycle budget file in
# FM_REMOTE_CALL_BUDGET_FILE, which its bounded calls share: each adds the
# seconds it spent, a call's bound is cut to what remains of
# FM_REMOTE_CALL_CYCLE_BUDGET seconds (default 150, well under the watcher's
# default 300s stale grace), and once the budget is spent every further
# bounded call that cycle fails at once with 255 without dialing its host. A
# call cut short by the budget fails with 255 but is not recorded as a timeout
# of its host. Without FM_REMOTE_CALL_BUDGET_FILE no budget applies.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"
PROTOCOL=1

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

positive_int() {  # <name> <value> [allow-zero]
  case "$2" in ''|*[!0-9]*) die "$1 must be a non-negative integer: $2" ;; esac
  [ -n "${3:-}" ] || [ "$2" -gt 0 ] || die "$1 must be a positive integer: $2"
}

encode_base64() {
  base64 | tr -d '\n'
}

STDIN_MODE=closed
BOUNDED=0
BOUND_EXTRA=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stdin) STDIN_MODE=caller; shift ;;
    --bounded) BOUNDED=1; shift ;;
    --bound-extra)
      [ "$#" -ge 2 ] || usage
      positive_int --bound-extra "$2" allow-zero
      BOUND_EXTRA=$2
      shift 2
      ;;
    *) break ;;
  esac
done
[ "$#" -ge 2 ] || usage
ROUTE=$1
COMMAND=$2
shift 2

case "$ROUTE" in ''|-*|*[!A-Za-z0-9._-]*) die "remote route must be a safe secondmate id or SSH alias: $ROUTE" ;; esac
case "$COMMAND" in
  fm-*.sh) ;;
  *) die "remote command must be a basename in the fm-*.sh namespace: $COMMAND" ;;
esac
case "$COMMAND" in */*|*..*) die "remote command must not contain a path or traversal: $COMMAND" ;; esac
LOCAL_COMMAND="$FM_ROOT/bin/$COMMAND"
[ -f "$LOCAL_COMMAND" ] && [ ! -L "$LOCAL_COMMAND" ] && [ -x "$LOCAL_COMMAND" ] \
  || die "remote command is not a genuine tracked executable in this Firstmate checkout: $COMMAND"
git -C "$FM_ROOT" ls-files --error-unmatch "bin/$COMMAND" >/dev/null 2>&1 \
  || die "remote command is not tracked by this Firstmate checkout: $COMMAND"
[ -f "$REG" ] && [ ! -L "$REG" ] || die "no safe secondmate registry at $REG"

MATCHES=0
HOST=
ROOT=
HOME_PATH=
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '- '*) ;; *) continue ;; esac
  secondmate_registry_parse_line "$line" || die "malformed secondmate registry entry: $line"
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || continue
  if [ "$SECONDMATE_REGISTRY_ID" = "$ROUTE" ] || [ "$SECONDMATE_REGISTRY_HOST" = "$ROUTE" ]; then
    MATCHES=$((MATCHES + 1))
    HOST=$SECONDMATE_REGISTRY_HOST
    ROOT=$SECONDMATE_REGISTRY_ROOT
    HOME_PATH=$SECONDMATE_REGISTRY_HOME
  fi
done < "$REG"
[ "$MATCHES" -gt 0 ] || die "no remote secondmate or SSH alias matches '$ROUTE'"
[ "$MATCHES" -eq 1 ] || die "remote route '$ROUTE' is ambiguous across $MATCHES configured secondmates; use a secondmate id"
case "$HOST" in ''|-*|*[!A-Za-z0-9._-]*) die "configured SSH alias is unsafe: $HOST" ;; esac
case "$ROOT" in /*) ;; *) die "configured remote root is not absolute: $ROOT" ;; esac
case "$HOME_PATH" in /*) ;; *) die "configured remote home is not absolute: $HOME_PATH" ;; esac
case "$ROOT$HOME_PATH" in *$'\n'*|*$'\r'*|*$'\t'*) die "configured remote root or home contains control characters" ;; esac
for configured_path in "$ROOT" "$HOME_PATH"; do
  case "/$configured_path/" in */../*|*/./*) die "configured remote root or home contains traversal components" ;; esac
  case "$configured_path" in *'//'*) die "configured remote root or home contains an empty path component" ;; esac
done

ROOT_B64=$(printf '%s' "$ROOT" | encode_base64)
HOME_B64=$(printf '%s' "$HOME_PATH" | encode_base64)
ARGV_B64=$(printf '%s\0' "$COMMAND" "$@" | encode_base64)
SSH_BIN=${FM_SSH_BIN:-ssh}
ALIVE_INTERVAL=${FM_SSH_ALIVE_INTERVAL:-15}
ALIVE_COUNT_MAX=${FM_SSH_ALIVE_COUNT_MAX:-3}
case "$ALIVE_INTERVAL" in ''|*[!0-9]*) die "FM_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL" ;; esac
case "$ALIVE_COUNT_MAX" in ''|*[!0-9]*) die "FM_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX" ;; esac
[ "$ALIVE_INTERVAL" -gt 0 ] || die "FM_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL"
[ "$ALIVE_COUNT_MAX" -gt 0 ] || die "FM_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX"

SSH_ARGS=(
  -o ForwardAgent=no
  -o ClearAllForwardings=yes
  -o 'SendEnv=-*'
  -o "ServerAliveInterval=$ALIVE_INTERVAL"
  -o "ServerAliveCountMax=$ALIVE_COUNT_MAX"
  -- "$HOST" fm-remote-entrypoint.sh "$PROTOCOL" "$ROOT_B64" "$HOME_B64" "$ARGV_B64"
)
if [ "$BOUNDED" -eq 0 ]; then
  if [ "$STDIN_MODE" = caller ]; then
    exec "$SSH_BIN" "${SSH_ARGS[@]}"
  fi
  exec "$SSH_BIN" "${SSH_ARGS[@]}" < /dev/null
fi

# --bounded: the wall-clock bound, per-host backoff, and cycle budget described
# in the header.
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
CALL_TIMEOUT=${FM_REMOTE_CALL_TIMEOUT:-120}
BACKOFF_BASE=${FM_REMOTE_CALL_BACKOFF:-60}
BACKOFF_MAX=${FM_REMOTE_CALL_BACKOFF_MAX:-900}
CYCLE_BUDGET=${FM_REMOTE_CALL_CYCLE_BUDGET:-150}
positive_int FM_REMOTE_CALL_TIMEOUT "$CALL_TIMEOUT"
positive_int FM_REMOTE_CALL_BACKOFF "$BACKOFF_BASE" allow-zero
positive_int FM_REMOTE_CALL_BACKOFF_MAX "$BACKOFF_MAX" allow-zero
positive_int FM_REMOTE_CALL_CYCLE_BUDGET "$CYCLE_BUDGET"
BOUND=$((CALL_TIMEOUT + BOUND_EXTRA))
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TIMEOUT_DIR="$STATE_DIR/remote-call-timeouts"
TIMEOUT_RECORD="$TIMEOUT_DIR/$HOST"
BUDGET_FILE=${FM_REMOTE_CALL_BUDGET_FILE:-}
# One line naming the remote command for diagnostics and the wake, with control
# bytes flattened so another machine's arguments cannot shape the record.
CALL_LABEL=$(printf '%s ' "$COMMAND" "$@" | LC_ALL=C tr -c '[:print:]' ' ' | cut -c1-200)
CALL_LABEL=${CALL_LABEL% }

record_field() {  # <field>
  sed -n "s/^$1=//p" "$TIMEOUT_RECORD" 2>/dev/null | head -1
}

NOW=$(date +%s)
if [ -f "$TIMEOUT_RECORD" ] && [ ! -L "$TIMEOUT_RECORD" ]; then
  PRIOR_COUNT=$(record_field count)
  PRIOR_AT=$(record_field last_at)
  case "$PRIOR_COUNT" in ''|*[!0-9]*) PRIOR_COUNT=0 ;; esac
  case "$PRIOR_AT" in ''|*[!0-9]*) PRIOR_AT=0 ;; esac
  BACKOFF=$BACKOFF_BASE
  i=1
  while [ "$i" -lt "$PRIOR_COUNT" ] && [ "$BACKOFF" -lt "$BACKOFF_MAX" ]; do
    BACKOFF=$((BACKOFF * 2))
    i=$((i + 1))
  done
  [ "$BACKOFF" -le "$BACKOFF_MAX" ] || BACKOFF=$BACKOFF_MAX
  if [ "$PRIOR_COUNT" -gt 0 ] && [ "$NOW" -lt $((PRIOR_AT + BACKOFF)) ]; then
    printf 'error: remote host %s is backing off for %ss after %s consecutive timeouts (last: %s); not running %s\n' \
      "$HOST" "$((PRIOR_AT + BACKOFF - NOW))" "$PRIOR_COUNT" "$(record_field command)" "$CALL_LABEL" >&2
    exit 255
  fi
fi

EFFECTIVE_BOUND=$BOUND
SPENT=0
if [ -n "$BUDGET_FILE" ]; then
  SPENT=$(head -1 "$BUDGET_FILE" 2>/dev/null || true)
  case "$SPENT" in ''|*[!0-9]*) SPENT=0 ;; esac
  if [ "$SPENT" -ge "$CYCLE_BUDGET" ]; then
    printf 'error: remote-call budget of %ss for this supervision cycle is spent; not running %s on host %s\n' \
      "$CYCLE_BUDGET" "$CALL_LABEL" "$HOST" >&2
    exit 255
  fi
  [ $((CYCLE_BUDGET - SPENT)) -ge "$BOUND" ] || EFFECTIVE_BOUND=$((CYCLE_BUDGET - SPENT))
fi

# fm_exec_timed replaces a subshell with the bounded ssh, so the call stages no
# temporary files and its watchdog also ends ssh if this process is killed.
RC=0
STARTED=$SECONDS
if [ "$STDIN_MODE" = caller ]; then
  ( fm_exec_timed "$EFFECTIVE_BOUND" 2 "$SSH_BIN" "${SSH_ARGS[@]}" ) || RC=$?
else
  ( fm_exec_timed "$EFFECTIVE_BOUND" 2 "$SSH_BIN" "${SSH_ARGS[@]}" < /dev/null ) || RC=$?
fi
ELAPSED=$((SECONDS - STARTED))
[ -z "$BUDGET_FILE" ] || printf '%s\n' "$((SPENT + ELAPSED))" > "$BUDGET_FILE" 2>/dev/null || true
if ! fm_timed_out "$RC" || [ "$ELAPSED" -lt "$EFFECTIVE_BOUND" ]; then
  [ ! -e "$TIMEOUT_RECORD" ] || rm -f -- "$TIMEOUT_RECORD" 2>/dev/null || true
  exit "$RC"
fi
if [ "$EFFECTIVE_BOUND" -lt "$BOUND" ]; then
  printf 'error: remote command on host %s ran out the remaining %ss of this supervision cycle'"'"'s remote-call budget: %s\n' \
    "$HOST" "$EFFECTIVE_BOUND" "$CALL_LABEL" >&2
  exit 255
fi

COUNT=1 STREAK="$(date +%s)-$$"
if [ -f "$TIMEOUT_RECORD" ] && [ ! -L "$TIMEOUT_RECORD" ]; then
  COUNT=$(record_field count)
  PRIOR_STREAK=$(record_field streak)
  case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
  COUNT=$((COUNT + 1))
  [ -z "$PRIOR_STREAK" ] || STREAK=$PRIOR_STREAK
fi
printf 'error: remote command on host %s timed out after %ss (consecutive timeouts: %s): %s\n' \
  "$HOST" "$BOUND" "$COUNT" "$CALL_LABEL" >&2
if mkdir -p "$TIMEOUT_DIR" 2>/dev/null && [ ! -L "$TIMEOUT_DIR" ] \
  && RECORD_TMP=$(umask 077; mktemp "$TIMEOUT_DIR/.record.XXXXXX" 2>/dev/null); then
  if printf 'count=%s\nlast_at=%s\nbound=%s\ncommand=%s\nstreak=%s\n' \
      "$COUNT" "$(date +%s)" "$BOUND" "$CALL_LABEL" "$STREAK" > "$RECORD_TMP" \
    && mv -f -- "$RECORD_TMP" "$TIMEOUT_RECORD"; then
    :
  else
    rm -f -- "$RECORD_TMP"
  fi
fi
exit 255
