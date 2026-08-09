#!/usr/bin/env bash
# Direct board-reply adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-board-reply.sh serve <board.html> [--port <n>] [--host <addr>]
#   fm-procevent-board-reply.sh arm <board.html> [--rebase]
#   fm-procevent-board-reply.sh source <board.html>
#   fm-procevent-board-reply.sh requests <result-file>
#   fm-procevent-board-reply.sh classify <result-file>
#   fm-procevent-board-reply.sh terminal <result-file>
#   fm-procevent-board-reply.sh source-id <board.html>
#   fm-procevent-board-reply.sh log-path <board.html>
#   fm-procevent-board-reply.sh retire <board.html>
#
# This is the transport the mission control board's reply controls use. Unlike its
# thin sibling adapters it also LAUNCHES its own service, because that service and
# this adapter must agree on one board identity and one request log, and one owner
# for that derivation is safer than two that can drift.
#
# serve      Run the loopback reply service for this board in the foreground:
#            it serves the board file for GET and accepts one validated captain
#            request per POST. bin/fm-board-reply-server.py owns its exact wire
#            behavior, binding rule, and same-site refusals; docs/mission-control.md
#            owns how firstmate deploys it and exposes it over the tailnet.
# arm        Register the wake. The wake it produces is
#            `procevent board-reply <source-id> <sequence>`, which SELF-IDENTIFIES
#            as the captain's own board rather than an artifact review.
#            No precondition: arming before the service runs is safe, and requests
#            accepted while nothing is armed are picked up whole by a later arm,
#            because the request log is append-only and never consumed.
#            --rebase resumes from the CURRENT end of the request log, skipping any
#            ambiguous region. It is the supported recovery after a continuity
#            break, and it deliberately drops whatever it skips.
# source     The registered blocking child. NEVER run this in a conversational
#            turn; the runner exists to hold it outside one.
# requests   Normalize a captured result into one JSON record per line, through
#            bin/fm-board-request-parse.pl.
#
# AUTHORITY: none. A board control performs no action; it records a request.
# Every record this adapter emits is captain INTENT for firstmate to adjudicate
# under its own contract, exactly as if the captain had said the same words in
# chat, and never an authorization. The surface is reachable by anything that can
# reach the loopback port or its reverse proxy, so reachability is never
# authorization either.
#
# Request validation, the vocabulary, and every fail-closed rule are owned by
# bin/fm-board-request-parse.pl and shared with the legacy Lavish-bridged adapter,
# so a rule fixed in one place is fixed for both transports.
#
# NON-DESTRUCTIVE READ, stated precisely. The service appends to a private
# append-only log and never consumes it. `source` reads a delta from a cursor and
# advances NOTHING: the cursor is derived from the runner's own durably captured
# results for this source, so capture is the only commit point. A runner that dies
# after `source` printed but before the runner captured re-derives the same bytes
# on its next run, which removes the pre-capture loss window the Lavish poll has.
# It is still not lossless: bin/fm-procevent-lib.sh owns the exact boundary, and a
# request the browser never managed to send was never here at all.
#
# A captured delta is never terminal, so the surface stays armed for as long as the
# service runs. A continuity break IS terminal: the log no longer matches the
# recorded cursor, which is escalated exactly once and then stays unarmed until an
# operator deliberately runs `arm --rebase`, rather than re-announcing forever.
#
# Environment:
#   FM_BOARD_REPLY_PORT           default port for `serve` (default 4321)
#   FM_BOARD_REPLY_WAIT_SECONDS   bound `source`'s wait; 0 (default) waits for a
#                                 real request with no timeout
#   FM_BOARD_REPLY_POLL_MS        `source` poll interval in ms (default 250)
#   FM_BOARD_REPLY_MAX_DELTA_BYTES  most bytes one delta may carry (default 262144)
#
# Exit codes: 0 success, 1 runtime failure, 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

PARSER="$SCRIPT_DIR/fm-board-request-parse.pl"
SERVER="$SCRIPT_DIR/fm-board-reply-server.py"
REQUEST_DIR="$STATE/board-reply"
DEFAULT_PORT=${FM_BOARD_REPLY_PORT:-4321}
WAIT_SECONDS=${FM_BOARD_REPLY_WAIT_SECONDS:-0}
POLL_MS=${FM_BOARD_REPLY_POLL_MS:-250}
MAX_DELTA_BYTES=${FM_BOARD_REPLY_MAX_DELTA_BYTES:-262144}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

