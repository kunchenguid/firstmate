#!/usr/bin/env bash
# tests/fm-watch-ghost-window.test.sh - the ghost-window guard in the watcher's
# stale backbone (bin/fm-watch.sh). A recorded window whose backend reports its
# endpoint structurally gone (a torn-down task's pane: tmux `missing`, herdr
# structurally-missing) must be aged out before the stale ladder ever sees it,
# because a stable capture hash for a dead endpoint otherwise escalates every
# STALE_ESCALATE_SECS and wakes firstmate for a pane that no longer exists
# (2026-09 ghost-escalation incident: 21+ wedge escalations for torn-down herdr
# windows). The guard must NOT skip a live pane whose agent merely reads
# agent-less (`dead` = an idle shell), which is exactly the finished-but-
# unreported state the stale ladder exists to surface.
#
# Shared fixtures for the watcher wake paths live in wake-helpers.sh; the
# absorbed-then-escalated baseline these tests mirror lives in
# fm-watch-triage.test.sh.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
# shellcheck disable=SC2034 # make_case (wake-helpers.sh) roots every case under TMP_ROOT.
TMP_ROOT=$(fm_test_tmproot fm-watch-ghost-window-tests)

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Local copies of the poll-cycle and signature helpers the triage suite owns:
# kept here rather than promoted so the triage suite keeps its own contract.
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

seen_sig() {
  local reported size ident
  reported=$(status_observed_signature "$1")
  size=$(size_of "$1")
  ident=$(_fm_open_decisions_file_ident "$1")
  printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
}

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


# A recorded window the fake tmux session does NOT contain: the structural
# `missing` verdict. Pre-seeded stale bookkeeping (as a real ghost accumulates
# during its tear-down race) must be aged out, nothing woken, and the triage
# log must name the ghost exactly once.
test_ghost_window_is_aged_out_before_the_stale_ladder() {
  local dir state fakebin out window key capture_file pid
  dir=$(make_case ghost-window-aged-out); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-ghost"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\nbackend=tmux\n' "$window" > "$state/ghost.meta"
  printf 'working: still compiling\n' > "$state/ghost.status"
  sig=$(seen_sig "$state/ghost.status"); printf '%s' "$sig" > "$state/.seen-ghost_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # The ghost reached the stale ladder before its pane was torn down, so its
  # bookkeeping exists exactly as a real incident leaves it.
  printf '%s' "$(hash_text 'idle building output')" > "$state/.hash-$key"
  printf '3\n' > "$state/.count-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  # The fake session inventory names a DIFFERENT window: fm-ghost is gone.
  export FM_FAKE_TMUX_WINDOWS="otherwin"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "watcher exited on a ghost window (should absorb silently): $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "ghost window printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "ghost window enqueued a wake"
  [ ! -e "$state/.hash-$key" ] || fail "ghost window hash bookkeeping was not aged out"
  [ ! -e "$state/.stale-$key" ] || fail "ghost window stale suppressor was not aged out"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "ghost window escalation count was not aged out"
  grep -F "ghost window aged out" "$state/.watch-triage.log" >/dev/null \
    || fail "ghost window aging was not recorded in the triage log"
  unset FM_FAKE_TMUX_WINDOWS
  pass "ghost window aged out before the stale ladder: no wake, bookkeeping cleared, triage line once"
}

# The same recorded window WITH a live endpoint: the pane sits in the session
# inventory as an agent-less idle shell (`dead`, not `missing`), its capture
# hash is stable, and its backdated wedge timer is past the threshold - the
# exact shape the guard must leave alone, escalated like any real stale pane.
test_live_idle_shell_pane_still_escalates() {
  local dir state fakebin out window key capture_file pane_hash pid
  dir=$(make_case ghost-guard-spares-live-pane); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-real"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\nbackend=tmux\n' "$window" > "$state/real.meta"
  printf 'working: still compiling\n' > "$state/real.status"
  sig=$(seen_sig "$state/real.status"); printf '%s' "$sig" > "$state/.seen-real_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text 'idle building output')
  # Already-classified stale bookkeeping for a REAL pane: suppressor at the
  # current hash, plus a wedge timer backdated past the threshold, exactly the
  # shape a real pane carries when its escalation is due.
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '3\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  # An agent-less idle shell foreground: the fake's pane_current_command read
  # returns a shell, so the agent verdict is `dead`, never `missing`.
  export FM_FAKE_TMUX_WINDOW="$window"
  export FM_FAKE_TMUX_CURRENT_COMMAND="bash"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not escalate a live idle pane past the threshold (out=$(cat "$out"))"
  grep -F "possible wedge" "$out" >/dev/null || fail "live idle pane escalation did not flag a possible wedge"
  grep -F "ghost window aged out" "$state/.watch-triage.log" 2>/dev/null \
    && fail "the ghost guard aged out a LIVE pane"
  unset FM_FAKE_TMUX_WINDOW FM_FAKE_TMUX_CURRENT_COMMAND
  pass "live agent-less idle pane still wedge-escalated; guard did not suppress it"
}

test_ghost_window_is_aged_out_before_the_stale_ladder
test_live_idle_shell_pane_still_escalates
