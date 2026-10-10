#!/usr/bin/env bash
# Codex idle continuity: a single-shot process-event source stays ownerless
# after reconciliation stops, and the allowing Stop starts a detached
# supervisor that runs it again.
# shellcheck disable=SC2016 # single quotes are deliberate: positional args expand inside the fake Codex child
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
# Claims are keyed by source id under one per-user root, so a second home that
# registers the same id there finds it owned and never starts its source.
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

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
fm_test_track_procevent_home "$HOME_DIR" "$FM_PROCEVENT_CLAIM_ROOT"

hits() { wc -l < "$LOG" | tr -d ' '; }

# A bash named codex stands in for the Codex session: it records itself as the
# home's session-lock owner and runs the hook as its child.
FAKE_CODEX="$TMP_ROOT/fakebin/codex"
mkdir -p "$TMP_ROOT/fakebin"
ln -s "$(command -v bash)" "$FAKE_CODEX"
as_lock_owner() {  # <home> <command...>
  "$FAKE_CODEX" -c 'printf "%s\n" "$$" > "$1/state/.lock"; shift; "$@"; rc=$?; exit "$rc"' _ "$@"
}

FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" register lavish shot -- "$SRC" >/dev/null \
  || fail "could not register the single-shot source"
# reconcile exits non-zero when the runner has not proved its claim inside the
# confirm window, and the default 3s is too short on a loaded host. The wait
# ends as soon as the proof exists, so a long window costs nothing otherwise.
FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=30 FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null \
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
  as_lock_owner "$HOME_DIR" "$CONT" >/dev/null || fail "allowing stop with a Codex owner failed"
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

# macOS reports argv[0] in `ps -o comm=`, so an npm Codex ancestor shows up as
# the full vendor path of its native binary.
REAL_PS=$(command -v ps)
FAKE_PS="$TMP_ROOT/fake-ps"
mkdir -p "$FAKE_PS"
cat > "$FAKE_PS/ps" <<PS
#!/bin/sh
pid= prev= comm=
for a in "\$@"; do
  [ "\$prev" = -p ] && pid=\$a
  [ "\$a" = comm= ] && comm=1
  prev=\$a
done
if [ -n "\$comm" ] && [ -n "\$pid" ] && [ "\$pid" = "\$(cat '$TMP_ROOT/fake-codex-pid' 2>/dev/null)" ]; then
  printf '%s\n' /opt/node/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex
  exit 0
fi
exec '$REAL_PS' "\$@"
PS
chmod +x "$FAKE_PS/ps"
hits_before=$(hits)
PATH="$FAKE_PS:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_CODEX_IDLE_QUEUE="$QUEUE_BIN" FM_POLL=1 \
  bash -c 'printf "%s\n" "$$" > "$1"; printf "%s\n" "$$" > "$4/state/.lock"; printf "%s" "$2" | "$3" >/dev/null; exec sleep 60' \
  _ "$TMP_ROOT/fake-codex-pid" "$payload" "$CONT" "$HOME_DIR" &
owner=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ "$(cat "$HOME_DIR/state/.codex-idle-continuity.lock/owner" 2>/dev/null)" = "$owner" ] && break
  sleep 0.5
done
[ "$(cat "$HOME_DIR/state/.codex-idle-continuity.lock/owner" 2>/dev/null)" = "$owner" ] \
  || fail "a Codex ancestor whose comm is a full path ending in /codex did not start the supervisor"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  [ "$(hits)" -gt "$hits_before" ] && break
  sleep 0.5
done
[ "$(hits)" -gt "$hits_before" ] || fail "supervisor under a full-path Codex ancestor did not reconcile the source"
kill "$owner" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ ! -d "$HOME_DIR/state/.codex-idle-continuity.lock" ] && break
  sleep 0.5
done
[ ! -d "$HOME_DIR/state/.codex-idle-continuity.lock" ] || fail "supervisor survived its full-path Codex owner"
wait "$owner" 2>/dev/null || true

