#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: fm-dashboard-transition.sh record <state-dir> <task-id> <working|parked|paused|blocked|failed|done|unknown> <epoch>" >&2
  echo "       fm-dashboard-transition.sh recovery-claim <state-dir> <task-id> <epoch>" >&2
  echo "       fm-dashboard-transition.sh recovery-claim-clear <state-dir> <task-id> <claim>" >&2
  echo "       fm-dashboard-transition.sh recovery-working <state-dir> <task-id> <epoch> <claim>" >&2
  echo "       fm-dashboard-transition.sh barrier <state-dir> <task-id> <working|parked|paused|blocked|failed|done|unknown>" >&2
  echo "       fm-dashboard-transition.sh append <state-dir> <task-id> [state] <epoch> <status-line>" >&2
  echo "       fm-dashboard-transition.sh resolve <state-dir> <task-id> <epoch> <resolved-status-line>" >&2
  echo "       fm-dashboard-transition.sh self-append <state-dir> <task-id> [state] <epoch> <status-line>" >&2
  echo "       fm-dashboard-transition.sh self-resolve <state-dir> <task-id> <epoch> <resolved-status-line>" >&2
  echo "       fm-dashboard-transition.sh replay-busy <state-dir> <task-id>" >&2
  exit 2
}

ACTION=${1:-}
STATE=${2:-}
ID=${3:-}
[ -n "$STATE" ] && [ -n "$ID" ] || usage
case "$ID" in ''|*[!A-Za-z0-9._-]*) usage ;; esac
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
if [ "$ACTION" = replay-busy ]; then
  # shellcheck source=bin/fm-busy-lib.sh
  . "$SCRIPT_DIR/fm-busy-lib.sh"
  busy=$(fm_busy_record_read "$STATE" "$ID" 2>/dev/null) || exit 0
  read -r busy_state _ _ _ busy_at <<< "$busy"
  case "$busy_state:$busy_at" in
    busy:[0-9]*) CURRENT=working ;;
    idle:[0-9]*) CURRENT=parked ;;
    unknown:[0-9]*) CURRENT=unknown ;;
    *) exit 0 ;;
  esac
  exec "$0" record "$STATE" "$ID" "$CURRENT" "$busy_at"
fi
[ "$ACTION" = record ] || [ "$ACTION" = recovery-claim ] || [ "$ACTION" = recovery-claim-clear ] || [ "$ACTION" = recovery-working ] || [ "$ACTION" = barrier ] || [ "$ACTION" = append ] || [ "$ACTION" = resolve ] || [ "$ACTION" = self-append ] || [ "$ACTION" = self-resolve ] || usage
if [ "$ACTION" = barrier ]; then
  CURRENT=${4:-}
  AT=
  LINE=
elif [ "$ACTION" = recovery-claim ]; then
  CURRENT=unknown
  AT=${4:-}
  LINE=
elif [ "$ACTION" = recovery-claim-clear ]; then
  CURRENT=
  AT=
  LINE=
  CLAIM=${4:-}
elif [ "$ACTION" = recovery-working ]; then
  CURRENT=working
  AT=${4:-}
  LINE=
  CLAIM=${5:-}
elif [ "$ACTION" = resolve ] || [ "$ACTION" = self-resolve ]; then
  CURRENT=working
  AT=${4:-}
  LINE=${5:-}
else
  CURRENT=${4:-}
  AT=${5:-}
  LINE=${6:-}
fi
case "$ACTION:$CURRENT" in
  record:working|record:parked|record:paused|record:blocked|record:failed|record:done|record:unknown) ;;
  recovery-claim:unknown) ;;
  recovery-claim-clear:) ;;
  recovery-working:working) ;;
  barrier:working|barrier:parked|barrier:paused|barrier:blocked|barrier:failed|barrier:done|barrier:unknown) ;;
  append:|append:working|append:parked|append:paused|append:blocked|append:failed|append:done|append:unknown) ;;
  self-append:|self-append:working|self-append:parked|self-append:paused|self-append:blocked|self-append:failed|self-append:done|self-append:unknown) ;;
  resolve:working) ;;
  self-resolve:working) ;;
  *) usage ;;
esac
if [ "$ACTION" != barrier ] && [ "$ACTION" != recovery-claim-clear ]; then
  case "$AT" in ''|*[!0-9]*) usage ;; esac
