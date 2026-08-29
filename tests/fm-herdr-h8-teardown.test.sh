#!/usr/bin/env bash
# GATE h8 - teardown closes the pane, on the surface that created it.
#
# THE DEFECT THIS FREEZES (Quarterdeck reject, attempt 1). The brief listed
# "teardown closes it" as a gate and it was never implemented.
# bin/fm-teardown.sh passed the meta's `window=` - a herdr PANE ID for every
# crewmate spawned after the cutover - to `tmux kill-window`, swallowed the
# failure with `|| true`, deleted the meta, and printed "teardown complete".
# The tab leaked, untracked, possibly still running an agent, while firstmate
# believed the work was cleaned up. fm_herdr_close existed and worked; teardown
# simply never called it.
#
# The only prior "coverage" was a grep in h6 asserting `tmux kill-window` is
# still PRESENT for the drain. That proves the drain path survives. It says
# nothing about whether a herdr pane is ever closed - a gate can be green while
# the thing it is named for has never been done.
#
# WHAT IS GATED:
#   * a post-cutover meta (mux=herdr) is closed with herdr verbs
#   * a pre-cutover meta (no mux= line) is still closed with tmux - the drain
#   * a close that FAILS is reported, not swallowed under a success message
#   * a pane that is ALREADY GONE is a success, not a false leftover-pane alarm
#   * LIVE: a real herdr tab created by the library is really gone afterwards
set -u

# This gate's live half needs the real binary; tests/lib.sh otherwise shims it
# away so no suite can touch the captain's live server by accident.
FM_TEST_ALLOW_LIVE_HERDR=1

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"
# shellcheck source=bin/fm-herdr.sh
. "$ROOT/bin/fm-herdr.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-h8)

# Re-entrant mode: run ONLY the live case. Used by the strict-mode self-check
# below so it can prove the guard's ordering without recursing into itself.
LIVE_ONLY=0
[ "${1:-}" = "__live_only" ] && LIVE_ONLY=1

# --- the routing: each surface closes its own ------------------------------

test_a_herdr_pane_is_closed_with_herdr() {
  local fb calls
  fb=$(fm_herdr_fake_server "$TMP_ROOT/route")
  calls="$TMP_ROOT/route-calls"; : > "$calls"
  PATH="$fb:$PATH" CALLS="$calls" fm_herdr_close_pane "wM:p2" herdr
  assert_grep "tab close" "$calls" "a herdr pane was not closed with herdr"
  assert_no_grep "kill-window" "$calls" "a herdr pane was closed with a tmux verb"
  pass "teardown: a post-cutover pane is closed with herdr verbs"
}

test_a_pre_cutover_window_is_still_closed_with_tmux() {
  local fb calls
  fb=$(fm_herdr_fake_tmux "$TMP_ROOT/drain")
  calls="$TMP_ROOT/drain-calls"; : > "$calls"
  PATH="$fb:$PATH" CALLS="$calls" fm_herdr_close_pane "firstmate:fm-old" ""
  assert_grep "kill-window -t firstmate:fm-old" "$calls" \
    "a draining tmux window was not closed; teardown would strand it"
  pass "teardown: a pre-cutover window is still closed with tmux (the drain)"
}

