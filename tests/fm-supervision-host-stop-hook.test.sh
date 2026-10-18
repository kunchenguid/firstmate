#!/usr/bin/env bash
# Behavior tests for the supervision host (bin/fm-supervision-host.sh,
# docs/supervision-host.md): the Claude re-arm owner around the host, where the
# real Stop hook (bin/fm-claude-stop-autoarm.sh) runs the real host.
# tests/supervision-host-helpers.sh owns the shared fixture these cases drive.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

# --- the Claude re-arm owner around the host ----------------------------------

# A fixture home that is also a genuine primary checkout whose bin is this
# repo's, so the real Claude Stop hook (bin/fm-claude-stop-autoarm.sh) runs the
# real host in it.
make_primary_home() {  # <name>
  local home
  home=$(make_home "$1" attended)
  git init -q "$home"
  : > "$home/AGENTS.md"
  ln -s "$ROOT/bin" "$home/bin"
  printf '%s\n' "$home"
}

# One Claude main session under the fake harness. Each turn_end fires the real
# Stop hook as the tracked asyncRewake registration does, and records its exit
# status and stderr (the rewake banner Claude delivers on exit 2).
start_hook_session() {  # <home>
  local home=$1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" \
    PATH="$home/fakebin:$PATH" "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      for seed in "$FM_HOME"/mirror-seed.*; do
        [ -f "$seed" ] || continue
        "$FM_HOME/bin/fm-host-mirror.sh" hook claude < "$seed"
      done
      while [ ! -e "$FM_HOME/session.stop" ]; do
        if [ -e "$FM_HOME/stop.go" ]; then
          rm -f "$FM_HOME/stop.go"
          if [ -e "$FM_HOME/hook.own-group" ]; then
            # Claude owns the hook as a process group of its own and tears the
            # whole group down once the hook has exited.
            printf "{\"session_id\":\"sess-host-hook\",\"stop_hook_active\":false}\n" > "$FM_HOME/hook.stdin"
            set -m
            "$FM_HOME/bin/fm-claude-stop-autoarm.sh" < "$FM_HOME/hook.stdin" > "$FM_HOME/hook.out" 2> "$FM_HOME/hook.err" &
            printf "%s\n" "$!" > "$FM_HOME/hook.pgid"
            wait "$!"
            printf "%s\n" "$?" > "$FM_HOME/hook.rc"
            set +m
          else
            printf "{\"session_id\":\"sess-host-hook\",\"stop_hook_active\":false}\n" \
              | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$FM_HOME/hook.out" 2> "$FM_HOME/hook.err"
            printf "%s\n" "$?" > "$FM_HOME/hook.rc"
          fi
        fi
        sleep 0.1
      done
    ' 2>> "$home/claude.err" &
}
turn_end() { rm -f "$1/hook.rc"; : > "$1/stop.go"; }
hook_exited() { [ -s "$1/hook.rc" ]; }

