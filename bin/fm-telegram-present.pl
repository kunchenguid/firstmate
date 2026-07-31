#!/usr/bin/env perl
# Deterministic Markdown-subset to Telegram HTML/plain presentation renderer.
# It accepts UTF-8 source on stdin and emits one canonical JSON array of bounded
# same-chat messages. Source HTML is always escaped; only this renderer emits
# Telegram markup, and it emits no buttons or reply markup.
use strict;
use warnings;
use utf8;
use Encode qw(decode encode FB_CROAK);
use JSON::PP;

my $MAX_UNITS = 3500;
my $MAX_SOURCE_UNITS = 24000;

sub utf16_units { return length(encode('UTF-16BE', $_[0])) / 2; }

sub html_escape {
  my ($s, $attr) = @_;
  $s =~ s/&/&amp;/g;
  $s =~ s/</&lt;/g;
  $s =~ s/>/&gt;/g;
  $s =~ s/"/&quot;/g if $attr;
  return $s;
}

sub plain_inline {
  my ($s) = @_;
  $s =~ s/`([^`\n]+)`/$1/g;
  $s =~ s/\[([^\]\n]+)\]\((https?:\/\/[^\s\)]+)\)/$1 ($2)/g;
  $s =~ s/\*\*([^*\n]+)\*\*/$1/g;
  $s =~ s/(?<!\*)\*([^*\n]+)\*(?!\*)/$1/g;
  $s =~ s/_([^_\n]+)_/$1/g;
  return $s;
}

sub rich_inline {
  my ($s) = @_;
  my $out = '';
  while (length $s) {
    if ($s =~ s/^`([^`\n]+)`//) {
      $out .= '<code>' . html_escape($1) . '</code>';
    } elsif ($s =~ s/^\[([^\]\n]+)\]\((https?:\/\/[^\s\)]+)\)//) {
      my ($label, $url) = ($1, $2);
      if (length($url) <= 2048 && $url !~ /[\x00-\x20\x7f]/) {
        $out .= '<a href="' . html_escape($url, 1) . '">' . html_escape(plain_inline($label)) . '</a>';
      } else {
        $out .= html_escape("[$label]($url)");
      }
    } elsif ($s =~ s/^\*\*([^*\n]+)\*\*//) {
      $out .= '<b>' . html_escape($1) . '</b>';
    } elsif ($s =~ s/^\*([^*\n]+)\*//) {
      $out .= '<i>' . html_escape($1) . '</i>';
    } elsif ($s =~ s/^_([^_\n]+)_//) {
      $out .= '<i>' . html_escape($1) . '</i>';
    } else {
      $s =~ s/^(.)//s;
      $out .= html_escape($1);
    }
  }
  return $out;
}

sub grapheme_width {
  my ($g) = @_;
  return 0 if $g =~ /^\pM+$/;
  return 2 if $g =~ /[\x{1F1E6}-\x{1FAFF}\x{1F000}-\x{1F02F}]/;
  return 2 if $g =~ /[\x{2600}-\x{27BF}].*\x{FE0F}/;
  return 2 if $g =~ /\x{20E3}/;
  my $width = 0;
  for my $ch (split //, $g) {
    my $o = ord $ch;
    next if $ch =~ /\pM/ || $o == 0x200D || ($o >= 0xFE00 && $o <= 0xFE0F);
    next if $o < 0x20 || ($o >= 0x7F && $o < 0xA0);
    if (($o >= 0x1100 && $o <= 0x115F)
      || ($o >= 0x2E80 && $o <= 0xA4CF)
      || ($o >= 0xAC00 && $o <= 0xD7A3)
      || ($o >= 0xF900 && $o <= 0xFAFF)
      || ($o >= 0xFE10 && $o <= 0xFE6F)
      || ($o >= 0xFF01 && $o <= 0xFF60)
      || ($o >= 0xFFE0 && $o <= 0xFFE6)) {
      $width += 2;
    } else {
      $width += 1;
    }
  }
  return $width;
}

sub display_width {
  my ($s) = @_;
  my $max = 0;
  for my $line (split /\n/, $s, -1) {
    my $width = 0;
    $width += grapheme_width($_) for ($line =~ /(\X)/g);
    $max = $width if $width > $max;
  }
  return $max;
}

