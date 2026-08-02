#!/usr/bin/env bash
# tests/fm-afk-launch.test.sh - the script-owned, backend-aware away-daemon
# launch (bin/fm-afk-launch.sh) and the away-mode stale-artifact lifecycle fixes
# (bin/fm-afk-start.sh). Two layers:
#
#   UNIT (always run, no backend): the session-scoped stale-artifact clear on a
#   fresh entry vs a refresh, and the correct-ordered stop (daemon SIGTERM'd
#   while state/.afk is still present, .afk cleared last).
#
#   E2E TOPOLOGY (per backend, skipped when its tool is absent): the anti-
#   regression for the pane split/shrink - entering AND exiting away mode leaves
#   the captain's active tab topology UNCHANGED, because the daemon lands in a
#   NON-VISIBLE separate terminal (a herdr dedicated workspace, a detached tmux
#   session), never a split of the captain's pane. The herdr path runs on a
#   throwaway, NEVER-default HERDR_SESSION and asserts the default session is
#   byte-identical via the fm-herdr-lab.sh fleet-state tripwire; the tmux path
#   uses uniquely-named throwaway sessions killed by exact name. A harmless
#   sleeper replaces the real daemon (FM_AFK_LAUNCH_ENTRY) so the test observes
#   only the terminal lifecycle.
set -u
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
START="$ROOT/bin/fm-afk-start.sh"

FAILED=0
FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS=${FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS:-30}
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains() { case "$1" in *"$2"*) : ;; *) fail "$3" ;; esac; }

SLEEPER=$(mktemp "${TMPDIR:-/tmp}/fm-afk-sleeper.XXXXXX")
printf '#!/usr/bin/env bash\nexec sleep 600\n' > "$SLEEPER"
chmod +x "$SLEEPER"
TRACK_TMUX_SESSIONS=""
GLOBAL_CLEANUP() {
  rm -f "$SLEEPER" 2>/dev/null || true
  local s
  for s in $TRACK_TMUX_SESSIONS; do
    tmux kill-session -t "$s" 2>/dev/null || true
  done
}
trap GLOBAL_CLEANUP EXIT

# ---------------------------------------------------------------------------
# UNIT 1: fm_afk_clear_stale_artifacts removes exactly the three stale artifacts.
# ---------------------------------------------------------------------------
unit_clear_stale() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-clear.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  : > "$st/state/.subsuper-escalations.since"
  : > "$st/state/.subsuper-inject-wedged"
  : > "$st/state/.wake-queue"          # durable queue must be untouched
  # Source fm-afk-start.sh inside a child bash (it sets `set -eu` and would
  # otherwise leak that into this test shell) and call the clear helper.
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    bash -c '. "$1"; fm_afk_clear_stale_artifacts "$2"' _ "$START" "$st/state"
  if [ ! -e "$st/state/.subsuper-escalations" ] \
     && [ ! -e "$st/state/.subsuper-escalations.since" ] \
     && [ ! -e "$st/state/.subsuper-inject-wedged" ]; then
    pass "clear-stale: removes escalations buffer, sidecar, and wedge marker"
  else
    fail "clear-stale: stale artifacts survived"
  fi
  if [ -e "$st/state/.wake-queue" ]; then
    pass "clear-stale: leaves the durable wake-queue intact (no pending work dropped)"
  else
    fail "clear-stale: removed the durable wake-queue"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT 2: a FRESH entry clears; a REFRESH (daemon already alive) preserves the
# current session's buffered escalations.
# ---------------------------------------------------------------------------
unit_fresh_vs_refresh() {
  local st sleep_pid lock
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-refresh.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  : > "$st/state/.subsuper-inject-wedged"
  # A live "daemon": a real process whose identity the lock records, so
  # daemon_lock_held_by_live_daemon returns true (a refresh).
  sleep 600 &
  sleep_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$sleep_pid" > "$lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$sleep_pid" > "$lock/pid-identity" 2>/dev/null ) || true
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$START" >/dev/null 2>&1
  if [ -e "$st/state/.subsuper-escalations" ] && [ -e "$st/state/.subsuper-inject-wedged" ]; then
    pass "refresh: daemon already alive - stale artifacts preserved (current session's buffer kept)"
  else
    fail "refresh: incorrectly cleared the current session's buffered escalations"
  fi
  kill "$sleep_pid" 2>/dev/null || true
  wait "$sleep_pid" 2>/dev/null || true
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT 3: exit ordering - fm_afk_launch_stop SIGTERMs the daemon WHILE .afk is
# still present (so its flush is not a no-op), and clears .afk last.
# ---------------------------------------------------------------------------
unit_stop_ordering() {
  local st lock marker daemon_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop.XXXXXX")
  mkdir -p "$st/state"
  date '+%s' > "$st/state/.afk"
  marker="$st/afk-at-term"
  # A fake daemon: on SIGTERM, record whether .afk was still present, then exit.
  bash -c '
    trap "if [ -f \"$1/state/.afk\" ]; then echo present > \"$2\"; else echo absent > \"$2\"; fi; exit 0" TERM
    while :; do sleep 0.2; done
  ' _ "$st" "$marker" &
  daemon_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$daemon_pid" > "$lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$lock/pid-identity" 2>/dev/null ) || true
  printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if [ "$(cat "$marker" 2>/dev/null || echo missing)" = present ]; then
    pass "stop-ordering: daemon SIGTERM'd while .afk still present (flush is not a no-op)"
  else
    fail "stop-ordering: .afk was already cleared when the daemon got SIGTERM"
  fi
  if [ ! -e "$st/state/.afk" ]; then
    pass "stop-ordering: .afk cleared last"
  else
    fail "stop-ordering: .afk not cleared"
  fi
  if [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop-ordering: daemon-terminal record removed"
  else
    fail "stop-ordering: record not removed"
  fi
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_stop_rejects_reused_pid() {
  local st lock sleeper_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-pid-reuse.XXXXXX")
  mkdir -p "$st/state"
  date '+%s' > "$st/state/.afk"
  sleep 600 &
  sleeper_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$sleeper_pid" > "$lock/pid"
  printf 'different-process-identity' > "$lock/pid-identity"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if kill -0 "$sleeper_pid" 2>/dev/null; then
    pass "stop identity: stale lock cannot signal an unrelated live process"
  else
    fail "stop identity: stale lock signaled an unrelated live process"
  fi
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_stop_rejects_native_marker_for_unrelated_command() {
  local st sleeper_pid identity
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native-command.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
  sleep 30 & sleeper_pid=$!
  identity=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '. "$1"; fm_afk_native_process_identity "$2"' _ "$START" "$sleeper_pid")
  printf '%s\n%s\n' "$sleeper_pid" "$identity" > "$st/state/.afk-native-process"
  if ! FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" start-native >/dev/null 2>&1 \
    && ! FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1 \
    && kill -0 "$sleeper_pid" 2>/dev/null \
    && [ -e "$st/state/.afk" ] && [ -e "$st/state/.afk-native-process" ]; then
    pass "native process identity: matching PID start time cannot authorize an unrelated command"
  else
    fail "native process identity: unrelated command was refreshed, signaled, or cleared"
  fi
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_native_command_identity_is_anchored() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-command-shape.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_command_runs_script "  $FM_AFK_START_DIR/fm-afk-start.sh" "$FM_AFK_START_DIR/fm-afk-start.sh"
    fm_afk_command_runs_script "/bin/bash $FM_AFK_DAEMON" "$FM_AFK_DAEMON"
    fm_afk_command_runs_script "bash fm-supervise-daemon.sh" "$FM_AFK_DAEMON"
    ! fm_afk_command_runs_script "sleep 30 --note=fm-supervise-daemon.sh" "$FM_AFK_DAEMON"
    ! fm_afk_command_runs_script "/tmp/fm-supervise-daemon.sh" "$FM_AFK_DAEMON"
  ' _ "$START"; then
    pass "native process identity: direct and interpreter script shapes are anchored"
  else
    fail "native process identity: rejected a daemon shape or accepted a substring mention"
  fi
  rm -rf "$st"
}

unit_native_process_marker_is_one_bounded_snapshot() {
  local st marker
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native-marker.XXXXXX")
  mkdir -p "$st/state"
  marker="$st/state/.afk-native-process"
  printf '123\noriginal-identity\n' > "$marker"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    head() {
      command head "$@"
      printf "999\nreplacement-identity\n" > "$FM_AFK_NATIVE_PROCESS"
    }
    fm_afk_native_process_identity() {
      [ "$1" = 123 ] || return 1
      printf "original-identity\n"
    }
    fm_afk_native_process_command_matches() { return 0; }
    fm_afk_native_process_live
    [ "$FM_AFK_NATIVE_PID" = 123 ]
  ' _ "$START"; then
    pass "native process marker: validation uses one bounded snapshot"
  else
    fail "native process marker: validation reopened or mixed marker snapshots"
  fi
  printf '123\nidentity\nextra\n' > "$marker"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    ! fm_afk_native_process_live
    [ "$FM_AFK_NATIVE_PROCESS_UNSAFE" = 0 ]
  ' _ "$START"; then
    pass "native process marker: malformed records keep unsafe-command state clear"
  else
    fail "native process marker: malformed record changed unsafe-command semantics"
  fi
  {
    printf '123\nidentity\n'
    head -c 4096 /dev/zero
  } > "$marker"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    ! fm_afk_native_process_live
    [ "$FM_AFK_NATIVE_PROCESS_UNSAFE" = 0 ]
  ' _ "$START"; then
    pass "native process marker: oversized records are rejected before parsing"
  else
    fail "native process marker: oversized record was accepted or marked command-unsafe"
  fi
  rm -rf "$st"
}

unit_failed_start_rolls_back_state() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-failed-start.XXXXXX")
  mkdir -p "$st/state"
  printf 'pending\n' > "$st/state/.subsuper-escalations"
  printf 'wedged\n' > "$st/state/.subsuper-inject-wedged"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=unsupported "$LAUNCH" start >/dev/null 2>&1; then
    fail "failed start: unsupported backend unexpectedly succeeded"
  elif [ ! -e "$st/state/.afk" ] \
    && [ "$(cat "$st/state/.subsuper-escalations")" = pending ] \
    && [ "$(cat "$st/state/.subsuper-inject-wedged")" = wedged ]; then
    pass "failed start: away flag and delivery artifacts roll back"
  else
    fail "failed start: left false away state or discarded delivery artifacts"
  fi
  rm -rf "$st"
}

unit_concurrent_start_serialized() {
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found (concurrent start)"; return 0; }
  local st cap_session cap_pane first second rec count
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-concurrent.XXXXXX")
  cap_session="fm-afk-concurrent-cap-$$"
  tmux new-session -d -s "$cap_session" 2>/dev/null || { fail "concurrent start: captain session creation failed"; rm -rf "$st"; return 0; }
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $cap_session"
  cap_pane=$(tmux display-message -p -t "$cap_session" '#{pane_id}')
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET="$cap_pane" \
    FM_SUPERVISOR_BACKEND=tmux FM_AFK_LAUNCH_ENTRY="$SLEEPER" "$LAUNCH" start >/dev/null 2>&1 & first=$!
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET="$cap_pane" \
    FM_SUPERVISOR_BACKEND=tmux FM_AFK_LAUNCH_ENTRY="$SLEEPER" "$LAUNCH" start >/dev/null 2>&1 & second=$!
  wait "$first"; wait "$second"
  rec=$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)
  count=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | awk -v expected="$rec" '$0 == expected {n++} END{print n+0}')
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $rec"
  if [ -n "$rec" ] && tmux has-session -t "$rec" 2>/dev/null && [ "$count" -eq 1 ]; then
    pass "concurrent start: one serialized daemon terminal remains tracked"
  else
    fail "concurrent start: leaked or lost daemon terminal (count $count, record $rec)"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  tmux kill-session -t "$cap_session" 2>/dev/null || true
  rm -rf "$st"
}

