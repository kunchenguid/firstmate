#!/usr/bin/env bash
# One short-poll of the relay connector for a pending X-mode mention.
#
# Inert by default: a HARD no-op (exit 0, no output) unless X mode is configured
# via a non-empty FMX_PAIRING_TOKEN (from the home's .env or the environment).
# The watcher invokes this trusted repository script directly only after
# state/x-watch.check.sh matches the expected byte-static identity shim.
# Its contract is "output => wake firstmate, silence => keep sleeping", so the
# no-op keeps the watcher behaving exactly as today until a user opts in.
#
# Behavior when X mode is on:
#   HTTP 204 / empty / missing text              -> print nothing, exit 0 (no wake)
#   auth/config errors                           -> print one rate-limited diagnostic
#   a newly offered mention with non-empty text -> stash the full object to
#       state/x-inbox/<request_id>.json, record the durable per-request reply
#       context to state/x-context/<request_id>.json (best-effort), atomically
#       claim state/x-context/<request_id>.offered.json, and print one compact
#       line "x-mention <request_id>" (which becomes the watcher wake payload)
#   an already offered request_id                -> print nothing, exit 0
#   a new set of unreconciled public-followup terminal results -> print one
#       "public-followup ..." line BEFORE the relay call, so a promised final
#       reply is surfaced through this same wake path
#
# The public-followup line rides here rather than on a new poll of its own: this
# check only exists in a home that opted into the relay, and it is an O(1)
# directory presence test plus a signature compare, with no tasks-axi call and no
# backlog scan. A home with no pending terminal results pays nothing for it.
# The full object is stashed verbatim, so every conversation-context field the
# relay includes is preserved for fmx-respond to handle with continuity; the
# Relay section of docs/configuration.md owns that payload's wire contract. The
# durable context record lets a delayed follow-up recover the ORIGINAL
# platform/budget even after this inbox file is drained.
#
# Config (home .env, FMX_ENV_FILE, or env): FMX_PAIRING_TOKEN (required),
# FMX_RELAY_URL (default https://myfirstmate.io). Auth: Authorization: Bearer
# <token>.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-public-followup-lib.sh
# Also brings in bin/fm-x-lib.sh, which this script's relay client uses.
. "$SCRIPT_DIR/fm-public-followup-lib.sh"

fmx_load_config
# Hard no-op when X mode is off: this is what keeps the check shim inert.
[ -n "$FMX_TOKEN" ] || exit 0

# Unreconciled terminal results for a public commitment are actionable even when
# the relay has no new mention, and they outlive any session, so surface them
# first. The signature compare keeps this to one wake per new result set instead
# of one per cycle; bin/fm-public-followup.sh consume clears it.
if fm_pf_has_events "$STATE"; then
  PF_ROOT=$(fm_pf_root "$STATE")
  PF_SIG=$(fm_pf_events_signature "$STATE" 2>/dev/null) || PF_SIG=
  if [ -n "$PF_SIG" ] \
    && [ "$(cat "$PF_ROOT/$FM_PF_SURFACED_BASENAME" 2>/dev/null || true)" != "$PF_SIG" ]; then
    if printf '%s\n' "$PF_SIG" \
      | fmx_private_artifact_publish_stdin "$PF_ROOT" "$FM_PF_SURFACED_BASENAME" 600 2>/dev/null; then
      printf 'public-followup terminal results are waiting to be reconciled\n'
    fi
  fi
fi

ERROR_FILE="$STATE/x-poll.error"
CLAIM_ERROR_FILE="$STATE/x-poll.claim-error"

emit_error_once() {
  local msg=$1
  if fmx_private_artifact_file_valid "$STATE" "x-poll.error" 600 \
    && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" \
    | fmx_private_artifact_publish_stdin "$STATE" "x-poll.error" 600 2>/dev/null || true
  printf 'x-mode-error %s\n' "$msg"
}

clear_error() {
  fmx_private_artifact_dir_device "$STATE" >/dev/null 2>&1 || return 0
  rm -f "$ERROR_FILE" 2>/dev/null || true
}

emit_claim_error_once() {
  local msg=$1
  if fmx_private_artifact_file_valid "$STATE" "x-poll.claim-error" 600 \
    && [ "$(cat "$CLAIM_ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" \
    | fmx_private_artifact_publish_stdin "$STATE" "x-poll.claim-error" 600 2>/dev/null || true
  printf 'x-mode-error %s\n' "$msg"
}

clear_claim_error() {
  fmx_private_artifact_dir_device "$STATE" >/dev/null 2>&1 || return 0
  rm -f "$CLAIM_ERROR_FILE" 2>/dev/null || true
}

command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; exit 0; }
command -v jq   >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }

