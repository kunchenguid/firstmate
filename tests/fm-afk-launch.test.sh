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

unit_relative_paths_are_absolute_before_daemon_launch() {
  local root home state out status linked_home
  root=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-relative-home.XXXXXX")
  mkdir -p "$root/home/state" "$root/cdpath/home/state"
  home=$(cd "$root/home" && pwd -P)
  state="$home/state"
  out=$(
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_STATE_OVERRIDE=home/state \
      bash -c '. "$1"; printf "%s\n%s\n" "$FM_HOME" "$FM_AFK_LAUNCH_STATE"' _ "$LAUNCH"
  )
  if [ "$out" = "$home"$'\n'"$state" ]; then
    pass "launcher paths: relative home and state ignore CDPATH before daemon command construction"
  else
    fail "launcher paths: relative home or state remained cwd-dependent ($out)"
  fi
  linked_home="$root/home-link"
  ln -s "$root/home" "$linked_home"
  out=$(FM_HOME="$linked_home" FM_STATE_OVERRIDE="$linked_home/state" \
    bash -c '. "$1"; printf "%s\n%s\n" "$FM_HOME" "$FM_AFK_LAUNCH_STATE"' _ "$LAUNCH")
  if [ "$out" = "$linked_home"$'\n'"$linked_home/state" ]; then
    pass "launcher paths: absolute symlink spellings are preserved"
  else
    fail "launcher paths: absolute symlink spelling changed ($out)"
  fi
  out=$(
    cd "$root" || exit 1
    FM_HOME=missing-home "$LAUNCH" help 2>&1
  )
  status=$?
  if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -F "FM_HOME directory cannot be resolved: missing-home" >/dev/null; then
    pass "launcher paths: unresolved relative FM_HOME fails loudly"
  else
    fail "launcher paths: unresolved relative FM_HOME did not name the bad input ($out)"
  fi
  out=$(
    cd "$root" || exit 1
    FM_HOME=home FM_STATE_OVERRIDE=missing-state "$LAUNCH" help 2>&1
  )
  status=$?
  if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -F "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" >/dev/null; then
    pass "launcher paths: unresolved relative FM_STATE_OVERRIDE fails loudly"
  else
    fail "launcher paths: unresolved relative FM_STATE_OVERRIDE did not name the bad input ($out)"
  fi
  rm -rf "$root"
}

# ---------------------------------------------------------------------------
# UNIT 2: a FRESH entry clears; a REFRESH (daemon already alive) preserves the
# current session's buffered escalations.
# ---------------------------------------------------------------------------
unit_fresh_vs_refresh() {
  local st sleep_pid lock out
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
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_STATE_PREPARED=0 "$START" 2>&1)
  if [ -e "$st/state/.subsuper-escalations" ] \
    && [ -e "$st/state/.subsuper-inject-wedged" ] \
    && printf '%s\n' "$out" | grep -F 'daemon already running' >/dev/null; then
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
  # shellcheck disable=SC2031 # The background daemon writes this shared file; no shell variable is reassigned.
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

unit_restart_records_unexpected_daemon_death() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-restart-after-death.XXXXXX")
  mkdir -p "$st/state"
  date '+%s' > "$st/state/.afk"
  printf 'current-session escalation\n' > "$st/state/.subsuper-escalations"

  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=unsupported "$LAUNCH" start >/dev/null 2>&1; then
    fail "restart after death: unsupported replacement unexpectedly succeeded"
  elif [ -e "$st/state/.afk-daemon-died-unexpectedly" ] \
    && [ -e "$st/state/.afk" ] \
    && [ "$(cat "$st/state/.subsuper-escalations")" = 'current-session escalation' ]; then
    pass "restart after death: unsupervised interval and session evidence survive replacement rollback"
  else
    fail "restart after death: replacement attempt lost death or session evidence"
  fi
  rm -rf "$st"
}

