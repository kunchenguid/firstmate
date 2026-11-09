#!/usr/bin/env bash
# tests/watch-triage-helpers.sh - shared fixtures for the watch-triage
# behavior suites. These encode the watcher launch, poll-cycle waits, and
# wedge-threshold helpers, so they live here rather than in the generic
# tests/lib.sh. Generic reporters/assertions come from lib.sh via
# wake-helpers.sh.
#
# Source this from a watch-triage test file:
#   # shellcheck source=tests/watch-triage-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"
#
set -u

if [ -n "${FM_WATCH_TRIAGE_HELPERS_SOURCED:-}" ]; then
  return 0
fi
FM_WATCH_TRIAGE_HELPERS_SOURCED=1

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# Common watcher knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. FM_CREW_STATE_BIN
# points at the case's hermetic fake fm-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via FM_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$@" "$WATCH" > "$out" &
}

# Wait until <pid>'s watcher has completed a whole poll cycle, or exited first.
# A fixed wait_live budget only proves the process is still ALIVE: fm-watch.sh
# does bounded startup work (the recovery-marker snapshot, lock acquisition)
# before its first stale scan, so on a loaded
# machine a short fixed budget can reap a round before the cycle it asserts on
# ever ran - and then every "no wake, no marker" assertion passes vacuously
# while every "marker written" assertion fails spuriously.
# The liveness beacon is touched at the TOP of every poll, so this drops any
# beacon left by an earlier round, waits for THIS watcher to write a fresh one
# (some poll's top), then waits for that one to advance (the next poll's top) -
# and the whole cycle in between is what the caller's assertions describe.
# 0 if the watcher is still alive after a completed cycle, 1 if it exited.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Every wait_for_exit budget in this file is 100 ticks (10s), not because any
# watcher takes that long to decide, but because fm-watch.sh does bounded
# startup work before its first poll: a tighter budget reaps the process while
# it is still starting and reports a spurious "did not surface" failure. A
# generous budget can only remove that false negative - a watcher that never
# exits still fails the assertion when the budget runs out.
wait_numeric_file() {
  local file=$1 limit=${2:-30} i=0 value
  while [ "$i" -lt "$limit" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Set <file>'s mtime to exactly <epoch> seconds, for aging a busy-turn marker by
# a precise amount (touch -t takes a local-time stamp, not an epoch, on both
# platforms, so convert via BSD `date -r` or GNU `date -d @`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1")
      size=$(size_of "$1")
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
      ;;
    *)
      if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
      ;;
  esac
}

# Stop an owned watcher. TERM must end it through its EXIT cleanup, so one still
# alive after the file's standard 100-tick budget fails the case here, with the
# process evidence wait_for_exit prints, instead of an unbounded wait hanging
# the whole suite until the CI job timeout.
reap() {
  local rc
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher pid $1 did not exit within 10s of TERM"
}

# --- pure classifier predicates (fm-classify-lib.sh) ------------------------

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

# --- the wedge threshold consults the worker's own declared wait ------------
# Upstream kunchenguid/firstmate#3909 and #2614: wedge_timer_check escalated on
# elapsed idle time alone, without ever asking whether the worker had already
# said why its pane was quiet. Nothing re-consulted that declaration once the
# timer was running, so the ladder climbed for as long as the wait lasted and
# each escalation cost a supervising turn. Past FM_WEDGE_DEMAND_INSPECT_COUNT
# every repeat also carried demand-deep-inspection, which by its own wording
# forbids re-absorbing on the run-step or pane state, so the supervisor could not
# even use the evidence that was there.
#
# Both directions are pinned in each case below, because a bound that only
# proves the quiet direction would be indistinguishable from simply deleting
# wedge detection: the lane WITHOUT a declaration must keep the identical
# schedule, escalation count, reason and demand-deep-inspection wording.