fi
case "$ACTION" in append|resolve|self-append|self-resolve) [ -n "$LINE" ] || usage ;; esac

META="$STATE/$ID.meta"
has_meta=0
if [ -f "$META" ] && [ ! -L "$META" ]; then
  has_meta=1
  incarnation=$(sed -n 's/^dashboard_incarnation=//p' "$META" | tail -1)
  case "$incarnation" in ''|*[!A-Za-z0-9._-]*) incarnation="legacy-$ID" ;; esac
fi
[ "$has_meta" = 1 ] || [ "$ACTION" = append ] || [ "$ACTION" = resolve ] || [ "$ACTION" = self-append ] || [ "$ACTION" = self-resolve ] || exit 0

DIR="$STATE/dashboard-transitions"
if [ -e "$DIR" ] || [ -L "$DIR" ]; then
  [ -d "$DIR" ] && [ ! -L "$DIR" ] || exit 1
else
  (umask 077; mkdir -p "$DIR")
  chmod 700 "$DIR"
fi

LOCK="$DIR/$ID.lock"
LOCK_HELD=0
if [ "${FM_DASHBOARD_RECOVERY_TRANSITION_LOCK:-0}" = 1 ]; then
  [ "$ACTION" = recovery-working ] || exit 1
else
  fm_lock_acquire_wait "$LOCK"
  LOCK_HELD=1
fi
cleanup() {
  [ "$LOCK_HELD" = 1 ] && fm_lock_release "$LOCK" || true
}
trap cleanup EXIT HUP INT TERM

RECORD="$DIR/$ID.json"
prior_state=
prior_incarnation=
prior_at=
prior_active=0
prior_terminal_state=
prior_terminal_at=
if [ "$has_meta" = 1 ] && [ -n "$CURRENT" ] && [ -f "$RECORD" ] && [ ! -L "$RECORD" ]; then
  IFS=$'\t' read -r prior_state prior_incarnation prior_at prior_active prior_terminal_state prior_terminal_at < <(
    jq -r '[.state // "",(.incarnation // "" | tostring),(.transition_at | if type == "number" then tostring else "-" end),(.active_seconds // 0 | tostring),(.terminal_receipt.state // ""),(.terminal_receipt.recorded_at | if type == "number" then tostring else "-" end)] | @tsv' "$RECORD" 2>/dev/null || true
  )
  if [ "$prior_incarnation" != "$incarnation" ]; then
    prior_state=
    prior_at=
    prior_active=0
    prior_terminal_state=
    prior_terminal_at=
  fi
fi
case "$prior_at" in ''|*[!0-9]*) prior_at= ;; esac
case "$prior_active" in ''|*[!0-9]*) prior_active=0 ;; esac
case "$prior_terminal_state:$prior_terminal_at" in
  done:[0-9]*|failed:[0-9]*) ;;
  *) prior_terminal_state=; prior_terminal_at= ;;
esac
terminal_receipt_state=$prior_terminal_state
terminal_receipt_at=$prior_terminal_at
case "$ACTION" in
  append|self-append)
    case "$(status_line_verb "$LINE")" in
      done|failed)
        terminal_receipt_state=$(status_line_verb "$LINE")
        terminal_receipt_at=$AT
        [ -n "$CURRENT" ] || CURRENT=$terminal_receipt_state
        ;;
    esac
    ;;
esac
legacy_terminal_status_receipt() {
  [ -f "$STATE/$ID.status" ] && [ ! -L "$STATE/$ID.status" ] || return 1
  LC_ALL=C awk '
    length($0) > 4096 { next }
    {
      verb = $0
      sub(/:.*/, "", verb)
      sub(/\[.*/, "", verb)
      sub(/^[[:space:]]*/, "", verb)
      sub(/[[:space:]]*$/, "", verb)
      if (verb == "done" || verb == "failed") {
        found = 1
        exit
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$STATE/$ID.status"
}
terminal_recovery_receipt() {
  case "$terminal_receipt_state:$terminal_receipt_at" in done:[0-9]*|failed:[0-9]*) return 0 ;; esac
  case "$prior_state" in done|failed) return 0 ;; esac
  legacy_terminal_status_receipt
}
CLAIM_PATH="$DIR/$ID.recovery-claim"
if [ "$ACTION" = recovery-claim ]; then
  terminal_recovery_receipt && exit 3
fi
if [ "$ACTION" = recovery-working ]; then
  claim_incarnation=$(sed -n 's/^incarnation=//p' "$CLAIM_PATH" 2>/dev/null | tail -1)
  claim_value=$(sed -n 's/^claim=//p' "$CLAIM_PATH" 2>/dev/null | tail -1)
  if [ "$claim_incarnation" != "$incarnation" ] || [ "$claim_value" != "$CLAIM" ]; then
    exit 3
  fi
  terminal_recovery_receipt && exit 3
fi
if [ "$ACTION" = resolve ] || [ "$ACTION" = self-resolve ]; then
  case "$prior_state" in done|failed) CURRENT= ;; esac
