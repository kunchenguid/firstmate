#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html>
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh retirement-cleanup <source-id> <registration-generation> <reason>
#   fm-procevent-lavish.sh silent <result-file>
#   fm-procevent-lavish.sh answers <result-file>
#   fm-procevent-lavish.sh read <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
#   fm-procevent-lavish.sh reply <artifact.html> [<text>|--file <path>]
#   fm-procevent-lavish.sh poll <artifact.html>
#
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, missing, or unknown.
# read       Print a structured presentation of one already-captured result so a
#            handler consumes every queued item without grepping the raw file.
#            It is read-only over the capture: it does not arm, poll, or change
#            what Lavish delivered. The session-ending freeform message
#            (tag=message) is its own labeled field, printed first and distinct
#            from per-element annotations. Declared and presented item counts,
#            plus a completeness verdict, follow before all annotations so a
#            partial read is obvious. Each annotation retains its element uid,
#            selector, tag, and text. A non-choice freeform comment (`prompt`)
#            is printed as its own field even when a selector is also present
#            and even when that comment matches the element text, so typed
#            words are never dropped. Choice Context data is not a comment.
#            Captain-supplied body lines are visibly prefixed so they cannot
#            forge structural labels. Empty message and annotation sections
#            are reported explicitly.
# poll       The registered listener command `arm` publishes, not a command to
#            run in a conversational turn. It runs the published blocking poll
#            and prints its response verbatim, absorbing only the one exact
#            transient interruption described below.
# reply      Durably stage a short host acknowledgement for the listener that
#            already owns the poll, then request an immediate listener restart
#            and return without polling in the caller's turn.
#            Pass one text argument, pass --file <path>, or omit both to read
#            multiline text from stdin.
#            Set FM_LAVISH_HOST_STATUS_FILE to the host task's status log.
#            A second reply staged before consumption is appended after one
#            blank line, so concurrent host progress is not overwritten.
#            Reply delivery is bound to the registration generation active when
#            the acknowledgement was staged. A matching legacy registration is
#            upgraded atomically before staging. In-flight state is committed
#            only after the poll returns a nonempty successful response.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
# retirement-cleanup
#            Record and remove acknowledgements that cannot be delivered before
#            the generic runner removes their exact registration generation.
#            The runner invokes this idempotently under the source lock.
# silent     Exit 0 when the captured result is a routine no-op the runner should
#            record and never announce; any other exit publishes the wake. This
#            is the generic no-op contract bin/fm-procevent.sh calls, and the
#            only place Lavish's notion of "nothing was said" is decided.
#
# AN EMPTY BOARD CLOSE IS NOT NEWS, and that is what `silent` exists to say.
# Closing a review surface that carried nothing is the single most common Lavish
# result: the captain reads a board, says nothing, and closes it. Announcing that
# put a wake in front of the handler whose entire content was that nothing
# happened. `silent` therefore holds one narrow, positively-determined shape -
# a session this adapter classifies `ended` that carries no queued content block
# at all - and every other result stays announced.
#
# Deliberately narrow, in both directions. A `Send & End` close carrying the
# captain's actual answer arrives as `status: feedback` with `session_ended`, so
# it classifies `feedback`, never `ended`, and is announced exactly as before; so
# is any `ended` result that still carries a `prompts` or `feedback` block, which
# the published poll is not expected to produce but which must never be dropped
# on that expectation. A `waiting` session, a `missing` one, an `unknown` or
# unreadable result, and any error all stay announced, because none of them
# positively proves nothing was said. Silence is only ever an absence this
# adapter can see in the result, never an absence it assumes.
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
# `read` is the presentation command summarized above; keyed intake remains
# the separate `answers` contract described here.
#
# It wraps ONLY the currently published interface, verified against 0.1.64:
#   Usage: lavish-axi poll <html-file> [--agent-reply "..."]
# and that command "long-polls indefinitely" server-side. The adapter therefore
# runs the plain blocking form with no timeout flag, so results arrive as real
# server-side events. It adds no periodic discovery, no timer fallback, and no
# dependency on any unreleased capability.
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
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

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

