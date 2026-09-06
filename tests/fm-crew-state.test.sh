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
#   (b2) blocked log claiming the daemon/timeout while the run is fixing with
#       fresh activity = superseded BECAUSE THE RUN IS ALIVE; the same claim
#       a genuine socket-refusal claim over a stale or terminal run record
#       remains blocked, and an ordinary blocked log over a live run keeps the generic
#       superseded reading
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
[ -z "${FM_FAKE_NM_CALL_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_NM_CALL_LOG"
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
    printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# FM_FAKE_TMUX_MISSING: the window is authoritatively gone - every addressed
# call fails, but the session inventory still answers successfully and simply
# omits the window, which is what proves absence.
# FM_FAKE_TMUX_UNREADABLE: tmux itself cannot answer - it fails to execute (a
# trimmed PATH) or errors non-definitively - so even the inventory fails, with
# a message that is NOT one of the definitive no-session/no-server/no-socket
# responses that fm_backend_tmux_agent_state owns as death.
[ "${FM_FAKE_TMUX_UNREADABLE:-0}" = 1 ] && { printf 'no current client\n' >&2; exit 1; }
case "${1:-}" in
  list-windows)
    # A successful but empty inventory: it omits the crew's window, so absence
    # is proved by the answer rather than by an addressed call failing. Only
    # reached once display-message has already failed.
    ;;
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
        [ "${FM_FAKE_HERDR_READ_FAIL:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
      get)
        if [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ]; then
          printf '{"error":{"code":"pane_not_found","message":"no such pane"}}\n'
          exit 1
        fi
        printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        if [ "${FM_FAKE_HERDR_HUSK:-0}" = 1 ]; then
          printf '{"error":{"code":"agent_not_found","message":"no agent in pane"}}\n'
          exit 0
        fi
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
  FM_FAKE_TMUX_UNREADABLE=0
  FM_FAKE_HERDR_BUSY=0
  FM_FAKE_HERDR_MISSING=0
  FM_FAKE_HERDR_READ_FAIL=0
  FM_FAKE_HERDR_HUSK=0
  FM_FAKE_HERDR_AGENT_STATUS=""
  FM_FAKE_CI_LOGS=""
  FM_FAKE_NM_CALL_LOG=""
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_BUSY FM_FAKE_BUSY_TEXT FM_FAKE_TMUX_MISSING FM_FAKE_TMUX_UNREADABLE
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_READ_FAIL FM_FAKE_HERDR_HUSK FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_CI_LOGS FM_FAKE_NM_CALL_LOG
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

# A fixing run whose active step reports FRESH activity. `axi status` emits the
# active_steps table only while a step is running or fixing, and leaves
# last_activity unprefixed while step-log or agent lifecycle events keep
# arriving - that is the client's own recency verdict.
run_fixing_active_recent() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    review,12m3s,8s,44121,"auto-fix 1/3"
EOF
}

# The same run gone QUIET: the client prefixes last_activity with `quiet` once
# nothing has arrived for longer than its configured quiet warning. This is the
# shape a run record keeps when the daemon really did die under it.
run_fixing_active_quiet() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    review,42m8s,"quiet 31m2s",44121,"auto-fix 1/3"
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
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
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

# A crew whose drive call timed out or was killed by its harness command limit
# routinely blocks claiming the pipeline died. The daemon accepts `respond`
# immediately and runs the fix round in the background, so such a claim over a
# run that is fixing WITH fresh activity is contradicted by the run itself: the
# supervisor answer is to steer a reattach, not to escalate a dead pipeline.
test_daemon_claim_over_live_run_reads_run_alive() {
  reset_fakes
  local d; d=$(new_case daemon-claim-live)
  make_repo_on_branch "$d/wt" fm/feat-dl
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dl.meta" "window=fm:fm-feat-dl" "worktree=$d/wt" "kind=ship"
  printf 'blocked: no-mistakes daemon unreachable, drive run: read response: i/o timeout\n' \
    > "$d/state/feat-dl.status"
  FM_FAKE_AXI_STATUS="$(run_fixing_active_recent fm/feat-dl)"
  local out; out=$(run_crew_state "$d" feat-dl)
  assert_contains "$out" "state: working" "live run beats the crew's death claim"
  assert_contains "$out" "source: run-step" "live run -> run-step source"
  assert_contains "$out" "run alive" "daemon claim over a live run is named as run alive"
  assert_contains "$out" "reattach" "the reading names the reattach steer"
  assert_not_contains "$out" "superseded by active run" \
    "the daemon claim gets the sharper reading, not the generic one"
  pass "daemon/timeout blocked claim over a live fixing run reads as run alive"
}

# A genuine refused socket outranks the persisted fixing record, which can
# survive after the daemon exits.
test_socket_refusal_over_stale_fixing_run_reports_blocked() {
  reset_fakes
  local d; d=$(new_case daemon-socket-refused)
  make_repo_on_branch "$d/wt" fm/feat-dq
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dq.meta" "window=fm:fm-feat-dq" "worktree=$d/wt" "kind=ship"
  printf 'blocked: no-mistakes daemon socket refused connections\n' \
    > "$d/state/feat-dq.status"
  FM_FAKE_AXI_STATUS="$(run_fixing_active_quiet fm/feat-dq)"
  local out; out=$(run_crew_state "$d" feat-dq)
  assert_contains "$out" "state: blocked" "socket refusal outranks a stale fixing record"
  assert_contains "$out" "source: status-log" "socket refusal remains status-log evidence"
  assert_contains "$out" "socket refused connections" "socket failure is preserved"
  assert_not_contains "$out" "run alive" "stale fixing record is not reported alive"

  # Exercise the exact alternate wordings emitted by the generated crew rule.
  printf 'blocked: no-mistakes daemon socket refuses connections\n' \
    > "$d/state/feat-dq.status"
  out=$(run_crew_state "$d" feat-dq)
  assert_contains "$out" "state: blocked" "socket-refuses wording outranks a stale fixing record"
  assert_not_contains "$out" "state: working" "socket-refuses wording cannot be suppressed by a stale active record"

  printf 'blocked: no-mistakes daemon socket is missing\n' \
    > "$d/state/feat-dq.status"
  out=$(run_crew_state "$d" feat-dq)
  assert_contains "$out" "state: blocked" "missing socket outranks a stale fixing record"
  assert_contains "$out" "source: status-log" "missing socket remains status-log evidence"
  assert_not_contains "$out" "state: working" "missing socket cannot be suppressed by a stale active record"
  pass "socket refusal or missing socket over a stale fixing run reports blocked"
}

# A terminal run record can be the final persisted state after the daemon exits.
# Positive socket-failure evidence must not be discarded merely because that
# attributed record no longer has an active status.
test_socket_refusal_over_terminal_run_reports_blocked() {
  reset_fakes
  local d; d=$(new_case daemon-socket-refused-terminal)
  make_repo_on_branch "$d/wt" fm/feat-dqt
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dqt.meta" "window=fm:fm-feat-dqt" "worktree=$d/wt" "kind=ship"
  printf 'blocked: no-mistakes daemon socket refused connections\n' \
    > "$d/state/feat-dqt.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-dqt)"
  local out; out=$(run_crew_state "$d" feat-dqt)
  assert_contains "$out" "state: blocked" "socket refusal outranks a terminal run record"
  assert_contains "$out" "source: status-log" "terminal run cannot suppress socket-failure evidence"
  assert_not_contains "$out" "state: failed" "terminal run state is not emitted over socket-failure evidence"
  pass "socket refusal over a terminal attributed run reports blocked"
}