real_path() {  # <path>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

# Canonical identity is physical, not the path string, so two names for one board
# file are one source and can never become two owners. The service and this
# adapter both take their log path from here.
cmd_source_id() {
  local board=${1-} real
  [ -n "$board" ] || usage
  case "$board" in *$'\n'*) die "board paths cannot contain newlines" ;; esac
  real=$(real_path "$board") || die "cannot resolve the board path: $board"
  [ -f "$real" ] || die "board does not exist: $board"
  if command -v shasum >/dev/null 2>&1; then
    printf 'board-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'board-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

cmd_log_path() {
  local board=${1-} id
  [ -n "$board" ] || usage
  id=$(cmd_source_id "$board") || exit 1
  printf '%s/%s.log\n' "$REQUEST_DIR" "$id"
}

rebase_path() { printf '%s/%s.rebase\n' "$REQUEST_DIR" "$1"; }

ensure_request_dir() {
  (umask 077; mkdir -p "$REQUEST_DIR") || die "cannot create the request directory: $REQUEST_DIR"
  [ -d "$REQUEST_DIR" ] && [ ! -L "$REQUEST_DIR" ] || die "request directory is unsafe: $REQUEST_DIR"
}

# The registration this board's wake would be armed under. The service reports
# whether it exists, so the board can never confirm a request as collected when
# nothing is collecting - and so a serve launched against the wrong FM_HOME says
# so at startup instead of accepting requests no one will ever read.
registration_path() {  # <source-id>
  printf '%s/%s.source\n' "$(fm_procevent_registry_dir "$STATE")" "$1"
}

cmd_serve() {
  local board='' port=$DEFAULT_PORT host=127.0.0.1 real log id
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) [ $# -ge 2 ] || usage; port=$2; shift 2 ;;
      --host) [ $# -ge 2 ] || usage; host=$2; shift 2 ;;
      -*) usage ;;
      *) [ -z "$board" ] || usage; board=$1; shift ;;
    esac
  done
  [ -n "$board" ] || usage
  command -v python3 >/dev/null 2>&1 || die "python3 is not installed"
  [ -f "$PARSER" ] || die "request validator not found: $PARSER"
  [ -f "$SERVER" ] || die "reply service not found: $SERVER"
  real=$(real_path "$board") || die "cannot resolve the board path: $board"
  id=$(cmd_source_id "$real") || exit 1
  log=$(cmd_log_path "$real") || exit 1
  ensure_request_dir
  printf 'home: %s\n' "$FM_HOME"
  exec python3 "$SERVER" --board "$real" --requests "$log" --parser "$PARSER" \
    --registration "$(registration_path "$id")" --port "$port" --host "$host"
}

# Resume from the current end of the log, deliberately skipping anything the
# recorded cursor can no longer account for. Written completely in memory and
# promoted atomically, so a partial marker can never become a cursor.
write_rebase() {  # <source-id> <log>
  local id=$1 log=$2 body tmp path
  path=$(rebase_path "$id")
  [ ! -L "$path" ] || die "rebase marker is unsafe: $path"
  body=$(perl -MDigest::SHA=sha256_hex -e '
    my $log = $ARGV[0];
    my ($offset, $data) = (0, "");
    if (open(my $fh, "<", $log)) {
      binmode($fh);
      local $/;
      $data = <$fh> // "";
      close($fh);
      # Only whole records can be a resume point; a partial trailing line stays
      # unread rather than becoming a cursor in the middle of a request.
      my $at = rindex($data, "\n");
      $data = $at >= 0 ? substr($data, 0, $at + 1) : "";
      $offset = length($data);
    }
    printf "schema=fm-board-rebase.v1\noffset=%d\nprefix_sha256=%s\n", $offset, sha256_hex($data);
  ' "$log") || die "cannot read the request log for rebase: $log"
  tmp=$(umask 077; mktemp "$REQUEST_DIR/.rebase.XXXXXX") || die "cannot stage the rebase marker"
  if ! printf '%s\n' "$body" > "$tmp"; then
    rm -f -- "$tmp"
    die "cannot write the rebase marker"
  fi
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; die "cannot secure the rebase marker"; }
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; die "cannot publish the rebase marker"; }
  printf '%s' "$body" | sed -n 's/^offset=//p'
}

cmd_arm() {
  local board='' rebase=0 id real log skipped
  while [ $# -gt 0 ]; do
    case "$1" in
      --rebase) rebase=1; shift ;;
      -*) usage ;;
      *) [ -z "$board" ] || usage; board=$1; shift ;;
    esac
  done
  [ -n "$board" ] || usage
  [ -f "$PARSER" ] || die "request validator not found: $PARSER"
  id=$(cmd_source_id "$board") || exit 1
  real=$(real_path "$board") || die "cannot resolve the board path: $board"
  log=$(cmd_log_path "$real") || exit 1
  ensure_request_dir
  if [ "$rebase" = 1 ]; then
    skipped=$(write_rebase "$id" "$log") || exit 1
    printf 'rebased: %s resumes at offset %s\n' "$id" "$skipped"
  fi
  "$SCRIPT_DIR/fm-procevent.sh" register board-reply "$id" -- \
    "$SCRIPT_DIR/fm-procevent-board-reply.sh" source "$real" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'board: %s\n' "$real"
  printf 'requests: %s\n' "$log"
}