# Main's rewoken turn drains; the caller runs the printed acknowledgement
# (MAIN_ACK) when that turn's handling is done.
main_drain() {  # <home>; prints the drain and sets MAIN_ACK
  local out
  out=$(FM_HOME="$1" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  MAIN_ACK=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
  printf '%s\n' "$out"
}

assert_rewoke_main() {  # <home> <label>
  expect_code 2 "$(cat "$1/hook.rc")" "$2: the Stop hook must rewake main: $(cat "$1/hook.err"; cat "$1/state/.watcher-down" 2>/dev/null)"
  assert_grep 'firstmate watcher wake - one supervision event needs a handling turn now.' "$1/hook.err" "$2: the rewake banner is missing"
  assert_re '^epoch=[0-9]+ owner_pid=[0-9]+ outcome=rewake ' "$1/state/.claude-autoarm-epoch" "$2: the auto-arm ledger must record the rewake"
}

# The live failure (2026-09-27): a main-only pass-through confirmed a handling
# handoff before the close reached main's re-arm owner, so the Stop hook's
# rewake commit refused and it exited 0 in silence. An idle primary was never
# woken, and the detached successor's own later close reached no reader.
test_claude_stop_hook_delivers_a_main_only_pass_through() {
  local home
  home=$(make_primary_home hook-main-only)
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "hook main-only: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "hook main-only: the Stop hook never closed: $(cat "$home/state/.supervision-host.log")"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "fixture: the close was not a main-only pass-through"
  assert_rewoke_main "$home" "hook main-only"
  assert_re '^signal: .*demo.status' "$home/hook.err" "the rewake must carry the close"
  watcher_live "$home" || fail "hook main-only: the pass-through left no successor watcher"
  pass "host+hook: an attended main-only pass-through rewakes main and keeps its successor watcher"
}

# Close the confirmed handling watcher after the engine has acknowledged its
# wake but before its captain outcome returns to the host.
test_claude_stop_hook_restores_handoff_when_successor_closed_before_exit_to_main() {
  local home
  home=$(make_primary_home hook-successor-closed-before-return)
  ln -s "$ROOT/.agents" "$home/.agents"
  echo captain-close-before-return > "$home/stub-mode"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "closed successor: the Stop hook never started a watcher cycle"
  append_status "$home" 'first actionable wake'
  wait_until 250 hook_exited "$home" || fail "closed successor: the Stop hook did not finish: $(cat "$home/state/.supervision-host.log")"
  assert_re '^supervision-host: branch-outcome: ' "$home/hook.err" "the host must hand its captain outcome to main"
  expect_code 2 "$(cat "$home/hook.rc")" "the Stop hook must rewake main after the successor closed"
  assert_re '^(pending|announced):downtime:' "$home/state/.watcher-down" \
    "the closed handling successor must leave a deliverable downtime episode"
  pass "host+hook: a successor closed before exit_to_main does not suppress the branch-outcome rewake"
}

assert_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails() {
  local status=$1 home real_mktemp successor
  home=$(make_primary_home "hook-successor-restore-fails-$status")
  ln -s "$ROOT/.agents" "$home/.agents"
  echo captain-held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  real_mktemp=$(command -v mktemp)
  cat > "$home/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'/.watcher-down.tmp.'*) [ ! -e "\$FM_HOME/fail-downtime-write" ] || exit 1 ;;
esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$home/fakebin/mktemp"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "restore failure: the Stop hook never started a watcher cycle"
  append_status "$home" 'first actionable wake'
  wait_until 250 test -s "$home/stub-ready" || fail "restore failure: the engine did not reach its hold"
  successor=$(cat "$home/state/.watch.lock/pid")
  append_status "$home" 'wake while the engine is handling'
  wait_until 250 bash -c '! kill -0 "$1" 2>/dev/null' _ "$successor" \
    || fail "restore failure: its watcher did not close during the engine turn"
  FM_HOME="$home" bash -c '. "$1"; fm_recovery_marker_begin_handling "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/.watcher-down" \
    || fail "fixture: could not model the queued successor wake entering handling"
  if [ "$status" = announced ]; then
    FM_HOME="$home" bash -c '. "$1"; fm_recovery_marker_read "$2" && _fm_recovery_marker_write_locked "$2" handling "${FM_RECOVERY_MARKER_TOKEN##*:}" announced' _ \
      "$ROOT/bin/fm-wake-lib.sh" "$home/state/.watcher-down" \
      || fail "fixture: could not model the handling episode as announced"
  fi
  assert_re "^$status:handling:" "$home/state/.watcher-down" \
    "fixture: the closed handling successor must leave the marker in handling before the host hands back"
  : > "$home/fail-downtime-write"
  printf 'continue\n' > "$home/stub-release"
  wait_until 250 hook_exited "$home" || fail "restore failure: the Stop hook did not finish"
  expect_code 2 "$(cat "$home/hook.rc")" "the Stop hook must notify main when neither hand-back nor downtime restoration commits"
  assert_grep 'firstmate watcher auto-arm FAILED' "$home/hook.err" "the refused rewake must turn into a delivered failure notice"
  assert_re '^epoch=[0-9]+ owner_pid=[0-9]+ outcome=failed ' "$home/state/.claude-autoarm-epoch" \
    "the failed hand-back must be committed"
}

test_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails() {
  assert_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails pending
  pass "host+hook: a refused hand-back becomes a delivered failure notice"
}

test_claude_stop_hook_notifies_when_closed_announced_successor_downtime_restore_fails() {
  assert_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails announced
  pass "host+hook: a refused hand-back on an announced handling marker becomes a delivered failure notice"
}

test_claude_stop_hook_restores_handoff_when_successor_closed_mid_engine_turn() {
  local home successor
  home=$(make_primary_home hook-successor-closed-before-outcome)
  ln -s "$ROOT/.agents" "$home/.agents"
  echo captain-held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "closed successor: the Stop hook never started a watcher cycle"
  append_status "$home" 'first actionable wake'
  wait_until 250 test -s "$home/stub-ready" || fail "closed successor: the engine did not reach its hold: hook=$(cat "$home/hook.err" 2>/dev/null) host=$(cat "$home/state/.supervision-host.log" 2>/dev/null) mode=$(cat "$home/stub-mode" 2>/dev/null) engine=$(find "$home" -maxdepth 1 -name 'engine-call.*' -exec sh -c 'cat "$1"' _ {} \; 2>/dev/null) errors=$(cat "$home"/engine-errors.* 2>/dev/null)"
  successor=$(cat "$home/state/.watch.lock/pid")
  append_status "$home" 'wake while the engine is handling'
  wait_until 250 bash -c '! kill -0 "$1" 2>/dev/null' _ "$successor" \
    || fail "closed successor: its watcher did not close during the engine turn"
  FM_HOME="$home" bash -c '. "$1"; fm_recovery_marker_begin_handling "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/.watcher-down" \
    || fail "fixture: could not model the queued successor wake entering handling"
  assert_re '^pending:handling:' "$home/state/.watcher-down" \
    "fixture: the closed handling successor must leave the marker in handling before the host hands back"
  printf 'continue\n' > "$home/stub-release"
  wait_until 250 hook_exited "$home" || fail "closed successor: the Stop hook did not finish: $(cat "$home/state/.supervision-host.log")"
  assert_re '^supervision-host: branch-outcome: ' "$home/hook.err" "the host must hand its captain outcome to main"
  expect_code 2 "$(cat "$home/hook.rc")" "the Stop hook must rewake main after the successor closed"
  assert_re '^epoch=[0-9]+ owner_pid=[0-9]+ outcome=rewake ' "$home/state/.claude-autoarm-epoch" \
    "the hand-back must commit the rewake"
  assert_re '^(pending|announced):downtime:' "$home/state/.watcher-down" \
    "the closed handling successor must leave a deliverable downtime episode"
  pass "host+hook: a successor that closes during a held engine turn does not suppress the branch-outcome rewake"
}

# The live repro (2026-09-28): a quiet record live with no daemon flag parked a
# present Claude captain, whose worker's captain outcomes waited for a return.
# Through the real Stop hook the outcome now rewakes main, with no away note.
test_claude_stop_hook_rewakes_a_present_captain_beside_a_quiet_record() {
  local home drained
  home=$(make_primary_home hook-quiet-record)
  # This case runs an engine turn from the primary root, whose prompt reads the skills.
  ln -s "$ROOT/.agents" "$home/.agents"
  FM_HOME="$home" FM_AFK_MODE=quiet "$CONTRACT" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  echo captain > "$home/stub-mode"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "hook quiet: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'ready for review'
  wait_until 250 hook_exited "$home" || fail "hook quiet: the Stop hook never closed: $(cat "$home/state/.supervision-host.log")"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "a quiet record must leave the host's turn attended"
  assert_rewoke_main "$home" "hook quiet"
  assert_re '^supervision-host: branch-outcome: ' "$home/hook.err" "the rewake must carry the captain outcome"
  assert_no_grep 'not a return' "$home/hook.err" "a present captain's rewake must not call itself away-posture supervision"
  drained=$(main_drain "$home")
  assert_contains "$drained" " ago] demo: stub escalated: " "main's drain must present the captain outcome beside a quiet record"
  pass "host+hook: a captain outcome beside a quiet record rewakes the present captain with no away note"
}

# Default-on for Claude (docs/configuration.md "Supervision host"): through the
# real Stop hook and mirror writer, a Claude primary home with no
# config/supervision-host runs the host at the default engine, mirrors the
# captain's dialog, and keeps a routine attended wake off main; a home with
# config/supervision-host-off runs the plain watcher arm, mirrors nothing, and every wake
# reaches main as the arm printed it.
test_claude_stop_hook_runs_the_host_without_the_file_and_off_opts_out() {
  local home first
  home=$(make_primary_home hook-default-on)
  ln -s "$ROOT/.agents" "$home/.agents"
  rm -f "$home/config/supervision-host"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "default-on: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  assert_grep 'watch the fleet for me' "$home/state/.host-mirror.jsonl" "a Claude home without the file must mirror the captain's dialog"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "default-on: the wake was not handled on the engine: $(cat "$home/hook.err" 2>/dev/null; cat "$home/state/.supervision-host.log" 2>/dev/null)"
  first="$home/engine-call.1"
  assert_re '^arg=sonnet$' "$first" "a Claude home without the file must run the Claude engine at its default model"
  assert_re '^primary=claude$' "$first" "the engine must carry the Claude primary pin"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "the ledger must record the attended turn"
  [ ! -s "$home/hook.rc" ] || fail "a routine attended wake on a Claude home without the file reached main: $(cat "$home/hook.err")"
  watcher_live "$home" || fail "default-on: the host is not parked on a live successor"
  : > "$home/session.stop"
  stop_home_processes "$home"

  home=$(make_primary_home hook-opted-out)
  : > "$home/config/supervision-host-off"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "off: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until 250 hook_exited "$home" || fail "off: the Stop hook never closed"
  assert_rewoke_main "$home" "off"
  assert_re '^signal: .*demo.status' "$home/hook.err" "off: the rewake must carry the arm's close"
  assert_no_re '^supervision-host' "$home/hook.err" "off: the close must reach main exactly as the arm printed it"
  assert_absent "$home/state/.supervision-host.log" "a home opted out by config/supervision-host-off must never run the host"
  assert_absent "$home/state/.host-mirror.jsonl" "a home opted out by config/supervision-host-off must mirror nothing"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "a home opted out by config/supervision-host-off ran an engine turn"
  : > "$home/session.stop"
  stop_home_processes "$home"
  pass "host+hook: a Claude home without config/supervision-host runs the host at the default engine, and an off file restores the plain arm"
}

test_claude_stop_hook_delivers_a_close_that_turns_main_only_at_its_turn() {
  local home
  home=$(make_primary_home hook-turns-main-only)
  turn_main_only_at_second_offer "$home"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "hook turns-main-only: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until 250 hook_exited "$home" || fail "hook turns-main-only: the Stop hook never closed: $(cat "$home/state/.supervision-host.log")"
  [ "$(cat "$home/offer-count" 2>/dev/null)" -ge 2 ] || fail "fixture: the close was not accepted before it turned main-only"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "hook turns-main-only: the engine ran on a stale offer"
  assert_rewoke_main "$home" "hook turns-main-only"
  watcher_live "$home" || fail "hook turns-main-only: the pass-through left no successor watcher"
  pass "host+hook: a close that turns main-only at its turn rewakes main and keeps its successor watcher"
}

# The successor a close that turns main-only at its turn leaves for main
# outlives the Stop hook's process group teardown, like the pass-through's.
test_successor_left_at_the_turn_survives_the_hook_process_group_teardown() {
  local home watcher
  home=$(make_primary_home hook-turns-main-only-teardown)
  turn_main_only_at_second_offer "$home" quiet
  : > "$home/hook.own-group"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "at-turn teardown: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until 250 hook_exited "$home" || fail "at-turn teardown: the Stop hook never closed: $(cat "$home/state/.supervision-host.log")"
  [ "$(cat "$home/offer-count" 2>/dev/null)" -ge 2 ] || fail "fixture: the close was not accepted before it turned main-only"
  assert_rewoke_main "$home" "at-turn teardown"
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM -- "-$(cat "$home/hook.pgid")" 2>/dev/null || true
  sleep 2
  kill -0 "$watcher" 2>/dev/null || fail "at-turn teardown: the successor watcher (pid $watcher) did not survive the hook's process group teardown"
  stop_home_processes "$home"
  pass "host+hook: the successor a close that turns main-only at its turn leaves for main survives the hook's process group teardown"
}

# If the at-turn hand-back cannot publish downtime, the healthy successor
# cannot turn that undelivered close into a silent Stop-hook success.
test_claude_stop_hook_notifies_when_at_turn_downtime_write_fails() {
  local home real_mktemp
  home=$(make_primary_home hook-turns-main-only-write-fails)
  turn_main_only_at_second_offer "$home"
  real_mktemp=$(command -v mktemp)
  cat > "$home/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'/state/.watcher-down.tmp.'*)
    [ "\$(cat "\$FM_HOME/offer-count" 2>/dev/null)" != 2 ] || exit 1 ;;
esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$home/fakebin/mktemp"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "hook write failure: no watcher started"
  append_status "$home" 'step one'
  wait_until 250 hook_exited "$home" || fail "hook write failure: the Stop hook did not finish"
  [ "$(cat "$home/offer-count" 2>/dev/null)" -ge 2 ] || fail "fixture: the close did not turn main-only at its turn"
  assert_re 'pass-through[[:space:]]+downtime-unrestored' "$home/state/.supervision-host.log" "fixture: downtime publication did not fail"
  assert_re '^(pending|announced):handling:' "$home/state/.watcher-down" "fixture: the marker unexpectedly became downtime"
  expect_code 2 "$(cat "$home/hook.rc")" "the Stop hook must notify main instead of dropping the close"
  assert_grep 'firstmate watcher auto-arm FAILED' "$home/hook.err" "main must receive the failure notification"
  assert_re 'outcome=failed ' "$home/state/.claude-autoarm-epoch" "the failure must be committed"
  pass "host+hook: failed at-turn downtime write notifies main despite a healthy successor"
}

# The successor a pass-through leaves closes while main's rewoken turn is still
# running, so no arm is attached to read it: the next turn end must still
# deliver that close instead of stranding it in the queue.
test_successor_close_during_main_turn_is_delivered_at_the_next_turn_end() {
  local home successor drained
  home=$(make_primary_home hook-successor-close)
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "successor close: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "successor close: the first close never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
  assert_rewoke_main "$home" "successor close (first)"
  successor=$(cat "$home/state/.watch.lock/pid")
  main_drain "$home" >/dev/null
  append_status "$home" 'which region?' needs-decision
  wait_until 250 bash -c '! kill -0 "$1" 2>/dev/null' _ "$successor" || fail "fixture: the successor did not close on the later decision"
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  [ -z "$MAIN_ACK" ] || FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@" >/dev/null 2>&1' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK \
    || fail "successor close: main's acknowledgement failed: $MAIN_ACK"
  turn_end "$home"
  wait_until 250 hook_exited "$home" || fail "successor close: the next turn end never closed: $(cat "$home/state/.supervision-host.log")"
  assert_rewoke_main "$home" "successor close (next turn end)"
  drained=$(main_drain "$home")
  assert_contains "$drained" 'which region?' "the successor's close must reach main's drain"
  watcher_live "$home" || fail "successor close: the next turn end left no watcher"
  pass "host+hook: a successor close that lands during main's turn is delivered at the next turn end"
}

# The live loop (2026-10-07): the successor a main-only pass-through leaves
# for main shared the Stop hook's process group, so Claude's teardown of that
# group after the exit-2 rewake stopped it mid-turn. The stop published
# downtime, and the next park's first cycle announced an empty
# "check: rearm-resurface" that woke main again, over and over. The successor
# must outlive that teardown, so the next park takes it over quietly.
test_pass_through_successor_survives_the_hook_process_group_teardown() {
  local home pgid watcher
  home=$(make_primary_home hook-group-teardown)
  : > "$home/hook.own-group"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "group teardown: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "group teardown: the decision close never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "fixture: the close was not a main-only pass-through"
  assert_rewoke_main "$home" "group teardown (pass-through)"
  watcher=$(cat "$home/state/.watch.lock/pid")
  pgid=$(cat "$home/hook.pgid")
  kill -TERM -- "-$pgid" 2>/dev/null || true
  sleep 2
  kill -0 "$watcher" 2>/dev/null || fail "group teardown: the successor watcher (pid $watcher) did not survive the hook's process group teardown"
  [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" = "$watcher" ] || fail "group teardown: the watcher lock moved"
  stop_home_processes "$home"
  pass "host+hook: the successor a pass-through leaves for main survives the hook's process group teardown"
}

# The arm processes running from <home>'s bin, one "<pid> <ppid>" per line.
# A command substitution inside an arm is a forked copy that shows the same
# command line, so a process whose parent is itself an arm is not counted.
home_arms() {  # <home>
  ps -A -o pid= -o ppid= -o command= 2>/dev/null \
    | awk -v arm="$1/bin/fm-watch-arm.sh" '
        $3 ~ /(^|\/)bash$/ && $4 == arm { ppid[$1] = $2; order[++n] = $1 }
        END { for (i = 1; i <= n; i++) if (!(ppid[order[i]] in ppid)) print order[i], ppid[order[i]] }'
}
parent_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }

# True once the park's own arm owns the home's only watcher cycle: exactly one
# arm runs from the home, it is the host's child, and it is the watcher's parent.
host_owns_the_only_cycle() {  # <home>
  local home=$1 host watcher arm arms
  host=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host" 2>/dev/null)
  watcher=$(cat "$home/state/.watch.lock/pid" 2>/dev/null)
  [ -n "$host" ] && [ -n "$watcher" ] && kill -0 "$watcher" 2>/dev/null || return 1
  arms=$(home_arms "$home")
  [ "$(printf '%s\n' "$arms" | grep -c .)" -eq 1 ] || return 1
  arm=$(parent_of "$watcher")
  [ "$arms" = "$arm $host" ]
}

# The live leak (2026-10-01): a main-only pass-through leaves its successor
# cycle running through main's handling turn, and the next park - here a
# restarted session's first turn end - attached to that cycle instead of
# owning it. The successor arm, orphaned by its host's exit, kept owning the
# watcher while the new park's arm polled it until the park boundary, hours
# later. The next park now takes that cycle over: one arm, the host's own
# child, owns the watcher, nothing reaches main for the takeover, no downtime
# episode is opened, and the cycle it owns still delivers the next close.
# A main-only pass-through in <home> leaves its successor cycle running, main
# handles and acknowledges the close, and the session restarts. Sets
# LEFT_WATCHER and LEFT_ARM to the successor watcher and the arm that owns it.
LEFT_WATCHER=
LEFT_ARM=
leave_a_cycle_for_main_and_restart() {  # <home>
  local home=$1 first_session
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "takeover: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "takeover: the decision close never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "fixture: the close was not a main-only pass-through"
  assert_rewoke_main "$home" "takeover (pass-through)"
  LEFT_WATCHER=$(cat "$home/state/.watch.lock/pid")
  LEFT_ARM=$(parent_of "$LEFT_WATCHER")
  [ -n "$LEFT_ARM" ] && [ "$LEFT_ARM" != 1 ] || fail "fixture: the successor watcher has no arm of its own"
  main_drain "$home" >/dev/null
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  [ -z "$MAIN_ACK" ] || FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@" >/dev/null 2>&1' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK \
    || fail "takeover: main's acknowledgement failed: $MAIN_ACK"
  # The session restarts: the old one ends, and a new one holds the lock.
  first_session=$(tail -n 1 "$home/claude-pids")
  : > "$home/session.stop"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$first_session" || fail "fixture: the first session did not end"
  rm -f "$home/session.stop"
  kill -0 "$LEFT_ARM" 2>/dev/null || fail "fixture: the successor arm did not outlive its session"
  start_hook_session "$home"
}

test_next_park_takes_over_the_cycle_a_pass_through_left_for_main() {
  local home left_watcher left_arm
  home=$(make_primary_home hook-takeover)
  leave_a_cycle_for_main_and_restart "$home"
  left_watcher=$LEFT_WATCHER
  left_arm=$LEFT_ARM
  turn_end "$home"
  wait_until 150 host_owns_the_only_cycle "$home" \
    || fail "takeover: the next park did not own the home's only watcher cycle (left arm $left_arm, watcher $left_watcher):"$'\n'"$(home_arms "$home")"$'\n'"$(cat "$home/state/.supervision-host.log")"
  ! kill -0 "$left_arm" 2>/dev/null || fail "takeover: the successor arm a pass-through left still runs (pid $left_arm)"
  ! kill -0 "$left_watcher" 2>/dev/null || fail "takeover: the successor watcher still runs (pid $left_watcher)"
  sleep 2
  ! hook_exited "$home" || fail "takeover: the takeover woke main: $(cat "$home/hook.err")"
  host_owns_the_only_cycle "$home" || fail "takeover: the park did not keep the cycle it took over"
  assert_re '^acked:' "$home/state/.watcher-down" "takeover: the takeover opened a downtime episode"
  assert_no_re 'rearm-resurface' "$home/state/.supervision-host.log" "takeover: the takeover resurfaced a recovery to main"
  append_status "$home" 'which region?' needs-decision
  wait_until 250 hook_exited "$home" || fail "takeover: the owned cycle did not deliver the next close: $(cat "$home/state/.supervision-host.log")"
  assert_rewoke_main "$home" "takeover (next close)"
  assert_re '^signal: .*demo.status' "$home/hook.err" "takeover: the next close must carry the watcher's reason line"
  pass "host+hook: the next park takes over the cycle a main-only pass-through left, so one arm owns it"
}

# A park stopped before its take-over stops the left cycle (here held in the
# take-over's handover snapshot by the recovery-marker lock) must not forget
# that cycle's arm: the park the Stop hook runs next still takes it over rather
# than attaching to it beside the orphan.
test_a_park_stopped_mid_take_over_leaves_the_take_over_to_the_next_park() {
  local home holder host
  home=$(make_primary_home hook-takeover-interrupted)
  leave_a_cycle_for_main_and_restart "$home"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 1
    : > "$3"
    while [ ! -e "$4" ]; do sleep 0.1; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state/.watcher-down.lock" "$home/marker-lock-held" "$home/marker-lock-release" &
  holder=$!
  wait_until 100 test -e "$home/marker-lock-held" || fail "fixture: could not hold the recovery-marker lock"
  turn_end "$home"
  wait_until 150 grep -q "	take-over	arm=$LEFT_ARM\$" "$home/state/.supervision-host.log" \
    || fail "interrupted takeover: the park did not start a take-over of $LEFT_ARM: $(cat "$home/state/.supervision-host.log")"
  host=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  sleep 1
  kill -0 "$LEFT_WATCHER" 2>/dev/null || fail "fixture: the take-over stopped the left watcher before the park was stopped"
  kill -TERM "$host" 2>/dev/null || fail "fixture: the park host $host was not running"
  wait_until 150 sh -c '! kill -0 "$1" 2>/dev/null' _ "$host" || fail "fixture: the park host did not stop"
  : > "$home/marker-lock-release"
  wait "$holder" 2>/dev/null || true
  # The Stop hook runs the next park in place of the one stopped by a signal.
  wait_until 150 host_owns_the_only_cycle "$home" \
    || fail "interrupted takeover: the next park did not own the home's only watcher cycle (left arm $LEFT_ARM):"$'\n'"$(home_arms "$home")"$'\n'"$(cat "$home/state/.supervision-host.log")"
  ! kill -0 "$LEFT_ARM" 2>/dev/null || fail "interrupted takeover: the left arm still runs (pid $LEFT_ARM)"
  pass "host+hook: a park stopped mid take-over leaves the take-over to the next park"
}

no_home_arms() { [ -z "$(home_arms "$1")" ]; }

# A successor the host cannot record for the next park's take-over (here the
# record path is a directory the record would land inside) must not be left
# running: the host stops it on exit, the close still reaches main unchanged,
# and main's next turn end owns a fresh cycle with no orphan beside it.
test_unrecorded_successor_is_stopped_rather_than_left_for_main() {
  local home
  home=$(make_primary_home hook-successor-unrecorded)
  mkdir "$home/state/.supervision-host-left"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "unrecorded successor: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "unrecorded successor: the decision close never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "fixture: the close was not a main-only pass-through"
  assert_re '	pass-through	successor-unrecorded	signal:' "$home/state/.supervision-host.log" "unrecorded successor: the failed record was not logged"
  assert_rewoke_main "$home" "unrecorded successor (pass-through)"
  assert_re '^signal: .*demo.status' "$home/hook.err" "unrecorded successor: the close must carry the watcher's reason line"
  wait_until 100 no_home_arms "$home" || fail "unrecorded successor: an arm outlived the host:"$'\n'"$(home_arms "$home")"
  rmdir "$home/state/.supervision-host-left" \
    || fail "unrecorded successor: the record left inside the directory was not removed: $(ls -A "$home/state/.supervision-host-left")"
  main_drain "$home" >/dev/null
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  [ -z "$MAIN_ACK" ] || FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@" >/dev/null 2>&1' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK \
    || fail "unrecorded successor: main's acknowledgement failed: $MAIN_ACK"
  turn_end "$home"
  wait_until 150 host_owns_the_only_cycle "$home" \
    || fail "unrecorded successor: main's next turn end did not own the home's only watcher cycle:"$'\n'"$(home_arms "$home")"$'\n'"$(cat "$home/state/.supervision-host.log")"
  pass "host+hook: a successor that cannot be recorded is stopped, and main's next turn end arms a fresh cycle"
}

test_claude_stop_hook_restores_handoff_when_successor_closed_before_exit_to_main
test_claude_stop_hook_restores_handoff_when_successor_closed_mid_engine_turn
test_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails
test_claude_stop_hook_notifies_when_closed_announced_successor_downtime_restore_fails
test_claude_stop_hook_delivers_a_main_only_pass_through
test_claude_stop_hook_rewakes_a_present_captain_beside_a_quiet_record
test_claude_stop_hook_runs_the_host_without_the_file_and_off_opts_out
test_claude_stop_hook_delivers_a_close_that_turns_main_only_at_its_turn
test_successor_left_at_the_turn_survives_the_hook_process_group_teardown
test_claude_stop_hook_notifies_when_at_turn_downtime_write_fails
test_successor_close_during_main_turn_is_delivered_at_the_next_turn_end
test_pass_through_successor_survives_the_hook_process_group_teardown
test_next_park_takes_over_the_cycle_a_pass_through_left_for_main
test_a_park_stopped_mid_take_over_leaves_the_take_over_to_the_next_park
test_unrecorded_successor_is_stopped_rather_than_left_for_main
