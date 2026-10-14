#!/usr/bin/env bash
# fm-captain-beads-check.sh - deliver closed captain beads to their requester.
#
# This is the close leg of firstmate's captain-request loop (the hold and ask
# legs live in bin/fm-captain-hold.sh and bin/fm-captain-ask.sh).
#
# Behavior:
#   - no config/beads-board in this home: exit 0, emit nothing, run no bd.
#   - list recently closed beads from the configured board, take the ones
#     carrying a requester marker (a `requester:<name>` label, peer convention
#     documented in docs/herdr-backend.md, or an `fm-requester: <name>` line
#     in the body firstmate's own mirroring writes), and deliver each bead's
#     close reason to that requester:
#       * requester `firstmate`: print one wake line, which the watcher turns
#         into a `check:` wake for this home's own session;
#       * a task id this home carries (state/<name>.meta, including a
#         secondmate): steer it with bin/fm-send.sh (FM_HOME explicit);
#       * anything else, when this home has state/peers/peers.sh: send through
#         `peers.sh send <name>`, the hand-launched-peer transport.
#   - a bead with no requester marker is skipped, untouched.
#   - every delivery is deduped under state/.captain-bead-notified/<bead-id>:
#     a claim token is written BEFORE the send so a crash mid-delivery never
#     double-notifies, at the stated cost of possibly dropping one notice. A
#     successful delivery (or a firstmate wake line) keeps the token so the
#     close is never delivered twice; a failed send to a task or peer this
#     home manages drops the token so the next poll retries, and an
#     unreachable or unknown requester keeps it, because a retry loop there
#     is exactly the duplicate storm the token is for. An operator re-arms a
#     stranded close by removing the token.
#
# Run shapes:
#   bin/fm-captain-beads-check.sh            one poll (custom watcher check)
#   bin/fm-captain-beads-check.sh install    copy this script to
#       state/captain-beads.check.sh and hash-bind it with
#       bin/fm-check-register.sh, so the home's watcher polls it directly
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state"
# shellcheck source=bin/fm-bead-board-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-bead-board-lib.sh"

fail() {
  printf 'fm-captain-beads-check: %s\n' "$*" >&2
  exit 1
}

install_check() {
  local check="$STATE/captain-beads.check.sh"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  cp "$SCRIPT_DIR/fm-captain-beads-check.sh" "$check" \
    || fail "could not write $check"
  chmod 0700 "$check" || fail "could not set $check executable"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-register.sh" captain-beads \
    || fail "could not hash-bind the installed check; remove $check and retry"
  printf 'installed: %s (hash-bound; the watcher polls it on its check cadence)\n' "$check"
}

case "${1:-}" in
  '') : ;;
  install) install_check; exit 0 ;;
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  *)
    printf 'usage: fm-captain-beads-check.sh [install]\n' >&2
    exit 2
    ;;
esac

# Closed-bead consumption is silent for an unjoined home.
fm_bead_board_ready || exit 0

command -v jq >/dev/null 2>&1 || exit 0

NOTIFIED_DIR="$STATE/.captain-bead-notified"
umask 077
mkdir -p "$NOTIFIED_DIR" || exit 0

CLOSED_JSON=$(fm_bead_board_bd list --status closed --label captain \
  --limit 0 --json 2>/dev/null) || exit 0
printf '%s' "$CLOSED_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 0

PEERS_SH="$STATE/peers/peers.sh"

# Deliver one closed bead's close reason to its requester. Prints one wake
# line for requester `firstmate`; steers every other requester. The
# keep-token vs retry semantics after a failed send follow the header.
deliver_close() {  # <bead-id> <title> <reason> <requester>
  local id=$1 title=$2 reason=$3 requester=$4 token msg send_rc=0
  token="$NOTIFIED_DIR/$id"
  [ -e "$token" ] || [ -L "$token" ] && return 0
  # Claim first: at-most-once delivery beats at-least-once here.
  : > "$token" || return 0
  msg="Captain bead closed: $title ($id) - ${reason:-no close reason recorded}"
  if [ "$requester" = firstmate ]; then
    printf '%s\n' "$msg"
    return 0
  fi
  if [ -f "$STATE/$requester.meta" ] && [ ! -L "$STATE/$requester.meta" ]; then
    if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$requester" "$msg" \
      >/dev/null 2>&1; then
      return 0
    fi
    send_rc=1
  elif [ -x "$PEERS_SH" ] && [ ! -L "$PEERS_SH" ]; then
    if "$PEERS_SH" send "$requester" "$msg" >/dev/null 2>&1; then
      return 0
    fi
    send_rc=1
  else
    send_rc=1
  fi
  if [ "$send_rc" -ne 0 ]; then
    printf 'fm-captain-beads-check: could not deliver the close of %s to %s; the bead reads closed on the board (reason: %s)\n' \
      "$id" "$requester" "${reason:-none recorded}" >&2
    # Only a transient delivery failure stays retryable; unreachable or
    # unknown requesters keep their claim (documented in the header) so a
    # broken requester marker can never produce a duplicate storm.
    if [ -f "$STATE/$requester.meta" ] || [ -L "$STATE/$requester.meta" ]; then
      rm -f -- "$token"
    fi
  fi
  return 0
}

printf '%s' "$CLOSED_JSON" | jq -r '
  .[]
  | ((.description // "") | split("\n") | map(select(startswith("fm-requester: "))) | first // "") as $body_req
  | ((.labels // []) | map(select(startswith("requester:"))) | first // "") as $label_req
  | ($body_req | sub("^fm-requester: "; "")) as $body_name
  | ($label_req | sub("^requester:"; "")) as $label_name
  | (if $body_name != "" then $body_name elif $label_name != "" then $label_name else "" end) as $requester
  | select($requester != "" and .id != null)
  | [.id, ($requester | gsub("\t"; " ")), ((.title // "") | gsub("\t"; " ") | gsub("\n"; " ")), ((.close_reason // "") | gsub("\t"; " ") | gsub("\n"; " "))]
  | @tsv
' | while IFS=$'\t' read -r bead_id requester title reason; do
  deliver_close "$bead_id" "$title" "$reason" "$requester"
done

exit 0
