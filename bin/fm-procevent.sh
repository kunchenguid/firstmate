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
#            A start is REPORTED only once it is confirmed: starting a runner is
#            detached and its errors reach no caller, so a source that cannot
#            start would otherwise be counted exactly like one that is
#            listening, and a wedged source would go on presenting as armed.
#            Every launch is counted as `started` only after the source is
#            observed owned or its launch-pacing stamp has moved, `failed`
#            otherwise, and any failure also makes this command exit non-zero.
#            One bounded window covers a whole cycle's launches
#            (FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS; docs/configuration.md).
#            A launch that fails to confirm is also announced as a durable
#            `check` wake, once per failure episode - keyed by the registration
#            identity it ran under and ended by a later launch of that source
#            confirming - because the supervision cycle discards the `failed=`
#            count. The launch itself is retried every cycle exactly as before.
#            A source whose claim nothing may automatically displace is not
#            relaunched at all; it is counted `uncertain` and announced once per
#            stranded claim generation as a durable `check` wake, because the
#            supervision cycle discards this command's own output and exit
#            status. The wake names what clears that strand: the `start`
#            command for a reused pid whose group survives, or the check a
#            human makes for a group that lost its leader, which `start`
#            reports as owned and which the next cycle reclaims on its own
#            once that group is empty.
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
# Reconcile selections use the parallel `reconciles` adapter command and the
# binding-verified `reconcile-requests` intake, never the keyed-answer value.
# External binding responses never enter either authority-bearing intake.
#
# Feeding is deliberately independent of handling: it never acknowledges a result
# and never suppresses a wake. Recording the captain's answer is transcription,
# while ACTING on it is firstmate's judgement, so the capture stays unacknowledged
# and its `check` wake reaches the handler exactly as it would have anyway.
#
# A runner is bound to the HOME that owns it, not to the one session that armed
# it: a persistent source is meant to outlive that session, so reconcile stops a
# runner whose source is retired in a live home, and this lease is the backstop
# for a home that is GONE. Detaching a runner into its own
# process group is what lets a persistent source outlive the turn that armed it,
# and with nothing else it is also what lets a runner outlive its whole home:
# reparented to init, it keeps its blocking child - and everything that child
# spawns - running with nobody left to reap it. So every runner starts a small
# guard beside it, in its own separate process group, which re-reads the owning
# state root's lease on a bounded cadence and stops the runner's whole process
# group once that lease can no longer be proved fresh. Owner-presence operations
# refresh the lease, an attached public start keeps it fresh while its caller
# remains attached, and the watcher's reconcile cycle keeps it fresh in a live
# home. A runner exports the inherited FM_PROCEVENT_IN_RUNNER marker and every
# refresh is skipped under it, so a runner and its ordinary children do not
# certify their own owner. That rule is CONFUSED-AGENT-GRADE, the grade
# bin/fm-lease-lib.sh documents: a source that DELIBERATELY strips the marker
# can still refresh, and adversarial-grade unforgeability is out of scope (see
# docs/configuration.md). Scope is the owning state root and one runner
# generation, never a script or process name, so a live source in
# another home is untouched. See bin/fm-procevent-lib.sh for the lease itself.
#
# Ownership is machine-wide per canonical source, because separate Firstmate
# homes can share one underlying source store. A live owner is never displaced;
# only a claim whose stale owner and independently absent process group prove
# its whole generation gone is reclaimed. A crashed leader or reused pid whose
# process group still has members cannot relax ownership cleanup. Reconcile
# signals only a live identity-matched runner group and otherwise keeps the
# claim without starting a replacement.
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
stranded_file() { printf '%s/.%s.stranded\n' "$REG" "$1"; }
launch_failed_file() { printf '%s/.%s.launch-failed\n' "$REG" "$1"; }

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

