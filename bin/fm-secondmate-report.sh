#!/usr/bin/env bash
# fm-secondmate-report.sh - optional helper to append a correlated parent report.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/fm-pending-reply-lib.sh).
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
#
# Examples:
#   fm-secondmate-report.sh done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --doc done abcdef0123456789 data/x/report.md "see report"
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
EOF
  exit 2
}

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
# One report answers ONE request. A line that carries a second correlation
# token - a made-up 'corr2=' or a repeated 'corr=' - is not a supported
# format: the matcher only knows 'corr=<16 hex>', so the extra token never
# correlates and the request it names stays unanswered for ever. Refuse the
# unsupported form here, where the mate reads the correction.
if printf '%s' "$CORR" | grep -qE '(^|[^[:alnum:]_])corr[[:alnum:]_]*='; then
  echo "error: this helper reports ONE request per line. Pass the single corr=<16 hex> token of the request you are answering, and send a separate report for the other request: a 'corr2=' token, or two 'corr=' tokens in one report, is not a supported format and never correlates." >&2
  exit 1
fi
case "$CORR" in
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *)
    echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
    exit 1
    ;;
esac

HOME_DIR=$CALLER_FM_HOME
case "$HOME_DIR" in
  '')
    echo "error: FM_HOME is required so the helper can resolve the parent channel" >&2
    exit 1
    ;;
esac
STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"

DESTINATION=
DEST_RC=0
DESTINATION=$(fm_parent_channel_destination "$HOME_DIR" "$STATE_DIR") || DEST_RC=$?
if [ "$DEST_RC" -ne 0 ] || [ -z "$DESTINATION" ]; then
  echo "error: cannot resolve the parent channel from this home (not a seeded secondmate?)" >&2
  exit 1
fi
mkdir -p "$(dirname "$DESTINATION")" 2>/dev/null || true
if [ ! -d "$(dirname "$DESTINATION")" ]; then
  echo "error: cannot create parent directory for status file '$DESTINATION'" >&2
  exit 1
fi

# The note is written verbatim onto the parent channel, and this helper
# already writes the request's own token, so a correlation token in the note
# can only be a second one: a multi-request report, which never correlates.
if printf '%s' "$*" | grep -qE '(^|[^[:alnum:]_])corr[[:alnum:]_]*='; then
  echo "error: this helper reports ONE request per line, and its note must not carry a correlation token: this helper already writes the request's corr=<16 hex> token. A 'corr2=' token, or any second 'corr=' token, is not a supported format - send a separate report for the other request." >&2
  exit 1
fi
token=$(fm_pending_reply_corr_token "$CORR")
if [ "$DOC_MODE" = 1 ]; then
  DOC_PATH=$1
  shift
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf -v line '%s [%s]: %s (%s via-helper)' "$VERB" "$token" "$NOTE" "$DOC_PATH"
  else
    printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$DOC_PATH"
  fi
else
  NOTE=$*
  printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$NOTE"
fi
printf '%s\n' "$(status_stamp_line "$line")" >> "$DESTINATION"
