#!/usr/bin/env perl
use strict;
use warnings;
use Errno qw(EEXIST ENOENT);
use Fcntl qw(:DEFAULT :flock :mode);
use Digest::SHA qw(sha256_hex);
use IO::Handle ();

sub fail {
  print STDERR "$_[0]\n";
  exit 1;
}

sub enter_dir {
  chdir($_[0]) or fail("CHDIR:$!");
}

sub open_dir {
  my ($path, $optional) = @_;
  my $fh;
  if (!sysopen($fh, $path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)) {
    return if $optional && $! == ENOENT;
    fail("OPEN_DIR:$path:$!");
  }
  my @st = stat($fh);
  @st && S_ISDIR($st[2]) or fail("OPEN_DIR:$path:not-directory");
  return ($fh, \@st);
}

sub open_dir_at {
  my ($dir, $name, $optional) = @_;
  enter_dir($dir);
  my $fh;
  if (!sysopen($fh, $name, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)) {
    return if $optional && $! == ENOENT;
    fail("OPEN_DIR:$name:$!");
  }
  my @st = stat($fh);
  @st && S_ISDIR($st[2]) or fail("OPEN_DIR:$name:not-directory");
  return ($fh, \@st);
}

sub open_regular_at {
  my ($dir, $name, $optional) = @_;
  enter_dir($dir);
  my $fh;
  if (!sysopen($fh, $name, O_RDONLY | O_NOFOLLOW)) {
    return if $optional && $! == ENOENT;
    fail("OPEN_REGULAR:$name:$!");
  }
  my @st = stat($fh);
  @st && S_ISREG($st[2]) or fail("OPEN_REGULAR:$name:not-regular");
  return ($fh, \@st);
}

sub read_all {
  my ($fh) = @_;
  seek($fh, 0, 0) or fail("READ:seek:$!");
  my $bytes = '';
  while (1) {
    my $count = sysread($fh, my $chunk, 65536);
    defined($count) or fail("READ:$!");
    last if $count == 0;
    $bytes .= $chunk;
  }
  return $bytes;
}

sub create_at {
  my ($dir, $name, $bytes, $mode) = @_;
  enter_dir($dir);
  sysopen(my $fh, $name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, $mode) or return;
  my @st = stat($fh);
  my $offset = 0;
  while ($offset < length($bytes)) {
    my $count = syswrite($fh, $bytes, length($bytes) - $offset, $offset);
    defined($count) && $count > 0 or fail("STAGING_RESIDUE:$name:WRITE:$!");
    $offset += $count;
  }
  chmod($mode, $fh) or fail("STAGING_RESIDUE:$name:CHMOD:$!");
  return ($fh, \@st);
}

sub copy_at {
  my ($source_dir, $source_name, $target_dir, $target_name, $optional, $mode) = @_;
  $mode //= 0600;
  my ($source) = open_regular_at($source_dir, $source_name, $optional);
  return 0 if !$source;
  my $bytes = read_all($source);
  my ($target) = create_at($target_dir, $target_name, $bytes, $mode);
  $target or fail("CREATE_SNAPSHOT:$target_name:$!");
  return 1;
}

sub open_nested_dir {
  my ($root, @parts) = @_;
  my $current = $root;
  for my $part (@parts) {
    my ($next) = open_dir_at($current, $part, 0);
    $current = $next;
  }
  return $current;
}

sub create_snapshot_dir_at {
  my ($task) = @_;
  enter_dir($task);
  for (1 .. 128) {
    my $name = sprintf('.routing-decision.validate.%08x%08x', $$, int(rand(0xffffffff)));
    if (mkdir($name, 0700)) {
      my ($snapshot, $snapshot_st) = open_dir_at($task, $name, 0);
      ($snapshot_st->[2] & 0777) == 0700 or fail("SNAPSHOT_CREATE:$name:mode");
      return ($name, $snapshot, $snapshot_st);
    }
    $! == EEXIST or fail("SNAPSHOT_CREATE:$name:$!");
  }
  fail('SNAPSHOT_CREATE:collisions');
}

