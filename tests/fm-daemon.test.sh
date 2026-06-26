#!/usr/bin/env bash
# tests/fm-daemon.test.sh - supervise-daemon classifiers, the captain-relevant
# status-phrase matrix (a product contract), escalation batching/dedupe, afk
# presence-gating, and the injection-hardening units that an e2e cannot
# deterministically reach (persistent-Enter-swallow, max-defer wedge alarms,
# fm-send swallow reporting, composer-pending ANSI parsing). The operator-visible
# inject flow lives in fm-afk-inject-e2e and fm-wake-daemon-lifecycle-e2e.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
# Source the daemon's pure functions once. Its main loop is skipped under sourcing
# via a BASH_SOURCE guard, so only classify_*/housekeeping/escalate_*/afk_* and the
# pane/submit helpers become defined.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-daemon-tests)


test_daemon_state_root_uses_fm_home() {
  local dir home override out
  dir=$(make_supercase daemon-fm-home)
  home="$dir/firstmate-home"
  override="$dir/override-state"
  mkdir -p "$home" "$override"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE='' _state_root)
  [ "$out" = "$home/state" ] || fail "daemon state root ignored FM_HOME: $out"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$override" _state_root)
  [ "$out" = "$override" ] || fail "daemon state root ignored FM_STATE_OVERRIDE: $out"

  pass "supervise daemon state root is scoped by FM_HOME"
}

test_classify_routine_signal_self() {
  local dir state out
  dir=$(make_supercase classify-routine)
  state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/foo-x1.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/foo-x1.status" "$state")
  case "$out" in self\|*) pass "routine signal self-handles" ;; *) fail "routine signal did not self-handle: $out" ;; esac
}

test_classify_terminal_signal_escalates() {
  local dir state kw out
  dir=$(make_supercase classify-terminal)
  state="$dir/state"
  for kw in "done: PR https://x/y/pull/1" "needs-decision: pick A" "blocked: no perms" \
            "failed: rc 2" "PR ready https://x/y/pull/2" "checks green" \
            "ready in branch fm/t1" "merged"; do
    printf 'working\n%s\n' "$kw" > "$state/t.status"
    out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/t.status" "$state")
    case "$out" in escalate\|*) ;; *) fail "captain verb did not escalate ($kw): $out" ;; esac
  done
  pass "captain-relevant status verbs escalate"
}

test_classify_check_and_unknown_escalate() {
  local out
  out=$(classify_check "check: /s/c.check.sh: merged: https://x")
  case "$out" in escalate\|*) ;; *) fail "check did not escalate: $out" ;; esac
  out=$(classify_unknown "frobnicate: weird")
  case "$out" in escalate\|*) ;; *) fail "unknown did not fail-safe escalate: $out" ;; esac
  out=$(classify_heartbeat)
  case "$out" in self\|*) ;; *) fail "heartbeat did not self-handle: $out" ;; esac
  pass "check + unknown escalate; heartbeat self-handles"
}

test_stale_transient_self_records_marker() {
  local dir state out key
  dir=$(make_supercase stale-transient)
  state="$dir/state"
  printf 'working: building\n' > "$state/qux-w4.status"
  stale_marker_record "sess:fm-qux-w4" "$state"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-qux-w4" "$state")
  case "$out" in self\|*) ;; *) fail "transient stale did not self-handle: $out" ;; esac
  key=$(printf '%s' "$(window_to_task "sess:fm-qux-w4")" | tr ':/.' '___')
  [ -e "$state/.subsuper-stale-$key" ] || fail "stale marker was not recorded"
  pass "transient stale self-handles and records a persistence marker"
}

test_stale_terminal_escalates() {
  local dir state out
  dir=$(make_supercase stale-terminal)
  state="$dir/state"
  printf 'done: ready in branch fm/t1\n' > "$state/fin-t5.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-fin-t5" "$state")
  case "$out" in escalate\|*) ;; *) fail "terminal stale did not escalate: $out" ;; esac
  pass "stale + terminal status escalates immediately"
}