unit_start_waits_for_recorded_terminal_readiness() {
  local st fake_bin daemon_pid daemon_identity publisher status
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-start-readiness.XXXXXX")
  fake_bin="$st/bin"
  mkdir -p "$st/state" "$fake_bin"
  : > "$st/state/.afk"
  printf 'tmux\tstarting-session\towned\n' > "$st/state/.afk-daemon-terminal"
  # shellcheck disable=SC2016 # The generated fixture expands these variables when executed.
  printf '#!/usr/bin/env bash\n[ "$1" = has-session ] && { : > "$FM_HOME/terminal-probed"; exit 0; }\nexit 1\n' > "$fake_bin/tmux"
  chmod +x "$fake_bin/tmux"

  sleep 30 &
  daemon_pid=$!
  daemon_identity=$( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" 2>/dev/null )
  (
    sleep 0.15
    mkdir -p "$st/state/.supervise-daemon.lock"
    printf '%s' "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid"
    printf '%s' "$daemon_identity" > "$st/state/.supervise-daemon.lock/pid-identity"
  ) &
  publisher=$!

  PATH="$fake_bin:$PATH" FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    FM_SUPERVISOR_TARGET=unused FM_SUPERVISOR_BACKEND=unsupported \
    "$LAUNCH" start >/dev/null 2>&1
  status=$?
  wait "$publisher" 2>/dev/null || true
  if [ "$status" -eq 0 ] \
    && [ -e "$st/terminal-probed" ] \
    && [ ! -e "$st/state/.afk-daemon-died-unexpectedly" ] \
    && [ -e "$st/state/.afk" ] \
    && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "start readiness: live recorded terminal can publish its daemon lock before death is declared"
  else
    fail "start readiness: in-progress detached launch was reported as an unexpected death"
  fi
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_refresh_revalidates_daemon_before_success() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-refresh-revalidate.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=unsupported bash -c '
      . "$1"
      sleep 30 &
      daemon_pid=$!
      mkdir -p "$FM_AFK_LAUNCH_STATE/.supervise-daemon.lock"
      printf "%s" "$daemon_pid" > "$FM_AFK_LAUNCH_STATE/.supervise-daemon.lock/pid"
      fm_pid_identity "$daemon_pid" > "$FM_AFK_LAUNCH_STATE/.supervise-daemon.lock/pid-identity"
      printf "tmux\trefresh-session\towned\n" > "$FM_AFK_LAUNCH_RECORD"
      fm_backend_source() { return 0; }
      tmux() {
        case "$1" in
          has-session)
            if fm_pid_alive "$daemon_pid"; then
              return 0
            fi
            printf "%s" "can'"'"'t find session: refresh-session" >&2
            return 1
            ;;
          kill-session) return 0 ;;
        esac
        return 1
      }
      fm_afk_launch_flag_write() {
        fm_afk_flag_write "$FM_AFK_LAUNCH_STATE" || return 1
        command kill -TERM "$daemon_pid" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
      }
      ! fm_afk_launch_start
    ' _ "$LAUNCH" \
    && [ -e "$st/state/.afk-daemon-died-unexpectedly" ] \
    && [ -e "$st/state/.afk" ]; then
    pass "refresh revalidation: daemon death continues through durable recovery instead of reporting success"
  else
    fail "refresh revalidation: daemon death during refresh was silently accepted"
  fi
  rm -rf "$st"
}

unit_stop_confirms_recorded_terminal_absence_before_death() {
  local st fake_bin status
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-readiness.XXXXXX")
  fake_bin="$st/bin"
  mkdir -p "$st/state" "$fake_bin"
  : > "$st/state/.afk"
  printf 'tmux\tabsent-session\towned\n' > "$st/state/.afk-daemon-terminal"
  # shellcheck disable=SC2016 # The generated fixture expands these variables when executed.
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "$1" = has-session ]; then' \
    '  if [ ! -e "$FM_HOME/first-terminal-probe" ]; then' \
    '    : > "$FM_HOME/first-terminal-probe"' \
    '    [ ! -e "$FM_HOME/state/.afk-daemon-died-unexpectedly" ] || : > "$FM_HOME/death-before-first-probe"' \
    '  fi' \
    '  printf "%s" "can'"'"'t find session: absent-session" >&2' \
    '  exit 1' \
    'fi' \
    'exit 1' > "$fake_bin/tmux"
  chmod +x "$fake_bin/tmux"

  PATH="$fake_bin:$PATH" FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    "$LAUNCH" stop >/dev/null 2>&1
  status=$?
  if [ "$status" -eq 0 ] \
    && [ -e "$st/first-terminal-probe" ] \
    && [ ! -e "$st/death-before-first-probe" ] \
    && [ -e "$st/state/.afk-daemon-died-unexpectedly" ]; then
    pass "stop readiness: recorded terminal absence is confirmed before death is declared"
  else
    fail "stop readiness: death was declared without first excluding terminal startup"
  fi
  rm -rf "$st"
}

