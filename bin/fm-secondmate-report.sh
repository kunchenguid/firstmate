#!/usr/bin/env bash
# fm-secondmate-report.sh - optional helper to append a correlated parent report.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/fm-pending-reply-lib.sh).
#
# It also carries the OTHER direction, which has no corr id to correlate: an
# escalation this secondmate RAISES itself. That line has no prior request by
# contract, so it cannot use the correlated form above, and it must still reach
# the parent's own log or the parent never learns the decision exists. In
# --escalate mode this script resolves the parent escalation channel from this
# home's own durable bindings (bin/fm-parent-channel-lib.sh) instead of trusting
# a hand-typed path into another home, so the line this home OPENS and the line
# that later CLOSES it provably address the same channel.
#
# Usage:
#   fm-secondmate-report.sh <status-file> <verb> <corr_id> <note...>
#   fm-secondmate-report.sh --doc <status-file> <verb> <corr_id> <doc-path> <note...>
#   fm-secondmate-report.sh --escalate <verb> [--key <slug>] [--task <id>] <note...>
#
# Examples:
#   fm-secondmate-report.sh "$STATUS" done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --doc "$STATUS" done abcdef0123456789 data/x/report.md "see report"
#   fm-secondmate-report.sh --escalate needs-decision --key money-risk "two findings look like real money leaving"
#   fm-secondmate-report.sh --escalate needs-decision --key review --task wi812 "worker needs scope"
#   fm-secondmate-report.sh --escalate resolved --key money-risk "captain scoped it to a separate scout"
#
# The status file must be the absolute parent route from the secondmate charter
# (state/<id>.status under the PARENT home), never a path relative to this
# secondmate home. Writing under the wrong home is detected as supporting
# evidence by the parent pending-reply guard and does not acknowledge the
# request. --escalate takes no status file at all, for exactly that reason.
#
# --escalate refuses rather than guessing: a home with no parent binding, an
# unreadable binding, and a key in a reserved namespace whose owning library is
# the only thing allowed to open or close it all fail loudly. An escalation is
# routed through the channel owner's required write categories.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  fm-secondmate-report.sh <status-file> <verb> <corr_id> <note...>
  fm-secondmate-report.sh --doc <status-file> <verb> <corr_id> <doc-path> <note...>
  fm-secondmate-report.sh --escalate <verb> [--key <slug>] [--task <id>] <note...>
EOF
  exit 2
}

