#!/usr/bin/env bash
# Tests for session-lock harness identity fallback when process ancestry is
# unavailable under sandboxed Codex or Cursor-hosted terminals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-session-lock)

make_ps_denied() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf 'ps: operation not permitted\n' >&2
exit 1
SH
  chmod +x "$fakebin/ps"
}

test_codex_marker_detects_harness_without_ps() {
  local dir fakebin got
  dir="$TMP_ROOT/codex-harness"
  fakebin=$(fm_fakebin "$dir")
  make_ps_denied "$fakebin"

  got=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-123 "$ROOT/bin/fm-harness.sh")
  [ "$got" = codex ] || fail "fm-harness marker fallback resolved '$got', expected codex"

  got=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-123 bash -c \
    ". \"\$0/bin/fm-session-lock-lib.sh\"; fm_harness_ancestry_pid" "$ROOT")
  [ "$got" = "codex:thread-123" ] || fail "lock identity fallback resolved '$got', expected codex:thread-123"

  pass "Codex marker detects harness identity without ps ancestry"
}

test_codex_marker_acquires_and_reuses_lock() {
  local dir fakebin home out status
  dir="$TMP_ROOT/codex-lock"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home/state"
  make_ps_denied "$fakebin"

  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-123 FM_HOME="$home" "$ROOT/bin/fm-lock.sh") \
    || fail "fm-lock did not acquire through Codex marker"
  case "$out" in
    *"lock acquired: harness identity codex:thread-123"*) ;;
    *) fail "unexpected lock acquisition output: $out" ;;
  esac
  [ "$(cat "$home/state/.lock")" = "codex:thread-123" ] || fail "lock file did not store the Codex marker identity"

  status=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-123 FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
  case "$status" in
    *"lock: held by current harness marker codex:thread-123"*) ;;
    *) fail "unexpected current marker lock status: $status" ;;
  esac

  pass "Codex marker acquires and reuses the session lock"
}

test_different_marker_lock_fails_closed() {
  local dir fakebin home err
  dir="$TMP_ROOT/codex-different-lock"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home/state"
  make_ps_denied "$fakebin"
  printf 'codex:thread-old\n' > "$home/state/.lock"

  if err=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-new FM_HOME="$home" "$ROOT/bin/fm-lock.sh" 2>&1); then
    fail "fm-lock acquired over a different marker lock"
  fi
  case "$err" in
    *"another firstmate session holds an unverifiable marker lock (codex:thread-old)"*) ;;
    *) fail "unexpected different marker lock error: $err" ;;
  esac
  case "$err" in
    *"reclaim it with: bin/fm-lock.sh reclaim codex:thread-old"*) ;;
    *) fail "marker lock refusal did not print the exact reclaim remediation: $err" ;;
  esac

  pass "Different marker lock fails closed and prints its reclaim remediation"
}

# A marker identity can only be proven live by its own session, so a lock left
# behind by a dead sandboxed session must stay reclaimable or the home wedges
# read-only forever. reclaim is deliberate: the caller names the recorded holder.
test_marker_lock_reclaim_takes_over_confirmed_dead_session() {
  local dir fakebin home out status err
  dir="$TMP_ROOT/codex-reclaim"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home/state"
  make_ps_denied "$fakebin"
  printf 'codex:thread-old\n' > "$home/state/.lock"

  status=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-new FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
  case "$status" in
    *"reclaim it with: bin/fm-lock.sh reclaim codex:thread-old"*) ;;
    *) fail "status did not print the reclaim remediation: $status" ;;
  esac

  if err=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-new FM_HOME="$home" "$ROOT/bin/fm-lock.sh" reclaim codex:thread-other 2>&1); then
    fail "reclaim took a lock it did not name"
  fi
  [ "$(cat "$home/state/.lock")" = "codex:thread-old" ] || fail "a mismatched reclaim rewrote the lock"

  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-new FM_HOME="$home" "$ROOT/bin/fm-lock.sh" reclaim codex:thread-old) \
    || fail "reclaim did not take over a named marker lock"
  case "$out" in
    *"reclaiming marker lock codex:thread-old"*) ;;
    *) fail "unexpected reclaim output: $out" ;;
  esac
  [ "$(cat "$home/state/.lock")" = "codex:thread-new" ] || fail "reclaim did not publish the new holder"

  pass "A named marker lock is reclaimable and an unnamed one is not"
}

