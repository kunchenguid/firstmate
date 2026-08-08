#!/usr/bin/env bash
# Mission control adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-mission-control.sh arm <board.html>
#   fm-procevent-mission-control.sh requests <result-file>
#   fm-procevent-mission-control.sh classify <result-file>
#   fm-procevent-mission-control.sh terminal <result-file>
#   fm-procevent-mission-control.sh source-id <board.html>
#   fm-procevent-mission-control.sh retire <board.html>
#
# arm        Register the captain reply surface: the mission control board
#            rendered with --controls, polled through Lavish. The wake it
#            produces is `procevent mission-control <source-id> <sequence>`,
#            which is the whole reason this adapter exists rather than reusing
#            the lavish one - it SELF-IDENTIFIES. Captain action requests and
#            ordinary artifact review feedback arrive through the same Lavish
#            poll, and reading the first as the second is exactly the mistake
#            this name prevents.
#
#            PRECONDITION: open the Lavish session on the board FIRST. This only
#            registers the source. With no session open, the first poll returns
#            "No active Lavish Editor session", which is terminal, so the runner
#            retires the registration straight away and the reply surface is
#            dead without ever having worked. Arming is not what puts the board
#            on screen.
# requests   Normalize a captured result into one JSON record per line. See
#            "What requests emits" below.
#
# AUTHORITY: none. A board control performs no action; it queues a request.
# Every record this adapter emits is captain INTENT for firstmate to adjudicate
# under its own contract, exactly as if the captain had said the same words in
# chat, and never an authorization. The surface is reachable by anything that
# can reach the local Lavish port, so reachability is never authorization
# either. Nothing here merges, answers, defers, or writes anything: this reads
# one file and prints to stdout.
#
# Identity, terminal knowledge, and Lavish lifecycle stay owned by
# bin/fm-procevent-lavish.sh, which this delegates to, so one Lavish session can
# never acquire two competing owners and "ended" keeps exactly one definition.
#
# What requests emits, one compact JSON object per line:
#   {"kind":"contract",...}      always first; states that nothing below is authority
#   {"kind":"request",...}       a validated request: intent, home, id, key, note
#   {"kind":"message",...}       captain prose typed into the Lavish panel. The
#                                panel sits beside the board at all times, so
#                                this is the ORDINARY case, never a malfunction.
#   {"kind":"unrecognized",...}  anything else, with a reason. Never acted on.
#
# It is deliberately STATELESS: one result file in, records out. No snapshot, no
# backlog, no network, and no write but stdout. Whether a target still exists is
# firstmate's business at wake time, because a PR may have merged or a task been
# torn down since the board was rendered. There is no fuzzy target matching.
#
# `requests` says what the captain asked for, never whether the surface is still
# there, so classify every result too. The captain's "Send & End" sits beside
# "Send to Agent" in the Lavish panel, and one tap on it makes that delivery
# terminal: the request still arrives, and the source retires behind it. An
# `ended` or `missing` result means the reply surface is GONE until the Lavish
# session is opened on the board again and it is re-armed.
#
# Fail-closed rules, each of which drops a record to "unrecognized" rather than
# guessing: an unknown or missing intent, a wrong version, a field outside its
# allowed set for that intent, an over-long field, an id or home outside the
# safe character set, more than one envelope marker in one prompt, an envelope
# that is not at the start of the prompt, trailing envelope content, duplicate
# object keys, and a record whose quoted field never terminates - which is what
# a result truncated at FM_PROCEVENT_MAX_OUTPUT_BYTES looks like. A `defer`
# carrying note text is refused outright, because the hold reason is the
# captain's own stored text and a request must never rewrite it.
#
# Only lines inside the `prompts[...]` block are read. dom_snapshot and
# next_step are never treated as input.
#
# Wire format verified end to end against lavish-axi 0.1.45, the version
# bin/fm-procevent-lavish.sh pins. Three facts it depends on: one prompt is one
# physical line with embedded newlines escaped inside a JSON-quoted field; the
# queuePrompt `data` option is NOT returned as its own column, so the envelope
# carries everything; and a note containing text like intent=merge stays inside
# its JSON string value and cannot contribute tokens to the parse.
# tests/fm-procevent-mission-control.test.sh pins that format against captured
# real bytes; re-capture it after a lavish-axi upgrade.
#
# Exit codes: 0 success, 1 runtime failure, 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAVISH="$SCRIPT_DIR/fm-procevent-lavish.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# Identity is delegated so this adapter and the lavish one always agree on which
# physical file is which source; a second derivation here could drift and hand
# one Lavish session two owners.
cmd_source_id() {
  local artifact=${1-}
  [ -n "$artifact" ] || usage
  "$LAVISH" source-id "$artifact"
}

cmd_arm() {
  local artifact=${1-} id real
  [ -n "$artifact" ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the board path: $artifact"
  # The same plain blocking poll the lavish adapter registers; only the adapter
  # name differs, so the wake says which kind of source produced the result.
  "$SCRIPT_DIR/fm-procevent.sh" register mission-control "$id" -- lavish-axi poll "$real" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'board: %s\n' "$real"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

cmd_requests() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  perl -e '
use strict;
use warnings;
use JSON::PP;
use bytes ();

my $MARK = "FM-BOARD-REQUEST";
my $MAX_NOTE = 2000;
my $MAX_ID   = 120;
my $MAX_TEXT = 4000;

my $json = JSON::PP->new->canonical->allow_nonref->utf8;
sub emit { print $json->encode($_[0]), "\n"; }

emit({kind => "contract", authority => "none",
      note => "Each record below is captain intent for firstmate to adjudicate "
            . "under its own authority. None of it is an authorization."});

open(my $fh, "<", $ARGV[0]) or exit 1;
my @lines = <$fh>;
close($fh);

# Only the prompts block is input. Anything before it (dom_snapshot) and after
# it (next_step) is never read.
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

# Exactly which fields each intent may carry. An intent is refused outright if
# it carries anything else, so a field that means nothing for that intent can
# never ride along unnoticed.
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
' "$file"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  requests)  shift; cmd_requests "$@" ;;
  classify)  shift; [ $# -ge 1 ] || usage; "$LAVISH" classify "$@" ;;
  terminal)  shift; [ $# -ge 1 ] || usage; "$LAVISH" terminal "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