# And the claim half: an ordinary blocked line over the same live run keeps the
# generic reading, so the sharper one cannot fire on every superseded block.
test_ordinary_blocked_over_live_run_keeps_plain_superseded() {
  reset_fakes
  local d; d=$(new_case ordinary-blocked-live)
  make_repo_on_branch "$d/wt" fm/feat-ob
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ob.meta" "window=fm:fm-feat-ob" "worktree=$d/wt" "kind=ship"
  printf 'blocked: database upload failed with broken pipe\n' > "$d/state/feat-ob.status"
  FM_FAKE_AXI_STATUS="$(run_fixing_active_recent fm/feat-ob)"
  local out; out=$(run_crew_state "$d" feat-ob)
  assert_contains "$out" "state: working" "ordinary blocked log over an active run -> working"
  assert_contains "$out" "superseded by active run" "ordinary blocked keeps the generic reading"
  assert_not_contains "$out" "run alive" "broken pipe is not a pipeline-unreachable alias"
  pass "broken-pipe blocker over a live run keeps the plain superseded reading"
}

# The genuine daemon-down case still reaches the supervisor as blocked: the
# socket refused connections and no run is executing anywhere.
test_genuine_daemon_down_reports_blocked() {
  reset_fakes
  local d; d=$(new_case daemon-down)
  make_repo_on_branch "$d/wt" fm/feat-dd
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dd.meta" "window=fm:fm-feat-dd" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: no-mistakes daemon socket refused connections\n' > "$d/state/feat-dd.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-dd
  local out; out=$(run_crew_state "$d" feat-dd)
  assert_contains "$out" "state: blocked" "a genuine daemon-down claim with no run stays blocked"
  assert_contains "$out" "source: status-log" "no run -> status-log source"
  assert_not_contains "$out" "run alive" "nothing is alive to report"
  pass "genuine daemon-down blocked line still reports blocked"
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
test_coarse_socket_refusal_reports_blocked() {
  reset_fakes
  local d short; d=$(new_case coarse-socket-refused)
  make_repo_on_branch "$d/wt" fm/feat-coarse-down
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarse-down.meta" "window=fm:fm-feat-coarse-down" "worktree=$d/wt" "kind=ship"
  printf 'blocked: no-mistakes daemon connection refused\n' > "$d/state/feat-coarse-down.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-coarse-down ${short}  2026-07-02 22:05
EOF
)"
  local out; out=$(run_crew_state "$d" feat-coarse-down)
  assert_contains "$out" "state: blocked" "socket refusal outranks a coarse active record"
  assert_contains "$out" "source: status-log" "coarse socket refusal remains status-log evidence"
  assert_not_contains "$out" "state: working" "coarse active record cannot suppress socket refusal"
  pass "socket refusal over a coarse active run reports blocked"
}

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

# Regression (2026-09 G7 stale-claim incident): a herdr CLI that errors or
# stalls under load made pane_readable's capture fail, and the fallback read
# that single failure as "backend target gone" - text the stale sweep matches
# as positive death - so a busy box briefly scored dozens of live claims dead.
# The reader must separate the two outcomes: only a successful herdr answer
# proving the pane absent may say gone; a CLI that failed to answer is unknown
# and unreachable, never death.
test_no_run_herdr_cli_failure_reads_unreachable_not_gone() {
  command -v jq >/dev/null 2>&1 || { pass "herdr cli-failure fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-cli-dead)
  make_repo_on_branch "$d/wt" fm/feat-herdr-cli
  make_fakebin "$d" >/dev/null
  # A herdr whose server is up but whose endpoint calls cannot answer at all:
  # every pane/agent invocation exits non-zero, the busiest-box form of a
  # stalled CLI (capture and pane get alike fail). `status` still answers so
  # the reader probes the endpoint instead of waiting out a server start.
  cat > "$d/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = status ] && { printf '{"server":{"running":true}}\n'; exit 0; }
exit 1
SH
  chmod +x "$d/fakebin/herdr"
  fm_write_meta "$d/state/feat-herdr-cli.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-herdr-cli)
  assert_contains "$out" "state: unknown" "a failed herdr CLI must stay unknown"
  assert_contains "$out" "source: none" "a failed herdr CLI has no state source"
  assert_contains "$out" "backend unreachable" "a failed herdr CLI must read as unreachable, not gone"
  assert_not_contains "$out" "backend target gone" "a failed herdr CLI is not positive death evidence"
  pass "a herdr CLI that fails to answer reads unknown/unreachable, never gone"
}

# Decision follow-up (2026-09-05 review): an `alive` endpoint answer is
# authoritative even when the heavy scrollback read failed - the live state is
# classified by the normal flow, never discarded as unreachable.
test_no_run_herdr_alive_with_failed_read_stays_live() {
  command -v jq >/dev/null 2>&1 || { pass "herdr alive/read-fail test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-alive-readfail)
  make_repo_on_branch "$d/wt" fm/feat-herdr-alive
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-alive.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  # The 200-line scrollback read fails while the cheap pane get / agent get
  # pair answers: the pane is present and its agent is working.
  FM_FAKE_HERDR_READ_FAIL=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-herdr-alive)
  assert_contains "$out" "state: working" "an alive endpoint with a failed scrollback read stays live"
  assert_not_contains "$out" "backend unreachable" "an authoritative alive answer is never unreachable"
  assert_not_contains "$out" "backend target gone" "an authoritative alive answer is never death"
  pass "an alive endpoint whose scrollback read failed stays working"
}

# Decision follow-up (2026-09-05 review): a husk pane (pane present,
# agent_not_found) is authoritative death evidence - it keeps the gone-class
# text so the stale sweep may still reclaim it, never unknown/unreachable.
test_no_run_herdr_husk_dead_still_reads_gone() {
  command -v jq >/dev/null 2>&1 || { pass "herdr husk test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-husk-dead)
  make_repo_on_branch "$d/wt" fm/feat-herdr-husk
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-husk.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  # The pane exists and answers pane get, but no agent is registered in it,
  # and the scrollback read fails besides.
  FM_FAKE_HERDR_READ_FAIL=1
  FM_FAKE_HERDR_HUSK=1
  local out; out=$(run_crew_state "$d" feat-herdr-husk)
  assert_contains "$out" "state: unknown" "a husk pane has no live current state"
  assert_contains "$out" "backend target gone" "a husk pane keeps its gone-class death evidence"
  assert_contains "$out" "agent gone, pane shell remains" "the husk verdict names what actually died"
  assert_not_contains "$out" "backend unreachable" "a husk pane is not an unreachable backend"
  pass "a husk pane (agent gone) still reads gone for reclaim"
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
  assert_contains "$out" "backend target gone" "an inventory that omits the window is positive death evidence"
  pass "dead window ignores stale status log"
}

# Regression (2026-09 G7 stale-claim incident, tmux half): the default backend
# reached the same false-death path as herdr. A tmux that cannot answer at all
# - a trimmed PATH, or any non-definitive error - made every live crew report
# "backend target gone", the text the stale sweep matches as positive death.
# Absence must be proved by tmux's own answer: a window inventory that omits
# the recorded window, or one of its definitive no-session/no-server/no-socket
# responses. Anything else is a tmux that failed to answer: unknown, never
# death. (A socket-connection error is deliberately NOT in this test's scope -
# fm_backend_tmux_agent_state classifies it as `missing` so fm-bootstrap and
# fm-session-start can respawn after a genuine server death.)
test_no_run_tmux_unreadable_reads_unreachable_not_gone() {
  reset_fakes
  local d; d=$(new_case tmux-unreadable)
  make_repo_on_branch "$d/wt" fm/feat-tmux-unread
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-tmux-unread.meta" "window=fm:fm-feat-tmux-unread" \
    "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-tmux-unread.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_UNREADABLE=1
  local out; out=$(run_crew_state "$d" feat-tmux-unread)
  assert_contains "$out" "state: unknown" "an unreadable tmux must stay unknown"
  assert_contains "$out" "source: none" "an unreadable tmux has no state source"
  assert_contains "$out" "backend unreachable" "an unreadable tmux reads as unreachable, not gone"
  assert_not_contains "$out" "backend target gone" "an unreadable tmux is not positive death evidence"
  pass "a tmux that fails to answer reads unknown/unreachable, never gone"
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

# --- remote secondmate arm ---------------------------------------------------
# A meta recording remote_host= must never be read through the local worktree
# probe or a local backend adapter: the recorded worktree and pane live on the
# remote host, and the old local reads misreported a healthy remote mate as
# "worktree gone". These cases drive the real helper over the real fm-on.sh
# route with a stubbed ssh transport (FM_SSH_BIN seam): the stub prints
# FM_FAKE_REMOTE_STATE_OUT as the remote endpoint's recovery-grade state and
# exits FM_FAKE_SSH_RC.

setup_remote_case() {  # <name> -> echoes case dir with remote meta + registry
  local d
  d=$(new_case "$1")
  mkdir -p "$d/data" "$d/fakebin"
  fm_write_meta "$d/state/rsm.meta" \
    "window=remote:rsm" \
    "endpoint_task_id=rsm" \
    "worktree=/remote/home/never-locally-present" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  cat > "$d/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  cat > "$d/fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
[ -z "${FM_FAKE_REMOTE_STATE_OUT:-}" ] || printf '%s\n' "$FM_FAKE_REMOTE_STATE_OUT"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$d/fakebin/fake-ssh"
  printf '%s\n' "$d"
}

run_remote_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_SSH_BIN="$1/fakebin/fake-ssh" "$CREW_STATE" "$2"
}

test_remote_alive_with_log_uses_status_log() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-log)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(FM_FAKE_REMOTE_STATE_OUT=alive FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive exits 0"
  assert_contains "$out" "state: working" "alive remote mate with a working log reads working"
  assert_contains "$out" "source: status-log" "alive remote mate reads current activity from the routed log"
  assert_contains "$out" "remote endpoint alive on remote-mac" "the remote liveness read should be visible"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  pass "fm-crew-state remote: alive endpoint falls through to the routed status log"
}

test_remote_alive_idle_is_healthy_not_gone() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-idle)
  make_fakebin "$d" >/dev/null
  out=$(FM_FAKE_REMOTE_STATE_OUT=alive FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive-idle exits 0"
  assert_contains "$out" "source: remote-endpoint" "the remote endpoint is the reported source"
  assert_contains "$out" "alive on remote-mac" "an idle remote mate reads alive"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  assert_not_contains "$out" "backend target gone" "a healthy remote mate must never read as a dead target"
  pass "fm-crew-state remote: an idle alive endpoint reads alive, never gone or dead"
}

