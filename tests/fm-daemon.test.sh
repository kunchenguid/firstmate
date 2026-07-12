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
AFK_START="$ROOT/bin/fm-afk-start.sh"
# Source the daemon's pure functions once. Its main loop is skipped under sourcing
# via a BASH_SOURCE guard, so only classify_*/housekeeping/escalate_*/afk_* and the
# pane/submit helpers become defined.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-daemon-tests)

test_afk_start_refuses_when_flag_cannot_be_written() {
  local dir state out status
  dir=$(make_supercase afk-start-flag-unwritable)
  state="$dir/state"
  mkdir -p "$state/.afk"

  out=$(FM_STATE_OVERRIDE="$state" FM_SUPERVISOR_BACKEND=unsupported "$AFK_START" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "fm-afk-start.sh should fail when state/.afk cannot be written"
  assert_not_contains "$out" "starting supervise daemon" "fm-afk-start.sh continued into daemon startup after .afk write failure"
  assert_absent "$state/.supervise-daemon.log" "fm-afk-start.sh started the daemon after .afk write failure"
  pass "fm-afk-start.sh fails before daemon startup when the afk flag cannot be written"
}

test_afk_start_ignores_stale_pidfile_without_lock() {
  local dir state out status
  dir=$(make_supercase afk-start-stale-pidfile)
  state="$dir/state"
  printf '%s\n' "$$" > "$state/.supervise-daemon.pid"

  out=$(FM_STATE_OVERRIDE="$state" FM_SUPERVISOR_BACKEND=unsupported "$AFK_START" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "fm-afk-start.sh should attempt daemon startup instead of trusting a pidfile-only live pid"
  assert_contains "$out" "starting supervise daemon" "fm-afk-start.sh did not attempt daemon startup"
  assert_contains "$out" "does not support supervisor backend 'unsupported'" "daemon startup did not reach backend validation"
  assert_not_contains "$out" "daemon already running" "fm-afk-start.sh trusted a stale pidfile-only live pid"
  pass "fm-afk-start.sh ignores stale pidfile-only live pids"
}

test_afk_start_reclaims_stale_daemon_lock_reused_pid() {
  local dir state out status lock
  dir=$(make_supercase afk-start-stale-lock-reused-pid)
  state="$dir/state"
  lock="$state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s\n' "$$" > "$state/.supervise-daemon.pid"
  printf '%s\n' "$$" > "$lock/pid"
  printf '%s\n' "stale daemon identity" > "$lock/pid-identity"

  out=$(FM_STATE_OVERRIDE="$state" FM_SUPERVISOR_BACKEND=unsupported "$AFK_START" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "fm-afk-start.sh should attempt daemon startup after rejecting a reused-pid lock"
  assert_contains "$out" "starting supervise daemon" "fm-afk-start.sh did not attempt daemon startup after rejecting the stale lock"
  assert_contains "$out" "does not support supervisor backend 'unsupported'" "daemon startup did not reach backend validation after stale lock cleanup"
  assert_not_contains "$out" "daemon already running" "fm-afk-start.sh trusted a stale daemon lock with a reused pid"
  assert_not_contains "$out" "another fm-supervise-daemon is already running" "daemon singleton lock still trusted the reused pid"
  pass "fm-afk-start.sh reclaims stale daemon locks whose live pid identity no longer matches"
}

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
  fm_write_meta "$state/herdr-t5.meta" "window=default:w1:p2" "backend=herdr"
  printf 'done: ready in branch fm/herdr\n' > "$state/herdr-t5.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "default:w1:p2" "$state")
  case "$out" in escalate\|*) ;; *) fail "terminal herdr stale did not escalate through metadata: $out" ;; esac
  pass "stale + terminal status escalates immediately"
}

# A DECLARED external-wait pause (paused:) is neither a wedge nor a terminal
# escalation: classify_stale returns the `pause` action so handle_wake records a
# pause marker (long re-surface cadence) rather than a wedge stale marker.
test_stale_paused_classifies_pause() {
  local dir state out pause_reason
  dir=$(make_supercase stale-paused)
  state="$dir/state"
  pause_reason='paused: waiting for upstream checks green, merged, and blocked state to clear'
  status_is_captain_relevant "$pause_reason" && fail "pause reason phrases made the status captain-relevant"
  printf '%s\n' "$pause_reason" > "$state/held-w9.status"
  out=$(FM_STATE_OVERRIDE="$state" classify_stale "sess:fm-held-w9" "$state")
  case "$out" in pause\|*) ;; *) fail "declared pause did not classify as pause: $out" ;; esac
  pass "paused reasons with captain phrases remain pause-classified"
}

# handle_wake on a paused stale records a pause marker, drops any pre-existing wedge
# marker (so a working->paused pane is not still wedge-aged), and does NOT escalate
# on the wake itself - the recheck is housekeeping's job on the long cadence.
test_handle_wake_paused_records_pause_marker() {
  local dir state key win
  dir=$(make_supercase handle-paused)
  state="$dir/state"
  win="sess:fm-held-w10"
  printf 'paused: awaiting the vendor rate-limit reset\n' > "$state/held-w10.status"
  key=$(printf '%s' "held-w10" | tr ':/.' '___')
  date +%s > "$state/.subsuper-stale-$key"
  FM_STATE_OVERRIDE="$state" handle_wake "stale: $win" "$state"
  [ -e "$state/.subsuper-paused-$key" ] || fail "pause marker not recorded by handle_wake"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "wedge marker not cleared when the crew declared a pause"
  [ ! -s "$state/.subsuper-escalations" ] || fail "a declared pause escalated on the wake itself (should defer to the long recheck)"
  pass "handle_wake on a paused stale records a pause marker, drops the wedge marker, and does not escalate"
}

test_handle_wake_paused_signal_records_pause_marker() {
  local dir state key win
  dir=$(make_supercase handle-paused-signal)
  state="$dir/state"
  win="sess:fm-held-w10-signal"
  printf 'window=%s\nkind=ship\n' "$win" > "$state/held-w10-signal.meta"
  printf 'paused: awaiting the vendor rate-limit reset\n' > "$state/held-w10-signal.status"
  key=$(printf '%s' "held-w10-signal" | tr ':/.' '___')
  date +%s > "$state/.subsuper-stale-$key"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/held-w10-signal.status" "$state"
  [ -e "$state/.subsuper-paused-$key" ] || fail "pause signal did not record a pause marker"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "pause signal did not clear the wedge marker"
  [ ! -s "$state/.subsuper-escalations" ] || fail "a declared pause signal escalated instead of self-handling"
  pass "handle_wake records a declared pause from a routine signal for long-cadence rechecks"
}

test_handle_wake_terminal_signal_clears_pause_tracking() {
  local dir state key watcher_key win
  dir=$(make_supercase handle-terminal-signal)
  state="$dir/state"
  win="sess:fm-held-w10-terminal"
  printf 'window=%s\nkind=ship\n' "$win" > "$state/held-w10-terminal.meta"
  printf 'done: upstream landed\n' > "$state/held-w10-terminal.status"
  key=$(printf '%s' "held-w10-terminal" | tr '.:/' '___')
  watcher_key=$(printf '%s' "$win" | tr '.:/' '___')
  date +%s > "$state/.subsuper-paused-$key"
  date +%s > "$state/.subsuper-stale-$key"
  : > "$state/.paused-$watcher_key"
  : > "$state/.stale-$watcher_key"
  : > "$state/.wedge-escalations-$watcher_key"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $state/held-w10-terminal.status" "$state"
  [ ! -e "$state/.subsuper-paused-$key" ] || fail "terminal signal retained the daemon pause marker"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "terminal signal retained daemon stale tracking"
  [ ! -e "$state/.paused-$watcher_key" ] || fail "terminal signal retained watcher pause tracking"
  [ ! -e "$state/.stale-$watcher_key" ] || fail "terminal signal retained watcher stale tracking"
  [ ! -e "$state/.wedge-escalations-$watcher_key" ] || fail "terminal signal retained watcher wedge tracking"
  FM_STATE_OVERRIDE="$state" handle_wake "stale: $win" "$state"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "terminal stale dedupe restored daemon stale tracking"
  pass "a terminal signal clears pause and stale tracking across both supervisors"
}