cmd_retire() {
  local board=${1-} id
  [ -n "$board" ] || usage
  id=$(cmd_source_id "$board") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# The registered blocking child. It reads and never writes: the cursor comes from
# this source's own durably captured results, so nothing here can consume a
# request the runner has not already stored.
cmd_source() {
  local board=${1-} id log inbox
  [ -n "$board" ] || usage
  id=$(cmd_source_id "$board") || exit 1
  log=$(cmd_log_path "$board") || exit 1
  inbox="$STATE/procevent-inbox"
  case "$WAIT_SECONDS" in ''|*[!0-9]*) die "FM_BOARD_REPLY_WAIT_SECONDS must be a nonnegative integer" ;; esac
  case "$POLL_MS" in ''|*[!0-9]*|0) die "FM_BOARD_REPLY_POLL_MS must be a positive integer" ;; esac
  case "$MAX_DELTA_BYTES" in ''|*[!0-9]*|0) die "FM_BOARD_REPLY_MAX_DELTA_BYTES must be a positive integer" ;; esac
  perl -MDigest::SHA=sha256_hex -e '
use strict;
use warnings;

my ($id, $log, $inbox, $rebase, $wait, $poll_ms, $max_bytes) = @ARGV;

# --- cursor -----------------------------------------------------------------
# Every resume point durable state records, furthest first: one per COMPLETE
# delta this source has already had captured, plus an explicit rebase marker.
# Capture is therefore the only commit point, and a result truncated before its
# end sentinel records nothing. An EMPTY list means nothing has ever been
# recorded for this source, which is the only state that may legitimately read
# the log from its beginning.
sub cursor_candidates {
  my @found;
  my @results;
  if (opendir(my $dh, $inbox)) {
    for my $entry (readdir($dh)) {
      push @results, "$inbox/$entry"
        if $entry =~ /\A\Q$id\E\.[0-9]+\.result\z/;
    }
    closedir($dh);
  }
  for my $path (@results) {
    next if -l $path;
    next unless -f $path;
    open(my $fh, "<", $path) or next;
    my (%field, $end);
    while (my $line = <$fh>) {
      $line =~ s/\r?\n\z//;
      if ($line =~ /^([a-z_0-9]+)=(.*)$/) {
        $field{$1} = $2 unless exists $field{$1};
      }
      $end = $1 if $line =~ /^board-delta-end=([0-9]+)$/;
    }
    close($fh);
    next unless ($field{schema} // "") eq "fm-board-delta.v1";
    next unless ($field{status} // "") eq "delta";
    next unless ($field{source} // "") eq $id;
    my $to = $field{to_offset} // "";
    my $to_hash = lc($field{to_prefix_sha256} // "");
    next unless $to =~ /^[0-9]+$/ && $to_hash =~ /^[0-9a-f]{64}$/;
    next unless defined $end && $end eq $to;
    push @found, [$to + 0, $to_hash];
  }
  if (open(my $fh, "<", $rebase)) {
    my %field;
    while (my $line = <$fh>) {
      $line =~ s/\r?\n\z//;
      $field{$1} = $2 if $line =~ /^([a-z_0-9]+)=(.*)$/;
    }
    close($fh);
    my $at = $field{offset} // "";
    my $at_hash = lc($field{prefix_sha256} // "");
    if (($field{schema} // "") eq "fm-board-rebase.v1"
      && $at =~ /^[0-9]+$/ && $at_hash =~ /^[0-9a-f]{64}$/) {
      push @found, [$at + 0, $at_hash];
    }
  }
  return sort { $b->[0] <=> $a->[0] } @found;
}

my @candidates = cursor_candidates();
my $recorded = @candidates ? $candidates[0][0] : 0;

sub broken {
  my ($reason) = @_;
  print "schema=fm-board-delta.v1\n";
  print "status=continuity-broken\n";
  print "source=$id\n";
  print "from_offset=$recorded\n";
  print "reason=$reason\n";
  exit 0;
}

sub read_range {  # <from> <length>
  my ($at, $length) = @_;
  open(my $fh, "<", $log) or return undef;
  binmode($fh);
  seek($fh, $at, 0) or do { close($fh); return undef; };
  my $buffer = "";
  while (length($buffer) < $length) {
    my $count = read($fh, my $chunk, $length - length($buffer));
    last if !defined($count) || $count == 0;
    $buffer .= $chunk;
  }
  close($fh);
  return $buffer;
}

# Resume from the furthest recorded cursor the CURRENT log actually verifies. A
# stale rebase marker is therefore harmless, a deliberate rewind is honoured, and
# a log that verifies no recorded cursor is refused rather than replayed from its
# beginning - replaying would re-announce every request the captain already sent.
sub resolve_cursor {  # <size>
  my ($size) = @_;
  return (0, sha256_hex("")) unless @candidates;
  for my $candidate (@candidates) {
    my ($at, $hash) = @$candidate;
    next if $at > $size;
    my $prefix = $at ? read_range(0, $at) : "";
    next unless defined $prefix && length($prefix) == $at;
    return ($at, $hash) if sha256_hex($prefix) eq $hash;
  }
  broken("the request log no longer matches any recorded cursor");
}

my $deadline = $wait > 0 ? time + $wait : 0;
my $seen_size = -1;
while (1) {
  # stat, not -s: an existing but empty log is a real state, not a missing one.
  my @stat = stat($log);
  my $size = @stat && -f $log && !-l $log ? $stat[7] : undef;
  if (!defined $size) {
    broken("the request log is missing") if @candidates;
  } elsif ($size != $seen_size) {
    # Only a log whose size changed is worth re-reading, so an idle poll costs
    # one stat rather than a full prefix hash.
    $seen_size = $size;
    my ($from, $expected) = resolve_cursor($size);
    if ($size > $from) {
      my $want = $size - $from;
      $want = $max_bytes if $want > $max_bytes;
      my $chunk = read_range($from, $want);
      broken("the request log could not be read") unless defined $chunk;
      my $at = rindex($chunk, "\n");
      if ($at >= 0) {
        $chunk = substr($chunk, 0, $at + 1);
        my @records = split(/(?<=\n)/, $chunk);
        # A record that would end the tabular block early would silently drop
        # every record after it, so a malformed private log refuses as a whole.
        for my $record (@records) {
          broken("the request log carries a malformed record")
            unless $record =~ /^[ \t]/ && $record =~ /\n\z/ && $record !~ /\r/;
        }
        my $to = $from + length($chunk);
        my $whole = read_range(0, $to);
        broken("the request log could not be read")
          unless defined $whole && length($whole) == $to;
        print "schema=fm-board-delta.v1\n";
        print "status=delta\n";
        print "source=$id\n";
        print "from_offset=$from\n";
        print "to_offset=$to\n";
        print "from_prefix_sha256=$expected\n";
        print "to_prefix_sha256=", sha256_hex($whole), "\n";
        print "requests=", scalar(@records), "\n";
        print "\n";
        printf "prompts[%d]{received,attempt,prompt}:\n", scalar(@records);
        print $_ for @records;
        print "board-delta-end=$to\n";
        exit 0;
      }
    }
  }
  exit 1 if $deadline && time >= $deadline;
  select(undef, undef, undef, $poll_ms / 1000);
}
' "$id" "$log" "$inbox" "$(rebase_path "$id")" "$WAIT_SECONDS" "$POLL_MS" "$MAX_DELTA_BYTES"
}

cmd_requests() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  [ -f "$PARSER" ] || die "request validator not found: $PARSER"
  perl "$PARSER" "$file"
}

# One field of the delta's own provenance header. Read only from the leading
# header block, so a stored request payload can never forge a provenance field.
delta_field() {  # <result-file> <field>
  awk -v field="$2" '
    /^[ \t]/ { exit }
    $0 == "" { exit }
    index($0, field "=") == 1 { print substr($0, length(field) + 2); exit }
  ' "$1"
}

cmd_classify() {
  local file=${1-} schema status count
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  schema=$(delta_field "$file" schema)
  status=$(delta_field "$file" status)
  if [ "$schema" != fm-board-delta.v1 ]; then printf 'malformed\n'; return 0; fi
  case "$status" in
    continuity-broken) printf 'continuity-broken\n'; return 0 ;;
    delta) ;;
    *) printf 'malformed\n'; return 0 ;;
  esac
  count=$(delta_field "$file" requests)
  case "$count" in
    ''|*[!0-9]*|0) printf 'malformed\n' ;;
    *) printf 'requests\n' ;;
  esac
}

# A delta never ends this source: the service keeps accepting requests. A broken
# cursor does, so it escalates once instead of re-announcing on every cycle.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" = continuity-broken ]
}

case "${1-}" in
  serve)     shift; cmd_serve "$@" ;;
  arm)       shift; cmd_arm "$@" ;;
  source)    shift; cmd_source "$@" ;;
  requests)  shift; cmd_requests "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  log-path)  shift; cmd_log_path "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
