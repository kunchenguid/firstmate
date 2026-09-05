#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html>
#   fm-procevent-lavish.sh managed-poll <artifact.html>
#   fm-procevent-lavish.sh receipt <source-id> <sequence> <result-file> <outcome-file>
#   fm-procevent-lavish.sh applying <source-id> <sequence>
#   fm-procevent-lavish.sh complete <source-id> <sequence>
#   fm-procevent-lavish.sh receipt-text <source-id>
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh silent <result-file>
#   fm-procevent-lavish.sh answers <result-file>
#   fm-procevent-lavish.sh read <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
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
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
#            Two guards are added to the plain session facts: a review whose
#            latest received submission still owes its receipt is not terminal,
#            so an ended review is never retired before its final receipt was
#            displayed or became impossible to display; and a result this
#            adapter cannot completely parse is indeterminate rather than empty,
#            so it keeps the source armed instead of retiring it unacknowledged.
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
# VISIBLE RECEIPT LIFECYCLE, owned here. The captain's only proof that a
# submission was not lost is the acknowledgement this adapter presents in the
# review page itself, through the published poll's `--agent-reply` surface. The
# per-source receipts record (`state/procevent/<source-id>.receipts`, layout
# owned by the runner, bytes owned here) journals exactly one fact per event,
# and every visible state is printed only after its fact exists:
#
#   Received   the runner's durable capture, journaled by the `receipt` seam
#              after the capture exists in `state/procevent-inbox/`. A round
#              that carried no answers - a comment-only submission - is
#              acknowledged as the written comment it was, never as a count of
#              answers nobody asked for.
#   Saved      what the one keyed-answer intake returned for that generation,
#              journaled only after that intake has run; partial and rejected
#              rows are reported as counts, never presented as saved.
#   Applying   only `applying <source-id> <sequence>`, run by the handler when
#              it begins routing the accepted answers.
#   Complete   only `complete <source-id> <sequence>`, run by the handler when
#              that routing is done; it refuses without a recorded Applying.
#   Already received  a captured submission whose content digest matches an
#              earlier generation and whose own outcome proves no new effect;
#              reported as a replay, never as new work. A resubmission that
#              really did save something - an answer skipped the first time
#              because its task was not held yet - is presented and journaled
#              as the new action it was, never hidden behind that replay.
#
# `arm` registers the source with `managed-poll` as its child instead of the
# bare poll. managed-poll is still exactly the published blocking poll shape -
# no timeout flag, no timer, no second owner - it only presents the current
# receipt text through `--agent-reply` when the record has something to state,
# journals that `armed` fact, and then behaves identically to the bare poll.
# Because each poll presents the truth recorded so far, a receipt the captain
# sees is always the state at the moment that poll armed; Applying and Complete
# for the last round of an ended review are stated durably in the record even
# though the ended page keeps the last displayed receipt. `arm` resets the
# record, so re-hosting the same artifact never inherits an earlier session's
# rounds, and it refuses to arm while any captured result of that artifact is
# still unhandled, so that reset can never orphan a still-live round from the
# Applying and Complete it has yet to record.
#
# `receipt` is this adapter's half of the runner's generic receipt seam. It
# journals delivery (a completed poll that armed a receipt proves it displayed,
# unless the session was already gone), Received, and Saved - the outcome file
# handed over by the runner states exactly what the keyed-answer intake
# returned - and acknowledges one narrow generation: an ended session with no
# queued submission whose only purpose was displaying a new receipt. Everything
# else stays announced for the handler exactly as before. A missing or failing
# step here changes nothing about publication or handling.
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
# It wraps ONLY the currently published interface, verified against 0.1.45:
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
# close that source-side handoff window. The receipt lifecycle proves only what
# reached Firstmate: it can never promise the captain that a submission lost in
# that window was received, and the `--agent-reply` presentation proves nothing
# about what the source delivered to the browser. Never describe this path as
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
usage() { sed -n '2,169p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

RECEIPT_SCHEMA=fm-lavish-receipt.v1
RECEIPT_MAX_ROUNDS=8
RECEIPT_MAX_TEXT_BYTES=4096

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the realpath of the artifact, so two names for one file are one
# source and must never become two owners.
resolve_real() {  # <artifact>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(resolve_real "$artifact") \
    || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

sha16_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,16)}'
  else
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,16)}'
  fi
}