feed_reconcile_requests() {  # <adapter> <source-id> <result-file>
  local adapter=$1 id=$2 result=$3 script origin seq rows
  script=$(adapter_script "$adapter")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  origin=$("$SCRIPT_DIR/fm-captain-hold.sh" binding "$id" 2>/dev/null) || return 1
  [ -n "$origin" ] || return 1
  seq=$(fm_procevent_result_sequence "$result") || return 1
  rows=$("$script" reconciles "$result" 2>/dev/null) || return 1
  printf '%s\n' "$rows" \
    | "$SCRIPT_DIR/fm-captain-hold.sh" reconcile-requests \
        --source-id "$id" --source "the captured result $id sequence $seq" >/dev/null 2>&1
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
  owner_lease_refresh
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
  owner_lease_refresh
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

# Start one command as the leader of a fresh process group, either waiting for
# it (the public `start` boundary) or detaching from it (reconcile's restart and
# the runner's own owner guard). The guard deliberately gets its OWN group
# rather than joining the runner's: it has to survive the group signal it sends,
# and a member of the runner's group would also make that group read as alive
# after the runner itself is gone.
isolate_process() {  # <wait|detach> <command> [argv...]
  local mode=$1 program
  shift
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
    perl -e "$program" "$mode" "$@"
    return $?
  fi
  perl -e "$program" "$mode" "$@" >/dev/null 2>&1 &
}

isolate_runner() {  # <wait|detach> <source-id>
  isolate_process "$1" "$SCRIPT_DIR/fm-procevent.sh" _start "$2"
}

require_isolated_group() {  # <role>
  local role=$1 pgid
  [ "${FM_PROCEVENT_RUNNER_GROUP:-}" = "$$" ] \
    || die "$role process group was not isolated"
  pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]') \
    || die "cannot inspect $role process group"
  [ -n "$pgid" ] || die "cannot inspect $role process group"
  [ "$pgid" = "$$" ] || die "$role does not lead its process group"
  unset FM_PROCEVENT_RUNNER_GROUP
}

require_runner_group() { require_isolated_group runner; }

# Record owner-presence activity for this home. Skipped under the inherited
# FM_PROCEVENT_IN_RUNNER marker, so a runner and its ordinary children do not
# keep refreshing their own lease after the home goes away.
# Confused-agent-grade: a source that deliberately unsets the marker can still
# refresh, and that is out of scope (see docs/configuration.md).
owner_lease_refresh() {
  [ "${FM_PROCEVENT_IN_RUNNER:-0}" = 1 ] && return 0
  fm_procevent_owner_lease_touch "$STATE" 2>/dev/null || true
}

owner_lease_keepalive() {  # <parent-pid> <parent-identity>
  local parent=$1 identity=$2 state
  while :; do
    sleep 1
    fm_procevent_pid_state "$parent" "$identity"
    state=$?
    case "$state" in
      0) owner_lease_refresh ;;
      2) ;;
      *) return 0 ;;
    esac
  done
}

