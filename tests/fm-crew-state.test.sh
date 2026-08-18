#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-state.sh - the deterministic crew-current-state
# helper.
#
# The status file (state/<id>.status) is a best-effort append-only EVENT LOG, so
# `tail -1` of it reports the last event, not the current state. fm-crew-state
# reads the AUTHORITATIVE source (a matching no-mistakes run-step, else the
# semantic busy-state contract) and reconciles the possibly-stale log against it. These
# cases pin every branch of that logic, hermetically, over real throwaway git
# repos with a fake `no-mistakes` (run-step source) and a fake `tmux` (pane
# source):
#   (a) active run-step is authoritative                          -> run-step
#   (b) needs-decision/blocked log + resumed run = SUPERSEDED     -> run-step
#   (c) genuine parked run + needs-decision log = NOT superseded  -> run-step
#   (d) terminal run-step (passed/failed) is authoritative        -> run-step
#   (e) cross-branch attribution: this branch's own run found via list lookup
#   (f) no run + semantic busy                                    -> pane
#   (g) no run + semantic idle falls to the status-log verb       -> status-log
#   (h) dead pane: no run -> unknown/none; with a run -> run-step (not the shell)
#   (i) kind=scout skips the run lookup                           -> pane/status-log
#   (j) torn-down worktree / missing meta                         -> unknown/none
#   (k) crew_is_provably_working end-to-end over the REAL helper (not a canned
#       fake fm-crew-state.sh verdict): cross-branch attribution via the runs
#       list -> absorbed; genuinely no run anywhere + idle pane -> surfaced.
#       This is the direct regression pair for the 2026-07-02 herdr incident,
#       proving the watcher's own absorb-only-when-provably-working predicate
#       benefits from the fix in both directions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state)
fm_git_identity fmtest fmtest@example.invalid

# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live crew worktree.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  # Real worktree HEAD for run head-binding (fixtures read FM_FAKE_RUN_HEAD).
  FM_FAKE_RUN_HEAD=$(git -C "$dir" rev-parse HEAD)
  export FM_FAKE_RUN_HEAD
}

# A commit that exists in <dir> but is neither the current HEAD nor a descendant
# of it - the shape a pipeline leaves behind when it rebases its work onto
# another base while the crew's own copy stays put. Kept reachable by its own
# branch so the repo can still resolve it; HEAD is restored before returning.
make_diverged_commit() {  # <dir> -> echoes the diverged commit sha
  local dir=$1 branch sha
  branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD)
  git -C "$dir" checkout -q --orphan fm-test-diverged
  git -C "$dir" commit -q --allow-empty -m 'pipeline rebased head'
  sha=$(git -C "$dir" rev-parse HEAD)
  git -C "$dir" checkout -q "$branch"
  git -C "$dir" merge-base --is-ancestor HEAD "$sha" 2>/dev/null \
    && fail "make_diverged_commit produced a descendant, not a diverged head"
  printf '%s\n' "$sha"
}

# A fakebin with a fake `no-mistakes` (serves the env-driven run output) and a
# fake `tmux` (serves a busy or idle pane). The fake no-mistakes mirrors the real
# command surface the helper uses: `axi status`, `axi status --run <id>` (the
# `axi` surface - no runs-listing subcommand exists under it, verified against
# the real CLI), and the actual top-level run-listing command, `no-mistakes
# runs --limit N`, which is plain text - no run id, no quoting - serving
# FM_FAKE_RUNS_LIST verbatim.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
      logs)
        printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs)
    printf 'runs\n' >> "${FM_FAKE_RUNS_CALL_LOG:-/dev/null}"
    [ "${FM_FAKE_RUNS_FAIL:-0}" = 1 ] && exit 124
    printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\n%s\n' "${FM_FAKE_BUSY_TEXT:-esc to interrupt}"
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    [ "${2:-}" = --json ] && {
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
      exit 0
    } ;;
  server)
    exit 0 ;;
  pane)
    case "${2:-}" in
      read)
        [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$FM_FAKE_HERDR_AGENT_STATUS"
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/herdr"
  printf '%s\n' "$fb"
}

make_no_timeout_toolbin() {  # <dir> -> echoes toolbin path
  local dir=$1 tb="$1/notimeoutbin" tool real
  mkdir -p "$tb"
  for tool in bash git grep sed head cut tail dirname perl; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for no-timeout path: $tool"
    ln -s "$real" "$tb/$tool"
  done
  printf '%s\n' "$tb"
}

# Run the helper for one case dir. FM_FAKE_* env (run output, busy flag) are read
# from the caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

# `no-mistakes runs` invocations recorded by the fake, for the supersession
# probe's cost assertions.
assert_runs_calls() {  # <expected> <log> <msg>
  local actual=0
  [ -f "$2" ] && actual=$(awk 'END { print NR + 0 }' "$2")
  [ "$actual" = "$1" ] || fail "$3 (expected $1 runs calls, got $actual)"
}

arm_idle_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_AXI_STATUS_RUN=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  FM_FAKE_BUSY_TEXT=
  FM_FAKE_TMUX_MISSING=0
  FM_FAKE_HERDR_BUSY=0
  FM_FAKE_HERDR_MISSING=0
  FM_FAKE_HERDR_AGENT_STATUS=""
  FM_FAKE_CI_LOGS=""
  FM_FAKE_RUNS_CALL_LOG=/dev/null
  FM_FAKE_RUNS_FAIL=0
  export FM_FAKE_RUNS_CALL_LOG FM_FAKE_RUNS_FAIL
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_BUSY FM_FAKE_BUSY_TEXT FM_FAKE_TMUX_MISSING
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_CI_LOGS
}

# --- run-object fixtures (TOON, as `no-mistakes axi status` emits) -----------

run_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

run_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
EOF
}

run_top_level_ci() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ci
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
EOF
}

run_parked() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_scalar_gate_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_in_gate_block() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate:
  step: review
  status: fix_review
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  review,fix_review,1,0
  test,pending,0,0
EOF
}

run_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed
EOF
}

run_failed() {  # <branch>
  run_outcome "$1" failed
}

# Any terminal run object, by outcome word (failed, cancelled, passed, ...).
run_outcome() {  # <branch> <outcome>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: $2
EOF
}

run_ci_monitoring() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_fixing_ci_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_ci_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,fixing,0,0
EOF
}

# ---------------------------------------------------------------------------
# (a) active run-step is authoritative
test_active_run_is_authoritative() {
  reset_fakes
  local d; d=$(new_case active)
  make_repo_on_branch "$d/wt" fm/feat-a
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-a.meta" "window=fm:fm-feat-a" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-a)"
  local out; out=$(run_crew_state "$d" feat-a)
  assert_contains "$out" "state: working" "active run -> working"
  assert_contains "$out" "source: run-step" "active run -> run-step source"
  assert_contains "$out" "validating (running)" "active run reports the step"
  pass "active run-step is authoritative"
}

# (b) needs-decision log + a resumed (running/fixing) run = SUPERSEDED
test_stale_needs_decision_superseded() {
  reset_fakes
  local d; d=$(new_case superseded)
  make_repo_on_branch "$d/wt" fm/feat-b
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-b.meta" "window=fm:fm-feat-b" "worktree=$d/wt" "kind=ship"
  printf 'working: started\nneeds-decision: pick A or B\n' > "$d/state/feat-b.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-b)"
  local out; out=$(run_crew_state "$d" feat-b)
  assert_contains "$out" "state: working" "resumed run -> working despite needs-decision log"
  assert_contains "$out" "source: run-step" "resumed run -> run-step source"
  assert_contains "$out" "superseded" "stale needs-decision log flagged superseded"
  pass "stale needs-decision over active run is superseded"
}

# blocked log + a resumed run is also superseded
test_stale_blocked_superseded() {
  reset_fakes
  local d; d=$(new_case superseded-blocked)
  make_repo_on_branch "$d/wt" fm/feat-bb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-bb.meta" "window=fm:fm-feat-bb" "worktree=$d/wt" "kind=ship"
  printf 'blocked: waiting on review answer\n' > "$d/state/feat-bb.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-bb)"
  local out; out=$(run_crew_state "$d" feat-bb)
  assert_contains "$out" "state: working" "resumed run -> working despite blocked log"
  assert_contains "$out" "superseded" "stale blocked log flagged superseded"
  pass "stale blocked over active run is superseded"
}

# (c) genuine parked run + needs-decision log AGREE -> parked, NOT superseded
test_genuine_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked)
  make_repo_on_branch "$d/wt" fm/feat-c
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-c.meta" "window=fm:fm-feat-c" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-c.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-c)"
  local out; out=$(run_crew_state "$d" feat-c)
  assert_contains "$out" "state: parked" "genuine parked run -> parked"
  assert_contains "$out" "source: run-step" "parked -> run-step source"
  assert_contains "$out" "2 finding(s)" "parked includes gate finding count"
  assert_contains "$out" "ask-user" "parked surfaces ask-user finding"
  assert_not_contains "$out" "superseded" "agreeing parked+needs-decision not flagged stale"
  pass "genuine parked run is not flagged superseded"
}

