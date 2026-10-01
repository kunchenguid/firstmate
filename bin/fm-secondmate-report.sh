#!/usr/bin/env bash
# fm-secondmate-report.sh - optional helper to append a correlated parent report
# or a payload-free delivery receipt.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/fm-pending-reply-lib.sh).
#
# --receipt is a different, narrower shape for acknowledging a fire-and-forget
# `delivery=<id>` instruction (bin/fm-send.sh): it takes ONLY that 16-hex
# identifier and emits the fixed record `receipt: delivery=<id>` unchanged -
# no note, no doc path, no "(via-helper)" suffix, and never a corr token.
# fm-classify-lib.sh's status_span_is_all_receipts is the sole owner of that
# exact grammar; this helper exists only to make emitting it convenient, and a
# plain `echo "receipt: delivery=<id>" >> <status-file>` is equally valid. A
# receipt never resolves a pending reply, closes a decision key, or stands in
# for reporting an outcome (PR #27 Astra shape review) - use the ordinary
# corr-based report above, or a plain done:/needs-decision:/blocked:/failed:
# line, for anything that is actually an answer or a result.
#
# The write destination is mechanical: this helper never takes a status path.
# It resolves the parent channel through fm_parent_channel_destination
# (bin/fm-parent-channel-lib.sh): a local mate writes the parent home's
# state/<id>.status, and a remote mate writes this home's
# state/parent-replies.status. Call it from the secondmate home with FM_HOME
# set to that home.
#
# Usage:
#   fm-secondmate-report.sh <verb> <corr_id> <note...>
#   fm-secondmate-report.sh --doc <verb> <corr_id> <doc-path> <note...>
#   fm-secondmate-report.sh --receipt <delivery-id>
#
# Examples:
#   fm-secondmate-report.sh done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --doc done abcdef0123456789 data/x/report.md "see report"
#   fm-secondmate-report.sh --receipt abcdef0123456789
set -eu

CALLER_FM_HOME=${FM_HOME:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  fm-secondmate-report.sh <verb> <corr_id> <note...>
  fm-secondmate-report.sh --doc <verb> <corr_id> <doc-path> <note...>
  fm-secondmate-report.sh --receipt <delivery-id>
EOF
  exit 2
}

resolve_home_state() {
  HOME_DIR=$CALLER_FM_HOME
  case "$HOME_DIR" in
    '')
      echo "error: FM_HOME is required so the helper can resolve the parent channel" >&2
      exit 1
      ;;
  esac
  STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"
}

if [ "${1:-}" = "--receipt" ]; then
  [ $# -eq 2 ] || usage
  DELIVERY_ID=$2
  case "$DELIVERY_ID" in
    [a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]) ;;
    *)
      echo "error: delivery id must be 16 lowercase hex characters (got '$DELIVERY_ID')" >&2
      exit 1
      ;;
  esac
  resolve_home_state
  fm_parent_channel_report_receipt "$HOME_DIR" "$STATE_DIR" "receipt: delivery=$DELIVERY_ID" || {
    echo "error: could not publish the receipt to the parent channel" >&2
    exit 1
  }
  exit 0
fi

DOC_MODE=0
if [ "${1:-}" = "--doc" ]; then
  DOC_MODE=1
  shift
fi

[ $# -ge 2 ] || usage
VERB=$1
CORR=$2
shift 2
if [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] && [ -n "$1" ] || usage
else
  [ $# -ge 1 ] && [ -n "$*" ] || usage
fi

case "$CORR" in
  corr=*) CORR=${CORR#corr=} ;;
esac
case "$CORR" in
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *)
    echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
    exit 1
    ;;
esac

resolve_home_state

DESTINATION=
DEST_RC=0
DESTINATION=$(fm_parent_channel_destination "$HOME_DIR" "$STATE_DIR") || DEST_RC=$?
if [ "$DEST_RC" -ne 0 ] || [ -z "$DESTINATION" ]; then
  echo "error: cannot resolve the parent channel from this home (not a seeded secondmate?)" >&2
  exit 1
fi
token=$(fm_pending_reply_corr_token "$CORR")
if [ "$DOC_MODE" = 1 ]; then
  DOC_PATH=$1
  shift
  NOTE=$*
  if [ -n "$NOTE" ]; then
    line="$VERB [$token]: $(fm_parent_channel_clean_note "$NOTE") ($(fm_parent_channel_clean_note "$DOC_PATH") via-helper)"
  else
    line="$VERB [$token]: $(fm_parent_channel_clean_note "$DOC_PATH") (via-helper)"
  fi
else
  NOTE=$*
  line="$VERB [$token]: $(fm_parent_channel_clean_note "$NOTE") (via-helper)"
fi
fm_parent_channel_report_correlated "$HOME_DIR" "$STATE_DIR" "$line" || {
  echo "error: could not publish correlated report to the parent channel" >&2
  exit 1
}
