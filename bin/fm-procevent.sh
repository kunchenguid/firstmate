#!/usr/bin/env bash
# Generic process-to-event runner: supervise a registered long-polling child
# outside the agent's foreground turn and turn completed results into normalized
# durable wakes.
#
# Usage:
#   fm-procevent.sh register <adapter> <source-id> -- <argv>...
#   fm-procevent.sh register-extension <adapter> <source-id> --config-ref <reference>
#   fm-procevent.sh start <source-id>
#   fm-procevent.sh reconcile
#   fm-procevent.sh classify <result-file>
#   fm-procevent.sh handled <source-id> <sequence>
#   fm-procevent.sh retire <source-id> [--if-absent|--if-matches <adapter> -- <argv>...|--if-owner <registration-token>]
#   fm-procevent.sh sweep-home [--preflight]
#   fm-procevent.sh binding-retirement-preflight <binding-digest>
#   fm-procevent.sh extension-retirement <binding|transfer> <retirement-arguments...>
#   fm-procevent.sh extension-bind <bind|receive-transfer-bind> <binding-arguments...>
#   fm-procevent.sh extension-process-event <process-event-arguments...>
#   fm-procevent.sh list
#
# register   Record a built-in source: its adapter, its canonical id, and the
#            exact argv to execute. argv is stored one argument per line and
#            executed directly, so there is no shell surface and no argument
#            splitting. Built-in adapters register sources; nothing here parses
#            user text.
# register-extension
#            Resolve an explicitly enabled home-local process-event-adapter/1
#            binding, verify its package and handshake, and record the source
#            configuration reference with the exact extension id/version,
#            capability version, package digest, binding digest, and a fresh
#            registration token. The tracked extension host constructs every
#            invocation; no package argv or shell command is stored.
# classify   Ask the immutable adapter owner captured beside <result-file> for a
#            bounded classification. Built-in results keep their existing
#            script command; extension results must still match the exact bound
#            package identity captured with them.
# start      Claim the source, run its child to completion, durably capture the
#            output, publish normalized wakes for pending results, then release
#            the claim. It blocks for as long as the source blocks and is meant
#            to run as a supervised background process, never in a conversational
#            turn. After publishing, it asks the source's own adapter whether the
#            captured result ends the source and retires the registration when it
#            says so, so a source that has ended stops being restarted.
# reconcile  Idempotent liveness entry the watcher calls on its ordinary cycle:
#            republish every durably captured result with no handled
#            acknowledgement yet - regardless of any earlier publication - and
#            start a runner for any registered source that has no live owner.
#            This is liveness repair only - it never discovers results by
#            polling the source, because the child blocks on the source itself.
# handled    Durably and idempotently record that a captured result has been
#            fully handled: <source-id> <sequence>. Prints "handled: id seq"
#            the first time for that exact source-and-sequence generation and
#            "already-handled: id seq" on every repeat call, atomically
#            deduplicated so a paired external effect is never authorized
#            twice. Until this is called, the result stays eligible for
#            bounded re-announcement on every reconcile. Marking a result
#            handled does not retire its source registration or claim.
# retire     Drop a registration, stop a runner this home owns, release the claim.
#            Idempotent, and still the supported explicit path after a source has
#            already retired itself on its adapter's terminal verdict. Existing
#            unconditional built-in retirement remains compatible. An external
#            registration requires --if-owner. --if-matches compares a complete
#            built-in registration, --if-absent refuses while any registration
#            exists, and --if-owner removes only the exact extension registration
#            token printed by register-extension, so a stale owner cannot retire
#            a replacement generation.
# sweep-home Retire a bounded snapshot of this home's registrations and owned
#            claims, then refuse unless no registration, runner record, or owned
#            claim remains. Used by supported Firstmate home retirement.
# binding-retirement-preflight
#            Refuse while an extension registration or unhandled captured result
#            still owns the exact enabled binding digest. Called by the tracked
#            extension host before identity-conditional binding retirement.
# extension-retirement
#            Serialize one tracked binding or transfer retirement against
#            extension resolution and registration publication in this home.
# extension-bind
#            Serialize tracked binding publication against extension resolution,
#            registration publication, and retirement in this home.
# list       Show registered sources, owners, and pending captured results.
#
# Terminal knowledge is adapter-owned. This runner never inspects a result and
# never names an adapter-specific status: built-ins keep the existing
# `bin/fm-procevent-<adapter>.sh terminal <result-file>` path, while an external
# result uses the exact process-event-adapter/1 package identity captured beside
# it. Exit 0 is the only terminal verdict. A missing command, an error, or any
# other exit keeps the registration armed, so an adapter that has no notion of
# ending needs no change.
#
# Routine no-op knowledge is adapter-owned through the same kind of seam. Some
# sources produce a result that carries no news at all - a review surface that
# simply closed with nothing said - and announcing it makes the handler read a
# wake to learn that nothing happened. So before publishing, this runner asks
# the immutable captured adapter owner - the built-in `silent` command or the
# bound extension operation - and treats exit 0 as the only silence verdict: the
# result is recorded handled and never announced, so it neither wakes a handler
# now nor returns on a later reconcile. A missing command, an error, or any other
# exit publishes the wake exactly as before, so an adapter with no notion of a
# no-op needs no change and an unknown or degraded result always reaches its
# handler. This runner still inspects nothing and still names no adapter-specific
# condition. For built-ins, silence remains independent of the keyed-answer feed
# below: suppressing an announcement never suppresses the captain's own answer.
#
# Applying a built-in result is adapter-owned through the same kind of seam. Some results
# carry no judgement at all - they must simply be applied idempotently to the
# home's own durable state - and leaving that to an agent that has to remember
# means it silently does not happen. So after publishing, `start` calls
# `bin/fm-procevent-<adapter>.sh autohandle <source-id> <sequence> <result-file>`
# and lets the adapter apply and acknowledge its own result. Exit 0 means the
# adapter fully handled it. A missing command, an error, or any other exit is not
# a failure of capture: the result stays unacknowledged and therefore eligible
# for re-announcement, so the handler still receives it exactly as before. This
# runner still inspects nothing and still names no adapter-specific condition.
# External bindings deliberately receive no autohandle operation.
#
# Built-in announcement is adapter-owned through one more seam of the same kind. An
# adapter that answers exit 0 to `bin/fm-procevent-<adapter>.sh self-announcing`
# declares that every result its autohandle fully applies is announced through a
# durable downstream channel of its own (for remote-reply, the mirrored parent
# status append the watcher's signal scan detects). For such an adapter, `start`
# runs autohandle FIRST and publishes a check wake only for what remains
# unhandled afterwards, so a fully autohandled capture never produces a second
# announcement and a byte-identical replay produces none at all. Every other
# adapter keeps the strict publish-before-apply order, because without a
# declared downstream channel an applied-and-acknowledged result would otherwise
# go silent. An unhandled result stays eligible for bounded re-announcement on
# every reconcile in both modes, exactly as before.
#
# Keyed captain answers from built-in adapters use one more seam of the same kind,
# and this runner still decides nothing about them. Some sources carry the
# captain's answer to a captain-held task. What such an answer MEANS is owned
# once, by bin/fm-captain-hold.sh's keyed-answer intake, and reaching it must not
# depend on an agent remembering. So after capture, a bound source
# has its result passed to
# `bin/fm-procevent-<adapter>.sh answers <result-file>`, and whatever that prints
# is piped straight into that one intake. The adapter reports only what the
# captain chose; the intake owns every rule about what happens next. This runner
# names no adapter, parses no result, and knows no decision rule, so a future
# built-in source needs nothing here beyond an `answers` command and a binding.
# External binding responses never enter this authority-bearing intake.
#
# Feeding is deliberately independent of handling: it never acknowledges a result
# and never suppresses a wake. Recording the captain's answer is transcription,
# while ACTING on it is firstmate's judgement, so the capture stays unacknowledged
# and its `check` wake reaches the handler exactly as it would have anyway.
#
# Receipt state is adapter-owned through one more seam of the same kind, and
# this runner presents nothing anywhere. The per-source boundary orders the
# capture against publication: the runner holds it across the durable capture
# and the staging of the receipt outcome and its generation note, releases it
# for the potentially slow external keyed-answer feed, and re-acquires a fresh
# hold for the seam, where it hands the adapter the outcome:
# `bin/fm-procevent-<adapter>.sh receipt <source-id> <sequence> <result-file>
# <outcome-file>`, where the outcome file states exactly what the intake
# returned - `not-fed`, `fed <exit>` plus its bounded output, or that verdict
# with an incomplete quality when the adapter's own extraction failed - so an
# adapter that acknowledges a capture toward its own audience can record what
# was received and what was saved, never more than that. A missing command, an
# error, or any other exit changes nothing: publication and handling proceed
# exactly as before. This runner never reads or presents a receipt.
#
# The unlocked feed never lets a capture publish early: while the outcome and
# its generation note are staged, publish_result declines the generation, and
# reconcile's recovery reclaims the seam once the runner's claim is gone, so a
# concurrent reconcile can neither observe a capture before the adapter
# acknowledged it nor run the seam twice.
#
# A runner killed between its durable capture and that seam leaves a generation
# the adapter never saw, and reconcile would otherwise republish it with its
# acknowledgement silently skipped. So the runner records, under the same hold,
# that the seam had its one chance at a generation, and reconcile gives that
# chance to any captured generation still missing it - before it publishes
# anything or starts a replacement - over whatever that generation can still
# prove. A runner killed after its intake returned left that verdict staged
# beside a note naming the exact source and sequence it speaks for, and the
# seam is handed it; a runner killed before the intake returned recorded no
# verdict, so the seam is handed an empty outcome rather than a guess. The
# intake is never re-fed, and the recorded note is what keeps a seam that
# already ran from running twice.
#
# Ownership is machine-wide per canonical source, because separate Firstmate
# homes can share one underlying source store. A live owner is never displaced;
# only a claim whose whole generation is gone is reclaimed. A runner leads its
# own process group, so a crashed leader whose group still has members is not
# stale: reconcile stops that surviving group and releases its generation before
# any replacement starts, and keeps the claim for a later retry when it cannot.
#
# Durability boundary: see bin/fm-procevent-lib.sh. This runner proves capture
# before publication and bounded re-announcement until handled, and nothing
# about the source side of the handoff.
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

case "${1-}" in ''|-h|--help|help) usage ;; esac

REG=$(fm_procevent_registry_dir "$STATE")
MAX_OUTPUT_BYTES=${FM_PROCEVENT_MAX_OUTPUT_BYTES:-1048576}
# Retirement's bounded wait for the adapter's receipts lock, in 0.1s tries. The
# bound is a property of the seam it waits on - one journal append - not an
# operator choice, so only a test overrides it.
RECEIPTS_RETIRE_LOCK_TRIES=${FM_PROCEVENT_RECEIPTS_RETIRE_LOCK_TRIES:-50}
EXTENSION_HOST="$SCRIPT_DIR/fm-extension.mjs"
EXTENSION_LIFECYCLE_LOCK="$REG/.extension-binding-lifecycle.lock"