test_housekeeping_migrates_watcher_pause_marker() {
  local dir state key win
  dir=$(make_supercase migrate-watcher-pause)
  state="$dir/state"
  win="sess:fm-held-w10-migrate"
  printf 'window=%s\nkind=ship\n' "$win" > "$state/held-w10-migrate.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/held-w10-migrate.status"
  key=$(printf '%s' "$win" | tr '.:/' '___')
  : > "$state/.paused-$key"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  key=$(printf '%s' "held-w10-migrate" | tr '.:/' '___')
  [ -e "$state/.subsuper-paused-$key" ] || fail "watcher pause marker was not migrated into daemon tracking"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "watcher pause migration left a wedge marker behind"
  pass "housekeeping migrates a normal-watcher's declared pause into daemon tracking"
}

test_housekeeping_migrates_watcher_unpaused_marker_to_clear() {
  local dir state key watcher_key win
  dir=$(make_supercase migrate-watcher-unpaused)
  state="$dir/state"
  win="sess:fm-held-w10-migrate-unpaused"
  printf 'window=%s\nkind=ship\n' "$win" > "$state/held-w10-migrate-unpaused.meta"
  printf 'working: upstream landed, resuming\n' > "$state/held-w10-migrate-unpaused.status"
  watcher_key=$(printf '%s' "$win" | tr '.:/' '___')
  : > "$state/.paused-$watcher_key"
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  key=$(printf '%s' "held-w10-migrate-unpaused" | tr '.:/' '___')
  [ ! -e "$state/.paused-$watcher_key" ] || fail "stale watcher pause marker was not cleared after resume"
  [ ! -e "$state/.subsuper-paused-$key" ] || fail "unpaused watcher handoff created a daemon pause marker"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "unpaused watcher handoff retained daemon stale tracking"
  [ ! -e "$state/.stale-$watcher_key" ] || fail "unpaused watcher handoff retained watcher stale tracking"
  pass "housekeeping clears an already-resumed watcher pause across both supervisors"
}

test_housekeeping_seeds_pause_marker_from_status() {
  local dir state key win
  dir=$(make_supercase seed-paused-status)
  state="$dir/state"
  win="sess:fm-held-w10-seed"
  printf 'window=%s\nkind=ship\n' "$win" > "$state/held-w10-seed.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/held-w10-seed.status"
  key=$(printf '%s' "held-w10-seed" | tr '.:/' '___')
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ -e "$state/.subsuper-paused-$key" ] || fail "paused status did not seed daemon pause tracking"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "paused status seeded wedge tracking"
  pass "housekeeping seeds pause tracking from status without a watcher marker"
}

# housekeeping re-surfaces a stale declared pause only past PAUSE_RESURFACE_SECS,
# as an awaiting-external recheck (never a wedge), and RESETS the marker so the
# window repeats rather than firing once.
test_housekeeping_paused_resurfaces_and_resets() {
  local dir state fakebin win pane key age
  dir=$(make_supercase paused-resurface)
  state="$dir/state"; fakebin="$dir/fakebin"
  win="sess:fm-held-w11"; pane="$dir/pane.txt"
  printf 'paused: holding for the upstream tool release\n' > "$state/held-w11.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "held-w11" | tr ':/.' '___')
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$state"
  grep -F "awaiting external" "$state/.subsuper-escalations" >/dev/null 2>&1 || fail "declared pause was not re-surfaced as an awaiting-external recheck"
  grep -F "possible wedge" "$state/.subsuper-escalations" >/dev/null 2>&1 && fail "declared pause was mislabeled a possible wedge"
  [ -e "$state/.subsuper-paused-$key" ] || fail "pause marker cleared instead of reset for the next window"
  age=$(( $(date +%s) - $(cat "$state/.subsuper-paused-$key" 2>/dev/null || echo 0) ))
  [ "$age" -lt 60 ] || fail "pause marker was not reset to now on re-surface (age ${age}s)"
  pass "housekeeping re-surfaces a stale declared pause on the long cadence and resets its window"
}

# A pause whose pane became busy again (the crew resumed) drops its marker without
# escalating, exactly like a resumed wedge.
test_housekeeping_paused_resumed_cleared() {
  local dir state fakebin win pane key
  dir=$(make_supercase paused-resumed)
  state="$dir/state"; fakebin="$dir/fakebin"
  win="sess:fm-held-w12"; pane="$dir/pane.txt"
  printf 'paused: holding for the upstream tool release\n' > "$state/held-w12.status"
  printf 'Working...\n' > "$pane"
  key=$(printf '%s' "held-w12" | tr ':/.' '___')
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$state"
  [ -e "$state/.subsuper-paused-$key" ] && fail "resumed (busy) pause marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "a resumed pause was escalated"
  pass "housekeeping clears a paused marker whose pane became busy again, without escalating"
}

# A pane still idle but whose status is no longer a pause (the crew changed state
# without becoming busy) drops the marker - the signal path owns the new state, so
# the pause recheck must not re-surface a stale pause reason.
test_housekeeping_paused_unpaused_cleared() {
  local dir state fakebin win pane key
  dir=$(make_supercase paused-unpaused)
  state="$dir/state"; fakebin="$dir/fakebin"
  win="sess:fm-held-w13"; pane="$dir/pane.txt"
  printf 'paused: holding for the upstream release\nworking: resumed, upstream landed\n' > "$state/held-w13.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "held-w13" | tr ':/.' '___')
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=240 housekeeping "$state"
  [ -e "$state/.subsuper-paused-$key" ] && fail "no-longer-paused marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "a crew that left its pause was re-surfaced as a pause"
  pass "housekeeping clears a paused marker once the crew is no longer declaring the pause"
}

test_housekeeping_stale_marker_transitions_to_pause() {
  local dir state fakebin win pane key
  dir=$(make_supercase stale-to-paused)
  state="$dir/state"; fakebin="$dir/fakebin"; win="sess:fm-held-w14"; pane="$dir/pane.txt"
  printf 'paused: awaiting the upstream tool release\n' > "$state/held-w14.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "held-w14" | tr ':/.' '___')
  echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-stale-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ -e "$state/.subsuper-paused-$key" ] || fail "existing stale marker did not move to paused state"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "existing stale marker remained wedge-aged after pause"
  [ ! -s "$state/.subsuper-escalations" ] || fail "a newly declared pause was escalated as a possible wedge"
  pass "housekeeping moves an existing stale marker to pause before wedge escalation"
}

