#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html>
#   printf '%s' '<reply>' | fm-procevent-lavish.sh arm-reply <artifact.html>
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh answers <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
#   fm-procevent-lavish.sh poll <artifact.html>
#
# arm-reply  Read one nonempty agent reply of at most 8192 bytes from stdin,
#            replace this home's existing Lavish listener, and start its next
#            blocking wait with that reply. The reply is staged at mode 0600,
#            passed as one direct argv element, and consumed at most once. A
#            live owner in another home, an in-flight reply, or uncertain source
#            ownership is refused rather than displaced or overwritten.
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, missing, or unknown.
# poll       The registered listener command `arm` publishes, not a command to
#            run in a conversational turn. It runs the published blocking poll
#            and prints its response verbatim, absorbing only the one exact
#            transient interruption described below.
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
# It wraps ONLY the currently published interface, verified against 0.1.53:
#   Usage: lavish-axi poll <html-file> [--agent-reply "..."]
# and that command "long-polls indefinitely" server-side. The adapter therefore
# runs the plain blocking form with no timeout flag, so results arrive as real
# server-side events. It adds no periodic discovery, no timer fallback, and no
# dependency on any unreleased capability.
#
# ONE-SHOT REPLY, owned here and nowhere else. `arm-reply` interrupts only this
# home's current listener generation through the generic runner's serialized
# restart command. The next invocation claims the private reply before invoking
# Lavish and passes the bytes only to that invocation; the unchanged registration
# makes every later generation reply-free. Any retry after the exact transient
# interruption below is reply-free. A crash after the claim but before or during
# the Lavish call can lose the reply, because there is no upstream receipt proving
# whether Lavish displayed it; recovery deliberately returns to plain polling
# rather than risking a duplicate. A crash after private publication but before
# restart can leave the reply pending for a later generation, so that caller
# cannot claim immediate delivery.
#
# BOUNDED QUIET RETRY, owned here and nowhere else. A live listener can be cut
# short by the server with exactly this two-line response while the session's
# marks remain available:
#
#   error: Lavish Editor poll response was interrupted
#   code: SERVER_ERROR
#
# That is an internal retry, not news, so registering the raw poll made the
# generic runner capture it and wake the whole fleet. `poll` therefore re-runs
# the published poll up to POLL_RETRY_LIMIT times for that exact response, with
# POLL_RETRY_DELAY_DEFAULT seconds between attempts. The match is exact and
# deliberately narrow: real feedback, ended and missing sessions, any other
# SERVER_ERROR, and the same interruption still standing after the bound is
# spent are all printed straight through and captured normally. The retry is a
# Lavish fact, so the generic runner in bin/fm-procevent.sh stays
# adapter-agnostic and learns nothing about it.
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
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,88p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

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

reply_lock() { printf '%s/.%s.reply-lock\n' "$(fm_procevent_registry_dir "$STATE")" "$1"; }
reply_pending() { printf '%s/.%s.reply.pending\n' "$(fm_procevent_registry_dir "$STATE")" "$1"; }

reply_state_present() {  # <source-id>
  local id=$1 path
  if [ -e "$(reply_pending "$id")" ] || [ -L "$(reply_pending "$id")" ]; then
    return 0
  fi
  for path in "$(fm_procevent_registry_dir "$STATE")/.$id.reply."*.consumed; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      return 0
    fi
  done
  return 1
}

reply_state_remove() {  # <source-id>
  local id=$1 path
  rm -f -- "$(reply_pending "$id")"
  for path in "$(fm_procevent_registry_dir "$STATE")/.$id.reply."*.consumed; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      rm -f -- "$path"
    fi
  done
}