fmt_utc() {  # <epoch>
  if date -u -r "$1" '+%Y-%m-%d %H:%M UTC' >/dev/null 2>&1; then
    date -u -r "$1" '+%Y-%m-%d %H:%M UTC'
  else
    date -u -d "@$1" '+%Y-%m-%d %H:%M UTC'
  fi
}

# --- the receipts record -----------------------------------------------------
# Layout lives in bin/fm-procevent-lib.sh so the runner cleans it with the
# registration; every byte and rule below is owned here.

receipts_path() { fm_procevent_receipts_path "$STATE" "$1"; }
receipts_lock_path() { fm_procevent_receipts_lock_path "$STATE" "$1"; }

# 0 when the record is absent (nothing journaled yet) or carries our schema.
# Anything else at that path - a symlink, a directory, a foreign schema - is
# unreadable rather than empty, so no state is ever presented from, and no event
# ever written through, a record this adapter does not own.
journal_readable() {  # <source-id>
  local f
  f=$(receipts_path "$1")
  [ -e "$f" ] || [ -L "$f" ] || return 0
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  [ "$(sed -n '1p' "$f" 2>/dev/null)" = "$RECEIPT_SCHEMA" ]
}

journal_events() {  # <source-id> <type>: print one type's event lines, oldest first
  local f
  f=$(receipts_path "$1")
  [ ! -L "$f" ] || return 1
  [ -f "$f" ] || return 0
  awk -F '\t' -v t="$2" '$1 == t { print }' "$f"
}

journal_count() {  # <source-id> <type>
  local n
  n=$(journal_events "$1" "$2" | grep -c '')
  printf '%s\n' "$n"
}

journal_last_field() {  # <source-id> <type> <field-number>
  journal_events "$1" "$2" | tail -n 1 | cut -f"$3"
}

journal_append() {  # <source-id> <event-line>
  local f
  f=$(receipts_path "$1")
  [ ! -L "$f" ] || return 1
  if [ ! -e "$f" ]; then
    (umask 077; mkdir -p "$(dirname "$f")") || return 1
    (umask 077; printf '%s\n' "$RECEIPT_SCHEMA" > "$f") || return 1
    chmod 0600 "$f" 2>/dev/null || true
  fi
  printf '%s\n' "$2" >> "$f" || return 1
}

has_event() {  # <source-id> <type> <sequence>
  journal_events "$1" "$2" | grep -qF "$(printf '%s\t%s\t' "$2" "$3")"
}

acquire_receipts_lock() {  # <source-id>
  local lock
  lock=$(receipts_lock_path "$1")
  (umask 077; mkdir -p "$(dirname "$lock")") || return 1
  fm_lock_acquire_wait "$lock"
}

