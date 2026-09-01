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
#   bin/fm-on.sh                the SSH route to a REMOTE secondmate home, whose
#                               state no local path can reach.
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
#       worth looking at, including a delivered open loop, 1 otherwise. Safe to
#       call unconditionally.
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
#       binding is copied into a brief instead of hand-assembled. The
#       --deliverable flags name the obligation's actual required keys.
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
#       One bounded public-safe line per open public loop, for the session
#       start digest. Unresolved commitments print as "unresolved" (a reply is
#       still owed). Delivered or settled registrations print as "open-loop"
#       (the thread is still open with nothing owed). Registrations are never
#       pruned here; only `retire` removes one. Silent when nothing is open.
#
#   fm-public-followup.sh deliver <obligation-id> [--text-file <path>]
#       Post the final public reply into the ORIGINAL thread. Uses the stored
#       platform and opaque context binding, so the destination is never guessed.
#       Without --text-file the accepted terminal event's bounded public-safe
#       outcome is reused exactly, which keeps the common path deterministic.
#       The sequence is begin-delivery with the payload hash, post, then record
#       the posted receipt or a typed error. A validated receipt also clears any
#       bound legacy X link, then stamps the registration state=delivered. Delivery
#       does not close the public loop; `retire` is the only close. Prints a
#       disposition line so the loop is handed on with `rechain` or closed
#       explicitly. An already-posted obligation is an idempotent success
#       without another post; an obligation left in delivery-posting by a crash
#       is REFUSED rather than posted again.
#
#   fm-public-followup.sh record-posted <obligation-id> --attempt <n> --chunks <n>
#       Record an obligation whose post is known to have landed on exactly
#       attempt <n> with exactly <n> messages, without posting anything. This is
#       the late-receipt path: use it when a post succeeded but its receipt was
#       lost, never to paper over an unknown outcome. Stamps the registration
#       delivered; does not remove it.
#
#   fm-public-followup.sh guard-work <work-home-id> <work-id>
#       Exit 3 when this home has an unresolved public commitment bound to that
#       exact work, printing one line per blocking obligation. Exit 0 otherwise.
#       Cleanup paths call this so bound work is never treated as finished while
#       its public promise is still open. A delivered registration is not a
#       block: that work's reply already landed.
#
#   fm-public-followup.sh rechain <new-obligation-id> --from <delivered-id>
#         --work-home <main|secondmate:<id>> --work-id <task-id>
#         --expected <pr-merged|report-ready|local-main>
#         [--deliverable-key <k>]...
#       Hand a delivered public loop on to follow-on work against the same
#       thread. Decodes the retained request context, creates and binds a fresh
#       promised-final obligation, registers it, retires the source with reason
#       "handed on to <new-id>", and prints `brief` for the new obligation.
#       Refuses unless the source is state=delivered, the follow-up window is
#       still open, and the relay is active. A pre-change record without
#       request_context_b64 is un-rechainable.
#
#   fm-public-followup.sh retire <obligation-id> --reason "<why the loop is done>" [--force]
#       The only close. Drops the registration after recording --reason.
#       --force is the explicit discard-approved escape hatch for an unresolved
#       or missing obligation. --reason is required. --force never covers
#       clearing the bound legacy X link: a loop whose link is still verifiably
#       in place is retained for reconciliation either way. When the bound work
#       lives in a REMOTE secondmate home, that clear runs over the route's SSH
#       transport, and a remote that never confirms it is reported as unknown
#       completion to reconcile on that host, not as a definite failure.
#
# Requires jq and a compatible tasks-axi for registration, briefs,
# reconciliation, delivery, cleanup guards, and retirement; only `active`
# inspects local state alone.
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
  echo "usage: fm-public-followup.sh <active|register|brief|consume|pending|deliver|record-posted|guard-work|rechain|retire> [args]" >&2
}