test_housekeeping_pause_marker_transitions_to_clear() {
  local dir state fakebin win pane key
  dir=$(make_supercase paused-to-stale)
  state="$dir/state"; fakebin="$dir/fakebin"; win="sess:fm-held-w15"; pane="$dir/pane.txt"
  printf 'working: upstream landed, resuming\n' > "$state/held-w15.status"
  printf 'idle prompt $\n' > "$pane"
  key=$(printf '%s' "held-w15" | tr ':/.' '___')
  date +%s > "$state/.subsuper-paused-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=999999 housekeeping "$state"
  [ ! -e "$state/.subsuper-paused-$key" ] || fail "pause marker remained after the crew resumed"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "resume retained normal stale tracking"
  [ ! -s "$state/.subsuper-escalations" ] || fail "resuming from pause escalated immediately"
  pass "housekeeping clears tracking when a crew leaves pause"
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

test_housekeeping_herdr_persistent_stale_resolves_meta() {
  local dir state key
  dir=$(make_supercase stale-herdr-persistent)
  state="$dir/state"
  fm_write_meta "$state/herdr-w7.meta" "window=default:w1:p2" "backend=herdr"
  printf 'working\n' > "$state/herdr-w7.status"
  key=$(printf '%s' "herdr-w7" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  (
    fm_backend_capture() {
      [ "$1" = herdr ] || fail "expected herdr capture backend, got $1"
      [ "$2" = "default:w1:p2" ] || fail "expected herdr window target, got $2"
      printf 'idle prompt\n'
    }
    fm_backend_busy_state() {
      [ "$1" = herdr ] || fail "expected herdr busy backend, got $1"
      [ "$2" = "default:w1:p2" ] || fail "expected herdr busy target, got $2"
      printf 'idle'
    }
    fm_backend_capture herdr default:w1:p2 40 >/dev/null
    [ "$(fm_backend_busy_state herdr default:w1:p2)" = idle ] || fail "herdr busy stub did not report idle"
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  ) || fail "herdr persistent stale housekeeping failed"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent herdr stale was not escalated"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "herdr stale marker not cleared after escalation"
  pass "persistent herdr stale resolves the target from metadata and escalates"
}

test_housekeeping_herdr_idle_busy_footer_clears_stale() {
  local dir state key
  dir=$(make_supercase stale-herdr-idle-busy-footer)
  state="$dir/state"
  fm_write_meta "$state/herdr-footer.meta" "window=default:w1:p4" "backend=herdr"
  printf 'working\n' > "$state/herdr-footer.status"
  key=$(printf '%s' "herdr-footer" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  (
    fm_backend_capture() {
      [ "$1" = herdr ] || fail "expected herdr capture backend, got $1"
      [ "$2" = "default:w1:p4" ] || fail "expected herdr window target, got $2"
      printf 'esc to interrupt\n'
    }
    fm_backend_busy_state() {
      [ "$1" = herdr ] || fail "expected herdr busy backend, got $1"
      [ "$2" = "default:w1:p4" ] || fail "expected herdr busy target, got $2"
      printf 'idle'
    }
    fm_backend_capture herdr default:w1:p4 40 >/dev/null
    [ "$(fm_backend_busy_state herdr default:w1:p4)" = idle ] || fail "herdr busy stub did not report idle"
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  ) || fail "herdr idle busy-footer housekeeping failed"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "idle+busy-footer herdr stale marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "idle+busy-footer herdr stale was escalated"
  pass "herdr idle busy-footer stale clears through capture corroboration"
}

test_housekeeping_herdr_resumed_stale_cleared() {
  local dir state key
  dir=$(make_supercase stale-herdr-resumed)
  state="$dir/state"
  fm_write_meta "$state/herdr-busy.meta" "window=default:w1:p3" "backend=herdr"
  printf 'working\n' > "$state/herdr-busy.status"
  key=$(printf '%s' "herdr-busy" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  (
    fm_backend_capture() {
      [ "$1" = herdr ] || fail "expected herdr capture backend, got $1"
      [ "$2" = "default:w1:p3" ] || fail "expected herdr window target, got $2"
      printf 'unchanged pane\n'
    }
    fm_backend_busy_state() {
      [ "$1" = herdr ] || fail "expected herdr busy backend, got $1"
      [ "$2" = "default:w1:p3" ] || fail "expected herdr busy target, got $2"
      printf 'busy'
    }
    fm_backend_capture herdr default:w1:p3 40 >/dev/null
    [ "$(fm_backend_busy_state herdr default:w1:p3)" = busy ] || fail "herdr busy stub did not report busy"
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  ) || fail "herdr resumed stale housekeeping failed"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "busy herdr stale marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "busy herdr stale was escalated"
  pass "resumed herdr stale clears through backend-aware busy state"
}

test_housekeeping_orca_persistent_stale_resolves_terminal() {
  local dir state key
  dir=$(make_supercase stale-orca-persistent)
  state="$dir/state"
  fm_write_meta "$state/orca-w8.meta" "window=fm-orca-w8" "terminal=term-orca-w8" "backend=orca"
  printf 'working\n' > "$state/orca-w8.status"
  key=$(printf '%s' "orca-w8" | tr ':/.' '___')
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  (
    fm_backend_capture() {
      [ "$1" = orca ] || fail "expected orca capture backend, got $1"
      [ "$2" = "term-orca-w8" ] || fail "expected Orca terminal target, got $2"
      printf 'idle prompt\n'
    }
    fm_backend_busy_state() {
      [ "$1" = orca ] || fail "expected orca busy backend, got $1"
      [ "$2" = "term-orca-w8" ] || fail "expected Orca busy target, got $2"
      printf 'idle'
    }
    fm_backend_capture orca term-orca-w8 40 >/dev/null
    [ "$(fm_backend_busy_state orca term-orca-w8)" = idle ] || fail "Orca busy stub did not report idle"
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  ) || fail "Orca persistent stale housekeeping failed"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent Orca stale was not escalated"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "Orca stale marker not cleared after escalation"
  pass "persistent Orca stale resolves the terminal from metadata"
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

# The safety fix at the tmux classifier (task fm-composer-shellglyph-safety): a
# bare, unbordered shell prompt is a dead shell (the agent exited to its login
# shell), NOT an empty agent composer. It must read `unknown` (unsafe target),
# never `empty`. Before this fix a dead-shell pane read `empty` and the away-mode
# injector could type (and a shell could execute) an escalation there.
test_tmux_composer_state_bare_shell_is_unknown() {
  local dir fakebin capture g out
  dir=$(make_supercase composer-bare-shell)
  fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  for g in '$' '%' '#' '>'; do
    printf 'output\noutput\n%s \n' "$g" > "$capture"
    out=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=2 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = unknown ] \
      || fail "bare shell prompt '$g' must classify unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_tmux_composer_state: a bare shell prompt (\$/%/#/>) reads unknown, never empty (dead-shell injection safety)"
}

# The other side of the fix: a bordered composer box (the harness draws its own
# prompt glyph inside it) and a bare AGENT prompt glyph (claude ❯, codex ›) are
# genuine empty agent composers and must still read `empty`.
test_tmux_composer_state_bordered_and_agent_rows_are_empty() {
  local dir fakebin capture out
  dir=$(make_supercase composer-empty-agent)
  fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  printf '%s\n' "│ >                     │" > "$capture"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] || fail "a bordered '│ > │' composer should read empty, got '$out'"
  printf '%s\n' "❯ " > "$capture"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] || fail "a bare claude '❯' composer should read empty, got '$out'"
  printf '%s\n' "› " > "$capture"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] || fail "a bare codex '›' composer should read empty, got '$out'"
  pass "fm_tmux_composer_state: a bordered composer box and bare agent glyphs (❯/›) still read empty"
}

test_tmux_composer_state_requires_matching_box_borders() {
  local dir fakebin capture line out
  dir=$(make_supercase composer-decorated-shell)
  fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  for line in '| $ ' '$ |' '│ % ' '# ┃'; do
    printf '%s\n' "$line" > "$capture"
    out=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" FM_FAKE_TMUX_CURSOR_Y=0 \
      fm_tmux_composer_state "fakepane")
    [ "$out" != empty ] \
      || fail "a decorated shell prompt '$line' must not read as an empty composer"
  done
  pass "fm_tmux_composer_state: only matching edge borders form a composer box"
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

# --- backend-independent active wedge alert ---------------------------------
# These cover the 2026-07-10 overnight-incident fix: the max-defer wedge alarm's
# ACTIVE alert channel must reach the captain even when the wedged pane and its
# backend status-line are unreadable (a claude-on-herdr primary that night).
#
# NO test here EVER posts a real notification. Every notifier routes through
# the FM_WEDGE_ALARM_EXEC seam, which tests/wake-helpers.sh forces to a recorder
# ($FM_WEDGE_ALARM_LOG logs "<channel>\t<summary>"); the daemon also defaults
# that seam to "discard" whenever it is sourced. Assertions read the recorder
# log, so they verify channel SELECTION and summary propagation; the real
# osascript/herdr argv is verified once by the bounded manual evidence in
# docs/wedge-alarm.md, never from a suite.
make_wedge_case() {  # <name> -> echoes dir; creates state/, fakebin/{uname,osascript,herdr}, alert.log
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  # Fake uname so `auto` platform resolution is deterministic on any CI host.
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_UNAME:-Darwin}"
SH
  # Fakes keep command discovery deterministic on any CI host.
  cat > "$fakebin/osascript" <<'SH'
#!/usr/bin/env bash
printf '%s\n' osascript >> "${FM_WEDGE_ALARM_REAL_LOG:-/dev/null}"
exit 0
SH
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' herdr >> "${FM_WEDGE_ALARM_REAL_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/uname" "$fakebin/osascript" "$fakebin/herdr"
  : > "$dir/alert.log"
  printf '%s\n' "$dir"
}

test_wedge_alarm_library_mode_defaults_to_discard() {
  # The structural guarantee: sourcing the daemon with NO seam configured defaults
  # FM_WEDGE_ALARM_EXEC to "discard", so a sourced context (every test) cannot
  # fire a real notification even if it forgets to stub. Checked in a clean
  # subshell that first unsets this harness's recorder.
  local out
  # shellcheck disable=SC2016  # $1/$FM_WEDGE_ALARM_EXEC must expand in the child, not here
  out=$(env -u FM_WEDGE_ALARM_EXEC bash -c '. "$1"; printf "%s" "${FM_WEDGE_ALARM_EXEC:-UNSET}"' _ "$DAEMON")
  [ "$out" = discard ] \
    || fail "sourcing the daemon did not default the notifier seam to discard (got: $out)"
  pass "library mode: sourcing the daemon defaults FM_WEDGE_ALARM_EXEC to discard (no test can fire a real notification)"
}

test_wake_helpers_replace_inherited_notifier_override() {
  local dir unsafe_log alert_log unsafe
  dir=$(make_wedge_case wedge-inherited-override)
  unsafe_log="$dir/unsafe.log"
  alert_log="$dir/alert.log"
  unsafe="$dir/unsafe-override"
  cat > "$unsafe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' invoked >> "${FM_WEDGE_ALARM_UNSAFE_LOG:?}"
SH
  chmod +x "$unsafe"
  FM_WEDGE_ALARM_EXEC="$unsafe" FM_WEDGE_ALARM_UNSAFE_LOG="$unsafe_log" \
    FM_WEDGE_ALARM_LOG="$alert_log" FM_WEDGE_ALARM_CHANNEL=osascript \
    bash -c '. "$1"; . "$2"; wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"' \
      _ "$ROOT/tests/wake-helpers.sh" "$DAEMON"
  [ ! -s "$unsafe_log" ] || fail "wake helpers preserved an inherited notifier override"
  grep -F 'osascript' "$alert_log" >/dev/null \
    || fail "wake helpers did not install the safe notifier recorder"
  pass "wake helpers replace inherited notifier overrides with the safe recorder"
}

test_wedge_alarm_discard_seam_fires_nothing() {
  local dir log command_output channel
  dir=$(make_wedge_case wedge-discard); log="$dir/alert.log"
  command_output="$dir/command-output"
  channel="command: printf '%s' \"\$1\" > '$command_output'"
  PATH="$dir/fakebin:$PATH" FM_WEDGE_ALARM_LOG="$log" FM_WEDGE_ALARM_EXEC=discard \
    FM_WEDGE_ALARM_CHANNEL=$'osascript\nherdr\n'"$channel" \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  [ ! -s "$log" ] || fail "the discard seam still fired a notifier: $(cat "$log")"
  [ ! -e "$command_output" ] || fail "the discard seam still fired a command: notifier"
  pass "the discard seam suppresses every notifier, including command: (fires nothing)"
}

test_wedge_alarm_direct_notifiers_honor_discard_seam() {
  local dir real_log command_output command
  dir=$(make_wedge_case wedge-direct-discard); real_log="$dir/real.log"
  command_output="$dir/command-output"
  command="printf '%s' \"\$1\" > '$command_output'"
  PATH="$dir/fakebin:$PATH" FM_WEDGE_ALARM_REAL_LOG="$real_log" FM_WEDGE_ALARM_EXEC=discard \
    wedge_alarm_via_osascript "away-mode WEDGED 900s"
  PATH="$dir/fakebin:$PATH" FM_WEDGE_ALARM_REAL_LOG="$real_log" FM_WEDGE_ALARM_EXEC=discard \
    wedge_alarm_via_herdr "away-mode WEDGED 900s"
  FM_WEDGE_ALARM_EXEC=discard wedge_alarm_via_command "$command" "away-mode WEDGED 900s"
  [ ! -s "$real_log" ] || fail "direct notifier helpers bypassed the discard seam: $(cat "$real_log")"
  [ ! -e "$command_output" ] || fail "direct command helper bypassed the discard seam"
  pass "direct notifier helpers honor the discard seam, including command:"
}

test_wedge_alarm_osascript_channel_selected() {
  local dir log
  dir=$(make_wedge_case wedge-osascript); log="$dir/alert.log"
  FM_WEDGE_ALARM_LOG="$log" FM_WEDGE_ALARM_CHANNEL=osascript \
    wedge_alarm_notify "away-mode escalations WEDGED 600s undelivered - see /s/.marker" "/s/.marker"
  grep -F 'osascript' "$log" >/dev/null || fail "osascript channel not routed through the notifier seam: $(cat "$log")"
  grep -F 'WEDGED 600s undelivered' "$log" >/dev/null || fail "osascript channel did not carry the summary"
  grep -F 'herdr' "$log" >/dev/null && fail "osascript-only config also selected herdr"
  pass "osascript channel routes through the notifier seam with the summary (never a real notification)"
}

test_wedge_alarm_herdr_channel_selected() {
  local dir log
  dir=$(make_wedge_case wedge-herdr); log="$dir/alert.log"
  FM_WEDGE_ALARM_LOG="$log" FM_WEDGE_ALARM_CHANNEL=herdr \
    wedge_alarm_notify "away-mode escalations WEDGED 800s undelivered - see /s/.marker" "/s/.marker"
  grep -F 'herdr' "$log" >/dev/null || fail "herdr channel not routed through the notifier seam: $(cat "$log")"
  grep -F 'WEDGED 800s undelivered' "$log" >/dev/null || fail "herdr channel did not carry the summary"
  grep -F 'osascript' "$log" >/dev/null && fail "herdr-only config also selected osascript"
  pass "herdr channel routes through the notifier seam with the summary (never a real notification)"
}

test_wedge_alarm_command_channel_receives_summary() {
  local dir out_argv out_stdin chan
  dir=$(make_wedge_case wedge-command)
  out_argv="$dir/argv.txt"; out_stdin="$dir/stdin.txt"
  chan="command: printf '%s' \"\$1\" > '$out_argv'; cat > '$out_stdin'"
  FM_WEDGE_ALARM_EXEC='' FM_WEDGE_ALARM_CHANNEL="$chan" \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  [ "$(cat "$out_argv" 2>/dev/null)" = "away-mode WEDGED 900s" ] || fail "command channel did not receive the summary on \$1"
  grep -F 'away-mode WEDGED 900s' "$out_stdin" >/dev/null || fail "command channel did not receive the summary on stdin"
  pass "command channel runs the captain command with the summary on \$1 and on stdin"
}

test_wedge_alarm_command_failure_hides_configured_command() {
  local dir daemon_log secret rc
  dir=$(make_wedge_case wedge-command-redaction); daemon_log="$dir/daemon.log"
  secret="https://alerts.example.invalid/hook?token=private-wedge-token"
  LOG="$daemon_log" FM_WEDGE_ALARM_EXEC='' FM_WEDGE_ALARM_CHANNEL="command:exit 73 # $secret" \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  rc=$?
  [ "$rc" -eq 0 ] || fail "a failed command channel made wedge_alarm_notify return non-zero ($rc)"
  grep -F 'command channel exited 73 (command redacted)' "$daemon_log" >/dev/null \
    || fail "command channel failure did not log its exit status: $(cat "$daemon_log" 2>/dev/null)"
  grep -F "$secret" "$daemon_log" >/dev/null \
    && fail "command channel failure leaked its configured command: $(cat "$daemon_log")"
  pass "command channel failures redact configured commands while logging their exit status"
}

test_wedge_alarm_unknown_channel_hides_configured_directive() {
  local dir daemon_log secret rc
  dir=$(make_wedge_case wedge-unknown-redaction); daemon_log="$dir/daemon.log"
  secret="https://alerts.example.invalid/hook?token=private-wedge-token"
  LOG="$daemon_log" FM_WEDGE_ALARM_CHANNEL="webhook:$secret" \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  rc=$?
  [ "$rc" -eq 0 ] || fail "an unknown channel made wedge_alarm_notify return non-zero ($rc)"
  grep -F 'unrecognized active-alert channel directive (redacted); marker still written' "$daemon_log" >/dev/null \
    || fail "an unknown channel did not log the redacted directive category: $(cat "$daemon_log" 2>/dev/null)"
  grep -F "$secret" "$daemon_log" >/dev/null \
    && fail "an unknown channel leaked its configured directive: $(cat "$daemon_log")"
  pass "unknown channel directives are redacted while the alarm keeps running"
}

test_wedge_alarm_off_disables_active_alert_regardless_of_position() {
  local dir log directives
  dir=$(make_wedge_case wedge-off); log="$dir/alert.log"
  for directives in $'osascript\noff' $'off\nosascript'; do
    : > "$log"
    FM_WEDGE_ALARM_LOG="$log" FM_WEDGE_ALARM_CHANNEL="$directives" \
      wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
    [ ! -s "$log" ] || fail "off did not disable a preceding or following active alert: $(cat "$log")"
  done
  pass "off disables every active alert regardless of directive position (marker and tmux flash are unaffected)"
}

test_wedge_alarm_auto_darwin_selects_osascript() {
  local dir log
  dir=$(make_wedge_case wedge-auto-darwin); log="$dir/alert.log"
  PATH="$dir/fakebin:$PATH" FM_WEDGE_ALARM_LOG="$log" FM_FAKE_UNAME=Darwin FM_WEDGE_ALARM_CHANNEL=auto \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  grep -F 'osascript' "$log" >/dev/null || fail "auto did not resolve to osascript on Darwin: $(cat "$log")"
  pass "auto resolves to the macOS osascript notifier on Darwin (default-on)"
}

test_wedge_alarm_auto_non_darwin_has_no_os_channel() {
  local dir log
  dir=$(make_wedge_case wedge-auto-linux); log="$dir/alert.log"
  PATH="$dir/fakebin:$PATH" FM_WEDGE_ALARM_LOG="$log" FM_FAKE_UNAME=Linux FM_WEDGE_ALARM_CHANNEL=auto \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  [ ! -s "$log" ] || fail "auto selected a built-in OS channel on a non-macOS platform: $(cat "$log")"
  pass "auto on a non-macOS platform selects no built-in OS channel (the marker or a configured command carries it)"
}

test_wedge_alarm_config_file_multi_channel() {
  local dir cfgdir log
  dir=$(make_wedge_case wedge-config); log="$dir/alert.log"
  cfgdir="$dir/config"; mkdir -p "$cfgdir"
  printf '# active alert channels\n\nosascript\nherdr\n' > "$cfgdir/wedge-alarm"
  FM_WEDGE_ALARM_LOG="$log" FM_CONFIG_OVERRIDE="$cfgdir" \
    wedge_alarm_notify "away-mode WEDGED 700s" "/s/.marker"
  grep -F 'osascript' "$log" >/dev/null || fail "config/wedge-alarm osascript line was not selected"
  grep -F 'herdr' "$log" >/dev/null || fail "config/wedge-alarm herdr line was not selected"
  pass "config/wedge-alarm selects every configured channel and skips comment and blank lines"
}

test_wedge_alarm_failing_channel_degrades_gracefully() {
  local dir log rc
  dir=$(make_wedge_case wedge-degrade); log="$dir/alert.log"
  FM_WEDGE_ALARM_LOG="$log" FM_WEDGE_ALARM_FAIL=osascript \
    FM_WEDGE_ALARM_CHANNEL=$'osascript\nherdr' \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  rc=$?
  [ "$rc" -eq 0 ] || fail "a failing channel made wedge_alarm_notify return non-zero ($rc)"
  grep -F 'osascript' "$log" >/dev/null || fail "the failing osascript channel was not even attempted"
  grep -F 'herdr' "$log" >/dev/null || fail "a failing earlier channel prevented the herdr channel from firing"
  pass "a failing channel logs and falls back to the next channel, never crashing the alarm"
}

test_wedge_alarm_hung_channel_times_out_and_falls_through() {
  local dir daemon_log output channel start elapsed
  dir=$(make_wedge_case wedge-timeout); daemon_log="$dir/daemon.log"; output="$dir/fallback-output"
  channel="command: printf '%s' \"\$1\" > '$output'"
  start=$SECONDS
  LOG="$daemon_log" FM_WEDGE_ALARM_EXEC='' FM_WEDGE_ALARM_TIMEOUT_SECS=1 \
    FM_WEDGE_ALARM_CHANNEL=$'command:sleep 30\n'"$channel" \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt 5 ] || fail "a hung wedge notifier blocked the alarm for ${elapsed}s"
  grep -F 'command notifier timed out' "$daemon_log" >/dev/null \
    || fail "a hung wedge notifier did not log its timeout: $(cat "$daemon_log" 2>/dev/null)"
  [ "$(cat "$output" 2>/dev/null)" = "away-mode WEDGED 900s" ] \
    || fail "a timed-out command notifier prevented the next channel"
  pass "a hung notifier is bounded, logged, and falls through to the next channel"
}

