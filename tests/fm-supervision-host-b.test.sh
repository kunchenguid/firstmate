#!/usr/bin/env bash
# Behavior tests for the supervision host (bin/fm-supervision-host.sh,
# docs/supervision-host.md): the complementary CI-cost-balanced half of the
# former combined suite. Cases cover attended/away latch, park and engine-turn
# bounds, remaining Stop-hook takeover, and remaining report/drain routing
# against a stub engine. The other half lives in
# tests/fm-supervision-host-a.test.sh. Split by measured CI per-test cost so
# each portable serial shard stays under the job cap; see
# docs/fm-test-portable-shards.md.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/fm-supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host-helpers.sh"

test_main_only_close_after_handled_turn_restores_inherited_handling() {
  assert_main_only_close_after_handled_turn restore
  pass "host+hook: a main-only close after a handled turn restores inherited handling and rewakes main"
}

test_returned_driver_is_caught_attended() {
  assert_returned_driver_is_caught attended
  pass "host+hook: a driver returning to an idle worker is stale-handled while attended"
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
  wait_until 600 hook_exited "$home" || fail "closed successor: the Stop hook did not finish: $(cat "$home/state/.supervision-host.log")"
  assert_re '^supervision-host: branch-outcome: ' "$home/hook.err" "the host must hand its captain outcome to main"
  expect_code 2 "$(cat "$home/hook.rc")" "the Stop hook must rewake main after the successor closed"
  assert_re '^(pending|announced):downtime:' "$home/state/.watcher-down" \
    "the closed handling successor must leave a deliverable downtime episode"
  pass "host+hook: a successor closed before exit_to_main does not suppress the branch-outcome rewake"
}

test_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails() {
  assert_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails pending
  pass "host+hook: a refused hand-back becomes a delivered failure notice"
}

test_claude_stop_hook_notifies_when_closed_announced_successor_downtime_restore_fails() {
  assert_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails announced
  pass "host+hook: a refused hand-back on an announced handling marker becomes a delivered failure notice"
}

test_park_exit_probe_uses_half_second_child_sleeps() {
  local home host_pid
  home=$(make_home park-cadence attended)
  cat > "$home/fakebin/sleep" <<'SH'
#!/bin/bash
pid=''
if [ -f "$FM_HOME/probe-host" ]; then
  IFS= read -r pid < "$FM_HOME/probe-host" || true
  if [ "$PPID" = "$pid" ]; then
    printf '%s\n' "$1" >> "$FM_HOME/park-sleeps"
  fi
fi
exec /bin/sleep "$@"
SH
  chmod +x "$home/fakebin/sleep"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "park-cadence: no watcher started"
  host_pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  [ -n "$host_pid" ] || fail "park-cadence: no recorded host"
  printf '%s\n' "$host_pid" > "$home/probe-host"
  wait_until 100 test -s "$home/park-sleeps" || fail "park-cadence: no child sleep observed"
  [ "$(sort -u "$home/park-sleeps")" = 0.5 ] || fail "park-cadence: exit probing did not use half-second sleeps"
  stop_home_processes "$home"
  pass "host: parked child-exit sampling uses ordinary half-second sleeps"
}

# --- dispatch entry -----------------------------------------------------------

test_dispatch_entry_scopes_rows_and_renders_the_away_tail() {
  local home state out rc
  home="$TMP_ROOT/dispatch"
  state="$home/state"
  mkdir -p "$state"
  printf 'project=demo\nwindow=fm-demo\n' > "$state/demo.meta"
  append_wake "$state" signal demo.status "signal: $state/demo.status"
  append_wake "$state" check merge "check: merge landed: fixture"

  out=$(FM_HOME="$home" node "$DISPATCH" scope)
  assert_contains "$out" "status=safe" "an attended scan with a resolvable row must be safe"
  assert_contains "$out" "rows=1" "an attended scan must leave the check row to main"
  assert_contains "$out" "tasks=demo" "the signal row must resolve to its task"
  assert_contains "$out" "unscoped=0" "a task-local claim must be scoped"

  out=$(FM_HOME="$home" node "$DISPATCH" scope --afk)
  assert_contains "$out" "rows=1 2" "an away scan must claim the check row too"
  assert_contains "$out" "unscoped=1" "a claimed check row names no task, so the claim is unscoped"

  out=$(printf 'check: merge landed: fixture\n' | FM_HOME="$home" node "$DISPATCH" offer)
  assert_contains "$out" "eligible=0" "an attended check trigger must stay main's"
  out=$(printf 'check: merge landed: fixture\n' | FM_HOME="$home" node "$DISPATCH" offer --afk)
  assert_contains "$out" "eligible=1" "an away check trigger must be the branch's"
  out=$(printf 'signal: %s\n' "$state/demo.status" | FM_HOME="$home" node "$DISPATCH" offer)
  assert_contains "$out" "eligible=1" "an attended signal trigger with a claimable row must be the branch's"
  assert_contains "$out" "rows=1" "the offer must carry the scope it judged"

  printf '[captain] keep it small\n[main] Will do.\n' > "$home/mirror"
  out=$(printf 'signal: demo.status\n' | FM_HOME="$home" node "$DISPATCH" wake-prompt --report 'the bin/fm-branch-report.sh command' --mirror-file "$home/mirror")
  assert_contains "$out" "MAIN DIALOG MIRROR (read-only context" "an attended wake prompt must open with the mirror header"
  assert_contains "$out" "[captain] keep it small" "the mirror must carry the captain's words"
  assert_not_contains "$out" "POSTURE: AWAY" "an attended wake prompt must carry no away tail"
  : > "$home/mirror"
  out=$(printf 'signal: demo.status\n' | FM_HOME="$home" node "$DISPATCH" wake-prompt --report 'the bin/fm-branch-report.sh command' --mirror-file "$home/mirror")
  assert_not_contains "$out" "MAIN DIALOG MIRROR" "an empty feed must add nothing"
  rm -f "$home/mirror"
  rc=0
  out=$(printf 'signal: demo.status\n' | FM_HOME="$home" node "$DISPATCH" wake-prompt --report 'the bin/fm-branch-report.sh command' --mirror-file "$home/mirror" 2>/dev/null) || rc=$?
  [ "$rc" -eq 3 ] || fail "a supplied mirror feed that cannot be read must exit 3, got $rc"
  [ -z "$out" ] || fail "a supplied mirror feed that cannot be read must render no prompt: $out"

  printf 'Away posture (recorded):\n  your words (verbatim):\n    merge nothing\n' > "$home/readback"
  out=$(printf 'signal: demo.status\n' | FM_HOME="$home" node "$DISPATCH" wake-prompt --report 'the bin/fm-branch-report.sh command' --away --readback-file "$home/readback")
  assert_contains "$out" "FIRSTMATE SUPERVISION WAKE: signal: demo.status" "the wake prompt must carry the reason"
  assert_contains "$out" "finish with the bin/fm-branch-report.sh command." "the wake prompt must name the host's report surface"
  assert_contains "$out" "POSTURE: AWAY." "an away wake prompt must carry the posture tail"
  assert_contains "$out" "    merge nothing" "the away tail must carry the record's read-back verbatim"
  pass "dispatch entry: the host reads branch eligibility, the offer rule, and the wake prompt from the Pi branch's own owner"
}

