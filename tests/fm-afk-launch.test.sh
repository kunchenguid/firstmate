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
#   NON-VISIBLE separate terminal (a herdr dedicated workspace, a detached herdr
#   session), never a split of the captain's pane. The herdr path runs on a
#   throwaway, NEVER-default HERDR_SESSION and asserts the default session is
#   byte-identical via the fm-herdr-lab.sh fleet-state tripwire; the herdr path
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
GLOBAL_CLEANUP() {
  rm -f "$SLEEPER" 2>/dev/null || true
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
    ! fm_afk_launch_commit_terminal herdr exact-session ""
  ' _ "$LAUNCH"
  if [ "$(cat "$closed" 2>/dev/null || true)" = "herdr:exact-session" ]; then
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
    ! fm_afk_launch_commit_terminal herdr exact-session ""
  ' _ "$LAUNCH"
  if [ "$(cat "$closed" 2>/dev/null || true)" = "herdr:exact-session" ] \
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
    ! fm_afk_launch_commit_terminal herdr exact-session ""
  ' _ "$LAUNCH"
  if [ "$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)" = exact-session ]; then
    pass "readiness failure: unconfirmed terminal retains its reconciliation id"
  else
    fail "readiness failure: unconfirmed terminal lost its reconciliation id"
  fi
  rm -rf "$st"
}

unit_herdr_absence_distinguishes_probe_failure() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-probe.XXXXXX")
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    herdr() { printf "%s" "can'\''t find session: exact-session" >&2; return 1; }
    fm_afk_launch_terminal_absent herdr exact-session
    herdr() { printf "%s" "error connecting to /tmp/herdr.sock" >&2; return 1; }
    ! fm_afk_launch_terminal_absent herdr exact-session
  ' _ "$LAUNCH"; then
    pass "herdr absence: clean missing differs from transport probe failure"
  else
    fail "herdr absence: probe failure was treated as confirmed absence"
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
  printf 'herdr\texact-session\towned\n' > "$st/state/.afk-daemon-terminal"
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
  printf 'herdr\told-session\towned\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    mv() { return 1; }
    ! fm_afk_launch_record_write herdr new-session owned
  ' _ "$LAUNCH" \
    && [ "$(cat "$st/state/.afk-daemon-terminal")" = $'herdr\told-session\towned' ] \
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
  printf 'herdr\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
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

unit_removed_runtime_record_fails_closed() {
  local st runtime out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-removed.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  runtime=$(printf '\164\155\165\170')
  printf '%s\tfm-afk-daemon-upgrade\t\n' "$runtime" > "$st/state/.afk-daemon-terminal"
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    ! fm_afk_launch_reconcile && ! fm_afk_launch_stop
  ' _ "$LAUNCH" 2>&1)
  if [ -e "$st/state/.afk" ] && [ -e "$st/state/.afk-daemon-terminal" ] \
    && [[ "$out" == *"legacy removed-runtime daemon state"* ]] \
    && [[ "$out" == *"remove only this terminal record"* ]]; then
    pass "record read: removed-runtime daemon state is diagnosed and preserved"
  else
    fail "record read: removed-runtime daemon state was ambiguous, changed, or discarded"
  fi
  rm -rf "$st"
}

unit_stop_malformed_record_fails_closed() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-malformed.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  printf 'herdr\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
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

unit_stop_validates_before_signal() {
  local st sleeper_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-validate.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  printf 'herdr\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
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
  printf 'herdr\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  sleep 30 & daemon_pid=$!
  printf '%s' "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid-identity" )
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=herdr bash -c '
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
  printf 'herdr\texact-session\towned\n' > "$st/state/.afk-daemon-terminal"
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

unit_clear_stale
unit_fresh_vs_refresh
unit_stop_ordering
unit_stop_rejects_reused_pid
unit_failed_start_rolls_back_state
unit_lock_initialization_grace
unit_signal_exits_with_lock_cleanup
unit_herdr_partial_create_recovery
unit_herdr_error_with_exact_ids_closes_exact
unit_herdr_run_failure_preserves_unconfirmed_record
unit_record_failure_closes_terminal
unit_readiness_failure_rolls_back_terminal
unit_readiness_failure_preserves_unconfirmed_record
unit_herdr_absence_distinguishes_probe_failure
unit_native_lifecycle
unit_native_entry_preserves_prepared_state
unit_close_failure_preserves_record
unit_record_publication_atomic
unit_malformed_record_fails_closed
unit_removed_runtime_record_fails_closed
unit_stop_malformed_record_fails_closed
unit_stop_validates_before_signal
unit_lock_requires_complete_metadata
unit_stop_surfaces_afk_removal_failure
unit_stop_confirms_daemon_exit
unit_refresh_validates_record
unit_clear_failure_aborts_entry
unit_confirmed_absence_succeeds
unit_incomplete_restore_retains_backup
unit_flag_write_failure_aborts

[ "$FAILED" -eq 0 ] || exit 1
