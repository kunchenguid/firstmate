use strict;
use warnings;
use Cwd qw(getcwd);
use Fcntl qw(O_CREAT O_EXCL O_NOFOLLOW O_RDONLY O_RDWR);
use JSON::PP qw(encode_json);
use POSIX qw(dup2);

if (@ARGV && $ARGV[0] eq 'handoff') {
  shift @ARGV;
  my ($inbox_fd, $reservation_fd, $claim_path, $claim_home, $id, $claim_token, $claim_pid,
      $claim_identity, $binding_digest, $reservation_token, $operation, $result_name, $host, @command) = @ARGV;
  die "missing handoff command\n" unless @command && shift(@command) eq "--";
  die "invalid handoff\n" unless defined $inbox_fd && $inbox_fd =~ /\A\d+\z/
    && defined $reservation_fd && $reservation_fd =~ /\A\d+\z/
    && defined $claim_path && $claim_path =~ m{\A/}
    && defined $claim_home && $claim_home =~ m{\A/}
    && defined $id && $id =~ /\A[A-Za-z0-9._-]{1,64}\z/
    && defined $claim_token && $claim_token =~ /\A[A-Za-z0-9._-]{1,256}\z/
    && defined $claim_pid && $claim_pid =~ /\A\d+\z/
    && defined $claim_identity && length($claim_identity)
    && defined $binding_digest && $binding_digest =~ /\Asha256:[a-f0-9]{64}\z/
    && defined $reservation_token && $reservation_token =~ /\A[a-f0-9]{64}\z/
    && defined $operation && ($operation eq 'result.terminal' || $operation eq 'result.silent')
    && defined $result_name && $result_name =~ /\A\.\/[A-Za-z0-9._-]{1,64}\.\d+\.result\z/
    && defined $host && $host =~ m{\A/};
  my ($result_id, $sequence) = $result_name =~ /\A\.\/([A-Za-z0-9._-]{1,64})\.(\d+)\.result\z/;
  die "invalid handoff\n" unless $result_id eq $id && getppid() == $claim_pid;
  open(my $inbox, "<&$inbox_fd") or die "cannot retain inbox\n";
  chdir($inbox) or die "cannot enter inbox\n";
  my $inbox_root = getcwd();
  my @inbox_stat = lstat('.');
  die "unsafe inbox\n" unless @inbox_stat && -d _ && !-l _ && $inbox_stat[4] == $< && ($inbox_stat[2] & 07777) == 0700;
  sysopen(my $result, "$id.$sequence.result", O_RDONLY | O_NOFOLLOW) or die "cannot open result\n";
  my @result_stat = lstat($result_name);
  die "unsafe result\n" unless @result_stat && -f _ && !-l _ && $result_stat[4] == $<
    && ($result_stat[2] & 07777) == 0600 && $result_stat[3] == 1;
  sysopen(my $claim, $claim_path, O_RDONLY | O_NOFOLLOW) or die "cannot open claim\n";
  my @claim_stat = stat($claim);
  die "unsafe claim\n" unless @claim_stat && -f _ && $claim_stat[4] == $<
    && ($claim_stat[2] & 07777) == 0600 && $claim_stat[3] == 1 && $claim_stat[7] <= 4096;
  my $claim_bytes = '';
  while (1) {
    my $read = sysread($claim, my $buffer, 4096);
    defined $read or die "cannot read claim\n";
    last if $read == 0;
    $claim_bytes .= $buffer;
    die "claim too large\n" if length($claim_bytes) > 4096;
  }
  my @claim_lines = split(/\n/, $claim_bytes, -1);
  die "invalid claim\n" unless pop(@claim_lines) eq '' && (@claim_lines == 7 || @claim_lines == 12);
  die "claim changed\n" unless $claim_lines[0] eq $claim_home && $claim_lines[1] eq $claim_pid
    && $claim_lines[2] eq $claim_token && $claim_lines[3] eq $claim_identity && $claim_lines[6] eq 'active';
  if (@claim_lines == 12) {
    die "invalid claim\n" unless $claim_lines[7] =~ m{\A/} && $claim_lines[7] !~ /[\x00-\x1f\x7f]/ && $claim_lines[8] =~ /\A\d+\z/
      && $claim_lines[9] =~ /\A\d+\z/ && $claim_lines[10] =~ /\A\d+\z/
      && $claim_lines[11] =~ /\A[0-7]+\z/ && (oct($claim_lines[11]) & 0022) == 0;
  }
  seek($claim, 0, 0) or die "cannot rewind claim\n";
  open(my $reservation, "<&=$reservation_fd") or die "cannot retain reservation root\n";
  chdir($reservation) or die "cannot enter reservation root\n";
  my @reservation_stat = lstat('.');
  die "unsafe reservation root\n" unless @reservation_stat && -d _ && !-l _ && $reservation_stat[4] == $< && ($reservation_stat[2] & 07777) == 0700;
  dup2(fileno($reservation), 7) >= 0 or die "cannot reserve capability descriptor\n";
  my $capability_name = ".extension-capture-capability-$claim_token.$reservation_token";
  sysopen(my $capability, $capability_name, O_CREAT | O_EXCL | O_NOFOLLOW | O_RDWR, 0600) or die "cannot create capability\n";
  my $record = encode_json({
    schema => 'fm-procevent-capture-capability.v1', token => $reservation_token,
    operation => $operation, source_id => $id, sequence => 0 + $sequence, binding_digest => $binding_digest,
    claim_home => $claim_home, claim_pid => "$claim_pid", claim_identity => $claim_identity, claim_token => $claim_token,
    claim_device => "$claim_stat[0]", claim_inode => "$claim_stat[1]",
    inbox_device => "$inbox_stat[0]", inbox_inode => "$inbox_stat[1]",
    result_device => "$result_stat[0]", result_inode => "$result_stat[1]",
  }) . "\n";
  my $offset = 0;
  while ($offset < length($record)) {
    my $written = syswrite($capability, $record, length($record) - $offset, $offset);
    defined $written && $written > 0 or die "cannot write capability\n";
    $offset += $written;
  }
  seek($capability, 0, 0) or die "cannot rewind capability\n";
  unlink($capability_name) or die "cannot unlink capability\n";
  dup2(fileno($claim), 6) >= 0 or die "cannot install claim descriptor\n";
  dup2(fileno($capability), 7) >= 0 or die "cannot install capability descriptor\n";
  dup2(fileno($inbox), 8) >= 0 or die "cannot install inbox descriptor\n";
  dup2(fileno($result), 9) >= 0 or die "cannot install result descriptor\n";
  chdir($inbox) or die "cannot restore inbox\n";
  delete @ENV{grep { /^FM_PROCEVENT_INTERNAL_CAPTURE_/ } keys %ENV};
  exec {$host} $host, @command;
  die "cannot execute host\n";
}