# reclaim must never weaken the invariant it exists to unblock: a numeric holder
# that is provably a live harness process still refuses.
test_reclaim_never_overrides_a_live_pid_holder() {
  local dir fakebin home err holder
  dir="$TMP_ROOT/live-pid-holder"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home/state"
  holder=$$
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"-p $holder"*) printf 'claude\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$holder" > "$home/state/.lock"

  if err=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-new FM_HOME="$home" "$ROOT/bin/fm-lock.sh" reclaim "codex:thread-old" 2>&1); then
    fail "reclaim forced a live numeric lock holder"
  fi
  case "$err" in
    *"another live firstmate session holds the lock (pid $holder)"*) ;;
    *) fail "unexpected live-holder refusal: $err" ;;
  esac
  [ "$(cat "$home/state/.lock")" = "$holder" ] || fail "reclaim rewrote a live numeric lock"

  pass "Reclaim never overrides a live numeric lock holder"
}

# A live cursor-agent sets CURSOR_AGENT=1 itself; an inherited CODEX_THREAD_ID
# from a multiplexer's stored environment must not relabel it as Codex.
test_own_cursor_marker_outranks_inherited_codex_thread() {
  local dir fakebin got
  dir="$TMP_ROOT/cursor-over-codex"
  fakebin=$(fm_fakebin "$dir")
  make_ps_denied "$fakebin"

  got=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-stale CURSOR_AGENT=1 CURSOR_CONVERSATION_ID=conversation-123 bash -c \
    ". \"\$0/bin/fm-session-lock-lib.sh\"; fm_harness_ancestry_pid" "$ROOT")
  [ "$got" = "cursor:conversation-123" ] || fail "inherited Codex thread outranked a live Cursor marker, got '$got'"

  got=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-stale CURSOR_AGENT=1 CURSOR_CONVERSATION_ID=conversation-123 "$ROOT/bin/fm-harness.sh")
  [ "$got" = cursor ] || fail "inherited Codex thread relabelled a live Cursor harness as '$got'"

  pass "A harness's own live marker outranks an inherited Codex thread id"
}

# VSCODE_PID identifies an editor window, not an agent session: two sessions in
# one window would share it, so it must never become a lock identity.
test_vscode_window_env_is_not_a_lock_identity() {
  local dir fakebin home got err
  dir="$TMP_ROOT/vscode-window"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home/state"
  make_ps_denied "$fakebin"

  if got=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CODEX_THREAD_ID -u CURSOR_CONVERSATION_ID -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    PATH="$fakebin:$BASE_PATH" TERM_PROGRAM=vscode VSCODE_PID=4242 bash -c \
    ". \"\$0/bin/fm-session-lock-lib.sh\"; fm_harness_ancestry_pid" "$ROOT"); then
    fail "a VS Code window env produced a lock identity '$got'"
  fi

  if err=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CODEX_THREAD_ID -u CURSOR_CONVERSATION_ID -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    PATH="$fakebin:$BASE_PATH" TERM_PROGRAM=vscode VSCODE_PID=4242 FM_HOME="$home" \
    "$ROOT/bin/fm-lock.sh" 2>&1); then
    fail "a VS Code window env acquired the fleet lock"
  fi
  case "$err" in
    *"cannot locate harness process in ancestry or verified host marker"*) ;;
    *) fail "unexpected VS Code window refusal: $err" ;;
  esac

  pass "A VS Code window env is not a session-lock identity"
}

# Only the trial-verified CURSOR_CONVERSATION_ID (the session id) is a Cursor
# identity. A variable whose per-session scope no trial recorded must not become
# one: if it were per-turn, its own live session would later compute a different
# identity and wedge the home read-only against itself.
test_unverified_cursor_env_is_not_a_lock_identity() {
  local dir fakebin got
  dir="$TMP_ROOT/cursor-unverified"
  fakebin=$(fm_fakebin "$dir")
  make_ps_denied "$fakebin"

  if got=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CODEX_THREAD_ID -u CURSOR_CONVERSATION_ID -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    PATH="$fakebin:$BASE_PATH" CURSOR_AGENT_SESSION_ID=cursor-123 CURSOR_TRACE_ID=trace-1 bash -c \
    ". \"\$0/bin/fm-session-lock-lib.sh\"; fm_harness_ancestry_pid" "$ROOT"); then
    fail "an unverified Cursor env variable produced a lock identity '$got'"
  fi

  pass "Unverified Cursor env variables are not session-lock identities"
}