state_root_bind() {  # [create]
  if [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; then
    [ "${1-}" = create ] || return 1
    (umask 077; mkdir -p "$STATE") || return 1
  fi
  STATE=$(fm_procevent_state_root_resolve "$STATE") || return 1
  REG=$(fm_procevent_registry_dir "$STATE")
  EXTENSION_LIFECYCLE_LOCK="$REG/.extension-binding-lifecycle.lock"
  FM_STATE_OVERRIDE=$STATE
  export FM_STATE_OVERRIDE
}

if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  state_root_bind || die "process-event state root is not a private directory"
fi

# Shared by the two bounded-capture sites: copy stdin to stdout up to $1 bytes,
# drain the rest, and exit 3 exactly when truncation was needed.
# shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
FM_PROCEVENT_BOUNDER='use strict;
    use warnings;
    my $limit = shift;
    my ($written, $truncated) = (0, 0);
    while (1) {
      my $count = sysread(STDIN, my $buffer, 65536);
      exit 2 unless defined $count;
      last if $count == 0;
      my $take = $written < $limit ? $limit - $written : 0;
      $take = $count if $take > $count;
      if ($take > 0) {
        my $offset = 0;
        while ($offset < $take) {
          my $count_written = syswrite(STDOUT, $buffer, $take - $offset, $offset);
          exit 2 unless defined $count_written;
          $offset += $count_written;
        }
        $written += $take;
      }
      $truncated = 1 if $take < $count;
    }
    exit($truncated ? 3 : 0);'

adapter_script() { printf '%s/bin/fm-procevent-%s.sh\n' "$FM_ROOT" "$1"; }

extension_lifecycle_lock_acquire() {
  state_root_bind create || return 1
  (umask 077; mkdir -p "$REG") || return 1
  [ -d "$REG" ] && [ ! -L "$REG" ] || return 1
  fm_lock_acquire_wait "$EXTENSION_LIFECYCLE_LOCK"
}

extension_lifecycle_lock_release() {
  fm_lock_release "$EXTENSION_LIFECYCLE_LOCK"
}

run_extension_invocation_cleanup() {  # [cleanup selector...]
  [ -x "$EXTENSION_HOST" ] && [ ! -L "$EXTENSION_HOST" ] || return 1
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$EXTENSION_HOST" cleanup-invocations "$@" >/dev/null 2>&1
  else
    FM_HOME="$FM_HOME" "$EXTENSION_HOST" cleanup-invocations "$@" >/dev/null 2>&1
  fi
}

cleanup_extension_binding_invocations() {  # <binding-digest>
  run_extension_invocation_cleanup --binding-digest "$1"
}

cleanup_extension_registration_invocations_locked() {  # <source-id>
  local owner_state
  fm_procevent_extension_registration_load_locked "$STATE" "$1"
  owner_state=$?
  case "$owner_state" in
    0) cleanup_extension_binding_invocations "$FM_PROCEVENT_EXTENSION_BINDING_DIGEST" ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
}

# Invoke one captured result through its exact extension owner. The immutable
# sidecar, not the current adapter name alone, supplies every expected binding
# field, so replacing a binding cannot reinterpret old evidence.
extension_result_command() {  # <adapter> <operation> <result-file>
  local adapter=$1 operation=$2 result=$3 owner_state reservation='' owner claim_path handoff_status
  fm_procevent_result_extension_load "$result"
  owner_state=$?
  [ "$owner_state" -eq 0 ] || return 1
  [ -x "$EXTENSION_HOST" ] && [ ! -L "$EXTENSION_HOST" ] || return 1
  case "$operation" in
    result.terminal) reservation=${FM_PROCEVENT_CAPTURE_RESERVATION_TERMINAL:-} ;;
    result.silent) reservation=${FM_PROCEVENT_CAPTURE_RESERVATION_SILENT:-} ;;
  esac
  local -a command=("$EXTENSION_HOST" process-event "$adapter" "$operation"
    --result-file "$result"
    --expect-extension "$FM_PROCEVENT_RESULT_EXTENSION_ID"
    --expect-version "$FM_PROCEVENT_RESULT_EXTENSION_VERSION"
    --expect-capability-version "$FM_PROCEVENT_RESULT_EXTENSION_CAPABILITY_VERSION"
    --expect-package-digest "$FM_PROCEVENT_RESULT_EXTENSION_PACKAGE_DIGEST"
    --expect-binding-digest "$FM_PROCEVENT_RESULT_EXTENSION_BINDING_DIGEST")
  if [ -n "$reservation" ]; then
    extension_lifecycle_lock_acquire || return 1
    owner=${FM_LOCK_OWNER_DIR:-}
    [ -n "$owner" ] || { extension_lifecycle_lock_release; return 1; }
    claim_path=$(fm_procevent_claim_path "$CLAIM_ID") || { extension_lifecycle_lock_release; return 1; }
    FM_EXTENSION_RETIREMENT_MODE=process-event \
      FM_EXTENSION_LIFECYCLE_LOCK="$EXTENSION_LIFECYCLE_LOCK" \
      FM_EXTENSION_LIFECYCLE_OWNER="$owner" \
      perl "$SCRIPT_DIR/fm-procevent-extension-capture.pl" handoff \
        8 6 "$claim_path" "$CLAIM_HOME" "$CLAIM_ID" "$CLAIM_TOKEN" "$CLAIM_PID" \
        "$(fm_pid_identity "$CLAIM_PID")" "$FM_PROCEVENT_RESULT_EXTENSION_BINDING_DIGEST" "$reservation" \
        "$operation" "$result" "$EXTENSION_HOST" -- "${command[@]:1}"
    handoff_status=$?
    extension_lifecycle_lock_release
    return "$handoff_status"
  fi
  "${command[@]}"
}

# Ask the source's own adapter whether a captured result ends the source. Exit 0
# is the only terminal verdict; everything else - including a missing adapter
# command - keeps the registration armed. See the terminal-knowledge note in the
# header: no adapter-specific condition may appear in this runner.
adapter_result_is_terminal() {  # <adapter> <result-file>
  local script owner_state
  fm_procevent_result_extension_load "$2"
  owner_state=$?
  case "$owner_state" in
    0) extension_result_command "$1" result.terminal "$2" >/dev/null 2>&1; return $? ;;
    2) return 1 ;;
  esac
  script=$(adapter_script "$1")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  "$script" terminal "$2" >/dev/null 2>&1
}

# Ask the source's own adapter whether a captured result is a routine no-op that
# needs no wake at all. This mirrors the terminal seam above exactly: exit 0 is
# the only silence verdict, and everything else - including a missing adapter
# command - publishes the wake. See the routine-no-op note in the header: no
# adapter-specific condition may appear in this runner.
adapter_result_is_silent() {  # <adapter> <result-file>
  local script owner_state
  fm_procevent_result_extension_load "$2"
  owner_state=$?
  case "$owner_state" in
    0) extension_result_command "$1" result.silent "$2" >/dev/null 2>&1; return $? ;;
    2) return 1 ;;
  esac
  script=$(adapter_script "$1")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  "$script" silent "$2" >/dev/null 2>&1
}

# Ask the adapter whether its autohandled results announce themselves through a
# durable downstream channel of their own (see the announcement-ownership note
# in the header). Exit 0 is the only declaration; everything else - including a
# missing adapter or an adapter without the command - keeps the strict
# publish-before-apply order.
adapter_self_announcing() {  # <adapter>
  local script
  script=$(adapter_script "$1")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  "$script" self-announcing >/dev/null 2>&1
}

source_file()  { printf '%s/%s.source\n' "$REG" "$1"; }
runner_file()  { printf '%s/%s.runner\n' "$REG" "$1"; }
staging_file() { printf '%s/.%s.%s.output\n' "$REG" "$1" "$2"; }

# Every private file one claim generation can leave staged: the capture's own
# bounded output, the receipt outcome, the generation note that pins that
# outcome to one sequence, the intake body staged beside it, and the outcome's
# atomic-rename staging name. A runner killed mid-generation leaves any of
# them, so reaping a claim drops them rather than the one name the caller
# happened to know about - with one exception. The outcome and its note are a
# verdict the receipt seam is still owed: while that seam has not run they are
# the only proof of a round whose answers the intake may already have applied,
# and recover_receipt_seams consumes them even after the source is retired. So
# they go only once the seam has had its chance, exactly as the claim reclaim
# in fm-procevent-lib.sh treats them.
remove_staged_generation() {  # <source-id> <claim-token>
  local outcome gen_id gen_seq
  outcome=$(staging_file "$1" "$2.rcpt")
  rm -f -- "$(staging_file "$1" "$2")" "$outcome.body" "$outcome.tmp"
  gen_seq=
  if [ -f "$outcome.gen" ] && [ ! -L "$outcome.gen" ]; then
    IFS=$'\t' read -r gen_id gen_seq < "$outcome.gen" || gen_seq=
    [ "$gen_id" = "$1" ] || gen_seq=
    case "$gen_seq" in ''|*[!0-9]*) gen_seq= ;; esac
  fi
  if [ -z "$gen_seq" ] || fm_procevent_receipt_seam_ran "$STATE" "$1" "$gen_seq"; then
    rm -f -- "$outcome" "$outcome.gen"
  fi
}

# Let the source's own adapter apply and acknowledge one captured result. See
# the header for why this exists and what each exit means. An already
# acknowledged result is skipped, so this is safe to call more than once for the
# same generation. The adapter runs OUTSIDE any source-lock hold here, because a
# handling adapter is expected to re-arm its own next source, which takes that
# same lock.
adapter_autohandle() {  # <adapter> <source-id> <result-file>
  local adapter=$1 id=$2 result=$3 script seq
  script=$(adapter_script "$adapter")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  seq=$(fm_procevent_result_sequence "$result") || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  fm_procevent_is_handled "$STATE" "$id" "$seq" && return 0
  # Silenced exactly like the terminal seam above, so an adapter that has no
  # such command is a quiet no-op rather than runner noise. This runner's own
  # one-line outcome is the interface; an adapter that failed keeps its result
  # announced, and the handler's own call reproduces the diagnostics in full.
  "$script" autohandle "$id" "$seq" "$result" >/dev/null 2>&1
}