cmd_arm() {
  local artifact=${1-} id real record
  [ -n "$artifact" ] || usage
  [ "$#" -eq 1 ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  poll_retry_delay >/dev/null
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(resolve_real "$artifact") \
    || die "cannot resolve the artifact path: $artifact"
  # This adapter's own listener command, which runs the plain blocking form with
  # no --timeout-ms so completion is a server event, and absorbs only the exact
  # transient interruption. Registering raw poll output is what let that
  # interruption reach the runner as a captured result.
  # A fresh arm hosts a fresh review, so the receipt lifecycle starts empty and
  # a reused artifact never inherits an earlier session's rounds. It never
  # starts while captured results of an earlier session are still unhandled:
  # resetting the record would orphan their Applying and Complete from the
  # received rounds they speak for.
  local unhandled=0 genf genseq
  for genf in "$STATE/procevent-inbox/$id."*.result; do
    [ -f "$genf" ] && [ ! -L "$genf" ] || continue
    genseq=${genf##*/}; genseq=${genseq%.result}; genseq=${genseq##*.}
    case "$genseq" in ''|*[!0-9]*) continue ;; esac
    fm_procevent_is_handled "$STATE" "$id" "$genseq" && continue
    unhandled=$((unhandled + 1))
  done
  [ "$unhandled" -eq 0 ] \
    || die "cannot arm: $unhandled unhandled captured result(s) for this artifact remain; reconcile or handle them first"
  local record
  record=$(receipts_path "$id")
  if [ -e "$record" ] || [ -L "$record" ]; then
    acquire_receipts_lock "$id" || die "cannot lock the receipts record"
    rm -f -- "$record"
    if [ -e "$record" ] || [ -L "$record" ]; then
      fm_lock_release "$(receipts_lock_path "$id")"
      die "cannot reset the receipts record: $id"
    fi
    fm_lock_release "$(receipts_lock_path "$id")"
  fi
  # The managed poll wraps the plain blocking form and nothing else: it presents
  # the current receipt through --agent-reply when the record has something to
  # state, then behaves identically to `lavish-axi poll <file>`.
  "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" -- \
    "$SCRIPT_DIR/fm-procevent-lavish.sh" managed-poll "$real" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
}

# The registered child: the published blocking poll, plus the one visible
# acknowledgement this adapter owns. With nothing received there is nothing to
# present and this is exactly the bare poll; otherwise the current receipt text
# is journaled as armed and passed through --agent-reply, so whatever the page
# shows next is a fact this record can prove.
cmd_managed_poll() {  # <artifact.html>
  local artifact=${1-} id real text digest upto
  [ "$#" -eq 1 ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(resolve_real "$artifact") \
    || die "cannot resolve the artifact path: $artifact"
  journal_readable "$id" || die "receipts record is unreadable: $id"
  # The snapshot and its armed record are built under one receipts lock: a
  # handler appending applying or complete between building the text and
  # journaling its armed count would present stale text while marking the new
  # count delivered, hiding the newly recorded transition.
  acquire_receipts_lock "$id" || die "cannot lock the receipts record"
  text=$(receipt_build_text "$id") \
    || { fm_lock_release "$(receipts_lock_path "$id")"; die "cannot build the receipt text: $id"; }
  if [ -n "$text" ]; then
    digest=$(sha16_text "$text")
    upto=$(journal_count "$id" received)
    journal_append "$id" "$(printf 'armed\t%s\t%s\t%s' "$(date +%s)" "$upto" "$digest")" \
      || { fm_lock_release "$(receipts_lock_path "$id")"; die "cannot journal the armed receipt"; }
  fi
  fm_lock_release "$(receipts_lock_path "$id")"
  if [ -n "$text" ]; then
    run_poll "$real" --agent-reply "$text"
    return  # the poll's exit status is the delivery attempt's outcome
  fi
  run_poll "$real"
}

# The runner's receipt seam: journal what this capture proved. Delivery first
# (this capture exists because a poll completed), then Received and Saved in
# that order - a Saved line is written only from the outcome file the runner
# hands over, which states what the one keyed-answer intake actually returned.
cmd_receipt() {  # <source-id> <sequence> <result-file> <outcome-file>
  local id=${1-} seq=${2-} result=${3-} outcome=${4-}
  [ "$#" -eq 4 ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer: $seq" ;; esac
  [ -f "$result" ] && [ ! -L "$result" ] || die "result file does not exist: $result"
  [ -f "$outcome" ] && [ ! -L "$outcome" ] || die "intake outcome file does not exist: $outcome"

  local classify submission armed_upto delivered_upto epoch submission_line=''
  local submission_rc=0
  classify=$(cmd_classify "$result")
  # A parse that did not complete is indeterminate, never proof that the
  # captain submitted nothing: it yields no verdict here, so this seam neither
  # acknowledges the capture as a pure delivery nor journals a round for it.
  submission=$(perl_rows submission "$result" 2>/dev/null) || submission_rc=$?
  [ "$submission_rc" -eq 0 ] || submission=''

  acquire_receipts_lock "$id" || die "cannot lock the receipts record"
  trap 'fm_lock_release "$(receipts_lock_path "$id")"' EXIT
  journal_readable "$id" || die "receipts record is unreadable: $id"
  epoch=$(date +%s)

  if [ "$classify" != missing ] && [ "$classify" != unknown ]; then
    armed_upto=$(journal_last_field "$id" armed 3); armed_upto=${armed_upto:-0}
    delivered_upto=$(journal_last_field "$id" delivered 3); delivered_upto=${delivered_upto:-0}
    case "$armed_upto$delivered_upto" in *[!0-9]*) armed_upto=0; delivered_upto=0 ;; esac
    if [ "$armed_upto" -gt "$delivered_upto" ]; then
      # This poll completed after arming an uncovered receipt: it displayed it,
      # unless the session was already gone - a missing session proves nothing.
      journal_append "$id" "$(printf 'delivered\t%s\t%s' "$epoch" "$armed_upto")" || true
      if [ "$classify" = ended ] && [ "$submission_rc" -eq 0 ] && [ -z "$submission" ]; then
        # A pure delivery capture has served its only purpose. Acknowledge it so
        # its wake never publishes: the handled marker is written under the same
        # per-source boundary the runner's publication checks - held across this
        # seam by the runner when it invoked us, taken here when it was not - so
        # a concurrent reconcile can never observe it unhandled. Any failure
        # here leaves the ordinary announcement path fully intact.
        local lock_taken=0
        if [ "${FM_PROCEVENT_RUNNER_SOURCE_LOCK_HELD:-}" = 1 ] || fm_procevent_source_lock_acquire "$id"; then
          [ "${FM_PROCEVENT_RUNNER_SOURCE_LOCK_HELD:-}" = 1 ] || lock_taken=1
          fm_procevent_is_handled "$STATE" "$id" "$seq" \
            || fm_procevent_mark_handled "$STATE" "$id" "$seq" >/dev/null 2>&1 || true
          [ "$lock_taken" -eq 0 ] || fm_procevent_source_lock_release "$id"
        fi
      fi
    fi
  fi

  if [ -n "$submission" ]; then
    local choices messages rows digest replay='-' closed='' skipped='' quality='' head_line
    choices=$(printf '%s' "$submission" | cut -f1)
    messages=$(printf '%s' "$submission" | cut -f2)
    rows=$(printf '%s' "$submission" | cut -f3)
    digest=$(printf '%s' "$submission" | cut -f4 | cut -c1-16)
    head_line=$(sed -n '1p' "$outcome")
    closed=$(grep -c '^closed: ' "$outcome" || true)
    # A digest that matches an earlier round is a replay - unless this
    # submission's own outcome proves a new effect: an answer skipped on its
    # first submission, because its task was not held yet, can be genuinely
    # applied when the captain resubmits it, and the captain must see that
    # action rather than an actionless "already received".
    if [ -n "$digest" ]; then
      replay=$(journal_events "$id" received | awk -F '\t' -v d="$digest" '$6 == d { print NR; exit }')
      [ -n "$replay" ] || replay='-'
    fi
    if [ "$replay" != '-' ] && [ "${head_line#fed }" != "$head_line" ]; then
      [ "${closed:-0}" -gt 0 ] && replay='-'
    fi
    case "$rows" in ''|*[!0-9]*) rows=0 ;; esac
    if [ "$rows" -gt 0 ] && ! has_event "$id" received "$seq"; then
      journal_append "$id" \
        "$(printf 'received\t%s\t%s\t%s\t%s\t%s\t%s' "$seq" "$epoch" "$choices" "$messages" "$digest" "$replay")" || true
      submission_line=received
    elif has_event "$id" received "$seq"; then
      submission_line=received
    fi
    if [ "${submission_line:-}" = received ] && [ "${head_line#fed }" != "$head_line" ]; then
      skipped=$(grep -c '^skipped: ' "$outcome" || true)
      # Every quality the intake can state is carried through verbatim; only a
      # verdict the runner vouches for in full is `ok`, and anything else makes
      # the receipt report an incomplete save rather than a verified one.
      local outcome_quality
      outcome_quality=$(sed -n '2p' "$outcome")
      quality=ok
      case "$outcome_quality" in
        truncated|unreadable|incomplete) quality=$outcome_quality ;;
      esac
      if ! has_event "$id" saved "$seq"; then
        journal_append "$id" \
          "$(printf 'saved\t%s\t%s\t%s\t%s\t%s' "$seq" "$(date +%s)" "${closed:-0}" "${skipped:-0}" "$quality")" || true
      fi
    fi
  fi

  fm_lock_release "$(receipts_lock_path "$id")"
  trap - EXIT
}