cmd_retire() {
  local artifact=${1-} id state reg registration pending inflight
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id" || exit 1
  if [ -e "$STATE" ] && state=$(fm_procevent_state_root_resolve "$STATE"); then
    STATE=$state
    reg=$(fm_procevent_registry_dir "$STATE")
    registration="$reg/$id.source"
    pending=$(pending_reply_path "$id")
    inflight=$(inflight_reply_path "$id")
    fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
    if [ ! -e "$registration" ] && [ ! -L "$registration" ]; then
      if [ -e "$pending" ] || [ -L "$pending" ]; then
        fallback_reply_record_locked "$pending" "source retired before delivery"
      fi
      if [ -e "$inflight" ] || [ -L "$inflight" ]; then
        fallback_reply_record_locked "$inflight" "source retired before delivery"
      fi
    fi
    fm_procevent_source_lock_release "$id"
  fi
}

pending_reply_path() {  # <source-id>
  printf '%s/%s.pending-reply\n' "$(fm_procevent_registry_dir "$STATE")" "$1"
}

inflight_reply_path() {  # <source-id>
  printf '%s/%s.inflight-reply\n' "$(fm_procevent_registry_dir "$STATE")" "$1"
}

pending_reply_is_private() {  # <path>
  [ -f "$1" ] && [ ! -L "$1" ] \
    && [ "$(fm_pr_file_mode "$1" 2>/dev/null)" = 600 ] \
    && [ "$(fm_pr_file_link_count "$1" 2>/dev/null)" = 1 ]
}

host_status_path_validate() {  # <path>
  local host_status=$1 status_key
  case "$host_status" in
    "$STATE/"*.status) ;;
    *) return 1 ;;
  esac
  case "$host_status" in *$'\n'*) return 1 ;; esac
  status_key=${host_status#"$STATE/"}
  case "$status_key" in ''|*.status/*|*/?*|.status) return 1 ;; esac
  if [ -e "$host_status" ] || [ -L "$host_status" ]; then
    [ -f "$host_status" ] && [ ! -L "$host_status" ] \
      && [ "$(fm_pr_file_link_count "$host_status" 2>/dev/null)" = 1 ] || return 1
  fi
}

reply_record_write() {  # <generation> <status-path> <input-path> <output-path>
  {
    printf 'generation=%s\nstatus=%s\nreply:\n' "$1" "$2"
    cat -- "$3"
  } > "$4"
}

