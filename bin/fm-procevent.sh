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

REG=$(fm_procevent_registry_dir "$STATE")
MAX_OUTPUT_BYTES=${FM_PROCEVENT_MAX_OUTPUT_BYTES:-1048576}
EXTENSION_HOST="$SCRIPT_DIR/fm-extension.mjs"
EXTENSION_LIFECYCLE_LOCK="$REG/.extension-binding-lifecycle.lock"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

adapter_script() { printf '%s/bin/fm-procevent-%s.sh\n' "$FM_ROOT" "$1"; }

extension_lifecycle_lock_acquire() {
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
feed_keyed_answers() {  # <adapter> <source-id> <result-file>
  local adapter=$1 id=$2 result=$3 script origin seq
  script=$(adapter_script "$adapter")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  origin=$("$SCRIPT_DIR/fm-captain-hold.sh" binding "$id" 2>/dev/null) || return 1
  [ -n "$origin" ] || return 1
  seq=$(fm_procevent_result_sequence "$result") || return 1
  "$script" answers "$result" 2>/dev/null \
    | "$SCRIPT_DIR/fm-captain-hold.sh" answers "$origin" \
        --source "the captured result $id sequence $seq" >/dev/null 2>&1
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
  fm_procevent_claim_acquire_locked "$id" "$FM_HOME" "$$" "$(source_file "$id")"
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
  release_start_claim() {
    extension_lifecycle_lock_release 2>/dev/null || true
    [ -z "$STAGED_OUTPUT" ] || rm -f -- "$STAGED_OUTPUT"
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
  local runner inbox reservation_dir
  if [ "$extension_owner" -eq 1 ]; then
    fm_procevent_extension_staging_prepare "$STATE" \
      || die "cannot safely prepare the external registry staging boundary"
    inbox=$(fm_procevent_capture_inbox_prepare "$STATE") \
      || die "cannot durably capture the extension result"
    CDPATH='' cd -- "$REG" 2>/dev/null \
      || die "cannot safely prepare the external registry staging boundary"
    [ "$(pwd -P)" = "$REG" ] \
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
    "${ARGV[@]}" 2>/dev/null | perl -e '
      use strict;
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
      exit($truncated ? 3 : 0);
    ' "$MAX_OUTPUT_BYTES" > "$out"
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

  if [ "$extension_owner" -eq 1 ]; then
    durable="./$durable"
  fi

  if [ "$extension_owner" -eq 1 ]; then
    :
  else
    durable=$(fm_procevent_capture "$STATE" "$id" "$adapter" "$out") \
      || { rm -f -- "$out"; die "cannot durably capture the result"; }
  fi
  [ "$extension_owner" -eq 1 ] || rm -f -- "$out"
  STAGED_OUTPUT=
  [ "$truncated" -eq 1 ] && printf 'truncated: %s at %s bytes\n' "$id" "$MAX_OUTPUT_BYTES" >&2

  # Independent of publication and acknowledgement, so it runs once per capture
  # for every adapter and cannot change what the handler receives.
  if [ "$extension_owner" -eq 0 ] \
    && feed_keyed_answers "$adapter" "$id" "$durable"; then
    printf 'answers-fed: %s\n' "$id"
  fi

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

cmd_reconcile() {
  local rec id published started=0 stopped=0 uncertain=0 claim owner pid token identity claim_state stop_state
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
    if [ "$owner" != "$FM_HOME" ]; then
      fm_procevent_source_lock_release "$id"
      continue
    fi
    stop_runner_pid "$pid" "$identity"
    stop_state=$?
    case "$stop_state" in
      0|1)
        if fm_procevent_claim_release_locked "$id" "$owner" "$pid" "$token" 2>/dev/null; then
          rm -f -- "$(staging_file "$id" "$token")"
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
          if [ "$owner" = "$FM_HOME" ] \
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
          if [ "$owner" = "$FM_HOME" ]; then
            stop_runner_pid "$pid" "$identity"
            stop_state=$?
          fi
          if [ "$stop_state" -eq 0 ] \
            && cleanup_extension_registration_invocations_locked "$id" \
            && fm_procevent_claim_release_locked "$id" "$owner" "$pid" "$token" 2>/dev/null; then
            rm -f -- "$(staging_file "$id" "$token")"
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
  local extension_binding_digest=''
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
    if [ "$FM_PROCEVENT_CLAIM_HOME" = "$FM_HOME" ]; then
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
      rm -f -- "$(staging_file "$id" "$token")"
    fi
  elif [ -n "$extension_binding_digest" ] \
    && ! cleanup_extension_binding_invocations "$extension_binding_digest"; then
    fm_procevent_source_lock_release "$id"
    die "cannot prove external adapter cleanup; source remains registered: $id"
  fi
  rm -f -- "$(source_file "$id")"
  rm -f -- "$(runner_file "$id")"
  fm_procevent_source_lock_release "$id"
  # A retired source produces no further answer, so drop any decision binding it
  # carried. Generic and idempotent: the binding owner is asked to forget this
  # source id, and an unbound source is unaffected.
  "$SCRIPT_DIR/fm-captain-hold.sh" unbind "$id" >/dev/null 2>&1 || true
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
  for path in "$REG"/*.source "$REG"/*.runner; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      return 0
    fi
  done
  for path in "$(fm_procevent_claim_root)"/*.claim; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    IFS= read -r owner < "$path" 2>/dev/null || continue
    [ "$owner" = "$FM_HOME" ] && return 0
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
    if [ "$FM_PROCEVENT_CLAIM_HOME" = "$FM_HOME" ]; then
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
    IFS= read -r owner < "$path" 2>/dev/null || continue
    [ "$owner" = "$FM_HOME" ] || continue
    id=${path##*/}; id=${id%.claim}
    if fm_procevent_source_id_valid "$id"; then
      sweep_add_id "$id"
    else
      failed=$((failed + 1))
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