test_remote_unreachable_is_unknown_remote_not_dead() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-unreachable)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(FM_FAKE_SSH_RC=255 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "unreachable remote exits 0"
  assert_contains "$out" "unknown-remote" "an unreachable remote must be labeled unknown-remote"
  assert_contains "$out" "not proof of death" "an unreachable remote must not read as dead"
  assert_not_contains "$out" "worktree gone" "an unreachable remote must never read as torn down"
  assert_not_contains "$out" "backend target gone" "an unreachable remote must never read as a dead target"
  pass "fm-crew-state remote: an unreachable host reads unknown-remote, never gone or dead"
}

test_remote_dead_reports_remote_verdict() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-dead)
  make_fakebin "$d" >/dev/null
  out=$(FM_FAKE_REMOTE_STATE_OUT=dead FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote dead exits 0"
  assert_contains "$out" "remote endpoint dead on remote-mac" \
    "a genuinely dead remote endpoint reports the remote host's own verdict"
  pass "fm-crew-state remote: the remote host's own dead verdict is reported truthfully"
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

# --- Run-attribution precedence for pipeline-owned lane heads ----------------
# A live run whose pipeline OWNS the branch (branch_sync.state=pipeline_owned)
# can report a lane head that is not a git object in the task worktree.
# Every fixture head is deliberately unresolvable so only the top-level
# branch_sync exemption - never an accidental nested-field match - attributes
# the run.
run_running_pipeline_owned() {  # <branch> <head> [<sync-state>]
  cat <<EOF
run:
  id: "01RUNLIVE"
  branch: $1
  status: running
  head: "$2"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
branch_sync:
  state: ${3:-pipeline_owned}
  changed: false
  local:
    branch: $1
    head: "e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5"
    clean: true
  next_action:
    code: continue_active_run
    command: no-mistakes axi status
EOF
}

# T1 direction 1: the daemon-attributed ACTIVE pipeline-owned run binds without
# head equality and wins over the older superseded failed row.
test_pipeline_owned_active_run_beats_superseded_failed_row() {
  reset_fakes
  local d short; d=$(new_case f10-pipeline-owned)
  make_repo_on_branch "$d/wt" fm/feat-f10
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10.meta" "window=fm:fm-feat-f10" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running_pipeline_owned fm/feat-f10 f0f0f0f0)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-f10 f0f0f0f0  2026-08-27 13:53
  failed     fm/feat-f10 ${short}  2026-08-27 12:09
EOF
)"
  local out; out=$(run_crew_state "$d" feat-f10)
  assert_contains "$out" "state: working" "pipeline-owned live run -> working"
  assert_contains "$out" "source: run-step" "pipeline-owned live run -> run-step source"
  assert_not_contains "$out" "state: failed" "superseded failed row must not surface over the live run"
  pass "pipeline-owned active run binds without head equality and beats the failed row"
}

# T1 direction 2: a genuinely-failed run with NO later run on the branch still
# surfaces as failed - hiding real failures is equally wrong.
test_failed_run_with_no_later_run_still_surfaces() {
  reset_fakes
  local d short; d=$(new_case f10-genuine-failure)
  make_repo_on_branch "$d/wt" fm/feat-f10b
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10b.meta" "window=fm:fm-feat-f10b" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-f10b)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-f10b ${short}  2026-08-27 12:09"
  local out; out=$(run_crew_state "$d" feat-f10b)
  assert_contains "$out" "state: failed" "a genuinely failed run with no later run still reports failed"
  assert_contains "$out" "source: run-step" "the genuine failure is run-step sourced"
  pass "a genuinely failed run with no later run is not hidden"
}

# The coarse runs-list rows: the branch's newest row is ACTIVE at an
# unresolvable head and the row immediately before it ended at exactly this
# worktree's head - the ledger proves this is this crew's own pipeline-owned
# fix round (axi status answers another branch here, so attribution can only
# go through the coarse list). The anchored active run answers via the
# run-step, and the older failed row never surfaces.
test_coarse_unresolvable_active_row_never_falls_to_older_row() {
  reset_fakes
  local d short; d=$(new_case f10-coarse-guard)
  make_repo_on_branch "$d/wt" fm/feat-f10c
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10c.meta" "window=fm:fm-feat-f10c" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-27 14:00
  running    fm/feat-f10c f0f0f0f0  2026-08-27 13:53
  failed     fm/feat-f10c ${short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-f10c)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-f10c busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-f10c)
  assert_not_contains "$out" "state: failed" "an unresolvable active row must not fall to the older failed row"
  assert_contains "$out" "source: run-step" "the ledger-anchored continuation binds via the runs list"
  assert_contains "$out" "state: working" "the anchored active fix round reads working"
  assert_contains "$out" "validating (background run)" "coarse resolution keeps coarse run detail"
  pass "coarse scan anchors the unresolvable active row instead of falling to an older one"
}

# Coarse negative control: the anchor must end at EXACTLY this worktree's
# head. The newest same-branch row is active at an unresolvable head, but the
# row immediately before it sits at an OLDER local commit, so the ledger
# proves nothing - unknown attribution stops the scan, never falls to the
# older failed row, and the busy pane answers instead.
test_coarse_mismatched_anchor_falls_to_pane_not_older_row() {
  reset_fakes
  local d old_short; d=$(new_case f10-coarse-no-anchor)
  make_repo_on_branch "$d/wt" fm/feat-f10g
  git -C "$d/wt" commit -q --allow-empty -m 'second local commit'
  old_short=$(git -C "$d/wt" rev-parse --short=8 HEAD~1)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10g.meta" "window=fm:fm-feat-f10g" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-27 14:00
  running    fm/feat-f10g f0f0f0f0  2026-08-27 13:53
  failed     fm/feat-f10g ${old_short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-f10g)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-f10g busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-f10g)
  assert_not_contains "$out" "state: failed" "a mismatched anchor must not fall to the older failed row"
  assert_not_contains "$out" "source: run-step" "unknown attribution must not bind a run"
  assert_contains "$out" "state: working" "the busy crew still reads working through the pane fallback"
  assert_contains "$out" "source: pane" "without an exact anchor the pane answers, not the runs rows"
  pass "coarse scan with a mismatched anchor stays unknown and lets the pane answer"
}