test_scalar_gate_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-scalar-gate)
  make_repo_on_branch "$d/wt" fm/feat-cs
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cs.meta" "window=fm:fm-feat-cs" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cs.status"
  FM_FAKE_AXI_STATUS="$(run_parked_scalar_gate_running fm/feat-cs)"
  local out; out=$(run_crew_state "$d" feat-cs)
  assert_contains "$out" "state: parked" "scalar gate wait -> parked"
  assert_contains "$out" "source: run-step" "scalar gate wait -> run-step source"
  assert_contains "$out" "parked at review" "scalar gate wait names the gate"
  assert_contains "$out" "1 finding(s)" "scalar gate wait includes finding count"
  assert_not_contains "$out" "superseded" "scalar gate wait not flagged stale"
  pass "scalar gate parked run is not flagged superseded"
}

test_gate_block_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-gate-block)
  make_repo_on_branch "$d/wt" fm/feat-cb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cb.meta" "window=fm:fm-feat-cb" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cb.status"
  FM_FAKE_AXI_STATUS="$(run_parked_in_gate_block fm/feat-cb)"
  local out; out=$(run_crew_state "$d" feat-cb)
  assert_contains "$out" "state: parked" "gate block wait -> parked"
  assert_contains "$out" "source: run-step" "gate block wait -> run-step source"
  assert_contains "$out" "parked at review" "gate block wait names the gate"
  assert_contains "$out" "1 finding(s)" "gate block wait includes finding count"
  assert_not_contains "$out" "superseded" "gate block wait not flagged stale"
  pass "gate block parked run is not flagged superseded"
}

test_ci_ready_done_log_beats_monitoring_run() {
  reset_fakes
  local d; d=$(new_case ci-ready)
  make_repo_on_branch "$d/wt" fm/feat-ci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci.meta" "window=fm:fm-feat-ci" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-ci.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ci)"
  local out; out=$(run_crew_state "$d" feat-ci)
  assert_contains "$out" "state: done" "ci-ready status log -> done"
  assert_contains "$out" "source: status-log" "ci-ready state comes from the status log"
  assert_contains "$out" "checks green" "ci-ready detail preserves the report"
  assert_not_contains "$out" "state: working" "ci-ready is not hidden by monitoring run"
  pass "ci-ready status log beats monitoring run"
}

# Regression for the PR #252 incident: the crew's own status log never got a
# "done: ... checks green" line (log_reports_ci_ready above does not apply),
# but the ci step's log tail shows CI is actually green and only waiting on
# merge/close. fm-crew-state must surface this as done, not "validating
# (running)", so a green PR is never silently absorbed as still-in-progress.
test_ci_monitoring_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-green)
  make_repo_on_branch "$d/wt" fm/feat-cigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cigreen.meta" "window=fm:fm-feat-cigreen" "worktree=$d/wt" "kind=ship"
  # No status-log line at all: the crew never reported its own checks-green line.
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cigreen)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
EOF
)
  local out; out=$(run_crew_state "$d" feat-cigreen)
  assert_contains "$out" "state: done" "green ci-monitor run -> done"
  assert_contains "$out" "source: run-step" "green ci-monitor -> run-step source"
  assert_contains "$out" "checks green" "green ci-monitor detail mentions checks green"
  assert_not_contains "$out" "state: working" "green ci-monitor must not read as still validating"
  pass "ci-monitoring run with checks already green surfaces done"
}

test_top_level_ci_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case top-level-ci-green)
  make_repo_on_branch "$d/wt" fm/feat-topcigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topcigreen.meta" "window=fm:fm-feat-topcigreen" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_top_level_ci fm/feat-topcigreen)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topcigreen)
  assert_contains "$out" "state: done" "top-level ci with green log -> done"
  assert_contains "$out" "source: run-step" "top-level ci green -> run-step source"
  assert_contains "$out" "checks green" "top-level ci green detail mentions checks green"
  assert_not_contains "$out" "state: working" "top-level ci green must not stay working"
  pass "top-level ci status uses ci log green marker"
}

test_ci_monitoring_no_checks_terminal_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-nochecks)
  make_repo_on_branch "$d/wt" fm/feat-cinochecks
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecks.meta" "window=fm:fm-feat-cinochecks" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecks)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cinochecks)
  assert_contains "$out" "state: done" "terminal no-checks ci-monitor run -> done"
  assert_contains "$out" "checks green" "terminal no-checks ci-monitor detail mentions checks green"
  pass "terminal no-checks ci-monitor marker surfaces done"
}

test_ci_monitoring_green_then_rearm_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-rearm)
  make_repo_on_branch "$d/wt" fm/feat-cirearm
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirearm.meta" "window=fm:fm-feat-cirearm" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirearm)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirearm)
  assert_contains "$out" "state: working" "base-advance rearm marker -> working"
  assert_not_contains "$out" "state: done" "base-advance rearm marker must not read as done"
  assert_not_contains "$out" "checks green" "base-advance rearm marker must not read as checks green"
  pass "base-advance rearm after green stays working"
}

test_ci_monitoring_no_checks_yet_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-yet)
  make_repo_on_branch "$d/wt" fm/feat-cinochecksyet
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecksyet.meta" "window=fm:fm-feat-cinochecksyet" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecksyet)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
no CI checks reported - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
no CI checks reported yet, waiting for checks to register...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cinochecksyet)
  assert_contains "$out" "state: working" "pending no-checks marker -> working"
  assert_not_contains "$out" "state: done" "pending no-checks marker must not read as done"
  assert_not_contains "$out" "checks green" "pending no-checks marker must not read as checks green"
  pass "pending no-checks ci-monitor marker stays working"
}

test_ci_monitoring_still_waiting_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-waiting)
  make_repo_on_branch "$d/wt" fm/feat-ciwait
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciwait.meta" "window=fm:fm-feat-ciwait" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciwait)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-ciwait)
  assert_contains "$out" "state: working" "ci step still red -> working"
  assert_not_contains "$out" "checks green" "no green marker present -> no checks-green detail"
  pass "ci-monitoring run with checks not yet green stays working"
}

# A later merge-conflict auto-fix round after an earlier green reading must
# not be masked: the MOST RECENT marker in the log tail wins.
test_ci_monitoring_green_then_new_issue_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-issue)
  make_repo_on_branch "$d/wt" fm/feat-cirelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirelapse.meta" "window=fm:fm-feat-cirelapse" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
issues detected: merge conflict - auto-fixing (attempt 2/10)...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirelapse)
  assert_contains "$out" "state: working" "a later relapse marker must win over an earlier green one"
  assert_not_contains "$out" "state: done" "relapsed ci run must not read as done"
  pass "a fresh issue after an earlier green reading is not masked"
}

test_ci_ready_done_log_relapse_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-ready-then-relapse)
  make_repo_on_branch "$d/wt" fm/feat-cireadyrelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cireadyrelapse.meta" "window=fm:fm-feat-cireadyrelapse" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cireadyrelapse.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cireadyrelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
CI checks running, waiting for results...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cireadyrelapse)
  assert_contains "$out" "state: working" "a stale ready status must not mask a later CI relapse"
  assert_contains "$out" "source: run-step" "relapsed ci run remains run-step sourced"
  assert_not_contains "$out" "state: done" "relapsed ci run with stale done log must not read as done"
  pass "stale checks-green status log does not mask CI relapse"
}

test_ci_fixing_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-fixing-after-green)
  make_repo_on_branch "$d/wt" fm/feat-cifixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cifixing.meta" "window=fm:fm-feat-cifixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cifixing.status"
  FM_FAKE_AXI_STATUS="$(run_ci_fixing fm/feat-cifixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cifixing)
  assert_contains "$out" "state: working" "ci fixing step must stay working"
  assert_contains "$out" "source: run-step" "ci fixing remains run-step sourced"
  assert_not_contains "$out" "state: done" "ci fixing must not read as checks-green done"
  pass "ci fixing is not overridden by an earlier green marker"
}

test_top_level_fixing_ci_running_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-ci-running)
  make_repo_on_branch "$d/wt" fm/feat-topfixingci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixingci.meta" "window=fm:fm-feat-topfixingci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_fixing_ci_running fm/feat-topfixingci)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixingci)
  assert_contains "$out" "state: working" "top-level fixing with ci running must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing with ci running remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not use stale green marker"
  pass "top-level fixing is not overridden by a stale ci running row"
}

test_top_level_fixing_done_log_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-done-log)
  make_repo_on_branch "$d/wt" fm/feat-topfixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixing.meta" "window=fm:fm-feat-topfixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-topfixing.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-topfixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixing)
  assert_contains "$out" "state: working" "top-level fixing must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not read as stale checks-green done"
  pass "top-level fixing is not overridden by a stale done log"
}

# (d) terminal run-step is authoritative
test_terminal_passed() {
  reset_fakes
  local d; d=$(new_case passed)
  make_repo_on_branch "$d/wt" fm/feat-d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-d.meta" "window=fm:fm-feat-d" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-d)"
  local out; out=$(run_crew_state "$d" feat-d)
  assert_contains "$out" "state: done" "passed run -> done"
  assert_contains "$out" "source: run-step" "passed -> run-step source"
  pass "terminal passed run is authoritative"
}

test_terminal_failed() {
  reset_fakes
  local d; d=$(new_case failed)
  make_repo_on_branch "$d/wt" fm/feat-e
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-e.meta" "window=fm:fm-feat-e" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-e)"
  local out; out=$(run_crew_state "$d" feat-e)
  assert_contains "$out" "state: failed" "failed run -> failed"
  assert_contains "$out" "source: run-step" "failed -> run-step source"
  pass "terminal failed run is authoritative"
}