unit_lock_initialization_grace() {
  local st marker initializer
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-init.XXXXXX")
  marker="$st/initialized"
  mkdir -p "$st/state/.afk-launch.lock"
  (
    sleep 0.15
    if [ -d "$st/state/.afk-launch.lock" ]; then
      printf '%s' "$$" > "$st/state/.afk-launch.lock/pid"
      ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$$" > "$st/state/.afk-launch.lock/pid-identity" 2>/dev/null ) || true
      : > "$marker"
      sleep 0.15
      rm -rf "$st/state/.afk-launch.lock"
    fi
  ) &
  initializer=$!
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_lock_acquire
    fm_afk_launch_lock_release
  ' _ "$LAUNCH" && [ -e "$marker" ]; then
    pass "launcher lock: incomplete publication receives initialization grace"
  else
    fail "launcher lock: contender removed a lock during initialization"
  fi
  wait "$initializer" 2>/dev/null || true
  rm -rf "$st"
}

unit_stale_lock_reclaim_is_serialized() {
  local st marker pids="" pid failures=0 count
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-stale.XXXXXX")
  marker="$st/acquired"
  mkdir -p "$st/state/.afk-launch.lock"
  printf '%s' "$$" > "$st/state/.afk-launch.lock/pid"
  printf 'different-process-identity' > "$st/state/.afk-launch.lock/pid-identity"
  for i in 1 2 3 4 5 6 7 8; do
    FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" MARKER="$marker" bash -c '
      . "$1"
      fm_afk_launch_path_identity() { printf "reused-lock-identity\n"; }
      fm_afk_launch_lock_acquire || exit 1
      printf "%s\n" "$2" >> "$MARKER"
      sleep 0.02
      fm_afk_launch_lock_release
    ' _ "$LAUNCH" "$i" &
    pids="$pids $!"
  done
  for pid in $pids; do
    wait "$pid" || failures=$((failures + 1))
  done
  count=$(wc -l < "$marker" 2>/dev/null | tr -d ' ')
  [ "$failures" -eq 0 ] || fail "launcher stale-lock reclaim lost $failures contender(s)"
  [ "$count" = 8 ] || fail "launcher stale-lock reclaim admitted only $count contenders"
  [ ! -e "$st/state/.afk-launch.lock" ] || fail "launcher stale-lock reclaim retained the active lock"
  if find "$st/state" -maxdepth 1 -name '.afk-launch.lock.stale.*' | grep . >/dev/null 2>&1; then
    fail "launcher stale-lock reclaim leaked quarantine state"
  fi
  pass "launcher lock serializes concurrent stale-lock reclamation"
  rm -rf "$st"
}

unit_abandoned_reclaim_is_recovered() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-abandoned.XXXXXX")
  mkdir -p "$st/state/.afk-launch.lock/.reclaim"
  printf '%s' "$$" > "$st/state/.afk-launch.lock/pid"
  printf 'different-process-identity' > "$st/state/.afk-launch.lock/pid-identity"
  printf '%s' "$$" > "$st/state/.afk-launch.lock/.reclaim/pid"
  printf 'different-process-identity' > "$st/state/.afk-launch.lock/.reclaim/pid-identity"
  printf 'abandoned' > "$st/state/.afk-launch.lock/.reclaim/token"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_LAUNCH_RECLAIM_GRACE_SECONDS=0 bash -c '
    . "$1"
    fm_afk_launch_lock_acquire
    fm_afk_launch_lock_release
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk-launch.lock" ]; then
    pass "launcher lock recovers abandoned reclaim ownership by process identity and age"
  else
    fail "launcher lock could not recover an abandoned reclaim owner"
  fi
  rm -rf "$st"
}

unit_reclaim_owner_liveness_is_tristate() {
  local st lock owner_identity state
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-liveness.XXXXXX")
  lock="$st/state/.afk-launch.lock"
  mkdir -p "$lock"
  printf '%s' "$$" > "$lock/pid"
  : > "$lock/pid-identity"
  state=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c \
    '. "$1"; fm_afk_launch_directory_owner_state "$FM_AFK_LAUNCH_LOCK"' _ "$LAUNCH")
  [ "$state" = unknown ] || fail "launcher lock treated an empty owner identity as proof of death"
  owner_identity=$( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$$" ) \
    || { fail "launcher liveness fixture could not identify its live owner"; rm -rf "$st"; return; }
  printf 'different-process-identity' > "$lock/pid-identity"
  state=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c \
    '. "$1"; fm_afk_launch_directory_owner_state "$FM_AFK_LAUNCH_LOCK"' _ "$LAUNCH")
  [ "$state" = dead ] || fail "launcher lock did not classify a reused owner PID as dead"
  printf '%s' "$owner_identity" > "$lock/pid-identity"
  state=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c \
    '. "$1"; fm_afk_launch_directory_owner_state "$FM_AFK_LAUNCH_LOCK"' _ "$LAUNCH")
  [ "$state" = alive ] || fail "launcher lock did not classify exact process ownership as alive"
  state=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_pid_identity() { return 1; }
    fm_afk_launch_pid_existence_state() { printf "exists\n"; }
    fm_afk_launch_directory_owner_state "$FM_AFK_LAUNCH_LOCK"
  ' _ "$LAUNCH")
  [ "$state" = unknown ] || fail "launcher lock treated an identity-probe error as proof of death"
  rm -rf "$st"
  pass "launcher reclaim liveness distinguishes alive, dead, and unknown owners"
}

unit_reclaim_test_handshake_requires_inherited_fds() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-test-seam.XXXXXX")
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    FM_AFK_LAUNCH_RECLAIM_TEST_READY="$st/ready" \
    FM_AFK_LAUNCH_RECLAIM_TEST_PROCEED="$st/proceed" \
    FM_AFK_LAUNCH_RECLAIM_TEST_PHASES=probe bash -c '
      . "$1"
      ! fm_afk_launch_reclaim_test_handshake probe
    ' _ "$LAUNCH" && [ ! -e "$st/ready" ] && [ ! -e "$st/proceed" ]; then
    pass "launcher reclaim test seam accepts inherited numeric descriptors only"
  else
    fail "launcher reclaim test seam accepted an arbitrary path"
  fi
  rm -rf "$st"
}

unit_namespace_guard_releases_when_owner_crashes() {
  local st event owner waiter phase waiter_status=0
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-namespace-crash.XXXXXX")
  event="$st/event"
  mkdir -p "$st/state"
  mkfifo "$event"
  exec 8<> "$event"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_state_prepare
    fm_afk_launch_namespace_guard_acquire
    [ "$FM_AFK_LAUNCH_NAMESPACE_GUARD_HELD" -eq 1 ]
    [ -z "$FM_AFK_LAUNCH_NAMESPACE_GUARD_PID" ]
    printf "owner-held\n" >&8
    while :; do :; done
  ' _ "$LAUNCH" > "$st/owner.out" 2>&1 &
  owner=$!
  if ! IFS= read -r -t "$FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS" phase <&8 || [ "$phase" != owner-held ]; then
    fail "launcher namespace-guard owner did not acquire the kernel lock"
    kill -KILL "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true
    exec 8>&-; rm -rf "$st"; return
  fi
  kill -KILL "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_namespace_guard_acquire
    printf "waiter-acquired\n" >&8
    fm_afk_launch_namespace_guard_release
  ' _ "$LAUNCH" > "$st/waiter.out" 2>&1 &
  waiter=$!
  if ! IFS= read -r -t "$FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS" phase <&8 || [ "$phase" != waiter-acquired ]; then
    fail "launcher namespace guard remained locked after its owner was killed"
    kill -KILL "$waiter" 2>/dev/null || true; wait "$waiter" 2>/dev/null || true
    exec 8>&-; rm -rf "$st"; return
  fi
  wait "$waiter" || waiter_status=$?
  [ "$waiter_status" -eq 0 ] \
    || fail "launcher namespace-guard waiter failed after owner crash: $(cat "$st/waiter.out")"
  if find "$st/state" -maxdepth 1 -type d -name '.afk-namespace-guard.*' | grep . >/dev/null 2>&1; then
    fail "launcher namespace guard left private FIFO state after owner crash"
  fi
  exec 8>&-
  rm -rf "$st"
  pass "launcher namespace guard releases and cleans up when its owning shell is killed"
}

