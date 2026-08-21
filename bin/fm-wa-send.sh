#!/usr/bin/env bash
# Send one WhatsApp reply to the captain from this home.
#
# Usage:
#   fm-wa-send.sh --text-file <path> [--to <number>]
#   fm-wa-send.sh --text '<message>' [--to <number>]
#
# Outbound rides mudslide's existing linked device, completely untouched by the
# inbound listener: the listener owns a SEPARATE credential folder precisely so
# arming it can never break sending. This script adds a dry-run and an echo
# marker on top of `mudslide send`; it changes nothing about how mudslide works.
#
# Message text is read from a file and handed to mudslide as a single argument
# vector element, after a `--` that ends mudslide's own option parsing so text
# beginning with a dash is still text. It is never interpolated into a command
# string, never passed through eval or sh -c, and never used to build a path, so
# a reply quoting the captain's own words cannot become execution.
#
# A failed send reports mudslide's own output, because a reply that silently
# never arrives is the one failure this channel cannot afford.
#
# FM_WA_DRY_RUN=1 (or FM_WA_DRY_RUN in config/whatsapp.env) records what WOULD
# be sent to state/wa-outbox/ and sends nothing, so the whole
# poll -> wake -> compose -> would-send loop can be exercised without live
# traffic. It records one entry per recipient, matching the deliveries and the
# echo markers a real send makes, because the dry run is the only place the
# fan-out can be inspected before it reaches the captain's phones.
#
# Every send also records a digest of its normalized text under state/wa-sent/,
# one marker per recipient, because each delivery echoes back separately and the
# listener consumes one marker per echo. The listener consumes those markers if
# the same text arrives back, which is the second line of defence (behind the
# sender-device filter) against firstmate reading its own replies as new captain
# instructions. A dry run records the same markers so the loop behaves
# identically either way.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-wa-lib.sh
. "$SCRIPT_DIR/fm-wa-lib.sh"

usage() {
  echo "usage: fm-wa-send.sh --text-file <path> [--to <number>]" >&2
  echo "       fm-wa-send.sh --text '<message>' [--to <number>]" >&2
}