test_wedge_alarm_backgrounded_command_times_out_and_reaps_descendant() {
  local dir daemon_log child_file child command
  dir=$(make_wedge_case wedge-backgrounded-timeout)
  daemon_log="$dir/daemon.log"
  child_file="$dir/notifier-child"
  command="sleep 30 & printf '%s' \"\$!\" > '$child_file'"
  LOG="$daemon_log" FM_WEDGE_ALARM_EXEC='' FM_WEDGE_ALARM_TIMEOUT_SECS=1 \
    wedge_alarm_via_command "$command" "away-mode WEDGED 900s"
  [ -s "$child_file" ] || fail "the backgrounded notifier did not record its descendant"
  child=$(cat "$child_file")
  grep -F 'command notifier timed out' "$daemon_log" >/dev/null \
    || fail "a backgrounded command notifier bypassed its timeout: $(cat "$daemon_log" 2>/dev/null)"
  if is_live_non_zombie "$child"; then
    kill -TERM "$child" 2>/dev/null || true
    fail "a timed-out command notifier left its descendant running (pid $child)"
  fi
  pass "a backgrounded command notifier remains bounded until its process group is reaped"
}

test_wedge_alarm_hung_override_times_out_and_falls_through() {
  local dir blocker daemon_log start elapsed
  dir=$(make_wedge_case wedge-override-timeout)
  blocker="$dir/blocker"; daemon_log="$dir/daemon.log"
  cat > "$blocker" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$blocker"
  start=$SECONDS
  LOG="$daemon_log" FM_WEDGE_ALARM_EXEC="$blocker" FM_WEDGE_ALARM_TIMEOUT_SECS=1 \
    FM_WEDGE_ALARM_CHANNEL=$'osascript\nherdr' \
    wedge_alarm_notify "away-mode WEDGED 900s" "/s/.marker"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt 6 ] || fail "a hung wedge notifier override blocked the alarm for ${elapsed}s"
  grep -F 'osascript notifier timed out' "$daemon_log" >/dev/null \
    || fail "a hung notifier override did not log its timeout: $(cat "$daemon_log" 2>/dev/null)"
  grep -F 'herdr notifier timed out' "$daemon_log" >/dev/null \
    || fail "a hung notifier override prevented the next channel: $(cat "$daemon_log" 2>/dev/null)"
  pass "a hung notifier override is bounded, logged, and proceeds to the next channel"
}

