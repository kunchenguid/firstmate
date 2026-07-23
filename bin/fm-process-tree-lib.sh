#!/usr/bin/env bash
# Shared bounded command runner for operations whose descendants must be
# terminated and reaped before the caller releases lifecycle or Git locks.
# Usage: fm_run_bounded <positive-seconds> <command> [args...]

fm_run_bounded() {
  local seconds=$1
  shift
  command -v perl >/dev/null 2>&1 || {
    echo "error: perl is required for bounded process-tree control" >&2
    return 127
  }
  # shellcheck disable=SC2016
  perl -e 'sub tree { my ($root) = @_; my %children; open my $ps, "-|", "ps", "-axo", "pid=,ppid=" or return ($root); while (<$ps>) { my ($pid, $ppid) = /(\d+)\s+(\d+)/; push @{$children{$ppid}}, $pid if defined $pid } close $ps; my @out = ($root); for (my $i = 0; $i < @out; $i++) { push @out, @{$children{$out[$i]} || []} } return @out } sub alive { grep { kill 0, $_ } @_ } sub stop_tree { my ($root) = @_; my @seen = tree($root); kill "TERM", reverse @seen; for (1 .. 20) { last unless alive(@seen); select undef, undef, undef, 0.05 } my %seen; @seen = grep { !$seen{$_}++ } (@seen, tree($root)); my @left = alive(@seen); kill "KILL", reverse @left if @left; waitpid $root, 0; for (1 .. 20) { last unless alive(@seen); select undef, undef, undef, 0.05 } } my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { exec @ARGV; exit 127 } local $SIG{ALRM} = sub { stop_tree($pid); exit 124 }; alarm $t; waitpid $pid, 0; alarm 0; my $status = $?; exit(($status & 127) ? 128 + ($status & 127) : $status >> 8)' "$seconds" "$@"
}