sub snapshot_bundle {
  my ($task_path, $config_path, $id) = @_;
  $id =~ /\A[A-Za-z0-9._-]+\z/ or fail("SNAPSHOT:task-id");
  my ($task) = open_dir($task_path);
  my ($snapshot_name, $snapshot, $snapshot_st) = create_snapshot_dir_at($task);
  my ($config) = open_dir($config_path, 1);
  enter_dir($snapshot);
  mkdir('data', 0700) or fail("SNAPSHOT:data:$!");
  mkdir('config', 0700) or fail("SNAPSHOT:config:$!");
  my $data = open_nested_dir($snapshot, 'data');
  enter_dir($data);
  mkdir($id, 0700) or fail("SNAPSHOT:id:$!");
  my $task_snapshot = open_nested_dir($data, $id);
  my $config_snapshot = open_nested_dir($snapshot, 'config');
  my ($pending, $pending_st) = open_regular_at($task, 'routing-decision.pending.json', 0);
  my $pending_bytes = read_all($pending);
  my ($pending_copy) = create_at($task_snapshot, 'routing-decision.pending.json', $pending_bytes, 0600);
  $pending_copy or fail("SNAPSHOT:pending:$!");
  copy_at($task, 'routing-intent.json', $task_snapshot, 'routing-intent.json', 0);
  copy_at($task, 'brief.md', $task_snapshot, 'brief.md', 0, 0400);
  my $config_present = $config
    ? copy_at($config, 'crew-dispatch.json', $config_snapshot, 'crew-dispatch.json', 1)
    : 0;
  copy_at($task, 'quota-snapshot.json', $task_snapshot, 'quota-snapshot.json', 1);
  print join("\t", $snapshot_name, $snapshot_st->[0], $snapshot_st->[1], $pending_st->[0], $pending_st->[1], $config_present, sha256_hex($pending_bytes)), "\n";
}

sub publish_artifact {
  my ($generation_dir, $name, $bytes) = @_;
  my ($created, $created_st) = create_at($generation_dir, $name, $bytes, 0400);
  return ($created, $created_st) if $created;
  $! == EEXIST or fail("PUBLISH:$name:$!");
  my ($existing, $existing_st) = open_regular_at($generation_dir, $name, 0);
  (($existing_st->[2] & 0777) == 0400 && $existing_st->[3] == 1)
    or fail("COLLISION:$name:ownership");
  read_all($existing) eq $bytes or fail("COLLISION:$name:bytes");
  return ($existing, $existing_st);
}

sub publish_bundle {
  my ($task_path, $snapshot_path, $snapshot_dev, $snapshot_ino, $pending_dev, $pending_ino, $id, $expected_generation) = @_;
  $id =~ /\A[A-Za-z0-9._-]+\z/ or fail("PUBLISH:task-id");
  $expected_generation =~ /\A[0-9a-f]{64}\z/ or fail("PUBLISH:generation");
  my ($task) = open_dir($task_path);
  my ($snapshot, $snapshot_st) = open_dir($snapshot_path);
  $snapshot_st->[0] == $snapshot_dev && $snapshot_st->[1] == $snapshot_ino or fail("SNAPSHOT_IDENTITY");
  my $task_snapshot = open_nested_dir($snapshot, 'data', $id);
  my ($pending, $pending_st) = open_regular_at($task, 'routing-decision.pending.json', 0);
  $pending_st->[0] == $pending_dev && $pending_st->[1] == $pending_ino or fail("PENDING_IDENTITY");
  my ($receipt_source) = open_regular_at($task_snapshot, 'routing-decision.pending.json', 0);
  my ($brief_source) = open_regular_at($task_snapshot, 'brief.md', 0);
  my $receipt_bytes = read_all($receipt_source);
  my $brief_bytes = read_all($brief_source);
  my $generation = sha256_hex($receipt_bytes);
  $generation eq $expected_generation or fail("PUBLISH:generation-mismatch");
  read_all($pending) eq $receipt_bytes or fail("PENDING_BYTES");
  my $generation_name = "routing-generation.$generation";
  enter_dir($task);
  my $created = mkdir($generation_name, 0700);
  if (!$created && $! != EEXIST) {
    fail("STAGING:$generation_name:$!");
  }
  my ($generation_dir, $generation_st) = open_dir_at($task, $generation_name, 0);
  my $mode = $generation_st->[2] & 0777;
  $mode == 0700 or fail("COLLISION:$generation_name:mode");
  publish_artifact($generation_dir, 'receipt.json', $receipt_bytes);
  publish_artifact($generation_dir, 'brief.md', $brief_bytes);
  print "$generation\n";
}

sub hash_regular {
  my ($dir_path, $name) = @_;
  my ($dir) = open_dir($dir_path);
  my ($file) = open_regular_at($dir, $name, 0);
  print sha256_hex(read_all($file)), "\n";
}