test_wedge_alarm_shutdown_stops_active_notifier_group() {
  local dir child_file pid child
  dir=$(make_wedge_case wedge-shutdown)
  child_file="$dir/notifier-child"
  (
    set -m
    sh -c 'sleep 30 & printf "%s" "$!" > "$1"; wait' sh "$child_file" &
    pid=$!
    while [ ! -s "$child_file" ]; do sleep 0.05; done
    child=$(cat "$child_file")
    WEDGE_ALARM_NOTIFIER_PID=$pid
    wedge_alarm_stop_active_notifier
    if kill -0 "$child" 2>/dev/null; then
      fail "shutdown left a notifier descendant running (pid $child)"
    fi
  ) || fail "notifier shutdown cleanup helper failed"
  pass "daemon shutdown stops and reaps the active notifier process group"
}

test_inject_wedge_alarm_fires_active_alert_on_non_tmux_backend() {
  # The whole incident: a non-tmux (herdr) primary gets NO tmux status-line
  # flash, so inject_wedge_alarm must still emit the backend-independent alert
  # alongside the durable marker.
  local dir state log
  dir=$(make_wedge_case wedge-integration); state="$dir/state"; log="$dir/alert.log"
  escalate_add "$state" "needs-decision: pick A"
  WEDGE_ALARM_LAST_EPOCH=0
  FM_WEDGE_ALARM_LOG="$log" FM_STATE_OVERRIDE="$state" \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_SUPERVISOR_BACKEND=herdr \
    inject_wedge_alarm "$state" 30600
  [ -s "$state/.subsuper-inject-wedged" ] || fail "inject_wedge_alarm did not write the durable marker"
  grep -F 'osascript' "$log" >/dev/null || fail "inject_wedge_alarm did not emit the active alert on a non-tmux backend: $(cat "$log")"
  grep -F 'WEDGED 30600s' "$log" >/dev/null || fail "active alert missing the age and summary"
  pass "inject_wedge_alarm writes the marker AND emits the active alert even with no tmux status-line (herdr backend)"
}

