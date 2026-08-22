#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html>
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh answers <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
#
# arm        Register the canonical source for the published poll argv, start
#            this home's liveness reconciliation immediately rather than at a
#            later watcher cycle, and print `armed:` only after a live owner
#            of that exact registration is confirmed within a bounded wait
#            (FM_PROCEVENT_LAVISH_ARM_WAIT_MS milliseconds, default 5000).
#            Without confirmation arm exits nonzero without printing `armed:`;
#            the registration stays in place for later reconciliation either
#            way.
#
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, missing, or unknown.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
#
# This adapter is deliberately thin. It owns only what is specific to Lavish:
# canonical source identity, the argv for the currently published poll command,
# and how to read a completed result. Ownership, durable capture, publication,
# and restart recovery all belong to bin/fm-procevent.sh.
#
# `answers` is this adapter's half of the generic keyed-answer contract in
# bin/fm-procevent.sh. It reports what the captain actually chose, as
# `<task-id>\t<answer>\t<label>` lines, and stops there. It maps nothing to a
# task, records no decision, and closes nothing: a captain answer is not special
# to Lavish, so every rule about what a keyed answer DOES belongs to the one
# intake in bin/fm-captain-hold.sh, which the runner feeds. A Lavish review is
# just an ephemeral discussion format that happens to carry answers.
#
# Only rows tagged `choice` are read. A freeform captain message is prose that may
# contain anything, and must never be able to forge a decision key.
#
# It wraps ONLY the currently published interface, verified against 0.1.45:
#   Usage: lavish-axi poll <html-file> [--agent-reply "..."]
# and that command "long-polls indefinitely" server-side. The adapter therefore
# runs the plain blocking form with no timeout flag, so results arrive as real
# server-side events. It adds no periodic discovery, no timer fallback, and no
# dependency on any unreleased capability.
#
# LOSS LIMITATION, stated plainly. The published poll destructively clears
# feedback before returning it. A result lost after that clearing and before the
# runner reads the process output is unrecoverable, and no Firstmate wrapper can
# close that source-side handoff window. Never describe this path as
# at-least-once, no-loss, or lossless. The only durability this proves is the
# runner's own: output that reached the runner is stored before it is announced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the realpath of the artifact, so two names for one file are one
# source and must never become two owners.
cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

# Milliseconds since the epoch, used only to bound cmd_arm's listener-liveness
# wait by wall clock. Counting fixed sleep intervals cannot bound elapsed time,
# because every iteration also spends real time on fm_procevent_generation_live's
# own work - a filesystem lock, claim load, and process-identity check - which a
# sleep-only budget never accounts for. EPOCHREALTIME is a bash builtin (no
# fork) and is tried first. A shell without it - stock macOS ships Bash 3.2,
# which predates EPOCHREALTIME - falls back to perl's Time::HiRes, a core
# module bundled with every perl this adapter already requires elsewhere
# (cmd_source_id, cmd_answers), so sub-second FM_PROCEVENT_LAVISH_ARM_WAIT_MS
# values stay honored instead of degrading to whole-second granularity, which
# could make a bounded wait take close to a full second longer than requested.
arm_now_ms() {
  local raw sec frac ms
  raw=${EPOCHREALTIME:-}
  case "$raw" in
    *[0-9][.,][0-9]*)
      sec=${raw%%[.,]*}
      frac=${raw#*[.,]}
      frac="${frac}000"
      frac=${frac:0:3}
      case "$sec$frac" in
        ''|*[!0-9]*) ;;
        *) printf '%s\n' "$(( sec * 1000 + 10#$frac ))"; return 0 ;;
      esac
      ;;
  esac
  ms=$(perl -MTime::HiRes=time -e 'printf "%.0f", time() * 1000' 2>/dev/null)
  case "$ms" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$ms"; return 0 ;;
  esac
  sec=$(date +%s 2>/dev/null || printf '0')
  case "$sec" in ''|*[!0-9]*) sec=0 ;; esac
  printf '%s\n' "$(( sec * 1000 ))"
}