printf 'ok - a Codex ancestor reported by its full binary path owns idle continuity\n'

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
fm_test_track_procevent_home "$TURNS" "$FM_PROCEVENT_CLAIM_ROOT"
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
    as_lock_owner "$TURNS" "$CONT" >/dev/null || fail "allowing stop failed"
}
checkpoint() {  # <seconds>; sets CP_RC. Runs as the session-lock owner, as a Codex turn does.
  CP_RC=0
  as_lock_owner "$TURNS" env FM_ROOT_OVERRIDE="$TURNS" FM_HOME="$TURNS" \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds "$1" \
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

foreign_rc=0
FM_ROOT_OVERRIDE="$TURNS" FM_HOME="$TURNS" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 1 \
  >"$TMP_ROOT/foreign-cp.out" 2>"$TMP_ROOT/foreign-cp.err" || foreign_rc=$?
supervisor_up || fail "a checkpoint from a session that does not own the lock stopped the idle supervisor (rc=$foreign_rc)"
[ "$foreign_rc" -eq 124 ] || fail "a non-owner checkpoint exited $foreign_rc instead of a quiet checkpoint: $(cat "$TMP_ROOT/foreign-cp.out" "$TMP_ROOT/foreign-cp.err")"
grep -F 'checkpoint: no actionable wake within 1s' "$TMP_ROOT/foreign-cp.out" >/dev/null \
  || fail "a non-owner checkpoint did not report a quiet bound: $(cat "$TMP_ROOT/foreign-cp.out")"
printf 'ok - a checkpoint from a session that does not own the lock leaves the idle supervisor running\n'

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

# A wake the primary has not drained yet keeps an announced downtime episode
# open, so the first supervised watcher resurfaces it once. The arm after that
# queued close is a handling successor and must not resurface it again.
sleep 600 &
owner=$!
: > "$QUEUE"
checkpoint 2
case "$CP_RC" in 0|124) ;; *) fail "the downtime checkpoint failed (rc=$CP_RC): $(cat "$TMP_ROOT/cp.out" "$TMP_ROOT/cp.err")" ;; esac
printf '1700000000\t1\tcheck\tundrained\tcheck: undrained\n' >> "$TSTATE/.wake-queue"
allowing_stop
wait_until 50 grep -q '^check: rearm-resurface' "$QUEUE" \
  || fail "the idle supervisor did not resurface the undrained downtime: $(cat "$QUEUE")"
sleep 8
resurfaced=$(grep -c '^check: rearm-resurface' "$QUEUE")
[ "$resurfaced" -eq 1 ] || fail "the idle supervisor re-queued rearm-resurface $resurfaced times"
supervisor_owns_watcher || fail "the idle supervisor did not keep a watcher after the resurface"
kill "$owner" 2>/dev/null || true
wait_until 50 test ! -d "$TLOCK" || fail "supervisor survived its Codex owner"
wait "$owner" 2>/dev/null || true
printf 'ok - the idle supervisor queues pending downtime once and re-arms as a handling successor\n'

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
[ "\${1:-}" = --stop ] && { printf 'x\n' >> '$STUB/stops'; exit 0; }
printf 'x\n' >> '$STUB/arms'
case "\$(cat '$STUB/mode')" in
  away) : > '$SSTATE/.afk'; printf 'watcher: started pid=1 (beacon fresh)\nsignal: demo away close\n' ;;
  handover) printf 'watcher: attached pid=1 (beacon 0s)\nwatcher: FAILED - cycle ended without an actionable reason\n' ;;
  taken) printf 'watcher: started pid=1 (beacon fresh)\nwatcher: FAILED - watcher cycle exited 143 without an actionable reason\n' ;;
  stall) printf 'watcher: attached pid=1 (beacon 0s)\nwatcher: FAILED - attached watcher pid=1 stalled (beacon 9s at or past hard bound 8s)\n' ;;
  started-fail) printf 'watcher: started pid=1 (beacon fresh)\nwatcher: FAILED - cycle ended without an actionable reason\n' ;;
  hold) printf 'watcher: attached pid=1 (beacon 0s)\n'; exec sleep 600 ;;
  hold-started) printf 'watcher: started pid=1 (beacon fresh)\n'; exec sleep 600 ;;
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
    as_lock_owner "$STUB" "$STUB/bin/fm-codex-idle-continuity.sh" >/dev/null 2>&1 || true
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
printf 'ok - a broken watcher queues one give-up check per failure episode, and a successful checkpoint ends the episode\n'