# (e) cross-branch attribution: `axi status` returns ANOTHER branch's run (the
# routine case once more than one crew validates the same underlying repo
# concurrently - they share ONE no-mistakes repo registration), so the helper
# falls back to the real top-level `no-mistakes runs` listing to learn whether
# THIS branch has an active run of its own. Regression coverage for the
# 2026-07-02 herdr incident: the old fallback shelled out to `no-mistakes axi`
# (bare) expecting a `runs[N]{...}:` TOON table that the real CLI never emits
# (verified against the installed v1.32.2 - the `axi` surface has no
# runs-listing subcommand at all), so attribution silently failed every time
# the repo-wide answer was not this crew's own branch.
test_cross_branch_attribution_via_runs_list() {
  reset_fakes
  local d short; d=$(new_case crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-f
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f.meta" "window=fm:fm-feat-f" "worktree=$d/wt" "kind=ship"
  # The repo-wide active/most-recent run belongs to a different crew's branch.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  # Real `no-mistakes runs` shape: plain text, newest-first, no run id, no
  # quoting - "<status> <branch> <short-sha> <date> [<pr-url>]".
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-f ${short}  2026-07-02 22:05
EOF
)"
  local out; out=$(run_crew_state "$d" feat-f)
  assert_contains "$out" "state: working" "this branch's own run attributed via the runs list"
  assert_contains "$out" "source: run-step" "runs-list-resolved run -> run-step source"
  pass "cross-branch run is attributed via the real runs list"
}

# The runs list is newest-first; a branch with an OLDER completed run must not
# shadow its own newer active one - the first (topmost) matching row wins.
test_cross_branch_attribution_picks_most_recent_row() {
  reset_fakes
  local d short; d=$(new_case crossbranch-mostrecent)
  make_repo_on_branch "$d/wt" fm/feat-fq
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-fq.meta" "window=fm:fm-feat-fq" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-fq ${short}  2026-07-02 21:50
  completed  fm/feat-fq bbbbbbb  2026-07-02 20:00  https://github.com/o/r/pull/1
EOF
)"
  local out; out=$(run_crew_state "$d" feat-fq)
  assert_contains "$out" "state: working" "most recent (running) row wins over an older completed row"
  assert_contains "$out" "source: run-step" "most-recent-row resolution -> run-step source"
  pass "cross-branch attribution picks the branch's most recent row"
}

test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status() {
  reset_fakes
  local d short; d=$(new_case coarse-ready-other-log)
  make_repo_on_branch "$d/wt" fm/feat-coarseready
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarseready.meta" "window=fm:fm-feat-coarseready" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/4 checks green\n' > "$d/state/feat-coarseready.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-coarseready ${short}  2026-07-02 22:05
EOF
)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-coarseready)
  assert_contains "$out" "state: done" "coarse ready status -> done"
  assert_contains "$out" "source: status-log" "coarse ready status remains status-log sourced"
  assert_not_contains "$out" "state: working" "coarse ready status must not be suppressed by another branch log"
  pass "coarse run does not probe another branch's ci log"
}

# A different-branch run with NO matching runs-list row must NOT be
# misattributed, and must not be treated as a false "working" verdict either.
test_other_branch_run_ignored() {
  reset_fakes
  local d; d=$(new_case otherbranch)
  make_repo_on_branch "$d/wt" fm/feat-g
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-g.meta" "window=fm:fm-feat-g" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'done: implemented, ready to validate\n' > "$d/state/feat-g.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/some-other)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/some-other aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-g
  local out; out=$(run_crew_state "$d" feat-g)
  assert_not_contains "$out" "source: run-step" "another branch's run not misattributed"
  assert_contains "$out" "source: status-log" "no own run -> falls back to status-log"
  assert_contains "$out" "state: done" "falls back to the log verb"
  pass "another branch's run is ignored, falls back"
}

# (f) no run for this crew + a busy pane -> working via pane
test_no_run_busy_pane() {
  reset_fakes
  local d; d=$(new_case busy)
  make_repo_on_branch "$d/wt" fm/feat-h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h.meta" "window=fm:fm-feat-h" "worktree=$d/wt" "kind=ship" "harness=claude"
  # No matching run anywhere. The busy verdict comes from the crew's own
  # semantic lifecycle record (bin/fm-busy-lib.sh), not from rendered text.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-h)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-h busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-h)
  assert_contains "$out" "state: working" "busy record -> working"
  assert_contains "$out" "source: pane" "busy record -> pane source"
  assert_contains "$out" "claude-hook" "the working verdict names its semantic source"
  pass "no run + a busy semantic record reads working, attributed to its source"
}

# A converted adapter must NOT read working from rendered footer text: the
# redesign removed that dependency, so a pane painting "esc to interrupt" with
# no semantic record is unknown, never working and never silently idle.
test_no_run_footer_text_alone_is_not_working() {
  reset_fakes
  local d; d=$(new_case busy-footer-only)
  make_repo_on_branch "$d/wt" fm/feat-h2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h2.meta" "window=fm:fm-feat-h2" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  printf 'done: stale completion event\n' > "$d/state/feat-h2.status"
  local out; out=$(run_crew_state "$d" feat-h2)
  assert_not_contains "$out" "state: working" "a footer alone must not read working for a converted adapter"
  assert_contains "$out" "state: unknown" "no semantic record -> unknown"
  assert_not_contains "$out" "source: status-log" "unknown semantic state must not fall through to a stale log"
  pass "a converted adapter never reads working from rendered footer text"
}

# Grok keeps its isolated temporary rendered-tail fallback until its structured
# lifecycle is live-verified, so a grok crew still reads working from its own
# verified signature.
test_no_run_grok_uses_isolated_fallback() {
  reset_fakes
  local d; d=$(new_case busy-grok)
  make_repo_on_branch "$d/wt" fm/feat-h3
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h3.meta" "window=fm:fm-feat-h3" "worktree=$d/wt" "kind=ship" "harness=grok"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT='Ctrl+c:cancel'
  export FM_FAKE_BUSY_TEXT
  local out; out=$(run_crew_state "$d" feat-h3)
  assert_contains "$out" "state: working" "grok busy tail -> working"
  assert_contains "$out" "grok-regex" "the grok verdict names its isolated fallback source"
  pass "grok still reads working through its isolated rendered-tail fallback"
}

# Regression for the 2026-08-18 sm-snacksuite incident: two freshly spawned
# Claude crewmates on a quota-exhausted account read "working" for minutes
# because claude-hook had opened a turn on UserPromptSubmit and no
# Stop/StopFailure fired while the pane sat on Claude Code's own account-limit
# banner. A Claude worker parked on that banner is an external wait, not a
# working turn, so fm_busy_claude_limit_banner (bin/fm-busy-lib.sh) overrides
# the busy verdict to paused once its pane tail shows the banner.
test_no_run_claude_session_limit_banner_paused() {
  reset_fakes
  local d; d=$(new_case claude-session-limit)
  make_repo_on_branch "$d/wt" fm/feat-limit5h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-limit5h.meta" "window=fm:fm-feat-limit5h" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT="You've hit your session limit · resets 2:30pm
Usage limit reached · continuing automatically at 3:00pm · esc to cancel
╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts"
  export FM_FAKE_BUSY_TEXT
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-limit5h)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-limit5h busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-limit5h)
  assert_contains "$out" "state: paused" "the 5h session-limit banner overrides busy to paused"
  assert_contains "$out" "source: pane" "the override stays pane-sourced"
  assert_contains "$out" "session limit" "the detail names the limit that was hit"
  assert_contains "$out" "resets 2:30pm" "the detail carries the banner's reset hint"
  pass "a Claude worker parked on the 5h session-limit banner reads paused, not working"
}

# Same override for the 7-day weekly-limit banner (wLt.seven_day="weekly
# limit" in the claude-cli 2.1.234 bundle - see fm_busy_claude_limit_banner's
# header for the verified wording and its source).
test_no_run_claude_weekly_limit_banner_paused() {
  reset_fakes
  local d; d=$(new_case claude-weekly-limit)
  make_repo_on_branch "$d/wt" fm/feat-limit7d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-limit7d.meta" "window=fm:fm-feat-limit7d" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT="You've hit your weekly limit · resets Tue 2:30pm
Usage limit reached · continuing automatically at 3:00pm · esc to cancel
╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts"
  export FM_FAKE_BUSY_TEXT
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-limit7d)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-limit7d busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-limit7d)
  assert_contains "$out" "state: paused" "the weekly-limit banner overrides busy to paused"
  assert_contains "$out" "source: pane" "the override stays pane-sourced"
  assert_contains "$out" "weekly limit" "the detail names the limit that was hit"
  pass "a Claude worker parked on the weekly-limit banner reads paused, not working"
}

# An ordinary busy pane (no limit banner text) must keep reading working -
# the override only fires on the verified banner wording, never on a plain
# claude-hook busy verdict.
test_no_run_claude_ordinary_busy_tail_stays_working() {
  reset_fakes
  local d; d=$(new_case claude-ordinary-busy)
  make_repo_on_branch "$d/wt" fm/feat-ordinary
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ordinary.meta" "window=fm:fm-feat-ordinary" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT='esc to interrupt'
  export FM_FAKE_BUSY_TEXT
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-ordinary)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-ordinary busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-ordinary)
  assert_contains "$out" "state: working" "an ordinary busy tail stays working"
  assert_not_contains "$out" "state: paused" "no limit banner text means no override"
  pass "a Claude worker with an ordinary busy pane still reads working"
}