# Negative control: the exemption is gated on pipeline_owned specifically - any
# other branch_sync state keeps the strict head rule.
test_non_pipeline_owned_unresolvable_head_not_attributed() {
  reset_fakes
  local d; d=$(new_case f10-not-owned)
  make_repo_on_branch "$d/wt" fm/feat-f10d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10d.meta" "window=fm:fm-feat-f10d" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-f10d.status"
  FM_FAKE_AXI_STATUS="$(run_running_pipeline_owned fm/feat-f10d f0f0f0f0 synced)"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-f10d
  local out; out=$(run_crew_state "$d" feat-f10d)
  assert_not_contains "$out" "source: run-step" "a non-pipeline-owned unresolvable head must not bind"
  assert_contains "$out" "source: status-log" "falls back to the status log without the exemption"
  pass "the exemption requires branch_sync.state=pipeline_owned"
}

# Negative control: the exemption also requires an ACTIVE run - a terminal run
# released the branch, so an inconsistent pipeline_owned label must not bind a
# terminal run by branch name alone.
test_pipeline_owned_terminal_run_not_exempt() {
  reset_fakes
  local d; d=$(new_case f10-terminal-not-exempt)
  make_repo_on_branch "$d/wt" fm/feat-f10e
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10e.meta" "window=fm:fm-feat-f10e" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 in progress\n' > "$d/state/feat-f10e.status"
  FM_FAKE_AXI_STATUS="$(run_running_pipeline_owned fm/feat-f10e f0f0f0f0)
outcome: failed"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-f10e
  local out; out=$(run_crew_state "$d" feat-f10e)
  assert_not_contains "$out" "source: run-step" "a terminal run must not bind through the exemption"
  assert_contains "$out" "source: status-log" "falls back to the status log for a terminal unresolvable head"
  pass "the exemption never applies to a terminal run"
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

# Mint a descendant of <repo>'s HEAD in a separate clone, echoing its full sha.
# The task copy never receives the new object, which is exactly the incident
# shape: the pipeline committed its fix round in its own checkout, so the run
# head advanced beyond the submitted head while the task copy lacks the commit.
mint_unfetched_fix_head() {  # <worktree>
  local wt=$1 h2
  rm -rf "$wt.pipe"
  git clone -q "$wt" "$wt.pipe"
  git -C "$wt.pipe" commit -q --allow-empty -m 'pipeline fix round commit'
  h2=$(git -C "$wt.pipe" rev-parse HEAD)
  if git -C "$wt" cat-file -e "$h2" 2>/dev/null; then
    fail "fixture broken: fix head object leaked into the task copy"
  fi
  printf '%s' "$h2"
}

# Head-binding regression (model-routing-benchmark-hardening incident): the
# active run's head advanced beyond the submitted head through a pipeline fix
# round whose commit object never reached the task copy. The reader must
# attribute the active run through the pipeline's own ledger - its newest row
# for the branch is active with a locally unverifiable head, and the row
# immediately before it ended at exactly this worktree's head - instead of
# rejecting the active row and letting the older failed row answer.
test_active_fix_round_unfetched_pipeline_head_reports_current() {
  reset_fakes
  local d h1 h2 out
  d=$(new_case unfetched-fix-head)
  make_repo_on_branch "$d/wt" fm/feat-unfetched
  h1=$(git -C "$d/wt" rev-parse HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  [ "$h1" != "$h2" ] || fail "fix head did not advance past the submitted head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unfetched.meta" "window=fm:fm-unfetched" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-unfetched)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other aaaaaaa  2026-07-30 22:10
  running    fm/feat-unfetched $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-unfetched $(git -C "$d/wt" rev-parse --short=7 HEAD)  2026-07-29 20:00
EOF
)"
  out=$(run_crew_state "$d" unfetched)
  assert_contains "$out" "source: run-step" "active run with an unfetched pipeline head still attributes"
  assert_contains "$out" "state: working" "active fix round reads working, not the older failed row"
  assert_contains "$out" "validating (fixing)" "full run detail survives the unfetched pipeline head"
  assert_not_contains "$out" "state: failed" "the older failed row must never answer for the active run"
  pass "active fix round with an unfetched pipeline head reads working"
}

# Negative control for the ledger continuation rule: without the anchor row
# ending at exactly this worktree's head, an active row with an unverifiable
# head is branch-name coincidence and must stay unattributed - the historical
# status-log fallback answers instead, never the runs rows.
test_unanchored_unfetched_active_row_does_not_match() {
  reset_fakes
  local d h2 out
  d=$(new_case unfetched-no-anchor)
  make_repo_on_branch "$d/wt" fm/feat-noanchor
  # A second commit gives the ledger a resolvable anchor row (HEAD~1) that is
  # NOT this worktree's head - the exact-equality anchor must fail on it.
  git -C "$d/wt" commit -q --allow-empty -m 'second local commit'
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/noanchor.meta" "window=fm:fm-noanchor" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'failed: earlier stage run\n' > "$d/state/noanchor.status"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-noanchor)"
  # The row before the active one is an OLDER commit, not this worktree's
  # head: the ledger proves nothing about whose run the active row is.
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other aaaaaaa  2026-07-30 22:10
  running    fm/feat-noanchor $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-noanchor $(git -C "$d/wt" rev-parse --short=7 HEAD~1)  2026-07-29 20:00
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" noanchor
  out=$(run_crew_state "$d" noanchor)
  assert_not_contains "$out" "source: run-step" "an unanchored unverifiable active row must not match"
  assert_contains "$out" "source: status-log" "historical fallback preserved when no active run is proven"
  assert_contains "$out" "state: failed" "status-log answers, not the runs rows"
  pass "unanchored unverifiable active row is never attributed"
}

# Negative control: a TERMINAL row whose commit object is gone from the task
# copy is history even when it is the branch's newest row - an ancient or
# rewritten run whose commit was pruned must never read as current state.
test_unresolved_terminal_row_is_history_not_current() {
  reset_fakes
  local d h_old out
  d=$(new_case unresolved-terminal)
  make_repo_on_branch "$d/wt" fm/feat-hist
  # Mint the historical run head outside the task copy, then orphan-rewrite
  # the worktree tip, so the run head can never resolve locally.
  h_old=$(mint_unfetched_fix_head "$d/wt")
  git -C "$d/wt" checkout -q --orphan tmp-rewrite
  git -C "$d/wt" commit -q --allow-empty -m 'rewritten tip'
  git -C "$d/wt" branch -q -M fm/feat-hist
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/hist.meta" "window=fm:fm-hist" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 in progress\n' > "$d/state/hist.status"
  FM_FAKE_RUN_HEAD="$h_old"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-hist)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-hist $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-01 20:00
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" hist
  out=$(run_crew_state "$d" hist)
  assert_not_contains "$out" "source: run-step" "an unresolvable terminal row is history, not current state"
  assert_contains "$out" "source: status-log" "historical fallback answers after an unresolvable terminal row"
  assert_contains "$out" "state: working" "the rewritten worktree's own log stays current"
  pass "unresolvable terminal row never reads as current"
}

