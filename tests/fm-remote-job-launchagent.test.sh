#!/usr/bin/env bash
# Darwin ensure and LaunchAgent concurrency tests through the executable library
# and worker. The launchctl stub models launchd: bootstrap loads the agent and
# starts the worker without waiting for readiness, kickstart -k stops the
# tracked worker before starting a new one, bootout stops the tracked worker,
# and print reports the pid launchd tracks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-launchagent)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REMOTE_ROOT="$TMP_ROOT/remote-root"
ACCOUNT_HOME="$TMP_ROOT/account"
STATE_ROOT="$TMP_ROOT/state"
STUB_BIN="$TMP_ROOT/stub-bin"
LAUNCH_LOG="$TMP_ROOT/launchctl.log"
SWEEP_GATE="$TMP_ROOT/sweep-gate"
mkdir -p "$REMOTE_ROOT/bin" "$ACCOUNT_HOME" "$STUB_BIN"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
chmod +x "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'launchagent fixture'

# The first sequence-claim removal holds the real worker inside its sweep until
# the test releases it, far beyond the probe's freshness bound and wait.
REAL_RMDIR=$(command -v rmdir)
cat > "$STUB_BIN/rmdir" <<'SH'
#!/bin/bash
last=${!#}
case "$last" in
  */.seq-claims/[0-9]*)
    if [ -n "${FM_TEST_SWEEP_GATE:-}" ] && mkdir "$FM_TEST_SWEEP_GATE.once" 2>/dev/null; then
      : > "$FM_TEST_SWEEP_GATE"
      for _ in $(seq 1 1200); do
        [ -f "$FM_TEST_SWEEP_GATE.release" ] && break
        /bin/sleep 0.05
      done
    fi
    ;;