reply_record_load() {  # <path>
  local path=$1 generation_line status_line marker extra
  pending_reply_is_private "$path" || return 1
  {
    IFS= read -r generation_line \
      && IFS= read -r status_line \
      && IFS= read -r marker
  } < "$path" || return 1
  case "$generation_line" in generation=*) ;; *) return 1 ;; esac
  case "$status_line" in status=*) ;; *) return 1 ;; esac
  [ "$marker" = reply: ] || return 1
  REPLY_RECORD_GENERATION=${generation_line#generation=}
  REPLY_RECORD_STATUS=${status_line#status=}
  fm_procevent_registration_generation_valid "$REPLY_RECORD_GENERATION" || return 1
  host_status_path_validate "$REPLY_RECORD_STATUS" || return 1
  extra=$(perl -0777 -ne 's/\A[^\n]*\n[^\n]*\nreply:\n// or exit 1; exit(length($_) ? 0 : 1)' "$path") \
    || return 1
  [ -z "$extra" ] || return 1
}

reply_record_body() {  # <path>
  perl -0777 -ne 's/\A[^\n]*\n[^\n]*\nreply:\n// or exit 1; print' "$1"
}

append_reply_input() {  # <record-path> <new-input> <output-path> <generation> <status-path>
  printf 'generation=%s\nstatus=%s\nreply:\n' "$4" "$5" > "$3" || return 1
  perl -0777 -e '
    use strict;
    use warnings;
    my ($old_path, $new_path) = @ARGV;
    open my $old, "<", $old_path or exit 1;
    open my $new, "<", $new_path or exit 1;
    local $/;
    my $old_text = <$old>;
    my $new_text = <$new>;
    $old_text =~ s/\A[^\n]*\n[^\n]*\nreply:\n// or exit 1;
    $old_text =~ s/\n+\z//;
    $new_text =~ s/\A\n+//;
    print $old_text, "\n\n", $new_text;
  ' "$1" "$2" >> "$3"
}

merge_reply_records() {  # <older-record> <newer-record> <output-path> <generation> <status-path>
  printf 'generation=%s\nstatus=%s\nreply:\n' "$4" "$5" > "$3" || return 1
  perl -0777 -e '
    use strict;
    use warnings;
    my ($old_path, $new_path) = @ARGV;
    open my $old, "<", $old_path or exit 1;
    open my $new, "<", $new_path or exit 1;
    local $/;
    my $old_text = <$old>;
    my $new_text = <$new>;
    $old_text =~ s/\A[^\n]*\n[^\n]*\nreply:\n// or exit 1;
    $new_text =~ s/\A[^\n]*\n[^\n]*\nreply:\n// or exit 1;
    $old_text =~ s/\n+\z//;
    $new_text =~ s/\A\n+//;
    print $old_text, "\n\n", $new_text;
  ' "$1" "$2" >> "$3"
}

record_ended_reply_text_locked() {  # <reply-text> <status-path> <reason>
  local reply_text=$1 host_status=$2 reason=$3 status_text reason_text
  host_status_path_validate "$host_status" \
    || die "Lavish session has ended and FM_LAVISH_HOST_STATUS_FILE is not this home's task status log"
  status_text=$(printf '%s' "$reply_text" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  reason_text=$(printf '%s' "$reason" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  (umask 077; printf 'note: Lavish session ended; acknowledgement: %s; reason: %s\n' \
    "$status_text" "$reason_text" >> "$host_status") \
    || die "Lavish session has ended but the acknowledgement could not be recorded"
}

record_ended_reply_locked() {  # <reply-input> <status-path> <reason>
  local reply_text
  reply_text=$(cat -- "$1") || die "cannot read reply text"
  record_ended_reply_text_locked "$reply_text" "$2" "$3"
}

fallback_reply_record_locked() {  # <record-path> <reason>
  local path=$1 reason=$2 reply_text
  reply_record_load "$path" || die "reply record is unreadable"
  reply_text=$(reply_record_body "$path") || die "cannot read reply record"
  record_ended_reply_text_locked "$reply_text" "$REPLY_RECORD_STATUS" "$reason"
  rm -f -- "$path" || die "cannot remove stale reply record"
}

remove_reply_generation_locked() {  # <source-id> <generation> <reason>
  local id=$1 generation=$2 reason=$3 path label
  for label in pending in-flight; do
    case "$label" in
      pending) path=$(pending_reply_path "$id") ;;
      in-flight) path=$(inflight_reply_path "$id") ;;
    esac
    [ -e "$path" ] || [ -L "$path" ] || continue
    reply_record_load "$path" || die "$label reply record is unreadable: $id"
    [ "$REPLY_RECORD_GENERATION" = "$generation" ] || continue
    fallback_reply_record_locked "$path" "$reason"
  done
}

discard_stale_reply_records_locked() {  # <source-id> <live-generation>
  local id=$1 live_generation=$2 path label
  for label in pending in-flight; do
    case "$label" in
      pending) path=$(pending_reply_path "$id") ;;
      in-flight) path=$(inflight_reply_path "$id") ;;
    esac
    [ -e "$path" ] || [ -L "$path" ] || continue
    reply_record_load "$path" || die "$label reply record is unreadable: $id"
    [ "$REPLY_RECORD_GENERATION" = "$live_generation" ] || \
      fallback_reply_record_locked "$path" "source generation changed before delivery"
  done
}

cmd_retirement_cleanup() {  # <source-id> <registration-generation> <reason>
  local id=${1-} generation=${2-} reason=${3-} state
  [ "$#" -eq 3 ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  [ -n "$generation" ] && [ -n "$reason" ] || die "retirement cleanup identity is incomplete"
  case "$generation$reason" in *$'\n'*) die "retirement cleanup fields cannot contain newlines" ;; esac
  if [ -e "$STATE" ] && state=$(fm_procevent_state_root_resolve "$STATE"); then
    STATE=$state
    discard_stale_reply_records_locked "$id" "$generation"
    remove_reply_generation_locked "$id" "$generation" "$reason"
  fi
}

