#!/usr/bin/env bash
# Send one line of literal text to a crewmate endpoint, then Enter.
# Usage: fm-send.sh <target> <text...>
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit well-formed backend
#   target. fm-send refuses unresolved guesses rather than falling back to a
#   tmux window search, because a "successful" send to the wrong endpoint is
#   worse than a loud failure.
# Special keys instead of text: fm-send.sh <target> --key Enter
# Key support is backend-specific: tmux/herdr support Escape, Enter, and C-c;
# Orca currently supports Enter and C-c only, and rejects Escape.
#
# Text submission is verified: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the target backend confirms a
# submit or reports an inconclusive send. If a swallowed Enter is positively
# confirmed, fm-send exits NON-ZERO so the caller knows the steer did not land
# instead of silently leaving an unsubmitted instruction.
# Submission dispatches through the target's recorded backend; the tmux adapter
# shares its composer/submit core with the away-mode daemon via bin/fm-tmux-lib.sh.
# Tune with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP (0.4).
# Slash commands, and codex `$...` skill invocations resolved through harness
# meta, get a longer pre-Enter settle so completion popups do not swallow Enter.
# Herdr text sends also require a positively identified empty composer before
# staging text. A modal, pending input, unreadable pane, or malformed detector
# result fails closed before fm-send presses any key.
#
# From-firstmate marker: when the resolved target is a task selector whose meta
# records kind=secondmate, the text is prefixed with the from-firstmate marker
# (bin/fm-marker-lib.sh) so the secondmate routes its reply via its status file
# or a status-pointed doc instead of stranding it in chat the main firstmate
# never reads. A crewmate/scout target, an explicit backend-target escape-hatch
# target, and the --key path are never marked - their behavior is unchanged.
# A secondmate whose meta ALSO records placement=azure is a cloud compartment:
# its marked text is not typed anywhere - it becomes one durable, canonical,
# content-addressed envelope in state/<id>.cloud-inbox/<seq>-<sha256>.json that
# bin/fm-secondmate-cloud-monitor.sh relays to the worker, and --key is refused
# (there is no composer). Only meta written by the gated cloud secondmate spawn
# selects this route, so every other send path is byte-identical.
# Successful text steering for a managed account task is also appended to the
# task-owned data/<id>/steering.md trail for provider-neutral continuation.
# After a successful text submit fm-send pauses FM_SEND_SETTLE seconds (default 1,
# 0 disables) before returning: submit confirmation only proves the text was
# accepted, but the harness needs a beat to spin up the turn before its busy
# footer appears, so an immediate peek would otherwise see the stale idle pane.
# The pause is fm-send-only; the shared submit core (used by the away-mode daemon,
# which only needs "submitted") does not pay it, and the --key path is unaffected.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-send refuses to resolve targets without an explicit firstmate home" >&2
  exit 1
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
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
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"

FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the requested message WILL still be sent.' "$SCRIPT_DIR/fm-guard.sh" || true

