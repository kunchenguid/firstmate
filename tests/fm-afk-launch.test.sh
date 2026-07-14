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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
START="$ROOT/bin/fm-afk-start.sh"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

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

unit_signal_exits_with_lock_cleanup() {
  local st marker child
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-signal.XXXXXX")
  marker="$st/resumed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_start() { sleep 30; }
    fm_afk_launch_main start
    : > "$2"
  ' _ "$LAUNCH" "$marker" &
  child=$!
  for _ in $(seq 1 40); do
    [ -d "$st/state/.afk-launch.lock" ] && break
    sleep 0.05
  done
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  if [ ! -e "$marker" ] && [ ! -e "$st/state/.afk-launch.lock" ]; then
    pass "launcher signal: TERM exits and releases the lifecycle lock"
  else
    fail "launcher signal: interrupted lifecycle resumed or retained its lock"
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
  if [ "$(cat "$recorded" 2>/dev/null || true)" = "herdr:lab:pane-exact:ws-partial" ]; then
    pass "herdr create: malformed response recovers durable exact ownership"
  else
    fail "herdr create: malformed response left terminal ownership unknown"
  fi
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

unit_native_entry_preserves_prepared_state() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native-entry.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  : > "$st/state/.subsuper-escalations"
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

unit_close_failure_preserves_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-close-fail.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\texact-session\towned\n' > "$st/state/.afk-daemon-terminal"
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
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-confirmed-absent.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\texact-session\towned\n' > "$st/state/.afk-daemon-terminal"
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
    cp() { return 1; }
    ! fm_afk_launch_restore_backup "$2" 1
  ' _ "$LAUNCH" "$backup" && [ -d "$backup" ] && [ -e "$backup/.afk" ]; then
    pass "rollback restore: incomplete restoration retains its recovery backup"
  else
    fail "rollback restore: incomplete restoration discarded its backup"
  fi
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

# ---------------------------------------------------------------------------
# UNIT: the arm-time injection canary on the FOREGROUND arm path.
#
# The away-mode daemon injects only into a pane with a confirmed live agent
# process, and it fails closed - so a supervisor whose harness a backend cannot
# attribute (pi execs into a generic `node`) receives NO escalation for the whole
# away session. The daemon probes that at arm time too, but it does so from inside
# the terminal it was launched in: a detached tmux session or a --no-focus herdr
# workspace nobody attaches to, on exactly the path a bad verdict is most likely
# on. THIS script runs in the foreground of the pane away mode is armed from, so
# its own stderr is the channel firstmate actually reads and relays. These cases
# pin that warning, that it names the right cause (a `dead` target is the wrong
# pane - fixable; an `unknown` harness is the accepted pi degradation), and that a
# bad verdict NEVER turns into a failed arm.
#
# A fake tmux answers pane_current_command - the whole input to the liveness
# verdict - and no-ops the terminal lifecycle, the same seam tests/fm-daemon.test.sh
# uses for the daemon's own probe. It answers PER TARGET (`-t <pane>`), because
# which pane the canary probes is itself under test: FM_FAKE_TMUX_COMMAND is what
# runs in firstmate's own pane, while FM_FAKE_DAEMON_PANE_COMMAND is what runs in
# the separate pane a live daemon was launched against. FM_FAKE_MISSING_PANE fails
# every query for one pane, which is how a pane that no longer exists reads.
make_canary_tmux() {  # <dir> -> prints the fakebin path
  local fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
target=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-t" ] && target="$arg"
  prev="$arg"
done
if [ -n "${FM_FAKE_MISSING_PANE:-}" ] && [ "$target" = "$FM_FAKE_MISSING_PANE" ]; then
  exit 1
fi
command=${FM_FAKE_TMUX_COMMAND:-claude}
if [ -n "${FM_FAKE_DAEMON_PANE:-}" ] && [ "$target" = "$FM_FAKE_DAEMON_PANE" ]; then
  command=${FM_FAKE_DAEMON_PANE_COMMAND:-$command}
fi
for arg in "$@"; do
  case "$arg" in
    *pane_current_command*) printf '%s\n' "$command"; exit 0 ;;
    *pane_id*) printf '%s\n' "${target:-%1}"; exit 0 ;;
  esac
done
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s' "$fakebin"
}