cmd_reply() {
  local artifact=${1-} input real id reg registration pending staged cleanup_command
  local generation_line generation='' current_generation host_status
  [ -n "$artifact" ] || usage
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  id=$(cmd_source_id "$real") || exit 1
  input=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-reply.XXXXXX") || die "cannot stage reply input"
  printf -v cleanup_command 'rm -f -- %q' "$input"
  # shellcheck disable=SC2064 # Expand the private path while it is still set.
  trap "$cleanup_command" EXIT
  case "$#" in
    1) cat > "$input" || die "cannot read reply text from stdin" ;;
    2)
      [ "$2" != --file ] || usage
      printf '%s' "$2" > "$input" || die "cannot stage reply text"
      ;;
    3)
      [ "$2" = --file ] || usage
      [ -f "$3" ] && [ ! -L "$3" ] || die "reply file is not a regular file: $3"
      cp -- "$3" "$input" || die "cannot read reply file: $3"
      ;;
    *) usage ;;
  esac
  [ -s "$input" ] || die "reply text must not be empty"
  perl -0777 -ne 'exit(index($_, "\0") >= 0 ? 1 : 0)' "$input" \
    || die "reply text cannot contain NUL bytes"
  perl -0777 -ne 's/\n+\z//; exit(length($_) > 0 ? 0 : 1)' "$input" \
    || die "reply text must not become empty after trailing newlines are removed"

  STATE=$(fm_procevent_state_root_resolve "$STATE") \
    || die "process-event state root is not a private directory"
  reg=$(fm_procevent_registry_dir "$STATE")
  [ -d "$reg" ] && [ ! -L "$reg" ] || die "Lavish source is not armed: $id"
  registration="$reg/$id.source"
  pending=$(pending_reply_path "$id")
  host_status=${FM_LAVISH_HOST_STATUS_FILE-}
  host_status_path_validate "$host_status" \
    || die "FM_LAVISH_HOST_STATUS_FILE is not this home's task status log"
  generation_line=$("$SCRIPT_DIR/fm-procevent.sh" generation "$id" --upgrade-legacy --if-matches lavish -- \
    "$SCRIPT_DIR/fm-procevent-lavish.sh" poll "$real" 2>/dev/null) || generation_line=
  case "$generation_line" in
    'generation: '*) generation=${generation_line#generation: } ;;
  esac
  [ -z "$generation" ] || fm_procevent_registration_generation_valid "$generation" \
    || die "cannot read Lavish source registration generation: $id"
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  if ! fm_procevent_registration_matches_locked "$STATE" lavish "$id" \
    "$SCRIPT_DIR/fm-procevent-lavish.sh" poll "$real"; then
    if [ ! -e "$registration" ] && [ ! -L "$registration" ]; then
      record_ended_reply_locked "$input" "$host_status" "source is no longer registered"
      fm_procevent_source_lock_release "$id"
      printf 'session ended; acknowledgement recorded in host status log: %s\n' "$host_status"
      return 0
    fi
    fm_procevent_source_lock_release "$id"
    die "Lavish source is not armed by this adapter: $id"
  fi
  current_generation=$(fm_procevent_registration_generation_locked "$STATE" "$id") || {
    fm_procevent_source_lock_release "$id"
    die "cannot read Lavish source registration generation: $id"
  }
  if [ -z "$generation" ] || [ "$current_generation" != "$generation" ]; then
    record_ended_reply_locked "$input" "$host_status" "source generation changed before staging"
    fm_procevent_source_lock_release "$id"
    printf 'session ended; acknowledgement recorded in host status log: %s\n' "$host_status"
    return 0
  fi
  discard_stale_reply_records_locked "$id" "$generation"
  staged=$(umask 077; mktemp "$reg/.pending-reply.XXXXXX") || {
    fm_procevent_source_lock_release "$id"
    die "cannot stage reply"
  }
  if [ -e "$pending" ] || [ -L "$pending" ]; then
    if ! reply_record_load "$pending"; then
      rm -f -- "$staged"
      fm_procevent_source_lock_release "$id"
      die "pending reply record is unreadable: $id"
    fi
    if [ "$REPLY_RECORD_STATUS" != "$host_status" ]; then
      rm -f -- "$staged"
      fm_procevent_source_lock_release "$id"
      die "pending reply belongs to a different host status log: $id"
    fi
    if ! append_reply_input "$pending" "$input" "$staged" "$generation" "$host_status"; then
      rm -f -- "$staged"
      fm_procevent_source_lock_release "$id"
      die "cannot append pending reply"
    fi
  else
    reply_record_write "$generation" "$host_status" "$input" "$staged" || {
      rm -f -- "$staged"
      fm_procevent_source_lock_release "$id"
      die "cannot stage reply"
    }
  fi
  chmod 0600 "$staged" || {
    rm -f -- "$staged"
    fm_procevent_source_lock_release "$id"
    die "cannot protect pending reply"
  }
  mv -f -- "$staged" "$pending" || {
    rm -f -- "$staged"
    fm_procevent_source_lock_release "$id"
    die "cannot publish pending reply"
  }
  fm_procevent_source_lock_release "$id"

  if ! "$SCRIPT_DIR/fm-procevent.sh" restart "$id" --if-generation "$generation" \
    --if-matches lavish -- \
    "$SCRIPT_DIR/fm-procevent-lavish.sh" poll "$real" >/dev/null; then
    fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
    current_generation=$(fm_procevent_registration_generation_locked "$STATE" "$id" 2>/dev/null || true)
    if [ "$current_generation" != "$generation" ]; then
      remove_reply_generation_locked "$id" "$generation" \
        "source generation changed before delivery"
      fm_procevent_source_lock_release "$id"
      printf 'session ended; acknowledgement recorded in host status log: %s\n' "$host_status"
      return 0
    fi
    fm_procevent_source_lock_release "$id"
    die "reply is staged but the listener could not be restarted: $id"
  fi
  printf 'reply staged: %s\n' "$id"
}