# Run one watcher round against a lane whose pane is already stably stale at the
# recorded hash - the population wedge_timer_check owns. FM_STALE_ESCALATE_SECS=1
# puts every round at the threshold, so a round either escalates or is deferred;
# the real 240s default only changes how long that takes.
# <mode> `exit` requires the watcher to surface and exit, `absorb` requires it to
# survive whole poll cycles at the threshold. Returns 1 when it does the other.
# The endpoint this lane's window resolves to is a live grok agent unless a case
# drives it elsewhere with FM_TEST_PANE_COMMAND (the pane's foreground command)
# and FM_TEST_TMUX_WINDOWS (the session inventory the recorded window must appear
# in), which is how the dead-endpoint cases below reach `dead` and `missing`.
wedge_threshold_round() {  # <state> <fakebin> <out> <capture> <window> <verdict> <exit|absorb>
  local state=$1 fakebin=$2 out=$3 capture=$4 window=$5 verdict=$6 mode=$7 pid cycles=0
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_CONFIG_OVERRIDE="$(dirname "$state")/config" \
    FM_FAKE_TMUX_CURRENT_COMMAND="${FM_TEST_PANE_COMMAND-grok}" \
    FM_FAKE_TMUX_WINDOWS="${FM_TEST_TMUX_WINDOWS-}" FM_FAKE_CREW_STATE="$verdict" \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS="${FM_TEST_PAUSE_RESURFACE:-999}" FM_STALE_ESCALATE_SECS="${FM_TEST_STALE_ESCALATE:-1}" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if [ "$mode" = exit ]; then
    wait_for_exit "$pid" 100 || { reap "$pid"; return 1; }
    return 0
  fi
  while [ "$cycles" -lt 3 ]; do
    wait_poll_cycle "$state" "$pid" 300 || { reap "$pid"; return 1; }
    cycles=$((cycles + 1))
  done
  reap "$pid"
  return 0
}

# A lane already stably stale at its recorded hash - exactly where
# wedge_timer_check owns the pane. <status-log> is the WHOLE log, so a case can
# supply the multi-line history a decision fold actually reads; <status-age>
# backdates the file so a case can put the bounded recheck cadence in or out of
# reach. <wedge-timer-age>, when given, pre-arms this key's wedge timer at that
# age: a log whose last line is captain-relevant (a `needs-decision:` escalation
# is) routes through the overridden-terminal-status branch, which reaches
# wedge_timer_check only for a hash whose timer is already running, so a case on
# that path must arm it rather than assume the plain non-terminal route.
wedge_threshold_fixture() {  # <name> <status-log> <status-age-secs> [<wedge-timer-age-secs>]
  local name=$1 log=$2 age=$3 timer=${4-} dir state statusf window key text back
  dir=$(make_case "$name"); state="$dir/state"
  window="test:fm-wedge"
  statusf="$state/wedge.status"
  text='waiting at the gate'
  printf '%s' "$text" > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/wedge.meta"
  printf '%s\n' "$log" > "$statusf"
  back=$(( $(date +%s) - age ))
  set_mtime "$back" "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-wedge_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "$text")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Already surfaced once, as it is after the supervision turn that handled the
  # first sight: the suppressor holds this exact hash, so every further poll goes
  # straight to the wedge timer.
  printf '%s' "$(hash_text "$text")" > "$state/.stale-$key"
  if [ -n "$timer" ]; then
    printf '%s\n' "$(( $(date +%s) - timer ))" > "$state/.stale-since-$key"
  fi
  # An UNCONFIGURED home: the config dir exists and is empty, so every case here
  # starts with the parked-gate wait evidence off and has to arm it deliberately.
  mkdir -p "$dir/config"
  printf '%s\n' "$dir"
}

wedge_stale_wakes() {  # <state> <window>
  awk -F '\t' -v w="$2" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

# bin/fm-captain-hold.sh against a hold fixture's own home.
run_hold() {  # <dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_CONFIG_OVERRIDE="$dir/config" "$ROOT/bin/fm-captain-hold.sh" "$@" >/dev/null 2>&1
}

# --- the away-posture record: captain-held items are never rechecked ----------
# While state/.afk-contract exists (bin/fm-afk-contract.sh) nobody is there to
# answer a captain-held item and the return brief lists it, so every stale path
# absorbs such a pane silently: the declared-wait cadence, the live-agent first
# sight, the backlog-hold bound, and the daemon-owned one-shot handoff. Archiving
# the record restores the ordinary bounded recheck, so the rule is the record's,
# not a lost alarm.

# A UTC ISO 8601 stamp for an epoch, on either date flavor.
iso_utc_at() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

write_away_record() {  # <state>
  if ! FM_HOME="$(dirname "$1")" FM_STATE_OVERRIDE="$1" "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null 2>&1; then
    fail "could not write the away-posture record in $1"
  fi
}

archive_away_record() {  # <state>
  FM_HOME="$(dirname "$1")" FM_STATE_OVERRIDE="$1" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null 2>&1 \
    || fail "could not archive the away-posture record in $1"
}