# Arm away mode with the supervisor pane running <pane-command>, capturing the
# launcher's own stderr and exit status. <missing-pane>, when given, is a pane the
# fake tmux cannot resolve at all.
run_canary_arm() {  # <case> <pane-command> [<missing-pane>]
  local fakebin
  CANARY_HOME=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-canary-$1.XXXXXX")
  CANARY_ERR="$CANARY_HOME/arm.err"
  fakebin=$(make_canary_tmux "$CANARY_HOME")
  PATH="$fakebin:$PATH" FM_HOME="$CANARY_HOME" FM_STATE_OVERRIDE="$CANARY_HOME/state" \
    FM_SUPERVISOR_TARGET='%1' FM_SUPERVISOR_BACKEND=tmux \
    FM_FAKE_TMUX_COMMAND="$2" FM_FAKE_MISSING_PANE="${3:-}" FM_AFK_LAUNCH_ENTRY="$SLEEPER" \
    "$LAUNCH" start >/dev/null 2>"$CANARY_ERR"
  CANARY_RC=$?
}

# Arm away mode while a LIVE daemon already holds the lock and has published the
# pane it injects into (%5), with firstmate itself restarted into a DIFFERENT pane
# (%9). fm_afk_launch_start returns early on that live lock without retargeting the
# daemon, which is precisely the state a restarted firstmate re-enters, so this is
# the setup for every case about the daemon's own target. Extra env assignments say
# what %5 reads as.
run_canary_arm_over_live_daemon() {  # <case> [<env>=<value>...]
  local fakebin daemon_stub daemon_pid lock
  CANARY_HOME=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-canary-$1.XXXXXX")
  CANARY_ERR="$CANARY_HOME/arm.err"
  mkdir -p "$CANARY_HOME/state"
  fakebin=$(make_canary_tmux "$CANARY_HOME")
  shift

  # A live process that reads as the away-mode daemon, holding the daemon lock and
  # publishing the pane it injects into. The lock's pid-identity is what marks its
  # owner as a real daemon rather than a recycled pid, and the stub writes it from
  # INSIDE itself exactly as the real daemon does: `ps` reports the command line
  # differently before and after the interpreter re-execs, so an identity captured
  # from outside at spawn time can disagree with the very next read and make a live
  # daemon look dead.
  lock="$CANARY_HOME/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  daemon_stub="$CANARY_HOME/fm-supervise-daemon.sh"
  cat > "$daemon_stub" <<'SH'
#!/usr/bin/env bash
FM_STATE_OVERRIDE=$(dirname "$1") . "$2"
fm_pid_identity "${BASHPID:-$$}" > "$1/pid-identity"
while :; do sleep 0.2; done
SH
  chmod +x "$daemon_stub"
  "$daemon_stub" "$lock" "$ROOT/bin/fm-wake-lib.sh" &
  daemon_pid=$!
  printf '%s' "$daemon_pid" > "$lock/pid"
  for _ in $(seq 1 100); do
    [ -s "$lock/pid-identity" ] && break
    sleep 0.05
  done
  printf 'tmux\t%%5\n' > "$lock/supervisor-endpoint"
  date '+%s' > "$CANARY_HOME/state/.afk"

  env "$@" PATH="$fakebin:$PATH" FM_HOME="$CANARY_HOME" FM_STATE_OVERRIDE="$CANARY_HOME/state" \
    FM_SUPERVISOR_TARGET='%9' FM_SUPERVISOR_BACKEND=tmux FM_FAKE_TMUX_COMMAND=claude \
    FM_AFK_LAUNCH_ENTRY="$SLEEPER" "$LAUNCH" start >/dev/null 2>"$CANARY_ERR"
  CANARY_RC=$?
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
}

# Every non-alive verdict is ADVISORY: away mode must still be armed afterwards.
assert_canary_still_armed() {  # <case>
  [ "$CANARY_RC" -eq 0 ] \
    || fail "canary($1): a non-alive probe must never fail the arm (exit $CANARY_RC)"
  [ -e "$CANARY_HOME/state/.afk" ] \
    || fail "canary($1): away mode did not arm"
  [ -e "$CANARY_HOME/state/.afk-daemon-terminal" ] \
    || fail "canary($1): the daemon terminal was not recorded, so the arm did not complete"
}

unit_canary_warns_on_dead_supervisor() {
  run_canary_arm dead zsh
  assert_canary_still_armed dead
  grep -F 'AWAY-MODE INJECTION IS DISABLED FOR THIS SUPERVISOR' "$CANARY_ERR" >/dev/null \
    || fail "canary(dead): the foreground arm path printed no warning on its own stderr: $(cat "$CANARY_ERR")"
  grep -F 'is a bare shell, not the pane running firstmate' "$CANARY_ERR" >/dev/null \
    || fail "canary(dead): the warning did not name the wrong target as the cause"
  grep -F 'point FM_SUPERVISOR_TARGET' "$CANARY_ERR" >/dev/null \
    || fail "canary(dead): the warning gave no repoint remediation for a wrong target"
  if grep -F 'generic node' "$CANARY_ERR" >/dev/null; then
    fail "canary(dead): a wrong target was misreported as the accepted unattributable-harness degradation"
  fi
  pass "arm canary: a dead supervisor target warns in the foreground, names the wrong target, and still arms"
  rm -rf "$CANARY_HOME"
}