test_inject_wedge_alarm_throttles_when_marker_cannot_be_written() {
  local dir state log daemon_log alerts errors
  dir=$(make_wedge_case wedge-unwritable-marker)
  state="$dir/state"; log="$dir/alert.log"; daemon_log="$dir/daemon.log"
  escalate_add "$state" "needs-decision: pick A"
  chmod u-w "$state"
  WEDGE_ALARM_LAST_EPOCH=0
  LOG="$daemon_log" FM_WEDGE_ALARM_LOG="$log" FM_MAX_DEFER_SECS=600 \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_SUPERVISOR_BACKEND=herdr \
    inject_wedge_alarm "$state" 30600
  LOG="$daemon_log" FM_WEDGE_ALARM_LOG="$log" FM_MAX_DEFER_SECS=600 \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_SUPERVISOR_BACKEND=herdr \
    inject_wedge_alarm "$state" 30615
  chmod u+w "$state"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "wedge marker unexpectedly persisted in an unwritable state directory"
  alerts=$(grep -c 'osascript' "$log" 2>/dev/null || true)
  [ "$alerts" -eq 1 ] || fail "unwritable marker emitted $alerts active alerts instead of one"
  errors=$(grep -c 'ERROR: away-mode escalation undelivered' "$daemon_log" 2>/dev/null || true)
  [ "$errors" -eq 1 ] || fail "unwritable marker logged $errors wedge errors instead of one"
  pass "in-process wedge throttle prevents alert spam when the marker cannot persist"
}

test_fm_send_exits_nonzero_on_confirmed_swallow() {
  # fm-send.sh must exit NON-ZERO when a steer's Enter is positively swallowed
  # (text left in the composer), so firstmate learns the instruction did not land
  # — and exit ZERO on a clean submit.
  local dir fakebin err
  dir=$(make_bordered_case send-swallow)
  fakebin="$dir/fakebin"; err="$dir/send.err"
  # Clean submit -> exit 0.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_SEND_SLEEP=0.05 "$ROOT/bin/fm-send.sh" sess:win 'route this work' >/dev/null 2>"$err" \
    || fail "fm-send exited non-zero on a clean submit: $(cat "$err")"
  # Persistent swallow -> exit non-zero with a clear message.
  printf '│ > │\n' > "$dir/composer"
  touch "$dir/.swallow"
  if PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
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
  if PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_COMPOSER="$dir/composer" \
    FM_FAKE_SEND_FAIL=1 FM_SEND_SLEEP=0.05 \
    "$ROOT/bin/fm-send.sh" sess:win 'route this work' >/dev/null 2>"$err"; then
    fail "fm-send exited zero despite initial tmux send-keys failure"
  fi
  grep -F 'text not sent' "$err" >/dev/null || fail "fm-send did not explain initial send failure: $(cat "$err")"
  pass "fm-send exits non-zero when initial text send fails"
}