test_housekeeping_persistent_stale_escalates() {
  local dir state fakebin win pane key
  dir=$(make_supercase stale-persistent)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-pers-w5"
  pane="$dir/pane.txt"
  printf 'working\n' > "$state/pers-w5.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "pers-w5" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent stale was not escalated"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "stale marker not cleared after escalation"
  pass "persistent stale escalates after threshold and clears its marker"
}

test_housekeeping_resumed_stale_cleared() {
  local dir state fakebin win pane key
  dir=$(make_supercase stale-resumed)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-res-w6"
  pane="$dir/pane.txt"
  printf 'working\n' > "$state/res-w6.status"
  printf 'Working...\n' > "$pane"
  key=$(printf '%s' "res-w6" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -e "$state/.subsuper-stale-$key" ] && fail "resumed stale marker was not cleared"
  [ -s "$state/.subsuper-escalations" ] && fail "resumed stale was escalated"
  pass "resumed (busy) stale clears its marker without escalating"
}

test_escalate_batches_into_one_digest() {
  local dir state fakebin sent capture n
  dir=$(make_supercase batch)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "event A: done: PR 1"
  escalate_add "$state" "event B: done: PR 2"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed"
  grep -F "event A" "$sent" >/dev/null || fail "batch digest missing event A"
  grep -F "event B" "$sent" >/dev/null || fail "batch digest missing event B"
  grep -F 'event A: done: PR 1 | event B: done: PR 2' "$sent" >/dev/null \
    || fail "batch digest did not join events with literal ' | '"
  [ -s "$state/.subsuper-escalations" ] && fail "escalation buffer not cleared after flush"
  [ -e "$state/.subsuper-escalations.since" ] && fail "first-append sidecar not cleared after flush"
  n=$(grep -c '\[ENTER\]' "$sent")
  [ "$n" -eq 1 ] || fail "expected one injected digest, got $n send-keys submits"
  pass "multiple escalations flush as a single batched digest"
}

