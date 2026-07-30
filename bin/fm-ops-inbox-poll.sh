#!/usr/bin/env bash
# One bounded read of the machine's operational alert inbox.
# Usage: fm-ops-inbox-poll.sh
#
# The watcher runs this through the registered standing check
# state/ops-watch.check.sh, so it obeys the same contract as any custom check: it
# prints ONE line when firstmate should wake, prints nothing otherwise, and always
# finishes well inside FM_CHECK_TIMEOUT. It only reads the alert spool; it never
# writes, rotates, or acknowledges alerts, and it never contacts a network.
#
# Wake conditions (docs/ops-inbox-wake.md owns the contract and the defaults):
#   - more unacked critical alerts than the configured count threshold;
#   - any unacked critical alert older than the configured age threshold;
#   - the spool is longer than the bounded read cap, so it can no longer be read
#     whole inside one check and needs rotating or triaging;
#   - the periodic receipt is stale, missing, or unreadable, because a dead
#     receipt generator is itself the alerting failure;
#   - the watch configuration is malformed, so thresholds cannot be trusted.
#
# The wake line is a triage digest: total, oldest age, and the three busiest
# alert classes.
#
# Dedupe: a standing backlog must not re-wake every poll. state/.ops-inbox-wake
# records the last wake's count, receipt state, and class set; a further wake
# needs a materially larger count, a class not seen at the last wake, a changed
# receipt state, or the configured re-remind interval to have passed. A backlog
# below every wake threshold removes that record, so the next qualifying one
# wakes immediately.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SIDECAR="$STATE/.ops-inbox-wake"

# shellcheck source=bin/fm-ops-inbox-lib.sh
. "$SCRIPT_DIR/fm-ops-inbox-lib.sh"

# Emit one deduplicated wake line, then record it. A recording failure is
# reported on stderr and the line is still printed: an unnoticed alert backlog is
# the worse outcome, and the watcher's own cadence bounds the repetition.
wake_once() {  # <state> <count> <classes> <line>
  local state=$1 count=$2 classes=$3 line=$4 class due
  fm_ops_inbox_sidecar_read "$SIDECAR" || FM_OPS_INBOX_LAST_EPOCH=
  if [ -n "$FM_OPS_INBOX_LAST_EPOCH" ]; then
    due=0
    [ "$state" != "$FM_OPS_INBOX_LAST_STATE" ] && due=1
    [ "$count" -ge $((FM_OPS_INBOX_LAST_COUNT + FM_OPS_INBOX_GROWTH)) ] && due=1
    if [ "$FM_OPS_INBOX_REMIND_HOURS" -gt 0 ] \
      && [ $((NOW - FM_OPS_INBOX_LAST_EPOCH)) -ge $((FM_OPS_INBOX_REMIND_HOURS * 3600)) ]; then
      due=1
    fi
    if [ "$due" -eq 0 ]; then
      for class in $classes; do
        case " $FM_OPS_INBOX_LAST_CLASSES " in
          *" $class "*) ;;
          *) due=1; break ;;
        esac
      done
    fi
    [ "$due" -eq 1 ] || return 0
  fi
  fm_ops_inbox_sidecar_write "$SIDECAR" "$NOW" "$count" "$state" "$classes" \
    || echo "fm-ops-inbox-poll: could not record the wake at $SIDECAR" >&2
  printf '%s\n' "$line"
}

set_now() {
  NOW=$(date +%s 2>/dev/null) || return 1
  case "$NOW" in
    ''|*[!0-9]*) return 1 ;;
  esac
}

if ! fm_ops_inbox_config_load "$CONFIG"; then
  if ! set_now; then
    printf '%s\n' 'ops-inbox: alert watch could not read the current time'
    exit 0
  fi
  wake_once config-error 0 '' "ops-inbox: alert watch configuration is unusable - $FM_OPS_INBOX_CONFIG_ERROR"
  exit 0
fi

# Disabled and auto-without-spool homes stay silent; explicit watches continue
# and fail closed below when their required spool cannot be read.
fm_ops_inbox_watch_expected "$FM_HOME" || exit 0

if ! set_now; then
  printf '%s\n' 'ops-inbox: alert watch could not read the current time'
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  wake_once no-jq 0 '' 'ops-inbox: alert watch cannot read the inbox because jq is not installed'
  exit 0
fi

# Receipt state first: the receipt is the external runtime's own periodic proof
# that alert review is happening, so its absence or staleness is wake-worthy on
# its own, and it also decides whether its count can be trusted below.
RECEIPT_STATE=fresh
RECEIPT_NOTE=
RECEIPT_COUNT=
if [ ! -f "$FM_OPS_INBOX_RECEIPT" ]; then
  RECEIPT_STATE=missing
  RECEIPT_NOTE='alert receipt missing'
