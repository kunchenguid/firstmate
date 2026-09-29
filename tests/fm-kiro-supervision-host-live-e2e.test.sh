#!/usr/bin/env bash
# Opt-in credentialed live guard for the Kiro primary's supervision host
# (bin/fm-primary-doorbell.sh "SUPERVISION HOST", bin/fm-supervision-host.sh
# host_session_owns_lock, docs/supervision-host.md).
#
# Proves against the real installed Claude Code engine, in an isolated lab copy
# of this checkout opted into the host: a copied Bash named kiro-cli owns the
# fleet lock inside a private tmux server pane and publishes the Kiro endpoint
# for that pane; with the away-posture record written and no away daemon, the
# doorbell owner starts, runs the supervision host for primary kiro-cli, and a
# wake produced by a real status append is handled by a real headless engine
# turn while the host stays parked, the owner stays alive, and the Kiro pane is
# never rung. No live fleet home, tmux server, or session is touched.
# FM_KIRO_SUPERVISION_HOST_POSTURE=attended runs the same proof with no away
# record: the Kiro pane seeds the dialog mirror as its UserPromptSubmit hook
# would, and a routine status append must be handled on the engine in the
# attended posture that the verified Kiro mirror enables, again with no ring.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_KIRO_SUPERVISION_HOST_LIVE_E2E claude node perl tmux git

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
LAB=$(fm_test_tmproot fm-kiro-supervision-host-live)
LAB=$(cd -P "$LAB" && pwd -P)
FM="$LAB/fm"
SOCK="$LAB/tmux.sock"
HOST_TIMEOUT_POLLS=${FM_SUPERVISION_HOST_LIVE_POLLS:-3000}
POSTURE=${FM_KIRO_SUPERVISION_HOST_POSTURE:-away}
case "$POSTURE" in away|attended) ;; *) fail "FM_KIRO_SUPERVISION_HOST_POSTURE must be away or attended" ;; esac
mkdir -p "$LAB/harness"
cp "$(command -v bash)" "$LAB/harness/kiro-cli"
chmod +x "$LAB/harness/kiro-cli"

ptmux() { tmux -S "$SOCK" -f /dev/null "$@"; }

