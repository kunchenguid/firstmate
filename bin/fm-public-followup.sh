#!/usr/bin/env bash
# fm-public-followup.sh - the deterministic consumer and delivery owner for
# public commitments made through the myfirstmate relay (X and Discord).
#
# THE PROBLEM THIS SOLVES: firstmate promises a public final reply, routes the
# work out, and then the conversation compacts or the session restarts. Nothing
# in memory survives, so the promise is only kept if reconciling it is a disk
# operation. Every command here reads durable state and nothing else.
#
# OWNERSHIP BOUNDARIES (do not re-implement any of these here):
#   tasks-axi public-followup   the typed obligation and its state machine.
#   state/x-context/            the private full request context (fm-x-lib.sh).
#   bin/fm-x-reply.sh           posting to the relay, thread splitting, dry run.
#   bin/fm-public-followup-lib.sh  the activation gate and private transport.
# This script composes them; it never restates their contracts or schemas.
#
# ZERO OVERHEAD FOR HOMES THAT DO NOT USE THE RELAY: every subcommand gates
# first on the authoritative activation contract (a non-empty FMX_PAIRING_TOKEN
# in $FM_HOME/.env). Read-side and cleanup paths then use an O(1) presence check
# for registrations this home actually created. A relay-disabled home therefore
# runs one [ -f ] test before any backlog work: no tasks-axi call, no backlog scan,
# and no file created. Silent read-side commands return without output; commands
# that require an active relay report their configuration error after the same
# gate. A relay-enabled home with no live commitments stops at the second gate
# for the same cost.
#
# Usage:
#   fm-public-followup.sh active
#       Silent gate probe. Exit 0 when this home has live public-followup work
#       worth looking at, 1 otherwise. Safe to call unconditionally.
#
#   fm-public-followup.sh register <obligation-id> --relation <relation-id>
#         --work-home <main|secondmate:<id>> --work-id <task-id> --generation <n>
#         [--platform <x|discord>] [--request <request-id>]
#       Record the binding the relay path just created with `tasks-axi
#       public-followup add` + `bind-work`. This is the event-driven
#       registration: it creates this home's private public-followup directories
#       (0700) and the bounded public-safe registration record, which is what
#       later makes the presence checks O(1) and lets bound work report a typed
#       terminal result. Refuses when the relay is not active for this home.
#
#   fm-public-followup.sh brief <obligation-id>
#       Print the exact fm-public-followup-emit.sh command line the bound worker
#       must run when its work reaches the promised terminal outcome, so the
#       binding is copied into a brief instead of hand-assembled.
#
#   fm-public-followup.sh consume
#       Drain every pending typed terminal event: validate its derived identity,
#       skip anything already accepted, apply `tasks-axi public-followup
#       work-event`, and quarantine what tasks-axi refuses. Prints one
#       "ready <obligation-id> <request-id> <platform>" line per obligation that
#       became delivery-ready, and one "rejected <event-id>: <reason>" line per
#       refusal. Silent when there is nothing to do. Duplicate events and restart
#       replay are no-ops.
#
#   fm-public-followup.sh pending
#       One bounded public-safe line per unresolved commitment, for the session
#       start digest. Prunes registrations whose obligation is already closed.
#       Silent when nothing is unresolved.
#
#   fm-public-followup.sh deliver <obligation-id> [--text-file <path>]
#       Post the final public reply into the ORIGINAL thread and close the
#       obligation. Uses the stored platform and opaque context binding, so the
#       destination is never guessed. Without --text-file the accepted terminal
#       event's bounded public-safe outcome is reused exactly, which keeps the
#       common path deterministic. The sequence is begin-delivery with the
#       payload hash, post, then record the posted receipt or a typed error.
#       A validated receipt also clears any bound legacy X link before the
#       registration is removed.
#       An already-posted obligation is an idempotent success without another
#       post; an obligation left in delivery-posting by a crash is REFUSED
#       rather than posted again.
#
#   fm-public-followup.sh record-posted <obligation-id> --attempt <n> --chunks <n>
#       Close an obligation whose post is known to have landed on exactly
#       attempt <n> with exactly <n> messages, without posting anything. This is
#       the late-receipt path: use it when a post succeeded but its receipt was
#       lost, never to paper over an unknown outcome.
#
#   fm-public-followup.sh guard-work <work-home-id> <work-id>
#       Exit 3 when this home has an unresolved public commitment bound to that
#       exact work, printing one line per blocking obligation. Exit 0 otherwise.
#       Cleanup paths call this so bound work is never treated as finished while
#       its public promise is still open.
#
#   fm-public-followup.sh retire <obligation-id> [--force]
#       Drop the registration once its obligation is closed. --force is the
#       explicit discard-approved escape hatch for an unresolved or missing
#       obligation.
#
# Requires jq and a compatible tasks-axi for registration, reconciliation,
# delivery, cleanup guards, and retirement; `active` and `brief` only inspect
# local state.
# FM_PF_RETRY_BACKOFF_SECS (default 900) sets the next-attempt time recorded with
# a retryable delivery error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

RETRY_BACKOFF=${FM_PF_RETRY_BACKOFF_SECS:-900}
case "$RETRY_BACKOFF" in ''|*[!0-9]*) RETRY_BACKOFF=900 ;; esac