unit_wait_sources_herdr_before_terminal_probe() {
  local st sourced slept
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-wait-source.XXXXXX")
  sourced="$st/sourced"
  slept="$st/slept"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" SOURCED="$sourced" SLEPT="$slept" bash -c '
      . "$1"
      daemon_lock_held_by_live_daemon() { return 1; }
      fm_backend_source() {
        [ "$1" = herdr ] || return 1
        : > "$SOURCED"
        fm_backend_herdr_cli() {
          printf "%s" "{\"error\":{\"code\":\"pane_not_found\"}}"
          return 1
        }
      }
      sleep() { : > "$SLEPT"; }
      ! fm_afk_launch_wait_recorded_daemon herdr lab:pane
    ' _ "$LAUNCH" \
    && [ -e "$sourced" ] \
    && [ ! -e "$slept" ]; then
    pass "Herdr readiness: adapter loads before confirming recorded terminal absence"
  else
    fail "Herdr readiness: absent terminal was probed before its adapter loaded"
  fi
  rm -rf "$st"
}

unit_stop_classifies_death_during_failed_signal() {
  local st live_st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-signal-race.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
      . "$1"
      sleep 30 &
      daemon_pid=$!
      mkdir -p "$FM_AFK_LAUNCH_STATE/.supervise-daemon.lock"
      printf "%s" "$daemon_pid" > "$FM_AFK_LAUNCH_STATE/.supervise-daemon.lock/pid"
      fm_pid_identity "$daemon_pid" > "$FM_AFK_LAUNCH_STATE/.supervise-daemon.lock/pid-identity"
      kill() {
        if [ "$1" = -TERM ]; then
          command kill -TERM "$2" 2>/dev/null || true
          wait "$2" 2>/dev/null || true
          return 1
        fi
        command kill "$@"
      }
      fm_afk_launch_stop
    ' _ "$LAUNCH" \
    && [ -e "$st/state/.afk-daemon-died-unexpectedly" ] \
    && [ ! -e "$st/state/.afk" ] \
    && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop signal race: disappeared daemon is classified before lifecycle cleanup"
  else
    fail "stop signal race: failed signal lost the concurrent daemon death"
  fi
  rm -rf "$st"

  live_st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-signal-live.XXXXXX")
  mkdir -p "$live_st/state"
  : > "$live_st/state/.afk"
  printf 'none\t-\tnative\n' > "$live_st/state/.afk-daemon-terminal"
  if FM_HOME="$live_st" FM_STATE_OVERRIDE="$live_st/state" bash -c '
      . "$1"
      sleep 30 &
      daemon_pid=$!
      mkdir -p "$FM_AFK_LAUNCH_STATE/.supervise-daemon.lock"
      printf "%s" "$daemon_pid" > "$FM_AFK_LAUNCH_STATE/.supervise-daemon.lock/pid"
      fm_pid_identity "$daemon_pid" > "$FM_AFK_LAUNCH_STATE/.supervise-daemon.lock/pid-identity"
      kill() {
        [ "$1" != -TERM ] || return 1
        command kill "$@"
      }
      ! fm_afk_launch_stop
      alive=0
      command kill -0 "$daemon_pid" 2>/dev/null && alive=1
      command kill -TERM "$daemon_pid" 2>/dev/null || true
      wait "$daemon_pid" 2>/dev/null || true
      [ "$alive" -eq 1 ]
    ' _ "$LAUNCH" \
    && [ -e "$live_st/state/.afk" ] \
    && [ -e "$live_st/state/.afk-daemon-terminal" ] \
    && [ ! -e "$live_st/state/.afk-daemon-died-unexpectedly" ]; then
    pass "stop signal failure: still-live daemon preserves lifecycle state"
  else
    fail "stop signal failure: live daemon was misclassified or lifecycle state was cleared"
  fi
  rm -rf "$live_st"
}