cmd_start_public() {
  local id=${1-} identity keeper status
  [ "$#" -eq 1 ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  owner_lease_refresh
  identity=$(fm_pid_identity "$$" 2>/dev/null) || die "cannot identify the attached owner"
  owner_lease_keepalive "$$" "$identity" &
  keeper=$!
  isolate_runner wait "$id"
  status=$?
  kill "$keeper" 2>/dev/null || true
  wait "$keeper" 2>/dev/null || true
  return "$status"
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
  exec 7<"$(source_file "$id")" || {
    fm_procevent_source_lock_release "$id"
    die "cannot retain registration identity: $id"
  }
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
  CLAIM_STATE_DEVICE=$FM_PROCEVENT_CLAIM_STATE_DEVICE
  CLAIM_STATE_INODE=$FM_PROCEVENT_CLAIM_STATE_INODE
  STAGED_OUTPUT=
  # Exit cleanup must not wait for the source lock: retire and reconcile hold it
  # while waiting for this runner, so blocking here creates a circular wait
  # broken only by KILL. On contention, leave the generation-bound claim for
  # the stopper or subsequent reconciliation to reclaim.
  release_start_claim() {
    extension_lifecycle_lock_release 2>/dev/null || true
    [ -z "$STAGED_OUTPUT" ] || rm -f -- "$STAGED_OUTPUT"
    fm_procevent_source_lock_try_acquire "$CLAIM_ID" 2>/dev/null || return 0
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
  # The inherited marker keeps the runner and its ordinary children from
  # accidentally refreshing the owner lease. A source that deliberately strips
  # it is outside this confused-agent-grade boundary.
  export FM_PROCEVENT_IN_RUNNER=1
  start_owner_guard "$id" || die "cannot start the runner's owner guard: $id"
  local launch_floor runner inbox reservation_dir staging launch_ready launch_reply launch_pid
  launch_floor=$(fm_procevent_launch_floor_seconds) \
    || die "FM_PROCEVENT_LAUNCH_FLOOR_SECONDS must be whole seconds from $FM_PROCEVENT_LAUNCH_FLOOR_MIN_SECONDS to $FM_PROCEVENT_LAUNCH_FLOOR_MAX_SECONDS"
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
  fm_procevent_launch_floor_wait "$STATE" "$id" "$CLAIM_REG_IDENTITY" "$launch_floor"
  case "$?" in
    0) ;;
    # A superseded generation leaves nothing behind. The runner marker is
    # written before this wait, and a home sweep counts a marker with no owned
    # claim as a preflight failure, so exiting without removing it would make
    # that home refuse to sweep.
    2) [ "$extension_owner" -eq 1 ] || rm -f -- "$runner"; exit 0 ;;
    *) die "cannot enforce the source launch floor: $id" ;;
  esac
  exec 7<&-
  if [ "$extension_owner" -eq 1 ]; then
    launch_ready=".$id.$CLAIM_TOKEN.launch-ready"
    launch_reply="$REG/.$id.$CLAIM_TOKEN.launch-reply"
    (umask 077; : > "$REG/$launch_ready" && : > "$launch_reply") || {
      rm -f -- "$REG/$launch_ready" "$launch_reply"
      fm_procevent_source_lock_release "$id"
      die "cannot prepare the source launch boundary: $id"
    }
    perl "$SCRIPT_DIR/fm-procevent-extension-capture.pl" \
      9 8 6 "$id" "$adapter" "$FM_PROCEVENT_EXTENSION_ID" \
      "$FM_PROCEVENT_EXTENSION_VERSION" "$FM_PROCEVENT_EXTENSION_CAPABILITY_VERSION" \
      "$FM_PROCEVENT_EXTENSION_PACKAGE_DIGEST" "$FM_PROCEVENT_EXTENSION_BINDING_DIGEST" \
      "$CLAIM_TOKEN" "$runner" "$out" "$$" "$(fm_pid_identity "$$")" "$MAX_OUTPUT_BYTES" \
      "$launch_ready" -- "${ARGV[@]}" > "$launch_reply" &
    launch_pid=$!
    while [ ! -s "$REG/$launch_ready" ] && kill -0 "$launch_pid" 2>/dev/null; do sleep 0.01; done
    fm_procevent_source_lock_release "$id" \
      || die "cannot release the source launch boundary: $id"
    wait "$launch_pid" || {
      rm -f -- "$REG/$launch_ready" "$launch_reply"
      die "cannot safely stage the extension result"
    }
    [ -s "$REG/$launch_ready" ] || {
      rm -f -- "$REG/$launch_ready" "$launch_reply"
      die "cannot establish the source launch boundary: $id"
    }
    IFS= read -r capture_state < "$launch_reply" || capture_state=
    rm -f -- "$REG/$launch_ready" "$launch_reply"
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
    [ ! -e "$out" ] && [ ! -L "$out" ] || {
      fm_procevent_source_lock_release "$id"
      die "cannot safely stage output"
    }
    (umask 077; : > "$out") || {
      fm_procevent_source_lock_release "$id"
      die "cannot stage output"
    }
    STAGED_OUTPUT=$out
    launch_ready="$REG/.$id.$CLAIM_TOKEN.launch-pipe"
    mkfifo -m 600 "$launch_ready" || {
      fm_procevent_source_lock_release "$id"
      die "cannot prepare the source launch boundary: $id"
    }
    exec 5<> "$launch_ready" || {
      rm -f -- "$launch_ready"
      fm_procevent_source_lock_release "$id"
      die "cannot retain the source launch boundary: $id"
    }
    exec 4< "$launch_ready" || {
      exec 5>&-
      rm -f -- "$launch_ready"
      fm_procevent_source_lock_release "$id"
      die "cannot retain the source output boundary: $id"
    }
    "${ARGV[@]}" >&5 5>&- 4<&- 2>/dev/null &
    launch_pid=$!
    exec 5>&-
    rm -f -- "$launch_ready"
    fm_procevent_source_lock_release "$id" \
      || die "cannot release the source launch boundary: $id"
    perl -e '
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
    ' "$MAX_OUTPUT_BYTES" <&4 > "$out"
    bound_rc=$?
    exec 4<&-
    wait "$launch_pid"
    rc=$?
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
    && feed_reconcile_requests "$adapter" "$id" "$durable"; then
    printf 'reconciles-fed: %s\n' "$id"
  fi
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
      fm_procevent_claim_release_terminal_self_locked "$id" "$CLAIM_HOME" "$CLAIM_PID" "$CLAIM_TOKEN" || status=1
    else
      status=1
    fi
  else
    status=1
  fi
  fm_procevent_source_lock_release "$id"
  return "$status"
}

# Bind this runner's lifetime to the home that owns it. Started once the
# claim is held, so the guard names the exact generation it protects, and
# detached into its OWN process group so the group signal it may later send
# reaches the runner and every descendant without killing the guard first.
# If signalling cannot be proved safe or does not finish, the guard remains
# alive and retries on its normal check cadence rather than abandoning cleanup.
start_owner_guard() {  # <source-id>
  local identity ready value
  identity=$(fm_pid_identity "$$" 2>/dev/null) || return 1
  ready=$(umask 077; mktemp "$REG/.owner-guard-ready.XXXXXX") || return 1
  if ! isolate_process detach "$SCRIPT_DIR/fm-procevent.sh" _owner-watchdog \
      "$1" "$$" "$identity" "$ready" "$CLAIM_STATE_DEVICE" "$CLAIM_STATE_INODE"; then
    rm -f -- "$ready"
    return 1
  fi
  for _ in $(seq 1 50); do
    if [ -s "$ready" ]; then
      IFS= read -r value < "$ready" || value=
      rm -f -- "$ready"
      [ "$value" = ready ]
      return $?
    fi
    sleep 0.1
  done
  rm -f -- "$ready"
  return 1
}

