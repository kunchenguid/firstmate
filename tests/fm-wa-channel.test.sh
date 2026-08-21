#!/usr/bin/env bash
# Behavioral regressions for the inbound WhatsApp channel.
#
# Everything here runs without a live WhatsApp session: the listener's
# accept/reject rules are driven through its handle-fixture command, and the
# send path through FM_WA_DRY_RUN. Pairing itself needs the captain's phone and
# is out of scope for an automated test.

# shellcheck disable=SC2030,SC2031 # bin/fm-wa-lib.sh reads a process identity
# inside a subshell that sources bin/fm-wake-lib.sh, and that library assigns its
# own FM_HOME, FM_ROOT and STATE. The subshell IS the containment, so this file's
# own values are unaffected and every later read of them is the value it always had.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLL="$ROOT/bin/fm-wa-poll.sh"
SETUP="$ROOT/bin/fm-wa-setup.sh"
SEND="$ROOT/bin/fm-wa-send.sh"
LISTENER="$ROOT/bin/fm-wa-listen.mjs"
LISTEN_SH="$ROOT/bin/fm-wa-listen.sh"
LIB="$ROOT/bin/fm-wa-lib.sh"
CAPTAIN=447700900123
# A second captain number, for the two-phones case. Invented, like the first.
CAPTAIN2=447700900124
TMP_ROOT=$(fm_test_tmproot fm-wa-channel)

new_home() {
  local home=$1
  mkdir -p "$home/state" "$home/config"
  chmod 700 "$home/state"
  printf 'FM_WA_CAPTAIN=%s\nFM_WA_ALLOW_DEVICES=0\n' "$CAPTAIN" > "$home/config/whatsapp.env"
}

stash_message() {
  local home=$1 id=$2
  mkdir -p "$home/state/wa-inbox"
  chmod 700 "$home/state/wa-inbox"
  printf '{"schema":"fm-wa-inbox-v1","id":"%s","text":"hello"}\n' "$id" \
    > "$home/state/wa-inbox/$id.json"
  chmod 600 "$home/state/wa-inbox/$id.json"
}

poll() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" "$POLL" 2>/dev/null
}

# A paired, running listener, so a test about the inbox is not answered by the
# liveness nudge instead. The pid is a disposable process rather than this test
# runner, because the poll repairs a wedged listener by stopping it.
FAKE_PIDS=
fake_listener() {
  local home=$1 pid
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  sleep 300 &
  pid=$!
  FAKE_PIDS="$FAKE_PIDS $pid"
  printf '%s\n' "$pid" > "$home/state/wa-listener.pid"
  # The poll refuses to signal a pid it cannot bind to the listener this home
  # started, so a stand-in has to carry the same identity record a real start
  # writes.
  ( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    FM_WA_STATE="$home/state" fm_wa_record_listener_identity "$pid" ) \
    >/dev/null 2>&1 || true
}