unit_unexpected_death_record_failure_preserves_away_state() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-death-record-failure.XXXXXX")
  mkdir -p "$st/state/.afk-daemon-died-unexpectedly"
  date '+%s' > "$st/state/.afk"

  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1; then
    fail "death record failure: stop unexpectedly succeeded"
  elif [ -e "$st/state/.afk" ]; then
    pass "death record failure: away state remains retryable until evidence is durable"
  else
    fail "death record failure: stop cleared away state without durable death evidence"
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
      # shellcheck disable=SC2031 # The subshell writes the path value; it does not reassign the variable.
      : > "$marker"
      sleep 0.15
      rm -rf "$st/state/.afk-launch.lock"
    fi
  ) &
  initializer=$!
  # shellcheck disable=SC2031 # The initializer communicates through this shared file path.
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
  # Signal only once the lifecycle actually holds its lock. Killing before the
  # lock exists tests nothing, and on a loaded machine it used to race: the
  # lock could be created just after the kill and outlive the process.
  local locked=0 _
  for _ in $(seq 1 100); do
    if [ -d "$st/state/.afk-launch.lock" ]; then locked=1; break; fi
    sleep 0.05
  done
  [ "$locked" = 1 ] || fail "launcher signal: lifecycle never acquired its lock to interrupt"
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  # The signal handler releases the lock as it exits; give that removal a
  # bounded settle rather than sampling the instant `wait` returns.
  for _ in $(seq 1 100); do
    [ -e "$st/state/.afk-launch.lock" ] || break
    sleep 0.05
  done
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

unit_native_start_refused() {
  local st out status
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native.XXXXXX")
  mkdir -p "$st/state"
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" start-native 2>&1)
  status=$?
  if [ "$status" -ne 0 ] \
    && [ ! -e "$st/state/.afk" ] \
    && [ ! -e "$st/state/.afk-daemon-terminal" ] \
    && printf '%s' "$out" | grep -q 'bin/fm-afk-launch.sh start'; then
    pass "native start: start-native refuses, names the verified path, and writes no state"
  else
    fail "native start: start-native did not refuse cleanly (status=$status; output: $out)"
  fi
  rm -rf "$st"
}

unit_native_entry_refused() {
  local st out status sentinel
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native-entry.XXXXXX")
  mkdir -p "$st/state"
  for sentinel in unset 1 invalid; do
    if [ "$sentinel" = unset ]; then
      out=$(env -u FM_AFK_STATE_PREPARED FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
        FM_SUPERVISOR_BACKEND=unsupported "$START" 2>&1)
    else
      out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_STATE_PREPARED="$sentinel" \
        FM_SUPERVISOR_BACKEND=unsupported "$START" 2>&1)
    fi
    status=$?
    if [ "$status" -ne 0 ] \
      && [ ! -e "$st/state/.afk" ] \
      && printf '%s' "$out" | grep -q 'bin/fm-afk-launch.sh start'; then
      pass "native entry: sentinel '$sentinel' refuses and names the verified path"
    else
      fail "native entry: sentinel '$sentinel' did not refuse cleanly (status=$status; output: $out)"
      rm -f "$st/state/.afk"
    fi
  done
  rm -rf "$st"
}

