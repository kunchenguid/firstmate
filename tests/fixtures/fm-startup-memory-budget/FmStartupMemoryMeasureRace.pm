package FmStartupMemoryMeasureRace;
# Test-only sysopen interposer for tests/fm-startup-memory-budget.test.sh.
#
# One bin/fm-startup-memory-budget.sh report run loads it through PERL5OPT:
#   PERL5OPT="-I<repo>/tests/fixtures/fm-startup-memory-budget \
#             -MFmStartupMemoryMeasureRace=<fixture-root>,<replacement>"
# The measurement's first sysopen then renames <replacement> over the regular
# file that open resolves to, reproducing a target replaced between inspection
# and open.  Activation is confined to a tests/lib.sh fixture root:
# <fixture-root> must carry the .fm-test-fixture marker, and the resolved
# target and <replacement> must both sit beneath it on its device.  Every
# other call dies before touching the filesystem, so a real home or memory
# target is never replaced.
use strict;
use warnings;
use Cwd qw(realpath);
use Fcntl qw(:mode);

my ($root, $root_dev, $replacement, $armed);

sub import {
  my ($class, $fixture_root, $replacement_path) = @_;
  (defined $fixture_root && defined $replacement_path)
    or die "$class: usage -M$class=<fixture-root>,<replacement>\n";
  my $real_root = realpath($fixture_root);
  (defined $real_root && -d $real_root && -f "$real_root/.fm-test-fixture")
    or die "$class: $fixture_root is not a tests/lib.sh fixture root\n";
  ($root, $root_dev, $replacement, $armed) =
    ($real_root, (stat $real_root)[0], $replacement_path, 1);
}

sub proven_path {
  my ($label, $path) = @_;
  my $real = realpath($path);
  (defined $real && index($real, "$root/") == 0)
    or die __PACKAGE__ . ": refused $label outside fixture root $root: $path\n";
  my @st = lstat $real;
  (@st && $st[0] == $root_dev)
    or die __PACKAGE__ . ": refused $label off the fixture device: $path\n";
  return ($real, @st);
}

sub replace_target {
  my ($target) = @_;
  my ($real_target, @target_st) = proven_path('target', $target);
  S_ISREG($target_st[2])
    or die __PACKAGE__ . ": refused target that is not a regular file: $target\n";
  my ($real_replacement) = proven_path('replacement', $replacement);
  rename($real_replacement, $real_target)
    or die __PACKAGE__ . ": could not replace $target: $!\n";
}

BEGIN {
  *CORE::GLOBAL::sysopen = sub (*$$;$) {
    if ($armed) {
      $armed = 0;
      replace_target($_[1]);
    }
    return @_ > 3
      ? CORE::sysopen($_[0], $_[1], $_[2], $_[3])
      : CORE::sysopen($_[0], $_[1], $_[2]);
  };
}

1;