test_escalate_batch_age_uses_first_append() {
  local dir state fakebin sent capture
  dir=$(make_supercase batch-age)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "event A: done: PR 1"
  escalate_add "$state" "event B: done: PR 2"
  echo $(( $(date +%s) - 100 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=90 FM_HOUSEKEEPING_TICK=0 \
    housekeeping "$state"
  grep -F 'event A: done: PR 1 | event B: done: PR 2' "$sent" >/dev/null \
    || fail "backdated batch did not flush as a joined digest (max-delay measured from last append)"
  [ -s "$state/.subsuper-escalations" ] && fail "escalation buffer not cleared after backdated flush"
  [ -e "$state/.subsuper-escalations.since" ] && fail "first-append sidecar not cleared after flush"
  pass "batch flush measures max-delay from the first append, not the last"
}

test_heartbeat_scan_dedup() {
  local dir state
  dir=$(make_supercase scan-dedup)
  state="$dir/state"
  printf 'done: ready\n' > "$state/dup-t6.status"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "catch-all scan did not escalate a terminal"
  : > "$state/.subsuper-escalations"
  echo $(( $(date +%s) - 99999 )) > "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ -s "$state/.subsuper-escalations" ] && fail "catch-all scan re-escalated the same terminal (dedup failed)"
  pass "catch-all scan escalates a missed terminal once, not twice"
}

test_handle_wake_routes_self_and_escalate() {
  local dir state
  dir=$(make_supercase handle)
  state="$dir/state"
  printf 'working\n' > "$state/h-routine.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/h-routine.status" "$state"
  [ -s "$state/.subsuper-escalations" ] && fail "routine signal was escalated by handle_wake"
  printf 'done: PR 1\n' > "$state/h-done.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/h-done.status" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "captain signal was not buffered by handle_wake"
  pass "handle_wake routes routine->self and captain->escalate"
}

test_inject_skip_forces_self() {
  local dir state
  dir=$(make_supercase skip)
  state="$dir/state"
  printf 'done: PR 1\n' > "$state/s1.status"
  FM_STATE_OVERRIDE="$state" FM_INJECT_SKIP="signal" handle_wake "signal: $state/s1.status" "$state"
  [ -s "$state/.subsuper-escalations" ] && fail "INJECT_SKIP=signal did not force self-handle"
  pass "INJECT_SKIP forces self-handle, bypassing captain-relevant classification"
}

test_is_wake_reason_distinguishes_status_stdout() {
  # Real wake reasons are recognized; watcher status lines (singleton collision)
  # are not, so the main loop can idle them without flooding escalations.
  is_wake_reason "signal: /x/y.status" || fail "signal: not recognized as wake"
  is_wake_reason "stale: s:fm-x" || fail "stale: not recognized as wake"
  is_wake_reason "check: /s/c.sh: merged" || fail "check: not recognized as wake"
  is_wake_reason "heartbeat" || fail "heartbeat not recognized as wake"
  is_wake_reason "watcher: already running" && fail "singleton status line misclassified as wake"
  is_wake_reason "watcher: already running pid 123" && fail "singleton status (pid) misclassified as wake"
  pass "is_wake_reason distinguishes watcher wake reasons from singleton-status stdout"
}

test_terminal_stale_escalate_leaves_no_marker() {
  local dir state win key
  dir=$(make_supercase stale-terminal-nomarker)
  state="$dir/state"
  win="sess:fm-fin-n7"
  printf 'done: PR https://x/y/pull/7\n' > "$state/fin-n7.status"
  key=$(printf '%s' "fin-n7" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  FM_STATE_OVERRIDE="$state" handle_wake "stale: $win" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "terminal stale was not escalated"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "terminal stale left a persistence marker (housekeeping would re-escalate)"
  : > "$state/.subsuper-escalations"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "housekeeping re-escalated a terminal stale as a wedge"
  pass "terminal-stale escalate removes its marker so housekeeping does not re-escalate"
}

test_signal_escalate_marks_seen_no_catchall_refire() {
  local dir state key
  dir=$(make_supercase signal-seen)
  state="$dir/state"
  printf 'done: PR https://x/y/pull/8\n' > "$state/sig-t8.status"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/sig-t8.status" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "captain signal was not escalated"
  key=$(printf '%s' "sig-t8" | tr ':/.' '___')
  [ "$(cat "$state/.subsuper-seen-status-$key" 2>/dev/null || true)" = "done: PR https://x/y/pull/8" ] \
    || fail "captain signal escalate did not write the seen-status marker"
  : > "$state/.subsuper-escalations"
  rm -f "$state/.subsuper-last-scan"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "catch-all scan re-fired an already-escalated signal"
  pass "captain signal escalate marks seen so the catch-all scan does not re-fire"
}

test_collapse_newlines_pure() {
  local out
  out=$(_collapse_newlines $'line one\nline two\nline three')
  [ "$out" = "line one - line two - line three" ] || fail "collapse failed: '$out'"
  out=$(_collapse_newlines "no newlines here")
  [ "$out" = "no newlines here" ] || fail "collapse changed no-newline text"
  out=$(_collapse_newlines $'a\nb')
  [ "$out" = "a - b" ] || fail "collapse two lines failed: '$out'"
  pass "_collapse_newlines replaces newlines with literal separator"
}

test_afk_absent_daemon_does_not_inject() {
  local dir state fakebin sent capture
  dir=$(make_supercase afk-off)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; : > "$capture"
  escalate_add "$state" "done: PR 1"
  # afk flag deliberately NOT set
  if PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state"; then
    fail "escalate_flush succeeded while afk inactive"
  fi
  [ -s "$sent" ] && fail "daemon injected while afk inactive"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer not preserved when afk inactive"
  pass "afk flag absent: daemon does not inject, buffer preserved"
}

test_busy_guard_defers_when_supervisor_busy() {
  local dir state fakebin sent capture
  dir=$(make_supercase busy-guard)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"
  # pane shows a busy signature (firstmate mid-turn)
  printf 'esc to interrupt\n' > "$capture"
  escalate_add "$state" "done: PR 1"
  afk_enter "$state"
  if PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state"; then
    fail "escalate_flush should defer when supervisor pane busy"
  fi
  [ -s "$sent" ] && fail "daemon injected into a busy pane"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer not preserved when deferred"
  pass "busy-guard defers injection when supervisor pane is busy"
}

test_marker_detection() {
  # message_is_injection: marker present -> injection; absent -> real message
  message_is_injection "${FM_INJECT_MARK}Supervisor escalate: done" \
    || fail "marker-prefixed message not detected as injection"
  message_is_injection "how's it going?" \
    && fail "plain message misdetected as injection"
  message_is_injection "" && fail "empty message misdetected as injection"
  # should_exit_afk: the full afk-exit contract
  local dir state
  dir=$(make_supercase marker-detect)
  state="$dir/state"
  afk_enter "$state"
  should_exit_afk "$state" "${FM_INJECT_MARK}escalate" \
    && fail "marker message should not exit afk (internal escalation)"
  should_exit_afk "$state" "status update please" \
    || fail "plain message should exit afk (captain is back)"
  pass "marker detection: marker -> stay afk, no marker -> exit afk"
}

test_afk_turn_exemption() {
  local dir state
  dir=$(make_supercase afk-exempt)
  state="$dir/state"
  afk_enter "$state"
  # /afk while already away must NOT self-cancel (re-entering/extending)
  should_exit_afk "$state" "/afk" \
    && fail "bare /afk should not exit afk"
  should_exit_afk "$state" "/afk back in an hour" \
    && fail "/afk with args should not exit afk"
  # a non-/afk skill invocation DOES exit (the captain is actively working)
  should_exit_afk "$state" "/no-mistakes" \
    || fail "non-afk skill should exit afk"
  pass "/afk invocation is exempt from afk exit (no self-cancel)"
}

test_should_exit_afk_when_afk_inactive() {
  local dir state
  dir=$(make_supercase no-afk)
  state="$dir/state"
  # afk flag absent: should never signal exit (nothing to exit)
  should_exit_afk "$state" "hello" \
    && fail "should_exit_afk true when afk inactive"
  should_exit_afk "$state" "${FM_INJECT_MARK}test" \
    && fail "should_exit_afk true when afk inactive (marker)"
  pass "should_exit_afk returns false when afk is not active"
}

test_strip_injection_marker() {
  local stripped
  stripped=$(strip_injection_marker "${FM_INJECT_MARK}Supervisor escalate: done")
  [ "$stripped" = "Supervisor escalate: done" ] \
    || fail "marker not stripped: '$stripped'"
  # No marker → unchanged.
  stripped=$(strip_injection_marker "no marker here")
  [ "$stripped" = "no marker here" ] \
    || fail "non-marker text changed: '$stripped'"
  # Empty → empty.
  stripped=$(strip_injection_marker "")
  [ "$stripped" = "" ] || fail "empty text changed: '$stripped'"
  # Only marker → empty.
  stripped=$(strip_injection_marker "$FM_INJECT_MARK")
  [ "$stripped" = "" ] || fail "bare marker not stripped: '$stripped'"
  pass "strip_injection_marker removes the sentinel marker cleanly"
}

test_pane_input_pending_detects_partial_input() {
  local dir state fakebin capture
  dir=$(make_supercase pending-input)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  # Line 3 (cursor_y=2) has human's partial text (no Enter) → pending.
  printf 'line one\nline two\nhuman draft text\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    || fail "pane_input_pending should detect non-empty composer (human text)"
  pass "pane_input_pending detects partial input on the cursor line"
}

test_pane_input_pending_blank_is_not_pending() {
  local dir state fakebin capture
  dir=$(make_supercase pending-blank)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  # Cursor line (line 3, cursor_y=2) is blank → not pending.
  printf 'some output\nmore output\n\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    && fail "blank composer line falsely detected as pending"
  pass "pane_input_pending: blank cursor line is not pending"
}

test_pane_input_pending_idle_prompt_not_pending() {
  local dir state fakebin capture
  dir=$(make_supercase pending-prompt)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  # Cursor line (line 3, cursor_y=2) is a bare prompt ($) → idle → not pending.
  printf 'output\noutput\n$ \n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    && fail "bare prompt falsely detected as pending"
  # Bare > prompt also idle.
  printf 'output\noutput\n> \n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
    pane_input_pending "fakepane" \
    && fail "bare > prompt falsely detected as pending"
  pass "pane_input_pending: bare prompts are not pending (idle)"
}

test_pane_input_pending_honors_idle_override_after_border_strip() {
  local dir state fakebin capture
  dir=$(make_supercase pending-custom-idle)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  printf '│ custom idle> │\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_COMPOSER_IDLE_RE='^custom idle>$' pane_input_pending "fakepane" \
    && fail "FM_COMPOSER_IDLE_RE was not applied after border stripping"
  pass "pane_input_pending honors FM_COMPOSER_IDLE_RE after border stripping"
}

test_classify_signal_dedup_against_scan() {
  # If the catch-all scan already escalated a status (seen marker matches),
  # classify_signal must self-handle to avoid a duplicate in the digest.
  local dir state key out
  dir=$(make_supercase signal-dedup)
  state="$dir/state"
  printf 'done: PR https://x/y/pull/9\n' > "$state/dup-s9.status"
  # Simulate the catch-all scan having already escalated this status.
  key=$(printf '%s' "dup-s9" | tr ':/.' '___')
  printf 'done: PR https://x/y/pull/9' > "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/dup-s9.status" "$state")
  case "$out" in self\|*) ;; *) fail "signal not deduped against scan: $out" ;; esac
  # Without the seen marker, it should escalate.
  rm -f "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_signal "$state/dup-s9.status" "$state")
  case "$out" in escalate\|*) ;; *) fail "signal should escalate when not seen: $out" ;; esac
  pass "classify_signal dedupes against the catch-all scan seen marker"
}