unit_abandoned_reclaim_parent_aba_is_fenced() {
  local st lock old preserved ready proceed child phase owner_identity child_status=0
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-abandoned-aba.XXXXXX")
  lock="$st/state/.afk-launch.lock"
  old="$st/old-lock"
  preserved="$st/preserved-live-lock"
  ready="$st/ready"
  proceed="$st/proceed"
  mkdir -p "$lock/.reclaim"
  printf '%s' "$$" > "$lock/pid"
  printf 'different-process-identity' > "$lock/pid-identity"
  printf 'stale-parent' > "$lock/token"
  printf '%s' "$$" > "$lock/.reclaim/pid"
  printf 'different-process-identity' > "$lock/.reclaim/pid-identity"
  printf 'abandoned' > "$lock/.reclaim/token"
  owner_identity=$( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$$" ) \
    || { fail "launcher abandoned-reclaim ABA fixture could not identify its live owner"; rm -rf "$st"; return; }
  mkfifo "$ready" "$proceed"
  exec 8<> "$ready"
  exec 9<> "$proceed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_LAUNCH_RECLAIM_GRACE_SECONDS=0 \
    FM_AFK_LAUNCH_RECLAIM_TEST_READY=8 FM_AFK_LAUNCH_RECLAIM_TEST_PROCEED=9 \
    FM_AFK_LAUNCH_RECLAIM_TEST_PHASES=abandoned-before-revalidate:abandoned-after-revalidate:abandoned-after-quarantine:abandoned-quarantine-restored \
    bash -c '. "$1"; fm_afk_launch_lock_acquire; rc=$?; [ "$rc" -ne 0 ] || fm_afk_launch_lock_release; exit "$rc"' \
      _ "$LAUNCH" > "$st/child.out" 2>&1 &
  child=$!
  if ! IFS= read -r -t "$FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS" phase <&8 || [ "$phase" != abandoned-before-revalidate ]; then
    fail "launcher abandoned-reclaim ABA did not reach its pre-revalidation fence"
    kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true
    exec 8>&-; exec 9>&-; rm -rf "$st"; return
  fi
  printf 'proceed\n' >&9
  if ! IFS= read -r -t "$FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS" phase <&8 || [ "$phase" != abandoned-after-revalidate ]; then
    fail "launcher abandoned-reclaim ABA did not reach the guarded post-revalidation point"
    kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true
    exec 8>&-; exec 9>&-; rm -rf "$st"; return
  fi
  mv "$lock" "$old"
  mkdir -p "$lock/.reclaim"
  printf '%s' "$$" > "$lock/pid"
  printf '%s' "$owner_identity" > "$lock/pid-identity"
  printf 'live-parent' > "$lock/token"
  printf 'new-parent-sentinel' > "$lock/sentinel"
  printf '%s' "$$" > "$lock/.reclaim/pid"
  printf '%s' "$owner_identity" > "$lock/.reclaim/pid-identity"
  printf 'live-reclaim' > "$lock/.reclaim/token"
  printf 'proceed\n' >&9
  if ! IFS= read -r -t "$FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS" phase <&8 || [ "$phase" != abandoned-after-quarantine ]; then
    fail "launcher abandoned-reclaim ABA did not expose its guarded quarantine checkpoint"
    kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true
    exec 8>&-; exec 9>&-; rm -rf "$st"; return
  fi
  printf 'proceed\n' >&9
  if ! IFS= read -r -t "$FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS" phase <&8 || [ "$phase" != abandoned-quarantine-restored ]; then
    fail "launcher abandoned-reclaim ABA did not restore the swapped reclaim generation"
    kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true
    exec 8>&-; exec 9>&-; rm -rf "$st"; return
  fi
  [ "$(cat "$lock/sentinel" 2>/dev/null || true)" = new-parent-sentinel ] \
    || fail "launcher abandoned-reclaim ABA changed the newer parent generation"
  [ "$(cat "$lock/.reclaim/token" 2>/dev/null || true)" = live-reclaim ] \
    || fail "launcher abandoned-reclaim ABA renamed or deleted the newer live reclaim"
  if find "$lock" -maxdepth 1 -name '.reclaim.stale.*' | grep . >/dev/null 2>&1; then
    fail "launcher abandoned-reclaim ABA stranded the newer reclaim in quarantine"
  fi
  mv "$lock" "$preserved"
  mv "$old" "$lock"
  printf 'proceed\n' >&9
  wait "$child" || child_status=$?
  [ "$child_status" -eq 0 ] || fail "launcher abandoned-reclaim ABA child failed: $(cat "$st/child.out")"
  [ "$(cat "$preserved/sentinel" 2>/dev/null || true)" = new-parent-sentinel ] \
    || fail "launcher abandoned-reclaim ABA did not preserve the swapped live generation"
  [ "$(cat "$preserved/.reclaim/token" 2>/dev/null || true)" = live-reclaim ] \
    || fail "launcher abandoned-reclaim ABA did not preserve live reclaim ownership"
  [ ! -e "$lock" ] || fail "launcher abandoned-reclaim ABA retained its final acquired lock"
  exec 8>&-
  exec 9>&-
  rm -rf "$st"
  pass "launcher abandoned reclaim revalidates parent, reclaim, and liveness before quarantine"
}

unit_claimed_parent_swap_restores_quarantine() {
  local st lock old preserved ready proceed child third phase owner_identity child_status=0 third_status=0
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-claimed-aba.XXXXXX")
  lock="$st/state/.afk-launch.lock"
  old="$st/old-lock"
  preserved="$st/preserved-live-lock"
  ready="$st/ready"
  proceed="$st/proceed"
  mkdir -p "$lock"
  printf '%s' "$$" > "$lock/pid"
  printf 'different-process-identity' > "$lock/pid-identity"
  printf 'stale-parent' > "$lock/token"
  owner_identity=$( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$$" ) \
    || { fail "launcher claimed-parent ABA fixture could not identify its live owner"; rm -rf "$st"; return; }
  mkfifo "$ready" "$proceed"
  exec 8<> "$ready"
  exec 9<> "$proceed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_LAUNCH_RECLAIM_GRACE_SECONDS=0 \
    FM_AFK_LAUNCH_RECLAIM_TEST_READY=8 FM_AFK_LAUNCH_RECLAIM_TEST_PROCEED=9 \
    FM_AFK_LAUNCH_RECLAIM_TEST_PHASES=claimed-before-revalidate:claimed-after-revalidate:claimed-after-quarantine:claimed-quarantine-restored \
    bash -c '. "$1"; fm_afk_launch_lock_acquire; rc=$?; [ "$rc" -ne 0 ] || fm_afk_launch_lock_release; exit "$rc"' \
      _ "$LAUNCH" > "$st/child.out" 2>&1 &
  child=$!
  if ! IFS= read -r -t "$FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS" phase <&8 || [ "$phase" != claimed-before-revalidate ]; then
    fail "launcher claimed-parent ABA did not reach final generation revalidation"
    kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true
    exec 8>&-; exec 9>&-; rm -rf "$st"; return
  fi
  printf 'proceed\n' >&9
  if ! IFS= read -r -t "$FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS" phase <&8 || [ "$phase" != claimed-after-revalidate ]; then
    fail "launcher claimed-parent ABA did not reach the post-fence rename point"
    kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true
    exec 8>&-; exec 9>&-; rm -rf "$st"; return
  fi
  mv "$lock" "$old"
  mkdir "$lock"
  printf '%s' "$$" > "$lock/pid"
  printf '%s' "$owner_identity" > "$lock/pid-identity"
  printf 'live-parent' > "$lock/token"
  printf 'new-parent-sentinel' > "$lock/sentinel"
  printf 'proceed\n' >&9
  if ! IFS= read -r -t "$FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS" phase <&8 || [ "$phase" != claimed-after-quarantine ]; then
    fail "launcher claimed-parent ABA did not reach its guarded post-quarantine checkpoint"
    kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true
    exec 8>&-; exec 9>&-; rm -rf "$st"; return
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    printf "third-started\n" >&8
    . "$1"
    fm_afk_launch_lock_acquire || exit 1
    printf "third-acquired\n" >&8
    fm_afk_launch_lock_release
  ' _ "$LAUNCH" > "$st/third.out" 2>&1 &
  third=$!
  if ! IFS= read -r -t "$FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS" phase <&8 || [ "$phase" != third-started ]; then
    fail "launcher namespace-guard contender did not start during the canonical-name gap"
    kill "$child" "$third" 2>/dev/null || true
    wait "$child" 2>/dev/null || true; wait "$third" 2>/dev/null || true
    exec 8>&-; exec 9>&-; rm -rf "$st"; return
  fi
  printf 'proceed\n' >&9
  if ! IFS= read -r -t "$FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS" phase <&8 || [ "$phase" != claimed-quarantine-restored ]; then
    fail "launcher claimed-parent ABA did not restore the mismatched quarantine"
    [ "$phase" != third-acquired ] \
      || fail "launcher namespace guard admitted a third installer before quarantine restoration"
    kill "$child" "$third" 2>/dev/null || true
    wait "$child" 2>/dev/null || true; wait "$third" 2>/dev/null || true
    exec 8>&-; exec 9>&-; rm -rf "$st"; return
  fi
  [ "$(cat "$lock/sentinel" 2>/dev/null || true)" = new-parent-sentinel ] \
    || fail "launcher claimed-parent ABA did not restore the newer parent generation"
  [ "$(cat "$lock/token" 2>/dev/null || true)" = live-parent ] \
    || fail "launcher claimed-parent ABA restored the wrong lock generation"
  if find "$st/state" -maxdepth 1 -name '.afk-launch.lock.stale.*' | grep . >/dev/null 2>&1; then
    fail "launcher claimed-parent ABA leaked the restored live generation in quarantine"
  fi
  mv "$lock" "$preserved"
  rm -rf "$old"
  printf 'proceed\n' >&9
  wait "$child" || child_status=$?
  [ "$child_status" -eq 0 ] || fail "launcher claimed-parent ABA child failed: $(cat "$st/child.out")"
  if ! IFS= read -r -t "$FM_AFK_TEST_LIVENESS_TIMEOUT_SECONDS" phase <&8 || [ "$phase" != third-acquired ]; then
    fail "launcher namespace guard did not admit the third installer after restoration completed"
  fi
  wait "$third" || third_status=$?
  [ "$third_status" -eq 0 ] || fail "launcher namespace-guard contender failed: $(cat "$st/third.out")"
  [ "$(cat "$preserved/sentinel" 2>/dev/null || true)" = new-parent-sentinel ] \
    || fail "launcher claimed-parent ABA changed the preserved live generation"
  [ ! -e "$lock" ] || fail "launcher claimed-parent ABA retained its final acquired lock"
  if find "$st/state" -maxdepth 1 -name '.afk-launch.lock.stale.*' | grep . >/dev/null 2>&1; then
    fail "launcher claimed-parent ABA left quarantine state after recovery"
  fi
  exec 8>&-
  exec 9>&-
  rm -rf "$st"
  pass "launcher post-fence parent swaps restore the live generation on mismatch or control-read failure"
}

unit_launcher_lock_symlinks_are_refused() {
  local st outside out rc
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-symlink.XXXXXX")
  outside=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-outside.XXXXXX")
  mkdir -p "$st/state"
  printf 'sentinel\n' > "$outside/sentinel"
  ln -s "$outside" "$st/state/.afk-launch.lock"
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c \
    '. "$1"; fm_afk_launch_lock_acquire' _ "$LAUNCH" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "launcher lock accepted a directory symlink"
  assert_contains "$out" "refusing unsafe launcher lock" "launcher lock symlink refusal was not actionable"
  [ "$(cat "$outside/sentinel")" = sentinel ] || fail "launcher lock symlink changed outside data"
  rm -f "$st/state/.afk-launch.lock"
  mkdir "$st/state/.afk-launch.lock"
  printf '999999' > "$st/state/.afk-launch.lock/pid"
  printf 'dead' > "$st/state/.afk-launch.lock/pid-identity"
  ln -s "$outside" "$st/state/.afk-launch.lock/.reclaim"
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_LAUNCH_RECLAIM_GRACE_SECONDS=0 bash -c \
    '. "$1"; fm_afk_launch_lock_acquire' _ "$LAUNCH" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "launcher lock accepted a symlinked reclaim directory"
  assert_contains "$out" "refusing unsafe launcher reclaim directory" \
    "launcher reclaim symlink refusal was not actionable"
  [ "$(cat "$outside/sentinel")" = sentinel ] || fail "launcher reclaim symlink changed outside data"
  rm -rf "$st" "$outside"
  pass "launcher lock acquisition refuses symlinked lock and reclaim directories"
}

unit_launcher_control_files_are_bounded_and_nonfollowing() {
  local st outside rc marker
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-controls.XXXXXX")
  outside=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-controls-outside.XXXXXX")
  mkdir -p "$st/state/.afk-launch.lock"
  mkfifo "$st/state/.afk-launch.lock/pid"
  printf 'identity\n' > "$st/state/.afk-launch.lock/pid-identity"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c \
    '. "$1"; ! fm_afk_launch_lock_owned' _ "$LAUNCH"
  rc=$?
  [ "$rc" -eq 0 ] || fail "launcher lock opened a non-regular pid control"

  rm -f "$st/state/.afk-launch.lock/pid"
  marker="$outside/cat-called"
  mkdir -p "$outside/fakebin"
  cat > "$outside/fakebin/cat" <<SH
#!/usr/bin/env bash
touch '$marker'
exit 99
SH
  chmod +x "$outside/fakebin/cat"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" PATH="$outside/fakebin:$PATH" bash -c '
    . "$1"
    printf "%s" "$$" > "$FM_AFK_LAUNCH_LOCK/pid"
    fm_pid_identity "$$" > "$FM_AFK_LAUNCH_LOCK/pid-identity"
    printf "token" > "$FM_AFK_LAUNCH_LOCK/token"
    fm_afk_launch_lock_owned
  ' _ "$LAUNCH" || fail "bounded launcher control reader rejected valid ownership"
  [ ! -e "$marker" ] || fail "launcher lock control reader used unbounded cat"

  dd if=/dev/zero bs=4097 count=1 2>/dev/null | tr '\0' x > "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c \
    '. "$1"; fm_afk_launch_record_read >/dev/null 2>&1; [ "$?" -eq 2 ]' _ "$LAUNCH"
  rc=$?
  [ "$rc" -eq 0 ] || fail "oversized daemon-terminal record was accepted"
  rm -rf "$st" "$outside"
  pass "launcher control records are bounded and reject non-regular inputs"
}

unit_terminal_record_symlink_is_malformed() {
  local st outside rc
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-read.XXXXXX")
  outside=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-outside.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\tunrelated-session\tnative\n' > "$outside/record"
  ln -s "$outside/record" "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c \
    '. "$1"; fm_afk_launch_record_read >/dev/null 2>&1; [ "$?" -eq 2 ]; ! fm_afk_launch_plan_grace_elapsed' \
    _ "$LAUNCH"
  rc=$?
  [ "$rc" -eq 0 ] || fail "symlinked daemon terminal record was treated as absent or trusted"
  [ "$(cat "$outside/record")" = $'tmux\tunrelated-session\tnative' ] \
    || fail "terminal-record validation changed the symlink target"
  rm -rf "$st" "$outside"
  pass "daemon terminal readers reject symlinked control records"
}

unit_tmux_record_is_home_scoped_and_exact() {
  local st hash target rc log
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-record-scope.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\tunrelated-session\t\n' > "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c \
    '. "$1"; fm_afk_launch_record_read >/dev/null 2>&1; [ "$?" -eq 2 ]' _ "$LAUNCH"
  rc=$?
  [ "$rc" -eq 0 ] || fail "foreign tmux daemon record was accepted for this home"

  hash=$(printf '%s' "$st" | cksum | cut -d' ' -f1)
  target="fm-afk-daemon-$hash-123-4-1700000000"
  printf 'tmux\t%s\t\n' "$target" > "$st/state/.afk-daemon-terminal"
  log="$st/tmux.log"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_FAKE_TMUX_LOG="$log" bash -c '
    . "$1"
    tmux() { printf "%s\n" "$*" >> "$FM_FAKE_TMUX_LOG"; return 0; }
    fm_afk_launch_record_read || exit 1
    fm_afk_launch_close_terminal "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET" "$FM_AFK_REC_EXTRA"
    fm_afk_launch_terminal_alive "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET" "$FM_AFK_REC_EXTRA"
  ' _ "$LAUNCH" || fail "valid home-scoped tmux daemon record was rejected"
  grep -Fx "kill-session -t =$target" "$log" >/dev/null \
    || fail "tmux daemon close did not use exact-match target syntax"
  grep -Fx "has-session -t =$target" "$log" >/dev/null \
    || fail "tmux daemon liveness did not use exact-match target syntax"
  rm -rf "$st"
  pass "tmux daemon records are home-scoped and use exact targets"
}

unit_linux_stat_selection_avoids_filesystem_stat_output() {
  local st fakebin output
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-linux-stat.XXXXXX")
  fakebin="$st/fakebin"
  mkdir -p "$fakebin" "$st/state/.afk-launch.lock"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Linux\n'
SH
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -f) printf 'File: poisoned-filesystem-output\n'; exit 0 ;;
  -c) printf '11:22:33\n' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/uname" "$fakebin/stat"
  output=$(PATH="$fakebin:$PATH" FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c \
    '. "$1"; fm_afk_launch_path_identity "$2"' _ "$LAUNCH" "$st/state/.afk-launch.lock") \
    || fail "Linux AFK lock identity selection failed"
  if [ "$output" = '11:22:33' ]; then
    pass "AFK lock identity selects GNU stat without probing BSD filesystem stat"
  else
    fail "AFK lock identity accepted filesystem-stat output: $output"
  fi
  rm -rf "$st"
}