lab_pids() {  # every process whose environment names this lab
  local f pid
  for f in /proc/[0-9]*/environ; do
    pid=${f#/proc/}
    pid=${pid%/environ}
    [ "$pid" != "$$" ] || continue
    grep -qzF "$LAB" "$f" 2>/dev/null && printf '%s\n' "$pid"
  done
}

stop_lab() {
  local pid
  pid=$(cat "$FM/state/.primary-doorbell.lock/pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  sleep 2
  if [ -f "$FM/state/.supervision-host" ]; then
    pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$FM/state/.supervision-host")
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
    sleep 2
  fi
  pid=$(cat "$FM/state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  ptmux kill-server 2>/dev/null || true
  sleep 1
  for pid in $(lab_pids); do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in $(lab_pids); do kill -KILL "$pid" 2>/dev/null || true; done
}
trap 'stop_lab; fm_test_cleanup' EXIT

# A lab copy of this checkout's current tree (tracked and untracked, never
# ignored), committed on main, so the lab is a genuine primary checkout.
mkdir -p "$FM"
git -C "$ROOT" ls-files -z -co --exclude-standard \
  | (cd "$ROOT" && tar --null -T - -cf -) | (cd "$FM" && tar -xf -)
git -C "$FM" init -q -b main
git -C "$FM" add -A >/dev/null
git -C "$FM" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m lab
mkdir -p "$FM/state" "$FM/config"
printf 'claude\n' > "$FM/config/supervision-host"

unset FM_SUPERVISION_ENGINE_CLAUDE_BIN FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN FM_LEASE_HOLDER_PID
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE PI_CODING_AGENT TMUX TMUX_PANE

wait_until() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# The Kiro primary: owns the lock, publishes its own pane, idles on an empty composer.
cat > "$LAB/kiro-pane.sh" <<'SH'
printf '%s\n' "$$" > "$FM_STATE_OVERRIDE/.lock"
. "$FM_ROOT_OVERRIDE/bin/fm-primary-endpoint-lib.sh"
if fm_primary_endpoint_publish "$FM_STATE_OVERRIDE" "$FM_ROOT_OVERRIDE" "$FM_HOME"; then
  printf 'ok\n' > "$LAB_DIR/publish.rc"
else
  printf 'fail %s\n' "$FM_PRIMARY_ENDPOINT_ERROR" > "$LAB_DIR/publish.rc"
fi
printf '%s\n%s\n' "$TMUX" "$TMUX_PANE" > "$LAB_DIR/pane.env"
if [ "$POSTURE" = attended ]; then
  printf '{"session_id":"sess_kiro_live","hook_event_name":"UserPromptSubmit","cwd":"%s","prompt":"watch the fleet for me"}' "$FM_HOME" \
    | "$FM_ROOT_OVERRIDE/bin/fm-host-mirror.sh" hook kiro-cli
fi
printf 'done\n' > "$LAB_DIR/mirror.rc"
printf '\n› ask a question or describe a task'
while :; do sleep 1; done
SH
ptmux new-session -d -s kiro -x 200 -y 50 \
  "env FM_HOME='$FM' FM_ROOT_OVERRIDE='$FM' FM_STATE_OVERRIDE='$FM/state' LAB_DIR='$LAB' POSTURE='$POSTURE' '$LAB/harness/kiro-cli' '$LAB/kiro-pane.sh'" \
  || fail "the private tmux server did not start"
wait_until 100 test -s "$LAB/publish.rc" || fail "the kiro-cli pane never published"
[ "$(cat "$LAB/publish.rc")" = ok ] || fail "the kiro-cli pane could not publish its endpoint: $(cat "$LAB/publish.rc")"
PANE_TMUX=$(sed -n 1p "$LAB/pane.env")
KIRO_PID=$(cat "$FM/state/.lock")
grep -qx "pid=$KIRO_PID" "$FM/state/.primary-endpoint" || fail "the endpoint does not name the kiro-cli lock pid"
pass "a kiro-cli pane in a private tmux server owns the lab lock and published its endpoint"

wait_until 100 test -s "$LAB/mirror.rc" || fail "the kiro-cli pane never finished its setup"
if [ "$POSTURE" = away ]; then
  FM_HOME="$FM" "$FM/bin/fm-afk-contract.sh" enter --words 'Watch the fleet. Merge nothing and dispatch nothing.' >/dev/null \
    || fail "could not record the lab's away posture"
  [ -e "$FM/state/.afk-contract" ] && [ ! -e "$FM/state/.afk" ] || fail "the away record is not a contract-only record"
else
  grep -q '"tag":"captain"' "$FM/state/.host-mirror.jsonl" 2>/dev/null \
    || fail "the Kiro writer did not seed the dialog mirror for the attended posture"
  [ ! -e "$FM/state/.afk-contract" ] || fail "an attended run must have no away record"
fi
printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$FM/state/demo.meta"

ensure_out=$(env FM_HOME="$FM" FM_ROOT_OVERRIDE="$FM" FM_STATE_OVERRIDE="$FM/state" TMUX="$PANE_TMUX" \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$FM/bin/fm-primary-doorbell.sh" ensure 2>&1)
case "$ensure_out" in
  'doorbell-owner: started pid='*) pass "the doorbell owner started ($ensure_out)" ;;
  *) fail "the doorbell owner did not start: $ensure_out" ;;
esac
OWNER_PID=${ensure_out##*pid=}

watcher_live() {
  local pid
  pid=$(cat "$FM/state/.watch.lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
host_pid() { awk -F '\t' '$1 == "host" { print $2; exit }' "$FM/state/.supervision-host" 2>/dev/null; }
host_live() { local p; p=$(host_pid); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
settled() { grep -qE '	(handled|failed|stand-down|to-main)	' "$FM/state/.supervision-host.log" 2>/dev/null; }
rung() { ptmux capture-pane -p -t kiro 2>/dev/null | grep -q 'Firstmate wake waiting'; }
diagnose() {
  printf -- '--- host log\n%s\n--- queue\n%s\n--- doorbell note\n%s\n--- pane\n%s\n' \
    "$(cat "$FM/state/.supervision-host.log" 2>/dev/null)" "$(cat "$FM/state/.wake-queue" 2>/dev/null)" \
    "$(cat "$FM/state/.primary-doorbell-note" 2>/dev/null)" "$(ptmux capture-pane -p -t kiro 2>/dev/null)"
  local f
  for f in "$FM"/state/.primary-doorbell-arm.* "$FM"/state/.supervision-host-arm.* "$FM/state/.primary-doorbell-failed"; do
    [ -e "$f" ] && printf -- '--- %s\n%s\n' "${f##*/}" "$(cat "$f")"
  done
  ls -la "$FM/state"
}

wait_until 300 host_live || fail "the doorbell owner never started the supervision host"$'\n'"$(diagnose)"
wait_until 300 watcher_live || fail "the host never started a watcher cycle"$'\n'"$(diagnose)"
HOST_PID=$(host_pid)
tr '\0' '\n' < "/proc/$HOST_PID/environ" | grep -qx 'FM_SUPERVISION_HOST_PRIMARY=kiro-cli' \
  || fail "the host does not run for primary kiro-cli"
tr '\0' '\n' < "/proc/$HOST_PID/environ" | grep -qx "FM_SUPERVISION_HOST_SERVED_PID=$KIRO_PID" \
  || fail "the host does not serve the kiro-cli lock pid"
pass "the doorbell owner runs the supervision host for primary kiro-cli serving pid $KIRO_PID"
# The wake lands at once, so the first cycle can close before the host streams
# its status line; the owner must still see readiness and keep this host
# through the engine turn (the host prints that line after an early close).
if [ "$POSTURE" = away ]; then
  printf 'done [at=%s]: the demo cleanup finished; nothing else is needed\n' "$(date +%s)" >> "$FM/state/demo.status"
else
  printf 'working [at=%s]: step one of the demo cleanup; nothing is needed from anyone\n' "$(date +%s)" >> "$FM/state/demo.status"
fi
i=0
while [ "$i" -lt "$HOST_TIMEOUT_POLLS" ]; do
  rung && fail "the Kiro pane was rung during the engine turn ($CLAUDE_VERSION)"$'\n'"$(diagnose)"
  settled && break
  sleep 0.1
  i=$((i + 1))
done
settled || fail "the engine turn never settled ($CLAUDE_VERSION)"$'\n'"$(diagnose)"
grep -q "	handled	turn=[^	]*	posture=$POSTURE	" "$FM/state/.supervision-host.log" \
  || fail "the real engine did not handle the $POSTURE wake ($CLAUDE_VERSION)"$'\n'"$(diagnose)"
pass "a real headless engine turn handled the $POSTURE wake ($CLAUDE_VERSION)"
! grep -qE '	(stand-down|to-main)	' "$FM/state/.supervision-host.log" \
  || fail "the host stood down or went to main"$'\n'"$(diagnose)"
pass "the host neither stood down nor handed the wake to main"
grep -q '"task":"demo"' "$FM/state/branch-outcomes.jsonl" 2>/dev/null \
  || fail "the engine's outcome did not reach the store"$'\n'"$(diagnose)"
! grep -q 'demo.status' "$FM/state/.wake-queue" 2>/dev/null \
  || fail "the engine did not acknowledge its wake"$'\n'"$(diagnose)"
pass "the engine recorded its outcome and the wake queue no longer holds the row"
wait_until 100 watcher_live || fail "the host is not parked on a live successor after handling"$'\n'"$(diagnose)"
if [ "$(host_pid)" != "$HOST_PID" ] || ! host_live; then
  fail "the host did not stay parked after handling"$'\n'"$(diagnose)"
fi
pass "the host stays parked on a live successor watcher"
# Give a late ring a chance to land before judging the pane.
sleep 5
kill -0 "$OWNER_PID" 2>/dev/null || fail "the doorbell owner died"$'\n'"$(diagnose)"
[ "$(cat "$FM/state/.primary-doorbell.lock/pid" 2>/dev/null)" = "$OWNER_PID" ] || fail "the doorbell owner lock moved"
pass "the doorbell owner is still alive"
! rung || fail "the Kiro pane was rung"$'\n'"$(diagnose)"
[ ! -s "$FM/state/.primary-doorbell-note" ] || fail "the owner queued a doorbell note for main"$'\n'"$(diagnose)"
pass "the Kiro pane was never rung"
printf '# turn: %s\n' "$(grep '	handled	' "$FM/state/.supervision-host.log" | head -n 1 | cut -f2-)"

kill -TERM "$OWNER_PID" 2>/dev/null || true
wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null' _ "$OWNER_PID" || fail "the doorbell owner did not stop on TERM"
wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null' _ "$HOST_PID" || fail "a stopped owner left its host running"
stop_lab
[ -z "$(lab_pids)" ] || fail "processes outlived the lab: $(lab_pids | tr '\n' ' ')"
pass "cleanup left no lab process"
