#!/usr/bin/env bash
# fm-lint-slot.sh - the single owner of the whole-machine bound on concurrent
# ShellCheck processes.
#
# Every layer that launches ShellCheck has its own defensible parallelism
# (fm-test-run.sh files, the lint test's sweep batches, fm-lint.sh's workers),
# and any number of unrelated worktrees can run those layers at once. Their
# product is unbounded, and one full-analysis ShellCheck of a large root holds
# over 1 GiB, so the product is what exhausts a host. This helper bounds the
# TOTAL: it runs a command only while holding one of N per-user, per-host slots,
# so every ShellCheck launch site runs its command through it instead of
# tuning its own number.
#
# Usage:
#   fm-lint-slot.sh <command> [arg]...   run the command under one slot
#   fm-lint-slot.sh --slots              print the resolved slot count
#   fm-lint-slot.sh --help               print this usage
#
# Mechanism: slot i is an exclusive non-blocking flock(2) on
# /tmp/fm-lint-slots.<uid>/slot.<i>, taken through perl because flock(1) is
# absent on macOS and perl is already a lint requirement. The helper then
# exec's the command with the locked descriptor inherited, so the command keeps
# the helper's pid (callers signal it exactly as before) and the kernel drops
# the slot the instant that process dies for any reason, including SIGKILL.
# There is no lock file to go stale and nothing to clean up. The directory is
# deliberately not under TMPDIR, which differs per session and per test;
# FM_LINT_SLOT_DIR overrides it, which isolates a test from the real slots and
# equally splits the bound for anything else that sets it.
#
# Slot count: FM_LINT_SLOTS when set, else half the online CPUs but at least 4,
# capped at half the physical memory in GiB, never below 2. FM_LINT_SLOTS=0
# disables the bound. Half the CPUs because lint never has the host to itself:
# the test scripts around it occupy the rest. At least 4 because that is one
# checkout's own peak (the lint test's sweep batch), so a worker running alone
# never waits. The memory cap is what keeps a small host out of swap.
#
# Safety, in the direction of running rather than hanging:
#   - A slot holder is always the exec'd command and never waits for a slot.
#     The exported FM_LINT_SLOT_HELD marker makes a nested call run directly, so
#     no process can wait on a slot while holding one and deadlock is impossible.
#   - If coordination is unavailable (no perl, the slot directory cannot be
#     created, is a symlink, is not a directory, or is not owned by this user,
#     or a slot file cannot be opened) the command runs immediately, unbounded,
#     and one "fm-lint-slot: ..." line says so.
#   - If no slot frees within FM_LINT_SLOT_WAIT_SECS (default 600) the command
#     runs anyway with the same loud line, so a wedged slot holder elsewhere
#     can delay a run but never stall it.
# Diagnostics go to the descriptor named by FM_LINT_SLOT_DIAG_FD (default 2) so
# a caller that captures the command's stderr keeps it byte-identical; a
# non-default descriptor is closed before the command runs.
# The bound covers this user on this host. Workers under another user, or in a
# sandbox with a private /tmp, hold their own separate slots.
set -u

SELF="${BASH_SOURCE[0]}"

fm_lint_slot_cpu_count() {
  local n
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
  case "$n" in ''|*[!0-9]*) n=2 ;; esac
  printf '%s\n' "$n"
}

fm_lint_slot_mem_gib() {
  local kib='' bytes=''
  if [ -r /proc/meminfo ]; then
    kib=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
  fi
  case "$kib" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' $((kib / 1048576)); return 0 ;;
  esac
  bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
  case "$bytes" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' $((bytes / 1073741824))
}

