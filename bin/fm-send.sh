#!/usr/bin/env bash
# Steer a task by durable record: write the message into the task's steering
# inbox and ring a constant doorbell line into its terminal, best-effort.
# Usage: fm-send.sh <target> [--resolve-key <key>]... [--fire-and-forget <delivery-id>] <text...>
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit well-formed backend
#   target. fm-send refuses unresolved guesses rather than falling back to a
#   tmux window search, because a "successful" send to the wrong endpoint is
#   worse than a loud failure.
# Special keys instead of text: fm-send.sh <target> --key Enter
# Key support is backend-specific: tmux/herdr support Escape, Enter, and C-c;
# Orca currently supports Enter and C-c only, and rejects Escape.
#
# Two data planes:
#
# INBOX - the default for text to a task recorded in this home, local and
# remote alike. The message is appended as a durable sequenced record under
# the task's steering inbox (newlines are legal) - state/<id>.inbox/ for a
# local task, or the remote home's host-local inbox reached through fm-on.sh
# for a remote secondmate - and the terminal receives only one short constant
# self-describing doorbell line plus Enter, best-effort. The durable record IS
# the delivery, so the record's fate alone governs the exit: 0 = the steer is
# durably sent (recorded); nonzero = nothing was confirmed delivered and a
# resend is appropriate (unresolvable target, an endpoint that cannot be
# locked and revalidated or that retired or changed, an unwritable record, a
# failed or lost remote transport) or a decision-close append failed after
# delivery (the error then carries the exact manual close). The remote enqueue
# is idempotent: the remote leg deduplicates an exact re-run of the same
# request onto the existing record (bin/fm-task-inbox-lib.sh), so after a lost
# transport (ssh exit 255, completion unknown) fm-send retries the same leg
# once itself. For an ordinary reply-bearing request, a later re-run is
# idempotent only through the printed FM_PENDING_REPLY_EXISTING_CORR=<corr>
# command: it preserves the same correlation, body, and record, while a plain
# re-run mints a new correlation and delivers a separate record. An explicit
# fire-and-forget request instead retries with its same caller-supplied delivery
# id. A still-unconfirmed reply-bearing request keeps its reply expectation
# preserved for the record that may have landed.
# Pending-reply bookkeeping trouble after a durable enqueue NEVER exits
# nonzero: with the recovery marker stored the watcher reconciles it silently,
# and with both the commit and the marker lost the send prints a distinct
# "reply-tracking-degraded (steer delivered, do not resend)" warning instead,
# because a resend-inviting status there would duplicate a delivered
# instruction. There is no delivered-unconfirmed
# outcome on this plane: "did the doorbell land" is no longer the question -
# "was the message acted on" is, and that is answered asynchronously for an
# ordinary record by the worker's acknowledgement move into handled/, with the
# watcher re-ringing an unacknowledged message and escalating a stuck one. An
# explicit fire-and-forget record is excluded from that ladder.
# bin/fm-task-inbox-lib.sh owns the record format, the doorbell line, and the
# re-ring ladder. The composer pre-check before the ring is ADVISORY only: when
# the composer visibly holds pending text the ring is skipped with a notice and
# the watcher re-rings an ordinary record later; no composer verdict is
# delivery proof on this plane, and a failed ring never fails the send.
#
# TYPED - the LOCAL text that must reach the terminal itself: a harness-native
# invocation (a leading "/", or a leading "$" to a codex target) must reach
# the harness's own parser, and an explicit backend target names an endpoint,
# not a task, so it stays typed even when local metadata happens to match it
# (the same boundary that keeps it unmarked and outside --resolve-key). These
# type the literal
# text through the target backend's verified submit core: typed ONCE, then
# Enter retried (never retyped) until the backend confirms a submit or reports
# an inconclusive send. Typed-plane exit contract: 0 = submit confirmed;
# 3 = the text was typed into the live endpoint and
# Enter was sent, but the submit read-back stayed unconfirmed (verify the pane
# before any resend, and never re-type blindly; a marked request's
# pending-reply expectation stays armed because this outcome is not a proven
# failure); any other nonzero = the send failed and nothing may be assumed
# delivered. Submission dispatches through the target's recorded backend; the
# tmux adapter shares its composer/submit core with the away-mode daemon via
# bin/fm-tmux-lib.sh. Tune with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP
# (0.4). Slash commands, and codex `$...` skill invocations resolved through
# harness meta, get a longer pre-Enter settle so completion popups do not
# swallow Enter. A remote secondmate target has no typed text plane at all:
# every remote text steer rides the inbox (a marked secondmate request already
# reaches the harness as marker-prefixed chat rather than a parser command, so
# routing a remote "/..." or "$..." through the record changes nothing the
# parser would have seen); only --key still crosses to the remote pane as a
# keystroke.
#
# Stage-1 compatibility boundary: classification uses the original pre-marker
# text, but secondmate marking still precedes every typed submission. Therefore
# a marked parser-native secondmate invocation intentionally reaches the harness
# as marker-prefixed chat rather than executing as a parser command. This is a
# pre-existing interaction retained for byte compatibility in this local-inbox
# stage; do not move the marker behind the invocation or omit it here. Follow-up
# fm-send-secondmate-harness-invocation-r1 owns that behavior.
#
# From-firstmate marker: when the resolved target is a task selector whose meta
# records kind=secondmate, the message uses the live-charter-compatible
# from-firstmate carrier owned by bin/fm-operational-input.sh so the secondmate
# routes its reply via its status file or a status-pointed doc instead of
# stranding it in chat the main firstmate never reads. On the inbox plane the
# marker travels verbatim inside the recorded body. A crewmate/scout target,
# an explicit backend-target escape-hatch target, and the --key path are never
# marked - their behavior is unchanged.
#
# Parent-owned pending-reply expectation: every newly marked secondmate request
# except an explicit --fire-and-forget delivery receives a privacy-safe
# correlation id and a durable parent record under state/pending-replies/ before
# delivery (bin/fm-pending-reply-lib.sh). Delivery
# success and reply success are separate facts: delivery never resolves the
# expectation. On the inbox plane the durable enqueue IS delivery to the task's
# record, so the expectation is marked delivered at enqueue time; when that
# bookkeeping commit fails after its durable recovery marker is stored, the
# send remains successful and watcher reconciliation owns the repair, and when
# the commit and marker are BOTH lost the send still remains successful with a
# reply-tracking-degraded warning naming the expectation an operator must
# inspect (it can no longer reconcile or escalate on its own). Only a
# failed enqueue discards the expectation. On the typed plane an unconfirmed submit (exit 3) keeps
# it armed rather than dropping it, and only a proven send failure discards it.
# Set FM_PENDING_REPLY_EXISTING_CORR=<id> when re-sending a recovery request
# for an already-open expectation so a second record is not created. Direct
# unmarked captain input never creates one. A marked secondmate instruction
# sent with --fire-and-forget <16-hex-delivery-id> uses the same inbox transport
# without creating a reply expectation; its delivery id makes uncertain retries
# idempotent while allowing a later identical instruction to be distinct.
#
# Remote secondmate delivery: the send crosses fm-on.sh to a host-local leg
# (bin/fm-remote-secondmate-control.sh cmd_send) that writes the message as a
# durable record into the remote home's steering inbox and rings the remote
# doorbell, best-effort. The remote record is the delivery, exactly as it is
# locally: leg exit 0 means durably recorded (fm-send then exits 0, marks the
# pending-reply expectation delivered, and closes any --resolve-key
# decisions), and any real remote failure fails loudly with the remote leg's
# own stderr attached. Transport loss (ssh exit 255) means completion unknown,
# so fm-send retries the identical leg once - safe because the remote write
# deduplicates the same request onto the same record - and a still-lost
# transport exits nonzero while preserving a reply-bearing marked request's
# expectation, since the record may have landed. Its error prints the exact
# FM_PENDING_REPLY_EXISTING_CORR=<id> resend command that preserves the body
# and makes a later remote enqueue deduplicate onto that same record. An
# unconfirmed fire-and-forget request exits 3 and names the same delivery id to
# retry. Every remote transport attempt is bounded by FM_SEND_REMOTE_BUDGET
# seconds (default 30, and any override must be a positive integer): a bound
# hit is completion-unknown and exits through this same unconfirmed contract
# instead of waiting out a busy remote queue.
# The remote host runs no re-ring ladder of its own: a swallowed ordinary
# doorbell surfaces through the parent's pending-reply recovery and escalation,
# whose recovery request re-rings the remote doorbell when it is enqueued;
# fire-and-forget delivery deliberately arms neither mechanism. Internal
# semantic callers may set FM_SEND_EXPECTED_SPAWN_GEN or
# FM_SEND_EXPECTED_REMOTE_HOST to require that sampled identity to still match
# during the final locked remote-route validation; unset or empty guards do not
# change ordinary sends.
#
# Decision closure (answerer-closes): pass --resolve-key <key> (repeatable,
# before the message) when this send answers an open keyed needs-decision: or
# blocked: record in the target task's state/<id>.status. fm-send itself
# appends the closing resolved line to that status file, so the captain-facing
# OPEN DECISIONS record closes at answer time and never depends on the busy
# worker writing a matching resolved line. Ordinary keys close with
# "resolved [key=<key>]: answered: <capped excerpt>". A reserved key
# (pending-reply-* today; bin/fm-classify-lib.sh's reserved-key guard) is
# closed with the owning library's vocabulary note
# (fm_pending_reply_close_note_for_key / fm_pending_reply_resolved_note), so
# the fold actually drops it; a bare answered: note is not a reserved-key
# transition and is never written for those keys. If this send cannot produce
# a note the guard will accept, or the structural key would be lost to the
# status-line cap, it refuses before sending and names the cause rather than
# exiting 0 on a silent no-op. After a delivered close it also
# re-folds and fails loudly if the named key is still open. On the inbox plane
# the close happens at ENQUEUE time, because enqueue is durable delivery to
# the task's record; the worker reading the answer late is covered by the
# acknowledgement re-ring ladder. On the typed plane it still waits for the
# confirmed submit. The close is a LOCAL append for every target kind -
# crewmate, scout, local secondmate, and remote secondmate alike - because the
# open-decision ledger fm-wake-drain folds lives in this home's own state dir
# (a remote mate's escalations reach it through the parent-replies ingest);
# only the answer message crosses the backend or remote transport.
#
# Chat is also a channel that carries keyed captain answers, so the same flag
# feeds bin/fm-captain-hold.sh's one keyed-answer intake for any key that names
# a captain-held task in this home - the key as a task id itself, or through
# the legacy `<task>-decision-<key>` identity for pre-collapse rows. fm-send
# closes nothing itself; it hands the intake `<task-id>\t<answer>\t<label>`
# exactly as every other channel does, and the intake owns what that means.
# This is what lets an answer reach a decision that has already been
# transferred from the live status log to its durable captain-held task, which
# the status ledger alone can no longer close.
#
# Each named key must therefore currently be open in ONE of the two ledgers: open
# in this home's status log per status_open_decisions (bin/fm-classify-lib.sh), or
# a still-open captain-held task resolved as above. A key in neither is refused
# before sending, so a mistyped key cannot deliver an answer while silently
# orphaning the decision. A failed or unconfirmed send never closes a key; a
# delivered answer whose closing append fails exits nonzero with the exact
# manual close command, leaving the decision open to re-surface (the safe
# direction). A send without the flag never closes anything: a routine steer,
# working:, or done: event still cannot clear a captain decision. The flag is
# refused with --key, with an explicit backend target (no task ledger in this
# home), and with an empty message.
#
# After a successful TYPED-plane submit fm-send pauses FM_SEND_SETTLE seconds
# (default 1, 0 disables) before returning: submit confirmation only proves the
# text was accepted, but the harness needs a beat to spin up the turn before its
# busy footer appears, so an immediate peek would otherwise see the stale idle
# pane. The pause is typed-plane-only; the inbox plane, the shared submit core
# (used by the away-mode daemon, which only needs "submitted"), and the --key
# path do not pay it.
set -eu