unit_signal_exits_with_lock_cleanup() {
  local st ready resumed child
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-signal.XXXXXX")
  ready="$st/handler-ready"
  resumed="$st/resumed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    test_ready=$2
    test_resumed=$3
    fm_afk_launch_start() {
      : > "$test_ready"
      while :; do :; done
    }
    fm_afk_launch_main start
    : > "$test_resumed"
  ' _ "$LAUNCH" "$ready" "$resumed" &
  child=$!
  for _ in $(seq 1 40); do
    [ -e "$ready" ] && break
    sleep 0.05
  done
  if [ ! -e "$ready" ]; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "launcher signal: cleanup handler did not become ready"
    rm -rf "$st"
    return
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  if [ ! -e "$resumed" ] && [ ! -e "$st/state/.afk-launch.lock" ]; then
    pass "launcher signal: TERM exits and releases the lifecycle lock"
  else
    fail "launcher signal: interrupted lifecycle resumed or retained its lock"
  fi
  rm -rf "$st"
}

unit_signal_during_lock_publication_cleanup() {
  local st entered resumed child
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-signal-publish.XXXXXX")
  entered="$st/entered-lifecycle"
  resumed="$st/resumed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    test_entered=$2
    fm_afk_launch_atomic_rename() {
      command mv "$1" "$2" || return 1
      kill -TERM "$$"
      return 0
    }
    fm_afk_launch_start() { : > "$test_entered"; }
    fm_afk_launch_main start
    : > "$3"
  ' _ "$LAUNCH" "$entered" "$resumed" &
  child=$!
  wait "$child" 2>/dev/null || true
  if [ ! -e "$entered" ] && [ ! -e "$resumed" ] \
    && [ ! -e "$st/state/.afk-launch.lock" ]; then
    pass "launcher signal: TERM during atomic lock publication releases the lifecycle lock"
  else
    fail "launcher signal: lock publication resumed or retained its lock after TERM"
  fi
  rm -rf "$st"
}

unit_herdr_partial_create_recovery() {
  local st recorded
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-partial.XXXXXX")
  recorded="$st/recorded"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_LAUNCH_ENTRY=/bin/true \
    FM_AFK_LAUNCH_LABEL=afk-exact-label RECORDED="$recorded" bash -c '
    . "$1"
    fm_backend_source() { return 0; }
    fm_backend_herdr_server_ensure() { return 0; }
    fm_backend_herdr_cli() {
      if [ "$2 $3" = "workspace create" ]; then
        printf %s '\''truncated'\''
        return 1
      elif [ "$2 $3" = "workspace list" ]; then
        printf %s '\''{"result":{"workspaces":[{"workspace_id":"ws-partial","label":"afk-exact-label"}]}}'\''
      else
        printf %s '\''{"result":{"panes":[{"pane_id":"pane-exact"}]}}'\''
      fi
    }
    fm_afk_launch_record_write() { printf "%s:%s:%s" "$1" "$2" "$3" > "$RECORDED"; }
    fm_afk_launch_create_herdr lab:captain herdr
  ' _ "$LAUNCH"
  if [ "$(cat "$recorded" 2>/dev/null || true)" = "herdr:lab:pane-exact:ws-partial|afk-exact-label" ]; then
    pass "herdr create: malformed response recovers durable exact ownership"
  else
    fail "herdr create: malformed response left terminal ownership unknown"
  fi
  rm -rf "$st"
}

unit_herdr_creation_intent_reconciles() {
  local st marker
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-plan.XXXXXX")
  marker="$st/closed"
  mkdir -p "$st/state"
  printf 'herdr-plan\tlab\tafk-planned-label\n' > "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" CLOSED="$marker" bash -c '
    . "$1"
    fm_backend_source() { return 0; }
    fm_backend_herdr_cli() {
      case "$2 $3" in
        "workspace list") printf %s '\''{"result":{"workspaces":[{"workspace_id":"ws-planned","label":"afk-planned-label"}]}}'\'' ;;
        "pane list") if [ -e "$CLOSED" ]; then printf %s '\''{"result":{"panes":[]}}'\''; else printf %s '\''{"result":{"panes":[{"pane_id":"pane-planned"}]}}'\''; fi ;;
        "pane close") : > "$CLOSED" ;;
        "pane get") printf %s '\''{"error":{"code":"pane_not_found"}}'\''; return 1 ;;
        *) return 2 ;;
      esac
    }
    fm_afk_launch_reconcile
  ' _ "$LAUNCH"
  if [ -e "$marker" ] && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "herdr launch: a persisted creation intent recovers and closes the exact workspace after restart"
  else
    fail "herdr launch: planned workspace ownership was not recoverable"
  fi
  rm -rf "$st"
}

unit_expired_herdr_creation_intent_clears() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-plan-absent.XXXXXX")
  mkdir -p "$st/state"
  printf 'herdr-plan\tlab\tafk-never-created\n' > "$st/state/.afk-daemon-terminal"
  touch -t 200001010000 "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    seq() { printf "1\n"; }
    sleep() { :; }
    fm_backend_source() { return 0; }
    fm_backend_herdr_cli() {
      [ "$2 $3" = "workspace list" ] || return 2
      printf %s '\''{"result":{"workspaces":[]}}'\''
    }
    fm_afk_launch_reconcile
  ' _ "$LAUNCH"
  if [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "herdr launch: an expired intent clears after exact label absence is confirmed"
  else
    fail "herdr launch: an expired never-created intent remained wedged"
  fi
  rm -rf "$st"
}

unit_detached_daemons_receive_state_override() {
  local st herdr_cmd tmux_cmd
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-state-override.XXXXXX")
  mkdir -p "$st/override-state"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/override-state" FM_AFK_LAUNCH_ENTRY=/bin/true bash -c '
    . "$1"
    fm_backend_source() { return 0; }
    fm_backend_herdr_server_ensure() { return 0; }
    fm_afk_launch_wait_ready() { return 0; }
    fm_backend_herdr_cli() {
      case "$2 $3" in
        "workspace create")
          [ "$(cut -f1,2 "$FM_AFK_LAUNCH_RECORD")" = "$(printf "herdr-plan\tlab")" ] || return 8
          printf %s '\''{"result":{"workspace":{"workspace_id":"ws-state"},"root_pane":{"pane_id":"pane-state"}}}'\''
          ;;
        "pane run") printf "%s" "$5" > "$FM_HOME/herdr-command" ;;
        *) return 0 ;;
      esac
    }
    fm_afk_launch_create_herdr lab:captain herdr
  ' _ "$LAUNCH" || fail "herdr state-override launch fixture failed"
  herdr_cmd=$(cat "$st/herdr-command" 2>/dev/null || true)
  case "$herdr_cmd" in
    *"FM_STATE_OVERRIDE=$st/override-state"*) ;;
    *) fail "herdr daemon command lost FM_STATE_OVERRIDE" ;;
  esac
  case "$herdr_cmd" in
    *"FM_AFK_STATE_PREPARED=1"*) ;;
    *) fail "herdr daemon command lost FM_AFK_STATE_PREPARED" ;;
  esac

  rm -f "$st/override-state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/override-state" FM_AFK_LAUNCH_ENTRY=/bin/true bash -c '
    . "$1"
    fm_afk_launch_wait_ready() { return 0; }
    tmux() {
      if [ "$1" = new-session ]; then printf "%s" "$5" > "$FM_HOME/tmux-command"; fi
      return 0
    }
    fm_afk_launch_create_tmux captain:0 tmux
  ' _ "$LAUNCH" || fail "tmux state-override launch fixture failed"
  tmux_cmd=$(cat "$st/tmux-command" 2>/dev/null || true)
  case "$tmux_cmd" in
    *"FM_STATE_OVERRIDE=$st/override-state"*) ;;
    *) fail "tmux daemon command lost FM_STATE_OVERRIDE" ;;
  esac
  case "$tmux_cmd" in
    *"FM_AFK_STATE_PREPARED=1"*) ;;
    *) fail "tmux daemon command lost FM_AFK_STATE_PREPARED" ;;
  esac
  pass "detached away daemons receive the prepared effective state"
  rm -rf "$st"
}