# `unknown` is not one condition, so it must not be diagnosed as one. The probe
# returns it for pi's unattributable generic `node`, but equally for a wrapper, an
# unreadable pane, or an outright probe error - and only the first of those is the
# accepted degradation. A confident "do nothing" here would send a captain whose
# supervisor pane is simply unreadable off to live with a problem they could fix.
unit_canary_warns_on_unattributable_harness() {
  run_canary_arm unknown node
  assert_canary_still_armed unknown
  grep -F 'AWAY-MODE INJECTION IS DISABLED FOR THIS SUPERVISOR' "$CANARY_ERR" >/dev/null \
    || fail "canary(unknown): an unattributable harness armed with no foreground warning: $(cat "$CANARY_ERR")"
  grep -F 'liveness could not be confirmed' "$CANARY_ERR" >/dev/null \
    || fail "canary(unknown): an ambiguous verdict was not reported as ambiguous"
  grep -F 'cannot be attributed there (pi runs as a generic node)' "$CANARY_ERR" >/dev/null \
    || fail "canary(unknown): the warning did not offer the unattributable harness as a cause"
  grep -F 'could not be read' "$CANARY_ERR" >/dev/null \
    || fail "canary(unknown): the warning did not offer an unreadable pane as the OTHER cause of the same verdict"
  grep -F 'accepted degradation' "$CANARY_ERR" >/dev/null \
    || fail "canary(unknown): the warning never says a confirmed-target unknown is an accepted degradation"
  grep -F "check that the target above is still firstmate's own pane" "$CANARY_ERR" >/dev/null \
    || fail "canary(unknown): the remediation skipped straight to acceptance without having the captain confirm the target first"
  if grep -F 'is a bare shell' "$CANARY_ERR" >/dev/null; then
    fail "canary(unknown): an ambiguous verdict was misreported with the definite dead-target diagnosis"
  fi
  pass "arm canary: an ambiguous verdict names BOTH its causes and confirms the target before accepting it"
  rm -rf "$CANARY_HOME"
}

# The daemon fixes its injection target ONCE, at launch, and fm_afk_launch_start
# returns early on a live daemon WITHOUT retargeting it. So away mode armed in pane
# %5 outlives firstmate's session: the captain restarts firstmate in a new pane %9,
# state/.afk is still set, recovery re-arms - and the daemon is still typing into
# %5. A canary that probed the pane it was RUN in would find firstmate obviously
# alive in %9 and report all-clear, while every escalation lands in a pane nobody
# is reading. It has to probe the pane the running daemon actually injects into.
#
# The remediation has to follow the same fact. Re-arming does NOT retarget a live
# daemon - the early return above refreshes state/.afk and nothing else, and there
# is no retarget subcommand - so telling the reader to repoint and re-arm here is
# advice that provably changes nothing. Away mode has to be stopped first.
unit_canary_probes_the_running_daemons_target() {
  # firstmate is back, in %9, provably alive there. The daemon's %5 is a bare shell.
  run_canary_arm_over_live_daemon restart FM_FAKE_DAEMON_PANE='%5' FM_FAKE_DAEMON_PANE_COMMAND=zsh

  [ "$CANARY_RC" -eq 0 ] || fail "canary(restart): the canary is advisory and must never fail the arm (exit $CANARY_RC)"
  grep -F 'AWAY-MODE INJECTION IS DISABLED FOR THIS SUPERVISOR' "$CANARY_ERR" >/dev/null \
    || fail "canary(restart): probed firstmate's own live pane instead of the one the running daemon injects into, so a broken away mode reported all-clear: $(cat "$CANARY_ERR")"
  grep -F "target '%5'" "$CANARY_ERR" >/dev/null \
    || fail "canary(restart): the warning did not name the daemon's actual target: $(cat "$CANARY_ERR")"
  if grep -F "target '%9'" "$CANARY_ERR" >/dev/null; then
    fail "canary(restart): the canary probed the pane it was RUN in, not the daemon's target"
  fi
  grep -F 'stop away mode' "$CANARY_ERR" >/dev/null \
    || fail "canary(restart): the remediation did not say to stop the running daemon, so the printed fix is a no-op: $(cat "$CANARY_ERR")"
  pass "arm canary: a refresh probes the running daemon's target and says to stop away mode, not just re-arm it"
  rm -rf "$CANARY_HOME"
}