# A close that could not happen must SAY SO. Swallowing it under "teardown
# complete" is what let the tab leak unnoticed in the first place.
test_a_failed_close_is_reported() {
  local out rc=0 clean
  clean=$(fm_herdr_path_without_binary herdr)
  out=$(PATH="$clean" fm_herdr_close_pane "wM:p2" herdr 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then fail "a close that could not run reported success"; fi
  assert_contains "$out" "wM:p2" "the failure does not name the pane that was left behind"
  pass "teardown: a close that fails is reported, not swallowed"
}

# THE OTHER HALF, and the one that makes the warning above worth reading. A pane
# the captain closed by hand is an ordinary path, and herdr answers rc=1 for it
# on every close verb - so reading the exit code alone sent firstmate hunting a
# leaked tab that does not exist, on every hand-closed crewmate. A warning that
# cries wolf is a warning nobody acts on.
test_an_already_closed_pane_is_a_successful_close() {
  local fb out rc=0
  fb=$(fm_herdr_fake_server "$TMP_ROOT/gone")
  out=$(PATH="$fb:$PATH" HERDR_GONE=1 fm_herdr_close_pane "wM:p2" herdr 2>&1) || rc=$?
  expect_code 0 "$rc" "a pane that is already gone was reported as a close that failed"
  assert_eq "$out" "" "an already-gone pane produced a leftover-pane warning"
  pass "teardown: a pane that is already gone is a successful close, not a leak"
}

# The same truth on the OTHER branch. `tmux kill-window` also fails for a window
# that no longer exists, so the drain path cried the same wolf for a pre-cutover
# window the captain had closed himself. Both surfaces answer the same question:
# is the window still there?
test_an_already_closed_drain_window_is_a_successful_close() {
  local fb out rc=0
  fb=$(fm_herdr_fake_tmux "$TMP_ROOT/drain-gone")
  out=$(PATH="$fb:$PATH" CALLS="$TMP_ROOT/drain-gone-calls" TMUX_RC=1 TMUX_WINDOWS="" \
    fm_herdr_close_pane "firstmate:fm-old" "" 2>&1) || rc=$?
  expect_code 0 "$rc" "a drained window that is already gone was reported as a close that failed"
  assert_eq "$out" "" "an already-gone tmux window produced a leftover-window warning"
  pass "teardown: a drained window that is already gone is a successful close, not a leak"
}

# And the warning still means something: a window that IS there and would not
# close is the case teardown must not swallow.
test_a_drain_window_that_will_not_close_is_reported() {
  local fb out rc=0
  fb=$(fm_herdr_fake_tmux "$TMP_ROOT/drain-stuck")
  out=$(PATH="$fb:$PATH" CALLS="$TMP_ROOT/drain-stuck-calls" TMUX_RC=1 \
    TMUX_WINDOWS="firstmate:fm-old" \
    fm_herdr_close_pane "firstmate:fm-old" "" 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then fail "a drained window that is still open reported a successful close"; fi
  assert_contains "$out" "firstmate:fm-old" "the failure does not name the window left behind"
  pass "teardown: a drained window that will not close is still reported"
}

# GONE MUST BE OBSERVED, NEVER INFERRED FROM SILENCE. The two cases above both
# read the window listing, and an unreadable listing is empty for the same
# reason a hand-closed window is: nothing names the target. Concluding "gone"
# from that reports a successful close for a window nothing ever touched -
# teardown then warns about nothing, deletes the meta and calls itself complete,
# which is the same leak the helper exists to stop, reached by a different road.
test_an_undeterminable_drain_window_is_not_called_gone() {
  local fb out rc=0
  # 1. tmux answers, but the listing itself failed.
  fb=$(fm_herdr_fake_tmux "$TMP_ROOT/drain-unreadable")
  out=$(PATH="$fb:$PATH" CALLS="$TMP_ROOT/drain-unreadable-calls" TMUX_RC=1     TMUX_LIST_RC=1 TMUX_WINDOWS=""     fm_herdr_close_pane "firstmate:fm-old" "" 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then
    fail "an unreadable window listing was read as proof the window is gone"
  fi
  assert_contains "$out" "firstmate:fm-old" "the failure does not name the window it could not close"
  assert_contains "$out" "could not determine"     "the failure does not distinguish 'still open' from 'could not tell'"

  # 2. tmux is not on PATH at all - the same silence, no server involved.
  rc=0
  out=$(PATH="$(fm_herdr_path_without_binary tmux)"     fm_herdr_close_pane "firstmate:fm-old" "" 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then
    fail "an absent tmux was read as proof the window is gone"
  fi
  assert_contains "$out" "could not determine"     "an absent tmux did not report that the outcome is unknown"
  pass "teardown: a close that cannot be verified is reported, not called gone"
}

# --- teardown itself calls it ----------------------------------------------

# The routing being right is worthless if teardown never reaches it. This is the
# assertion whose absence let the defect through.
test_fm_teardown_closes_through_the_surface() {
  local body
  body=$(grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-teardown.sh")
  case "$body" in
    *"fm_herdr_close_pane"*) : ;;
    *) fail "fm-teardown never closes through the surface; a herdr tab would leak" ;;
  esac
  # And it must not be reaching past the helper straight at tmux for the task's
  # own window any more.
  # shellcheck disable=SC2016  # matching the literal source text, not expanding it
  if printf '%s' "$body" | grep -qE 'tmux kill-window -t "\$T"'; then
    fail "fm-teardown still kills the task's own window with a raw tmux call"
  fi
  pass "teardown: fm-teardown.sh routes its closes through the surface helper"
}

# --- LIVE: the tab is really gone -------------------------------------------

test_live_a_real_herdr_tab_is_really_closed() {
  # Order matters, and getting it wrong is how a strict-mode guard becomes a
  # strict-mode BUG: this checked FM_TEST_REQUIRE_LIVE before reachability, so
  # it failed even with the server up - refusing to run the very case it exists
  # to force. Reachability first; the switch only decides what an unreachable
  # server MEANS (a hard failure instead of a skip).
  if ! fm_herdr_up && [ "${FM_TEST_REQUIRE_LIVE:-0}" = 1 ]; then
    fail "FM_TEST_REQUIRE_LIVE=1 but no herdr server is reachable; this gate cannot be proven here"
  fi
  if ! fm_herdr_up; then
    printf 'SKIP - the live half of h8 needs a herdr server; the routing cases above still ran.\n' >&2
    return 0
  fi
  local ws pane workdir waited
  workdir="$TMP_ROOT/live"; mkdir -p "$workdir"; workdir=$(cd "$workdir" && pwd -P)
  ws=$(FM_HERDR_WORKSPACE='' fm_herdr_workspace_for "fm-gate-h8-$$" "$workdir") \
    || fail "could not create a throwaway workspace"
  pane=$(fm_herdr_new_tab "$ws" "gate-h8-probe" "$workdir") || {
    herdr workspace close "$ws" >/dev/null 2>&1
    fail "could not create a real tab"; }
  herdr pane get "$pane" >/dev/null 2>&1 || {
    herdr workspace close "$ws" >/dev/null 2>&1
    fail "the tab was not really created"; }

  fm_herdr_close_pane "$pane" herdr || {
    herdr workspace close "$ws" >/dev/null 2>&1
    fail "close reported failure against a real tab"; }

  waited=0
  while [ "$waited" -lt 20 ]; do
    waited=$((waited + 1))
    herdr pane get "$pane" >/dev/null 2>&1 || break
    sleep 0.25
  done
  if herdr pane get "$pane" >/dev/null 2>&1; then
    herdr workspace close "$ws" >/dev/null 2>&1
    fail "the real tab is still there after teardown closed it"
  fi
  herdr workspace close "$ws" >/dev/null 2>&1
  pass "teardown: a real herdr tab is really gone after the close"
}

# THE GUARD IS ITSELF GATED. A strict-mode switch that fires when it should not
# is worse than no switch: it makes the live case unrunnable exactly when someone
# is trying hardest to prove it. This asserts the ordering directly.
test_strict_mode_does_not_fire_against_a_live_server() {
  if ! fm_herdr_up; then
    printf 'SKIP - the strict-mode ordering check needs a live server to be meaningful.\n' >&2
    return 0
  fi
  local rc=0
  FM_TEST_REQUIRE_LIVE=1 bash "$0" __live_only >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "strict mode failed with a reachable server; the guard checks the switch before reachability"
  pass "strict mode: with a server up, FM_TEST_REQUIRE_LIVE runs the live case instead of failing it"
}

if [ "$LIVE_ONLY" = 1 ]; then
  # Re-entered by the strict-mode self-check: run ONLY the live case, so the
  # check proves the guard's ordering without recursing into itself.
  test_live_a_real_herdr_tab_is_really_closed
  exit 0
fi

test_strict_mode_does_not_fire_against_a_live_server
test_a_herdr_pane_is_closed_with_herdr
test_a_pre_cutover_window_is_still_closed_with_tmux
test_a_failed_close_is_reported
test_an_already_closed_pane_is_a_successful_close
test_an_already_closed_drain_window_is_a_successful_close
test_a_drain_window_that_will_not_close_is_reported
test_an_undeterminable_drain_window_is_not_called_gone
test_fm_teardown_closes_through_the_surface
test_live_a_real_herdr_tab_is_really_closed
