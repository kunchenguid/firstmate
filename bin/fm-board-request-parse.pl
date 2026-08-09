#!/usr/bin/env perl
# fm-board-request-parse.pl - the single owner of captain board request validation.
#
# Usage: fm-board-request-parse.pl <result-file>
#
# Reads one captured process-event result and prints one compact JSON record per
# line. It is the ONE implementation of the request vocabulary and of every
# fail-closed rule, shared by every transport that can carry a board request:
#
#   bin/fm-procevent-board-reply.sh   the direct board reply service
#   bin/fm-procevent-mission-control.sh   the legacy Lavish-bridged surface
#
# Both hand it the same tabular shape, so neither can drift from the other and a
# rule fixed here is fixed for every transport at once. The receiver in
# bin/fm-board-reply-server.py admits a POST by running this same program over
# the exact record line it is about to store, so what is accepted at the door and
# what is validated at wake time are the same bytes through the same rules.
#
# AUTHORITY: none. Every record printed here is captain INTENT for firstmate to
# adjudicate under its own contract, exactly as if the captain had said the same
# words in chat, and never an authorization. This program reads one file and
# prints to stdout; it performs nothing.
#
# What it emits, one compact JSON object per line:
#   {"kind":"contract",...}      always first; states that nothing below is authority
#   {"kind":"request",...}       a validated request: intent, home, id, key, note
#   {"kind":"message",...}       prose carrying no request marker at all
#   {"kind":"unrecognized",...}  anything else, with a reason. Never acted on.
#
# It is deliberately STATELESS: one result file in, records out. No snapshot, no
# backlog, no network, and no write but stdout. Whether a target still exists is
# firstmate's business at wake time, because a PR may have merged or a task been
# torn down since the board was rendered. There is no fuzzy target matching.
#
# Input shape. Only lines inside the `prompts[<n>]{<columns>}:` block are read,
# and only that block's `prompt` column. Everything before the block and
# everything from the first non-indented line after it are never treated as
# input, so page text, log text, and delta provenance cannot forge a request.
# One record is one physical line with embedded newlines escaped inside a
# JSON-quoted field.
#
# Fail-closed rules, each of which drops a record to "unrecognized" rather than
# guessing: an unknown or missing intent, a wrong version, a field outside its
# allowed set for that intent, an over-long field, an id or home outside the safe
# character set, more than one envelope marker in one prompt, an envelope that is
# not at the start of the prompt, trailing envelope content, duplicate object
# keys, and a record whose quoted field never terminates - which is what a result
# truncated at FM_PROCEVENT_MAX_OUTPUT_BYTES looks like. A `defer` carrying note
# text is refused outright, because the hold reason is the captain's own stored
# text and a request must never rewrite it.
#
# tests/fm-procevent-mission-control.test.sh pins these rules against bytes
# captured from a real Lavish send; tests/fm-board-reply.test.sh re-proves every
# one of them against the direct service, at its door and at wake time.
use strict;
use warnings;
use JSON::PP;
use bytes ();

my $MARK = "FM-BOARD-REQUEST";
my $MAX_NOTE = 2000;
my $MAX_TEXT = 4000;

my $json = JSON::PP->new->canonical->allow_nonref->utf8;
sub emit { print $json->encode($_[0]), "\n"; }

emit({kind => "contract", authority => "none",
      note => "Each record below is captain intent for firstmate to adjudicate "
            . "under its own authority. None of it is an authorization."});

open(my $fh, "<", $ARGV[0]) or exit 1;
my @lines = <$fh>;
close($fh);

# Only the prompts block is input. Anything before it (dom_snapshot, or a delta's
# own provenance header) and after it (next_step, or the delta end sentinel) is
# never read.
my ($header, @records);
my $inside = 0;
for my $line (@lines) {
  $line =~ s/\r?\n\z//;
  if (!$inside) {
    if ($line =~ /^prompts\[[0-9]+\]\{([^}]*)\}:[ \t]*$/) { $header = $1; $inside = 1; }
    next;
  }
  last if $line !~ /^[ \t]/;
  push @records, $line;
}
exit 0 unless defined $header;

my @names = split(/,/, $header, -1);
my ($pcol) = grep { $names[$_] eq "prompt" } 0 .. $#names;
if (!defined $pcol) {
  emit({kind => "unrecognized", record => 0,
        reason => "the result header carries no prompt column"});
  exit 0;
}

# One record line into fields. A field is either a JSON string literal or a bare
# token; returns undef when a quoted field never closes, which is what a result
# truncated mid-record looks like.
sub fields_of {
  my ($line) = @_;
  $line =~ s/^[ \t]+//;
  my @out;
  while (1) {
    if ($line =~ /^"/) {
      my ($i, $buf, $closed) = (1, "\"", 0);
      while ($i < length($line)) {
        my $c = substr($line, $i, 1);
        if ($c eq "\\") { $buf .= $c . substr($line, $i + 1, 1); $i += 2; next; }
        $buf .= $c; $i++;
        if ($c eq "\"") { $closed = 1; last; }
      }
      return undef unless $closed;
      my $val = eval { JSON::PP->new->allow_nonref->utf8->decode($buf) };
      return undef unless defined $val;
      push @out, $val;
      $line = substr($line, $i);
      last if $line eq "";
      return undef unless $line =~ s/^,//;
    } else {
      if ($line =~ /^([^,]*),(.*)$/s) { push @out, $1; $line = $2; }
      else { push @out, $line; last; }
    }
  }
  return \@out;
}