TEXT_FILE=
TEXT=
TO=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --text-file) TEXT_FILE=${2-}; shift 2 || { usage; exit 2; } ;;
    --text) TEXT=${2-}; shift 2 || { usage; exit 2; } ;;
    --to) TO=${2-}; shift 2 || { usage; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if ! fm_wa_load_config; then
  if [ -n "${FM_WA_CONFIG_ERROR:-}" ]; then
    echo "error: WhatsApp channel is off; $FM_WA_CONFIG_ERROR" >&2
  else
    echo "error: WhatsApp channel is off; no FM_WA_CAPTAIN in ${FM_WA_CONFIG_FILE:-config/whatsapp.env}" >&2
  fi
  exit 1
fi

if [ -n "$TEXT_FILE" ]; then
  [ -f "$TEXT_FILE" ] || { echo "error: message file is unavailable" >&2; exit 1; }
  TEXT=$(cat -- "$TEXT_FILE") || { echo "error: cannot read the message file" >&2; exit 1; }
fi
[ -n "$TEXT" ] || { usage; exit 2; }

# With no explicit recipient the reply goes to EVERY configured captain number,
# because he carries more than one phone and an update that reaches only one of
# them is an update he may never see. An explicit --to still addresses exactly
# one, which is how a reply follows an inbound message back to where it came
# from. RECIPIENTS is a space-separated list of digits; the config parse has
# already rejected anything that is not a number.
if [ -n "$TO" ]; then
  RECIPIENTS=$(printf '%s' "$TO" | tr -cd '0-9')
else
  RECIPIENTS=$FM_WA_CAPTAIN
fi
[ -n "$RECIPIENTS" ] || { echo "error: recipient must be a number in international form" >&2; exit 1; }

# Proved present BEFORE the echo marker below is written, not after it. The
# marker outlives this command by the listener's whole echo window, and a marker
# left behind by a reply that never went out is exactly what swallows the
# captain saying those same words himself. Both failure paths further down drop
# the marker for that reason; this one refuses before there is one to drop. A
# dry run sends nothing, so it needs no mudslide and is not held to this.
if [ -z "$FM_WA_DRY_RUN" ] && ! command -v mudslide >/dev/null 2>&1; then
  echo "error: mudslide is not installed" >&2
  exit 1
fi

# Normalized digest, matching what the listener computes on inbound text.
# The marker is short-lived by contract: the listener ignores and prunes any
# digest older than its echo window, so a reply the captain never echoes back
# cannot sit there forever waiting to swallow those exact words from him.
NORMALIZED=$(printf '%s' "$TEXT" | fm_wa_normalize_text)
DIGEST=$(printf '%s' "$NORMALIZED" | fm_wa_sha256) || DIGEST=
# ONE MARKER PER RECIPIENT, not one per send. Each delivery echoes back on its
# own message id, and the listener consumes exactly one marker per echo, so a
# single marker would be spent by the first echo and leave every later one
# unguarded - which under FM_WA_ALLOW_DEVICES=* is firstmate reading its own
# reply back as a fresh captain instruction. The index also lets a recipient
# that never got the message drop its own marker below and no one else's.
#
# The name is keyed to THIS send as well as to the text. The publish is an
# atomic rename, so naming a marker by digest and index alone would let a second
# send of identical words inside the echo window REWRITE the first send's
# markers instead of adding to them, leaving twice the echoes with half the
# markers - the same ledger imbalance one marker per send had, one level up.
# Identical replies are ordinary traffic here, not a corner case: the routine
# acknowledgement firstmate sends is a fixed sentence.
SEND_KEY="$(date +%s)-$$"
# An ARRAY, not a joined string. Every marker path starts at FM_HOME, and a home
# under a path containing a space would be shredded into fragments by the word
# splitting a joined list needs: the cleanup below would then delete nothing and
# a reply that never went out would leave its digest sitting there for the whole
# echo window, swallowing the captain saying those same words himself.
MARKERS=()
marker_for() {
  [ -n "$DIGEST" ] || return 1
  printf '%s/%s.%s-%s.sent' "$FM_WA_SENT" "$DIGEST" "$SEND_KEY" "$1"
}
if [ -n "$DIGEST" ] && fm_wa_id_safe "$DIGEST"; then
  IDX=0
  for RECIPIENT in $RECIPIENTS; do
    IDX=$(( IDX + 1 ))
    if : | fm_wa_publish_stdin "$FM_WA_SENT" "$DIGEST.$SEND_KEY-$IDX.sent" 2>/dev/null; then
      MARKERS+=("$(marker_for "$IDX")")
    fi
  done
fi
drop_markers() {
  local marker
  for marker in ${MARKERS[@]+"${MARKERS[@]}"}; do
    rm -f -- "$marker" 2>/dev/null || true
  done
  MARKERS=()
}
# Only ever drop a marker THIS send created. An identical reply still inside the
# echo window already owns its markers, and removing one of those would spend
# the guard belonging to a message that really did go out.
drop_marker() {
  local marker=$1 kept dropped=
  local -a remaining=()
  for kept in ${MARKERS[@]+"${MARKERS[@]}"}; do
    if [ -z "$dropped" ] && [ "$kept" = "$marker" ]; then
      rm -f -- "$marker" 2>/dev/null || true
      dropped=1
    else
      remaining+=("$kept")
    fi
  done
  MARKERS=(${remaining[@]+"${remaining[@]}"})
  return 0
}

if [ -n "$FM_WA_DRY_RUN" ]; then
  STAMP=$(date +%s)
  # Built with the library's own encoder rather than jq: the record is read back
  # as fm-wa-outbox-v1 JSON, so a host without jq must still produce valid JSON
  # instead of a .json file holding raw text.
  JSON_TEXT=$(printf '%s' "$TEXT" | fm_wa_json_string) || JSON_TEXT=
  # ONE RECORD PER RECIPIENT, exactly as a real send makes one delivery and one
  # echo marker per recipient. A dry run is the only place the fan-out can be
  # inspected before it reaches the captain's phones, so a single record naming
  # the first number would be evidence quietly saying less than the truth. The
  # `to` field keeps meaning one address rather than growing into a list.
  RECORDS=()
  # Announced only once every record survives. A later recipient failing to
  # publish rolls the whole run back, so a line printed as each one is written
  # would leave the operator holding the names of files that are no longer
  # there - evidence of a fan-out that was undone.
  NOTES=()
  DRY_OK=1
  IDX=0
  for RECIPIENT in $RECIPIENTS; do
    IDX=$(( IDX + 1 ))
    BASE="$STAMP-$$-$IDX.json"
    if [ -n "$JSON_TEXT" ] && printf '{"schema":"fm-wa-outbox-v1","dry_run":true,"to":"%s","digest":"%s","text":%s}\n' \
      "$RECIPIENT" "${DIGEST:-}" "$JSON_TEXT" \
      | fm_wa_publish_stdin "$FM_WA_OUTBOX" "$BASE"; then
      RECORDS+=("$FM_WA_OUTBOX/$BASE")
      NOTES+=("dry-run: recorded state/wa-outbox/$BASE for $RECIPIENT (nothing sent)")
    else
      DRY_OK=
      break
    fi
  done
  if [ -n "$DRY_OK" ] && [ "${#RECORDS[@]}" -gt 0 ]; then
    for NOTE in ${NOTES[@]+"${NOTES[@]}"}; do
      echo "$NOTE"
    done
    exit 0
  fi
  # Nothing was ever going to be sent, so the echo markers have nothing to guard
  # against and must not sit there swallowing those words from the captain. The
  # records already written go with them: a run that could not record every
  # delivery it would have made is not evidence of the fan-out.
  for RECORD in ${RECORDS[@]+"${RECORDS[@]}"}; do
    rm -f -- "$RECORD" 2>/dev/null || true
  done
  drop_markers
  echo "error: cannot record the dry-run reply" >&2
  exit 1
fi

# mudslide's own words are the only place a refused or failed delivery says why,
# and reporting a failure without them names the symptom while discarding the
# cause. A partial send is now the commonest real failure - one number reachable
# on WhatsApp and another not - so it is held to the same promise as a total
# one. Idempotent, and clears SEND_OUT so the caller cannot report it twice.
report_send_output() {
  if [ -n "$SEND_OUT" ] && [ -s "$SEND_OUT" ]; then
    echo "mudslide said:" >&2
    head -n 20 -- "$SEND_OUT" >&2
    [ "$(wc -l < "$SEND_OUT")" -le 20 ] || echo "(output truncated at 20 lines)" >&2
  fi
  [ -z "$SEND_OUT" ] || rm -f -- "$SEND_OUT" 2>/dev/null || true
  SEND_OUT=
}

# Single argv element: the shell never re-parses the captain's words. `--` ends
# mudslide's own option parsing before the positionals, so a reply that opens
# with a dash ("- PR is up: ...") is sent as text instead of being rejected as
# an unknown option and silently never reaching the captain.
#
# mudslide's combined output is captured rather than discarded: it is the only
# place a refused or failed send says why, and a reply that never arrives is
# exactly the silence this channel exists to prevent.
SEND_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-wa-send.XXXXXX" 2>/dev/null) || SEND_OUT=
STATUS=0
DELIVERED=
FAILED=
IDX=0
for RECIPIENT in $RECIPIENTS; do
  IDX=$(( IDX + 1 ))
  if [ -n "$SEND_OUT" ]; then
    mudslide send -- "$RECIPIENT" "$TEXT" >> "$SEND_OUT" 2>&1
    ONE=$?
  else
    mudslide send -- "$RECIPIENT" "$TEXT" >/dev/null 2>&1
    ONE=$?
  fi
  if [ "$ONE" -eq 0 ]; then
    DELIVERED="$DELIVERED $RECIPIENT"
  else
    FAILED="$FAILED $RECIPIENT"
    STATUS=$ONE
    # This phone never got the message, so nothing will echo back from it and
    # its marker would only sit there swallowing those words from the captain.
    if ONE_MARKER=$(marker_for "$IDX"); then
      drop_marker "$ONE_MARKER"
    fi
  fi
done
DELIVERED=${DELIVERED# }
FAILED=${FAILED# }

# A send that reached one phone but not another is not a success, because the
# missed one is silence the captain cannot distinguish from being ignored. It is
# reported as the partial failure it is, naming which number missed it - but the
# markers of the phones that DID get it are KEPT, because the message really did
# go out to them and will echo back from each of them.
if [ -n "$DELIVERED" ] && [ -n "$FAILED" ]; then
  echo "sent to $DELIVERED"
  echo "error: the reply did not reach $FAILED" >&2
  report_send_output
  exit 1
fi

if [ "$STATUS" -eq 0 ]; then
  [ -z "$SEND_OUT" ] || rm -f -- "$SEND_OUT" 2>/dev/null || true
  echo "sent to $DELIVERED"
else
  # Nothing went out, so nothing can echo back: drop the markers rather than
  # leaving them to suppress the captain saying those same words himself.
  drop_markers
  echo "error: mudslide could not send the reply" >&2
  report_send_output
  exit 1
fi