cmd_arm() {
  local artifact=${1-} id real reg_out identity wait_ms live deadline_ms now_ms remaining_ms frac first
  [ -n "$artifact" ] || usage
  [ "$#" -eq 1 ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  # The plain blocking form: no --timeout-ms, so completion is a server event.
  # register reports the identity of the exact generation it just published,
  # captured on the other side while it still held the source lock. Reading it
  # back from that line - rather than re-deriving it here with a separate,
  # unlocked stat of the registry file - is what keeps this attempt's identity
  # from ever being some concurrent arm call's later registration instead.
  reg_out=$("$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" -- lavish-axi poll "$real") || exit 1
  printf '%s\n' "$reg_out"
  identity=${reg_out##* }
  [ -n "$identity" ] || die "cannot read the registered generation: $id"
  # Registration proves the source definition was accepted; it does not prove
  # this attempt's listener ever starts, because reconcile owns that launch.
  # Readiness is therefore proved before it is reported: kick one reconcile so
  # the runner starts now rather than at the watcher's leisure, then require a
  # live owner whose claim names THIS registration attempt. Anything else stays
  # unconfirmed - exit nonzero without armed:, leaving the registration in
  # place for later reconciliation either way.
  case "${FM_PROCEVENT_LAVISH_ARM_WAIT_MS:-5000}" in
    ''|*[!0-9]*) die "FM_PROCEVENT_LAVISH_ARM_WAIT_MS must be a nonnegative integer" ;;
  esac
  wait_ms=${FM_PROCEVENT_LAVISH_ARM_WAIT_MS:-5000}
  # Kicked in the background, never awaited: reconcile can block on a source
  # lock held by a live process elsewhere or on slow runner cleanup, and only
  # the timed sampling loop below is allowed to bound how long arm waits.
  # Running it synchronously here would let that internal blocking silently
  # replace the documented bound with reconcile's own, possibly unbounded, one.
  "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 &
  deadline_ms=$(( $(arm_now_ms) + wait_ms ))
  live=1
  first=1
  while :; do
    # The very first probe always runs, even for a 0ms budget, so a caller
    # gets at least one real check. Every later probe is itself real work -
    # a filesystem lock, claim load, and process-identity check - so the
    # deadline is re-checked against the wall clock right before starting
    # one, not only after it returns; otherwise a probe could be kicked off
    # an instant after the budget already ran out, growing the overrun by
    # that whole probe's duration instead of stopping at the deadline.
    if [ "$first" -eq 0 ]; then
      now_ms=$(arm_now_ms)
      [ "$now_ms" -lt "$deadline_ms" ] || break
    fi
    first=0
    if fm_procevent_generation_live "$id" "$identity"; then
      live=0
      break
    fi
    now_ms=$(arm_now_ms)
    [ "$now_ms" -lt "$deadline_ms" ] || break
    remaining_ms=$(( deadline_ms - now_ms ))
    [ "$remaining_ms" -le 50 ] || remaining_ms=50
    printf -v frac '%03d' "$remaining_ms"
    sleep "0.$frac"
  done
  [ "$live" -eq 0 ] || die "listener for $id did not confirm live within ${wait_ms}ms"
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed field name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Classify a completed result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback) printf 'feedback\n'; return 0 ;;
    ended)    printf 'ended\n'; return 0 ;;
    waiting)  printf 'waiting\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result ends this source, for the generic runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. Anything else - including an unreadable result - keeps the source armed.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    ended|missing) return 0 ;;
  esac
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) return 0 ;;
  esac
  return 1
}

# Print `key<TAB>answer<TAB>label[<TAB>mode]` for every structured choice the
# captain submitted in a captured result; the optional mode column relays the
# card's declared close mode (`done` or `release`) to the keyed-answer intake. The published response frames queued feedback as
# a `prompts[N]{field,...}:` header followed by exactly N indented CSV rows whose
# quoted fields carry JSON-style escapes, so this reads the declared field ORDER
# rather than assuming a fixed column, and takes only rows whose `tag` field is
# `choice`. A freeform `message` row is captain prose and is deliberately never a
# source of decision keys. A row that does not carry both a slug-shaped `question`
# and an `answer` inside its `Context data:` block is skipped, so a deck that does
# not key its forms by decision key simply yields nothing.
# The question cap is 128 so any task id fits, including the long legacy
# `<origin>-decision-<key>` identities pre-collapse decks still carry; the
# security property is the slug SHAPE, which is unchanged.
cmd_answers() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($path) = @ARGV;
    open my $fh, "<", $path or exit 1;
    my (@fields, $want, @rows);
    while (my $line = <$fh>) {
      if (!@fields) {
        next unless $line =~ /^prompts\[(\d+)\]\{([^}]*)\}:\s*$/;
        ($want, @fields) = ($1, split /,/, $2);
        next;
      }
      last unless $line =~ /^\s/;
      last if @rows >= $want;
      chomp $line;
      push @rows, $line;
    }
    close $fh;
    my %seen;
    my @out;
    for my $row (@rows) {
      $row =~ s/^\s+//;
      my @vals;
      while (length $row) {
        if ($row =~ s/^"((?:[^"\\]|\\.)*)"//) {
          my $v = $1;
          $v =~ s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge;
          push @vals, $v;
        } else {
          $row =~ s/^([^,]*)//;
          push @vals, $1;
        }
        last unless $row =~ s/^,//;
      }
      my %f;
      $f{$fields[$_]} = $vals[$_] for 0 .. $#fields;
      next unless defined $f{tag} && $f{tag} eq "choice";
      my $prompt = $f{prompt};
      next unless defined $prompt && $prompt =~ /Context data:\s*(\{.*\})/s;
      my $ctx = $1;
      my $data = eval { decode_json($ctx) };
      next unless ref($data) eq "HASH";
      my $key = $data->{question};
      my $answer = $data->{answer};
      next if !defined($key) || ref($key) || !defined($answer) || ref($answer);
      my $mode = "";
      if (exists $data->{close}) {
        next if !defined($data->{close}) || ref($data->{close})
          || ($data->{close} ne "done" && $data->{close} ne "release");
        $mode = $data->{close};
      }
      next unless $key =~ /\A[A-Za-z0-9._-]{1,128}\z/;
      next unless length $answer && length($answer) <= 512;
      my $label = defined $f{text} ? $f{text} : "";
      s/[\x00-\x1f\x7f]/ /g for ($answer, $label);
      $label = substr($label, 0, 512);
      # A re-answered form appears again later in the queue; the last submission wins.
      if (defined $seen{$key}) { $out[$seen{$key}] = undef }
      $seen{$key} = scalar @out;
      push @out, length $mode ? "$key\t$answer\t$label\t$mode" : "$key\t$answer\t$label";
    }
    print "$_\n" for grep { defined } @out;
  ' "$file"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
