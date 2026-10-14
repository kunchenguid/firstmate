#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
#
# SUPERVISION HOST. A home opted in with config/supervision-host
# (docs/configuration.md "Supervision host" owns the gate;
# config/supervision-host-off opts out, and a Codex home without the file does not run the host) runs
# bin/fm-supervision-host.sh in the watcher's place for the checkpoint's bound,
# as the host's park boundary; the host takes away-posture wakes itself and
# returns only when main is needed (its header owns the output read here).
# While an away record state/.afk-contract exists (never quiet mode's, whose
# captain is present: bin/fm-afk-contract.sh mode), the bound is
# raised to FM_CODEX_WATCH_CHECKPOINT_AWAY (default 3600) when that is longer,
# so a parked main is not woken every few minutes; an engine turn that starts
# before the bound may finish after it. A close that carries a wake or a
# "supervision-host:" line other than the park boundary passes through as a
# wake; the boundary alone is the ordinary quiet checkpoint.
#
# Without the host (the plain checkpoint, below the host branch) the cycle runs
# under bin/fm-watch-arm.sh's scheduling continuation; the PLAIN CHECKPOINT
# comment owns the conditions for leaving it running between checkpoints.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--seconds <n>]

Run the watcher cycle for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
Either way the cycle keeps running for the next checkpoint to take over.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

# A checkpoint is neither an ordinary watcher start nor an Option B handling
# successor. It keeps an announced recovery episode stable while preserving the
# watcher's ordinary recovery of a generation that becomes pending.
export FM_WATCH_FOREGROUND_CHECKPOINT=1

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
trap 'rm -f "$OUT" "$ERR"' EXIT

run_with_perl_timeout() {  # <seconds> <signal> <kill-after-seconds> <command...>
  perl -e '
    use POSIX qw(:sys_wait_h);
    my $seconds = shift;
    my $signal = shift;
    my $kill_after = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    my $timed_out = 0;
    local $SIG{ALRM} = sub {
      if ($timed_out) {
        kill "KILL", -$pid;
        waitpid $pid, 0;
        exit 124;
      }
      $timed_out = 1;
      kill $signal, -$pid;
      alarm($kill_after) if $kill_after;
    };
    alarm $seconds;
    while (1) {
      my $waited = waitpid $pid, WNOHANG;
      if ($waited == $pid) {
        alarm 0;
        exit($timed_out ? 124 : ($? >> 8));
      }
      select undef, undef, undef, 0.05;
    }
  ' "$@"
}

run_bounded() {  # <seconds> <signal> <command...>
  local seconds=$1 signal=$2
  shift 2
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal="$signal" "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --signal="$signal" "$seconds" "$@"
  else
    run_with_perl_timeout "$seconds" "$signal" 0 "$@"
  fi
}