test_cursor_conversation_marker_identity_without_ps() {
  local dir fakebin got
  dir="$TMP_ROOT/cursor-conversation-lock"
  fakebin=$(fm_fakebin "$dir")
  make_ps_denied "$fakebin"

  got=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CODEX_THREAD_ID -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CURSOR_CONVERSATION_ID=conversation-123 bash -c \
    ". \"\$0/bin/fm-session-lock-lib.sh\"; fm_harness_ancestry_pid" "$ROOT")
  [ "$got" = "cursor:conversation-123" ] || fail "Cursor conversation marker fallback resolved '$got', expected cursor:conversation-123"

  pass "Cursor conversation marker provides a session-lock identity without ps ancestry"
}

# A multiplexer replays its server's stored environment into every later window,
# so two sandboxed sessions can read ONE CODEX_THREAD_ID. Without a per-window
# scope both would compute the same identity, self-match the other's lock, and
# run the mutating bootstrap sweeps at once - a fail-open mutual exclusion.
test_marker_identity_is_scoped_to_its_window() {
  local dir fakebin home first second out err
  dir="$TMP_ROOT/marker-window-scope"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home/state"
  make_ps_denied "$fakebin"

  first=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-shared TMUX_PANE=%1 bash -c \
    ". \"\$0/bin/fm-session-lock-lib.sh\"; fm_harness_ancestry_pid" "$ROOT")
  second=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-shared TMUX_PANE=%2 bash -c \
    ". \"\$0/bin/fm-session-lock-lib.sh\"; fm_harness_ancestry_pid" "$ROOT")
  [ "$first" = "codex:thread-shared@%1" ] || fail "window-scoped identity resolved '$first', expected codex:thread-shared@%1"
  [ "$first" != "$second" ] || fail "two windows sharing one Codex thread id computed the same identity '$first'"

  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-shared TMUX_PANE=%1 FM_HOME="$home" "$ROOT/bin/fm-lock.sh") \
    || fail "fm-lock did not acquire through a window-scoped marker"
  case "$out" in
    *"lock acquired: harness identity codex:thread-shared@%1"*) ;;
    *) fail "unexpected window-scoped acquisition output: $out" ;;
  esac

  if err=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-shared TMUX_PANE=%2 FM_HOME="$home" "$ROOT/bin/fm-lock.sh" 2>&1); then
    fail "a second window sharing the same Codex thread id took the lock"
  fi
  case "$err" in
    *"another firstmate session holds an unverifiable marker lock (codex:thread-shared@%1)"*) ;;
    *) fail "unexpected second-window refusal: $err" ;;
  esac
  [ "$(cat "$home/state/.lock")" = "codex:thread-shared@%1" ] || fail "a second window rewrote the first window's lock"

  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT \
    -u CURSOR_CONVERSATION_ID -u HERDR_ENV -u HERDR_PANE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-shared TMUX_PANE=%1 FM_HOME="$home" "$ROOT/bin/fm-lock.sh") \
    || fail "the owning window could not reacquire its own window-scoped lock"

  pass "A marker identity is scoped to its window, so one thread id cannot grant two sessions the lock"
}

test_codex_marker_detects_harness_without_ps
test_codex_marker_acquires_and_reuses_lock
test_different_marker_lock_fails_closed
test_marker_lock_reclaim_takes_over_confirmed_dead_session
test_reclaim_never_overrides_a_live_pid_holder
test_own_cursor_marker_outranks_inherited_codex_thread
test_vscode_window_env_is_not_a_lock_identity
test_unverified_cursor_env_is_not_a_lock_identity
test_cursor_conversation_marker_identity_without_ps
test_marker_identity_is_scoped_to_its_window
