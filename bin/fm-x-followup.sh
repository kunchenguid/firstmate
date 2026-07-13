#!/usr/bin/env bash
# Post a completion follow-up for an X-mode-linked task, up to three within a
# 7-day window, and manage the link's counter.
#
# An X-mode mention that spawned real work is linked to its task by fm-x-link.sh
# (x_request/x_request_ts/x_followups plus optional reply context in
# state/<id>.meta). When that task reaches a genuine milestone (investigation
# done, build started, shipped, failed), firstmate composes a public-safe outcome
# and posts it here as one of up to three follow-ups, within the window. Past the
# window, past the cap, or after --final, this clears the link so a later call is
# a clean no-op.
#
# Detection (no reply text needed - cheap pre-check before composing a reply):
#   fm-x-followup.sh --check <task-id>
#     exit 0, prints <request_id>  -> a follow-up is due (linked, within window
#                                      and cap)
#     exit 1, silent               -> not linked, or window/cap exhausted (link
#                                      pruned)
#
# Post (after composing the reply to a file or stdin):
#   fm-x-followup.sh <task-id> [--image <path>] [--final] --text-file <path>
#   fm-x-followup.sh <task-id> [--image <path>] [--final] -
#     Linked, within window, and under the cap: posts ONE follow-up via
#       fm-x-reply.sh --followup.
#       On success: increments the counter and KEEPS the link, unless --final
#       was passed or the new count reaches the cap, in which case the link is
#       cleared instead - this is the "we're done" signal.
#       On a relay rejection distinguishing an exhausted cap/window (see
#       fm-x-reply.sh): clears the link and skips quietly, exactly like a
#       locally-detected expiry, so an old relay (which only ever supported one
#       follow-up) or an already-exhausted binding degrades gracefully instead
#       of retrying forever.
#       On fm-x-reply's fail-safe refusal (exit 8: platform or explicit budget
#       unresolved): KEEPS the link and exits non-zero. This is a
#       retryable hold, not an exhausted binding - retry once both values are
#       recoverable rather than posting with a local default.
#       On any other post failure: leaves the link in place so it can be
#       retried, exit non-zero.
#     Window or cap already exhausted: clears the link, posts nothing, exit 0
#       (silent skip).
#     Not linked: nothing to do, exit 0.
#
# --final marks this as the outcome reply: it always clears the link after a
# successful post, even if follow-ups remain under the cap. Use it for the
# final milestone (shipped, failed) so a task never leaves a stale link lying
# around waiting for a follow-up that will never come.
#
# Dry-run (FMX_DRY_RUN) flows through fm-x-reply.sh: the follow-up is recorded to
# state/x-outbox/<request_id>.json instead of posted, and the counter/link are
# mutated exactly as a live post would (increment-and-keep, or clear on --final
# / cap), so the full loop runs end to end without a public post. With --image,
# the follow-up carries one local image attachment; if the reply text splits
# into a thread, the relay attaches the image to the opener.
#
# The window is FMX_FOLLOWUP_MAX_AGE_SECS (default 604800, 7 days). The cap is
# FMX_FOLLOWUP_MAX_COUNT (default 3). FMX_NOW_OVERRIDE pins "now" for
# deterministic tests. Meta read/write lives in fm-x-lib.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

usage() {
  echo "usage: fm-x-followup.sh --check <task-id> | <task-id> [--image <path>] [--final] --text-file <path> | <task-id> [--image <path>] [--final] -" >&2
}

help() {
  cat <<'EOF'
usage: fm-x-followup.sh --check <task-id>
       fm-x-followup.sh <task-id> [--image <path>] [--final] --text-file <path>
       fm-x-followup.sh <task-id> [--image <path>] [--final] -

Post a completion follow-up (up to 3 per link, within a 7-day window) for an
X-mode-linked task and manage the link's follow-up counter.

Options:
  --check          Print the request_id when a follow-up is due.
  --image <path>   Attach one local image file; threaded replies attach it to the opener tweet or message.
  --final          Clear the link after this post regardless of the remaining count.
  --text-file <path>
                   Read follow-up text from a file.
  -                Read follow-up text from stdin.
  --help           Show this help.
EOF
}

MAX_AGE=${FMX_FOLLOWUP_MAX_AGE_SECS:-604800}
case "$MAX_AGE" in
  ''|*[!0-9]*) MAX_AGE=604800 ;;
esac

MAX_COUNT=${FMX_FOLLOWUP_MAX_COUNT:-3}
case "$MAX_COUNT" in
  ''|*[!0-9]*) MAX_COUNT=3 ;;
esac
[ "$MAX_COUNT" -ge 1 ] 2>/dev/null || MAX_COUNT=3

# Parse mode: --check is detection-only; otherwise it is a post, with the text
# source (--text-file <path> | -) deferred until after the link/window/cap
# check so a missing or exhausted link never consumes stdin or posts.
MODE=post
case "${1:-}" in
  --help|-h) help; exit 0 ;;
esac

FINAL=0
if [ "${1:-}" = --check ]; then
  MODE=check
  ID=${2:-}
  if [ -z "$ID" ] || [ "$#" -gt 2 ]; then usage; exit 2; fi
else
  ID=${1:-}
  if [ -z "$ID" ]; then usage; exit 2; fi
  shift
  TS_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --final)
        FINAL=1
        ;;
      --image)
        TS_ARGS+=("$1")
        shift
        if [ "$#" -lt 1 ] || [ -z "$1" ]; then
          echo "fm-x-followup: missing --image path" >&2
          usage
          exit 2
        fi
        TS_ARGS+=("$1")
        ;;
      *) TS_ARGS+=("$1") ;;
    esac
    shift
  done
  if [ "${#TS_ARGS[@]}" -lt 1 ]; then usage; exit 2; fi