# A non-Claude harness must never be classified by this banner text, even
# when its pane happens to show similar wording: the override is scoped to
# harness=claude only (fm_busy_claude_limit_banner is consulted only from
# fm-crew-state.sh's claude* arm).
test_no_run_non_claude_harness_ignores_limit_banner_text() {
  reset_fakes
  local d; d=$(new_case opencode-similar-text)
  make_repo_on_branch "$d/wt" fm/feat-opencode
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-opencode.meta" "window=fm:fm-feat-opencode" "worktree=$d/wt" "kind=ship" "harness=opencode"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT="You've hit your session limit · resets 2:30pm
Usage limit reached · continuing automatically at 3:00pm · esc to cancel
╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts"
  export FM_FAKE_BUSY_TEXT
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-opencode)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-opencode busy --gen "$gen" \
    --source opencode-plugin --event session-status
  local out; out=$(run_crew_state "$d" feat-opencode)
  assert_contains "$out" "state: working" "a non-claude harness keeps the plain busy -> working mapping"
  assert_not_contains "$out" "state: paused" "similar pane text never overrides a non-claude harness"
  pass "a non-Claude harness ignores lookalike limit-banner text in its pane"
}

# Every name in claude-cli 2.1.234's wLt window map blocks the worker the same
# way, so all six must override busy, not just the 5h/7d pair.
test_no_run_claude_named_limit_variants_paused() {
  local name
  for name in "Opus limit" "Sonnet limit" "Fable 5 limit" "usage credit limit"; do
    reset_fakes
    local d; d=$(new_case "claude-limit-${name// /-}")
    make_repo_on_branch "$d/wt" fm/feat-limitvar
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/feat-limitvar.meta" "window=fm:fm-feat-limitvar" "worktree=$d/wt" "kind=ship" "harness=claude"
    FM_FAKE_AXI_STATUS=""
    FM_FAKE_RUNS_LIST=""
    FM_FAKE_BUSY=1
    FM_FAKE_BUSY_TEXT="You've hit your $name · resets 2:30pm
Usage limit reached · continuing automatically at 3:00pm · esc to cancel
╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts"
    export FM_FAKE_BUSY_TEXT
    local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-limitvar)
    "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-limitvar busy --gen "$gen" \
      --source claude-hook --event user-prompt-submit
    local out; out=$(run_crew_state "$d" feat-limitvar)
    assert_contains "$out" "state: paused" "the \"$name\" banner overrides busy to paused"
    assert_contains "$out" "$name" "the detail names the limit that was hit"
  done
  pass "every named Claude limit window (Opus/Sonnet/Fable 5/usage credit) reads paused"
}

# The named notice scrolls out of the capture window while the persistent
# auto-continue widget stays on screen; the widget alone is still an external
# wait, and the auto-continue-stopped state is the most wedged wait of all.
test_no_run_claude_widget_only_tail_paused() {
  local widget
  for widget in "Usage limit reached · continuing automatically at 3:00pm · esc to cancel
╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts" \
                "Your usage limit has reset · press enter to continue" \
                "Automatic continue stopped after repeated usage-limit hits"; do
    reset_fakes
    local d; d=$(new_case "claude-widget-${#widget}")
    make_repo_on_branch "$d/wt" fm/feat-widget
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/feat-widget.meta" "window=fm:fm-feat-widget" "worktree=$d/wt" "kind=ship" "harness=claude"
    FM_FAKE_AXI_STATUS=""
    FM_FAKE_RUNS_LIST=""
    FM_FAKE_BUSY=1
    FM_FAKE_BUSY_TEXT="$widget
╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts"
    export FM_FAKE_BUSY_TEXT
    local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-widget)
    "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-widget busy --gen "$gen" \
      --source claude-hook --event user-prompt-submit
    local out; out=$(run_crew_state "$d" feat-widget)
    assert_contains "$out" "state: paused" "the auto-continue widget alone overrides busy to paused"
    assert_contains "$out" "unspecified" "a widget-only match reports the limit type as unspecified"
  done
  pass "the auto-continue widget alone reads paused without naming a limit"
}

# A genuinely busy crewmate editing this repo's own limit-banner code has both
# "session limit" and "resets"/"press enter" on screen in ordinary scrollback.
# The override is anchored to the bottom-most widget/composer region, so that
# content must never flip the worker to paused.
test_no_run_claude_scrollback_limit_words_stay_working() {
  reset_fakes
  local d; d=$(new_case claude-scrollback-words)
  make_repo_on_branch "$d/wt" fm/feat-scrollback
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-scrollback.meta" "window=fm:fm-feat-scrollback" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT="+ # the 5-hour window is named \"session limit\" and the 7-day one
+ # \"weekly limit\"; a rejected turn renders resets <time>, and the widget
+ # says press enter to continue once stale
$(for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do printf '  editing bin/fm-busy-lib.sh line %s\n' "$i"; done)
· Thinking…
╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts"
  export FM_FAKE_BUSY_TEXT
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-scrollback)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-scrollback busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-scrollback)
  assert_contains "$out" "state: working" "limit words in ordinary scrollback keep the worker working"
  assert_not_contains "$out" "state: paused" "scrollback far from the composer never triggers the override"
  pass "a busy Claude worker editing limit-banner text is not misread as paused"
}

# A PARKED run stays authoritative even when the pane is limit-blocked: the gate
# is waiting on a CAPTAIN decision the worker's quota block does not prevent, so
# the parked verdict and its gate detail must survive and only gain a note.
test_parked_run_claude_limit_banner_paused() {
  reset_fakes
  local d; d=$(new_case claude-limit-parked-run)
  make_repo_on_branch "$d/wt" fm/feat-limitparked
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-limitparked.meta" "window=fm:fm-feat-limitparked" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-limitparked)"
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT="You've hit your weekly limit · resets Tue 2:30pm
Usage limit reached · continuing automatically at 3:00pm · esc to cancel
╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts"
  export FM_FAKE_BUSY_TEXT
  local out; out=$(run_crew_state "$d" feat-limitparked)
  assert_contains "$out" "state: parked" "a parked run keeps its own state over the pane override"
  assert_not_contains "$out" "state: paused" "a limit-blocked pane must not absorb a pending gate decision"
  assert_contains "$out" "2 finding(s)" "the parked gate detail survives the limit note"
  assert_contains "$out" "ask-user" "the parked gate's ask-user marker survives the limit note"
  assert_contains "$out" "worker pane limit-blocked" "the parked run's detail records the blocked pane"
  assert_contains "$out" "weekly limit" "the appended note names the limit"
  pass "a parked run whose Claude pane is limit-blocked stays parked with an appended note"
}

# An actively running step may progress independently of this crew's pane, so
# it keeps reporting working - but the supervisor still sees the pane is stuck.
test_active_run_claude_limit_banner_annotates_working() {
  reset_fakes
  local d; d=$(new_case claude-limit-active-run)
  make_repo_on_branch "$d/wt" fm/feat-limitactive
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-limitactive.meta" "window=fm:fm-feat-limitactive" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-limitactive)"
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT="You've hit your session limit · resets 2:30pm
Usage limit reached · continuing automatically at 3:00pm · esc to cancel
╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts"
  export FM_FAKE_BUSY_TEXT
  local out; out=$(run_crew_state "$d" feat-limitactive)
  assert_contains "$out" "state: working" "an active run step keeps reporting working"
  assert_contains "$out" "worker pane limit-blocked" "the active run's detail records the blocked pane"
  pass "an actively running step with a limit-blocked Claude pane stays working with a note"
}

# Claude Code's NON-blocking approaching-limit warning ("You've used NN% of your
# <name> · resets <time>", status allowed_warning at >=70% utilization) renders
# the same names and reset hint while the account is NOT blocked and the worker
# is genuinely still working. Only a blocking auto-continue widget phrase means
# a real block, so the warning alone must never read paused.
test_no_run_claude_approaching_limit_warning_stays_working() {
  reset_fakes
  local d; d=$(new_case claude-approaching-limit)
  make_repo_on_branch "$d/wt" fm/feat-approaching
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-approaching.meta" "window=fm:fm-feat-approaching" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT="Approaching session limit
You've used 85% of your session limit · resets 3:00pm
╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts"
  export FM_FAKE_BUSY_TEXT
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-approaching)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-approaching busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-approaching)
  assert_contains "$out" "state: working" "an approaching-limit warning keeps the worker working"
  assert_not_contains "$out" "state: paused" "a non-blocking warning must never read paused"
  pass "a Claude worker on the non-blocking approaching-limit warning still reads working"
}

# A bare named limit notice with no blocking widget is deliberately NOT a pause:
# Claude Code renders the same "<name> limit ... resets <time>" wording while
# merely approaching a limit and while blocked, so the worker keeps reading
# working - but the notice is surfaced in the detail so the supervisor sees it.
# fm_busy_claude_limit_banner's header owns this accepted limitation.
test_no_run_claude_bare_limit_notice_annotates_working() {
  reset_fakes
  local d; d=$(new_case claude-bare-notice)
  make_repo_on_branch "$d/wt" fm/feat-barenotice
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-barenotice.meta" "window=fm:fm-feat-barenotice" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT="You've hit your weekly limit · resets Tue 2:30pm
╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts"
  export FM_FAKE_BUSY_TEXT
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-barenotice)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-barenotice busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-barenotice)
  assert_contains "$out" "state: working" "a bare limit notice keeps the worker working"
  assert_not_contains "$out" "state: paused" "only a blocking widget may report paused"
  assert_contains "$out" "limit notice visible in pane" "the working detail surfaces the visible notice"
  pass "a bare Claude limit notice annotates the working detail instead of pausing"
}