my ($registry_fd, $inbox_fd, $reservation_fd, $id, $adapter, $extension_id, $extension_version, $capability_version,
    $package_digest, $binding_digest, $claim_token, $runner_name, $output_name,
    $runner_pid, $claim_identity, $limit, @command) = @ARGV;
die "missing command\n" unless @command && shift(@command) eq "--";
die "invalid limit\n" unless defined $limit && $limit =~ /\A\d+\z/;
our ($registry_dir, $registry, $reservation_dir, $reservation_root, $sequence);

sub fail { die "capture failed: $_[0]\n"; }
sub safe_dir {
  my ($path, $mode) = @_;
  my @st = lstat($path);
  return 0 unless @st && -d _ && !-l _ && $st[4] == $<;
  return 0 unless ($st[2] & 0022) == 0;
  return 0 if defined $mode && ($st[2] & 07777) != $mode;
  return 1;
}
sub open_new {
  my ($name) = @_;
  sysopen(my $fh, $name, O_CREAT | O_EXCL | O_NOFOLLOW | O_RDWR, 0600)
    or fail("cannot create $name");
  return $fh;
}
sub write_all {
  my ($fh, $value) = @_;
  my $offset = 0;
  while ($offset < length $value) {
    my $written = syswrite($fh, $value, length($value) - $offset, $offset);
    defined $written && $written > 0 or fail("cannot write evidence");
    $offset += $written;
  }
}
sub copy_all {
  my ($from, $to) = @_;
  while (1) {
    my $read = sysread($from, my $buffer, 65536);
    defined $read or fail("cannot read staged output");
    last if $read == 0;
    write_all($to, $buffer);
  }
}
sub publish_new {
  my ($temporary, $final) = @_;
  link($temporary, $final) or fail("cannot publish $final");
  unlink($temporary) or fail("cannot remove temporary evidence");
}
sub random_token {
  open(my $random, '<', '/dev/urandom') or fail('cannot create capture reservation');
  my $bytes = '';
  while (length($bytes) < 32) {
    my $read = sysread($random, my $buffer, 32 - length($bytes));
    defined $read && $read > 0 or fail('cannot create capture reservation');
    $bytes .= $buffer;
  }
  close($random) or fail('cannot close capture reservation entropy');
  return unpack('H*', $bytes);
}
sub write_reservation {
  my ($token, $operation, $inbox_stat, $result_stat) = @_;
  chdir($reservation_dir) or fail('cannot enter capture reservation directory');
  getcwd() eq $reservation_root or fail('capture reservation directory changed');
  my $reservation = open_new(".extension-capture-$claim_token.$token.json");
  my $record = encode_json({
    schema => 'fm-procevent-capture-reservation.v1', token => $token,
    operation => $operation, source_id => $id, sequence => $sequence,
    inbox_device => "$inbox_stat->[0]", inbox_inode => "$inbox_stat->[1]",
    result_device => "$result_stat->[0]", result_inode => "$result_stat->[1]",
    claim_pid => "$runner_pid", claim_identity => $claim_identity,
    claim_token => $claim_token, binding_digest => $binding_digest,
  }) . "\n";
  write_all($reservation, $record);
  close($reservation) or fail('cannot close capture reservation');
}

