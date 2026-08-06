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
if ! declare -F fm_nm_run >/dev/null 2>&1; then
  poll_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [ -f "$poll_script_dir/fm-nm-run-lib.sh" ] && [ ! -L "$poll_script_dir/fm-nm-run-lib.sh" ] || exit 0
  . "$poll_script_dir/fm-nm-run-lib.sh" || exit 0
fi
command -v no-mistakes >/dev/null 2>&1 || exit 0
worktree_branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "$worktree_branch" ] || exit 0

parked_secs=${FM_VALIDATION_PARKED_SECS:-240}
query_timeout=5
check_timeout=${FM_CHECK_TIMEOUT:-30}
[[ "$parked_secs" =~ ^[1-9][0-9]{0,7}$ ]] || exit 0
[[ "$query_timeout" =~ ^[1-9][0-9]{0,7}$ ]] || exit 0
[[ "$check_timeout" =~ ^[1-9][0-9]{0,7}$ ]] || exit 0
[ "$check_timeout" -gt 1 ] || exit 0
[ "$query_timeout" -lt "$check_timeout" ] || query_timeout=$((check_timeout - 1))
[ "$query_timeout" -ge 1 ] || exit 0

run=$(fm_nm_run "$worktree" "$query_timeout" axi status)
[ -n "$run" ] || exit 0

run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$run" branch)")
[ "$run_branch" = "$worktree_branch" ] || exit 0
run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$run" head)")
fm_nm_head_matches_worktree "$worktree" "$run_head" || exit 0

terminal=
for value in "$(fm_nm_strip_quotes "$(fm_nm_field "$run" outcome)")" "$(fm_nm_strip_quotes "$(fm_nm_field "$run" status)")"; do
  case "$value" in
    passed|failed|cancelled|completed) terminal=$value ;;
  esac
done
if [ -n "$terminal" ]; then
  printf 'validation: terminal %s\n' "$terminal"
  exit 0
fi

awaiting=$(fm_nm_strip_quotes "$(fm_nm_field "$run" awaiting_agent)")
case "$awaiting" in
  parked\ *) parked_age=${awaiting#parked } ;;
  *) exit 0 ;;
esac

duration_seconds() {
  local rest=$1 number unit multiplier rank previous_rank=5 total=0
  [ -n "$rest" ] || return 1
  while [ -n "$rest" ]; do
    [[ "$rest" =~ ^([0-9]{1,8})([smhd])(.*)$ ]] || return 1
    number=${BASH_REMATCH[1]}
    unit=${BASH_REMATCH[2]}
    rest=${BASH_REMATCH[3]}
    case "$unit" in
      s) multiplier=1; rank=1 ;;
      m) multiplier=60; rank=2 ;;
      h) multiplier=3600; rank=3 ;;
      d) multiplier=86400; rank=4 ;;
    esac
    [ "$rank" -lt "$previous_rank" ] || return 1
    total=$((total + 10#$number * multiplier))
    previous_rank=$rank
  done
  printf '%s\n' "$total"
}

parked_age_secs=$(duration_seconds "$parked_age") || exit 0
[ "$parked_age_secs" -gt "$parked_secs" ] || exit 0
printf 'validation: awaiting_agent parked %ss\n' "$parked_age_secs"
