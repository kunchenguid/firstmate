#!/usr/bin/env perl
use strict;
use warnings;
use Errno qw(EEXIST ENOENT);
use Fcntl qw(:DEFAULT :mode);
use File::Basename qw(basename dirname);
use Digest::SHA qw(sha256_hex);
use JSON::PP qw(decode_json);

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

sub snapshot_bundle {
  my ($task_path, $config_path, $snapshot_path, $id) = @_;
  $id =~ /\A[A-Za-z0-9._-]+\z/ or fail("SNAPSHOT:task-id");
  my ($task) = open_dir($task_path);
  my ($config) = open_dir($config_path, 1);
  my ($snapshot, $snapshot_st) = open_dir($snapshot_path);
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
  print join("\t", $snapshot_st->[0], $snapshot_st->[1], $pending_st->[0], $pending_st->[1], $config_present, sha256_hex($pending_bytes)), "\n";
}

sub validate_generation {
  my ($generation_dir, $generation, $transaction) = @_;
  my ($receipt, $receipt_st) = open_regular_at($generation_dir, 'receipt.json', 0);
  my ($brief, $brief_st) = open_regular_at($generation_dir, 'brief.md', 0);
  my ($transaction_fh, $transaction_st) = open_regular_at($generation_dir, 'transaction', 0);
  (($receipt_st->[2] & 0777) == 0400 && $receipt_st->[3] == 1) or fail("COLLISION:receipt.json:ownership");
  (($brief_st->[2] & 0777) == 0400 && $brief_st->[3] == 1) or fail("COLLISION:brief.md:ownership");
  (($transaction_st->[2] & 0777) == 0400 && $transaction_st->[3] == 1) or fail("STAGING_COLLISION:transaction:ownership");
  my $receipt_bytes = read_all($receipt);
  my $brief_bytes = read_all($brief);
  sha256_hex($receipt_bytes) eq $generation or fail("COLLISION:receipt.json:generation");
  my $receipt_json = eval { decode_json($receipt_bytes) };
  ref($receipt_json) eq 'HASH' or fail("COLLISION:receipt.json:json");
  my $transaction_bytes = read_all($transaction_fh);
  $transaction_bytes =~ /\A[^\t\n]+\t[^\t\n]+\t([0-9a-f]{64})\n\z/ or fail("STAGING_COLLISION:transaction:format");
  $1 eq sha256_hex($brief_bytes) or fail("COLLISION:brief.md:hash");
  if (defined($transaction)) {
    $transaction_bytes eq $transaction or fail("STAGING_COLLISION:transaction");
  }
  return ($receipt, $receipt_st, $brief, $brief_st, $transaction_bytes);
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
  my $transaction = "$snapshot_dev\t$snapshot_ino\t" . sha256_hex($brief_bytes) . "\n";
  enter_dir($task);
  my $created = mkdir($generation_name, 0700);
  if (!$created && $! != EEXIST) {
    fail("STAGING:$generation_name:$!");
  }
  my ($generation_dir, $generation_st) = open_dir_at($task, $generation_name, 0);
  my $mode = $generation_st->[2] & 0777;
  if ($mode == 0500) {
    fail("CONSUMED");
  }
  $mode == 0700 or fail("STAGING_COLLISION:$generation_name:mode");
  if ($created) {
    create_at($generation_dir, 'transaction', $transaction, 0400) or fail("STAGING_RESIDUE:transaction:$!");
    create_at($generation_dir, 'receipt.json', $receipt_bytes, 0400) or fail("STAGING_RESIDUE:receipt.json:$!");
    create_at($generation_dir, 'brief.md', $brief_bytes, 0400) or fail("STAGING_RESIDUE:brief.md:$!");
  } else {
    validate_generation($generation_dir, $generation, $transaction);
  }
  my ($receipt, $receipt_st, $brief, $brief_st) = validate_generation($generation_dir, $generation, $transaction);
  chmod(0500, $generation_dir) or fail("STAGING_RESIDUE:$generation_name:COMMIT:$!");
  print join("\t", $generation, $receipt_st->[0], $receipt_st->[1], $brief_st->[0], $brief_st->[1], $generation_st->[0], $generation_st->[1]), "\n";
}

sub resolve_receipt {
  my ($receipt_path) = @_;
  basename($receipt_path) eq 'receipt.json' or fail("UNCOMMITTED_RECEIPT:name");
  my $generation_path = dirname($receipt_path);
  my $generation_name = basename($generation_path);
  $generation_name =~ /\Arouting-generation\.([0-9a-f]{64})\z/ or fail("UNCOMMITTED_RECEIPT:generation");
  my $generation = $1;
  my ($generation_dir, $generation_st) = open_dir($generation_path);
  (($generation_st->[2] & 0777) == 0500) or fail("UNCOMMITTED_RECEIPT:stage");
  validate_generation($generation_dir, $generation, undef);
  my $brief_path = "$generation_path/brief.md";
  print "$receipt_path\t$brief_path\n";
}

sub retire_snapshot {
  my ($path, $dev, $ino) = @_;
  my ($snapshot, $snapshot_st) = open_dir($path);
  $snapshot_st->[0] == $dev && $snapshot_st->[1] == $ino or fail("CLEANUP_IDENTITY");
  chmod(0000, $snapshot) or fail("STAGING_RESIDUE:$path:RETIRE:$!");
}

my $operation = shift(@ARGV) // fail('USAGE');
if ($operation eq 'identity') {
  my ($dir, $st) = open_dir($ARGV[0]);
  print "$st->[0]\t$st->[1]\n";
} elsif ($operation eq 'snapshot') {
  snapshot_bundle(@ARGV);
} elsif ($operation eq 'publish') {
  publish_bundle(@ARGV);
} elsif ($operation eq 'resolve') {
  resolve_receipt(@ARGV);
} elsif ($operation eq 'cleanup') {
  retire_snapshot(@ARGV);
} else {
  fail('USAGE');
}