FM_SEND_ORIGINAL_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never steer
# a crewmate (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-send refuses to resolve targets without an explicit firstmate home" >&2
  exit 1
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
if [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory; fm-send cannot resolve this home's state" >&2
  exit 1
fi
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-send cannot resolve targets for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the requested message WILL still be sent.' "$SCRIPT_DIR/fm-guard.sh" || true

fm_send_id_from_meta() {  # <meta-file>
  local base
  base=${1##*/}
  printf '%s' "${base%.meta}"
}

# fm_send_clear_after_interrupt: muse RESTORES the interrupted prompt back into
# the composer when Escape cancels a turn, as real bright text (verified: fg
# 38;2;204;211;219, luminance ~210, muse 0.1.0-R708.1), not de-emphasised ghost
# text. Classifying that as pending input is correct - the text really is
# unsubmitted - but leaving it there means the NEXT steer types onto the end of
# it and submits both as one garbled message. Ctrl-U clears the composer
# (verified), so the interrupt is not complete until it has been sent. A failed
# clear is loud rather than silent, because the alternative is a corrupted steer.
# WHICH adapters need that clear, and which key clears them, comes from the one
# control-plane capability table (bin/fm-control-lib.sh) rather than a second
# copy here - the same table bin/fm-control.sh's interrupt verb reads.
fm_send_clear_after_interrupt() {  # <key>
  local key=$1 family clear
  [ "$key" = Escape ] || return 0
  family=$(fm_control_harness_family "$TARGET_HARNESS") || return 0
  clear=$(fm_control_interrupt_clear_key "$family") || return 0
  [ -n "$clear" ] || return 0
  [ "$TARGET_BACKEND" != remote ] || return 0
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$clear" "$EXPECTED_LABEL"; then
    echo "error: Escape reached $T, but the $TARGET_HARNESS composer could not be cleared; it still holds the restored prompt. Clear it before sending the next message." >&2
    return 1
  fi
}

fm_send_normalize_key() {  # <key>
  case "$1" in
    Escape|escape|Esc|esc) printf '%s' Escape ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_send_record_interrupt() {  # <key>
  local key=$1 id gen
  [ "$key" = Escape ] || return 0
  case "$TARGET_HARNESS" in claude*) : ;; *) return 0 ;; esac
  [ -n "$TARGET_META" ] || return 0
  id=$(fm_send_id_from_meta "$TARGET_META")
  [ -f "$STATE/$id.busy-gen" ] || return 0
  gen=$(fm_meta_get "$TARGET_META" busy_gen)
  if [ -n "$gen" ]; then
    "$FM_ROOT/bin/fm-busy-event.sh" apply "$STATE" "$id" idle \
      --gen "$gen" --source fm-interrupt --event interrupt
  else
    "$FM_ROOT/bin/fm-busy-event.sh" apply "$STATE" "$id" idle \
      --current-gen --source fm-interrupt --event interrupt
  fi || {
    echo "error: key '$key' reached $T, but the Claude interrupt state could not be recorded for $id" >&2
    return 1
  }
}