# Handler-owned state transitions. The wake handler records Applying when it
# begins routing the accepted answers and Complete when that routing is done;
# nothing else can produce these states, and Complete refuses without Applying.
cmd_applying() {  # <source-id> <sequence>
  local id=${1-} seq=${2-}
  [ "$#" -eq 2 ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer: $seq" ;; esac
  [ -f "$STATE/procevent-inbox/$id.$seq.result" ] && [ ! -L "$STATE/procevent-inbox/$id.$seq.result" ] \
    || die "no captured result for that generation: $id $seq"
  journal_readable "$id" || die "receipts record is unreadable: $id"
  acquire_receipts_lock "$id" || die "cannot lock the receipts record"
  trap 'fm_lock_release "$(receipts_lock_path "$id")"' EXIT
  if ! has_event "$id" received "$seq"; then
    die "no received submission for that generation: $id $seq"
  fi
  if has_event "$id" applying "$seq"; then
    printf 'already-applying: %s %s\n' "$id" "$seq"
  else
    journal_append "$id" "$(printf 'applying\t%s\t%s' "$seq" "$(date +%s)")" \
      || die "cannot record applying: $id $seq"
    printf 'applying: %s %s\n' "$id" "$seq"
  fi
  fm_lock_release "$(receipts_lock_path "$id")"
  trap - EXIT
}

cmd_complete() {  # <source-id> <sequence>
  local id=${1-} seq=${2-}
  [ "$#" -eq 2 ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer: $seq" ;; esac
  [ -f "$STATE/procevent-inbox/$id.$seq.result" ] && [ ! -L "$STATE/procevent-inbox/$id.$seq.result" ] \
    || die "no captured result for that generation: $id $seq"
  journal_readable "$id" || die "receipts record is unreadable: $id"
  acquire_receipts_lock "$id" || die "cannot lock the receipts record"
  trap 'fm_lock_release "$(receipts_lock_path "$id")"' EXIT
  if ! has_event "$id" applying "$seq"; then
    fm_lock_release "$(receipts_lock_path "$id")"
    trap - EXIT
    die "complete requires a recorded applying for the same generation: $id $seq"
  fi
  if has_event "$id" complete "$seq"; then
    printf 'already-complete: %s %s\n' "$id" "$seq"
  else
    journal_append "$id" "$(printf 'complete\t%s\t%s' "$seq" "$(date +%s)")" \
      || die "cannot record complete: $id $seq"
    printf 'complete: %s %s\n' "$id" "$seq"
  fi
  fm_lock_release "$(receipts_lock_path "$id")"
  trap - EXIT
}

cmd_receipt_text() {  # <source-id>
  local id=${1-} text
  [ "$#" -eq 1 ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  journal_readable "$id" || die "receipts record is unreadable: $id"
  text=$(receipt_build_text "$id") || die "cannot build the receipt text: $id"
  [ -n "$text" ] && printf '%s' "$text"
  return 0
}

# Build the visible receipt: one concise line per received round, stating only
# journaled facts. Every visible state - Received, Saved, Applying, Complete,
# Already received - appears only after its fact exists in the record.
receipt_build_text() {  # <source-id>
  local id=$1 total skip_floor n=0 out='' ev
  total=$(journal_count "$id" received) || return 1
  [ "$total" -gt 0 ] || { printf ''; return 0; }
  skip_floor=0
  [ "$total" -le "$RECEIPT_MAX_ROUNDS" ] || skip_floor=$((total - RECEIPT_MAX_ROUNDS))
  if [ "$skip_floor" -gt 0 ]; then
    out+="(+$skip_floor earlier round(s) received.)"$'\n'
  fi
  local seq epoch choices messages digest replay saved_line s_epoch s_closed s_skipped s_quality
  local applying_line a_epoch complete_line c_epoch answers_word
  while IFS= read -r ev; do
    [ -n "$ev" ] || continue
    n=$((n + 1))
    [ "$n" -gt "$skip_floor" ] || continue
    IFS=$'\t' read -r _ seq epoch choices messages digest replay <<< "$ev"
    if [ "$replay" != "-" ]; then
      out+="Round $n: already received at $(fmt_utc "$epoch") (identical to round $replay); no new action."$'\n'
      continue
    fi
    if [ "$choices" = 0 ]; then
      # A round that carried no answers has no answer count to state - a
      # comment-only submission, and equally a board holding only pure
      # annotations. The acknowledgement is the point, and it must never
      # claim a zero count for answers that were never asked of it. Its own
      # progress states are still its own, so this states the acknowledgement
      # and joins the rendering below rather than short-circuiting past it.
      out+="Round $n: received your written comment at $(fmt_utc "$epoch")"
    else
      answers_word="$choices answer"
      [ "$choices" = 1 ] || answers_word="$choices answers"
      out+="Round $n: received $answers_word"
      if [ "$messages" -gt 0 ]; then
        [ "$messages" = 1 ] && out+=' and a message' || out+=" and $messages messages"
      fi
      out+=" at $(fmt_utc "$epoch")"
    fi
    saved_line=$(journal_events "$id" saved | awk -F '\t' -v s="$seq" '$2 == s { print; exit }')
    if [ -n "$saved_line" ] && [ "$choices" -gt 0 ]; then
      IFS=$'\t' read -r _ _ s_epoch s_closed s_skipped s_quality <<< "$saved_line"
      if [ "$s_quality" = ok ]; then
        out+="; saved $s_closed of $choices at $(fmt_utc "$s_epoch")"
        [ "$s_skipped" = 0 ] || out+=" ($s_skipped not saved - firstmate follows up in chat)"
      else
        out+="; its saving report was incomplete at $(fmt_utc "$s_epoch") - firstmate follows up in chat"
      fi
    fi
    applying_line=$(journal_events "$id" applying | awk -F '\t' -v s="$seq" '$2 == s { print; exit }')
    complete_line=$(journal_events "$id" complete | awk -F '\t' -v s="$seq" '$2 == s { print; exit }')
    if [ -n "$complete_line" ]; then
      IFS=$'\t' read -r _ _ c_epoch <<< "$complete_line"
      out+="; complete at $(fmt_utc "$c_epoch")"
    elif [ -n "$applying_line" ]; then
      IFS=$'\t' read -r _ _ a_epoch <<< "$applying_line"
      out+="; firstmate is applying them (since $(fmt_utc "$a_epoch"))"
    fi
    out+='.'$'\n'
  done <<EOF
$(journal_events "$id" received)
EOF
  printf '%s' "$out" | head -c "$RECEIPT_MAX_TEXT_BYTES"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
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

# Arguments beyond the artifact are presented ONCE, on the first attempt only.
# The retried condition interrupts the poll response, after the server already
# accepted the request, so re-sending a visible argument like --agent-reply
# would repeat what the captain sees for a single round.
run_poll() {  # <artifact> [first-attempt-only lavish-axi poll arguments...]
  local artifact=${1-} delay attempt=0 response cleanup_command rc filter_rc
  local pipeline_status attempt_args
  [ -n "$artifact" ] || return 1
  shift
  attempt_args=("$@")
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
    lavish-axi poll "$artifact" ${attempt_args[@]+"${attempt_args[@]}"} | poll_response_filter "$response"
    pipeline_status=("${PIPESTATUS[@]}")
    rc=${pipeline_status[0]}
    filter_rc=${pipeline_status[1]}
    case "$filter_rc" in
      0) break ;;
      10)
        if [ "$attempt" -lt "$POLL_RETRY_LIMIT" ]; then
          attempt=$((attempt + 1))
          attempt_args=()
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

cmd_poll() {
  local artifact=${1-}
  [ -n "$artifact" ] || usage
  [ "$#" -eq 1 ] || usage
  run_poll "$artifact"
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
#
# One guard is added on top of those session facts, and it is what makes the
# visible receipt trustworthy: a review whose latest received submission still
# owes its receipt is not terminal yet, so the source stays armed for exactly
# one more poll - the one that presents the receipt - before retiring. A missing
# session can never display anything again, so its queued receipt stays queued
# and the source ends. An unreadable receipts record is never read as delivered.
cmd_terminal() {
  local file=${1-} classify id latest delivered submission rows seq
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  classify=$(cmd_classify "$file")
  case "$classify" in
    ended|missing) : ;;
    *)
      case "$(session_field "$file" session_ended)" in
        true|True|TRUE) : ;;
        *) return 1 ;;
      esac
      ;;
  esac
  [ "$classify" = missing ] && return 0
  id=$(fm_procevent_result_source_id "$file") || return 1
  fm_procevent_source_id_valid "$id" || return 1
  journal_readable "$id" || return 1
  # The journal's counts describe earlier rounds; they say nothing about what
  # THIS final result carries. So the result is parsed first, on every path: a
  # refused parse or a failed journal append must keep the source armed rather
  # than retire it unacknowledged. Terminal needs positive evidence - a
  # completely parsed result whose own receipt-worthy rows, if any, are already
  # journaled under this generation. A refused parse is indeterminate, never
  # proof of absence, whether or not an earlier round was already received.
  submission=$(perl_rows submission "$file" 2>/dev/null) || return 1
  rows=0
  if [ -n "$submission" ]; then
    rows=$(printf '%s' "$submission" | cut -f3)
    case "$rows" in ''|*[!0-9]*) return 1 ;; esac
  fi
  if [ "$rows" -gt 0 ]; then
    seq=$(fm_procevent_result_sequence "$file") || return 1
    case "$seq" in ''|*[!0-9]*) return 1 ;; esac
    has_event "$id" received "$seq" || return 1
  fi
  latest=$(journal_count "$id" received)
  case "$latest" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$latest" -gt 0 ]; then
    delivered=$(journal_last_field "$id" delivered 3); delivered=${delivered:-0}
    case "$delivered" in ''|*[!0-9]*) return 1 ;; esac
    [ "$delivered" -ge "$latest" ] && return 0
    return 1
  fi
  [ "$rows" -eq 0 ] || return 1
  return 0
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