positive_or() {  # <value> <default>
  case "$1" in ''|0*|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
if fm_supervision_host_enabled "$CONFIG" codex; then
  BOUND=$SECONDS_ARG
  if [ -f "$STATE/.afk-contract" ] \
    && [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" != quiet ]; then
    AWAY_BOUND=$(positive_or "${FM_CODEX_WATCH_CHECKPOINT_AWAY:-}" 3600)
    [ "$AWAY_BOUND" -le "$BOUND" ] 2>/dev/null || BOUND=$AWAY_BOUND
  fi
  # The host's park boundary stays below the 28800-second registration.
  [ "$BOUND" -lt 27000 ] 2>/dev/null || BOUND=27000
  LIMIT=$(( BOUND + $(positive_or "${FM_SUPERVISION_HOST_TURN_TIMEOUT:-}" 1200) + $(positive_or "${FM_SUPERVISION_ENGINE_GRACE:-}" 30) ))
  set +e
  # The host ends its own park; the outer bound only catches a host that
  # outlived every one of its own bounds.
  FM_SUPERVISION_HOST_PRIMARY=codex FM_SUPERVISION_HOST_PARK_SECONDS=$BOUND FM_SUPERVISION_HOST_PARK_LIMIT=$LIMIT \
    run_bounded $((LIMIT + 120)) TERM "$SCRIPT_DIR/fm-supervision-host.sh" park >"$OUT" 2>"$ERR"
  RC=$?
  set -e
  if grep -E '^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)' "$OUT" 2>/dev/null \
    | grep -Ev '^supervision-host: cycle boundary' >/dev/null; then
    grep -Ev '^watcher: (started|attached) ' "$OUT"
    [ ! -s "$ERR" ] || cat "$ERR" >&2
    exit 0
  fi
  if grep -E '^supervision-host: cycle boundary' "$OUT" >/dev/null 2>&1; then
    printf 'checkpoint: no actionable wake within %ss\n' "$BOUND"
    exit 124
  fi
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  if [ "$RC" -eq 124 ]; then
    echo "checkpoint: the supervision host outlived its own bound of ${BOUND}s" >&2
    exit 1
  fi
  [ "$RC" -ne 0 ] || RC=1
  exit "$RC"
fi

# PLAIN CHECKPOINT. The cycle runs under bin/fm-watch-arm.sh as its continuing
# arm with this checkpoint as the reader (that header, "Scheduling
# continuation"), so the arm, not the model's next checkpoint, restarts the one
# watcher after each actionable close and registered check sweeps carry on
# while the model reasons between checkpoints. The checkpoint is the arm's busy
# reader for its whole run: closes reach it through the arm's spool, the first
# one ends the checkpoint (exit 0), and the quiet bound ends it with exit 124.
# Either outcome can leave the arm running by recording its pid and
# identity in state/.supervision-host-left, the record bin/fm-supervision-host.sh
# detach_successor writes, under the spool lock the arm's continuation decision
# shares. The next checkpoint takes that arm over (--take-over), so one arm owns
# the one watcher. The arm ends on its own conditions: the session lock names
# another session, the away daemon's flag exists, or a take-over. A home with no
# readable session lock pins nothing to continue under, so the bound stops the
# cycle as it always did. Failed ownership persistence also stops the arm.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

LEFT_RECORD="$STATE/.supervision-host-left"
BUSY_FILE="$STATE/.supervision-host-busy"
GUARD_GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
ARM_PID=
ARM_OUT=
ARM_SPOOL=
SPOOL_TEXT=
tab=$'\t'

# Stop the arm, which stops the watcher it owns, and force it once its grace ends.
retire_arm() {
  local i=0
  [ -n "$ARM_PID" ] || return 0
  if fm_pid_alive "$ARM_PID"; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    while [ "$i" -lt 100 ] && fm_pid_alive "$ARM_PID"; do
      sleep 0.1
      i=$((i + 1))
    done
    ! fm_pid_alive "$ARM_PID" || kill -KILL "$ARM_PID" 2>/dev/null || true
  fi
  wait "$ARM_PID" 2>/dev/null || true
  ARM_PID=
}

spool_ready() {
  [ -s "$ARM_SPOOL" ] || return 1
  case "$(tail -n 1 "$ARM_SPOOL" 2>/dev/null)" in S"$tab"*) return 0 ;; esac
  return 1
}

# Leave the arm running for the next checkpoint. Returns 2 when a complete
# notification batch is waiting in the spool and <final> is not given, which
# the caller takes first, and 1 when the arm has nothing to continue under (no session lock
# to pin, or an arm that only attached to another holder's watcher) or could not
# be recorded.
detach_arm() {  # [final]
  local identity tmp=''
  [ -n "$ARM_PID" ] || return 0
  fm_pid_alive "$ARM_PID" || return 1
  [ -n "$(sed -n '1p' "$STATE/.lock" 2>/dev/null | tr -cd '0-9')" ] || return 1
  grep -q '^watcher: started ' "$ARM_OUT" 2>/dev/null || return 1
  fm_lock_acquire_wait "$ARM_SPOOL.lock"
  if [ -z "${1:-}" ] && spool_ready && grep -q "^C$tab" "$ARM_SPOOL"; then
    fm_lock_release "$ARM_SPOOL.lock"
    return 2
  fi
  identity=$(fm_pid_identity "$ARM_PID" 2>/dev/null || true)
  if [ -z "$identity" ] || ! tmp=$(mktemp "$LEFT_RECORD.tmp.XXXXXX" 2>/dev/null) \
    || ! printf '%s\t%s\n' "$ARM_PID" "$identity" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$LEFT_RECORD" 2>/dev/null \
    || [ -L "$LEFT_RECORD" ] || [ ! -f "$LEFT_RECORD" ] \
    || [ "$(cat "$LEFT_RECORD" 2>/dev/null)" != "$ARM_PID$tab$identity" ]; then
    [ -z "$tmp" ] || rm -f "$tmp" "$LEFT_RECORD/${tmp##*/}" 2>/dev/null || true
    fm_lock_release "$ARM_SPOOL.lock"
    return 1
  fi
  fm_lock_release "$ARM_SPOOL.lock"
  # The shell would signal its background job when it exits, and the arm's TERM
  # handler would then stop the watcher.
  disown "$ARM_PID" 2>/dev/null || true
  ARM_PID=
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
plain_cleanup() {
  local rc=$?
  trap - EXIT HUP TERM INT
  detach_arm final || retire_arm
  rm -f "$BUSY_FILE" "$OUT" "$ERR" ${ARM_OUT:+"$ARM_OUT"} ${ARM_SPOOL:+"$ARM_SPOOL"} 2>/dev/null || true
  exit "$rc"
}

# Take the arm's hand-off: the closes it took, then the watcher it restarted (an
# S record). Sets SPOOL_TEXT. Confirming the handling handoff and clearing the
# batch happen under the lock the arm's continuation decision shares.
take_spool() {
  local line rest watcher='' generation=''
  SPOOL_TEXT=
  spool_ready || return 1
  fm_lock_try_acquire "$ARM_SPOOL.lock" || return 1
  if ! spool_ready; then
    fm_lock_release "$ARM_SPOOL.lock"
    return 1
  fi
  while IFS= read -r line; do
    rest=${line#*"$tab"}
    case "$line" in
      C"$tab"*) SPOOL_TEXT=${SPOOL_TEXT:+$SPOOL_TEXT$'\n'}$rest ;;
      S"$tab"*)
        watcher=${rest%%"$tab"*}
        generation=
        case "$rest" in *"$tab"*) generation=${rest#*"$tab"} ;; esac
        ;;
    esac
  done < "$ARM_SPOOL"
  if ! fm_pid_alive "$watcher" \
    || ! fm_watcher_lock_matches_pid "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$watcher" "$FM_HOME" \
    || { [ -n "$generation" ] \
      && ! "$SCRIPT_DIR/fm-watch-arm.sh" --handling-delivered "$generation" --watcher-pid "$watcher" >/dev/null 2>&1; }; then
    SPOOL_TEXT=
    fm_lock_release "$ARM_SPOOL.lock"
    return 1
  fi
  : > "$ARM_SPOOL"
  fm_lock_release "$ARM_SPOOL.lock"
  [ -n "$SPOOL_TEXT" ]
}

# The arm a previous checkpoint left running, while it still answers to the
# identity it was recorded under.
left_arm() {
  local pid='' identity=''
  [ -f "$LEFT_RECORD" ] || return 1
  IFS=$tab read -r pid identity < "$LEFT_RECORD" || true
  if fm_pid_alive "$pid" && [ -n "$identity" ] && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "$identity" ]; then
    printf '%s\n' "$pid"
    return 0
  fi
  rm -f "$LEFT_RECORD"
  return 1
}