esac
exec "$FM_TEST_REAL_RMDIR" "$@"
SH
# Fault injection keeps the heartbeat process alive but prevents timestamp
# refresh, so ensure must handle a genuinely stale live owner's readiness.
REAL_TOUCH=$(command -v touch)
cat > "$STUB_BIN/touch" <<'SH'
#!/bin/bash
last=${!#}
if [ "$last" = "$FM_TEST_STATE/worker.ready" ] && [ -f "$FM_TEST_STALE_GATE" ]; then
  : > "$FM_TEST_STALE_GATE.observed"
  exit 0
fi
exec "$FM_TEST_REAL_TOUCH" "$@"
SH
# Hold lock-owner publication so probes run against crash leftovers before
# the replacement has recorded ownership or published its code identity.
REAL_MV=$(command -v mv)
cat > "$STUB_BIN/mv" <<'SH'
#!/bin/bash
last=${!#}
if [ "$last" = "$FM_TEST_STATE/worker.lock/pid" ] && [ -f "$FM_TEST_OWNER_GATE" ]; then
  : > "$FM_TEST_OWNER_GATE.observed"
  for _ in $(seq 1 400); do
    [ -f "$FM_TEST_OWNER_GATE.release" ] && break
    /bin/sleep 0.05
  done
  [ -f "$FM_TEST_OWNER_GATE.release" ] || exit 1
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
cat > "$STUB_BIN/launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FM_TEST_LAUNCH_LOG"
tracked_pid() {
  local pid
  pid=$(cat "$FM_TEST_TRACKED" 2>/dev/null) || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}
stop_tracked() {
  local pid
  pid=$(tracked_pid) || { rm -f "$FM_TEST_TRACKED"; return 0; }
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 200); do
    kill -0 "$pid" 2>/dev/null || break
    /bin/sleep 0.05
  done
  rm -f "$FM_TEST_TRACKED"
}
# The tracked process sleeps before exec'ing the worker, so the spawn stays
# unpublished for a moment after launchctl returns, as a slow startup does.
start_worker() {
  set -m
  (
    /bin/sleep "${FM_TEST_SPAWN_DELAY:-1}"
    HOME="$FM_TEST_ACCOUNT" FM_ROOT_OVERRIDE="$FM_TEST_ROOT" \
      FM_REMOTE_JOB_STATE_ROOT="$FM_TEST_STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Darwin \
      exec "$FM_TEST_WORKER"
  ) >> "$FM_TEST_WORKER_LOG" 2>&1 < /dev/null &
  printf '%s\n' "$!" > "$FM_TEST_TRACKED"
  set +m
}
case "${1:-}" in
  print)
    case "${2:-}" in
      gui/*/dev.firstmate.remote-job)
        [ -f "$FM_TEST_LOADED" ] || exit 113
        printf 'path = %s\nprogram = %s\n' "$FM_TEST_PLIST" "$FM_TEST_WORKER"
        if pid=$(tracked_pid); then printf '\tpid = %s\n' "$pid"; fi
        printf 'label = dev.firstmate.remote-job\n'
        ;;
      gui/[0-9]*) exit 0 ;;
      *) exit 113 ;;
    esac
    ;;
  bootout)
    [ -f "$FM_TEST_LOADED" ] || exit 113
    stop_tracked
    if [ "${FM_TEST_ASYNC_BOOTOUT:-0}" -eq 1 ]; then
      : > "$FM_TEST_REMOVING"
      nohup /bin/sh -c 'sleep "$1"; rm -f "$2" "$3"' sh "${FM_TEST_BOOTOUT_DELAY:-1}" "$FM_TEST_LOADED" "$FM_TEST_REMOVING" \
        </dev/null >/dev/null 2>&1 &
    else
      rm -f "$FM_TEST_LOADED"
    fi
    ;;
  bootstrap)
    [ ! -f "$FM_TEST_LOADED" ] && [ ! -f "$FM_TEST_REMOVING" ] || { printf 'Bootstrap failed: 5: Input/output error\n' >&2; exit 5; }
    : > "$FM_TEST_LOADED"
    start_worker
    ;;
  kickstart)
    [ -f "$FM_TEST_LOADED" ] || exit 113
    stop_tracked
    start_worker
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$STUB_BIN/rmdir" "$STUB_BIN/touch" "$STUB_BIN/mv" "$STUB_BIN/launchctl"
export PATH="$STUB_BIN:$PATH"
export FM_TEST_REAL_RMDIR="$REAL_RMDIR" FM_TEST_LAUNCH_LOG="$LAUNCH_LOG"
export FM_TEST_REAL_TOUCH="$REAL_TOUCH" FM_TEST_STALE_GATE="$TMP_ROOT/stale-gate"
export FM_TEST_REAL_MV="$REAL_MV"
export FM_TEST_OWNER_GATE="$TMP_ROOT/owner-gate"
export FM_TEST_ROOT="$REMOTE_ROOT" FM_TEST_ACCOUNT="$ACCOUNT_HOME"
export FM_TEST_WORKER="$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
export FM_TEST_WORKER_LOG="$TMP_ROOT/worker.log" FM_TEST_STATE="$STATE_ROOT"
export FM_TEST_LOADED="$TMP_ROOT/launchagent.loaded" FM_TEST_TRACKED="$TMP_ROOT/launchagent.pid"
export FM_TEST_REMOVING="$TMP_ROOT/launchagent.removing"
export FM_TEST_PLIST="$ACCOUNT_HOME/Library/LaunchAgents/dev.firstmate.remote-job.plist"
export FM_TEST_SWEEP_GATE="$SWEEP_GATE"
export FM_REMOTE_JOB_STATE_ROOT="$STATE_ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Darwin
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

stop_pid() {
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -0 "$pid" 2>/dev/null || return 0
  fm_remote_job_stop_worker_tree "$pid" >/dev/null 2>&1 || true
}

cleanup() {
  : > "$SWEEP_GATE.release" 2>/dev/null || true
  stop_pid "$(cat "$FM_TEST_TRACKED" 2>/dev/null)"
  stop_pid "$(cat "$STATE_ROOT/worker.lock/pid" 2>/dev/null)"
  stop_pid "${ORPHAN_PID:-}"
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

ensure_darwin() (
  fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT_HOME" || {
    printf 'ensure failed: %s\n' "$FM_REMOTE_JOB_ERROR" >&2
    exit 1
  }
)

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

tracked() { cat "$FM_TEST_TRACKED" 2>/dev/null; }
lock_owner() { cat "$STATE_ROOT/worker.lock/pid" 2>/dev/null; }
launch_count() { grep -c "^$1 " "$LAUNCH_LOG" 2>/dev/null || true; }

# --- a crashed predecessor's fresh heartbeat cannot ready its replacement ----

fm_remote_job_prepare_state "$ACCOUNT_HOME" || fail 'could not prepare remote job state'
fm_remote_job_write_launchagent "$REMOTE_ROOT" "$ACCOUNT_HOME" || fail 'could not write the LaunchAgent'
# Persisted crash leftovers are the public worker state contract. The old
# process is gone, but its stale code identity and fresh heartbeat remain.
printf 'stale-code\n' > "$STATE_ROOT/worker.identity"
printf '99999999\n' > "$STATE_ROOT/worker.ready"
chmod 600 "$STATE_ROOT/worker.identity" "$STATE_ROOT/worker.ready"
: > "$FM_TEST_OWNER_GATE"
launchctl bootstrap "gui/$(id -u)" "$FM_TEST_PLIST" || fail 'could not start the replacement'
for _ in $(seq 1 200); do
  [ -f "$FM_TEST_OWNER_GATE.observed" ] && break
  /bin/sleep 0.05
done
[ -f "$FM_TEST_OWNER_GATE.observed" ] || fail 'replacement did not reach lock-owner publication'
fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  && fail 'replacement published its current identity before ownership'
[ ! -e "$STATE_ROOT/worker.ready" ] || fail 'replacement retained the predecessor heartbeat'
fm_remote_job_probe "$ACCOUNT_HOME" && fail 'replacement inherited predecessor readiness before recording ownership'
fm_remote_job_wait_for_probe "$REMOTE_ROOT" "$ACCOUNT_HOME" > "$TMP_ROOT/wait-owner.out" 2>&1 &
PROBE_WAITER=$!
/bin/sleep 1
kill -0 "$PROBE_WAITER" 2>/dev/null || fail 'startup wait accepted the predecessor heartbeat'
: > "$FM_TEST_OWNER_GATE.release"
wait "$PROBE_WAITER" || fail 'replacement did not become ready after ownership publication'
[ "$(fm_remote_job_read_single_line "$STATE_ROOT/worker.ready" 64)" = "$(lock_owner)" ] \
  || fail 'replacement readiness did not identify its recorded lock owner'
rm -f "$FM_TEST_OWNER_GATE" "$FM_TEST_OWNER_GATE.observed" "$FM_TEST_OWNER_GATE.release"
launchctl bootout "gui/$(id -u)/dev.firstmate.remote-job" || fail 'could not stop the replacement'
pass 'a stale-code crash heartbeat cannot count as replacement readiness'

# --- a slow sequence-claim sweep must not trigger a LaunchAgent reload -------

rm -f "$STATE_ROOT/.seq-claims-reaped"
mkdir -p "$STATE_ROOT/.seq-claims/1"
touch -t 200001010000 "$STATE_ROOT/.seq-claims/1"
launchctl bootstrap "gui/$(id -u)" "$FM_TEST_PLIST" || fail 'the stub launchd did not load the agent'
SWEEP_PID=$(tracked)
for _ in $(seq 1 200); do
  [ -f "$SWEEP_GATE" ] && break
  /bin/sleep 0.05
done
[ -f "$SWEEP_GATE" ] || { cat "$FM_TEST_WORKER_LOG"; fail 'the real worker did not enter its sequence-claim sweep'; }
[ "$(lock_owner)" = "$SWEEP_PID" ] || fail 'the launchd-tracked worker does not own the worker lock'
# Remove readiness under a live worker blocked in its sweep: only the
# independent heartbeat can restore it before the sweep is released.
rm -f "$STATE_ROOT/worker.ready"
for _ in $(seq 1 100); do
  [ -f "$STATE_ROOT/worker.ready" ] && break
  /bin/sleep 0.05
done
[ -f "$STATE_ROOT/worker.ready" ] || fail 'the live worker heartbeat did not recreate missing readiness during its sweep'
[ "$(fm_remote_job_read_single_line "$STATE_ROOT/worker.ready" 64)" = "$SWEEP_PID" ] \
  || fail 'recreated readiness did not identify the serving worker'
[ "$(file_mode "$STATE_ROOT/worker.ready")" = 600 ] \
  || fail 'recreated readiness did not retain its private mode'
fm_remote_job_probe "$ACCOUNT_HOME" || fail 'recreated readiness did not restore probe availability'
pass 'the live worker recreates missing readiness independently of a blocked sweep'
# Outlast the probe's 10-second freshness bound while the main loop is blocked.
/bin/sleep 11
: > "$LAUNCH_LOG"
ensure_darwin > "$TMP_ROOT/ensure-sweep.out" 2>&1 \
  || { cat "$TMP_ROOT/ensure-sweep.out"; fail 'ensure failed while the worker was inside a slow sweep'; }
[ ! -f "$SWEEP_GATE.release" ] || fail 'the sweep ended before ensure observed it'
[ "$(launch_count bootout)" -eq 0 ] || fail 'ensure booted out a healthy worker during its slow sweep'
kill -0 "$SWEEP_PID" 2>/dev/null || fail 'the sweeping worker was killed'
[ "$(tracked)" = "$SWEEP_PID" ] && [ "$(lock_owner)" = "$SWEEP_PID" ] \
  || fail 'the sweeping worker lost launchd tracking or worker ownership'
: > "$SWEEP_GATE.release"
pass 'a slow sequence-claim sweep keeps readiness fresh and cannot trigger a LaunchAgent bootout'

# --- concurrent callers cannot bootout-war a fresh asynchronous spawn ----------

launchctl bootout "gui/$(id -u)/dev.firstmate.remote-job" || fail 'the stub launchd did not unload the agent'
! kill -0 "$SWEEP_PID" 2>/dev/null || fail 'bootout did not stop the tracked worker'
: > "$LAUNCH_LOG"
CALLERS=()
for caller in 1 2 3; do
  ensure_darwin > "$TMP_ROOT/ensure-$caller.out" 2>&1 &
  CALLERS+=("$!")
done
for caller_pid in "${CALLERS[@]}"; do
  wait "$caller_pid" || { cat "$TMP_ROOT"/ensure-*.out; fail 'a concurrent Darwin ensure failed'; }
done
[ "$(launch_count bootout)" -eq 1 ] || { cat "$LAUNCH_LOG"; fail 'concurrent callers ran more than one LaunchAgent bootout'; }
[ "$(launch_count bootstrap)" -eq 1 ] || { cat "$LAUNCH_LOG"; fail 'concurrent callers bootstrapped the agent more than once'; }
[ "$(launch_count kickstart)" -eq 1 ] || { cat "$LAUNCH_LOG"; fail 'concurrent callers kickstarted more than one worker'; }
FRESH_PID=$(tracked)
kill -0 "$FRESH_PID" 2>/dev/null || fail 'no tracked worker survived the concurrent ensures'
[ "$(lock_owner)" = "$FRESH_PID" ] || fail 'the surviving worker lock owner is not the launchd-tracked worker'
pass 'concurrent Darwin ensures serialize one reload and adopt its fresh worker'

# --- stale readiness diagnoses a verified tracked owner without reloading ------

fm_remote_job_launchagent_owner_current "$REMOTE_ROOT" "$ACCOUNT_HOME" "$(id -u)" \
  || fail 'the stale-readiness fixture is not a verified launchd-tracked current owner'
: > "$FM_TEST_STALE_GATE"
for _ in $(seq 1 100); do
  [ -f "$FM_TEST_STALE_GATE.observed" ] && break
  /bin/sleep 0.05
done
[ -f "$FM_TEST_STALE_GATE.observed" ] || fail 'heartbeat refresh fault injection was not reached'
"$REAL_TOUCH" -t 200001010000 "$STATE_ROOT/worker.ready"
fm_remote_job_probe "$ACCOUNT_HOME" && fail 'the fault-injected readiness was not stale'
: > "$LAUNCH_LOG"
if ensure_darwin > "$TMP_ROOT/ensure-stale.out" 2>&1; then
  fail 'ensure accepted stale readiness for a live tracked worker'
fi
grep -Fx 'remote-job: ready heartbeat stale while verified worker lock owner is alive' "$TMP_ROOT/ensure-stale.out" >/dev/null \
  || { cat "$TMP_ROOT/ensure-stale.out"; fail 'ensure omitted the named stale-ready diagnostic'; }
for action in bootout bootstrap kickstart; do
  [ "$(launch_count "$action")" -eq 0 ] || fail "stale readiness triggered launchctl $action"
done
kill -0 "$FRESH_PID" 2>/dev/null || fail 'stale readiness killed the verified live worker'
[ "$(tracked)" = "$FRESH_PID" ] && [ "$(lock_owner)" = "$FRESH_PID" ] \
  || fail 'stale readiness changed launchd tracking or lock ownership'
rm -f "$FM_TEST_STALE_GATE"
fm_remote_job_wait_for_probe "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail 'the same worker did not recover readiness after refresh resumed'
pass 'stale readiness logs the named condition without reloading a verified launchd-tracked live owner'

# --- a verified owner launchd no longer tracks is replaced identity-safely -----

# launchd lost the worker while it kept the lock, then code changed under it.
ORPHAN_PID=$FRESH_PID
rm -f "$FM_TEST_TRACKED"
printf '\n# updated fixture code\n' >> "$REMOTE_ROOT/bin/fm-remote-job-worker.sh"
git -C "$REMOTE_ROOT" commit -qam 'updated worker identity'
: > "$LAUNCH_LOG"
ensure_darwin > "$TMP_ROOT/ensure-orphan.out" 2>&1 \
  || { cat "$TMP_ROOT/ensure-orphan.out"; fail 'Darwin did not recover the untracked stale-code owner'; }
! kill -0 "$ORPHAN_PID" 2>/dev/null || fail 'the untracked stale-code owner remained alive'
REPLACEMENT_PID=$(tracked)
[ -n "$REPLACEMENT_PID" ] && [ "$REPLACEMENT_PID" != "$ORPHAN_PID" ] && [ "$(lock_owner)" = "$REPLACEMENT_PID" ] \
  || fail 'the replacement worker is not the launchd-tracked lock owner'
fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || fail 'the replacement worker identity does not match current code'
pass 'Darwin stops an untracked stale-code owner and starts the current worker through launchd'

# The agent stays loaded but launchd tracks no process, as when its own spawn
# exited because the orphan still held the worker lock. Current code alone must
# not let the orphan keep the service.
ORPHAN_PID=$REPLACEMENT_PID
rm -f "$FM_TEST_TRACKED"
: > "$LAUNCH_LOG"
ensure_darwin > "$TMP_ROOT/ensure-loaded-orphan.out" 2>&1 \
  || { cat "$TMP_ROOT/ensure-loaded-orphan.out"; fail 'Darwin did not recover the untracked current-code owner'; }
! kill -0 "$ORPHAN_PID" 2>/dev/null || fail 'the untracked current-code owner remained alive'
REPLACEMENT_PID=$(tracked)
[ -n "$REPLACEMENT_PID" ] && [ "$(lock_owner)" = "$REPLACEMENT_PID" ] \
  || fail 'the loaded agent did not regain a launchd-tracked lock owner'
pass 'Darwin replaces a current-code owner that the loaded agent does not track'

# A repairing caller killed while holding the repair lock leaves its record.
plant_dead_repair_lock() {
  local holder name
  holder=$(bash -c 'printf "%s\n" "$$"')
  name=launchagent.repair.owner.$holder.1
  mkdir "$STATE_ROOT/$name" || return 1
  printf '%s\n' "$holder" > "$STATE_ROOT/$name/pid"
  printf 'gone\n' > "$STATE_ROOT/$name/start"
  printf 'gone\n' > "$STATE_ROOT/$name/command"
  ln -s "$name" "$STATE_ROOT/launchagent.repair"
}

# --- a repairing caller that dies after kickstart cannot doom its spawn ------

# Caller A reloads the agent and dies before its asynchronous spawn publishes
# the worker lock or identity. Caller B must let that spawn finish starting.
launchctl bootout "gui/$(id -u)/dev.firstmate.remote-job" || fail 'the stub launchd did not unload the agent'
launchctl bootstrap "gui/$(id -u)" "$FM_TEST_PLIST" || fail 'the stub launchd did not load the agent'
FM_TEST_SPAWN_DELAY=3 launchctl kickstart -k "gui/$(id -u)/dev.firstmate.remote-job" \
  || fail 'the stub launchd did not kickstart the agent'
plant_dead_repair_lock || fail 'could not plant the dead caller repair lock'
SPAWN_PID=$(tracked)
[ -z "$(lock_owner)" ] && [ ! -e "$STATE_ROOT/worker.identity" ] \
  || fail 'the spawn published ownership before the surviving caller ran'
: > "$LAUNCH_LOG"
ensure_darwin > "$TMP_ROOT/ensure-dead-caller.out" 2>&1 \
  || { cat "$TMP_ROOT/ensure-dead-caller.out"; fail 'ensure failed after the repairing caller died'; }
[ "$(launch_count bootout)" -eq 0 ] || { cat "$LAUNCH_LOG"; fail 'ensure booted out the dead caller fresh spawn'; }
[ "$(tracked)" = "$SPAWN_PID" ] && [ "$(lock_owner)" = "$SPAWN_PID" ] \
  || fail 'the dead caller spawn did not become the launchd-tracked lock owner'
[ ! -e "$STATE_ROOT/launchagent.repair" ] && [ ! -L "$STATE_ROOT/launchagent.repair" ] \
  || fail 'the reclaimed repair lock was not released'
pass 'a fresh spawn survives when the caller that started it dies before publication'

# --- a dead repair-lock holder is reclaimed by exactly one caller ------------

# Two later callers must not both reclaim a dead holder's lock.
plant_dead_repair_lock || fail 'could not plant the dead holder repair lock'
HOLD_LOG="$TMP_ROOT/hold.log"
: > "$HOLD_LOG"
hold_lock() (
  fm_remote_job_prepare_state "$ACCOUNT_HOME" || exit 1
  fm_remote_job_reload_lock_acquire "$STATE_ROOT/launchagent.repair" || exit 1
  printf 'enter %s\n' "$1" >> "$HOLD_LOG"
  /bin/sleep 1
  printf 'leave %s\n' "$1" >> "$HOLD_LOG"
  fm_remote_job_reload_lock_release "$STATE_ROOT/launchagent.repair"
)
hold_lock a & HOLD_A=$!
hold_lock b & HOLD_B=$!
wait "$HOLD_A" || fail 'the first reclaiming caller did not acquire the repair lock'
wait "$HOLD_B" || fail 'the second reclaiming caller did not acquire the repair lock'
[ "$(sed -n 1p "$HOLD_LOG" | cut -d' ' -f1)$(sed -n 2p "$HOLD_LOG" | cut -d' ' -f1)" = enterleave ] \
  && [ "$(sed -n 3p "$HOLD_LOG" | cut -d' ' -f1)$(sed -n 4p "$HOLD_LOG" | cut -d' ' -f1)" = enterleave ] \
  || { cat "$HOLD_LOG"; fail 'two callers held the reclaimed repair lock at once'; }
[ ! -e "$STATE_ROOT/launchagent.repair" ] && [ ! -L "$STATE_ROOT/launchagent.repair" ] \
  || fail 'the repair lock was not released'
for leftover in "$STATE_ROOT"/launchagent.repair.*; do
  [ -e "$leftover" ] || [ -L "$leftover" ] || continue
  fail "repair lock records were left behind: $leftover"
done
pass 'a dead repair-lock holder is reclaimed by one caller at a time'

# --- wait for Darwin bootout cleanup before bootstrapping the same label -----

: > "$LAUNCH_LOG"
FM_TEST_ASYNC_BOOTOUT=1 FM_TEST_BOOTOUT_DELAY=1
export FM_TEST_ASYNC_BOOTOUT FM_TEST_BOOTOUT_DELAY
OLD_PID=$(tracked)
START=$SECONDS
fm_remote_job_reload_launchagent "$ACCOUNT_HOME" "$(id -u)" \
  || fail "Darwin reload failed while bootout cleanup was pending: ${FM_REMOTE_JOB_ERROR:-no diagnostic}"
ELAPSED=$((SECONDS - START))
NEW_PID=$(tracked)
[ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ] \
  || fail 'the async bootout reload did not replace the tracked worker'
[ "$(launch_count bootout)" -eq 1 ] && [ "$(launch_count bootstrap)" -eq 1 ] && [ "$(launch_count kickstart)" -eq 1 ] \
  || { cat "$LAUNCH_LOG"; fail 'the async bootout reload did not perform exactly one bootout/bootstrap/kickstart'; }
fm_remote_job_wait_for_probe "$REMOTE_ROOT" "$ACCOUNT_HOME" \
  || { cat "$WORKER_LOG"; fail 'the replacement worker did not become ready after async bootout cleanup'; }
[ "$(tracked)" = "$NEW_PID" ] && [ "$(lock_owner)" = "$NEW_PID" ] \
  || fail 'launchd tracking and worker ownership diverged after async bootout cleanup'
[ ! -e "$FM_TEST_REMOVING" ] || fail 'launchd removal remained pending after successful bootstrap'
pass "Darwin reload waits for asynchronous bootout cleanup before bootstrap (${ELAPSED}s)"

printf 'ALL TESTS PASSED\n'