# The runner's owner guard, which bounds an accidentally orphaned detached
# runner after its home ends. It revalidates the recorded physical state root
# and its lease on a bounded cadence and, after two consecutive reads cannot prove
# both, invokes the identity-gated stop for the runner's whole process group -
# which is what reaches the blocking child and everything that child spawned,
# exactly as retirement does. A failed verified stop stays on the retry cadence;
# an absent leader ends the guard without signalling an ambiguous group.
#
# Those two reads are spaced HALF a check interval apart, so the pair completes
# within one check interval rather than costing two. That keeps the debounce -
# one unreadable read still cannot end a live runner - while bounding detection
# at the lease plus a single check interval. The spacing is what was tightened;
# the second read is what must not be traded away for it.
#
# Scope is the owning state root and this one runner generation. It never
# matches on a script name, a command line, or a process name: those are shared
# by every home running the same adapter, and a live source in another home
# proves its own owner through that home's own lease.
cmd_owner_watchdog() {  # <source-id> <runner-pid> <runner-identity> <ready-file> <state-device> <state-inode>
  local id=${1-} pid=${2-} identity=${3-} ready=${4-} state_device=${5-} state_inode=${6-}
  local lease tick half misses=0 pid_state state_identity current_device current_inode
  [ "$#" -eq 6 ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  case "$pid" in ''|*[!0-9]*) die "runner pid must be a positive integer: $pid" ;; esac
  [ -n "$identity" ] || die "runner identity is required"
  case "$state_device" in ''|*[!0-9]*) die "state device must be an integer" ;; esac
  case "$state_inode" in ''|*[!0-9]*) die "state inode must be an integer" ;; esac
  [ "${ready%/*}" = "$REG" ] && [ -f "$ready" ] && [ ! -L "$ready" ] \
    || die "owner guard readiness boundary is invalid"
  trap 'printf "failed\n" > "$ready" 2>/dev/null || true' EXIT
  require_isolated_group guard
  lease=$(fm_procevent_owner_lease_seconds) \
    || die "FM_PROCEVENT_OWNER_LEASE_SECONDS must be whole seconds from $FM_PROCEVENT_OWNER_LEASE_MIN_SECONDS to $FM_PROCEVENT_OWNER_LEASE_MAX_SECONDS"
  tick=$(fm_procevent_owner_check_seconds) \
    || die "FM_PROCEVENT_OWNER_CHECK_SECONDS must be whole seconds from $FM_PROCEVENT_OWNER_CHECK_MIN_SECONDS to $FM_PROCEVENT_OWNER_CHECK_MAX_SECONDS"
  # Force base ten before any arithmetic. The validator accepts a zero-prefixed
  # value and `[` reads it as decimal, but `$(( ))` would read it as octal: 010
  # would halve to 4 rather than 5, and 08 would not be a number at all and
  # would end the guard before it reports ready, so the runner would fail closed
  # and never listen. Every value the validator accepts must keep working.
  tick=$((10#$tick))
  # Half the configured interval, kept exact for an odd interval so the smallest
  # configurable interval still yields two reads rather than collapsing to one.
  half=$((tick / 2))
  [ $((tick % 2)) -eq 0 ] || half="$half.5"
  fm_procevent_pid_state "$pid" "$identity"
  pid_state=$?
  [ "$pid_state" -eq 0 ] || die "runner identity changed before owner guard initialization"
  state_identity=$(fm_procevent_claim_state_root_identity "$STATE") \
    || die "owning state root identity is unreadable at owner guard initialization"
  IFS=$'\t' read -r _ current_device current_inode _ _ <<< "$state_identity"
  [ "$current_device" = "$state_device" ] && [ "$current_inode" = "$state_inode" ] \
    || die "owning state root identity changed before owner guard initialization"
  fm_procevent_owner_alive "$STATE" "$lease" \
    || die "owning home lease is not fresh at owner guard initialization"
  printf 'ready\n' > "$ready" || die "cannot confirm owner guard initialization"
  trap - EXIT
  while :; do
    sleep "$half"
    fm_procevent_pid_state "$pid" "$identity"
    pid_state=$?
    case "$pid_state" in
      1|3) exit 0 ;;
      0) ;;
      *) continue ;;
    esac
    state_identity=$(fm_procevent_claim_state_root_identity "$STATE" 2>/dev/null || true)
    current_device=
    current_inode=
    [ -z "$state_identity" ] \
      || IFS=$'\t' read -r _ current_device current_inode _ _ <<< "$state_identity"
    if [ "$current_device" = "$state_device" ] \
      && [ "$current_inode" = "$state_inode" ] \
      && fm_procevent_owner_alive "$STATE" "$lease"; then
      misses=0
      continue
    fi
    # Two consecutive misses, so one unreadable read cannot end a live runner.
    # They are half an interval apart, so requiring the second costs detection
    # time inside the interval already budgeted rather than a second interval.
    misses=$((misses + 1))
    [ "$misses" -ge 2 ] || continue
    if stop_runner_pid "$pid" "$identity"; then
      exit 0
    fi
    # Identity/group inspection and signalling can fail transiently. Keep the
    # guard alive so the next normal tick retries the same generation cleanup.
  done
}