test_classify_stale_dedup_against_signal() {
  # If the signal path already escalated a status (seen marker matches),
  # classify_stale must self-handle to avoid a duplicate in the digest.
  local dir state key out
  dir=$(make_supercase stale-dedup)
  state="$dir/state"
  printf 'done: PR https://x/y/pull/10\n' > "$state/dup-s10.status"
  key=$(printf '%s' "dup-s10" | tr ':/.' '___')
  printf 'done: PR https://x/y/pull/10' > "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-dup-s10" "$state")
  case "$out" in self\|*) ;; *) fail "stale not deduped against signal: $out" ;; esac
  # Without the seen marker, it should escalate.
  rm -f "$state/.subsuper-seen-status-$key"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-dup-s10" "$state")
  case "$out" in escalate\|*) ;; *) fail "stale should escalate when not seen: $out" ;; esac
  pass "classify_stale dedupes against the signal path seen marker"
}

test_pane_input_pending_bordered_idle_not_pending() {
  # THE regression: an idle claude composer is a bordered box ("│ > … │"). The
  # old idle regex only matched a BARE prompt, so every idle claude pane read as
  # pending and the away-mode daemon deferred 100% of escalations for 9.5h.
  local dir state fakebin capture line
  dir=$(make_supercase pending-bordered-idle)
  state="$dir/state"; fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  for line in \
    "│ >                                            │" \
    "│ ❯                                            │" \
    "│ >  │" \
    "│                                              │"; do
    printf '%s\n' "$line" > "$capture"
    if PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
      pane_input_pending "fakepane"; then
      fail "bordered idle composer falsely detected as pending: <$line>"
    fi
  done
  pass "pane_input_pending: an idle bordered composer is NOT pending (afk-invx-i5)"
}