# The same stand-in, but one that ignores SIGTERM, so the stop paths are driven
# all the way to the SIGKILL they only reach for a genuinely wedged listener.
# Orphaned on purpose, exactly as the real listener is: a child of this shell
# would linger as a zombie after it is killed and still answer `kill -0`, which
# would make this fixture prove the bug rather than the fix. An ignored signal
# survives exec, so the sleep that replaces the shell inherits the deaf handler.
DEAF_PID=
deaf_listener() {
  local home=$1 pidfile waited=0
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  pidfile="$TMP_ROOT/deaf.$$.$RANDOM.pid"
  rm -f "$pidfile"
  ( bash -c 'trap "" TERM; printf "%s\n" "$$" > "$1"; exec sleep 300' _ "$pidfile" >/dev/null 2>&1 & )
  while [ ! -s "$pidfile" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    waited=$(( waited + 1 ))
  done
  DEAF_PID=$(cat "$pidfile" 2>/dev/null) || DEAF_PID=
  [ -n "$DEAF_PID" ] || fail "could not start a stand-in listener that ignores SIGTERM"
  FAKE_PIDS="$FAKE_PIDS $DEAF_PID"
  printf '%s\n' "$DEAF_PID" > "$home/state/wa-listener.pid"
  ( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    FM_WA_STATE="$home/state" fm_wa_record_listener_identity "$DEAF_PID" ) \
    >/dev/null 2>&1 || true
}

# A live process this home cannot claim that really IS another listener, which
# is the only case that justifies refusing to act. An unrelated process holding
# a recycled pid is a different thing entirely - see the stale-record test - so
# it cannot be modelled with a bare `sleep`: the refusal is drawn on whether the
# command names the listener program, exactly as fm_wa_process_is_listener does.
foreign_listener() {
  local home=$1 fake pid
  fake="$TMP_ROOT/foreign-listener/fm-wa-listen.mjs"
  mkdir -p "$(dirname "$fake")"
  # No exec: the process must KEEP the script in its command line, which is what
  # fm_wa_process_is_listener reads. exec would replace it with `sleep`.
  printf 'sleep 300\n' > "$fake"
  bash "$fake" >/dev/null 2>&1 &
  pid=$!
  FAKE_PIDS="$FAKE_PIDS $pid"
  printf '%s\n' "$pid" > "$home/state/wa-listener.pid"
  printf 'Sat Jan  1 00:00:00 2000\n' > "$home/state/wa-listener.pid-identity"
  FOREIGN_PID=$pid
}

reap_fake_listeners() {
  local pid
  for pid in $FAKE_PIDS; do
    kill "$pid" 2>/dev/null || true
    kill -9 "$pid" 2>/dev/null || true
  done
  FAKE_PIDS=
}

# Tests that exercise the real start, restart and autostart paths leave a real
# node listener running in their fixture home, and nothing was reaping those:
# only the SIGTERM-ignoring stand-ins above were tracked. Every run therefore
# leaked one process per such test, which accumulate across runs until the host
# runs out of memory - measured at 199 stranded listeners, and enough to make
# unrelated work on the same machine fail to start.
#
# Both passes are scoped to THIS run's own temp root, so a listener belonging to
# a real home, or to another run, is never signalled. The pid files are the
# ordinary case; the /proc pass catches a listener whose home was already
# removed, which is why it matches on FM_HOME rather than on the command name.
#
# Where the pid file SITS proves nothing about the process the number now names:
# several tests leave a pid file behind on purpose for a process that has
# already exited, so by the time this runs that number can belong to anything on
# the developer's own machine. The process is proved before it is signalled,
# exactly as the production paths do it.
reap_started_listeners() {
  local pidfile pid env_home
  for pidfile in "$TMP_ROOT"/*/state/wa-listener.pid; do
    [ -f "$pidfile" ] || continue
    pid=$(cat "$pidfile" 2>/dev/null) || continue
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    ( # shellcheck source=bin/fm-wa-lib.sh
      . "$LIB"
      fm_wa_process_is_listener "$pid" ) >/dev/null 2>&1 || continue
    kill "$pid" 2>/dev/null || true
    kill -9 "$pid" 2>/dev/null || true
  done
  [ -d /proc ] || return 0
  for pid in $(pgrep -f 'fm-wa-listen\.mjs listen' 2>/dev/null); do
    env_home=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
      | sed -n 's/^FM_HOME=//p') || continue
    case "$env_home" in
      "$TMP_ROOT"/*) kill "$pid" 2>/dev/null || true; kill -9 "$pid" 2>/dev/null || true ;;
    esac
  done
}
trap 'reap_fake_listeners; reap_started_listeners; fm_test_cleanup' EXIT

# --- the channel is inert until a home opts in ------------------------------

test_off_by_default() {
  local home out
  home="$TMP_ROOT/off"
  mkdir -p "$home/state" "$home/config"
  stash_message "$home" MSGOFF

  out=$(poll "$home")
  [ -z "$out" ] || fail "poll produced output with no config: $out"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm 2>&1) && \
    fail "arm succeeded with no config"
  assert_contains "$out" 'FM_WA_CAPTAIN' "arm did not name the missing configuration"
  assert_absent "$home/state/wa-watch.check.sh" "arm wrote a check shim with no config"

  pass "a home with no config/whatsapp.env polls nothing and arms nothing"
}

test_removing_config_reverts_to_silence() {
  local home out
  home="$TMP_ROOT/optout"
  new_home "$home"
  fake_listener "$home"
  stash_message "$home" MSGOPTOUT
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending' "armed home did not announce a pending message"

  rm -f "$home/config/whatsapp.env"
  out=$(poll "$home")
  [ -z "$out" ] || fail "poll still spoke after the config was removed: $out"

  pass "removing config/whatsapp.env reverts the home to no polling at all"
}

# --- the check contract -----------------------------------------------------

test_check_contract() {
  local home out
  home="$TMP_ROOT/check"
  new_home "$home"
  mkdir -p "$home/state/wa-inbox"
  chmod 700 "$home/state/wa-inbox"
  # A paired listener is faked so the liveness nudge stays quiet and only the
  # inbox contract is under test.
  fake_listener "$home"

  out=$(poll "$home")
  [ -z "$out" ] || fail "empty inbox produced output: $out"

  stash_message "$home" MSGA
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending, including MSGA' "a new message was not announced"

  out=$(poll "$home")
  [ -z "$out" ] || fail "the same pending set was announced twice: $out"

  stash_message "$home" MSGB
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 2 pending' "a changed pending set was not announced"

  rm -f "$home/state/wa-inbox/"*.json
  out=$(poll "$home")
  [ -z "$out" ] || fail "a drained inbox produced output: $out"

  pass "the check speaks once per new pending set and is silent otherwise"
}

test_undrained_inbox_is_reannounced() {
  local home out
  home="$TMP_ROOT/reannounce"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s\nFM_WA_REANNOUNCE=0\n' "$CAPTAIN" > "$home/config/whatsapp.env"
  fake_listener "$home"
  stash_message "$home" MSGSTUCK

  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending' "first announcement missing"
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending' "an undrained inbox was never re-announced"

  pass "a message firstmate failed to drain resurfaces rather than being lost"
}

test_an_unusable_entry_never_silences_the_rest() {
  local home out
  home="$TMP_ROOT/badname"
  new_home "$home"
  fake_listener "$home"
  stash_message "$home" MSGGOOD
  : > "$home/state/wa-inbox/not a usable id.json"
  chmod 600 "$home/state/wa-inbox/not a usable id.json"

  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending, including MSGGOOD' \
    "one unusable filename silenced the real messages behind it"
  assert_not_contains "$out" 'wa-channel-error' \
    "the announcement was traded for a fault line the skill reads as do-not-read"

  # With nothing usable left there is nothing to announce, so the fault is the
  # right and only thing to say.
  rm -f "$home/state/wa-inbox/MSGGOOD.json" "$home/state/wa-poll.offered"
  out=$(poll "$home")
  assert_contains "$out" 'unusable message id' \
    "an inbox holding only an unusable entry reported nothing at all"

  pass "an unusable inbox entry is skipped, and never buries the messages behind it"
}

test_unpaired_listener_reports_once() {
  local home out
  home="$TMP_ROOT/unpaired"
  new_home "$home"

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "an unpaired listener was not reported"
  assert_contains "$out" 'pair' "the unpaired report did not name the fix"

  out=$(poll "$home")
  [ -z "$out" ] || fail "the same listener fault was reported twice: $out"

  pass "a listener fault is reported once, not on every cycle"
}

test_channel_fault_and_inbox_never_share_a_cycle() {
  local home out
  home="$TMP_ROOT/onefault"
  new_home "$home"
  stash_message "$home" MSGFAULT

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "the listener fault was not reported"
  assert_not_contains "$out" 'wa-message' "a fault cycle also announced the inbox"

  # The fault is deduped, so the pending message is not starved behind it.
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending, including MSGFAULT' \
    "pending messages stayed buried behind a reported fault"
  assert_not_contains "$out" 'wa-channel-error' "the same fault was reported twice"

  pass "a cycle reports either a channel fault or the inbox, never both"
}

test_logged_out_listener_is_reported() {
  local home out
  home="$TMP_ROOT/loggedout"
  new_home "$home"
  # Credentials survive a logout, so pairing alone cannot tell the difference.
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  printf '{"state":"logged-out","at":1}\n' > "$home/state/wa-listener.status"

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "a logged-out listener was never surfaced"
  assert_contains "$out" 'logged out' "the report did not name the logout"
  assert_absent "$home/state/wa-listener.restart" "a logged-out listener was respawned anyway"

  pass "a logged-out device is reported instead of being restarted forever"
}

test_repeated_listener_exits_are_reported() {
  local home out
  home="$TMP_ROOT/flapping"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  printf '3\n' > "$home/state/wa-listener.restarts"

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "a listener that keeps exiting was never surfaced"
  assert_contains "$out" 'will not stay healthy' "the report did not name the repeated exits"

  pass "a listener that dies on every restart is reported rather than respawned forever"
}

test_slow_flap_still_reaches_the_restart_limit() {
  local home
  home="$TMP_ROOT/slowflap"
  new_home "$home"
  fake_listener "$home"
  printf '1\n' > "$home/state/wa-listener.beat"
  # A listener that dies on a period longer than the check interval: alive on
  # this cycle, restarted moments ago, and already twice down.
  printf '2\n' > "$home/state/wa-listener.restarts"
  : > "$home/state/wa-listener.restart"

  poll "$home" >/dev/null
  assert_grep '2' "$home/state/wa-listener.restarts" \
    "one live observation erased a flapping listener's restart history"

  # No restart has been needed for a long stretch, so the listener really is up.
  touch -t 200001010000 "$home/state/wa-listener.restart"
  poll "$home" >/dev/null
  assert_absent "$home/state/wa-listener.restarts" \
    "a listener that stayed up without a restart kept its stale restart history"

  pass "restart history survives a live cycle and clears only after a stable stretch"
}

test_a_refused_restart_says_why_in_the_log() {
  local home bindir waited
  home="$TMP_ROOT/spawnlog"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"

  # A listener wrapper that refuses before the listener can open its own log,
  # the way the real one does with no node or an unusable state directory. The
  # fault line the poll eventually prints names that log, so the reason has to
  # reach it.
  bindir="$TMP_ROOT/spawnlog-bin"
  mkdir -p "$bindir"
  cp "$POLL" "$LIB" "$bindir/"
  cat > "$bindir/fm-wa-listen.sh" <<'SH'
#!/usr/bin/env bash
echo "error: node is required for the WhatsApp listener" >&2
exit 1
SH
  chmod +x "$bindir/fm-wa-listen.sh"

  FM_HOME="$home" "$bindir/fm-wa-poll.sh" >/dev/null 2>&1

  waited=0
  while [ "$waited" -lt 25 ] \
    && ! grep -q 'node is required' "$home/state/wa-listener.log" 2>/dev/null; do
    sleep 0.2
    waited=$(( waited + 1 ))
  done
  assert_grep 'node is required' "$home/state/wa-listener.log" \
    "a restart that never got off the ground left no reason in the log the fault line names"

  pass "a restart refused by the listener wrapper explains itself in the listener log"
}

test_outbound_digests_are_pruned() {
  local home
  home="$TMP_ROOT/sentjanitor"
  new_home "$home"
  fake_listener "$home"
  printf '1\n' > "$home/state/wa-listener.beat"
  mkdir -p "$home/state/wa-sent"
  chmod 700 "$home/state/wa-sent"
  : > "$home/state/wa-sent/aaaa.sent"
  touch -t 200001010000 "$home/state/wa-sent/aaaa.sent"
  : > "$home/state/wa-sent/bbbb.sent"

  poll "$home" >/dev/null

  assert_absent "$home/state/wa-sent/aaaa.sent" \
    "an outbound digest long past the echo window was never pruned"
  assert_present "$home/state/wa-sent/bbbb.sent" \
    "pruning removed a digest that could still match a live echo"

  pass "outbound digests are bounded by the poll, not only by an inbound message"
}

test_dry_run_records_are_pruned() {
  local home
  home="$TMP_ROOT/outboxjanitor"
  new_home "$home"
  fake_listener "$home"
  printf '1\n' > "$home/state/wa-listener.beat"
  mkdir -p "$home/state/wa-outbox"
  chmod 700 "$home/state/wa-outbox"
  : > "$home/state/wa-outbox/1000000000-1.json"
  touch -t 200001010000 "$home/state/wa-outbox/1000000000-1.json"
  : > "$home/state/wa-outbox/1000000001-2.json"

  poll "$home" >/dev/null

  assert_absent "$home/state/wa-outbox/1000000000-1.json" \
    "a long-dead dry-run record was never pruned"
  assert_present "$home/state/wa-outbox/1000000001-2.json" \
    "pruning removed a dry-run record still worth reading back"

  pass "a home standing in dry-run does not grow an unbounded outbox"
}

test_a_spent_restart_block_releases_itself_after_a_while() {
  local home out
  home="$TMP_ROOT/latch"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  printf '3\n' > "$home/state/wa-listener.restarts"

  # A block that was spent moments ago still reports rather than respawning...
  out=$(poll "$home")
  assert_contains "$out" 'will not stay healthy' "a listener that keeps exiting was not reported"
  assert_contains "$out" 'bin/fm-wa-listen.sh restart' \
    "the report did not name the command that releases the block"

  # ...but an hour later the channel gets another chance on its own, so a
  # transient cause does not leave it off until someone happens to look.
  touch -t 200001010000 "$home/state/wa-listener.restarts"
  rm -f "$home/state/wa-listener.error.restart-latch"
  out=$(FM_WA_FORCE_SPAWN_FALLBACK=1 poll "$home")
  assert_not_contains "$out" 'will not stay healthy' \
    "the restart block never released, so the channel stayed off for good"
  assert_present "$home/state/wa-listener.restart" \
    "the released block did not actually retry the listener"

  pass "a spent restart block reports, then retries on its own an hour later"
}

test_a_hand_run_start_releases_the_restart_block() {
  local home fakebin pid
  home="$TMP_ROOT/handstart"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  fakebin=$(fm_fakebin "$TMP_ROOT/handstart")
  # A real listener's command names the program it is running, and the start
  # binds the pid to that command, so the stand-in has to keep it too.
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
exec -a "node $*" sleep 30
SH
  chmod +x "$fakebin/node"

  # The poll's own restart must NOT clear the history, or a listener that dies
  # slowly would erase the very evidence that proves it is flapping.
  printf '3\n' > "$home/state/wa-listener.restarts"
  # A start publishes its pid file before the listener has claimed the status
  # file, so the predecessor's last word has to go with the process that said it.
  printf '{"state":"connected","me":"x","at":1,"deviceHook":"unavailable"}\n' \
    > "$home/state/wa-listener.status"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_AUTOSTART=1 \
    "$LISTEN_SH" start >/dev/null 2>&1 || fail "the fake listener never started"
  assert_grep '3' "$home/state/wa-listener.restarts" \
    "an automatic restart erased the restart history that proves a flap"
  assert_absent "$home/state/wa-listener.status" \
    "a start left the previous listener's reported state for the new one to be judged by"
  pid=$(cat "$home/state/wa-listener.pid" 2>/dev/null) || pid=
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  rm -f "$home/state/wa-listener.pid"

  # A start run by hand is the operator's repair, and releases the block.
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$LISTEN_SH" start >/dev/null 2>&1 || fail "the hand-run listener never started"
  assert_absent "$home/state/wa-listener.restarts" \
    "a start run by hand left the restart block in place"

  # `restart` is what the fault line and the skill actually name, because it is
  # the one that repairs a listener still holding a pid. `start` would only
  # report that one already runs and change nothing.
  printf '3\n' > "$home/state/wa-listener.restarts"
  : > "$home/state/wa-listener.error.restart-latch"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$LISTEN_SH" start >/dev/null 2>&1
  assert_grep '3' "$home/state/wa-listener.restarts" \
    "start repaired a running listener instead of reporting it, so the named remedy is untested"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$LISTEN_SH" restart >/dev/null 2>&1 || fail "restart failed"
  assert_absent "$home/state/wa-listener.restarts" \
    "the remedy the fault line names left the restart block in place"
  assert_absent "$home/state/wa-listener.error.restart-latch" \
    "the remedy the fault line names left the reported fault in place"
  pid=$(cat "$home/state/wa-listener.pid" 2>/dev/null) || pid=
  [ -n "$pid" ] && kill "$pid" 2>/dev/null

  pass "the remedy the fault line names releases the block, and start alone does not"
}

# The watcher signals the whole process group of a check once it returns, so a
# listener spawned into that group is reaped seconds after it starts. Both
# detach paths are exercised, because the fallback is what a host without setsid
# depends on entirely.
assert_restart_survives_the_check_reap() {
  local home=$1 label=$2 bindir pid listener_pid waited
  bindir="$TMP_ROOT/$label-bin"
  mkdir -p "$bindir"
  cp "$POLL" "$LIB" "$bindir/"
  cat > "$bindir/fm-wa-listen.sh" <<SH
#!/usr/bin/env bash
echo \$\$ > "$home/state/fake-listener.pid"
exec sleep 60
SH
  chmod +x "$bindir/fm-wa-listen.sh"

  # Run the poll the way the watcher runs a check: in its own process group,
  # then signal that whole group once it has returned.
  # shellcheck disable=SC2016  # single quotes are deliberate: perl expands its own variables.
  perl -e 'setpgrp(0, 0); exec @ARGV' \
    env FM_HOME="$home" "FM_WA_FORCE_SPAWN_FALLBACK=${3:-0}" \
    bash "$bindir/fm-wa-poll.sh" >/dev/null 2>&1 &
  pid=$!
  wait "$pid" 2>/dev/null || true

  waited=0
  while [ "$waited" -lt 25 ] && [ ! -s "$home/state/fake-listener.pid" ]; do
    sleep 0.2
    waited=$(( waited + 1 ))
  done
  listener_pid=$(cat "$home/state/fake-listener.pid" 2>/dev/null) || listener_pid=
  [ -n "$listener_pid" ] || fail "$label: the poll never restarted the listener"

  kill -TERM -- "-$pid" 2>/dev/null || true
  sleep 0.3
  kill -KILL -- "-$pid" 2>/dev/null || true
  sleep 0.3

  kill -0 "$listener_pid" 2>/dev/null \
    || fail "$label: the watcher reaping the check took the listener with it"
  kill -9 "$listener_pid" 2>/dev/null || true
}

test_a_restarted_listener_survives_the_check_being_reaped() {
  command -v perl >/dev/null 2>&1 || { pass "detach test skipped: perl is unavailable"; return 0; }
  local home
  home="$TMP_ROOT/detach"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  assert_restart_survives_the_check_reap "$home" detach 1

  if command -v setsid >/dev/null 2>&1; then
    home="$TMP_ROOT/detach-setsid"
    new_home "$home"
    mkdir -p "$home/state/wa-auth"
    printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
    assert_restart_survives_the_check_reap "$home" detach-setsid 0
  fi

  pass "a restarted listener outlives the check that started it, with or without setsid"
}

test_stalled_listener_is_reported() {
  local home out pid
  home="$TMP_ROOT/stalled"
  new_home "$home"
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")
  # An alive process whose connection went away long ago.
  printf '1\n' > "$home/state/wa-listener.beat"
  touch -t 200001010000 "$home/state/wa-listener.beat"

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "a live listener with a dead connection looked healthy"
  assert_contains "$out" 'connection is down' "the report did not name the dead connection"

  pass "a running listener whose connection is down is reported, not trusted"
}

test_stalled_listener_is_replaced_not_only_reported() {
  local home out pid
  home="$TMP_ROOT/stallheal"
  new_home "$home"
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")
  printf '1\n' > "$home/state/wa-listener.beat"
  touch -t 200001010000 "$home/state/wa-listener.beat"

  out=$(poll "$home")
  assert_contains "$out" 'restarting it' \
    "a wedged listener was reported without saying it is being replaced"
  if kill -0 "$pid" 2>/dev/null; then
    fail "the wedged listener was left running, so nothing could bring the channel back"
  fi
  assert_absent "$home/state/wa-listener.pid" "the wedged listener's pid record outlived it"
  # The beat belongs to the process that wrote it: left behind, it would make
  # the replacement look wedged on its very first cycle and kill it again.
  assert_absent "$home/state/wa-listener.beat" "the wedged listener's beat outlived it"

  pass "a listener whose connection is down is replaced, not reported forever"
}

# The sender-device filter is the guard that keeps firstmate's own replies out
# of the inbox, and it is fed by a raw stanza hook. A listener that cannot
# attach that hook still connects and still beats, so nothing else in the poll
# would notice that every message from the captain is being thrown away.
# Reporting alone would leave it that way for as long as the socket holds,
# because the hook is only ever attached by a new connection.
test_a_listener_that_cannot_read_sender_devices_is_reported() {
  local home out pid
  home="$TMP_ROOT/nodevicehook"
  new_home "$home"
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")
  date +%s > "$home/state/wa-listener.beat"
  stash_message "$home" MSGHOOK

  printf '{"state":"connected","me":"x","at":1}\n' > "$home/state/wa-listener.status"
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending, including MSGHOOK' \
    "a healthy listener did not reach the inbox announcement"

  printf '{"state":"connected","me":"x","at":2,"deviceHook":"unavailable"}\n' \
    > "$home/state/wa-listener.status"
  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' \
    "a listener that rejects every message looked perfectly healthy"
  assert_contains "$out" 'sender devices' \
    "the report did not name what the listener cannot read"
  assert_contains "$out" 'restarting it' \
    "the fault was reported without saying the listener is being replaced"
  assert_present "$home/state/wa-listener.error.device-hook" \
    "the fault was announced without being recorded"
  if kill -0 "$pid" 2>/dev/null; then
    fail "the deaf listener was left running, so the hook could never be reattached"
  fi
  assert_absent "$home/state/wa-listener.pid" \
    "the deaf listener's pid record outlived it"

  # It clears itself the moment a replacement attaches the hook again, so the
  # captain is not left with a fault that outlives the problem.
  fake_listener "$home"
  date +%s > "$home/state/wa-listener.beat"
  printf '{"state":"connected","me":"x","at":3}\n' > "$home/state/wa-listener.status"
  poll "$home" >/dev/null
  assert_absent "$home/state/wa-listener.error.device-hook" \
    "the fault outlived the listener recovering its sender-device hook"

  pass "a listener that cannot read sender devices is reported and replaced"
}

# The pid file is written at spawn and removed only on a clean exit, so a crash
# leaves it behind and the number in it can later belong to anything this user
# runs. Both repair paths above signal that pid, so it has to be bound to the
# listener this home actually started before anything is sent to it.
test_a_recycled_pid_is_never_signalled() {
  local home out pid
  home="$TMP_ROOT/pidreuse"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  # An unrelated process that happens to hold the number a dead listener left in
  # its pid file. Deliberately NOT a listener: this is the pid-reuse case, and
  # the refusal must not fire for it.
  sleep 300 &
  pid=$!
  FAKE_PIDS="$FAKE_PIDS $pid"
  printf '%s\n' "$pid" > "$home/state/wa-listener.pid"
  printf 'Sat Jan  1 00:00:00 2000\n' > "$home/state/wa-listener.pid-identity"
  # ...and everything that would otherwise make the poll stop it.
  printf '1\n' > "$home/state/wa-listener.beat"
  touch -t 200001010000 "$home/state/wa-listener.beat"
  printf '{"state":"connected","me":"x","at":1,"deviceHook":"unavailable"}\n' \
    > "$home/state/wa-listener.status"
  # Spent, so the cycle reports instead of spawning a listener this test would
  # then have to chase.
  printf '3\n' > "$home/state/wa-listener.restarts"

  out=$(poll "$home")
  kill -0 "$pid" 2>/dev/null \
    || fail "the poll signalled a process it never proved was its own listener"
  assert_not_contains "$out" 'connection is down' \
    "a stranger's pid was reported as the listener's own wedged connection"

  pass "a pid the poll cannot bind to this home's listener is never signalled"
}

# The identity is written by whoever started the listener and read back by
# whoever later checks it, and those two run under whatever environment their
# own caller had. A false mismatch is worse here than a refused stop: the poll
# concludes there is no listener at all and starts a second one onto the single
# credential folder WhatsApp allows, which is the break the binding exists to
# prevent. Timezone, locale and COLUMNS each re-render the ps form of that
# identity, so all three are varied between the write and every read below.
test_a_listener_binding_survives_an_environment_change() {
  local home listener_pid long bound recorded reread no_proc
  home="$TMP_ROOT/identityenv"
  new_home "$home"
  # ps truncates the command column to COLUMNS, so the process this binds to
  # needs a command line long enough for that truncation to be visible at all.
  long="$home/$(printf 'x%.0s' $(seq 1 200))"
  ln -s "$(command -v sleep)" "$long"
  "$long" 300 &
  listener_pid=$!
  FAKE_PIDS="$FAKE_PIDS $listener_pid"
  printf '%s\n' "$listener_pid" > "$home/state/wa-listener.pid"
  ( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    TZ=UTC LC_ALL=C COLUMNS=200 FM_WA_STATE="$home/state" \
      fm_wa_record_listener_identity "$listener_pid" ) >/dev/null 2>&1 \
    || fail "the identity of a running process was not recorded"
  recorded=$(cat "$home/state/wa-listener.pid-identity")

  reread=$( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    TZ=America/New_York LC_ALL=en_US.UTF-8 COLUMNS=40 FM_WA_STATE="$home/state" \
      fm_wa_process_identity "$listener_pid" )
  [ "$reread" = "$recorded" ] \
    || fail "the same live process rendered a different identity under another environment"

  bound=$( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    FM_HOME="$home"
    fm_wa_paths
    TZ=America/New_York LC_ALL=en_US.UTF-8 COLUMNS=40 fm_wa_listener_pid ) || bound=
  [ "$bound" = "$listener_pid" ] \
    || fail "a live listener stopped being its own recorded identity under another environment"

  # On a host without a readable /proc - macOS, which this channel supports -
  # the identity falls back to ps, which is the form that renders the date in
  # the caller's own zone and locale and cuts the command at the caller's
  # COLUMNS. Everything above passes on Linux without ever reaching it, so the
  # fallback is pinned here in its own right.
  no_proc="$home/no-proc"
  mkdir -p "$no_proc"
  rm -f "$home/state/wa-listener.pid-identity"
  ( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    FM_PROC_ROOT_OVERRIDE="$no_proc" TZ=UTC LC_ALL=C COLUMNS=200 FM_WA_STATE="$home/state" \
      fm_wa_record_listener_identity "$listener_pid" ) >/dev/null 2>&1 \
    || fail "a host without /proc recorded no identity for a running process"
  grep -q 'starttime=' "$home/state/wa-listener.pid-identity" \
    && fail "the no-/proc case never exercised the ps fallback it exists to pin"
  recorded=$(cat "$home/state/wa-listener.pid-identity")
  case "$recorded" in
    *xxxxxxxxxx*) ;;
    *) fail "the recorded identity carries no command, so truncation could never show" ;;
  esac

  reread=$( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    FM_PROC_ROOT_OVERRIDE="$no_proc" TZ=America/New_York LC_ALL=en_US.UTF-8 COLUMNS=40 \
      FM_WA_STATE="$home/state" fm_wa_process_identity "$listener_pid" )
  [ "$reread" = "$recorded" ] \
    || fail "without /proc, the environment changed how the same process renders its identity"

  bound=$( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    FM_HOME="$home"
    fm_wa_paths
    FM_PROC_ROOT_OVERRIDE="$no_proc" TZ=America/New_York LC_ALL=en_US.UTF-8 COLUMNS=40 \
      fm_wa_listener_pid ) || bound=
  [ "$bound" = "$listener_pid" ] \
    || fail "without /proc, a live listener stopped being its own identity under another environment"

  pass "a listener stays bound to its own identity across an environment change"
}

# The pid file appears the instant a replacement forks, well before that process
# has loaded enough to claim the status file. A predecessor's last status left in
# place is then read as the replacement's own, and the replacement is killed for
# a fault it never had - burning a slot of the restart budget every time.
test_a_replacement_is_not_judged_by_its_predecessor() {
  local home pid
  home="$TMP_ROOT/staleclaim"
  new_home "$home"
  fake_listener "$home"
  date +%s > "$home/state/wa-listener.beat"
  printf '{"state":"connected","me":"x","at":1,"deviceHook":"unavailable"}\n' \
    > "$home/state/wa-listener.status"

  poll "$home" >/dev/null
  assert_absent "$home/state/wa-listener.status" \
    "the deaf listener's reported state outlived the process that wrote it"

  # A replacement that is up but has not written its own status yet.
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")
  date +%s > "$home/state/wa-listener.beat"
  poll "$home" >/dev/null
  kill -0 "$pid" 2>/dev/null \
    || fail "a healthy replacement was stopped for its predecessor's fault"

  pass "a replacement listener is never judged by its predecessor's record"
}

test_a_skipped_entry_is_reported_on_a_quiet_cycle() {
  local home out
  home="$TMP_ROOT/badnamesaid"
  new_home "$home"
  fake_listener "$home"
  printf '1\n' > "$home/state/wa-listener.beat"
  stash_message "$home" MSGSAID
  : > "$home/state/wa-inbox/not a usable id.json"
  chmod 600 "$home/state/wa-inbox/not a usable id.json"

  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending, including MSGSAID' \
    "the announcement did not win its own cycle"

  # The set is unchanged, so this cycle has nothing to announce and is where the
  # skipped entry gets said - once, not on every cycle after it.
  out=$(poll "$home")
  assert_contains "$out" 'unusable message id' \
    "a skipped inbox entry was never reported at all"
  out=$(poll "$home")
  [ -z "$out" ] || fail "the skipped entry was reported again on the next cycle: $out"

  pass "an entry the poll had to skip is reported once, without burying the messages"
}

test_listener_that_never_connects_is_reported() {
  local home out
  home="$TMP_ROOT/nevercame"
  new_home "$home"
  fake_listener "$home"
  # No beat at all: a listener that started but never got a connection up. Its
  # own start time is how long the channel has been down.
  touch -t 200001010000 "$home/state/wa-listener.pid"

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "a listener that never connected looked healthy"
  assert_contains "$out" 'never come up' "the report did not name the connection that never came up"

  # A listener started moments ago has no beat either, and must be given the
  # same grace a working one gets between beats.
  rm -f "$home/state/wa-listener.error"
  touch "$home/state/wa-listener.pid"
  out=$(poll "$home")
  [ -z "$out" ] || fail "a listener that has just started was reported as faulty: $out"

  pass "a listener whose connection never came up is reported, not trusted"
}

test_repairing_the_link_clears_stale_listener_health() {
  command -v node >/dev/null 2>&1 || { pass "re-pairing check skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/repair"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  # The wreckage of the old link: logged out, and out of restart attempts.
  printf '{"state":"logged-out"}\n' > "$home/state/wa-listener.status"
  printf '3\n' > "$home/state/wa-listener.restarts"
  : > "$home/state/wa-listener.restart"
  printf 'stale\n' > "$home/state/wa-listener.error"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" unpair 2>&1) \
    || fail "unpair failed: $out"
  assert_absent "$home/state/wa-listener.status" "unpair left the old link's connection state behind"
  assert_absent "$home/state/wa-listener.restarts" "unpair left the old link's restart count behind"
  assert_absent "$home/state/wa-listener.restart" "unpair left the old link's restart marker behind"
  assert_absent "$home/state/wa-listener.error" "unpair left the old link's fault behind"

  out=$(poll "$home")
  assert_contains "$out" 'not paired' "the poll did not name the missing pairing after unpair"
  assert_not_contains "$out" 'logged out' "the poll still reported the removed link as logged out"
  assert_not_contains "$out" 'will not stay healthy' "the poll still reported the removed link's restart count"

  pass "unpairing clears the old link's health, so the poll names the real next step"
}

test_listener_state_growth_is_bounded() {
  local home before after i
  home="$TMP_ROOT/janitor"
  new_home "$home"
  fake_listener "$home"
  printf '1\n' > "$home/state/wa-listener.beat"
  mkdir -p "$home/state/wa-seen"
  chmod 700 "$home/state/wa-seen"
  printf 'handled long ago\n' > "$home/state/wa-seen/OLDMSG.seen"
  touch -t 200001010000 "$home/state/wa-seen/OLDMSG.seen"
  printf 'handled just now\n' > "$home/state/wa-seen/NEWMSG.seen"
  i=1
  while [ "$i" -le 6000 ]; do
    printf 'listener line %s padding padding padding padding padding padding\n' "$i"
    i=$(( i + 1 ))
  done > "$home/state/wa-listener.log"
  before=$(wc -c < "$home/state/wa-listener.log" | tr -d '[:space:]')

  poll "$home" >/dev/null

  after=$(wc -c < "$home/state/wa-listener.log" | tr -d '[:space:]')
  [ "$after" -lt "$before" ] || fail "the listener log grew past its cap unchecked ($after bytes)"
  assert_grep 'listener line 6000' "$home/state/wa-listener.log" "capping the log dropped its newest lines"
  assert_absent "$home/state/wa-seen/OLDMSG.seen" "a long-expired handled-message marker was never pruned"
  assert_present "$home/state/wa-seen/NEWMSG.seen" "pruning removed a marker that still guards against redelivery"

  pass "the listener log and its handled-message markers are both bounded"
}

# --- the check shim ---------------------------------------------------------

test_shim_arm_register_disarm() {
  local home out
  home="$TMP_ROOT/shim"
  new_home "$home"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm 2>&1) \
    || fail "arm failed: $out"
  assert_present "$home/state/wa-watch.check.sh" "arm did not write the check shim"
  assert_present "$home/state/wa-watch.check-trust" "arm did not register the check shim"

  # The watcher validates a custom check against its registration before running
  # it; prove the real validator accepts what arm produced.
  ( . "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-check-lib.sh"
    fm_custom_check_registered "$home/state" wa-watch ) \
    || fail "the watcher's own validator rejected the armed check"

  # And that an edit disarms it until re-registered.
  printf '# tampered\n' >> "$home/state/wa-watch.check.sh"
  if ( . "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-check-lib.sh"
       fm_custom_check_registered "$home/state" wa-watch ); then
    fail "an edited check shim stayed trusted"
  fi

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 \
    || fail "re-arm failed"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" disarm 2>&1) \
    || fail "disarm failed: $out"
  assert_absent "$home/state/wa-watch.check.sh" "disarm left the check shim behind"
  assert_absent "$home/state/wa-watch.check-trust" "disarm left the registration behind"

  pass "the check shim arms through the ordinary registration and disarms cleanly"
}

test_arming_makes_an_idle_home_need_supervision() {
  local home
  home="$TMP_ROOT/supneed"
  new_home "$home"

  # An idle home with the channel off arms no watcher, and must keep behaving
  # exactly that way.
  ( . "$ROOT/bin/fm-supervision-lib.sh"
    fm_supervision_needed "$home/state" 300 ) \
    && fail "a home with the channel off was counted as needing supervision"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 \
    || fail "arm failed"

  # The captain messages precisely when nothing is running, so an armed channel
  # alone has to keep a watcher up or the poll never runs at all.
  ( . "$ROOT/bin/fm-supervision-lib.sh"
    fm_supervision_needed "$home/state" 300 ) \
    || fail "an armed inbound channel did not keep an idle home supervised"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" disarm >/dev/null 2>&1 \
    || fail "disarm failed"
  ( . "$ROOT/bin/fm-supervision-lib.sh"
    fm_supervision_needed "$home/state" 300 ) \
    && fail "a disarmed home was still counted as needing supervision"

  pass "an armed channel keeps an idle home supervised, and only while it is armed"
}

# The primary harnesses that decide for themselves when to arm each carry their
# own copy of the "does this home need a watcher" question. An armed channel is
# a supervision reason in bin/fm-supervision-lib.sh, so a primary that misses it
# leaves the captain's messages sitting in the inbox with nothing to announce
# them.
test_every_primary_arms_for_an_armed_channel() {
  local home probe out
  home="$TMP_ROOT/primaryarm"
  new_home "$home"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 \
    || fail "arm failed"

  if ! command -v node >/dev/null 2>&1; then
    pass "an armed channel is a supervision reason on every self-arming primary (skipped: no node)"
    return
  fi

  # The predicate is private to the plugin, so it is lifted out and answered
  # directly rather than by driving a whole OpenCode session.
  probe="$home/shouldarm.mjs"
  cat > "$probe" <<'PROBE'
import fs from 'node:fs'
const [file, state, config] = process.argv.slice(2)
const src = fs.readFileSync(file, 'utf8')
const body = src.match(/function shouldArm\(paths\) \{[\s\S]*?\n\}/)
if (!body) { process.stderr.write('no shouldArm in the OpenCode plugin\n'); process.exit(1) }
const shouldArm = new Function('existsSync', 'readdirSync', `${body[0]}; return shouldArm`)(fs.existsSync, fs.readdirSync)
process.stdout.write(String(shouldArm({ state, config })))
PROBE

  out=$(node "$probe" "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" \
    "$home/state" "$home/config" 2>&1) \
    || fail "could not evaluate the OpenCode arm predicate: $out"
  [ "$out" = true ] \
    || fail "the OpenCode primary would not arm a watcher for an armed channel"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" disarm >/dev/null 2>&1 \
    || fail "disarm failed"
  out=$(node "$probe" "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" \
    "$home/state" "$home/config" 2>&1) \
    || fail "could not evaluate the OpenCode arm predicate: $out"
  [ "$out" = false ] \
    || fail "the OpenCode primary would arm a watcher for a home with nothing to watch"

  pass "an armed channel is a supervision reason on every self-arming primary"
}

# The cadence is only worth generating if the process that launches the watcher
# actually inherits it, so every primary that builds its own arm command has to
# source it exactly as it sources Relay's.
test_every_primary_arm_command_sources_the_cadence() {
  local home cmd out
  home="$TMP_ROOT/primarycadence"
  mkdir -p "$home/config"
  printf 'export FM_CHECK_INTERVAL=30\n' > "$home/config/wa-mode.env"
  cat > "$home/arm.sh" <<'ARM'
#!/usr/bin/env bash
printf 'interval=%s\n' "${FM_CHECK_INTERVAL:-unset}"
ARM
  chmod +x "$home/arm.sh"

  for cmd in \
    "$(sed -n "s/.*spawn(\"bash\", \[\"-lc\", '\(config_dir=.*--restart\)'.*/\1/p" \
        "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" | head -n 1)" \
    "$(sed -n 's/.*spawn("bash", \["-lc", "\(config_dir=.*--restart\)".*/\1/p' \
        "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" | head -n 1 | sed 's/\\"/"/g')"
  do
    [ -n "$cmd" ] || fail "could not read a primary's arm command"
    cmd=${cmd//\"\$FM_ROOT_OVERRIDE\/bin\/fm-watch-arm.sh\"/\"\$FM_WATCH_ARM_SCRIPT\"}
    out=$(FM_CONFIG_OVERRIDE="$home/config" FM_HOME="$home" \
      FM_WATCH_ARM_SCRIPT="$home/arm.sh" bash -c "$cmd" 2>/dev/null)
    assert_contains "$out" 'interval=30' \
      "a primary's arm command did not source the generated cadence: $cmd"
  done

  pass "every primary's arm command inherits the generated cadence"
}

test_arming_writes_the_watcher_cadence() {
  local home out
  home="$TMP_ROOT/cadence"
  new_home "$home"
  assert_absent "$home/config/wa-mode.env" "a home that never armed already had a cadence file"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm 2>&1) || fail "arm failed: $out"
  assert_present "$home/config/wa-mode.env" "arm did not write the watcher cadence"
  assert_contains "$(cat "$home/config/wa-mode.env")" 'FM_CHECK_INTERVAL=30' \
    "the cadence file does not speed the watcher up"
  # Sourced, never executed, and private to this home.
  local mode
  mode=$(stat -c %a "$home/config/wa-mode.env" 2>/dev/null \
    || stat -f %Lp "$home/config/wa-mode.env" 2>/dev/null)
  [ "$mode" = 600 ] || fail "the cadence file is not private: $mode"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" status 2>&1)
  assert_contains "$out" 'cadence: present' "status did not report the armed cadence"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" disarm 2>&1) || fail "disarm failed: $out"
  assert_absent "$home/config/wa-mode.env" "disarm left the cadence file behind"

  pass "arming writes the 30s watcher cadence and disarming removes it"
}

test_the_cadence_reaches_the_supervision_block() {
  local home out
  home="$TMP_ROOT/cadenceblock"
  new_home "$home"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness codex 2>&1)
  assert_not_contains "$out" "$home/config/wa-mode.env" \
    "an unarmed home was told to source a cadence file it does not have"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness codex 2>&1)
  assert_contains "$out" "$home/config/wa-mode.env" \
    "the emitted supervision block never names the generated cadence"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness codex --repair-line 2>&1)
  assert_contains "$out" "source '$home/config/wa-mode.env' first" \
    "the repair line does not carry the cadence into a re-armed watcher"

  pass "the generated cadence is sourced the same way Relay's is"
}