# Start a runner outside the watcher cycle that noticed it was missing. The
# public start boundary establishes its own process group before claiming.
detach_runner() {  # <source-id>
  isolate_runner detach "$1"
}

# Announce a source whose claim no unattended caller may displace, once per
# stranded claim generation.
#
# The supervision cycle runs this command with its output and its exit status
# both discarded, so a strand that only shows up in `list` as `orphaned` and in
# this command's `uncertain=` count reaches nobody. A durable `check` wake does
# reach firstmate through the ordinary queue, and it carries what clears the
# strand so acting on it needs no hunt. The caller supplies that part, because
# the two strand shapes clear differently and naming the wrong recovery would
# send someone to a command that reports `already owned` and changes nothing.
#
# The marker records the claim generation that was reported, so the same strand
# never wakes twice while a genuinely new claim still does - an alarm that
# repeats every supervision cycle is as unusable as one nobody gets. It is
# written before the wake and removed again if the wake does not land, so a
# failed announcement retries instead of being silently marked as delivered.
report_stranded_source() {  # <source-id> <claim-token> <why-and-recovery>
  local id=$1 token=$2 detail=$3
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -n "$detail" ] || return 1
  announce_source_once "$(stranded_file "$id")" "$token" \
    "procevent:$id:stranded:$token" \
    "check: process-event source $id is registered but nothing can arm it: $detail"
}

# Announce a launch that reconcile could not confirm, once per failure episode.
#
# A launch that never proves it took the claim - a runner that died before
# claiming on unreadable argv, a missing adapter binary or a guard that refused
# to start, or one merely too slow under load - is relaunched every supervision
# cycle and reported `failed=` to a stdout that cycle discards: armed in
# appearance, a dead drop in fact, which is the incident with a different cause.
# Confirmation observes only that no claim and no launch stamp appeared inside
# the window, so this says exactly that and no more about why. An episode is
# keyed by the registration identity the launch ran under and ends when a later
# cycle finds the source owned or a launch confirms, so a second failure inside
# one episode announces nothing, a slow runner that arms later closes its own
# episode without a retraction, and a source that recovers and then fails again
# announces a new one. Nothing here changes what reconcile does about the launch
# itself: it keeps relaunching exactly as before, and this only says so once.
#
# The queue key carries a nonce beyond the episode: the watcher remembers every
# key it has surfaced for good, so a key made of the registration identity alone
# would be surfaced for the first episode only and every later episode of the
# same registration would sit in the queue unannounced. The marker records the
# episode and that nonce together, and the episode alone decides whether to
# announce.
report_launch_failure() {  # <source-id> <registration-identity>
  local id=$1 identity=$2 episode nonce
  case "$identity" in ''|*[!0-9:]*) episode=unreadable ;; *) episode=${identity//:/-} ;; esac
  nonce="$RANDOM$RANDOM"
  announce_source_once "$(launch_failed_file "$id")" "$episode" \
    "procevent:$id:launch-failed:$episode-$nonce" \
    "check: process-event source $id is registered but its launch did not prove it took the source's claim within FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS, so nothing is confirmed to be collecting from it; reconcile reports that as failed= and keeps launching it every supervision cycle. If it stays that way, check the source command and the adapter binary the registration names, and run an attached bin/fm-procevent.sh start $id to reproduce a refusal on its stderr - the detached launch discards it, and a hand-run reconcile only counts it as failed=. A later cycle that finds the source owned ends this episode on its own, so a runner that was merely slow to claim needs nothing from you." \
    "$episode $nonce"
}

