# fm-remote-herdr-supervisor.pl - keep one command in the foreground of this
# process while that command leads its own POSIX session.
#
# Usage:
#   perl fm-remote-herdr-supervisor.pl <program> [argument...]
#
# bin/fm-remote-herdr-guard.sh execs this in place of `herdr server`, so the
# process launchd supervises for the fm-remote launch agent stays in the
# foreground while the server it starts leads its own session. Herdr advertises
# the detached_server_daemon capability that `herdr machine add` requires only
# for a server process that leads its own session (getsid(0) == getpid()), and
# Herdr arranges that only for servers it spawns itself. launchd starts every
# job as a process-group leader inside launchd's own session, and setsid()
# fails with EPERM in a process-group leader, so the job cannot lead a session
# in place: a forked child calls setsid() and execs the command instead.
# setsid() leaves the macOS audit session alone, so the server keeps the Aqua
# login session and login-keychain access the gui/<uid> domain gives this
# process.
#
# Contract (this header is its single owner):
#   - The child calls setsid(), then execs the command with this process's
#     environment and standard streams. A failed setsid() or exec exits 127.
#   - The child restores XPC_SERVICE_NAME to this process's value before it
#     execs, because macOS sets that variable to 0 in every forked child, and
#     bin/fm-remote-herdr-owner-lib.sh reads the launchd label from it; the
#     server so carries the launchd environment it had as the job itself.
#   - HUP, INT, QUIT, TERM, USR1, and USR2 received here are forwarded to the
#     child, including one that arrives while the child is being started, so
#     launchd's stop signal and `launchctl kill` still reach the server as they
#     did when the server was the job itself. Nothing here shortens the
#     server's shutdown: when launchd's exit timeout ends this process with
#     SIGKILL, the watcher below kills the server, as launchd's SIGKILL did.
#   - A watcher inside the child's process group holds the read end of a pipe
#     that only this process can write. If this process dies without reaping
#     the child, SIGKILL included, the pipe reaches end-of-file and the watcher
#     kills that whole process group, as launchd kills a job's process group.
#   - Once the child exits, every process left in its process group, the
#     watcher included, is killed.
#   - This process exits with the child's exit status, or 128 plus the number of
#     the signal that ended it, so KeepAlive={SuccessfulExit=false} still tells
#     a clean stop from a crash.
#   - Each event prints one line to standard error, which launchd appends to
#     the agent's log.
use strict;
use warnings;
use POSIX ();

my @command = @ARGV;
unless (@command) {
  print STDERR "usage: fm-remote-herdr-supervisor.pl <program> [argument...]\n";
  exit 2;
}

my @forwarded = qw(HUP INT QUIT TERM USR1 USR2);
my $child = 0;
my $service_name = $ENV{XPC_SERVICE_NAME};

sub note { print STDERR "fm-remote-herdr-supervisor: @_\n" }

# Hold the forwarded signals until this process knows the child's pid and the
# child has restored their default dispositions, so the fork loses none.
my $held = POSIX::SigSet->new(
  POSIX::SIGHUP(), POSIX::SIGINT(), POSIX::SIGQUIT(),
  POSIX::SIGTERM(), POSIX::SIGUSR1(), POSIX::SIGUSR2(),
);
POSIX::sigprocmask(POSIX::SIG_BLOCK(), $held) or do {
  note("cannot hold signals while starting the child: $!");
  exit 1;
};
for my $name (@forwarded) {
  $SIG{$name} = sub {
    return unless $child;
    note("forwarding SIG$name to pid $child");
    kill $name, $child;
  };
}

pipe(my $watch_read, my $watch_write) or do {
  note("cannot create the watcher pipe: $!");
  exit 1;
};

my $pid = fork();
unless (defined $pid) {
  note("cannot fork: $!");
  exit 1;
}

if ($pid == 0) {
  $SIG{$_} = 'DEFAULT' for @forwarded;
  close $watch_write;
  unless (defined POSIX::setsid()) {
    note("setsid failed: $!");
    POSIX::_exit(127);
  }
  my $watcher = fork();
  if (defined $watcher && $watcher == 0) {
    # Only this read end and the supervisor's write end keep the pipe open, so
    # end-of-file means the supervisor is gone without having reaped the
    # child. A normal supervisor exit kills this watcher first.
    $SIG{$_} = 'IGNORE' for @forwarded;
    my ($bytes, $buffer);
    do { $bytes = sysread($watch_read, $buffer, 1) } while (!defined $bytes && $!{EINTR});
    my $group = getpgrp();
    note("the supervisor of process group $group is gone; killing that group");
    kill '-KILL', $group if $group > 1;
    POSIX::_exit(0);
  }
  note("cannot fork the watcher, so an abrupt supervisor exit would leave pid $$ running: $!") unless defined $watcher;
  close $watch_read;
  $ENV{XPC_SERVICE_NAME} = $service_name if defined $service_name;
  POSIX::sigprocmask(POSIX::SIG_UNBLOCK(), $held);
  { no warnings 'exec'; exec { $command[0] } @command; }
  note("cannot exec $command[0]: $!");
  POSIX::_exit(127);
}

$child = $pid;
close $watch_read;
note("started pid $child to lead its own session: @command");
POSIX::sigprocmask(POSIX::SIG_UNBLOCK(), $held);

waitpid($child, 0);
my $status = $?;
kill '-KILL', $child;

if ($status & 127) {
  my $signal = $status & 127;
  note("pid $child ended by signal $signal");
  exit 128 + $signal;
}
my $code = $status >> 8;
note("pid $child exited with status $code");
exit $code;
