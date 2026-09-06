#!/usr/bin/env bash
# tests/fm-watch-replay-gate.test.sh - durable-state verdicts for re-presenting
# a persisted Pi replacement-session actionable wake. The gate is the boundary
# that keeps an already-acknowledged wake from looping across session
# replacements, so each drop rule and each safe-direction deliver here drives
# the real script against a real state directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-watch-replay-gate.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-replay-gate)

new_home() {  # <name>
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

write_meta() {  # <state> <task> <window>
  printf 'window=%s\n' "$3" > "$1/$2.meta"
}

verdict() {  # <state> <reason>
  FM_STATE_OVERRIDE="$1" "$GATE" "$2"
}

test_gate_drops_replay_when_queue_empty_and_episode_acked() {
  local home
  home=$(new_home acked-episode)
  printf 'acked:handling:130247.1788720192.pbH0L2\n' > "$home/state/.watcher-down"
  out=$(verdict "$home/state" "stale: default:wMA:p2")
  expect_code 0 "$?" "gate must exit 0 on a drop verdict"
  [ "$out" = "drop empty-queue-acked-recovery" ] || fail "expected the acked-episode drop, got: $out"
  pass "empty queue plus an acked recovery episode drops the replay"
}

test_gate_drops_replay_when_queue_empty_and_no_marker() {
  local home
  home=$(new_home no-marker)
  out=$(verdict "$home/state" "stale: default:wMA:p2")
  [ "$out" = "drop empty-queue-acked-recovery" ] || fail "expected the no-marker drop, got: $out"
  pass "empty queue with no recovery episode at all drops the replay"
}

test_gate_delivers_when_a_recovery_episode_is_still_outstanding() {
  local home
  home=$(new_home pending-episode)
  printf 'pending:handling:130247.1788720192.pbH0L2\n' > "$home/state/.watcher-down"
  out=$(verdict "$home/state" "stale: default:wMA:p2")
  [ "$out" = "deliver" ] || fail "an outstanding episode must deliver, got: $out"
  pass "an unacked recovery episode keeps the replay eligible"
}

test_gate_delivers_when_the_stale_row_is_still_queued() {
  local home
  home=$(new_home row-queued)
  write_meta "$home/state" task-a default:wMA:p2
  printf '1\t1\tstale\tdefault:wMA:p2\tstale: default:wMA:p2\n' > "$home/state/.wake-queue"
  out=$(verdict "$home/state" "stale: default:wMA:p2")
  [ "$out" = "deliver" ] || fail "a queued row must deliver, got: $out"
  pass "a still-queued stale row for a live task delivers the replay"
}

test_gate_drops_stale_replay_when_no_meta_records_the_window() {
  local home out
  home=$(new_home window-gone)
  # An unrelated queued row keeps the global empty-queue rule out of the way,
  # so only the window rule can produce this verdict.
  printf '1\t1\tstale\tother:win\tstale: other:win\n' > "$home/state/.wake-queue"
  out=$(verdict "$home/state" "stale: default:wMA:p2")
  [ "$out" = "drop stale-window-task-gone" ] || fail "expected the torn-down-window drop, got: $out"
  pass "a stale replay whose window has no task meta is dropped"
}

test_gate_drops_stale_replay_when_its_row_was_acked() {
  local home out
  home=$(new_home row-acked)
  write_meta "$home/state" task-a default:wMA:p2
  # The task still exists but its stale row was acknowledged; another task's
  # row keeps the queue non-empty past the global rule.
  printf '1\t1\tstale\tother:win\tstale: other:win\n' > "$home/state/.wake-queue"
  out=$(verdict "$home/state" "stale: default:wMA:p2")
  [ "$out" = "drop referenced-wake-acked" ] || fail "expected the acked-row drop, got: $out"
  pass "a stale replay whose own row was acknowledged is dropped"
}

test_gate_decorated_stale_reason_parses_its_window() {
  local home out
  home=$(new_home decorated-stale)
  # A decoy row keeps the global empty-queue rule out of the way, so this case
  # exercises only the window parse.
  printf '1\t1\tstale\tother:win\tstale: other:win\n' > "$home/state/.wake-queue"
  printf '2\t2\tstale\tfm-live\tstale: fm-live (idle 480s, possible wedge, escalation 2)\n' >> "$home/state/.wake-queue"
  write_meta "$home/state" task-a fm-live
  out=$(verdict "$home/state" "stale: fm-live (idle 480s, possible wedge, escalation 2)")
  [ "$out" = "deliver" ] || fail "a decorated reason must still parse its window, got: $out"
  rm -f "$home/state/task-a.meta"
  out=$(verdict "$home/state" "stale: fm-live (idle 480s, possible wedge, escalation 2)")
  [ "$out" = "drop stale-window-task-gone" ] || fail "decorated reason missed the torn-down window, got: $out"
  pass "a decorated stale reason is parsed down to its window"
}

test_gate_delivers_non_stale_reasons_on_a_non_empty_queue() {
  local home out
  home=$(new_home check-replay)
  printf '1\t1\tstale\tother:win\tstale: other:win\n' > "$home/state/.wake-queue"
  out=$(verdict "$home/state" "check: process-event result captured: lavish-abcd")
  [ "$out" = "deliver" ] || fail "a check replay on a non-empty queue must deliver, got: $out"
  out=$(verdict "$home/state" "heartbeat")
  [ "$out" = "deliver" ] || fail "a heartbeat replay on a non-empty queue must deliver, got: $out"
  pass "non-stale replays rely on the global rule and stay bounded by the accept-once rule"
}

test_gate_drops_any_replay_when_the_queue_is_empty_even_unparsed() {
  local home out
  home=$(new_home empty-queue-check)
  printf 'acked:handling:g.1\n' > "$home/state/.watcher-down"
  out=$(verdict "$home/state" "check: x-mention 1234567890")
  [ "$out" = "drop empty-queue-acked-recovery" ] || fail "expected the global drop, got: $out"
  out=$(verdict "$home/state" "heartbeat")
  [ "$out" = "drop empty-queue-acked-recovery" ] || fail "expected the global drop for heartbeat, got: $out"
  pass "an empty queue plus an acked episode drops any kind of replay"
}

test_gate_delivers_when_durable_state_is_unreadable() {
  local home out
  home=$(new_home unreadable-marker)
  printf 'garbage that is not a marker token\n' > "$home/state/.watcher-down"
  out=$(verdict "$home/state" "stale: default:wMA:p2")
  [ "$out" = "deliver" ] || fail "an unreadable marker must deliver, got: $out"
  pass "unreadable durable state answers deliver, the safe direction"
}

test_gate_rejects_missing_reason_argument() {
  local out status
  out=$(FM_STATE_OVERRIDE="$(new_home usage)/state" "$GATE" 2>/dev/null)
  status=$?
  expect_code 2 "$status" "the gate must exit 2 without a reason argument"
  [ -z "$out" ] || fail "usage failure printed stdout: $out"
  pass "the gate refuses to run without its reason argument"
}

test_gate_torn_down_task_whose_row_lingers_is_dropped() {
  # The incident shape: the task was torn down while a stale row for its
  # window was still unacknowledged. The replay must stop even though a row
  # exists, because the subject task is gone; the durable row itself still
  # reaches main through the next drain.
  local home out
  home=$(new_home lingering-row)
  printf '1\t1\tstale\tdefault:wMA:p2\tstale: default:wMA:p2\n' > "$home/state/.wake-queue"
  out=$(verdict "$home/state" "stale: default:wMA:p2")
  [ "$out" = "drop stale-window-task-gone" ] || fail "expected the torn-down-window drop, got: $out"
  pass "a lingering row for a torn-down task does not resurrect its replay"
}

test_gate_accepts_orca_terminal_window_targets() {
  local home out
  home=$(new_home orca-terminal)
  printf 'backend=orca\nterminal=default:wMA:p2\n' > "$home/state/task-o.meta"
  printf '1\t1\tstale\tdefault:wMA:p2\tstale: default:wMA:p2\n' > "$home/state/.wake-queue"
  out=$(verdict "$home/state" "stale: default:wMA:p2")
  [ "$out" = "deliver" ] || fail "an orca terminal target must count as recorded, got: $out"
  pass "the window lookup mirrors the watcher's own target derivation"
}

test_gate_drops_replay_when_queue_empty_and_episode_acked
test_gate_drops_replay_when_queue_empty_and_no_marker
test_gate_delivers_when_a_recovery_episode_is_still_outstanding
test_gate_delivers_when_the_stale_row_is_still_queued
test_gate_drops_stale_replay_when_no_meta_records_the_window
test_gate_drops_stale_replay_when_its_row_was_acked
test_gate_decorated_stale_reason_parses_its_window
test_gate_delivers_non_stale_reasons_on_a_non_empty_queue
test_gate_drops_any_replay_when_the_queue_is_empty_even_unparsed
test_gate_delivers_when_durable_state_is_unreadable
test_gate_rejects_missing_reason_argument
test_gate_torn_down_task_whose_row_lingers_is_dropped
test_gate_accepts_orca_terminal_window_targets