recover_inflight_reply_locked() {  # <source-id> <registry-dir>
  local id=$1 reg=$2 pending inflight staged generation status
  pending=$(pending_reply_path "$id")
  inflight=$(inflight_reply_path "$id")
  [ -e "$inflight" ] || [ -L "$inflight" ] || return 0
  reply_record_load "$inflight" || die "in-flight reply record is unreadable: $id"
  generation=$REPLY_RECORD_GENERATION
  status=$REPLY_RECORD_STATUS
  if [ ! -e "$pending" ] && [ ! -L "$pending" ]; then
    mv -- "$inflight" "$pending" || die "cannot recover in-flight reply: $id"
    return 0
  fi
  reply_record_load "$pending" || die "pending reply record is unreadable: $id"
  [ "$REPLY_RECORD_GENERATION" = "$generation" ] \
    && [ "$REPLY_RECORD_STATUS" = "$status" ] \
    || die "pending and in-flight replies belong to different source generations: $id"
  staged=$(umask 077; mktemp "$reg/.pending-reply.XXXXXX") \
    || die "cannot stage recovered reply: $id"
  if ! merge_reply_records "$inflight" "$pending" "$staged" "$generation" "$status"; then
    rm -f -- "$staged"
    die "cannot append recovered reply: $id"
  fi
  chmod 0600 "$staged" || {
    rm -f -- "$staged"
    die "cannot protect recovered reply: $id"
  }
  mv -f -- "$staged" "$pending" || {
    rm -f -- "$staged"
    die "cannot publish recovered reply: $id"
  }
  rm -f -- "$inflight" || die "cannot finish in-flight reply recovery: $id"
}

restore_inflight_reply() {  # <source-id> <generation>
  local id=$1 expected_generation=$2 reg live_generation
  reg=$(fm_procevent_registry_dir "$STATE")
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  live_generation=$(fm_procevent_registration_generation_locked "$STATE" "$id" 2>/dev/null || true)
  discard_stale_reply_records_locked "$id" "$live_generation"
  if [ "$live_generation" != "$expected_generation" ]; then
    fm_procevent_source_lock_release "$id"
    return 0
  fi
  recover_inflight_reply_locked "$id" "$reg"
  fm_procevent_source_lock_release "$id"
}

commit_inflight_reply() {  # <source-id> <generation>
  local id=$1 expected_generation=$2 inflight live_generation
  inflight=$(inflight_reply_path "$id")
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  live_generation=$(fm_procevent_registration_generation_locked "$STATE" "$id" 2>/dev/null || true)
  discard_stale_reply_records_locked "$id" "$live_generation"
  if [ -e "$inflight" ] || [ -L "$inflight" ]; then
    reply_record_load "$inflight" || {
      fm_procevent_source_lock_release "$id"
      die "in-flight reply record is unreadable: $id"
    }
    [ "$live_generation" = "$expected_generation" ] \
      && [ "$REPLY_RECORD_GENERATION" = "$expected_generation" ] || {
        fm_procevent_source_lock_release "$id"
        die "in-flight reply generation changed before commit: $id"
      }
    rm -f -- "$inflight" || {
      fm_procevent_source_lock_release "$id"
      die "cannot commit in-flight reply: $id"
    }
  fi
  fm_procevent_source_lock_release "$id"
}