# Pass a bound source's captured result to the one keyed-answer intake. The
# adapter turns its own format into keyed lines; the intake owns everything those
# lines mean. Silenced and best-effort exactly like the seams above: an unbound
# source, an adapter with no `answers` command, and a failure on either side all
# leave the capture untouched and still announced, because this never
# acknowledges anything (see the keyed-answer note in the header).
#
# Whatever the intake returned is written to the outcome file for the receipt
# seam: `not-fed`, or `fed <exit>` plus the bounded stdout of the intake. A
# truncated or unreadable capture is stated as such rather than silently
# presented as a complete verdict.
feed_keyed_answers() {  # <adapter> <source-id> <result-file> <outcome-file>
  local adapter=$1 id=$2 result=$3 outcome=$4 script origin seq
  local intake_rc bound_rc answers_rc body pipe_status
  body="$outcome.body"
  script=$(adapter_script "$adapter")
  if [ ! -f "$script" ] || [ -L "$script" ] \
    || ! origin=$("$SCRIPT_DIR/fm-captain-hold.sh" binding "$id" 2>/dev/null) \
    || [ -z "$origin" ] \
    || ! seq=$(fm_procevent_result_sequence "$result"); then
    printf 'not-fed\n' > "$outcome"
    return 1
  fi
  # Both staged files can carry task-id rows, so neither may depend on the
  # caller's umask for its privacy, and neither may be written through anything
  # already standing at its path.
  [ ! -e "$body" ] && [ ! -L "$body" ] || { printf 'not-fed\n' > "$outcome"; return 1; }
  (umask 077; : > "$body") || { printf 'not-fed\n' > "$outcome"; return 1; }
  "$script" answers "$result" 2>/dev/null \
    | "$SCRIPT_DIR/fm-captain-hold.sh" answers "$origin" \
        --source "the captured result $id sequence $seq" 2>/dev/null \
    | perl -e "$FM_PROCEVENT_BOUNDER" "$MAX_OUTPUT_BYTES" > "$body"
  pipe_status=("${PIPESTATUS[@]}")
  answers_rc=${pipe_status[0]}
  intake_rc=${pipe_status[1]}
  bound_rc=${pipe_status[2]}
  # The completed outcome is staged beside its final path and renamed into
  # place, so a reader - the seam, or recovery after a runner died mid-write -
  # never sees a half-written verdict as a whole one.
  [ ! -e "$outcome.tmp" ] && [ ! -L "$outcome.tmp" ] \
    || { printf 'not-fed\n' > "$outcome"; rm -f -- "$body"; return 1; }
  (umask 077; : > "$outcome.tmp") \
    || { printf 'not-fed\n' > "$outcome"; rm -f -- "$body"; return 1; }
  {
    if [ "$answers_rc" -ne 0 ]; then
      # The adapter failed to extract its own answers. The intake above may
      # still have consumed and applied part of what came through, so the
      # outcome states fed with an incomplete quality rather than not-fed:
      # the receipt says its saving report was incomplete instead of
      # presenting a verified save over rows this runner cannot vouch for.
      printf 'fed %s\nincomplete\n' "$intake_rc"
    elif [ "$bound_rc" -eq 0 ]; then
      printf 'fed %s\n' "$intake_rc"
    elif [ "$bound_rc" -eq 3 ]; then
      printf 'fed %s\ntruncated\n' "$intake_rc"
    else
      printf 'fed %s\nunreadable\n' "$intake_rc"
    fi
    cat "$body"
  } > "$outcome.tmp"
  if mv -f -- "$outcome.tmp" "$outcome"; then
    rm -f -- "$body"
    return "$intake_rc"
  fi
  rm -f -- "$outcome.tmp" "$body"
  return 1
}

# Let the source's own adapter record receipt state for one captured result and
# prepare whatever acknowledgement it presents to its own audience (see the
# receipt-state note in the header). Silenced and best-effort exactly like the
# seams above: an adapter with no such command, and any failure on its side,
# leaves the capture untouched and still announced.
adapter_receipt() {  # <adapter> <source-id> <sequence> <result-file> <outcome-file>
  local adapter=$1 script
  script=$(adapter_script "$adapter")
  [ -f "$script" ] && [ ! -L "$script" ] || return 0
  "$script" receipt "$2" "$3" "$4" "$5" >/dev/null 2>&1
}

read_adapter() {  # <source-id>
  local f; f=$(source_file "$1")
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  sed -n 's/^adapter=//p' "$f" | head -1
}

# Read the stored argv into the ARGV array. One argument per line after the
# argv= count, so an argument containing spaces is not re-split.
read_argv() {  # <source-id>
  local f n; f=$(source_file "$1")
  ARGV=()
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  n=$(sed -n 's/^argc=//p' "$f" | head -1)
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  local i=0 line
  while IFS= read -r line; do
    i=$((i + 1))
    [ "$i" -le "$n" ] && ARGV+=("$line")
  done < <(sed -n '/^argv:$/,$p' "$f" | tail -n +2)
  [ "${#ARGV[@]}" -eq "$n" ]
}

extension_registration_replacement_safe_locked() {  # <source-id>
  local id=$1 owner_state claim_state
  if [ ! -e "$(source_file "$id")" ] && [ ! -L "$(source_file "$id")" ]; then
    return 0
  fi
  fm_procevent_extension_registration_load_locked "$STATE" "$id"
  owner_state=$?
  [ "$owner_state" -eq 0 ] || return 0
  fm_procevent_claim_state_locked "$id"
  claim_state=$?
  case "$claim_state" in
    0|2|3|4) return 1 ;;
    *) return 0 ;;
  esac
}

cmd_register() {
  local adapter=${1-} id=${2-} sep=${3-}
  shift 3 2>/dev/null || usage
  fm_procevent_adapter_valid "$adapter" || die "adapter name must be lowercase alphanumeric or dash: $adapter"
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe and at most 64 characters: $id"
  [ "$sep" = -- ] || usage
  [ "$#" -ge 1 ] || die "register needs at least one argv element after --"
  local arg
  for arg in "$@"; do
    case "$arg" in *$'\n'*) die "argv elements cannot contain newlines" ;; esac
  done
  [ -f "$(adapter_script "$adapter")" ] || die "no installed adapter for: $adapter"
  state_root_bind create || die "cannot safely prepare the process-event state root"
  fm_procevent_source_lock_acquire "$id" || die "cannot lock the source"
  if ! extension_registration_replacement_safe_locked "$id"; then
    fm_procevent_source_lock_release "$id"
    die "cannot replace extension registration while its prior runner remains active: $id"
  fi
  if ! fm_procevent_registration_publish_locked "$STATE" "$adapter" "$id" "$@"; then
    fm_procevent_source_lock_release "$id"
    die "cannot publish the registration"
  fi
  fm_procevent_source_lock_release "$id"
  printf 'registered: %s (%s)\n' "$id" "$adapter"
}

new_extension_registration_token() {
  local hex
  hex=$(LC_ALL=C od -An -v -tx1 -N 32 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  [ "${#hex}" -eq 64 ] || return 1
  printf 'sha256:%s\n' "$hex"
}

extension_source_request_id() {  # <adapter> <source-id> <next-sequence> <registration-token> <package-digest>
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf 'firstmate-process-event-request-v1\n%s\n%s\n%s\n%s\n%s\n' "$@" \
      | shasum -a 256 | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf 'firstmate-process-event-request-v1\n%s\n%s\n%s\n%s\n%s\n' "$@" \
      | sha256sum | awk '{print $1}') || return 1
  else
    return 1
  fi
  [ "${#digest}" -eq 64 ] || return 1
  printf 'sha256:%s\n' "$digest"
}

next_result_sequence() {  # <source-id>
  local id=$1 inbox seq=1
  inbox=$(fm_procevent_inbox_dir "$STATE")
  while [ -e "$inbox/$id.$seq.result" ]; do seq=$((seq + 1)); done
  printf '%s\n' "$seq"
}

cmd_register_extension() {
  local adapter=${1-} id=${2-} option=${3-} config_ref=${4-} resolution schema extension_id
  local extension_version capability_version package_digest binding_digest extra registration_token
  [ "$#" -eq 4 ] || usage
  fm_procevent_adapter_valid "$adapter" || die "adapter name must be lowercase alphanumeric or dash: $adapter"
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe and at most 64 characters: $id"
  [ "$option" = --config-ref ] || usage
  fm_procevent_extension_config_ref_valid "$config_ref" \
    || die "source configuration reference must be one bounded line"
  if [ ! -x "$EXTENSION_HOST" ] || [ -L "$EXTENSION_HOST" ]; then
    die "the tracked extension host is unavailable"
  fi
  extension_lifecycle_lock_acquire || die "cannot lock the extension lifecycle"
  if ! resolution=$("$EXTENSION_HOST" resolve-process-event "$adapter"); then
    extension_lifecycle_lock_release
    die "extension adapter verification failed: $adapter"
  fi
  if [ "$(printf '%s\n' "$resolution" | wc -l | tr -d ' ')" != 1 ]; then
    extension_lifecycle_lock_release
    die "extension adapter resolution was malformed: $adapter"
  fi
  IFS=$'\t' read -r schema extension_id extension_version capability_version \
    package_digest binding_digest extra <<< "$resolution"
  if [ "$schema" != fm-extension-process-event-resolution.v1 ] || [ -n "$extra" ]; then
    extension_lifecycle_lock_release
    die "extension adapter resolution was malformed: $adapter"
  fi
  if ! fm_procevent_extension_id_valid "$extension_id" \
    || ! fm_procevent_extension_version_valid "$extension_version" \
    || [ "$capability_version" != 1 ] \
    || ! fm_procevent_digest_valid "$package_digest" \
    || ! fm_procevent_digest_valid "$binding_digest"; then
    extension_lifecycle_lock_release
    die "extension adapter identity was malformed: $adapter"
  fi
  if ! registration_token=$(new_extension_registration_token); then
    extension_lifecycle_lock_release
    die "cannot create an extension registration identity"
  fi
  if ! fm_procevent_source_lock_acquire "$id"; then
    extension_lifecycle_lock_release
    die "cannot lock the source"
  fi
  if ! extension_registration_replacement_safe_locked "$id"; then
    fm_procevent_source_lock_release "$id"
    extension_lifecycle_lock_release
    die "cannot replace extension registration while its prior runner remains active: $id"
  fi
  if ! fm_procevent_extension_registration_publish_locked "$STATE" "$adapter" "$id" \
      "$extension_id" "$extension_version" "$capability_version" "$package_digest" \
      "$binding_digest" "$config_ref" "$registration_token"; then
    fm_procevent_source_lock_release "$id"
    extension_lifecycle_lock_release
    die "cannot publish the extension registration"
  fi
  fm_procevent_source_lock_release "$id"
  extension_lifecycle_lock_release
  printf 'registered: %s (%s from %s@%s)\n' "$id" "$adapter" "$extension_id" "$extension_version"
  printf 'owner-token: %s\n' "$registration_token"
  printf 'retire: bin/fm-procevent.sh retire %s --if-owner %s\n' "$id" "$registration_token"
}

# Publish every durably captured result with no handled acknowledgement yet.
# Capture already happened, so this only turns durable state into durable
# events - and it republishes on every call regardless of any earlier
# publication, so a result stays eligible for re-announcement across restarts
# and drains until `fm_procevent_mark_handled` records it.
publish_result() {  # <result-file>
  local result=$1 id seq adapter line status=1
  id=$(fm_procevent_result_source_id "$result")
  seq=$(fm_procevent_result_sequence "$result")
  fm_procevent_source_id_valid "$id" || return 1
  adapter=$(fm_procevent_result_adapter "$result" 2>/dev/null || true)
  [ -n "$adapter" ] || return 1
  line=$(fm_procevent_event_line "$adapter" "$id" "$seq") || return 1
  fm_procevent_source_lock_acquire "$id" || return 1
  # A generation whose receipt seam is still owed - its staged outcome and
  # generation note exist but no seam-ran marker proves the seam saw it - is
  # never published here. The live runner that captured it publishes it after
  # the seam, and recovery runs the seam for a dead one before this loop, so
  # declining here only ever delays a wake until its acknowledgement is
  # ordered, which is the boundary's whole point.
  if ! fm_procevent_receipt_seam_ran "$STATE" "$id" "$seq" \
    && [ -n "$(staged_receipt_outcome "$id" "$seq" 2>/dev/null || true)" ]; then
    fm_procevent_source_lock_release "$id"
    return 1
  fi
  if ! fm_procevent_is_handled "$STATE" "$id" "$seq"; then
    # A result its own adapter declares a routine no-op is recorded as handled
    # and never announced, so it neither wakes a handler now nor comes back on
    # a later reconcile's re-announcement. Recording it is what makes that
    # silence durable, so both a newly written marker (0) and one a concurrent
    # caller already wrote (1) settle it; only an unrecordable silence (2)
    # falls through and announces, because a silence nothing remembers would
    # otherwise be re-evaluated on every reconcile forever.
    export FM_PROCEVENT_CAPTURE_SOURCE_LOCK_HELD=1
    if adapter_result_is_silent "$adapter" "$result"; then
      unset FM_PROCEVENT_CAPTURE_SOURCE_LOCK_HELD
      fm_procevent_mark_handled "$STATE" "$id" "$seq"
      case "$?" in
        0|1)
          fm_procevent_source_lock_release "$id"
          return 1
          ;;
      esac
    fi
    unset FM_PROCEVENT_CAPTURE_SOURCE_LOCK_HELD
    if fm_wake_append check "procevent:$id:$seq" "check: $line"; then
      status=0
    fi
  fi
  fm_procevent_source_lock_release "$id"
  return "$status"
}

