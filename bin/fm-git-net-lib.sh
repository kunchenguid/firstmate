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
# fm_git_net_run returns the command's own status, FM_GIT_NET_DEADLINE when the
# deadline was hit, 128+signal when the command died by a signal without
# completing, and FM_GIT_NET_NO_WATCHDOG when no watchdog could be started at all.
# Every one of those is a refusal: a caller reports it as loudly as an unreachable
# remote and never falls back to the clone's cached state. Reporting a signal death
# as success is the failure this helper must never produce, because the caller
# would then trust a FETCH_HEAD that a pooled worktree still holds from some
# earlier task's fetch.
#
# Which watchdog ran is this file's business and no caller's. The deadline is
# reported as one canonical status whichever one it was, so a host whose timeout
# reports the deadline as 128+SIGTERM is indistinguishable from GNU's 124.

FM_GIT_NET_TIMEOUT_DEFAULT=20
# Seconds between the deadline's SIGTERM and the SIGKILL behind it. Every branch
# escalates identically, so a command that ignores SIGTERM cannot turn a bounded
# call back into the hang this lib exists to prevent.
FM_GIT_NET_KILL_GRACE=0.2
# The one status a deadline ever produces, normalized from whatever the selected
# watchdog reported. GNU timeout's own value, so the common case needs no mapping.
FM_GIT_NET_DEADLINE=124
# Deliberately outside every status the watchdogs themselves produce: GNU timeout
# already owns 124 (deadline), 125 (timeout itself failed), 126, and 127, so
# reusing 125 here would report a real watchdog failure as "no watchdog".
FM_GIT_NET_NO_WATCHDOG=199
FM_GIT_NET_WATCHDOG=
FM_GIT_NET_WATCHDOG_MODE=

fm_git_net_timeout() {
  local secs=${FM_GIT_NET_TIMEOUT:-$FM_GIT_NET_TIMEOUT_DEFAULT}
  # A non-positive or non-numeric bound is not a bound: `timeout 0` and the perl
  # fallback's `alarm 0` both disable the deadline outright.
  case "$secs" in
    ''|*[!0-9]*|0*) secs=$FM_GIT_NET_TIMEOUT_DEFAULT ;;
  esac
  printf '%s\n' "$secs"
}

# Pick the watchdog once per process, into FM_GIT_NET_WATCHDOG. A binary named
# `timeout` on PATH says nothing about whether it speaks the escalating GNU
# invocation this lib needs: a busybox build rejects it outright, which would
# refuse every ship and scout spawn while the perl watchdog that does work sits
# unreached. So the selected watchdog is made to prove the exact invocation first.
fm_git_net_select_watchdog() {
  local mode=${FM_GIT_NET_FORCE_FALLBACK:-0} candidate
  if [ -n "$FM_GIT_NET_WATCHDOG" ] && [ "$FM_GIT_NET_WATCHDOG_MODE" = "$mode" ]; then
    return 0
  fi
  FM_GIT_NET_WATCHDOG=
  if [ "$mode" != 1 ]; then
    for candidate in timeout gtimeout; do
      command -v "$candidate" >/dev/null 2>&1 || continue
      "$candidate" -k "${FM_GIT_NET_KILL_GRACE}s" 1 true >/dev/null 2>&1 || continue
      FM_GIT_NET_WATCHDOG=$candidate
      break
    done
  fi
  if [ -z "$FM_GIT_NET_WATCHDOG" ] && command -v perl >/dev/null 2>&1; then
    FM_GIT_NET_WATCHDOG=perl
  fi
  [ -n "$FM_GIT_NET_WATCHDOG" ] || FM_GIT_NET_WATCHDOG=none
  FM_GIT_NET_WATCHDOG_MODE=$mode
}

# Bounded execution, mirroring bin/fm-vendor-auth-probe.sh's run_timed selection
# so a macOS host with no GNU coreutils still gets a hard deadline. Every branch
# behaves the same: SIGTERM at the deadline, SIGKILL after the grace,
# FM_GIT_NET_DEADLINE for the deadline, the command's own status otherwise, and a
# signal death reported as 128+signal rather than swallowed.
fm_git_net_run() {  # <command...>
  local secs status=0 started elapsed
  secs=$(fm_git_net_timeout)
  fm_git_net_select_watchdog
  started=$SECONDS
  # Never prompt for credentials: an interactive prompt in a spawn path hangs the
  # launch instead of failing it. stdin is closed for the same reason.
  case "$FM_GIT_NET_WATCHDOG" in
    timeout|gtimeout)
      GIT_TERMINAL_PROMPT=0 "$FM_GIT_NET_WATCHDOG" -k "${FM_GIT_NET_KILL_GRACE}s" "$secs" "$@" \
        </dev/null || status=$?
      ;;
    perl)
      GIT_TERMINAL_PROMPT=0 perl -e 'my $t = shift; my $g = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, $g; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' \
        "$secs" "$FM_GIT_NET_KILL_GRACE" "$@" </dev/null || status=$?
      ;;
    *)
      return "$FM_GIT_NET_NO_WATCHDOG"
      ;;
  esac
  [ "$status" -ne 0 ] || return 0
  elapsed=$((SECONDS - started))
  # A watchdog that reports its deadline as the signal it delivered rather than as
  # GNU's 124 must still look like a deadline to the caller.
  if [ "$status" -eq "$FM_GIT_NET_DEADLINE" ]; then
    return "$FM_GIT_NET_DEADLINE"
  fi
  if [ "$elapsed" -ge "$secs" ] && { [ "$status" -eq 143 ] || [ "$status" -eq 137 ]; }; then
    return "$FM_GIT_NET_DEADLINE"
  fi
  return "$status"
}

# The phrase a caller appends to its own refusal so the reason a bounded call
# failed is never guesswork.
fm_git_net_reason() {  # <status>
  local status=$1
  case "$status" in
    "$FM_GIT_NET_DEADLINE")
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