take_pending_reply() {  # <artifact>
  local artifact=$1 id reg pending inflight live_generation
  POLL_AGENT_REPLY=
  POLL_REPLY_SOURCE_ID=
  POLL_REPLY_GENERATION=
  [ -e "$STATE" ] || return 1
  STATE=$(fm_procevent_state_root_resolve "$STATE") || return 1
  reg=$(fm_procevent_registry_dir "$STATE")
  [ -d "$reg" ] && [ ! -L "$reg" ] || return 1
  id=$(cmd_source_id "$artifact") || return 1
  pending=$(pending_reply_path "$id")
  inflight=$(inflight_reply_path "$id")
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  live_generation=$(fm_procevent_registration_generation_locked "$STATE" "$id" 2>/dev/null || true)
  discard_stale_reply_records_locked "$id" "$live_generation"
  recover_inflight_reply_locked "$id" "$reg"
  if [ ! -e "$pending" ] && [ ! -L "$pending" ]; then
    fm_procevent_source_lock_release "$id"
    return 1
  fi
  if ! reply_record_load "$pending"; then
    fm_procevent_source_lock_release "$id"
    die "pending reply record is unreadable: $id"
  fi
  if [ -z "$live_generation" ] || [ "$REPLY_RECORD_GENERATION" != "$live_generation" ]; then
    fm_procevent_source_lock_release "$id"
    die "pending reply generation does not match the live source: $id"
  fi
  POLL_REPLY_GENERATION=$REPLY_RECORD_GENERATION
  if ! mv -- "$pending" "$inflight"; then
    fm_procevent_source_lock_release "$id"
    die "cannot claim pending reply"
  fi
  fm_procevent_source_lock_release "$id"
  POLL_AGENT_REPLY=$(reply_record_body "$inflight") || die "cannot read claimed reply"
  [ -n "$POLL_AGENT_REPLY" ] || die "claimed reply text is empty"
  POLL_REPLY_SOURCE_ID=$id
  return 0
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

cmd_poll() {
  local artifact=${1-} delay attempt=0 response poll_pipe cleanup_command rc filter_rc
  local poll_pid='' filter_pid='' restart_signal='' reply_claimed
  local -a poll_argv
  [ -n "$artifact" ] || usage
  [ "$#" -eq 1 ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  delay=$(poll_retry_delay) || exit 1
  response=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-poll.XXXXXX") || die "cannot stage the poll response"
  poll_pipe=$(mktemp "${TMPDIR:-/tmp}/fm-lavish-pipe.XXXXXX") || die "cannot stage the poll pipe"
  rm -f -- "$poll_pipe" || die "cannot prepare the poll pipe"
  mkfifo -m 600 "$poll_pipe" || die "cannot prepare the poll pipe"
  printf -v cleanup_command 'rm -f -- %q %q' "$response" "$poll_pipe"
  # shellcheck disable=SC2064 # Expand private paths while both are still set.
  trap "$cleanup_command" EXIT

  # The generic restart hook signals this wrapper, not the runner group. Waiting
  # through the shell builtin lets the trap forward that signal to the exact
  # lavish-axi poll child while the runner stays alive to drain any response
  # bytes that had already arrived.
  forward_poll_signal() {
    restart_signal=$1
    [ -z "$poll_pid" ] || kill -"$1" "$poll_pid" 2>/dev/null || true
  }
  local signal
  for signal in INT TERM HUP; do
    # shellcheck disable=SC2064 # Bind this iteration's signal name now.
    trap "forward_poll_signal $signal" "$signal"
  done
  while :; do
    if [ -n "$restart_signal" ]; then
      case "$restart_signal" in
        HUP) return 129 ;;
        INT) return 130 ;;
        TERM) return 143 ;;
      esac
    fi
    poll_argv=(poll "$artifact")
    reply_claimed=0
    if take_pending_reply "$artifact"; then
      poll_argv+=(--agent-reply "$POLL_AGENT_REPLY")
      reply_claimed=1
    fi
    if [ -n "$restart_signal" ]; then
      [ "$reply_claimed" -eq 0 ] \
        || restore_inflight_reply "$POLL_REPLY_SOURCE_ID" "$POLL_REPLY_GENERATION"
      case "$restart_signal" in
        HUP) return 129 ;;
        INT) return 130 ;;
        TERM) return 143 ;;
      esac
    fi
    lavish-axi "${poll_argv[@]}" > "$poll_pipe" &
    poll_pid=$!
    poll_response_filter "$response" < "$poll_pipe" &
    filter_pid=$!
    wait "$poll_pid"
    rc=$?
    if [ -n "$restart_signal" ]; then
      wait "$poll_pid" 2>/dev/null || true
    fi
    poll_pid=
    wait "$filter_pid"
    filter_rc=$?
    filter_pid=
    if [ "$reply_claimed" -eq 1 ]; then
      if [ -z "$restart_signal" ] && [ "$rc" -eq 0 ] \
        && { [ "$filter_rc" -eq 0 ] || [ "$filter_rc" -eq 10 ]; } \
        && [ -s "$response" ]; then
        commit_inflight_reply "$POLL_REPLY_SOURCE_ID" "$POLL_REPLY_GENERATION"
      else
        restore_inflight_reply "$POLL_REPLY_SOURCE_ID" "$POLL_REPLY_GENERATION"
      fi
    fi
    if [ -n "$restart_signal" ]; then
      case "$restart_signal" in
        HUP) return 129 ;;
        INT) return 130 ;;
        TERM) return 143 ;;
      esac
    fi
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
  return "$rc"
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

