#!/usr/bin/env bash
# Send a completion follow-up for a Telegram-linked task to the captain's phone.
#
# Usage:
#   fm-tg-followup.sh --check <task-id>
#   fm-tg-followup.sh <task-id> [--final] --text-file <path>
#   fm-tg-followup.sh <task-id> [--final] -
#
# --check prints the linked note id and exits 0 when a follow-up is still due
# (a tg_note= link exists, the count is under the cap, and the window has not
# lapsed); it is silent and exits 1 otherwise, pruning an exhausted or expired
# link. An unlinked task is a silent exit-1 no-op.
#
# A send reads the follow-up text from --text-file <path> or stdin (-), NEVER
# from a shell argument, and pipes it on stdin to the phone-inbox outbound
# client `tg` (FMTG_TG_BIN overrides the default ~/dev/phone-inbox/tg, e.g.
# for tests). Note-influenced text therefore never transits a shell command
# line. A REAL send notifies the captain's phone - never send one as a test.
#
# On a successful non-final send the local tg_followups= counter increments and
# the link is kept unless the new count reaches the cap, in which case the link
# is cleared. --final always clears the link after the send. A send past the
# window or cap is skipped silently and the link is cleared. A failed send
# leaves the link and counter untouched so it can be retried.
#
# The message is already on the captain's phone once tg returns, so a
# post-send meta write that fails must never let the same follow-up be spent
# twice: if the counter write fails, the link is cleared instead (a warning on
# stderr, still exit 0), which costs the remaining budget rather than risking a
# duplicate. Only when that fallback clear ALSO fails does the send report a
# failure.
#
# The cap and window are local policy, not a transport limit (there is no relay
# binding to expire): FMTG_FOLLOWUP_MAX_COUNT defaults to 3 non-final
# follow-ups and FMTG_FOLLOWUP_MAX_AGE_SECS to 604800 (7 days).
# FMTG_NOW_OVERRIDE keeps tests deterministic.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  echo "usage: fm-tg-followup.sh --check <task-id> | fm-tg-followup.sh <task-id> [--final] --text-file <path> | fm-tg-followup.sh <task-id> [--final] -" >&2
}

MODE=send
ID=
FINAL=0
TEXT_FILE=
STDIN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)
      MODE=check
      ;;
    --final)
      FINAL=1
      ;;
    --text-file)
      shift
      TEXT_FILE=${1:-}
      [ -n "$TEXT_FILE" ] || { usage; exit 2; }
      ;;
    -)
      STDIN=1
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      [ -z "$ID" ] || { usage; exit 2; }
      ID=$1
      ;;
  esac
  shift
done

[ -n "$ID" ] || { usage; exit 2; }
fm_pr_task_id_valid "$ID" || { echo "fm-tg-followup: unsafe task id: $ID" >&2; exit 2; }
META="$STATE/$ID.meta"

MAX_COUNT=${FMTG_FOLLOWUP_MAX_COUNT:-3}
case "$MAX_COUNT" in
  ''|*[!0-9]*) MAX_COUNT=3 ;;
esac
MAX_AGE=${FMTG_FOLLOWUP_MAX_AGE_SECS:-604800}
case "$MAX_AGE" in
  ''|*[!0-9]*) MAX_AGE=604800 ;;
esac
NOW=${FMTG_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in
  ''|*[!0-9]*) echo "fm-tg-followup: could not read the current time" >&2; exit 1 ;;
esac

NID=$(fmx_meta_get "$META" tg_note)
TS=$(fmx_meta_get "$META" tg_note_ts)
COUNT=$(fmx_meta_get "$META" tg_followups)
case "$COUNT" in
  ''|*[!0-9]*) COUNT=0 ;;
esac

# No link is a quiet non-event for both modes: the task simply did not come
# from a Telegram note.
[ -n "$NID" ] || exit 1

expired_or_exhausted() {
  case "$TS" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ $((NOW - TS)) -gt "$MAX_AGE" ] && return 0
  [ "$COUNT" -ge "$MAX_COUNT" ] && [ "$FINAL" -eq 0 ] && return 0
  return 1
}

if [ "$MODE" = check ]; then
  if expired_or_exhausted; then
    fmtg_meta_link_clear "$META" >/dev/null 2>&1 || true
    exit 1
  fi
  printf '%s\n' "$NID"
  exit 0
fi

if expired_or_exhausted; then
  # Past the window or cap: skip silently and clear the link - never treated
  # as a failure worth retrying (mirrors the X follow-up contract).
  fmtg_meta_link_clear "$META" >/dev/null 2>&1 || true
  exit 0
fi

if [ -n "$TEXT_FILE" ] && [ "$STDIN" -eq 1 ]; then
  usage
  exit 2
fi
if [ -z "$TEXT_FILE" ] && [ "$STDIN" -eq 0 ]; then
  usage
  exit 2
fi

TEXT=
if [ -n "$TEXT_FILE" ]; then
  [ -f "$TEXT_FILE" ] || { echo "fm-tg-followup: no such text file: $TEXT_FILE" >&2; exit 1; }
  TEXT=$(cat "$TEXT_FILE") || exit 1
else
  TEXT=$(cat) || exit 1
fi
STRIPPED=$(printf '%s' "$TEXT" | tr -d '[:space:]')
[ -n "$STRIPPED" ] || { echo "fm-tg-followup: refusing to send an empty follow-up" >&2; exit 2; }

TG_BIN=${FMTG_TG_BIN:-$HOME/dev/phone-inbox/tg}
if [ ! -f "$TG_BIN" ] || [ ! -x "$TG_BIN" ]; then
  echo "fm-tg-followup: phone-inbox tg client not runnable at $TG_BIN" >&2
  exit 1
fi

# The text travels on stdin only; tg owns the Telegram message limit.
if ! printf '%s' "$TEXT" | "$TG_BIN"; then
  echo "fm-tg-followup: tg send failed; link kept for retry" >&2
  exit 1
fi

if [ "$FINAL" -eq 1 ]; then
  fmtg_meta_link_clear "$META" || {
    echo "fm-tg-followup: sent, but failed to clear the link in state/$ID.meta" >&2
    exit 1
  }
  printf 'final follow-up sent for %s (note %s)\n' "$ID" "$NID"
  exit 0
fi

NEW_COUNT=$((COUNT + 1))
if [ "$NEW_COUNT" -ge "$MAX_COUNT" ]; then
  fmtg_meta_link_clear "$META" || {
    echo "fm-tg-followup: sent, but failed to clear the exhausted link in state/$ID.meta" >&2
    exit 1
  }
else
  fmtg_meta_followups_set "$META" "$NEW_COUNT" || {
    fmtg_meta_link_clear "$META" || {
      echo "fm-tg-followup: sent, but failed to record the follow-up count or clear the link in state/$ID.meta" >&2
      exit 1
    }
    echo "fm-tg-followup: warning: sent, but failed to record the follow-up count in state/$ID.meta; cleared the link to avoid duplicate follow-ups" >&2
  }
fi
printf 'follow-up %s/%s sent for %s (note %s)\n' "$NEW_COUNT" "$MAX_COUNT" "$ID" "$NID"