usage() {
  echo "usage: fm-public-followup.sh <active|register|brief|consume|pending|deliver|record-posted|guard-work|retire> [args]" >&2
}

# The header comment IS the help text, so the two can never drift apart.
help() { sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

die() { printf 'fm-public-followup: %s\n' "$1" >&2; exit "${2:-2}"; }

PF_TEMP_FILES=()
pf_cleanup_temp_files() {
  [ "${#PF_TEMP_FILES[@]}" -eq 0 ] || rm -f -- "${PF_TEMP_FILES[@]}"
}
trap pf_cleanup_temp_files EXIT

now_rfc3339() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# next_attempt_rfc3339: the retry time recorded with a retryable delivery error.
# BSD and GNU date disagree on the flag, so try both and print nothing when
# neither works - the error is still recorded, just without a retry time.
next_attempt_rfc3339() {
  local at
  at=$(( $(date +%s) + RETRY_BACKOFF ))
  date -u -r "$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || true
}

require_tools() {
  command -v jq >/dev/null 2>&1 || die "jq is required" 1
  command -v tasks-axi >/dev/null 2>&1 || die "tasks-axi is required" 1
}

# Every tasks-axi call runs from the home whose backlog owns the obligation, the
# same convention bin/fm-decision-hold.sh uses for typed backlog state.
tx() { (cd "$FM_HOME" && tasks-axi "$@"); }

# obligation_json <id>: the complete typed obligation payload on stdout, empty
# when the backlog simply has no such public-followup item, and a non-zero exit
# ONLY when the backlog could not be read at all. Callers depend on that
# distinction to report the right thing, so jq runs without -e here. tasks-axi
# stays the single source of truth; the registration record is never consulted
# for state.
obligation_json() {
  local id=$1 out
  out=$(tx public-followup list --json 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | jq -c --arg id "$id" \
    '(.public_followups // []) | map(select(.id == $id)) | .[0] // empty' 2>/dev/null \
    || return 1
}

pf_field() { printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null; }

# --- gates ------------------------------------------------------------------

# gate_or_exit: the shared silent gate for every read-side subcommand. Exits 0
# with no output when this home has no public-followup work, so callers can
# invoke unconditionally without a relay-disabled home paying anything.
gate_or_exit() {
  fm_pf_relay_active "$FM_HOME" || exit 0
  fm_pf_has_registrations "$STATE" || fm_pf_has_events "$STATE" || exit 0
}

# --- subcommand: active -----------------------------------------------------

cmd_active() {
  fm_pf_relay_active "$FM_HOME" || exit 1
  fm_pf_has_registrations "$STATE" || fm_pf_has_events "$STATE" || exit 1
  exit 0
}

# --- subcommand: register ---------------------------------------------------

cmd_register() {
  local id=${1:-}
  local relation='' work_home='' work_id='' generation='' platform='' request=''
  [ -n "$id" ] || { usage; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --relation)   shift; relation=${1:-} ;;
      --work-home)  shift; work_home=${1:-} ;;
      --work-id)    shift; work_id=${1:-} ;;
      --generation) shift; generation=${1:-} ;;
      --platform)   shift; platform=${1:-} ;;
      --request)    shift; request=${1:-} ;;
      *) die "unknown argument '$1'" ;;
    esac
    shift || true
  done

  fm_pf_relay_active "$FM_HOME" \
    || die "this home has not opted into the myfirstmate relay, so it cannot own a public commitment" 1
  require_tools

  fm_pf_slug_valid "$id"       || die "unsafe obligation id: $id"
  fm_pf_slug_valid "$relation" || die "unsafe relation id: $relation"
  fm_pf_slug_valid "$work_id"  || die "unsafe work id: $work_id"
  fm_pf_home_id_valid "$work_home" \
    || die "work home must be 'main' or 'secondmate:<stable-id>', got '$work_home'"
  case "$generation" in
    ''|*[!0-9]*) die "generation must be a positive integer, got '$generation'" ;;
  esac
  [ "$generation" -ge 1 ] || die "generation must be >= 1"

  local payload
  payload=$(obligation_json "$id") \
    || die "could not read the backlog through tasks-axi" 1
  [ -n "$payload" ] \
    || die "no public-followup obligation '$id' in this home's backlog; create it with tasks-axi public-followup add before registering" 1

  # The relation must already be bound, so a registration can never describe a
  # binding tasks-axi does not have.
  printf '%s' "$payload" | jq -e --arg r "$relation" --arg h "$work_home" --arg w "$work_id" \
    '(.public_followup.work_relations // [])
       | map(select(.relation_id == $r and .work_ref.home_id == $h and .work_ref.task_id == $w))
       | length > 0' >/dev/null 2>&1 \
    || die "obligation '$id' has no bound relation '$relation' for $work_home/$work_id; run tasks-axi public-followup bind-work first" 1

  [ -n "$platform" ] || platform=$(pf_field "$payload" '.public_followup.request.platform')
  [ -n "$request" ] || request=$(pf_field "$payload" '.public_followup.request.request_id')
  [ -z "$request" ] || fm_pf_slug_valid "$request" || die "unsafe request id: $request"

  local mkdir_target
  for mkdir_target in "$(fm_pf_registry_dir "$STATE")" "$(fm_pf_events_dir "$STATE")" \
                      "$(fm_pf_consumed_dir "$STATE")" "$(fm_pf_rejected_dir "$STATE")"; do
    fmx_private_artifact_dir_prepare "$mkdir_target" >/dev/null \
      || die "could not prepare $mkdir_target" 1
  done

  printf 'obligation_id=%s\nrelation_id=%s\nwork_home=%s\nwork_id=%s\ngeneration=%s\nplatform=%s\nrequest_id=%s\n' \
    "$id" "$relation" "$work_home" "$work_id" "$generation" "$platform" "$request" \
    | fmx_private_artifact_publish_stdin "$(fm_pf_registry_dir "$STATE")" "$id" 600 \
    || die "could not write the registration record" 1

  printf 'registered %s %s/%s generation=%s platform=%s\n' \
    "$id" "$work_home" "$work_id" "$generation" "${platform:-unknown}"
}