test_pane_input_pending_bordered_with_text_is_pending() {
  # Guard against over-broadening: real unsubmitted text inside the box must
  # still read as pending so the daemon defers (and the captain-return race is
  # still protected).
  local dir state fakebin capture
  dir=$(make_supercase pending-bordered-text)
  state="$dir/state"; fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  printf '%s\n' "│ > fix findings 1 and 3, skip 2               │" > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    pane_input_pending "fakepane" \
    || fail "real text inside a bordered composer was not detected as pending"
  pass "pane_input_pending: text inside a bordered composer is still pending"
}

test_submit_ack_confirms_on_bordered_empty_composer() {
  # RC2: the submit acknowledgement must recognize a bordered-EMPTY composer as
  # "submitted." The old ACK reused the broken check, so on claude it could never
  # confirm and always reported a false "Enter swallowed."
  local dir fakebin sent verdict
  dir=$(make_bordered_case ack-bordered)
  fakebin="$dir/fakebin"; sent="$dir/sent.log"; : > "$sent"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    fm_tmux_submit_core "win" "the digest" 3 0.05 0.05)
  [ "$verdict" = empty ] || fail "submit-ACK did not confirm on a bordered-empty composer: $verdict"
  [ "$(grep -cv '\[ENTER\]' "$sent")" -eq 1 ] || fail "digest typed more than once (retype)"
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] || fail "expected exactly one submitted Enter"
  pass "submit-ACK confirms a submit when the composer returns to a bordered-empty box"
}