publish_pending() {  # [result-file-to-skip]
  local skip=${1-} result published=0
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    [ "$result" = "$skip" ] && continue
    if publish_result "$result"; then
      published=$((published + 1))
    fi
  done < <(fm_procevent_pending "$STATE")
  printf '%s\n' "$published"
}

isolate_runner() {  # <wait|detach> <source-id>
  local mode=$1 id=$2 program
  # shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
  program='my $mode = shift @ARGV;
    defined(my $pid = fork) or exit 125;
    if ($pid == 0) {
      setpgrp(0, 0) or exit 125;
      $ENV{FM_PROCEVENT_RUNNER_GROUP} = $$;
      exec @ARGV;
      exit 125;
    }
    exit 0 if $mode eq "detach";
    waitpid($pid, 0) == $pid or exit 125;
    my $status = $?;
    exit(128 + ($status & 127)) if $status & 127;
    exit($status >> 8);'
  if [ "$mode" = wait ]; then
    exec perl -e "$program" "$mode" "$SCRIPT_DIR/fm-procevent.sh" _start "$id"
  fi
  perl -e "$program" "$mode" "$SCRIPT_DIR/fm-procevent.sh" _start "$id" >/dev/null 2>&1 &
}

require_runner_group() {
  local pgid
  [ "${FM_PROCEVENT_RUNNER_GROUP:-}" = "$$" ] \
    || die "runner process group was not isolated"
  pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]') \
    || die "cannot inspect runner process group"
  [ -n "$pgid" ] || die "cannot inspect runner process group"
  [ "$pgid" = "$$" ] || die "runner does not lead its process group"
  unset FM_PROCEVENT_RUNNER_GROUP
}

cmd_start_public() {
  local id=${1-}
  [ "$#" -eq 1 ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  isolate_runner wait "$id"
}

cmd_start() {
  local id=${1-} adapter out rc claimed bound_rc published_capture=0 handled_capture=0 self_announcing=0
  local extension_owner=0 extension_load_state extension_sequence='' extension_request_id=''
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  require_runner_group
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  if [ ! -f "$(source_file "$id")" ] || [ -L "$(source_file "$id")" ]; then
    fm_procevent_source_lock_release "$id"
    die "source is not registered: $id"
  fi
  if ! adapter=$(read_adapter "$id"); then
    fm_procevent_source_lock_release "$id"
    die "registration is unreadable: $id"
  fi
  if ! fm_procevent_adapter_valid "$adapter"; then
    fm_procevent_source_lock_release "$id"
    die "registration names an invalid adapter"
  fi
  fm_procevent_extension_registration_load_locked "$STATE" "$id"
  extension_load_state=$?
  case "$extension_load_state" in
    0)
      extension_owner=1
      [ "$FM_PROCEVENT_EXTENSION_ADAPTER" = "$adapter" ] || {
        fm_procevent_source_lock_release "$id"
        die "extension registration adapter identity is inconsistent: $id"
      }
      [ -x "$EXTENSION_HOST" ] && [ ! -L "$EXTENSION_HOST" ] || {
        fm_procevent_source_lock_release "$id"
        die "the tracked extension host is unavailable"
      }
      extension_sequence=$(next_result_sequence "$id") \
        || { fm_procevent_source_lock_release "$id"; die "cannot derive extension request sequence: $id"; }
      extension_request_id=$(extension_source_request_id "$adapter" "$id" "$extension_sequence" \
        "$FM_PROCEVENT_EXTENSION_REGISTRATION_TOKEN" "$FM_PROCEVENT_EXTENSION_PACKAGE_DIGEST") \
        || { fm_procevent_source_lock_release "$id"; die "cannot derive extension request identity: $id"; }
      ARGV=("$EXTENSION_HOST" process-event "$adapter" source.poll \
        --source-id "$id" --config-ref "$FM_PROCEVENT_EXTENSION_CONFIG_REF" \
        --request-id "$extension_request_id" \
        --expect-extension "$FM_PROCEVENT_EXTENSION_ID" \
        --expect-version "$FM_PROCEVENT_EXTENSION_VERSION" \
        --expect-capability-version "$FM_PROCEVENT_EXTENSION_CAPABILITY_VERSION" \
        --expect-package-digest "$FM_PROCEVENT_EXTENSION_PACKAGE_DIGEST" \
        --expect-binding-digest "$FM_PROCEVENT_EXTENSION_BINDING_DIGEST")
      ;;
    1)
      if ! read_argv "$id"; then
        fm_procevent_source_lock_release "$id"
        die "registration argv is unreadable: $id"
      fi
      ;;
    *)
      fm_procevent_source_lock_release "$id"
      die "extension registration owner is unreadable: $id"
      ;;
  esac
  fm_procevent_claim_acquire_locked "$id" "$FM_HOME" "$$" "$(source_file "$id")" "$STATE"
  claimed=$?
  fm_procevent_source_lock_release "$id"
  case "$claimed" in
    0) ;;
    2) printf 'already owned: %s\n' "$id"; exit 0 ;;
    *) die "cannot claim source: $id" ;;
  esac
  CLAIM_ID=$id
  CLAIM_HOME=$FM_HOME
  CLAIM_PID=$$
  CLAIM_TOKEN=$FM_PROCEVENT_CLAIM_TOKEN
  CLAIM_REG_IDENTITY=$FM_PROCEVENT_CLAIM_REG_IDENTITY
  STAGED_OUTPUT=
  RECEIPT_OUTCOME=
  release_start_claim() {
    extension_lifecycle_lock_release 2>/dev/null || true
    [ -z "$STAGED_OUTPUT" ] || rm -f -- "$STAGED_OUTPUT"
    # The receipt staging is deliberately left where it lies. An abnormal exit
    # is exactly when the generation note has to keep publication waiting and
    # the staged verdict has to survive for the seam recovery owes this round;
    # the reaping paths that drop a claim's staging set own its cleanup. The
    # claim is deliberately left with it, for that same reason: every one of
    # those paths is keyed on the claim record, so releasing it here would
    # orphan the staged set from the only owner that can reap it. A generation
    # still mid-flight keeps both, and the stale-claim recovery takes them
    # together. Only an exit with nothing staged - before the capture, or after
    # the normal cleanup - releases the claim.
    [ -z "$RECEIPT_OUTCOME" ] || return 0
    fm_procevent_source_lock_acquire "$CLAIM_ID" 2>/dev/null || return 0
    if fm_procevent_claim_load_locked "$CLAIM_ID" 2>/dev/null \
      && [ "$FM_PROCEVENT_CLAIM_HOME" = "$CLAIM_HOME" ] \
      && [ "$FM_PROCEVENT_CLAIM_PID" = "$CLAIM_PID" ] \
      && [ "$FM_PROCEVENT_CLAIM_TOKEN" = "$CLAIM_TOKEN" ] \
      && [ "$FM_PROCEVENT_CLAIM_TERMINAL" = terminal ]; then
      fm_procevent_source_lock_release "$CLAIM_ID" 2>/dev/null || true
      return 0
    fi
    fm_procevent_claim_release_locked "$CLAIM_ID" "$CLAIM_HOME" "$CLAIM_PID" "$CLAIM_TOKEN" 2>/dev/null || true
    fm_procevent_source_lock_release "$CLAIM_ID" 2>/dev/null || true
  }
  trap release_start_claim EXIT
  local runner inbox reservation_dir staging
  if [ "$extension_owner" -eq 1 ]; then
    staging=$(fm_procevent_extension_staging_prepare "$STATE") \
      || die "cannot safely prepare the external registry staging boundary"
    inbox=$(fm_procevent_capture_inbox_prepare "$STATE") \
      || die "cannot durably capture the extension result"
    CDPATH='' cd -- "$staging" 2>/dev/null \
      || die "cannot safely prepare the external registry staging boundary"
    [ "$(pwd -P)" = "$staging" ] \
      || die "cannot safely prepare the external registry staging boundary"
    exec 9<. || die "cannot retain the external registry staging boundary"
    CDPATH='' cd -- "$inbox" 2>/dev/null \
      || die "cannot durably capture the extension result"
    [ "$(pwd -P)" = "$inbox" ] \
      || die "cannot durably capture the extension result"
    exec 8<. || die "cannot retain the external capture boundary"
    reservation_dir=$(fm_procevent_capture_reservation_prepare "$STATE") \
      || die "cannot retain the external capture reservation boundary"
    exec 6<"$reservation_dir" || die "cannot retain the external capture reservation boundary"
    FM_PROCEVENT_CAPTURE_PINNED_INBOX=1
    export FM_PROCEVENT_CAPTURE_INBOX_FD=8
    runner="$id.runner"
  else
    runner=$(runner_file "$id")
  fi

  case "$MAX_OUTPUT_BYTES" in ''|*[!0-9]*) die "FM_PROCEVENT_MAX_OUTPUT_BYTES must be a nonnegative integer" ;; esac
  if [ "$extension_owner" -eq 1 ]; then
    out=".$id.$CLAIM_TOKEN.output"
  else
    out=$(staging_file "$id" "$CLAIM_TOKEN")
    printf '%s\n' "$$" > "$runner" 2>/dev/null || true
    chmod 0600 "$runner" 2>/dev/null || true
  fi
  # Built-in adapters do not run the extension capture helper, so keep this
  # sentinel defined while sharing the no-result branch below under `set -u`.
  local truncated=0 capture_state='' durable='' reservation_terminal='' reservation_silent=''
  if [ "$extension_owner" -eq 1 ]; then
    capture_state=$(perl "$SCRIPT_DIR/fm-procevent-extension-capture.pl" \
      9 8 6 "$id" "$adapter" "$FM_PROCEVENT_EXTENSION_ID" \
      "$FM_PROCEVENT_EXTENSION_VERSION" "$FM_PROCEVENT_EXTENSION_CAPABILITY_VERSION" \
      "$FM_PROCEVENT_EXTENSION_PACKAGE_DIGEST" "$FM_PROCEVENT_EXTENSION_BINDING_DIGEST" \
      "$CLAIM_TOKEN" "$runner" "$out" "$$" "$(fm_pid_identity "$$")" "$MAX_OUTPUT_BYTES" -- "${ARGV[@]}") \
      || die "cannot safely stage the extension result"
    IFS=$'\t' read -r capture_state durable rc truncated reservation_terminal reservation_silent <<EOF