unit_detached_entries_clear_native_sentinel() {
  local st entry
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-detached-env.XXXXXX")
  mkdir -p "$st/state"
  entry="$st/entry.sh"
  # shellcheck disable=SC2016 # The generated fixture expands these variables when executed.
  printf '#!/usr/bin/env bash\nprintf "%%s" "${FM_AFK_STATE_PREPARED:-unset}" > "$FM_HOME/prepared-value"\n' > "$entry"
  chmod +x "$entry"

  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_STATE_PREPARED=1 FM_AFK_LAUNCH_ENTRY="$entry" bash -c '
    . "$1"
    tmux() {
      case "$1" in
        new-session) bash -c "$5" ;;
        has-session) return 0 ;;
        *) return 0 ;;
      esac
    }
    fm_afk_launch_create_tmux captain:0 tmux
  ' _ "$LAUNCH"
  if [ "$(cat "$st/prepared-value" 2>/dev/null || true)" = 0 ]; then
    pass "tmux launch: detached entry clears an inherited native-path sentinel"
  else
    fail "tmux launch: detached entry inherited FM_AFK_STATE_PREPARED=1"
  fi

  rm -f "$st/prepared-value" "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_STATE_PREPARED=1 FM_AFK_LAUNCH_ENTRY="$entry" bash -c '
    . "$1"
    fm_backend_source() { return 0; }
    fm_backend_herdr_server_ensure() { return 0; }
    fm_backend_herdr_cli() {
      if [ "$2 $3" = "workspace create" ]; then
        printf "%s\n" "{\"result\":{\"workspace\":{\"workspace_id\":\"ws\"},\"root_pane\":{\"pane_id\":\"pane\"}}}"
      elif [ "$2 $3" = "pane run" ]; then
        bash -c "$5"
      fi
    }
    fm_afk_launch_create_herdr captain:0 herdr
  ' _ "$LAUNCH"
  if [ "$(cat "$st/prepared-value" 2>/dev/null || true)" = 0 ]; then
    pass "Herdr launch: detached entry clears an inherited native-path sentinel"
  else
    fail "Herdr launch: detached entry inherited FM_AFK_STATE_PREPARED=1"
  fi
  rm -rf "$st"
}

# The reproduced false positive: a bare basename match on the daemon script
# ("*fm-supervise-daemon.sh*", equivalent to `pgrep -f fm-supervise-daemon`)
# says "alive" for ANY home's daemon process, not just this home's. A fake
# daemon under a DIFFERENT bin/ directory (a stand-in for a sibling
# secondmate's own checkout) is alive and matches that bare pattern, but must
# not satisfy this home's liveness check when its lock has no recorded
# identity (the fallback path in daemon_pid_matches).
unit_daemon_liveness_is_home_scoped() {
  local st other_bin other_daemon other_pid old_style_verdict
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-home-scope.XXXXXX")
  other_bin=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-other-home-bin.XXXXXX")
  mkdir -p "$st/state" "$other_bin"
  other_daemon="$other_bin/fm-supervise-daemon.sh"
  printf '#!/usr/bin/env bash\nwhile :; do sleep 0.2; done\n' > "$other_daemon"
  chmod +x "$other_daemon"
  "$other_daemon" &
  other_pid=$!
  mkdir -p "$st/state/.supervise-daemon.lock"
  printf '%s' "$other_pid" > "$st/state/.supervise-daemon.lock/pid"
  # No pid-identity file: this home's lock never recorded one, forcing the
  # command-line fallback daemon_pid_matches uses.
  old_style_verdict=0
  case "$(ps -p "$other_pid" -o command= 2>/dev/null || true)" in
    *"fm-supervise-daemon.sh"*) old_style_verdict=1 ;;
  esac
  if [ "$old_style_verdict" -eq 1 ] && FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    ! daemon_lock_held_by_live_daemon
  ' _ "$START"; then
    pass "daemon liveness: home-scoped check rejects a live same-basename process from another home's bin/"
  else
    fail "daemon liveness: a foreign home's same-named daemon satisfied this home's liveness check"
  fi
  kill "$other_pid" 2>/dev/null || true
  wait "$other_pid" 2>/dev/null || true
  rm -rf "$st" "$other_bin"
}