# The same continuation recognition must work when bare `axi status` answers
# with ANOTHER branch's run: this branch's own active run is then visible only
# in the ledger, with coarse (status-word) detail.
test_runs_list_continuation_found_when_axi_answers_other_branch() {
  reset_fakes
  local d h1 h2 out
  d=$(new_case unfetched-coarse)
  make_repo_on_branch "$d/wt" fm/feat-coarsefix
  h1=$(git -C "$d/wt" rev-parse HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/coarsefix.meta" "window=fm:fm-coarsefix" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-30 22:10
  running    fm/feat-coarsefix $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-coarsefix $(git -C "$d/wt" rev-parse --short=7 HEAD)  2026-07-29 20:00
EOF
)"
  out=$(run_crew_state "$d" coarsefix)
  assert_contains "$out" "source: run-step" "ledger continuation attributes via the runs list too"
  assert_contains "$out" "state: working" "coarse continuation reads working"
  assert_contains "$out" "validating (background run)" "coarse resolution keeps coarse detail, not the other branch's run"
  pass "runs-list continuation attribution works when axi answers another branch"
}

# ---------------------------------------------------------------------------
# Run ownership on ONE branch: the binding and the delivery-mode gate.
#
# Branch attribution alone cannot separate concurrent crews whose worktrees sit
# on one long-lived feature branch, and no-mistakes exposes nothing that names
# the worktree a run was invoked from (bin/fm-crew-state.sh's header records the
# three surfaces checked). These cases pin the two guards that settle ownership.

# Two ship crews on ONE branch, sharing an object store and the branch ref, so
# both resolve the same HEAD and both satisfy the head rule for a single run.
make_shared_branch_case() {  # <name> <branch> -> echoes case dir
  local d branch=$2
  d=$(new_case "$1")
  mkdir -p "$d/repo"
  git -C "$d/repo" init -q
  git -C "$d/repo" commit -q --allow-empty -m init
  git -C "$d/repo" checkout -q -b "$branch"
  git -C "$d/repo" worktree add -q --force "$d/wt-owner" "$branch" 2>/dev/null
  git -C "$d/repo" worktree add -q --force "$d/wt-other" "$branch" 2>/dev/null
  printf '%s\n' "$d"
}

# The shared HEAD both worktrees resolve, exported for the run fixtures. Set by
# the caller rather than inside make_shared_branch_case: that helper is read
# through a command substitution, so an export inside it never reaches the case.
arm_shared_head() {  # <case-dir>
  FM_FAKE_RUN_HEAD=$(git -C "$1/wt-owner" rev-parse HEAD)
  export FM_FAKE_RUN_HEAD
}

# The active run object both crews' `axi status` answers, since the real CLI is
# repo-scoped and returns the identical run from either worktree.
run_running_id() {  # <branch> <run-id>
  cat <<EOF
run:
  id: "$2"
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

test_bound_owner_keeps_the_run_its_neighbour_loses_it() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case bound-owner fm/shared-bound)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes" "nm_run=01BOUNDRUN0000000000000001"
  fm_write_meta "$d/state/other.meta" "window=fm:fm-other" "worktree=$d/wt-other" \
    "kind=ship" "mode=no-mistakes" "harness=claude"
  printf 'paused: waiting on the captain\n' > "$d/state/other.status"
  arm_idle_record "$d/state" other
  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-bound 01BOUNDRUN0000000000000001)"

  out=$(run_crew_state "$d" owner)
  assert_contains "$out" "state: working" "the bound crew still reads its own run"
  assert_contains "$out" "source: run-step" "the bound crew reads it from the run step"

  out=$(run_crew_state "$d" other)
  assert_not_contains "$out" "state: working" \
    "a crew on the same branch must not inherit a run another task has bound"
  assert_contains "$out" "state: paused" \
    "the unbound crew falls to its own declared wait"
  pass "a bound run stays with its owner and is withheld from its co-branch neighbour"
}

test_unbound_neighbour_without_a_status_line_is_not_working() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case bound-owner-quiet fm/shared-quiet)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes" "nm_run=01BOUNDRUN0000000000000002"
  fm_write_meta "$d/state/other.meta" "window=fm:fm-other" "worktree=$d/wt-other" \
    "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-quiet 01BOUNDRUN0000000000000002)"
  out=$(run_crew_state "$d" other)
  assert_not_contains "$out" "state: working" \
    "with no status line of its own the unbound crew still must not read working"
  pass "an unbound co-branch crew with no status line never reads working"
}

test_no_bindings_on_the_branch_preserves_legacy_behaviour() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case unbound-legacy fm/shared-legacy)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes"
  fm_write_meta "$d/state/other.meta" "window=fm:fm-other" "worktree=$d/wt-other" \
    "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-legacy 01LEGACYRUN000000000000001)"
  out=$(run_crew_state "$d" owner)
  assert_contains "$out" "state: working" "an unbound crew still reads the branch's run"
  out=$(run_crew_state "$d" other)
  assert_contains "$out" "state: working" \
    "with no binding anywhere the branch behaviour is unchanged, so no home regresses"
  pass "no bindings on the branch preserves the existing branch-based behaviour"
}

test_bound_crew_ignores_a_run_that_is_not_its_own() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case bound-mismatch fm/shared-mismatch)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes" "harness=claude" "nm_run=01BOUNDRUN0000000000000003"
  printf 'paused: waiting on the captain\n' > "$d/state/owner.status"
  arm_idle_record "$d/state" owner
  # The repo's current run is a different id: someone else's, whatever the
  # branch says. The coarse ledger cannot overrule it either, because the runs
  # listing carries no run id column to check the binding against.
  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-mismatch 01OTHERRUN0000000000000009)"
  FM_FAKE_RUNS_LIST="  running    fm/shared-mismatch $(git -C "$d/wt-owner" rev-parse --short=7 HEAD)  2026-09-04 10:00"
  out=$(run_crew_state "$d" owner)
  assert_not_contains "$out" "state: working" \
    "a bound crew must not be credited a run whose id is not its own"
  pass "a bound crew is never credited a run that is not its binding"
}

# The bound crew's own run is fetched by id when the repo's current run is
# another crew's on ANOTHER branch: before, a foreign-branch answer that failed
# the id rule was dropped outright, and the compliant owner fell to its idle
# pane and read as a possible wedge.
test_bound_crew_finds_its_own_run_by_id_when_axi_answers_another_branch() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case bound-by-id fm/shared-byid)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes" "harness=claude" "nm_run=01BOUNDRUN0000000000000004"
  arm_idle_record "$d/state" owner
  FM_FAKE_AXI_STATUS="$(run_running_id fm/other-crew 01OTHERRUN0000000000000010)"
  FM_FAKE_AXI_STATUS_RUN="$(run_running_id fm/shared-byid 01BOUNDRUN0000000000000004)"
  out=$(run_crew_state "$d" owner)
  assert_contains "$out" "state: working" \
    "a bound crew must still be credited its own run when the repo's current run is another branch's"
  assert_contains "$out" "source: run-step" "the bound crew reads it from the run step"
  assert_contains "$out" "validating (running)" \
    "the run fetched by id carries the crew's own full step detail, not coarse ledger detail"
  pass "a bound crew's own run is found by id when axi answers another branch"
}

# The coarse ledger route names no run id, so it is gated by the branch: while
# a sibling binds a run from a worktree on this branch, an unbound co-branch
# crew is withheld branch-level credit entirely - even when the repo's current
# run is an UNBOUND run on another branch, which the id rule alone would let
# through to the ledger. The bound sibling itself keeps its run, by id.
test_unbound_cobranch_crew_is_withheld_coarse_credit_while_a_sibling_is_bound() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case coarse-gate fm/shared-coarse)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes" "harness=claude" "nm_run=01BOUNDRUN0000000000000005"
  fm_write_meta "$d/state/other.meta" "window=fm:fm-other" "worktree=$d/wt-other" \
    "kind=ship" "mode=no-mistakes" "harness=claude"
  printf 'paused: waiting on the captain\n' > "$d/state/other.status"
  arm_idle_record "$d/state" owner
  arm_idle_record "$d/state" other
  FM_FAKE_AXI_STATUS="$(run_running_id fm/other-crew 01NOBODYSRUN00000000000011)"
  FM_FAKE_AXI_STATUS_RUN="$(run_running_id fm/shared-coarse 01BOUNDRUN0000000000000005)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-09-04 10:10
  running    fm/shared-coarse $(git -C "$d/wt-owner" rev-parse --short=7 HEAD)  2026-09-04 10:05