$capture_state
EOF
    exec 9<&-
    case "$capture_state" in
      captured|no-result) ;;
      failure) die "external source invocation failed: $id" ;;
      *) die "cannot safely stage the extension result" ;;
    esac
    if [ "$capture_state" = captured ]; then
      FM_PROCEVENT_CAPTURE_RESERVATION_TERMINAL=$reservation_terminal
      FM_PROCEVENT_CAPTURE_RESERVATION_SILENT=$reservation_silent
    fi
  else
    [ ! -e "$out" ] && [ ! -L "$out" ] || die "cannot safely stage output"
    (umask 077; : > "$out") || die "cannot stage output"
    STAGED_OUTPUT=$out
    "${ARGV[@]}" 2>/dev/null | perl -e "$FM_PROCEVENT_BOUNDER" "$MAX_OUTPUT_BYTES" > "$out"
    local pipe_status=("${PIPESTATUS[@]}")
    rc=${pipe_status[0]}
    bound_rc=${pipe_status[1]}
    case "$bound_rc" in
      0) ;;
      3) truncated=1 ;;
      *) die "cannot bound source output" ;;
    esac
  fi


  if [ "$capture_state" = no-result ] || { [ "$extension_owner" -eq 0 ] && [ "$rc" -ne 0 ] && [ ! -s "$out" ]; }; then
    # No usable result. Leave the registration armed; the adapter decides
    # whether a nonzero exit is terminal when it handles the next result.
    if [ "$extension_owner" -eq 0 ]; then
      rm -f -- "$out" "$runner"
    fi
    printf 'no-result: %s (exit %s)\n' "$id" "$rc"
    exit 0
  fi

  # The per-source boundary orders capture against publication, but the
  # external keyed-answer intake no longer runs under it: a slow or hung
  # backlog would otherwise wedge every reconcile, publication, and retirement
  # that needs this source's lock. The ordering the boundary exists for - a
  # concurrent reconcile must never publish a capture whose receipt seam has
  # not spoken - is preserved by the staged outcome and its generation note:
  # publish_result declines a generation whose seam is still owed (marker
  # present, seam-ran marker absent), and recover_receipt_seams leaves a
  # generation staged under this runner's own claim token to this runner. The
  # feed writes its verdict atomically, so recovery after a death here reads a
  # whole outcome or none.
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  if [ "$extension_owner" -eq 1 ]; then
    durable="./$durable"
  else
    durable=$(fm_procevent_capture "$STATE" "$id" "$adapter" "$out") \
      || { fm_procevent_source_lock_release "$id"; rm -f -- "$out"; die "cannot durably capture the result"; }
  fi
  [ "$extension_owner" -eq 1 ] || rm -f -- "$out"
  STAGED_OUTPUT=
  [ "$truncated" -eq 1 ] && printf 'truncated: %s at %s bytes\n' "$id" "$MAX_OUTPUT_BYTES" >&2

  # Independent of publication and acknowledgement, so it runs once per capture
  # for every adapter and cannot change what the handler receives. The receipt
  # seam runs after the feed so a receipt can state the intake's verdict, and
  # before publication so recording a receipt can never delay a capture's wake.
  local durable_seq
  durable_seq=$(fm_procevent_result_sequence "$durable")
  RECEIPT_OUTCOME=$(staging_file "$id" "$CLAIM_TOKEN.rcpt")
  [ ! -e "$RECEIPT_OUTCOME" ] && [ ! -L "$RECEIPT_OUTCOME" ] \
    && [ ! -e "$RECEIPT_OUTCOME.gen" ] && [ ! -L "$RECEIPT_OUTCOME.gen" ] \
    || { fm_procevent_source_lock_release "$id"; die "cannot safely stage the receipt outcome"; }
  (umask 077; : > "$RECEIPT_OUTCOME") || { fm_procevent_source_lock_release "$id"; die "cannot stage the receipt outcome"; }
  # The generation note beside the outcome names the one source and sequence
  # that outcome speaks for. A runner killed after the intake returned but
  # before the seam ran leaves both behind, and this is what lets recovery read
  # that verdict as this round's, never as another round's or another source's
  # (see recover_receipt_seams). Staged under the hold, it is also the
  # publication marker the unlocked feed below relies on.
  (umask 077; printf '%s\t%s\n' "$id" "$durable_seq" > "$RECEIPT_OUTCOME.gen") \
    || { fm_procevent_source_lock_release "$id"; die "cannot stage the receipt outcome"; }
  fm_procevent_source_lock_release "$id"
  if [ "$extension_owner" -eq 0 ] \
    && feed_keyed_answers "$adapter" "$id" "$durable" "$RECEIPT_OUTCOME"; then
    printf 'answers-fed: %s\n' "$id"
  fi
  # The seam runs under a fresh acquisition: the feed above ran unlocked, and
  # everything after this point - seam, its handled generations, the seam-ran
  # marker - is again ordered against every concurrent reconcile exactly as
  # when the hold spanned the whole capture.
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  FM_PROCEVENT_RUNNER_SOURCE_LOCK_HELD=1 \
    adapter_receipt "$adapter" "$id" "$durable_seq" \
      "$durable" "$RECEIPT_OUTCOME" || true
  # Still under the same hold: the seam has had its one chance at this
  # generation, whatever it did with it. Recording that is what lets reconcile
  # tell a generation captured by a runner that died before the seam from one
  # the seam already saw (see recover_receipt_seams).
  fm_procevent_mark_receipt_seam "$STATE" "$id" "$durable_seq" >/dev/null 2>&1 || true
  fm_procevent_source_lock_release "$id"
  rm -f -- "$RECEIPT_OUTCOME" "$RECEIPT_OUTCOME.gen" "$RECEIPT_OUTCOME.body" \
    "$RECEIPT_OUTCOME.tmp"
  RECEIPT_OUTCOME=

  # A self-announcing adapter's autohandle announces through its own durable
  # downstream channel, so publication waits until after application and covers
  # only what remains unhandled; every other adapter keeps the strict
  # publish-before-apply order (announcement-ownership note in the header).
  if [ "$extension_owner" -eq 0 ] && adapter_self_announcing "$adapter"; then
    self_announcing=1
  else
    if publish_result "$durable"; then
      published_capture=1
    elif fm_procevent_is_handled "$STATE" "$id" "$(fm_procevent_result_sequence "$durable")"; then
      handled_capture=1
    fi
    publish_pending "$durable" >/dev/null
  fi
  [ "$extension_owner" -eq 1 ] || rm -f -- "$runner"
  if [ "$self_announcing" -eq 1 ]; then
    if adapter_autohandle "$adapter" "$id" "$durable"; then
      printf 'autohandled: %s\n' "$id"
    else
      printf 'not-autohandled: %s (left for the handler; still unacknowledged)\n' "$id" >&2
    fi
    # publish_result's own handled guard keeps a fully autohandled capture
    # quiet here; anything the adapter left unhandled is announced exactly as
    # before, and a crash above leaves it to reconcile's re-announcement.
    if publish_result "$durable"; then
      published_capture=1
    fi
    publish_pending "$durable" >/dev/null
  elif [ "$handled_capture" -eq 1 ]; then
    :
  elif [ "$extension_owner" -eq 0 ] \
    && [ "$published_capture" -eq 1 ] \
    && adapter_autohandle "$adapter" "$id" "$durable"; then
    printf 'autohandled: %s\n' "$id"
  else
    printf 'not-autohandled: %s (left for the handler; still unacknowledged)\n' "$id" >&2
  fi
  if adapter_result_is_terminal "$adapter" "$durable"; then
    if retire_owned_terminal_source "$id"; then
      printf 'retired: %s (adapter classified the captured result terminal)\n' "$id"
    else
      printf 'cannot retire terminal source; it remains registered: %s\n' "$id" >&2
    fi
  fi
  printf 'captured: %s\n' "$durable"
  if [ "$extension_owner" -eq 1 ]; then
    fm_procevent_claim_capture_reservation_remove_locked || true
    exec 6<&-
  fi
}

# Retire a source this runner owns because its adapter classified the captured
# result terminal. Ownership is re-proved, the registration is dropped, and this
# runner's own claim is released under ONE source-lock hold, so no concurrent
# reconcile can observe a registered source with no owner (and start a
# replacement) or an owned claim with no registration (and signal this runner
# mid-exit), and a generation this runner no longer owns is never unregistered.
# The EXIT trap's own release then no-ops, because the generation is already gone.
retire_owned_terminal_source() {  # <source-id>
  local id=$1 status=0 registration current_identity
  registration=$(source_file "$id")
  fm_procevent_source_lock_acquire "$id" || return 1
  if fm_procevent_claim_load_locked "$id" 2>/dev/null \
    && [ "$FM_PROCEVENT_CLAIM_HOME" = "$CLAIM_HOME" ] \
    && [ "$FM_PROCEVENT_CLAIM_PID" = "$CLAIM_PID" ] \
    && [ "$FM_PROCEVENT_CLAIM_TOKEN" = "$CLAIM_TOKEN" ] \
    && [ "$FM_PROCEVENT_CLAIM_REG_IDENTITY" = "$CLAIM_REG_IDENTITY" ] \
    && current_identity=$(fm_pr_file_identity "$registration" 2>/dev/null) \
    && [ "$current_identity" = "$CLAIM_REG_IDENTITY" ] \
    && fm_procevent_claim_mark_terminal_locked "$id" "$CLAIM_HOME" "$CLAIM_PID" "$CLAIM_TOKEN"; then
    if rm -f -- "$registration" && [ ! -e "$registration" ] && [ ! -L "$registration" ]; then
      fm_procevent_claim_release_locked "$id" "$CLAIM_HOME" "$CLAIM_PID" "$CLAIM_TOKEN" || status=1
    else
      status=1
    fi
  else
    status=1
  fi
  fm_procevent_source_lock_release "$id"
  return "$status"
}

# Start a runner outside the watcher cycle that noticed it was missing. The
# public start boundary establishes its own process group before claiming.
detach_runner() {  # <source-id>
  isolate_runner detach "$1"
}