# --- herdr backend-awareness (fm-turnend-guard-h6-adjacent transport fix) ----
# Discovery, busy/pending dispatch, and the full inject_msg guard chain must
# work through the herdr backend, not just tmux. Env-var prefix assignments
# (e.g. `TMUX_PANE= HERDR_ENV=1 ... discover_supervisor_target`) neutralize
# whatever ambient TMUX_PANE/HERDR_ENV the CURRENT dev/CI shell happens to carry
# for the duration of that one call only, so these tests are deterministic
# regardless of what runtime backend is running this test suite itself.

test_discover_supervisor_backend_precedence() {
  local out
  out=$(FM_SUPERVISOR_BACKEND=herdr TMUX_PANE='%9' HERDR_ENV=1 HERDR_PANE_ID=w1:p1 discover_supervisor_backend)
  [ "$out" = herdr ] || fail "explicit FM_SUPERVISOR_BACKEND override was not honored: $out"

  out=$(FM_SUPERVISOR_BACKEND='' TMUX_PANE='%9' HERDR_ENV=1 HERDR_PANE_ID=w1:p1 discover_supervisor_backend)
  [ "$out" = tmux ] || fail "TMUX_PANE should win over HERDR_ENV (tmux nested in herdr resolves to tmux): $out"

  out=$(FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p1 discover_supervisor_backend)
  [ "$out" = herdr ] || fail "HERDR_ENV=1 with HERDR_PANE_ID present should resolve to herdr: $out"

  if out=$(FM_SUPERVISOR_BACKEND='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_backend); then
    fail "bare fallback (no override, no TMUX_PANE, no HERDR_ENV) should return non-zero"
  fi
  [ "$out" = tmux ] || fail "bare fallback should still print tmux: $out"

  pass "discover_supervisor_backend: override > TMUX_PANE > HERDR_ENV+HERDR_PANE_ID > tmux fallback"
}

test_discover_supervisor_target_herdr() {
  local out
  out=$(FM_SUPERVISOR_TARGET=explicit:target TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 discover_supervisor_target)
  [ "$out" = "explicit:target" ] || fail "explicit FM_SUPERVISOR_TARGET override was not honored: $out"

  out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='%3' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 discover_supervisor_target)
  [ "$out" = '%3' ] || fail "TMUX_PANE should win over herdr markers: $out"

  out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 HERDR_SESSION='' discover_supervisor_target)
  [ "$out" = "default:w1:p9" ] || fail "herdr target should default HERDR_SESSION to 'default': $out"

  out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV=1 HERDR_PANE_ID=w1:p9 HERDR_SESSION=iso1 discover_supervisor_target)
  [ "$out" = "iso1:w1:p9" ] || fail "herdr target should use an explicit HERDR_SESSION: $out"

  if out=$(FM_SUPERVISOR_TARGET='' TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' discover_supervisor_target); then
    fail "bare fallback should return non-zero"
  fi
  [ "$out" = "firstmate:0" ] || fail "bare fallback should still print firstmate:0: $out"

  pass "discover_supervisor_target: override > TMUX_PANE > herdr '<session>:<pane-id>' composition > firstmate:0 fallback"
}

test_pane_is_busy_herdr_native_busy_state() {
  (
    fm_backend_busy_state() { [ "$1" = herdr ] && [ "$2" = "default:w1:p2" ] || fail "unexpected busy_state args: $1 $2"; printf 'busy'; }
    fm_backend_capture() { fail "capture should not be consulted when busy_state is conclusive"; }
    pane_is_busy "default:w1:p2" herdr || fail "pane_is_busy should report busy from herdr's native busy_state"
  ) || fail "herdr native-busy pane_is_busy subshell failed"
  pass "pane_is_busy: herdr native busy_state='busy' short-circuits without a capture fallback"
}

test_pane_is_busy_herdr_falls_back_to_capture_regex() {
  (
    fm_backend_busy_state() { printf 'unknown'; }
    fm_backend_capture() { [ "$1" = herdr ] && [ "$2" = "default:w1:p2" ] || fail "unexpected capture args: $1 $2"; printf 'esc to interrupt\n'; }
    pane_is_busy "default:w1:p2" herdr || fail "pane_is_busy should fall back to the regex-over-capture reader when busy_state is unknown"
  ) || fail "herdr capture-fallback pane_is_busy subshell failed"
  pass "pane_is_busy: herdr falls back to the shared regex-over-capture reader when native busy_state is unknown"
}

test_pane_is_busy_herdr_idle_falls_back_to_capture_regex() {
  (
    fm_backend_busy_state() { printf 'idle'; }
    fm_backend_capture() { [ "$1" = herdr ] && [ "$2" = "default:w1:p2" ] || fail "unexpected capture args: $1 $2"; printf 'esc to interrupt\n'; }
    pane_is_busy "default:w1:p2" herdr || fail "pane_is_busy should fall back to the regex-over-capture reader when busy_state is idle"
  ) || fail "herdr idle capture-fallback pane_is_busy subshell failed"
  pass "pane_is_busy: herdr corroborates native idle with the shared regex-over-capture reader"
}

test_pane_is_busy_defaults_to_tmux_when_backend_omitted() {
  local dir fakebin capture
  dir=$(make_supercase busy-default-backend)
  fakebin="$dir/fakebin"; capture="$dir/pane.txt"
  printf 'esc to interrupt\n' > "$capture"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" pane_is_busy "fakepane" \
    || fail "pane_is_busy with no backend arg should still default to tmux"
  pass "pane_is_busy: omitted backend arg defaults to tmux (pre-existing callers unaffected)"
}

test_pane_input_pending_herdr_dispatch() {
  (
    fm_backend_composer_state() { [ "$1" = herdr ] && [ "$2" = "default:w1:p2" ] || fail "unexpected composer_state args: $1 $2"; printf 'pending'; }
    pane_input_pending "default:w1:p2" herdr || fail "pane_input_pending should report pending from herdr composer_state"
  ) || fail "herdr pane_input_pending (pending case) subshell failed"
  (
    fm_backend_composer_state() { printf 'empty'; }
    if pane_input_pending "default:w1:p2" herdr; then
      fail "pane_input_pending should report not-pending for an empty herdr composer"
    fi
  ) || fail "herdr pane_input_pending (empty case) subshell failed"
  pass "pane_input_pending: dispatches through fm_backend_composer_state for backend=herdr"
}

test_inject_msg_herdr_busy_guard_defers() {
  local dir state
  dir=$(make_supercase inject-herdr-busy)
  state="$dir/state"
  afk_enter "$state"
  (
    fm_backend_target_exists() { [ "$1" = herdr ] && [ "$2" = "default:w1:p2" ] || fail "unexpected target_exists args: $1 $2"; return 0; }
    fm_backend_busy_state() { printf 'busy'; }
    fm_backend_capture() { fail "capture should not run when busy_state is conclusive"; }
    fm_backend_composer_state() { fail "composer_state should not be consulted once the busy-guard already deferred"; }
    fm_backend_send_text_submit() { fail "send_text_submit should not run when the busy-guard defers"; }
    if FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="default:w1:p2" inject_msg "hello" "$state"; then
      fail "inject_msg should defer (return non-zero) when the herdr supervisor pane is busy"
    fi
  ) || fail "herdr busy-guard inject_msg subshell failed"
  pass "inject_msg: herdr busy-guard defers before ever attempting a submit"
}