test_stop_says_the_armed_check_restarts_it() {
  local home out
  home="$TMP_ROOT/stopnote"
  new_home "$home"
  fake_listener "$home"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" stop 2>&1)
  assert_not_contains "$out" 'disarm' "an unarmed home was told to disarm something"

  fake_listener "$home"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" stop 2>&1)
  assert_contains "$out" 'disarm' \
    "stop did not say the armed check brings the listener straight back"

  pass "stopping the listener says plainly that an armed check restarts it"
}

test_shim_runs_the_poll_the_way_the_watcher_does() {
  local home out
  home="$TMP_ROOT/shimrun"
  new_home "$home"
  fake_listener "$home"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 \
    || fail "arm failed"
  stash_message "$home" MSGSHIM

  # fm-watch.sh snapshots the shim and runs it as `bash <snapshot>`.
  out=$( . "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-check-lib.sh"
         fm_custom_check_snapshot_prepare "$home/state" wa-watch || exit 1
         bash "$FM_CUSTOM_CHECK_SNAPSHOT"
         fm_custom_check_snapshot_cleanup )
  assert_contains "$out" 'wa-message 1 pending, including MSGSHIM' \
    "the shim did not produce a wake line through the watcher's own execution path"

  pass "the watcher's snapshot-and-run path reaches the poll and gets one wake line"
}

# --- the send path ----------------------------------------------------------

test_dry_run_records_and_sends_nothing() {
  local home out record
  home="$TMP_ROOT/dryrun"
  new_home "$home"
  printf 'Captain, the fix is up: https://example.invalid/pull/1\n' > "$TMP_ROOT/reply.txt"

  # A mudslide that fails loudly proves the dry run never reaches it.
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/dryrun-bin")
  cat > "$fakebin/mudslide" <<'SH'
#!/usr/bin/env bash
echo "mudslide was called" >&2
exit 1
SH
  chmod +x "$fakebin/mudslide"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_WA_DRY_RUN=1 "$SEND" --text-file "$TMP_ROOT/reply.txt" 2>&1) \
    || fail "dry-run send failed: $out"
  assert_contains "$out" 'dry-run' "the dry run did not announce itself"
  assert_not_contains "$out" 'mudslide was called' "the dry run reached mudslide"

  record=$(find "$home/state/wa-outbox" -name '*.json' -type f | head -n 1)
  [ -n "$record" ] || fail "the dry run recorded nothing to state/wa-outbox"
  assert_grep 'example.invalid/pull/1' "$record" "the outbox record lost the reply text"
  [ -n "$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null)" ] \
    || fail "the dry run recorded no echo marker"

  pass "FM_WA_DRY_RUN records the reply and transmits nothing"
}