else
  receipt_mtime=$(fm_ops_inbox_stat_mtime "$FM_OPS_INBOX_RECEIPT")
  case "$receipt_mtime" in
    ''|*[!0-9]*)
      RECEIPT_STATE=unreadable
      RECEIPT_NOTE='alert receipt unreadable'
      ;;
    *)
      receipt_age=$((NOW - receipt_mtime))
      [ "$receipt_age" -ge 0 ] || receipt_age=0
      if [ "$FM_OPS_INBOX_RECEIPT_STALE_HOURS" -gt 0 ] \
        && [ "$receipt_age" -ge $((FM_OPS_INBOX_RECEIPT_STALE_HOURS * 3600)) ]; then
        RECEIPT_STATE=stale
        RECEIPT_NOTE="alert receipt stale $(fm_ops_inbox_age_label "$receipt_age")"
      fi
      ;;
  esac
fi

if [ "$RECEIPT_STATE" = fresh ] || [ "$RECEIPT_STATE" = stale ]; then
  if ! RECEIPT_COUNT=$(fm_ops_inbox_receipt_count "$FM_OPS_INBOX_RECEIPT"); then
    RECEIPT_COUNT=
    RECEIPT_STATE=unreadable
    RECEIPT_NOTE='alert receipt unreadable'
  fi
fi

if ! fm_ops_inbox_scan "$FM_OPS_INBOX_SPOOL" "$FM_OPS_INBOX_ACKS" "$FM_OPS_INBOX_MAX_LINES"; then
  wake_once scan-failed 0 '' "ops-inbox: alert inbox at $FM_OPS_INBOX_SPOOL could not be read"
  exit 0
fi

COUNT=$FM_OPS_INBOX_SCAN_COUNT
if [ "$RECEIPT_STATE" = fresh ]; then
  COUNT=$RECEIPT_COUNT
fi

OLDEST_AGE=
if [ -n "$FM_OPS_INBOX_SCAN_OLDEST" ]; then
  if oldest_epoch=$(fm_ops_inbox_epoch_of_iso "$FM_OPS_INBOX_SCAN_OLDEST"); then
    OLDEST_AGE=$((NOW - oldest_epoch))
    [ "$OLDEST_AGE" -ge 0 ] || OLDEST_AGE=0
  else
    wake_once scan-failed 0 '' "ops-inbox: alert inbox at $FM_OPS_INBOX_SPOOL could not be read"
    exit 0
  fi
fi

over_count=0
[ "$COUNT" -gt "$FM_OPS_INBOX_COUNT" ] && over_count=1
over_age=0
if [ -n "$OLDEST_AGE" ] \
  && [ "$OLDEST_AGE" -ge $((FM_OPS_INBOX_AGE_HOURS * 3600)) ]; then
  over_age=1
fi

if [ "$RECEIPT_STATE" = fresh ] && [ "$over_count" -eq 0 ] && [ "$over_age" -eq 0 ] \
  && [ "$FM_OPS_INBOX_SCAN_TRUNCATED" -eq 0 ]; then
  # Nothing to report. Drop any prior wake record so a fresh backlog is not
  # silently deduplicated against an already-resolved one.
  if ! rm -f -- "$SIDECAR" 2>/dev/null; then
    wake_once sidecar-clear-failed "$COUNT" "$FM_OPS_INBOX_SCAN_CLASSES" \
      "ops-inbox: wake dedupe state at $SIDECAR could not be cleared"
  fi
  exit 0
fi

top=
while IFS=$(printf '\t') read -r class_count class_name; do
  [ -n "$class_name" ] || continue
  if [ -z "$top" ]; then
    top="$class_name $class_count"
  else
    top="$top, $class_name $class_count"
  fi
done <<EOF
$FM_OPS_INBOX_SCAN_TOP
EOF

line="ops-inbox: "
if [ "$FM_OPS_INBOX_SCAN_TRUNCATED" -eq 1 ]; then
  line="${line}inbox past its $FM_OPS_INBOX_MAX_LINES-line read cap, so the total and oldest age below are understated; "
fi
[ -z "$RECEIPT_NOTE" ] || line="$line$RECEIPT_NOTE; "
if [ "$COUNT" -eq 1 ]; then
  line="${line}1 unacked critical alert"
else
  line="$line$COUNT unacked critical alerts"
fi
[ -z "$OLDEST_AGE" ] || line="$line, oldest $(fm_ops_inbox_age_label "$OLDEST_AGE")"
[ -z "$top" ] || line="$line, top: $top"

WAKE_STATE=$RECEIPT_STATE
[ "$FM_OPS_INBOX_SCAN_TRUNCATED" -eq 0 ] || WAKE_STATE="$RECEIPT_STATE-capped"

wake_once "$WAKE_STATE" "$COUNT" "$FM_OPS_INBOX_SCAN_CLASSES" "$line"