fm_send_id_from_meta() {  # <meta-file>
  local base
  base=${1##*/}
  printf '%s' "${base%.meta}"
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
  RESOLUTION_TRIED=""

  meta=$(fm_backend_meta_for_selector "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
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
    id=$(fm_send_id_from_meta "$meta")
    EXPECTED_LABEL="fm-$id"
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

fm_backend_validate "$TARGET_BACKEND" || exit 1

# Classify a from-firstmate -> secondmate request. Only a task selector resolved
# through this home's meta whose authoritative kind is secondmate is marked: the
# secondmate then routes its reply via the status path (see fm-marker-lib.sh).
# An explicit backend target (the escape hatch for endpoints outside this home)
# and any crewmate/scout target are left unmarked, and so is the --key path.
MARK_FROM_FIRSTMATE=0
if [ -n "$TARGET_SELECTOR" ] && [ -n "$TARGET_META" ] && [ "$(fm_meta_get "$TARGET_META" kind)" = secondmate ]; then
  MARK_FROM_FIRSTMATE=1
fi

# Cloud secondmate compartment routing (R2/R3 design B.4). A secondmate whose
# durable meta records placement=azure has no local composer at all: its agent
# runs on an elastic worker and its inbound lane is the compartment inbox that
# bin/fm-secondmate-cloud-monitor.sh relays through the claim-exempt
# message-put. The classification is driven ONLY by durable meta this home's
# own gated spawn wrote (kind=secondmate + placement=azure), so every existing
# local secondmate and crewmate send path is byte-identical.
CLOUD_SECONDMATE_ROUTE=0
if [ "$MARK_FROM_FIRSTMATE" = 1 ] && [ "$(fm_meta_get "$TARGET_META" placement)" = azure ]; then
  CLOUD_SECONDMATE_ROUTE=1
fi

fm_send_cloud_secondmate_enqueue() {  # <marked-message-text>
  # One durable inbox envelope per send: the exact canonical JSON message the
  # session runner's closed inbox schema accepts ({kind, text, nonce}), named
  # <seq>-<sha256>.json where the digest is the content address of the file
  # bytes - the monitor uploads the file VERBATIM, so this name digest equals
  # the session/in/<sha256>.json blob the runner verifies and dedupes on.
  # The assignment generation rides INSIDE the nonce: the runner's schema
  # refuses any unknown envelope key, and nonce is its one documented
  # free-form field, so the delivery-fencing generation stamp lives there
  # (runner-side refusal of a foreign generation is deferred to a runner
  # change and documented in the PR that added this routing). The nonce also
  # makes two sends of identical text distinct messages instead of one
  # deduped blob. Sequencing claims .claims/<seq> with O_EXCL so concurrent
  # sends never share a sequence number.
  local send_id assignment send_generation
  send_id=$(fm_send_id_from_meta "$TARGET_META")
  # The controller's CURRENT assignment is the authority: meta records the
  # spawn-time assignment once, but a resume mints a new assignment
  # generation, and an envelope fenced to the dead one would misname every
  # message for the rest of the compartment's life. Meta is only the
  # fallback for a controller that is momentarily unreadable.
  send_generation=$(fm_meta_get "$TARGET_META" generation_id)
  assignment=$(python3 - "$STATE/azure-workers/controller.json" "$send_id" "$send_generation" <<'PY'
import json
import sys

path, task, generation = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(0)
item = (state.get("queue") or {}).get("{}@{}".format(task, generation)) or {}
if item.get("status") == "assigned" and item.get("assignment_generation"):
    print(item["assignment_generation"])
PY
  ) || assignment=
  [ -n "$assignment" ] || assignment=$(fm_meta_get "$TARGET_META" worker_assignment_generation)
  if [ -z "$assignment" ]; then
    echo "error: cloud secondmate $send_id has no worker assignment yet; run bin/fm-worker-lifecycle.sh reconcile --apply and retry so the message envelope can be generation-fenced" >&2
    return 1
  fi
  python3 - "$STATE/$send_id.cloud-inbox" "$assignment" "$1" <<'PY' || return 1
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

inbox, assignment, text = sys.argv[1:]
inbox = Path(inbox)
claims = inbox / ".claims"
claims.mkdir(parents=True, exist_ok=True, mode=0o700)
os.chmod(inbox, 0o700)
existing = [
    int(path.name) for path in claims.iterdir()
    if path.name.isdigit() and len(path.name) == 8
]
sequence = max(existing) + 1 if existing else 1
for _attempt in range(10000):
    try:
        fd = os.open(str(claims / "{:08d}".format(sequence)), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        sequence += 1
        continue
    os.close(fd)
    break
else:
    print("error: could not claim a cloud inbox sequence", file=sys.stderr)
    raise SystemExit(1)
message = {
    "kind": "fm.secondmate-message/v1",
    "text": text,
    "nonce": "{}/{:08d}".format(assignment, sequence),
}
body = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
if len(body) > 256 * 1024:
    print("error: message exceeds the 262144-byte compartment envelope cap", file=sys.stderr)
    raise SystemExit(1)
name = "{:08d}-{}.json".format(sequence, hashlib.sha256(body).hexdigest())
fd, staging = tempfile.mkstemp(prefix=".fm-send-", dir=str(inbox))
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(body)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(staging, str(inbox / name))
finally:
    try:
        os.unlink(staging)
    except FileNotFoundError:
        pass
print(str(inbox / name))
PY
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

MANAGED_LIFECYCLE_LOCK=
MANAGED_STEERING_ID=
EXPECTED_ACCOUNT_PROFILE=
EXPECTED_GENERATION=
RECORDED_SCOPED_TARGET=
if [ -n "$TARGET_META" ]; then
  EXPECTED_ACCOUNT_PROFILE=$(fm_meta_get "$TARGET_META" account_profile)
  [ "$TARGET_BACKEND" != tmux ] || RECORDED_SCOPED_TARGET=$(fm_meta_get "$TARGET_META" tmux_session_target)
fi
if [ -n "$EXPECTED_ACCOUNT_PROFILE" ]; then
  MANAGED_STEERING_ID=$(fm_send_id_from_meta "$TARGET_META")
  EXPECTED_GENERATION=$(fm_meta_get "$TARGET_META" generation_id)
  [ -n "$EXPECTED_GENERATION" ] || {
    echo "error: managed task metadata has no generation_id: $TARGET_META" >&2
    exit 1
  }
  MANAGED_LIFECYCLE_LOCK=$(fm_account_lifecycle_lock_acquire "$STATE" "$MANAGED_STEERING_ID") || exit 1
  cleanup_managed_send_lifecycle() {
    [ -z "$MANAGED_LIFECYCLE_LOCK" ] \
      || fm_account_lifecycle_lock_release "$MANAGED_LIFECYCLE_LOCK" >/dev/null 2>&1 \
      || true
  }
  trap cleanup_managed_send_lifecycle EXIT
  trap 'exit 1' HUP INT TERM
  if [ ! -f "$TARGET_META" ] || [ -L "$TARGET_META" ] \
    || [ "$(fm_meta_get "$TARGET_META" generation_id)" != "$EXPECTED_GENERATION" ] \
    || [ "$(fm_meta_get "$TARGET_META" account_profile)" != "$EXPECTED_ACCOUNT_PROFILE" ] \
    || [ "$(fm_backend_of_meta "$TARGET_META")" != "$TARGET_BACKEND" ] \
    || [ "$(fm_backend_target_of_meta "$TARGET_META")" != "$T" ]; then
    echo "error: managed task generation or endpoint changed while fm-send waited for $MANAGED_STEERING_ID" >&2
    exit 1
  fi
fi

if [ "${1:-}" = "--key" ]; then
  if [ "$CLOUD_SECONDMATE_ROUTE" = 1 ]; then
    echo "error: '$RAW_TARGET' is a cloud secondmate compartment with no local composer; --key cannot reach it - send text instead, which routes through the compartment inbox" >&2
    exit 1
  fi
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$2" "$EXPECTED_LABEL" "$RECORDED_SCOPED_TARGET"; then
    echo "error: key '$2' not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  if [ -n "$MANAGED_LIFECYCLE_LOCK" ]; then
    if fm_account_lifecycle_lock_release "$MANAGED_LIFECYCLE_LOCK"; then
      MANAGED_LIFECYCLE_LOCK=
    else
      echo "warning: key '$2' was sent to $T but its managed lifecycle lock could not be released cleanly" >&2
    fi
  fi
else
  MESSAGE=$*
  if [ "$MARK_FROM_FIRSTMATE" = 1 ]; then
    fm_message_mark_from_firstmate "$MESSAGE" MESSAGE
  fi
  if [ "$CLOUD_SECONDMATE_ROUTE" = 1 ]; then
    # The marked text is enqueued durably; the compartment monitor relays it
    # through the claim-exempt message-put and the guest polls it within its
    # poll interval. No pane is typed into and no submit is verified here -
    # the durable envelope plus the monitor's relay receipt are the delivery
    # evidence for this lane.
    ENVELOPE=$(fm_send_cloud_secondmate_enqueue "$MESSAGE") || exit 1
    echo "queued for cloud secondmate '$RAW_TARGET': $ENVELOPE (relayed by fm-secondmate-cloud-monitor)"
    exit 0
  fi
  persist_managed_steering() (  # <file-name> <header> <annotation> <message...>
    local file_name=$1 header=$2 annotation=$3
    shift 3
    local steering_id steering_dir steering_file steering_lock
    steering_id=$(fm_send_id_from_meta "$TARGET_META")
    steering_lock=$(fm_account_lock_acquire "$STATE" "$steering_id" account-steering "managed steering" "${FM_ACCOUNT_STEERING_LOCK_WAIT_SECONDS:-10}") || return 1
    trap 'fm_account_meta_lock_release "$steering_lock" >/dev/null 2>&1 || true' EXIT
    trap 'exit 1' HUP INT TERM
    steering_dir=$(fm_account_task_dir "$DATA" "$steering_id" create) || return 1
    steering_file="$steering_dir/$file_name"
    fm_account_safe_task_file "$steering_file" || return 1
    {
      printf -- '- %s%s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$annotation"
      if [ "$#" -gt 0 ]; then
        printf '%s\n' "$*" | sed 's/^/> /'
        printf '\n'
      fi
    } | node "$SCRIPT_DIR/fm-task-file-append.mjs" "$DATA" "$steering_id" "$file_name" "$header"
  )
  record_managed_steering() {
    persist_managed_steering steering.md '# Steering trail' '' "$@"
  }
  record_pending_managed_steering() {
    persist_managed_steering steering-pending.md '' ' (delivered; steering trail append pending)' "$@"
  }
  record_unconfirmed_managed_steering() {
    persist_managed_steering steering-unconfirmed.md '# Unconfirmed steering' ' (delivery unconfirmed)' "$@"
  }
  record_managed_delivery_event() {
    if [ "$#" -gt 1 ]; then
      persist_managed_steering steering-journal.md '# Steering delivery journal' " (intent $STEERING_EVENT_ID $1)" "$2"
    else
      persist_managed_steering steering-journal.md '# Steering delivery journal' " (intent $STEERING_EVENT_ID $1)"
    fi
  }
  if [ -n "$MANAGED_STEERING_ID" ]; then
    STEERING_EVENT_ID=$(python3 -c 'import secrets; print(secrets.token_hex(16))') || {
      echo "error: could not allocate a managed steering intent id" >&2
      exit 1
    }
    if ! record_managed_delivery_event pending "$MESSAGE"; then
      echo "error: managed steering intent could not be durably recorded before delivery" >&2
      exit 1
    fi
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
  # A Herdr Enter is terminal input, not a semantic "submit this composer"
  # operation. Prove that the target is an empty agent composer before staging
  # text; every other outcome refuses before send_text_submit can type or press
  # anything. This is deliberately Herdr-scoped because it is the established
  # affected retry path and its adapter already exposes a structural composer
  # classifier. Do not weaken unknown into success: a permission modal has no
  # composer row and therefore reaches exactly that refusal branch.
  if [ "$TARGET_BACKEND" = herdr ]; then
    composer_state=$(fm_backend_composer_state "$TARGET_BACKEND" "$T" 2>/dev/null) \
      || composer_state=unknown
    case "$composer_state" in
      empty) ;;
      pending)
        [ -z "$MANAGED_STEERING_ID" ] || record_managed_delivery_event not-submitted >/dev/null 2>&1 || true
        echo "error: text not sent to $T (Herdr composer already contains pending input; refusing to type or press Enter; tried $RESOLUTION_TRIED)" >&2
        exit 1
        ;;
      *)
        [ -z "$MANAGED_STEERING_ID" ] || record_managed_delivery_event not-submitted >/dev/null 2>&1 || true
        echo "error: text not sent to $T (could not prove an empty Herdr composer; a modal or unreadable state is unsafe, so no text or key was sent; tried $RESOLUTION_TRIED)" >&2
        exit 1
        ;;
    esac
  fi
  # Type once, submit, verify. The preflight above has already rejected an
  # unreadable starting state; this adapter verdict now describes only the
  # submission attempt that began from a positively empty composer.
  if ! verdict=$(fm_backend_send_text_submit "$TARGET_BACKEND" "$T" "$MESSAGE" "$retries" "$sleep_s" "$settle" "$EXPECTED_LABEL" "$RECORDED_SCOPED_TARGET"); then
    [ -z "$MANAGED_STEERING_ID" ] || record_managed_delivery_event send-failed >/dev/null 2>&1 || true
    echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  if [ -n "${FM_SEND_TEST_AFTER_SUBMIT_READY:-}" ] && [ -n "${FM_SEND_TEST_AFTER_SUBMIT_PROCEED:-}" ]; then
    : > "$FM_SEND_TEST_AFTER_SUBMIT_READY"
    while [ ! -e "$FM_SEND_TEST_AFTER_SUBMIT_PROCEED" ]; do sleep 0.01; done
  fi
  case "$verdict" in
    pending)
      [ -z "$MANAGED_STEERING_ID" ] || record_managed_delivery_event not-submitted >/dev/null 2>&1 || true
      echo "error: text not submitted to $T (Enter swallowed; text left in composer; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
    send-failed)
      [ -z "$MANAGED_STEERING_ID" ] || record_managed_delivery_event send-failed >/dev/null 2>&1 || true
      echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
  esac
  if [ -n "$MANAGED_STEERING_ID" ]; then
    if [ "$verdict" = unknown ]; then
      record_managed_delivery_event unconfirmed >/dev/null 2>&1 || true
      if record_unconfirmed_managed_steering "$MESSAGE"; then
        echo "warning: text delivery to $T could not be confirmed and was durably recorded as unconfirmed" >&2
      else
        echo "warning: text delivery to $T could not be confirmed or durably recorded" >&2
      fi
    else
      record_managed_delivery_event confirmed >/dev/null 2>&1 || true
    fi
    if [ "$verdict" != unknown ] && ! record_managed_steering "$MESSAGE"; then
      if record_pending_managed_steering "$MESSAGE"; then
        echo "warning: text was sent to $T and durably recorded as pending because its managed steering trail could not be appended" >&2
      else
        echo "warning: text was sent to $T but its managed steering delivery could not be durably recorded" >&2
      fi
    fi
    if fm_account_lifecycle_lock_release "$MANAGED_LIFECYCLE_LOCK"; then
      MANAGED_LIFECYCLE_LOCK=
    elif [ "$verdict" = unknown ]; then
      echo "warning: text delivery to $T was unconfirmed and its managed lifecycle lock could not be released cleanly" >&2
    else
      echo "warning: text was sent to $T but its managed lifecycle lock could not be released cleanly" >&2
    fi
  fi
  # The submit attempt finished without a positively-confirmed pending composer. Confirmation only proves
  # the text was accepted; the harness still needs a beat to spin up the
  # turn before its busy footer shows. Pause so an immediate peek catches the
  # crewmate actually working instead of the stale idle pane. FM_SEND_SETTLE=0
  # disables it. Scoped to this path only, never the shared submit core.
  [ "${FM_SEND_SETTLE:-1}" = 0 ] || sleep "${FM_SEND_SETTLE:-1}"
fi
