#!/usr/bin/env bash
# tests/fm-watch-wedge-cap-live.test.sh - live lab proof that the
# FM_WEDGE_MAX_ESCALATIONS cap engages on a genuinely wedged worker and then
# releases itself, driven through a real disposable lab home.
#
# Why a live guard exists: the hermetic suite in
# tests/fm-watch-wedge-cap.test.sh pins the cap's logic against a stubbed tmux
# and a canned crew-state verdict, so it can only confirm the assumptions those
# stubs already encode. This guard removes both substitutions: a real tmux server
# on a lab-private socket (minted by bin/fm-lab-home.sh, the repository's own
# disposable-home mechanism) hosts a real pane running a real process, and the
# real bin/fm-watch.sh polls it. A pane whose process is genuinely wedged - a
# live shell sitting at a prompt with nothing running behind it - is what the
# wedge timer exists to catch, and the cap's whole purpose is to bound what an
# unattended supervisor spends re-notifying about exactly that pane.
#
# It demonstrates both halves of the contract in one run:
#   1. the cap engaging - after FM_WEDGE_MAX_ESCALATIONS wedge escalations the
#      watcher publishes exactly one PERMANENTLY-WEDGED wake, writes both cap
#      markers, and goes silent while the pane stays wedged;
#   2. the cap releasing - once FM_CAP_HORIZON_SECS has elapsed the markers
#      expire, the wedge re-escalates on its own merits, and the watcher is
#      audible again without any operator action.
#
# It writes a timestamped transcript so a pull request can cite real output
# rather than a claim.
#
# Ordinary CI has no cost-free way to keep a tmux server and a wedged process
# alive for the horizon this run needs, so this is opt-in under fm_live_gate and
# stays out of the default lanes. The portable counterpart runs everywhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_WATCH_WEDGE_CAP_LIVE tmux

LAB_HOME=''
LAB_TMUX_DIR=''
LAB_SOCKET=''
SESSION=''
TRANSCRIPT=''
cleanup() {
  if [ -n "$LAB_SOCKET" ] && [ -n "$SESSION" ]; then
    tmux -S "$LAB_SOCKET" kill-server >/dev/null 2>&1 || true
  fi
  if [ -n "$LAB_HOME" ]; then
    "$ROOT/bin/fm-lab-home.sh" teardown "$LAB_HOME" >/dev/null 2>&1 || true
    rm -rf "$LAB_HOME"
  fi
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

# say <text>: one timestamped transcript line, on stdout and in the transcript.
say() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" | tee -a "$TRANSCRIPT"
}

note() { printf '# %s\n' "$1"; }
pass() { printf 'ok - %s\n' "$1"; }

MAX=2
# A horizon short enough to watch elapse, and a stale bound short enough to
# reach the wedge path without a long wait. Both are the point of a live run:
# the real production values are a day and four minutes, which no CI budget can
# spend, and shrinking them exercises the identical code path.
#
# The horizon must comfortably exceed one whole watcher cycle plus the silence
# probes that follow the cap. A horizon that expires mid-probe makes the pane
# audible again for a completely legitimate reason, and the run then proves
# nothing about the cap holding - so the guard below also asserts the probes
# finished inside the horizon rather than trusting the sleep.
STALE_SECS=2
# Sized against the measured cost of a real cycle on this host: a lab watcher
# takes tens of seconds to start (it loads the full library set and refreshes
# the home summary), so two silence probes plus their startup dominate the
# window. The guard asserts the probes finished inside the horizon rather than
# trusting this number, and fails loudly if a slower host overruns it.
HORIZON_SECS=300
# How long a single cycle waits for the pane classification to land before it
# concludes the cycle stayed silent. A wedged pane produces no wake on a
# silenced poll, so the watcher keeps polling and this is the bound that ends
# it. The cap check runs on the watcher's first poll, so this only has to cover
# one poll plus the heartbeat write.
CYCLE_BOUND=6

TMP_ROOT=$(fm_test_tmproot fm-watch-wedge-cap-live)
LAB_HOME="$TMP_ROOT/lab-home"
TRANSCRIPT="$TMP_ROOT/transcript.txt"
: > "$TRANSCRIPT"

say "wedge-cap live run starting"
say "cap=FM_WEDGE_MAX_ESCALATIONS=$MAX horizon=FM_CAP_HORIZON_SECS=${HORIZON_SECS}s stale=FM_STALE_ESCALATE_SECS=${STALE_SECS}s"
say "tmux $(tmux -V), watcher $(basename "$ROOT")/bin/fm-watch.sh at $(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# The disposable home, minted by the repository's own lab mechanism.
"$ROOT/bin/fm-lab-home.sh" create "$LAB_HOME" >/dev/null \
  || fail "bin/fm-lab-home.sh could not mint a lab home at $LAB_HOME"
say "lab home: $LAB_HOME"
LAB_TMUX_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB_HOME") \
  || fail "bin/fm-lab-home.sh could not mint a private tmux socket directory"