# The blocking widget phrases are matched ONLY inside the composer region. A
# crewmate grepping this repo (whose sources carry the literal phrase) while
# genuinely mid-turn has the hit in scrollback with an ordinary busy footer at
# the bottom, and must keep reading working.
test_no_run_claude_widget_phrase_in_scrollback_stays_working() {
  reset_fakes
  local d; d=$(new_case claude-widget-scrollback)
  make_repo_on_branch "$d/wt" fm/feat-widgetscroll
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-widgetscroll.meta" "window=fm:fm-feat-widgetscroll" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT="bin/fm-busy-lib.sh: says press enter to continue once stale
· Thinking…
esc to interrupt"
  export FM_FAKE_BUSY_TEXT
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-widgetscroll)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-widgetscroll busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-widgetscroll)
  assert_contains "$out" "state: working" "a widget phrase in scrollback keeps the worker working"
  assert_not_contains "$out" "state: paused" "a widget phrase outside the composer region never pauses"
  pass "a busy Claude worker with a widget phrase in scrollback is not misread as paused"
}

test_no_run_herdr_unknown_uses_backend_capture() {
  command -v jq >/dev/null 2>&1 || { pass "herdr pane fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-busy)
  make_repo_on_branch "$d/wt" fm/feat-herdr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_BUSY=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-herdr)
  assert_contains "$out" "state: working" "herdr native busy -> working"
  assert_contains "$out" "source: pane" "herdr native busy -> pane source"
  assert_contains "$out" "herdr-native" "the herdr verdict names its native source"
  pass "herdr's native busy verdict reads working with no record present"
}

# Regression (2026-07 herdr false-surface incident, now solved semantically):
# herdr's agent.get reports generation state ("working" only while the model is
# actively streaming - docs/herdr-backend.md "Busy state"), not "this crew's
# turn is still in progress". A crew blocked on its own long-running foreground
# `no-mistakes axi run` (no --yes; blocks until a gate or outcome) is not
# generating for that whole span, so agent.get reads idle. The crew's own
# semantic lifecycle record still says busy for the whole turn, and it outranks
# the narrower native verdict - so the crew is no longer misread as not-working.
test_no_run_herdr_idle_agent_status_outranked_by_record() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle corroboration skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-busy-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-idle
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-idle.meta" "window=default:w1:p3" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  # No run attributable (mirrors a no-mistakes run-step lookup that found no
  # matching row within the configured runs-list window): the crew's semantic
  # busy state is the only remaining signal.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-idle)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-idle busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-herdr-idle)
  assert_contains "$out" "state: working" "a busy record with herdr idle agent_status -> working"
  assert_contains "$out" "claude-hook" "the record's source outranks herdr's narrower native verdict"
  pass "a mid-tool-call crew stays working because its record outranks herdr's generation state"
}

# The record must not mask a genuinely idle or human-blocked agent: an idle
# record with idle agent_status still reads not-busy.
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle+idle-record skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-idle-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stopped.meta" "window=default:w1:p4" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-herdr-stopped.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-stopped)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-stopped idle --gen "$gen" \
    --source claude-hook --event stop
  local out; out=$(run_crew_state "$d" feat-herdr-stopped)
  assert_not_contains "$out" "source: pane" "an idle record must not read as busy"
  assert_contains "$out" "source: status-log" "an idle record falls to the status log"
  pass "an idle record with idle agent_status stays not-busy (no regression for a human-blocked agent)"
}

# (g) no run + idle pane -> the status-log verb, as-is
test_no_run_idle_pane_uses_log() {
  reset_fakes
  local d; d=$(new_case idle)
  make_repo_on_branch "$d/wt" fm/feat-i
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-i.meta" "window=fm:fm-feat-i" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: which database?\n' > "$d/state/feat-i.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-i
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: parked" "needs-decision log -> parked"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  pass "no run + idle pane uses the status-log verb"
}

test_no_run_idle_pane_uses_keyed_log() {
  reset_fakes
  local d; d=$(new_case keyed-idle)
  make_repo_on_branch "$d/wt" fm/feat-keyed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-keyed.meta" "window=fm:fm-feat-keyed" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision [key=q1]: which database?\n' > "$d/state/feat-keyed.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-keyed
  local out; out=$(run_crew_state "$d" feat-keyed)
  assert_contains "$out" "state: parked" "keyed needs-decision log -> parked"
  assert_contains "$out" "which database?" "key token is excluded from status detail"
  pass "no run + idle pane parses keyed status syntax"
}

# (g') no run + idle pane on a DECLARED external-wait pause -> state: paused, so a
# supervisor reading the crew sees a distinct pause (and its reason) rather than a
# wedge-suspect idle. This is the reader half the watcher/daemon build on.
test_no_run_idle_pane_paused() {
  reset_fakes
  local d; d=$(new_case paused)
  make_repo_on_branch "$d/wt" fm/feat-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pause.meta" "window=fm:fm-feat-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'paused: holding for the upstream tool release\n' > "$d/state/feat-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-pause
  local out; out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "paused log -> paused"
  assert_contains "$out" "source: status-log" "idle pause -> status-log source"
  assert_contains "$out" "holding for the upstream tool release" "the pause reason is carried in the detail"
  pass "no run + idle pane on a paused: status reports state: paused with its reason"
}

test_no_run_idle_pane_custom_paused_verb() {
  reset_fakes
  local d; d=$(new_case custom-paused)
  make_repo_on_branch "$d/wt" fm/feat-custom-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-custom-pause.meta" "window=fm:fm-feat-custom-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'awaiting: vendor maintenance window\n' > "$d/state/feat-custom-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-custom-pause
  local out; out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: paused" "custom paused verb -> paused"
  assert_contains "$out" "source: status-log" "custom paused verb -> status-log source"
  assert_contains "$out" "vendor maintenance window" "custom pause preserves its reason"
  printf 'paused: default verb no longer selected\n' > "$d/state/feat-custom-pause.status"
  out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: unknown" "custom paused verb replaces the default"
  pass "no run + idle pane honors the configured paused verb"
}

# A trailing keyed resolved: event is a decision-CLOSING event, not a run-state
# verb. It must never become the current state or leak its resolution prose as the
# detail: a healthy idle secondmate that just closed a keyed decision falls through
# to the idle default (unknown/none), not `unknown` with the resolution note as its
# `doing`. Regression for the bearings render bug where such a secondmate showed
# state=unknown with resolution prose. The one-owner keyed fold in fm-classify-lib.sh
# is untouched; this only stops the deriver from reading a non-state event as state.
test_no_run_idle_secondmate_resolved_event_not_state() {
  reset_fakes
  local d; d=$(new_case resolved-idle)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "home=$d/wt"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$d/state/mate.status"
  printf 'resolved [key=race]: went with subscribe-before-write\n' >> "$d/state/mate.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "resolved-then-idle secondmate is not a spurious run-state"
  assert_contains "$out" "source: none" "a resolved event is not treated as a status-log state source"
  assert_not_contains "$out" "subscribe-before-write" "resolution prose must not leak into the detail"
  # A bare (non-keyed) resolved: closes the default key and behaves the same.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "source: none" "a bare resolved: is not a state source either"
  assert_not_contains "$out" "infra access granted" "bare resolution prose must not leak into the detail"
  # Control: a genuine trailing state verb still renders from the log.
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a real trailing state verb still renders"
  assert_contains "$out" "reconciling routed items" "a real state line still carries its detail"
  pass "a trailing resolved: event does not corrupt state render (idle stays idle)"
}

test_dead_window_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case dead-window)
  make_repo_on_branch "$d/wt" fm/feat-dead
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead.meta" "window=fm:fm-feat-dead" "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-dead.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead)
  assert_contains "$out" "state: unknown" "dead window -> unknown"
  assert_contains "$out" "source: none" "dead window -> none source"
  assert_not_contains "$out" "source: status-log" "dead window does not reuse stale log"
  pass "dead window ignores stale status log"
}

# A closed/unreadable pane must NOT mask an authoritative run-step: judge by the
# run-step, not the shell. The common case is a finished crew whose agent has
# exited and closed its window (the normal gap between completion and teardown) -
# it must still report its terminal run-step state (e.g. done), never unknown.
test_dead_window_still_reports_terminal_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-done)
  make_repo_on_branch "$d/wt" fm/feat-dead-done
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-done.meta" "window=fm:fm-feat-dead-done" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/3 checks green\n' > "$d/state/feat-dead-done.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-dead-done)"
  FM_FAKE_TMUX_MISSING=1   # the crew's window has closed
  local out; out=$(run_crew_state "$d" feat-dead-done)
  assert_contains "$out" "state: done" "closed pane still reports terminal run-step done"
  assert_contains "$out" "source: run-step" "closed pane does not mask the run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with a run must never be unknown"
  pass "closed pane still reports a terminal run-step"
}

# The same for an active run: an agent pane that crashed mid-validation while the
# daemon-backed run continues must report the live run-step, not unknown.
test_dead_window_still_reports_active_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-active)
  make_repo_on_branch "$d/wt" fm/feat-dead-act
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-act.meta" "window=fm:fm-feat-dead-act" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-dead-act)"
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead-act)
  assert_contains "$out" "state: working" "closed pane still reports active run-step"
  assert_contains "$out" "source: run-step" "closed pane does not mask the active run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with an active run must never be unknown"
  pass "closed pane still reports an active run-step"
}

