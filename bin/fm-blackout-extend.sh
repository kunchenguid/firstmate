#!/usr/bin/env bash
# Defer (extend) the overnight blackout into the evening on demand: "keep
# supervising until 21:00 tonight" even if said after the default 18:00 start.
#
# Usage:
#   fm-blackout-extend.sh HH:MM      supervise until HH:MM local time today
#   fm-blackout-extend.sh +Nh|+Nm    supervise until now + N hours / minutes
#   fm-blackout-extend.sh --clear     cancel any active extension
#   fm-blackout-extend.sh --status    print the current extension, if any
#
# The target is resolved to an absolute epoch in FM_BLACKOUT_TZ and written to the
# LOCAL, GITIGNORED state file state/blackout-override. The shared predicate
# (fm-blackout-lib.sh) honors it: while the override epoch is in the FUTURE we stay
# ACTIVE (not in blackout) even past the start hour; once now reaches it, normal
# blackout rules resume. A past override is ignored (auto-expiry) so it never
# lingers into the next day.
#
# Works both proactively (before 18:00: extend to 21:00) and reactively (already
# 19:00 and in blackout: this re-activates supervision until the given time). In
# the reactive case the running blackout sleeper (bin/fm-watch-arm.sh) sees the
# window is active on its next check and (re)starts the real watcher on its own -
# no rival process is spawned here, so the existing singleton/lock discipline is
# untouched. The override file write is atomic.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-blackout-lib.sh
. "$SCRIPT_DIR/fm-blackout-lib.sh"

OVERRIDE_FILE="$STATE/blackout-override"
TZ_NAME=${FM_BLACKOUT_TZ:-America/New_York}

usage() {
  echo "usage: fm-blackout-extend.sh HH:MM | +Nh | +Nm | --clear | --status" >&2
  exit 2
}

# Epoch -> "HH:MM TZ" for confirmations, in the blackout timezone.
fmt_epoch() {
  local e=$1
  if [ "$(uname)" = Darwin ]; then
    TZ="$TZ_NAME" date -r "$e" "+%H:%M %Z" 2>/dev/null
  else
    TZ="$TZ_NAME" date -d "@$e" "+%H:%M %Z" 2>/dev/null
  fi
}

# Today's date (YYYY-MM-DD) in the blackout timezone, at the current (injectable) now.
today_in_tz() {
  local now=$1
  if [ "$(uname)" = Darwin ]; then
    TZ="$TZ_NAME" date -r "$now" +%Y-%m-%d 2>/dev/null
  else
    TZ="$TZ_NAME" date -d "@$now" +%Y-%m-%d 2>/dev/null
  fi
}

# Resolve "today at HH:MM in TZ_NAME" to an epoch. Echoes the epoch or returns 1.
resolve_hhmm() {
  local hh=$1 mm=$2 now day epoch
  now=$(fm_blackout_now_epoch)
  day=$(today_in_tz "$now") || return 1
  [ -n "$day" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    epoch=$(TZ="$TZ_NAME" date -j -f "%Y-%m-%d %H:%M" "$day $hh:$mm" +%s 2>/dev/null) || return 1
  else
    epoch=$(TZ="$TZ_NAME" date -d "$day $hh:$mm" +%s 2>/dev/null) || return 1
  fi
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$epoch"
}

write_override() {  # <epoch>
  local epoch=$1 tmp
  mkdir -p "$STATE" 2>/dev/null || true
  tmp="$OVERRIDE_FILE.tmp.$$"
  printf '%s\n' "$epoch" > "$tmp" || { echo "fm-blackout-extend: cannot write override" >&2; exit 1; }
  mv -f "$tmp" "$OVERRIDE_FILE" || { rm -f "$tmp"; echo "fm-blackout-extend: cannot write override" >&2; exit 1; }
}

arg=${1:-}
[ -n "$arg" ] || usage

case "$arg" in
  --clear)
    if [ -f "$OVERRIDE_FILE" ]; then
      rm -f "$OVERRIDE_FILE"
      echo "blackout override cleared: normal quiet-hours schedule resumes."
    else
      echo "blackout override cleared: none was set."
    fi
    exit 0
    ;;
  --status)
    ov=$(fm_blackout_override_epoch)
    if [ -n "$ov" ]; then
      echo "blackout extended: supervising until $(fmt_epoch "$ov") (override active)."
    else
      echo "no active blackout extension."
    fi
    exit 0
    ;;
  --help|-h)
    usage
    ;;
esac

now=$(fm_blackout_now_epoch)
target=

case "$arg" in
  +*h|+*H)
    n=${arg#+}; n=${n%[hH]}
    case "$n" in ''|*[!0-9]*) usage ;; esac
    target=$(( now + n * 3600 ))
    ;;
  +*m|+*M)
    n=${arg#+}; n=${n%[mM]}
    case "$n" in ''|*[!0-9]*) usage ;; esac
    target=$(( now + n * 60 ))
    ;;
  [0-9][0-9]:[0-9][0-9]|[0-9]:[0-9][0-9])
    hh=${arg%%:*}; mm=${arg##*:}
    if [ "$((10#$hh))" -gt 23 ] || [ "$((10#$mm))" -gt 59 ]; then
      echo "fm-blackout-extend: invalid time '$arg' (expected HH:MM, 00:00-23:59)" >&2
      exit 2
    fi
    target=$(resolve_hhmm "$hh" "$mm") || {
      echo "fm-blackout-extend: could not resolve '$arg' in $TZ_NAME" >&2
      exit 1
    }
    ;;
  *)
    usage
    ;;
esac

if [ "$target" -le "$now" ]; then
  echo "fm-blackout-extend: '$arg' resolves to $(fmt_epoch "$target"), which is not in the future - nothing to extend." >&2
  echo "  For a time earlier in the clock than now, it has already passed today; use a later HH:MM or a +Nh/+Nm form." >&2
  exit 2
fi

write_override "$target"
mins=$(( (target - now + 59) / 60 ))
echo "blackout extended: supervising until $(fmt_epoch "$target") (in ${mins}m). Quiet hours resume then; a running watcher restarts within ~1 min."
