#!/usr/bin/env bash
# tests/fm-watch-pause-precedence.test.sh - the order in which
# pause_state_class (bin/fm-watch.sh) weighs a crew's own declared wait against
# the run-based working class, and the shared-branch misattribution that makes
# the order matter.
#
# The captain's one-PR-per-repo posture puts several crews' worktrees on ONE
# long-lived feature branch. bin/fm-crew-state.sh attributes a no-mistakes run
# by BRANCH (plus a head rule that two worktrees of one branch both satisfy, since
# they follow the same ref), so a crew that has exited still inherits a co-branch
# crew's active run and reports `working`. pause_state_class used to consult that
# class BEFORE endpoint liveness, so the exited crew's empty pane was absorbed as
# provably working on every poll while the wedge timer escalated it as a possible
# wedge every STALE_ESCALATE_SECS, indefinitely.
#
# These cases pin the fix and its limits:
#   (a) real fm-crew-state.sh over two REAL git worktrees on one branch with one
#       active run proves the misattribution is live - both crews read `working`
#   (b) declared wait + confidently dead agent -> paused, never the co-branch
#       crew's `working` (the regression case)
#   (c) declared wait + LIVE agent -> working: a live crew's declaration still
#       never silences a genuinely running pipeline
#   (d) declared wait + ambiguous (unknown) liveness -> working: only a
#       confident `dead` reorders the checks
#   (e) captain hold + dead agent -> paused on the same rule as a paused line
#   (f) declared wait + dead agent + no run at all -> paused (unchanged)
#   (g) a secondmate's hold -> paused with endpoint liveness never read
#   (h) no declaration at all -> straight delegation to crew_absorb_class
#   (i) the run's real owner still classifies as working end-to-end
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-watch-pause-precedence)
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
fm_git_identity fmtest fmtest@example.invalid

# Source the watcher with an isolated state/home. Its source guard returns
# before the singleton lock and the blocking loop, so only the functions load.
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
# Production modules are independently linted canonical roots. Keep this test's
# ShellCheck context local while preserving its unchanged runtime source path.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

# --- fixture: two ship crews whose worktrees sit on ONE branch ---------------
#
# `git worktree add --force` is what reproduces the real shape: two independent
# checkouts of one branch, sharing the object store and the branch ref, so both
# resolve the SAME HEAD and both satisfy the head rule for a single run.
REPO="$TMP/repo"
OWNER_WT="$TMP/wt-owner"
CLOSED_WT="$TMP/wt-closed"
BRANCH=fm/shared-feature

mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" checkout -q -b "$BRANCH"
git -C "$REPO" worktree add -q --force "$OWNER_WT" "$BRANCH" 2>/dev/null
git -C "$REPO" worktree add -q --force "$CLOSED_WT" "$BRANCH" 2>/dev/null
SHARED_HEAD=$(git -C "$OWNER_WT" rev-parse HEAD)
[ -n "$SHARED_HEAD" ] || fail "fixture: shared branch head did not resolve"
[ "$(git -C "$CLOSED_WT" rev-parse HEAD)" = "$SHARED_HEAD" ] \
  || fail "fixture: the two worktrees are not on the same head"

# A fake `no-mistakes` serving ONE active run for the shared branch, mirroring
# the surface bin/fm-crew-state.sh uses (`axi status`; the top-level `runs`
# listing is the cross-branch fallback). The real CLI answers the SAME run from
# either worktree - `axi status` is repo-scoped, not worktree-scoped - so the
# fake is deliberately blind to the caller's directory too.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status) printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
      logs)   printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1; printf '%%1\n' ;;
  capture-pane)    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1; printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/no-mistakes" "$FAKEBIN/tmux"
export PATH="$FAKEBIN:$PATH"

run_running() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "$2"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

FM_FAKE_AXI_STATUS="$(run_running "$BRANCH" "$SHARED_HEAD")"
FM_FAKE_RUNS_LIST=""
FM_FAKE_CI_LOGS=""
FM_FAKE_TMUX_MISSING=0
export FM_FAKE_AXI_STATUS FM_FAKE_RUNS_LIST FM_FAKE_CI_LOGS FM_FAKE_TMUX_MISSING

