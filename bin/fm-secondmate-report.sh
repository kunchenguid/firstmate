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
#   fm-secondmate-report.sh <verb> [[key=<slug>]] <corr_id> <note...>
#   fm-secondmate-report.sh --doc <verb> [[key=<slug>]] <corr_id> <doc-path> <note...>
#
# The optional [key=<slug>] token is the same decision key a worker would put
# between the verb and the colon on a plain status line. Pass it as its own
# argument after the verb; the helper emits it in that documented slot next
# to the correlation id so a via-helper needs-decision stays closable with
# --resolve-key. A line with no key still opens the shared default key, as
# before.
#
# Examples:
#   fm-secondmate-report.sh done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh needs-decision '[key=color]' abcdef0123456789 "pick a color"
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
  fm-secondmate-report.sh <verb> [[key=<slug>]] <corr_id> <note...>
  fm-secondmate-report.sh --doc <verb> [[key=<slug>]] <corr_id> <doc-path> <note...>
EOF
  exit 2
}

# Print the slug when $1 is a complete [key=<slug>] token, with an optional
# trailing colon. The slug charset is owned by _fm_decision_slug_ok.
_fm_report_key_token_slug() {  # <token> -> slug
  local t=$1 slug
  case "$t" in
    \[key=*\]|\[key=*\]:)
      slug=${t#\[key=}
      slug=${slug%\]:}
      slug=${slug%\]}
      _fm_decision_slug_ok "$slug" || return 1
      printf '%s' "$slug"
      return 0
      ;;
  esac
  return 1
}

_fm_report_set_key() {  # <slug>
  local slug=$1
  if [ -n "$KEY" ] && [ "$KEY" != "$slug" ]; then
    echo "error: conflicting decision keys '$KEY' and '$slug'" >&2
    exit 1
  fi
  KEY=$slug
}

# A verb that ends in "[key=<slug>]:" would leave a colon inside the verb and
# push the correlation id into the note, so split that token off the verb.
_fm_report_split_verb_key() {
  local last slug prefix
  case "$VERB" in
    *' [key='*']:')
      last=${VERB##* }
      if slug=$(_fm_report_key_token_slug "$last"); then
        prefix=${VERB% *}
        [ -n "$prefix" ] || usage
        VERB=$prefix
        _fm_report_set_key "$slug"
      fi
      ;;
  esac
}

DOC_MODE=0
if [ "${1:-}" = "--doc" ]; then
  DOC_MODE=1
  shift
fi

[ $# -ge 2 ] || usage
VERB=$1
shift
KEY=
case "${1:-}" in
  \[key=*)
    if slug=$(_fm_report_key_token_slug "$1"); then
      KEY=$slug
      shift
    else
      echo "error: [key=...] slug must be nonempty A-Za-z0-9._- (got '$1')" >&2
      exit 1
    fi
    ;;
esac
_fm_report_split_verb_key
[ $# -ge 1 ] || usage
CORR=$1
shift
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

token=$(fm_pending_reply_corr_token "$CORR")
if [ "$DOC_MODE" = 1 ]; then
  DOC_PATH=$1
  shift
  NOTE=$*
else
  NOTE=$*
fi
key_tag=
if [ -n "$KEY" ]; then
  key_tag=" [key=$KEY]"
fi
if [ "$DOC_MODE" = 1 ]; then
  if [ -n "$NOTE" ]; then
    printf -v line '%s [%s]%s: %s (%s via-helper)' "$VERB" "$token" "$key_tag" "$NOTE" "$DOC_PATH"
  else
    printf -v line '%s [%s]%s: %s (via-helper)' "$VERB" "$token" "$key_tag" "$DOC_PATH"
  fi
else
  printf -v line '%s [%s]%s: %s (via-helper)' "$VERB" "$token" "$key_tag" "$NOTE"
fi
printf '%s\n' "$(status_stamp_line "$line")" >> "$DESTINATION"
