#!/usr/bin/env bash
# Steer an ordinary task through its durable inbox or a verified local backend.
# Usage: fm-send.sh <target> [--action-id <prepared-lifecycle-id> --expected-generation <spawn-gen>] [--resolve-key <key>]... <text...>
# Special key form: fm-send.sh <target> --key Enter
# Recorded historical secondmate or remote-home targets refuse before delivery.
# Text addressed by task selector uses the durable inbox except harness-native
# slash commands and Codex CLI $skill invocations, which use direct native
# prompt submission. Explicit backend targets use that same direct path.
# --resolve-key closes a matching local task decision only after durable enqueue
# or native API acceptance.
set -eu

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
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

FM_GUARD_CONTINUE_LINE='This is a supervision warning only; delivery is reported by the send operation below.' "$SCRIPT_DIR/fm-guard.sh" || true

fm_send_id_from_meta() { # <meta-file>
  local base
  base=${1##*/}
  printf '%s' "${base%.meta}"
}

# fm_send_clear_after_interrupt: TraeX restores the interrupted prompt into
# the composer as real unsubmitted text. Classifying that as pending input is correct - the text really is
# unsubmitted - but leaving it there means the NEXT steer types onto the end of
# it and submits both as one garbled message. Ctrl-U clears the composer
# (verified), so the interrupt is not complete until it has been sent. A failed
# clear is loud rather than silent, because the alternative is a corrupted steer.
# WHICH adapters need that clear, and which key clears them, comes from the one
# control-plane capability table (bin/fm-control-lib.sh) rather than a second
# copy here - the same table bin/fm-control.sh's interrupt verb reads.
fm_send_clear_after_interrupt() { # <key>
  local key=$1 family clear
  [ "$key" = Escape ] || return 0
  family=$(fm_control_harness_family "$TARGET_HARNESS") || return 0
  clear=$(fm_control_interrupt_clear_key "$family") || return 0
  [ -n "$clear" ] || return 0
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$clear" "$EXPECTED_LABEL"; then
    echo "error: Escape reached $T, but the $TARGET_HARNESS composer could not be cleared; it still holds the restored prompt. Clear it before sending the next message." >&2
    return 1
  fi
}

fm_send_normalize_key() { # <key>
  case "$1" in
  Escape | escape | Esc | esc) printf '%s' Escape ;;
  *) printf '%s' "$1" ;;
  esac
}