fm_write_meta "$STATE_DIR/owner.meta" "window=fm:fm-owner" "worktree=$OWNER_WT" \
  "kind=ship" "mode=no-mistakes"
# Both crews ship no-mistakes and NEITHER is bound to the run, so this file
# exercises the legacy shape bin/fm-crew-state.sh still serves by branch. The
# binding and delivery-mode guards that separate two such crews are owned by
# tests/fm-crew-state.test.sh; what these cases pin is that pause_state_class
# stops trusting the branch verdict for a crew whose agent is gone.
fm_write_meta "$STATE_DIR/closed.meta" "window=fm:fm-closed" "worktree=$CLOSED_WT" \
  "kind=ship" "mode=no-mistakes"
fm_write_meta "$STATE_DIR/mate.meta" "window=fm:fm-mate" "worktree=$TMP/mate-home" \
  "kind=secondmate"
mkdir -p "$TMP/mate-home"

OWNER_WIN=fm:fm-owner
CLOSED_WIN=fm:fm-closed
MATE_WIN=fm:fm-mate

# --- liveness stub -----------------------------------------------------------
#
# The one input pause_state_class must weigh against the run class. Overridden
# after sourcing so no real backend is probed and each case states the verdict
# it is describing. Every call is journalled to a FILE, not a variable: the cases
# read the class through a command substitution, so a probe made inside that
# subshell would leave no trace in the parent otherwise.
FAKE_ALIVE=dead
PROBE_LOG="$TMP/liveness-probes"
: > "$PROBE_LOG"
fm_backend_agent_alive() {
  printf 'probe\n' >> "$PROBE_LOG"
  printf '%s\n' "$FAKE_ALIVE"
}

probe_count() {
  wc -l < "$PROBE_LOG" | tr -d '[:space:]'
}