# --- subcommand: brief ------------------------------------------------------

cmd_brief() {
  local id=${1:-} relation work_home work_id generation
  [ -n "$id" ] || { usage; exit 2; }
  fm_pf_slug_valid "$id" || die "unsafe obligation id: $id"
  fm_pf_relay_active "$FM_HOME" || die "the relay is not active for this home" 1
  [ -f "$(fm_pf_registry_dir "$STATE")/$id" ] \
    || die "no registration for '$id' in this home" 1

  relation=$(fm_pf_registry_get "$STATE" "$id" relation_id)
  work_home=$(fm_pf_registry_get "$STATE" "$id" work_home)
  work_id=$(fm_pf_registry_get "$STATE" "$id" work_id)
  generation=$(fm_pf_registry_get "$STATE" "$id" generation)

  cat <<EOF
When this work reaches its promised terminal outcome, report it as typed data
(never as a sentence for someone to parse) by running exactly:

  $FM_ROOT/bin/fm-public-followup-emit.sh \\
    --home $FM_HOME \\
    --obligation $id \\
    --relation $relation \\
    --source-home $work_home \\
    --work-id $work_id \\
    --generation $generation \\
    --outcome <pr-merged|report-ready|local-main|failed> \\
    --deliverable <key>=<value> \\
    --outcome-text '<one bounded public-safe sentence>'

Do not post anything publicly yourself and do not look for the public thread:
the home above owns the reply.
EOF
}

# --- subcommand: consume ----------------------------------------------------

# reject_event <file> <event-id> <reason>: quarantine one refused event with an
# inspectable reason so it is never retried in a loop.
reject_event() {
  local file=$1 event_id=$2 reason=$3 rejected event_payload
  rejected=$(fm_pf_rejected_dir "$STATE")
  fmx_private_artifact_dir_prepare "$rejected" >/dev/null \
    || { printf 'rejected %s: %s (quarantine failed; event retained)\n' "$event_id" "$reason"; return 1; }
  if ! printf '%s\n' "$reason" \
      | fmx_private_artifact_publish_stdin "$rejected" "$event_id.reason" 600 2>/dev/null; then
    printf 'rejected %s: %s (quarantine failed; event retained)\n' "$event_id" "$reason"
    return 1
  fi
  if ! event_payload=$(cat "$file" 2>/dev/null); then
    printf 'rejected %s: %s (quarantine failed; event retained)\n' "$event_id" "$reason"
    return 1
  fi
  if ! printf '%s' "$event_payload" \
      | fmx_private_artifact_publish_stdin "$rejected" "$event_id.json" 600 2>/dev/null; then
    printf 'rejected %s: %s (quarantine failed; event retained)\n' "$event_id" "$reason"
    return 1
  fi
  if ! rm -f -- "$file" 2>/dev/null; then
    printf 'rejected %s: %s (quarantine cleanup failed; event retained)\n' "$event_id" "$reason"
    return 1
  fi
  printf 'rejected %s: %s\n' "$event_id" "$reason"
}