test_no_timeout_uses_perl_bound() {
  reset_fakes
  local d toolbin out start elapsed calls_file calls
  d=$(new_case no-timeout)
  make_repo_on_branch "$d/wt" fm/feat-timeout
  make_fakebin "$d" >/dev/null
  calls_file="$d/no-mistakes.calls"
  : > "$calls_file"
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:-/dev/null}"
while :; do :; done
SH
  chmod +x "$d/fakebin/no-mistakes"
  toolbin=$(make_no_timeout_toolbin "$d")
  fm_write_meta "$d/state/feat-timeout.meta" "window=fm:fm-feat-timeout" "worktree=$d/wt" "kind=ship" \
    "harness=claude"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-timeout)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-timeout busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  start=$SECONDS
  out=$(FM_FAKE_NM_CALLS="$calls_file" PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" feat-timeout)
  elapsed=$((SECONDS - start))
  assert_contains "$out" "state: working" "timed-out no-mistakes falls back to pane"
  assert_contains "$out" "source: pane" "timed-out no-mistakes -> pane source"
  [ "$elapsed" -lt 5 ] || fail "perl timeout did not bound no-mistakes calls (elapsed ${elapsed}s)"
  calls=$(awk 'END { print NR + 0 }' "$calls_file" 2>/dev/null || echo 0)
  [ "$calls" -eq 1 ] || fail "empty no-mistakes status triggered extra lookups ($calls calls)"
  pass "no timeout command uses perl bound"
}

# (i) kind=scout skips the run lookup entirely (its deliverable is a report).
test_scout_skips_run_lookup() {
  reset_fakes
  local d; d=$(new_case scout)
  make_repo_on_branch "$d/wt" fm/scout-j
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/scout-j.meta" "window=fm:fm-scout-j" "worktree=$d/wt" "kind=scout" \
    "harness=claude"
  # Even if a run existed on this branch, a scout must not read it.
  FM_FAKE_AXI_STATUS="$(run_running fm/scout-j)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" scout-j)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" scout-j busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" scout-j)
  assert_not_contains "$out" "source: run-step" "scout ignores no-mistakes run-step"
  assert_contains "$out" "source: pane" "scout reads its semantic busy state"
  pass "scout skips the run lookup"
}

# (j) torn-down worktree and missing meta are graceful (unknown/none, exit 0)
test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torndown)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/gone-k.meta" "window=fm:fm-gone-k" "worktree=$d/no-such-worktree" "kind=ship"
  local out rc
  out=$(run_crew_state "$d" gone-k); rc=$?
  expect_code 0 "$rc" "torn-down worktree exits 0"
  assert_contains "$out" "state: unknown" "torn-down -> unknown"
  assert_contains "$out" "source: none" "torn-down -> none source"
  pass "torn-down worktree is handled gracefully"
}

test_missing_meta() {
  reset_fakes
  local d; d=$(new_case nometa)
  make_fakebin "$d" >/dev/null
  local out rc
  out=$(run_crew_state "$d" ghost-z); rc=$?
  expect_code 0 "$rc" "missing meta exits 0"
  assert_contains "$out" "state: unknown" "missing meta -> unknown"
  assert_contains "$out" "source: none" "missing meta -> none source"
  pass "missing meta is handled gracefully"
}

# (k) crew_is_provably_working end-to-end over the REAL fm-crew-state.sh (not a
# canned fake verdict, unlike tests/fm-watch-triage.test.sh's classifier
# coverage). This is the direct regression pair for the 2026-07-02 herdr
# incident: a validating crew whose bare `axi status` answer belongs to
# another branch must still be absorbed by the watcher via the runs-list
# fallback (working), while a crew with genuinely no run anywhere and an idle
# pane must still surface (the safety property the fix must never widen away).
test_provably_working_via_runs_list_fallback() {
  reset_fakes
  local d short; d=$(new_case provably-working-crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-provable
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-provable.meta" "window=fm:fm-feat-provable" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-provable ${short}  2026-07-02 22:05
EOF
)"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-provable \
    || fail "cross-branch attribution via the runs list was not treated as provably working"
  pass "crew_is_provably_working absorbs a validating crew found only via the runs-list fallback"
}

test_not_provably_working_when_stopped() {
  reset_fakes
  local d; d=$(new_case provably-working-stopped)
  make_repo_on_branch "$d/wt" fm/feat-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-stopped.meta" "window=fm:fm-feat-stopped" "worktree=$d/wt" "kind=ship"
  # Repo-wide run belongs to someone else, and this branch has no row in the
  # runs list either (it never validated, or genuinely finished/stopped) - the
  # only remaining signal is the pane, which is idle.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-stopped \
    && fail "a stopped crew with no run anywhere and an idle pane was treated as provably working"
  pass "crew_is_provably_working still surfaces a genuinely stopped crew (safety property preserved)"
}

# Usage error (no id) is the one non-zero exit.
test_usage_error() {
  reset_fakes
  local rc
  "$CREW_STATE" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  pass "usage error exits 2"
}

# Head-binding: same branch name with a rewritten/diverged worktree tip must not
# attribute a historical no-mistakes run (multi-stage branch reuse incident).
test_historical_same_branch_rewritten_head_not_current() {
  reset_fakes
  local d old_head new_head out
  d=$(new_case rewritten-head)
  make_repo_on_branch "$d/wt" fm/todo-flag
  old_head=$(git -C "$d/wt" rev-parse HEAD)
  # Simulate a rebase rewrite: orphan new history on the same branch name.
  git -C "$d/wt" checkout -q --orphan tmp-rewrite
  git -C "$d/wt" commit -q --allow-empty -m 'rewritten tip'
  git -C "$d/wt" branch -q -M fm/todo-flag
  new_head=$(git -C "$d/wt" rev-parse HEAD)
  [ "$old_head" != "$new_head" ] || fail "rewrite did not produce a new head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/wishlist.meta" "window=fm:fm-wishlist" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 setup complete rebased onto merged #76\n' > "$d/state/wishlist.status"
  # Historical run still reports the pre-rewrite head on the reused branch.
  FM_FAKE_RUN_HEAD="$old_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/todo-flag)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" wishlist
  out=$(run_crew_state "$d" wishlist)
  assert_not_contains "$out" "source: run-step" "historical rewritten head must not use run-step"
  assert_not_contains "$out" "parked at" "historical parked run must not mask current state"
  assert_contains "$out" "source: status-log" "falls back to status-log after head mismatch"
  assert_contains "$out" "state: working" "status-log working: remains current"
  pass "historical same-branch rewritten head is not attributed as current"
}

# Head-binding: an active pipeline whose run head is a descendant of the local
# tip (fix commits on the same history) remains current.
test_active_run_descendant_fix_head_remains_current() {
  reset_fakes
  local d base_head fix_head out
  d=$(new_case pipeline-descendant)
  make_repo_on_branch "$d/wt" fm/feat-pipeline
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'pipeline fix commit'
  fix_head=$(git -C "$d/wt" rev-parse HEAD)
  # Worktree still at the pre-fix tip; run reports the pipeline fix head.
  git -C "$d/wt" reset -q --hard "$base_head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/pipe.meta" "window=fm:fm-pipe" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$fix_head"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-pipeline)"
  out=$(run_crew_state "$d" pipe)
  assert_contains "$out" "source: run-step" "descendant pipeline fix head remains run-step"
  assert_contains "$out" "state: working" "active fixing run remains working"
  pass "active run with valid descendant fix head remains current"
}

# Head-binding: local work that advanced past the run head invalidates the run.
test_local_advanced_past_run_head_invalidates() {
  reset_fakes
  local d run_head out
  d=$(new_case local-advanced)
  make_repo_on_branch "$d/wt" fm/feat-adv
  run_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'local stage-2 work after prior run'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/adv.meta" "window=fm:fm-adv" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 implementation in progress\n' > "$d/state/adv.status"
  FM_FAKE_RUN_HEAD="$run_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-adv)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" adv
  out=$(run_crew_state "$d" adv)
  assert_not_contains "$out" "source: run-step" "local-advanced tip must not use historical run"
  assert_contains "$out" "source: status-log" "falls back after local advanced past run"
  assert_contains "$out" "state: working" "status-log working: is current"
  pass "local work advanced past run head invalidates attribution"
}

test_missing_run_head_falls_back_to_current_state() {
  reset_fakes
  local d out
  d=$(new_case missing-run-head)
  make_repo_on_branch "$d/wt" fm/feat-no-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/no-head.meta" "window=fm:fm-no-head" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: current stage still in progress\n' > "$d/state/no-head.status"
  FM_FAKE_AXI_STATUS=$(run_parked fm/feat-no-head | grep -v '^  head:')
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" no-head
  out=$(run_crew_state "$d" no-head)
  assert_not_contains "$out" "source: run-step" "missing run head must not permit branch-only attribution"
  assert_contains "$out" "source: status-log" "missing run head falls back to current state sources"
  assert_contains "$out" "state: working" "status-log remains current after missing run head"
  pass "missing run head falls back instead of matching by branch"
}