test_json_encoder_round_trips_hostile_text() {
  command -v node >/dev/null 2>&1 || { pass "JSON encoder check skipped: node is unavailable"; return 0; }
  local encoded decoded
  # Every character class a JSON string has to escape, plus multi-byte UTF-8
  # that must survive untouched.
  printf 'quote " backslash \\ tab\tcontrol \001 caf\xc3\xa9\nsecond line' \
    > "$TMP_ROOT/encoder-input.txt"

  # shellcheck source=bin/fm-wa-lib.sh
  encoded=$( . "$LIB"; fm_wa_json_string < "$TMP_ROOT/encoder-input.txt" )
  decoded=$(printf '%s' "$encoded" | node -e '
    const chunks = []
    process.stdin.on("data", (c) => chunks.push(c))
    process.stdin.on("end", () => {
      const value = JSON.parse(Buffer.concat(chunks).toString("utf8"))
      if (typeof value !== "string") { process.stderr.write("not a JSON string\n"); process.exit(1) }
      process.stdout.write(value)
    })
  ') || fail "bin/fm-wa-lib.sh produced text that is not a JSON string"
  [ "$decoded" = "$(cat "$TMP_ROOT/encoder-input.txt")" ] \
    || fail "the JSON encoder did not round-trip the text it was given"

  pass "the JSON encoder in bin/fm-wa-lib.sh escapes what JSON requires and nothing else"
}

test_dry_run_record_is_valid_json() {
  command -v node >/dev/null 2>&1 || { pass "dry-run JSON check skipped: node is unavailable"; return 0; }
  local home record decoded fakebin
  home="$TMP_ROOT/dryrunjson"
  new_home "$home"
  # Quotes, a backslash, a tab, a line break and non-ASCII: everything a record
  # named .json has to survive.
  printf 'he said "go" \\ now\tstill\nsecond line caf\xc3\xa9\n' > "$TMP_ROOT/tricky.txt"

  # A jq that fails proves the encoding never depended on it.
  fakebin=$(fm_fakebin "$TMP_ROOT/dryrunjson-bin")
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/jq"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/tricky.txt" >/dev/null 2>&1 \
    || fail "the dry-run send failed"

  record=$(find "$home/state/wa-outbox" -name '*.json' -type f | head -n 1)
  [ -n "$record" ] || fail "the dry run recorded nothing to state/wa-outbox"
  decoded=$(node -e '
    const fs = require("fs")
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
    if (r.schema !== "fm-wa-outbox-v1") { process.stderr.write("wrong schema\n"); process.exit(1) }
    if (r.dry_run !== true) { process.stderr.write("not marked dry-run\n"); process.exit(1) }
    process.stdout.write(r.text)
  ' "$record") || fail "the dry-run record is not valid fm-wa-outbox-v1 JSON"
  [ "$decoded" = "$(cat "$TMP_ROOT/tricky.txt")" ] \
    || fail "the dry-run record did not carry the reply text back unchanged"

  pass "a dry-run record is valid JSON that round-trips the reply, with or without jq"
}

test_message_text_is_never_executed() {
  local home out record
  home="$TMP_ROOT/injection"
  new_home "$home"
  # Text a naive implementation would let the shell re-parse.
  # shellcheck disable=SC2016  # the unexpanded expression IS the payload.
  printf '%s\n' 'hi $(touch '"$TMP_ROOT"'/pwned) `touch '"$TMP_ROOT"'/pwned2` ; rm -rf /' \
    > "$TMP_ROOT/hostile.txt"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/hostile.txt" 2>&1) \
    || fail "send of hostile text failed: $out"
  assert_absent "$TMP_ROOT/pwned" "command substitution in message text executed"
  assert_absent "$TMP_ROOT/pwned2" "backticks in message text executed"
  record=$(find "$home/state/wa-outbox" -name '*.json' -type f | head -n 1)
  assert_grep 'rm -rf' "$record" "the hostile text was not preserved verbatim as data"

  pass "message text is carried as data and never re-parsed by a shell"
}

test_config_is_read_as_data() {
  local home out
  home="$TMP_ROOT/configdata"
  mkdir -p "$home/state" "$home/config"
  # shellcheck disable=SC2016  # the unexpanded substitution IS the payload.
  printf 'FM_WA_CAPTAIN=%s\nFM_WA_ALLOW_DEVICES=$(touch %s/config-pwned)0\n' \
    "$CAPTAIN" "$TMP_ROOT" > "$home/config/whatsapp.env"
  out=$(poll "$home")
  assert_absent "$TMP_ROOT/config-pwned" "config/whatsapp.env was sourced rather than read"
  pass "config/whatsapp.env is parsed as data, never sourced"
}

# --- the listener's accept and reject rules ---------------------------------

# The listener only ever runs paired, and its OWN credentials are what tell it
# which chat is its own chat with itself as opposed to a conversation with
# somebody else. A fixture home without them is not a listener any real message
# ever reaches, so every fixture below drives a paired one.
#
# A second argument writes `me.lid` as well, which is the field a real paired
# account carries and the only thing that identifies a LID-addressed self-chat
# without pinning the test-only FM_WA_SELF_LID. Fixtures that must prove a LID
# chat on the resolved number alone leave it out.
pair_fixture_home() {
  local home=$1 lid=${2:-}
  mkdir -p "$home/state/wa-auth"
  chmod 700 "$home/state/wa-auth" 2>/dev/null || true
  if [ -n "$lid" ]; then
    printf '{"registered":true,"me":{"id":"%s:0@s.whatsapp.net","lid":"%s:0@lid"}}\n' \
      "$CAPTAIN" "$lid" > "$home/state/wa-auth/creds.json"
  else
    printf '{"registered":true,"me":{"id":"%s:0@s.whatsapp.net"}}\n' "$CAPTAIN" \
      > "$home/state/wa-auth/creds.json"
  fi
}

fixture() {
  local home=$1 body=$2
  pair_fixture_home "$home"
  printf '%s' "$body" | FM_WA_STATE="$home/state" FM_WA_AUTH_DIR="$home/state/wa-auth" \
    FM_WA_CAPTAIN="$CAPTAIN" FM_WA_ALLOW_DEVICES=0 \
    node "$LISTENER" handle-fixture 2>/dev/null
}

# Every fixture gets its own later timestamp. A shared one would let the history
# watermark short-circuit each case before the rule it names is ever reached, so
# the assertions below would pass for the wrong reason.
# The counter lives in a file because msg() is called inside a command
# substitution, and a shell variable bumped there would never reach the caller.
FIXTURE_TS_FILE="$TMP_ROOT/fixture-ts"
printf '2000000000\n' > "$FIXTURE_TS_FILE"
next_ts() {
  local n
  n=$(cat "$FIXTURE_TS_FILE" 2>/dev/null) || n=2000000000
  n=$(( n + 1 ))
  printf '%s\n' "$n" > "$FIXTURE_TS_FILE"
  printf '%s' "$n"
}

msg() {
  # msg <id> <device> <chat-jid> <from-me> <inner-json> [<timestamp>]
  printf '{"stanza_from":"%s:%s@s.whatsapp.net","message":{"key":{"id":"%s","remoteJid":"%s","fromMe":%s},"messageTimestamp":%s,"message":%s}}' \
    "$CAPTAIN" "$2" "$1" "$3" "$4" "${6:-$(next_ts)}" "$5"
}

# The listener logs its reason on the same stream as the verdict, so a refusal
# can be pinned to the rule that produced it rather than to REJECTED alone.
assert_refused() {
  local out=$1 reason=$2 what=$3
  assert_contains "$out" 'REJECTED' "$what"
  assert_contains "$out" "ignored ($reason)" \
    "$what: refused for the wrong reason, output was: $out"
}

test_listener_filters() {
  command -v node >/dev/null 2>&1 || { pass "listener filters skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/filters"
  new_home "$home"

  out=$(fixture "$home" "$(msg CAPMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"ship the fix"}')")
  assert_contains "$out" 'ACCEPTED' "a message from the captain's own phone was refused"
  assert_grep '"sender_device": 0' "$home/state/wa-inbox/CAPMSG.json" \
    "the stashed record lost the sending device"
  assert_grep 'ship the fix' "$home/state/wa-inbox/CAPMSG.json" \
    "the stashed record lost the message text"

  out=$(fixture "$home" "$(msg ECHOMSG 2 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, the PR is up"}')")
  assert_refused "$out" 'device 2 is not an accepted captain device' \
    "firstmate's own outbound echo was ingested as an instruction"

  out=$(fixture "$home" "$(msg GRPMSG 0 '99-88@g.us' true '{"conversation":"in a group"}')")
  assert_refused "$out" "not the captain's direct chat" "a group message was ingested"

  out=$(fixture "$home" "$(msg FWDMSG 0 "$CAPTAIN@s.whatsapp.net" true \
    '{"extendedTextMessage":{"text":"do this","contextInfo":{"isForwarded":true,"forwardingScore":3}}}')")
  assert_refused "$out" 'forwarded message' "a forwarded message was ingested"

  out=$(fixture "$home" "$(printf '{"stanza_from":"447111111111:0@s.whatsapp.net","message":{"key":{"id":"OTHERMSG","remoteJid":"447111111111@s.whatsapp.net","fromMe":false},"messageTimestamp":%s,"message":{"conversation":"hi"}}}' "$(next_ts)")")
  assert_refused "$out" "not the captain's direct chat" \
    "a message from someone other than the captain was ingested"

  out=$(fixture "$home" "$(msg EMPTYMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"   "}')")
  assert_refused "$out" 'no text to act on' "an empty message was stashed"

  # A voice note with no caption is still the captain reaching out, and silence
  # on his phone reads as being ignored.
  out=$(fixture "$home" "$(msg VOICEMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"audioMessage":{"ptt":true,"seconds":7}}')")
  assert_contains "$out" 'ACCEPTED' "a caption-less voice note was silently discarded"
  assert_grep '"attachment": "audio"' "$home/state/wa-inbox/VOICEMSG.json" \
    "the stashed voice note did not name what kind of attachment it was"
  assert_grep '"text": ""' "$home/state/wa-inbox/VOICEMSG.json" \
    "the stashed voice note did not record that it carried no text"

  # Only history is older than the watermark; a second message in the same
  # second as an accepted one is a new instruction, not a redelivery.
  local same_second
  same_second=$(next_ts)
  out=$(fixture "$home" "$(msg SAMESEC1 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"first"}' "$same_second")")
  assert_contains "$out" 'ACCEPTED' "a fresh message was refused"
  out=$(fixture "$home" "$(msg SAMESEC2 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"and also this"}' "$same_second")")
  assert_contains "$out" 'ACCEPTED' "a second message in the same second was silently dropped"

  out=$(fixture "$home" "$(msg OLDMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"ancient"}' 1000000000)")
  assert_refused "$out" 'older than the history watermark' "backlog older than the watermark was ingested"

  pass "the listener accepts only the captain's own device on his own direct chat"
}

test_listener_is_idempotent() {
  command -v node >/dev/null 2>&1 || { pass "listener idempotence skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/idempotent"
  new_home "$home"

  local repeat_ts
  repeat_ts=$(next_ts)
  out=$(fixture "$home" "$(msg REPEATMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"once"}' "$repeat_ts")")
  assert_contains "$out" 'ACCEPTED' "the first delivery was refused"

  # Firstmate drains it, then WhatsApp redelivers the same message. The refusal
  # must come from the durable marker, not from the history watermark.
  rm -f "$home/state/wa-inbox/REPEATMSG.json"
  out=$(fixture "$home" "$(msg REPEATMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"once"}' "$repeat_ts")")
  assert_refused "$out" 'already handled' "a drained message was offered a second time"
  assert_absent "$home/state/wa-inbox/REPEATMSG.json" "a drained message was rebuilt in the inbox"

  pass "a handled message is never re-offered, even after the inbox entry is cleared"
}

test_listener_captures_quoted_context() {
  command -v node >/dev/null 2>&1 || { pass "quoted context skipped: node is unavailable"; return 0; }
  local home out record
  home="$TMP_ROOT/quoted"
  new_home "$home"

  out=$(fixture "$home" "$(msg QUOTEMSG 0 "$CAPTAIN@s.whatsapp.net" true \
    '{"extendedTextMessage":{"text":"yes do that","contextInfo":{"stanzaId":"EARLIER","quotedMessage":{"conversation":"shall I merge it?"}}}}')")
  assert_contains "$out" 'ACCEPTED' "a reply with quoted context was refused"
  record="$home/state/wa-inbox/QUOTEMSG.json"
  assert_grep 'shall I merge it' "$record" "the quoted message was dropped"
  assert_grep 'EARLIER' "$record" "the quoted message id was dropped"

  pass "a reply carries the message it replied to"
}

test_stale_echo_marker_does_not_swallow_the_captain() {
  command -v node >/dev/null 2>&1 || { pass "stale echo guard skipped: node is unavailable"; return 0; }
  local home out marker
  home="$TMP_ROOT/staleecho"
  new_home "$home"
  printf 'on it\n' > "$TMP_ROOT/stale-reply.txt"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/stale-reply.txt" >/dev/null 2>&1 \
    || fail "recording the outbound reply failed"
  marker=$(find "$home/state/wa-sent" -name '*.sent' -type f | head -n 1)
  [ -n "$marker" ] || fail "no echo marker was recorded"

  # An echo comes back in seconds. This one never did, so it is not an echo and
  # must not swallow the captain typing those same words much later.
  touch -t 200001010000 "$marker"
  out=$(fixture "$home" "$(msg STALEECHO 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"on it"}')")
  assert_contains "$out" 'ACCEPTED' "a stale outbound digest swallowed the captain's own words"
  assert_absent "$marker" "the stale digest was left behind to trap those words again"

  pass "an outbound digest the captain never echoed expires instead of trapping his words"
}

test_failed_send_leaves_no_echo_trap() {
  local home out
  home="$TMP_ROOT/failedsend"
  new_home "$home"
  printf 'this never left the building\n' > "$TMP_ROOT/failed-reply.txt"
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/failedsend-bin")
  cat > "$fakebin/mudslide" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/mudslide"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/failed-reply.txt" 2>&1) \
    && fail "a failing mudslide reported success: $out"

  [ -z "$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null)" ] \
    || fail "a send that never went out left an echo marker behind"

  pass "a failed send leaves no digest to suppress the captain saying the same thing"
}

# mudslide parses its own arguments with commander, so a reply that opens with
# a dash is read as an unknown option and never reaches the captain unless
# option parsing is ended first.
test_a_dash_leading_reply_still_reaches_the_send() {
  local home out argv fakebin
  home="$TMP_ROOT/dashsend"
  new_home "$home"
  printf -- '- PR is up: https://example.invalid/pr/1\n' > "$TMP_ROOT/dash-reply.txt"
  fakebin=$(fm_fakebin "$TMP_ROOT/dashsend-bin")
  argv="$TMP_ROOT/dashsend-argv"
  cat > "$fakebin/mudslide" <<'SH'
#!/usr/bin/env bash
# Stands in for mudslide's commander parser: a dash-leading argument is an
# option until `--` ends option parsing.
ended=0
args=()
for a in "$@"; do
  if [ "$ended" -eq 0 ] && [ "$a" = "--" ]; then ended=1; continue; fi
  if [ "$ended" -eq 0 ]; then
    case "$a" in
      -*) echo "error: unknown option '$a'" >&2; exit 1 ;;
    esac
  fi
  args+=("$a")
done
printf '%s\n' "${args[@]}" > "$FAKE_MUDSLIDE_ARGV"
SH
  chmod +x "$fakebin/mudslide"

  out=$(PATH="$fakebin:$PATH" FAKE_MUDSLIDE_ARGV="$argv" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" "$SEND" --text-file "$TMP_ROOT/dash-reply.txt" 2>&1) \
    || fail "a reply beginning with a dash was never sent: $out"

  [ -f "$argv" ] || fail "the send never reached mudslide"
  assert_contains "$(tail -n 1 "$argv")" '- PR is up: https://example.invalid/pr/1' \
    "the dash-leading reply did not arrive as message text"

  pass "a reply beginning with a dash reaches the send instead of being read as an option"
}

# A reply that never arrives is the one failure this channel cannot afford, so
# the send must say what mudslide said rather than only that it failed.
test_a_failed_send_says_why() {
  local home out fakebin
  home="$TMP_ROOT/sendwhy"
  new_home "$home"
  printf 'this never left the building\n' > "$TMP_ROOT/sendwhy-reply.txt"
  fakebin=$(fm_fakebin "$TMP_ROOT/sendwhy-bin")
  cat > "$fakebin/mudslide" <<'SH'
#!/usr/bin/env bash
echo "error: not logged in, run mudslide login" >&2
exit 1
SH
  chmod +x "$fakebin/mudslide"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/sendwhy-reply.txt" 2>&1) \
    && fail "a failing mudslide reported success: $out"

  assert_contains "$out" 'not logged in' "the failed send discarded the reason it failed"

  pass "a failed reply reports what mudslide said, not just that it failed"
}

test_failed_dry_run_leaves_no_echo_trap() {
  local home out
  home="$TMP_ROOT/faileddry"
  new_home "$home"
  printf 'this was never even going to be sent\n' > "$TMP_ROOT/faileddry-reply.txt"
  # An outbox that cannot be written to: nothing is recorded, so nothing can
  # echo back, and the marker must not survive to swallow those exact words.
  : > "$home/state/wa-outbox"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/faileddry-reply.txt" 2>&1) \
    && fail "a dry run that recorded nothing reported success: $out"

  [ -z "$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null)" ] \
    || fail "a dry run that recorded nothing left an echo marker behind"

  pass "a dry run that could not record leaves no digest to swallow the captain"
}

test_echo_digest_guard() {
  command -v node >/dev/null 2>&1 || { pass "echo guard skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/echoguard"
  new_home "$home"
  printf 'Captain, that is done.\n' > "$TMP_ROOT/echo-reply.txt"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/echo-reply.txt" >/dev/null 2>&1 \
    || fail "recording the outbound reply failed"

  # Same text arriving back on an otherwise-accepted device must still be
  # recognised as firstmate's own words.
  out=$(fixture "$home" "$(msg ECHODIGEST 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, that is done."}')")
  assert_refused "$out" 'matches firstmate outbound' \
    "firstmate's own reply came back as a new instruction"

  # The marker is consumed, so the captain may genuinely say the same words next.
  out=$(fixture "$home" "$(msg ECHOAGAIN 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, that is done."}')")
  assert_contains "$out" 'ACCEPTED' "the echo guard permanently swallowed that wording"

  pass "an outbound reply coming back is dropped once, and only once"
}

# The echo firstmate's own reply produces arrives on mudslide's device, which
# the default sender-device filter rejects. If that rejection came first the
# digest marker would never be consumed by the echo it was written for, and it
# would sit out its whole ten-minute life waiting to swallow the captain typing
# those same words himself.
test_the_real_echo_consumes_its_own_marker() {
  command -v node >/dev/null 2>&1 || { pass "echo consumption skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/echoconsume"
  new_home "$home"
  printf 'Captain, the PR is up.\n' > "$TMP_ROOT/echoconsume-reply.txt"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/echoconsume-reply.txt" >/dev/null 2>&1 \
    || fail "recording the outbound reply failed"

  # Device 2 is mudslide: firstmate's own words coming back.
  out=$(fixture "$home" "$(msg REALECHO 2 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, the PR is up."}')")
  assert_contains "$out" 'REJECTED' "firstmate's own reply came back as a new instruction"
  [ -z "$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null)" ] \
    || fail "the echo was dropped without consuming the digest it was written for"

  # So the captain saying the same thing straight afterwards is still heard.
  out=$(fixture "$home" "$(msg CAPSAME 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, the PR is up."}')")
  assert_contains "$out" 'ACCEPTED' \
    "the captain's own words were swallowed by a digest his echo should have cleared"

  pass "firstmate's echo clears its own digest instead of leaving it as a trap"
}

# FM_WA_ALLOW_DEVICES=* accepts every device, mudslide's included, so on such a
# home the digest is the only thing standing between firstmate and its own words.
# It is kept rather than refused because it is the only way a host whose baileys
# exposes no raw stanza hook can read the captain at all - but one mechanism is
# not enough for something that runs unattended, and the digest is single-consume
# by design. WhatsApp delivers the same message twice routinely: once as `notify`
# and again as `append`, and again after a restart for anything that was offline.
# The second delivery finds no digest, and a self-reply loop over the captain's
# own account is the result. The durable per-message marker is the second
# mechanism, and it outlives the digest by thirty days.
wildcard_fixture() {
  # wildcard_fixture <home> <body> [<captain-config>]
  local home=$1 body=$2
  pair_fixture_home "$home"
  printf '%s' "$body" | FM_WA_STATE="$home/state" FM_WA_AUTH_DIR="$home/state/wa-auth" \
    FM_WA_CAPTAIN="${3:-$CAPTAIN}" FM_WA_ALLOW_DEVICES='*' \
    node "$LISTENER" handle-fixture 2>/dev/null
}

test_a_consumed_echo_cannot_be_redelivered() {
  command -v node >/dev/null 2>&1 || { pass "echo redelivery guard skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/echoredeliver"
  new_home "$home"
  printf 'Captain, the checks are green.\n' > "$TMP_ROOT/echoredeliver-reply.txt"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/echoredeliver-reply.txt" >/dev/null 2>&1 \
    || fail "recording the outbound reply failed"

  out=$(wildcard_fixture "$home" "$(msg ECHOREDELIVER 2 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, the checks are green."}')")
  assert_refused "$out" 'matches firstmate outbound' \
    "firstmate's own reply came back as a new instruction"
  assert_present "$home/state/wa-seen/ECHOREDELIVER.seen" \
    "the echo was dropped without leaving anything a redelivery could be caught by"

  # The digest is gone now, exactly as it is in the field. The same delivery
  # arriving again must still not become an instruction.
  out=$(wildcard_fixture "$home" "$(msg ECHOREDELIVER 2 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, the checks are green."}')")
  assert_refused "$out" 'already handled' \
    "a redelivered echo was stashed as a fresh captain instruction"
  assert_absent "$home/state/wa-inbox/ECHOREDELIVER.json" \
    "a redelivered echo reached the inbox with every device accepted"

  # ...and the marker is per message, so the captain repeating those exact words
  # under his own id is still heard.
  out=$(wildcard_fixture "$home" "$(msg CAPGREEN 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, the checks are green."}')")
  assert_contains "$out" 'ACCEPTED' \
    "the durable echo marker swallowed the captain's own words"

  pass "a consumed echo stays refused when WhatsApp delivers it again"
}

# A stalled listener is reported AND repaired in the same cycle, so the poll
# carries on to the restart budget after speaking. Two fault lines in one cycle
# would break the one-line check contract, and a shared record would leave the
# specific report replaced by the generic one that came after it: the captain
# would be left holding a remedy that cannot fix what he was originally told
# about, and the dedupe that keeps a known fault quiet would be defeated.
test_two_faults_in_one_cycle_still_speak_once() {
  local home out lines first second
  home="$TMP_ROOT/doublefault"
  new_home "$home"
  fake_listener "$home"
  # Alive, but a connection that never came up: no beat, and a pid record old
  # enough to count as stalled.
  touch -t 200001010000 "$home/state/wa-listener.pid"
  # And a restart budget already spent, which is the next thing the cycle finds.
  printf '3\n' > "$home/state/wa-listener.restarts"

  out=$(poll "$home")
  lines=$(printf '%s' "$out" | grep -c . || true)
  [ "$lines" = 1 ] || fail "the cycle printed $lines lines instead of one: $out"
  first=$out
  assert_contains "$first" 'wa-channel-error' "the stalled listener was not reported"
  [ "$(cat "$home/state/wa-listener.error.never-up" 2>/dev/null)" = "${first#wa-channel-error }" ] \
    || fail "the recorded fault does not match the one that was reported"

  # The fault that lost the race is not lost: it is what the next cycle finds.
  second=$(poll "$home")
  lines=$(printf '%s' "$second" | grep -c . || true)
  [ "$lines" = 1 ] || fail "the following cycle printed $lines lines instead of one: $second"
  assert_contains "$second" 'will not stay healthy after restart' \
    "the spent restart budget was never reported"

  # Each fault keeps its own record, so the second one does not overwrite the
  # first: the specific report survives the generic one that followed it.
  [ "$(cat "$home/state/wa-listener.error.never-up" 2>/dev/null)" = "${first#wa-channel-error }" ] \
    || fail "the second fault overwrote the record of the first"
  [ "$(cat "$home/state/wa-listener.error.restart-latch" 2>/dev/null)" = "${second#wa-channel-error }" ] \
    || fail "the second fault was reported without being recorded in its own right"

  # And having been recorded truthfully, it is said once rather than every cycle.
  [ -z "$(poll "$home")" ] \
    || fail "the same fault was reported again instead of being deduped"

  pass "a cycle that finds two faults reports one, records it, and reports the other next"
}

# The digest is computed once in the shell and once in the listener, so the two
# normalizations have to agree on exactly which characters count as whitespace.
# A reply carrying a non-breaking space used to hash differently on each side,
# which left the echo unrecognised and the reply stashed as a fresh instruction.
test_echo_digest_normalization_matches() {
  command -v node >/dev/null 2>&1 || { pass "digest normalization skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/echonorm"
  new_home "$home"
  printf 'Captain,\xc2\xa0that is done.\n' > "$TMP_ROOT/echo-nbsp.txt"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/echo-nbsp.txt" >/dev/null 2>&1 \
    || fail "recording the outbound reply failed"

  out=$(fixture "$home" "$(msg ECHONBSP 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain,\u00a0that is done."}')")
  assert_refused "$out" 'matches firstmate outbound' \
    "a reply containing a non-breaking space came back as a new instruction"

  pass "the outbound digest matches the listener's on non-ASCII whitespace"
}

# A home snapshot that is sensitive to any file appearing, disappearing, or
# changing content: path plus mode plus a content digest for every regular file.
snapshot_home() {
  local home=$1
  ( cd "$home" && find . -mindepth 1 \( -type f -o -type d \) -print0 \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' entry; do
          if [ -d "$entry" ]; then
            printf 'd %s\n' "$entry"
          else
            printf 'f %s %s\n' "$entry" "$(cksum < "$entry" | awk '{print $1"-"$2}')"
          fi
        done )
}

test_removing_the_config_restores_the_home_exactly() {
  local home before after out
  home="$TMP_ROOT/selfdisarm"
  mkdir -p "$home/state" "$home/config"
  chmod 700 "$home/state"
  # A neighbouring home artifact that must survive: self-disarm removes only the
  # three files the channel generates, never anything else.
  printf 'export FM_CHECK_INTERVAL=30\n' > "$home/config/x-mode.env"
  printf 'unrelated\n' > "$home/state/keepme"

  before=$(snapshot_home "$home")

  printf 'FM_WA_CAPTAIN=%s\n' "$CAPTAIN" > "$home/config/whatsapp.env"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 \
    || fail "arm failed"
  assert_present "$home/state/wa-watch.check.sh" "arm wrote no check shim"
  assert_present "$home/config/wa-mode.env" "arm wrote no cadence file"
  ( . "$ROOT/bin/fm-supervision-lib.sh"; fm_supervision_status "$home/state" >/dev/null 2>&1
    [ -n "${FM_SUP_NEEDED:-}" ] ) || fail "an armed home was not counted as needing supervision"

  # The documented opt-out, and one poll cycle to act on it.
  rm -f "$home/config/whatsapp.env"
  out=$(poll "$home")
  [ -z "$out" ] || fail "the retiring cycle spoke: $out"

  assert_absent "$home/state/wa-watch.check.sh" "the check shim outlived the config"
  assert_absent "$home/state/wa-watch.check-trust" "the registration outlived the config"
  assert_absent "$home/config/wa-mode.env" "the cadence file outlived the config"
  assert_present "$home/config/x-mode.env" "self-disarm removed Relay's cadence file"
  assert_present "$home/state/keepme" "self-disarm removed an unrelated state file"

  after=$(snapshot_home "$home")
  [ "$before" = "$after" ] || {
    printf 'before/after differ:\n%s\n' "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)" >&2
    fail "the home is not byte-identical to before the channel was armed"
  }

  # Idempotent: with everything already gone it does nothing and says nothing.
  out=$(poll "$home")
  [ -z "$out" ] || fail "a second retiring cycle spoke: $out"
  [ "$(snapshot_home "$home")" = "$before" ] || fail "a second retiring cycle changed the home"

  pass "removing config/whatsapp.env restores the home byte-for-byte and repeats safely"
}

# The captain's account has two identities and WhatsApp uses both: some
# deliveries of his self-chat are addressed to his phone number, others to his
# LID. Reproduced live - every real message he sent arrived under his LID and
# was refused as a non-direct chat, so state/wa-inbox stayed empty while he
# believed he was messaging firstmate.
#
# A LID is a real per-account WhatsApp identifier, so this one is invented for
# the tests, exactly as the number above is. A home's own LID is never
# configured: the listener reads it from its own pairing credentials.
CAPTAIN_LID=100000000000001

lid_fixture() {
  local home=$1 body=$2
  pair_fixture_home "$home"
  printf '%s' "$body" | FM_WA_STATE="$home/state" FM_WA_AUTH_DIR="$home/state/wa-auth" \
    FM_WA_CAPTAIN="$CAPTAIN" FM_WA_ALLOW_DEVICES=0 FM_WA_SELF_LID="$CAPTAIN_LID" \
    node "$LISTENER" handle-fixture 2>/dev/null
}

lid_msg() {
  # lid_msg <id> <chat-jid> <inner-json>
  printf '{"stanza_from":"%s:0@lid","message":{"key":{"id":"%s","remoteJid":"%s","fromMe":true},"messageTimestamp":%s,"message":%s}}' \
    "$CAPTAIN_LID" "$1" "$2" "$(next_ts)" "$3"
}

test_captain_reaches_us_under_either_identity() {
  command -v node >/dev/null 2>&1 || { pass "LID identity skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/lid"
  new_home "$home"

  out=$(lid_fixture "$home" "$(lid_msg LIDMSG "$CAPTAIN_LID@lid" '{"conversation":"testing from the road"}')")
  assert_contains "$out" 'ACCEPTED' "the captain's LID self-chat was refused, so his real messages are dropped"
  assert_grep '"sender": "'"$CAPTAIN"'"' "$home/state/wa-inbox/LIDMSG.json"     "a LID-addressed message did not record the captain's number as the sender"
  assert_grep '"chat_identity": "lid"' "$home/state/wa-inbox/LIDMSG.json"     "the stashed record does not say which identity the chat used"

  # The same message under his phone-number identity must still work.
  out=$(fixture "$home" "$(msg PNMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"and from the desk"}')")
  assert_contains "$out" 'ACCEPTED' "the phone-number form regressed while adding the LID form"

  pass "the captain reaches firstmate under either of his two WhatsApp identities"
}

test_lid_acceptance_is_not_a_hole() {
  command -v node >/dev/null 2>&1 || { pass "LID security skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/lidsec"
  new_home "$home"

  out=$(lid_fixture "$home" "$(lid_msg LIDGRP '445566@g.us' '{"conversation":"group message"}')")
  assert_contains "$out" 'REJECTED' "a group message was accepted once LID chats were allowed"

  out=$(lid_fixture "$home" "$(lid_msg LIDSTRANGER '999888777666@lid' '{"conversation":"not the captain"}')")
  assert_contains "$out" 'REJECTED' "another user's LID was accepted as the captain"

  out=$(lid_fixture "$home" "$(lid_msg LIDCAST '1234@broadcast' '{"conversation":"broadcast"}')")
  assert_contains "$out" 'REJECTED' "a broadcast was accepted"

  # With no LID established from our own credentials there is nothing proving a
  # LID chat is his, so it must fail closed rather than be assumed.
  out=$(printf '%s' "$(lid_msg LIDNOSELF "$CAPTAIN_LID@lid" '{"conversation":"no identity known"}')"     | FM_WA_STATE="$home/state" FM_WA_AUTH_DIR="$home/state/wa-auth"       FM_WA_CAPTAIN="$CAPTAIN" FM_WA_ALLOW_DEVICES=0       node "$LISTENER" handle-fixture 2>/dev/null)
  assert_contains "$out" 'REJECTED' "a LID chat was accepted with no LID identity established"

  pass "accepting the captain's LID admits only him, never a group, broadcast or stranger"
}


# --- more than one captain number -------------------------------------------

# The captain has two phones and wants either to reach firstmate, and every
# update to reach both. FM_WA_CAPTAIN therefore holds a LIST. The parse has to
# stay strict about what a number is while accepting either separator, and a
# home that names one number must behave exactly as it did before the list
# existed - that is the compatibility this asserts, not just that it parses.
captain_parse() {
  ( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    FM_HOME=$TMP_ROOT
    FM_WA_ENV_FILE=$1 fm_wa_load_config >/dev/null || { printf 'REFUSED'; exit 0; }
    printf '%s' "$FM_WA_CAPTAIN" )
}

write_env() {
  mkdir -p "$(dirname "$1")"
  printf 'FM_WA_CAPTAIN=%s\n' "$2" > "$1"
}

test_one_captain_number_parses_exactly_as_before() {
  local env out
  env="$TMP_ROOT/parse-one.env"

  write_env "$env" "$CAPTAIN"
  out=$(captain_parse "$env")
  [ "$out" = "$CAPTAIN" ] || fail "a single number no longer parses to itself: '$out'"

  # The old parse stripped every non-digit, and that must not change for a
  # single value: punctuation people really type into a phone number is dropped
  # rather than turning one number into two.
  write_env "$env" "+44 7700 900123"
  out=$(captain_parse "$env")
  [ "$out" = "$CAPTAIN" ] || fail "a spaced and plus-prefixed single number did not normalise to '$CAPTAIN': '$out'"

  pass "a single captain number behaves exactly as it did before the list"
}

test_two_captain_numbers_parse_as_a_list() {
  local env out
  env="$TMP_ROOT/parse-two.env"

  write_env "$env" "$CAPTAIN,$CAPTAIN2"
  out=$(captain_parse "$env")
  [ "$out" = "$CAPTAIN $CAPTAIN2" ] || fail "a comma-separated pair did not parse to both numbers: '$out'"

  write_env "$env" "$CAPTAIN $CAPTAIN2"
  out=$(captain_parse "$env")
  [ "$out" = "$CAPTAIN $CAPTAIN2" ] || fail "a space-separated pair did not parse to both numbers: '$out'"

  write_env "$env" "  $CAPTAIN ,, $CAPTAIN2  "
  out=$(captain_parse "$env")
  [ "$out" = "$CAPTAIN $CAPTAIN2" ] || fail "untidy separators did not normalise to both numbers: '$out'"

  # The one outcome that must never happen quietly: the numbers running together
  # into a single value that matches neither phone. That is what the old
  # digits-only strip did to a list, and it would refuse both captains while
  # looking configured.
  case "$out" in
    *"$CAPTAIN$CAPTAIN2"*) fail "the two numbers were concatenated into one value" ;;
  esac

  pass "two captain numbers parse as a list, whatever the separator"
}

# Both entry points read FM_WA_CAPTAIN, and a message accepted by one and
# dropped by the other is the failure the shared rule exists to prevent. The
# shell decides the split and hands the listener the result, so what has to hold
# is that the listener reproduces that list rather than re-deriving it - checked
# here over the inputs that pulled the two apart, a short entry above all: a
# list carrying one came back out of the listener's whitespace heuristic
# concatenated, so a genuine second number was replied to and never heard.
listener_captains() {
  ( FM_WA_STATE="$TMP_ROOT/parse-agree/state" \
    FM_WA_AUTH_DIR="$TMP_ROOT/parse-agree/state/wa-auth" \
    FM_WA_CAPTAIN="$1" node "$LISTENER" captains 2>/dev/null | tr '\n' ' ' \
    | sed 's/ $//' )
}

test_both_entry_points_read_one_captain_list() {
  command -v node >/dev/null 2>&1 || { pass "parser agreement skipped: node is unavailable"; return 0; }
  local env raw shell_out wire listener_out
  env="$TMP_ROOT/parse-agree.env"
  mkdir -p "$TMP_ROOT/parse-agree/state"

  for raw in \
    "$CAPTAIN" \
    "+44 7700 900123" \
    "$CAPTAIN,$CAPTAIN2" \
    "$CAPTAIN $CAPTAIN2" \
    "  $CAPTAIN ,, $CAPTAIN2  " \
    "1234567,$CAPTAIN2" \
    "$CAPTAIN,,$CAPTAIN2" \
    ",$CAPTAIN,"
  do
    write_env "$env" "$raw"
    shell_out=$(captain_parse "$env")
    [ "$shell_out" != REFUSED ] || fail "the shell refused '$raw', which this case assumes it accepts"
    wire=$(
      # shellcheck source=bin/fm-wa-lib.sh
      . "$LIB"
      fm_wa_captains_wire "$shell_out" )
    listener_out=$(listener_captains "$wire")
    [ "$listener_out" = "$shell_out" ] \
      || fail "'$raw' parsed to '$shell_out' for the shell and '$listener_out' for the listener"
  done

  # A value naming no number is refused on both sides rather than becoming an
  # empty list one of them still treats as configured.
  write_env "$env" " , , "
  [ "$(captain_parse "$env")" = REFUSED ] || fail "a value naming no number was accepted by the shell"
  wire=$(
    # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    fm_wa_captains_wire '' )
  [ -z "$(listener_captains "$wire")" ] \
    || fail "the listener built a captain list out of a value naming no number"

  pass "the shell and the listener resolve the same captain list from every input"
}

test_a_configuration_naming_no_number_is_still_refused() {
  local env out
  env="$TMP_ROOT/parse-none.env"

  write_env "$env" ""
  [ "$(captain_parse "$env")" = REFUSED ] || fail "a blank value was accepted as a captain list"

  write_env "$env" " , , "
  [ "$(captain_parse "$env")" = REFUSED ] || fail "separators with no digits were accepted as a captain list"

  pass "a configuration that names no number is refused, list or not"
}

# --- a LID chat is resolved to a number, never trusted on its own ------------

# `creds.me.lid` is OUR OWN account's LID, so comparing a chat's user against it
# only ever matches a literal self-chat - which is why a real LID-addressed chat
# from the captain was refused, his primary phone included. WhatsApp supplies
# the mapping instead: baileys lifts the stanza's `sender_pn` onto the message
# key, so the LID is resolved to a phone number by the server and then checked
# against the configured numbers exactly as a plain chat is.
#
# These LIDs are invented, like the numbers.
CAPTAIN2_LID=100000000000002
STRANGER_LID=100000000000003

lid_pn_msg() {
  # lid_pn_msg <id> <chat-lid> <sender-pn|-> <inner-json> [<from-me>] [<pn-field-name>]
  local pn_field=''
  [ "$3" = '-' ] || pn_field=$(printf ',"%s":"%s@s.whatsapp.net"' "${6:-senderPn}" "$3")
  printf '{"stanza_from":"%s:0@lid","message":{"key":{"id":"%s","remoteJid":"%s@lid","fromMe":%s%s},"messageTimestamp":%s,"message":%s}}' \
    "$2" "$1" "$2" "${5:-false}" "$pn_field" "$(next_ts)" "$4"
}

# Like fixture(), but with the configured captain list spelled out, because the
# cases below turn on which numbers this home knows about. A fourth argument
# pairs the home with that LID in its own credentials, which is how a real
# account carries the identity its LID-addressed self-chat is recognised by.
configured_fixture() {
  # configured_fixture <home> <captain-config> <body> [<own-lid>]
  pair_fixture_home "$1" "${4:-}"
  printf '%s' "$3" | FM_WA_STATE="$1/state" FM_WA_AUTH_DIR="$1/state/wa-auth" \
    FM_WA_CAPTAIN="$2" FM_WA_ALLOW_DEVICES=0 \
    node "$LISTENER" handle-fixture 2>/dev/null
}

test_a_second_phone_reaches_us_by_messaging_in() {
  command -v node >/dev/null 2>&1 || { pass "second phone skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/secondphone"
  new_home "$home"

  # A second phone is its own WhatsApp account, so its message to us arrives
  # INBOUND - fromMe is false and the chat is addressed by its own number.
  out=$(configured_fixture "$home" "$CAPTAIN,$CAPTAIN2" \
    "$(msg PN2MSG 0 "$CAPTAIN2@s.whatsapp.net" false '{"conversation":"from the other phone"}')")
  assert_contains "$out" 'ACCEPTED' \
    "an inbound message from the configured second number was refused"
  assert_grep '"sender": "'"$CAPTAIN2"'"' "$home/state/wa-inbox/PN2MSG.json" \
    "the stashed record named the wrong phone as the sender"
  assert_grep '"from_me": false' "$home/state/wa-inbox/PN2MSG.json" \
    "the stashed record claimed an inbound message came from our own account"

  # The same phone on a LID-addressed chat, resolved by the number the server
  # supplies rather than by the opaque identity.
  out=$(configured_fixture "$home" "$CAPTAIN,$CAPTAIN2" \
    "$(lid_pn_msg LID2MSG "$CAPTAIN2_LID" "$CAPTAIN2" '{"conversation":"and on a LID chat"}')")
  assert_contains "$out" 'ACCEPTED' \
    "an inbound LID chat from the configured second number was refused"
  assert_grep '"sender": "'"$CAPTAIN2"'"' "$home/state/wa-inbox/LID2MSG.json" \
    "a LID-addressed record named the wrong phone as the sender"

  # And the self-chat, which is the primary path, still works alongside it.
  out=$(configured_fixture "$home" "$CAPTAIN,$CAPTAIN2" \
    "$(msg SELFSTILL 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"and from my own phone"}')")
  assert_contains "$out" 'ACCEPTED' "the captain's own self-chat regressed"
  assert_grep '"sender": "'"$CAPTAIN"'"' "$home/state/wa-inbox/SELFSTILL.json" \
    "the self-chat record lost the captain's own number"

  pass "a configured second phone reaches firstmate by messaging in, on either identity form"
}

test_a_lid_chat_is_admitted_by_its_resolved_number() {
  command -v node >/dev/null 2>&1 || { pass "LID resolution skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/lidpn"
  new_home "$home"

  # The second phone, which has its own LID our credentials can never prove.
  # This is the whole inbound shape: a separate account, so fromMe is false and
  # the server-supplied number is the only proof of who is on the other end.
  # The primary phone's own LID chat is not modelled here - it is OUR account,
  # so it can only ever be the self-chat, and that is proved by our own
  # credentials in test_the_lid_self_chat_is_proved_by_our_own_credentials.
  out=$(configured_fixture "$home" "$CAPTAIN,$CAPTAIN2" \
    "$(lid_pn_msg LIDPN2 "$CAPTAIN2_LID" "$CAPTAIN2" '{"conversation":"from the second phone"}')")
  assert_contains "$out" 'ACCEPTED' \
    "the second captain number was refused on a LID chat, so his other phone cannot reach firstmate"

  # baileys carries the same mapping as participantPn on some deliveries, and a
  # number the server did supply must not be dropped for arriving under the
  # other name - that refusal would look exactly like being ignored.
  out=$(configured_fixture "$home" "$CAPTAIN,$CAPTAIN2" \
    "$(lid_pn_msg LIDPN3 "$CAPTAIN2_LID" "$CAPTAIN2" '{"conversation":"and again"}' false participantPn)")
  assert_contains "$out" 'ACCEPTED' \
    "a LID chat resolved by participantPn was refused, so the same phone gets in or not by delivery shape"

  pass "a LID chat is admitted by the number the server resolves it to"
}

# The one LID chat our own credentials can decide, and the only LID shape the
# captain's PRIMARY phone can produce: it is our account, so its chat with
# itself is fromMe and is recognised by `me.lid` from the pairing credentials.
# A real paired account carries that field; the fixtures that leave it out are
# proving the resolved-number path instead, so this covers the credential one.
test_the_lid_self_chat_is_proved_by_our_own_credentials() {
  command -v node >/dev/null 2>&1 || { pass "LID self-chat skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/lidself-creds"
  new_home "$home"

  # No FM_WA_SELF_LID anywhere: the credentials are the whole evidence.
  out=$(configured_fixture "$home" "$CAPTAIN" \
    "$(lid_pn_msg LIDSELFC "$CAPTAIN_LID" - '{"conversation":"from my own phone"}' true)" \
    "$CAPTAIN_LID")
  assert_contains "$out" 'ACCEPTED' \
    "the LID self-chat was refused with our own LID in the credentials, so his messages are dropped"
  assert_grep '"sender": "'"$CAPTAIN"'"' "$home/state/wa-inbox/LIDSELFC.json" \
    "the LID self-chat record lost the captain's own number"
  assert_grep '"chat_identity": "lid"' "$home/state/wa-inbox/LIDSELFC.json" \
    "the stashed record does not say which identity the chat used"

  # Our own LID identifies our own chat and nothing else. Somebody else's LID
  # chat is refused even when the message we sent into it carries a configured
  # number as its sender - which it always does, because we are the sender.
  out=$(configured_fixture "$home" "$CAPTAIN" \
    "$(lid_pn_msg LIDSELFX "$STRANGER_LID" "$CAPTAIN" '{"conversation":"see you at six"}' true)" \
    "$CAPTAIN_LID")
  assert_refused "$out" "our own outgoing message in a chat that is not the captain's own" \
    "a message we sent into a stranger's LID chat was read as an instruction"

  pass "the LID self-chat is proved by our own credentials, and proves nothing else"
}

test_a_lid_chat_is_never_trusted_on_its_own() {
  command -v node >/dev/null 2>&1 || { pass "LID trust skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/lidpn-strict"
  new_home "$home"

  # A stranger's LID, whatever number it claims to be, is not a configured one.
  out=$(configured_fixture "$home" "$CAPTAIN,$CAPTAIN2" \
    "$(lid_pn_msg LIDPNX "$STRANGER_LID" 447700900999 '{"conversation":"not the captain"}')")
  assert_contains "$out" 'REJECTED' "a stranger's LID chat was accepted"

  # A second number that is NOT configured must not get in just because some
  # other number is. This is the security property the list must not weaken.
  out=$(configured_fixture "$home" "$CAPTAIN" \
    "$(lid_pn_msg LIDPNY "$CAPTAIN2_LID" "$CAPTAIN2" '{"conversation":"an unconfigured second phone"}')")
  assert_contains "$out" 'REJECTED' \
    "a number absent from the configuration was admitted on a LID chat"

  pass "a LID chat is never trusted on its own, only on a number we configured"
}

# The regression that made every LID-addressed chat the captain has into an
# instruction channel. `sender_pn` names the SENDER, so on a message HE sent it
# is always his own number - matching the configured list in a stranger's chat
# just as surely as in his own. Checking it without also requiring the message
# to be inbound meant firstmate read his private conversations with third
# parties, acted on them, and replied inside them.
#
# The earlier LID tests all passed because every one of them put a STRANGER's
# number in sender_pn, which is the case that never happens on an outgoing
# message.
test_our_own_outgoing_words_are_never_an_instruction() {
  command -v node >/dev/null 2>&1 || { pass "outgoing LID guard skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/lidpn-outgoing"
  new_home "$home"

  out=$(configured_fixture "$home" "$CAPTAIN,$CAPTAIN2" \
    "$(lid_pn_msg LIDOUT "$STRANGER_LID" "$CAPTAIN" '{"conversation":"see you at six"}' true)")
  # Refused under its own reason, not folded into ordinary stranger traffic:
  # this line also covers a message from the captain whose chat identity we do
  # not recognise, which is a dropped instruction, so it has to be greppable.
  assert_refused "$out" "our own outgoing message in a chat that is not the captain's own" \
    "a message the captain sent to a stranger was ingested as an instruction to firstmate"
  assert_absent "$home/state/wa-inbox/LIDOUT.json" \
    "a private message to a third party was stashed for firstmate to act on"

  # Same shape on a phone-number chat: our own words to his second phone are his
  # conversation, not an instruction, even though that number IS configured.
  out=$(configured_fixture "$home" "$CAPTAIN,$CAPTAIN2" \
    "$(msg PNOUT 0 "$CAPTAIN2@s.whatsapp.net" true '{"conversation":"see you at six"}')")
  assert_contains "$out" 'REJECTED' \
    "our own outgoing message to the second number was ingested as an instruction"

  # The linked device sees everything he sends to anybody, so the per-delivery
  # claim that keeps a redelivered echo from spending another echo's marker is
  # taken only while a reply is actually outstanding. Taken on all of it, his
  # ordinary traffic would accumulate a record per message for a month.
  assert_absent "$home/state/wa-seen/LIDOUT.seen" \
    "a private message to a third party left a durable record behind with no reply outstanding"
  assert_absent "$home/state/wa-seen/PNOUT.seen" \
    "an outgoing message left a durable record behind with no reply outstanding"

  pass "our own outgoing words in someone else's chat are never read as an instruction"
}

test_an_unresolvable_lid_is_refused_and_said_out_loud() {
  command -v node >/dev/null 2>&1 || { pass "LID diagnostics skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/lidpn-quiet"
  new_home "$home"

  # No senderPn, and no self-LID to fall back on. It must fail closed - but this
  # is the one refusal that can hide a real message from the captain, so it has
  # to be distinguishable in the log from ordinary stranger traffic rather than
  # looking like routine noise.
  out=$(configured_fixture "$home" "$CAPTAIN" \
    "$(lid_pn_msg LIDPNQ "$CAPTAIN_LID" - '{"conversation":"no number to check"}')")
  assert_contains "$out" 'REJECTED' "an unresolvable LID chat was accepted"
  assert_contains "$out" 'no phone number' \
    "an unresolvable LID was refused as an ordinary stranger, so a dropped message looks like routine traffic"

  pass "an unresolvable LID chat is refused and says why"
}


# A pid file outlives SIGKILL, an OOM kill and a reboot, and after a reboot low
# pids are handed out again freely, so this record routinely names some
# unrelated process that merely inherited the number. Refusing every repair path
# for that left the channel dead with no remedy but deleting the pid file by
# hand, which nothing documented - a silent permanent outage, and the captain
# cannot tell a dead channel from being ignored. So a recycled pid is a stale
# record to clear, and only a real listener is refused.
test_a_recycled_pid_is_a_stale_record_not_an_outage() {
  local home out pid
  home="$TMP_ROOT/pidrecover"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  # An unrelated process that inherited the number, exactly as a reboot leaves.
  sleep 300 &
  pid=$!
  FAKE_PIDS="$FAKE_PIDS $pid"
  printf '%s\n' "$pid" > "$home/state/wa-listener.pid"
  printf 'Sat Jan  1 00:00:00 2000\n' > "$home/state/wa-listener.pid-identity"

  # The documented repair must work rather than refusing, and it must not
  # signal the unrelated process on its way through.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" stop >/dev/null 2>&1 \
    || fail "stop refused a recycled pid, so the channel cannot be repaired at all"
  kill -0 "$pid" 2>/dev/null \
    || fail "stop signalled an unrelated process that merely held the pid"
  assert_absent "$home/state/wa-listener.pid" \
    "the stale pid record survived the repair, so every later path refuses again"

  pass "a recycled pid is cleared as a stale record instead of stranding the channel"
}


# He carries two phones, so an update that reaches only one of them is an update
# he may never see. Every reply therefore goes to every configured number unless
# one is named explicitly, and a send that reaches one phone but not the other
# is reported as the partial failure it is rather than as success.
test_a_reply_reaches_every_captain_number() {
  local home fakebin out
  home="$TMP_ROOT/sendboth"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s,%s\nFM_WA_ALLOW_DEVICES=0\n' "$CAPTAIN" "$CAPTAIN2" \
    > "$home/config/whatsapp.env"
  printf 'both phones please\n' > "$TMP_ROOT/sendboth-reply.txt"

  fakebin=$(fm_fakebin "$TMP_ROOT/sendboth-bin")
  cat > "$fakebin/mudslide" <<'SH'
#!/bin/sh
# Record the recipient of each send, and fail only for the number named in
# FAIL_FOR so the partial case can be driven.
for a in "$@"; do
  case "$a" in
    [0-9][0-9]*) printf '%s
' "$a" >> "$MUDSLIDE_LOG"
      [ "$a" = "${FAIL_FOR:-}" ] && { echo "refused $a" >&2; exit 1; }
      break ;;
  esac
done
exit 0
SH
  chmod +x "$fakebin/mudslide"

  MUDSLIDE_LOG="$TMP_ROOT/sendboth.log"; : > "$MUDSLIDE_LOG"
  out=$(PATH="$fakebin:$PATH" MUDSLIDE_LOG="$MUDSLIDE_LOG" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/sendboth-reply.txt" 2>&1) \
    || fail "sending to both numbers failed: $out"
  grep -qx "$CAPTAIN" "$MUDSLIDE_LOG" || fail "the reply never reached the first number"
  grep -qx "$CAPTAIN2" "$MUDSLIDE_LOG" || fail "the reply never reached the second number"

  # An explicit recipient still addresses exactly one, so a reply can follow an
  # inbound message back to the phone it came from.
  : > "$MUDSLIDE_LOG"
  out=$(PATH="$fakebin:$PATH" MUDSLIDE_LOG="$MUDSLIDE_LOG" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --to "$CAPTAIN2" --text-file "$TMP_ROOT/sendboth-reply.txt" 2>&1) \
    || fail "an addressed send failed: $out"
  grep -qx "$CAPTAIN2" "$MUDSLIDE_LOG" || fail "an addressed reply did not reach that number"
  grep -qx "$CAPTAIN" "$MUDSLIDE_LOG" && fail "an addressed reply also went to the other number"

  # Reaching one phone but not the other is not success.
  : > "$MUDSLIDE_LOG"
  out=$(PATH="$fakebin:$PATH" MUDSLIDE_LOG="$MUDSLIDE_LOG" FAIL_FOR="$CAPTAIN2" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/sendboth-reply.txt" 2>&1) \
    && fail "a reply that missed one phone was reported as sent: $out"
  assert_contains "$out" "$CAPTAIN2" "the partial failure did not name the number that missed it"

  pass "a reply reaches every captain number, and a partial delivery is not called success"
}

# Pairing links ONE account and therefore takes ONE number. Defaulting it to the
# whole configured list handed the pairer the two numbers run together, which is
# long enough to pass every "is this a number" check and matches no phone on
# earth, so the documented setup step would ask WhatsApp for a code that could
# never arrive.
test_pairing_uses_one_number_not_the_whole_list() {
  local home fakebin argv out
  home="$TMP_ROOT/pairone"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s,%s\n' "$CAPTAIN" "$CAPTAIN2" > "$home/config/whatsapp.env"

  fakebin=$(fm_fakebin "$TMP_ROOT/pairone-bin")
  argv="$TMP_ROOT/pairone.argv"
  cat > "$fakebin/node" <<'SH'
#!/bin/sh
# Stands in for the listener: record what the pairer was asked to pair.
printf '%s\n' "$@" > "$PAIR_ARGV"
exit 0
SH
  chmod +x "$fakebin/node"

  out=$(PATH="$fakebin:$PATH" PAIR_ARGV="$argv" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$LISTEN_SH" pair 2>&1) || fail "pairing failed: $out"
  [ -f "$argv" ] || fail "the pair command never reached the listener"
  grep -qx "$CAPTAIN" "$argv" \
    || fail "pairing was not asked for the first configured number: $(tr '\n' ' ' < "$argv")"
  grep -q "$CAPTAIN$CAPTAIN2" "$argv" \
    && fail "pairing was asked for the two numbers run together"
  assert_contains "$out" "+$CAPTAIN" "the captain was told the wrong number was being paired"
  case "$out" in
    *"$CAPTAIN2"*) fail "the pairing prompt named a number it was not pairing" ;;
  esac

  pass "pairing asks for one account, never the whole captain list"
}

# One reply, several phones, several echoes. The listener consumes exactly one
# digest marker per echo, so a send that writes a single marker leaves every
# echo after the first with no digest to be caught by - and on a
# FM_WA_ALLOW_DEVICES=* home there is no device filter behind it either, so
# firstmate reads its own reply back as a fresh instruction and answers it.
test_every_delivery_of_one_reply_has_its_own_echo_marker() {
  command -v node >/dev/null 2>&1 || { pass "fan-out echo guard skipped: node is unavailable"; return 0; }
  local home fakebin out markers
  home="$TMP_ROOT/echofanout"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s,%s\nFM_WA_ALLOW_DEVICES=*\n' "$CAPTAIN" "$CAPTAIN2" \
    > "$home/config/whatsapp.env"
  printf 'Captain, both phones have this.\n' > "$TMP_ROOT/echofanout-reply.txt"

  fakebin=$(fm_fakebin "$TMP_ROOT/echofanout-bin")
  fm_fake_exit0 "$fakebin" mudslide

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/echofanout-reply.txt" 2>&1) \
    || fail "sending to both numbers failed: $out"
  markers=$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$markers" -eq 2 ] \
    || fail "a reply that went to two phones recorded $markers echo markers, not one each"

  # Each delivery echoes back separately: one into the chat with the second
  # phone, one into the self-chat. Nothing orders those two arrivals, so the
  # adverse interleaving is the one to drive - the delivery that CANNOT be
  # ingested arriving first and spending a marker the self-chat echo then needs.
  out=$(wildcard_fixture "$home" \
    "$(msg FANECHO1 2 "$CAPTAIN2@s.whatsapp.net" true '{"conversation":"Captain, both phones have this."}')" \
    "$CAPTAIN,$CAPTAIN2")
  assert_contains "$out" 'REJECTED' "our own reply to the second phone came back as an instruction"

  out=$(wildcard_fixture "$home" \
    "$(msg FANECHO2 2 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, both phones have this."}')" \
    "$CAPTAIN,$CAPTAIN2")
  assert_refused "$out" 'matches firstmate outbound' \
    "the self-chat echo of a fanned-out reply came back as a fresh captain instruction"
  assert_absent "$home/state/wa-inbox/FANECHO2.json" \
    "firstmate stashed its own reply as an instruction to answer"

  # Every marker was spent by the delivery it was written for, including the one
  # whose delivery could never have been ingested anyway. A marker no echo
  # consumes outlives the reply as a trap for the captain typing those same
  # words himself, so the ledger has to balance.
  [ -z "$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null)" ] \
    || fail "an echo marker outlived the echoes it was written for"
  out=$(wildcard_fixture "$home" \
    "$(msg FANCAP 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, both phones have this."}')" \
    "$CAPTAIN,$CAPTAIN2")
  assert_contains "$out" 'ACCEPTED' \
    "the captain repeating firstmate's own words was swallowed as an echo"

  pass "every delivery of a fanned-out reply has an echo marker of its own"
}

# WhatsApp delivers the same message more than once - once as `notify` and again
# as `append`, and a restart replays what was offline. A redelivered echo that
# spent a SECOND marker would leave the echo that marker belonged to unguarded,
# and on a FM_WA_ALLOW_DEVICES=* home there is nothing behind it, so firstmate
# would stash its own reply as a fresh instruction and answer it.
test_a_redelivered_echo_does_not_spend_a_second_marker() {
  command -v node >/dev/null 2>&1 || { pass "echo redelivery skipped: node is unavailable"; return 0; }
  local home fakebin out markers ts
  home="$TMP_ROOT/echoredeliver"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s,%s\nFM_WA_ALLOW_DEVICES=*\n' "$CAPTAIN" "$CAPTAIN2" \
    > "$home/config/whatsapp.env"
  printf 'Captain, shipshape.\n' > "$TMP_ROOT/echoredeliver-reply.txt"

  fakebin=$(fm_fakebin "$TMP_ROOT/echoredeliver-bin")
  fm_fake_exit0 "$fakebin" mudslide

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/echoredeliver-reply.txt" 2>&1) \
    || fail "sending to both numbers failed: $out"

  # The delivery addressed to the second phone, arriving twice under one id.
  ts=$(next_ts)
  out=$(wildcard_fixture "$home" \
    "$(msg REDELIVER 2 "$CAPTAIN2@s.whatsapp.net" true '{"conversation":"Captain, shipshape."}' "$ts")" \
    "$CAPTAIN,$CAPTAIN2")
  assert_contains "$out" 'REJECTED' "our own reply to the second phone came back as an instruction"
  out=$(wildcard_fixture "$home" \
    "$(msg REDELIVER 2 "$CAPTAIN2@s.whatsapp.net" true '{"conversation":"Captain, shipshape."}' "$ts")" \
    "$CAPTAIN,$CAPTAIN2")
  assert_refused "$out" 'our own outgoing message, already accounted for' \
    "a redelivered echo was treated as a new one"
  markers=$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$markers" -eq 1 ] \
    || fail "a redelivered echo left $markers markers, so it spent one belonging to another delivery"

  # The self-chat echo still finds the marker written for it.
  out=$(wildcard_fixture "$home" \
    "$(msg REDELIVERSELF 2 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, shipshape."}')" \
    "$CAPTAIN,$CAPTAIN2")
  assert_refused "$out" 'matches firstmate outbound' \
    "the self-chat echo came back as a fresh captain instruction after a redelivery"
  assert_absent "$home/state/wa-inbox/REDELIVERSELF.json" \
    "firstmate stashed its own reply as an instruction to answer"

  pass "a redelivered echo never spends a marker belonging to another delivery"
}

# The same redelivery, but on the echo that IS ingestable - the one arriving in
# the captain's own chat, which reaches the accepted path rather than being
# turned away as outgoing. Nothing there consulted the durable per-id marker
# before consuming, so the second delivery of one echo spent the marker written
# for the other phone's, and that phone's echo then had nothing left to catch it.
test_a_redelivered_self_chat_echo_leaves_the_other_marker_alone() {
  command -v node >/dev/null 2>&1 || { pass "self-chat echo redelivery skipped: node is unavailable"; return 0; }
  local home fakebin out markers ts
  home="$TMP_ROOT/echoselfredeliver"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s,%s\nFM_WA_ALLOW_DEVICES=*\n' "$CAPTAIN" "$CAPTAIN2" \
    > "$home/config/whatsapp.env"
  printf 'Captain, shipshape.\n' > "$TMP_ROOT/echoselfredeliver-reply.txt"

  fakebin=$(fm_fakebin "$TMP_ROOT/echoselfredeliver-bin")
  fm_fake_exit0 "$fakebin" mudslide

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/echoselfredeliver-reply.txt" 2>&1) \
    || fail "sending to both numbers failed: $out"

  ts=$(next_ts)
  out=$(wildcard_fixture "$home" \
    "$(msg SELFECHO 2 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, shipshape."}' "$ts")" \
    "$CAPTAIN,$CAPTAIN2")
  assert_refused "$out" 'matches firstmate outbound' \
    "the self-chat echo of a fanned-out reply came back as a fresh captain instruction"
  out=$(wildcard_fixture "$home" \
    "$(msg SELFECHO 2 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, shipshape."}' "$ts")" \
    "$CAPTAIN,$CAPTAIN2")
  assert_refused "$out" 'already handled' \
    "a redelivered self-chat echo was treated as a new one"
  markers=$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$markers" -eq 1 ] \
    || fail "a redelivered self-chat echo left $markers markers, so it spent one belonging to another delivery"

  # The delivery to the other phone still finds the marker written for it.
  out=$(wildcard_fixture "$home" \
    "$(msg SELFECHOOTHER 2 "$CAPTAIN2@s.whatsapp.net" true '{"conversation":"Captain, shipshape."}')" \
    "$CAPTAIN,$CAPTAIN2")
  assert_contains "$out" 'REJECTED' "our own reply to the second phone came back as an instruction"
  [ -z "$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null)" ] \
    || fail "an echo marker outlived the echoes it was written for"

  pass "a redelivered self-chat echo never spends the marker another delivery needs"
}

# Byte-identical replies are ordinary traffic, not a corner case: the routine
# acknowledgement is a fixed sentence. Markers named by digest alone would be
# REWRITTEN by the second send rather than added to, leaving twice the echoes
# with half the markers - the same ledger imbalance, one level up.
test_an_identical_reply_adds_markers_rather_than_replacing_them() {
  local home fakebin out markers
  home="$TMP_ROOT/echorepeat"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s,%s\n' "$CAPTAIN" "$CAPTAIN2" > "$home/config/whatsapp.env"
  printf 'Captain, shipshape.\n' > "$TMP_ROOT/echorepeat-reply.txt"

  fakebin=$(fm_fakebin "$TMP_ROOT/echorepeat-bin")
  fm_fake_exit0 "$fakebin" mudslide

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/echorepeat-reply.txt" 2>&1) \
    || fail "the first reply failed: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/echorepeat-reply.txt" 2>&1) \
    || fail "the second reply failed: $out"

  markers=$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$markers" -eq 4 ] \
    || fail "two identical replies to two phones recorded $markers echo markers, not one per delivery"

  pass "an identical reply inside the echo window adds its own markers"
}

# A phone that never got the message will never echo it back, so its marker is
# only a trap for the captain typing those same words himself.
test_a_phone_that_missed_the_reply_drops_its_own_marker() {
  local home fakebin out markers
  home="$TMP_ROOT/echopartial"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s,%s\n' "$CAPTAIN" "$CAPTAIN2" > "$home/config/whatsapp.env"
  printf 'Captain, only one phone got this.\n' > "$TMP_ROOT/echopartial-reply.txt"

  fakebin=$(fm_fakebin "$TMP_ROOT/echopartial-bin")
  cat > "$fakebin/mudslide" <<'SH'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    [0-9][0-9]*) [ "$a" = "${FAIL_FOR:-}" ] && { echo "refused $a" >&2; exit 1; }
      break ;;
  esac
done
exit 0
SH
  chmod +x "$fakebin/mudslide"

  out=$(PATH="$fakebin:$PATH" FAIL_FOR="$CAPTAIN2" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/echopartial-reply.txt" 2>&1) \
    && fail "a reply that missed one phone was reported as sent: $out"
  markers=$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$markers" -eq 1 ] \
    || fail "a partial delivery left $markers echo markers, not one per phone that got it"

  pass "a phone that missed the reply drops its own echo marker and no one else's"
}

# Every marker path starts at FM_HOME, so a home under a path containing a space
# is where a cleanup that word-splits its list quietly deletes nothing. The
# markers of a reply that never went out then sit there for the whole echo
# window, and the captain typing those same words himself is dropped as
# firstmate's own echo - silently, from his side.
test_a_failed_send_drops_its_markers_under_a_home_with_a_space() {
  local home fakebin out markers
  home="$TMP_ROOT/echo spaced home"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s,%s\n' "$CAPTAIN" "$CAPTAIN2" > "$home/config/whatsapp.env"
  printf 'Captain, nothing went out.\n' > "$TMP_ROOT/echospaced-reply.txt"

  fakebin=$(fm_fakebin "$TMP_ROOT/echospaced-bin")
  cat > "$fakebin/mudslide" <<'SH'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    [0-9][0-9]*) [ "$a" = "${ONLY_FOR:-}" ] || { echo "refused $a" >&2; exit 1; }
      break ;;
  esac
done
exit 0
SH
  chmod +x "$fakebin/mudslide"

  # Nothing reached either phone, so nothing can echo back from either.
  out=$(PATH="$fakebin:$PATH" ONLY_FOR=none FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/echospaced-reply.txt" 2>&1) \
    && fail "a send that reached no phone was reported as sent: $out"
  markers=$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$markers" -eq 0 ] \
    || fail "a send that went nowhere left $markers echo markers under a home with a space in its path"

  # And the partial case, where exactly the phone that missed it drops its own.
  out=$(PATH="$fakebin:$PATH" ONLY_FOR="$CAPTAIN" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/echospaced-reply.txt" 2>&1) \
    && fail "a reply that missed one phone was reported as sent: $out"
  markers=$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$markers" -eq 1 ] \
    || fail "a partial delivery left $markers echo markers under a home with a space in its path"

  # The dry run has its own cleanup path over the same list.
  rm -f "$home"/state/wa-sent/*.sent
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/echospaced-reply.txt" 2>&1) \
    || fail "a dry run under a home with a space in its path failed: $out"
  markers=$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$markers" -eq 2 ] \
    || fail "a dry run to two phones recorded $markers echo markers under a home with a space in its path"

  pass "a send that went nowhere leaves no echo trap when the home path contains a space"
}

# The dry run is the only place the fan-out can be inspected before it reaches
# the captain's phones, so a record naming one number where two deliveries would
# happen is evidence quietly saying less than the truth.
test_a_dry_run_records_every_delivery_it_would_make() {
  local home out records first second
  home="$TMP_ROOT/dryrunfanout"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s,%s\n' "$CAPTAIN" "$CAPTAIN2" > "$home/config/whatsapp.env"
  printf 'Captain, both phones would have this.\n' > "$TMP_ROOT/dryrunfanout-reply.txt"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/dryrunfanout-reply.txt" 2>&1) \
    || fail "the dry run failed: $out"

  records=$(find "$home/state/wa-outbox" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$records" -eq 2 ] \
    || fail "a dry run that would reach two phones recorded $records deliveries, not one each"
  first=$(grep -l "\"to\":\"$CAPTAIN\"" "$home"/state/wa-outbox/*.json 2>/dev/null | head -n 1)
  second=$(grep -l "\"to\":\"$CAPTAIN2\"" "$home"/state/wa-outbox/*.json 2>/dev/null | head -n 1)
  [ -n "$first" ] || fail "no dry-run record names the first configured number"
  [ -n "$second" ] || fail "no dry-run record names the second configured number"
  [ "$first" != "$second" ] || fail "both configured numbers came from one record"
  assert_grep 'both phones would have this' "$second" \
    "the record for the second phone lost the reply text"

  # An addressed reply still records exactly the one delivery it would make.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --to "$CAPTAIN2" --text "just you" 2>&1) \
    || fail "an addressed dry run failed: $out"
  [ "$(grep -l '"text":"just you"' "$home"/state/wa-outbox/*.json 2>/dev/null | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "an addressed dry run recorded more than the one delivery it would make"

  pass "a dry run records one entry per recipient, matching what a real send would do"
}

test_off_by_default
test_removing_config_reverts_to_silence
test_check_contract
test_undrained_inbox_is_reannounced
test_an_unusable_entry_never_silences_the_rest
test_unpaired_listener_reports_once
test_channel_fault_and_inbox_never_share_a_cycle
test_logged_out_listener_is_reported
test_repeated_listener_exits_are_reported
test_stalled_listener_is_reported
test_stalled_listener_is_replaced_not_only_reported
test_a_listener_that_cannot_read_sender_devices_is_reported
test_a_skipped_entry_is_reported_on_a_quiet_cycle
test_slow_flap_still_reaches_the_restart_limit
test_outbound_digests_are_pruned
test_dry_run_records_are_pruned
test_a_spent_restart_block_releases_itself_after_a_while
test_a_hand_run_start_releases_the_restart_block
test_a_recycled_pid_is_never_signalled
test_a_listener_binding_survives_an_environment_change
test_a_replacement_is_not_judged_by_its_predecessor
test_a_restarted_listener_survives_the_check_being_reaped
test_a_refused_restart_says_why_in_the_log
test_listener_that_never_connects_is_reported
test_repairing_the_link_clears_stale_listener_health
test_listener_state_growth_is_bounded
test_shim_arm_register_disarm
test_removing_the_config_restores_the_home_exactly
test_arming_makes_an_idle_home_need_supervision
test_every_primary_arms_for_an_armed_channel
test_every_primary_arm_command_sources_the_cadence
test_arming_writes_the_watcher_cadence
test_the_cadence_reaches_the_supervision_block
test_stop_says_the_armed_check_restarts_it
test_shim_runs_the_poll_the_way_the_watcher_does
test_dry_run_records_and_sends_nothing
test_json_encoder_round_trips_hostile_text
test_dry_run_record_is_valid_json
test_message_text_is_never_executed
test_config_is_read_as_data
test_listener_filters
test_captain_reaches_us_under_either_identity
test_lid_acceptance_is_not_a_hole
test_listener_is_idempotent
test_listener_captures_quoted_context
test_echo_digest_guard
test_the_real_echo_consumes_its_own_marker
test_a_consumed_echo_cannot_be_redelivered
test_two_faults_in_one_cycle_still_speak_once
test_echo_digest_normalization_matches
test_stale_echo_marker_does_not_swallow_the_captain
test_failed_send_leaves_no_echo_trap
test_a_dash_leading_reply_still_reaches_the_send
test_a_failed_send_says_why
test_failed_dry_run_leaves_no_echo_trap

# --- switching the channel off cleans up after itself ------------------------

# The home-is-byte-identical test above never starts a listener, so it proves
# nothing about the thing that actually matters here: a listener left running is
# a live linked device on the captain's own personal account with nothing
# watching it. Every test below starts one first.

test_stopping_works_after_the_config_is_gone() {
  local home out pid
  home="$TMP_ROOT/optoutstop"
  new_home "$home"
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")

  # The documented opt-out done in the worst order: config first, commands after.
  rm -f "$home/config/whatsapp.env"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" stop 2>&1) \
    || fail "stop refused once the config it is tearing down was gone: $out"
  assert_contains "$out" 'listener stopped' "stop did not report stopping the listener"
  if kill -0 "$pid" 2>/dev/null; then
    fail "the listener survived a stop run after the config was removed"
  fi
  assert_absent "$home/state/wa-listener.pid" "stop left the pid file behind"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" logs 5 >/dev/null 2>&1 \
    || fail "logs refused to read a listener log with the config gone"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" unpair 2>&1) \
    || fail "unpair refused once the config was gone: $out"
  assert_absent "$home/state/wa-auth" "unpair left this listener's credentials behind"

  pass "stop, logs and unpair still tear the channel down after the config is gone"
}

test_the_retiring_cycle_stops_the_listener() {
  local home out pid
  home="$TMP_ROOT/optoutpoll"
  new_home "$home"
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"

  # No command is run at all. The config simply goes, which is the whole switch.
  rm -f "$home/config/whatsapp.env"
  out=$(poll "$home")
  [ -z "$out" ] || fail "the retiring cycle spoke while cleaning up normally: $out"

  if kill -0 "$pid" 2>/dev/null; then
    fail "the retiring cycle left the listener holding a linked device"
  fi
  assert_absent "$home/state/wa-listener.pid" "the retiring cycle left the pid file behind"
  assert_absent "$home/state/wa-watch.check.sh" "the retiring cycle left the check shim armed"

  pass "removing the config alone stops the listener as well as retiring the shim"
}

test_status_reports_a_stranded_listener() {
  local home out
  home="$TMP_ROOT/optoutstatus"
  new_home "$home"
  fake_listener "$home"

  rm -f "$home/config/whatsapp.env"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" status 2>&1)
  assert_contains "$out" 'channel: off' "status did not say the channel is off"
  assert_contains "$out" 'listener: running' \
    "status hid a listener that is still running, so a stranded one is invisible"

  pass "status still reports a running listener once the channel is off"
}

test_a_listener_this_home_does_not_own_is_never_signalled() {
  local home out pid
  home="$TMP_ROOT/optoutforeign"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  # Another listener holding the number, with an identity that cannot be its own.
  foreign_listener "$home"
  pid=$FOREIGN_PID
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"

  rm -f "$home/config/whatsapp.env"
  out=$(poll "$home")
  kill -0 "$pid" 2>/dev/null \
    || fail "the retiring cycle killed a process it never proved was its own listener"
  assert_contains "$out" 'wa-channel-error' \
    "the retiring cycle left an unclaimable listener record without saying so"
  assert_contains "$out" 'cannot prove' "the report did not name why nothing was signalled"
  assert_present "$home/state/wa-listener.pid" \
    "the retiring cycle discarded the record of a process it refused to signal"
  assert_absent "$home/state/wa-watch.check.sh" "the retiring cycle left the check shim armed"

  # The command path refuses for the same reason rather than guessing.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" stop >/dev/null 2>&1 \
    && fail "stop signalled a process it could not prove was this home's listener"
  kill -0 "$pid" 2>/dev/null \
    || fail "stop killed a process it could not prove was this home's listener"

  pass "a live process this home cannot claim is reported, never signalled"
}

# The same refusal, on the one path nobody is watching. The channel-off paths
# report an unclaimable pid rather than signalling it, but the poll's automatic
# restart is what runs unattended, and it is the direction where guessing costs
# more: spawning past a live stranger puts a SECOND connection on the one
# credential folder WhatsApp allows - the failure the whole design exists to
# avoid - and then overwrites the pid file, so the first process keeps running
# with nothing tracking it. Unattended is exactly when that happens and exactly
# when nobody sees it, so this path must be the same as every other.
test_the_restart_path_never_spawns_over_an_unclaimable_listener() {
  local home out pid
  home="$TMP_ROOT/restartforeign"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  # Alive, paired, and holding a pid this home cannot bind to its own listener:
  # everything the restart path needs to decide the listener is gone.
  foreign_listener "$home"
  pid=$FOREIGN_PID
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' \
    "the restart path passed an unclaimable listener record without saying so"
  assert_contains "$out" 'cannot prove' "the report did not name why nothing was started"
  [ "$(cat "$home/state/wa-listener.pid")" = "$pid" ] \
    || fail "the restart path overwrote the pid of a process it could not claim"
  kill -0 "$pid" 2>/dev/null \
    || fail "the restart path signalled a process it never proved was its own listener"
  assert_absent "$home/state/wa-listener.restart" \
    "the restart path spawned a second listener onto the one credential folder"

  # ...and it is deduped like every other fault, so an unattended home does not
  # wake firstmate every cycle over a condition only a human can clear.
  out=$(poll "$home")
  [ -z "$out" ] || fail "the unclaimable listener was reported again on the next cycle: $out"

  # The command that actually writes the pid file refuses for the same reason,
  # so the guard does not depend on the caller having checked first.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" start 2>&1) \
    && fail "start wrote over the pid of a process it could not claim"
  assert_contains "$out" 'cannot prove' "start did not say why it started nothing"
  [ "$(cat "$home/state/wa-listener.pid")" = "$pid" ] \
    || fail "start overwrote the pid of a process it could not claim"

  pass "the unattended restart path refuses an unclaimable listener like every other path"
}

# The listener and the shell library both decide whether a message id may become
# a path, and they have to decide it identically. When the listener was the more
# permissive of the two, a dot-leading id was stashed as a dotfile that `find`
# still lists and the drain's own glob never does, so the captain's message was
# dropped behind a fault line that could not even name it.
test_a_dot_leading_id_is_never_stashed() {
  command -v node >/dev/null 2>&1 || { pass "id rule agreement skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/dotid"
  new_home "$home"

  bash -c '. "$1"; fm_wa_id_safe ".HIDDEN"' _ "$LIB" \
    && fail "the shell library accepted a dot-leading id, so this test proves nothing"

  out=$(fixture "$home" "$(msg .HIDDEN 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"hidden"}')")
  assert_refused "$out" 'unsafe or missing message id' \
    "the listener stashed an id the poll would then refuse to use"
  assert_absent "$home/state/wa-inbox/.HIDDEN.json" \
    "a message record the drain's own glob can never see was created"

  pass "the listener and the shell library agree on which message ids are usable"
}

# A PATH holding every command this host has EXCEPT the named ones, so a script
# runs for real on a host that is missing exactly one tool. Building it from the
# real PATH rather than a hand-picked list is what keeps the assertion honest:
# the script has to get all the way to the missing tool to say anything at all.
path_excluding() {
  local dir=$1
  shift
  local excluded=" $* " entry name part
  mkdir -p "$dir"
  # shellcheck disable=SC2086 # PATH is a colon-separated list and is split on purpose.
  ( IFS=:; printf '%s\n' $PATH ) | while IFS= read -r part; do
    [ -n "$part" ] && [ -d "$part" ] || continue
    for entry in "$part"/*; do
      [ -f "$entry" ] && [ -x "$entry" ] || continue
      name=${entry##*/}
      case "$excluded" in
        *" $name "*) continue ;;
      esac
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null || true
    done
  done
}

path_without_sha256() {
  path_excluding "$1" sha256sum shasum
}

# Total silence with the captain's messages sitting in the inbox is the one
# outcome this channel exists to prevent, so a host that cannot digest the
# pending set has to say why instead of exiting quietly forever.
test_a_host_that_cannot_hash_says_so() {
  local home out bin
  home="$TMP_ROOT/nosha"
  new_home "$home"
  fake_listener "$home"
  stash_message "$home" MSGNOSHA
  bin="$TMP_ROOT/nosha-bin"
  path_without_sha256 "$bin"
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || { pass "digest failure skipped: this host has no digest tool to remove"; return 0; }

  out=$(PATH="$bin" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$POLL" 2>/dev/null)
  assert_contains "$out" 'wa-channel-error' \
    "a host that cannot digest the inbox went silent with a message pending"
  assert_contains "$out" 'sha256sum' "the report did not name what is missing"

  # ...and it is still deduped, so it is said once rather than every cycle.
  out=$(PATH="$bin" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$POLL" 2>/dev/null)
  [ -z "$out" ] || fail "the same digest fault was reported again instead of being deduped"

  pass "a host with no digest tool reports why instead of losing the inbox silently"
}

# A kill returns once the signal is delivered, not once the target is gone, so a
# process read in the very next command is still there - terminating, or waiting
# to be reaped. Every path that reaches SIGKILL is a repair for a listener that
# already stopped behaving, so a stop that judged itself on that one read would
# report failure exactly where the repair matters, and refuse the restart, the
# unpair and the switch-off that depend on it.
test_a_deaf_listener_is_reported_as_stopped_once_it_is() {
  local home out pid
  home="$TMP_ROOT/deafstop"
  new_home "$home"
  deaf_listener "$home"
  pid=$DEAF_PID

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" stop 2>&1) \
    || fail "stop reported failure for a listener it had in fact killed: $out"
  assert_contains "$out" 'listener stopped' "stop did not report stopping the deaf listener"
  if kill -0 "$pid" 2>/dev/null; then
    fail "a listener that ignored SIGTERM was left running after a stop"
  fi
  assert_absent "$home/state/wa-listener.pid" \
    "stop reported success but kept the pid record of a listener that is gone"
  assert_absent "$home/state/wa-listener.pid-identity" \
    "stop left the identity binding of a listener that is gone"

  pass "a listener that ignores SIGTERM is reported as stopped once SIGKILL has taken effect"
}

test_a_deaf_wedged_listener_is_cleaned_up_and_replaced() {
  local home bindir out pid waited=0
  home="$TMP_ROOT/deafwedge"
  new_home "$home"
  deaf_listener "$home"
  pid=$DEAF_PID
  # Alive, but with a connection that went away long ago.
  printf '1\n' > "$home/state/wa-listener.beat"
  touch -t 200001010000 "$home/state/wa-listener.beat"
  printf '{"state":"connected","me":"x","at":1}\n' > "$home/state/wa-listener.status"

  # A stand-in for the listener wrapper, so the replacement the cycle promises is
  # something this test can actually observe rather than infer.
  bindir="$TMP_ROOT/deafwedge-bin"
  mkdir -p "$bindir"
  cp "$POLL" "$LIB" "$bindir/"
  cat > "$bindir/fm-wa-listen.sh" <<SH
#!/usr/bin/env bash
printf 'spawned\n' > "$home/state/replacement-spawned"
SH
  chmod +x "$bindir/fm-wa-listen.sh"

  out=$(FM_HOME="$home" "$bindir/fm-wa-poll.sh" 2>/dev/null)
  assert_contains "$out" 'restarting it' \
    "a wedged listener was reported without saying it is being replaced"
  if kill -0 "$pid" 2>/dev/null; then
    fail "a wedged listener that ignored SIGTERM was left holding the channel"
  fi
  assert_absent "$home/state/wa-listener.pid" "the wedged listener's pid record outlived it"
  assert_absent "$home/state/wa-listener.pid-identity" \
    "the wedged listener's identity binding outlived it"
  assert_absent "$home/state/wa-listener.beat" "the wedged listener's beat outlived it"
  assert_absent "$home/state/wa-listener.status" "the wedged listener's reported state outlived it"
  while [ ! -s "$home/state/replacement-spawned" ] && [ "$waited" -lt 50 ]; do
    sleep 0.2
    waited=$(( waited + 1 ))
  done
  assert_present "$home/state/replacement-spawned" \
    "the cycle announced a restart and then never spawned the replacement"

  pass "a wedged listener that ignores SIGTERM is cleaned up and actually replaced"
}

# Disarming is what removes the one cycle that would otherwise have stopped the
# listener, so it is the sequence that strands a live linked device on the
# captain's own account unless disarm stops it itself.
test_disarm_stops_the_listener() {
  local home out pid
  home="$TMP_ROOT/disarmstop"
  new_home "$home"
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" disarm 2>&1) \
    || fail "disarm reported failure: $out"
  assert_contains "$out" 'disarmed' "disarm did not report retiring the check"
  assert_contains "$out" 'stopped the listener' "disarm did not report stopping the listener"
  if kill -0 "$pid" 2>/dev/null; then
    fail "disarm removed the cycle that would have stopped the listener and left it running"
  fi
  assert_absent "$home/state/wa-listener.pid" "disarm left the pid record behind"
  assert_absent "$home/state/wa-watch.check.sh" "disarm left the check shim armed"
  assert_absent "$home/config/wa-mode.env" "disarm left the watcher cadence behind"

  # The config never had to go for any of that, and removing it afterwards is
  # still a hard no-op rather than a second cleanup.
  rm -f "$home/config/whatsapp.env"
  out=$(poll "$home")
  [ -z "$out" ] || fail "the poll spoke after a disarm had already cleaned up: $out"

  pass "disarm stops the listener as well as retiring the check it needs to do that"
}

test_disarm_is_quiet_with_nothing_to_stop() {
  local home out
  home="$TMP_ROOT/disarmquiet"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" disarm 2>&1) \
    || fail "disarm reported failure with no listener running: $out"
  case "$out" in
    *'stopped the listener'*) fail "disarm claimed to stop a listener that was never running: $out" ;;
  esac

  # And again, on a home that is already fully disarmed.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" disarm 2>&1) \
    || fail "a second disarm reported failure: $out"
  assert_contains "$out" 'nothing armed' "a repeated disarm did not report an already-clean home"
  case "$out" in
    *'stopped the listener'*) fail "a repeated disarm claimed to stop a listener: $out" ;;
  esac

  pass "disarm is idempotent and says nothing about a listener that is not running"
}

test_disarm_never_signals_a_listener_this_home_cannot_claim() {
  local home out pid
  home="$TMP_ROOT/disarmforeign"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  # An unrelated process holding the number a dead listener left behind.
  foreign_listener "$home"
  pid=$FOREIGN_PID
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" disarm 2>&1) \
    && fail "disarm reported success over a live process it could not claim: $out"
  kill -0 "$pid" 2>/dev/null \
    || fail "disarm killed a process it never proved was this home's listener"
  assert_contains "$out" 'cannot prove' "disarm did not say why it signalled nothing"
  assert_present "$home/state/wa-listener.pid" \
    "disarm discarded the record of a process it refused to signal"
  assert_absent "$home/state/wa-watch.check.sh" \
    "disarm left the check shim armed after refusing to signal the recorded pid"

  pass "disarm reports a live process it cannot claim instead of killing it on a guess"
}

test_stopping_works_after_the_config_is_gone
test_the_retiring_cycle_stops_the_listener
test_status_reports_a_stranded_listener
test_a_listener_this_home_does_not_own_is_never_signalled
test_the_restart_path_never_spawns_over_an_unclaimable_listener
test_a_deaf_listener_is_reported_as_stopped_once_it_is
test_a_deaf_wedged_listener_is_cleaned_up_and_replaced
test_disarm_stops_the_listener
test_disarm_is_quiet_with_nothing_to_stop
test_disarm_never_signals_a_listener_this_home_cannot_claim
test_a_dot_leading_id_is_never_stashed
test_a_host_that_cannot_hash_says_so

# --- the channel goes down only for a reason, and comes back on its own ------

# Every reason a present config/whatsapp.env yields no captain looks the same
# from outside, and none of them is the deliberate opt-out. Answering them by
# stopping the listener and deleting the poll means one unlucky cycle - or one
# blanked value typed as a guess at the off switch - takes the channel down for
# good, after which he messages a home that will never answer and cannot tell
# that apart from being ignored. The report has to name the real off switches,
# because a file that read perfectly well and simply names nobody is the
# commonest way into this state.
test_an_unreadable_config_is_never_an_opt_out() {
  local variant home out pid
  for variant in empty truncated unreadable; do
    if [ "$variant" = unreadable ] && [ "$(id -u)" = 0 ]; then
      continue
    fi
    home="$TMP_ROOT/indeterminate-$variant"
    new_home "$home"
    fake_listener "$home"
    pid=$(cat "$home/state/wa-listener.pid")
    stash_message "$home" "MSGKEEP"
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 \
      || fail "arm failed for the $variant config"

    case "$variant" in
      empty) : > "$home/config/whatsapp.env" ;;
      truncated) printf 'FM_WA_CAP' > "$home/config/whatsapp.env" ;;
      unreadable) chmod 000 "$home/config/whatsapp.env" ;;
    esac

    out=$(poll "$home")
    assert_contains "$out" 'wa-channel-error' \
      "a $variant config was treated as an opt-out instead of being reported"
    assert_contains "$out" 'no captain could be read' \
      "the report did not say the configuration names no captain rather than being gone"
    assert_contains "$out" 'is not the off switch' \
      "the report did not name the deliberate off switches"

    kill -0 "$pid" 2>/dev/null \
      || fail "a $variant config stopped the listener"
    assert_present "$home/state/wa-watch.check.sh" \
      "a $variant config retired the check shim"
    assert_present "$home/state/wa-watch.check-trust" \
      "a $variant config retired the check registration"
    assert_present "$home/config/wa-mode.env" \
      "a $variant config removed the watcher cadence"
    assert_present "$home/state/wa-inbox/MSGKEEP.json" \
      "a $variant config destroyed a message the captain had already sent"

    # ...and it is said once, not once a cycle, so a blip is not a wake storm.
    out=$(poll "$home")
    [ -z "$out" ] || fail "the $variant config was reported again on the next cycle: $out"

    chmod 600 "$home/config/whatsapp.env" 2>/dev/null || true
  done

  pass "a configuration that names no captain leaves the channel armed and running"
}

# A home that never opted in has nothing armed and nothing running, so the poll
# must stay the hard no-op it has always been rather than reporting on a
# configuration it was never given.
test_an_unconfigured_home_is_still_silent() {
  local home out
  home="$TMP_ROOT/neveropted"
  mkdir -p "$home/state" "$home/config"
  chmod 700 "$home/state"
  : > "$home/config/whatsapp.env"

  out=$(poll "$home")
  [ -z "$out" ] || fail "a home that never armed the channel spoke: $out"

  pass "an unconfigured home stays a hard no-op even with an unusable config file"
}

# Nothing put the arming artifacts back once they were gone, so a home could sit
# there configured, listening to nothing, while the captain went on messaging
# it. Relay self-heals from exactly this because bootstrap re-runs its setup at
# every session start; this is the same shape.
test_a_configured_home_rearms_itself_at_session_start() {
  local home out
  home="$TMP_ROOT/rearm"
  new_home "$home"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"
  # However they went - a disarm, a restored backup, a half-finished arm - the
  # configuration still names the captain, so this home must not stay deaf.
  rm -f "$home/state/wa-watch.check.sh" "$home/state/wa-watch.check-trust" \
    "$home/config/wa-mode.env"

  out=$(FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null \
    | grep '^WA:' || true)
  assert_contains "$out" 're-armed' \
    "session start left a configured home unable to hear the captain"
  assert_present "$home/state/wa-watch.check.sh" "session start did not restore the check shim"
  assert_present "$home/state/wa-watch.check-trust" "session start did not restore the registration"
  assert_present "$home/config/wa-mode.env" "session start did not restore the watcher cadence"

  # Idempotent and silent: with the channel already armed it changes nothing.
  out=$(FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null \
    | grep '^WA:' || true)
  [ -z "$out" ] || fail "an already-armed home was reported again: $out"

  # And a home that never opted in is untouched, exactly as before.
  home="$TMP_ROOT/rearm-none"
  mkdir -p "$home/state" "$home/config"
  chmod 700 "$home/state"
  out=$(FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null \
    | grep '^WA:' || true)
  [ -z "$out" ] || fail "a home that never opted in was armed by session start: $out"
  assert_absent "$home/state/wa-watch.check.sh" "session start armed an unconfigured home"

  pass "a configured home whose arming artifacts went missing arms itself again"
}

# Session start and the channel itself have to agree on whether a home is on.
# Bootstrap used to decide with a raw read plus a digit filter, which keeps a
# number written into a note beside a blanked key: it would arm the check shim
# and the thirty-second cadence for a home whose own channel reports itself off,
# so the home sweeps for ever for a message it could never deliver. One reader
# decides, and it is the channel's.
test_session_start_arms_only_what_the_channel_itself_reads() {
  local home out
  home="$TMP_ROOT/rearm-blanked"
  mkdir -p "$home/state" "$home/config"
  chmod 700 "$home/state"
  printf 'FM_WA_CAPTAIN= # was %s, ask before re-enabling\n' "$CAPTAIN2" \
    > "$home/config/whatsapp.env"

  # The channel's own answer first, so the assertion below is about agreement
  # rather than about either side in isolation.
  [ -z "$(config_load "$home" captain)" ] \
    || fail "the channel itself read a captain out of a blanked key"

  out=$(FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null \
    | grep '^WA:' || true)
  [ -z "$out" ] || fail "session start armed a home whose channel reads itself off: $out"
  assert_absent "$home/state/wa-watch.check.sh" \
    "session start armed the check shim for a home that names no captain"
  assert_absent "$home/config/wa-mode.env" \
    "session start armed the 30s cadence for a home that names no captain"

  # And a line the channel refuses outright is not armed around either.
  printf 'FM_WA_CAPTAIN="%s\n' "$CAPTAIN" > "$home/config/whatsapp.env"
  out=$(FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null \
    | grep '^WA:' || true)
  [ -z "$out" ] || fail "session start armed a home whose configuration cannot be read: $out"
  assert_absent "$home/state/wa-watch.check.sh" \
    "session start armed the check shim from an unreadable configuration line"

  pass "session start arms a home only when the channel's own reader says it is on"
}

# --- opting out takes the captain's words with it ---------------------------

SECRET_TEXT='meet me at the harbour at dawn'

# Everything an opted-out home must not still be holding, written by hand so the
# assertion is about content rather than about which cycle happened to create
# what.
seed_message_state() {
  local home=$1
  mkdir -p "$home/state/wa-inbox" "$home/state/wa-seen" "$home/state/wa-sent" \
    "$home/state/wa-outbox"
  printf '{"schema":"fm-wa-inbox-v1","id":"MSGSECRET","text":"%s"}\n' "$SECRET_TEXT" \
    > "$home/state/wa-inbox/MSGSECRET.json"
  printf '%s\n' "$SECRET_TEXT" > "$home/state/wa-seen/MSGSECRET.seen"
  : > "$home/state/wa-sent/abc123.sent"
  printf '{"text":"%s"}\n' "$SECRET_TEXT" > "$home/state/wa-outbox/1-1.json"
  printf '1700000000\n' > "$home/state/wa-watermark"
  printf 'deadbeef\n' > "$home/state/wa-poll.offered"
  printf 'some earlier fault\n' > "$home/state/wa-poll.error"
  printf 'stashed %s\n' "$SECRET_TEXT" > "$home/state/wa-listener.log"
  printf '{"state":"connected"}\n' > "$home/state/wa-listener.status"
  printf '1\n' > "$home/state/wa-listener.beat"
}

assert_no_trace_of_the_captain() {
  local home=$1 what=$2 hit
  hit=$(grep -rl -- "$SECRET_TEXT" "$home" 2>/dev/null | head -n 1)
  [ -z "$hit" ] || fail "$what left the captain's own words behind in $hit"
  assert_absent "$home/state/wa-inbox" "$what left the stashed messages behind"
  assert_absent "$home/state/wa-seen" "$what left the per-message markers behind"
  assert_absent "$home/state/wa-sent" "$what left the outbound digests behind"
  assert_absent "$home/state/wa-outbox" "$what left the dry-run records behind"
  assert_absent "$home/state/wa-watermark" "$what left the watermark behind"
  assert_absent "$home/state/wa-poll.offered" "$what left the announcement marker behind"
  assert_absent "$home/state/wa-poll.error" "$what left the poll's fault record behind"
  assert_absent "$home/state/wa-listener.log" "$what left the listener log behind"
}

test_the_retiring_cycle_clears_the_captains_messages() {
  local home out pid
  home="$TMP_ROOT/optoutwipe"
  new_home "$home"
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")
  seed_message_state "$home"
  printf 'unrelated\n' > "$home/state/keepme"
  printf 'export FM_CHECK_INTERVAL=30\n' > "$home/config/x-mode.env"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"

  rm -f "$home/config/whatsapp.env"
  out=$(poll "$home")
  [ -z "$out" ] || fail "the retiring cycle spoke while cleaning up normally: $out"

  if kill -0 "$pid" 2>/dev/null; then
    fail "the retiring cycle cleared the records while the listener was still running"
  fi
  assert_no_trace_of_the_captain "$home" "the retiring cycle"
  assert_present "$home/state/keepme" "the retiring cycle removed an unrelated state file"
  assert_present "$home/config/x-mode.env" "the retiring cycle removed Relay's cadence file"

  # Idempotent with nothing left to clear.
  out=$(poll "$home")
  [ -z "$out" ] || fail "a second retiring cycle spoke: $out"

  pass "switching the channel off clears the captain's stashed messages, not just the shim"
}

test_unpair_clears_the_messages_only_once_the_channel_is_off() {
  local home out
  # A re-pair, with the channel still on: the credentials go, the captain's
  # undrained messages and the watermark that protects them do not.
  home="$TMP_ROOT/repairkeeps"
  new_home "$home"
  seed_message_state "$home"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" unpair 2>&1) \
    || fail "unpair failed during a re-pair: $out"
  assert_present "$home/state/wa-inbox/MSGSECRET.json" \
    "re-pairing destroyed a message the captain had sent and firstmate had not read"
  assert_present "$home/state/wa-watermark" \
    "re-pairing dropped the watermark, so old messages can replay as new instructions"

  # The last step of switching the channel off: everything goes.
  home="$TMP_ROOT/unpairwipe"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  seed_message_state "$home"
  rm -f "$home/config/whatsapp.env"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" unpair 2>&1) \
    || fail "unpair refused with the channel already off: $out"
  assert_contains "$out" 'cleared' "unpair did not report clearing the stashed messages"
  assert_absent "$home/state/wa-auth" "unpair left this listener's credentials behind"
  assert_no_trace_of_the_captain "$home" "unpair with the channel off"

  pass "unpair clears the stashed messages when it is a teardown, and never on a re-pair"
}

# The echo marker outlives the send by the listener's whole echo window, so a
# reply that was never even attempted must not leave one: the captain saying
# those same words back would be dropped as firstmate's own echo, from his side
# silently.
test_a_send_without_mudslide_leaves_no_echo_trap() {
  local home out bin
  home="$TMP_ROOT/nomudslide"
  new_home "$home"
  printf 'on it\n' > "$TMP_ROOT/nomudslide-reply.txt"
  bin="$TMP_ROOT/nomudslide-bin"
  path_excluding "$bin" mudslide

  out=$(PATH="$bin" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/nomudslide-reply.txt" 2>&1) \
    && fail "the send reported success with no mudslide installed: $out"
  assert_contains "$out" 'mudslide is not installed' "the failed send did not say why"

  [ -z "$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null)" ] \
    || fail "a send that could never happen left an echo marker behind"

  pass "a send with no mudslide installed leaves no digest to swallow the captain"
}

# --- an annotated configuration reads the way it is written ------------------

# config/whatsapp.env is presented as an env file, so the first thing anyone
# does to it is annotate a line - and until this it took the note as part of the
# value. Every key was affected and every one failed silently: a captain number
# with a comment appended matched no phone while the channel reported itself on,
# a device list reverted to the default that drops his own handset, and
# `FM_WA_DRY_RUN=1 # never send live while testing` loaded as OFF, so the file
# said the opposite of what the home did. Read here through the real
# fm_wa_load_config, one key at a time.
config_load() {
  local home=$1 field=$2
  ( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    FM_HOME=$home fm_wa_load_config >/dev/null 2>&1
    case "$field" in
      captain) printf '%s' "$FM_WA_CAPTAIN" ;;
      devices) printf '%s' "$FM_WA_ALLOW_DEVICES" ;;
      dry) printf '%s' "$FM_WA_DRY_RUN" ;;
      horizon) printf '%s' "$FM_WA_HISTORY_HORIZON" ;;
      reannounce) printf '%s' "$FM_WA_REANNOUNCE" ;;
      baileys) printf '%s' "$FM_WA_BAILEYS_DIR" ;;
      fault) printf '%s' "$FM_WA_CONFIG_ERROR" ;;
    esac )
}

write_config() {
  local home=$1
  shift
  mkdir -p "$home/config"
  printf '%s\n' "$@" > "$home/config/whatsapp.env"
}

test_an_annotated_configuration_reads_the_way_it_is_written() {
  local home out
  home="$TMP_ROOT/annotated"
  mkdir -p "$home/state" "$home/config"

  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN # main phone"
  out=$(config_load "$home" captain)
  [ "$out" = "$CAPTAIN" ] || fail "an annotated captain number loaded as '$out'"
  [ -z "$(config_load "$home" fault)" ] || fail "a well-formed annotated line was reported as a fault"

  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN,$CAPTAIN2   # both phones"
  out=$(config_load "$home" captain)
  [ "$out" = "$CAPTAIN $CAPTAIN2" ] || fail "an annotated captain list loaded as '$out'"

  # The one with real-world consequences: the operator wrote down that this home
  # must not send, and the home reading that as permission to send live is the
  # config and its behaviour being exact opposites.
  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_DRY_RUN=1 # never send live while testing"
  [ "$(config_load "$home" dry)" = 1 ] \
    || fail "an annotated FM_WA_DRY_RUN=1 turned dry run OFF, so a rehearsing home sends live traffic"

  # The device list is the likeliest reason a correctly configured channel still
  # hears nothing, so silently reverting it to 0 hides the fix as well as the fault.
  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_ALLOW_DEVICES=0,2,22 # phone and web"
  out=$(config_load "$home" devices)
  [ "$out" = "0,2,22" ] || fail "an annotated device list loaded as '$out'"

  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_HISTORY_HORIZON=600 # only the last ten minutes"
  [ "$(config_load "$home" horizon)" = 600 ] || fail "an annotated FM_WA_HISTORY_HORIZON did not load"

  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_REANNOUNCE=900 # nag sooner"
  [ "$(config_load "$home" reannounce)" = 900 ] || fail "an annotated FM_WA_REANNOUNCE did not load"

  # A `#` that is genuinely inside quotes belongs to the value, exactly as the
  # shell would read it. A real package directory, so the value survives the
  # usability check as well as the parse.
  mkdir -p "$TMP_ROOT/wa#lib/lib"
  : > "$TMP_ROOT/wa#lib/lib/index.js"
  write_config "$home" "FM_WA_CAPTAIN=\"$CAPTAIN\" # quoted" \
    "FM_WA_BAILEYS_DIR=\"$TMP_ROOT/wa#lib\" # quoted too"
  [ "$(config_load "$home" captain)" = "$CAPTAIN" ] || fail "a quoted captain number did not load"
  out=$(config_load "$home" baileys)
  [ "$out" = "$TMP_ROOT/wa#lib" ] || fail "a quoted value lost the # that was part of it: '$out'"
  [ -z "$(config_load "$home" fault)" ] || fail "a usable quoted baileys directory was reported as a fault"

  # Stripping the note must not start expanding the value: the file is still
  # read as data, so a substitution stays the literal text it was written as.
  rm -f "$TMP_ROOT/annotated-PWNED"
  write_config "$home" "FM_WA_CAPTAIN=\"\$(touch $TMP_ROOT/annotated-PWNED)$CAPTAIN\" # sneaky"
  config_load "$home" captain >/dev/null
  assert_absent "$TMP_ROOT/annotated-PWNED" \
    "reading the configuration executed a substitution written into it"

  pass "an annotated configuration line loads the value, not the note"
}

# Blanking a key and writing down why is how an operator retires a number, and
# for a while the note was read as the value - so `FM_WA_CAPTAIN= # was
# 447700900999` armed the channel on the very number he had just taken out,
# fanned every reply to it, and accepted anything it sent as an instruction.
# The other keys landed the other way round, raising a channel fault for a line
# that is not malformed at all. Empty once the note is removed means empty.
test_a_blanked_key_keeps_its_note_out_of_its_value() {
  local home out
  home="$TMP_ROOT/blanked"
  mkdir -p "$home/state" "$home/config"

  write_config "$home" "FM_WA_CAPTAIN= # was $CAPTAIN2, ask before re-enabling"
  out=$(config_load "$home" captain)
  [ -z "$out" ] \
    || fail "a blanked captain key resurrected '$out' out of the note beside it"
  [ -z "$(config_load "$home" fault)" ] \
    || fail "blanking a key with a note beside it was reported as unreadable"

  # Blanked with no note at all, for the same reason: the two must agree.
  write_config "$home" "FM_WA_CAPTAIN="
  [ -z "$(config_load "$home" captain)" ] || fail "a blanked captain key produced a number"

  # The switch the operator is most likely to blank while deciding: read as off
  # here it sends live traffic, so it must be the documented default and not the
  # word "decide" turning into one.
  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_DRY_RUN= # decide later"
  [ -z "$(config_load "$home" dry)" ] || fail "a blanked FM_WA_DRY_RUN did not read as off"
  [ -z "$(config_load "$home" fault)" ] \
    || fail "a blanked FM_WA_DRY_RUN with a note was reported as unreadable"

  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_ALLOW_DEVICES= # widen later"
  [ "$(config_load "$home" devices)" = 0 ] \
    || fail "a blanked device list did not fall back to the documented default"
  [ -z "$(config_load "$home" fault)" ] \
    || fail "a blanked device list with a note was reported as unreadable"

  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_HISTORY_HORIZON= # none for now" \
    "FM_WA_REANNOUNCE= # default is fine"
  [ "$(config_load "$home" horizon)" = 0 ] || fail "a blanked history horizon did not default"
  [ "$(config_load "$home" reannounce)" = 1800 ] || fail "a blanked re-announce did not default"
  [ -z "$(config_load "$home" fault)" ] \
    || fail "blanked interval keys with notes beside them were reported as unreadable"

  # A `#` with nothing between it and the `=` is a value, not a note, exactly as
  # the shell reads it - stripping notes must not start eating values.
  write_config "$home" "FM_WA_CAPTAIN=#$CAPTAIN"
  [ "$(config_load "$home" captain)" = "$CAPTAIN" ] \
    || fail "a # written against the = was treated as a note instead of a value"

  pass "a key blanked with a note beside it stays blank"
}

# FM_WA_BAILEYS_DIR was the one key handed to the listener unchecked, so a stale
# or mistyped path surfaced three restarts later as "will not stay healthy after
# restart" - a remedy that cannot repair a wrong path. It belongs on the same
# footing as every other key: absent takes its default in silence, present and
# unusable says so.
test_an_unusable_baileys_directory_is_reported() {
  local home out
  home="$TMP_ROOT/baileysdir"
  mkdir -p "$home/state" "$home/config"

  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN"
  [ -z "$(config_load "$home" fault)" ] \
    || fail "an absent FM_WA_BAILEYS_DIR did not take its auto-discovery default in silence"

  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_BAILEYS_DIR=$TMP_ROOT/no-such-baileys"
  out=$(config_load "$home" fault)
  assert_contains "$out" 'FM_WA_BAILEYS_DIR' "a baileys directory that does not exist was not reported"
  [ -z "$(config_load "$home" baileys)" ] \
    || fail "an unusable baileys directory was still handed to the listener"

  # A directory that is there but holds no package is the likelier typo, and it
  # fails in exactly the same unhelpful way.
  mkdir -p "$TMP_ROOT/empty-baileys"
  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_BAILEYS_DIR=$TMP_ROOT/empty-baileys"
  assert_contains "$(config_load "$home" fault)" 'FM_WA_BAILEYS_DIR' \
    "a directory holding no baileys package was accepted"

  mkdir -p "$TMP_ROOT/real-baileys/lib"
  : > "$TMP_ROOT/real-baileys/lib/index.js"
  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_BAILEYS_DIR=$TMP_ROOT/real-baileys"
  [ "$(config_load "$home" baileys)" = "$TMP_ROOT/real-baileys" ] \
    || fail "a usable baileys directory did not survive the check"
  [ -z "$(config_load "$home" fault)" ] || fail "a usable baileys directory was reported as a fault"

  pass "a baileys directory that cannot be used is reported instead of failing as a sick listener"
}

# The whole class of bug here is a value that quietly became a default, so a
# line that cannot be read must announce itself rather than joining it.
test_a_configuration_line_that_cannot_be_read_is_reported() {
  local home out
  home="$TMP_ROOT/badline"
  mkdir -p "$home/state" "$home/config"

  write_config "$home" "FM_WA_CAPTAIN=\"$CAPTAIN" 
  out=$(config_load "$home" fault)
  assert_contains "$out" 'FM_WA_CAPTAIN' "an unterminated quote was not reported against its key"
  [ -z "$(config_load "$home" captain)" ] \
    || fail "an unterminated quote still produced a captain number"

  write_config "$home" "FM_WA_CAPTAIN=\"$CAPTAIN\" oops"
  assert_contains "$(config_load "$home" fault)" 'FM_WA_CAPTAIN' \
    "text after a closing quote was accepted as a value"

  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_ALLOW_DEVICES=phone,web"
  out=$(config_load "$home" fault)
  assert_contains "$out" 'FM_WA_ALLOW_DEVICES' "an unusable device list was not reported"
  [ "$(config_load "$home" devices)" = 0 ] \
    || fail "an unusable device list did not fall back to the documented default"

  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_DRY_RUN=maybe"
  assert_contains "$(config_load "$home" fault)" 'FM_WA_DRY_RUN' \
    "a dry-run switch that is neither on nor off was not reported"

  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_REANNOUNCE=half an hour"
  assert_contains "$(config_load "$home" fault)" 'FM_WA_REANNOUNCE' \
    "a re-announce interval that is not a number of seconds was not reported"

  write_config "$home" "FM_WA_CAPTAIN=nobody"
  assert_contains "$(config_load "$home" fault)" 'names no number' \
    "a captain value naming no number was not reported"

  pass "a configuration line that cannot be read is reported instead of silently defaulting"
}

# ...and it reaches the captain through the channel's own fault path, once,
# rather than becoming a wake every cycle for as long as the line is there.
test_a_configuration_fault_reaches_the_captain_once() {
  local home out
  home="$TMP_ROOT/badlinepoll"
  new_home "$home"
  fake_listener "$home"
  stash_message "$home" MSGBADCFG
  printf 'FM_WA_CAPTAIN=%s\nFM_WA_ALLOW_DEVICES=phone\n' "$CAPTAIN" > "$home/config/whatsapp.env"

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "an unusable configuration value was never reported"
  assert_contains "$out" 'FM_WA_ALLOW_DEVICES' "the report did not name the key to fix"
  assert_not_contains "$out" 'wa-message' "a fault cycle also announced the inbox"

  # Said once. The message the captain is waiting on is not starved behind it.
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending, including MSGBADCFG' \
    "the pending message stayed buried behind the configuration fault"
  assert_not_contains "$out" 'wa-channel-error' "the configuration fault was reported twice"

  # A quiet cycle clears the ordinary poll marker, and a permanent fault sharing
  # it would be forgotten and re-reported for ever - one bad line becoming a
  # wake storm. Draining the inbox is the quiet cycle.
  rm -f "$home/state/wa-inbox/MSGBADCFG.json"
  out=$(poll "$home")
  [ -z "$out" ] || fail "the configuration fault re-fired on a quiet cycle: $out"
  out=$(poll "$home")
  [ -z "$out" ] || fail "the configuration fault re-fired on a later quiet cycle: $out"

  # Fixed at the file, reported again if it ever comes back.
  printf 'FM_WA_CAPTAIN=%s\nFM_WA_ALLOW_DEVICES=0,22\n' "$CAPTAIN" > "$home/config/whatsapp.env"
  out=$(poll "$home")
  [ -z "$out" ] || fail "a repaired configuration still reported a fault: $out"
  printf 'FM_WA_CAPTAIN=%s\nFM_WA_ALLOW_DEVICES=phone\n' "$CAPTAIN" > "$home/config/whatsapp.env"
  out=$(poll "$home")
  assert_contains "$out" 'FM_WA_ALLOW_DEVICES' \
    "a fault that came back after being fixed was never reported again"

  pass "a configuration fault reaches the captain once and stays reportable"
}

# The end-to-end consequence of the dry-run key, driven through the real send
# rather than only through the parse: the operator wrote that this home must not
# send, so nothing may leave it.
test_an_annotated_dry_run_still_sends_nothing() {
  local home out bin
  home="$TMP_ROOT/annotateddry"
  mkdir -p "$home/state" "$home/config"
  chmod 700 "$home/state"
  write_config "$home" "FM_WA_CAPTAIN=$CAPTAIN" "FM_WA_DRY_RUN=1 # never send live while testing"
  printf 'Captain, shipshape.\n' > "$TMP_ROOT/annotateddry-reply.txt"

  # No mudslide on PATH at all, so a send that went live could not even pretend
  # to succeed - the dry run is the only way this can pass.
  bin="$TMP_ROOT/annotateddry-bin"
  path_excluding "$bin" mudslide

  out=$(PATH="$bin" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/annotateddry-reply.txt" 2>&1) \
    || fail "the annotated dry run failed: $out"
  assert_contains "$out" 'nothing sent' "the annotated dry run did not report itself as a dry run"
  [ "$(find "$home/state/wa-outbox" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "the annotated dry run did not record what it would have sent"

  pass "an annotated FM_WA_DRY_RUN=1 keeps the home from sending live traffic"
}

# A reply that never arrived is the one failure this channel cannot afford, and
# mudslide's own output is the only place it says why. Reporting which phone
# missed it while discarding that output names the symptom and throws away the
# diagnosis - and now that a reply fans out, one number reachable and another
# not is the commonest real failure, not the rare one.
test_a_partial_delivery_reports_what_mudslide_said() {
  local home fakebin out
  home="$TMP_ROOT/partialsays"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s,%s\n' "$CAPTAIN" "$CAPTAIN2" > "$home/config/whatsapp.env"
  printf 'Captain, the build is green.\n' > "$TMP_ROOT/partialsays-reply.txt"

  fakebin=$(fm_fakebin "$TMP_ROOT/partialsays-bin")
  cat > "$fakebin/mudslide" <<'SH'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    [0-9][0-9]*)
      if [ "$a" = "${FAIL_FOR:-}" ]; then
        echo "not a WhatsApp account: $a" >&2
        exit 1
      fi
      break ;;
  esac
done
exit 0
SH
  chmod +x "$fakebin/mudslide"

  out=$(PATH="$fakebin:$PATH" FAIL_FOR="$CAPTAIN2" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/partialsays-reply.txt" 2>&1) \
    && fail "a partial delivery was reported as success: $out"
  assert_contains "$out" "$CAPTAIN2" "the partial failure did not name the number that missed it"
  assert_contains "$out" 'mudslide said' "the partial failure discarded mudslide's own output"
  assert_contains "$out" 'not a WhatsApp account' "the cause of the missed delivery was never printed"

  # A total failure still says the same thing, so the two paths cannot drift.
  out=$(PATH="$fakebin:$PATH" FAIL_FOR="$CAPTAIN" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --to "$CAPTAIN" --text-file "$TMP_ROOT/partialsays-reply.txt" 2>&1) \
    && fail "a failed send was reported as success: $out"
  assert_contains "$out" 'not a WhatsApp account' "a total failure stopped reporting mudslide's output"

  pass "a delivery that missed a phone reports mudslide's own cause, partial or total"
}

# The dry run is evidence, so its output has to match what is on disk: a later
# recipient failing to record rolls the whole run back, and lines already
# printed would leave the operator holding the names of files that are gone.
test_a_rolled_back_dry_run_names_no_record() {
  local home fakebin out records real_mktemp
  # Resolved BEFORE the fake goes on PATH: a command prefix's assignments take
  # effect left to right, so resolving it inline would point the stub at itself.
  real_mktemp=$(command -v mktemp)
  home="$TMP_ROOT/dryrollback"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s,%s\n' "$CAPTAIN" "$CAPTAIN2" > "$home/config/whatsapp.env"
  printf 'Captain, shipshape.\n' > "$TMP_ROOT/dryrollback-reply.txt"

  # Lets the first delivery record and refuses the second, which is the only
  # shape that can print a line and then take the file away again.
  fakebin=$(fm_fakebin "$TMP_ROOT/dryrollback-bin")
  cat > "$fakebin/mktemp" <<'SH'
#!/bin/sh
case "${1:-}" in
  */wa-outbox/*)
    n=$(cat "$MKTEMP_COUNT" 2>/dev/null) || n=0
    n=$(( n + 1 ))
    printf '%s\n' "$n" > "$MKTEMP_COUNT"
    [ "$n" -ge 2 ] && exit 1
    ;;
esac
exec "$REAL_MKTEMP" "$@"
SH
  chmod +x "$fakebin/mktemp"
  : > "$TMP_ROOT/dryrollback.count"

  out=$(PATH="$fakebin:$PATH" MKTEMP_COUNT="$TMP_ROOT/dryrollback.count" \
    REAL_MKTEMP="$real_mktemp" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/dryrollback-reply.txt" 2>&1) \
    && fail "a dry run that could not record every delivery reported success: $out"
  assert_contains "$out" 'cannot record the dry-run reply' "the rolled-back dry run did not say why"
  assert_not_contains "$out" 'dry-run: recorded' \
    "the rolled-back dry run named a record it then deleted"

  records=$(find "$home/state/wa-outbox" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$records" -eq 0 ] || fail "the rolled-back dry run left $records records behind"
  [ -z "$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null)" ] \
    || fail "a dry run that recorded nothing left an echo marker behind"

  pass "a dry run that rolls back names no record it has taken away"
}

test_an_unreadable_config_is_never_an_opt_out
test_an_unconfigured_home_is_still_silent
test_a_configured_home_rearms_itself_at_session_start
test_session_start_arms_only_what_the_channel_itself_reads
test_the_retiring_cycle_clears_the_captains_messages
test_unpair_clears_the_messages_only_once_the_channel_is_off
test_a_send_without_mudslide_leaves_no_echo_trap
test_one_captain_number_parses_exactly_as_before
test_two_captain_numbers_parse_as_a_list
test_a_configuration_naming_no_number_is_still_refused
test_both_entry_points_read_one_captain_list
test_a_second_phone_reaches_us_by_messaging_in
test_a_lid_chat_is_admitted_by_its_resolved_number
test_the_lid_self_chat_is_proved_by_our_own_credentials
test_a_lid_chat_is_never_trusted_on_its_own
test_our_own_outgoing_words_are_never_an_instruction
test_an_unresolvable_lid_is_refused_and_said_out_loud
test_a_recycled_pid_is_a_stale_record_not_an_outage
test_a_reply_reaches_every_captain_number
test_pairing_uses_one_number_not_the_whole_list
test_every_delivery_of_one_reply_has_its_own_echo_marker
test_a_redelivered_echo_does_not_spend_a_second_marker
test_a_redelivered_self_chat_echo_leaves_the_other_marker_alone
test_an_identical_reply_adds_markers_rather_than_replacing_them
test_a_phone_that_missed_the_reply_drops_its_own_marker
test_a_failed_send_drops_its_markers_under_a_home_with_a_space
test_a_dry_run_records_every_delivery_it_would_make
test_an_annotated_configuration_reads_the_way_it_is_written
test_a_blanked_key_keeps_its_note_out_of_its_value
test_an_unusable_baileys_directory_is_reported
test_a_configuration_line_that_cannot_be_read_is_reported
test_a_configuration_fault_reaches_the_captain_once
test_an_annotated_dry_run_still_sends_nothing
test_a_partial_delivery_reports_what_mudslide_said
test_a_rolled_back_dry_run_names_no_record