# What a dead generation's own keyed-answer intake actually returned, when its
# runner got far enough to write it down. A staged outcome is claimed by nothing
# but the generation note beside it, which names the exact source and sequence
# the outcome speaks for, so a recovered seam can only ever read the verdict of
# the round it is recovering; the staging file names themselves are never
# matched, because a source id may itself contain the separator. One generation
# is staged by exactly one runner, so two notes can never name it - and if two
# somehow do, nothing here is proven and none is used. Only ever called while
# holding the source's lock, where no live runner can be staging one.
staged_receipt_outcome() {  # <source-id> <sequence>
  local gen f want found=''
  want=$(printf '%s\t%s' "$1" "$2")
  for gen in "$REG"/.*.rcpt.output.gen; do
    [ -f "$gen" ] && [ ! -L "$gen" ] || continue
    [ "$(sed -n '1p' "$gen" 2>/dev/null)" = "$want" ] || continue
    f=${gen%.gen}
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ -z "$found" ] || return 1
    found=$f
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# Give the receipt seam the one chance a dead runner owed it. A runner killed
# after its durable capture but before the seam ran leaves a captured generation
# its adapter never saw: reconcile republishes that capture, so without this the
# handler would be woken for a submission whose acknowledgement lifecycle
# silently skipped a round, and a later terminal capture could retire the source
# before that round was ever acknowledged. Recovery reruns the same seam the
# same way - under the same per-source hold, taken in the same order, before
# publication - over whatever the dead generation can still prove: its own
# staged intake outcome when the runner died after that intake returned, and an
# empty outcome when it died before, because the durable capture is a fact this
# can always prove and a verdict nobody recorded is not. The intake is never
# re-fed here, so nothing can be applied twice. A generation whose seam already
# ran is left alone, re-checked under the hold so a live runner mid-seam is
# never doubled. A retired source is still recovered from what its dead runner
# actually recorded: a staged verdict is an obligation that outlived the poll,
# and it is that verdict - never the presence of a receipts record, which does
# not exist until some round journals one - that says the obligation is live.
# It runs before this cycle publishes anything or starts any replacement
# runner, so the seam still speaks for the poll that produced the capture,
# never for one a replacement has since armed. A replacement already running
# does not hold it back either: a live claim owns only the generation it staged
# under its own token, so an older generation's owed verdict is recovered while
# that replacement polls rather than waiting on a poll that may never end.
recover_receipt_seams() {
  local result id adapter seq outcome staged claim_state live_token registered
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    id=$(fm_procevent_result_source_id "$result")
    fm_procevent_source_id_valid "$id" || continue
    seq=$(fm_procevent_result_sequence "$result")
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    fm_procevent_receipt_seam_ran "$STATE" "$id" "$seq" && continue
    adapter=$(fm_procevent_result_adapter "$result" 2>/dev/null || true)
    [ -n "$adapter" ] || continue
    fm_procevent_source_lock_acquire "$id" || continue
    # Read under the hold, like every other fact this decides on: retirement
    # runs under the same lock, so a check taken outside it could describe a
    # source that has since been retired or re-registered.
    registered=0
    if [ -f "$(source_file "$id")" ] && [ ! -L "$(source_file "$id")" ]; then
      registered=1
    fi
    if ! fm_procevent_receipt_seam_ran "$STATE" "$id" "$seq"; then
      # A generation whose runner can still reach its own seam owns it: that
      # runner runs it between its capture and its publication, and recovery
      # stepping in now would present a half-kept verdict. The claim is the
      # liveness fact, and a claim whose LEADER is gone is always recoverable
      # here: a gone claim (1), and equally the crash cut (3), where the leader
      # is dead and only its owned group survives. That leader can never run
      # its seam, and the reap that stops its group drops the whole staging
      # set, so deferring 3 would destroy the verdict it had already recorded.
      # The seam-ran re-check above stays, so a runner that completed its seam
      # while this reconcile waited on the lock is still respected.
      fm_procevent_claim_state_locked "$id"
      claim_state=$?
      live_token=
      case "$claim_state" in 0|4) live_token=$FM_PROCEVENT_CLAIM_TOKEN ;; esac
      # The dead generation's own outcome belongs to that claim's staging set
      # and is dropped with the rest of it when the claim is reaped. A set the
      # live claim no longer names - a runner that released its own claim on
      # the way out, or a generation a reclaim has already replaced - has no
      # reaper left, so once the seam it owed has spoken this drops that set
      # itself rather than leaking a private verdict nothing will ever clean.
      # It is also what says whether a live claim owns this generation at all:
      # a runner stages its verdict under its OWN claim token, so a verdict
      # named for another token is one no live runner can ever consume.
      outcome=$(staged_receipt_outcome "$id" "$seq") || outcome=
      case "$claim_state" in
        1|3) ;;
        0|4)
          # A held or terminal-marked claim is left to its runner only for the
          # generation that runner itself staged. A replacement that reclaimed
          # a dead claim inherits the source, never the older generation's
          # owed seam: deferring to it would leave that round unacknowledged
          # and its capture undeliverable for as long as the replacement polls,
          # which a managed poll can do indefinitely.
          if [ -z "$outcome" ] || [ -z "$live_token" ] \
            || [ "$outcome" = "$(staging_file "$id" "$live_token.rcpt")" ]; then
            fm_procevent_source_lock_release "$id"
            continue
          fi
          ;;
        # An unreadable claim (2) proves nothing about who owns what, so the
        # generation is left to its runner exactly as before.
        *) fm_procevent_source_lock_release "$id"; continue ;;
      esac
      staged=
      if [ "$registered" -eq 0 ]; then
        # A retired source has no poll left to prove anything new, so the only
        # thing recoverable here is the verdict its dead runner already staged.
        # That staged pair IS the obligation: a receipts record does not exist
        # until some round journals one, so its absence proves nothing, and the
        # seam creates it. An unconsumed verdict is never deleted here.
        if [ -z "$outcome" ]; then
          fm_procevent_source_lock_release "$id"
          continue
        fi
      elif [ -z "$outcome" ]; then
        staged=$(staging_file "$id" "reconcile.$$.rcpt")
        # A reconcile killed before its trailing removal leaves this exact name
        # behind, and no reaper knows it: the claim reap and the sweep key on a
        # claim token this name can never be. A later reconcile that reuses the
        # dead PID would otherwise refuse to stage, skip the seam entirely, and
        # strand the generation - so drop the leftover and its notes first.
        rm -f -- "$staged" "$staged.gen" "$staged.body" "$staged.tmp"
        if [ ! -e "$staged" ] && [ ! -L "$staged" ] && (umask 077; : > "$staged"); then
          outcome=$staged
        else
          staged=
        fi
      fi
      if [ -n "$outcome" ]; then
        FM_PROCEVENT_RUNNER_SOURCE_LOCK_HELD=1 \
          adapter_receipt "$adapter" "$id" "$seq" "$result" "$outcome" || true
        fm_procevent_mark_receipt_seam "$STATE" "$id" "$seq" >/dev/null 2>&1 || true
        if [ -z "$staged" ]; then
          live_token=
          if { [ -e "$(fm_procevent_claim_path "$id")" ] || [ -L "$(fm_procevent_claim_path "$id")" ]; } \
            && fm_procevent_claim_load_locked "$id" 2>/dev/null; then
            live_token=$FM_PROCEVENT_CLAIM_TOKEN
          fi
          if [ -z "$live_token" ] || [ "$outcome" != "$(staging_file "$id" "$live_token.rcpt")" ]; then
            rm -f -- "$outcome" "$outcome.gen" "$outcome.body" "$outcome.tmp"
          fi
        fi
      fi
      [ -z "$staged" ] || rm -f -- "$staged"
    fi
    fm_procevent_source_lock_release "$id"
  done < <(fm_procevent_pending "$STATE")
}

cmd_reconcile() {
  local rec id published started=0 stopped=0 uncertain=0 claim owner pid token identity claim_state stop_state
  recover_receipt_seams
  published=$(publish_pending)

  # Stop a runner this home owns whose source is no longer registered. Without
  # this, unregistering a source that never completes leaves its child blocked
  # forever with nothing left to reap it.
  for claim in "$(fm_procevent_claim_root)"/*.claim; do
    [ -e "$claim" ] || continue
    id=${claim##*/}; id=${id%.claim}
    fm_procevent_source_id_valid "$id" || continue
    fm_procevent_source_lock_acquire "$id" || continue
    if [ -f "$(source_file "$id")" ] && [ ! -L "$(source_file "$id")" ]; then
      fm_procevent_source_lock_release "$id"
      continue
    fi
    if ! fm_procevent_claim_load_locked "$id" 2>/dev/null; then
      uncertain=$((uncertain + 1))
      fm_procevent_source_lock_release "$id"
      continue
    fi
    owner=$FM_PROCEVENT_CLAIM_HOME
    pid=$FM_PROCEVENT_CLAIM_PID
    token=$FM_PROCEVENT_CLAIM_TOKEN
    identity=$FM_PROCEVENT_CLAIM_IDENTITY
    if ! fm_procevent_claim_owned_by_state "$STATE" "$FM_HOME"; then
      fm_procevent_source_lock_release "$id"
      continue
    fi
    stop_runner_pid "$pid" "$identity"
    stop_state=$?
    case "$stop_state" in
      0|1)
        if fm_procevent_claim_release_locked "$id" "$owner" "$pid" "$token" 2>/dev/null; then
          remove_staged_generation "$id" "$token"
          rm -f -- "$(runner_file "$id")"
          stopped=$((stopped + 1))
        else
          uncertain=$((uncertain + 1))
        fi
        ;;
      *) uncertain=$((uncertain + 1)) ;;
    esac
    fm_procevent_source_lock_release "$id"
  done

  if [ -d "$REG" ]; then
    for rec in "$REG"/*.source; do
      [ -e "$rec" ] || continue
      id=${rec##*/}; id=${id%.source}
      fm_procevent_source_id_valid "$id" || continue
      fm_procevent_source_lock_acquire "$id" || continue
      if [ -f "$(source_file "$id")" ] && [ ! -L "$(source_file "$id")" ]; then
        fm_procevent_claim_state_locked "$id"
        claim_state=$?
        if [ "$claim_state" -eq 1 ]; then
          if ! cleanup_extension_registration_invocations_locked "$id"; then
            uncertain=$((uncertain + 1))
            fm_procevent_source_lock_release "$id"
            continue
          fi
          fm_procevent_source_lock_release "$id"
          detach_runner "$id"
          started=$((started + 1))
          continue
        elif [ "$claim_state" -eq 4 ]; then
          owner=$FM_PROCEVENT_CLAIM_HOME
          pid=$FM_PROCEVENT_CLAIM_PID
          token=$FM_PROCEVENT_CLAIM_TOKEN
          if fm_procevent_claim_owned_by_state "$STATE" "$FM_HOME" \
            && rm -f -- "$(source_file "$id")" \
            && [ ! -e "$(source_file "$id")" ] \
            && [ ! -L "$(source_file "$id")" ] \
            && fm_procevent_claim_release_locked "$id" "$owner" "$pid" "$token" 2>/dev/null; then
            stopped=$((stopped + 1))
          else
            uncertain=$((uncertain + 1))
          fi
        elif [ "$claim_state" -eq 3 ]; then
          # The leader crashed but its owned group is still consuming the
          # source. Never start a replacement alongside it: stop that group and
          # release its generation first, and if either cannot be proved, keep
          # the claim and retry on a later cycle rather than adding a second
          # poller. Only the owning home may signal its own group.
          owner=$FM_PROCEVENT_CLAIM_HOME
          pid=$FM_PROCEVENT_CLAIM_PID
          token=$FM_PROCEVENT_CLAIM_TOKEN
          identity=$FM_PROCEVENT_CLAIM_IDENTITY
          stop_state=2
          if fm_procevent_claim_owned_by_state "$STATE" "$FM_HOME"; then
            stop_runner_pid "$pid" "$identity"
            stop_state=$?
          fi
          if [ "$stop_state" -eq 0 ] \
            && cleanup_extension_registration_invocations_locked "$id" \
            && fm_procevent_claim_release_locked "$id" "$owner" "$pid" "$token" 2>/dev/null; then
            remove_staged_generation "$id" "$token"
            rm -f -- "$(runner_file "$id")"
            fm_procevent_source_lock_release "$id"
            detach_runner "$id"
            started=$((started + 1))
            continue
          fi
          uncertain=$((uncertain + 1))
        elif [ "$claim_state" -eq 2 ]; then
          uncertain=$((uncertain + 1))
        fi
      fi
      fm_procevent_source_lock_release "$id"
    done
  fi
  printf 'reconciled: published=%s started=%s stopped=%s uncertain=%s\n' "$published" "$started" "$stopped" "$uncertain"
}