fi

case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) echo "fm-x-followup: unsafe task id: $ID" >&2; exit 2 ;;
esac

META="$STATE/$ID.meta"
RID=$(fmx_meta_get "$META" x_request)
TS=$(fmx_meta_get "$META" x_request_ts)
COUNT=$(fmx_meta_get "$META" x_followups)
REQ_PLATFORM=$(fmx_meta_get "$META" x_platform)
REQ_REPLY_MAX=$(fmx_meta_get "$META" x_reply_max_chars)
case "$COUNT" in
  ''|*[!0-9]*) COUNT=0 ;;
esac

# Not linked: this task did not originate from an X-mode mention. Detection fails;
# a post is simply a no-op success (firstmate need not special-case it).
if [ -z "$RID" ]; then
  if [ "$MODE" = check ]; then
    exit 1
  fi
  echo "fm-x-followup: $ID is not X-linked; nothing to post" >&2
  exit 0
fi

NOW=${FMX_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in
  ''|*[!0-9]*) echo "fm-x-followup: could not read the current time" >&2; exit 1 ;;
esac

# A missing or malformed timestamp cannot prove the follow-up is still in
# window, so treat it like an elapsed window: prune the link and skip. Being at
# or past the cap is pruned the same way.
EXPIRED=0
REASON="follow-up window elapsed"
case "$TS" in
  ''|*[!0-9]*) EXPIRED=1 ;;
  *) [ "$((NOW - TS))" -gt "$MAX_AGE" ] && EXPIRED=1 ;;
esac
if [ "$COUNT" -ge "$MAX_COUNT" ]; then
  EXPIRED=1
  REASON="follow-up cap reached"
fi

if [ "$EXPIRED" = 1 ]; then
  fmx_meta_link_clear "$META" || echo "fm-x-followup: warning: could not clear the elapsed link in state/$ID.meta" >&2
  if [ "$MODE" = check ]; then
    exit 1
  fi
  echo "fm-x-followup: $REASON for $ID; skipped and cleared the link" >&2
  exit 0
fi

# Linked, within window, and under the cap.
if [ "$MODE" = check ]; then
  printf '%s\n' "$RID"
  exit 0
fi

# Post the follow-up. fm-x-reply owns text reading, thread-split, dry-run, the
# endpoint, and the never-inline safety; we only pass the text source and any
# recorded reply-platform context through.
declare -a REPLY_ENV=()
case "$REQ_PLATFORM" in
  discord|x) REPLY_ENV+=("FMX_REPLY_PLATFORM=$REQ_PLATFORM") ;;
esac
case "$REQ_REPLY_MAX" in
  ''|*[!0-9]*) ;;
  *) REPLY_ENV+=("FMX_REPLY_MAX_CHARS=$REQ_REPLY_MAX") ;;
esac
if [ "${#REPLY_ENV[@]}" -gt 0 ]; then
  env "${REPLY_ENV[@]}" "$FM_ROOT/bin/fm-x-reply.sh" "$RID" --followup "${TS_ARGS[@]}" >/dev/null
else
  "$FM_ROOT/bin/fm-x-reply.sh" "$RID" --followup "${TS_ARGS[@]}" >/dev/null
fi
post_rc=$?

case "$post_rc" in
  0)
    NEWCOUNT=$((COUNT + 1))
    if [ "$FINAL" = 1 ] || [ "$NEWCOUNT" -ge "$MAX_COUNT" ]; then
      if ! fmx_meta_link_clear "$META"; then
        echo "fm-x-followup: error: posted but could not clear the link in state/$ID.meta" >&2
        exit 1
      fi
    elif ! fmx_meta_followups_set "$META" "$NEWCOUNT"; then
      if ! fmx_meta_link_clear "$META"; then
        echo "fm-x-followup: error: posted but could not record the follow-up count or clear the link in state/$ID.meta" >&2
        exit 1
      fi
      echo "fm-x-followup: warning: posted but could not record the follow-up count in state/$ID.meta; cleared the link to avoid duplicate follow-ups" >&2
    fi
    printf '%s\n' "$RID"
    exit 0
    ;;
  8)
    # fm-x-reply.sh refused this follow-up (exit 8) because it could not
    # authoritatively determine both the reply platform and explicit budget.
    # That is a RETRYABLE HOLD, not an exhausted binding: keep the link so
    # the follow-up can post once both values are recoverable. Never clear the
    # link here.
    echo "fm-x-followup: follow-up for $ID held: reply context lacks an authoritative platform or explicit budget; left the link in place to retry once both values are recoverable" >&2
    exit 1
    ;;
  9)
    # fm-x-reply.sh distinguishes a relay rejection of this specific follow-up
    # (cap or window exhausted relay-side) with exit 9. Treat it exactly like a
    # locally-detected expiry: clear the link and skip quietly. This is also the
    # graceful-degradation path against an old relay that only ever supported
    # one follow-up, or a binding the relay already considers exhausted for any
    # other reason - either way, retrying would never succeed.
    fmx_meta_link_clear "$META" || echo "fm-x-followup: warning: could not clear the rejected link in state/$ID.meta" >&2
    echo "fm-x-followup: relay rejected the follow-up for $ID (cap or window exhausted); skipped and cleared the link" >&2
    exit 0
    ;;
  *)
    # Post failed for another reason (network, auth, transport): leave the link
    # so firstmate can retry on a later pass.
    echo "fm-x-followup: follow-up post failed for $ID; left the link in place to retry" >&2
    exit 1
    ;;
esac