test_submit_ack_reports_pending_on_persistent_swallow() {
  # A genuinely swallowed Enter (text stays in the box across all retries) is
  # reported as "pending" — the daemon keeps the buffer, fm-send exits non-zero —
  # and the digest is typed ONCE (Enter-only retries, never a retype).
  local dir fakebin sent verdict
  dir=$(make_bordered_case ack-swallow)
  fakebin="$dir/fakebin"; sent="$dir/sent.log"; : > "$sent"
  touch "$dir/.swallow"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    fm_tmux_submit_core "win" "the digest" 3 0.05 0.05)
  [ "$verdict" = pending ] || fail "persistent swallow not reported as pending: $verdict"
  [ "$(grep -cv '\[ENTER\]' "$sent")" -eq 1 ] || fail "digest retyped on swallow (expected type-once)"
  pass "submit-ACK reports pending on a persistently swallowed Enter (type-once)"
}

test_max_defer_empty_swallow_types_once_and_alarms() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-stuck)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '│ > │\n' > "$dir/composer"
  touch "$dir/.swallow"
  escalate_add "$state" "needs-decision: pick A"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_INJECT_CONFIRM_SLEEP=0.05 \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 housekeeping "$state"
  [ "$(grep -c 'Supervisor escalate' "$sent" 2>/dev/null || true)" -eq 1 ] \
    || fail "max-defer typed the digest more than once"
  [ -s "$state/.subsuper-inject-wedged" ] \
    || fail "stuck max-defer inject did not raise a wedge alarm marker"
  [ -s "$state/.subsuper-escalations" ] \
    || fail "buffer lost after a failed max-defer inject (must be preserved)"
  pass "max-defer on an empty stuck pane types once, alarms, and preserves the buffer"
}

test_max_defer_flushes_empty_idle_pane() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-recover)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '│ > │\n' > "$dir/composer"
  escalate_add "$state" "done: PR https://x/y/pull/1"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after a recovered max-defer flush"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm left behind after a successful max-defer flush"
  pass "max-defer flushes and clears the buffer on an empty bordered pane"
}

test_max_defer_pending_composer_alarms_without_typing() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-pending-digest)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '│ > human draft │\n' > "$dir/composer"
  escalate_add "$state" "needs-decision: pick B"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$sent" ] || fail "max-defer typed into a pending composer"
  [ -s "$state/.subsuper-inject-wedged" ] || fail "pending composer did not raise a wedge alarm marker"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer lost while composer was pending"
  grep -F 'human draft' "$dir/composer" >/dev/null || fail "pending composer content changed"
  pass "max-defer on a pending composer alarms without typing"
}

test_normal_flush_clears_stale_wedge_marker() {
  local dir state fakebin sent
  dir=$(make_bordered_case normal-clears-wedge)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf 'old wedge\n' > "$state/.subsuper-inject-wedged"
  escalate_add "$state" "done: PR https://x/y/pull/2"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_INJECT_CONFIRM_SLEEP=0.05 escalate_flush "$state" \
    || fail "normal escalate_flush failed"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after normal flush"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge marker survived successful normal flush"
  pass "normal flush clears a stale wedge marker"
}

test_below_max_defer_does_nothing() {
  local dir state fakebin sent capture
  dir=$(make_supercase below-maxdefer)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  capture="$dir/pane.txt"; printf 'stuck junk line\n' > "$capture"
  escalate_add "$state" "needs-decision: pick A"
  date +%s > "$state/.subsuper-escalations.since"   # just now
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=300 housekeeping "$state"
  [ ! -s "$sent" ] || fail "injected before MAX_DEFER elapsed"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm fired before MAX_DEFER"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer dropped below MAX_DEFER"
  pass "below MAX_DEFER: no inject, no alarm, buffer preserved"
}