# Stop a runner and the child it is blocked on. A runner started by reconcile is
# its own process group leader, so the group signal is what actually reaches the
# blocking child - signalling only the runner would leave that child alive and
# reparented, which is exactly how a source that never completes leaks.
stop_runner_pid() {  # <pid> <identity>
  local pid=${1-} identity=${2-} state pgid i=0
  case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  [ -n "$identity" ] || return 2
  fm_procevent_pid_state "$pid" "$identity"
  state=$?
  case "$state" in
    0)
      # A live identity-matched leader still owns its group, so prove the group
      # really is the one this pid leads before signalling it.
      pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 2
      [ "$pgid" = "$pid" ] || return 2
      ;;
    3)
      # The leader crashed but its owned group is still running. Its pgid cannot
      # be read from the dead leader, and it does not need to be: only an absent
      # leader reaches this state, so the group cannot belong to a reused pid.
      ;;
    *) return "$state" ;;
  esac
  kill -TERM -"$pid" 2>/dev/null || return 2
  while [ "$i" -lt 20 ]; do
    kill -0 -"$pid" 2>/dev/null || return 0
    if kill -0 "$pid" 2>/dev/null; then
      fm_procevent_pid_state "$pid" "$identity"
      state=$?
      [ "$state" -eq 2 ] && return 2
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL -"$pid" 2>/dev/null || return 2
  i=0
  while [ "$i" -lt 20 ]; do
    kill -0 -"$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 2
}

# The owned handling interface: durably and idempotently record that a
# captured result has been fully handled, keyed by the exact source id and
# sequence generation. Serialized under the same per-source boundary as every
# other mutation here, on top of the marker's own atomic O_EXCL create, so a
# caller can trust the reported first-time/repeat distinction to authorize a
# paired external effect at most once.
cmd_classify() {
  local result=${1-} adapter script owner_state
  [ "$#" -eq 1 ] || usage
  adapter=$(fm_procevent_result_adapter "$result" 2>/dev/null) \
    || die "captured result has no readable adapter identity: $result"
  fm_procevent_result_extension_load "$result"
  owner_state=$?
  case "$owner_state" in
    0) extension_result_command "$adapter" result.classify "$result"; return $? ;;
    2) die "captured extension result has an unreadable owner identity: $result" ;;
  esac
  script=$(adapter_script "$adapter")
  [ -f "$script" ] && [ ! -L "$script" ] \
    || die "captured result adapter is unavailable: $adapter"
  "$script" classify "$result"
}

cmd_handled() {
  local id=${1-} seq=${2-} status
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer: $seq" ;; esac
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  fm_procevent_mark_handled "$STATE" "$id" "$seq"
  status=$?
  fm_procevent_source_lock_release "$id"
  case "$status" in
    0) printf 'handled: %s %s\n' "$id" "$seq" ;;
    1) printf 'already-handled: %s %s\n' "$id" "$seq" ;;
    *) die "cannot durably record handling: $id $seq" ;;
  esac
}

cmd_retire() {
  local id=${1-} condition=${2-} adapter='' sep='' expected_owner='' owner='' pid='' token='' identity='' stop_state owner_state
  local extension_binding_digest='' receipts_lock_taken=1 receipts_wait=0
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  case "$condition" in
    '') [ "$#" -eq 1 ] || usage ;;
    --if-absent) [ "$#" -eq 2 ] || usage ;;
    --if-owner)
      [ "$#" -eq 3 ] || usage
      expected_owner=${3-}
      fm_procevent_extension_registration_token_valid "$expected_owner" \
        || die "extension registration owner token is invalid"
      ;;
    --if-matches)
      adapter=${3-}
      sep=${4-}
      shift 4 2>/dev/null || usage
      fm_procevent_adapter_valid "$adapter" \
        || die "adapter name must be lowercase alphanumeric or dash: $adapter"
      [ "$sep" = -- ] && [ "$#" -ge 1 ] || usage
      ;;
    *) usage ;;
  esac
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  if [ -e "$(source_file "$id")" ] || [ -L "$(source_file "$id")" ]; then
    if [ -z "$condition" ]; then
      fm_procevent_extension_registration_load_locked "$STATE" "$id"
      owner_state=$?
      case "$owner_state" in
        0)
          fm_procevent_source_lock_release "$id"
          die "extension registration requires its exact --if-owner token: $id"
          ;;
        2)
          fm_procevent_source_lock_release "$id"
          die "cannot safely read extension registration ownership: $id"
          ;;
      esac
    fi
    case "$condition" in
      --if-absent)
        fm_procevent_source_lock_release "$id"
        die "source registration does not match the expected owner: $id"
        ;;
      --if-matches)
        if ! fm_procevent_registration_matches_locked "$STATE" "$adapter" "$id" "$@"; then
          fm_procevent_source_lock_release "$id"
          die "source registration does not match the expected owner: $id"
        fi
        ;;
      --if-owner)
        fm_procevent_extension_registration_load_locked "$STATE" "$id"
        owner_state=$?
        if [ "$owner_state" -ne 0 ] \
          || [ "$FM_PROCEVENT_EXTENSION_REGISTRATION_TOKEN" != "$expected_owner" ]; then
          fm_procevent_source_lock_release "$id"
          die "source registration does not match the expected owner: $id"
        fi
        extension_binding_digest=$FM_PROCEVENT_EXTENSION_BINDING_DIGEST
        ;;
    esac
  elif [ "$condition" = --if-owner ] \
    && { [ -e "$(fm_procevent_claim_path "$id")" ] || [ -L "$(fm_procevent_claim_path "$id")" ]; }; then
    fm_procevent_source_lock_release "$id"
    die "source owner cannot be proved after its registration disappeared: $id"
  fi
  if [ -e "$(fm_procevent_claim_path "$id")" ]; then
    if ! fm_procevent_claim_load_locked "$id" 2>/dev/null; then
      fm_procevent_source_lock_release "$id"
      die "cannot safely read source ownership: $id"
    fi
    if fm_procevent_claim_owned_by_state "$STATE" "$FM_HOME"; then
      owner=$FM_PROCEVENT_CLAIM_HOME
      pid=$FM_PROCEVENT_CLAIM_PID
      token=$FM_PROCEVENT_CLAIM_TOKEN
      identity=$FM_PROCEVENT_CLAIM_IDENTITY
      stop_runner_pid "$pid" "$identity"
      stop_state=$?
      if [ "$stop_state" -eq 2 ]; then
        fm_procevent_source_lock_release "$id"
        die "cannot confirm runner identity; source remains registered: $id"
      fi
      if [ -n "$extension_binding_digest" ] \
        && ! cleanup_extension_binding_invocations "$extension_binding_digest"; then
        fm_procevent_source_lock_release "$id"
        die "cannot prove external adapter cleanup; source remains registered: $id"
      fi
      if ! fm_procevent_claim_release_locked "$id" "$owner" "$pid" "$token"; then
        fm_procevent_source_lock_release "$id"
        die "cannot release source ownership: $id"
      fi
      remove_staged_generation "$id" "$token"
    fi
  elif [ -n "$extension_binding_digest" ] \
    && ! cleanup_extension_binding_invocations "$extension_binding_digest"; then
    fm_procevent_source_lock_release "$id"
    die "cannot prove external adapter cleanup; source remains registered: $id"
  fi
  rm -f -- "$(source_file "$id")"
  rm -f -- "$(runner_file "$id")"
  # The receipts record is part of this runner's per-source layout (its bytes
  # belong to the source's adapter), so it is cleaned with the registration.
  # The removal takes the adapter's receipts lock so a writer already holding
  # it cannot append the record back into existence after the unlink. The wait
  # is BOUNDED: the adapter's own receipt seam takes the receipts lock before
  # the source lock, so waiting unboundedly here, under the source lock, would
  # be a lock-order inversion that could never resolve. A seam holds that lock
  # only for the length of one journal append, so a short retry covers every
  # ordinary contention while still failing rather than hanging.
  if [ -e "$(fm_procevent_receipts_path "$STATE" "$id")" ] \
    || [ -L "$(fm_procevent_receipts_path "$STATE" "$id")" ]; then
    receipts_lock_taken=0
    while [ "$receipts_wait" -lt "$RECEIPTS_RETIRE_LOCK_TRIES" ]; do
      if fm_lock_try_acquire "$(fm_procevent_receipts_lock_path "$STATE" "$id")"; then
        receipts_lock_taken=1
        break
      fi
      receipts_wait=$((receipts_wait + 1))
      sleep 0.1
    done
    if [ "$receipts_lock_taken" -eq 1 ]; then
      rm -f -- "$(fm_procevent_receipts_path "$STATE" "$id")"
      fm_lock_release "$(fm_procevent_receipts_lock_path "$STATE" "$id")"
    fi
  fi
  fm_procevent_source_lock_release "$id"
  # A retired source produces no further answer, so drop any decision binding it
  # carried. Generic and idempotent: the binding owner is asked to forget this
  # source id, and an unbound source is unaffected.
  "$SCRIPT_DIR/fm-captain-hold.sh" unbind "$id" >/dev/null 2>&1 || true
  # The registration and the binding are gone either way, so the source really
  # is retired; a record this call could not lock is reported rather than
  # covered by a clean retirement line, and a later sweep reclaims it.
  [ "$receipts_lock_taken" -ne 0 ] \
    || die "retired the source but could not lock its receipts record: $id"
  printf 'retired: %s\n' "$id"
}

sweep_add_id() {
  local id=$1
  case "$SWEEP_IDS" in
    *$'\n'"$id"$'\n'*) ;;
    *) SWEEP_IDS+="$id"$'\n' ;;
  esac
}

sweep_relevant_state() {
  local path owner
  for path in "$STATE/extension-invocations"/*.owner.json; do
    [ -e "$path" ] && return 0
  done
  for path in "$REG"/*.source "$REG"/*.runner "$REG"/*.receipts; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      return 0
    fi
  done
  for path in "$(fm_procevent_claim_root)"/*.claim; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    owner=${path##*/}; owner=${owner%.claim}
    fm_procevent_source_id_valid "$owner" || return 0
    fm_procevent_source_lock_acquire "$owner" || return 0
    if ! fm_procevent_claim_load_locked "$owner" 2>/dev/null; then
      fm_procevent_source_lock_release "$owner"
      return 0
    fi
    if fm_procevent_claim_owned_by_state "$STATE" "$FM_HOME"; then
      fm_procevent_source_lock_release "$owner"
      return 0
    fi
    fm_procevent_source_lock_release "$owner"
  done
  return 1
}

sweep_source_preflight() {
  local id=$1 state
  fm_procevent_source_lock_acquire "$id" || return 1
  if [ -e "$(fm_procevent_claim_path "$id")" ] || [ -L "$(fm_procevent_claim_path "$id")" ]; then
    if ! fm_procevent_claim_load_locked "$id" 2>/dev/null; then
      fm_procevent_source_lock_release "$id"
      return 1
    fi
    if fm_procevent_claim_owned_by_state "$STATE" "$FM_HOME"; then
      fm_procevent_pid_state "$FM_PROCEVENT_CLAIM_PID" "$FM_PROCEVENT_CLAIM_IDENTITY"
      state=$?
      if [ "$state" -eq 2 ]; then
        fm_procevent_source_lock_release "$id"
        return 1
      fi
    fi
  fi
  fm_procevent_source_lock_release "$id"
}

