#!/usr/bin/env perl
use strict;
use warnings;
use Errno qw(EEXIST ENOENT);
use Fcntl qw(:DEFAULT :mode);
use File::Basename qw(basename dirname);

sub fail {
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
  my ($dir, $name, $bytes, $mode) = @_;
  enter_dir($dir);
  sysopen(my $fh, $name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, $mode)
    or return;
  my $offset = 0;
  while ($offset < length($bytes)) {
    my $count = syswrite($fh, $bytes, length($bytes) - $offset, $offset);
    defined($count) && $count > 0 or fail("WRITE:$name:$!");
    $offset += $count;
  }
  chmod($mode, $fh) or fail("CHMOD:$name:$!");
  my @st = stat($fh);
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

sub unlink_identity_at {
  my ($dir, $name, $expected) = @_;
  enter_dir($dir);
  my @current = lstat($name);
  return 1 if !@current && $! == ENOENT;
  return 0 unless @current && $current[0] == $expected->[0] && $current[1] == $expected->[1];
  return unlink($name);
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
  print join("\t", $snapshot_st->[0], $snapshot_st->[1], $pending_st->[0], $pending_st->[1], $config_present), "\n";
}

sub publish_bundle {
  my ($task_path, $snapshot_path, $snapshot_dev, $snapshot_ino, $pending_dev, $pending_ino, $id, $generation) = @_;
  $id =~ /\A[A-Za-z0-9._-]+\z/ or fail("PUBLISH:task-id");
  $generation =~ /\A[0-9a-f]{64}\z/ or fail("PUBLISH:generation");
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
  my @created;
  my @order = $ENV{FM_TEST_ROUTING_FS_ORDER} && $ENV{FM_TEST_ROUTING_FS_ORDER} eq 'brief-first'
    ? ('brief', 'receipt') : ('receipt', 'brief');
  for my $which (@order) {
    next if $which eq 'receipt' ? $receipt : $brief;
    if ($ENV{FM_TEST_ROUTING_FS_COLLIDE_BEFORE} && $ENV{FM_TEST_ROUTING_FS_COLLIDE_BEFORE} eq $which) {
      my $name = $which eq 'receipt' ? $receipt_name : $brief_name;
      my ($collision) = create_at($task, $name, "collision\n", 0400);
      $collision or fail("TEST_COLLISION:$name:$!");
    }
    my $name = $which eq 'receipt' ? $receipt_name : $brief_name;
    my $bytes = $which eq 'receipt' ? $receipt_bytes : $brief_bytes;
    my ($fh, $st) = create_at($task, $name, $bytes, 0400);
    if (!$fh) {
      for my $item (reverse @created) {
        unlink_identity_at($task, $item->[0], $item->[2]) or fail("ROLLBACK_IDENTITY:$item->[0]");
      }
      fail("CREATE:$name:$!");
    }
    push @created, [$name, $fh, $st];
    if ($ENV{FM_TEST_ROUTING_FS_REPLACE_AFTER} && $ENV{FM_TEST_ROUTING_FS_REPLACE_AFTER} eq $which) {
      unlink_identity_at($task, $name, $st) or fail("TEST_REPLACE_UNLINK:$name");
      my ($substitute) = create_at($task, $name, "substitute\n", 0400);
      $substitute or fail("TEST_REPLACE_CREATE:$name:$!");
      for my $item (reverse @created) {
        unlink_identity_at($task, $item->[0], $item->[2]) or fail("ROLLBACK_IDENTITY:$item->[0]");
      }
      fail("TEST_REPLACEMENT:$which");
    }
    if ($ENV{FM_TEST_ROUTING_FS_FAIL_AFTER} && $ENV{FM_TEST_ROUTING_FS_FAIL_AFTER} eq $which) {
      for my $item (reverse @created) {
        unlink_identity_at($task, $item->[0], $item->[2]) or fail("ROLLBACK_IDENTITY:$item->[0]");
      }
      fail("TEST_FAILURE:$which");
    }
    if ($which eq 'receipt') { $receipt = $fh; $receipt_st = $st; }
    else { $brief = $fh; $brief_st = $st; }
  }
  print join("\t", $receipt_st->[0], $receipt_st->[1], $brief_st->[0], $brief_st->[1]), "\n";
}

sub consume {
  my ($task_path, $snapshot_path, $snapshot_dev, $snapshot_ino, $generation, $receipt_dev, $receipt_ino) = @_;
  $generation =~ /\A[0-9a-f]{64}\z/ or fail("CONSUME:generation");
  my ($task) = open_dir($task_path);
  my ($snapshot, $snapshot_st) = open_dir($snapshot_path);
  $snapshot_st->[0] == $snapshot_dev && $snapshot_st->[1] == $snapshot_ino or fail("SNAPSHOT_IDENTITY");
  my ($anchor) = open_regular_at($snapshot, 'final.anchor.json', 0);
  my $anchor_bytes = read_all($anchor);
  my $receipt_name = "routing-decision.$generation.json";
  my ($receipt, $receipt_st) = open_regular_at($task, $receipt_name, 0);
  $receipt_st->[0] == $receipt_dev && $receipt_st->[1] == $receipt_ino or fail("FINAL_IDENTITY");
  read_all($receipt) eq $anchor_bytes or fail("FINAL_BYTES");
  my $marker_name = "routing-decision.$generation.consumed";
  my ($marker_created) = create_at($task, $marker_name, $anchor_bytes, 0400);
  $marker_created or fail("CONSUME:$!");
  my ($marker, $marker_st) = open_regular_at($task, $marker_name, 0);
  read_all($marker) eq $anchor_bytes or fail("CONSUME_IDENTITY");
}

sub remove_contents {
  my ($dir) = @_;
  enter_dir($dir);
  opendir(my $scan, '.') or fail("SCAN:$!");
  my @names = grep { $_ ne '.' && $_ ne '..' } readdir($scan);
  closedir($scan);
  for my $name (@names) {
    enter_dir($dir);
    my @st = lstat($name);
    next if !@st && $! == ENOENT;
    if (S_ISDIR($st[2]) && !S_ISLNK($st[2])) {
      sysopen(my $child, $name, O_RDONLY | O_NOFOLLOW | O_DIRECTORY) or fail("OPEN_CHILD:$name:$!");
      remove_contents($child);
      enter_dir($dir);
      rmdir($name) or fail("RMDIR:$name:$!");
    } else {
      unlink($name) or fail("UNLINK:$name:$!");
    }
  }
}

sub cleanup {
  my ($path, $dev, $ino) = @_;
  my ($dir, $st) = open_dir($path);
  $st->[0] == $dev && $st->[1] == $ino or fail("CLEANUP_IDENTITY");
  remove_contents($dir);
  my $parent_path = dirname($path);
  my $name = basename($path);
  my ($parent) = open_dir($parent_path);
  enter_dir($parent);
  my @current = lstat($name);
  @current && $current[0] == $dev && $current[1] == $ino or fail("CLEANUP_REPLACED");
  rmdir($name) or fail("CLEANUP_RMDIR:$!");
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
  consume(@ARGV);
} elsif ($operation eq 'cleanup') {
  cleanup(@ARGV);
} else {
  fail('USAGE');
}