test_max_defer_afk_inactive_does_not_flush_or_alarm() {
  local dir state fakebin sent
  dir=$(make_bordered_case maxdefer-inactive)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  escalate_add "$state" "needs-decision: pick B"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$sent" ] || fail "injected while afk was inactive"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge alarm fired while afk was inactive"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer dropped while afk was inactive"
  pass "max-defer does not flush or alarm while afk is inactive"
}

test_fm_send_exits_nonzero_on_confirmed_swallow() {
  # fm-send.sh must exit NON-ZERO when a steer's Enter is positively swallowed
  # (text left in the composer), so firstmate learns the instruction did not land
  # — and exit ZERO on a clean submit.
  local dir fakebin err
  dir=$(make_bordered_case send-swallow)
  fakebin="$dir/fakebin"; err="$dir/send.err"
  # Clean submit -> exit 0.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_SEND_SLEEP=0.05 "$ROOT/bin/fm-send.sh" sess:win 'route this work' >/dev/null 2>"$err" \
    || fail "fm-send exited non-zero on a clean submit: $(cat "$err")"
  # Persistent swallow -> exit non-zero with a clear message.
  printf '│ > │\n' > "$dir/composer"
  touch "$dir/.swallow"
  if PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_SEND_SLEEP=0.05 \
    "$ROOT/bin/fm-send.sh" sess:win 'fix findings 1 and 3, skip 2' >/dev/null 2>"$err"; then
    fail "fm-send exited zero despite a swallowed Enter (silent unsubmitted instruction)"
  fi
  grep -F 'not submitted' "$err" >/dev/null || fail "fm-send did not explain the swallowed submit: $(cat "$err")"
  pass "fm-send exits non-zero on a confirmed swallow, zero on a clean submit"
}

test_fm_send_exits_nonzero_on_initial_send_failure() {
  local dir fakebin err
  dir=$(make_bordered_case send-type-failure)
  fakebin="$dir/fakebin"; err="$dir/send.err"
  if PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_FAKE_SEND_FAIL=1 FM_SEND_SLEEP=0.05 \
    "$ROOT/bin/fm-send.sh" sess:win 'route this work' >/dev/null 2>"$err"; then
    fail "fm-send exited zero despite initial tmux send-keys failure"
  fi
  grep -F 'text not sent' "$err" >/dev/null || fail "fm-send did not explain initial send failure: $(cat "$err")"
  pass "fm-send exits non-zero when initial text send fails"
}

test_daemon_state_root_uses_fm_home
test_classify_routine_signal_self
test_classify_terminal_signal_escalates
test_classify_check_and_unknown_escalate
test_stale_transient_self_records_marker
test_stale_terminal_escalates
test_housekeeping_persistent_stale_escalates
test_housekeeping_resumed_stale_cleared
test_escalate_batches_into_one_digest
test_escalate_batch_age_uses_first_append
test_heartbeat_scan_dedup
test_handle_wake_routes_self_and_escalate
test_inject_skip_forces_self
test_is_wake_reason_distinguishes_status_stdout
test_terminal_stale_escalate_leaves_no_marker
test_signal_escalate_marks_seen_no_catchall_refire
test_collapse_newlines_pure
test_afk_absent_daemon_does_not_inject
test_busy_guard_defers_when_supervisor_busy
test_marker_detection
test_afk_turn_exemption
test_should_exit_afk_when_afk_inactive
test_strip_injection_marker
test_pane_input_pending_detects_partial_input
test_pane_input_pending_blank_is_not_pending
test_pane_input_pending_idle_prompt_not_pending
test_pane_input_pending_honors_idle_override_after_border_strip
test_classify_signal_dedup_against_scan
test_classify_stale_dedup_against_signal
test_pane_input_pending_bordered_idle_not_pending
test_pane_input_pending_bordered_with_text_is_pending
test_submit_ack_confirms_on_bordered_empty_composer
test_submit_ack_reports_pending_on_persistent_swallow
test_max_defer_empty_swallow_types_once_and_alarms
test_max_defer_flushes_empty_idle_pane
test_max_defer_pending_composer_alarms_without_typing
test_normal_flush_clears_stale_wedge_marker
test_below_max_defer_does_nothing
test_max_defer_afk_inactive_does_not_flush_or_alarm
test_fm_send_exits_nonzero_on_confirmed_swallow
test_fm_send_exits_nonzero_on_initial_send_failure
