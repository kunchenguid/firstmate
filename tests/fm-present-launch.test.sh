#!/usr/bin/env bash
# tests/fm-present-launch.test.sh - the script-owned, backend-aware present-mode
# daemon launch (bin/fm-present-launch.sh), the Codex/traex durable-wake fallback
# (issue #352). Present mode is the sibling of away mode's launcher: it lands the
# daemon in a NON-VISIBLE separate terminal (a herdr dedicated workspace, a
# detached tmux session), never a split of the captain's pane, but it never
# touches state/.afk and keeps no escalation buffer. Two layers:
#
#   UNIT (always run, no backend): exact-id teardown, fail-closed on a malformed
#   record, atomic record publication, and rollback when create/readiness fails.
#
#   E2E TOPOLOGY (tmux, skipped when absent): start lands the daemon in a
#   separate detached session, leaving the captain window untouched, and stop
#   kills it by exact id. A harmless sleeper replaces the real daemon
#   (FM_PRESENT_LAUNCH_ENTRY) so the test observes only the terminal lifecycle.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="$ROOT/bin/fm-present-launch.sh"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

SLEEPER=$(mktemp "${TMPDIR:-/tmp}/fm-present-sleeper.XXXXXX")
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
# UNIT: reconcile a leaked terminal closes it by exact id and drops the record.
# ---------------------------------------------------------------------------
unit_reconcile_confirmed_absence_succeeds() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-present-absent.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\texact-session\t\n' > "$st/state/.present-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 1; }
    fm_present_close_terminal() { return 1; }
    fm_present_terminal_absent() { return 0; }
    fm_present_reconcile
  ' _ "$LAUNCH" && [ ! -e "$st/state/.present-daemon-terminal" ]; then
    pass "reconcile: confirmed absence removes the stale record even if the close command errored"
  else
    fail "reconcile: confirmed absence did not drop the stale record"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT: an unconfirmed teardown preserves the exact reconciliation id.
# ---------------------------------------------------------------------------
unit_reconcile_close_failure_preserves_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-present-close-fail.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\texact-session\t\n' > "$st/state/.present-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 1; }
    fm_present_close_terminal() { return 1; }
    fm_present_terminal_absent() { return 1; }
    ! fm_present_reconcile
  ' _ "$LAUNCH" && [ -e "$st/state/.present-daemon-terminal" ]; then
    pass "reconcile: unconfirmed teardown preserves the exact terminal record"
  else
    fail "reconcile: unconfirmed teardown discarded the exact terminal record"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT: a malformed record fails closed - reconcile refuses to act on a partial