cmd_consume() {
  gate_or_exit
  fm_pf_has_events "$STATE" || exit 0
  require_tools

  local events_dir consumed_dir stderr_file file event_id payload derived out rc reason consume_rc=0
  local obligation delivery request platform
  events_dir=$(fm_pf_events_dir "$STATE")
  consumed_dir=$(fm_pf_consumed_dir "$STATE")
  fmx_private_artifact_dir_prepare "$consumed_dir" >/dev/null \
    || die "could not prepare the consumed-event ledger" 1
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/fm-pf-consume.XXXXXX") \
    || die "could not stage the reconciliation log" 1
  PF_TEMP_FILES+=("$stderr_file")

  for file in "$events_dir"/*.json; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    event_id=$(basename "$file" .json)

    if ! fm_pf_slug_valid "$event_id"; then
      printf 'rejected %s: unsafe event filename (event retained)\n' "$event_id"
      consume_rc=1
      continue
    fi

    # Already accepted on an earlier pass (duplicate emit, or a replay after
    # restart): drop the copy without touching the state machine.
    if [ -f "$consumed_dir/$event_id" ]; then
      rm -f -- "$file" 2>/dev/null || true
      continue
    fi

    if [ "$(wc -c < "$file" 2>/dev/null || echo 0)" -gt "$FM_PF_EVENT_BYTES_MAX" ]; then
      reject_event "$file" "$event_id" "event exceeds $FM_PF_EVENT_BYTES_MAX bytes" || consume_rc=1
      continue
    fi

    if ! payload=$(jq -ce . "$file" 2>/dev/null) || [ -z "$payload" ]; then
      reject_event "$file" "$event_id" "event is not valid JSON" || consume_rc=1
      continue
    fi

    # The filename, the declared event_id, and the identity tuple must all agree.
    # A mismatch means the file was hand-edited or built by something other than
    # fm-public-followup-emit.sh, so it is refused before tasks-axi sees it.
    if [ "$(pf_field "$payload" '.event_id')" != "$event_id" ]; then
      reject_event "$file" "$event_id" "declared event_id does not match the filename" || consume_rc=1
      continue
    fi
    derived=$(fm_pf_event_id \
      "$(pf_field "$payload" '.obligation_id')" \
      "$(pf_field "$payload" '.relation_id')" \
      "$(pf_field "$payload" '.source_home_id')" \
      "$(pf_field "$payload" '.work_id')" \
      "$(pf_field "$payload" '.generation')" \
      "$(pf_field "$payload" '.outcome_type')" \
      "$(printf '%s' "$payload" | jq -Sc '.deliverables // {}' 2>/dev/null)")
    if [ -z "$derived" ] || [ "$derived" != "$event_id" ]; then
      reject_event "$file" "$event_id" "event id does not match its own identity fields" || consume_rc=1
      continue
    fi

    obligation=$(pf_field "$payload" '.obligation_id')
    if ! fm_pf_slug_valid "$obligation"; then
      reject_event "$file" "$event_id" "unsafe obligation id in event" || consume_rc=1
      continue
    fi

    # tasks-axi is the authority on source home, work id, generation, schema,
    # outcome, and deliverables. Anything it refuses is quarantined verbatim.
    # stderr is captured separately so a warning can never corrupt the JSON that
    # the accepted path parses.
    if out=$(tx public-followup work-event "$obligation" --event-file "$file" --json 2>"$stderr_file"); then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      reason=$( { cat "$stderr_file" 2>/dev/null; printf '%s\n' "$out"; } \
        | grep -v '^[[:space:]]*$' | head -1 | fm_pf_clean_outcome_text | fm_pf_bound_bytes 400)
      reject_event "$file" "$event_id" "${reason:-tasks-axi refused the event}" || consume_rc=1
      continue
    fi

    if ! printf 'accepted %s\n' "$(now_rfc3339)" \
        | fmx_private_artifact_publish_stdin "$consumed_dir" "$event_id" 600 2>/dev/null; then
      printf 'accepted %s: consumed ledger could not be recorded; event retained for reconciliation\n' "$event_id"
      consume_rc=1
      continue
    fi
    if ! rm -f -- "$file" 2>/dev/null; then
      printf 'accepted %s: consumed ledger recorded but event could not be removed; event retained for reconciliation\n' "$event_id"
      consume_rc=1
      continue
    fi

    delivery=$(printf '%s' "$out" | jq -r '.task.public_followup.delivery.state // empty' 2>/dev/null)
    if [ "$delivery" = ready ]; then
      request=$(printf '%s' "$out" | jq -r '.task.public_followup.request.request_id // empty' 2>/dev/null)
      platform=$(printf '%s' "$out" | jq -r '.task.public_followup.request.platform // empty' 2>/dev/null)
      printf 'ready %s %s %s\n' "$obligation" "${request:-unknown}" "${platform:-unknown}"
    fi
  done

  # A fresh event must be able to wake firstmate again, so drop the surfaced
  # signature once the inbox has been worked.
  rm -f -- "$(fm_pf_root "$STATE")/$FM_PF_SURFACED_BASENAME" 2>/dev/null || true
  return "$consume_rc"
}

# --- subcommand: pending ----------------------------------------------------

cmd_pending() {
  gate_or_exit

  local listing id payload delivery task_state summary platform request printed=0
  # An unreadable backlog with registrations present is exactly the silence this
  # whole path exists to prevent, so say so rather than printing nothing.
  if ! command -v jq >/dev/null 2>&1 || ! command -v tasks-axi >/dev/null 2>&1 \
      || ! listing=$(tx public-followup list --json 2>/dev/null) || [ -z "$listing" ] \
      || ! printf '%s' "$listing" | jq -e '
        type == "object"
        and (.public_followups | type == "array")
        and all(.public_followups[];
          type == "object"
          and (.id | type == "string")
          and (.public_followup | type == "object")
          and (.state | type == "string"))
      ' >/dev/null 2>&1; then
    if fm_pf_has_registrations "$STATE"; then
      printf 'cannot read this home'\''s public commitments through tasks-axi; %s registration(s) are still recorded under state/%s/registry\n' \
        "$(fm_pf_registry_ids "$STATE" | grep -c . || true)" "$FM_PF_DIRNAME"
      printed=1
    fi
    if fm_pf_has_events "$STATE"; then
      printf 'unconsumed terminal results are waiting; run %s/bin/fm-public-followup.sh consume\n' "$FM_ROOT"
      printed=1
    fi
    [ "$printed" -eq 1 ] || exit 0
    return 0
  fi

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    payload=$(printf '%s' "$listing" | jq -ce --arg id "$id" \
      '(.public_followups // []) | map(select(.id == $id)) | .[0] // empty' 2>/dev/null)
    if [ -z "$payload" ]; then
      # The obligation is gone from the backlog (pruned after Done): the
      # registration is stale bookkeeping, not evidence, so drop it.
      if ! clear_public_followup_link "$id"; then
        printf 'cannot clear the legacy X link for closed public commitment %s; registration retained for reconciliation\n' "$id"
        printed=1
        continue
      fi
      rm -f -- "$(fm_pf_registry_dir "$STATE")/$id" 2>/dev/null || true
      continue
    fi
    delivery=$(pf_field "$payload" '.public_followup.delivery.state')
    task_state=$(pf_field "$payload" '.state')
    if [ "$task_state" = 'done' ] || [ "$delivery" = 'posted' ] || [ "$delivery" = 'waived' ]; then
      if ! clear_public_followup_link "$id"; then
        printf 'cannot clear the legacy X link for closed public commitment %s; registration retained for reconciliation\n' "$id"
        printed=1
        continue
      fi
      rm -f -- "$(fm_pf_registry_dir "$STATE")/$id" 2>/dev/null || true
      continue
    fi
    summary=$(pf_field "$payload" '.public_followup.request.public_safe_summary' | fm_pf_clean_outcome_text)
    platform=$(pf_field "$payload" '.public_followup.request.platform')
    request=$(pf_field "$payload" '.public_followup.request.request_id')
    printf 'unresolved %s state=%s platform=%s request=%s summary=%s\n' \
      "$id" "${delivery:-unknown}" "${platform:-unknown}" "${request:-unknown}" "$summary"
    printed=1
  done <<EOF
$(fm_pf_registry_ids "$STATE")
EOF

  # Events that arrived while no agent was present are actionable on their own,
  # so surface them even when every registration currently looks settled.
  if fm_pf_has_events "$STATE"; then
    printf 'unconsumed terminal results are waiting; run %s/bin/fm-public-followup.sh consume\n' "$FM_ROOT"
    printed=1
  fi
  [ "$printed" -eq 1 ] || exit 0
}

# --- subcommand: deliver ----------------------------------------------------

public_followup_registration_valid() {
  local id=$1 file relation work_home work_id generation
  file="$(fm_pf_registry_dir "$STATE")/$id"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  relation=$(fm_pf_registry_get "$STATE" "$id" relation_id)
  work_home=$(fm_pf_registry_get "$STATE" "$id" work_home)
  work_id=$(fm_pf_registry_get "$STATE" "$id" work_id)
  generation=$(fm_pf_registry_get "$STATE" "$id" generation)
  [ -n "$relation" ] && [ -n "$work_id" ] || return 1
  fm_pf_home_id_valid "$work_home" || return 1
  fm_pf_slug_valid "$work_id" || return 1
  case "$generation" in ''|*[!0-9]*) return 1 ;; esac
}

public_followup_secondmate_home() {
  local id=$1 meta home marker
  fm_pf_home_id_valid "secondmate:$id" || return 1
  meta="$STATE/$id.meta"
  home=$(fmx_meta_get "$meta" home)
  if [ -z "$home" ] && [ -f "$DATA/secondmates.md" ] && [ ! -L "$DATA/secondmates.md" ]; then
    home=$(secondmate_registry_field "$DATA/secondmates.md" "$id" home || true)
  fi
  [ -n "$home" ] || return 1
  case "$home" in /*) ;; *) return 1 ;; esac
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || return 1
  marker=$(sed -n '1p' "$home/.fm-secondmate-home" 2>/dev/null)
  [ "$marker" = "$id" ] || return 1
  printf '%s\n' "$home"
}

clear_public_followup_link() {
  local id=$1 work_home work_id home state
  public_followup_registration_valid "$id" || return 1
  work_home=$(fm_pf_registry_get "$STATE" "$id" work_home)
  work_id=$(fm_pf_registry_get "$STATE" "$id" work_id)
  [ -n "$work_home" ] && [ -n "$work_id" ] || return 1
  case "$work_home" in
    main)
      home=$FM_HOME
      state=$STATE
      ;;
    secondmate:*)
      home=$(public_followup_secondmate_home "${work_home#secondmate:}") || return 1
      state="$home/state"
      ;;
    *) return 1 ;;
  esac
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$FM_ROOT/bin/fm-x-followup.sh" --clear "$work_id" >/dev/null
}

public_followup_legacy_link_status() {
  local payload=$1 relations work_home work_id home meta
  if ! printf '%s' "$payload" | jq -e '
    (.public_followup.work_relations | type == "array")
    and all(.public_followup.work_relations[];
      (.work_ref.home_id | type == "string")
      and (.work_ref.task_id | type == "string")
    )
  ' >/dev/null 2>&1; then
    return 2
  fi
  relations=$(printf '%s' "$payload" | jq -r '
    .public_followup.work_relations[]
    | [.work_ref.home_id, .work_ref.task_id]
    | @tsv
  ' 2>/dev/null) || return 2
  [ -n "$relations" ] || return 2
  while IFS=$'\t' read -r work_home work_id; do
    [ -n "$work_home" ] && [ -n "$work_id" ] || return 2
    case "$work_home" in
      main) home=$FM_HOME ;;
      secondmate:*) home=$(public_followup_secondmate_home "${work_home#secondmate:}") || return 2 ;;
      *) return 2 ;;
    esac
    meta="$home/state/$work_id.meta"
    [ -e "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 2
    [ -n "$(fmx_meta_get "$meta" x_request)" ] && return 0
  done <<EOF
$relations
EOF
  return 1
}

record_error() {
  local id=$1 attempt=$2 state=$3 code=$4 next=$5 tmp rc
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-pf-error.XXXXXX") || return 1
  if [ -n "$next" ]; then
    jq -n --argjson a "$attempt" --arg s "$state" --arg c "$code" \
      --arg o "$(now_rfc3339)" --arg n "$next" \
      '{state:$s, attempt_count:$a, error_code:$c, occurred_at:$o, next_attempt_at:$n}' > "$tmp"
  else
    jq -n --argjson a "$attempt" --arg s "$state" --arg c "$code" --arg o "$(now_rfc3339)" \
      '{state:$s, attempt_count:$a, error_code:$c, occurred_at:$o}' > "$tmp"
  fi
  tx public-followup record-error "$id" --error-file "$tmp" >/dev/null 2>&1
  rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

record_posted() {
  local id=$1 attempt=$2 request=$3 platform=$4 chunks=$5 tmp rc
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-pf-receipt.XXXXXX") || return 1
  jq -n --argjson a "$attempt" --arg r "$request" --arg p "$platform" \
    --argjson c "$chunks" --arg t "$(now_rfc3339)" \
    '{state:"posted", request_id:$r, platform:$p, attempt_count:$a,
      total_chunks:$c, posted_chunks:$c, posted_at:$t}' > "$tmp"
  tx public-followup record-delivery "$id" --receipt-file "$tmp" >/dev/null 2>&1
  rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

cmd_deliver() {
  local id=${1:-} text_file=
  [ -n "$id" ] || { usage; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --text-file) shift; text_file=${1:-} ;;
      *) die "unknown argument '$1'" ;;
    esac
    shift || true
  done

  fm_pf_slug_valid "$id" || die "unsafe obligation id: $id"
  fm_pf_relay_active "$FM_HOME" \
    || die "this home has not opted into the myfirstmate relay, so it cannot post a public reply" 1
  require_tools

  local payload delivery attempt request platform text tmp_text hash chunks rc receipt receipt_fields receipt_dry_run link_status
  payload=$(obligation_json "$id") || die "could not read the backlog through tasks-axi" 1
  [ -n "$payload" ] || die "no public-followup obligation '$id' in this home's backlog" 1

  delivery=$(pf_field "$payload" '.public_followup.delivery.state')
  request=$(pf_field "$payload" '.public_followup.request.request_id')
  platform=$(pf_field "$payload" '.public_followup.request.platform')
  attempt=$(pf_field "$payload" '.public_followup.delivery.attempt_count')
  case "$attempt" in ''|*[!0-9]*) attempt=0 ;; esac

  case "$delivery" in
    posted|waived)
      if public_followup_registration_valid "$id"; then
        if ! clear_public_followup_link "$id"; then
          die "obligation '$id' is already $delivery, but its legacy X link could not be cleared; the registration was retained for reconciliation" 1
        fi
      else
        link_status=1
        public_followup_legacy_link_status "$payload" || link_status=$?
        case "$link_status" in
          0) die "obligation '$id' is already $delivery, but its legacy X link cannot be cleared without a valid registration; reconcile it before any later terminal follow-up" 1 ;;
          1) ;;
          *) die "obligation '$id' is already $delivery, but its registration is missing or invalid and the legacy X link cannot be verified; reconcile it before any later terminal follow-up" 1 ;;
        esac
      fi
      rm -f -- "$(fm_pf_registry_dir "$STATE")/$id" 2>/dev/null || true
      printf 'already delivered %s state=%s\n' "$id" "$delivery"
      return 0
      ;;
    ready|retry-due|context-blocked|unknown|partial)
      public_followup_registration_valid "$id" \
        || die "public-followup registration for '$id' is missing or invalid; reconcile it before delivery so any legacy X link can be cleared" 1
      ;;
    delivery-posting)
      die "obligation '$id' is mid-delivery on attempt $attempt: a previous post was started and its outcome was never recorded. Confirm whether that post landed, then close it with 'record-posted $id --attempt $attempt --chunks <exact-count>' or reopen it for retry. Posting again here could duplicate the public reply." 1
      ;;
    pending-work)
      die "obligation '$id' is still waiting on its bound work; nothing to deliver yet" 1
      ;;
    *)
      die "obligation '$id' is in delivery state '${delivery:-unknown}', which is not deliverable" 1
      ;;
  esac

  [ -n "$request" ] || die "obligation '$id' has no relay request id; its thread binding is unusable" 1

  if [ -n "$text_file" ]; then
    [ -f "$text_file" ] || die "reply text file not found: $text_file"
    text=$(cat "$text_file")
  else
    # Deterministic default: reuse the accepted terminal event's bounded
    # public-safe outcome exactly rather than paraphrasing a landed result.
    text=$(printf '%s' "$payload" | jq -r '
      [(.public_followup.work_relations // [])[]
        | (.accepted_events // [])[]
        | .public_safe_outcome // empty] | last // empty' 2>/dev/null)
    [ -n "$text" ] \
      || die "obligation '$id' carries no accepted public-safe outcome to reuse; pass --text-file with the reply you composed" 1
  fi
  [ -n "$text" ] || die "the reply text is empty" 2

  tmp_text=$(mktemp "${TMPDIR:-/tmp}/fm-pf-text.XXXXXX") || die "could not stage the reply text" 1
  PF_TEMP_FILES+=("$tmp_text")
  receipt=$(mktemp "${TMPDIR:-/tmp}/fm-pf-postreceipt.XXXXXX") || die "could not stage the post receipt" 1
  PF_TEMP_FILES+=("$receipt")
  printf '%s' "$text" > "$tmp_text"

  hash=$(fm_pf_sha256 < "$tmp_text") || die "sha256 (shasum or sha256sum) is required" 1
  [ -n "$hash" ] || die "could not hash the reply payload" 1

  # begin-delivery is what makes a retry safe: it pins the attempt and the exact
  # payload before anything leaves the machine. The attempt is read back rather
  # than assumed, because every later receipt or error must name it exactly.
  local begun
  begun=$(tx public-followup begin-delivery "$id" --payload-hash "$hash" --json 2>/dev/null) \
    || die "tasks-axi refused to begin delivery for '$id'" 1
  attempt=$(printf '%s' "$begun" | jq -r '.task.public_followup.delivery.attempt_count // empty' 2>/dev/null)
  case "$attempt" in
    ''|*[!0-9]*) die "could not read the delivery attempt for '$id' after beginning it; nothing was posted" 1 ;;
  esac

  rc=0
  FMX_REPLY_PLATFORM="$platform" FM_HOME="$FM_HOME" \
    "$FM_ROOT/bin/fm-x-reply.sh" "$request" --followup --receipt-file "$receipt" \
    --text-file "$tmp_text" >/dev/null || rc=$?

  if [ "$rc" -eq 0 ]; then
    receipt_fields=$(jq -er --arg request "$request" '
      if type != "object" or .request_id != $request or .endpoint != "followup"
         or (.chunks | type) != "number" or (.chunks < 1) or (.chunks != (.chunks | floor))
         or (.dry_run | type) != "boolean" then error("invalid receipt")
      else [(.chunks | tostring), (.dry_run | tostring)] | @tsv end
    ' "$receipt" 2>/dev/null) \
      || die "the public reply for '$id' POSTED but its receipt is missing or invalid; inspect the relay and close it with 'record-posted $id --attempt $attempt --chunks <exact-count>' before any retry" 1
    IFS=$'\t' read -r chunks receipt_dry_run <<EOF
$receipt_fields
EOF
    if [ "$receipt_dry_run" = true ]; then
      if ! record_error "$id" "$attempt" retry-due dry_run_no_post "$(next_attempt_rfc3339)"; then
        die "dry-run for '$id' did not post and its retryable state could not be recorded; the obligation remains mid-delivery and needs explicit reconciliation before retry" 1
      fi
      die "dry-run for '$id' did not post; recorded as retryable and left the obligation open" 1
    fi
    if record_posted "$id" "$attempt" "$request" "$platform" "$chunks"; then
      if ! clear_public_followup_link "$id"; then
        die "the public reply for '$id' POSTED and its receipt was recorded, but its legacy X link could not be cleared; the registration was retained for reconciliation" 1
      fi
      rm -f -- "$(fm_pf_registry_dir "$STATE")/$id" 2>/dev/null || true
      printf 'delivered %s request=%s platform=%s chunks=%s\n' "$id" "$request" "$platform" "$chunks"
      return 0
    fi
    die "the public reply for '$id' POSTED but its receipt could not be recorded; close it with 'record-posted $id --attempt $attempt --chunks <exact-count>' before any retry, or the thread will get a second reply" 1
  fi

  case "$rc" in
    8)  if ! record_error "$id" "$attempt" context-blocked reply_context_unresolved ""; then
          die "the public reply for '$id' was not posted, and its held state could not be recorded; the obligation remains mid-delivery and needs explicit reconciliation before retry" 1
        fi
        die "held '$id': the original thread's platform or size budget could not be resolved, so nothing was posted. Retry once the request context is recoverable." 1 ;;
    9)  if ! record_error "$id" "$attempt" expired-action-required followup_binding_exhausted ""; then
          die "the relay rejected '$id', and its expired state could not be recorded; the obligation remains mid-delivery and needs explicit reconciliation before retry" 1
        fi
        die "the relay no longer accepts a follow-up for '$id' (window or cap exhausted); nothing was posted and this needs a captain decision" 1 ;;
    *)  if ! record_error "$id" "$attempt" retry-due relay_post_failed "$(next_attempt_rfc3339)"; then
          die "posting the public reply for '$id' failed, and its retryable state could not be recorded; the obligation remains mid-delivery and needs explicit reconciliation before retry" 1
        fi
        die "posting the public reply for '$id' failed (exit $rc); recorded as retryable, nothing was delivered" 1 ;;
  esac
}

# --- subcommand: record-posted ---------------------------------------------

cmd_record_posted() {
  local id=${1:-} attempt='' chunks=''
  [ -n "$id" ] || { usage; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --attempt) shift; attempt=${1:-} ;;
      --chunks)  shift; chunks=${1:-} ;;
      *) die "unknown argument '$1'" ;;
    esac
    shift || true
  done
  fm_pf_slug_valid "$id" || die "unsafe obligation id: $id"
  case "$attempt" in ''|*[!0-9]*) die "--attempt <n> is required and must be an integer" ;; esac
  case "$chunks" in ''|*[!0-9]*) die "--chunks <n> is required and must be a positive integer" ;; esac
  [ "$chunks" -ge 1 ] 2>/dev/null || die "--chunks <n> is required and must be a positive integer"
  fm_pf_relay_active "$FM_HOME" || die "the relay is not active for this home" 1
  public_followup_registration_valid "$id" \
    || die "public-followup registration for '$id' is missing or invalid; reconcile it before recording a receipt so any legacy X link can be cleared" 1
  require_tools

  local payload request platform
  payload=$(obligation_json "$id") || die "could not read the backlog through tasks-axi" 1
  [ -n "$payload" ] || die "no public-followup obligation '$id' in this home's backlog" 1
  request=$(pf_field "$payload" '.public_followup.request.request_id')
  platform=$(pf_field "$payload" '.public_followup.request.platform')

  record_posted "$id" "$attempt" "$request" "$platform" "$chunks" \
    || die "tasks-axi refused the receipt for '$id' attempt $attempt; the recorded attempt must match exactly" 1
  if ! clear_public_followup_link "$id"; then
    die "the receipt for '$id' was recorded, but its legacy X link could not be cleared; the registration was retained for reconciliation" 1
  fi
  rm -f -- "$(fm_pf_registry_dir "$STATE")/$id" 2>/dev/null || true
  printf 'recorded %s attempt=%s request=%s\n' "$id" "$attempt" "$request"
}

# --- subcommand: guard-work -------------------------------------------------

cmd_guard_work() {
  local work_home=${1:-} work_id=${2:-} bound id payload delivery task_state blocked=0
  [ -n "$work_home" ] && [ -n "$work_id" ] || { usage; exit 2; }
  fm_pf_relay_active "$FM_HOME" || exit 0
  fm_pf_has_registrations "$STATE" || exit 0

  # Reading the registration records needs no tools, so establish whether this
  # work is bound to any commitment before deciding anything else.
  bound=$(fm_pf_registry_ids_for_work "$STATE" "$work_home" "$work_id")
  [ -n "$bound" ] || exit 0

  # From here the work IS bound to a public promise, so an unreadable state is a
  # blocking answer, not a pass: cleanup must never proceed on a guess.
  if ! command -v jq >/dev/null 2>&1 || ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'cannot verify the public commitments bound to %s/%s: jq and tasks-axi are required\n' \
      "$work_home" "$work_id"
    exit 3
  fi

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! payload=$(obligation_json "$id"); then
      printf 'cannot read the state of public commitment %s for %s/%s\n' "$id" "$work_home" "$work_id"
      blocked=1
      continue
    fi
    # Gone from the backlog entirely (pruned after Done): nothing left to owe.
    [ -n "$payload" ] || continue
    delivery=$(pf_field "$payload" '.public_followup.delivery.state')
    task_state=$(pf_field "$payload" '.state')
    case "$task_state:$delivery" in
      done:*|*:posted|*:waived) continue ;;
    esac
    printf 'public commitment %s is still %s for %s/%s\n' "$id" "${delivery:-unknown}" "$work_home" "$work_id"
    blocked=1
  done <<EOF
$bound
EOF
  [ "$blocked" -eq 0 ] || exit 3
}

# --- subcommand: retire -----------------------------------------------------

cmd_retire() {
  local id=${1:-} force=0 payload delivery task_state
  [ -n "$id" ] || { usage; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      *) die "unknown argument '$1'" ;;
    esac
    shift || true
  done
  fm_pf_slug_valid "$id" || die "unsafe obligation id: $id"
  fm_pf_relay_active "$FM_HOME" || exit 0
  require_tools

  payload=$(obligation_json "$id") || die "could not read the backlog through tasks-axi" 1
  if [ -n "$payload" ]; then
    delivery=$(pf_field "$payload" '.public_followup.delivery.state')
    task_state=$(pf_field "$payload" '.state')
    case "$task_state:$delivery" in
      done:*|*:posted|*:waived) ;;
      *)
        [ "$force" -eq 1 ] \
          || die "obligation '$id' is still ${delivery:-unresolved}; retiring its registration now would hide an open public promise. Deliver it, waive it, or pass --force." 1
        ;;
    esac
  fi
  if ! clear_public_followup_link "$id"; then
    die "could not clear the legacy X link for '$id'; its registration was retained for reconciliation" 1
  fi
  rm -f -- "$(fm_pf_registry_dir "$STATE")/$id" 2>/dev/null || true
  printf 'retired %s\n' "$id"
}

# --- dispatch ---------------------------------------------------------------

CMD=${1:-}
case "$CMD" in
  --help|-h|help) help; exit 0 ;;
  '') usage; exit 2 ;;
esac
shift

case "$CMD" in
  active)        cmd_active "$@" ;;
  register)      cmd_register "$@" ;;
  brief)         cmd_brief "$@" ;;
  consume)       cmd_consume "$@" ;;
  pending)       cmd_pending "$@" ;;
  deliver)       cmd_deliver "$@" ;;
  record-posted) cmd_record_posted "$@" ;;
  guard-work)    cmd_guard_work "$@" ;;
  retire)        cmd_retire "$@" ;;
  *) usage; exit 2 ;;
esac