# --escalate: this home's OWN escalation, with no correlation id.
if [ "${1:-}" = "--escalate" ]; then
  shift
  [ $# -ge 1 ] || usage
  VERB=$1
  shift
  KEY=
  ORIGIN_TASK=
  while [ $# -gt 0 ]; do
    case "$1" in
      --key)
        [ $# -ge 2 ] || usage
        [ -z "$KEY" ] || { echo "error: --key may be supplied only once" >&2; exit 1; }
        KEY=$2
        shift 2
        ;;
      --task)
        [ $# -ge 2 ] || usage
        [ -z "$ORIGIN_TASK" ] || { echo "error: --task may be supplied only once" >&2; exit 1; }
        ORIGIN_TASK=$2
        shift 2
        ;;
      *) break ;;
    esac
  done
  # The paused and resolved spellings come from fm-classify-lib.sh's own
  # constants rather than being restated here, so this writer cannot drift from
  # the vocabulary the fold consumes.
  ESC_PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  ESC_RESOLVE_VERB=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  case "$VERB" in
    working|needs-decision|blocked|done|failed) ;;
    "$ESC_PAUSED_VERB"|"$ESC_RESOLVE_VERB") ;;
    *)
      echo "error: --escalate verb must be one of working, needs-decision, blocked, $ESC_PAUSED_VERB, done, failed, $ESC_RESOLVE_VERB (got '$VERB')" >&2
      exit 1
      ;;
  esac
  case "$KEY" in
    '') ;;
    *[!A-Za-z0-9._-]*)
      echo "error: --key '$KEY' is not a valid decision key (allowed: A-Z a-z 0-9 . _ -)" >&2
      exit 1
      ;;
  esac
  case "$ORIGIN_TASK" in
    '') ;;
    *[!A-Za-z0-9._-]*)
      echo "error: --task '$ORIGIN_TASK' is not a valid task id (allowed: A-Z a-z 0-9 . _ -)" >&2
      exit 1
      ;;
  esac
  if [ -n "$ORIGIN_TASK" ]; then
    case "$VERB" in
      needs-decision|blocked|"$ESC_RESOLVE_VERB") ;;
      *) echo "error: --task applies only to a decision, blocker, or resolution" >&2; exit 1 ;;
    esac
  fi
  NOTE=$*
  [ -n "$NOTE" ] || { echo "error: --escalate requires a note" >&2; exit 1; }
  FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
  STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # A reserved key namespace has exactly one owning library; a self-raised
  # escalation must never claim one, or it could block that owner's close.
  if [ -n "$KEY" ] && fm_classify_decision_key_is_reserved "$KEY"; then
    echo "error: --key '$KEY' is in a reserved namespace whose owning library is the only writer that may open or close it; pick a key of your own." >&2
    exit 1
  fi
  ESC_RC=0
  CHANNEL=$(fm_parent_channel_path "$FM_HOME" "$STATE") || ESC_RC=$?
  case "$ESC_RC" in
    0) ;;
    1)
      echo "error: $FM_HOME is not a secondmate home, so it has no parent escalation channel; --escalate applies only to a seeded secondmate home." >&2
      exit 1
      ;;
    *)
      echo "error: $FM_HOME is a secondmate home, but its parent escalation channel cannot be resolved from .fm-secondmate-home and .fm-secondmate-parent; repair the parent binding rather than writing this escalation somewhere else." >&2
      exit 1
      ;;
  esac
  [ -n "$ORIGIN_TASK" ] || ORIGIN_TASK=$(fm_parent_channel_self_id "$FM_HOME") \
    || { echo "error: cannot identify this secondmate as the escalation's origin task" >&2; exit 1; }
  NOTE=$(printf '%s' "$NOTE" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  case "$VERB" in
    needs-decision|blocked|"$ESC_RESOLVE_VERB")
      LINE_PREFIX="$VERB${KEY:+ [key=$KEY]} [task=$ORIGIN_TASK]: "
      ;;
    *)
      LINE_PREFIX="$VERB${KEY:+ [key=$KEY]}: "
      ;;
  esac
  fm_cap_prefixed_line_var "$LINE_PREFIX" "$NOTE" \
    || { echo "error: --key '$KEY' is too long to preserve in the parent escalation channel" >&2; exit 1; }
  case "$VERB" in
    needs-decision|blocked)
      fm_parent_channel_append transition "$CHANNEL" "$FM_LINE_CAP_LINE" open "${KEY:-default}" "" "$ORIGIN_TASK"
      ;;
    "$ESC_RESOLVE_VERB")
      fm_parent_channel_append transition "$CHANNEL" "$FM_LINE_CAP_LINE" close "${KEY:-default}" "" "$ORIGIN_TASK"
      ;;
    *)
      fm_parent_channel_append event "$CHANNEL" "$FM_LINE_CAP_LINE"
      ;;
  esac || { echo "error: could not append the escalation to $CHANNEL" >&2; exit 1; }
  printf 'escalated to %s\n' "$CHANNEL"
  exit 0
fi

DOC_MODE=0
if [ "${1:-}" = "--doc" ]; then
  DOC_MODE=1
  shift
fi

[ $# -ge 4 ] || usage
STATUS_FILE=$1
VERB=$2
CORR=$3
shift 3

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

case "$STATUS_FILE" in
  '') usage ;;
esac
mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || true
if [ ! -d "$(dirname "$STATUS_FILE")" ]; then
  echo "error: cannot create parent directory for status file '$STATUS_FILE'" >&2
  exit 1
fi

token=$(fm_pending_reply_corr_token "$CORR")
if [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] || usage
  DOC_PATH=$1
  shift
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf '%s [%s]: %s (%s via-helper)\n' "$VERB" "$token" "$NOTE" "$DOC_PATH" >> "$STATUS_FILE"
  else
    printf '%s [%s]: %s (via-helper)\n' "$VERB" "$token" "$DOC_PATH" >> "$STATUS_FILE"
  fi
else
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf '%s [%s]: %s (via-helper)\n' "$VERB" "$token" "$NOTE" >> "$STATUS_FILE"
  else
    printf '%s [%s]: (via-helper)\n' "$VERB" "$token" >> "$STATUS_FILE"
  fi
fi