# A fresh captain outcome is never hidden behind older routine outcomes: the
# captain rows come first whatever the routine backlog, the newest routine
# outcomes that fit the byte cap follow, and the older overflow collapses into
# a count that is marked read, so one drain clears the whole backlog.
test_branch_outcomes_put_captain_first_and_collapse_routine_overflow() {
  local home drained pad n
  home="$TMP_ROOT/drain-cap"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  pad=$(awk 'BEGIN { for (i = 0; i < 400; i++) printf "x" }')
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict routine --summary "routine $n $pad" >/dev/null \
      || fail "fixture: could not record routine outcome $n"
  done
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict captain --summary 'PR ready for review' >/dev/null \
    || fail "fixture: could not record the captain outcome"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 13, recorded 0m ago] demo: PR ready for review" "the captain outcome must be presented despite the routine backlog"
  assert_contains "$drained" "run bin/fm-branch-outcome.sh mark-processed --through 13" "the captain outcome must carry its acknowledgement"
  [ "$(printf '%s\n' "$drained" | grep -n 'PR ready for review' | cut -d: -f1)" -lt "$(printf '%s\n' "$drained" | grep -n 'routine 12' | cut -d: -f1)" ] \
    || fail "the captain outcome must come before the routine outcomes: $drained"
  assert_contains "$drained" "[seq 12] demo: routine 12" "the newest routine outcome must be listed"
  assert_not_contains "$drained" "routine 1 " "the oldest routine outcome must collapse into the count"
  assert_re '^\([0-9]+ earlier routine outcome\(s\) not shown; bin/fm-branch-outcome.sh list keeps them\)$' <(printf '%s\n' "$drained") \
    "the routine overflow must collapse into one count"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 13 >/dev/null 2>&1 \
    || fail "main's acknowledgement of the presented captain outcome was refused"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "one drain must clear the routine backlog, and an acknowledged store must present nothing"
  pass "drain: captain outcomes come first, and routine overflow collapses into a count one drain clears"
}

# Repeated captain outcomes for one task collapse to its newest, one line per
# task; when the byte cap holds rows back, the section shows only the oldest
# contiguous run its acknowledgement covers - a shown task's newer row that
# follows a held-back one waits too, so no presented situation repeats - and
# the next drain shows the rest.
test_branch_outcomes_collapse_repeated_captain_outcomes_per_task() {
  local home drained pad n task
  home="$TMP_ROOT/drain-collapse"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  for n in 1 2 3; do
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task alpha --verdict captain --summary "alpha still blocked $n" >/dev/null \
      || fail "fixture: could not record alpha outcome $n"
  done
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task beta --verdict captain --summary 'beta ready to merge' >/dev/null \
    || fail "fixture: could not record the beta outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 3, newest of 3 for this task, recorded 0m ago] alpha: alpha still blocked 3" "repeated outcomes for one task must collapse to its newest"
  assert_not_contains "$drained" "alpha still blocked 1" "an older outcome for the same task must not be repeated"
  assert_contains "$drained" "[seq 4, recorded 0m ago] beta: beta ready to merge" "another task's outcome must keep its own line"
  assert_contains "$drained" "mark-processed --through 4;" "one acknowledgement must cover every presented task"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 4 >/dev/null 2>&1 || fail "the acknowledgement was refused"

  pad=$(awk 'BEGIN { for (i = 0; i < 535; i++) printf "y" }')
  for n in 1 2 3 4 5 6 7 8; do
    task=task-$n
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task "$task" --verdict captain --summary "$task $pad" >/dev/null \
      || fail "fixture: could not record $task"
  done
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task task-1 --verdict captain --summary 'task-1 changed again' >/dev/null \
    || fail "fixture: could not record the later task-1 outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "BRANCH OUTCOMES: 3 newer captain outcome(s) are held back (byte cap); they follow on the next drain once these are acknowledged" \
    "the section must count every held-back captain row"
  assert_contains "$drained" "[seq 5, recorded 0m ago] task-1: task-1 $pad" "the first task must show its newest outcome the acknowledgement covers"
  assert_not_contains "$drained" "task-1 changed again" "a row after a held-back one must wait, since the acknowledgement cannot cover it"
  assert_not_contains "$drained" "task-7:" "the cap must hold back the rows past the contiguous run"
  assert_contains "$drained" "mark-processed --through 10;" "the acknowledgement must cover exactly the presented run"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 10 >/dev/null 2>&1 || fail "the acknowledgement was refused"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "task-8: task-8" "a held-back task must follow once the shown tasks are acknowledged"
  assert_contains "$drained" "[seq 13, recorded 0m ago] task-1: task-1 changed again" "the held-back row of a shown task must follow once the run is acknowledged"
  assert_not_contains "$drained" "held back" "the rest must fit once the run is acknowledged"
  assert_contains "$drained" "mark-processed --through 13;" "the acknowledgement must cover the rest"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 13 >/dev/null 2>&1 || fail "the acknowledgement was refused"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "an acknowledged situation must not be presented again"
  pass "drain: repeated captain outcomes collapse per task, and the byte cap presents only the run its acknowledgement covers"
}

# The reference experience after a long away window: the drain is the only
# presenter, so the first drain once the away record is gone shows the window
# once - each task's captain outcomes collapsed to one line, routine ones past
# the section's limit as a count - and once main acknowledges them, a second
# drain shows nothing from the window.
test_branch_outcomes_present_a_long_away_window_once() {
  local home drained pad n target
  home="$TMP_ROOT/drain-away-window"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'watch the fleet' >/dev/null 2>&1 \
    || fail "fixture: could not record the away posture"
  pad=$(awk 'BEGIN { for (i = 0; i < 200; i++) printf "z" }')
  for n in $(seq 1 40); do
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task "task-$((n % 4))" --verdict routine --summary "routine $n $pad" >/dev/null \
      || fail "fixture: could not record routine outcome $n"
    case "$n" in
      10|20|30)
        FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task alpha --verdict captain --summary "alpha still needs review $n" >/dev/null \
          || fail "fixture: could not record alpha outcome $n" ;;
    esac
  done
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task beta --verdict captain --summary 'beta ready to merge' >/dev/null \
    || fail "fixture: could not record the beta outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a drain while away must leave the window's outcomes for the return"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null 2>&1 || fail "fixture: could not archive the away posture"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 33, newest of 3 for this task, recorded 0m ago] alpha: alpha still needs review 30" "a task's repeated captain outcomes must collapse to its newest"
  [ "$(printf '%s\n' "$drained" | grep -c '] alpha: ')" -eq 1 ] || fail "a task's captain outcomes must take one line: $drained"
  assert_contains "$drained" "[seq 44, recorded 0m ago] beta: beta ready to merge" "another task's captain outcome must keep its own line"
  assert_re '^\([0-9]+ earlier routine outcome\(s\) not shown; bin/fm-branch-outcome.sh list keeps them\)$' <(printf '%s\n' "$drained") \
    "the window's routine overflow must collapse into one count"
  assert_contains "$drained" "routine 40 $pad" "the newest routine outcome must be listed"
  assert_not_contains "$drained" "routine 1 $pad" "the oldest routine outcome must collapse into the count"
  [ "${#drained}" -lt 8000 ] || fail "a long away window must cost one short drain, got ${#drained} bytes"
  target=$(printf '%s\n' "$drained" | sed -n 's/.*mark-processed --through \([0-9]*\);.*/\1/p')
  [ "$target" = 44 ] || fail "one acknowledgement must cover every captain outcome of the window, got '${target:-none}'"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through "$target" >/dev/null 2>&1 || fail "the acknowledgement was refused"

  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a second drain must show nothing from the window"
  pass "drain: a long away window costs one short drain, captain outcomes collapsed per task and routine overflow counted, and nothing from it is shown again"
}