# assert_class <actual> <expected> <msg>: the class token is a whole word, so
# these cases compare it exactly rather than by substring.
assert_class() {
  [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"
}

# Reset every per-window marker pause_state_class reads or writes, so each case
# enters on the first-sighting path rather than the bounded-recheck branch.
reset_markers() {
  rm -f "$STATE_DIR"/.paused-* "$STATE_DIR"/.paused-rechecked-* \
    "$STATE_DIR"/.paused-resurfaced-*
}

set_status() {  # <task> <line...>
  printf '%s\n' "$2" > "$STATE_DIR/$1.status"
}

# --- (a) the misattribution itself, over the REAL helper ---------------------
test_shared_branch_run_is_attributed_to_both_crews() {
  reset_markers
  local owner closed
  owner=$("$ROOT/bin/fm-crew-state.sh" owner)
  closed=$("$ROOT/bin/fm-crew-state.sh" closed)
  assert_contains "$owner" "state: working" "the run's owner reads working"
  assert_contains "$owner" "source: run-step" "the run's owner reads it from the run step"
  # NOT an endorsement: this is the defect pause_state_class must not trust for a
  # crew whose agent is gone. Branch attribution cannot tell the two crews apart,
  # so the closed crew inherits the same active run.
  assert_contains "$closed" "state: working" \
    "fixture must reproduce the shared-branch misattribution (closed crew reads working)"
  pass "one active run on a shared branch is attributed to BOTH crews by branch"
}

# --- (b) the regression: declared wait + dead agent ---------------------------
test_declared_pause_on_dead_agent_beats_cobranch_run() {
  reset_markers
  set_status closed "paused: waiting on the captain's merge"
  FAKE_ALIVE=dead
  local class
  class=$(pause_state_class "$CLOSED_WIN" closed)
  assert_class "$class" paused "a declared wait on a dead agent classifies as paused"
  assert_present "$STATE_DIR/.paused-rechecked-$(window_key "$CLOSED_WIN")" \
    "the paused verdict must arm the bounded re-surface cadence"
  pass "declared wait + dead agent classifies paused, not the co-branch run's working"
}

# --- (c) a LIVE agent's declaration still never silences a running pipeline ---
test_declared_pause_on_live_agent_still_reports_working() {
  reset_markers
  set_status owner "paused: waiting on CI"
  FAKE_ALIVE=alive
  local class
  class=$(pause_state_class "$OWNER_WIN" owner)
  assert_class "$class" working \
    "a live agent's declaration must not silence its genuinely running pipeline"
  pass "declared wait + live agent still reports working"
}

# --- (d) ambiguous liveness keeps the existing order -------------------------
test_declared_pause_on_unknown_liveness_reports_working() {
  reset_markers
  set_status owner "paused: waiting on CI"
  FAKE_ALIVE=unknown
  local class
  class=$(pause_state_class "$OWNER_WIN" owner)
  assert_class "$class" working \
    "only a confident dead verdict may reorder the checks; unknown keeps working"
  pass "declared wait + ambiguous liveness keeps the working class"
}

# --- (e) a captain hold takes the same rule ----------------------------------
test_captain_hold_on_dead_agent_classifies_paused() {
  reset_markers
  set_status closed "captain-held: waiting on the captain's call"
  FAKE_ALIVE=dead
  local class
  class=$(pause_state_class "$CLOSED_WIN" closed)
  assert_class "$class" paused "a captain hold on a dead agent classifies as paused"
  pass "captain hold + dead agent classifies paused"
}

# --- (f) the unchanged case: dead agent, no run anywhere ---------------------
test_declared_pause_dead_agent_no_run_is_paused() {
  reset_markers
  set_status closed "paused: waiting on an upstream release"
  FAKE_ALIVE=dead
  local class saved=$FM_FAKE_AXI_STATUS
  FM_FAKE_AXI_STATUS=""
  class=$(pause_state_class "$CLOSED_WIN" closed)
  FM_FAKE_AXI_STATUS=$saved
  assert_class "$class" paused "a declared wait with no run at all stays paused"
  pass "declared wait + dead agent + no run classifies paused"
}

# --- (g) a secondmate's endpoint liveness is never read ----------------------
test_secondmate_hold_never_reads_liveness() {
  reset_markers
  set_status mate "captain-held: waiting on the captain's call"
  local class probes_before probes_after
  probes_before=$(probe_count)
  FAKE_ALIVE=alive
  class=$(pause_state_class "$MATE_WIN" mate)
  probes_after=$(probe_count)
  assert_class "$class" paused "a mate's captain hold still classifies as paused"
  [ "$probes_before" = "$probes_after" ] \
    || fail "a secondmate's endpoint liveness must never be probed"
  pass "secondmate hold classifies paused with liveness never probed"
}

# --- (h) no declaration delegates straight to the absorb class ---------------
test_no_declaration_delegates_to_absorb_class() {
  reset_markers
  set_status owner "working: implementing"
  FAKE_ALIVE=dead
  local class
  class=$(pause_state_class "$OWNER_WIN" owner)
  assert_class "$class" working \
    "with no declared wait the absorb class answers unchanged, dead agent or not"
  pass "no declaration delegates straight to crew_absorb_class"
}

# --- (i) the run's real owner is still working end-to-end -------------------
test_run_owner_still_provably_working() {
  reset_markers
  set_status owner "working: validating"
  crew_is_provably_working owner \
    || fail "the run's real owner must still be provably working"
  pass "the run's real owner still classifies as working"
}

test_shared_branch_run_is_attributed_to_both_crews
test_declared_pause_on_dead_agent_beats_cobranch_run
test_declared_pause_on_live_agent_still_reports_working
test_declared_pause_on_unknown_liveness_reports_working
test_captain_hold_on_dead_agent_classifies_paused
test_declared_pause_dead_agent_no_run_is_paused
test_secondmate_hold_never_reads_liveness
test_no_declaration_delegates_to_absorb_class
test_run_owner_still_provably_working

printf '# fm-watch-pause-precedence.test.sh: all assertions passed\n'