# The arm gets a process group of its own, so the harness ending this command
# does not take it down with the checkpoint.
start_arm() {  # [arm argument...]
  ARM_OUT=$(mktemp "$STATE/.supervision-host-arm.XXXXXX") || return 1
  ARM_SPOOL=$(mktemp "$STATE/.supervision-host-spool.XXXXXX") || return 1
  printf '%s\n' "$$" > "$BUSY_FILE" || return 1
  set -m 2>/dev/null || true
  env FM_WATCH_ARM_CONTINUE_READER="$$" FM_WATCH_ARM_CONTINUE_SPOOL="$ARM_SPOOL" FM_WATCH_ARM_CONTINUE_BUSY="$BUSY_FILE" \
    FM_GUARD_GRACE="$GUARD_GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" "$@" >"$ARM_OUT" 2>&1 </dev/null &
  ARM_PID=$!
  set +m 2>/dev/null || true
}

set +e
trap plain_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 143' TERM
trap 'exit 130' INT
START=$SECONDS
if LEFT=$(left_arm); then start_arm --take-over "$LEFT"; else start_arm; fi \
  || { echo "watcher: FAILED - the checkpoint could not start a watcher cycle" >&2; exit 1; }

while :; do
  if take_spool; then
    printf '%s\n' "$SPOOL_TEXT"
    exit 0
  fi
  fm_pid_alive "$ARM_PID" || break
  if [ $((SECONDS - START)) -ge "$SECONDS_ARG" ]; then
    detach_arm
    case $? in
      2)
        if take_spool; then
          printf '%s\n' "$SPOOL_TEXT"
          exit 0
        fi
        detach_arm final || retire_arm
        ;;
      1)
        [ -z "$(sed -n '1p' "$STATE/.lock" 2>/dev/null | tr -cd '0-9')" ] \
          || echo "checkpoint: the watcher cycle could not be left running between checkpoints; scheduled checks wait for the next checkpoint" >&2
        retire_arm
        ;;
    esac
    printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
    exit 124
  fi
  sleep 0.5
done

# The arm ended on its own: a wake it could not continue past (the session lock
# changed, the away daemon owns triage, or no lock pinned a session), or a failure.
wait "$ARM_PID" 2>/dev/null
RC=$?
ARM_PID=
TEXT=$(cat "$ARM_OUT" 2>/dev/null || true)
EARLIER=$(awk -F "$tab" '$1 == "C" { sub(/^C\t/, ""); print }' "$ARM_SPOOL" 2>/dev/null || true)
[ -z "$EARLIER" ] || TEXT=$EARLIER${TEXT:+$'\n'$TEXT}
if printf '%s\n' "$TEXT" | grep -E '^(signal:|stale:|check:|heartbeat($|:))' >/dev/null 2>&1; then
  printf '%s\n' "$TEXT" | grep -Ev '^watcher: (started|attached) '
  exit 0
fi
[ -z "$TEXT" ] || printf '%s\n' "$TEXT"
exit "$RC"