# Without jq the drain cannot present the store, so it marks nothing read and
# exits nonzero for the return's gate.
test_branch_outcomes_stay_unread_without_jq() {
  local home drained rc dir entry path=''
  home="$TMP_ROOT/drain-no-jq"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict routine --summary 'merged the docs fix' >/dev/null \
    || fail "fixture: could not record the routine outcome"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ -e "$dir/jq" ]; then
      mkdir -p "$home/no-jq$dir"
      for entry in "$dir"/*; do
        [ "${entry##*/}" = jq ] || ln -s "$entry" "$home/no-jq$dir/" 2>/dev/null || true
      done
      dir="$home/no-jq$dir"
    fi
    path="${path:+$path:}$dir"
  done <<DIRS
$(printf '%s\n' "$PATH" | tr ':' '\n')
DIRS
  PATH="$path" command -v jq >/dev/null 2>&1 && fail "fixture: jq is still reachable"
  rc=0
  drained=$(PATH="$path" FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh") || rc=$?
  [ "$rc" -ne 0 ] || fail "a drain without jq over a non-empty store must exit nonzero: $drained"
  assert_contains "$drained" "BRANCH OUTCOMES SKIPPED: jq is not installed" "a drain without jq must say it could not present the store"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1] demo: merged the docs fix" "an outcome a drain without jq could not present must follow on the next drain"
  pass "drain: branch outcomes stay unread and the drain fails when jq is missing"
}

# A drain that cannot print the section, because its output is already
# closed, has presented nothing, so the rows stay unread for the next drain.
test_branch_outcomes_stay_unread_when_the_drain_cannot_print() {
  local home drained rc=0
  home="$TMP_ROOT/drain-closed"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task demo --verdict routine --summary 'merged the docs fix' >/dev/null \
    || fail "fixture: could not record the routine outcome"
  # Bypass /usr/bin/env: Rust-based env reopens a closed stdout on /dev/null,
  # so the shebang would make printing succeed instead of testing a write error.
  FM_HOME="$home" "$FAKE_CLAUDE" -c 'bash "$0" >&- 2>/dev/null' "$ROOT/bin/fm-wake-drain.sh" || rc=$?
  [ "$rc" -ne 0 ] || fail "a drain that cannot print its outcomes must exit nonzero"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1] demo: merged the docs fix" "a routine outcome a drain could not print must follow on the next drain"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "merged the docs fix" "a routine outcome a drain printed must not repeat"
  pass "drain: branch outcomes stay unread when the drain cannot print them"
}

# A newer settled branch line must not close an older keyed status decision.
test_branch_ack_keeps_older_keyed_decision_open() {
  local home drained
  home="$TMP_ROOT/drain-older-decision"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  printf 'needs-decision [key=merge-153]: merge PR 153 now or hold?\n' > "$home/state/held.status"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task held --verdict captain --summary 'needs merge decision' >/dev/null || fail "fixture: older outcome"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append --task held --verdict captain --summary 'CI is now green' >/dev/null || fail "fixture: newer outcome"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" 'OPEN DECISIONS' "the status decision must appear in the first drain"
  assert_contains "$drained" 'held [key=merge-153] needs-decision: merge PR 153 now or hold?' "the older decision must remain open"
  assert_contains "$drained" '[seq 2, newest of 2 for this task' "the branch line must collapse to the newest outcome"
  assert_contains "$drained" "including its still-open decisions listed above under OPEN DECISIONS" "the check-first instruction must include the older keyed decision"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 2 >/dev/null || fail "fixture: acknowledgement refused"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" 'held [key=merge-153] needs-decision: merge PR 153 now or hold?' "acknowledging the newer branch line closed the older keyed decision"
  assert_not_contains "$drained" 'CI is now green' "acknowledged branch outcome repeated"
  pass "drain: a keyed decision survives acknowledgement through a newer outcome for its task"
}

