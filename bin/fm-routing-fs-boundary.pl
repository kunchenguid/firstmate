#!/usr/bin/env perl
use strict;
use warnings;
use Errno qw(EEXIST ENOENT);
use Fcntl qw(:DEFAULT :mode);
use File::Basename qw(basename dirname);
use Digest::SHA qw(sha256_hex);

my @rollback;
my $rollback_dir;
my $rolling_back = 0;
my $quarantine_counter = 0;

sub fail {
  if (@rollback && !$rolling_back) {
    $rolling_back = 1;
    for my $item (reverse @rollback) {
      quarantine_identity_at($rollback_dir, $item->[0], $item->[1]);
    }
    @rollback = ();
  }
  print STDERR "$_[0]\n";
  exit 1;
}

sub open_dir {
  my ($path) = @_;
  sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY) or fail("OPEN_DIR:$path:$!");
  my @st = stat($fh);
  @st && S_ISDIR($st[2]) or fail("OPEN_DIR:$path:not-directory");
  return ($fh, \@st);
}

sub enter_dir {
  chdir($_[0]) or fail("CHDIR:$!");
}

sub open_regular_at {
  my ($dir, $name, $optional) = @_;
  my $fh;
  enter_dir($dir);
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
  my ($dir, $name, $bytes, $mode, $durable) = @_;
  enter_dir($dir);
  sysopen(my $fh, $name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, $mode)
    or return;
  my @st = stat($fh);
  if ($durable) {
    $rollback_dir = $dir;
    push @rollback, [$name, \@st];
  }
  my $offset = 0;
  while ($offset < length($bytes)) {
    my $count = syswrite($fh, $bytes, length($bytes) - $offset, $offset);
    defined($count) && $count > 0 or fail("WRITE:$name:$!");
    $offset += $count;
  }
  chmod($mode, $fh) or fail("CHMOD:$name:$!");
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

sub existing_at {
  my ($dir, $name, $bytes) = @_;
  my ($fh, $st) = open_regular_at($dir, $name, 1);
  return if !$fh;
  (($st->[2] & 0777) == 0400 && $st->[3] == 1) or fail("COLLISION:$name:ownership");
  read_all($fh) eq $bytes or fail("COLLISION:$name:bytes");
  return ($fh, $st);
}

sub quarantine_identity_at {
  my ($dir, $name, $expected) = @_;
  enter_dir($dir);
  my $quarantine = ".fm-routing-quarantine.$$." . ++$quarantine_counter;
  return 1 if !lstat($name) && $! == ENOENT;
  rename($name, $quarantine) or return 0;
  my @moved = lstat($quarantine);
  if (!@moved || $moved[0] != $expected->[0] || $moved[1] != $expected->[1]) {
    rename($quarantine, $name) if !lstat($name) && $! == ENOENT;
    return 0;
  }
  if (S_ISDIR($moved[2])) {
    sysopen(my $held, $quarantine, O_RDONLY | O_NOFOLLOW | O_DIRECTORY) or return 0;
    remove_contents_dir($held) or return 0;
    enter_dir($dir);
    return rmdir($quarantine);
  }
  return unlink($quarantine);
}

sub open_nested_dir {
  my ($root, @parts) = @_;
  my $current = $root;
  for my $part (@parts) {
    enter_dir($current);
    sysopen(my $next, $part, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)
      or fail("OPEN_DIR:$part:$!");
    my @st = stat($next);
    @st && S_ISDIR($st[2]) or fail("OPEN_DIR:$part:not-directory");
    $current = $next;
  }
  return $current;
}

sub snapshot_bundle {
  my ($task_path, $config_path, $snapshot_path, $id) = @_;
  $id =~ /\A[A-Za-z0-9._-]+\z/ or fail("SNAPSHOT:task-id");
  my ($task, $task_st) = open_dir($task_path);
  my ($config) = open_dir($config_path);
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
  my $config_present = copy_at($config, 'crew-dispatch.json', $config_snapshot, 'crew-dispatch.json', 1);
  copy_at($task, 'quota-snapshot.json', $task_snapshot, 'quota-snapshot.json', 1);
  print join("\t", $snapshot_st->[0], $snapshot_st->[1], $pending_st->[0], $pending_st->[1], $config_present, sha256_hex($pending_bytes)), "\n";
}

sub publish_bundle {
  my ($task_path, $snapshot_path, $snapshot_dev, $snapshot_ino, $pending_dev, $pending_ino, $id, $expected_generation) = @_;
  $id =~ /\A[A-Za-z0-9._-]+\z/ or fail("PUBLISH:task-id");
  $expected_generation =~ /\A[0-9a-f]{64}\z/ or fail("PUBLISH:generation");
  my ($task) = open_dir($task_path);
  my ($snapshot, $snapshot_st) = open_dir($snapshot_path);
  $snapshot_st->[0] == $snapshot_dev && $snapshot_st->[1] == $snapshot_ino
    or fail("SNAPSHOT_IDENTITY");
  my $task_snapshot = open_nested_dir($snapshot, 'data', $id);
  my ($pending, $pending_st) = open_regular_at($task, 'routing-decision.pending.json', 0);
  $pending_st->[0] == $pending_dev && $pending_st->[1] == $pending_ino
    or fail("PENDING_IDENTITY");
  my ($receipt_source) = open_regular_at($task_snapshot, 'routing-decision.pending.json', 0);
  my ($brief_source) = open_regular_at($task_snapshot, 'brief.md', 0);
  my $receipt_bytes = read_all($receipt_source);
  my $brief_bytes = read_all($brief_source);
  my $generation = sha256_hex($receipt_bytes);
  $generation eq $expected_generation or fail("PUBLISH:generation-mismatch");
  read_all($pending) eq $receipt_bytes or fail("PENDING_BYTES");
  my ($receipt_anchor) = create_at($snapshot, 'final.anchor.json', $receipt_bytes, 0400);
  $receipt_anchor or fail("ANCHOR:receipt:$!");
  my ($brief_anchor) = create_at($snapshot, 'brief.anchor.md', $brief_bytes, 0400);
  $brief_anchor or fail("ANCHOR:brief:$!");
  my $receipt_name = "routing-decision.$generation.json";
  my $brief_name = "routing-brief.$generation.md";
  my $marker_name = "routing-decision.$generation.consumed";
  my ($receipt, $receipt_st) = existing_at($task, $receipt_name, $receipt_bytes);
  my ($brief, $brief_st) = existing_at($task, $brief_name, $brief_bytes);
  my ($marker) = open_regular_at($task, $marker_name, 1);
  !$marker or fail("CONSUMED");
  my $receipt_created = 0;
  my $brief_created = 0;
  for my $which ('receipt', 'brief') {
    next if $which eq 'receipt' ? $receipt : $brief;
    my $name = $which eq 'receipt' ? $receipt_name : $brief_name;
    my $bytes = $which eq 'receipt' ? $receipt_bytes : $brief_bytes;
    my ($fh, $st) = create_at($task, $name, $bytes, 0400, 1);
    $fh or fail("CREATE:$name:$!");
    if ($which eq 'receipt') { $receipt = $fh; $receipt_st = $st; $receipt_created = 1; }
    else { $brief = $fh; $brief_st = $st; $brief_created = 1; }
  }
  my ($receipt_final, $receipt_final_st) = open_regular_at($task, $receipt_name, 0);
  my ($brief_final, $brief_final_st) = open_regular_at($task, $brief_name, 0);
  $receipt_final_st->[0] == $receipt_st->[0] && $receipt_final_st->[1] == $receipt_st->[1]
    && read_all($receipt_final) eq $receipt_bytes or fail("FINAL_IDENTITY:receipt");
  $brief_final_st->[0] == $brief_st->[0] && $brief_final_st->[1] == $brief_st->[1]
    && read_all($brief_final) eq $brief_bytes or fail("FINAL_IDENTITY:brief");
  my ($marker_created, $marker_st) = create_at($task, $marker_name, $receipt_bytes, 0400, 1);
  $marker_created or fail("CONSUME:$!");
  my ($marker_final, $marker_final_st) = open_regular_at($task, $marker_name, 0);
  $marker_final_st->[0] == $marker_st->[0] && $marker_final_st->[1] == $marker_st->[1]
    && read_all($marker_final) eq $receipt_bytes or fail("CONSUME_IDENTITY");
  ($receipt_final, $receipt_final_st) = open_regular_at($task, $receipt_name, 0);
  ($brief_final, $brief_final_st) = open_regular_at($task, $brief_name, 0);
  $receipt_final_st->[0] == $receipt_st->[0] && $receipt_final_st->[1] == $receipt_st->[1]
    && read_all($receipt_final) eq $receipt_bytes or fail("FINAL_IDENTITY:receipt");
  $brief_final_st->[0] == $brief_st->[0] && $brief_final_st->[1] == $brief_st->[1]
    && read_all($brief_final) eq $brief_bytes or fail("FINAL_IDENTITY:brief");
  my $manifest = join("\t", $generation, $receipt_st->[0], $receipt_st->[1], $brief_st->[0], $brief_st->[1], $marker_st->[0], $marker_st->[1], $receipt_created, $brief_created) . "\n";
  my ($manifest_fh) = create_at($snapshot, 'publication.manifest', $manifest, 0400);
  $manifest_fh or fail("MANIFEST:$!");
  @rollback = ();
  print $manifest;
}

sub verify_consumed {
  my ($task_path, $snapshot_path, $snapshot_dev, $snapshot_ino) = @_;
  my ($task) = open_dir($task_path);
  my ($snapshot, $snapshot_st) = open_dir($snapshot_path);
  $snapshot_st->[0] == $snapshot_dev && $snapshot_st->[1] == $snapshot_ino or fail("SNAPSHOT_IDENTITY");
  my ($manifest_fh) = open_regular_at($snapshot, 'publication.manifest', 0);
  my $manifest = read_all($manifest_fh);
  chomp($manifest);
  my ($generation, $receipt_dev, $receipt_ino, $brief_dev, $brief_ino, $marker_dev, $marker_ino) = split(/\t/, $manifest, -1);
  $generation =~ /\A[0-9a-f]{64}\z/ or fail("CONSUME:generation");
  my $marker_name = "routing-decision.$generation.consumed";
  my ($marker, $marker_st) = open_regular_at($task, $marker_name, 0);
  $marker_st->[0] == $marker_dev && $marker_st->[1] == $marker_ino or fail("CONSUME_IDENTITY");
  print "$generation\n";
}

sub abort_bundle {
  my ($task_path, $snapshot_path, $snapshot_dev, $snapshot_ino) = @_;
  my ($task) = open_dir($task_path);
  my ($snapshot, $snapshot_st) = open_dir($snapshot_path);
  $snapshot_st->[0] == $snapshot_dev && $snapshot_st->[1] == $snapshot_ino or fail("SNAPSHOT_IDENTITY");
  my ($manifest_fh) = open_regular_at($snapshot, 'publication.manifest', 0);
  my $manifest = read_all($manifest_fh);
  chomp($manifest);
  my ($generation, $receipt_dev, $receipt_ino, $brief_dev, $brief_ino, $marker_dev, $marker_ino, $receipt_created, $brief_created) = split(/\t/, $manifest, -1);
  my $ok = quarantine_identity_at($task, "routing-decision.$generation.consumed", [$marker_dev, $marker_ino]);
  $ok = 0 unless !$brief_created || quarantine_identity_at($task, "routing-brief.$generation.md", [$brief_dev, $brief_ino]);
  $ok = 0 unless !$receipt_created || quarantine_identity_at($task, "routing-decision.$generation.json", [$receipt_dev, $receipt_ino]);
  $ok or fail("ABORT:identity");
}

sub remove_contents_dir {
  my ($dir) = @_;
  enter_dir($dir);
  opendir(my $scan, '.') or return 0;
  my @names = grep { $_ ne '.' && $_ ne '..' } readdir($scan);
  closedir($scan);
  for my $name (@names) {
    enter_dir($dir);
    if (sysopen(my $child, $name, O_RDONLY | O_NOFOLLOW | O_DIRECTORY)) {
      remove_contents_dir($child) or return 0;
      enter_dir($dir);
      rmdir($name) or return 0;
    } else {
      unlink($name) or return 0;
    }
  }
  return 1;
}

sub cleanup {
  my ($path, $dev, $ino) = @_;
  my $parent_path = dirname($path);
  my $name = basename($path);
  my ($parent) = open_dir($parent_path);
  quarantine_identity_at($parent, $name, [$dev, $ino]) or fail("CLEANUP_IDENTITY");
}

my $operation = shift(@ARGV) // fail('USAGE');
if ($operation eq 'identity') {
  my ($dir, $st) = open_dir($ARGV[0]);
  print "$st->[0]\t$st->[1]\n";
} elsif ($operation eq 'snapshot') {
  snapshot_bundle(@ARGV);
} elsif ($operation eq 'publish') {
  publish_bundle(@ARGV);
} elsif ($operation eq 'consume') {
  verify_consumed(@ARGV);
} elsif ($operation eq 'abort') {
  abort_bundle(@ARGV);
} elsif ($operation eq 'cleanup') {
  cleanup(@ARGV);
} else {
  fail('USAGE');
}
