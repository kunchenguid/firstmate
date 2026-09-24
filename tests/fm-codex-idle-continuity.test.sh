#!/usr/bin/env bash
# Codex idle continuity: a single-shot process-event source stays ownerless
# after reconciliation stops, and the allowing Stop starts a detached
# supervisor that runs it again.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-codex-idle)
HOME_DIR="$TMP_ROOT/primary"
LOG="$TMP_ROOT/hits"
QUEUE="$TMP_ROOT/queue"
SRC="$TMP_ROOT/source.sh"
QUEUE_BIN="$TMP_ROOT/queue.sh"
CONT="$ROOT/bin/fm-codex-idle-continuity.sh"

fail() { [ -z "${owner:-}" ] || kill "$owner" 2>/dev/null; printf 'not ok - %s\n' "$1" >&2; exit 1; }

mkdir -p "$HOME_DIR/bin" "$HOME_DIR/state"
git init -q "$HOME_DIR"
: > "$HOME_DIR/AGENTS.md"
cat > "$SRC" <<EOF
#!/bin/sh
printf 'x\n' >> '$LOG'
EOF
chmod +x "$SRC"
cat > "$QUEUE_BIN" <<EOF
#!/bin/sh
cat >> '$QUEUE'
EOF
chmod +x "$QUEUE_BIN"
fm_test_track_procevent_home "$HOME_DIR"

hits() { wc -l < "$LOG" | tr -d ' '; }

FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" register lavish shot -- "$SRC" >/dev/null \
  || fail "could not register the single-shot source"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null \
  || fail "initial reconcile did not start the source"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -f "$LOG" ] && [ "$(hits)" -ge 1 ] && break
  sleep 0.2
done
[ "$(hits)" -eq 1 ] || fail "registration reconcile did not run the source once"
list=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" list)
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  printf '%s\n' "$list" | grep -F 'none' >/dev/null && break
  sleep 0.3
  list=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" list)
done
printf '%s\n' "$list" | grep -F 'none' >/dev/null || fail "source was still owned after it exited: $list"
sleep 1
[ "$(hits)" -eq 1 ] || fail "source restarted with no supervision cycle"

payload=$(jq -cn '{stop_hook_active:true,session_id:"thread-test"}')
printf '%s' "$payload" | FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" \
  "$CONT" >/dev/null || fail "allowing stop without a Codex owner must still forward"
sleep 1
[ "$(hits)" -eq 1 ] || fail "allowing stop spawned continuity without a Codex owner"
[ ! -d "$HOME_DIR/state/.codex-idle-continuity.lock" ] || fail "lock left behind without a Codex owner"

sleep 60 &
owner=$!
printf '%s' "$payload" | FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" \
  FM_CODEX_IDLE_OWNER_PID="$owner" FM_CODEX_IDLE_QUEUE="$QUEUE_BIN" FM_POLL=1 \
  "$CONT" >/dev/null || fail "allowing stop with a Codex owner failed"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  [ -f "$LOG" ] && [ "$(hits)" -ge 2 ] && [ -s "$QUEUE" ] && break
  sleep 0.5
done
[ "$(hits)" -ge 2 ] || fail "detached supervisor did not reconcile the ownerless source"
[ -s "$QUEUE" ] || fail "actionable close was not handed to the queue command"
kill "$owner" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ ! -d "$HOME_DIR/state/.codex-idle-continuity.lock" ] && break
  sleep 0.5
done
[ ! -d "$HOME_DIR/state/.codex-idle-continuity.lock" ] || fail "supervisor survived its Codex owner"
wait "$owner" 2>/dev/null || true

printf 'ok - codex idle continuity re-arms a single-shot source only for a live owner\n'

# Later turns: a perpetual source keeps supervision needed without actionable
# closes, so only handovers end the supervisor's arm cycles below.
TURNS="$TMP_ROOT/turns"
TSTATE="$TURNS/state"
TLOCK="$TSTATE/.codex-idle-continuity.lock"
PERPETUAL="$TMP_ROOT/perpetual.sh"
mkdir -p "$TURNS/bin" "$TSTATE"
git init -q "$TURNS"
: > "$TURNS/AGENTS.md"
printf '#!/bin/sh\nexec sleep 600\n' > "$PERPETUAL"
chmod +x "$PERPETUAL"
fm_test_track_procevent_home "$TURNS"
FM_HOME="$TURNS" "$ROOT/bin/fm-procevent.sh" register lavish forever -- "$PERPETUAL" >/dev/null \
  || fail "could not register the perpetual source"