# A switch off Pi hands the drain an outcome the branch delivered but main
# never acknowledged; it comes back with its age instead of as news, and is
# still not adopted.
test_branch_outcomes_date_an_outcome_carried_across_a_switch_off_pi() {
  local home drained fakepi
  home="$TMP_ROOT/drain-switch-off-pi"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  fakepi="$TMP_ROOT/fakepi"
  mkdir -p "$fakepi"
  ln -sf /bin/bash "$fakepi/pi"
  outcome_row 1 $(( $(date +%s) - 2 * 86400 )) gamma captain 'gamma needs your decision on the schema migration' \
    > "$home/state/branch-outcomes.jsonl"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 1 \
    || fail "fixture: could not record the Pi branch's delivery"
  drained=$(FM_HOME="$home" "$fakepi/pi" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_not_contains "$drained" "BRANCH OUTCOMES" "a Pi primary's drain must leave the outcome to the branch extension"
  drained=$(FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" "[seq 1, recorded 2d ago] gamma: gamma needs your decision" \
    "an outcome delivered on Pi but never acknowledged must come back with its age"
  [ -n "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed)" ] \
    || fail "the switch adopted an unacknowledged captain outcome as processed"
  pass "drain: an outcome carried across a switch off Pi comes back with its age, never adopted"
}

# A lost index-ready marker makes the next drain's status backstop run
# processed-init under the outcome lock before BRANCH OUTCOMES. That repair
# must not adopt the presented but unacknowledged row either.
test_branch_outcomes_keep_a_drain_presented_outcome_across_an_index_repair() {
  local drained
  present_unacknowledged_outcome_twice drain-index-repair
  rm -f "$PRESENTED_HOME/state/.branch-outcome-index-ready"
  printf 'working: rebasing onto main\n' > "$PRESENTED_HOME/state/epsilon.status"
  drained=$(FM_HOME="$PRESENTED_HOME" "$FAKE_CLAUDE" -c '"$0" 2>&1' "$ROOT/bin/fm-wake-drain.sh")
  [ -f "$PRESENTED_HOME/state/.branch-outcome-index-ready" ] || fail "the drain's status backstop did not repair the outcome index"
  assert_contains "$drained" "epsilon: epsilon PR is ready to merge" \
    "an index repair adopted a drain-presented, unacknowledged outcome as processed"
  assert_contains "$(FM_HOME="$PRESENTED_HOME" "$ROOT/bin/fm-branch-outcome.sh" unprocessed)" '"seq":1' \
    "an index repair left the unacknowledged outcome processed"
  pass "drain: an outcome the host drain presented but main never acknowledged survives an outcome index repair"
}

# A TERM that lands just after a handled wake, while the host settles its
# successor handoff under the queue and marker locks, must not leave the host
# waiting in its own exit cleanup on the queue lock it still holds: that wedged
# the host (and every later queue append) instead of exiting.
test_host_stopped_right_after_a_handled_wake_exits_and_frees_the_queue() {
  local home pid
  home=$(make_home handled-then-term attended)
  echo hold-marker > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "handled then TERM: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "handled then TERM: the wake was not handled on the engine: $(cat "$home/state/.supervision-host.log")"
  pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  [ -n "$pid" ] || fail "fixture: no host record after the handled wake"
  kill -TERM "$pid" 2>/dev/null || true
  wait_until 100 bash -c '! kill -0 "$1" 2>/dev/null' _ "$pid" \
    || fail "handled then TERM: the host did not exit within 10s of TERM after a handled wake"
  FM_HOME="$home" timeout 10 bash -c '. "$1"; fm_wake_append check probe "check: probe"' _ "$ROOT/bin/fm-wake-lib.sh" \
    || fail "handled then TERM: the stopped host left the wake queue lock held"
  stop_home_processes "$home"
  pass "host: a host stopped right after a handled wake exits and leaves the wake queue usable"
}

# A wrapper may launch the engine in another time zone than the host's (one
# observed wrapper exports a TZ the main session's hooks never see). The
# process-table identity that ties the branch grant to the host must read the
# same from both, or the engine's drain discards the grant as stale, refuses,
# and leaves every granted row for main. The proc root is hidden so Linux takes
# the same process-table path as macOS.
test_engine_in_another_time_zone_handles_its_granted_rows() {
  local home no_proc
  home=$(make_home engine-tz attended)
  no_proc="$TMP_ROOT/engine-tz-no-proc"
  [ "$(TZ=UTC0 LC_ALL=C ps -p $$ -o lstart=)" != "$(TZ=ENG-9 LC_ALL=C ps -p $$ -o lstart=)" ] \
    || fail "fixture: ps renders the same start time in both time zones, so the case would prove nothing"
  printf 'ENG-9\n' > "$home/stub-tz"
  TZ=UTC0 FM_PROC_ROOT_OVERRIDE="$no_proc" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "engine tz: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "engine tz: the turn did not end handled: $(cat "$home/state/.supervision-host.log"; cat "$home"/engine-drain.* 2>/dev/null)"
  assert_no_re '	failed	' "$home/state/.supervision-host.log" "engine tz: a turn that reported for its granted rows must not fail"
  assert_no_grep 'no branch-eligible row snapshot' "$home/engine-drain.1" "engine tz: the engine's drain discarded the host's grant"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "engine tz: the engine's acknowledgement did not consume the wake"
  [ ! -s "$home/host.rc" ] || fail "engine tz: the handled wake reached main: $(cat "$home/host.out")"
  pass "host: an engine in another time zone than the host drains, reports, and acknowledges its granted rows"
}

# The file is read at every wake (docs/configuration.md "Supervision host"), so
# an off written while the host is parked sends the next attended close to main
# exactly as the arm printed it, with the ledger naming the opt-out.
test_off_written_while_parked_passes_the_next_attended_close_to_main() {
  local home
  home=$(make_home attended-off-while-parked attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "off while parked: the host never started a watcher cycle"
  : > "$home/config/supervision-host-off"
  append_status "$home" 'step one'
  wait_until 250 host_exited "$home" || fail "off while parked: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a close on a home that opted out must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "off while parked: the engine ran after the home opted out"
  assert_re '	pass-through	attended	the home does not run the supervision host	signal:' "$home/state/.supervision-host.log" \
    "the ledger must name the opt-out as why the close went to main"
  stop_home_processes "$home"
  pass "host: an off written while the host is parked sends the next attended close to main, naming the opt-out"
}

# The live failure this guards: a main-only pass-through used to exit without
# a watcher, so nothing restarted short-lived listeners until the session
# armed again. The close still reaches main unchanged, and the successor
# cycle stays up for the session's next arm to attach to.
test_main_only_pass_through_leaves_the_successor_watcher_running() {
  local home pid
  home=$(make_home main-only-successor attended)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "successor: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 host_exited "$home" || fail "successor: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a main-only close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "a main-only close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "successor: the engine ran for a decision close"
  watcher_live "$home" || fail "successor: the pass-through left no live watcher: $(cat "$home/state/.supervision-host.log")"
  [ "$(marker_kind "$home")" = downtime ] \
    || fail "successor: the pass-through claimed the close was being handled, so main's re-arm owner would not deliver it: $(cat "$home/state/.watcher-down")"
  pid=$(cat "$home/state/.watch.lock/pid")
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "successor: the watcher exited after the pass-through (pid $pid)"
  [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" = "$pid" ] || fail "successor: the watcher lock moved after the pass-through"
  pass "host: a main-only pass-through leaves the successor watcher running and the close undelivered for main"
}

test_attended_close_that_turns_main_only_before_its_turn_passes_to_main() {
  local home
  home=$(make_home attended-turns-main-only attended)
  turn_main_only_at_second_offer "$home" snapshot
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "turns-main-only: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 host_exited "$home" || fail "turns-main-only: the close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_grep 'which export format?' "$home/state/demo.status" "fixture: the decision was not recorded before the turn"
  expect_code 0 "$(cat "$home/host.rc")" "the close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "turns-main-only: the engine ran on a stale offer"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the wake must stay queued for main"
  assert_grep 'which export format?' "$home/pi-offer-state/demo.status" "fixture: the Pi snapshot must contain the new decision"
  assert_no_re 'needs-decision:' "$home/pi-offer-state/.wake-queue" "fixture: the Pi snapshot must contain only the accepted wake"
  local pi_offer
  pi_offer=$(node --input-type=module -e '
    const dispatch = await import(process.argv[1]);
    console.log(dispatch.branchOfferForWake(process.argv[2], process.argv[3], false).eligible);
  ' "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$home/pi-offer-state" "signal: $home/state/demo.status")
  [ "$pi_offer" = true ] || fail "the host-only transition veto changed Pi's existing offer rule"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  watcher_live "$home" || fail "the pass-through left no successor watcher"
  pass "host: an attended close whose task turns main-only before its turn still reaches main unchanged"
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

# Every file carrying the captain's dialog is owner-only, even under an open
# umask and when a readable copy was already there. The feed is removed before
# the engine starts, so a node wrapper records its mode as the wake renders.
test_dialog_bearing_files_are_owner_only() {
  local home old
  home=$(make_home attended-private attended)
  {
    printf '#!/usr/bin/env bash\nREAL_NODE=%q\n' "$(command -v node)"
    cat <<'SH'
prev=
for a in "$@"; do
  [ "$prev" != --mirror-file ] || { stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a"; } >> "$FM_HOME/feed-modes"
  prev=$a
done
exec "$REAL_NODE" "$@"
SH
  } > "$home/fakebin/node"
  chmod +x "$home/fakebin/node"
  old=$(umask)
  umask 022
  for f in .host-mirror.jsonl .supervision-host-mirror .supervision-host-wake; do
    : > "$home/state/$f"
    chmod 644 "$home/state/$f"
  done
  start_host "$home"
  umask "$old"
  wait_until 150 watcher_live "$home" || fail "private: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "private: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  assert_re '^\[captain\] watch the fleet for me$' "$home/engine-call.1" "fixture: the wake must carry the captain's words"
  [ "$(mode_of "$home/state/.host-mirror.jsonl")" = 600 ] || fail "the dialog mirror must be owner-only, got $(mode_of "$home/state/.host-mirror.jsonl")"
  [ "$(mode_of "$home/state/.supervision-host-wake")" = 600 ] || fail "the wake file must be owner-only, got $(mode_of "$home/state/.supervision-host-wake")"
  [ "$(cat "$home/feed-modes" 2>/dev/null)" = 600 ] || fail "the mirror feed must be owner-only, got $(cat "$home/feed-modes" 2>/dev/null)"
  pass "host: the dialog mirror, its feed, and the wake file are owner-only"
}

test_away_wake_is_handled_on_the_engine_and_never_reaches_main() {
  local home lock_pid session first second pid watcher
  home=$(make_home away-handled away)
  echo hold-lease > "$home/stub-mode"
  # Dialog in the mirror that an away wake must neither carry nor mark read.
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "away: the wake was not handled: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  lock_pid=$(cat "$home/state/.lock")

  first="$home/engine-call.1"
  assert_re '^actor=branch$' "$first" "the engine must run as the branch actor"
  assert_re "^holder=$lock_pid\$" "$first" "the engine's lease holder must be the session-lock holder"
  assert_re '^primary=claude$' "$first" "the engine must carry the primary-harness pin"
  assert_re '^turn=host-' "$first" "the engine must carry its report turn"
  assert_re '^arg=--safe-mode$' "$first" "the engine must load none of the home's hooks"
  assert_re '^arg=dontAsk$' "$first" "the engine must never prompt"
  assert_re '^arg=sonnet$' "$first" "the engine must default to its default model"
  assert_re '^arg=--session-id$' "$first" "the first turn must open a new conversation"
  assert_re '^POSTURE: AWAY\.' "$first" "the wake must carry the away tail"
  assert_grep 'keep the export worker on low effort' "$home/state/.host-mirror.jsonl" "fixture: the captain's dialog was not mirrored"
  assert_no_re 'MAIN DIALOG MIRROR|low effort' "$first" "an away wake must carry no dialog mirror"
  assert_absent "$home/state/.host-mirror-cursor" "a handled away wake must leave the mirror cursor where it was"
  assert_absent "$home/state/.host-mirror-cursor.next" "an away wake must stage no mirror cursor"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "the engine's report did not reach the outcome store"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the engine's acknowledgement did not consume the wake"
  if FM_HOME="$home" "$LEASE" check demo >/dev/null 2>&1; then
    fail "the host did not release the lease the engine left held: $(FM_HOME="$home" "$LEASE" check demo)"
  fi
  [ ! -s "$home/host.rc" ] || fail "a handled away wake reached main: $(cat "$home/host.out")"
  [ "$(grep -cv '^watcher: started pid=' "$home/host.out")" -eq 0 ] \
    || fail "a handled away wake printed more than the first cycle's status to main: $(cat "$home/host.out")"
  watcher_live "$home" || fail "the host is not parked on a live successor cycle"

  echo handle > "$home/stub-mode"
  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 || fail "away: the second wake was not handled"
  session=$(sed -n '/^arg=--session-id$/{n;s/^arg=//p;}' "$first")
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "a later turn must resume the conversation"
  assert_re "^arg=$session\$" "$second" "a later turn must resume the same conversation"
  [ "$(grep -c '"task":"demo"' "$home/state/branch-outcomes.jsonl")" -eq 2 ] || fail "the second outcome was not recorded"
  assert_re '	handled	turn=[^	]*\.2	.* cost=0\.25 conversation_cost=0\.5 ' "$home/state/.supervision-host.log" \
    "a resumed turn must log its own cost, not the conversation's running total"

  pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM "$pid"
  wait_until 200 host_exited "$home" || fail "the host did not stop on TERM"
  expect_code 143 "$(cat "$home/host.rc")" "a TERMed host must exit 143"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "a stopped host left its watcher running"
  assert_absent "$home/state/.supervision-host" "a stopped host left its record"
  pass "host: an away wake is handled on the engine through the branch contract and never reaches main"
}

test_away_turn_without_a_report_hands_the_wake_to_main() {
  local home token
  home=$(make_home away-noreport away)
  echo noreport > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noreport: the host never started a watcher cycle"
  append_status "$home" 'needs a look'
  wait_until 250 host_exited "$home" || fail "noreport: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*recorded no outcome for its wake; this wake is yours$' "$home/host.out" "the handback must say why"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unhandled wake must stay durable for main"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  token=$(cat "$home/state/.watcher-down")
  case "$token" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "a handback must leave the recovery marker in downtime for the owner's rewake, got: $token" ;;
  esac
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn that records no outcome hands its durable wake to main"
}

# Silent outcomes stay stored, but neither captain-return path names or relays
# them when the host decides whether to hand the wake to main.
test_silent_outcomes_are_not_relayed_when_the_captain_returns() {
  local mode home host
  for mode in return-silent return-fail-silent; do
    home=$(make_home "away-$mode" away)
    echo "$mode" > "$home/stub-mode"
    start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$mode: the host never started a watcher cycle"
    append_status "$home" 'no-change result during a captain return'

    if [ "$mode" = return-silent ]; then
      wait_until 250 handled_at_least "$home" 1 || fail "$mode: the wake was not handled: host=$(cat "$home/host.out" 2>/dev/null) log=$(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null) report=$(cat "$home/engine-report.log" 2>/dev/null)"
      [ ! -s "$home/host.rc" ] || fail "$mode: a silent-only outcome forced a captain handoff: $(cat "$home/host.out")"
      watcher_live "$home" || fail "$mode: the host did not park on its successor"
      host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
      kill -TERM "$host"
      wait_until 200 host_exited "$home" || fail "$mode: the host did not stop on TERM"
    else
      wait_until 250 host_exited "$home" || fail "$mode: the failed turn did not hand the wake to main: $(cat "$home/host.out" 2>/dev/null) $(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null)"
      assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
        "$home/host.out" "$mode: the failed turn must still hand its wake to main"
    fi
    assert_no_re 'captain returned|store rows|^supervision-host: outcome ' "$home/host.out" \
      "$mode: a silent outcome was referenced in the captain-return handoff"
    assert_grep '"silent":true' "$home/state/branch-outcomes.jsonl" "$mode: the silent outcome was not retained in the store"
    assert_absent "$home/state/.afk-contract" "$mode: the captain return was not archived"
  done
  pass "host: silent outcomes are excluded from both captain-return handoff paths"
}

test_outcome_lookup_failure_is_not_treated_as_silence() {
  local home
  home=$(make_home away-lookup-failure away)
  echo return-lookup-fail > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "lookup failure: the host never started a watcher cycle"
  append_status "$home" 'outcome lookup failure after a captain return'
  wait_until 2000 host_exited "$home" || fail "lookup failure: the host treated an unreadable store as a silent outcome"
  assert_re '^supervision-host: the captain returned while the away session was handling this wake, but the recorded outcomes could not be verified; main must review them$' \
    "$home/host.out" "lookup failure: the main handoff did not explain the lookup failure"
  assert_re '^supervision-host: outcome lookup failed for turn receipt rows 1; visible outcomes may require manual review$' \
    "$home/host.out" "lookup failure: the missing outcome warning was not emitted"
  pass "host: an outcome lookup failure forces a visible main handoff"
}

# The live failure this guards: a Cursor park superseded by the captain's
# return kills its host as the engine turn ends, so the host's own handoff is
# never printed. The outcome still reaches main: the next host's first cycle
# resurfaces the durable queue and main's drain presents it.
test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end() {
  local home host rc drained
  home=$(make_home away-return-first away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-first: the host never started a watcher cycle"
  append_status "$home" 'finishing while the captain comes back'
  wait_until 250 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" \
    || fail "return-first: the late outcome was never queued: $(cat "$home/engine-report.log" 2>/dev/null)"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  kill -TERM "$host"
  wait_until 250 host_exited "$home" || fail "return-first: the stopped host did not exit"
  rc=$(cat "$home/host.rc")
  [ "$rc" -gt 128 ] || fail "fixture: the host was not stopped mid-turn (rc=$rc): $(cat "$home/host.out")"
  assert_no_re '^supervision-host: ' "$home/host.out" "fixture: the stopped host printed a handoff, so this case proves nothing"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.*; do
    [ -e "$f" ] && fail "a host stopped mid-turn left its turn file behind: $f"
  done
  assert_grep 'supervision-host-return:1' "$home/state/.wake-queue" "the late outcome must stay queued after its host died"

  rm -f "$home/host.rc"
  start_host "$home"
  wait_until 250 host_exited "$home" || fail "return-first: the next host did not resurface the queued outcome"
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  assert_re '	pass-through	attended	main-only	check: rearm-resurface' "$home/state/.supervision-host.log" "the attended resurface must reach main"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drained" "supervision-host outcome 1 for demo [routine] was recorded after the captain returned" \
    "main's drain must present the outcome the killed host never handed off"
  pass "host: an outcome recorded after the return reaches main even when its host dies at the turn's end"
}

# A host killed outright mid-turn leaves turn files, but the bounded engine's
# watchdog stops the engine when its owner dies. The next host clears the files.
test_next_host_clears_a_turn_its_killed_predecessor_left() {
  local home host engine
  home=$(make_home away-killed-mid-turn away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "killed: the host never started a watcher cycle"
  append_status "$home" 'mid-turn when its host is killed'
  wait_until 250 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" || fail "killed: the turn never reported"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  engine=$(cut -f1 "$home/state/.supervision-host.engine-pid")
  kill -KILL "$host"
  wait_until 100 host_exited "$home" || fail "killed: the host did not die"
  ls "$home"/state/.supervision-host-result.* >/dev/null 2>&1 || fail "fixture: the killed turn left no result file, so this case proves nothing"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$engine" || fail "the bounded engine survived its killed host"

  rm -f "$home/host.rc"
  start_host "$home"
  wait_until 250 host_exited "$home" || fail "killed: the next host did not resurface the queued outcome"
  ! kill -0 "$engine" 2>/dev/null || fail "the next host revived its killed predecessor's engine"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.* \
    "$home"/state/.supervision-host-descendants.* "$home/state/.supervision-host-turn"; do
    [ -e "$f" ] && fail "the next host left its killed predecessor's turn file behind: $f"
  done
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  pass "host: a killed predecessor's engine is reaped and the next host removes its turn files"
}

test_return_during_a_failed_turn_still_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return-fail away)
  echo return-fail > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-fail: the host never started a watcher cycle"
  append_status "$home" 'mid-task, then a crash'
  wait_until 250 host_exited "$home" || fail "return-fail: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a failed turn's handback must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); .*captain returned during its turn.*store rows 1[,)]' "$home/host.out" \
    "the handback must say the turn failed, that the captain returned, and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handback must carry the failed turn's outcome for main to relay"
  assert_re '	failed	turn=' "$home/state/.supervision-host.log" "the turn itself failed"
  pass "host: a captain return during a failed engine turn still hands that turn's outcomes to main"
}

test_latch_trips_after_two_engine_errors_then_probes_and_recovers() {
  local home
  home=$(make_home away-latch away)
  trip_latch "$home"

  park_again "$home"
  append_status "$home" 'inside the cooldown'
  wait_until 250 host_exited "$home" || fail "latch: a close inside the cooldown did not reach main"
  assert_re '^signal: .*demo.status' "$home/host.out" "a close inside the cooldown must reach main"
  assert_re '^supervision-host: the away session is paused after repeated engine errors until .*; this wake is yours$' \
    "$home/host.out" "a close inside the cooldown must say why main has it"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "the engine ran inside the cooldown"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close inside the cooldown must stay durable for main"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  park_again "$home"
  append_status "$home" 'the probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 3 ] || fail "the cooldown's end did not let one wake probe the engine"
  assert_no_re 'paused' "$home/host.out" "a failed probe must not repeat the trip line"
  assert_grep 'cooldown=600' "$home/state/.supervision-host-health" "a failed probe must double the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home" 2400
  park_again "$home"
  append_status "$home" 'a later probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the later failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 4 ] || fail "the grown cooldown's end did not let one wake probe the engine"
  assert_grep 'cooldown=3600' "$home/state/.supervision-host-health" "the doubled cooldown must stop at one hour"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  echo handle > "$home/stub-mode"
  park_again "$home"
  append_status "$home" 'the probe succeeds'
  wait_until 250 handled_at_least "$home" 1 || fail "latch: the successful probe was not handled: $(cat "$home/host.out")"
  [ "$(engine_calls "$home")" -eq 5 ] || fail "the cooldown's end did not let the recovering wake probe the engine"
  host_exited "$home" && fail "an away recovery must not reach main: $(cat "$home/host.out")"
  assert_re '	recovered	after a successful probe' "$home/state/.supervision-host.log" "the ledger must record the recovery"
  assert_grep 'cooldown=0' "$home/state/.supervision-host-health" "a successful probe must clear the latch"
  assert_grep 'errors=0' "$home/state/.supervision-host-health" "a successful probe must clear the error streak"
  watcher_live "$home" || fail "the recovered host is not parked on a live successor cycle"
  pass "host: two engine errors latch the session, main keeps every away wake in the cooldown, a failed probe doubles it up to its cap, and a report recovers it silently"
}

test_attended_latch_keeps_closes_on_main_and_records_recovery_off_main() {
  local home handled
  home=$(make_home attended-latch attended)
  echo fail > "$home/stub-mode"
  start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 host_exited "$home" || fail "latch: the first engine error did not hand the wake back"
  assert_re '^supervision-host: the supervision session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
    "$home/host.out" "the first engine error must hand the wake back with its reason"
  assert_no_re 'paused' "$home/host.out" "one engine error must not latch the session"
  main_drain_and_ack "$home"

  park_again "$home"
  append_status "$home" 'second'
  wait_until 250 host_exited "$home" || fail "latch: the second engine error did not hand the wake back"
  assert_re '^supervision-host: the supervision session is paused after repeated engine errors; every wake reaches you for the next 5 minutes' "$home/host.out" \
    "the second consecutive engine error must trip the latch with one line"
  assert_grep 'cooldown=300' "$home/state/.supervision-host-health" "the latch must start with the Pi policy's five-minute cooldown"
  main_drain_and_ack "$home"

  park_again "$home"
  append_status "$home" 'inside the cooldown'
  wait_until 250 host_exited "$home" || fail "latch: a close inside the cooldown did not reach main"
  assert_re '^signal: .*demo.status' "$home/host.out" "a close inside the cooldown must reach main"
  assert_no_re '^supervision-host' "$home/host.out" "a close inside the cooldown must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "the engine ran inside the cooldown"
  assert_re '	pass-through	attended	the supervision session is cooling down' "$home/state/.supervision-host.log" \
    "the ledger must record the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  park_again "$home"
  append_status "$home" 'the probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 3 ] || fail "the cooldown's end did not let one wake probe the engine"
  assert_no_re 'paused' "$home/host.out" "a failed probe must not repeat the trip line"
  assert_grep 'cooldown=600' "$home/state/.supervision-host-health" "a failed probe must double the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home" 2400
  park_again "$home"
  append_status "$home" 'a later probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the later failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 4 ] || fail "the grown cooldown's end did not let one wake probe the engine"
  assert_grep 'cooldown=3600' "$home/state/.supervision-host-health" "the doubled cooldown must stop at one hour"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  echo handle > "$home/stub-mode"
  handled=$(handled_count "$home")
  park_again "$home"
  append_status "$home" 'the probe succeeds'
  wait_until 250 handled_at_least "$home" $((handled + 1)) \
    || fail "latch: the successful probe was not handled: $(cat "$home/host.out"; tail -n 5 "$home/state/.supervision-host.log")"
  assert_re '	recovered	after a successful probe$' "$home/state/.supervision-host.log" "the ledger must record the recovery"
  ! wait_until 20 host_exited "$home" || fail "a routine probe's recovery reached main: $(cat "$home/host.out")"
  assert_no_re '^supervision-host' "$home/host.out" "a recovery must stay off main"
  assert_grep 'cooldown=0' "$home/state/.supervision-host-health" "a successful probe must clear the latch"
  assert_grep 'errors=0' "$home/state/.supervision-host-health" "a successful probe must clear the error streak"
  pass "host: attended, two engine errors latch the session, main keeps every close unchanged in the cooldown, a failed probe doubles it up to its cap, and a routine probe's recovery stays in the ledger, off main"
}

test_engine_turn_is_bounded_and_its_descendants_reaped() {
  local home orphan
  home=$(make_home away-hang away)
  echo hang > "$home/stub-mode"
  FM_SUPERVISION_HOST_TURN_TIMEOUT=3 FM_SUPERVISION_ENGINE_GRACE=1 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "hang: the host never started a watcher cycle"
  append_status "$home" 'slow one'
  wait_until 300 host_exited "$home" || fail "hang: the bounded turn did not end"
  assert_re '^supervision-host: .*the engine turn hit its 3s bound; this wake is yours$' "$home/host.out" "a bounded turn must hand its wake to main"
  orphan=$(cat "$home/orphan-pid")
  wait_until 50 sh -c '! kill -0 "$1" 2>/dev/null' _ "$orphan" \
    || fail "an engine tool process in its own process group outlived the turn: $(ps -p "$orphan" -o pid=,pgid=,command=)"
  pass "host: an engine turn is bounded, and tool processes outside its process group are reaped"
}

test_park_boundary_ends_the_park_before_the_hook_timeout() {
  local home token
  home=$(make_home boundary attended)
  # The wall-clock bound must sit past the exit check: only the injected clock
  # can reach the boundary in time, so a host ignoring it fails instead of
  # passing on real elapsed seconds.
  FM_SUPERVISION_HOST_PARK_SECONDS=60 FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary: the host never started a watcher cycle"
  echo 60 > "$home/park-clock"
  wait_until 150 host_exited "$home" || fail "boundary: the host did not end its park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the park boundary must reach main as a host line"
  watcher_live "$home" && fail "the park boundary left the watcher running"
  [ ! -e "$home/state/.supervision-handoff-pending" ] || fail "the absent opt-in changed the default boundary"
  token=$(cat "$home/state/.watcher-down")
  case "$token" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "the park boundary must publish downtime for the owner's rewake, got: $token" ;;
  esac
  pass "host: the park ends itself with a boundary wake and a stopped watcher"
}

# A leaked test clock in a real primary's environment must stay inert: the
# host reads it only alongside the FM_TEST_SEAM marker that test suites set.
test_park_test_clock_requires_the_marker() {
  local home
  home=$(make_home clock-armed away)
  echo 99999 > "$home/park-clock"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 host_exited "$home" || fail "clock-armed: the marked test clock did not end the park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the marked test clock must drive the boundary"

  home=$(make_home clock-unmarked away)
  echo 99999 > "$home/park-clock"
  FM_TEST_SEAM='' FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "clock-unmarked: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'handled on the wall clock'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "a test clock without FM_TEST_SEAM changed the park: $(cat "$home/host.out" "$home/state/.supervision-host.log")"
  [ ! -s "$home/host.rc" ] || fail "a test clock without FM_TEST_SEAM ended the park: $(cat "$home/host.out")"
  assert_no_re 'cycle boundary' "$home/host.out" "a test clock without FM_TEST_SEAM reached the boundary"
  pass "host: the park's test clock is inert without the test marker"
}

# An owner whose own bound is the park lets a turn run past the boundary up to
# its limit; a limit below the boundary or at the registration is the boundary.
test_park_limit_lets_a_turn_outlive_the_boundary() {
  local cases name limit want home
  cases='limit-later:28000:handled limit-earlier:50:boundary limit-registration:28800:boundary limit-absent::boundary'
  for c in $cases; do
    name=${c%%:*}; limit=${c#*:}; want=${limit#*:}; limit=${limit%%:*}
    home=$(make_home "$name" away)
    FM_SUPERVISION_HOST_PARK_SECONDS=100 FM_SUPERVISION_HOST_PARK_LIMIT=$limit FM_SUPERVISION_HOST_TURN_TIMEOUT=200 \
      FM_SUPERVISION_ENGINE_GRACE=10 start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$name: the host never started a watcher cycle"
    append_status "$home" 'one close'
    wait_until 250 sh -c '[ -s "$1/host.rc" ] || grep -q "	handled	" "$1/state/.supervision-host.log" 2>/dev/null' _ "$home" \
      || fail "$name: the close was neither handled nor handed to main: $(cat "$home/state/.supervision-host.log")"
    if host_exited "$home"; then
      grep -q '^supervision-host: cycle boundary - ' "$home/host.out" || fail "$name: the host exited without the boundary: $(cat "$home/host.out")"
      [ "$want" = boundary ] || fail "$name: a turn inside the owner's limit was refused at the boundary"
    else
      [ "$want" = handled ] || fail "$name: a turn past the boundary ran without a later limit"
      kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
      wait_until 200 host_exited "$home" || fail "$name: the host did not stop on TERM"
    fi
  done
  pass "host: an owner's later park limit lets a turn outlive the boundary, and no other limit does"
}

test_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event() {
  local home cycle old pid watcher
  home=$(make_home away-held-once away)
  echo captain > "$home/stub-mode"
  mkdir -p "$home/projects/held"
  git -C "$home/projects/held" init -q
  git -C "$home/projects/held" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m init
  fm_write_meta "$home/state/held.meta" \
    'window=fm-held' "worktree=$home/projects/held" "project=$home/projects/held" \
    'harness=claude' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=g1' \
    'pr=https://example.test/o/r/pull/153'
  printf 'done: PR https://example.test/o/r/pull/153 open, green, mergeable\n' > "$home/state/held.status"
  old=$(( $(date +%s) - 600 ))
  perl -e 'my $t = shift; utime $t, $t, @ARGV or exit 1' "$old" \
    "$home/state/held.meta" "$home/state/held.status" \
    || fail "fixture: could not age the held task's records"
  prime_status_seen "$home/state" "$home/state/held.status"

  export FM_FAKE_CREW_STATE_held='state: done · source: fake'
  export FM_INACTIVE_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" FM_INACTIVE_RECONCILE_SECS=60
  start_host "$home"
  wait_until 250 captain_rows_at_least "$home" 1 \
    || fail "held: the first cadence never escalated the held outcome: $(cat "$home/state/.supervision-host.log" 2>/dev/null)"
  assert_grep 'child=held' "$home/state/branch-outcomes.jsonl" "held: the escalation did not name the held task's outcome: $(cat "$home"/engine-drain.* "$home/state/.supervision-host.log")"
  wait_until 150 handled_at_least "$home" 1 || fail "held: the escalating turn never finished"
  assert_no_grep '	inactive-outcome:' "$home/state/.wake-queue" "held: the branch acknowledgement left the presentation row queued"

  for cycle in 1 2 3 4; do
    old=$(( $(date +%s) - 120 ))
    perl -e 'my $t = shift; utime $t, $t, @ARGV or exit 1' "$old" "$home/state/.inactive-outcome-reconcile" \
      || fail "held: could not age the scan marker before cadence $cycle"
    wait_until 150 scan_ran "$home" || fail "held: cadence $cycle never rescanned"
    wait_until 150 scan_idle "$home" || fail "held: cadence $cycle never finished its scan"
    ! wait_until 10 flood_signal "$home" \
      || fail "held: cadence $cycle re-escalated the unchanged held outcome: $(cat "$home/state/branch-outcomes.jsonl")"
  done
  [ "$(captain_rows "$home")" -eq 1 ] || fail "held: the unchanged situation reached the captain $(captain_rows "$home") times"
  [ -s "$home/host.rc" ] && fail "held: the host handed a wake to main: $(cat "$home/host.out")"

  printf 'needs-decision [key=merge-153]: merge PR 153 now or hold it for the return?\n' >> "$home/state/held.status"
  wait_until 250 captain_rows_at_least "$home" 2 \
    || fail "held: the new decision never reached the captain path: $(cat "$home/state/branch-outcomes.jsonl")"
  [ "$(captain_rows "$home")" -eq 2 ] || fail "held: the decision escalated $(captain_rows "$home") rows, not one"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list --recent 1 | sed -n 's/.*"task":"\([^"]*\)".*"verdict":"\([a-z]*\)".*/\1 \2/p')" = 'held captain' ] \
    || fail "held: the decision was not recorded as a captain outcome for the held task: $(cat "$home/state/branch-outcomes.jsonl")"
  unset FM_FAKE_CREW_STATE_held FM_INACTIVE_CREW_STATE_BIN FM_INACTIVE_RECONCILE_SECS
  # Stop the host and its watcher here, so no cadence scan is still writing
  # into this home while the suite's cleanup removes it.
  pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM "$pid"
  wait_until 200 host_exited "$home" || fail "held: the host did not stop on TERM"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "held: a stopped host left its watcher running"
  pass "host: an unchanged held outcome reaches the captain once across cadences, and a later decision on the task still does"
}

test_unverified_engine_hands_every_away_wake_to_main() {
  local home
  home=$(make_home no-engine away 'pi')
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "no engine: the host never started a watcher cycle"
  append_status "$home" 'anything'
  wait_until 200 host_exited "$home" || fail "no engine: the wake did not reach main"
  assert_re "^supervision-host: no supervision engine runs here: config/supervision-host names 'pi', which is not a verified supervision engine" \
    "$home/host.out" "an unverified engine must be named on the wake it hands to main"
  ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "no engine: an engine ran"
  pass "host: a home naming an unverified engine hands every away wake to main with the reason"
}


test_lost_pass_through_handoff() { assert_lost_handoff_keeps_watching pass-through; }

# A close that turns main-only at its turn hands back through the same opt-in
# path and must keep its pass-through row too. The hand-back stops the successor
# this turn confirmed, and the owner replaces that stopped arm within its poll,
# so the live-watcher check waits for it.
test_acknowledged_handoff_at_the_turn_keeps_the_pass_through_row() {
  local home
  home=$(make_primary_home hook-turns-main-only-ack)
  : > "$home/config/supervision-handoff-ack"
  turn_main_only_at_second_offer "$home"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "ack turns-main-only: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until 250 hook_exited "$home" || fail "ack turns-main-only: the Stop hook never closed: $(cat "$home/state/.supervision-host.log")"
  [ "$(cat "$home/offer-count" 2>/dev/null)" -ge 2 ] || fail "fixture: the close was not accepted before it turned main-only"
  assert_rewoke_main "$home" "ack turns-main-only"
  [ -f "$home/state/.supervision-handoff-pending" ] || fail "ack turns-main-only: the close was not handed back for acknowledgement"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "ack turns-main-only: the hand-back dropped the pass-through row"
  wait_until 150 watcher_live "$home" || fail "ack turns-main-only: the hand-back left no watcher: $(cat "$home/state/.watch-cycle-exits.log")"
  stop_home_processes "$home"
  pass "host+hook: an acknowledged hand-back at the turn keeps its pass-through row"
}

test_main_only_close_after_handled_turn_restores_inherited_handling
test_returned_driver_is_caught_attended
test_lost_pass_through_handoff
test_acknowledged_handoff_at_the_turn_keeps_the_pass_through_row
test_claude_stop_hook_restores_handoff_when_successor_closed_before_exit_to_main
test_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails
test_claude_stop_hook_notifies_when_closed_announced_successor_downtime_restore_fails
test_park_exit_probe_uses_half_second_child_sleeps
test_dispatch_entry_scopes_rows_and_renders_the_away_tail
test_branch_outcomes_put_captain_first_and_collapse_routine_overflow
test_branch_outcomes_collapse_repeated_captain_outcomes_per_task
test_branch_outcomes_present_a_long_away_window_once
test_branch_outcomes_stay_unread_without_jq
test_branch_outcomes_stay_unread_when_the_drain_cannot_print
test_branch_ack_keeps_older_keyed_decision_open
test_branch_outcomes_date_an_outcome_carried_across_a_switch_off_pi
test_branch_outcomes_keep_a_drain_presented_outcome_across_an_index_repair
test_host_stopped_right_after_a_handled_wake_exits_and_frees_the_queue
test_engine_in_another_time_zone_handles_its_granted_rows
test_off_written_while_parked_passes_the_next_attended_close_to_main
test_main_only_pass_through_leaves_the_successor_watcher_running
test_attended_close_that_turns_main_only_before_its_turn_passes_to_main
test_claude_stop_hook_delivers_a_close_that_turns_main_only_at_its_turn
test_successor_left_at_the_turn_survives_the_hook_process_group_teardown
test_pass_through_successor_survives_the_hook_process_group_teardown
test_next_park_takes_over_the_cycle_a_pass_through_left_for_main
test_a_park_stopped_mid_take_over_leaves_the_take_over_to_the_next_park
test_unrecorded_successor_is_stopped_rather_than_left_for_main
test_dialog_bearing_files_are_owner_only
test_away_wake_is_handled_on_the_engine_and_never_reaches_main
test_away_turn_without_a_report_hands_the_wake_to_main
test_silent_outcomes_are_not_relayed_when_the_captain_returns
test_outcome_lookup_failure_is_not_treated_as_silence
test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end
test_next_host_clears_a_turn_its_killed_predecessor_left
test_return_during_a_failed_turn_still_hands_its_outcomes_to_main
test_latch_trips_after_two_engine_errors_then_probes_and_recovers
test_attended_latch_keeps_closes_on_main_and_records_recovery_off_main
test_engine_turn_is_bounded_and_its_descendants_reaped
test_park_boundary_ends_the_park_before_the_hook_timeout
test_park_test_clock_requires_the_marker
test_park_limit_lets_a_turn_outlive_the_boundary
test_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event
test_unverified_engine_hands_every_away_wake_to_main