# id and preserves the record for a human.
# ---------------------------------------------------------------------------
unit_reconcile_malformed_record_fails_closed() {
  local st acted
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-present-malformed.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.present-daemon-terminal"
  acted="$st/acted"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" ACTED="$acted" bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 1; }
    fm_present_close_terminal() { : > "$ACTED"; }
    ! fm_present_reconcile
  ' _ "$LAUNCH" && [ ! -e "$acted" ] && [ -e "$st/state/.present-daemon-terminal" ]; then
    pass "reconcile: malformed record fails closed without acting on a partial id"
  else
    fail "reconcile: malformed record was acted on or discarded"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT: record publication is atomic - a failed rename preserves the prior
# record and leaves no pending temp file behind.
# ---------------------------------------------------------------------------
unit_record_publication_atomic() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-present-record-atomic.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\told-session\t\n' > "$st/state/.present-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    mv() { return 1; }
    ! fm_present_record_write tmux new-session ""
  ' _ "$LAUNCH" \
    && [ "$(cat "$st/state/.present-daemon-terminal")" = $'tmux\told-session\t' ] \
    && ! find "$st/state" -name '.present-daemon-terminal.pending.*' -print -quit | grep -q .; then
    pass "record publication: failed atomic rename preserves the prior record and leaves no temp file"
  else
    fail "record publication: failed write truncated the prior record or leaked a temp file"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT: readiness failure rolls back the created terminal and its record.
# ---------------------------------------------------------------------------
unit_tmux_readiness_failure_rolls_back() {
  local st closed
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-present-not-ready.XXXXXX")
  closed="$st/closed"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" CLOSED="$closed" bash -c '
    . "$1"
    tmux() { [ "$1" != new-session ] || return 0; return 0; }
    fm_present_wait_ready() { return 1; }
    fm_present_close_terminal() { printf "%s:%s" "$1" "$2" > "$CLOSED"; }
    fm_present_terminal_absent() { [ -e "$CLOSED" ]; }
    ! fm_present_create_tmux captain:0 tmux
  ' _ "$LAUNCH" \
    && [ ! -e "$st/state/.present-daemon-terminal" ] \
    && [ "$(cut -d: -f1 "$closed" 2>/dev/null || true)" = tmux ]; then
    pass "readiness failure: created tmux terminal and record roll back by exact id"
  else
    fail "readiness failure: terminal or record survived a non-ready daemon"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT: the tmux exact target is recorded BEFORE creation and removed on a
# creation failure (never a leaked untracked session).
# ---------------------------------------------------------------------------
unit_tmux_planned_record_and_rollback() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-present-tmux-plan.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    tmux() {
      if [ "$1" = new-session ]; then
        [ -s "$FM_PRESENT_RECORD" ] || return 9   # record must exist before create
        printf "%s" "$4" > "$FM_HOME/created-name"
        return 1                                   # then fail the create
      fi
      [ "$1" != kill-session ] || : > "$FM_HOME/killed"
      return 1
    }
    ! fm_present_create_tmux captain:0 tmux
  ' _ "$LAUNCH" \
    && [ -s "$st/created-name" ] \
    && [ ! -e "$st/state/.present-daemon-terminal" ] \
    && [ ! -e "$st/killed" ]; then
    pass "tmux launch: exact target recorded before creation and record removed on failure"
  else
    fail "tmux launch: creation began before record publication or leaked the record"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT: herdr run failure preserves the unconfirmed exact reconciliation id.
# ---------------------------------------------------------------------------
unit_herdr_run_failure_preserves_unconfirmed_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-present-herdr-run-fail.XXXXXX")
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_PRESENT_LAUNCH_ENTRY=/bin/true bash -c '
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
    ! fm_present_create_herdr lab:captain herdr
  ' _ "$LAUNCH"
  if [ "$(cut -f2 "$st/state/.present-daemon-terminal" 2>/dev/null || true)" = "lab:pane-exact" ]; then
    pass "herdr run failure: unconfirmed exact id remains reconcilable"
  else
    fail "herdr run failure: unconfirmed exact id was discarded"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT: stop with a malformed record fails closed - it refuses to signal any
# daemon or touch state.
# ---------------------------------------------------------------------------
unit_stop_malformed_record_fails_closed() {
  local st sleeper_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-present-stop-malformed.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.present-daemon-terminal"
  sleep 30 & sleeper_pid=$!
  mkdir -p "$st/state/.supervise-present.lock"
  printf '%s' "$sleeper_pid" > "$st/state/.supervise-present.lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$sleeper_pid" > "$st/state/.supervise-present.lock/pid-identity" )
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1 || true
  if kill -0 "$sleeper_pid" 2>/dev/null && [ -e "$st/state/.present-daemon-terminal" ]; then
    pass "stop: malformed record signals no daemon and preserves the record"
  else
    fail "stop: malformed record signaled a daemon or discarded the record"
  fi
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT: an unsupported captain backend refuses to launch and leaves no state.
# ---------------------------------------------------------------------------
unit_unsupported_backend_refuses() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-present-unsupported.XXXXXX")
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=unsupported "$LAUNCH" start >/dev/null 2>&1; then
    fail "unsupported backend: start unexpectedly succeeded"
  elif [ ! -e "$st/state/.present-daemon-terminal" ] \
    && [ ! -e "$st/state/.supervise-present.lock" ]; then
    pass "unsupported backend: start refuses and leaves no terminal record or lock"
  else
    fail "unsupported backend: start left a terminal record or lock"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT: an independent-pty primary (no injectable supervisor pane resolves)
# degrades HONESTLY - it does not silently fail and does not inject into an
# unverified pane. It reports that durable notifications remain while automatic
# injection is unavailable, points at the checkpoint fallback, returns the
# distinct degrade code 3, and leaves no terminal record or lock. This is the
# Codex-on-an-independent-pty case from the 151 e2e run.
unit_independent_pty_degrades_honestly() {
  local st out status
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-present-independent-pty.XXXXXX")
  status=0
  # No FM_SUPERVISOR_TARGET/BACKEND and no tmux/herdr ambient markers, so
  # discover_supervisor_target fails: exactly an independent pty.
  out=$(env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
    -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
    FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" start 2>&1) || status=$?
  if [ "$status" -ne 3 ]; then
    fail "independent pty: expected degrade code 3, got $status (out: $out)"
  elif ! printf '%s' "$out" | grep -q 'durable notifications available'; then
    fail "independent pty: degrade did not state durable notifications remain (out: $out)"
  elif ! printf '%s' "$out" | grep -q 'automatic turn injection unavailable'; then
    fail "independent pty: degrade did not state injection is unavailable (out: $out)"
  elif ! printf '%s' "$out" | grep -q 'foreground checkpoint fallback'; then
    fail "independent pty: degrade did not point at the checkpoint fallback (out: $out)"
  elif [ -e "$st/state/.present-daemon-terminal" ] || [ -e "$st/state/.supervise-present.lock" ]; then
    fail "independent pty: degrade left a terminal record or lock (no unverified injection target must be armed)"
  else
    pass "independent pty: honest degrade (durable remain, injection unavailable, code 3), no state armed"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# E2E tmux: topology invariant - the daemon lands in a separate detached
# session, the captain window is untouched, and stop kills it by exact id.
# ---------------------------------------------------------------------------
e2e_tmux() {
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found (tmux e2e)"; return 0; }
  local cap_session home_tmp cap_pane before during after rec
  cap_session="fm-present-launch-cap-$$"
  home_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-present-tmux-home.XXXXXX")
  tmux new-session -d -s "$cap_session" 2>/dev/null || { fail "tmux e2e: could not create captain session"; rm -rf "$home_tmp"; return 0; }
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $cap_session"
  cap_pane=$(tmux display-message -p -t "$cap_session" '#{pane_id}')
  before=$(tmux list-panes -t "$cap_session" | wc -l | tr -d ' ')

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$cap_pane" FM_SUPERVISOR_BACKEND=tmux FM_PRESENT_LAUNCH_ENTRY="$SLEEPER" \
    "$LAUNCH" start >/dev/null 2>&1

  during=$(tmux list-panes -t "$cap_session" | wc -l | tr -d ' ')
  rec=$(cut -f2 "$home_tmp/state/.present-daemon-terminal" 2>/dev/null || true)
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $rec"
  if [ "$before" = "$during" ]; then pass "tmux e2e: captain window pane count unchanged after start (no split-window)"; else fail "tmux e2e: captain window pane count changed ($before -> $during)"; fi
  if [ -n "$rec" ] && tmux has-session -t "$rec" 2>/dev/null && [ "$rec" != "$cap_session" ]; then pass "tmux e2e: present daemon launched in a separate detached session"; else fail "tmux e2e: no separate present daemon session ($rec)"; fi

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$cap_pane" FM_SUPERVISOR_BACKEND=tmux "$LAUNCH" stop >/dev/null 2>&1

  after=$(tmux list-panes -t "$cap_session" | wc -l | tr -d ' ')
  if [ "$after" = "$before" ]; then pass "tmux e2e: captain window pane count unchanged after stop"; else fail "tmux e2e: captain window changed ($before -> $after)"; fi
  if [ -n "$rec" ] && ! tmux has-session -t "$rec" 2>/dev/null; then pass "tmux e2e: present daemon session killed by exact id on stop"; else fail "tmux e2e: present daemon session leaked ($rec)"; fi
  if [ ! -e "$home_tmp/state/.present-daemon-terminal" ]; then pass "tmux e2e: terminal record cleared on stop"; else fail "tmux e2e: terminal record not cleared"; fi

  tmux kill-session -t "$cap_session" 2>/dev/null || true
  rm -rf "$home_tmp" 2>/dev/null || true
}

unit_reconcile_confirmed_absence_succeeds
unit_reconcile_close_failure_preserves_record
unit_reconcile_malformed_record_fails_closed
unit_record_publication_atomic
unit_tmux_readiness_failure_rolls_back
unit_tmux_planned_record_and_rollback
unit_herdr_run_failure_preserves_unconfirmed_record
unit_stop_malformed_record_fails_closed
unit_unsupported_backend_refuses
unit_independent_pty_degrades_honestly
e2e_tmux

[ "$FAILED" -eq 0 ] || exit 1
