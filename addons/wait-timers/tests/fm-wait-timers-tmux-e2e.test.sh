#!/usr/bin/env bash
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMUX_BIN=$(command -v tmux) || exit 1
command -v tasks-axi >/dev/null || exit 1
world=$(mktemp -d "$ROOT/.fm-wait-e2e.XXXXXX")
sock="fm-wait-e2e-$$"
watch_pid=''
cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL: real tmux wait journey (exit %s)\n' "$rc"
    for file in out err events drain ack hold-identity state/.waiting-timers/held-lane parent/state/lead.status; do
      [ ! -f "$world/$file" ] || { printf '\n%s:\n' "$file"; cat "$world/$file"; }
    done
  fi
  [ -z "$watch_pid" ] || kill "$watch_pid" 2>/dev/null || :
  [ -z "$watch_pid" ] || wait "$watch_pid" 2>/dev/null || :
  "$TMUX_BIN" -L "$sock" kill-server 2>/dev/null || :
  rm -rf "$world"
}
trap cleanup EXIT
mkdir -p "$world"/{state,data,config,home,tmp,fakebin,parent/state}
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$TMUX_BIN" "$sock" > "$world/fakebin/tmux"
chmod +x "$world/fakebin/tmux"
export HOME="$world/home" XDG_CONFIG_HOME="$world/home/config" TMPDIR="$world/tmp"
export PATH="$world/fakebin:$PATH" FM_HOME="$world" FM_STATE_OVERRIDE="$world/state" FM_DATA_OVERRIDE="$world/data" FM_CONFIG_OVERRIDE="$world/config"
export FM_ROOT_OVERRIDE="$world" FM_TMUX_SESSION=firstmate FM_SESSION=firstmate
printf 'tmux\n' > "$world/config/backend"
printf 'lead\n' > "$world/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$world/parent" > "$world/.fm-secondmate-parent"
cp "$ROOT/.tasks.toml" "$world/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$world/data/backlog.md"
(cd "$world" && tasks-axi add held-lane 'deliberately paused lane' --file data/backlog.md)
tmux new-session -d -s firstmate -n fm-held-lane 'sleep 300'
printf 'window=firstmate:fm-held-lane\nkind=ship\nharness=pi\nbackend=tmux\nworktree=%s\n' "$world" > "$world/state/held-lane.meta"
cycle() {
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_HOME_SUMMARY_INTERVAL=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_WAIT_ALERT_SECS=2 FM_WAIT_ESCALATE_SECS=4 \
    bash "$ROOT/bin/fm-watch.sh" > "$world/out" 2> "$world/err" &
  watch_pid=$!
  for _unused in 1 2 3 4 5 6 7 8; do
    kill -0 "$watch_pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$watch_pid" 2>/dev/null; then
    kill "$watch_pid"
    wait "$watch_pid" || :
  else
    wait "$watch_pid" || { cat "$world/err"; exit 1; }
  fi
  watch_pid=''
  cat "$world/out" >> "$world/events"
  bash "$ROOT/bin/fm-wake-drain.sh" > "$world/drain" 2> "$world/ack"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$world/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$world/ack")
  [ -z "$seq" ] || bash "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}
printf 'paused: validation until 2099-01-01T00:00Z\n' > "$world/state/held-lane.status"
cycle
[ ! -e "$world/state/.waiting-timers/held-lane" ] || { echo 'future pause admitted'; exit 1; }
! grep -q 'waiting-state' "$world/events" || exit 1
printf 'paused: validation until 2000-01-01T00:00Z\n' >> "$world/state/held-lane.status"
cycle
cycle
# The signal scan runs before the timer tick, so one cycle consumes the
# appended pause line's signal before the episode arms; the arming cycle's
# poll must also leave the owner unalerted even though FM_WAIT_ALERT_SECS=2,
# because a declared pause rechecks at FM_PAUSE_RESURFACE_SECS (default 4 h).
[ -f "$world/state/.waiting-timers/held-lane" ] || { echo 'due pause not armed'; exit 1; }
IFS=$'\t' read -r _sig _since owner _parent _key < "$world/state/.waiting-timers/held-lane"
[ "$owner" = 0 ] || { echo 'pause alerted at the owner-alert threshold'; exit 1; }
IFS=$'\t' read -r sig since _owner _parent key _misses < "$world/state/.waiting-timers/held-lane"
printf '%s\t%s\t0\t0\t%s\t0\n' "$sig" "$((since - 15000))" "$key" > "$world/state/.waiting-timers/held-lane"
cycle
grep -q 'waiting-state held-lane (paused' "$world/events" || exit 1
[ ! -s "$world/parent/state/lead.status" ] || { echo 'pause escalated to Main'; exit 1; }
bash "$ROOT/bin/fm-captain-hold.sh" hold held-lane --reason test
bash "$ROOT/bin/fm-captain-hold.sh" open held-lane --identity > "$world/hold-identity"
[ -s "$world/hold-identity" ] || exit 1
: > "$world/events"
for _round in 1 2 3; do cycle; sleep 2; done
# The expired pause line still reaches the core stale heuristic, which is unchanged
# from the base, so only the timers' own alarms must stay silent for a held lane.
! grep -E 'waiting-state|stopped|possible wedge' "$world/events" || { echo 'held item alarmed'; exit 1; }
[ ! -e "$world/state/.waiting-timers/held-lane" ] || exit 1
! grep -q 'waiting-timer-overdue' "$world/parent/state/lead.status" || exit 1
echo 'PASS: real tmux watcher honours pause deadline, owner-only pause and active captain hold'

# Restart an unheld lane after its observation window has elapsed, but before
# its owner has received a wake. The real watcher must leave a response interval
# before publishing to Main, including for a future-until decision declaration.
tmux new-window -d -t firstmate -n fm-ladder 'sleep 300'
printf 'window=firstmate:fm-ladder\nkind=ship\nharness=pi\nbackend=tmux\nworktree=%s\n' "$world" > "$world/state/ladder.meta"
for verb in blocked needs-decision; do
  : > "$world/events"
  : > "$world/parent/state/lead.status"
  printf '%s [key=dependency]: fixture dependency until 2099-01-01T00:00Z\n' "$verb" > "$world/state/ladder.status"
  # The signal scan precedes the timer tick, so mark the fresh declaration
  # seen or the priming run exits on its signal before recording the episode.
  FM_HOME="$world" FM_STATE_OVERRIDE="$world/state" bash -c '
    # shellcheck disable=SC1090
    . "$1"; fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$world/state" "$world/state/ladder.status"
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_WAIT_ALERT_SECS=300 FM_WAIT_ESCALATE_SECS=900 \
    bash "$ROOT/bin/fm-watch.sh" > "$world/out" 2> "$world/err" &
  watch_pid=$!
  for _unused in $(seq 1 40); do
    [ ! -f "$world/state/.waiting-timers/ladder" ] || break
    kill -0 "$watch_pid" || { cat "$world/err"; exit 1; }
    sleep 0.1
  done
  [ -f "$world/state/.waiting-timers/ladder" ] || { echo 'observation not recorded'; exit 1; }
  kill "$watch_pid"
  wait "$watch_pid" || :
  watch_pid=''
  IFS=$'\t' read -r sig since owner _parent key < "$world/state/.waiting-timers/ladder"
  [ "$owner" = 0 ] || { echo 'priming woke owner'; exit 1; }
  printf '%s\t%s\t0\t0\t%s\n' "$sig" "$((since - 900))" "$key" > "$world/state/.waiting-timers/ladder"
  # The priming run was killed, so the next watcher start surfaces that
  # downtime recovery first and ends its cycle before the wait-timer tick.
  # Drain that recovery in its own cycle, then the tick records the owner wake.
  cycle
  cycle
  grep -q "waiting-state ladder ($verb" "$world/events" || exit 1
  [ ! -s "$world/parent/state/lead.status" ] || { echo 'Main alerted before owner response interval'; exit 1; }
  IFS=$'\t' read -r sig since owner _parent key < "$world/state/.waiting-timers/ladder"
  [ "$owner" -gt 1 ] || { echo 'owner delivery not recorded'; exit 1; }
  # A queued status-change wake may close the next watcher before its poll.
  # Drain that real event, then require the timer on a subsequent bounded run.
  for _unused in 1 2 3; do
    cycle
    [ ! -s "$world/parent/state/lead.status" ] || break
  done
  grep -q 'waiting-timer-overdue: ladder' "$world/parent/state/lead.status" || exit 1
  cycle
  [ "$(grep -c 'waiting-state ladder' "$world/events")" -eq 1 ] || { echo 'duplicate owner wake'; exit 1; }
  [ "$(grep -c '^blocked ' "$world/parent/state/lead.status")" -eq 1 ] || { echo 'duplicate Main escalation'; exit 1; }
  printf 'resolved [key=dependency]: fixture cleared\nworking: resumed\n' >> "$world/state/ladder.status"
  cycle
  cycle
  grep -q 'waiting-timer-cleared: ladder' "$world/parent/state/lead.status" || exit 1
  [ ! -e "$world/state/.waiting-timers/ladder" ] || exit 1
  grep 'waiting-state ladder' "$world/events"
  cat "$world/parent/state/lead.status"
  echo "PASS: real tmux $verb restart preserves owner-first interval, deduplicates and resolves Main report"
done