cmd_arm() {
  local artifact=${1-} id real
  [ -n "$artifact" ] || usage
  [ "$#" -eq 1 ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  poll_retry_delay >/dev/null
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  # This adapter's own listener command, which runs the plain blocking form with
  # no --timeout-ms so completion is a server event, and absorbs only the exact
  # transient interruption. Registering raw poll output is what let that
  # interruption reach the runner as a captured result.
  "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" \
    -- "$SCRIPT_DIR/fm-procevent-lavish.sh" poll "$real" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
}

AGENT_REPLY_MAX_BYTES=8192

# Read stdin without placing the reply in this adapter's argv. NUL cannot be
# represented in the shell argv Lavish publishes, and oversized input is fully
# rejected rather than truncated into a different message.
stage_agent_reply() {  # <destination>
  perl -e '
    use strict;
    use warnings;
    my ($limit) = @ARGV;
    binmode STDIN;
    binmode STDOUT;
    my $total = 0;
    while (1) {
      my $count = sysread STDIN, my $chunk, 65536;
      exit 2 unless defined $count;
      last if $count == 0;
      exit 5 if index($chunk, "\0") >= 0;
      $total += $count;
      exit 3 if $total > $limit;
      my $offset = 0;
      while ($offset < $count) {
        my $written = syswrite STDOUT, $chunk, $count - $offset, $offset;
        exit 2 unless defined $written;
        $offset += $written;
      }
    }
    exit 4 if $total == 0;
  ' "$AGENT_REPLY_MAX_BYTES" > "$1"
}

cmd_arm_reply() {
  local artifact=${1-} id real reg pending tmp device rc=0
  [ -n "$artifact" ] || usage
  [ "$#" -eq 1 ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  poll_retry_delay >/dev/null
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  reg=$(fm_procevent_registry_dir "$STATE")
  [ -d "$reg" ] && [ ! -L "$reg" ] || die "the Lavish source is not armed: $id"
  device=$(fm_pr_file_device "$reg") || die "cannot inspect the process-event registry"
  tmp=$(umask 077; mktemp "$reg/.reply.XXXXXX") || die "cannot stage the agent reply"
  stage_agent_reply "$tmp" || rc=$?
  case "$rc" in
    0) ;;
    3) rm -f -- "$tmp"; die "agent reply exceeds $AGENT_REPLY_MAX_BYTES bytes" ;;
    4) rm -f -- "$tmp"; die "agent reply cannot be empty" ;;
    5) rm -f -- "$tmp"; die "agent reply cannot contain NUL bytes" ;;
    *) rm -f -- "$tmp"; die "cannot read the agent reply" ;;
  esac
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; die "cannot secure the agent reply"; }
  fm_pr_private_file_valid "$tmp" 600 "$device" \
    || { rm -f -- "$tmp"; die "staged agent reply failed validation"; }

  fm_lock_acquire_wait "$(reply_lock "$id")" || { rm -f -- "$tmp"; die "cannot lock the agent reply"; }
  if reply_state_present "$id"; then
    fm_lock_release "$(reply_lock "$id")"
    rm -f -- "$tmp"
    die "an agent reply is already pending or in flight: $id"
  fi
  pending=$(reply_pending "$id")
  if ! mv -f -- "$tmp" "$pending" \
    || ! fm_pr_private_file_valid "$pending" 600 "$device"; then
    rm -f -- "$tmp" "$pending"
    fm_lock_release "$(reply_lock "$id")"
    die "cannot publish the private agent reply"
  fi
  if ! "$SCRIPT_DIR/fm-procevent.sh" restart "$id"; then
    rm -f -- "$pending"
    fm_lock_release "$(reply_lock "$id")"
    die "cannot arm the agent reply"
  fi
  fm_lock_release "$(reply_lock "$id")"
  printf 'reply-armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id" || exit 1
  fm_lock_acquire_wait "$(reply_lock "$id")" || die "cannot lock the agent reply"
  reply_state_remove "$id"
  fm_lock_release "$(reply_lock "$id")"
}

# The bounded quiet retry described in the header. The bound is a constant
# because it is a property of the transient response, not an operator choice;
# only the delay takes an override, so a test can exercise the real bound
# without waiting it out.
POLL_RETRY_LIMIT=12
POLL_RETRY_DELAY_DEFAULT=5
POLL_RETRY_DELAY_MAX=60

# Exit 0 only for the exact two-line interruption, and nothing else. The whole
# response must be those two lines with those exact bytes: whitespace variants,
# a longer response that merely opens with them, and any other SERVER_ERROR are
# genuine errors this adapter must never swallow.
poll_response_filter() {  # <response-file>
  perl -e '
    use strict;
    use warnings;
    my ($stage) = @ARGV;
    my $expected = "error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n";
    open my $staged, ">", $stage or exit 2;
    binmode STDIN;
    binmode STDOUT;
    binmode $staged;
    my ($candidate, $streaming) = ("", 0);
    sub write_all {
      my ($handle, $bytes) = @_;
      my $offset = 0;
      while ($offset < length $bytes) {
        my $written = syswrite $handle, $bytes, length($bytes) - $offset, $offset;
        exit 2 unless defined $written;
        $offset += $written;
      }
    }
    while (1) {
      my $count = sysread STDIN, my $chunk, 65536;
      exit 2 unless defined $count;
      last if $count == 0;
      if ($streaming) {
        write_all(*STDOUT, $chunk);
        next;
      }
      my $room = length($expected) + 1 - length($candidate);
      my $take = length($chunk) < $room ? length($chunk) : $room;
      my $prefix = substr($chunk, 0, $take);
      $candidate .= $prefix;
      write_all($staged, $prefix);
      my $matches_prefix = length($candidate) <= length($expected)
        && substr($expected, 0, length($candidate)) eq $candidate;
      if (!$matches_prefix) {
        write_all(*STDOUT, $candidate);
        write_all(*STDOUT, substr($chunk, $take));
        $streaming = 1;
      }
    }
    exit 10 if !$streaming && $candidate eq $expected;
    write_all(*STDOUT, $candidate) unless $streaming;
  ' "$1"
}

# Seconds between retries. FM_LAVISH_POLL_RETRY_DELAY is a bounded test
# override; a malformed or out-of-range value is refused rather than quietly
# rounded, because silently changing a retry cadence is how a bound stops
# meaning anything.
poll_retry_delay() {
  local delay=${FM_LAVISH_POLL_RETRY_DELAY-}
  if [ -z "$delay" ]; then
    printf '%s\n' "$POLL_RETRY_DELAY_DEFAULT"
    return 0
  fi
  case "$delay" in
    *[!0-9]*) die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from 0 to $POLL_RETRY_DELAY_MAX: $delay" ;;
  esac
  [ "$delay" -le "$POLL_RETRY_DELAY_MAX" ] \
    || die "FM_LAVISH_POLL_RETRY_DELAY must be whole seconds from 0 to $POLL_RETRY_DELAY_MAX: $delay"
  printf '%s\n' "$delay"
}