fm_lint_slot_count() {
  local slots cpus mem
  if [ -n "${FM_LINT_SLOTS:-}" ]; then
    case "$FM_LINT_SLOTS" in
      *[!0-9]*)
        printf 'fm-lint-slot: FM_LINT_SLOTS must be a whole number, got %s.\n' "$FM_LINT_SLOTS" >&2
        return 2
        ;;
    esac
    printf '%s\n' "$FM_LINT_SLOTS"
    return 0
  fi
  cpus=$(fm_lint_slot_cpu_count)
  slots=$((cpus / 2))
  [ "$slots" -ge 4 ] || slots=4
  if mem=$(fm_lint_slot_mem_gib) && [ $((mem / 2)) -lt "$slots" ]; then
    slots=$((mem / 2))
  fi
  [ "$slots" -ge 2 ] || slots=2
  printf '%s\n' "$slots"
}

case "${1:-}" in
  --help|-h)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$SELF"
    exit 0
    ;;
  --slots)
    fm_lint_slot_count
    exit $?
    ;;
  '')
    printf 'fm-lint-slot: a command is required; see --help.\n' >&2
    exit 2
    ;;
esac

SLOTS=$(fm_lint_slot_count) || exit $?
WAIT_SECS=${FM_LINT_SLOT_WAIT_SECS:-600}
case "$WAIT_SECS" in ''|*[!0-9]*) WAIT_SECS=600 ;; esac
DIAG_FD=${FM_LINT_SLOT_DIAG_FD:-2}
case "$DIAG_FD" in ''|*[!0-9]*) DIAG_FD=2 ;; esac

fm_lint_slot_run_unbounded() {  # <reason> <command>...
  local reason=$1
  shift
  if [ -n "$reason" ]; then
    { printf 'fm-lint-slot: %s; running without the machine-wide bound.\n' "$reason" >&"$DIAG_FD"; } 2>/dev/null || true
  fi
  if [ "$DIAG_FD" -ne 2 ]; then
    eval "exec $DIAG_FD>&-"
  fi
  exec "$@"
}

if [ "$SLOTS" -eq 0 ] || [ -n "${FM_LINT_SLOT_HELD:-}" ]; then
  fm_lint_slot_run_unbounded '' "$@"
fi
PERL_BIN=$(command -v perl 2>/dev/null) || fm_lint_slot_run_unbounded 'perl not found' "$@"
export FM_LINT_SLOT_HELD=1

# shellcheck disable=SC2016 # Perl, not the shell, expands these variables.
exec "$PERL_BIN" -e '
  use strict;
  use warnings;
  use Fcntl qw(:flock);
  my ($dir, $slots, $wait, $diag_fd, @cmd) = @ARGV;
  $^F = 1023;  # keep the locked descriptor open across exec
  my $diag;
  open($diag, ">&=", $diag_fd) or undef $diag;
  sub run {
    my ($reason) = @_;
    if (defined $reason && $diag) {
      syswrite($diag, "fm-lint-slot: $reason; running without the machine-wide bound.\n");
    }
    close($diag) if $diag && $diag_fd != 2;
    { no warnings "exec"; exec { $cmd[0] } @cmd; }
    print STDERR "fm-lint-slot: cannot run $cmd[0]: $!\n";
    exit 127;
  }
  mkdir($dir, 0700) unless -e $dir || -l $dir;
  my @st = lstat($dir);
  run("slot directory $dir is unavailable") unless @st;
  run("slot directory $dir is not a directory owned by this user")
    unless -d _ && !-l $dir && $st[4] == $>;
  my @fh;
  for my $i (1 .. $slots) {
    open(my $fh, ">>", "$dir/slot.$i") or run("cannot open slot file $dir/slot.$i: $!");
    push @fh, $fh;
  }
  my $deadline = time() + $wait;
  my $first = $$ % $slots;  # spread simultaneous starters across slots
  while (1) {
    for my $n (0 .. $slots - 1) {
      my $fh = $fh[($first + $n) % $slots];
      next unless flock($fh, LOCK_EX | LOCK_NB);
      for my $other (@fh) { close($other) unless $other == $fh; }
      run(undef);
    }
    run("no slot freed within ${wait}s") if time() >= $deadline;
    select(undef, undef, undef, 0.2);
  }
' "${FM_LINT_SLOT_DIR:-/tmp/fm-lint-slots.$(id -u)}" "$SLOTS" "$WAIT_SECS" "$DIAG_FD" "$@"