# Shared row parser for the published response's `prompts[N]{field,...}:`
# section: exactly N indented CSV rows whose quoted fields carry JSON-style
# escapes, read in declared field ORDER rather than assuming a fixed column.
#
#   answers     print `key<TAB>answer<TAB>label[<TAB>mode]` for every structured
#               choice; the optional mode column relays the card's declared close
#               mode (`done` or `release`) to the keyed-answer intake. A freeform
#               `message` row is captain prose and is deliberately never a source
#               of decision keys. A row that does not carry both a slug-shaped
#               `question` and an `answer` inside its `Context data:` block is
#               skipped, so a deck that does not key its forms by decision key
#               simply yields nothing. The question cap is 128 so any task id
#               fits, including the long legacy `<origin>-decision-<key>`
#               identities pre-collapse decks still carry; the security property
#               is the slug SHAPE, which is unchanged.
#   submission  print `choices<TAB>messages<TAB>rows<TAB>sha256` summarizing every
#               queued row (no output when the result carries no prompts
#               section): the per-tag counts, the total row count, and a content
#               digest over each row's tag, prompt, and text - the
#               exact-submission identity a replay is detected by, stable across
#               DOM uids and selectors.
perl_rows() {  # <answers|submission> <result-file>
  local mode=${1-} file=${2-}
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  perl -MJSON::PP -MDigest::SHA=sha256_hex -e '
    use strict; use warnings;
    my ($mode, $path) = @ARGV;
    open my $fh, "<", $path or exit 1;
    my (@fields, $want, @rows, @parsed);
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
    # A block that declares N rows must deliver N rows: a truncated or partial
    # block is refused rather than summarized, because a summary over a prefix
    # would acknowledge answers that were never captured or applied. Exit 3
    # marks the parse indeterminate; callers must treat that as no verdict
    # rather than as an empty submission. A present-but-malformed row is still
    # tolerated row-wise, exactly as the read path tolerates it: its fields
    # land loosely, so it counts as nothing rather than forging a shape it
    # does not have.
    exit 3 if @fields && @rows < $want;
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
      push @parsed, \%f;
    }
    if ($mode eq "submission") {
      exit 0 unless @fields;
      my ($choices, $messages) = (0, 0);
      my $material = "";
      for my $f (@parsed) {
        my $tag = defined $f->{tag} ? $f->{tag} : "";
        $choices++ if $tag eq "choice";
        $messages++ if $tag eq "message";
        my $prompt = defined $f->{prompt} ? $f->{prompt} : "";
        my $text = defined $f->{text} ? $f->{text} : "";
        $material .= join("\x1f", $tag, $prompt, $text) . "\x1e";
      }
      printf "%d\t%d\t%d\t%s\n", $choices, $messages, scalar(@parsed), sha256_hex($material);
      exit 0;
    }
    my %seen;
    my @out;
    for my $f (@parsed) {
      next unless defined $f->{tag} && $f->{tag} eq "choice";
      my $prompt = $f->{prompt};
      next unless defined $prompt && $prompt =~ /Context data:\s*(\{.*\})/s;
      my $ctx = $1;
      my $data = eval { decode_json($ctx) };
      next unless ref($data) eq "HASH";
      my $key = $data->{question};
      my $answer = $data->{answer};
      next if !defined($key) || ref($key) || !defined($answer) || ref($answer);
      my $mode2 = "";
      if (exists $data->{close}) {
        next if !defined($data->{close}) || ref($data->{close})
          || ($data->{close} ne "done" && $data->{close} ne "release");
        $mode2 = $data->{close};
      }
      next unless $key =~ /\A[A-Za-z0-9._-]{1,128}\z/;
      next unless length $answer && length($answer) <= 512;
      my $label = defined $f->{text} ? $f->{text} : "";
      s/[\x00-\x1f\x7f]/ /g for ($answer, $label);
      $label = substr($label, 0, 512);
      # A re-answered form appears again later in the queue; the last submission wins.
      if (defined $seen{$key}) { $out[$seen{$key}] = undef }
      $seen{$key} = scalar @out;
      push @out, length $mode2 ? "$key\t$answer\t$label\t$mode2" : "$key\t$answer\t$label";
    }
    print "$_\n" for grep { defined } @out;
  ' "$mode" "$file"
}

cmd_answers() {
  local file=${1-}
  [ -n "$file" ] || usage
  perl_rows answers "$file"
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
  arm)          shift; cmd_arm "$@" ;;
  managed-poll) shift; cmd_managed_poll "$@" ;;
  receipt)      shift; cmd_receipt "$@" ;;
  applying)     shift; cmd_applying "$@" ;;
  complete)     shift; cmd_complete "$@" ;;
  receipt-text) shift; cmd_receipt_text "$@" ;;
  retire)       shift; cmd_retire "$@" ;;
  poll)         shift; cmd_poll "$@" ;;
  source-id)    shift; cmd_source_id "$@" ;;
  classify)     shift; cmd_classify "$@" ;;
  terminal)     shift; cmd_terminal "$@" ;;
  silent)       shift; cmd_silent "$@" ;;
  answers)      shift; cmd_answers "$@" ;;
  read)         shift; cmd_read "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