fmx_context_registry_prune "$STATE"

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-x-poll.XXXXXX") || exit 0
AUTH_HEADER_FILE=
trap 'rm -f "$BODY_FILE" "$AUTH_HEADER_FILE"' EXIT
AUTH_HEADER_FILE=$(fmx_auth_header_file) || { emit_error_once "invalid token"; exit 0; }

# Short, bounded poll: a failure or timeout simply means "no wake this cycle";
# the next check cycle retries. -m 5 keeps this well inside the watcher's
# per-check timeout so the supervision loop is never starved.
code=$(curl -m 5 -s -o "$BODY_FILE" -w '%{http_code}' \
  -H "@$AUTH_HEADER_FILE" \
  -H 'Accept: application/json' \
  "$FMX_RELAY/connector/poll" 2>/dev/null) || exit 0

# 204 (nothing pending) is the common path; only 200 can carry a mention.
case "$code" in
  200) ;;
  204) clear_error; exit 0 ;;
  400|401|403|404) emit_error_once "relay returned HTTP $code"; exit 0 ;;
  *) exit 0 ;;
esac
[ -s "$BODY_FILE" ] || { clear_error; exit 0; }

REQ=$(jq -r '.request_id // empty' "$BODY_FILE" 2>/dev/null) || exit 0
[ -n "$REQ" ] || { clear_error; exit 0; }

# A pending mention only reaches the agent when it has non-empty text.
# Semantic worthiness is decided by fmx-respond, so acknowledgments can still be
# stashed here and deliberately skipped there.
# Empty/absent/null text must not stash an inbox file or wake a public X flow for
# nothing - stay inert (exit 0).
TEXT=$(jq -r '(.text // "") | gsub("[[:space:]]+"; " ") | gsub("^ +| +$"; "")' "$BODY_FILE" 2>/dev/null) || exit 0
[ -n "$TEXT" ] || { clear_error; exit 0; }

# Defend the inbox filename: request_id is relay-issued (e.g. "req-7"), but never
# trust it into a path. Reject anything outside a safe slug.
case "$REQ" in
  ''|.*|*[!A-Za-z0-9._-]*) clear_error; exit 0 ;;
esac

# The offer marker outlives the inbox file, which fmx-respond removes after a
# successful answer or dismiss. Checking it before the inbox stash keeps both a
# still-pending request and the relay's brief post-answer re-offer silent without
# recreating a drained inbox. The startup prune above bounds marker retention.
if fmx_private_artifact_file_valid "$STATE/x-context" "$REQ.offered.json" 600; then
  clear_error
  clear_claim_error
  exit 0
fi

INBOX="$STATE/x-inbox"
# Stash the full mention object atomically so a concurrent reader never sees a
# half-written file.
if ! (set -o pipefail; jq '.' "$BODY_FILE" 2>/dev/null \
  | fmx_private_artifact_publish_stdin "$INBOX" "$REQ.json" 600); then
  emit_error_once "cannot write inbox"
  exit 0
fi

# Record the durable per-request reply context from the authoritative relay
# payload, so a follow-up can recover the platform/budget even after this inbox
# file is drained and even when no task link survives (the single x_request per
# task collides across concurrent requests). Best-effort: the inbox stash above
# is the primary artifact and the relay lookup remains a fallback, so a registry
# write failure must never fail the poll or touch its one-line stdout wake
# payload. fmx_context_registry_set is a no-op when the platform is unknown.
POLL_CTX=$(fmx_extract_reply_context "$BODY_FILE" 2>/dev/null) || POLL_CTX=
if [ -n "$POLL_CTX" ]; then
  POLL_PLATFORM=$(printf '%s' "$POLL_CTX" | jq -r '.platform // ""' 2>/dev/null) || POLL_PLATFORM=
  POLL_MAX=$(printf '%s' "$POLL_CTX" | jq -r '.reply_max_chars // ""' 2>/dev/null) || POLL_MAX=
  fmx_context_registry_set "$STATE" "$REQ" "$POLL_PLATFORM" "$POLL_MAX" 2>/dev/null || true
fi

fmx_offer_registry_claim "$STATE" "$REQ"
offer_rc=$?
case "$offer_rc" in
  0) clear_error; clear_claim_error; printf 'x-mention %s\n' "$REQ" ;;
  1) clear_error; clear_claim_error; exit 0 ;;
  *) emit_claim_error_once "cannot record mention offer"; exit 0 ;;
esac