fm_send_meta_for_key_value() {  # <state-dir> <key> <value>
  local state=$1 key=$2 value=$3 meta got
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    got=$(fm_meta_get "$meta" "$key")
    [ "$got" = "$value" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_send_count_colons() {  # <string>
  local s=$1 no_colons
  no_colons=${s//:/}
  printf '%s' $(( ${#s} - ${#no_colons} ))
}

fm_send_resolve_target() {  # <raw-target>
  local raw=$1 meta pane_meta target backend assumed colons id session hint

  RESOLVED_TARGET=""
  TARGET_BACKEND=""
  TARGET_HARNESS=""
  EXPECTED_LABEL=""
  TARGET_META=""
  TARGET_SELECTOR=""
  TARGET_REMOTE_ID=""
  TARGET_REMOTE_HOST=""
  RESOLUTION_TRIED=""

  meta=$(fm_backend_meta_for_selector "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
      id=$(fm_send_id_from_meta "$meta")
      RESOLVED_TARGET="remote:$id"
      TARGET_BACKEND=remote
      TARGET_META=$meta
      TARGET_HARNESS=$(fm_meta_get "$meta" harness)
      EXPECTED_LABEL="fm-$id"
      TARGET_SELECTOR=1
      TARGET_REMOTE_ID=$id
      TARGET_REMOTE_HOST=$(fm_meta_get "$meta" remote_host)
      RESOLUTION_TRIED="meta=$meta; placement=remote"
      return 0
    fi
    RESOLUTION_TRIED="meta=$meta; backend=from-meta"
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried $RESOLUTION_TRIED)" >&2
      return 1
    fi
    backend=$(fm_backend_of_meta "$meta")
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$backend
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$raw" "$STATE")
    TARGET_SELECTOR=1
    return 0
  fi

  case "$raw" in
    fm-*:*)
      # A named Herdr session may itself begin with "fm-". Keep that explicit
      # session:pane target on the validated backend-target path below rather
      # than mistaking it for an unresolved task selector.
      ;;
    fm-*)
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; legacy-meta=$STATE/${raw#fm-}.meta; backend=none"
      echo "error: no metadata for $raw in $STATE (tried $RESOLUTION_TRIED); pass a well-formed explicit backend target only when targeting outside this firstmate home" >&2
      return 1
      ;;
  esac

  pane_meta=$(fm_send_meta_for_key_value "$STATE" herdr_pane_id "$raw" 2>/dev/null || true)
  if [ -n "$pane_meta" ]; then
    session=$(fm_meta_get "$pane_meta" herdr_session)
    hint="${session:-<herdr-session>}:$raw"
    id=$(fm_send_id_from_meta "$pane_meta")
    echo "error: target '$raw' matches herdr_pane_id in $pane_meta but is missing its herdr session prefix; expected <herdr-session>:<pane-id> such as '$hint' or use 'fm-$id' (tried meta=$STATE/$raw.meta; backend=herdr)" >&2
    return 1
  fi

  meta=$(fm_backend_meta_for_window "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried explicit target '$raw' via recorded window/terminal; backend=from-meta)" >&2
      return 1
    fi
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$(fm_backend_of_meta "$meta")
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    RESOLUTION_TRIED="explicit target '$raw' matched $meta; backend=$TARGET_BACKEND"
    return 0
  fi

  case "$raw" in
    *:*)
      colons=$(fm_send_count_colons "$raw")
      if [ "$colons" -ge 2 ]; then
        assumed=herdr
      else
        assumed=tmux
      fi
      if ! fm_backend_target_exists "$assumed" "$raw"; then
        echo "error: explicit target '$raw' is not a live $assumed endpoint (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed). Use fm-<id> for a recorded task/lane, or pass a target whose backend endpoint can be verified." >&2
        return 1
      fi
      RESOLVED_TARGET=$raw
      TARGET_BACKEND=$assumed
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed; endpoint=verified"
      return 0
      ;;
  esac

  echo "error: target '$raw' is not resolvable (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=none). Use fm-$raw for a recorded task/lane, or pass a well-formed explicit backend target such as session:window." >&2
  return 1
}

RAW_TARGET=$1
fm_send_resolve_target "$RAW_TARGET" || exit 1
T=$RESOLVED_TARGET
shift

# Supervision lease guard: a steer is overlap territory between the two Pi
# supervision actors, so refuse while the OTHER actor holds this task's live
# lease. A home with no supervision branch has no lease files and passes
# untouched (contract: bin/fm-lease-lib.sh).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
if [ -n "$TARGET_META" ]; then
  LEASE_GUARD_TASK=$(fm_send_id_from_meta "$TARGET_META")
  if [ -n "$LEASE_GUARD_TASK" ]; then
    fm_lease_guard "$LEASE_GUARD_TASK" "steer (fm-send)"
    trap 'fm_lease_guard_release' EXIT
  fi
fi

# Collect --resolve-key flags (answerer-closes; see the header contract). They
# must precede --key or the message text; everything after the last flag is the
# message exactly as before, so ordinary sends are byte-identical.
RESOLVE_KEYS=
FIRE_AND_FORGET_ID=
fm_send_add_resolve_key() {  # <key>
  local k=$1
  case "$k" in
    ''|*[!A-Za-z0-9._-]*)
      echo "error: --resolve-key '$k' is not a valid decision key (allowed: A-Z a-z 0-9 . _ -)" >&2
      return 1
      ;;
  esac
  case " $RESOLVE_KEYS " in
    *" $k "*)
      echo "error: duplicate --resolve-key '$k'" >&2
      return 1
      ;;
  esac
  RESOLVE_KEYS="${RESOLVE_KEYS}${RESOLVE_KEYS:+ }$k"
}
while :; do
  case "${1:-}" in
    --resolve-key)
      [ $# -ge 2 ] || { echo "error: --resolve-key requires a key" >&2; exit 1; }
      fm_send_add_resolve_key "$2" || exit 1
      shift 2
      ;;
    --resolve-key=*)
      fm_send_add_resolve_key "${1#--resolve-key=}" || exit 1
      shift
      ;;
    --fire-and-forget)
      [ $# -ge 2 ] || { echo "error: --fire-and-forget requires a delivery id" >&2; exit 1; }
      [ -z "$FIRE_AND_FORGET_ID" ] || { echo "error: duplicate --fire-and-forget" >&2; exit 1; }
      FIRE_AND_FORGET_ID=$2
      shift 2
      ;;
    --fire-and-forget=*)
      [ -z "$FIRE_AND_FORGET_ID" ] || { echo "error: duplicate --fire-and-forget" >&2; exit 1; }
      FIRE_AND_FORGET_ID=${1#--fire-and-forget=}
      shift
      ;;
    *) break ;;
  esac
done

if [ "$TARGET_BACKEND" != remote ]; then
  fm_backend_validate "$TARGET_BACKEND" || exit 1
fi

# Classify a from-firstmate -> secondmate request. Only a task selector resolved
# through this home's meta whose authoritative kind is secondmate is marked: the
# secondmate then routes its reply via the status path (see fm-marker-lib.sh).
# An explicit backend target (the escape hatch for endpoints outside this home)
# and any crewmate/scout target are left unmarked, and so is the --key path.
MARK_FROM_FIRSTMATE=0
PENDING_REPLY_CORR=
PENDING_REPLY_CREATED=0
TARGET_TASK_ID=
fm_send_known_undelivered_cleanup() {
  [ -n "$PENDING_REPLY_CORR" ] || return 0
  if [ "$PENDING_REPLY_CREATED" = 1 ]; then
    fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR"
  else
    fm_pending_reply_reset_known_undelivered "$STATE" "$PENDING_REPLY_CORR"
  fi
}
if [ -n "$TARGET_SELECTOR" ] && [ -n "$TARGET_META" ] && [ "$(fm_meta_get "$TARGET_META" kind)" = secondmate ]; then
  MARK_FROM_FIRSTMATE=1
  TARGET_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
fi

# Validate the answerer-closes request before any durable mutation or send: the
# target must have a task ledger in THIS home, the send must carry an answer
# message, and every named key must be open right now in that ledger per the
# ONE authoritative fold (status_open_decisions). Refusing here, before the
# send, is what keeps a mistyped key loud instead of delivering an answer that
# silently leaves its decision open.
RESOLVE_STATUS_FILE=
# Which ledger each answered key belongs to. A key still open in the status log
# is owned by the status log: fm-captain-hold's `complete` closes that live copy
# at the moment it transfers a decision to its durable captain-held task, so
# "still open in status" and "already held" are the two sides of one transfer,
# never both at once. Checking the backlog only for keys the status log no
# longer owns also keeps the common path free of any backlog read.
RESOLVE_STATUS_KEYS=
RESOLVE_HOLD_KEYS=

# Resolve a --resolve-key key that the status log no longer owns to the
# captain-held task that carries it: the key as a task id itself (the collapsed
# identity - a captain call IS a task held for the captain), then the legacy
# derived `<task>-decision-<key>` identity for pre-collapse rows. Answerable
# means not closed and still carrying the captain-hold annotations tasks-axi
# preserves even past a hold-until date.
fm_send_hold_resolved_id() {  # <task-id> <decision-key>
  local show id state hold_kind
  command -v tasks-axi >/dev/null 2>&1 || return 1
  for id in "$2" "$1-decision-$2"; do
    show=$( (cd "$FM_HOME" && tasks-axi show "$id" --full) 2>/dev/null ) || continue
    state=$(printf '%s\n' "$show" | sed -n 's/^  state: //p' | head -1)
    hold_kind=$(printf '%s\n' "$show" | sed -n 's/^  hold_kind: //p' | head -1)
    [ "$state" != "done" ] || continue
    [ "$hold_kind" = captain ] || continue
    printf '%s\n' "$id"
    return 0
  done
  return 1
}

# Close-note body for --resolve-key. Ordinary keys keep answered: <excerpt>.
# A pending-reply-* key uses the owning library's vocabulary so the reserved-key
# fold actually closes it (fm_pending_reply_close_note_for_key).
fm_send_resolve_close_note() {  # <key> <excerpt>
  local k=$1 excerpt=$2 owned
  if owned=$(fm_pending_reply_close_note_for_key "$k" "$RESOLVE_TASK_ID" operator-resolve-key "$excerpt"); then
    printf '%s' "$owned"
    return 0
  fi
  printf 'answered: %s' "$excerpt"
}

if [ -n "$FIRE_AND_FORGET_ID" ]; then
  printf '%s' "$FIRE_AND_FORGET_ID" | grep -Eq '^[a-f0-9]{16}$' \
    || { echo "error: --fire-and-forget delivery id must be 16 lowercase hex characters" >&2; exit 1; }
  [ "$MARK_FROM_FIRSTMATE" = 1 ] \
    || { echo "error: --fire-and-forget requires a recorded secondmate task selector" >&2; exit 1; }
  [ -z "$RESOLVE_KEYS" ] \
    || { echo "error: --fire-and-forget cannot accompany --resolve-key" >&2; exit 1; }
fi

if [ -n "$RESOLVE_KEYS" ]; then
  if [ -z "$TARGET_SELECTOR" ] || [ -z "$TARGET_META" ]; then
    echo "error: --resolve-key needs a task selector resolved through this home's metadata; an explicit backend target has no decision ledger here" >&2
    exit 1
  fi
  if [ "${1:-}" = "--key" ]; then
    echo "error: --resolve-key cannot accompany --key; answering a decision requires a text answer" >&2
    exit 1
  fi
  if [ -z "$*" ]; then
    echo "error: --resolve-key requires a nonempty answer message" >&2
    exit 1
  fi
  RESOLVE_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
  RESOLVE_STATUS_FILE="$STATE/$RESOLVE_TASK_ID.status"
  resolve_open_set=$(status_open_decisions "$RESOLVE_STATUS_FILE")
  for k in $RESOLVE_KEYS; do
    case "$resolve_open_set" in
      "$k"$'\t'*|*$'\n'"$k"$'\t'*)
        RESOLVE_STATUS_KEYS="${RESOLVE_STATUS_KEYS}${RESOLVE_STATUS_KEYS:+ }$k"
        continue
        ;;
    esac
    # Not open in the status log. A decision already transferred to its durable
    # captain-held task is exactly this case, and it is answerable - just
    # through the other ledger - so check there before refusing.
    if resolved_hold_id=$(fm_send_hold_resolved_id "$RESOLVE_TASK_ID" "$k"); then
      RESOLVE_HOLD_KEYS="${RESOLVE_HOLD_KEYS}${RESOLVE_HOLD_KEYS:+ }$resolved_hold_id"
      continue
    fi
    echo "error: --resolve-key '$k': no open decision or blocker with that key in $RESOLVE_STATUS_FILE, and no captain-held task '$k' or '$RESOLVE_TASK_ID-decision-$k' still open (already closed or mistyped). Re-check the OPEN DECISIONS listing, then resend without that key or with the right one; nothing was sent." >&2
    exit 1
  done
  # Refuse before send when a named status-log key cannot actually close: a
  # reserved key with an answered: note is a silent no-op in the fold.
  resolve_excerpt=$(printf '%s' "$*" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  for k in $RESOLVE_STATUS_KEYS; do
    probe=$(fm_send_resolve_close_note "$k" "$resolve_excerpt")
    if ! _fm_decision_key_transition_allowed "$k" "$probe"; then
      echo "error: --resolve-key '$k' cannot take effect: this key is reserved for its owning library, and this send cannot produce a close note that library's fold will accept. Refusing rather than writing a silent no-op; nothing was sent." >&2
      exit 1
    fi
    probe_line="resolved [key=$k]: $probe"
    fm_cap_line_var "$probe_line"
    probe_key=$(_fm_decision_key "$FM_LINE_CAP_LINE") || probe_key=
    if [ "$(status_line_verb "$FM_LINE_CAP_LINE")" != resolved ] || [ "$probe_key" != "$k" ]; then
      echo "error: --resolve-key cannot close a decision key of length ${#k}: its ${#probe_line}-character close record exceeds the $FM_LINE_CAP_DEFAULT-character status-line cap, and truncation would remove the structural key delimiter. Refusing rather than writing an ineffective close; nothing was sent." >&2
      exit 1
    fi
  done
fi

# Close each answered decision in this home's ledger, only after the answer is
# durably sent: enqueued on the inbox plane, submit-confirmed on the typed
# plane. An append failure exits nonzero with the manual close
# command; the decision then stays open and re-surfaces, never silently lost.
# The close is this home's own bookkeeping, written by the very turn that
# answered the decision, so it goes through the guarded self-announced append
# (bin/fm-wake-lib.sh) and does not wake this same session again; any
# concurrent foreign status bytes leave the watcher's wake path untouched.
fm_send_close_resolved_keys() {  # <answer-text>
  local note=$1 k line close_note append_rc still manual_close_cmd
  note=$(printf '%s' "$note" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  for k in $RESOLVE_STATUS_KEYS; do
    close_note=$(fm_send_resolve_close_note "$k" "$note")
    line="resolved [key=$k]: $close_note"
    fm_cap_line_var "$line"
    printf -v manual_close_cmd "printf '%%s\\n' %q >> %q" "$FM_LINE_CAP_LINE" "$RESOLVE_STATUS_FILE"
    append_rc=0
    fm_wake_status_append_self_announced "$STATE" "$RESOLVE_STATUS_FILE" "$FM_LINE_CAP_LINE" || append_rc=$?
    if [ "$append_rc" -eq 2 ]; then
      echo "error: the answer was delivered to $T, but decision key '$k' could not be closed in $RESOLVE_STATUS_FILE. Close it manually with: $manual_close_cmd - do not resend the answer." >&2
      return 1
    fi
    still=$(status_open_decisions "$RESOLVE_STATUS_FILE")
    case "$still" in
      "$k"$'\t'*|*$'\n'"$k"$'\t'*)
        echo "error: the answer was delivered to $T, but decision key '$k' is still open in $RESOLVE_STATUS_FILE; it may have been reopened concurrently or the fold did not accept the close. Close it manually with: $manual_close_cmd - do not resend the answer." >&2
        return 1
        ;;
    esac
  done
}

# Feed the answered captain-held tasks to the ONE keyed-answer intake, as keyed
# lines, exactly the way every other channel does. fm-send decides nothing here:
# it does not build a decision record or choose a close path; the keys were
# already resolved to task ids above, so the intake needs no legacy origin.
fm_send_feed_resolved_holds() {  # <answer-text>
  local note=$1 k lines=''
  [ -n "$RESOLVE_HOLD_KEYS" ] || return 0
  note=$(printf '%s' "$note" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  for k in $RESOLVE_HOLD_KEYS; do
    lines="${lines}${k}"$'\t'"${note}"$'\t'$'\n'
  done
  if ! printf '%s' "$lines" | "$SCRIPT_DIR/fm-captain-hold.sh" answers \
    --source "a firstmate answer sent to $RESOLVE_TASK_ID" >/dev/null 2>&1; then
    echo "error: the answer was delivered to $T, but this captain-held task could not be closed: ${RESOLVE_HOLD_KEYS}. Close it with fm-captain-hold.sh answer - do not resend the answer." >&2
    return 1
  fi
}

# Resolve the target's harness from its meta (recorded by fm-spawn), used only to
# scope the codex `$<skill>` popup-settle below. A task selector carries
# meta; an explicit backend-target escape hatch has none, so its harness is
# unknown and treated as non-codex (the safe default that keeps the fast path).
# The target's BACKEND comes from selector meta, from matching an explicit target
# back to recorded meta, or from strict explicit-target shape validation.
# Do not add a separate passive liveness preflight here. Active send paths own
# backend readiness: herdr, for example, must route through its session-aware
# target_ready path before sending, while zellij verifies pane labels in its
# send implementation. A failed backend send is still surfaced below as a hard
# error with the attempted resolution attached.

if [ "${1:-}" = "--key" ]; then
  [ -z "$FIRE_AND_FORGET_ID" ] \
    || { echo "error: --fire-and-forget cannot accompany --key" >&2; exit 1; }
  case "$*" in
    *--resolve-key*)
      echo "error: --resolve-key cannot accompany --key; answering a decision requires a text answer" >&2
      exit 1
      ;;
  esac
  key=$2
  semantic_key=$(fm_send_normalize_key "$key")
  if [ "$TARGET_BACKEND" = remote ]; then
    FM_SEND_REMOTE_BUDGET=${FM_SEND_REMOTE_BUDGET:-30}
    case "$FM_SEND_REMOTE_BUDGET" in
      ''|*[!0-9]*|0)
        echo "error: FM_SEND_REMOTE_BUDGET must be a positive integer: $FM_SEND_REMOTE_BUDGET" >&2
        exit 1
        ;;
    esac
    if ! fm_run_timed "$FM_SEND_REMOTE_BUDGET" "$SCRIPT_DIR/fm-on.sh" "$TARGET_REMOTE_ID" \
      fm-remote-secondmate-control.sh key "$TARGET_REMOTE_ID" "$key" < /dev/null; then
      echo "error: key '$key' not sent to remote secondmate $TARGET_REMOTE_ID; completion may be unknown" >&2
      exit 1
    fi
  elif ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$key" "$EXPECTED_LABEL"; then
    echo "error: key '$key' not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  fm_send_clear_after_interrupt "$semantic_key" || exit 1
  fm_send_record_interrupt "$semantic_key" || exit 1