sub consume_generation {
  my ($task_path, $generation) = @_;
  $generation =~ /\A[0-9a-f]{64}\z/ or fail("CONSUME:generation");
  my ($task) = open_dir($task_path);
  enter_dir($task);
  my $name = 'routing-generations.consumed';
  my $fh;
  my $created = sysopen($fh, $name, O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0600);
  if (!$created) {
    $! == EEXIST or fail("OPEN_LEDGER:$name:$!");
    sysopen($fh, $name, O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK)
      or fail("OPEN_LEDGER:$name:$!");
  }
  if ($created) {
    chmod(0600, $fh) or fail("LEDGER_CHMOD:$name:$!");
  }
  my @st = stat($fh);
  @st && S_ISREG($st[2]) && ($st[2] & 0777) == 0600 && $st[3] == 1
    or fail("LEDGER_OWNERSHIP:$name");
  flock($fh, LOCK_EX) or fail("LEDGER_LOCK:$name:$!");
  my $bytes = read_all($fh);
  $bytes =~ /\A(?:[0-9a-f]{64}\n)*\z/ or fail("LEDGER_FORMAT:$name");
  index($bytes, "$generation\n") < 0 or fail("CONSUMED_GENERATION:$generation");
  my $record = "$generation\n";
  my $offset = 0;
  while ($offset < length($record)) {
    my $count = syswrite($fh, $record, length($record) - $offset, $offset);
    defined($count) && $count > 0 or fail("LEDGER_WRITE:$name:$!");
    $offset += $count;
  }
  $fh->sync or fail("LEDGER_SYNC:$name:$!");
  if ($created) {
    $task->sync or fail("LEDGER_DIR_SYNC:$name:$!");
  }
  my @path_st = lstat($name);
  @path_st && $path_st[0] == $st[0] && $path_st[1] == $st[1]
    or fail("LEDGER_IDENTITY:$name");
  print "$generation\n";
}

sub verify_committed_generation {
  my ($task_path, $snapshot_path, $snapshot_dev, $snapshot_ino, $id, $expected_generation) = @_;
  $id =~ /\A[A-Za-z0-9._-]+\z/ or fail("VERIFY_COMMITTED:task-id");
  $expected_generation =~ /\A[0-9a-f]{64}\z/ or fail("VERIFY_COMMITTED:generation");
  my ($task) = open_dir($task_path);
  my ($snapshot, $snapshot_st) = open_dir($snapshot_path);
  $snapshot_st->[0] == $snapshot_dev && $snapshot_st->[1] == $snapshot_ino
    or fail("SNAPSHOT_IDENTITY");
  my $task_snapshot = open_nested_dir($snapshot, 'data', $id);
  my ($snapshot_receipt) = open_regular_at($task_snapshot, 'routing-decision.pending.json', 0);
  my ($snapshot_brief) = open_regular_at($task_snapshot, 'brief.md', 0);
  my $receipt_bytes = read_all($snapshot_receipt);
  my $brief_bytes = read_all($snapshot_brief);
  sha256_hex($receipt_bytes) eq $expected_generation
    or fail("VERIFY_COMMITTED:generation-mismatch");

  my ($ledger, $ledger_st) = open_regular_at($task, 'routing-generations.consumed', 0);
  (($ledger_st->[2] & 0777) == 0600 && $ledger_st->[3] == 1)
    or fail("LEDGER_OWNERSHIP:routing-generations.consumed");
  my $ledger_bytes = read_all($ledger);
  $ledger_bytes =~ /\A(?:[0-9a-f]{64}\n)*\z/
    or fail("LEDGER_FORMAT:routing-generations.consumed");
  my @generations = grep { length($_) } split(/\n/, $ledger_bytes);
  @generations && $generations[-1] eq $expected_generation
    or fail("COMMITTED_GENERATION_NOT_LATEST:$expected_generation");
  scalar(grep { $_ eq $expected_generation } @generations) == 1
    or fail("COMMITTED_GENERATION_AMBIGUOUS:$expected_generation");

  my $generation_name = "routing-generation.$expected_generation";
  my ($generation_dir, $generation_st) = open_dir_at($task, $generation_name, 0);
  ($generation_st->[2] & 0777) == 0700
    or fail("COLLISION:$generation_name:mode");
  my ($receipt, $receipt_st) = open_regular_at($generation_dir, 'receipt.json', 0);
  my ($brief, $brief_st) = open_regular_at($generation_dir, 'brief.md', 0);
  (($receipt_st->[2] & 0777) == 0400 && $receipt_st->[3] == 1)
    or fail("COLLISION:receipt.json:ownership");
  (($brief_st->[2] & 0777) == 0400 && $brief_st->[3] == 1)
    or fail("COLLISION:brief.md:ownership");
  read_all($receipt) eq $receipt_bytes or fail("COMMITTED_RECEIPT_BYTES");
  read_all($brief) eq $brief_bytes or fail("COMMITTED_BRIEF_BYTES");
  print "$expected_generation\n";
}

my $operation = shift(@ARGV) // fail('USAGE');
if ($operation eq 'identity') {
  my ($dir, $st) = open_dir($ARGV[0]);
  print "$st->[0]\t$st->[1]\n";
} elsif ($operation eq 'snapshot') {
  snapshot_bundle(@ARGV);
} elsif ($operation eq 'publish') {
  publish_bundle(@ARGV);
} elsif ($operation eq 'hash') {
  hash_regular(@ARGV);
} elsif ($operation eq 'consume-generation') {
  consume_generation(@ARGV);
} elsif ($operation eq 'verify-committed-generation') {
  verify_committed_generation(@ARGV);
} else {
  fail('USAGE');
}