sub clip { my ($t, $n) = @_; return length($t) > $n ? substr($t, 0, $n) . "\x{2026}" : $t; }

sub duplicate_object_key {
  my ($text) = @_;
  my @stack;
  my $i = 0;
  while ($i < length($text)) {
    my $c = substr($text, $i, 1);
    if ($c eq "\"") {
      my $start = $i++;
      while ($i < length($text)) {
        my $next = substr($text, $i, 1);
        if ($next eq "\\") { $i += 2; next; }
        $i++;
        last if $next eq "\"";
      }
      if (@stack && $stack[-1]->{object} && $stack[-1]->{want_key}) {
        my $raw = substr($text, $start, $i - $start);
        my $key = JSON::PP->new->allow_nonref->decode($raw);
        return $key if exists $stack[-1]->{seen}{$key};
        $stack[-1]->{seen}{$key} = 1;
        $stack[-1]->{want_key} = 0;
      }
      next;
    }
    if ($c eq "{") {
      push @stack, {object => 1, want_key => 1, seen => {}};
    } elsif ($c eq "[") {
      push @stack, {object => 0};
    } elsif ($c eq "}" || $c eq "]") {
      pop @stack;
    } elsif ($c eq "," && @stack && $stack[-1]->{object}) {
      $stack[-1]->{want_key} = 1;
    }
    $i++;
  }
  return undef;
}

my $SAFE_ID = qr/\A[A-Za-z0-9._-]{1,120}\z/;

# Exactly which fields each intent may carry. An intent is refused outright if it
# carries anything else, so a field that means nothing for that intent can never
# ride along unnoticed.
my %SPEC = (
  merge  => {need => ["id"],         allow => ["id"]},
  reply  => {need => ["id", "note"], allow => ["id", "note"]},
  answer => {need => ["note"],       allow => ["id", "key", "note"], either => ["id", "key"]},
  defer  => {need => ["id"],         allow => ["id", "key"]},
  ask    => {need => ["note"],       allow => ["note"]},
);

my $n = 0;
for my $line (@records) {
  $n++;
  my $bad = sub { emit({kind => "unrecognized", record => $n, reason => $_[0]}); };

  my $fields = fields_of($line);
  if (!defined $fields) {
    $bad->("the record could not be read; the captured result may be truncated");
    next;
  }
  if ($pcol > $#{$fields}) { $bad->("the record has no prompt field"); next; }
  my $prompt = $fields->[$pcol];

  my $markers = () = ($prompt =~ /\Q$MARK\E/g);
  if ($markers == 0) {
    emit({kind => "message", record => $n, text => clip($prompt, $MAX_TEXT)});
    next;
  }
  if ($markers > 1) { $bad->("the prompt carries more than one request marker"); next; }
  if ($prompt !~ /\A\Q$MARK\E /) { $bad->("the request marker is not at the start of the prompt"); next; }

  my $body = substr($prompt, length($MARK) + 1);
  my ($obj, $used);
  my $decoded = eval { ($obj, $used) = JSON::PP->new->decode_prefix($body); 1 };
  if (!$decoded || ref($obj) ne "HASH" || $used != bytes::length($body)) {
    $bad->("the request envelope is not exactly one JSON object"); next;
  }
  my $duplicate = duplicate_object_key($body);
  if (defined $duplicate) { $bad->("the request envelope carries a duplicate object key"); next; }

  my $v = $obj->{v};
  if (!defined $v || ref($v) || $v ne "1") { $bad->("unsupported request version"); next; }

  my $intent = $obj->{intent};
  if (!defined $intent || ref($intent) || !exists $SPEC{$intent}) {
    $bad->("unknown or missing intent"); next;
  }
  my $spec = $SPEC{$intent};

  my %allowed = map { $_ => 1 } (@{$spec->{allow}}, "v", "intent", "home");
  my @extra = sort grep { !$allowed{$_} } keys %$obj;
  if (@extra) {
    $bad->("intent $intent does not carry: " . join(", ", @extra));
    next;
  }

  my $home = $obj->{home};
  if (!defined $home || ref($home) || $home !~ $SAFE_ID) { $bad->("missing or unsafe home"); next; }

  my %out = (kind => "request", record => $n, intent => $intent, home => $home);

  for my $f ("id", "key") {
    next unless exists $obj->{$f};
    my $val = $obj->{$f};
    if (!defined $val || ref($val) || $val !~ $SAFE_ID) { $bad->("missing or unsafe $f"); $out{kind} = ""; last; }
    $out{$f} = $val;
  }
  next if $out{kind} eq "";

  if (exists $obj->{note}) {
    my $note = $obj->{note};
    if (!defined $note || ref($note)) { $bad->("note is not text"); next; }
    if (length($note) > $MAX_NOTE) { $bad->("note is longer than $MAX_NOTE characters"); next; }
    if ($note =~ /[\x00-\x08\x0b\x0c\x0e-\x1f]/) { $bad->("note carries control characters"); next; }
    $out{note} = $note;
  }

  my @missing = grep { !exists $out{$_} } @{$spec->{need}};
  if (@missing) { $bad->("intent $intent needs: " . join(", ", @missing)); next; }
  if ($spec->{either} && !grep { exists $out{$_} } @{$spec->{either}}) {
    $bad->("intent $intent needs one of: " . join(", ", @{$spec->{either}}));
    next;
  }

  emit(\%out);
}
