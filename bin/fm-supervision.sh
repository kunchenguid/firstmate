#!/usr/bin/env bash
# The operator's one off switch for this home's background supervision loop,
# and its matching on. docs/turnend-guard.md "Supervision switched off" owns
# what every supervision component does while it is off and how the session
# catches up when it is turned back on.
#
# Usage:
#   fm-supervision.sh off
#   fm-supervision.sh on
#   fm-supervision.sh status
#
# off     Writes state/.supervision-off FIRST, so every component that reads it
#         (fm_supervision_switched_off, bin/fm-supervision-lib.sh) stands aside
#         from that instant, then stops what is already running for this home:
#           - away or quiet mode and its daemon, through
#             bin/fm-afk-launch.sh stop, retried a few times because a daemon's
#             shutdown can outlast one stop's wait (the daemon's shutdown
#             flush types nothing while the switch is off);
#           - the live watcher cycle, through bin/fm-watch-arm.sh --stop, which
#             is home-scoped, retried until no watcher holds this home's lock
#             because a cycle closing at that moment can hand over to a
#             successor before it reads the marker; the arm owner parked on
#             that cycle then closes silently instead of re-arming.
#         The marker records the time.
#         Running off again re-stops anything still running and keeps the
#         original time.
# on      Removes the marker and starts nothing itself: the primary's next turn
#         end restores the cycle, either through its arm owner or through the
#         turn-end guard's repair instruction.
# status  Prints "supervision: on" or "supervision: off since <time>", and
#         whether a watcher or an away or quiet daemon is still running for
#         this home.
#
# Exit status: 0 on success; 1 when a stop step failed (the marker stays, so
# nothing re-arms; run off again); 2 on a usage error.
set -u

FM_SUPERVISION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_SUPERVISION_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME
MARKER="$STATE/.supervision-off"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_SUPERVISION_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$FM_SUPERVISION_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
FM_AFK_CONTRACT_STATE="$STATE" . "$FM_SUPERVISION_DIR/fm-afk-contract.sh"

usage() {
  sed -n '7,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

help_text() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

# The home's away or quiet daemon, when its singleton lock names a live,
# identity-matched process (the same proof the turn-end guard accepts).
daemon_running() {
  local lockdir="$STATE/.supervise-daemon.lock" pid recorded current
  pid=$(cat "$lockdir/pid" 2>/dev/null) || return 1
  fm_pid_alive "$pid" || return 1
  recorded=$(cat "$lockdir/pid-identity" 2>/dev/null) || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$current" ] && [ "$current" = "$recorded" ]
}

# A live pid in this home's watcher lock. Deliberately not identity-checked:
# a watcher that has just taken the lock has not recorded its identity yet, so
# the home-scoped stop declines it for that moment and off must try again.
watcher_running() {
  local pid
  pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null) || return 1
  fm_pid_alive "$pid"
}

write_marker() {
  local tmp
  [ -e "$MARKER" ] && return 0
  mkdir -p "$STATE" || return 1
  tmp=$(mktemp "$STATE/.supervision-off.XXXXXX") || return 1
  if ! {
    printf 'since=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'since_epoch=%s\n' "$(date +%s)"
  } > "$tmp" || ! mv -f "$tmp" "$MARKER"; then
    rm -f "$tmp"
    return 1
  fi
}

marker_field() {  # <name>
  sed -n "s/^$1=//p" "$MARKER" 2>/dev/null | head -n 1
}

switch_off() {
  local rc=0 attempt out stopped
  if ! write_marker; then
    echo "error: could not write $MARKER; supervision is unchanged" >&2
    return 1
  fi
  if [ -e "$STATE/.afk" ] || fm_afk_contract_present "$STATE" || daemon_running; then
    stopped=0
    for attempt in 1 2 3; do
      if out=$("$FM_SUPERVISION_DIR/fm-afk-launch.sh" stop 2>&1); then
        stopped=1
        break
      fi
      [ "$attempt" -lt 3 ] && sleep 2
    done
    if [ "$stopped" -eq 0 ]; then
      printf '%s\n' "$out" >&2
      echo "error: away or quiet mode did not stop cleanly; run off again" >&2
      rc=1
    fi
  fi
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    out=$("$FM_SUPERVISION_DIR/fm-watch-arm.sh" --stop 2>&1) || {
      printf '%s\n' "$out" >&2
      rc=1
      break
    }
    watcher_running || break
    [ "$attempt" -lt 10 ] && sleep 1
  done
  if watcher_running; then
    echo "error: a watcher is still running for this home; run off again" >&2
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    echo "supervision: off"
    echo "Nothing runs in the background for this home now: no watcher, no away or quiet daemon, and nothing is typed into the supervisor pane."
    echo "Workers keep writing their status; run bin/fm-wake-drain.sh to read it. Turn supervision back on with: bin/fm-supervision.sh on"
  fi
  return "$rc"
}

switch_on() {
  if [ ! -e "$MARKER" ]; then
    echo "supervision: on (it was not switched off)"
    return 0
  fi
  rm -f "$MARKER" || { echo "error: could not remove $MARKER" >&2; return 1; }
  echo "supervision: on"
  echo "The primary's next turn end restores the watcher cycle, and its first check reports every status change made while supervision was off."
}

show_status() {
  local since
  if fm_supervision_switched_off "$STATE"; then
    since=$(marker_field since)
    echo "supervision: off since ${since:-an unknown time}"
  else
    echo "supervision: on"
  fi
  if watcher_running; then echo "watcher: running"; else echo "watcher: not running"; fi
  if daemon_running; then echo "away/quiet daemon: running"; else echo "away/quiet daemon: not running"; fi
}

main() {
  case "${1:-}" in
    off) [ "$#" -eq 1 ] || { usage >&2; return 2; }; switch_off ;;
    on) [ "$#" -eq 1 ] || { usage >&2; return 2; }; switch_on ;;
    status) [ "$#" -eq 1 ] || { usage >&2; return 2; }; show_status ;;
    -h|--help|help) help_text ;;
    *) usage >&2; return 2 ;;
  esac
}

main "$@"