fi
receipt_changed=0
if [ "$terminal_receipt_state:$terminal_receipt_at" != "$prior_terminal_state:$prior_terminal_at" ]; then
  receipt_changed=1
fi
if [ "$has_meta" = 1 ] && [ "$ACTION" = barrier ]; then
  tmp=$(umask 077; mktemp "$DIR/.${ID}.XXXXXX")
  if ! jq -n --arg id "$ID" --arg state "$CURRENT" --arg incarnation "$incarnation" --arg terminal_state "$terminal_receipt_state" --argjson terminal_at "${terminal_receipt_at:-0}" --argjson active_seconds "$prior_active" '
    {schema_version:1,id:$id,incarnation:$incarnation,state:$state,transition_at:null,active_seconds:$active_seconds}
    + (if $terminal_state == "" then {} else {terminal_receipt:{state:$terminal_state,recorded_at:$terminal_at}} end)' > "$tmp" \
    || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    exit 1
  fi
elif [ "$has_meta" = 1 ] && [ -n "$CURRENT" ] && { [ "$prior_state" != "$CURRENT" ] || [ -z "$prior_at" ] || [ "$receipt_changed" -eq 1 ]; }; then
  if [ -n "$prior_at" ] && [ "$AT" -lt "$prior_at" ]; then exit 1; fi
  tmp=$(umask 077; mktemp "$DIR/.${ID}.XXXXXX")
  if ! jq -n --arg id "$ID" --arg state "$CURRENT" --arg incarnation "$incarnation" --arg terminal_state "$terminal_receipt_state" --argjson terminal_at "${terminal_receipt_at:-0}" --argjson transition_at "$AT" --arg prior_state "$prior_state" --argjson prior_at "${prior_at:-$AT}" --argjson active_seconds "$prior_active" '
    ($active_seconds + (if $prior_state == "working" then ($transition_at - $prior_at) else 0 end)) as $active_seconds
    | {schema_version:1,id:$id,incarnation:$incarnation,state:$state,transition_at:$transition_at,active_seconds:$active_seconds}
    + (if $terminal_state == "" then {} else {terminal_receipt:{state:$terminal_state,recorded_at:$terminal_at}} end)' > "$tmp" \
    || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    exit 1
  fi
fi
if [ "$ACTION" = recovery-claim ]; then
  CLAIM="r${AT}.${BASHPID:-$$}.${RANDOM}"
  tmp=$(umask 077; mktemp "$DIR/.${ID}.recovery-claim.XXXXXX")
  if ! {
    printf 'incarnation=%s\n' "$incarnation"
    printf 'claim=%s\n' "$CLAIM"
  } > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$CLAIM_PATH"; then
    rm -f -- "$tmp"
    exit 1
  fi
  printf '%s\n' "$CLAIM"
elif [ "$ACTION" = recovery-claim-clear ]; then
  claim=$(sed -n 's/^claim=//p' "$CLAIM_PATH" 2>/dev/null | tail -1)
  [ "$claim" = "$CLAIM" ] && rm -f -- "$CLAIM_PATH" || true
elif [ "$ACTION" = recovery-working ]; then
  rm -f -- "$CLAIM_PATH"
else
  case "$CURRENT" in done|failed) rm -f -- "$CLAIM_PATH" || true ;; esac
fi
case "$ACTION" in
  append|resolve)
    printf '%s\n' "$LINE" >> "$STATE/$ID.status"
    ;;
  self-append|self-resolve)
    append_rc=0
    fm_wake_status_append_self_announced "$STATE" "$STATE/$ID.status" "$LINE" || append_rc=$?
    [ "$append_rc" -ne 2 ] || exit 1
    ;;
esac