EOF
)"
  out=$(run_crew_state "$d" other)
  assert_not_contains "$out" "state: working" \
    "an unbound co-branch crew must not take the ledger's branch credit while a sibling binds a run there"
  assert_contains "$out" "state: paused" "the unbound crew falls to its own declared wait"

  out=$(run_crew_state "$d" owner)
  assert_contains "$out" "state: working" "the bound sibling still reads its own run"
  assert_contains "$out" "source: run-step" "the bound sibling reads it from the run step"
  pass "the coarse ledger route is withheld from an unbound co-branch crew while a sibling is bound"
}

# The sibling scan is scoped by the `project=` root bin/fm-spawn.sh records.
# Two records of the SAME project sharing a branch: the bound sibling still
# withholds the ledger's branch credit from the unbound crew.
test_same_project_bound_sibling_withholds_coarse_credit() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case project-same fm/shared-project-same)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "project=$d/repo" "kind=ship" "mode=no-mistakes" "nm_run=01BOUNDRUN0000000000000031"
  fm_write_meta "$d/state/other.meta" "window=fm:fm-other" "worktree=$d/wt-other" \
    "project=$d/repo" "kind=ship" "mode=no-mistakes" "harness=claude"
  printf 'paused: waiting on the captain\n' > "$d/state/other.status"
  arm_idle_record "$d/state" other
  FM_FAKE_AXI_STATUS="$(run_running_id fm/other-crew 01NOBODYSRUN00000000000031)"
  FM_FAKE_RUNS_LIST="  running    fm/shared-project-same $(git -C "$d/wt-other" rev-parse --short=7 HEAD)  2026-09-04 10:05"
  out=$(run_crew_state "$d" other)
  assert_not_contains "$out" "validating (background run)" \
    "a bound sibling of the same project must still withhold the ledger's branch credit"
  assert_not_contains "$out" "state: working" "the unbound crew must not read working on the sibling's run"
  assert_contains "$out" "state: paused" "the unbound crew falls to its own declared wait"
  pass "a same-project bound sibling on the branch withholds coarse credit"
}

# A bound record of ANOTHER project is never this branch's claimant, even when
# its worktree happens to sit on a branch of the same name: it is skipped, and
# the unbound crew keeps the ledger's branch credit.
test_other_project_bound_sibling_is_ignored_by_the_coarse_gate() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case project-other fm/shared-project-other)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "project=$d/elsewhere-repo" "kind=ship" "mode=no-mistakes" "nm_run=01BOUNDRUN0000000000000032"
  fm_write_meta "$d/state/other.meta" "window=fm:fm-other" "worktree=$d/wt-other" \
    "project=$d/repo" "kind=ship" "mode=no-mistakes" "harness=claude"
  printf 'paused: waiting on the captain\n' > "$d/state/other.status"
  arm_idle_record "$d/state" other
  FM_FAKE_AXI_STATUS="$(run_running_id fm/other-crew 01NOBODYSRUN00000000000032)"
  FM_FAKE_RUNS_LIST="  running    fm/shared-project-other $(git -C "$d/wt-other" rev-parse --short=7 HEAD)  2026-09-04 10:05"
  out=$(run_crew_state "$d" other)
  assert_contains "$out" "validating (background run)" \
    "a bound record of another project must not withhold this branch's ledger credit"
  assert_contains "$out" "state: working" "the unbound crew keeps the branch's run"
  pass "a bound sibling of another project is ignored by the coarse gate"
}

# A bound sibling holds the branch-level route only through its recorded
# worktree: crew B bound its run on X and then detached its worktree
# (mid-rebase, a checkout by sha). When `axi status` answers B's run directly,
# unbound crew A on X is still refused it by id. When it answers an unbound run
# on another branch and A falls to the ledger, B's branch is one local git ref
# read of its worktree - detached, so B no longer withholds and A takes the
# branch credit. That is the documented limit of never issuing a CLI call per
# sibling on the per-poll path: the fake CLI must log no `--run` lookup.
test_detached_bound_sibling_owns_its_run_by_id_but_no_longer_holds_the_branch() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case detached-sibling fm/shared-detached)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes" "nm_run=01BOUNDRUN0000000000000008"
  fm_write_meta "$d/state/other.meta" "window=fm:fm-other" "worktree=$d/wt-other" \
    "kind=ship" "mode=no-mistakes" "harness=claude"
  printf 'paused: waiting on the captain\n' > "$d/state/other.status"
  arm_idle_record "$d/state" other
  git -C "$d/wt-owner" checkout -q --detach HEAD
  [ -z "$(git -C "$d/wt-owner" symbolic-ref --quiet --short HEAD 2>/dev/null)" ] \
    || fail "fixture broke - the bound sibling's worktree is still on a branch"
  FM_FAKE_RUNS_LIST="  running    fm/shared-detached $(git -C "$d/wt-other" rev-parse --short=7 HEAD)  2026-09-04 10:05"

  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-detached 01BOUNDRUN0000000000000008)"
  out=$(run_crew_state "$d" other)
  assert_not_contains "$out" "state: working" \
    "a same-branch run bound by a detached sibling must not be credited to the unbound crew"
  assert_contains "$out" "state: paused" "the unbound crew falls to its own declared wait"

  FM_FAKE_AXI_STATUS="$(run_running_id fm/other-crew 01NOBODYSRUN00000000000013)"
  FM_FAKE_AXI_STATUS_RUN="$(run_running_id fm/shared-detached 01BOUNDRUN0000000000000008)"
  FM_FAKE_NM_CALL_LOG="$d/nm-calls.log"
  out=$(run_crew_state "$d" other)
  assert_contains "$out" "validating (background run)" \
    "a detached sibling's worktree no longer holds the branch, so the ledger's branch credit is taken (documented limit)"
  if [ -f "$FM_FAKE_NM_CALL_LOG" ] && grep -q -- '--run' "$FM_FAKE_NM_CALL_LOG"; then
    fail "the sibling's run was resolved through a no-mistakes CLI call instead of its worktree's git ref"
  fi
  pass "a detached bound sibling keeps its run by id but withholds nothing through its worktree, with no CLI call per sibling"
}

# A terminal run TOON named by id with an explicit head, as `axi status --run
# <id>` answers for a run that has already ended.
run_terminal_id() {  # <branch> <run-id> <head> <outcome>
  cat <<EOF
run:
  id: "$2"
  branch: $1
  status: completed
  head: "$3"
  pr: ""
  findings: none
outcome: $4
EOF
}

arm_busy_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
}

# A bound crew is never credited a ledger row that is not its own run. Crews A
# and B are both bound on X, both worktrees at h2. A's own run failed at the
# earlier head h1 and A kept working; B's run is running at h2 and is the
# repo's current run, so `axi status` answers B and A refetches its own run by
# id. The head rule rejects A's run (h1 is a strict ancestor of h2), and the
# ledger's newest row for X is B's running row at h2: before the fix that row
# credited A while A's own failed TOON was parsed as authoritative, reporting a
# busy crew as failed on evidence that belongs to B.
test_bound_crew_with_a_stale_own_run_is_not_credited_a_siblings_current_row() {
  reset_fakes
  local d h1 h2 out
  d=$(make_shared_branch_case stale-own-run fm/shared-stale)
  h1=$(git -C "$d/wt-owner" rev-parse HEAD)
  git -C "$d/wt-owner" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'A kept working'
  h2=$(git -C "$d/wt-owner" rev-parse HEAD)
  [ "$(git -C "$d/wt-other" rev-parse HEAD)" = "$h2" ] || fail "fixture broke - the shared branch did not advance both worktrees"
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes" "harness=claude" "nm_run=01STALEOWNRUN0000000000001"
  fm_write_meta "$d/state/other.meta" "window=fm:fm-other" "worktree=$d/wt-other" \
    "kind=ship" "mode=no-mistakes" "harness=claude" "nm_run=01SIBLINGRUN00000000000021"
  FM_FAKE_BUSY=1
  arm_busy_record "$d/state" owner
  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-stale 01SIBLINGRUN00000000000021)"
  FM_FAKE_AXI_STATUS_RUN="$(run_terminal_id fm/shared-stale 01STALEOWNRUN0000000000001 "$h1" failed)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/shared-stale $(git -C "$d/wt-owner" rev-parse --short=7 "$h2")  2026-09-04 11:00
  failed     fm/shared-stale $(git -C "$d/wt-owner" rev-parse --short=7 "$h1")  2026-09-04 10:00
