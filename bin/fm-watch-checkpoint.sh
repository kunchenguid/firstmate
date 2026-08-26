#!/usr/bin/env bash
# Run one bounded foreground watcher checkpoint for harnesses that should not
# rely on background-task completion to wake the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
SECONDS_ARG=${FM_CODEX_WATCH_CHECKPOINT:-180}
TERM_GRACE=${FM_WATCH_CHECKPOINT_TERM_GRACE:-2}

usage() {
  cat <<'EOF'
Usage: fm-watch-checkpoint.sh [--seconds <n>]

Run bin/fm-watch.sh in the foreground for a bounded checkpoint.
On an actionable watcher wake, pass through the watcher output and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
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
case "$TERM_GRACE" in
  ''|*[!0-9]*) echo "error: FM_WATCH_CHECKPOINT_TERM_GRACE must be a positive integer" >&2; exit 2 ;;
  0) echo "error: FM_WATCH_CHECKPOINT_TERM_GRACE must be greater than zero" >&2; exit 2 ;;
esac

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/fm-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
trap 'rm -f "$OUT" "$ERR"' EXIT

run_with_perl_timeout() {
  perl -e '
    my $seconds = shift;
    my $term_grace = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      my $deadline = time + $term_grace;
      while (time < $deadline) {
        my $done = waitpid $pid, 1;
        exit 124 if $done == $pid;
        select undef, undef, undef, 0.05;
      }
      kill "KILL", -$pid;
      waitpid $pid, 0;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    exit($? >> 8);
  ' "$SECONDS_ARG" "$TERM_GRACE" "$SCRIPT_DIR/fm-watch.sh"
}

cleanup_timed_out_watcher_lock() {
  local lock pid lock_home lock_path
  lock="$STATE/.watch.lock"
  [ -e "$lock" ] || [ -L "$lock" ] || return 0
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  [ -n "$pid" ] || return 0
  fm_pid_alive "$pid" && return 0
  lock_home=$(cat "$lock/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lock/watcher-path" 2>/dev/null || true)
  [ -z "$lock_home" ] || [ "$lock_home" = "$FM_HOME" ] || return 0
  [ -z "$lock_path" ] || [ "$lock_path" = "$SCRIPT_DIR/fm-watch.sh" ] || return 0
  fm_lock_remove_path "$lock" || true
}

set +e
if command -v timeout >/dev/null 2>&1; then
  timeout "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR"
  RC=$?
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout "$SECONDS_ARG" "$SCRIPT_DIR/fm-watch.sh" >"$OUT" 2>"$ERR"
  RC=$?
else
  run_with_perl_timeout >"$OUT" 2>"$ERR"
  RC=$?
fi
set -e

if grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" >/dev/null 2>&1; then
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
  cleanup_timed_out_watcher_lock
  printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
  exit 124
fi

[ ! -s "$OUT" ] || cat "$OUT"
[ ! -s "$ERR" ] || cat "$ERR" >&2
exit "$RC"