export TMUX_TMPDIR="$LAB_TMUX_DIR"
LAB_SOCKET="$TMUX_TMPDIR/tmux-$(id -u)/default"
# tmux creates only the socket file, not the per-user directory under
# TMUX_TMPDIR, so materialize that directory before asking for a session. tmux
# refuses a world- or group-accessible socket directory, so it must be 0700.
mkdir -p "$(dirname "$LAB_SOCKET")" \
  || fail "could not create the lab tmux socket directory $TMUX_TMPDIR/tmux-$(id -u)"
chmod 700 "$(dirname "$LAB_SOCKET")" \
  || fail "could not make the lab tmux socket directory private"

STATE="$LAB_HOME/state"
TASK=wedged-worker
WINDOW_NAME=wedged

# The wedged process: a real, live process whose command name the backend's own
# agent classifier reads as a coding agent, sitting there doing nothing. A bare
# shell would be classified `dead` instead, and a dead endpoint is a different
# contract (reported once, never re-escalated) - not the one the cap bounds.
AGENT_BIN="$TMP_ROOT/wedged-claude"
cat > "$AGENT_BIN" <<'AGENT'
#!/usr/bin/env bash
# A wedged worker: alive, occupying the pane, making no progress. It renders a
# prompt-like line and then waits forever, which is what a hung agent looks like
# from the outside.
printf 'claude> working (elapsed 00:00:01)\n'
sleep 2147483647
AGENT
chmod +x "$AGENT_BIN"

# A real tmux server on the lab-private socket, holding one real window running
# that wedged process. Nothing here is a stub: the pane exists, the process
# exists, and the watcher classifies all of it through its normal path.
tmux -S "$LAB_SOCKET" new-session -d -s "wedged-lab" -n "$WINDOW_NAME" "$AGENT_BIN" >/dev/null 2>&1 \
  || fail "could not start a tmux server on the lab-private socket"
SESSION=$(tmux -S "$LAB_SOCKET" list-sessions -F '#{session_name}' 2>/dev/null | head -1)
[ -n "$SESSION" ] || fail "the lab tmux server started but listed no session"
WINDOW="$SESSION:$WINDOW_NAME"
say "lab tmux server up on $LAB_SOCKET with window $WINDOW"

# Record the window the way firstmate records a spawned crew, so the real
# watcher classifies it through its normal metadata path.
cat > "$STATE/$TASK.meta" <<META
window=$WINDOW
backend=tmux
harness=claude
kind=ship
META
# A non-terminal status line: the crew said it was working and then went quiet.
printf 'working: implementing\n' > "$STATE/$TASK.status"
# Prime the signal scan through the production signature owner so it does not
# pre-empt the stale path on the first cycle: without this the first cycle
# exits on a status-signal wake and the pane never reaches the wedge timer.
FM_HOME="$LAB_HOME" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
  _ "$ROOT/bin/fm-wake-lib.sh" "$LAB_HOME" "$TASK.status"

key=$(printf '%s' "$WINDOW" | tr -c 'A-Za-z0-9' '_')
say "wedged worker recorded as $TASK (key=$key); its pane holds a live process that has made no progress"

# Arm the busy record the production path reads, so the pane reads as an agent
# mid-turn that never finished. This is the real record format (fm-busy-lib.sh
# owns it), written by hand here because a live guard must not spend model
# tokens opening a real agent turn it would then have to complete. With
# FM_BUSY_TURN_MAX_SECS=1 the pane crosses the completed-turn bound at once and
# is routed through the very wedge timer the cap bounds.
printf 'g1\n' > "$STATE/$TASK.busy-gen"
printf 'v1 gen=g1 seq=1 state=busy source=fm-spawn event=turn_start ts=%s\n' "$(date +%s)" \
  > "$STATE/$TASK.busy-state"
# Age the recorded turn so the completed-turn bound has crossed.
touch -d '5 seconds ago' "$STATE/$TASK.meta" 2>/dev/null \
  || perl -e 'utime(time()-5, time()-5, $ARGV[0])' "$STATE/$TASK.meta"