# The worst state in the design, and the one the surfaces above were built to
# catch: the pane a LIVE daemon injects into is GONE (the captain's terminal died,
# which is the ordinary reason firstmate gets restarted at all). The daemon delivers
# nothing, and with no pane it never reaches housekeeping, so not even the wedge
# alarm fires - every other channel is silent by construction. Treating the missing
# pane as "nothing to say", the way an unresolvable fallback pane is treated, would
# make this the one failure that reports all-clear from every surface at once. Here
# the non-existence IS the diagnosis.
unit_canary_reports_a_vanished_daemon_target() {
  run_canary_arm_over_live_daemon gone FM_FAKE_MISSING_PANE='%5'

  [ "$CANARY_RC" -eq 0 ] || fail "canary(gone): the canary is advisory and must never fail the arm (exit $CANARY_RC)"
  grep -F 'AWAY-MODE INJECTION IS DISABLED FOR THIS SUPERVISOR' "$CANARY_ERR" >/dev/null \
    || fail "canary(gone): the daemon is injecting into a pane that no longer exists and every surface stayed silent: $(cat "$CANARY_ERR")"
  grep -F "target '%5'" "$CANARY_ERR" >/dev/null \
    || fail "canary(gone): the warning did not name the vanished pane: $(cat "$CANARY_ERR")"
  grep -F 'no longer exists' "$CANARY_ERR" >/dev/null \
    || fail "canary(gone): the warning did not say the daemon's target is gone: $(cat "$CANARY_ERR")"
  grep -F 'wedge alarm' "$CANARY_ERR" >/dev/null \
    || fail "canary(gone): the warning did not say the wedge alarm cannot fire either, which is what makes this state silent"
  grep -F 'stop away mode' "$CANARY_ERR" >/dev/null \
    || fail "canary(gone): the remediation did not say to stop the running daemon, so the printed fix is a no-op"
  pass "arm canary: a live daemon injecting into a vanished pane is reported loudly, not swallowed"
  rm -rf "$CANARY_HOME"
}

# The other half of that branch. With NO live daemon, the pane in hand is just the
# one the launcher is running in, and if it does not resolve there is no foreground
# process to read - every verdict would be a guess dressed up as a diagnosis. Stay
# quiet. Only a live daemon's own asserted target turns a missing pane into news.
unit_canary_quiet_when_the_probed_pane_is_unresolvable() {
  run_canary_arm missing claude '%1'
  assert_canary_still_armed missing
  if grep -F 'AWAY-MODE INJECTION IS DISABLED' "$CANARY_ERR" >/dev/null; then
    fail "canary(missing): invented a verdict for a pane it could not resolve: $(cat "$CANARY_ERR")"
  fi
  pass "arm canary: an unresolvable pane with no live daemon stays quiet"
  rm -rf "$CANARY_HOME"
}

unit_canary_silent_when_agent_alive() {
  run_canary_arm alive claude
  assert_canary_still_armed alive
  if grep -F 'AWAY-MODE INJECTION IS DISABLED' "$CANARY_ERR" >/dev/null; then
    fail "canary(alive): warned even though the supervisor agent was alive (false alarm)"
  fi
  pass "arm canary: a live supervisor agent arms with no warning"
  rm -rf "$CANARY_HOME"
}

unit_clear_stale
unit_fresh_vs_refresh
unit_canary_warns_on_dead_supervisor
unit_canary_warns_on_unattributable_harness
unit_canary_silent_when_agent_alive
unit_canary_probes_the_running_daemons_target
unit_canary_reports_a_vanished_daemon_target
unit_canary_quiet_when_the_probed_pane_is_unresolvable
unit_stop_ordering
unit_stop_rejects_reused_pid
unit_failed_start_rolls_back_state
unit_concurrent_start_serialized
unit_lock_initialization_grace
unit_signal_exits_with_lock_cleanup
unit_herdr_partial_create_recovery
unit_herdr_error_with_exact_ids_closes_exact
unit_herdr_run_failure_preserves_unconfirmed_record
unit_record_failure_closes_terminal
unit_readiness_failure_rolls_back_terminal
unit_readiness_failure_preserves_unconfirmed_record
unit_tmux_absence_distinguishes_probe_failure
unit_native_lifecycle
unit_native_entry_preserves_prepared_state
unit_close_failure_preserves_record
unit_record_publication_atomic
unit_malformed_record_fails_closed
unit_stop_malformed_record_fails_closed
unit_tmux_planned_record_and_collision
unit_stop_validates_before_signal
unit_lock_requires_complete_metadata
unit_stop_surfaces_afk_removal_failure
unit_stop_confirms_daemon_exit
unit_refresh_validates_record
unit_clear_failure_aborts_entry
unit_confirmed_absence_succeeds
unit_incomplete_restore_retains_backup
unit_flag_write_failure_aborts
e2e_herdr
e2e_tmux

[ "$FAILED" -eq 0 ] || exit 1
