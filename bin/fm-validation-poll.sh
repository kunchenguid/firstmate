#!/usr/bin/env bash
# Read one no-mistakes validation run for a registered task check.
#
# This program is copied into state/<id>.check.sh by fm-validation-check.sh
# after that script pins FM_VALIDATION_WORKTREE as a shell-quoted literal and
# binds the resulting bytes with fm-check-register.sh. It is intentionally
# read-only: it queries only the local no-mistakes CLI, never a provider, and
# prints exactly one line only for a terminal run or an over-age parked gate.
#
# Environment:
#   FM_VALIDATION_WORKTREE        required existing task worktree
#   FM_VALIDATION_PARKED_SECS     parked-age wake threshold (default 240)
#   FM_CHECK_TIMEOUT              watcher bound; the query stays below it
#
# Usage:
#   FM_VALIDATION_WORKTREE=<worktree> fm-validation-poll.sh
#   fm-validation-poll.sh --help
set -u

usage() {
  sed -n '2,17{s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  '') ;;
  *) exit 0 ;;
esac

LC_ALL=C
export LC_ALL

worktree=${FM_VALIDATION_WORKTREE:-}
[ -n "$worktree" ] && [ -d "$worktree" ] || exit 0
command -v no-mistakes >/dev/null 2>&1 || exit 0

parked_secs=${FM_VALIDATION_PARKED_SECS:-240}
query_timeout=5
check_timeout=${FM_CHECK_TIMEOUT:-30}
[[ "$parked_secs" =~ ^[1-9][0-9]{0,7}$ ]] || exit 0
[[ "$query_timeout" =~ ^[1-9][0-9]{0,7}$ ]] || exit 0
[[ "$check_timeout" =~ ^[1-9][0-9]{0,7}$ ]] || exit 0
[ "$check_timeout" -gt 1 ] || exit 0
[ "$query_timeout" -lt "$check_timeout" ] || query_timeout=$((check_timeout - 1))
[ "$query_timeout" -ge 1 ] || exit 0

run_status() {
  if command -v timeout >/dev/null 2>&1; then
    ( cd "$worktree" && timeout "$query_timeout" no-mistakes axi status )
  elif command -v gtimeout >/dev/null 2>&1; then
    ( cd "$worktree" && gtimeout "$query_timeout" no-mistakes axi status )
  elif command -v perl >/dev/null 2>&1; then
    (
      cd "$worktree" || exit 1
      perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
        "$query_timeout" no-mistakes axi status
    )
  else
    return 1
  fi
}

run=$(run_status 2>/dev/null) || exit 0
[ -n "$run" ] || exit 0

field() {
  local key=$1 value
  value=$(printf '%s\n' "$run" | sed -n "s/^[[:space:]]*$key:[[:space:]]*//p" | head -1)
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
  esac
  printf '%s' "$value"
}

terminal=
for value in "$(field outcome)" "$(field status)"; do
  case "$value" in
    passed|failed|cancelled|completed) terminal=$value ;;
  esac
done
if [ -n "$terminal" ]; then
  printf 'validation: terminal %s\n' "$terminal"
  exit 0
fi

awaiting=$(field awaiting_agent)
case "$awaiting" in
  parked\ *) parked_age=${awaiting#parked } ;;
  *) exit 0 ;;
esac
case "$parked_age" in
  *' '*|'') exit 0 ;;
esac
parked_number=${parked_age%?}
parked_unit=${parked_age#"$parked_number"}
[[ "$parked_number" =~ ^[0-9]{1,8}$ ]] || exit 0
case "$parked_unit" in
  s) multiplier=1 ;;
  m) multiplier=60 ;;
  h) multiplier=3600 ;;
  d) multiplier=86400 ;;
  *) exit 0 ;;
esac
parked_age_secs=$((parked_number * multiplier))
[ "$parked_age_secs" -gt "$parked_secs" ] || exit 0
printf 'validation: awaiting_agent parked %ss\n' "$parked_age_secs"