# watcher_cycle <label>: one real watcher cycle against the lab home, run with
# the cap armed and the tmux socket pointed at the lab. Records its exit status
# and the reason line it printed, then drains and acknowledges what it queued.
cycle=0
CYCLE_WOKE=0
watcher_cycle() {
  local label=$1 out rc
  cycle=$((cycle + 1))
  out="$TMP_ROOT/cycle-$cycle.out"
  CYCLE_WOKE=0
  FM_HOME="$LAB_HOME" TMUX_TMPDIR="$LAB_TMUX_DIR" \
    FM_WEDGE_MAX_ESCALATIONS="$MAX" \
    FM_CAP_HORIZON_SECS="$HORIZON_SECS" \
    FM_STALE_ESCALATE_SECS="$STALE_SECS" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_BUSY_TURN_MAX_SECS=1 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  local pid=$!
  # Bound the cycle: a wedged pane produces no wake on a silenced poll, so wait
  # for the watcher heartbeat to prove it completed a poll, then bound the rest.
  # Both bounds are tight because a real lab watcher spends tens of seconds on
  # startup alone, and every second here is a second of the horizon the silence
  # probes must fit inside.
  local beat="$STATE/.last-watcher-beat" i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ -s "$beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt $(( CYCLE_BOUND * 10 )) ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rc=alive
  else
    set +e
    wait "$pid"
    rc=$?
    set -e
  fi
  rm -f "$beat"
  local reason
  reason=$(head -1 "$out" 2>/dev/null)
  # A cycle that printed a reason line published a wake; a cycle that printed
  # none stayed inside the poll loop. Record which, because "the cap holds the
  # pane quiet" is exactly the claim that must be read off the real cycle.
  case "$reason" in
    '') CYCLE_WOKE=0 ;;
    *) CYCLE_WOKE=1 ;;
  esac
  say "$label -> exit=$rc woke=$CYCLE_WOKE reason=${reason:-none}"
  # Acknowledge so the next cycle starts from an empty queue and its exit
  # status reflects the pane, not a leftover wake.
  FM_HOME="$LAB_HOME" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
  cat "$out" >> "$TRANSCRIPT"
}

# --- Part 1: the cap engages on a genuinely wedged worker -------------------
say "part 1: drive the wedged worker past the cap"
watcher_cycle "cycle 1 (first sight: absorbed)"
watcher_cycle "cycle 2 (escalation 1)"
watcher_cycle "cycle 3 (escalation 2: cap threshold)"

terminal_fired=0
for f in "$TMP_ROOT"/cycle-*.out; do
  grep -q 'PERMANENTLY-WEDGED' "$f" 2>/dev/null && terminal_fired=$((terminal_fired + 1))
done
say "cycles that printed PERMANENTLY-WEDGED: $terminal_fired (cap bound is $MAX)"
[ "$terminal_fired" -ge 1 ] \
  || fail "the cap never engaged on a genuinely wedged worker; no cycle printed PERMANENTLY-WEDGED"

# Both markers must be on disk: the per-hash one and the window-scoped one.
markers=$(find "$STATE" -maxdepth 1 -name '.wedge-permanent-*' | wc -l | tr -d ' ')
say "cap markers on disk: $markers"
[ "$markers" -ge 2 ] \
  || fail "the cap engaged but did not write both the per-hash and window-scoped markers"

# While the markers stand, further polls on the same wedged pane must stay
# silent. This is the property the whole cap exists for.
say "part 1b: the cap must silence the still-wedged pane"
silence_start=$(date +%s)
silenced=0
i=0
while [ "$i" -lt 2 ]; do
  i=$((i + 1))
  watcher_cycle "silence probe $i"
  [ "$CYCLE_WOKE" -eq 0 ] || fail "a poll re-escalated the still-wedged pane while the cap markers stood (probe $i)"
  silenced=$((silenced + 1))
done
silence_elapsed=$(( $(date +%s) - silence_start ))
say "post-cap polls that produced no further wake: $silenced (over ${silence_elapsed}s, inside the ${HORIZON_SECS}s horizon)"
[ "$silenced" -ge 2 ] || fail "could not confirm the cap holds the still-wedged pane quiet"
# The silence only proves anything if the probes ran INSIDE the horizon.
[ "$silence_elapsed" -lt "$HORIZON_SECS" ] \
  || fail "the silence probes ran ${silence_elapsed}s, past the ${HORIZON_SECS}s horizon, so they proved nothing about the cap"

# --- Part 2: the cap releases itself after the horizon ----------------------
say "part 2: wait out FM_CAP_HORIZON_SECS and confirm the cap releases itself"
remaining=$(( HORIZON_SECS - silence_elapsed + 2 ))
say "sleeping ${remaining}s so the ${HORIZON_SECS}s cap horizon elapses with no operator action"
sleep "$remaining"

# A wedge can only re-escalate once its counter has re-accumulated, so drive
# the same cycles again and require a real wake on a pane nobody touched.
watcher_cycle "post-horizon cycle 1"
watcher_cycle "post-horizon cycle 2"
[ "$CYCLE_WOKE" -eq 1 ] \
  || fail "after the cap horizon elapsed the pane stayed silent; the cap never released itself"

say "the pane is audible again with no operator action and both markers untouched"
markers_after=$(find "$STATE" -maxdepth 1 -name '.wedge-permanent-*' | wc -l | tr -d ' ')
say "cap markers still on disk after the horizon (stale, not yet rewritten): $markers_after"

say "cap engaged once at the bound, held the wedged pane quiet for $silenced polls inside the horizon, and released itself on the horizon with no operator action"
say "wedge-cap live run complete"
pass "the cap engaged on a real wedged worker and released itself after FM_CAP_HORIZON_SECS"

note "transcript: $TRANSCRIPT"
cleanup
trap - EXIT
exit 0