# Shared marker discipline for the announcements above: <marker> holds the
# generation last reported as its first field, written before the wake and
# removed again if the wake does not land, so a failed announcement retries
# instead of being marked delivered, and the same generation never announces
# twice. A caller may store more after that field (the launch-failure nonce);
# only the first field decides.
announce_source_once() {  # <marker> <generation> <key> <payload> [marker-record]
  local marker=$1 generation=$2 key=$3 payload=$4 record=${5:-$2} previous
  previous=$(cat -- "$marker" 2>/dev/null || true)
  [ "${previous%%[[:space:]]*}" != "$generation" ] || return 1
  (umask 077; printf '%s\n' "$record" > "$marker") || return 1
  if ! fm_wake_append check "$key" "$payload"; then
    rm -f -- "$marker"
    return 1
  fi
  return 0
}

# The reused-pid strand: the recorded pid is alive under a different identity
# while the runner's process group still has members. The claim path does not
# consult the process group, so a deliberate `start` reclaims this - provided
# the dead generation's reservation records can still be tidied, because that
# tidy-up is only waived for a generation proven gone, and this one is not.
stranded_reused_pid_detail() {  # <source-id>
  printf '%s' "its claim names a dead runner whose process group still has members, so reconcile preserves that claim and starts no replacement. Check that nothing is still polling the source, then reclaim it with: bin/fm-procevent.sh start $1 - that reclaims it provided the dead generation's reservation records can still be tidied, and otherwise refuses with: cannot claim source"
}

# The leaderless strand: the runner leader is gone and its group still has
# members. `start` reports this as owned and reclaims nothing, and nothing
# automatic signals that group, so the only honest recovery to name is the
# check a human makes; an empty group reads as gone on the next cycle.
stranded_leaderless_detail() {  # <source-id>
  printf '%s' "its runner died and its polling child may still be attached to the source's session, so reconcile preserves that claim and starts no replacement, and nothing automatic will touch that group. Verify whether anything is still polling $1; once that process group is empty, the next reconcile reclaims the source on its own."
}