export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3

wait_until() {  # <tries of 0.2s> <command...>
  local tries=$1 i=0
  shift
  while [ "$i" -lt "$tries" ]; do
    "$@" && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}
pid_in_live() { local pid; pid=$(cat "$1" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
supervisor_up() { pid_in_live "$TLOCK/pid"; }
watcher_up() { pid_in_live "$TSTATE/.watch.lock/pid"; }
supervisor_owns_watcher() {
  supervisor_up && watcher_up \
    && [ "$(ps -o ppid= -p "$(ps -o ppid= -p "$(cat "$TSTATE/.watch.lock/pid")" | tr -d ' ')" | tr -d ' ')" = "$(cat "$TLOCK/pid")" ]
}
allowing_stop() {
  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$TURNS" FM_HOME="$TURNS" \
    FM_CODEX_IDLE_OWNER_PID="$owner" FM_CODEX_IDLE_QUEUE="$QUEUE_BIN" \
    "$CONT" >/dev/null || fail "allowing stop failed"
}
checkpoint() {  # <seconds>; sets CP_RC
  CP_RC=0
  FM_ROOT_OVERRIDE="$TURNS" FM_HOME="$TURNS" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds "$1" \
    >"$TMP_ROOT/cp.out" 2>"$TMP_ROOT/cp.err" || CP_RC=$?
}

sleep 600 &
owner=$!
allowing_stop
wait_until 50 supervisor_owns_watcher || fail "the first idle boundary did not start a supervised watcher"
for turn in 1 2 3; do
  checkpoint 2
  case "$CP_RC" in 0|124) ;; *) fail "turn $turn checkpoint did not own its watcher (rc=$CP_RC): $(cat "$TMP_ROOT/cp.out" "$TMP_ROOT/cp.err")" ;; esac
  [ ! -d "$TLOCK" ] || fail "turn $turn checkpoint left the idle supervisor running"
  allowing_stop
  wait_until 50 supervisor_owns_watcher || fail "turn $turn idle boundary did not restore continuity"
done
printf 'ok - each new turn checkpoint takes over from the idle supervisor and the next stop restores it\n'

FM_ROOT_OVERRIDE="$TURNS" FM_HOME="$TURNS" "$CONT" --handover </dev/null || fail "handover of a live supervisor failed"
[ ! -d "$TLOCK" ] || fail "handover left the idle supervisor running"
checkpoint 4 &
cp_pid=$!
wait_until 50 watcher_up || fail "the checkpoint's watcher never took the lock"
allowing_stop
wait "$cp_pid"
wait_until 50 supervisor_owns_watcher || fail "the supervisor attached to a checkpoint watcher did not re-arm after it closed"
printf 'ok - a supervisor attached to a checkpoint watcher re-arms its own after the checkpoint ends\n'

kill "$owner" 2>/dev/null || true
wait_until 50 test ! -d "$TLOCK" || fail "supervisor survived its Codex owner"
wait "$owner" 2>/dev/null || true

# The failure budget, against an arm that reports only the documented status
# lines: closes of a watcher another owner held never end continuity, while
# closes with no watcher at all still do after three tries.
STUB="$TMP_ROOT/stub"
SSTATE="$STUB/state"
SLOCK="$SSTATE/.codex-idle-continuity.lock"
mkdir -p "$STUB/bin" "$SSTATE"
git init -q "$STUB"
: > "$STUB/AGENTS.md"
: > "$SSTATE/demo.meta"
for f in "$ROOT"/bin/*; do ln -s "$f" "$STUB/bin/${f##*/}"; done
rm "$STUB/bin/fm-watch-arm.sh"
cat > "$STUB/bin/fm-watch-arm.sh" <<EOF
#!/bin/sh
[ "\${1:-}" = --stop ] && exit 0
printf 'x\n' >> '$STUB/arms'
case "\$(cat '$STUB/mode')" in
  handover) printf 'watcher: attached pid=1 (beacon 0s)\nwatcher: FAILED - cycle ended without an actionable reason\n' ;;
  taken) printf 'watcher: started pid=1 (beacon fresh)\nwatcher: FAILED - watcher cycle exited 143 without an actionable reason\n' ;;
  broken) printf 'watcher: FAILED - no live watcher with a fresh beacon\n' ;;