fm_send_meta_for_key_value() { # <state-dir> <key> <value>
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

fm_send_count_colons() { # <string>
  local s=$1 no_colons
  no_colons=${s//:/}
  printf '%s' $((${#s} - ${#no_colons}))
}

fm_send_resolve_target() { # <raw-target>
  local raw=$1 meta pane_meta target backend assumed colons id session hint

  RESOLVED_TARGET=""
  TARGET_BACKEND=""
  TARGET_HARNESS=""
  EXPECTED_LABEL=""
  TARGET_META=""
  TARGET_SELECTOR=""
  RESOLUTION_TRIED=""

  meta=$(fm_backend_meta_for_selector "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    if [ "$(fm_meta_get "$meta" kind)" = secondmate ] || [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
      echo "error: target '$raw' is a historical secondmate record; steering is no longer supported" >&2
      return 1
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
      echo "error: legacy target '$raw' has no recorded Herdr identity; refusing to reinterpret it" >&2
      return 1
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
ACTION_ID=
if [ "${1:-}" = --action-id ]; then
  [ $# -ge 3 ] || { echo 'error: --action-id needs an id and body' >&2; exit 2; }
  ACTION_ID=$2
  shift 2
fi

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
    send_exit_status=0
    trap 'send_exit_status=$?; fm_lease_guard_release; exit "$send_exit_status"' EXIT
    # shellcheck source=bin/fm-task-lifecycle-lib.sh
    . "$SCRIPT_DIR/fm-task-lifecycle-lib.sh"
    if [ -z "$ACTION_ID" ]; then
      fm_task_lifecycle_execution_guard "$LEASE_GUARD_TASK" || exit 1
      branch_progress_token=''
      if [ "$(fm_lease_actor)" = branch ] && [ -n "${FM_BRANCH_PROGRESS_BINDINGS:-}" ]; then
        branch_progress_token=$(printf '%s' "$FM_BRANCH_PROGRESS_BINDINGS" | jq -er --arg task "$LEASE_GUARD_TASK" '.[$task] // empty' 2>/dev/null || true)
        printf '%s' "${FM_BRANCH_TASK_SCOPE:-[]}" | jq -e --arg task "$LEASE_GUARD_TASK" \
          'type == "array" and (index("*") != null or index($task) != null)' >/dev/null 2>&1 || {
          echo 'REFUSED: task is outside this exact branch admission' >&2; exit 6;
        }
        [ -n "$branch_progress_token" ] || {
          echo 'REFUSED: compact continuation may steer only its token-bound task' >&2; exit 6;
        }
      fi
      if [ -n "$branch_progress_token" ]; then
        # shellcheck source=bin/fm-task-progress-lib.sh
        . "$SCRIPT_DIR/fm-task-progress-lib.sh"
        branch_current_progress=$(fm_task_progress_read "$LEASE_GUARD_TASK") || exit 1
        [ "$(printf '%s' "$branch_current_progress" | jq -r '.record_token')" = "$branch_progress_token" ] || {
          echo 'REFUSED: task intent or progress changed after branch admission' >&2; exit 6;
        }
        printf '%s' "$branch_current_progress" | jq -e \
          '.task_state == "in_flight" and .remaining_gap != "" and .next_step != ""' >/dev/null || {
          echo 'REFUSED: compact task progress no longer permits continuation' >&2; exit 6;
        }
      elif [ "$(fm_lease_actor)" = branch ] && [ -f "${FM_DATA_OVERRIDE:-$FM_HOME/data}/$LEASE_GUARD_TASK/lifecycle.json" ]; then
        fm_task_lifecycle read "$LEASE_GUARD_TASK" | jq -e '.schema != "fm-task-lifecycle.v2"' >/dev/null || {
          echo 'REFUSED: delegated steer requires --action-id' >&2; exit 6;
        }
      fi
    fi
  fi
fi

# Collect --resolve-key flags (answerer-closes; see the header contract). They
# must precede --key or the message text; everything after the last flag is the
# message exactly as before, so ordinary sends are byte-identical.
RESOLVE_KEYS=
FIRE_AND_FORGET_ID=
EXPECTED_GENERATION=
fm_send_add_resolve_key() { # <key>
  local k=$1
  case "$k" in
  '' | *[!A-Za-z0-9._-]*)
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
  --action-id|--expected-generation)
    [ $# -ge 2 ] || exit 2
    case "$1" in
      --action-id) [ -z "$ACTION_ID" ] || exit 2; ACTION_ID=$2 ;;
      --expected-generation) [ -z "$EXPECTED_GENERATION" ] || exit 2; EXPECTED_GENERATION=$2 ;;
    esac
    shift 2
    ;;
  --resolve-key)
    [ $# -ge 2 ] || {
      echo "error: --resolve-key requires a key" >&2
      exit 1
    }
    fm_send_add_resolve_key "$2" || exit 1
    shift 2
    ;;
  --resolve-key=*)
    fm_send_add_resolve_key "${1#--resolve-key=}" || exit 1
    shift
    ;;
  --fire-and-forget|--fire-and-forget=*)
    echo "error: --fire-and-forget belonged to retired persistent-home delivery and is no longer supported" >&2
    exit 1
    ;;
  *) break ;;
  esac
done

if [ -n "$ACTION_ID$EXPECTED_GENERATION" ]; then
  [ -n "$ACTION_ID" ] && [ -n "$EXPECTED_GENERATION" ] && [ -n "$TARGET_META" ] || exit 2
  [ "$TARGET_BACKEND" != remote ] && [ -z "$FIRE_AND_FORGET_ID$RESOLVE_KEYS" ] || exit 2
  [ "$(fm_meta_get "$TARGET_META" kind)" != secondmate ] || exit 2
  [ "${1-}" != --key ] || exit 2
  FM_SEND_EXPECTED_SPAWN_GEN=$EXPECTED_GENERATION
fi
if [ -n "$TARGET_META" ] && [ -z "$RESOLVE_KEYS" ]; then
  # shellcheck source=bin/fm-task-lifecycle-lib.sh
  . "$SCRIPT_DIR/fm-task-lifecycle-lib.sh"
  fm_task_lifecycle_execution_allowed "$(fm_send_id_from_meta "$TARGET_META")" || exit 1
fi

if [ "$TARGET_BACKEND" != remote ]; then
  fm_backend_validate "$TARGET_BACKEND" || exit 1
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
fm_send_hold_resolved_id() { # <task-id> <decision-key>
  local show id state hold_kind
  command -v tasks-axi >/dev/null 2>&1 || return 1
  for id in "$2" "$1-decision-$2"; do
    show=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE='' "$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" --full 2>/dev/null) || continue
    state=$(printf '%s\n' "$show" | sed -n 's/^  state: //p' | head -1)
    hold_kind=$(printf '%s\n' "$show" | sed -n 's/^  hold_kind: //p' | head -1)
    [ "$state" != "done" ] || continue
    [ "$hold_kind" = captain ] || continue
    printf '%s\n' "$id"
    return 0
  done
  return 1
}

# Close-note body for --resolve-key.
fm_send_resolve_close_note() { # <key> <excerpt>
  local excerpt=$2
  printf 'answered: %s' "$excerpt"
}

if [ -n "$RESOLVE_KEYS" ]; then
  if [ -z "$TARGET_SELECTOR" ] || [ -z "$TARGET_META" ]; then
    echo "error: --resolve-key needs a task selector resolved through this home's metadata; an explicit backend target has no decision ledger here" >&2
    exit 1
  fi
  if [ -n "$ACTION_ID" ] && { [ "${1:-}" = --key ] || [ -n "$RESOLVE_KEYS" ] || [ -z "$TARGET_SELECTOR" ]; }; then
  echo 'REFUSED: lifecycle actions require ordinary task inbox text' >&2
  exit 6
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
    "$k"$'\t'* | *$'\n'"$k"$'\t'*)
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
  # Refuse before send when capping would remove the structural key and make
  # the close ineffective.
  resolve_excerpt=$(printf '%s' "$*" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  for k in $RESOLVE_STATUS_KEYS; do
    probe=$(fm_send_resolve_close_note "$k" "$resolve_excerpt")
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
# durably submitted: enqueued on the inbox plane, accepted by the native API on
# the direct plane. An append failure exits nonzero with the manual close
# command; the decision then stays open and re-surfaces, never silently lost.
# The close is this home's own bookkeeping, written by the very turn that
# answered the decision, so it goes through the guarded self-announced append
# (bin/fm-wake-lib.sh) and does not wake this same session again; any
# concurrent foreign status bytes leave the watcher's wake path untouched.
fm_send_close_resolved_keys() { # <answer-text>
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
    "$k"$'\t'* | *$'\n'"$k"$'\t'*)
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
fm_send_feed_resolved_holds() { # <answer-text>
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

# The target's harness comes from its task metadata and selects which leading
# forms are native harness invocations rather than ordinary inbox text. The
# target's BACKEND comes from selector meta, from matching an explicit target
# back to recorded meta, or from strict explicit-target shape validation.
# Do not add a separate passive liveness preflight here.
# The native Herdr prompt request itself reports target availability; a definite
# failure is surfaced below with the attempted resolution attached, while a
# timeout-like result stays uncertain and forbids blind replay.

if [ -n "$ACTION_ID" ] && { [ "${1:-}" = --key ] || [ -n "$RESOLVE_KEYS" ] || [ -z "$TARGET_SELECTOR" ]; }; then
  echo 'REFUSED: lifecycle actions require ordinary task inbox text' >&2
  exit 6
fi
if [ "${1:-}" = "--key" ]; then
  case "$*" in
  *--resolve-key*)
    echo "error: --resolve-key cannot accompany --key; answering a decision requires a text answer" >&2
    exit 1
    ;;
  esac
  key=$2
  semantic_key=$(fm_send_normalize_key "$key")
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$key" "$EXPECTED_LABEL"; then
    echo "error: key '$key' not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  fm_send_clear_after_interrupt "$semantic_key" || exit 1
else
  MESSAGE=$*
  if [ -z "${MESSAGE//[[:space:]]/}" ]; then
    echo "error: a text steer requires a nonempty message; nothing was sent" >&2
    exit 1
  fi
  # Keep the answer text for the closing resolved note.
  RESOLVE_ANSWER_TEXT=$MESSAGE
  # Text addressed to a task selector rides the inbox unless it is a
  # harness-native invocation: a leading slash, or a leading dollar sign for
  # the Codex CLI harness. Explicit backend targets stay on the direct native
  # prompt plane.
  INBOX_PLANE=0
  if [ -n "$TARGET_SELECTOR" ]; then
    case "$RESOLVE_ANSWER_TEXT" in
    /*) ;;
    \$*) [ "$TARGET_HARNESS" = codex ] || INBOX_PLANE=1 ;;
    *) INBOX_PLANE=1 ;;
    esac
  fi
  if [ -n "$ACTION_ID" ] && [ "$INBOX_PLANE" != 1 ]; then
    echo 'REFUSED: lifecycle actions cannot use the direct native-prompt plane' >&2; exit 6
  fi
  if [ "$INBOX_PLANE" = 1 ]; then
    INBOX_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
    INBOX_META_LOCK=$(fm_meta_lock_path "$TARGET_META") || exit 1
    if ! fm_task_inbox_lock_acquire "$INBOX_META_LOCK"; then
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
    if [ "$CURRENT_INBOX_TARGET" != "$T" ] ||
      [ "$CURRENT_INBOX_BACKEND" != "$TARGET_BACKEND" ] ||
      { [ -n "${FM_SEND_EXPECTED_SPAWN_GEN:-}" ] &&
        [ "$CURRENT_INBOX_SPAWN_GEN" != "$FM_SEND_EXPECTED_SPAWN_GEN" ]; } ||
      [ -n "$(fm_meta_get "$TARGET_META" remote_host)" ]; then
      fm_lock_release "$INBOX_META_LOCK"
      echo "error: steer not sent to $INBOX_TASK_ID: the task retired or changed endpoint during target resolution" >&2
      exit 1
    fi
    if [ -n "$ACTION_ID" ]; then
      BODY_SHA=$(printf '%s' "$MESSAGE" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
      EFFECT_RESULT=$(fm_task_lifecycle effect "$INBOX_TASK_ID" --action-id "$ACTION_ID" --payload-sha256 "$BODY_SHA") || {
        fm_lock_release "$INBOX_META_LOCK"
        exit 6
      }
      if [ "$(printf '%s' "$EFFECT_RESULT" | jq -r '.next_action.phase')" = confirmed ]; then
        fm_lock_release "$INBOX_META_LOCK"
        exit 0
      fi
      INBOX_RECORD=$(fm_task_inbox_write_handoff "$STATE" "$INBOX_TASK_ID" "$MESSAGE" "action.$ACTION_ID" "$CURRENT_INBOX_SPAWN_GEN") || inbox_write_rc=$?
      if [ "${inbox_write_rc:-0}" -eq 0 ]; then
        fm_task_lifecycle bind-inbox "$INBOX_TASK_ID" --action-id "$ACTION_ID" --receipt-ref "$INBOX_RECORD" >/dev/null || inbox_write_rc=$?
      fi
    else
      INBOX_RECORD=$(fm_task_inbox_write "$STATE" "$INBOX_TASK_ID" "$MESSAGE" '' "$CURRENT_INBOX_SPAWN_GEN") || inbox_write_rc=$?
    fi
    if [ "${inbox_write_rc:-0}" -ne 0 ]; then
      fm_lock_release "$INBOX_META_LOCK"
      echo "error: steer not sent to $INBOX_TASK_ID: its inbox record could not be written under $STATE/$INBOX_TASK_ID.inbox" >&2
      exit 1
    fi
    fm_lock_release "$INBOX_META_LOCK"
    # The answer is durably sent: close each answered decision at enqueue time
    # (answerer-closes; see the header contract).
    if [ -n "$RESOLVE_KEYS" ]; then
      fm_send_close_resolved_keys "$RESOLVE_ANSWER_TEXT" || exit 1
      fm_send_feed_resolved_holds "$RESOLVE_ANSWER_TEXT" || exit 1
    fi
    # Ring the doorbell, best-effort: no ring outcome changes the exit status,
    # because the watcher owns loss detection from here, either through its
    # bounded re-ring ladder or direct unavailable-endpoint recovery.
    ring_rc=0
    fm_task_inbox_ring "$TARGET_BACKEND" "$T" "$INBOX_RECORD" "$EXPECTED_LABEL" || ring_rc=$?
    case "$ring_rc" in
    2) echo "fm-send: doorbell did not reach $T; the steer is durably recorded at $INBOX_RECORD and the watcher will re-ring" >&2 ;;
    3) echo "fm-send: doorbell native submission skipped because the agent in $T has exited; the steer is durably recorded at $INBOX_RECORD for recovery (stuck-crewmate-recovery), and the watcher will not re-ring a dead pane" >&2 ;;
    4)
      if fm_wake_append stale "$T" "stale: $T (doorbell submission outcome is uncertain for $INBOX_RECORD; do not replay blindly; inspect the worker)"; then
        if ! fm_task_inbox_record_escalated "$STATE" "$INBOX_TASK_ID" "$INBOX_RECORD"; then
          echo "fm-send: uncertainty wake was queued for $T, but its inbox escalation marker could not be recorded; the watcher may report it again" >&2
        else
          echo "fm-send: doorbell submission to $T is uncertain; the steer remains at $INBOX_RECORD and will not be replayed blindly" >&2
        fi
      else
        echo "fm-send: uncertainty wake could not be queued for $T; leaving $INBOX_RECORD unmarked so the watcher can retry" >&2
      fi
      ;;
    esac
    exit 0
  fi
  # Submit once through the native backend API. API success means submitted,
  # not read or completed; uncertainty is loud and is never retried here.
  send_rc=0
  if verdict=$(fm_backend_send_text_submit "$TARGET_BACKEND" "$T" "$MESSAGE" 0 0 0 "$EXPECTED_LABEL"); then
    :
  else
    send_rc=$?
  fi
  if [ "$send_rc" -ne 0 ]; then
    echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  case "$verdict" in
  submitted)
    ;;
  send-failed)
    echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
    ;;
  unknown)
    echo "fm-send: text submission to $T is uncertain (tried $RESOLUTION_TRIED); do not retype or blindly resend - inspect the worker before deciding what happened" >&2
    exit 3
    ;;
  *)
    echo "error: text not submitted to $T (delivery unconfirmed; verdict=${verdict:-unknown}; tried $RESOLUTION_TRIED)" >&2
    exit 1
    ;;
  esac
  # Native submission was accepted: close each answered decision in this
  # home's ledger (answerer-closes; see the header contract).
  if [ -n "$RESOLVE_KEYS" ]; then
    fm_send_close_resolved_keys "$RESOLVE_ANSWER_TEXT" || exit 1
    fm_send_feed_resolved_holds "$RESOLVE_ANSWER_TEXT" || exit 1
  fi
  # Submission was accepted. It does not prove the worker read or completed it.
  # Keep the historical post-submit beat so an immediate peek can observe work.
  [ "${FM_SEND_SETTLE:-1}" = 0 ] || sleep "${FM_SEND_SETTLE:-1}"
fi
