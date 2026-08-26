#!/usr/bin/env bash
# tests/fm-watch-beacon.test.sh - the watcher liveness beacon
# (state/.last-watcher-beat) must reflect truth while backend reads misbehave.
# Regression for the 2026-08-22 herdr incident: a wedged herdr server made
# every unbounded control-socket read block for minutes, one supervision cycle
# stretched past FM_GUARD_GRACE while the loop was still processing wakes, and
# every guard read the live watcher as dead off the stale top-of-loop beat.
# These cases drive a real fm-watch.sh subprocess against a herdr-backed task
# window whose fake backend fails or hangs, and assert the beacon keeps
# advancing and the watcher neither exits nor wakes:
#   - a backend whose every call fails (write error / dead server) leaves the
#     cycle beating and alive;
#   - a backend whose every call HANGS is cut off by the herdr RPC bound
#     (FM_BACKEND_HERDR_CLI_TIMEOUT) so the beacon still advances promptly;
#   - a beacon the watcher cannot write ends the cycle instead of leaving a
#     live lock-holder whose beat can never resume.
# The two supervision loops whose wall time scales with the fleet live in
# shared libraries with non-watcher callers, so they reach the beacon through
# FM_LIVENESS_BEAT_HOOK rather than calling watcher_beat directly. The final
# cases pin that seam from both sides: the hook fires once per pending-reply
# record and once per triaged signal task, and an unset hook stays a no-op for
# every consumer that owns no beacon.
# Both watchers run with SIGPIPE ignored, the disposition a Node-based arm
# chain hands down and the environment the incident's broken-pipe noise came
# from. The herdr-side units for the RPC bound, the pipe-noise-free capability
# probe, and the bounded event-wait reads live in tests/fm-backend-herdr.test.sh;
# the always-on triage behavior lives in tests/fm-watch-triage.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-beacon-tests)

# Portable mtime in epoch seconds (see fm-watch.sh on why never `stat -f || stat -c`).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Launch a real watcher against <state> with SIGPIPE ignored (the arm-chain
# disposition) and the herdr fake first on PATH. Tight poll, no check or
# heartbeat cadence, event push disabled so the poll loop is what runs.
# Stdout (the wake channel) goes to <out>, stderr to <out>.err, so a case can
# assert on the watcher's own diagnostics instead of leaking them into the
# suite's output.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  # shellcheck disable=SC2016 # $1 belongs to the inner bash -c process.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_BACKEND_HERDR_EVENTS_FORCE=0 \
    env "$@" bash -c 'trap "" PIPE; exec "$1"' _ "$WATCH" > "$out" 2> "$out.err" &
}

# Wait until the beacon has been written once and then ADVANCED at least once
# more, proving a completed cycle boundary; 1 if the watcher exited first or
# the budget ran out.
wait_beat_advance() {  # <state> <pid> [limit-ticks]
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

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# One herdr-backed ship task window in <state>, so the watcher's per-window
# stale scan routes its capture and busy reads through the fake herdr.
seed_herdr_window() {  # <state>
  local state=$1
  fm_write_meta "$state/tsk.meta" "window=sess:wG:pQ" "backend=herdr" "kind=ship"
}

# One open pending-reply record for <task> under <state>, so the watcher's
# per-cycle fm_pending_reply_tick has a record to iterate. That loop lives in a
# shared library and reaches the beacon only through FM_LIVENESS_BEAT_HOOK, so
# a record here is what proves the watcher actually wires the hook up.
seed_pending_reply() {  # <state> <task>
  local state=$1 task=$2
  (
    set +u
    # shellcheck source=bin/fm-pending-reply-lib.sh
    . "$ROOT/bin/fm-pending-reply-lib.sh"
    fm_pending_reply_create "$(dirname "$state")" "$state" "$task" "please report back"
  ) >/dev/null
}

test_beacon_advances_when_every_backend_call_fails() {
  local dir state fakebin out pid
  dir=$(make_case beacon-backend-fails); state="$dir/state"; fakebin="$dir/fakebin"
  seed_herdr_window "$state"
  # Every herdr invocation fails after emitting a partial write - the dead- or
  # wedged-server shape whose write errors must stay non-fatal to the cycle.
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf 'herdr: connection reset' >&2
exit 1
SH
  chmod +x "$fakebin/herdr"
  out="$dir/out"
  watch_bg "$state" "$fakebin" "$out"
  # shellcheck disable=SC2031 # watch_bg backgrounds in this shell, so $! is ours.
  pid=$!
  wait_beat_advance "$state" "$pid" \
    || { reap "$pid"; fail "the beacon must keep advancing while every backend call fails"; }
  wait_beat_advance "$state" "$pid" \
    || { reap "$pid"; fail "the beacon must keep advancing across further cycles of backend failure"; }
  [ -s "$out" ] && { reap "$pid"; fail "a failing backend alone must not produce a wake, got: $(cat "$out")"; }
  reap "$pid"
  pass "beacon keeps advancing and the watcher stays quiet while every backend call fails"
}

test_beacon_advances_when_backend_hangs() {
  local dir state fakebin out pid start elapsed
  dir=$(make_case beacon-backend-hangs); state="$dir/state"; fakebin="$dir/fakebin"
  seed_herdr_window "$state"
  # An open pending-reply record puts the shared-library tick in the cycle too,
  # so this case covers the hook path as well as the watcher's own beats.
  seed_pending_reply "$state" tsk
  # Every herdr invocation hangs far past the guard grace - the wedged
  # post-machine-sleep server. The RPC bound must cut each call so the cycle
  # keeps beating; without it this case burns 60s per call and the advance
  # budget below fails.
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
exec sleep 60
SH
  chmod +x "$fakebin/herdr"
  out="$dir/out"
  start=$(date +%s)
  watch_bg "$state" "$fakebin" "$out" FM_BACKEND_HERDR_CLI_TIMEOUT=1
  # shellcheck disable=SC2031 # watch_bg backgrounds in this shell, so $! is ours.
  pid=$!
  wait_beat_advance "$state" "$pid" \
    || { reap "$pid"; fail "the beacon must keep advancing while backend calls hang"; }
  wait_beat_advance "$state" "$pid" \
    || { reap "$pid"; fail "the beacon must keep advancing across further cycles of hanging backend calls"; }
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 30 ] \
    || { reap "$pid"; fail "two beacon advances against a hanging backend took ${elapsed}s; the RPC bound is not cutting the calls"; }
  [ -s "$out" ] && { reap "$pid"; fail "a hanging backend alone must not produce a wake, got: $(cat "$out")"; }
  reap "$pid"
  pass "beacon keeps advancing within ${elapsed}s while every backend call hangs (RPC bound cuts each call)"
}