# The header comment IS the help text, so the two can never drift apart.
help() { sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

die() { printf 'fm-public-followup: %s\n' "$1" >&2; exit "${2:-2}"; }

PF_TEMP_FILES=()
PF_REGISTRY_LOCK_IDS=()
pf_registry_lock_held() {
  local wanted=$1 held
  # bash 3.2 + set -u treats "${arr[@]}" on an empty array as unbound.
  for held in ${PF_REGISTRY_LOCK_IDS[@]+"${PF_REGISTRY_LOCK_IDS[@]}"}; do
    [ "$held" = "$wanted" ] && return 0
  done
  return 1
}
pf_registry_lock_acquire() {
  local id=$1
  pf_registry_lock_held "$id" && return 0
  fm_pf_registry_lock_acquire "$STATE" "$id" || return 1
  PF_REGISTRY_LOCK_IDS+=("$id")
}
pf_registry_lock_release() {
  local id=$1 held
  local -a remaining=()
  pf_registry_lock_held "$id" || return 0
  fm_pf_registry_lock_release "$STATE" "$id"
  for held in ${PF_REGISTRY_LOCK_IDS[@]+"${PF_REGISTRY_LOCK_IDS[@]}"}; do
    [ "$held" = "$id" ] || remaining+=("$held")
  done
  PF_REGISTRY_LOCK_IDS=(${remaining[@]+"${remaining[@]}"})
}
pf_cleanup() {
  local i
  for ((i=${#PF_REGISTRY_LOCK_IDS[@]}-1; i>=0; i--)); do
    fm_pf_registry_lock_release "$STATE" "${PF_REGISTRY_LOCK_IDS[$i]}" 2>/dev/null || true
  done
  [ "${#PF_TEMP_FILES[@]}" -eq 0 ] || rm -f -- "${PF_TEMP_FILES[@]}"
}
trap pf_cleanup EXIT

now_rfc3339() { fm_pf_now_rfc3339; }

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
# same convention bin/fm-captain-hold.sh uses for typed backlog state.
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

  local followup_expires_at request_json request_context_b64 work_home_path
  followup_expires_at=$(pf_field "$payload" '.public_followup.request.followup_expires_at')
  request_json=$(printf '%s' "$payload" | jq -c '.public_followup.request // empty' 2>/dev/null || true)
  request_context_b64=
  if [ -n "$request_json" ]; then
    request_context_b64=$(printf '%s' "$request_json" | fm_pf_b64_encode)
  fi
  work_home_path=
  case "$work_home" in
    secondmate:*)
      work_home_path=$(public_followup_secondmate_home "${work_home#secondmate:}" 2>/dev/null || true)
      case "$work_home_path" in
        *$'\n'*|*$'\r'*) work_home_path= ;;
      esac
      ;;
  esac

  local mkdir_target registry_state retired_file
  for mkdir_target in "$(fm_pf_registry_dir "$STATE")" "$(fm_pf_events_dir "$STATE")" \
                      "$(fm_pf_consumed_dir "$STATE")" "$(fm_pf_rejected_dir "$STATE")"; do
    fmx_private_artifact_dir_prepare "$mkdir_target" >/dev/null \
      || die "could not prepare $mkdir_target" 1
  done

  pf_registry_lock_acquire "$id" \
    || die "could not lock registration '$id'" 1
  retired_file="$(fm_pf_retired_dir "$STATE")/$id"
  if [ -e "$retired_file" ] || [ -L "$retired_file" ]; then
    die "public loop '$id' has already been retired and cannot be registered again" 1
  fi
  registry_state=$(fm_pf_registry_loop_state "$STATE" "$id")
  if [ "$registry_state" = delivered ]; then
    pf_registry_lock_release "$id"
    printf 'already registered %s state=delivered\n' "$id"
    return 0
  fi
  printf 'obligation_id=%s\nrelation_id=%s\nwork_home=%s\nwork_home_path=%s\nwork_id=%s\ngeneration=%s\nplatform=%s\nrequest_id=%s\nstate=open\nfollowup_expires_at=%s\nrequest_context_b64=%s\n' \
    "$id" "$relation" "$work_home" "$work_home_path" "$work_id" "$generation" "$platform" "$request" \
    "$followup_expires_at" "$request_context_b64" \
    | fmx_private_artifact_publish_stdin "$(fm_pf_registry_dir "$STATE")" "$id" 600 \
    || die "could not write the registration record" 1
  pf_registry_lock_release "$id"

  printf 'registered %s %s/%s generation=%s platform=%s\n' \
    "$id" "$work_home" "$work_id" "$generation" "${platform:-unknown}"
}

# --- subcommand: brief ------------------------------------------------------

cmd_brief() {
  local id=${1:-} relation work_home work_id generation payload outcome keys key deliverable_flags
  [ -n "$id" ] || { usage; exit 2; }
  fm_pf_slug_valid "$id" || die "unsafe obligation id: $id"
  fm_pf_relay_active "$FM_HOME" || die "the relay is not active for this home" 1
  [ -f "$(fm_pf_registry_dir "$STATE")/$id" ] \
    || die "no registration for '$id' in this home" 1

  relation=$(fm_pf_registry_get "$STATE" "$id" relation_id)
  work_home=$(fm_pf_registry_get "$STATE" "$id" work_home)
  work_id=$(fm_pf_registry_get "$STATE" "$id" work_id)
  generation=$(fm_pf_registry_get "$STATE" "$id" generation)

  require_tools
  payload=$(obligation_json "$id") \
    || die "could not read public-followup obligation '$id' through tasks-axi" 1
  [ -n "$payload" ] \
    || die "public-followup obligation '$id' is missing from tasks-axi" 1
  outcome=$(pf_field "$payload" '.public_followup.expected_final.type')
  [ -n "$outcome" ] \
    || die "public-followup obligation '$id' has no expected final type" 1
  keys=$(printf '%s' "$payload" \
    | jq -er '.public_followup.expected_final.required_deliverables
        | select(type == "array" and length > 0
            and (map(type == "string" and test("^[a-z0-9_]+$")) | all))
        | .[]' 2>/dev/null) \
    || die "public-followup obligation '$id' has no readable required deliverable keys" 1
  deliverable_flags=
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    deliverable_flags="${deliverable_flags}    --deliverable ${key}=<value> \\
"
  done <<EOF
$keys
EOF

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
    --outcome $outcome \\
${deliverable_flags}    --outcome-text '<one bounded public-safe sentence>'

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

# print_open_loop <id> <payload>: the session-start line for a public loop that
# is still open after delivery (or whose obligation has left the backlog).
print_window_escalation() {
  local expires=$1 window
  window=$(fm_pf_followup_window_class "$expires")
  case "$window" in
    expired)
      printf '  DEADLINE: thread can no longer be reached (window closed %s); this needs a captain decision\n' \
        "${expires:-unknown}"
      ;;
    closing)
      printf '  DEADLINE: window closes %s (under 48 hours)\n' "${expires:-unknown}"
      ;;
  esac
}

print_open_loop() {
  local id=$1 payload=$2 request platform summary delivered expires ctx
  request=$(fm_pf_registry_get "$STATE" "$id" request_id)
  [ -n "$request" ] || request=$(pf_field "$payload" '.public_followup.request.request_id')
  platform=$(fm_pf_registry_get "$STATE" "$id" platform)
  [ -n "$platform" ] || platform=$(pf_field "$payload" '.public_followup.request.platform')
  delivered=$(fm_pf_registry_get "$STATE" "$id" delivered_at)
  expires=$(fm_pf_registry_get "$STATE" "$id" followup_expires_at)
  [ -n "$expires" ] || expires=$(pf_field "$payload" '.public_followup.request.followup_expires_at')
  summary=$(pf_field "$payload" '.public_followup.request.public_safe_summary' | fm_pf_clean_outcome_text)
  if [ -z "$summary" ]; then
    ctx=$(fm_pf_registry_get "$STATE" "$id" request_context_b64)
    if [ -n "$ctx" ]; then
      summary=$(printf '%s' "$ctx" | fm_pf_b64_decode | jq -r '.public_safe_summary // empty' 2>/dev/null | fm_pf_clean_outcome_text)
    fi
  fi
  printf 'open-loop %s request=%s platform=%s\n' "$id" "${request:-unknown}" "${platform:-unknown}"
  printf '  delivered=%s window-closes=%s\n' "${delivered:-unknown}" "${expires:-unknown}"
  printf '  summary=%s\n' "$summary"
  if ! fm_pf_registry_rechainable "$STATE" "$id"; then
    printf '  unrechainable: pre-change registration lacks request_context_b64\n'
  fi
  print_window_escalation "$expires"
  printf '  -> bind the follow-on with rechain, or close the loop with retire %s --reason ...\n' "$id"
}

cmd_pending() {
  gate_or_exit

  local listing id payload delivery task_state summary platform request expires printed=0 loop_state settled stamp_rc
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
    loop_state=$(fm_pf_registry_loop_state "$STATE" "$id")
    delivery=$(pf_field "$payload" '.public_followup.delivery.state')
    task_state=$(pf_field "$payload" '.state')
    settled=0
    if [ -z "$payload" ] || [ "$task_state" = 'done' ] \
        || [ "$delivery" = 'posted' ] || [ "$delivery" = 'waived' ] \
        || [ "$loop_state" = delivered ]; then
      settled=1
    fi
    if [ "$settled" -eq 1 ]; then
      if [ "$loop_state" != delivered ]; then
        stamp_rc=0
        fm_pf_registry_stamp_delivered "$STATE" "$id" "$(now_rfc3339)" || stamp_rc=$?
        if [ "$stamp_rc" -eq 3 ] && fm_pf_retirement_receipt_exists "$STATE" "$id"; then
          continue
        fi
        [ "$stamp_rc" -eq 0 ] \
          || die "could not stamp settled registration '$id' as delivered" 1
      fi
      # Keep the registration. Clearing a leftover legacy link is best-effort
      # and never the close; only retire removes the record.
      if public_followup_registration_valid "$id"; then
        clear_public_followup_link "$id" >/dev/null 2>&1 || true
      fi
      print_open_loop "$id" "$payload"
      printed=1
      continue
    fi
    summary=$(pf_field "$payload" '.public_followup.request.public_safe_summary' | fm_pf_clean_outcome_text)
    platform=$(pf_field "$payload" '.public_followup.request.platform')
    request=$(pf_field "$payload" '.public_followup.request.request_id')
    printf 'unresolved %s state=%s platform=%s request=%s summary=%s\n' \
      "$id" "${delivery:-unknown}" "${platform:-unknown}" "${request:-unknown}" "$summary"
    expires=$(fm_pf_registry_get "$STATE" "$id" followup_expires_at)
    [ -n "$expires" ] || expires=$(pf_field "$payload" '.public_followup.request.followup_expires_at')
    print_window_escalation "$expires"
    if ! fm_pf_registry_rechainable "$STATE" "$id"; then
      printf '  unrechainable: pre-change registration lacks request_context_b64\n'
    fi
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
  local id=$1 include_absent=${2:-} meta_home registry_home home marker
  fm_pf_home_id_valid "secondmate:$id" || return 1
  meta_home=$(fmx_meta_get "$STATE/$id.meta" home)
  registry_home=
  if [ -f "$DATA/secondmates.md" ] && [ ! -L "$DATA/secondmates.md" ]; then
    registry_home=$(secondmate_registry_field "$DATA/secondmates.md" "$id" home || true)
  fi
  if [ -n "$meta_home" ] && [ -n "$registry_home" ] && [ "$meta_home" != "$registry_home" ]; then
    return 2
  fi
  home=${meta_home:-$registry_home}
  [ -n "$home" ] || return 4
  case "$home" in /*) ;; *) return 2 ;; esac
  if [ ! -e "$home" ]; then
    [ ! -L "$home" ] || return 2
    [ "$include_absent" = include-absent ] && printf '%s\n' "$home"
    return 3
  fi
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 2
  [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || return 2
  marker=$(sed -n '1p' "$home/.fm-secondmate-home" 2>/dev/null)
  [ "$marker" = "$id" ] || return 2
  printf '%s\n' "$home"
}

# public_followup_route_is_remote <secondmate-id>: 0 when data/secondmates.md
# holds a genuine REMOTE route for that id. The registry is the route authority
# here for the same reason fm-on.sh and fm-send.sh treat it as one: a remote home
# has no local path, so nothing on this disk can answer the question. Resolving
# it live also means a registration written before this check (they all record an
# empty work_home_path for a remote route) still retires.
public_followup_route_is_remote() {
  local id=$1 remote
  fm_pf_home_id_valid "secondmate:$id" || return 1
  [ -f "$DATA/secondmates.md" ] && [ ! -L "$DATA/secondmates.md" ] || return 1
  remote=$(secondmate_registry_field "$DATA/secondmates.md" "$id" remote 2>/dev/null) || return 1
  [ "$remote" = 1 ]
}

# clear_public_followup_link_remote <secondmate-id> <work-id> <request-id>:
# clear the bound legacy X link inside a REMOTE secondmate home over that route's transport,
# because the link lives in the remote home's state and no local path reaches it.
# fm-on.sh returns ssh's status unchanged, so 255 is the established "delivered
# but completion unknown" status this codebase already reconciles rather than
# reads as done or refused (bin/fm-on.sh, bin/fm-remote-readiness-lib.sh,
# bin/fm-teardown.sh). It is passed through so a caller can say the remote never
# confirmed instead of claiming the clear definitely failed. The remote clear
# is guarded by the registration's Relay request identity and remains idempotent
# when the target has no link, so a reconciling retry is safe.
clear_public_followup_link_remote() {
  local id=$1 work_id=$2 request_id=$3 rc=0
  "$FM_ROOT/bin/fm-on.sh" "$id" fm-x-followup.sh --clear "$work_id" \
    --expect-request "$request_id" </dev/null >/dev/null || rc=$?
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}

# Returns 0 when the link is cleared, 255 when a remote home never confirmed the
# clear (completion unknown), and 1 for any other refusal.
clear_public_followup_link() {
  local id=$1 work_home work_home_path work_id request_id home state rc
  public_followup_registration_valid "$id" || return 1
  work_home=$(fm_pf_registry_get "$STATE" "$id" work_home)
  work_id=$(fm_pf_registry_get "$STATE" "$id" work_id)
  request_id=$(fm_pf_registry_get "$STATE" "$id" request_id)
  [ -n "$work_home" ] && [ -n "$work_id" ] || return 1
  case "$work_home" in
    main)
      home=$FM_HOME
      state=$STATE
      ;;
    secondmate:*)
      # A remote route is decided from the registry BEFORE any local path is
      # consulted: the recorded remote home path is meaningful only on its own
      # host, so a same-named local directory must never stand in for it.
      if public_followup_route_is_remote "${work_home#secondmate:}"; then
        clear_public_followup_link_remote "${work_home#secondmate:}" "$work_id" "$request_id"
        return $?
      fi
      work_home_path=$(fm_pf_registry_get "$STATE" "$id" work_home_path)
      case "$work_home_path" in /*) ;; *) return 1 ;; esac
      case "$work_home_path" in *$'\n'*|*$'\r'*) return 1 ;; esac
      rc=0
      home=$(public_followup_secondmate_home "${work_home#secondmate:}" include-absent) || rc=$?
      if [ "$rc" -eq 3 ]; then
        [ "$home" = "$work_home_path" ] || return 1
        [ ! -e "$work_home_path" ] && [ ! -L "$work_home_path" ] || return 1
        return 0
      fi
      if [ "$rc" -eq 4 ]; then
        [ ! -e "$work_home_path" ] && [ ! -L "$work_home_path" ] || return 1
        return 0
      fi
      [ "$rc" -eq 0 ] || return 1
      [ "$home" = "$work_home_path" ] || return 1
      state="$home/state"
      ;;
    *) return 1 ;;
  esac
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$FM_ROOT/bin/fm-x-followup.sh" --clear "$work_id" >/dev/null
}

# pf_link_clear_note <rc>: the qualifier appended to a refusal when a bound
# legacy X link is still in place. Empty for every local refusal, so those
# messages are unchanged. A remote clear returns fm-on.sh's pass-through ssh
# status, where 255 means the remote home never confirmed the clear: completion
# is unknown and belongs to that host's reconciliation, never a definite failure
# and never a silent success.
pf_link_clear_note() {
  [ "$1" -eq 255 ] || return 0
  printf ' The remote home never confirmed the clear, so reconcile it on that host rather than assuming nothing changed.'
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

# Delivery keeps the registration. Stamp it delivered and tell the caller the
# public loop is still open.
mark_loop_delivered() {
  local id=$1 rc=0
  fm_pf_registry_stamp_delivered "$STATE" "$id" "$(now_rfc3339)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) return 3 ;;
    *) die "could not stamp registration '$id' as delivered after the public reply landed" 1 ;;
  esac
}

print_loop_open_disposition() {
  local id=$1 request=$2
  printf "thread %s is still OPEN: hand it on with 'rechain ...' or close it with 'retire %s --reason ...'\n" \
    "${request:-unknown}" "$id"
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

  local payload delivery attempt request platform text tmp_text hash chunks rc receipt receipt_fields receipt_dry_run link_status link_rc
  local loop_retained=0
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
        link_rc=0
        clear_public_followup_link "$id" || link_rc=$?
        if [ "$link_rc" -ne 0 ]; then
          die "obligation '$id' is already $delivery, but its legacy X link could not be cleared; the registration was retained for reconciliation$(pf_link_clear_note "$link_rc")" 1
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
      if mark_loop_delivered "$id"; then loop_retained=1; fi
      printf 'already delivered %s state=%s\n' "$id" "$delivery"
      [ "$loop_retained" -eq 0 ] || print_loop_open_disposition "$id" "$request"
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
      link_rc=0
      clear_public_followup_link "$id" || link_rc=$?
      if [ "$link_rc" -ne 0 ]; then
        die "the public reply for '$id' POSTED and its receipt was recorded, but its legacy X link could not be cleared; the registration was retained for reconciliation$(pf_link_clear_note "$link_rc")" 1
      fi
      if mark_loop_delivered "$id"; then loop_retained=1; fi
      printf 'delivered %s request=%s platform=%s chunks=%s\n' "$id" "$request" "$platform" "$chunks"
      [ "$loop_retained" -eq 0 ] || print_loop_open_disposition "$id" "$request"
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
  local id=${1:-} attempt='' chunks='' link_rc
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

  local payload request platform loop_retained=0
  payload=$(obligation_json "$id") || die "could not read the backlog through tasks-axi" 1
  [ -n "$payload" ] || die "no public-followup obligation '$id' in this home's backlog" 1
  request=$(pf_field "$payload" '.public_followup.request.request_id')
  platform=$(pf_field "$payload" '.public_followup.request.platform')

  record_posted "$id" "$attempt" "$request" "$platform" "$chunks" \
    || die "tasks-axi refused the receipt for '$id' attempt $attempt; the recorded attempt must match exactly" 1
  link_rc=0
  clear_public_followup_link "$id" || link_rc=$?
  if [ "$link_rc" -ne 0 ]; then
    die "the receipt for '$id' was recorded, but its legacy X link could not be cleared; the registration was retained for reconciliation$(pf_link_clear_note "$link_rc")" 1
  fi
  if mark_loop_delivered "$id"; then loop_retained=1; fi
  printf 'recorded %s attempt=%s request=%s\n' "$id" "$attempt" "$request"
  [ "$loop_retained" -eq 0 ] || print_loop_open_disposition "$id" "$request"
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

# --- subcommand: rechain ----------------------------------------------------

rechain_default_deliverable_key() {
  case "$1" in
    pr-merged) printf 'pr_url\n' ;;
    report-ready) printf 'report_path\n' ;;
    *) return 1 ;;
  esac
}

cmd_rechain() {
  local new_id=${1:-} from='' work_home='' work_id='' expected=''
  local -a deliverable_keys=()
  [ -n "$new_id" ] || { usage; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from) shift; from=${1:-} ;;
      --work-home) shift; work_home=${1:-} ;;
      --work-id) shift; work_id=${1:-} ;;
      --expected) shift; expected=${1:-} ;;
      --deliverable-key) shift; deliverable_keys+=("${1:-}") ;;
      *) die "unknown argument '$1'" ;;
    esac
    shift || true
  done

  fm_pf_relay_active "$FM_HOME" \
    || die "this home has not opted into the myfirstmate relay, so it cannot own a public commitment" 1
  require_tools
  fm_pf_slug_valid "$new_id" || die "unsafe obligation id: $new_id"
  fm_pf_slug_valid "$from" || die "unsafe source obligation id: $from"
  fm_pf_slug_valid "$work_id" || die "unsafe work id: $work_id"
  fm_pf_home_id_valid "$work_home" \
    || die "work home must be 'main' or 'secondmate:<stable-id>', got '$work_home'"
  case "$expected" in
    pr-merged|report-ready|local-main) ;;
    *) die "--expected must be pr-merged, report-ready, or local-main, got '$expected'" ;;
  esac
  [ "$new_id" != "$from" ] || die "the new obligation id must differ from --from" 2

  pf_registry_lock_acquire "$from" \
    || die "could not lock source registration '$from' for rechain" 1
  local src_file loop_state expires window ctx rechain_to source_record first_claim=0 existing
  src_file="$(fm_pf_registry_dir "$STATE")/$from"
  [ -f "$src_file" ] && [ ! -L "$src_file" ] \
    || die "no registration for '$from' in this home" 1
  loop_state=$(fm_pf_registry_loop_state "$STATE" "$from")
  [ "$loop_state" = delivered ] \
    || die "source '$from' is not state=delivered (got '$loop_state'); nothing to hand on until that final lands" 1
  fm_pf_registry_rechainable "$STATE" "$from" \
    || die "source '$from' is un-rechainable: a pre-change registration has no request_context_b64. Close it with retire --reason or reconstruct the request context by hand." 1

  expires=$(fm_pf_registry_get "$STATE" "$from" followup_expires_at)
  [ -n "$expires" ] || die "source '$from' has no followup_expires_at; the thread window cannot be checked" 1
  window=$(fm_pf_followup_window_class "$expires")
  case "$window" in
    ok|closing) ;;
    expired)
      die "followup_expires_at $expires is in the past: the thread can no longer be reached, so this loop cannot be closed publicly. This is a captain decision." 1
      ;;
    *)
      die "followup_expires_at $expires could not be parsed: the thread window cannot be checked, so this loop cannot be rechained" 1
      ;;
  esac

  if [ "${#deliverable_keys[@]}" -eq 0 ]; then
    local default_key
    default_key=$(rechain_default_deliverable_key "$expected") \
      || die "--expected $expected needs --deliverable-key <k> (no default key)"
    deliverable_keys+=("$default_key")
  fi
  local key
  for key in "${deliverable_keys[@]}"; do
    case "$key" in
      ''|*[!a-z0-9_]*) die "deliverable key must be lowercase [a-z0-9_], got '$key'" ;;
    esac
  done

  # Claim the delivered baton before publishing its destination. The claim is
  # retained if any later retirement step fails, so a retry may resume the same
  # destination but can never fork this thread into a second obligation.
  rechain_to=$(fm_pf_registry_get "$STATE" "$from" rechain_to)
  if [ -n "$rechain_to" ] && [ "$rechain_to" != "$new_id" ]; then
    die "source '$from' is already claimed by rechain destination '$rechain_to'; resume that destination" 1
  fi
  if [ -z "$rechain_to" ]; then
    existing=$(obligation_json "$new_id") \
      || die "could not check whether rechain destination '$new_id' is unused" 1
    [ -z "$existing" ] \
      || die "'$new_id' already exists and was not created by this rechain; choose another id" 1
    [ ! -e "$(fm_pf_registry_dir "$STATE")/$new_id" ] \
      && [ ! -L "$(fm_pf_registry_dir "$STATE")/$new_id" ] \
      && [ ! -e "$(fm_pf_retired_dir "$STATE")/$new_id" ] \
      && [ ! -L "$(fm_pf_retired_dir "$STATE")/$new_id" ] \
      || die "'$new_id' already has local public-loop state; choose another id" 1
    source_record=$(grep -v -E '^rechain_to=' "$src_file" 2>/dev/null) \
      || die "could not read source registration '$from' while claiming it" 1
    printf '%s\nrechain_to=%s\n' "$source_record" "$new_id" \
      | fmx_private_artifact_publish_stdin "$(fm_pf_registry_dir "$STATE")" "$from" 600 \
      || die "could not claim source registration '$from' for '$new_id'" 1
    first_claim=1
  fi

  local ctx_file expected_file relation_file keys_json project src_payload
  ctx=$(fm_pf_registry_get "$STATE" "$from" request_context_b64)
  ctx_file=$(mktemp "${TMPDIR:-/tmp}/fm-pf-rechain-ctx.XXXXXX") \
    || die "could not stage the retained request context" 1
  expected_file=$(mktemp "${TMPDIR:-/tmp}/fm-pf-rechain-exp.XXXXXX") \
    || die "could not stage the expected-final document" 1
  relation_file=$(mktemp "${TMPDIR:-/tmp}/fm-pf-rechain-rel.XXXXXX") \
    || die "could not stage the relation document" 1
  PF_TEMP_FILES+=("$ctx_file" "$expected_file" "$relation_file")
  printf '%s' "$ctx" | fm_pf_b64_decode > "$ctx_file" \
    || die "could not decode request_context_b64 for '$from'" 1
  jq -e 'type == "object" and (.request_id | type == "string")' "$ctx_file" >/dev/null 2>&1 \
    || die "decoded request context for '$from' is not usable" 1

  keys_json=$(printf '%s\n' "${deliverable_keys[@]}" | jq -R . | jq -s -c .)
  project=
  if src_payload=$(obligation_json "$from") && [ -n "$src_payload" ]; then
    project=$(pf_field "$src_payload" '.public_followup.expected_final.project')
  fi
  if [ -n "$project" ]; then
    jq -n --arg t "$expected" --arg p "$project" --argjson keys "$keys_json" \
      '{type:$t, project:$p, required_deliverables:$keys, completion_policy:"all-required"}' \
      > "$expected_file"
  else
    jq -n --arg t "$expected" --argjson keys "$keys_json" \
      '{type:$t, required_deliverables:$keys, completion_policy:"all-required"}' \
      > "$expected_file"
  fi
  jq -n --arg h "$work_home" --arg w "$work_id" \
    '{relation_id:"rel-1", work_ref:{home_id:$h, task_id:$w},
      role:"fulfills", required:true, generation:1}' > "$relation_file"

  local relation_count new_registry
  if [ "$first_claim" -eq 1 ]; then
    existing=
  else
    existing=$(obligation_json "$new_id") \
      || die "could not read the backlog through tasks-axi" 1
  fi
  if [ -n "$existing" ]; then
    printf '%s' "$existing" | jq -e \
      --slurpfile request "$ctx_file" --slurpfile expected "$expected_file" \
      --arg expires "$expires" \
      '.public_followup as $pf
       | $pf.request == $request[0]
         and $pf.purpose == "promised-final"
         and $pf.expected_final == $expected[0]
         and $pf.obligation_expires_at == $expires' >/dev/null 2>&1 \
      || die "'$new_id' already exists with different public-followup data; choose another id" 1
  else
    tx public-followup add "$new_id" --request-context-file "$ctx_file" \
      --purpose promised-final --expected-final-file "$expected_file" \
      --expires-at "$expires" >/dev/null \
      || die "tasks-axi refused to add '$new_id' on the retained thread binding" 1
    existing=$(obligation_json "$new_id") \
      || die "added '$new_id' but could not read it back through tasks-axi; retry this same rechain command" 1
  fi

  relation_count=$(printf '%s' "$existing" \
    | jq -r '(.public_followup.work_relations // []) | length' 2>/dev/null) \
    || die "could not inspect work bindings for '$new_id'" 1
  if [ "$relation_count" -eq 0 ]; then
    tx public-followup bind-work "$new_id" --relation-file "$relation_file" >/dev/null \
      || die "tasks-axi refused to bind '$new_id' to $work_home/$work_id; retry this same rechain command" 1
  else
    printf '%s' "$existing" | jq -e --arg h "$work_home" --arg w "$work_id" \
      '(.public_followup.work_relations // []) as $relations
       | ($relations | length) == 1
         and $relations[0].relation_id == "rel-1"
         and $relations[0].work_ref.home_id == $h
         and $relations[0].work_ref.task_id == $w
         and $relations[0].role == "fulfills"
         and $relations[0].required == true
         and $relations[0].generation == 1' >/dev/null 2>&1 \
      || die "'$new_id' already has a different work binding; choose another id" 1
  fi

  new_registry="$(fm_pf_registry_dir "$STATE")/$new_id"
  if [ -f "$new_registry" ] && [ ! -L "$new_registry" ]; then
    [ "$(fm_pf_registry_get "$STATE" "$new_id" relation_id)" = rel-1 ] \
      && [ "$(fm_pf_registry_get "$STATE" "$new_id" work_home)" = "$work_home" ] \
      && [ "$(fm_pf_registry_get "$STATE" "$new_id" work_id)" = "$work_id" ] \
      && [ "$(fm_pf_registry_get "$STATE" "$new_id" generation)" = 1 ] \
      || die "registration '$new_id' already names different work; choose another id" 1
  else
    cmd_register "$new_id" --relation rel-1 --work-home "$work_home" \
      --work-id "$work_id" --generation 1 >/dev/null \
      || die "could not register '$new_id'; retry this same rechain command" 1
  fi

  cmd_retire "$from" --reason "handed on to $new_id" \
    || die "registered '$new_id' but could not retire '$from'; both loops are open until '$from' is retired" 1

  cmd_brief "$new_id"
}

# --- subcommand: retire -----------------------------------------------------

cmd_retire() {
  local id=${1:-} force=0 reason='' payload delivery task_state registry_file retired_dir retired_at link_rc
  local retirement_rc=0
  [ -n "$id" ] || { usage; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      --reason) shift; reason=${1:-} ;;
      *) die "unknown argument '$1'" ;;
    esac
    shift || true
  done
  fm_pf_slug_valid "$id" || die "unsafe obligation id: $id"
  fm_pf_relay_active "$FM_HOME" || exit 0
  [ -n "$reason" ] || die "retire requires --reason \"<why the public loop is done>\"" 2
  reason=$(printf '%s' "$reason" | fm_pf_clean_outcome_text)
  [ -n "$reason" ] || die "retire requires --reason \"<why the public loop is done>\"" 2
  require_tools
  pf_registry_lock_acquire "$id" \
    || die "could not lock registration '$id' for retirement" 1

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
  link_rc=0
  clear_public_followup_link "$id" || link_rc=$?
  if [ "$link_rc" -ne 0 ]; then
    die "could not clear the legacy X link for '$id'; its registration was retained for reconciliation$(pf_link_clear_note "$link_rc")" 1
  fi
  retired_dir=$(fm_pf_retired_dir "$STATE")
  retired_at=$(now_rfc3339)
  registry_file="$(fm_pf_registry_dir "$STATE")/$id"
  printf 'reason=%s\nretired_at=%s\n' "$reason" "$retired_at" \
    | fmx_private_artifact_publish_stdin "$retired_dir" "$id" 600 \
    || retirement_rc=1
  if [ "$retirement_rc" -eq 0 ]; then
    if ! rm -f -- "$registry_file" 2>/dev/null \
        || [ -e "$registry_file" ] || [ -L "$registry_file" ]; then
      retirement_rc=2
    fi
  fi
  pf_registry_lock_release "$id"
  case "$retirement_rc" in
    1) die "could not record the retirement reason for '$id'; the public loop remains open" 1 ;;
    2) die "could not remove registration for '$id'; the public loop remains open" 1 ;;
  esac
  printf 'retired %s reason=%s\n' "$id" "$reason"
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
  rechain)       cmd_rechain "$@" ;;
  retire)        cmd_retire "$@" ;;
  *) usage; exit 2 ;;
esac
