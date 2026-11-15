#!/usr/bin/env bash
# fm-hold-reason-lib.sh - the one reversible encoding of a captain-hold reason.
#
# tasks-axi stores a hold reason as one markdown line inside a parenthesised tag,
# so its own `hold` refuses parentheses and line breaks. A decision reason is
# ordinary prose, so bin/fm-captain-hold.sh encodes the reason where it writes
# it and every reader that shows it decodes it again, instead of banning the
# characters. Stored reasons use the reserved fm-hold-v1: prefix followed by
# base64-encoded UTF-8 text. Unmarked reasons are plain text. Readers decode only
# the hold-reason field, once, and keep line breaks in quoted output strings.
#
# Source this file; it defines functions only.

# fm_hold_reason_encode <reason>: print the storable form, no trailing newline.
fm_hold_reason_encode() {
  printf '%s' "$1" | perl -MMIME::Base64=encode_base64 -0777 -ne \
    'print "fm-hold-v1:", encode_base64($_, "")'
}

# fm_hold_reason_decode_stream [toon|markdown|json]: decode marked reason fields.
fm_hold_reason_decode_stream() {
  perl -MJSON::PP -MMIME::Base64=encode_base64,decode_base64 -MEncode=decode,FB_CROAK -e '
    use strict;
    use warnings;
    binmode STDIN, ":encoding(UTF-8)";
    binmode STDOUT, ":encoding(UTF-8)";
    my $format = shift;
    my $json = JSON::PP->new->allow_nonref;
    sub decode_reason {
      my ($value) = @_;
      return $value unless defined($value) && $value =~ /^fm-hold-v1:(.*)\z/s;
      my $payload = $1;
      my $bytes = decode_base64($payload);
      return $value unless encode_base64($bytes, "") eq $payload;
      # Historical literals with valid base64 and UTF-8 remain indistinguishable
      # from encoded reasons; malformed payloads retain their stored text.
      my $decoded = eval { decode("UTF-8", $bytes, FB_CROAK) };
      return $@ ? $value : $decoded;
    }
    sub decode_field {
      my ($raw) = @_;
      my $value = $raw =~ /^"/ ? $json->decode($raw) : $raw;
      my $decoded = decode_reason($value);
      return $decoded eq $value ? $raw : $json->encode($decoded);
    }
    if ($format eq "json") {
      local $/;
      my $snapshot = $json->decode(<STDIN>);
      for my $record (@{$snapshot->{records}}) {
        $record->{hold_reason} = decode_reason($record->{hold_reason})
          if exists $record->{hold_reason};
      }
      print $json->encode($snapshot), "\n";
      exit;
    }
    my ($column, $task);
    while (my $line = <STDIN>) {
      if ($format eq "markdown") {
        $line =~ s{^([-*] .*\(hold:\s*)(fm-hold-v1:[A-Za-z0-9+/]*={0,2})(\).*)$}
          {$1 . decode_field($2) . $3}e;
      } elsif ($line =~ /^tasks\[\d+\]\{([^}]*)\}:\n?$/) {
        my @names = split /,/, $1;
        ($column) = grep { $names[$_] eq "hold_reason" } 0 .. $#names;
        $task = 0;
      } elsif (defined($column) && $line =~ /^  (.*)\n?$/) {
        my @fields = $1 =~ /("(?:[^"\\]|\\.)*"|[^,]+)/g;
        $fields[$column] = decode_field($fields[$column]);
        $line = "  " . join(",", @fields) . "\n";
      } elsif ($task && $line =~ /^  hold_reason: (.*)\n?$/) {
        $line = "  hold_reason: " . decode_field($1) . "\n";
      } elsif ($line !~ /^  /) {
        $column = undef;
        $task = $line eq "task:\n";
      }
      print $line;
    }
  ' "${1:-toon}"
}
