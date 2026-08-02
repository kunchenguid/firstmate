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
#   FM_GIT_NET_TIMEOUT  seconds allowed per call (default 20)
#
# fm_git_net_run returns the command's own status, 124 when the deadline was hit,
# and 125 when the bound could not be established at all. Both are refusals: a
# caller reports them as loudly as an unreachable remote and never falls back to
# the clone's cached state.

FM_GIT_NET_TIMEOUT_DEFAULT=20

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
# so a macOS host with no GNU coreutils still gets a hard deadline. Exit 124 means
# the deadline was hit; 125 means no watchdog could be started, which is a refusal
# too rather than a licence to run the call unbounded.
fm_git_net_run() {  # <command...>
  local secs
  secs=$(fm_git_net_timeout)
  # Never prompt for credentials: an interactive prompt in a spawn path hangs the
  # launch instead of failing it. stdin is closed for the same reason.
  if command -v timeout >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 timeout "$secs" "$@" </dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 gtimeout "$secs" "$@" </dev/null
  elif command -v perl >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$secs" "$@" </dev/null
  else
    return 125
  fi
}

# The phrase a caller appends to its own refusal so the reason a bounded call
# failed is never guesswork.
fm_git_net_reason() {  # <status>
  case "$1" in
    124) printf 'it did not answer within %ss (FM_GIT_NET_TIMEOUT)\n' "$(fm_git_net_timeout)" ;;
    125) printf 'its bounded-run watchdog could not start\n' ;;
    *) printf 'the call failed with status %s\n' "$1" ;;
  esac
}