unit_herdr_error_with_exact_ids_closes_exact() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-error-exact.XXXXXX")
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_backend_source() { return 0; }
    fm_backend_herdr_server_ensure() { return 0; }
    fm_backend_herdr_cli() {
      if [ "$2 $3" = "workspace create" ]; then
        printf %s '\''{"result":{"workspace":{"workspace_id":"ws-exact"},"root_pane":{"pane_id":"pane-exact"}}}'\''
        return 1
      elif [ "$2 $3" = "pane get" ]; then
        printf %s '\''{"error":{"code":"transport_error"}}'\''
        return 2
      fi
      return 2
    }
    ! fm_afk_launch_create_herdr lab:captain herdr
  ' _ "$LAUNCH"
  if [ "$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)" = "lab:pane-exact" ]; then
    pass "herdr create error: unconfirmed exact id is persisted for reconciliation"
  else
    fail "herdr create error: unconfirmed exact cleanup id was discarded"
  fi
  rm -rf "$st"
}

unit_herdr_run_failure_preserves_unconfirmed_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-run-fail.XXXXXX")
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_backend_source() { return 0; }
    fm_backend_herdr_server_ensure() { return 0; }
    fm_backend_herdr_cli() {
      if [ "$2 $3" = "workspace create" ]; then
        printf %s '\''{"result":{"workspace":{"workspace_id":"ws-exact"},"root_pane":{"pane_id":"pane-exact"}}}'\''
        return 0
      elif [ "$2 $3" = "pane run" ]; then
        return 1
      elif [ "$2 $3" = "pane get" ]; then
        printf %s '\''{"error":{"code":"transport_error"}}'\''
        return 2
      fi
      return 2
    }
    ! fm_afk_launch_create_herdr lab:captain herdr
  ' _ "$LAUNCH"
  if [ "$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)" = "lab:pane-exact" ]; then
    pass "herdr run failure: unconfirmed exact id remains reconcilable"
  else
    fail "herdr run failure: unconfirmed exact id was discarded"
  fi
  rm -rf "$st"
}

unit_record_failure_closes_terminal() {
  local st closed
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-fail.XXXXXX")
  closed="$st/closed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" CLOSED="$closed" bash -c '
    . "$1"
    fm_afk_launch_record_write() { return 1; }
    fm_afk_launch_close_terminal() { printf "%s:%s" "$1" "$2" > "$CLOSED"; }
    ! fm_afk_launch_commit_terminal tmux exact-session ""
  ' _ "$LAUNCH"
  if [ "$(cat "$closed" 2>/dev/null || true)" = "tmux:exact-session" ]; then
    pass "record failure: newly created terminal is closed by exact id"
  else
    fail "record failure: newly created terminal leaked"
  fi
  rm -rf "$st"
}

unit_readiness_failure_rolls_back_terminal() {
  local st closed
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-not-ready.XXXXXX")
  closed="$st/closed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" CLOSED="$closed" bash -c '
    . "$1"
    fm_afk_launch_wait_ready() { return 1; }
    fm_afk_launch_close_terminal() { printf "%s:%s" "$1" "$2" > "$CLOSED"; }
    fm_afk_launch_terminal_absent() { [ -e "$CLOSED" ]; }
    ! fm_afk_launch_commit_terminal tmux exact-session ""
  ' _ "$LAUNCH"
  if [ "$(cat "$closed" 2>/dev/null || true)" = "tmux:exact-session" ] \
    && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "readiness failure: exact terminal and durable record roll back"
  else
    fail "readiness failure: terminal or record survived"
  fi
  rm -rf "$st"
}

unit_readiness_failure_preserves_unconfirmed_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-not-ready-unconfirmed.XXXXXX")
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_wait_ready() { return 1; }
    fm_afk_launch_close_terminal() { return 1; }
    fm_afk_launch_terminal_absent() { return 1; }
    ! fm_afk_launch_commit_terminal tmux exact-session ""
  ' _ "$LAUNCH"
  if [ "$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)" = exact-session ]; then
    pass "readiness failure: unconfirmed terminal retains its reconciliation id"
  else
    fail "readiness failure: unconfirmed terminal lost its reconciliation id"
  fi
  rm -rf "$st"
}

unit_tmux_absence_distinguishes_probe_failure() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-probe.XXXXXX")
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    tmux() { printf "%s" "can'\''t find session: exact-session" >&2; return 1; }
    fm_afk_launch_terminal_absent tmux exact-session
    tmux() { printf "%s" "no server running on /tmp/tmux-501/default" >&2; return 1; }
    fm_afk_launch_terminal_absent tmux exact-session
    tmux() { printf "%s" "error connecting to /tmp/tmux.sock" >&2; return 1; }
    ! fm_afk_launch_terminal_absent tmux exact-session
  ' _ "$LAUNCH"; then
    pass "tmux absence: clean missing differs from transport probe failure"
  else
    fail "tmux absence: probe failure was treated as confirmed absence"
  fi
  rm -rf "$st"
}

unit_native_lifecycle() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" start-native >/dev/null 2>&1 \
    && [ "$(cut -f1 "$st/state/.afk-daemon-terminal")" = none ] \
    && [ -e "$st/state/.afk" ] \
    && [ ! -e "$st/state/.subsuper-escalations" ]; then
    pass "native lifecycle: launcher owns state with no terminal"
  else
    fail "native lifecycle: state preparation or no-terminal record failed"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if [ ! -e "$st/state/.afk" ] && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "native lifecycle: uniform stop clears state without closing a terminal"
  else
    fail "native lifecycle: uniform stop retained state"
  fi
  rm -rf "$st"
}

unit_recovery_preserves_buffered_escalations() {
  local st
  for mode in native tmux; do
    st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-recovery.XXXXXX")
    mkdir -p "$st/state"
    printf 'away-session\n' > "$st/state/.afk"
    printf 'pending-escalation\n' > "$st/state/.subsuper-escalations"
    if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=captain:0 \
      FM_SUPERVISOR_BACKEND=tmux MODE="$mode" bash -c '
        . "$1"
        fm_afk_launch_reconcile() { return 0; }
        fm_afk_launch_create_tmux() { return 0; }
        if [ "$MODE" = native ]; then
          fm_afk_launch_start_native
        else
          fm_afk_launch_start
        fi
      ' _ "$LAUNCH" && [ "$(cat "$st/state/.subsuper-escalations" 2>/dev/null)" = pending-escalation ]; then
      :
    else
      fail "$mode recovery discarded a buffered escalation"
    fi
    rm -rf "$st"
  done
  pass "dead-daemon recovery preserves buffered away-mode escalations"
}

unit_native_entry_preserves_prepared_state() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native-entry.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  : > "$st/state/.subsuper-escalations"
  printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_STATE_PREPARED=1 bash -c '
    . "$1"
    FM_AFK_DAEMON=/bin/true
    fm_afk_start_main
  ' _ "$START" >/dev/null 2>&1
  if [ -e "$st/state/.afk" ] && [ -e "$st/state/.subsuper-escalations" ]; then
    pass "native entry: launcher-prepared lifecycle state is not rewritten"
  else
    fail "native entry: launcher-prepared lifecycle state was mutated"
  fi
  rm -rf "$st"
}