sweep_retire_source() {  # <source-id>
  local id=$1 owner_state expected_owner=''
  if [ -e "$(source_file "$id")" ] || [ -L "$(source_file "$id")" ]; then
    fm_procevent_source_lock_acquire "$id" || return 1
    fm_procevent_extension_registration_load_locked "$STATE" "$id"
    owner_state=$?
    case "$owner_state" in
      0) expected_owner=$FM_PROCEVENT_EXTENSION_REGISTRATION_TOKEN ;;
      1) ;;
      *) fm_procevent_source_lock_release "$id"; return 1 ;;
    esac
    fm_procevent_source_lock_release "$id"
  fi
  if [ -n "$expected_owner" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-procevent.sh" retire "$id" --if-owner "$expected_owner"
  else
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
  fi
}

cmd_sweep_home() {
  local preflight_only=${1-} path id owner attempted=0 failed=0
  [ -z "$preflight_only" ] || [ "$preflight_only" = --preflight ] || usage
  SWEEP_IDS=$'\n'
  for path in "$REG"/*.source; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      id=${path##*/}; id=${id%.source}
      if fm_procevent_source_id_valid "$id"; then
        sweep_add_id "$id"
      else
        failed=$((failed + 1))
      fi
    fi
  done
  for path in "$(fm_procevent_claim_root)"/*.claim; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    id=${path##*/}; id=${id%.claim}
    if ! fm_procevent_source_id_valid "$id"; then
      failed=$((failed + 1))
      continue
    fi
    if ! fm_procevent_source_lock_acquire "$id"; then
      failed=$((failed + 1))
      continue
    fi
    if ! fm_procevent_claim_load_locked "$id" 2>/dev/null; then
      failed=$((failed + 1))
      fm_procevent_source_lock_release "$id"
      continue
    fi
    if fm_procevent_claim_owned_by_state "$STATE" "$FM_HOME"; then
      sweep_add_id "$id"
    fi
    fm_procevent_source_lock_release "$id"
  done
  # A receipts record deliberately outlives the automatic retirement of its own
  # source, so the last round of an ended review can still state Applying and
  # Complete durably. This home's teardown is where that record is retired: it
  # is the only enumeration that still sees a source with no registration and no
  # claim, and retiring the id removes the record whether or not either remains.
  for path in "$REG"/*.receipts; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      id=${path##*/}; id=${id%.receipts}
      if fm_procevent_source_id_valid "$id"; then
        sweep_add_id "$id"
      else
        failed=$((failed + 1))
      fi
    fi
  done
  for path in "$REG"/*.runner; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      id=${path##*/}; id=${id%.runner}
      if ! fm_procevent_source_id_valid "$id"; then
        failed=$((failed + 1))
      else
        case "$SWEEP_IDS" in
          *$'\n'"$id"$'\n'*) ;;
          *) failed=$((failed + 1)) ;;
        esac
      fi
    fi
  done
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    sweep_source_preflight "$id" || failed=$((failed + 1))
  done <<< "$SWEEP_IDS"
  if [ "$failed" -ne 0 ]; then
    printf 'error: process-event home sweep preflight failed: attempted=0 failed=%s\n' "$failed" >&2
    return 1
  fi
  if [ "$preflight_only" = --preflight ]; then
    printf 'sweep preflight: ready\n'
    return 0
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    attempted=$((attempted + 1))
    if ! sweep_retire_source "$id"; then
      failed=$((failed + 1))
    fi
  done <<< "$SWEEP_IDS"
  if ! run_extension_invocation_cleanup; then
    failed=$((failed + 1))
  fi
  if [ "$failed" -ne 0 ] || sweep_relevant_state; then
    printf 'error: process-event home sweep incomplete: attempted=%s failed=%s\n' "$attempted" "$failed" >&2
    return 1
  fi
  printf 'swept: attempted=%s\n' "$attempted"
}

cmd_list() {
  local rec id adapter owner pending
  if ! fm_procevent_any_registered "$STATE"; then
    printf 'no sources registered\n'
    return 0
  fi
  printf '%-28s %-12s %-10s %s\n' SOURCE ADAPTER OWNER PENDING
  for rec in "$REG"/*.source; do
    [ -e "$rec" ] || continue
    id=${rec##*/}; id=${id%.source}
    adapter=$(read_adapter "$id" 2>/dev/null || echo '?')
    fm_procevent_source_lock_acquire "$id" || continue
    fm_procevent_claim_state_locked "$id"
    case "$?" in 0) owner=live ;; 1) owner=none ;; 3) owner=orphaned ;; *) owner=uncertain ;; esac
    fm_procevent_source_lock_release "$id"
    pending=$(fm_procevent_pending "$STATE" | grep -c "/$id\." || true)
    printf '%-28s %-12s %-10s %s\n' "$id" "$adapter" "$owner" "$pending"
  done
}

cmd_binding_retirement_preflight() {
  local digest=${1-} rec id owner_state result
  if [ "$#" -ne 1 ] || ! fm_procevent_digest_valid "$digest"; then
    die "binding-retirement-preflight requires one binding digest"
  fi
  for rec in "$REG"/*.source; do
    [ -e "$rec" ] || continue
    [ -f "$rec" ] && [ ! -L "$rec" ] || die "binding retirement found unsafe registration state"
    id=${rec##*/}; id=${id%.source}
    fm_procevent_source_id_valid "$id" || die "binding retirement found malformed registration state"
    fm_lock_try_acquire "$(fm_procevent_source_lock_path "$id")" \
      || die "binding still owns process-event registration: $id"
    fm_procevent_extension_registration_load_locked "$STATE" "$id"
    owner_state=$?
    fm_lock_release "$(fm_procevent_source_lock_path "$id")"
    case "$owner_state" in
      0) [ "$FM_PROCEVENT_EXTENSION_BINDING_DIGEST" != "$digest" ] \
        || die "binding still owns process-event registration: $id" ;;
      1) ;;
      *) die "binding retirement found malformed extension registration: $id" ;;
    esac
  done
  for result in "$(fm_procevent_inbox_dir "$STATE")"/*.result; do
    [ -e "$result" ] || continue
    if [ -e "${result%.result}.handled" ] || [ -L "${result%.result}.handled" ]; then
      [ -f "${result%.result}.handled" ] && [ ! -L "${result%.result}.handled" ] \
        || die "binding retirement found unsafe handled-result state: ${result##*/}"
      continue
    fi
    fm_procevent_result_extension_load "$result"
    owner_state=$?
    case "$owner_state" in
      0) [ "$FM_PROCEVENT_RESULT_EXTENSION_BINDING_DIGEST" != "$digest" ] \
        || die "binding still owns unhandled process-event result: ${result##*/}" ;;
      1) ;;
      *) die "binding retirement found malformed extension result: ${result##*/}" ;;
    esac
  done
  printf 'binding retirement preflight: ready\n'
}

cmd_extension_retirement() {
  local mode=${1-} owner
  [ "$#" -ge 1 ] || die "extension-retirement requires a retirement mode"
  shift
  case "$mode" in binding|transfer) ;; *) die "unsupported extension retirement mode: $mode" ;; esac
  extension_lifecycle_lock_acquire || die "cannot lock the extension lifecycle"
  owner=${FM_LOCK_OWNER_DIR:-}
  [ -n "$owner" ] || die "extension lifecycle lock has no owner identity"
  export FM_EXTENSION_RETIREMENT_MODE="$mode"
  export FM_EXTENSION_LIFECYCLE_LOCK="$EXTENSION_LIFECYCLE_LOCK"
  export FM_EXTENSION_LIFECYCLE_OWNER="$owner"
  exec "$EXTENSION_HOST" "$@"
}

cmd_extension_bind() {
  local binding_command=${1-} owner
  case "$binding_command" in bind|receive-transfer-bind) ;; *) die "unsupported extension binding command: $binding_command" ;; esac
  extension_lifecycle_lock_acquire || die "cannot lock the extension lifecycle"
  owner=${FM_LOCK_OWNER_DIR:-}
  [ -n "$owner" ] || die "extension lifecycle lock has no owner identity"
  export FM_EXTENSION_RETIREMENT_MODE=bind
  export FM_EXTENSION_LIFECYCLE_LOCK="$EXTENSION_LIFECYCLE_LOCK"
  export FM_EXTENSION_LIFECYCLE_OWNER="$owner"
  exec "$EXTENSION_HOST" "$@"
}

cmd_extension_process_event() {
  local owner arg
  [ "$#" -ge 2 ] || die "extension-process-event requires process-event arguments"
  for arg in "$@"; do
    [ "$arg" != --capture-reservation ] || die "capture reservation is internal"
  done
  extension_lifecycle_lock_acquire || die "cannot lock the extension lifecycle"
  owner=${FM_LOCK_OWNER_DIR:-}
  [ -n "$owner" ] || die "extension lifecycle lock has no owner identity"
  export FM_EXTENSION_RETIREMENT_MODE=process-event
  export FM_EXTENSION_LIFECYCLE_LOCK="$EXTENSION_LIFECYCLE_LOCK"
  export FM_EXTENSION_LIFECYCLE_OWNER="$owner"
  # These descriptors are reserved for the direct, internal capture handoff.
  # The public lifecycle path must not let unrelated descriptors acquired while
  # obtaining its lock look like a malformed handoff to the host.
  { exec 6<&-; } 2>/dev/null || true
  { exec 7<&-; } 2>/dev/null || true
  { exec 8<&-; } 2>/dev/null || true
  { exec 9<&-; } 2>/dev/null || true
  exec "$EXTENSION_HOST" process-event "$@"
}

unset FM_PROCEVENT_CAPTURE_PINNED_INBOX FM_PROCEVENT_CAPTURE_ABSOLUTE_INBOX \
  FM_PROCEVENT_CAPTURE_RESERVATION_TERMINAL \
  FM_PROCEVENT_CAPTURE_RESERVATION_SILENT
{ exec 7<&-; } 2>/dev/null || true
{ exec 6<&-; } 2>/dev/null || true
{ exec 8<&-; } 2>/dev/null || true
{ exec 9<&-; } 2>/dev/null || true

case "${1-}" in
  register)           shift; cmd_register "$@" ;;
  register-extension) shift; cmd_register_extension "$@" ;;
  start)              shift; cmd_start_public "$@" ;;
  _start)             shift; cmd_start "$@" ;;
  reconcile)          shift; cmd_reconcile "$@" ;;
  classify)           shift; cmd_classify "$@" ;;
  handled)            shift; cmd_handled "$@" ;;
  retire)             shift; cmd_retire "$@" ;;
  sweep-home)         shift; cmd_sweep_home "$@" ;;
  binding-retirement-preflight) shift; cmd_binding_retirement_preflight "$@" ;;
  extension-retirement) shift; cmd_extension_retirement "$@" ;;
  extension-bind) shift; cmd_extension_bind "$@" ;;
  extension-process-event) shift; cmd_extension_process_event "$@" ;;
  list)               shift; cmd_list "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