cmd_reconcile() {
  local rec id published started=0 stopped=0 uncertain=0 failed=0 claim owner pid token identity claim_state stop_state
  local launch_identity launch_stamp launch_mark unconfirmed entry
  local -a launched=()
  # Rejected before anything is launched, and by name. A window this command
  # cannot use makes every launch unconfirmable, so validating it later would
  # report a fleet of perfectly healthy runners as `failed=` and blame nothing.
  fm_procevent_launch_confirm_seconds >/dev/null \
    || die "FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS must be whole seconds from $FM_PROCEVENT_LAUNCH_CONFIRM_MIN_SECONDS to $FM_PROCEVENT_LAUNCH_CONFIRM_MAX_SECONDS"
  owner_lease_refresh
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
        if fm_procevent_claim_reclaim_locked "$id" "$owner" "$pid" "$token" 2>/dev/null; then
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
        if [ "$claim_state" -eq 1 ] && fm_procevent_claim_undisplaceable_locked "$id"; then
          # A stale claim whose process group still has members, which can mean
          # the dead runner's polling child is still on the source's session
          # (fm_procevent_claim_undisplaceable_locked owns that reasoning).
          # Preserve the claim, start nothing, and say the cycle could not
          # settle it, which is what this command already promises for the
          # leaderless variant below. Only a deliberate `start` reclaims here,
          # so report the strand durably rather than leaving it to whoever
          # happens to run this command.
          uncertain=$((uncertain + 1))
          report_stranded_source "$id" "$FM_PROCEVENT_CLAIM_TOKEN" \
            "$(stranded_reused_pid_detail "$id")" || true
        elif [ "$claim_state" -eq 1 ]; then
          if ! cleanup_extension_registration_invocations_locked "$id"; then
            uncertain=$((uncertain + 1))
            fm_procevent_source_lock_release "$id"
            continue
          fi
          # Snapshot the launch-pacing stamp for the registration generation
          # this launch will run under, while the source lock still keeps that
          # registration from being replaced underneath it. The runner writes
          # this stamp after it claims and before it runs the source command,
          # and nothing removes it on the way out, so an advanced or newly
          # appeared value is durable evidence the launch got going.
          launch_identity=$(fm_pr_file_identity "$(source_file "$id")" 2>/dev/null) || launch_identity=
          launch_mark=
          if [ -n "$launch_identity" ] \
            && launch_stamp=$(fm_procevent_launch_floor_stamp_path "$STATE" "$id" "$launch_identity"); then
            launch_mark=$(cat -- "$launch_stamp" 2>/dev/null || true)
          fi
          fm_procevent_source_lock_release "$id"
          detach_runner "$id"
          launched+=("$id"$'\t'"$launch_identity"$'\t'"$launch_mark")
          continue
        elif [ "$claim_state" -eq 4 ]; then
          owner=$FM_PROCEVENT_CLAIM_HOME
          pid=$FM_PROCEVENT_CLAIM_PID
          token=$FM_PROCEVENT_CLAIM_TOKEN
          if fm_procevent_claim_owned_by_state "$STATE" "$FM_HOME" \
            && rm -f -- "$(source_file "$id")" \
            && [ ! -e "$(source_file "$id")" ] \
            && [ ! -L "$(source_file "$id")" ] \
            && fm_procevent_claim_reclaim_locked "$id" "$owner" "$pid" "$token" 2>/dev/null; then
            stopped=$((stopped + 1))
          else
            uncertain=$((uncertain + 1))
          fi
        elif [ "$claim_state" -eq 3 ]; then
          # A leaderless group's generation is ambiguous under PID/PGID reuse,
          # so preserve its claim without signalling or starting a replacement.
          # This is the ordinary crash shape, and `start` cannot clear it
          # either, so it is announced the same way as the reused-pid strand
          # above but naming what a human should check rather than a command.
          uncertain=$((uncertain + 1))
          report_stranded_source "$id" "$FM_PROCEVENT_CLAIM_TOKEN" \
            "$(stranded_leaderless_detail "$id")" || true
        elif [ "$claim_state" -eq 2 ]; then
          uncertain=$((uncertain + 1))
        elif [ "$claim_state" -eq 0 ]; then
          # A live owner is the same evidence confirmation reads, however the
          # runner was started, so it ends any launch-failure episode here.
          rm -f -- "$(launch_failed_file "$id")"
        fi
      fi
      fm_procevent_source_lock_release "$id"
    done
  fi
  if [ "${#launched[@]}" -gt 0 ]; then
    unconfirmed=$(confirm_launched_runners "${launched[@]}") \
      || unconfirmed=$(printf '%s\n' "${launched[@]}")
    for entry in "${launched[@]}"; do
      id=${entry%%$'\t'*}
      launch_identity=${entry#*$'\t'}
      launch_identity=${launch_identity%%$'\t'*}
      if launch_entry_listed "$entry" "$unconfirmed"; then
        failed=$((failed + 1))
        report_launch_failure "$id" "$launch_identity" || true
      else
        started=$((started + 1))
        rm -f -- "$(launch_failed_file "$id")"
      fi
    done
  fi
  printf 'reconciled: published=%s started=%s stopped=%s uncertain=%s failed=%s\n' \
    "$published" "$started" "$stopped" "$uncertain" "$failed"
  [ "$failed" -eq 0 ]
}

launch_entry_listed() {  # <entry> <newline-separated entries>
  local entry=$1 line
  while IFS= read -r line; do
    [ "$line" = "$entry" ] && return 0
  done <<< "$2"
  return 1
}

# Bounded confirmation that every runner just detached actually took its
# source's claim, printing every launch entry that did not, one per line.
#
# detach_runner is fire-and-forget and discards the child's stderr, so before
# this every failure inside _start - a refused claim above all - was still
# counted and reported as a start. That made a source that CANNOT start
# indistinguishable from one that had, which is exactly how a wedged review
# board goes on presenting as armed while collecting nothing.
#
# Two signals confirm a launch, and each covers what the other cannot see:
# ownership covers the runner still blocked on its source, which is the only
# evidence such a runner ever shows; the launch-pacing stamp covers the runner
# that claimed, ran and exited between two polls, because the runner writes that
# stamp after claiming and before running the source command and nothing removes
# it on the way out - only registration replacement does, which also changes the
# snapshotted identity this reads under. A runner that dies BEFORE claiming
# reaches neither, and that is the case this confirmation exists to catch; a
# runner merely slow to claim looks the same inside the window, which is why
# the failure this reports is "not proved within the window" and nothing more.
#
# Every launch shares ONE window rather than taking a window each, so a whole
# fleet of failing sources costs a watcher cycle the same bounded wait as one.
confirm_launched_runners() {  # <source-id><TAB><registration-identity><TAB><launch-stamp-before>...
  local deadline window entry id rest identity before state stamp mark
  local -a pending=("$@") remaining=()
  window=$(fm_procevent_launch_confirm_seconds) || return 1
  # A zero-padded window is a valid value to its validator, which reads base 10;
  # reading it as octal here would silently shorten the window or abort this
  # subshell under `set -u` and report every launch as failed.
  # SECONDS is an integer clock that can tick at any moment after this
  # assignment, so a deadline of exactly SECONDS + window waits anywhere in
  # [window - 1, window] and a healthy launch could be reported failed for
  # losing a second it was promised. The extra second bounds the wait to
  # [window, window + 1] instead: never less than configured.
  deadline=$((SECONDS + 10#$window + 1))
  while :; do
    remaining=()
    for entry in "${pending[@]+"${pending[@]}"}"; do
      id=${entry%%$'\t'*}
      rest=${entry#*$'\t'}
      identity=${rest%%$'\t'*}
      before=${rest#*$'\t'}
      state=1
      if fm_procevent_source_lock_try_acquire "$id"; then
        fm_procevent_claim_state_locked "$id"
        state=$?
        fm_procevent_source_lock_release "$id"
      fi
      if [ "$state" -eq 0 ]; then
        continue
      fi
      mark=
      if [ -n "$identity" ] \
        && stamp=$(fm_procevent_launch_floor_stamp_path "$STATE" "$id" "$identity"); then
        mark=$(cat -- "$stamp" 2>/dev/null || true)
      fi
      if [ -n "$mark" ] && [ "$mark" != "$before" ]; then
        continue
      fi
      remaining+=("$entry")
    done
    pending=("${remaining[@]+"${remaining[@]}"}")
    [ "${#pending[@]}" -gt 0 ] || break
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 0.05
  done
  [ "${#pending[@]}" -eq 0 ] || printf '%s\n' "${pending[@]}"
}

# Stop a runner and the child it is blocked on. A runner started by reconcile is
# its own process group leader, so the group signal is what actually reaches the
# blocking child - signalling only the runner would leave that child alive and
# reparented, which is exactly how a source that never completes leaks.
# docs/configuration.md owns the operating contract and unproved-group limits.
# A leaderless group nobody in this call ever proved remains refused for every
# caller, and that untouched refusal is what makes a crashed leader's group
# permanent. Relaxing it is a SEPARATE OPEN QUESTION, not something this path
# assumes: an unresolved question has to be marked unresolved where the decision
# is made, because a reader who does not know it is open will read a bare refusal
# as settled design and eventually relax it.
runner_group_signal() {  # <signal> <pid> <identity> [proved]
  local signal=$1 pid=$2 identity=$3 proved=${4-} state pgid
  if [ -n "$proved" ]; then
    # This stop proved ownership before TERM; only its own escalation may reuse
    # that same proof within the same stop_runner_pid call. Re-reading the leader
    # as our signal ends it would discard that proof, not disprove ownership.
    # A group encountered without proof remains refused by the unproved path.
    fm_procevent_group_alive "$pid" || return 1
  else
    # Before the first signal, require a live identity-matched group leader:
    # absent, unreadable, reused, or nonleader PIDs cannot prove ownership.
    # Launch pacing, leases, and reconcile cleanup remain the backstop.
    fm_procevent_pid_state "$pid" "$identity"
    state=$?
    case "$state" in
      0) ;;
      1) fm_procevent_group_alive "$pid" && return 2; return 1 ;;
      *) return 2 ;;
    esac
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 2
    [ "$pgid" = "$pid" ] || return 2
  fi
  # KNOWN LIMIT: portable shell cannot make this verification and signal atomic,
  # so the PID and group could be reused in the interval between them.
  kill -"$signal" -"$pid" 2>/dev/null || return 2
}

stop_runner_pid() {  # <pid> <identity>
  local pid=${1-} identity=${2-} signal_state i=0
  case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  [ -n "$identity" ] || return 2
  runner_group_signal TERM "$pid" "$identity"
  signal_state=$?
  [ "$signal_state" -eq 0 ] || return "$signal_state"
  while [ "$i" -lt 20 ]; do
    kill -0 -"$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  runner_group_signal KILL "$pid" "$identity" proved
  signal_state=$?
  [ "$signal_state" -eq 0 ] || return "$signal_state"
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
  owner_lease_refresh
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
      if ! fm_procevent_claim_reclaim_locked "$id" "$owner" "$pid" "$token"; then
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
  rm -f -- "$(stranded_file "$id")"
  rm -f -- "$(launch_failed_file "$id")"
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
  local rec id adapter owner pending claim_state
  owner_lease_refresh
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
    claim_state=$?
    # A stale claim whose process group still has members is exactly as
    # undisplaceable as the leaderless group state 3 already reports, and a
    # reused PID reaches it through state 1 rather than state 3. Reporting that
    # as `none` reads like an idle source waiting to be started, which is the
    # reassuring answer this whole surface gave while a board collected nothing.
    case "$claim_state" in
      0) owner=live ;;
      1)
        owner=none
        if fm_procevent_claim_undisplaceable_locked "$id"; then
          owner=orphaned
        fi
        ;;
      3) owner=orphaned ;;
      *) owner=uncertain ;;
    esac
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
  _owner-watchdog)    shift; cmd_owner_watchdog "$@" ;;
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