unit_native_start_stop_handoff_is_atomic() {
  local st daemon starter stopper i
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native-race.XXXXXX")
  mkdir -p "$st/state"
  daemon="$st/fm-supervise-daemon.sh"
  cat > "$daemon" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' INT TERM
while :; do sleep 0.05; done
SH
  chmod +x "$daemon"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" start-native >/dev/null 2>&1 \
    || fail "native handoff precondition failed"

  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_STATE_PREPARED=1 \
    START="$START" DAEMON="$daemon" REACHED="$st/reached" GO="$st/go" bash -c '
      . "$START"
      FM_AFK_DAEMON=$DAEMON
      daemon_lock_pid() {
        : > "$REACHED"
        while [ ! -e "$GO" ]; do sleep 0.02; done
        return 1
      }
      fm_afk_start_main
    ' >/dev/null 2>&1 &
  starter=$!
  for i in $(seq 1 100); do
    [ -e "$st/reached" ] && break
    sleep 0.02
  done
  [ -e "$st/reached" ] || { kill "$starter" 2>/dev/null || true; fail "native entry never reached the pre-daemon handoff window"; return; }

  ( FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" STARTER="$starter" bash -c '
      . "$1"
      fm_afk_native_process_command_matches() { [ "$1" = "$STARTER" ]; }
      fm_afk_launch_main stop
    ' _ "$LAUNCH" >/dev/null 2>&1; : > "$st/stop-done" ) &
  stopper=$!
  sleep 0.2
  [ -e "$st/state/.afk" ] || fail "stop cleared away mode while a prepared native entry held the handoff"
  [ ! -e "$st/stop-done" ] || fail "stop completed before the prepared native entry registered its process"

  : > "$st/go"
  wait "$stopper" || fail "stop failed after the native entry completed its handoff"
  # Reap the exec'd infinite-loop fixture daemon unconditionally: a stop
  # regression that refuses before signaling must not hang the suite, and the
  # state assertions below still capture stop's outcome.
  kill -KILL "$starter" 2>/dev/null || true
  wait "$starter" 2>/dev/null || true
  [ ! -e "$st/state/.afk" ] || fail "atomic native stop retained away mode"
  [ ! -e "$st/state/.afk-native-process" ] || fail "atomic native stop retained the native process marker"
  pass "native lifecycle: start and stop serialize across the pre-daemon handoff"
  rm -rf "$st"
}

unit_direct_native_start_stop_handoff_is_atomic() {
  local st daemon starter stopper i
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-direct-native-race.XXXXXX")
  mkdir -p "$st/state"
  daemon="$st/fm-supervise-daemon.sh"
  cat > "$daemon" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' INT TERM
while :; do sleep 0.05; done
SH
  chmod +x "$daemon"

  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    START="$START" DAEMON="$daemon" REACHED="$st/reached" GO="$st/go" bash -c '
      . "$START"
      FM_AFK_DAEMON=$DAEMON
      daemon_lock_pid() {
        : > "$REACHED"
        while [ ! -e "$GO" ]; do sleep 0.02; done
        return 1
      }
      fm_afk_start_main
    ' >/dev/null 2>&1 &
  starter=$!
  for i in $(seq 1 100); do
    [ -e "$st/reached" ] && break
    sleep 0.02
  done
  [ -e "$st/reached" ] || { kill "$starter" 2>/dev/null || true; fail "direct native entry never reached the pre-daemon handoff window"; return; }

  ( FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" STARTER="$starter" bash -c '
      . "$1"
      fm_afk_native_process_command_matches() { [ "$1" = "$STARTER" ]; }
      fm_afk_launch_main stop
    ' _ "$LAUNCH" >/dev/null 2>&1; : > "$st/stop-done" ) &
  stopper=$!
  sleep 0.2
  [ -e "$st/state/.afk" ] || fail "stop cleared away mode while a direct native entry held the handoff"
  [ ! -e "$st/stop-done" ] || fail "stop completed before the direct native entry registered its process"

  : > "$st/go"
  wait "$stopper" || fail "stop failed after the direct native entry completed its handoff"
  # Reap the exec'd infinite-loop fixture daemon unconditionally: a stop
  # regression that refuses before signaling must not hang the suite, and the
  # state assertions below still capture stop's outcome.
  kill -KILL "$starter" 2>/dev/null || true
  wait "$starter" 2>/dev/null || true
  [ ! -e "$st/state/.afk" ] || fail "atomic direct native stop retained away mode"
  [ ! -e "$st/state/.afk-native-process" ] || fail "atomic direct native stop retained the native process marker"
  pass "native lifecycle: direct start and stop serialize across the pre-daemon handoff"
  rm -rf "$st"
}

unit_native_handoff_lock_wait_is_bounded() {
  local st out status
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-handoff-bounded.XXXXXX")
  mkdir -p "$st/state"
  if out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_NATIVE_HANDOFF_LOCK_WAIT_SECONDS=0 \
    bash -c '
      . "$1"
      fm_lock_try_acquire() { return 1; }
      fm_afk_launch_start_native
    ' _ "$LAUNCH" 2>&1); then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ] \
    && [[ "$out" == *"native handoff lock remained busy"* ]] \
    && [[ "$out" == *"retry after the active handoff finishes"* ]]; then
    pass "native lifecycle: busy handoff locks refuse within a bounded wait"
  else
    fail "native lifecycle: busy handoff lock did not return an actionable bounded refusal"
  fi
  rm -rf "$st"
}

unit_close_failure_preserves_record() {
  local st hash target
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-close-fail.XXXXXX")
  mkdir -p "$st/state"
  hash=$(printf '%s' "$st" | cksum | cut -d' ' -f1)
  target="fm-afk-daemon-$hash-123-4-1700000000"
  printf 'tmux\t%s\towned\n' "$target" > "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_close_terminal() { return 1; }
    fm_afk_launch_terminal_absent() { return 1; }
    ! fm_afk_launch_reconcile
  ' _ "$LAUNCH"
  if [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "teardown failure: exact terminal record is preserved"
  else
    fail "teardown failure: exact terminal record was discarded"
  fi
  rm -rf "$st"
}

unit_record_publication_atomic() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-atomic.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\told-session\towned\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    mv() { return 1; }
    ! fm_afk_launch_record_write tmux new-session owned
  ' _ "$LAUNCH" \
    && [ "$(cat "$st/state/.afk-daemon-terminal")" = $'tmux\told-session\towned' ] \
    && ! find "$st/state" -name '.afk-daemon-terminal.pending.*' -print -quit | grep -q .; then
    pass "record publication: failed atomic rename preserves the complete prior record"
  else
    fail "record publication: failed write truncated or replaced the prior record"
  fi
  rm -rf "$st"
}

unit_publication_rejects_unsafe_destinations() {
  local st outside
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-publish-destination.XXXXXX")
  outside="$st/outside"
  mkdir -p "$st/state" "$outside"
  ln -s "$outside" "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    ! fm_afk_launch_record_write tmux escaped-session owned
  ' _ "$LAUNCH" \
    && ! find "$outside" -mindepth 1 -print -quit | grep -q . \
    && ! find "$st/state" -name '.afk-daemon-terminal.pending.*' -print -quit | grep -q .; then
    pass "record publication: directory symlink destination is refused and staging is cleaned"
  else
    fail "record publication: unsafe directory symlink accepted or staging leaked"
  fi

  rm -f "$st/state/.afk-daemon-terminal"
  ln -s "$outside" "$st/state/.afk"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    ! fm_afk_launch_flag_write
  ' _ "$LAUNCH" \
    && ! find "$outside" -mindepth 1 -print -quit | grep -q . \
    && ! find "$st/state" -name '.afk.pending.*' -print -quit | grep -q .; then
    pass "flag publication: directory symlink destination is refused and staging is cleaned"
  else
    fail "flag publication: unsafe directory symlink accepted or staging leaked"
  fi
  rm -rf "$st"
}

unit_flag_staging_does_not_follow_predictable_symlink() {
  local st outside
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-flag-staging.XXXXXX")
  outside="$st/outside"
  mkdir -p "$st/state"
  printf 'unchanged\n' > "$outside"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    ln -s "$2" "$FM_AFK_LAUNCH_STATE/.afk.pending.$$"
    fm_afk_launch_flag_write
  ' _ "$LAUNCH" "$outside" \
    && [ "$(cat "$outside")" = unchanged ] \
    && [ -f "$st/state/.afk" ] \
    && ! find "$st/state" -name '.afk.pending.*' -type f -print -quit | grep -q .; then
    pass "flag publication: unpredictable staging does not follow a planted pid symlink"
  else
    fail "flag publication: predictable staging symlink was followed or staging leaked"
  fi
  rm -rf "$st"
}

unit_malformed_record_fails_closed() {
  local st acted
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-malformed.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  acted="$st/acted"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" ACTED="$acted" bash -c '
    . "$1"
    fm_afk_launch_close_terminal() { : > "$ACTED"; }
    ! fm_afk_launch_reconcile
  ' _ "$LAUNCH" \
    && [ ! -e "$acted" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "record read: malformed record fails closed without acting on a partial id"
  else
    fail "record read: malformed record was acted on or discarded"
  fi
  rm -rf "$st"
}

unit_stop_malformed_record_fails_closed() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-malformed.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    ! fm_afk_launch_stop
  ' _ "$LAUNCH" && [ -e "$st/state/.afk" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop: malformed terminal record preserves away state and fails closed"
  else
    fail "stop: malformed terminal record cleared protected lifecycle state"
  fi
  rm -rf "$st"
}

unit_tmux_planned_record_and_collision() {
  local st first second
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-plan.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    tmux() {
      if [ "$1" = new-session ]; then
        [ -s "$FM_AFK_LAUNCH_RECORD" ] || return 9
        printf "%s" "$4" > "$FM_HOME/created-name"
        return 1
      fi
      if [ "$1" = has-session ]; then printf "%s" "can'\''t find session" >&2; return 1; fi
      [ "$1" != kill-session ] || : > "$FM_HOME/killed"
      return 1
    }
    ! fm_afk_launch_create_tmux captain:0 tmux
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk-daemon-terminal" ] && [ ! -e "$st/killed" ]; then
    pass "tmux launch: planned exact target is recorded before creation and removed on failure"
  else
    fail "tmux launch: creation began before exact target publication"
  fi
  first=$(cat "$st/created-name")
  rm -rf "$st"

  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-unique.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    tmux() {
      [ "$1" != new-session ] || { printf "%s" "$4" > "$FM_HOME/created-name"; return 1; }
      [ "$1" != has-session ] || { printf "%s" "can'\''t find session" >&2; return 1; }
      [ "$1" != kill-session ] || : > "$FM_HOME/killed"
      return 1
    }
    ! fm_afk_launch_create_tmux captain:0 tmux
  ' _ "$LAUNCH" && [ ! -e "$st/killed" ]; then
    second=$(cat "$st/created-name")
    if [ "$first" != "$second" ]; then
      pass "tmux launch: unique names eliminate collision teardown"
    else
      fail "tmux launch: consecutive launches reused a session name"
    fi
  else
    fail "tmux launch: creation failure attempted session teardown"
  fi
  rm -rf "$st"
}

unit_stop_validates_before_signal() {
  local st sleeper_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-validate.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  sleep 30 & sleeper_pid=$!
  mkdir -p "$st/state/.supervise-daemon.lock"
  printf '%s' "$sleeper_pid" > "$st/state/.supervise-daemon.lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$sleeper_pid" > "$st/state/.supervise-daemon.lock/pid-identity" )
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1 || true
  if kill -0 "$sleeper_pid" 2>/dev/null && [ -e "$st/state/.afk" ]; then
    pass "stop validation: malformed record causes no daemon or state side effects"
  else
    fail "stop validation: malformed record signaled daemon or cleared state"
  fi
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_lock_requires_complete_metadata() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-metadata.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_pid_identity() { return 1; }
    ! fm_afk_launch_lock_acquire
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk-launch.lock" ]; then
    pass "launcher lock: incomplete metadata fails acquisition and releases lock"
  else
    fail "launcher lock: incomplete metadata was accepted"
  fi
  rm -rf "$st"
}

unit_stop_surfaces_afk_removal_failure() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-remove.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    rm() { local last=${!#}; [ "$last" != "$FM_AFK_LAUNCH_STATE/.afk" ]; }
    ! fm_afk_launch_stop
  ' _ "$LAUNCH"; then
    pass "stop state: away-flag removal failure is surfaced"
  else
    fail "stop state: away-flag removal failure reported success"
  fi
  rm -rf "$st"
}

unit_stop_confirms_daemon_exit() {
  local st daemon_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-live.XXXXXX")
  mkdir -p "$st/state/.supervise-daemon.lock"
  : > "$st/state/.afk"
  printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
  bash -c 'trap "" TERM; while :; do sleep 1; done' &
  daemon_pid=$!
  printf '%s' "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid-identity" )
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    seq() { printf "1\n"; }
    sleep() { :; }
    kill() {
      command kill "$@"
      if [ "$1" = -TERM ]; then
        rm -rf "$FM_AFK_LAUNCH_STATE/.supervise-daemon.lock"
      fi
    }
    ! fm_afk_launch_stop
  ' _ "$LAUNCH" && kill -0 "$daemon_pid" 2>/dev/null \
    && [ ! -e "$st/state/.supervise-daemon.lock" ] \
    && [ -e "$st/state/.afk" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop liveness: captured live daemon preserves lifecycle state after lock release"
  else
    fail "stop liveness: lock release was mistaken for captured daemon exit"
  fi
  kill -KILL "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_stop_confirms_native_process_exit() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-native-live.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  : > "$st/state/.afk-native-process"
  printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_native_process_live() { FM_AFK_NATIVE_PID=4242; return 0; }
    fm_afk_native_process_identity() { printf "native-identity\n"; }
    fm_pid_identity() { printf "generic-identity\n"; }
    fm_pid_alive() { return 0; }
    kill() { return 0; }
    seq() { printf "1\n"; }
    sleep() { :; }
    ! fm_afk_launch_stop
  ' _ "$LAUNCH" && [ -e "$st/state/.afk" ] \
    && [ -e "$st/state/.afk-native-process" ] \
    && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop liveness: native process identity is compared in its stored format"
  else
    fail "stop liveness: native process identity mismatch cleared lifecycle state"
  fi
  rm -rf "$st"
}

unit_refresh_validates_record() {
  local st daemon_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-refresh-record.XXXXXX")
  mkdir -p "$st/state/.supervise-daemon.lock"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  sleep 30 & daemon_pid=$!
  printf '%s' "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid-identity" )
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=tmux bash -c '
      . "$1"
      ! fm_afk_launch_start && ! fm_afk_launch_start_native
    ' _ "$LAUNCH" && [ ! -e "$st/state/.afk" ]; then
    pass "refresh record: malformed terminal identity fails closed"
  else
    fail "refresh record: malformed terminal identity was accepted"
  fi
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_clear_failure_aborts_entry() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-clear-fail.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_reconcile() { return 0; }
    fm_afk_clear_stale_artifacts() { return 1; }
    ! fm_afk_launch_start_native
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk" ] && [ -e "$st/state/.subsuper-escalations" ]; then
    pass "clear failure: native entry aborts and restores prior state"
  else
    fail "clear failure: native entry proceeded or lost prior state"
  fi
  rm -rf "$st"
}