# Whether a completed result carries any queued content block at all. The
# published response frames content as a top-level `prompts[N]{...}:` or
# `feedback[N]{...}:` header whose rows are INDENTED, so this anchors on column
# zero: an indented payload line is captain-supplied text and must never be able
# to forge - or, here, to hide behind - a content header. Any recognized block
# is content regardless of its declared count, while a malformed top-level
# prompts or feedback header makes the result indeterminate.
#
# 0 = content present, 1 = provably no content, anything else = the check did
# not complete. The caller must distinguish those three, because "the check
# failed" is never proof that nothing was said.
result_has_queued_content() {  # <result-file>
  awk '
    /^(prompts|feedback)\[[0-9]+\]\{[^}]*\}:[[:space:]]*$/ {
      verdict = "present"
      exit
    }
    /^(prompts|feedback)/ {
      verdict = "indeterminate"
      exit
    }
    END {
      if (verdict == "present") exit 0
      if (verdict == "indeterminate") exit 2
      exit 1
    }
  ' "$1"
}

# Whether a captured result is a routine no-op the runner should record without
# announcing, for the generic runner's silence seam. Lavish's notion of "nothing
# was said" lives here and nowhere else: an ended session carrying no queued
# content block is a board the captain closed without saying anything, and the
# handler learns nothing from being told. Anything else - a real answer, a
# missing or waiting session, an unreadable result - is announced.
cmd_silent() {
  local file=${1-} content_rc
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" = ended ] || return 1
  result_has_queued_content "$file"
  content_rc=$?
  # Only a completed check that proved the result carries nothing declares
  # silence; a check that could not complete announces, like every other
  # uncertainty here.
  [ "$content_rc" -eq 1 ]
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

# Present one already-captured result for a handler. Body lines are prefixed
# so a captain-supplied string cannot forge a section label. The session-ending
# message is printed before the count line and before any annotation, because
# that is the field a truncated grep of the raw capture historically dropped.
# A non-choice annotation that carries a freeform `prompt` prints that comment
# as its own field; a selector must not hide the typed words, even when the
# comment matches the captured element text. Choice rows keep Context data
# out of that field. A pure annotation has no prompt.
cmd_read() {
  local file=${1-} lifecycle session_ended
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  lifecycle=$(cmd_classify "$file")
  session_ended=$(session_field "$file" session_ended)
  perl -e '
    use strict; use warnings;
    my ($path, $lifecycle, $session_ended) = @ARGV;
    open my $fh, "<", $path or exit 1;
    my (@fields, $want, @rows);
    while (my $line = <$fh>) {
      if (!@fields) {
        next unless $line =~ /^(?:prompts|feedback)\[(\d+)\]\{([^}]*)\}:\s*$/;
        ($want, @fields) = ($1, split /,/, $2);
        next;
      }
      last unless $line =~ /^\s/;
      last if defined($want) && @rows >= $want;
      chomp $line;
      push @rows, $line;
    }
    close $fh;
    $want = 0 unless defined $want;
    my @parsed;
    my $malformed = 0;
    for my $row (@rows) {
      $row =~ s/^\s+//;
      my @vals;
      while (length $row) {
        if ($row =~ s/^"((?:[^"\\]|\\.)*)"//) {
          push @vals, $1;
        } else {
          $row =~ s/^([^,]*)//;
          push @vals, $1;
        }
        last unless $row =~ s/^,//;
      }
      if (@vals > @fields) {
        my ($preserve) = grep { $fields[$_] eq "prompt" } 0 .. $#fields;
        ($preserve) = grep { $fields[$_] eq "text" } 0 .. $#fields unless defined $preserve;
        if (defined $preserve) {
          my $count = @vals - @fields + 1;
          my @parts = splice @vals, $preserve, $count;
          splice @vals, $preserve, 0, join(",", @parts);
        }
      }
      if (@vals != @fields) {
        $malformed++;
        next;
      }
      s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge for @vals;
      my %f;
      $f{$fields[$_]} = $vals[$_] for 0 .. $#fields;
      push @parsed, \%f;
    }
    my $presented = scalar @parsed;
    my $complete = ($presented == $want && !$malformed) ? "yes" : "no";
    my @messages;
    my @annotations;
    for my $f (@parsed) {
      my $tag = defined $f->{tag} ? $f->{tag} : "";
      if ($tag eq "message") {
        push @messages, $f;
      } else {
        push @annotations, $f;
      }
    }
    sub emit_body {
      my ($text) = @_;
      $text = "" unless defined $text;
      $text =~ s/\r\n/\n/g;
      $text =~ s/\r/\n/g;
      my @lines = split /\n/, $text, -1;
      pop @lines if @lines && $lines[-1] eq "";
      return if !@lines || (@lines == 1 && $lines[0] eq "");
      print "| $_\n" for @lines;
    }
    if (@messages) {
      print "SESSION-ENDING MESSAGE\n";
      for my $i (0 .. $#messages) {
        print "SESSION-ENDING MESSAGE PART ", ($i + 1), " of ", scalar(@messages), "\n" if @messages > 1;
        my $body = defined $messages[$i]{prompt} && length $messages[$i]{prompt}
          ? $messages[$i]{prompt}
          : (defined $messages[$i]{text} ? $messages[$i]{text} : "");
        emit_body($body);
      }
      print "END SESSION-ENDING MESSAGE\n";
    } else {
      print "SESSION-ENDING MESSAGE: (none)\n";
    }
    print "\n";
    print "declared_items: $want\n";
    print "presented_items: $presented\n";
    print "malformed_items: $malformed\n";
    print "complete: $complete\n";
    print "lifecycle: $lifecycle\n";
    print "session_ended: ", (length $session_ended ? $session_ended : "(unset)"), "\n";
    print "annotation_count: ", scalar(@annotations), "\n";
    print "session_ending_message_count: ", scalar(@messages), "\n";
    print "\n";
    if (@annotations) {
      print "ANNOTATIONS\n";
      my $n = 0;
      for my $f (@annotations) {
        $n++;
        my $uid = defined $f->{uid} ? $f->{uid} : "";
        my $selector = defined $f->{selector} ? $f->{selector} : "";
        my $tag = defined $f->{tag} ? $f->{tag} : "";
        print "ANNOTATION $n of ", scalar(@annotations), "\n";
        print "element_uid: $uid\n";
        print "element_selector: $selector\n";
        print "tag: $tag\n";
        print "text:\n";
        my $elem = defined $f->{text} ? $f->{text} : "";
        my $comment = defined $f->{prompt} ? $f->{prompt} : "";
        my $body = length $elem ? $elem : $comment;
        emit_body($body);
        if ($tag ne "choice" && length $comment) {
          print "prompt:\n";
          emit_body($comment);
        }
      }
      print "END ANNOTATIONS\n";
    } else {
      print "ANNOTATIONS: (none)\n";
    }
    print "END LAVISH RESULT ($presented of $want)\n";
  ' "$file" "$lifecycle" "$session_ended"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  reply)     shift; cmd_reply "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  retirement-cleanup) shift; cmd_retirement_cleanup "$@" ;;
  silent)    shift; cmd_silent "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  read)      shift; cmd_read "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