poll_loop() {  # <artifact> [one-shot-agent-reply]
  local artifact=$1 reply=${2-} with_reply=0 delay attempt=0 response cleanup_command rc filter_rc
  local pipeline_status
  [ "$#" -eq 2 ] && with_reply=1
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  delay=$(poll_retry_delay) || exit 1
  response=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-poll.XXXXXX") || die "cannot stage the poll response"
  printf -v cleanup_command 'rm -f -- %q' "$response"
  # shellcheck disable=SC2064 # $cleanup_command must expand now, while the staged path is still set.
  trap "$cleanup_command" EXIT
  # Retirement stops this listener by signalling its process group, and bash runs
  # no EXIT trap for an uncaught signal, so each one cleans up the staged
  # response and then re-raises itself with the default disposition, leaving the
  # process dying exactly as the runner expects.
  local signal
  for signal in INT TERM HUP; do
    # shellcheck disable=SC2064 # Same reason: expand now, while both are set.
    trap "$cleanup_command; trap - $signal; kill -$signal $$" "$signal"
  done
  while :; do
    if [ "$with_reply" -eq 1 ] && [ "$attempt" -eq 0 ]; then
      lavish-axi poll "$artifact" --agent-reply "$reply" | poll_response_filter "$response"
    else
      lavish-axi poll "$artifact" | poll_response_filter "$response"
    fi
    pipeline_status=("${PIPESTATUS[@]}")
    rc=${pipeline_status[0]}
    filter_rc=${pipeline_status[1]}
    case "$filter_rc" in
      0) break ;;
      10)
        if [ "$attempt" -lt "$POLL_RETRY_LIMIT" ]; then
          attempt=$((attempt + 1))
          sleep "$delay"
        else
          cat -- "$response"
          break
        fi
        ;;
      *) die "cannot classify the poll response" ;;
    esac
  done
  rm -f -- "$response"
  trap - EXIT INT TERM HUP
  return "$rc"
}

# A registered listener atomically claims one pending reply before invoking
# Lavish. The generation token makes the consumed marker private to this run;
# after a crash, the next generation removes it and polls without a reply.
# A manually invoked poll has no runner-issued token and cannot touch reply state.
cmd_poll() {
  local artifact=${1-} id reg device pending consumed reply_with_sentinel reply rc
  [ -n "$artifact" ] || usage
  [ "$#" -eq 1 ] || usage
  if [ -z "${FM_PROCEVENT_ACTIVE_TOKEN:-}" ]; then
    poll_loop "$artifact"
    return $?
  fi
  id=$(cmd_source_id "$artifact") || exit 1
  [ "${FM_PROCEVENT_ACTIVE_SOURCE:-}" = "$id" ] || die "poll has mismatched source ownership"
  case "$FM_PROCEVENT_ACTIVE_TOKEN" in
    *[!A-Za-z0-9._-]*) die "poll has no valid source generation" ;;
  esac
  reg=$(fm_procevent_registry_dir "$STATE")
  device=$(fm_pr_file_device "$reg") || die "cannot inspect the process-event registry"
  pending=$(reply_pending "$id")
  fm_lock_acquire_wait "$(reply_lock "$id")" || die "cannot lock the agent reply"
  if fm_pr_private_file_valid "$pending" 600 "$device"; then
    # Recheck content at consumption time so local mutation cannot bypass the
    # arm boundary's NUL and size limits.
    rc=0
    stage_agent_reply /dev/null < "$pending" || rc=$?
    if [ "$rc" -ne 0 ]; then
      rm -f -- "$pending"
      fm_lock_release "$(reply_lock "$id")"
      die "the pending agent reply failed validation"
    fi
    reply_with_sentinel=$(cat -- "$pending"; printf '\034')
    reply=${reply_with_sentinel%$'\034'}
    consumed="$reg/.$id.reply.$FM_PROCEVENT_ACTIVE_TOKEN.consumed"
    if ! mv -- "$pending" "$consumed"; then
      fm_lock_release "$(reply_lock "$id")"
      die "cannot claim the private agent reply"
    fi
    fm_lock_release "$(reply_lock "$id")"
    poll_loop "$artifact" "$reply"
    rc=$?
    fm_lock_acquire_wait "$(reply_lock "$id")" || return "$rc"
    rm -f -- "$consumed"
    fm_lock_release "$(reply_lock "$id")"
    return "$rc"
  fi
  # No valid pending reply belongs to this generation. Remove stale or tampered
  # reply state from an earlier failed arm or consumed generation and continue
  # with the ordinary reply-free wait.
  reply_state_remove "$id"
  fm_lock_release "$(reply_lock "$id")"
  poll_loop "$artifact"
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
  arm-reply) shift; cmd_arm_reply "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