sub pad_width {
  my ($s, $target) = @_;
  my $need = $target - display_width($s);
  return $s . (' ' x ($need > 0 ? $need : 0));
}

sub split_pipe_row {
  my ($line) = @_;
  $line =~ s/^\s*\|//;
  $line =~ s/\|\s*$//;
  my @cells = split /(?<!\\)\|/, $line, -1;
  for (@cells) {
    s/\\\|/|/g;
    s/^\s+|\s+$//g;
  }
  return @cells;
}

sub is_table_separator {
  my ($line) = @_;
  my @cells = split_pipe_row($line);
  return 0 unless @cells;
  for (@cells) { return 0 unless /^:?-{3,}:?$/; }
  return 1;
}

sub split_visible {
  my ($text, $limit, $escaped_limit) = @_;
  my @out;
  my $part = '';
  for my $g ($text =~ /(\X)/g) {
    my @units = utf16_units($g) <= $limit
      && (!defined($escaped_limit) || utf16_units(html_escape($g)) <= $escaped_limit)
      ? ($g)
      : split(//, $g);
    for my $unit (@units) {
      my $candidate = $part . $unit;
      my $fits = utf16_units($candidate) <= $limit
        && (!defined($escaped_limit) || utf16_units(html_escape($candidate)) <= $escaped_limit);
      if (!$fits && length $part) {
        $part =~ s/\s+$//;
        push @out, $part if length $part;
        $part = '';
        $candidate = $unit;
        $fits = utf16_units($candidate) <= $limit
          && (!defined($escaped_limit) || utf16_units(html_escape($candidate)) <= $escaped_limit);
      }
      die "unsplittable visible unit\n" unless $fits;
      $part .= $unit;
    }
  }
  $part =~ s/\s+$//;
  push @out, $part if length $part;
  return @out;
}

my @blocks;
sub add_block {
  my ($rich, $plain) = @_;
  return unless length($rich) || length($plain);
  if (utf16_units($rich) <= $MAX_UNITS && utf16_units($plain) <= $MAX_UNITS) {
    push @blocks, { rich => $rich, plain => $plain };
    return;
  }
  for my $piece (split_visible($plain, 3000, $MAX_UNITS)) {
    push @blocks, { rich => html_escape($piece), plain => $piece };
  }
}

binmode STDIN, ':raw';
local $/;
my $bytes = <STDIN> // '';
my $source = eval { decode('UTF-8', $bytes, FB_CROAK) };
die "invalid utf-8\n" unless defined $source;
$source =~ s/\r\n?/\n/g;
die "control character\n" if $source =~ /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/;
die "source too large\n" if utf16_units($source) > $MAX_SOURCE_UNITS;
$source =~ s/[ \t]+$//mg;
$source =~ s/^\n+|\n+$//g;
die "empty source\n" unless $source =~ /\S/;

my @lines = split /\n/, $source, -1;
for (my $i = 0; $i < @lines;) {
  my $line = $lines[$i];
  if ($line =~ /^```/) {
    my @code;
    $i++;
    push @code, $lines[$i++] while $i < @lines && $lines[$i] !~ /^```\s*$/;
    $i++ if $i < @lines;
    my $code = join "\n", @code;
    for my $piece (split_visible($code, 2900)) {
      add_block('<pre><code>' . html_escape($piece) . '</code></pre>', "Code:\n$piece");
    }
    next;
  }
  if ($i + 1 < @lines && $line =~ /\|/ && is_table_separator($lines[$i + 1])) {
    my @headers = split_pipe_row($line);
    $i += 2;
    my @rows;
    while ($i < @lines && $lines[$i] =~ /\|/ && $lines[$i] !~ /^\s*$/) {
      my @row = split_pipe_row($lines[$i++]);
      push @rows, \@row;
    }
    my $compact = @headers <= 2 && @rows <= 12;
    my @widths;
    for my $c (0 .. $#headers) {
      $widths[$c] = display_width(plain_inline($headers[$c]));
      for my $row (@rows) {
        my $value = plain_inline($row->[$c] // '');
        my $w = display_width($value);
        $widths[$c] = $w if $w > $widths[$c];
      }
    }
    my $total = 3 * $#headers;
    $total += $_ for @widths;
    $compact = 0 if $total > 42;
    if ($compact) {
      my @table_lines;
      push @table_lines, join(' | ', map { pad_width(plain_inline($headers[$_]), $widths[$_]) } 0 .. $#headers);
      push @table_lines, join('-+-', map { '-' x $widths[$_] } 0 .. $#headers);
      for my $row (@rows) {
        push @table_lines, join(' | ', map { pad_width(plain_inline($row->[$_] // ''), $widths[$_]) } 0 .. $#headers);
      }
      my $table = join "\n", @table_lines;
      add_block('<pre>' . html_escape($table) . '</pre>', $table);
    } else {
      my $n = 0;
      for my $row (@rows) {
        $n++;
        my (@rich, @plain);
        for my $c (0 .. $#headers) {
          my $header = plain_inline($headers[$c]);
          my $value = $row->[$c] // '';
          push @rich, '<b>' . html_escape($header) . ':</b> ' . rich_inline($value);
          push @plain, "$header: " . plain_inline($value);
        }
        add_block(join("\n", @rich), join("\n", @plain));
      }
    }
    next;
  }
  if ($line =~ /^(#{1,6})\s+(.+)$/) {
    add_block('<b>' . rich_inline($2) . '</b>', plain_inline($2));
    $i++;
    next;
  }
  if ($line =~ /^>\s?(.*)$/) {
    my @quote;
    while ($i < @lines && $lines[$i] =~ /^>\s?(.*)$/) { push @quote, $1; $i++; }
    add_block('<blockquote>' . rich_inline(join("\n", @quote)) . '</blockquote>', join("\n", map { "> " . plain_inline($_) } @quote));
    next;
  }
  if ($line =~ /^\s*(?:[-+*]|\d+\.)\s+(.+)$/) {
    my (@rich, @plain);
    while ($i < @lines && $lines[$i] =~ /^\s*([-+*]|\d+\.)\s+(.+)$/) {
      my ($marker, $value) = ($1, $2);
      $marker = '•' if $marker !~ /^\d/;
      push @rich, html_escape($marker) . ' ' . rich_inline($value);
      push @plain, "$marker " . plain_inline($value);
      $i++;
    }
    add_block(join("\n", @rich), join("\n", @plain));
    next;
  }
  if ($line =~ /^\s*$/) { $i++; next; }
  my @paragraph;
  while ($i < @lines && $lines[$i] !~ /^\s*$/ && $lines[$i] !~ /^```/ && $lines[$i] !~ /^(?:#{1,6}\s+|>\s?|\s*(?:[-+*]|\d+\.)\s+)/) {
    last if $i + 1 < @lines && $lines[$i] =~ /\|/ && is_table_separator($lines[$i + 1]);
    push @paragraph, $lines[$i++];
  }
  if (@paragraph) {
    my $p = join "\n", @paragraph;
    add_block(rich_inline($p), plain_inline($p));
  }
}

my @messages;
my ($rich, $plain) = ('', '');
for my $block (@blocks) {
  my $next_rich = length($rich) ? "$rich\n\n$block->{rich}" : $block->{rich};
  my $next_plain = length($plain) ? "$plain\n\n$block->{plain}" : $block->{plain};
  if (length($rich) && (utf16_units($next_rich) > $MAX_UNITS || utf16_units($next_plain) > $MAX_UNITS)) {
    push @messages, { rich_text => $rich, plain_text => $plain, display_width => display_width($plain) };
    ($rich, $plain) = ($block->{rich}, $block->{plain});
  } else {
    ($rich, $plain) = ($next_rich, $next_plain);
  }
}
push @messages, { rich_text => $rich, plain_text => $plain, display_width => display_width($plain) } if length $rich;
die "no messages\n" unless @messages;
die "too many messages\n" if @messages > 12;
for my $message (@messages) {
  die "message exceeds rich limit\n" if utf16_units($message->{rich_text}) > $MAX_UNITS;
  die "message exceeds plain limit\n" if utf16_units($message->{plain_text}) > $MAX_UNITS;
}

my $json = JSON::PP->new->canonical(1)->utf8(1);
print $json->encode({ schema => 'firstmate.telegram-presentation.v1', parse_mode => 'HTML', messages => \@messages });
