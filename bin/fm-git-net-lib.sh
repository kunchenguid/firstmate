# shellcheck shell=bash
# Shared hard bound for the git network calls on the spawn path.
# Usage: . bin/fm-git-net-lib.sh   then   fm_git_net_run git -C <dir> ls-remote ...
#
# WHY THIS EXISTS. Base-branch resolution (bin/fm-base-branch.sh) is deliberately
# fail-loud: it refuses to launch rather than hand a worker the clone's stale
# cached state. An unbounded network call defeats that contract in the worst
# possible way, because a stalled TCP connect or an unresponsive SSH host never
# resolves either way - the launch neither succeeds nor refuses, it just hangs.
# GIT_TERMINAL_PROMPT=0 already covers the credential-prompt shape of that hang;
# this covers the network shape of it. Every network call the spawn path makes
# therefore runs under a hard deadline.
#
#   FM_GIT_NET_TIMEOUT         seconds allowed per call (default 20)
#   FM_GIT_NET_FORCE_FALLBACK  1 exercises the perl watchdog even where timeout
#                              exists, so tests cover every host's real branch
#
# fm_git_net_run returns the command's own status, 124 when the deadline was hit,
# 128+signal when the command died by a signal without completing, and 199 when no
# watchdog could be started at all. Every one of those is a refusal: a caller
# reports it as loudly as an unreachable remote and never falls back to the
# clone's cached state. Reporting a signal death as success is the failure this
# helper must never produce, because the caller would then trust a FETCH_HEAD that
# a pooled worktree still holds from some earlier task's fetch.

FM_GIT_NET_TIMEOUT_DEFAULT=20
# Seconds between the deadline's SIGTERM and the SIGKILL behind it. Every branch
# escalates identically, so a command that ignores SIGTERM cannot turn a bounded
# call back into the hang this lib exists to prevent.
FM_GIT_NET_KILL_GRACE=0.2
# Deliberately outside every status the watchdogs themselves produce: GNU timeout
# already owns 124 (deadline), 125 (timeout itself failed), 126, and 127, so
# reusing 125 here would report a real watchdog failure as "no watchdog".
FM_GIT_NET_NO_WATCHDOG=199

fm_git_net_timeout() {
  local secs=${FM_GIT_NET_TIMEOUT:-$FM_GIT_NET_TIMEOUT_DEFAULT}
  # A non-positive or non-numeric bound is not a bound: `timeout 0` and the perl
  # fallback's `alarm 0` both disable the deadline outright.
  case "$secs" in
    ''|*[!0-9]*|0*) secs=$FM_GIT_NET_TIMEOUT_DEFAULT ;;
  esac
  printf '%s\n' "$secs"
}

# Bounded execution, mirroring bin/fm-vendor-auth-probe.sh's run_timed selection
# so a macOS host with no GNU coreutils still gets a hard deadline. All three
# branches behave the same: SIGTERM at the deadline, SIGKILL after the grace,
# 124 for the deadline, the command's own status otherwise, and a signal death
# reported as 128+signal rather than swallowed.
fm_git_net_run() {  # <command...>
  local secs use_timeout=1
  secs=$(fm_git_net_timeout)
  [ "${FM_GIT_NET_FORCE_FALLBACK:-0}" != 1 ] || use_timeout=0
  # Never prompt for credentials: an interactive prompt in a spawn path hangs the
  # launch instead of failing it. stdin is closed for the same reason.
  if [ "$use_timeout" -eq 1 ] && command -v timeout >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 timeout -k "${FM_GIT_NET_KILL_GRACE}s" "$secs" "$@" </dev/null
  elif [ "$use_timeout" -eq 1 ] && command -v gtimeout >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 gtimeout -k "${FM_GIT_NET_KILL_GRACE}s" "$secs" "$@" </dev/null
  elif command -v perl >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 perl -e 'my $t = shift; my $g = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, $g; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' \
      "$secs" "$FM_GIT_NET_KILL_GRACE" "$@" </dev/null
  else
    return "$FM_GIT_NET_NO_WATCHDOG"
  fi
}

# The phrase a caller appends to its own refusal so the reason a bounded call
# failed is never guesswork.
fm_git_net_reason() {  # <status>
  local status=$1
  case "$status" in
    124)
      printf 'it did not answer within %ss (FM_GIT_NET_TIMEOUT)\n' "$(fm_git_net_timeout)"
      return 0
      ;;
    "$FM_GIT_NET_NO_WATCHDOG")
      printf 'no bounded-run watchdog (timeout, gtimeout, or perl) is available to bound it\n'
      return 0
      ;;
    125)
      printf 'its bounded-run watchdog could not run it\n'
      return 0
      ;;
  esac
  if [ "$status" -gt 128 ] 2>/dev/null && [ "$status" -lt 256 ] 2>/dev/null; then
    printf 'it was killed by signal %s before it completed\n' "$((status - 128))"
    return 0
  fi
  printf 'the call failed with status %s\n' "$status"
}