# --- a replaced run is history, not current state ---------------------------
# 2026-08-16 evidence, twice in one day: a worker's own supersession sequence
# (the run dies or is aborted, custody comes back, a fresh run starts) leaves
# the dead run as the most recently written record for a while.
#   - snacksuite-rag-umbau: run 01M03RWN cancelled, replaced by 01M0492M
#     running in the test step; this helper still reported "failed: run
#     cancelled", and the watcher turned that into an inactive-crew false alarm.
#   - lensclash-fix-runde-golive, 08:56: run 01M0490J failed, replaced by
#     01M04KJJ running; this helper still reported "failed: run failed" while
#     `axi status` showed running/fixing at the same moment.
# The pair below pins both shapes, and the third case pins the safety property
# they must not cost: a terminal run with NO replacement still reports failed.

# The dead run answers `axi status` (its head still binds), while the runs list
# already shows the newer running one on top.
test_replaced_terminal_run_not_reported_as_current() {
  local terminal detail short d out
  for terminal in cancelled failed; do
    reset_fakes
    d=$(new_case "replaced-$terminal")
    make_repo_on_branch "$d/wt" "fm/feat-replaced-$terminal"
    short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/replaced-$terminal.meta" \
      "window=fm:fm-replaced-$terminal" "worktree=$d/wt" "kind=ship"
    FM_FAKE_AXI_STATUS="$(run_outcome "fm/feat-replaced-$terminal" "$terminal")"
    FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-replaced-$terminal ${short}  2026-08-16 08:56
  $terminal  fm/feat-replaced-$terminal ${short}  2026-08-16 08:43
EOF
)"
    out=$(run_crew_state "$d" "replaced-$terminal")
    assert_contains "$out" "state: working" "a $terminal run replaced by a running one is not the current state"
    assert_contains "$out" "source: run-step" "the replacement run is still a run-step verdict"
    assert_contains "$out" "superseded run $terminal" "the superseded run is named in the detail"
    detail="run $terminal"
    assert_not_contains "$out" "state: failed" "the replaced $terminal run must not be reported as failed ($detail)"
  done
  pass "a cancelled or failed run replaced by a running one is not reported as the current state"
}

# The safety property the supersession rule must not cost: with no replacement
# in the runs list, a terminal run is still exactly as terminal as before.
test_terminal_run_without_replacement_stays_failed() {
  reset_fakes
  local d short out
  d=$(new_case terminal-no-replacement)
  make_repo_on_branch "$d/wt" fm/feat-dead
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/dead.meta" "window=fm:fm-dead" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_outcome fm/feat-dead failed)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-dead ${short}  2026-08-16 08:43
  running    fm/some-other aaaaaaa  2026-08-16 08:56
EOF
)"
  out=$(run_crew_state "$d" dead)
  assert_contains "$out" "state: failed" "an unreplaced failed run is still failed"
  assert_contains "$out" "run failed" "the failure detail is preserved"
  assert_not_contains "$out" "superseded" "nothing superseded an unreplaced run"
  pass "a terminal run with no replacement still reports failed"
}

# lensclash's other half: the replacement run was started from a preserved
# pipeline head after the pipeline had rebased onto another base, so its head
# is neither the local HEAD nor a descendant of it, and the strict head rule
# rejected it. An EXECUTING run on this crew's branch is current work whatever
# its head says - nothing but this crew's own validation runs on this branch -
# so it is attributed, with its own step detail intact.
test_executing_run_with_diverged_head_is_current() {
  reset_fakes
  local d diverged out
  d=$(new_case diverged-executing)
  make_repo_on_branch "$d/wt" fm/feat-diverged
  diverged=$(make_diverged_commit "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/diverged.meta" "window=fm:fm-diverged" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: restarted validation on the preserved head\n' > "$d/state/diverged.status"
  FM_FAKE_RUN_HEAD="$diverged"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-diverged)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" diverged
  out=$(run_crew_state "$d" diverged)
  assert_contains "$out" "state: working" "an executing run on this branch is current despite a diverged head"
  assert_contains "$out" "source: run-step" "the diverged executing run is a run-step verdict"
  assert_contains "$out" "validating (fixing)" "the run's own step detail is preserved"
  assert_contains "$out" "run head diverged from local copy" "the divergence is recorded in the detail"
  pass "an executing run whose head diverged from the local copy is still the current state"
}

# The boundary that relaxation must not cross: a TERMINAL run with a diverged
# head stays unattributed, exactly as before, so an abandoned run on a reused
# branch can never masquerade as this crew's state.
test_terminal_run_with_diverged_head_still_not_attributed() {
  reset_fakes
  local d diverged out
  d=$(new_case diverged-terminal)
  make_repo_on_branch "$d/wt" fm/feat-diverged-dead
  diverged=$(make_diverged_commit "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/diverged-dead.meta" "window=fm:fm-diverged-dead" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: current stage still in progress\n' > "$d/state/diverged-dead.status"
  FM_FAKE_RUN_HEAD="$diverged"
  FM_FAKE_AXI_STATUS="$(run_outcome fm/feat-diverged-dead failed)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" diverged-dead
  out=$(run_crew_state "$d" diverged-dead)
  assert_not_contains "$out" "source: run-step" "a terminal run with a diverged head must stay unattributed"
  assert_contains "$out" "source: status-log" "falls back to the status log as before"
  pass "a terminal run with a diverged head is still not attributed"
}

# The coarse path's own supersession: `axi status` answers for another crew's
# branch, and in the runs list this branch's newest row is the running
# replacement (diverged head, so the strict rule skips it) sitting above an
# older terminal row whose head DOES bind. Newest-first ordering makes the
# running row the newer one, so it wins.
test_coarse_running_row_outranks_older_matching_terminal_row() {
  reset_fakes
  local d short out
  d=$(new_case coarse-superseded)
  make_repo_on_branch "$d/wt" fm/feat-coarse-superseded
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/coarse-superseded.meta" \
    "window=fm:fm-coarse-superseded" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-coarse-superseded ffffff1  2026-08-16 08:56
  cancelled  fm/feat-coarse-superseded ${short}  2026-08-16 08:43
EOF
)"
  out=$(run_crew_state "$d" coarse-superseded)
  assert_contains "$out" "state: working" "a newer running row outranks an older terminal row that binds"
  assert_contains "$out" "source: run-step" "the coarse replacement is still a run-step verdict"
  assert_not_contains "$out" "state: failed" "the superseded cancelled row must not win"
  pass "the coarse runs list prefers a newer running row over an older terminal one"
}

# The other half of the newest-first ordering: no row binds to the worktree, the
# branch's NEWEST row is terminal and an OLDER row is still marked running. The
# running row is the stale one there - a run that died without its record being
# terminalized - so it must NOT supersede the newer terminal verdict, and the
# coarse fallback must attribute nothing. This is what keeps a genuinely dead
# crew escalating instead of reading as working forever.
test_coarse_older_running_row_loses_to_newer_terminal_row() {
  reset_fakes
  local d out
  d=$(new_case coarse-stale-running)
  make_repo_on_branch "$d/wt" fm/feat-coarse-stale-running
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/coarse-stale-running.meta" \
    "window=fm:fm-coarse-stale-running" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: waiting on the validation run\n' > "$d/state/coarse-stale-running.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  failed     fm/feat-coarse-stale-running ffffff2  2026-08-16 09:10
  running    fm/feat-coarse-stale-running ffffff1  2026-08-16 08:43
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" coarse-stale-running
  out=$(run_crew_state "$d" coarse-stale-running)
  assert_not_contains "$out" "source: run-step" "an older stuck-running row must not outrank a newer terminal row"
  assert_not_contains "$out" "validating" "no coarse row binds, so no run is attributed as active work"
  assert_contains "$out" "source: status-log" "falls back to the status log so the dead crew still escalates"
  pass "an older running row loses to a newer terminal row in the coarse runs list"
}

# The same ordering rule where a row DOES bind, which the two-halves formulation
# got wrong: newest row terminal and not binding (the pipeline rebased off the
# local line), middle row stuck at running and not binding, oldest row terminal
# and binding. The branch's newest record is not running, so the stuck row must
# not supersede anything and the binding row's own verdict is the answer.
test_coarse_stuck_running_row_below_newer_terminal_does_not_win() {
  reset_fakes
  local d short out
  d=$(new_case coarse-stuck-middle)
  make_repo_on_branch "$d/wt" fm/feat-coarse-stuck
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/coarse-stuck.meta" \
    "window=fm:fm-coarse-stuck" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  completed  fm/feat-coarse-stuck ffffff3  2026-08-16 09:10
  running    fm/feat-coarse-stuck ffffff2  2026-08-16 08:30
  failed     fm/feat-coarse-stuck ${short}  2026-08-16 08:00
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" coarse-stuck
  out=$(run_crew_state "$d" coarse-stuck)
  assert_contains "$out" "state: failed" "the binding row's own terminal verdict is the answer"
  assert_contains "$out" "source: run-step" "the binding row is still a run-step verdict"
  assert_not_contains "$out" "state: working" "a stuck running row below a newer terminal row must not win"
  pass "a stuck running row below a newer terminal row does not supersede the binding verdict"
}