$registry_dir = undef;
open($registry_dir, "<&=$registry_fd") or fail("cannot retain registry directory");
chdir($registry_dir) or fail("cannot enter registry directory");
safe_dir(".", 0700) or fail("unsafe registry directory");
$registry = getcwd();
open($reservation_dir, "<&=$reservation_fd") or fail("cannot retain capture reservation directory");
chdir($reservation_dir) or fail("cannot enter capture reservation directory");
safe_dir(".", 0700) or fail("unsafe capture reservation directory");
$reservation_root = getcwd();
open(my $inbox_dir, "<&=$inbox_fd") or fail("cannot retain inbox directory");
chdir($inbox_dir) or fail("cannot enter inbox directory");
safe_dir(".", 0700) or fail("unsafe inbox directory");
chdir($registry_dir) or fail("cannot return to registry directory");
getcwd() eq $registry or fail("registry directory changed");
my $runner = open_new($runner_name);
write_all($runner, "$runner_pid\n");
close($runner) or fail("cannot close runner record");
my $stage = open_new($output_name);
pipe(my $reader, my $writer) or fail("cannot create output pipe");
my $child = fork();
defined $child or fail("cannot fork adapter");
if ($child == 0) {
  close($reader);
  open(STDOUT, ">&", $writer) or exit 126;
  open(STDERR, ">", "/dev/null") or exit 126;
  exec @command;
  exit 127;
}
close($writer);
my ($written, $truncated) = (0, 0);
while (1) {
  my $read = sysread($reader, my $buffer, 65536);
  defined $read or fail("cannot read adapter output");
  last if $read == 0;
  my $take = $written < $limit ? $limit - $written : 0;
  $take = $read if $take > $read;
  if ($take > 0) {
    write_all($stage, substr($buffer, 0, $take));
    $written += $take;
  }
  $truncated = 1 if $take < $read;
}
close($reader);
my $waited = waitpid($child, 0);
my $status = $?;
if ($waited != $child || ($status & 127)) {
  close($stage);
  unlink($output_name);
  unlink($runner_name);
  print "failure\t$truncated\n";
  exit 0;
}
my $rc = $status >> 8;
if ($rc != 0 && $written == 0) {
  unlink($output_name);
  unlink($runner_name);
  print "no-result\t$rc\t$truncated\n";
  exit 0;
}
chdir($inbox_dir) or fail("cannot enter inbox directory");
$sequence = 1;
$sequence++ while -e "$id.$sequence.result" || -l "$id.$sequence.result";
my $prefix = "$id.$sequence";
my $nonce = ".$prefix.$$";
my $result_tmp = "$nonce.result";
my $adapter_tmp = "$nonce.adapter";
my $extension_tmp = "$nonce.extension";
my $result = open_new($result_tmp);
seek($stage, 0, 0) or fail("cannot rewind staged output");
copy_all($stage, $result);
close($result) or fail("cannot close result");
seek($stage, 0, 0) or fail("cannot rewind staged output");
my $adapter_file = open_new($adapter_tmp);
write_all($adapter_file, "$adapter\n");
close($adapter_file) or fail("cannot close adapter evidence");
my $extension_file = open_new($extension_tmp);
write_all($extension_file, join("\n", "schema=fm-procevent-extension-owner.v1", "extension_id=$extension_id", "extension_version=$extension_version", "capability_version=$capability_version", "package_digest=$package_digest", "binding_digest=$binding_digest", ""));
close($extension_file) or fail("cannot close extension evidence");
publish_new($adapter_tmp, "$prefix.adapter");
publish_new($extension_tmp, "$prefix.extension");
publish_new($result_tmp, "$prefix.result");
my @inbox_stat = stat($inbox_dir);
my @result_stat = stat("$prefix.result");
@inbox_stat && @result_stat or fail('cannot stat captured result');
my @reservations;
for my $operation ('result.terminal', 'result.silent') {
  my $token = random_token();
  write_reservation($token, $operation, \@inbox_stat, \@result_stat);
  push(@reservations, $token);
}
close($stage) or fail("cannot close staged output");
chdir($registry_dir) or fail("cannot return to registry directory");
unlink($output_name) or fail("cannot remove staged output");
unlink($runner_name) or fail("cannot remove runner record");
print "captured\t$prefix.result\t$rc\t$truncated\t" . join("\t", @reservations) . "\n";