test_inject_msg_herdr_composer_guard_defers() {
  local dir state
  dir=$(make_supercase inject-herdr-pending)
  state="$dir/state"
  afk_enter "$state"
  (
    fm_backend_target_exists() { return 0; }
    fm_backend_busy_state() { printf 'idle'; }
    fm_backend_capture() { printf 'idle prompt\n'; }
    fm_backend_composer_state() { [ "$1" = herdr ] && [ "$2" = "default:w1:p2" ] || fail "unexpected composer_state args: $1 $2"; printf 'pending'; }
    fm_backend_send_text_submit() { fail "send_text_submit should not run when the composer-guard defers"; }
    if FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="default:w1:p2" inject_msg "hello" "$state"; then
      fail "inject_msg should defer when the herdr composer has pending input"
    fi
  ) || fail "herdr composer-guard inject_msg subshell failed"
  pass "inject_msg: herdr composer-guard defers before ever attempting a submit"
}

test_inject_msg_herdr_pane_gone_defers() {
  local dir state
  dir=$(make_supercase inject-herdr-gone)
  state="$dir/state"
  afk_enter "$state"
  (
    fm_backend_target_exists() { return 1; }
    fm_backend_busy_state() { fail "busy_state should not be consulted once the pane-exists check already failed"; }
    fm_backend_send_text_submit() { fail "send_text_submit should not run when the pane does not exist"; }
    if FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="default:w1:gone" inject_msg "hello" "$state"; then
      fail "inject_msg should defer when the herdr target does not exist"
    fi
  ) || fail "herdr pane-gone inject_msg subshell failed"
  pass "inject_msg: herdr pane-gone check defers before any busy/composer/submit call"
}

test_inject_msg_herdr_submits_through_backend_dispatch() {
  local dir state
  dir=$(make_supercase inject-herdr-submit)
  state="$dir/state"
  afk_enter "$state"
  (
    fm_backend_target_exists() { return 0; }
    fm_backend_busy_state() { printf 'idle'; }
    fm_backend_capture() { printf 'idle prompt\n'; }
    fm_backend_composer_state() { printf 'empty'; }
    fm_backend_send_text_submit() {
      [ "$1" = herdr ] && [ "$2" = "default:w1:p2" ] || fail "unexpected send_text_submit args: $1 $2"
      case "$3" in *"hello"*) : ;; *) fail "digest text missing from send_text_submit: $3" ;; esac
      printf 'empty'
    }
    FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="default:w1:p2" inject_msg "hello" "$state" \
      || fail "inject_msg should succeed when send_text_submit confirms empty"
  ) || fail "herdr successful-submit inject_msg subshell failed"
  pass "inject_msg: dispatches busy-guard/composer-guard/submit through the herdr backend and succeeds on a confirmed empty composer"
}

# Safety-critical (task fm-composer-shellglyph-safety): the away-mode injector
# must NEVER type an escalation into a dead-shell pane. A bare shell prompt
# classifies `unknown` (not `pending`), and inject_msg now defers on anything
# that is not affirmatively `empty`, so a dead shell (or an unreadable pane) can
# never be mistaken for a safe empty agent composer and typed into.
test_inject_msg_defers_on_dead_shell_unknown() {
  local dir state
  dir=$(make_supercase inject-dead-shell)
  state="$dir/state"
  afk_enter "$state"
  (
    fm_backend_target_exists() { return 0; }
    fm_backend_busy_state() { printf 'idle'; }
    fm_backend_capture() { printf '$ \n'; }
    fm_backend_composer_state() { printf 'unknown'; }
    fm_backend_send_text_submit() { fail "send_text_submit must NOT run when the composer is a dead shell (unknown)"; }
    if FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="default:w1:p2" inject_msg "hello" "$state"; then
      fail "inject_msg should defer (never inject) when the composer reads unknown (dead shell / unreadable)"
    fi
  ) || fail "dead-shell inject_msg subshell failed"
  pass "inject_msg: defers on a dead-shell/unreadable composer (unknown), never typing the escalation into a shell"
}

test_afk_start_refuses_when_flag_cannot_be_written
test_afk_start_ignores_stale_pidfile_without_lock
test_afk_start_reclaims_stale_daemon_lock_reused_pid
test_daemon_state_root_uses_fm_home
test_classify_routine_signal_self
test_classify_terminal_signal_escalates
test_classify_check_and_unknown_escalate
test_stale_transient_self_records_marker
test_stale_terminal_escalates
test_stale_paused_classifies_pause
test_handle_wake_paused_records_pause_marker
test_handle_wake_paused_signal_records_pause_marker
test_handle_wake_terminal_signal_clears_pause_tracking
test_housekeeping_migrates_watcher_pause_marker
test_housekeeping_migrates_watcher_unpaused_marker_to_clear
test_housekeeping_seeds_pause_marker_from_status
test_housekeeping_persistent_stale_escalates
test_housekeeping_resumed_stale_cleared
test_housekeeping_paused_resurfaces_and_resets
test_housekeeping_paused_resumed_cleared
test_housekeeping_paused_unpaused_cleared
test_housekeeping_stale_marker_transitions_to_pause
test_housekeeping_pause_marker_transitions_to_clear
test_housekeeping_herdr_persistent_stale_resolves_meta
test_housekeeping_herdr_idle_busy_footer_clears_stale
test_housekeeping_herdr_resumed_stale_cleared
test_housekeeping_orca_persistent_stale_resolves_terminal
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
test_tmux_composer_state_bare_shell_is_unknown
test_tmux_composer_state_bordered_and_agent_rows_are_empty
test_tmux_composer_state_requires_matching_box_borders
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
test_wedge_alarm_library_mode_defaults_to_discard
test_wake_helpers_replace_inherited_notifier_override
test_wedge_alarm_discard_seam_fires_nothing
test_wedge_alarm_direct_notifiers_honor_discard_seam
test_wedge_alarm_osascript_channel_selected
test_wedge_alarm_herdr_channel_selected
test_wedge_alarm_command_channel_receives_summary
test_wedge_alarm_command_failure_hides_configured_command
test_wedge_alarm_unknown_channel_hides_configured_directive
test_wedge_alarm_off_disables_active_alert_regardless_of_position
test_wedge_alarm_auto_darwin_selects_osascript
test_wedge_alarm_auto_non_darwin_has_no_os_channel
test_wedge_alarm_config_file_multi_channel
test_wedge_alarm_failing_channel_degrades_gracefully
test_wedge_alarm_hung_channel_times_out_and_falls_through
test_wedge_alarm_backgrounded_command_times_out_and_reaps_descendant
test_wedge_alarm_hung_override_times_out_and_falls_through
test_wedge_alarm_shutdown_stops_active_notifier_group
test_inject_wedge_alarm_fires_active_alert_on_non_tmux_backend
test_inject_wedge_alarm_throttles_when_marker_cannot_be_written
test_fm_send_exits_nonzero_on_confirmed_swallow
test_fm_send_exits_nonzero_on_initial_send_failure
test_discover_supervisor_backend_precedence
test_discover_supervisor_target_herdr
test_pane_is_busy_herdr_native_busy_state
test_pane_is_busy_herdr_falls_back_to_capture_regex
test_pane_is_busy_herdr_idle_falls_back_to_capture_regex
test_pane_is_busy_defaults_to_tmux_when_backend_omitted
test_pane_input_pending_herdr_dispatch
test_inject_msg_herdr_busy_guard_defers
test_inject_msg_herdr_composer_guard_defers
test_inject_msg_herdr_pane_gone_defers
test_inject_msg_herdr_submits_through_backend_dispatch
test_inject_msg_defers_on_dead_shell_unknown