rm -f "$SSTATE/.codex-idle-continuity-failure-notified"
printf 'away\n' > "$STUB/mode"
: > "$STUB/arms"
: > "$STUB/queue"
: > "$STUB/stops"
stub_stop
wait_until 75 at_least_arms 1 || fail "the away-mode case never armed"
wait_until 75 test ! -d "$SLOCK" || fail "away mode that started mid-cycle did not end the supervisor"
[ ! -s "$STUB/queue" ] || fail "a close that returned in away mode reached the thread: $(cat "$STUB/queue")"
[ ! -s "$STUB/stops" ] || fail "the supervisor stopped the watcher the away daemon owns"
[ "$(arms)" -eq 1 ] || fail "the supervisor armed again in away mode: $(arms) arms"
rm -f "$SSTATE/.afk"
printf 'ok - a close that returns after away mode started is not queued and leaves the watcher alone\n'

mkdir -p "$STUB/config"
: > "$STUB/config/supervision-host"
printf 'broken\n' > "$STUB/mode"
: > "$STUB/arms"
: > "$STUB/queue"
stub_stop
sleep 2
[ ! -d "$SLOCK" ] || fail "a host-opted home started an idle supervisor"
[ "$(arms)" -eq 0 ] || fail "a host-opted home armed $(arms) times after the allowing stop"
[ ! -s "$STUB/queue" ] || fail "a host-opted home queued text: $(cat "$STUB/queue")"
printf 'ok - a home opted into the supervision host starts no idle supervisor\n'

printf 'off\n' > "$STUB/config/supervision-host"
: > "$STUB/arms"
stub_stop
sleep 2
[ ! -d "$SLOCK" ] || fail "a supervision-host file whose text is off started an idle supervisor"
[ "$(arms)" -eq 0 ] || fail "a supervision-host file whose text is off armed $(arms) times"
rm -f "$STUB/config/supervision-host"
: > "$STUB/config/supervision-host-off"
printf 'handover\n' > "$STUB/mode"
: > "$STUB/arms"
stub_stop
wait_until 75 at_least_arms 1 || fail "a home opted out with supervision-host-off started no idle supervisor"
FM_ROOT_OVERRIDE="$STUB" FM_HOME="$STUB" "$STUB/bin/fm-codex-idle-continuity.sh" --handover </dev/null \
  || fail "handover of the opted-out supervisor failed"
rm -f "$STUB/config/supervision-host-off"
printf 'ok - a supervision-host file opts out of idle continuity, and supervision-host-off does not\n'

foreign_stop() {
  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$STUB" FM_HOME="$STUB" \
    FM_CODEX_IDLE_OWNER_PID="$owner" FM_CODEX_IDLE_QUEUE="$STUB/queue.sh" \
    "$FAKE_CODEX" -c '"$1"; rc=$?; exit "$rc"' _ "$STUB/bin/fm-codex-idle-continuity.sh" >/dev/null 2>&1 || true
}
"$FAKE_CODEX" -c 'sleep 600; :' &
other=$!
printf '%s\n' "$other" > "$SSTATE/.lock"
: > "$STUB/arms"
: > "$STUB/queue"
foreign_stop
sleep 2
[ ! -d "$SLOCK" ] || fail "a session that does not own the home lock started an idle supervisor"
[ "$(arms)" -eq 0 ] || fail "a session that does not own the home lock armed $(arms) times"
[ "$(cat "$SSTATE/.lock")" = "$other" ] || fail "a non-owning session replaced the live session lock"
kill "$other" 2>/dev/null || true
wait "$other" 2>/dev/null || true
printf 'ok - a session that does not own the home lock starts no idle supervisor\n'