unit_confirmed_absence_succeeds() {
  local st hash target
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-confirmed-absent.XXXXXX")
  mkdir -p "$st/state"
  hash=$(printf '%s' "$st" | cksum | cut -d' ' -f1)
  target="fm-afk-daemon-$hash-123-4-1700000000"
  printf 'tmux\t%s\towned\n' "$target" > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_close_terminal() { return 1; }
    fm_afk_launch_terminal_absent() { return 0; }
    fm_afk_launch_reconcile
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "confirmed absence: cleanup succeeds and removes the stale record"
  else
    fail "confirmed absence: close error incorrectly failed reconciliation"
  fi
  rm -rf "$st"
}

unit_incomplete_restore_retains_backup() {
  local st backup
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-restore-fail.XXXXXX")
  mkdir -p "$st/state"
  backup=$(mktemp -d "$st/state/.afk-launch-backup.XXXXXX")
  printf 'prior\n' > "$backup/.afk"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_copy_bounded() { return 1; }
    ! fm_afk_launch_restore_backup "$2" 1
  ' _ "$LAUNCH" "$backup" && [ -d "$backup" ] && [ -e "$backup/.afk" ]; then
    pass "rollback restore: incomplete restoration retains its recovery backup"
  else
    fail "rollback restore: incomplete restoration discarded its backup"
  fi
  rm -rf "$st"
}

unit_afk_backups_reject_unsafe_or_oversized_sources() {
  local st outside backup
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-backup-source.XXXXXX")
  mkdir -p "$st/state"
  outside="$st/outside"
  printf 'outside\n' > "$outside"
  ln -s "$outside" "$st/state/.afk"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=captain:0 \
    FM_SUPERVISOR_BACKEND=tmux bash -c '
      . "$1"
      daemon_lock_held_by_live_daemon() { return 1; }
      ! fm_afk_launch_start
    ' _ "$LAUNCH" && [ "$(cat "$outside")" = outside ]; then
    pass "AFK backup: terminal startup refuses a symlinked source"
  else
    fail "AFK backup: terminal startup opened or altered a symlinked source"
  fi
  rm -f "$st/state/.afk"
  head -c 1048577 /dev/zero > "$st/state/.subsuper-escalations"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 1; }
    ! fm_afk_launch_start_native_locked
  ' _ "$LAUNCH"; then
    pass "AFK backup: native startup rejects an oversized source"
  else
    fail "AFK backup: native startup accepted an oversized source"
  fi
  rm -f "$st/state/.subsuper-escalations"
  backup=$(mktemp -d "$st/state/.afk-launch-backup.XXXXXX")
  ln -s "$outside" "$backup/.subsuper-escalations"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '. "$1"; ! fm_afk_launch_restore_backup "$2" 0' _ "$LAUNCH" "$backup" \
    && [ -d "$backup" ] && [ ! -e "$st/state/.subsuper-escalations" ]; then
    pass "AFK backup: incomplete restore refuses a symlink and retains the backup"
  else
    fail "AFK backup: restore followed a symlink or discarded its retry state"
  fi
  rm -rf "$st"
}

unit_afk_bounded_copy_preserves_mtime() {
  local st source backup restored source_mtime backup_mtime restored_mtime
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-backup-mtime.XXXXXX")
  mkdir -p "$st/state" "$st/backup"
  source="$st/state/.subsuper-inject-wedged"
  backup="$st/backup/.subsuper-inject-wedged"
  restored="$st/state/restored-wedge"
  printf 'wedged\n' > "$source"
  touch -t 200001010101 "$source"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_copy_bounded "$2" "$3"
    fm_afk_launch_copy_bounded "$3" "$4"
  ' _ "$LAUNCH" "$source" "$backup" "$restored"; then
    if [ "$(uname)" = Darwin ]; then
      source_mtime=$(stat -f '%m' "$source")
      backup_mtime=$(stat -f '%m' "$backup")
      restored_mtime=$(stat -f '%m' "$restored")
    else
      source_mtime=$(stat -c '%Y' "$source")
      backup_mtime=$(stat -c '%Y' "$backup")
      restored_mtime=$(stat -c '%Y' "$restored")
    fi
    if [ "$source_mtime" = "$backup_mtime" ] && [ "$backup_mtime" = "$restored_mtime" ]; then
      pass "AFK backup: bounded backup and restore preserve wedge age"
    else
      fail "AFK backup: bounded copy reset the wedge marker age"
    fi
  else
    fail "AFK backup: bounded copy failed while preserving wedge age"
  fi
  rm -rf "$st"
}

unit_afk_bounded_copy_rejects_source_generation_swap() {
  local st source moved destination ready proceed output pid status
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-copy-generation.XXXXXX")
  mkdir -p "$st/state" "$st/backup"
  source="$st/state/source"; moved="$st/state/source-owned"; destination="$st/backup/destination"
  ready="$st/ready"; proceed="$st/proceed"; output="$st/output"
  printf 'owned\n' > "$source"; printf 'destination\n' > "$destination"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_COPY_TEST_READY="$ready" \
    FM_AFK_COPY_TEST_PROCEED="$proceed" bash -c \
    '. "$1"; fm_afk_safe_control_copy "$2" "$3" 4096' _ "$START" "$source" "$destination" \
    > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.01; done
  if [ ! -e "$ready" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "AFK copy: source-generation gate did not open"
    rm -rf "$st"
    return
  fi
  mv "$source" "$moved"; printf 'raced\n' > "$source"; touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  if [ "$status" -ne 0 ] && grep -F destination "$destination" >/dev/null 2>&1; then
    pass "AFK copy: source generation is pinned through open"
  else
    fail "AFK copy: accepted a source generation swapped between stat and open"
  fi
  rm -rf "$st"
}

unit_afk_control_reads_are_nonblocking_and_generation_pinned() {
  local st control ready proceed output pid rc
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-control-read.XXXXXX")
  mkdir -p "$st/state"
  control="$st/state/control"
  mkfifo "$control"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c \
    '. "$1"; fm_afk_safe_control_read "$2" 4096' _ "$START" "$control" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.01; done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "AFK control reader blocked while opening a FIFO"
  else
    wait "$pid" 2>/dev/null; rc=$?
    [ "$rc" -ne 0 ] || fail "AFK control reader accepted a FIFO"
  fi

  rm -f "$control"
  printf 'first\n' > "$control"
  ready="$st/ready"; proceed="$st/proceed"; output="$st/output"
  FM_AFK_CONTROL_READ_TEST_READY="$ready" FM_AFK_CONTROL_READ_TEST_PROCEED="$proceed" \
    FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c \
      '. "$1"; fm_afk_safe_control_read "$2" 4096' _ "$START" "$control" > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.01; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "AFK control read generation gate did not open"; }
  mv "$control" "$control.previous"
  printf 'other\n' > "$control"
  touch "$proceed"
  wait "$pid" 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "AFK control reader accepted a same-size replacement generation"
  pass "AFK control reads reject special files and same-size generation swaps"
  rm -rf "$st"
}

unit_flag_write_failure_aborts() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-flag-fail.XXXXXX")
  mkdir -p "$st/state"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_flag_write() { return 1; }
    ! fm_afk_launch_start_native
  ' _ "$LAUNCH"
  if [ ! -e "$st/state/.afk" ] && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "flag failure: lifecycle aborts without active state"
  else
    fail "flag failure: lifecycle reported active state"
  fi
  rm -rf "$st"
}

unit_herdr_reused_pane_identity_fails_closed() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-reused.XXXXXX")
  mkdir -p "$st/state"
  printf 'herdr\tlab:pane-reused\tws-owned|afk-owned\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_backend_source() { return 0; }
    fm_backend_herdr_cli() {
      case "$2 $3" in
        "workspace list") printf %s '\''{"result":{"workspaces":[{"workspace_id":"ws-owned","label":"afk-owned"}]}}'\'' ;;
        "pane list") printf %s '\''{"result":{"panes":[]}}'\'' ;;
        "pane get") printf %s '\''{"result":{"pane":{"pane_id":"pane-reused"}}}'\'' ;;
        "pane close") : > "$FM_HOME/closed" ;;
        *) return 2 ;;
      esac
    }
    fm_afk_launch_record_read
    ! fm_afk_launch_close_recorded
  ' _ "$LAUNCH" && [ ! -e "$st/closed" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "herdr identity: a reused pane id cannot close another workspace"
  else
    fail "herdr identity: a reused pane id was closed or discarded"
  fi
  rm -rf "$st"
}

unit_tmux_partial_create_preserves_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-partial.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    tmux() {
      case "$1" in
        new-session) return 1 ;;
        has-session) return 0 ;;
        kill-session) : > "$FM_HOME/killed" ;;
      esac
    }
    ! fm_afk_launch_create_tmux captain:0 tmux
  ' _ "$LAUNCH" && [ -s "$st/state/.afk-daemon-terminal" ] && [ ! -e "$st/killed" ]; then
    pass "tmux launch: partial creation preserves its exact reconciliation record"
  else
    fail "tmux launch: partial creation lost its exact reconciliation record"
  fi
  rm -rf "$st"
}

unit_legacy_supervisor_fallback_is_usable() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-legacy-fallback.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 1; }
    fm_afk_launch_reconcile() { return 0; }
    fm_afk_clear_stale_artifacts() { return 0; }
    fm_afk_launch_flag_write() { return 0; }
    fm_afk_launch_create_tmux() { printf "%s|%s" "$1" "$2" > "$FM_HOME/fallback"; }
    fm_afk_launch_start
  ' _ "$LAUNCH" && [ "$(cat "$st/fallback" 2>/dev/null)" = 'firstmate:0|tmux' ]; then
    pass "supervisor discovery: the explicit legacy fallback remains usable"
  else
    fail "supervisor discovery: the legacy fallback was rejected"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# E2E herdr: topology invariant.