EOF
)"
  out=$(run_crew_state "$d" owner)
  assert_not_contains "$out" "state: failed" \
    "a bound crew's stale own run must not be reported as current on a sibling's ledger row"
  assert_not_contains "$out" "run failed" "the stale own run's TOON must not be parsed as authoritative"
  assert_not_contains "$out" "state: done" "the bound crew must not read done either"
  assert_contains "$out" "source: pane" "with no run of its own to credit, the bound crew falls to its pane"
  assert_contains "$out" "state: working" "the busy pane reports the crew working"

  out=$(run_crew_state "$d" other)
  assert_contains "$out" "state: working" "the sibling still reads its own current run"
  assert_contains "$out" "source: run-step" "the sibling reads it from the run step"
  pass "a bound crew with a stale own run is never credited its sibling's current ledger row"
}

# A run TOON named by id that is PARKED at a gate, as `axi status --run <id>`
# answers for a run that is still very much alive.
run_parked_id() {  # <branch> <run-id> <head>
  cat <<EOF
run:
  id: "$2"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "$3"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

# The head-UNCHANGED variant of a stale binding, and the one the head rule
# cannot catch. Crew T binds run A; A ends at head H; T starts run B at the SAME
# head H and never re-binds. `axi status` answers B, T refetches A by id, and A
# passes every gate - same branch, its own id, and a head equal to the
# worktree's - so before the decline T was reported `state: failed - run
# cancelled` while it was actively validating B, and teardown would then remove
# its worktree without aborting B. Declining a TERMINAL binding whose branch is
# still current returns T to the unbound path, where B - which no other task
# binds - is credited to it, so T reads its real current state.
test_stale_terminal_binding_at_the_same_head_falls_back_to_the_current_run() {
  reset_fakes
  local d out head
  d=$(make_shared_branch_case stale-same-head fm/shared-samehead)
  arm_shared_head "$d"
  head=$(git -C "$d/wt-owner" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes" "harness=claude" "nm_run=01STALESAMEHEAD0000000001"
  # The restarted run is the crew's OWN and nobody binds it - exactly the shape
  # a missed re-bind leaves behind.
  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-samehead 01RESTARTEDRUN000000000001)"
  FM_FAKE_AXI_STATUS_RUN="$(run_terminal_id fm/shared-samehead 01STALESAMEHEAD0000000001 "$head" cancelled)"
  out=$(run_crew_state "$d" owner)
  assert_not_contains "$out" "state: failed" \
    "a stale terminal binding at the same head must not report a validating crew as failed"
  assert_not_contains "$out" "run cancelled" \
    "the stale binding's terminal TOON must not be parsed as authoritative"
  assert_contains "$out" "state: working" "the crew reads the run it is actually validating"
  assert_contains "$out" "source: run-step" "and reads it from the run step"
  pass "a stale terminal binding at an unchanged head falls back to the crew's real current run"
}

# The decline is scoped to TERMINAL bindings only. A bound run that is still
# alive keeps precedence over whatever the repo happens to be reporting, so a
# crew parked at its own gate is never given up for a sibling's running row.
test_active_binding_keeps_precedence_over_the_repos_current_run() {
  reset_fakes
  local d out head
  d=$(make_shared_branch_case active-binding fm/shared-active)
  arm_shared_head "$d"
  head=$(git -C "$d/wt-owner" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes" "harness=claude" "nm_run=01ACTIVEOWNRUN00000000001"
  fm_write_meta "$d/state/other.meta" "window=fm:fm-other" "worktree=$d/wt-other" \
    "kind=ship" "mode=no-mistakes" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-active 01SIBLINGACTIVE000000000001)"
  FM_FAKE_AXI_STATUS_RUN="$(run_parked_id fm/shared-active 01ACTIVEOWNRUN00000000001 "$head")"
  out=$(run_crew_state "$d" owner)
  assert_contains "$out" "state: parked" \
    "an active binding must keep precedence over the repo's current run"
  assert_contains "$out" "source: run-step" "and is read from its own run step"
  assert_not_contains "$out" "validating (running)" \
    "the sibling's running row must not be substituted for the crew's own parked run"
  pass "an active binding keeps precedence over the repo's current run"
}

# The other way a bound crew reached the ledger on its binding alone: its own
# run, fetched by id, is on ANOTHER branch (started elsewhere before the
# worktree moved onto the shared branch). The ledger's same-head row on this
# branch is a sibling's and must not be credited to it.
test_bound_crew_whose_own_run_is_on_another_branch_takes_no_ledger_credit() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case own-run-elsewhere fm/shared-elsewhere)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes" "harness=claude" "nm_run=01ELSEWHERERUN000000000001"
  fm_write_meta "$d/state/other.meta" "window=fm:fm-other" "worktree=$d/wt-other" \
    "kind=ship" "mode=no-mistakes" "nm_run=01SIBLINGRUN00000000000022"
  printf 'paused: waiting on the captain\n' > "$d/state/owner.status"
  arm_idle_record "$d/state" owner
  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-elsewhere 01SIBLINGRUN00000000000022)"
  FM_FAKE_AXI_STATUS_RUN="$(run_running_id fm/earlier-branch 01ELSEWHERERUN000000000001)"
  FM_FAKE_RUNS_LIST="  running    fm/shared-elsewhere $(git -C "$d/wt-owner" rev-parse --short=7 HEAD)  2026-09-04 11:00"
  out=$(run_crew_state "$d" owner)
  assert_not_contains "$out" "validating (background run)" \
    "a bound crew whose own run is on another branch must not take this branch's ledger row"
  assert_not_contains "$out" "state: working" "the sibling's run must not read as this crew's work"
  assert_contains "$out" "state: paused" "the bound crew falls to its own declared wait"
  pass "a bound crew whose own run is on another branch is never credited the ledger's row here"
}

# With no binding anywhere on the branch, the ledger route keeps crediting
# co-branch crews exactly as before, so a home whose crews predate bindings
# regresses in no way.
test_unbound_cobranch_crews_keep_coarse_credit_with_no_binding_on_the_branch() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case coarse-legacy fm/shared-coarse-legacy)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes"
  fm_write_meta "$d/state/other.meta" "window=fm:fm-other" "worktree=$d/wt-other" \
    "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_running_id fm/other-crew 01NOBODYSRUN00000000000012)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-09-04 10:10
  running    fm/shared-coarse-legacy $(git -C "$d/wt-owner" rev-parse --short=7 HEAD)  2026-09-04 10:05
EOF
)"
  out=$(run_crew_state "$d" owner)
  assert_contains "$out" "validating (background run)" "an unbound crew still takes the ledger's branch credit"
  out=$(run_crew_state "$d" other)
  assert_contains "$out" "validating (background run)" \
    "with no binding on the branch the coarse route is unchanged for every co-branch crew"
  pass "no binding on the branch keeps the coarse ledger credit for co-branch crews"
}