else
  MESSAGE=$*
  if [ "$TARGET_BACKEND" = remote ]; then
    FM_SEND_REMOTE_BUDGET=${FM_SEND_REMOTE_BUDGET:-30}
    case "$FM_SEND_REMOTE_BUDGET" in
      ''|*[!0-9]*|0)
        echo "error: FM_SEND_REMOTE_BUDGET must be a positive integer: $FM_SEND_REMOTE_BUDGET" >&2
        exit 1
        ;;
    esac
  fi
  # The pre-marker answer text, kept for the closing resolved note so the
  # durable ledger records the plain answer without marker or corr bytes.
  RESOLVE_ANSWER_TEXT=$MESSAGE
  if [ "$MARK_FROM_FIRSTMATE" = 1 ] && [ -n "$FIRE_AND_FORGET_ID" ]; then
    fm_message_mark_from_firstmate "$MESSAGE" MESSAGE
    MESSAGE="${FM_FROMFIRST_MARK}delivery=${FIRE_AND_FORGET_ID} ${MESSAGE#"$FM_FROMFIRST_MARK"}"
    FM_SEND_IDEMPOTENT=1
  elif [ "$MARK_FROM_FIRSTMATE" = 1 ]; then
    # Reuse an existing correlation id for recovery resends; otherwise create a
    # durable parent expectation before delivery. Transport success never
    # resolves that expectation (see fm-pending-reply-lib.sh).
    existing_corr_explicit=0
    if [ "${FM_PENDING_REPLY_EXISTING_CORR+x}" = x ]; then
      existing_corr_explicit=1
      existing_corr=$FM_PENDING_REPLY_EXISTING_CORR
    else
      existing_corr=$(fm_pending_reply_extract_corr "$MESSAGE")
    fi
    if [ -n "$existing_corr" ] \
      && fm_pending_reply_corr_reusable "$STATE" "$existing_corr" "$TARGET_TASK_ID"; then
      PENDING_REPLY_CORR=$existing_corr
    else
      if [ "$existing_corr_explicit" = 1 ]; then
        echo "error: explicitly requested pending-reply correlation '${existing_corr:-empty}' is not reusable for $TARGET_TASK_ID; refusing to mint a replacement correlation" >&2
        exit 1
      fi
      if [ -z "$TARGET_TASK_ID" ]; then
        echo "error: cannot create pending-reply expectation without a resolvable secondmate task id" >&2
        exit 1
      fi
      PENDING_REPLY_CORR=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$TARGET_TASK_ID" "$MESSAGE") \
        || { echo "error: failed to create parent pending-reply expectation for $TARGET_TASK_ID" >&2; exit 1; }
      PENDING_REPLY_CREATED=1
    fi
    fm_pending_reply_embed_corr "$MESSAGE" "$PENDING_REPLY_CORR" MESSAGE
    if [ "$PENDING_REPLY_CREATED" != 1 ] \
      && fm_pending_reply_delivery_attempt_unresolved "$STATE" "$PENDING_REPLY_CORR"; then
      if [ "$TARGET_BACKEND" = remote ]; then
        if ! fm_pending_reply_reset_known_undelivered "$STATE" "$PENDING_REPLY_CORR"; then
          echo "error: pending-reply delivery for $TARGET_TASK_ID could not be reset for an idempotent remote resend of correlation $PENDING_REPLY_CORR" >&2
          exit 1
        fi
      else
        echo "error: pending-reply delivery for $TARGET_TASK_ID is unresolved; refusing to resend correlation $PENDING_REPLY_CORR" >&2
        exit 1
      fi
    fi
    if ! fm_pending_reply_prepare_delivery "$STATE" "$PENDING_REPLY_CORR"; then
      [ "$PENDING_REPLY_CREATED" != 1 ] \
        || fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      echo "error: failed to durably prepare pending-reply delivery for $TARGET_TASK_ID" >&2
      exit 1
    fi
  fi
  # Data-plane selection (see the header): text addressed to a task selector
  # resolved through this home's metadata rides the inbox plane, unless it is
  # a LOCAL harness-native invocation that must reach the harness's own parser
  # - a leading "/" (slash command), or a leading "$" to a codex target (skill
  # invocation). A remote secondmate selector always rides the inbox: its
  # requests are marked, and a marked request reaches the harness as
  # marker-prefixed chat rather than a parser command anyway, so no remote
  # text has a typed plane to lose. An explicit backend target stays typed
  # even when it happens to match local metadata: it names an endpoint, not a
  # task, the same boundary that keeps it unmarked and outside --resolve-key.
  # Classification reads the pre-marker text so a marked secondmate request
  # and a plain crewmate steer classify identically. It deliberately does NOT
  # promise that a marked parser-native secondmate request executes as a parser
  # command: the pre-existing marker-first wire bytes are retained in stage 1.
  INBOX_PLANE=0
  if [ -n "$TARGET_SELECTOR" ]; then
    if [ -n "$FIRE_AND_FORGET_ID" ] || [ "$TARGET_BACKEND" = remote ]; then
      INBOX_PLANE=1
    else
      case "$RESOLVE_ANSWER_TEXT" in
        /*) ;;
        \$*) [ "$TARGET_HARNESS" = codex ] || INBOX_PLANE=1 ;;
        *) INBOX_PLANE=1 ;;
      esac
    fi
  fi
  if [ "$INBOX_PLANE" = 1 ] && [ "$TARGET_BACKEND" = remote ]; then
    # Remote inbox leg: the message becomes a durable record in the remote
    # home's steering inbox, written idempotently by the host-local leg, then
    # the remote doorbell rings, best-effort. One identical retry after ssh
    # 255 is safe by that idempotence; a still-lost transport preserves a
    # reply-bearing request's expectation, while fire-and-forget reports the
    # delivery id that must be reused, because the record may have landed.
    # Every transport attempt is bounded by FM_SEND_REMOTE_BUDGET seconds
    # (default 30, overridable) so a busy remote queue cannot hold this send
    # open indefinitely; a bound hit exits through the same
    # unconfirmed-delivery contract.
    REMOTE_META_LOCK=$(fm_meta_lock_path "$TARGET_META") || exit 1
    if ! fm_task_inbox_lock_acquire "$REMOTE_META_LOCK"; then
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: steer not sent to remote secondmate $TARGET_REMOTE_ID: its parent task metadata could not be locked for final delivery validation" >&2
      exit 1
    fi
    CURRENT_REMOTE_ID=
    CURRENT_REMOTE_HOST=
    CURRENT_REMOTE_SPAWN_GEN=
    if [ -f "$TARGET_META" ]; then
      CURRENT_REMOTE_ID=$(fm_send_id_from_meta "$TARGET_META")
      CURRENT_REMOTE_HOST=$(fm_meta_get "$TARGET_META" remote_host)
      CURRENT_REMOTE_SPAWN_GEN=$(fm_meta_get "$TARGET_META" spawn_gen)
    fi
    if [ "$CURRENT_REMOTE_ID" != "$TARGET_REMOTE_ID" ] \
      || { [ -n "${FM_SEND_EXPECTED_SPAWN_GEN:-}" ] \
        && [ "$CURRENT_REMOTE_SPAWN_GEN" != "$FM_SEND_EXPECTED_SPAWN_GEN" ]; } \
      || { [ -n "${FM_SEND_EXPECTED_REMOTE_HOST:-}" ] \
        && [ "$CURRENT_REMOTE_HOST" != "$FM_SEND_EXPECTED_REMOTE_HOST" ]; } \
      || [ -z "$CURRENT_REMOTE_HOST" ] \
      || [ "$CURRENT_REMOTE_HOST" != "$TARGET_REMOTE_HOST" ]; then
      fm_lock_release "$REMOTE_META_LOCK"
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: steer not sent to remote secondmate $TARGET_REMOTE_ID: its parent task retired or changed route during target resolution" >&2
      exit 1
    fi
    remote_rc=0
    remote_completion_unknown=0
    REMOTE_SEND_ARGS=("$TARGET_REMOTE_ID" "$MESSAGE")
    [ -z "$FIRE_AND_FORGET_ID" ] || REMOTE_SEND_ARGS+=(fire-and-forget)
    # Each transport attempt is bounded by FM_SEND_REMOTE_BUDGET seconds.
    # fm_run_timed's 124 means the attempt was killed at the bound with remote
    # completion unknown - the enqueue may have landed - so it exits through
    # the same unconfirmed-delivery contract as a lost transport, without a
    # retry that would only wait out the same busy remote queue again. (A
    # remote job's own timeout also relays as 124; treating it as unconfirmed
    # stays safe because the remote enqueue deduplicates.)
    fm_run_timed "$FM_SEND_REMOTE_BUDGET" "$SCRIPT_DIR/fm-on.sh" "$TARGET_REMOTE_ID" \
      fm-remote-secondmate-control.sh send "${REMOTE_SEND_ARGS[@]}" < /dev/null || remote_rc=$?
    if [ "$remote_rc" -eq 124 ]; then
      remote_completion_unknown=1
    elif [ "$remote_rc" -eq 255 ]; then
      remote_completion_unknown=1
      remote_rc=0
      fm_run_timed "$FM_SEND_REMOTE_BUDGET" "$SCRIPT_DIR/fm-on.sh" "$TARGET_REMOTE_ID" \
        fm-remote-secondmate-control.sh send "${REMOTE_SEND_ARGS[@]}" < /dev/null || remote_rc=$?
    fi
    fm_lock_release "$REMOTE_META_LOCK"
    if [ "$remote_rc" -ne 0 ] && [ "$remote_completion_unknown" -eq 1 ]; then
      if [ -n "$FIRE_AND_FORGET_ID" ]; then
        echo "error: fire-and-forget steer to remote secondmate $TARGET_REMOTE_ID is unconfirmed (delivery-id=$FIRE_AND_FORGET_ID); retry only with the same delivery id" >&2
        exit 3
      fi
      if [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_mark_delivery_unknown "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      if [ "$remote_rc" -eq 255 ]; then
        echo "error: steer to remote secondmate $TARGET_REMOTE_ID is unconfirmed (transport lost twice; remote completion unknown). Only the correlation-reusing resend below is idempotent and lands on the same remote inbox record:" >&2
      elif [ "$remote_rc" -eq 124 ]; then
        echo "error: steer to remote secondmate $TARGET_REMOTE_ID is unconfirmed (the remote transport did not complete within its ${FM_SEND_REMOTE_BUDGET}s budget; remote completion unknown). Only the correlation-reusing resend below is idempotent and lands on the same remote inbox record:" >&2
      else
        echo "error: steer to remote secondmate $TARGET_REMOTE_ID is unconfirmed (the first transport attempt had unknown completion and the retry failed). Only the correlation-reusing resend below is idempotent and lands on the same remote inbox record:" >&2
      fi
      resend_home=$(cd "$FM_HOME" 2>/dev/null && pwd) || resend_home=$FM_HOME
      printf 'FM_HOME=%q ' "$resend_home" >&2
      if [ "${FM_STATE_OVERRIDE+x}" = x ]; then
        resend_state=$(cd "$STATE" 2>/dev/null && pwd) || resend_state=$STATE
        printf 'FM_STATE_OVERRIDE=%q ' "$resend_state" >&2
      fi
      printf 'FM_PENDING_REPLY_EXISTING_CORR=%q %q' "$PENDING_REPLY_CORR" "$SCRIPT_DIR/fm-send.sh" >&2
      for resend_arg in "${FM_SEND_ORIGINAL_ARGS[@]}"; do
        printf ' %q' "$resend_arg" >&2
      done
      printf '\n' >&2
      exit 1
    fi
    if [ "$remote_rc" -ne 0 ]; then
      fm_send_known_undelivered_cleanup || \
        echo "error: known-undelivered pending-reply state could not be reset for $TARGET_TASK_ID" >&2
      echo "error: steer not sent to remote secondmate $TARGET_REMOTE_ID (the remote steering-inbox record could not be written; the remote leg's stderr above has the reason)" >&2
      exit 1
    fi
    # The remote record is durable delivery, exactly as a local enqueue is.
    if [ -n "$PENDING_REPLY_CORR" ]; then
      if fm_pending_reply_confirm_delivery "$STATE" "$PENDING_REPLY_CORR"; then
        :
      else
        delivery_commit_status=$?
        if [ "$delivery_commit_status" = 2 ]; then
          echo "notice: the steer was durably recorded in the remote inbox, but its pending-reply delivery commit failed; a durable recovery marker was stored and the watcher will reconcile it. Do not resend." >&2
        else
          echo "warning: reply-tracking-degraded (steer delivered, do not resend): the steer was durably recorded in the remote inbox, but its pending-reply delivery commit and recovery marker both failed, so the reply expectation for this request may not reconcile on its own. Inspect $STATE." >&2
        fi
      fi
    fi
    if [ -n "$RESOLVE_KEYS" ]; then
      fm_send_close_resolved_keys "$RESOLVE_ANSWER_TEXT" || exit 1
      fm_send_feed_resolved_holds "$RESOLVE_ANSWER_TEXT" || exit 1
    fi
    exit 0
  fi
  if [ "$INBOX_PLANE" = 1 ]; then
    INBOX_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
    INBOX_META_LOCK=$(fm_meta_lock_path "$TARGET_META") || exit 1
    if ! fm_task_inbox_lock_acquire "$INBOX_META_LOCK"; then
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: steer not sent to $INBOX_TASK_ID: its task metadata could not be locked for final delivery validation" >&2
      exit 1
    fi
    CURRENT_INBOX_TARGET=
    CURRENT_INBOX_BACKEND=
    CURRENT_INBOX_SPAWN_GEN=
    if [ -f "$TARGET_META" ]; then
      CURRENT_INBOX_TARGET=$(fm_backend_target_of_meta "$TARGET_META")
      CURRENT_INBOX_BACKEND=$(fm_backend_of_meta "$TARGET_META")
      CURRENT_INBOX_SPAWN_GEN=$(fm_meta_get "$TARGET_META" spawn_gen)
    fi
    if [ "$CURRENT_INBOX_TARGET" != "$T" ] \
      || [ "$CURRENT_INBOX_BACKEND" != "$TARGET_BACKEND" ] \
      || { [ -n "${FM_SEND_EXPECTED_SPAWN_GEN:-}" ] \
        && [ "$CURRENT_INBOX_SPAWN_GEN" != "$FM_SEND_EXPECTED_SPAWN_GEN" ]; } \
      || [ -n "$(fm_meta_get "$TARGET_META" remote_host)" ]; then
      fm_lock_release "$INBOX_META_LOCK"
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: steer not sent to $INBOX_TASK_ID: the task retired or changed endpoint during target resolution" >&2
      exit 1
    fi
    if [ "${FM_SEND_IDEMPOTENT:-0}" = 1 ]; then
      INBOX_RECORD=$(fm_task_inbox_write_idempotent "$STATE" "$INBOX_TASK_ID" "$MESSAGE" \
        "${FIRE_AND_FORGET_ID:+fire-and-forget}") || inbox_write_rc=$?
    else
      INBOX_RECORD=$(fm_task_inbox_write "$STATE" "$INBOX_TASK_ID" "$MESSAGE" \
        "${FIRE_AND_FORGET_ID:+fire-and-forget}") || inbox_write_rc=$?
    fi
    if [ "${inbox_write_rc:-0}" -ne 0 ]; then
      fm_lock_release "$INBOX_META_LOCK"
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: steer not sent to $INBOX_TASK_ID: its inbox record could not be written under $STATE/$INBOX_TASK_ID.inbox" >&2
      exit 1
    fi
    fm_lock_release "$INBOX_META_LOCK"
    # Enqueue IS durable delivery to the task's record: mark the pending
    # expectation delivered now, without resolving it - only a correlated
    # parent report acknowledges the request.
    if [ -n "$PENDING_REPLY_CORR" ]; then
      if fm_pending_reply_confirm_delivery "$STATE" "$PENDING_REPLY_CORR"; then
        :
      else
        delivery_commit_status=$?
        if [ "$delivery_commit_status" = 2 ]; then
          echo "notice: the steer was recorded at $INBOX_RECORD, but its pending-reply delivery commit failed; a durable recovery marker was stored and the watcher will reconcile it. Do not resend." >&2
        else
          # Both the commit and its recovery marker failed. The durable inbox
          # record is what delivers the steer, so the send still SUCCEEDED:
          # a nonzero here would read as undelivered to every automated caller
          # and invite a duplicate enqueue - the exact defect this plane
          # removes. Surface the degradation as its own distinct,
          # non-resend-inviting condition instead: reply tracking for this
          # request may not resolve or escalate on its own until an operator
          # inspects it.
          echo "warning: reply-tracking-degraded (steer delivered, do not resend): the steer was durably recorded at $INBOX_RECORD, but its pending-reply delivery commit and recovery marker both failed, so the reply expectation for this request may not reconcile on its own. Inspect $STATE." >&2
        fi
      fi
    fi
    # The answer is durably sent: close each answered decision at enqueue time
    # (answerer-closes; see the header contract).
    if [ -n "$RESOLVE_KEYS" ]; then
      fm_send_close_resolved_keys "$RESOLVE_ANSWER_TEXT" || exit 1
      fm_send_feed_resolved_holds "$RESOLVE_ANSWER_TEXT" || exit 1
    fi
    # Ring the doorbell, best-effort: no ring outcome changes the exit status,
    # because the watcher's re-ring ladder owns loss detection from here.
    ring_rc=0
    fm_task_inbox_ring "$TARGET_BACKEND" "$T" "$INBOX_RECORD" "$EXPECTED_LABEL" || ring_rc=$?
    case "$ring_rc" in
      1) echo "fm-send: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at $INBOX_RECORD and the watcher will re-ring" >&2 ;;
      2) echo "fm-send: doorbell did not reach $T; the steer is durably recorded at $INBOX_RECORD and the watcher will re-ring" >&2 ;;
      3) echo "fm-send: doorbell not typed because the agent in $T has exited; the steer is durably recorded at $INBOX_RECORD for recovery (stuck-crewmate-recovery), and the watcher will not re-ring a dead pane" >&2 ;;
    esac
    exit 0
  fi
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing, so give the popup time to settle before
  # the (retried) Enter. Codex opens the same kind of popup for a `$<skill>`
  # invocation, so a `$...` message to a codex target gets the same settle. That
  # `$` case is scoped to codex on purpose: unlike `/`, a leading `$` commonly
  # starts ordinary text ("$5/month", "$HOME"), so a universal `$` rule would
  # needlessly slow plain text to claude/opencode/pi. The target backend's
  # verified submit retry still backs the settle up either way.
  case "$*" in
    /*) settle=1.2 ;;
    \$*)
      if [ "$TARGET_HARNESS" = codex ]; then settle=1.2; else settle=0.3; fi
      ;;
    *) settle=0.3 ;;
  esac
  retries=${FM_SEND_RETRIES:-3}
  sleep_s=${FM_SEND_SLEEP:-0.4}
  # Type once, submit, verify. Only exact empty confirms delivery; every other
  # verdict preserves the loud refusal boundary. Only LOCAL targets reach this
  # block: remote text rides the inbox leg above, and remote --key exits
  # earlier.
  send_rc=0
  if verdict=$(fm_backend_send_text_submit "$TARGET_BACKEND" "$T" "$MESSAGE" "$retries" "$sleep_s" "$settle" "$EXPECTED_LABEL"); then
    :
  else
    send_rc=$?
  fi
  if [ "$send_rc" -ne 0 ]; then
    fm_send_known_undelivered_cleanup || \
      echo "error: known-undelivered pending-reply state could not be reset for $TARGET_TASK_ID" >&2
    echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  case "$verdict" in
    empty)
      ;;
    send-failed)
      fm_send_known_undelivered_cleanup || \
        echo "error: known-undelivered pending-reply state could not be reset for $TARGET_TASK_ID" >&2
      echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
    pending)
      # The text was typed into the live target and Enter was sent; only the
      # submit read-back stayed unconfirmed (e.g. a busy harness queues the
      # steer and keeps rendering it). That is not a proven failure, so never
      # re-type the message: verify the pane instead. Exit 3 is the documented
      # delivered-unconfirmed status.
      # The pending-reply expectation is deliberately NOT discarded here:
      # dropping it would silently stop tracking a marked request that very
      # likely landed. It stays armed on its unconfirmed-delivery marker, so a
      # correlated report still resolves it and an unanswered one still
      # surfaces through the library's own reconciliation
      # (bin/fm-pending-reply-lib.sh).
      echo "fm-send: text delivered to $T but submission is unconfirmed (verdict=pending; tried $RESOLUTION_TRIED); do not retype or blindly resend - verify with fm-peek.sh, then re-send '--key Enter' only if the composer still holds the text" >&2
      exit 3
      ;;
    *)
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: text not submitted to $T (delivery unconfirmed; verdict=${verdict:-unknown}; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
  esac
  # Delivery confirmed. Mark the pending expectation delivered without resolving
  # it: only a correlated parent report acknowledges the request.
  if [ -n "$PENDING_REPLY_CORR" ]; then
    if fm_pending_reply_confirm_delivery "$STATE" "$PENDING_REPLY_CORR"; then
      :
    else
      delivery_commit_status=$?
      if [ "$delivery_commit_status" = 2 ]; then
        echo "error: text was delivered to $T, but its pending-reply delivery commit failed; a durable recovery marker was stored and the watcher will reconcile it. Do not resend." >&2
      else
        echo "error: text was delivered to $T, but its pending-reply delivery commit and recovery marker both failed. Do not resend; inspect $STATE manually." >&2
      fi
      exit 1
    fi
  fi
  # Delivery is fully confirmed: close each answered decision in this home's
  # ledger (answerer-closes; see the header contract).
  if [ -n "$RESOLVE_KEYS" ]; then
    fm_send_close_resolved_keys "$RESOLVE_ANSWER_TEXT" || exit 1
    fm_send_feed_resolved_holds "$RESOLVE_ANSWER_TEXT" || exit 1
  fi
  # Submit landed with exact empty. Confirmation only proves the text was
  # accepted; the harness still needs a beat to spin up the
  # turn before its busy footer shows. Pause so an immediate peek catches the
  # crewmate actually working instead of the stale idle pane. FM_SEND_SETTLE=0
  # disables it. Scoped to this path only, never the shared submit core.
  [ "${FM_SEND_SETTLE:-1}" = 0 ] || sleep "${FM_SEND_SETTLE:-1}"
fi