# ---------------------------------------------------------------------------
e2e_herdr() {
  command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found (herdr e2e)"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (herdr e2e)"; return 0; }
  # shellcheck source=tests/herdr-test-safety.sh
  . "$ROOT/tests/herdr-test-safety.sh"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"

  local SESSION home_tmp cap_ws cap_tab cap_pane target
  local before during after ws_before ws_during ws_after out dtgt dtab
  SESSION="fm-lab-afk-launch-e2e-$$"
  export HERDR_SESSION="$SESSION"
  herdr_test_lab_available "$SESSION" || return 0
  home_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e-home.XXXXXX")
  E2E_HERDR_CLEANUP() {
    FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
      FM_SUPERVISOR_TARGET="$target" FM_SUPERVISOR_BACKEND=herdr "$LAUNCH" stop >/dev/null 2>&1 || true
    herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1 || true
    rm -rf "$home_tmp" 2>/dev/null || true
  }
  fm_herdr_lab_prepare "$SESSION" || { fail "herdr e2e: could not prepare isolated lab session"; return 0; }
  fm_backend_source herdr || { E2E_HERDR_CLEANUP; fail "herdr e2e: fm_backend_source herdr failed"; return 0; }
  fm_backend_herdr_server_ensure "$SESSION" || { E2E_HERDR_CLEANUP; fail "herdr e2e: lab server did not start"; return 0; }

  out=$(fm_backend_herdr_cli "$SESSION" workspace create --cwd "$ROOT" --label captain --no-focus 2>/dev/null)
  cap_ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
  cap_tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
  cap_pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
  if [ -z "$cap_ws" ] || [ -z "$cap_pane" ]; then E2E_HERDR_CLEANUP; fail "herdr e2e: could not create captain workspace"; return 0; fi
  target="$SESSION:$cap_pane"
  before=$(fm_backend_herdr_cli "$SESSION" pane list --workspace "$cap_ws" 2>/dev/null | jq --arg t "$cap_tab" '[.result.panes[]?|select(.tab_id==$t)]|length')
  ws_before=$(fm_backend_herdr_cli "$SESSION" workspace list 2>/dev/null | jq '[.result.workspaces[]?]|length')

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$target" FM_SUPERVISOR_BACKEND=herdr FM_AFK_LAUNCH_ENTRY="$SLEEPER" \
    "$LAUNCH" start >/dev/null 2>&1

  during=$(fm_backend_herdr_cli "$SESSION" pane list --workspace "$cap_ws" 2>/dev/null | jq --arg t "$cap_tab" '[.result.panes[]?|select(.tab_id==$t)]|length')
  ws_during=$(fm_backend_herdr_cli "$SESSION" workspace list 2>/dev/null | jq '[.result.workspaces[]?]|length')
  dtgt=$(cut -f2 "$home_tmp/state/.afk-daemon-terminal" 2>/dev/null || true)
  dtab=$(fm_backend_herdr_cli "$SESSION" pane get "${dtgt#*:}" 2>/dev/null | jq -r '.result.pane.tab_id // empty')

  if [ "$before" = "$during" ]; then pass "herdr e2e: captain tab pane count unchanged after start (no split)"; else fail "herdr e2e: captain tab pane count changed ($before -> $during)"; fi
  if [ "$ws_during" -gt "$ws_before" ]; then pass "herdr e2e: daemon launched in a separate non-visible workspace"; else fail "herdr e2e: no separate daemon workspace created"; fi
  if [ -n "$dtab" ] && [ "$dtab" != "$cap_tab" ]; then pass "herdr e2e: daemon pane is NOT in the captain's tab"; else fail "herdr e2e: daemon pane shares the captain tab ($dtab)"; fi
  case "$dtgt" in "$SESSION":*) pass "herdr e2e: daemon terminal scoped to the lab session" ;; *) fail "herdr e2e: daemon terminal not in the lab session ($dtgt)" ;; esac

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$target" FM_SUPERVISOR_BACKEND=herdr "$LAUNCH" stop >/dev/null 2>&1

  after=$(fm_backend_herdr_cli "$SESSION" pane list --workspace "$cap_ws" 2>/dev/null | jq --arg t "$cap_tab" '[.result.panes[]?|select(.tab_id==$t)]|length')
  ws_after=$(fm_backend_herdr_cli "$SESSION" workspace list 2>/dev/null | jq '[.result.workspaces[]?]|length')
  if [ "$after" = "$before" ]; then pass "herdr e2e: captain tab pane count restored after stop"; else fail "herdr e2e: captain tab pane count not restored ($before -> $after)"; fi
  if [ "$ws_after" = "$ws_before" ]; then pass "herdr e2e: daemon workspace removed by exact id on stop"; else fail "herdr e2e: daemon workspace leaked ($ws_before -> $ws_after)"; fi
  if [ ! -e "$home_tmp/state/.afk-daemon-terminal" ] && [ ! -e "$home_tmp/state/.afk" ]; then pass "herdr e2e: record + .afk cleared on stop"; else fail "herdr e2e: record or .afk not cleared"; fi

  E2E_HERDR_CLEANUP
}

# ---------------------------------------------------------------------------
# E2E tmux: topology invariant (captain window untouched; daemon in a separate
# detached session).
# ---------------------------------------------------------------------------
e2e_tmux() {
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found (tmux e2e)"; return 0; }
  local cap_session home_tmp cap_pane before during after rec
  cap_session="fm-afk-launch-cap-$$"
  home_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-home.XXXXXX")
  tmux new-session -d -s "$cap_session" 2>/dev/null || { fail "tmux e2e: could not create captain session"; rm -rf "$home_tmp"; return 0; }
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $cap_session"
  cap_pane=$(tmux display-message -p -t "$cap_session" '#{pane_id}')
  before=$(tmux list-panes -t "$cap_session" | wc -l | tr -d ' ')

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$cap_pane" FM_SUPERVISOR_BACKEND=tmux FM_AFK_LAUNCH_ENTRY="$SLEEPER" \
    "$LAUNCH" start >/dev/null 2>&1

  during=$(tmux list-panes -t "$cap_session" | wc -l | tr -d ' ')
  rec=$(cut -f2 "$home_tmp/state/.afk-daemon-terminal" 2>/dev/null || true)
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $rec"
  if [ "$before" = "$during" ]; then pass "tmux e2e: captain window pane count unchanged after start (no split-window)"; else fail "tmux e2e: captain window pane count changed ($before -> $during)"; fi
  if [ -n "$rec" ] && tmux has-session -t "$rec" 2>/dev/null && [ "$rec" != "$cap_session" ]; then pass "tmux e2e: daemon launched in a separate detached session"; else fail "tmux e2e: no separate daemon session ($rec)"; fi

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$cap_pane" FM_SUPERVISOR_BACKEND=tmux "$LAUNCH" stop >/dev/null 2>&1

  after=$(tmux list-panes -t "$cap_session" | wc -l | tr -d ' ')
  if [ "$after" = "$before" ]; then pass "tmux e2e: captain window pane count unchanged after stop"; else fail "tmux e2e: captain window changed ($before -> $after)"; fi
  if [ -n "$rec" ] && ! tmux has-session -t "$rec" 2>/dev/null; then pass "tmux e2e: daemon session killed by exact id on stop"; else fail "tmux e2e: daemon session leaked ($rec)"; fi
  if [ ! -e "$home_tmp/state/.afk-daemon-terminal" ] && [ ! -e "$home_tmp/state/.afk" ]; then pass "tmux e2e: record + .afk cleared on stop"; else fail "tmux e2e: record or .afk not cleared"; fi

  tmux kill-session -t "$cap_session" 2>/dev/null || true
  rm -rf "$home_tmp" 2>/dev/null || true
}

if [ "${FM_TEST_FOCUSED:-}" = flag-staging ]; then
  unit_flag_staging_does_not_follow_predictable_symlink
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-10 ]; then
  unit_launcher_lock_symlinks_are_refused
  unit_terminal_record_symlink_is_malformed
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-12 ]; then
  unit_tmux_record_is_home_scoped_and_exact
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-13 ]; then
  unit_launcher_control_files_are_bounded_and_nonfollowing
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-16 ]; then
  unit_stop_rejects_native_marker_for_unrelated_command
  unit_afk_backups_reject_unsafe_or_oversized_sources
  unit_native_start_stop_handoff_is_atomic
  unit_direct_native_start_stop_handoff_is_atomic
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-17 ]; then
  unit_afk_bounded_copy_preserves_mtime
  unit_native_command_identity_is_anchored
  unit_native_process_marker_is_one_bounded_snapshot
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-18 ]; then
  unit_native_handoff_lock_wait_is_bounded
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-35 ]; then
  unit_afk_control_reads_are_nonblocking_and_generation_pinned
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-36 ]; then
  unit_afk_bounded_copy_rejects_source_generation_swap
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = signal-lock-cleanup ]; then
  unit_signal_exits_with_lock_cleanup
  unit_signal_during_lock_publication_cleanup
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = afk-lock-aba ]; then
  unit_stale_lock_reclaim_is_serialized
  unit_abandoned_reclaim_is_recovered
  unit_reclaim_owner_liveness_is_tristate
  unit_reclaim_test_handshake_requires_inherited_fds
  unit_namespace_guard_releases_when_owner_crashes
  unit_abandoned_reclaim_parent_aba_is_fenced
  unit_claimed_parent_swap_restores_quarantine
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

unit_detached_daemons_receive_state_override
unit_clear_stale
unit_fresh_vs_refresh
unit_stop_ordering
unit_stop_rejects_reused_pid
unit_stop_rejects_native_marker_for_unrelated_command
unit_native_command_identity_is_anchored
unit_native_process_marker_is_one_bounded_snapshot
unit_failed_start_rolls_back_state
unit_concurrent_start_serialized
unit_lock_initialization_grace
unit_stale_lock_reclaim_is_serialized
unit_abandoned_reclaim_is_recovered
unit_reclaim_owner_liveness_is_tristate
unit_reclaim_test_handshake_requires_inherited_fds
unit_namespace_guard_releases_when_owner_crashes
unit_abandoned_reclaim_parent_aba_is_fenced
unit_claimed_parent_swap_restores_quarantine
unit_launcher_lock_symlinks_are_refused
unit_launcher_control_files_are_bounded_and_nonfollowing
unit_terminal_record_symlink_is_malformed
unit_tmux_record_is_home_scoped_and_exact
unit_linux_stat_selection_avoids_filesystem_stat_output
unit_signal_exits_with_lock_cleanup
unit_signal_during_lock_publication_cleanup
unit_herdr_partial_create_recovery
unit_herdr_creation_intent_reconciles
unit_expired_herdr_creation_intent_clears
unit_herdr_error_with_exact_ids_closes_exact
unit_herdr_run_failure_preserves_unconfirmed_record
unit_record_failure_closes_terminal
unit_readiness_failure_rolls_back_terminal
unit_readiness_failure_preserves_unconfirmed_record
unit_tmux_absence_distinguishes_probe_failure
unit_native_lifecycle
unit_recovery_preserves_buffered_escalations
unit_native_entry_preserves_prepared_state
unit_native_start_stop_handoff_is_atomic
unit_direct_native_start_stop_handoff_is_atomic
unit_native_handoff_lock_wait_is_bounded
unit_close_failure_preserves_record
unit_record_publication_atomic
unit_publication_rejects_unsafe_destinations
unit_malformed_record_fails_closed
unit_stop_malformed_record_fails_closed
unit_tmux_planned_record_and_collision
unit_stop_validates_before_signal
unit_lock_requires_complete_metadata
unit_stop_surfaces_afk_removal_failure
unit_stop_confirms_daemon_exit
unit_stop_confirms_native_process_exit
unit_refresh_validates_record
unit_herdr_reused_pane_identity_fails_closed
unit_tmux_partial_create_preserves_record
unit_legacy_supervisor_fallback_is_usable
unit_clear_failure_aborts_entry
unit_confirmed_absence_succeeds
unit_incomplete_restore_retains_backup
unit_afk_backups_reject_unsafe_or_oversized_sources
unit_afk_bounded_copy_preserves_mtime
unit_afk_bounded_copy_rejects_source_generation_swap
unit_afk_control_reads_are_nonblocking_and_generation_pinned
unit_flag_write_failure_aborts
unit_flag_staging_does_not_follow_predictable_symlink
e2e_herdr
e2e_tmux

[ "$FAILED" -eq 0 ] || exit 1