# The done half of the terminal set bin/fm-inactive-reconcile.sh consumes: it
# raises its inactive-terminal-outcome record off `state: done ` exactly as off
# `state: failed `. Evidence 2026-08-16 10:35, lensclash-datenschutz-loeschung:
# supervision surfaced a terminal outcome while `axi status` showed running.
# A done run that a newer running one replaced must not be reported as terminal.
test_replaced_done_run_not_reported_as_current() {
  local outcome short d out
  for outcome in passed checks-passed; do
    reset_fakes
    d=$(new_case "replaced-done-$outcome")
    make_repo_on_branch "$d/wt" "fm/feat-replaced-$outcome"
    short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/replaced-$outcome.meta" \
      "window=fm:fm-replaced-$outcome" "worktree=$d/wt" "kind=ship"
    FM_FAKE_AXI_STATUS="$(run_outcome "fm/feat-replaced-$outcome" "$outcome")"
    FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-replaced-$outcome ${short}  2026-08-16 10:35
  completed  fm/feat-replaced-$outcome ${short}  2026-08-16 10:02
EOF
)"
    out=$(run_crew_state "$d" "replaced-$outcome")
    assert_contains "$out" "state: working" "a $outcome run replaced by a running one is not the current state"
    assert_contains "$out" "superseded" "the superseded done run is named in the detail"
    assert_not_contains "$out" "state: done" "the replaced $outcome run must not be reported as done"
  done
  pass "a done run replaced by a running one is not reported as the current state"
}

# The ci-green override is NOT a terminal verdict: that run is still executing
# and is its own newest row, so it must never be handed to the supersession
# probe and a green PR must keep surfacing as done.
test_ci_green_override_is_not_probed_for_supersession() {
  reset_fakes
  local d out
  d=$(new_case ci-green-no-probe)
  make_repo_on_branch "$d/wt" fm/feat-ci-green-probe
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/ci-green-probe.meta" \
    "window=fm:fm-ci-green-probe" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ci-green-probe)"
  FM_FAKE_CI_LOGS='CI checks passed'
  FM_FAKE_RUNS_CALL_LOG="$d/runs-calls.log"
  out=$(run_crew_state "$d" ci-green-probe)
  assert_contains "$out" "state: done" "a green PR still surfaces as done"
  assert_runs_calls 0 "$FM_FAKE_RUNS_CALL_LOG" "the ci-green override pays no supersession probe"
  pass "the ci-green override is never handed to the supersession probe"
}

# The probe's cost damping. A terminal run nothing ever replaces answers "not
# superseded" forever, and re-asking the runs list on every read is what made
# bin/fm-inactive-reconcile.sh's per-child budget worse for exactly the children
# it exists to report. The negative answer is remembered per task and worktree
# head for FM_RUN_SUPERSEDED_TTL seconds; a positive one never is.
test_terminal_supersession_probe_is_damped_but_never_caches_a_positive() {
  reset_fakes
  local d short out
  d=$(new_case supersession-damping)
  make_repo_on_branch "$d/wt" fm/feat-damping
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/damping.meta" "window=fm:fm-damping" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_outcome fm/feat-damping failed)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-damping ${short}  2026-08-16 08:43"
  FM_FAKE_RUNS_CALL_LOG="$d/runs-calls.log"

  out=$(run_crew_state "$d" damping)
  assert_contains "$out" "state: failed" "an unreplaced failed run is still failed on the first read"
  assert_runs_calls 1 "$FM_FAKE_RUNS_CALL_LOG" "the first read probes the runs list once"

  out=$(run_crew_state "$d" damping)
  assert_contains "$out" "state: failed" "the cached negative keeps the terminal verdict"
  assert_runs_calls 1 "$FM_FAKE_RUNS_CALL_LOG" "the second read is damped by the cached negative"

  out=$(PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_RUN_SUPERSEDED_TTL=0 \
    "$CREW_STATE" damping)
  assert_contains "$out" "state: failed" "an expired entry still reports the terminal verdict"
  assert_runs_calls 2 "$FM_FAKE_RUNS_CALL_LOG" "an expired entry re-probes"

  : > "$FM_FAKE_RUNS_CALL_LOG"
  rm -f "$d/state/.run-superseded-damping"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-damping ${short}  2026-08-16 08:56
  failed     fm/feat-damping ${short}  2026-08-16 08:43
EOF
)"
  out=$(run_crew_state "$d" damping)
  assert_contains "$out" "state: working" "a replacement is detected"
  out=$(run_crew_state "$d" damping)
  assert_contains "$out" "state: working" "the positive verdict is re-derived, not cached"
  assert_runs_calls 2 "$FM_FAKE_RUNS_CALL_LOG" "a positive supersession is never served from cache"
  pass "the supersession probe is damped for a negative answer and never caches a positive"
}

# The damping cache may only remember a DEFINITIVE answer. The runs call is
# fail-open, so a timed-out listing looks exactly like "no replacement" by its
# printed word alone; caching that non-answer would pin the terminal verdict for
# a whole TTL and hand bin/fm-inactive-reconcile.sh the false inactive-outcome
# record on its very first read, which is the failure this change exists to
# prevent. An unanswered listing must cost only that one read, as before.
test_unanswered_runs_listing_is_never_cached_as_absent() {
  reset_fakes
  local d short out
  d=$(new_case runs-listing-unanswered)
  make_repo_on_branch "$d/wt" fm/feat-listing-unanswered
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/listing-unanswered.meta" \
    "window=fm:fm-listing-unanswered" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_outcome fm/feat-listing-unanswered failed)"
  FM_FAKE_RUNS_FAIL=1
  FM_FAKE_RUNS_CALL_LOG="$d/runs-calls.log"

  out=$(run_crew_state "$d" listing-unanswered)
  assert_contains "$out" "state: failed" "an unanswered listing leaves the terminal verdict as it was"
  assert_runs_calls 1 "$FM_FAKE_RUNS_CALL_LOG" "the first read probes once"
  assert_absent "$d/state/.run-superseded-listing-unanswered" \
    "an unanswered listing must not be remembered as 'not superseded'"

  out=$(run_crew_state "$d" listing-unanswered)
  assert_runs_calls 2 "$FM_FAKE_RUNS_CALL_LOG" "the next read probes again instead of trusting a non-answer"

  FM_FAKE_RUNS_FAIL=0
  FM_FAKE_RUNS_LIST="  running    fm/feat-listing-unanswered ${short}  2026-08-16 08:56"
  out=$(run_crew_state "$d" listing-unanswered)
  assert_contains "$out" "state: working" "the replacement is detected as soon as the listing answers"
  pass "an unanswered runs listing is never cached as a negative supersession answer"
}

test_active_run_is_authoritative
test_stale_needs_decision_superseded
test_stale_blocked_superseded
test_genuine_parked_not_superseded
test_scalar_gate_parked_not_superseded
test_gate_block_parked_not_superseded
test_ci_ready_done_log_beats_monitoring_run
test_ci_monitoring_checks_green_surfaces_done
test_top_level_ci_checks_green_surfaces_done
test_ci_monitoring_no_checks_terminal_surfaces_done
test_ci_monitoring_green_then_rearm_stays_working
test_ci_monitoring_no_checks_yet_stays_working
test_ci_monitoring_still_waiting_stays_working
test_ci_monitoring_green_then_new_issue_stays_working
test_ci_ready_done_log_relapse_stays_working
test_ci_fixing_after_green_stays_working
test_top_level_fixing_ci_running_after_green_stays_working
test_top_level_fixing_done_log_stays_working
test_terminal_passed
test_terminal_failed
test_cross_branch_attribution_via_runs_list
test_cross_branch_attribution_picks_most_recent_row
test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status
test_other_branch_run_ignored
test_no_run_busy_pane
test_no_run_footer_text_alone_is_not_working
test_no_run_grok_uses_isolated_fallback
test_no_run_claude_session_limit_banner_paused
test_no_run_claude_weekly_limit_banner_paused
test_no_run_claude_ordinary_busy_tail_stays_working
test_no_run_non_claude_harness_ignores_limit_banner_text
test_no_run_claude_named_limit_variants_paused
test_no_run_claude_widget_only_tail_paused
test_no_run_claude_scrollback_limit_words_stay_working
test_parked_run_claude_limit_banner_paused
test_active_run_claude_limit_banner_annotates_working
test_no_run_claude_approaching_limit_warning_stays_working
test_no_run_claude_bare_limit_notice_annotates_working
test_no_run_claude_widget_phrase_in_scrollback_stays_working
test_no_run_herdr_unknown_uses_backend_capture
test_no_run_herdr_idle_agent_status_outranked_by_record
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle
test_no_run_idle_pane_uses_log
test_no_run_idle_pane_uses_keyed_log
test_no_run_idle_pane_paused
test_no_run_idle_pane_custom_paused_verb
test_no_run_idle_secondmate_resolved_event_not_state
test_dead_window_ignores_stale_status_log
test_dead_window_still_reports_terminal_run_step
test_dead_window_still_reports_active_run_step
test_no_timeout_uses_perl_bound
test_scout_skips_run_lookup
test_torn_down_worktree
test_missing_meta
test_provably_working_via_runs_list_fallback
test_not_provably_working_when_stopped
test_usage_error
test_historical_same_branch_rewritten_head_not_current
test_active_run_descendant_fix_head_remains_current
test_local_advanced_past_run_head_invalidates
test_missing_run_head_falls_back_to_current_state
test_replaced_terminal_run_not_reported_as_current
test_terminal_run_without_replacement_stays_failed
test_executing_run_with_diverged_head_is_current
test_terminal_run_with_diverged_head_still_not_attributed
test_coarse_running_row_outranks_older_matching_terminal_row
test_coarse_older_running_row_loses_to_newer_terminal_row
test_coarse_stuck_running_row_below_newer_terminal_does_not_win
test_replaced_done_run_not_reported_as_current
test_ci_green_override_is_not_probed_for_supersession
test_terminal_supersession_probe_is_damped_but_never_caches_a_positive
test_unanswered_runs_listing_is_never_cached_as_absent

echo "all fm-crew-state tests passed"