# The other half of "the beacon reflects truth": when the watcher CANNOT write
# the beacon it must not keep the singleton lock while its beat is frozen -
# that is the zombie lock-holder one machine-sleep episode left behind, a live
# process every guard reads as dead and no arm chain is allowed to replace. The
# cycle ends instead, so the lock's recorded holder is a dead pid the arm chain
# may evict.
test_unwritable_beacon_ends_the_cycle() {
  local dir state fakebin out pid rc waited lockpid
  dir=$(make_case beacon-unwritable); state="$dir/state"; fakebin="$dir/fakebin"
  seed_herdr_window "$state"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/herdr"
  out="$dir/out"
  watch_bg "$state" "$fakebin" "$out"
  # shellcheck disable=SC2031 # watch_bg backgrounds in this shell, so $! is ours.
  pid=$!
  wait_beat_advance "$state" "$pid" \
    || { reap "$pid"; fail "the watcher must be beating normally before the beacon is taken away"; }
  # Take the beacon away under the live watcher: a directory at that path is
  # unwritable as a file no matter who owns it, so the next cycle-top write
  # fails the way a full or read-only state directory fails it.
  rm -f "$state/.last-watcher-beat"
  mkdir "$state/.last-watcher-beat" \
    || { reap "$pid"; fail "could not make the beacon path unwritable"; }
  waited=0
  while [ "$waited" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    reap "$pid"
    fail "an unwritable beacon must end the cycle; the watcher is still holding the lock with a frozen beat"
  fi
  wait "$pid" 2>/dev/null
  rc=$?
  [ "$rc" -ne 0 ] \
    || fail "the watcher must exit non-zero so the arm chain replaces it, got $rc"
  grep -q 'liveness beacon unwritable' "$out.err" \
    || fail "the watcher must say why it ended the cycle, got: $(cat "$out.err" 2>/dev/null)"
  lockpid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$lockpid" ] && kill -0 "$lockpid" 2>/dev/null; then
    fail "the singleton lock still names a LIVE holder ($lockpid) after the beat went unwritable"
  fi
  pass "an unwritable beacon ends the cycle (exit $rc) and leaves no live lock-holder with a frozen beat"
}

# The probe every hook case installs: one line per beat, so a case can count
# how many times the loop under test refreshed the beacon.
beat_probe_lines() {  # <beats-file>
  local n
  n=$(wc -l < "$1" 2>/dev/null | tr -d ' ')
  printf '%s' "${n:-0}"
}

test_liveness_hook_beats_per_pending_reply_record() {
  local dir state beats n
  dir=$(make_case liveness-hook-pending-reply); state="$dir/state"; beats="$dir/beats"
  : > "$beats"
  (
    set +u
    # shellcheck source=bin/fm-pending-reply-lib.sh
    . "$ROOT/bin/fm-pending-reply-lib.sh"
    # shellcheck disable=SC2329 # Invoked indirectly through FM_LIVENESS_BEAT_HOOK.
    beat_probe() { printf 'x\n' >> "$beats"; }
    fm_pending_reply_create "$dir" "$state" alpha "first request" >/dev/null || exit 1
    fm_pending_reply_create "$dir" "$state" bravo "second request" >/dev/null || exit 1
    fm_pending_reply_create "$dir" "$state" charlie "third request" >/dev/null || exit 1
    FM_LIVENESS_BEAT_HOOK=beat_probe fm_pending_reply_tick "$state" || exit 1
  ) || fail "seeding and ticking three pending-reply records must succeed"
  n=$(beat_probe_lines "$beats")
  [ "$n" -ge 3 ] \
    || fail "fm_pending_reply_tick must beat once per record; three records produced $n beats"
  pass "fm_pending_reply_tick beats the liveness hook once per record ($n beats for 3 records)"
}

test_liveness_hook_beats_per_signal_triage_task() {
  local dir state fakebin beats n
  dir=$(make_case liveness-hook-signal-triage); state="$dir/state"; fakebin="$dir/fakebin"
  beats="$dir/beats"
  : > "$beats"
  : > "$state/one.status"; : > "$state/two.status"; : > "$state/three.status"
  (
    set +u
    # shellcheck disable=SC2030 # Deliberately scoped to this subshell; other cases source the lib without it.
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
    # shellcheck source=bin/fm-classify-lib.sh
    . "$ROOT/bin/fm-classify-lib.sh"
    # shellcheck disable=SC2329 # Invoked indirectly through FM_LIVENESS_BEAT_HOOK.
    beat_probe() { printf 'x\n' >> "$beats"; }
    # Every task provably working, so the batch runs to completion instead of
    # short-circuiting on the first one.
    # shellcheck disable=SC2030,SC2031 # Deliberately scoped to this subshell.
    export FM_FAKE_CREW_STATE='state: working · source: pane · fake'
    FM_LIVENESS_BEAT_HOOK=beat_probe signal_crew_provably_working \
      "$state/one.status" "$state/two.status" "$state/three.status" || exit 1
  ) || fail "a three-task batch with every crew provably working must classify as absorbable"
  n=$(beat_probe_lines "$beats")
  [ "$n" -ge 3 ] \
    || fail "signal_crew_provably_working must beat once per task; three tasks produced $n beats"
  pass "signal_crew_provably_working beats the liveness hook once per task ($n beats for 3 tasks)"
}

test_liveness_hook_is_never_evaluated_as_shell_code() {
  local dir marker argc n
  dir=$(make_case liveness-hook-no-eval); marker="$dir/evaluated"; argc="$dir/argc"
  (
    set +u
    # shellcheck source=bin/fm-classify-lib.sh
    . "$ROOT/bin/fm-classify-lib.sh"
    # shellcheck disable=SC2329 # Invoked indirectly through FM_LIVENESS_BEAT_HOOK.
    beat_probe() { printf '%s\n' "$#" >> "$argc"; }
    # The hook is a COMMAND WORD plus arguments, never shell source text. Every
    # consumer of this library sources it, so an eval here would turn an
    # environment string into shell code in fm-crew-state.sh, fm-brief.sh,
    # fm-fleet-snapshot.sh, and the rest.
    FM_LIVENESS_BEAT_HOOK="beat_probe one two > $marker" fm_liveness_beat || exit 1
  ) || fail "a hook carrying shell metacharacters must still leave the loop alive"
  [ ! -e "$marker" ] \
    || fail "fm_liveness_beat evaluated the hook as shell code: the redirection created $marker"
  n=$(head -1 "$argc" 2>/dev/null || printf '0')
  [ "${n:-0}" -eq 4 ] \
    || fail "the hook must be word-split into a command plus its literal arguments, got $n arguments"
  pass "fm_liveness_beat invokes the hook directly with word-split arguments and never evaluates it as shell code"
}

test_liveness_hook_unset_is_a_noop() {
  local dir state fakebin beats n
  dir=$(make_case liveness-hook-unset); state="$dir/state"; fakebin="$dir/fakebin"
  beats="$dir/beats"
  : > "$beats"
  : > "$state/one.status"
  (
    set +u
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
    # shellcheck source=bin/fm-pending-reply-lib.sh
    . "$ROOT/bin/fm-pending-reply-lib.sh"
    # shellcheck disable=SC2329 # Invoked indirectly through FM_LIVENESS_BEAT_HOOK.
    beat_probe() { printf 'x\n' >> "$beats"; }
    fm_liveness_beat || exit 1
    fm_pending_reply_create "$dir" "$state" alpha "first request" >/dev/null || exit 1
    fm_pending_reply_tick "$state" || exit 1
    # shellcheck disable=SC2030,SC2031 # Deliberately scoped to this subshell.
    export FM_FAKE_CREW_STATE='state: working · source: pane · fake'
    signal_crew_provably_working "$state/one.status" || exit 1
  ) || fail "with no hook set, both loops must behave exactly as they did before the hook existed"
  n=$(beat_probe_lines "$beats")
  [ "$n" -eq 0 ] \
    || fail "an unset FM_LIVENESS_BEAT_HOOK must beat nothing, got $n beats"
  pass "an unset liveness hook is a no-op for consumers that own no beacon"
}

test_beacon_advances_when_every_backend_call_fails
test_beacon_advances_when_backend_hangs
test_unwritable_beacon_ends_the_cycle
test_liveness_hook_beats_per_pending_reply_record
test_liveness_hook_beats_per_signal_triage_task
test_liveness_hook_is_never_evaluated_as_shell_code
test_liveness_hook_unset_is_a_noop

echo "fm-watch-beacon tests passed"