printf '9999999\n' > "$SSTATE/.lock"
foreign_stop
wait_until 75 at_least_arms 1 || fail "a stop after the recorded lock owner died started no idle supervisor"
[ "$(cat "$SSTATE/.lock")" != 9999999 ] || fail "the dead session-lock owner was not reclaimed"
FM_ROOT_OVERRIDE="$STUB" FM_HOME="$STUB" "$STUB/bin/fm-codex-idle-continuity.sh" --handover </dev/null \
  || fail "handover of the reclaimed-lock supervisor failed"
printf 'ok - a dead recorded session owner is reclaimed before the idle supervisor starts\n'

rm -f "$SSTATE/.codex-idle-continuity-failure-notified"
sleep 30 &
starter=$!
rm -rf "$SLOCK"
mkdir "$SLOCK"
printf '%s\n' "$starter" > "$SLOCK/starting"
printf '%s\n' "$owner" > "$SLOCK/owner"
: > "$STUB/arms"
stub_stop
[ "$(cat "$SLOCK/starting" 2>/dev/null)" = "$starter" ] \
  || fail "a second stop reclaimed a startup lock that had not recorded its supervisor pid"
[ ! -s "$SLOCK/pid" ] || fail "a second stop started a supervisor while startup still held the lock"
handover_rc=0
FM_ROOT_OVERRIDE="$STUB" FM_HOME="$STUB" "$STUB/bin/fm-codex-idle-continuity.sh" --handover </dev/null \
  || handover_rc=$?
[ "$handover_rc" -ne 0 ] || fail "handover treated a supervisor that had not recorded its pid as already stopped"
[ -d "$SLOCK" ] || fail "handover removed a startup lock that had not recorded its supervisor pid"
kill "$starter" 2>/dev/null || true
wait "$starter" 2>/dev/null || true
stub_stop
wait_until 75 pid_in_live "$SLOCK/pid" || fail "a startup lock whose hook pid had died was not reclaimed"
FM_ROOT_OVERRIDE="$STUB" FM_HOME="$STUB" "$STUB/bin/fm-codex-idle-continuity.sh" --handover </dev/null \
  || fail "handover of the reclaimed startup supervisor failed"
printf 'ok - a startup lock is not reclaimed or handed over until the supervisor pid is recorded\n'

# The window an overlapping stop used to hit: another stop holds the claim and
# has created the lock directory but has not written `starting` into it yet.
rm -f "$SSTATE/.codex-idle-continuity-failure-notified"
: > "$STUB/arms"
FM_ROOT_OVERRIDE="$STUB" FM_HOME="$STUB" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$STATE/.codex-idle-continuity-claim.lock" || exit 1
  mkdir "$STATE/.codex-idle-continuity.lock" || exit 1
  : > "$2"
  exec sleep 600
' _ "$STUB" "$TMP_ROOT/claim-held" >/dev/null 2>&1 &
claimer=$!
wait_until 75 test -e "$TMP_ROOT/claim-held" || fail "the stand-in stop never took the claim"
stub_stop
sleep 1
kill "$claimer" 2>/dev/null || true
wait "$claimer" 2>/dev/null || true
[ -d "$SLOCK" ] || fail "an overlapping stop removed a lock directory another stop was still filling"
[ ! -e "$SLOCK/starting" ] && [ ! -s "$SLOCK/pid" ] && [ "$(arms)" -eq 0 ] \
  || fail "an overlapping stop started a supervisor while another stop held the claim"
stub_stop
wait_until 75 pid_in_live "$SLOCK/pid" || fail "a claim whose holder had died blocked the next stop"
FM_ROOT_OVERRIDE="$STUB" FM_HOME="$STUB" "$STUB/bin/fm-codex-idle-continuity.sh" --handover </dev/null \
  || fail "handover of the supervisor started after a dead claim failed"