# A same-branch run another task has bound is never this crew's, even when the
# ledger would otherwise let the head rule's rejection fall through to branch
# credit: the direct route requires ownership by id, and the coarse route is
# withheld because the claimant's worktree sits on this branch.
test_unbound_crew_never_takes_coarse_credit_for_a_same_branch_run_bound_elsewhere() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case coarse-claimed fm/shared-claimed)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes" "nm_run=01BOUNDRUN0000000000000006"
  fm_write_meta "$d/state/other.meta" "window=fm:fm-other" "worktree=$d/wt-other" \
    "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-claimed 01BOUNDRUN0000000000000006)"
  FM_FAKE_RUNS_LIST="  running    fm/shared-claimed $(git -C "$d/wt-owner" rev-parse --short=7 HEAD)  2026-09-04 10:05"
  out=$(run_crew_state "$d" other)
  assert_not_contains "$out" "state: working" \
    "a same-branch run bound by a sibling must not reach the unbound crew through the ledger either"
  pass "a bound sibling's same-branch run is withheld from an unbound crew on every route"
}

# bin/fm-fleet-snapshot.sh reads a task's record through a captured COPY
# (FM_CREW_STATE_META_OVERRIDE). The live record under state/ is then the same
# task, not a rival claimant: a crew that bound its run between the copy and the
# read must still be credited it.
test_captured_record_copy_does_not_make_the_live_record_a_rival_claimant() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case snapshot-self fm/shared-snapshot)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes" "nm_run=01BOUNDRUN0000000000000007"
  mkdir -p "$d/snapshot"
  fm_write_meta "$d/snapshot/owner.meta" "window=fm:fm-owner" "worktree=$d/wt-owner" \
    "kind=ship" "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-snapshot 01BOUNDRUN0000000000000007)"
  out=$(FM_CREW_STATE_META_OVERRIDE="$d/snapshot/owner.meta" run_crew_state "$d" owner)
  assert_contains "$out" "state: working" \
    "the crew's own live record must not be read as another task claiming its run"
  pass "a captured record copy never turns the task's own live record into a rival claimant"
}

test_direct_pr_crew_is_never_credited_a_run() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case mode-gate fm/shared-mode)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/shipper.meta" "window=fm:fm-shipper" "worktree=$d/wt-other" \
    "kind=ship" "mode=direct-PR" "harness=claude"
  printf 'paused: waiting on the captain\n' > "$d/state/shipper.status"
  arm_idle_record "$d/state" shipper
  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-mode 01MODERUN00000000000000001)"
  out=$(run_crew_state "$d" shipper)
  assert_not_contains "$out" "state: working" \
    "a direct-PR crew never drives a pipeline, so it is never credited a run"
  assert_contains "$out" "state: paused" "it falls to its own declared wait instead"
  pass "a direct-PR crew is never credited a pipeline run"
}

test_local_only_crew_is_never_credited_a_run() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case mode-gate-local fm/shared-local)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/localer.meta" "window=fm:fm-localer" "worktree=$d/wt-other" \
    "kind=ship" "mode=local-only"
  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-local 01MODERUN00000000000000002)"
  out=$(run_crew_state "$d" localer)
  assert_not_contains "$out" "state: working" \
    "a local-only crew never drives a pipeline, so it is never credited a run"
  pass "a local-only crew is never credited a pipeline run"
}

test_absent_mode_keeps_the_run_lookup() {
  reset_fakes
  local d out
  d=$(make_shared_branch_case mode-absent fm/shared-absent)
  arm_shared_head "$d"
  make_fakebin "$d" >/dev/null
  # A record predating mode=: the lookup must still run, so an existing home
  # does not lose run-step state the moment this gate lands.
  fm_write_meta "$d/state/legacy.meta" "window=fm:fm-legacy" "worktree=$d/wt-owner" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running_id fm/shared-absent 01MODERUN00000000000000003)"
  out=$(run_crew_state "$d" legacy)
  assert_contains "$out" "state: working" "an absent mode= keeps today's run lookup"
  pass "a record with no mode= keeps the run lookup"
}

test_active_run_is_authoritative
test_stale_needs_decision_superseded
test_stale_blocked_superseded
test_daemon_claim_over_live_run_reads_run_alive
test_socket_refusal_over_stale_fixing_run_reports_blocked
test_socket_refusal_over_terminal_run_reports_blocked
test_ordinary_blocked_over_live_run_keeps_plain_superseded
test_genuine_daemon_down_reports_blocked
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
test_coarse_socket_refusal_reports_blocked
test_cross_branch_attribution_picks_most_recent_row
test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status
test_other_branch_run_ignored
test_no_run_busy_pane
test_no_run_footer_text_alone_is_not_working
test_no_run_grok_uses_isolated_fallback
test_no_run_herdr_unknown_uses_backend_capture
test_no_run_herdr_cli_failure_reads_unreachable_not_gone
test_no_run_herdr_alive_with_failed_read_stays_live
test_no_run_herdr_husk_dead_still_reads_gone
test_no_run_herdr_idle_agent_status_outranked_by_record
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle
test_no_run_idle_pane_uses_log
test_no_run_idle_pane_uses_keyed_log
test_no_run_idle_pane_paused
test_no_run_idle_pane_custom_paused_verb
test_no_run_idle_secondmate_resolved_event_not_state
test_dead_window_ignores_stale_status_log
test_no_run_tmux_unreadable_reads_unreachable_not_gone
test_dead_window_still_reports_terminal_run_step
test_dead_window_still_reports_active_run_step
test_no_timeout_uses_perl_bound
test_scout_skips_run_lookup
test_torn_down_worktree
test_remote_alive_with_log_uses_status_log
test_remote_alive_idle_is_healthy_not_gone
test_remote_unreachable_is_unknown_remote_not_dead
test_remote_dead_reports_remote_verdict
test_missing_meta
test_provably_working_via_runs_list_fallback
test_not_provably_working_when_stopped
test_usage_error
test_historical_same_branch_rewritten_head_not_current
test_active_run_descendant_fix_head_remains_current
test_local_advanced_past_run_head_invalidates
test_pipeline_owned_active_run_beats_superseded_failed_row
test_failed_run_with_no_later_run_still_surfaces
test_coarse_unresolvable_active_row_never_falls_to_older_row
test_coarse_mismatched_anchor_falls_to_pane_not_older_row
test_non_pipeline_owned_unresolvable_head_not_attributed
test_pipeline_owned_terminal_run_not_exempt
test_missing_run_head_falls_back_to_current_state
test_active_fix_round_unfetched_pipeline_head_reports_current
test_unanchored_unfetched_active_row_does_not_match
test_unresolved_terminal_row_is_history_not_current
test_runs_list_continuation_found_when_axi_answers_other_branch
test_bound_owner_keeps_the_run_its_neighbour_loses_it
test_unbound_neighbour_without_a_status_line_is_not_working
test_no_bindings_on_the_branch_preserves_legacy_behaviour
test_bound_crew_ignores_a_run_that_is_not_its_own
test_bound_crew_finds_its_own_run_by_id_when_axi_answers_another_branch
test_unbound_cobranch_crew_is_withheld_coarse_credit_while_a_sibling_is_bound
test_same_project_bound_sibling_withholds_coarse_credit
test_other_project_bound_sibling_is_ignored_by_the_coarse_gate
test_detached_bound_sibling_owns_its_run_by_id_but_no_longer_holds_the_branch
test_bound_crew_with_a_stale_own_run_is_not_credited_a_siblings_current_row
test_stale_terminal_binding_at_the_same_head_falls_back_to_the_current_run
test_active_binding_keeps_precedence_over_the_repos_current_run
test_bound_crew_whose_own_run_is_on_another_branch_takes_no_ledger_credit
test_unbound_cobranch_crews_keep_coarse_credit_with_no_binding_on_the_branch
test_unbound_crew_never_takes_coarse_credit_for_a_same_branch_run_bound_elsewhere
test_captured_record_copy_does_not_make_the_live_record_a_rival_claimant
test_direct_pr_crew_is_never_credited_a_run
test_local_only_crew_is_never_credited_a_run
test_absent_mode_keeps_the_run_lookup

echo "all fm-crew-state tests passed"