esac
exit 1
EOF
chmod +x "$STUB/bin/fm-watch-arm.sh"
printf '#!/bin/sh\ncat >> %s\n' "$STUB/queue" > "$STUB/queue.sh"
chmod +x "$STUB/queue.sh"
arms() { wc -l < "$STUB/arms" 2>/dev/null | tr -d ' ' || printf '0\n'; }
stub_stop() {
  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$STUB" FM_HOME="$STUB" \
    FM_CODEX_IDLE_OWNER_PID="$owner" FM_CODEX_IDLE_QUEUE="$STUB/queue.sh" \
    "$STUB/bin/fm-codex-idle-continuity.sh" >/dev/null 2>&1 || true
}
at_least_arms() { [ "$(arms)" -ge "$1" ]; }

sleep 600 &
owner=$!
for mode in handover taken; do
  printf '%s\n' "$mode" > "$STUB/mode"
  : > "$STUB/arms"
  stub_stop
  wait_until 75 at_least_arms 5 || fail "$mode closes ended idle continuity after $(arms) arm cycles"
  pid_in_live "$SLOCK/pid" || fail "$mode closes stopped the supervisor"
  FM_ROOT_OVERRIDE="$STUB" FM_HOME="$STUB" "$STUB/bin/fm-codex-idle-continuity.sh" --handover </dev/null \
    || fail "handover of the $mode supervisor failed"
done
printf 'broken\n' > "$STUB/mode"
: > "$STUB/arms"
stub_stop
wait_until 75 test ! -d "$SLOCK" || fail "arm failures with no watcher never ended the supervisor"
[ "$(arms)" -eq 3 ] || fail "the supervisor gave up after $(arms) failed arms instead of 3"
[ "$(cat "$STUB/queue" 2>/dev/null)" = "check: codex idle continuity stopped after 3 failed watcher arms: watcher: FAILED - no live watcher with a fresh beacon" ] \
  || fail "giving up left no check in the thread: $(cat "$STUB/queue" 2>/dev/null)"
printf 'ok - handover closes never spend the failure budget, and real arm failures still do\n'

giveups() { grep -c '^check: codex idle continuity stopped' "$STUB/queue" 2>/dev/null || true; }
for turn in 1 2 3; do
  stub_stop
  sleep 1
  [ ! -d "$SLOCK" ] || fail "turn end $turn restarted a supervisor during a notified failure episode"
done
[ "$(arms)" -eq 3 ] || fail "turn ends during a notified failure episode armed again: $(arms) arms"
[ "$(giveups)" -eq 1 ] || fail "a persistently broken watcher queued $(giveups) give-up checks"
CP_RC=0
FM_ROOT_OVERRIDE="$STUB" FM_HOME="$STUB" "$STUB/bin/fm-watch-checkpoint.sh" --seconds 1 \
  >"$TMP_ROOT/stub-cp.out" 2>"$TMP_ROOT/stub-cp.err" || CP_RC=$?
case "$CP_RC" in 0|124) ;; *) fail "the recovery checkpoint failed (rc=$CP_RC): $(cat "$TMP_ROOT/stub-cp.out" "$TMP_ROOT/stub-cp.err")" ;; esac
stub_stop
wait_until 75 at_least_arms 6 || fail "a successful checkpoint did not re-enable idle continuity"
wait_until 75 test ! -d "$SLOCK" || fail "the re-enabled supervisor never gave up on the broken watcher"
[ "$(giveups)" -eq 2 ] || fail "the next failure episode queued $(giveups) give-up checks in total instead of 2"
kill "$owner" 2>/dev/null || true
wait "$owner" 2>/dev/null || true
printf 'ok - a broken watcher queues one give-up check per failure episode, and a successful checkpoint ends the episode\n'