printf 'ok - a stop that overlaps another stop mid-claim starts no second supervisor\n'

rm -f "$SSTATE/.codex-idle-continuity-failure-notified"
printf 'stall\n' > "$STUB/mode"
: > "$STUB/arms"
: > "$STUB/queue"
stub_stop
wait_until 75 test ! -d "$SLOCK" || fail "an attached watcher that later stalled never ended the supervisor"
[ "$(arms)" -eq 3 ] || fail "a stall after attached spent $(arms) arms instead of 3"
grep -F 'check: codex idle continuity stopped after 3 failed watcher arms' "$STUB/queue" >/dev/null \
  || fail "a stall after attached queued no give-up check: $(cat "$STUB/queue" 2>/dev/null)"
printf 'ok - a stall after watcher: attached spends the failure budget\n'

rm -f "$SSTATE/.codex-idle-continuity-failure-notified"
printf 'started-fail\n' > "$STUB/mode"
: > "$STUB/arms"
: > "$STUB/queue"
stub_stop
wait_until 75 test ! -d "$SLOCK" || fail "a started arm that ended with no actionable reason never ended the supervisor"
[ "$(arms)" -eq 3 ] || fail "a started arm that ended with no actionable reason spent $(arms) arms instead of 3"
grep -F 'check: codex idle continuity stopped after 3 failed watcher arms' "$STUB/queue" >/dev/null \
  || fail "a started arm that ended with no actionable reason queued no give-up check: $(cat "$STUB/queue" 2>/dev/null)"
printf 'ok - a started arm that ends with no actionable reason spends the failure budget\n'

rm -f "$SSTATE/.codex-idle-continuity-failure-notified"
printf 'hold\n' > "$STUB/mode"
: > "$STUB/arms"
: > "$STUB/stops"
: > "$STUB/queue"
stub_stop
wait_until 75 grep -q '^watcher: attached ' "$SLOCK/arm.out" \
  || fail "the held arm never reported attached: $(cat "$SLOCK/arm.out" 2>/dev/null)"
kill "$owner" 2>/dev/null || true
wait_until 50 test ! -d "$SLOCK" || fail "the supervisor survived its Codex owner while attached"
[ ! -s "$STUB/stops" ] || fail "owner exit stopped a watcher the supervisor had only attached to"
wait "$owner" 2>/dev/null || true
printf 'ok - owner exit does not stop a watcher the supervisor only attached to\n'

sleep 600 &
owner=$!
rm -f "$SSTATE/.codex-idle-continuity-failure-notified"
printf 'hold\n' > "$STUB/mode"
: > "$STUB/arms"
: > "$STUB/stops"
: > "$STUB/queue"
stub_stop
wait_until 75 grep -q '^watcher: attached ' "$SLOCK/arm.out" \
  || fail "the held arm never reported attached before TERM: $(cat "$SLOCK/arm.out" 2>/dev/null)"
kill -TERM "$(cat "$SLOCK/pid")" 2>/dev/null || true
wait_until 50 test ! -d "$SLOCK" || fail "the supervisor survived TERM while only attached"
[ ! -s "$STUB/stops" ] || fail "TERM stopped a watcher the supervisor had only attached to"
printf 'hold-started\n' > "$STUB/mode"
: > "$STUB/arms"
: > "$STUB/stops"
stub_stop
wait_until 75 grep -q '^watcher: started ' "$SLOCK/arm.out" \
  || fail "the held arm never reported started before TERM: $(cat "$SLOCK/arm.out" 2>/dev/null)"
kill -TERM "$(cat "$SLOCK/pid")" 2>/dev/null || true
wait_until 50 test ! -d "$SLOCK" || fail "the supervisor survived TERM after it started the watcher"
[ -s "$STUB/stops" ] || fail "TERM left running a watcher the supervisor had started"
kill "$owner" 2>/dev/null || true
wait "$owner" 2>/dev/null || true
printf 'ok - TERM stops a watcher only when this supervisor started it\n'