# fm_afk_launch_stop must not treat "the daemon already exited on its own" the
# same as "I successfully stopped a running daemon" - the away-mode flag was
# active with nobody supervising it, and that must stay visible even though
# nothing is left alive to report it directly (the reproduced defect this
# brief fixes: a native-launched daemon SIGTERM'd by its own harness leaves
# exactly this state).
unit_stop_records_unexpected_daemon_death() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-unexpected-death.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if [ -e "$st/state/.afk-daemon-died-unexpectedly" ] && [ ! -e "$st/state/.afk" ]; then
    pass "stop: away mode active with no lock at all is recorded, not silently accepted"
  else
    fail "stop: away mode active with no lock at all left no durable record"
  fi
  rm -rf "$st"
}

# Stronger than the fixture above: a REAL daemon-shaped process is registered
# in this home's lock exactly like fm-supervise-daemon.sh registers itself,
# then killed by SIGTERM entirely OUT OF BAND - never through
# bin/fm-afk-launch.sh stop - with no trap of its own, the same default
# disposition a harness's own background-task teardown produces (the
# reproduced 2026-08-23 failure this brief fixes). Only after it has actually
# exited does this call stop, the same order the captain's return produces
# hours later. This proves the signal fires for a daemon that truly died, not
# only for a fixture where no lock ever existed.
unit_stop_records_death_of_a_really_killed_daemon() {
  local st lock daemon_pid registered
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-real-death.XXXXXX")
  mkdir -p "$st/state"
  date '+%s' > "$st/state/.afk"
  bash -c 'while :; do sleep 0.2; done' &
  daemon_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$daemon_pid" > "$lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$lock/pid-identity" 2>/dev/null ) || true
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '. "$1"; daemon_lock_held_by_live_daemon' _ "$START"; then
    registered=1
  else
    registered=0
  fi
  kill -TERM "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  if [ "$registered" -ne 1 ]; then
    fail "real death setup: the fixture daemon never registered as this home's live daemon (test proves nothing)"
  elif FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '. "$1"; daemon_lock_held_by_live_daemon' _ "$START"; then
    fail "real death setup: the fixture daemon is somehow still alive after SIGTERM+wait (test proves nothing)"
  elif FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1 \
    && [ -e "$st/state/.afk-daemon-died-unexpectedly" ] && [ ! -e "$st/state/.afk" ]; then
    pass "stop: a daemon truly killed out-of-band (SIGTERM, no fm-afk-launch.sh involvement) is recorded on the next stop"
  else
    fail "stop: a daemon truly killed out-of-band left no durable record on the next stop"
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
  local st out status
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-malformed.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop 2>&1)
  status=$?
  if [ "$status" -ne 0 ] \
    && [ -e "$st/state/.afk" ] \
    && [ -e "$st/state/.afk-daemon-terminal" ] \
    && [ -e "$st/state/.afk-daemon-died-unexpectedly" ] \
    && printf '%s\n' "$out" | grep -F 'malformed daemon terminal record' >/dev/null; then
    pass "stop: malformed terminal metadata preserves state and cannot suppress independent death evidence"
  else
    fail "stop: malformed terminal metadata suppressed death evidence or changed protected state (status=$status; output: $out)"
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
  if kill -0 "$sleeper_pid" 2>/dev/null \
    && [ -e "$st/state/.afk" ] \
    && [ ! -e "$st/state/.afk-daemon-died-unexpectedly" ]; then
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
      ! fm_afk_launch_start
    ' _ "$LAUNCH" && [ ! -e "$st/state/.afk" ]; then
    pass "refresh record: malformed terminal identity fails closed"
  else
    fail "refresh record: malformed terminal identity was accepted"
  fi
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_refresh_requires_supported_live_terminal() {
  local mode st daemon_pid lock out status fake_bin
  for mode in none absent; do
    st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-refresh-unsupported.XXXXXX")
    mkdir -p "$st/state"
    : > "$st/state/.afk"
    if [ "$mode" = none ]; then
      printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
    fi
    sleep 30 &
    daemon_pid=$!
    lock="$st/state/.supervise-daemon.lock"
    mkdir -p "$lock"
    printf '%s' "$daemon_pid" > "$lock/pid"
    ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$lock/pid-identity" )
    out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" start 2>&1)
    status=$?
    # shellcheck disable=SC2031 # The loop variable remains in this shell; only the launch is substituted.
    if [ "$status" -ne 0 ] \
      && kill -0 "$daemon_pid" 2>/dev/null \
      && [ -e "$st/state/.afk" ] \
      && [ ! -e "$st/state/.afk-daemon-died-unexpectedly" ] \
      && printf '%s\n' "$out" | grep -F "bin/fm-afk-launch.sh stop" >/dev/null \
      && printf '%s\n' "$out" | grep -F "bin/fm-afk-launch.sh start" >/dev/null; then
      pass "refresh terminal: live daemon with '$mode' ownership is rejected without false death evidence"
    else
      fail "refresh terminal: live daemon with '$mode' ownership was accepted or misclassified"
    fi
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    rm -rf "$st"
  done

  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-refresh-supported.XXXXXX")
  fake_bin="$st/bin"
  mkdir -p "$st/state" "$fake_bin"
  printf 'tmux\tsupported-session\towned\n' > "$st/state/.afk-daemon-terminal"
  # shellcheck disable=SC2016 # The generated fixture expands these variables when executed.
  printf '#!/usr/bin/env bash\n[ "$1" = has-session ] && exit 0\n[ "$1" != new-session ] || : > "$FM_HOME/unexpected-new-terminal"\nexit 1\n' > "$fake_bin/tmux"
  chmod +x "$fake_bin/tmux"
  sleep 30 &
  daemon_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$daemon_pid" > "$lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$lock/pid-identity" )
  if PATH="$fake_bin:$PATH" FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" start >/dev/null 2>&1 \
    && [ -e "$st/state/.afk" ] \
    && [ -e "$st/state/.afk-daemon-terminal" ] \
    && [ ! -e "$st/state/.afk-daemon-died-unexpectedly" ] \
    && [ ! -e "$st/unexpected-new-terminal" ]; then
    pass "refresh terminal: verified live tmux ownership refreshes without replacement"
  else
    fail "refresh terminal: verified live tmux ownership did not refresh safely"
  fi
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
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
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=tmux bash -c '
    . "$1"
    fm_afk_launch_flag_write() { return 1; }
    ! fm_afk_launch_start
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
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"

  local SESSION home_tmp cap_ws cap_tab cap_pane target
  local before during after ws_before ws_during ws_after out dtgt dtab
  SESSION="fm-lab-afk-launch-e2e-$$"
  export HERDR_SESSION="$SESSION"
  home_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e-home.XXXXXX")
  E2E_HERDR_CLEANUP() {
    # shellcheck disable=SC2031 # Cleanup reads the caller's resolved target; it does not reassign it.
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

unit_clear_stale
unit_relative_paths_are_absolute_before_daemon_launch
unit_fresh_vs_refresh
unit_stop_ordering
unit_stop_rejects_reused_pid
unit_failed_start_rolls_back_state
unit_restart_records_unexpected_daemon_death
unit_start_waits_for_recorded_terminal_readiness
unit_refresh_revalidates_daemon_before_success
unit_stop_confirms_recorded_terminal_absence_before_death
unit_wait_sources_herdr_before_terminal_probe
unit_stop_classifies_death_during_failed_signal
unit_unexpected_death_record_failure_preserves_away_state
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
unit_native_start_refused
unit_native_entry_refused
unit_detached_entries_clear_native_sentinel
unit_daemon_liveness_is_home_scoped
unit_stop_records_unexpected_daemon_death
unit_stop_records_death_of_a_really_killed_daemon
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
unit_refresh_requires_supported_live_terminal
unit_confirmed_absence_succeeds
unit_incomplete_restore_retains_backup
unit_flag_write_failure_aborts
e2e_herdr
e2e_tmux

[ "$FAILED" -eq 0 ] || exit 1
