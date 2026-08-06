#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
# The timeout owner monitors its checkpoint-shell parent and reaps the exact
# watcher process group if that parent disconnects, including an untrappable
# parent SIGKILL.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}
ROLLOVER_MARKER="$STATE/.watch-checkpoint-rollover"

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--seconds <n>]

Run bin/fm-watch.sh in the foreground for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
An owned watcher exit publishes one single-use marker for the required immediate wake drain.
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

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
trap 'rm -f "$OUT" "$ERR"' EXIT

run_with_perl_timeout() {
  perl -e '
    use POSIX qw(:sys_wait_h);
    use Time::HiRes ();

    my $seconds = shift;
    my $owner = getppid();
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }

    sub stop_child {
      kill "TERM", -$pid;
      for (1 .. 20) {
        my $done = waitpid($pid, WNOHANG);
        return if $done == $pid || $done == -1;
        select undef, undef, undef, 0.05;
      }
      kill "KILL", -$pid;
      waitpid($pid, 0);
    }

    sub exit_from_status {
      my $status = shift;
      exit(($status >> 8) & 255) if WIFEXITED($status);
      exit(128 + WTERMSIG($status)) if WIFSIGNALED($status);
      exit 1;
    }

    local $SIG{HUP} = sub { stop_child(); exit 129; };
    local $SIG{INT} = sub { stop_child(); exit 130; };
    local $SIG{TERM} = sub { stop_child(); exit 143; };

    my $deadline = Time::HiRes::time() + $seconds;
    while (1) {
      my $done = waitpid($pid, WNOHANG);
      exit_from_status($?) if $done == $pid;
      exit 1 if $done == -1;
      if (getppid() != $owner) {
        stop_child();
        exit 143;
      }
      if (Time::HiRes::time() >= $deadline) {
        stop_child();
        exit 124;
      }
      select undef, undef, undef, 0.1;
    }
  ' "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh"
}

write_rollover_marker() {
  local tmp now
  mkdir -p "$STATE" || return 1
  tmp=$(umask 077; mktemp "$STATE/.watch-checkpoint-rollover.XXXXXX") || return 1
  now=$(date +%s)
  if ! printf 'version=1\ncheckpoint_pid=%s\nended_at=%s\n' "${BASHPID:-$$}" "$now" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! mv -f "$tmp" "$ROLLOVER_MARKER"; then
    rm -f "$tmp"
    return 1
  fi
}

# A prior checkpoint marker is valid for one immediate drain only.
# Starting any new checkpoint retires it before watcher ownership changes.
rm -f "$ROLLOVER_MARKER"

set +e
run_with_perl_timeout >"$OUT" 2>"$ERR"
RC=$?
set -e

if grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" >/dev/null 2>&1; then
  if ! write_rollover_marker; then
    cat "$OUT"
    [ ! -s "$ERR" ] || cat "$ERR" >&2
    echo "checkpoint: actionable cycle ended but the rollover marker could not be recorded" >&2
    exit 1
  fi
  cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  exit 0
fi

if grep -E '^watcher: already running' "$OUT" "$ERR" >/dev/null 2>&1; then
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  echo "checkpoint: watcher is already running outside this foreground checkpoint" >&2
  exit 1
fi

if [ "$RC" -eq 124 ]; then
  if ! write_rollover_marker; then
    echo "checkpoint: quiet cycle ended but the rollover marker could not be recorded" >&2
    exit 1
  fi
  printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
  exit 124
fi

[ ! -s "$OUT" ] || cat "$OUT"
[ ! -s "$ERR" ] || cat "$ERR" >&2
exit "$RC"
