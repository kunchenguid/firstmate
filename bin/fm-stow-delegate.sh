#!/usr/bin/env bash
# Dispatch the live-secondmate portion of an internal /stow cascade and wait
# for correlated completion receipts under one foreground bound.
# Usage: fm-stow-delegate.sh <secondmate-id>...
#
# Every id must name a kind=secondmate endpoint in this explicit FM_HOME.
# Requests are delivered through fm-send.sh, so each one keeps the existing
# durable pending-reply expectation and correlation contract.
# All requests are dispatched before receipt polling starts.
# The entire receipt wait shares FM_STOW_CASCADE_TIMEOUT seconds (default 60),
# regardless of how many secondmates were dispatched.
# A receipt that misses the bound remains pending and can still surface through
# the normal pending-reply wake path after this command returns.
#
# Each result is one blank-line-separated stanza:
#   secondmate=<id>
#   result=completed|pending|send-error
#   receipt=<correlated status line>  (completed only)
#   reason=<one line>                 (pending or send-error)
#
# Exit status: 0 every dispatched secondmate replied; 3 at least one result is
# pending or failed to send; 1 local setup failed; 2 invalid use.
set -u

usage() {
  sed -n '2,22{s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  printf 'error: FM_HOME is not set; stow delegation requires an explicit firstmate home\n' >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
if [ ! -d "$FM_HOME" ] || [ ! -d "$STATE" ]; then
  printf 'error: stow delegation home or state dir is missing: %s\n' "$FM_HOME" >&2
  exit 1
fi

# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

BOUND=${FM_STOW_CASCADE_TIMEOUT:-60}
case "$BOUND" in
  ""|*[!0-9]*)
    printf 'error: FM_STOW_CASCADE_TIMEOUT must be a positive integer: %s\n' "$BOUND" >&2
    exit 2
    ;;
esac
[ "$BOUND" -gt 0 ] || {
  printf 'error: FM_STOW_CASCADE_TIMEOUT must be a positive integer: %s\n' "$BOUND" >&2
  exit 2
}

for id in "$@"; do
  case "$id" in
    ""|*[!A-Za-z0-9._-]*)
      printf 'error: invalid secondmate id: %s\n' "$id" >&2
      exit 2
      ;;
  esac
  seen=0
  for prior in "$@"; do
    [ "$prior" = "$id" ] || continue
    seen=$((seen + 1))
    [ "$seen" -le 1 ] || {
      printf 'error: duplicate secondmate id: %s\n' "$id" >&2
      exit 2
    }
  done
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-stow-delegate.XXXXXX") || exit 1
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap.
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
REQUEST='Run /stow for your home and report its completion receipt. Include the request correlation token in the parent status reply.'
RESULTS="$TMP/results"
: > "$RESULTS"
incomplete=0

for id in "$@"; do
  corr=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$id" "$REQUEST") || {
    printf 'error: failed to create the pending stow receipt for %s\n' "$id" >&2
    exit 1
  }
  if env FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SCRIPT_DIR/fm-send.sh" "fm-$id" "$REQUEST"; then
    printf '%s\t%s\tdispatched\n' "$id" "$corr" >> "$RESULTS"
  else
    fm_pending_reply_discard_undelivered "$STATE" "$corr" >/dev/null 2>&1 || true
    printf '%s\t%s\tsend-error\n' "$id" "$corr" >> "$RESULTS"
    incomplete=1
  fi
done

deadline=$(( $(date +%s) + BOUND ))
while :; do
  waiting=0
  while IFS=$'\t' read -r id corr dispatch; do
    [ "$dispatch" = dispatched ] || continue
    if ! fm_pending_reply_try_resolve "$STATE" "$corr" >/dev/null 2>&1; then
      waiting=1
    fi
  done < "$RESULTS"
  [ "$waiting" -eq 1 ] || break
  [ "$(date +%s)" -lt "$deadline" ] || break
  sleep 1
done

while IFS=$'\t' read -r id corr dispatch; do
  printf '\nsecondmate=%s\n' "$id"
  if [ "$dispatch" = send-error ]; then
    printf 'result=send-error\n'
    printf 'reason=the marked stow request was not delivered\n'
    continue
  fi
  if fm_pending_reply_try_resolve "$STATE" "$corr" >/dev/null 2>&1; then
    receipt=$(fm_pending_reply_find_resolve_line "$STATE/$id.status" "$corr")
    printf 'result=completed\n'
    printf 'receipt=%s\n' "$receipt"
  else
    printf 'result=pending\n'
    printf 'reason=foreground wait reached %ss; reply remains durable\n' "$BOUND"
    incomplete=1
  fi
done < "$RESULTS"

[ "$incomplete" -eq 0 ] || exit 3
exit 0
