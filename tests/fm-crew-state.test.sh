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
#   (d2) terminal failed run whose only failure is an orphaned ci monitor
#       after checks read green                                   -> done
#   (e) cross-branch attribution: this branch's own run found via list lookup
#   (e2) multiple runs: creation order preserves newer failures, replacement
#        gates retain their run identity, and competing live runs read unknown
#   (e3) an older live sibling with an unfetched head cannot hide a newer failure
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
#   (l) coarse runs-ledger fallback: a terminal failed record with the daemon
#       provably down (explicit daemon-status probe fails) reads unknown -
#       "unverified", never failed; the same record with the daemon up stays
#       failed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state)
fm_git_identity fmtest fmtest@example.invalid

# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live crew worktree.
# Stamp origin/main at the current HEAD so a later ship done: is not refused
# solely for being a fixture with no remote-tracking refs; tests that need an
# unpreserved named head point those refs at a different commit.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  git -C "$dir" update-ref refs/remotes/origin/main "$(git -C "$dir" rev-parse HEAD)"
  # Real worktree HEAD for run head-binding (fixtures read FM_FAKE_RUN_HEAD).
  FM_FAKE_RUN_HEAD=$(git -C "$dir" rev-parse HEAD)
  export FM_FAKE_RUN_HEAD
}

# A fakebin with a fake `no-mistakes` (serves the env-driven run output) and a
# fake `tmux` (serves a busy or idle pane). The fake no-mistakes mirrors the real
# command surface the helper uses: `axi` (the identity overview), `axi status`,
# and `axi status --run <id>` (the
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
    if [ "$#" = 0 ]; then
      printf '%s\n' "${FM_FAKE_AXI_HOME:-${FM_FAKE_AXI_STATUS:-}}"
      exit "${FM_FAKE_AXI_HOME_ERROR:-0}"
    fi
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then
          printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
          exit "${FM_FAKE_AXI_STATUS_RUN_ERROR:-0}"
        else
          printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
          exit "${FM_FAKE_AXI_STATUS_ERROR:-0}"
        fi ;;
      logs)
        shift
        # The real CLI prints only the last 40 log lines ("lines: 40 of N
        # total (tail)", verified against v1.79.0) unless --full asks for the
        # whole log, so a marker older than that is invisible to a plain read.
        full=0
        for arg in "$@"; do
          [ "$arg" = --full ] && full=1
        done
        if [ "$full" = 1 ]; then
          printf '%s\n' "${FM_FAKE_CI_LOGS:-}"
        else
          printf '%s\n' "${FM_FAKE_CI_LOGS:-}" | tail -40
        fi ;;
    esac
    ;;
  runs)
    printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
  daemon)
    # FM_FAKE_DAEMON_DOWN: the explicit down-probe fails, as the real
    # `no-mistakes daemon status` does when the daemon is not running.
    # FM_FAKE_DAEMON_TIMEOUT: the probe does not answer at all, which is what
    # the bounded call reports as 124 when `timeout` kills a slow daemon status.
    [ -z "${FM_FAKE_DAEMON_PROBE_LOG:-}" ] || printf 'probe\n' >> "$FM_FAKE_DAEMON_PROBE_LOG"
    [ "${FM_FAKE_DAEMON_TIMEOUT:-0}" = 1 ] && exit 124
    [ "${FM_FAKE_DAEMON_DOWN:-0}" = 1 ] && exit 1
    printf '%s\n' 'daemon running (pid 4242)'
    exit 0 ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "api graphql")
    [ -z "${FM_FAKE_PR_READ_LOG:-}" ] || printf 'gh\n' >> "$FM_FAKE_PR_READ_LOG"
    number=1
    for arg in "$@"; do
      case "$arg" in
        number=*) number=${arg#number=} ;;
      esac
    done
    case "$number" in *[!0-9]*|'') number=1 ;; esac
    state=${FM_FAKE_PR_STATE:-MERGED}
    merged=${FM_FAKE_PR_MERGED:-true}
    eval "state=\${FM_FAKE_PR_${number}_STATE:-\$state}"
    eval "merged=\${FM_FAKE_PR_${number}_MERGED:-\$merged}"
    [ "${FM_FAKE_PR_READ_FAIL:-0}" = 1 ] && exit 1
    printf 'state=%s\nmerged=%s\n' "$state" "$merged"
    exit 0 ;;
esac
exit 1
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pr view")
    [ -z "${FM_FAKE_PR_READ_LOG:-}" ] || printf 'gh-axi\n' >> "$FM_FAKE_PR_READ_LOG"
    [ "${FM_FAKE_PR_READ_FAIL:-0}" = 1 ] && exit 1
    printf 'pull_request:\n  number: %s\n  state: %s\n' "${3:-1}" "${FM_FAKE_PR_STATE_AXI:-merged}"
    exit 0 ;;
esac
exit 1
SH
  cat > "$fb/glab" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "mr view")
    [ -z "${FM_FAKE_GLAB_READ_LOG:-}" ] || printf '%s|%s\n' "${GITLAB_HOST:-}" "$*" >> "$FM_FAKE_GLAB_READ_LOG"
    [ "${FM_FAKE_GLAB_READ_FAIL:-0}" = 1 ] && exit 1
    printf '{"state":"%s"}\n' "${FM_FAKE_GLAB_STATE:-merged}"
    exit 0 ;;
esac
exit 1
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
      process-info)
        # The process-level view a registration is verified against (#4115):
        # `agent` puts a live claude in the foreground, `shell` a bare zsh whose
        # pid is the test script itself (a real, long-lived process with no
        # harness descendant, so the adapter's real process-table walk finds
        # it), and anything else answers nothing (unreadable).
        pane=""; args=("$@"); for ((i=0; i<${#args[@]}; i++)); do [ "${args[$i]}" = --pane ] && pane=${args[$((i+1))]:-}; done
        case "${FM_FAKE_HERDR_PROCESS:-agent}" in
          agent) printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":424242,"foreground_processes":[{"pid":424242,"name":"claude","argv0":"claude"}]}}}\n' "$pane" "${FM_FAKE_HERDR_SHELL_PID:-$PPID}" ;;
          shell) printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}\n' "$pane" "${FM_FAKE_HERDR_SHELL_PID:-$PPID}" "${FM_FAKE_HERDR_SHELL_PID:-$PPID}" "${FM_FAKE_HERDR_SHELL_PID:-$PPID}" ;;
        esac
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
  chmod +x "$fb/no-mistakes" "$fb/gh" "$fb/gh-axi" "$fb/glab" "$fb/tmux" "$fb/herdr"
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
  NM_HOME="$TMP_ROOT/no-mistakes-unused"
  export NM_HOME
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_AXI_STATUS_ERROR=0
  FM_FAKE_AXI_HOME=""
  FM_FAKE_AXI_HOME_ERROR=0
  FM_FAKE_AXI_STATUS_RUN_ERROR=0
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
  FM_FAKE_HERDR_PROCESS=agent
  FM_FAKE_HERDR_SHELL_PID=$$
  FM_FAKE_CI_LOGS=""
  FM_FAKE_DAEMON_DOWN=0
  FM_FAKE_DAEMON_TIMEOUT=0
  FM_FAKE_DAEMON_PROBE_LOG=
  FM_FAKE_PR_STATE=MERGED
  FM_FAKE_PR_MERGED=true
  FM_FAKE_PR_READ_FAIL=0
  FM_FAKE_PR_READ_LOG=
  FM_FAKE_PR_STATE_AXI=merged
  FM_FAKE_GLAB_STATE=merged
  FM_FAKE_GLAB_READ_FAIL=0
  FM_FAKE_GLAB_READ_LOG=
  unset FM_FAKE_PR_47_STATE FM_FAKE_PR_47_MERGED FM_FAKE_PR_48_STATE FM_FAKE_PR_48_MERGED
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_BUSY FM_FAKE_BUSY_TEXT FM_FAKE_TMUX_MISSING FM_FAKE_TMUX_UNREADABLE
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_READ_FAIL FM_FAKE_HERDR_HUSK FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_HERDR_PROCESS FM_FAKE_HERDR_SHELL_PID FM_FAKE_CI_LOGS
  export FM_FAKE_DAEMON_DOWN FM_FAKE_DAEMON_TIMEOUT FM_FAKE_DAEMON_PROBE_LOG FM_FAKE_AXI_HOME
  export FM_FAKE_AXI_HOME_ERROR FM_FAKE_AXI_STATUS_RUN_ERROR FM_FAKE_AXI_STATUS_ERROR
  export FM_FAKE_PR_STATE FM_FAKE_PR_MERGED FM_FAKE_PR_READ_FAIL FM_FAKE_PR_READ_LOG FM_FAKE_PR_STATE_AXI
  export FM_FAKE_GLAB_STATE FM_FAKE_GLAB_READ_FAIL FM_FAKE_GLAB_READ_LOG
  export FM_FAKE_PR_47_STATE FM_FAKE_PR_47_MERGED FM_FAKE_PR_48_STATE FM_FAKE_PR_48_MERGED
}

seed_retired_pr_receipt() {  # <state> <id> <url>
  local state=$1 id=$2 url=$3 template provider host path number
  template="$ROOT/bin/fm-pr-poll.sh"
  fm_pr_url_parse "$url" || fail "retirement fixture URL was invalid"
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  fm_pr_poll_prepare "$state" "$id" "$provider" "$url" "$host" "$path" "$number" "$template" \
    || fail "could not prepare retirement fixture"
  fm_pr_poll_publish_prepared || fail "could not publish retirement fixture"
  fm_pr_poll_snapshot_capture "$state" "$id" "$template" || fail "could not snapshot retirement fixture"
  fm_pr_poll_retirement_publish "$state" "$id" "$template" merged \
    || fail "could not publish retirement receipt"
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

# A gate owed the CREWMATE's own answer: every finding's `action` column is
# auto-fix. The free-text `description` column is where this repository's own
# review output routinely quotes finding actions, so one row spells the token out
# the way an enumeration does - surrounded by commas, in the exact shape a
# substring or unanchored-regex derivation would accept - and the branch name
# carries it too. Both are the counterexample: the ONLY thing that may mint the
# human-decision component is the `action` column read by position.
run_parked_crewmate_gate_with_ask_user_prose() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fix_review
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,the action field is one of no-op, auto-fix, ask-user, so pick one
    r2,warning,b.go,,auto-fix,ignored error
gate: review
EOF
}

# The same gate with the findings table's columns in a different order, so the
# derivation is proven to read the column INDEX out of the header rather than
# assuming action is the fifth field. Only the last row is owed a human.
run_parked_reordered_columns() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]{severity,action,id,file,line,description}:
    warning,auto-fix,r1,a.go,,ignored error
    error,ask-user,r2,b.go,,changes product behavior
gate: review
EOF
}

# The same crewmate-owed gate with `description` placed BEFORE `action` in the
# header. Every row's real action column is auto-fix, but one description spells
# the token out surrounded by commas at exactly the comma offset the `action`
# index lands on, so a derivation that reads the index from the header and then
# walks raw commas to it accepts free text as the action. The table's shape is
# not provably safe here, so the only correct answer is to keep the ladder.
run_parked_free_text_before_action() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fix_review
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,description,action}:
    r1,warning,a.go,12,the action field is one of auto-fix, ask-user,auto-fix
gate: review
EOF
}

# The same crewmate-owed gate preceded by an UNBRACED `findings[N]:` block from
# an earlier, already-resolved round. The braced header that follows is the live
# gate's table and is the one the column index is read from, so the rows walked
# must be that table's rows too. An earlier block carrying `ask-user` at the very
# comma offset the braced header's `action` index resolves to is the counter-
# example: a row scan that anchors on the looser unbraced pattern reads the wrong
# block's rows at the right block's index, and mints the component for a gate
# whose every action is auto-fix.
run_parked_unbraced_findings_precursor() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fix_review
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]:
    prior-1,warning,a.go,ask-user,an earlier already-resolved block
    prior-2,info,b.go,ask-user,another earlier row
  findings[1]{id,severity,file,action,description}:
    r1,warning,a.go,auto-fix,the live gate is owed to the crewmate
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

run_passed_with_override() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed-with-override
ci_override_reason: "live checks not all passed: Lint (fail)"
EOF
}

run_passed_with_skips() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed-with-skips
automatic_skips: "publication skipped: no-mistakes.yaml pr.enabled=false"
EOF
}

run_passed_with_pr() {  # <branch> <pr-url>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "$2"
  findings: none
outcome: passed
EOF
}

run_passed_no_pr() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
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

# The 2026-09-05 jr-voice orphaned-CI-monitor shape: every substantive step
# completed, only ci failed (after the shared daemon restarted under its
# merge poll), and GitHub read the PR green and mergeable.
run_failed_ci_orphan() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: failed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/203"
  findings: none
outcome: failed
steps[9]{step,status,findings,duration_ms}:
  intent,completed,0,0
  rebase,completed,0,0
  review,completed,0,0
  test,completed,0,0
  document,completed,0,0
  lint,completed,0,0
  push,completed,0,0
  pr,completed,0,0
  ci,failed,0,76127890
EOF
}

# Same shape but with no outcome line: only top-level status reads failed.
run_failed_ci_orphan_status_only() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: failed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/203"
  findings: none
steps[9]{step,status,findings,duration_ms}:
  intent,completed,0,0
  rebase,completed,0,0
  review,completed,0,0
  test,completed,0,0
  document,completed,0,0
  lint,completed,0,0
  push,completed,0,0
  pr,completed,0,0
  ci,failed,0,76127890
EOF
}

# A second failed step (lint) disqualifies the orphaned-monitor reclassification.
run_failed_ci_orphan_second_failure() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: failed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/203"
  findings: none
steps[9]{step,status,findings,duration_ms}:
  intent,completed,0,0
  rebase,completed,0,0
  review,completed,0,0
  test,completed,0,0
  document,completed,0,0
  lint,failed,0,0
  push,completed,0,0
  pr,completed,0,0
  ci,failed,0,76127890
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

# The socket-down override is evidence about the log's CURRENT tip, not a latch:
# once the crew appends any later event the attributed run is the better witness.
test_socket_refusal_override_expires_when_the_crew_moves_on() {
  reset_fakes
  local d out
  d=$(new_case daemon-socket-refused-superseded)
  make_repo_on_branch "$d/wt" fm/feat-ds
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ds.meta" "window=fm:fm-feat-ds" "worktree=$d/wt" "kind=ship"
  printf 'blocked: no-mistakes daemon socket is missing\n' > "$d/state/feat-ds.status"
  FM_FAKE_AXI_STATUS="$(run_fixing_active_recent fm/feat-ds)"
  out=$(run_crew_state "$d" feat-ds)
  assert_contains "$out" "state: blocked" "socket-down as the latest event still outranks a live run"
  assert_contains "$out" "source: status-log" "the override remains status-log evidence"
  assert_contains "$out" "daemon socket down despite attributed run record" "the override names its reason"

  printf 'working: reattached and continuing\n' >> "$d/state/feat-ds.status"
  out=$(run_crew_state "$d" feat-ds)
  assert_contains "$out" "state: working" "a later working event hands the reading back to the live run"
  assert_contains "$out" "source: run-step" "the superseded override no longer emits status-log state"
  assert_not_contains "$out" "daemon socket down despite attributed run record" \
    "a stale socket-down blocker cannot override a live run forever"

  # The later event does not have to be one the decision fold accepts. A blocked
  # line on a reserved key whose note does not speak that namespace is folded as
  # ordinary status, so the socket-down blocker stays the reconciled declaration
  # while the tip of the log has moved on; the override reads the tip, not the
  # declaration, so the stale daemon evidence stays retired.
  printf 'blocked: no-mistakes daemon socket is missing\nblocked [key=pending-reply-t3]: still waiting on the answer\n' \
    > "$d/state/feat-ds.status"
  out=$(run_crew_state "$d" feat-ds)
  assert_contains "$out" "state: working" "a later unfolded blocked event also hands the reading back to the run"
  assert_contains "$out" "source: run-step" "the retired override emits no status-log state"
  assert_not_contains "$out" "daemon socket down despite attributed run record" \
    "an unrelated later blocker cannot republish stale socket-down evidence"
  pass "socket-down evidence outranks a live run only while it is the log's latest event"
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

# Which HUMAN owes a parked gate its answer is the distinction the watcher's
# wedge deferral rests on, so the component that carries it must come from the
# findings table's `action` column and from nothing else. Both directions, plus
# the counterexample a text match would have accepted.
test_parked_human_decision_comes_from_the_action_column() {
  local d out
  reset_fakes
  d=$(new_case parked-ask-user-action-column)
  make_repo_on_branch "$d/wt" fm/feat-au
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-au.meta" "window=fm:fm-feat-au" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-au.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-au)"
  out=$(run_crew_state "$d" feat-au)
  assert_contains "$out" "state: parked" "an ask-user row still reports parked"
  assert_contains "$out" " · ask-user: authority decision" \
    "an action column of ask-user mints the human-decision component"

  # The counterexample. Nothing here is owed a human: every action column is
  # auto-fix. A description enumerating the action values, and a branch named
  # after the same token, must not mint the component - a crewmate that goes
  # quiet before answering its own gate has to keep the wedge ladder.
  reset_fakes
  d=$(new_case parked-ask-user-prose-only)
  make_repo_on_branch "$d/wt" fm/ask-user-authority-fix
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ap.meta" "window=fm:fm-feat-ap" "worktree=$d/wt" "kind=ship"
  printf 'working: validation under way\n' > "$d/state/feat-ap.status"
  FM_FAKE_AXI_STATUS="$(run_parked_crewmate_gate_with_ask_user_prose fm/ask-user-authority-fix)"
  # Guard the counterexample against going vacuous: the payload this gate is read
  # from must really contain the token in a position a substring or unanchored
  # regex would accept, or the case below proves nothing.
  assert_contains "$FM_FAKE_AXI_STATUS" ", ask-user," \
    "the counterexample payload must carry the token where a naive match accepts it"
  assert_contains "$FM_FAKE_AXI_STATUS" "branch: fm/ask-user-authority-fix" \
    "the counterexample payload must also carry the token in its branch name"
  out=$(run_crew_state "$d" feat-ap)
  assert_contains "$out" "state: parked" "a crewmate-owed gate still reports parked"
  assert_not_contains "$out" " · ask-user: authority decision" \
    "free text and a branch name must not mint the human-decision component"

  # Column order is read from the header, not assumed.
  reset_fakes
  d=$(new_case parked-ask-user-reordered)
  make_repo_on_branch "$d/wt" fm/feat-ar
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ar.meta" "window=fm:fm-feat-ar" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-ar.status"
  FM_FAKE_AXI_STATUS="$(run_parked_reordered_columns fm/feat-ar)"
  out=$(run_crew_state "$d" feat-ar)
  assert_contains "$out" " · ask-user: authority decision" \
    "the action column is located by header index, not by fixed position"

  # A header index alone is not enough, because the row is split on raw commas.
  # With `description` ahead of `action` the comma walk lands inside free text,
  # so a gate whose every action is auto-fix would mint the component. The table
  # is not provably safe to walk, so the derivation must refuse and the crewmate
  # must keep the wedge ladder.
  reset_fakes
  d=$(new_case parked-free-text-before-action)
  make_repo_on_branch "$d/wt" fm/feat-af
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-af.meta" "window=fm:fm-feat-af" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-af.status"
  FM_FAKE_AXI_STATUS="$(run_parked_free_text_before_action fm/feat-af)"
  # Non-vacuity: the payload must really carry the token at the comma offset the
  # `action` index resolves to, or the case below proves nothing.
  assert_contains "$FM_FAKE_AXI_STATUS" "findings[1]{id,severity,file,line,description,action}:" \
    "the fixture must really place free text before the action column"
  assert_contains "$FM_FAKE_AXI_STATUS" ", ask-user," \
    "the fixture description must carry the token where the comma walk would accept it"
  out=$(run_crew_state "$d" feat-af)
  assert_contains "$out" "state: parked" "an unsafe findings header still reports parked"
  assert_not_contains "$out" " · ask-user: authority decision" \
    "a findings header that puts free text before action must not mint the human-decision component"

  # The header and the rows must come from the SAME block. An earlier unbraced
  # `findings[N]:` block ahead of the live gate's braced table would otherwise
  # supply the rows while the braced header supplies the count and the `action`
  # index, so the walk reads the wrong rows at the right index. Here that earlier
  # block carries ask-user at exactly that offset while the live gate's only row
  # is auto-fix: the crewmate owes this gate its own answer and must keep the
  # wedge ladder.
  reset_fakes
  d=$(new_case parked-unbraced-findings-precursor)
  make_repo_on_branch "$d/wt" fm/feat-ub
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ub.meta" "window=fm:fm-feat-ub" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-ub.status"
  FM_FAKE_AXI_STATUS="$(run_parked_unbraced_findings_precursor fm/feat-ub)"
  # Non-vacuity: the payload must really carry an unbraced findings block ahead
  # of the braced one, with the token at the offset the walk would land on.
  assert_contains "$FM_FAKE_AXI_STATUS" "findings[2]:" \
    "the fixture must really place an unbraced findings block before the gate's table"
  assert_contains "$FM_FAKE_AXI_STATUS" ",ask-user," \
    "the earlier block must carry the token where the wrong-block walk would accept it"
  out=$(run_crew_state "$d" feat-ub)
  assert_contains "$out" "state: parked" "an unbraced findings precursor still reports parked"
  assert_not_contains "$out" " · ask-user: authority decision" \
    "rows from an earlier unbraced findings block must not mint the human-decision component"
  pass "the parked human-decision component is derived from the findings table's action column"
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
# but the ci step's log shows CI is actually green and only waiting on
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

# The monitor logs a checks state only when it changes, and a base-branch
# advance re-arms only its idle timeout, so a green PR on a busy base ends its
# ci log with re-arm lines (the 2026-09-22 PR #5317 shape: green, then main
# advanced while it waited for merge). The green marker before them is current.
test_ci_monitoring_green_then_rearm_stays_green() {
  reset_fakes
  local d; d=$(new_case ci-green-then-rearm)
  make_repo_on_branch "$d/wt" fm/feat-cirearm
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirearm.meta" "window=fm:fm-feat-cirearm" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirearm)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
base branch advanced (bbbbbbb..ccccccc), re-arming CI monitor timeout
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirearm)
  assert_contains "$out" "state: done" "a base-advance re-arm after green keeps the PR green"
  assert_contains "$out" "source: run-step" "re-armed green monitoring stays run-step sourced"
  assert_contains "$out" "checks green: PR ready for review" "re-armed green monitoring reads held for merge"
  assert_contains "$out" "https://github.com/o/r/pull/2" "the held-for-merge reading names the run's PR"
  assert_not_contains "$out" "state: working" "a re-arm line must not read as checks not ready"
  pass "base-advance re-arm after green stays checks green"
}

# The same green-then-re-arm shape, but monitored long enough that the base
# advanced past the CLI's 40-line log tail: `axi logs` without --full would
# answer with re-arm lines only, hiding the green marker entirely, and the
# green PR would read as still working for as long as main kept moving.
test_ci_monitoring_green_before_log_tail_stays_green() {
  reset_fakes
  local d; d=$(new_case ci-green-beyond-tail)
  make_repo_on_branch "$d/wt" fm/feat-citail
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-citail.meta" "window=fm:fm-feat-citail" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-citail)"
  FM_FAKE_CI_LOGS=$({
    printf 'monitoring CI for PR #2 (timeout: 4h0m0s)...\n'
    printf 'all CI checks passed - still monitoring until merged or closed\n'
    for i in $(seq 1 60); do
      printf 'base branch advanced (%07d..%07d), re-arming CI monitor timeout\n' "$i" "$((i + 1))"
    done
  })
  local out; out=$(run_crew_state "$d" feat-citail)
  assert_contains "$out" "state: done" "a green marker older than the log tail still reads green"
  assert_contains "$out" "source: run-step" "the full-log green reading stays run-step sourced"
  assert_contains "$out" "checks green: PR ready for review" "the full-log reading is held for merge"
  assert_contains "$out" "https://github.com/o/r/pull/2" "the full-log reading names the run's PR"
  assert_not_contains "$out" "state: working" "a truncated ci log must not hide a green PR"
  pass "a green marker before the ci log tail still surfaces done"
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
# not be masked: the MOST RECENT marker in the ci log wins.
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
  assert_contains "$out" "run passed: PR merged" "passed run reports merged only after the PR record says merged"
  assert_not_contains "$out" "merged/closed" "passed merged PR must not keep the old ambiguous label"
  pass "terminal passed run is authoritative"
}

test_terminal_passed_with_override() {
  reset_fakes
  local d; d=$(new_case passed-with-override)
  make_repo_on_branch "$d/wt" fm/feat-override
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-override.meta" "window=fm:fm-feat-override" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_with_override fm/feat-override)"
  local out; out=$(run_crew_state "$d" feat-override)
  assert_contains "$out" "state: done" "passed-with-override run -> done, not unknown"
  assert_contains "$out" "source: run-step" "passed-with-override -> run-step source"
  assert_contains "$out" "run passed: PR merged" "passed-with-override run reports merged only after the PR record says merged"
  assert_not_contains "$out" "state: unknown" "passed-with-override must not fall through to unknown"
  assert_not_contains "$out" "outcome: passed-with-override" "passed-with-override must not surface as a raw unmapped outcome detail"
  pass "terminal passed-with-override run reads done like a clean pass"
}

test_terminal_passed_with_skips() {
  reset_fakes
  local d; d=$(new_case passed-with-skips)
  make_repo_on_branch "$d/wt" fm/feat-skips
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-skips.meta" "window=fm:fm-feat-skips" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_with_skips fm/feat-skips)"
  local out; out=$(run_crew_state "$d" feat-skips)
  assert_contains "$out" "state: done" "passed-with-skips run -> done, not unknown"
  assert_contains "$out" "source: run-step" "passed-with-skips -> run-step source"
  assert_contains "$out" "run passed: PR merged" "passed-with-skips run reports merged only after the PR record says merged"
  assert_contains "$out" "publication/CI verification skipped" "passed-with-skips keeps the skip visible, unlike a clean pass"
  assert_not_contains "$out" "state: unknown" "passed-with-skips must not fall through to unknown"
  assert_not_contains "$out" "outcome: passed-with-skips" "passed-with-skips must not surface as a raw unmapped outcome detail"
  pass "terminal passed-with-skips run reads done with the skip kept visible"
}

test_terminal_passed_uses_matching_retirement_receipt_without_forge() {
  reset_fakes
  local d url read_log out
  d=$(new_case passed-receipt)
  url=https://github.com/o/r/pull/1
  make_repo_on_branch "$d/wt" fm/feat-dreceipt
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dreceipt.meta" "window=fm:fm-feat-dreceipt" \
    "worktree=$d/wt" "kind=ship" "pr=$url"
  seed_retired_pr_receipt "$d/state" feat-dreceipt "$url"
  read_log="$d/pr-read.log"
  : > "$read_log"
  FM_FAKE_PR_READ_LOG=$read_log
  FM_FAKE_PR_READ_FAIL=1
  FM_FAKE_AXI_STATUS="$(run_passed_no_pr fm/feat-dreceipt)"
  out=$(run_crew_state "$d" feat-dreceipt)
  assert_contains "$out" "state: done" "passed run with retired PR receipt -> done"
  assert_contains "$out" "run passed: PR merged" "matching retirement receipt is local merged evidence"
  [ ! -s "$read_log" ] || fail "matching retirement receipt still attempted a forge read"
  pass "terminal passed run uses matching retirement receipt without forge"
}

test_terminal_passed_no_forge_switch_skips_read_but_keeps_receipt() {
  reset_fakes
  local d url read_log out
  d=$(new_case passed-no-forge-switch)
  url=https://github.com/o/r/pull/1
  make_repo_on_branch "$d/wt" fm/feat-dnoforge
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dnoforge.meta" "window=fm:fm-feat-dnoforge" \
    "worktree=$d/wt" "kind=ship" "pr=$url"
  read_log="$d/pr-read.log"
  : > "$read_log"
  FM_FAKE_PR_READ_LOG=$read_log
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dnoforge "$url")"

  out=$(FM_CREW_STATE_NO_FORGE=1 run_crew_state "$d" feat-dnoforge)
  assert_contains "$out" "run passed: PR state unknown (forge read skipped)" "no-forge mode reports skipped read"
  assert_not_contains "$out" "PR merged" "no-forge mode without a receipt must not report merged"
  [ ! -s "$read_log" ] || fail "no-forge mode invoked a forge read"

  seed_retired_pr_receipt "$d/state" feat-dnoforge "$url"
  out=$(FM_CREW_STATE_NO_FORGE=1 run_crew_state "$d" feat-dnoforge)
  assert_contains "$out" "run passed: PR merged" "no-forge mode still trusts a matching retirement receipt"
  [ ! -s "$read_log" ] || fail "no-forge mode with a receipt invoked a forge read"
  pass "terminal passed no-forge mode preserves local receipt evidence"
}

test_terminal_passed_with_open_pr_does_not_claim_merged() {
  reset_fakes
  local d; d=$(new_case passed-open-pr)
  make_repo_on_branch "$d/wt" fm/feat-dopen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dopen.meta" "window=fm:fm-feat-dopen" \
    "worktree=$d/wt" "kind=ship" "pr=https://github.com/o/r/pull/1"
  FM_FAKE_PR_STATE=OPEN
  FM_FAKE_PR_MERGED=false
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-dopen)"
  local out; out=$(run_crew_state "$d" feat-dopen)
  assert_contains "$out" "state: done" "passed run with open PR -> done"
  assert_contains "$out" "run passed: PR open" "open PR state is named"
  assert_not_contains "$out" "merged/closed" "open PR must not get the old merged/closed label"
  assert_not_contains "$out" "PR merged" "open PR must not be reported merged"
  pass "terminal passed run with open PR does not claim merged"
}

test_terminal_passed_run_pr_overrides_stale_metadata() {
  reset_fakes
  local d; d=$(new_case passed-stale-meta)
  make_repo_on_branch "$d/wt" fm/feat-dstale
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dstale.meta" "window=fm:fm-feat-dstale" \
    "worktree=$d/wt" "kind=ship" "pr=https://github.com/o/r/pull/47"
  FM_FAKE_PR_47_STATE=MERGED
  FM_FAKE_PR_47_MERGED=true
  FM_FAKE_PR_48_STATE=OPEN
  FM_FAKE_PR_48_MERGED=false
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dstale https://github.com/o/r/pull/48)"
  local out; out=$(run_crew_state "$d" feat-dstale)
  assert_contains "$out" "state: done" "passed run with stale task metadata -> done"
  assert_contains "$out" "run passed: PR open" "run PR identity outranks stale task metadata"
  assert_not_contains "$out" "PR merged" "stale merged metadata must not report merged"
  pass "terminal passed run PR overrides stale task metadata"
}

test_terminal_passed_without_readable_pr_identity_reports_unknown() {
  reset_fakes
  local d; d=$(new_case passed-no-pr)
  make_repo_on_branch "$d/wt" fm/feat-dnopr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dnopr.meta" "window=fm:fm-feat-dnopr" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_no_pr fm/feat-dnopr)"
  local out; out=$(run_crew_state "$d" feat-dnopr)
  assert_contains "$out" "state: done" "passed run without PR identity -> done"
  assert_contains "$out" "run passed: PR state unknown (no PR identity)" "missing PR identity is honest unknown"
  assert_not_contains "$out" "merged/closed" "unknown PR state must not get the old merged/closed label"
  assert_not_contains "$out" "PR merged" "unknown PR state must not be reported merged"
  pass "terminal passed run without readable PR identity reports unknown"
}

test_terminal_passed_with_open_gitlab_mr_does_not_claim_merged() {
  reset_fakes
  local d read_log out
  d=$(new_case passed-open-gitlab-mr)
  make_repo_on_branch "$d/wt" fm/feat-dgitlabopen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dgitlabopen.meta" "window=fm:fm-feat-dgitlabopen" \
    "worktree=$d/wt" "kind=ship" "pr=https://git.example.com/group/subgroup/repo/-/merge_requests/9"
  read_log="$d/glab-read.log"
  : > "$read_log"
  FM_FAKE_GLAB_READ_LOG=$read_log
  FM_FAKE_GLAB_STATE=opened
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dgitlabopen https://git.example.com/group/subgroup/repo/-/merge_requests/9)"
  out=$(run_crew_state "$d" feat-dgitlabopen)
  assert_contains "$out" "run passed: PR open" "open GitLab MR state is named"
  assert_not_contains "$out" "PR merged" "open GitLab MR must not be reported merged"
  assert_grep 'git.example.com|mr view 9 -R https://git.example.com/group/subgroup/repo -F json' "$read_log" \
    "GitLab MR read uses the parsed host and project URL"
  pass "terminal passed run reads open GitLab MR state"
}

test_terminal_passed_with_merged_gitlab_mr_reports_merged() {
  reset_fakes
  local d out
  d=$(new_case passed-merged-gitlab-mr)
  make_repo_on_branch "$d/wt" fm/feat-dgitlabmerged
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dgitlabmerged.meta" "window=fm:fm-feat-dgitlabmerged" \
    "worktree=$d/wt" "kind=ship" "pr=https://gitlab.com/group/repo/-/merge_requests/10"
  FM_FAKE_GLAB_STATE=merged
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dgitlabmerged https://gitlab.com/group/repo/-/merge_requests/10)"
  out=$(run_crew_state "$d" feat-dgitlabmerged)
  assert_contains "$out" "run passed: PR merged" "merged GitLab MR is reported merged"
  pass "terminal passed run reads merged GitLab MR state"
}

test_terminal_passed_with_failed_gitlab_read_reports_unknown() {
  reset_fakes
  local d out
  d=$(new_case passed-unreadable-gitlab-mr)
  make_repo_on_branch "$d/wt" fm/feat-dgitlabunknown
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dgitlabunknown.meta" "window=fm:fm-feat-dgitlabunknown" \
    "worktree=$d/wt" "kind=ship" "pr=https://gitlab.com/group/repo/-/merge_requests/11"
  FM_FAKE_GLAB_READ_FAIL=1
  FM_FAKE_AXI_STATUS="$(run_passed_with_pr fm/feat-dgitlabunknown https://gitlab.com/group/repo/-/merge_requests/11)"
  out=$(run_crew_state "$d" feat-dgitlabunknown)
  assert_contains "$out" "run passed: PR state unknown (unreadable)" "failed GitLab read is honest unknown"
  assert_not_contains "$out" "PR merged" "failed GitLab read must not be reported merged"
  pass "terminal passed run handles failed GitLab read"
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

test_terminal_failed_ci_orphan_after_green_reads_done() {
  reset_fakes
  local d; d=$(new_case failed-ci-orphan)
  make_repo_on_branch "$d/wt" fm/feat-ci-orphan
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci-orphan.meta" "window=fm:fm-feat-ci-orphan" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_ci_orphan fm/feat-ci-orphan)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed
daemon shutting down"
  local out; out=$(run_crew_state "$d" feat-ci-orphan)
  assert_contains "$out" "state: done" "orphaned ci monitor after green must read done, not failed"
  assert_contains "$out" "source: run-step" "reclassified held run stays run-step sourced"
  assert_contains "$out" "https://github.com/o/r/pull/203" "PR URL surfaced from the run"
  assert_not_contains "$out" "state: failed" "monitor death must not read as a failed run"
  pass "orphaned ci monitor after green reads as held-for-merge done"
}

test_terminal_failed_ci_orphan_status_only_reads_done() {
  reset_fakes
  local d; d=$(new_case failed-ci-orphan-status-only)
  make_repo_on_branch "$d/wt" fm/feat-ci-orphan2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci-orphan2.meta" "window=fm:fm-feat-ci-orphan2" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_ci_orphan_status_only fm/feat-ci-orphan2)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed
daemon shutting down"
  local out; out=$(run_crew_state "$d" feat-ci-orphan2)
  assert_contains "$out" "state: done" "status-only failed orphaned monitor after green reads done"
  assert_contains "$out" "https://github.com/o/r/pull/203" "PR URL surfaced from the run"
  pass "status-only failed orphaned ci monitor after green reads done"
}

test_terminal_failed_ci_genuine_red_stays_failed() {
  reset_fakes
  local d; d=$(new_case failed-ci-genuine-red)
  make_repo_on_branch "$d/wt" fm/feat-ci-red
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci-red.meta" "window=fm:fm-feat-ci-red" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_ci_orphan fm/feat-ci-red)"
  FM_FAKE_CI_LOGS="CI checks running
checks failed: 1 of 2 checks red
daemon shutting down"
  local out; out=$(run_crew_state "$d" feat-ci-red)
  assert_contains "$out" "state: failed" "a genuinely red check keeps the run failed"
  assert_not_contains "$out" "state: done" "genuine CI failure must not reclassify to done"
  pass "genuinely failing CI keeps the failed verdict"
}

test_terminal_failed_ci_orphan_second_failed_step_stays_failed() {
  reset_fakes
  local d; d=$(new_case failed-ci-second-failure)
  make_repo_on_branch "$d/wt" fm/feat-ci-2fail
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci-2fail.meta" "window=fm:fm-feat-ci-2fail" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed_ci_orphan_second_failure fm/feat-ci-2fail)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed
daemon shutting down"
  local out; out=$(run_crew_state "$d" feat-ci-2fail)
  assert_contains "$out" "state: failed" "a second failed step keeps the run failed"
  assert_not_contains "$out" "state: done" "a second failed step must not reclassify to done"
  pass "a second failed step disqualifies the orphaned-monitor reclassification"
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

# The coarse fallback has no steps table and no ci log, so the 2026-09-05
# orphaned-monitor shape (every substantive step completed, only the ci
# monitor failed after the daemon restarted under its merge poll) cannot be
# recognized there. With the daemon provably down, that terminal failed
# record is unverified evidence from a dead instrument and must read unknown,
# never failed - the fleet rule from #3785. The fallback is reached while the
# daemon is answering for another branch, so the probe proves the daemon
# went down after that answer (a flapping daemon under incident load) - the
# two calls are separate socket connections. With the daemon up, the same
# record keeps its failure verdict.
test_coarse_failed_ledger_with_daemon_down_reports_unknown() {
  reset_fakes
  local d short; d=$(new_case coarse-daemon-down-failed)
  make_repo_on_branch "$d/wt" fm/feat-coarsedown
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarsedown.meta" "window=fm:fm-feat-coarsedown" "worktree=$d/wt" "kind=ship"
  # The primary `axi status` call answers (another crew's run - the shared
  # daemon serves the whole repo), so attribution falls to the coarse runs
  # ledger, whose newest row for this branch is terminal failed at this
  # worktree's own head.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="  failed     fm/feat-coarsedown ${short}  2026-09-05 21:00"
  FM_FAKE_DAEMON_DOWN=1
  local out; out=$(run_crew_state "$d" feat-coarsedown)
  assert_contains "$out" "state: unknown" "daemon down + failed ledger record -> unknown"
  assert_contains "$out" "no-mistakes daemon unreachable; last ledger record failed - unverified" \
    "the unverified detail names the dead instrument"
  assert_not_contains "$out" "state: failed" "an instrument failure never reads as work failure"
  assert_contains "$out" "source: run-step" "the ledger row is still this branch's attributed run"

  # Daemon provably up again: the same row stays a failure.
  FM_FAKE_DAEMON_DOWN=0
  out=$(run_crew_state "$d" feat-coarsedown)
  assert_contains "$out" "state: failed" "daemon up keeps the failed verdict over the failed record"
  assert_not_contains "$out" "unverified" "no unverified qualifier while the daemon answers"
  pass "failed ledger record reads unknown only when the daemon is provably down"
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

# The plain ledger is ordered by creation time, not the time a status changed.
# A newer failure must not be hidden by an older live run, even when both heads
# bind to the worktree. These legacy CLI cases lack the AXI identity table.
test_terminal_run_keeps_newer_failure_over_live_sibling() {
  reset_fakes
  local d base_head live_head short_base short_live out
  d=$(new_case live-beats-corpse)
  make_repo_on_branch "$d/wt" fm/feat-corpse
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'live run advanced the tip'
  live_head=$(git -C "$d/wt" rev-parse HEAD)
  # Worktree stays at the commit the dead run recorded; the live run is ahead.
  git -C "$d/wt" reset -q --hard "$base_head"
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base_head")
  short_live=$(git -C "$d/wt" rev-parse --short=7 "$live_head")
  [ "$short_base" != "$short_live" ] || fail "live run head did not advance past the worktree"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/corpse.meta" "window=fm:fm-corpse" "worktree=$d/wt" "kind=ship"
  # The newest run failed at this worktree's own commit.
  FM_FAKE_RUN_HEAD="$base_head"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-corpse)"
  # The older live run may have advanced its tip, but it did not replace this run.
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-corpse ${short_base}  2026-08-05 11:20
  running    fm/feat-corpse ${short_live}  2026-08-05 10:05
EOF
)"
  out=$(run_crew_state "$d" corpse)
  assert_contains "$out" "state: failed" "the newer failure remains authoritative beside an older live run"
  assert_contains "$out" "source: run-step" "the newer failure keeps its run-step verdict"
  pass "a newer failure is not hidden by a live sibling"
}

# The same creation-order rule on the runs-list path itself: `axi status` answers for
# another crew's branch, and this branch's newest row is terminal while an older
# row is still live.
test_runs_list_newer_failure_outranks_older_live_row() {
  reset_fakes
  local d base_head live_head short_base short_live out
  d=$(new_case live-row-beats-terminal-row)
  make_repo_on_branch "$d/wt" fm/feat-liverow
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'live run advanced the tip'
  live_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" reset -q --hard "$base_head"
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base_head")
  short_live=$(git -C "$d/wt" rev-parse --short=7 "$live_head")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/liverow.meta" "window=fm:fm-liverow" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-05 11:30
  failed     fm/feat-liverow ${short_base}  2026-08-05 11:20
  running    fm/feat-liverow ${short_live}  2026-08-05 10:05
EOF
)"
  out=$(run_crew_state "$d" liverow)
  assert_contains "$out" "state: failed" "the newest terminal row must not lose to an older live row"
  pass "runs-list selection keeps the newer failure over an older live row"
}

# An unfetched head on the older live row does not change creation order.
# Exact-head compatibility of the newer terminal row is not supersession proof.
test_unfetched_older_live_sibling_does_not_hide_failure() {
  reset_fakes
  local d base_head short_base unfetched out
  d=$(new_case unfetched-live-sibling)
  make_repo_on_branch "$d/wt" fm/feat-unfetched
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base_head")
  unfetched=0123abc
  git -C "$d/wt" rev-parse --verify --quiet "${unfetched}^{commit}" >/dev/null 2>&1 \
    && fail "the unfetched head must not resolve in the task copy"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unfetched.meta" "window=fm:fm-unfetched" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$base_head"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-unfetched)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-unfetched ${short_base}  2026-08-05 11:20
  running    fm/feat-unfetched ${unfetched}  2026-08-05 10:05
EOF
)"
  out=$(run_crew_state "$d" unfetched)
  assert_contains "$out" "state: failed" "an older unfetched live head must not hide the newer failure"
  pass "an older unfetched live sibling does not hide a newer failure"
}

# The preference must not widen: candidates of the SAME liveness class keep the
# listing's existing newest-first precedence, so two terminal rows still resolve
# to the newer one rather than to whichever the scan happens to reach last.
test_only_terminal_rows_keep_newest_first_precedence() {
  reset_fakes
  local d base_head older_head short_base short_older out
  d=$(new_case only-terminal-rows)
  make_repo_on_branch "$d/wt" fm/feat-allterminal
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'an earlier terminal run advanced the tip'
  older_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" reset -q --hard "$base_head"
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base_head")
  short_older=$(git -C "$d/wt" rev-parse --short=7 "$older_head")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/allterminal.meta" "window=fm:fm-allterminal" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-05 11:30
  cancelled  fm/feat-allterminal ${short_base}  2026-08-05 11:20
  completed  fm/feat-allterminal ${short_older}  2026-08-05 10:05
EOF
)"
  out=$(run_crew_state "$d" allterminal)
  assert_contains "$out" "state: failed" "the newest terminal row still wins when no live row binds"
  assert_contains "$out" "run cancelled" "the newer cancelled row, not the older completed one"
  pass "two terminal rows keep the existing newest-first precedence"
}

# An unclassifiable status word keeps the ledger's own newest-first precedence:
# the creation-order preference must preserve a status whose liveness is
# unknown, so an unexpected newest row is answered as-is instead of being
# displaced by an older running row and reported as working.
test_unknown_status_row_keeps_newest_first_precedence() {
  reset_fakes
  local d base_head live_head short_base short_live out
  d=$(new_case unknown-status-row)
  make_repo_on_branch "$d/wt" fm/feat-unknownrow
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'an older run advanced the tip'
  live_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" reset -q --hard "$base_head"
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base_head")
  short_live=$(git -C "$d/wt" rev-parse --short=7 "$live_head")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unknownrow.meta" "window=fm:fm-unknownrow" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-05 11:30
  quarantined fm/feat-unknownrow ${short_base}  2026-08-05 11:20
  running    fm/feat-unknownrow ${short_live}  2026-08-05 10:05
EOF
)"
  out=$(run_crew_state "$d" unknownrow)
  assert_contains "$out" "runs list status: quarantined" "the newest row's unclassifiable status is answered as-is"
  assert_not_contains "$out" "state: working" "an older live row must not displace an unclassifiable newer row"
  pass "an unclassifiable status row keeps the ledger's newest-first precedence"
}

# The other half of the no-widening criterion: a terminal `axi status` run with
# no live sibling on this worktree keeps reporting its own terminal outcome, in
# full run-step detail rather than degraded to the coarse listing.
test_terminal_run_without_live_sibling_is_unchanged() {
  reset_fakes
  local d base_head other_head short_base short_other out
  d=$(new_case terminal-no-live-sibling)
  make_repo_on_branch "$d/wt" fm/feat-nosibling
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'a second terminal run advanced the tip'
  other_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" reset -q --hard "$base_head"
  short_base=$(git -C "$d/wt" rev-parse --short=7 "$base_head")
  short_other=$(git -C "$d/wt" rev-parse --short=7 "$other_head")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/nosibling.meta" "window=fm:fm-nosibling" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$base_head"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-nosibling)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  failed     fm/feat-nosibling ${short_base}  2026-08-05 11:20
  completed  fm/feat-nosibling ${short_other}  2026-08-05 10:05
EOF
)"
  out=$(run_crew_state "$d" nosibling)
  assert_contains "$out" "state: failed" "a terminal run with no live sibling still reports its outcome"
  assert_contains "$out" "source: run-step" "terminal outcome stays an attributed run-step verdict"
  assert_contains "$out" "run failed" "the full axi-status detail is kept, not degraded to the listing"
  pass "a terminal run with no live sibling is unchanged"
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

# A ship done: whose named head lives only in the disposable copy is not
# current-state done (issue 4768). The worker's claim stays a blocked
# preservation failure rather than finished-and-safe.
test_unpushed_ship_done_is_blocked() {
  reset_fakes
  local d sha out
  d=$(new_case unpushed-done)
  make_repo_on_branch "$d/wt" fm/unpushed
  git -C "$d/wt" commit -q --allow-empty -m 'fix only in the worktree'
  sha=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unpushed.meta" \
    "window=fm:fm-unpushed" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=no-mistakes" "harness=claude"
  printf 'done: PR https://example.test/o/r/pull/9 checks green\n' \
    > "$d/state/unpushed.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" unpushed
  out=$(run_crew_state "$d" unpushed)
  assert_contains "$out" "state: blocked" "unpushed ship done: must not read as done"
  assert_contains "$out" "source: status-log" "preservation refusal stays status-log sourced"
  assert_contains "$out" "named head $sha is unreachable outside the worker copy" \
    "refusal must name the unpushed head"
  assert_not_contains "$out" "state: done" "unpushed ship done: must not remain done"
  pass "unpushed ship done: is current-state blocked"
}

# Fleet snapshot hands crew-state a captured meta copy outside state/. The
# poll's merge marker stays in the live state dir, so a squash-merged PR whose
# branch fleet sync pruned still reads done there.
test_merged_pr_reads_done_under_captured_meta() {
  reset_fakes
  local d out
  d=$(new_case merged-captured)
  make_repo_on_branch "$d/wt" fm/merged
  git -C "$d/wt" commit -q --allow-empty -m 'squash-merged fix, branch pruned'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/merged.meta" \
    "window=fm:fm-merged" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=direct-PR" "harness=claude" "pr=https://github.com/o/r/pull/7"
  printf '%s\n' fm-pr-poll-merge-notified-v1 github github.com o/r 7 \
    > "$d/state/merged.pr-poll-merge-notified"
  chmod 600 "$d/state/merged.pr-poll-merge-notified"
  printf 'done: PR https://github.com/o/r/pull/7\n' > "$d/state/merged.status"
  mkdir -p "$d/captured"
  cp "$d/state/merged.meta" "$d/captured/merged.meta"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" merged
  out=$(FM_CREW_STATE_META_OVERRIDE="$d/captured/merged.meta" run_crew_state "$d" merged)
  assert_contains "$out" "state: done" "recorded merged PR must read done under a captured meta"
  assert_not_contains "$out" "state: blocked" "merge marker must be read from the live state dir"
  pass "recorded merged PR reads done under the fleet snapshot's captured meta"
}

test_no_mistakes_prevalidation_done_stays_done() {
  reset_fakes
  local d out
  d=$(new_case preval-done)
  make_repo_on_branch "$d/wt" fm/preval
  git -C "$d/wt" commit -q --allow-empty -m 'fix only in the worktree'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/preval.meta" \
    "window=fm:fm-preval" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=no-mistakes" "harness=claude"
  printf 'done: implementation complete\n' > "$d/state/preval.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" preval
  out=$(run_crew_state "$d" preval)
  assert_contains "$out" "state: done" "no-mistakes pre-validation done: remains done"
  assert_not_contains "$out" "state: blocked" "pre-validation done: must not be the named-head gate"
  pass "no-mistakes pre-validation done: stays current-state done"
}

test_moved_remote_branch_without_named_head_is_blocked() {
  reset_fakes
  local d main_sha fix_sha out
  d=$(new_case moved-branch)
  make_repo_on_branch "$d/wt" fm/moved
  main_sha=$(git -C "$d/wt" rev-parse refs/remotes/origin/main)
  git -C "$d/wt" commit -q --allow-empty -m 'the actual fix'
  fix_sha=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" update-ref refs/remotes/origin/fm/moved "$main_sha"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/moved.meta" \
    "window=fm:fm-moved" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=direct-PR" "harness=claude"
  printf 'done: PR https://example.test/o/r/pull/8\n' > "$d/state/moved.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" moved
  out=$(run_crew_state "$d" moved)
  assert_contains "$out" "state: blocked" "a moved remote branch must not count as preserved"
  assert_contains "$out" "named head $fix_sha is unreachable outside the worker copy" \
    "refusal must name the missing fix, not the moved branch"
  pass "moved remote branch without the named head is current-state blocked"
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

# A launch pinned at the fm-spawn seed (no hook has posted yet) whose pane
# renders a recognized interactive prompt must read unknown, never working -
# this is the load-bearing link the launch-prompt backstop depends on:
# fm-watch.sh's pause_state_class absorbs a stale pane as "provably working"
# whenever THIS script reports `state: working · source: pane`, so if this
# authoritative read still said working, the watcher would silently swallow
# the wake even though bin/fm-busy-lib.sh's own classifier had already flipped
# to unknown launch-prompt. crew_busy_verdict must therefore capture a real
# tail for every harness, not only grok, so the backstop's own tail-based
# check ever runs here at all.
test_no_run_launch_prompt_parked_is_not_working() {
  reset_fakes
  local d; d=$(new_case launch-prompt)
  make_repo_on_branch "$d/wt" fm/feat-lp
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-lp.meta" "window=fm:fm-feat-lp" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT='Quick safety check: Is this a project you created or one you trust? ...
> No, exit
  Yes, I trust this folder
Enter to confirm . Esc to cancel'
  export FM_FAKE_BUSY_TEXT
  # arm only, never apply: the launch turn has never advanced past the seed
  # fm-spawn.sh writes at spawn time.
  "$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-lp >/dev/null
  local out; out=$(run_crew_state "$d" feat-lp)
  assert_not_contains "$out" "state: working" "a launch parked on its trust dialog must never read working"
  assert_contains "$out" "state: unknown" "a parked launch reads unknown, not busy or idle"
  assert_contains "$out" "launch-prompt" "the unknown verdict names the launch-prompt backstop as its source"
  pass "a launch parked on a recognized interactive prompt never reads working, closing the absorb path a stale watcher poll depends on"
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

# Issue #4115: a registration Herdr kept after its Pi exited to a plain shell is
# not an agent. The recovery-grade read proves the process level, so the
# shell-only pane reads as positive agent-gone evidence, never as a live agent
# or as unreachable.
test_no_run_herdr_stale_registration_over_shell_reads_agent_gone() {
  command -v jq >/dev/null 2>&1 || { pass "herdr stale-registration test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-stale-reg)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stale
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stale.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=pi"
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_READ_FAIL=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_PROCESS=shell
  local out; out=$(run_crew_state "$d" feat-herdr-stale)
  assert_contains "$out" "state: unknown" "a stale registration over a shell-only pane is not a live state"
  assert_contains "$out" "backend target gone" "a stale registration over a shell-only pane must read as positive agent-gone evidence"
  assert_contains "$out" "agent gone, pane shell remains" "the agent-gone reason must name the remaining shell"
  assert_not_contains "$out" "backend unreachable" "a readable shell-only pane is not unreachable"
  pass "herdr stale registration over a shell-only pane reads agent gone, not alive"
}

# The busy half of the same defect: a `working` record Herdr kept after the
# agent was killed mid-turn must never make a shell-only pane read as working.
test_no_run_herdr_stale_working_record_is_never_busy() {
  command -v jq >/dev/null 2>&1 || { pass "herdr stale-working test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-stale-working)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stale-working
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stale-working.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=pi"
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  FM_FAKE_HERDR_PROCESS=shell
  local out; out=$(run_crew_state "$d" feat-herdr-stale-working)
  assert_not_contains "$out" "state: working" "a stale working record over a shell-only pane must never read busy"
  assert_not_contains "$out" "herdr-native" "the native busy verdict must not be trusted for a shell-only pane"
  # The control: the same record with a live harness in the foreground is busy.
  FM_FAKE_HERDR_PROCESS=agent
  out=$(run_crew_state "$d" feat-herdr-stale-working)
  assert_contains "$out" "state: working" "the same working record with a live harness process must still read working"
  pass "herdr stale working record never reports a shell-only pane busy"
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
  printf 'The release window opens tomorrow.\n\n' >> "$d/state/feat-pause.status"
  out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "continuation prose and trailing blanks preserve the pause"
  assert_contains "$out" "holding for the upstream tool release" "multiline pause preserves its declared reason"
  pass "no run + idle pane on a paused: status reports state: paused with its reason"
}

test_secondmate_open_block_survives_unrelated_append() {
  reset_fakes
  local d out suffix gen
  d=$(new_case buried-block)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "harness=claude"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" mate)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" mate busy --gen "$gen" --source claude-hook --event user-prompt-submit
  for suffix in '' 'note: unrelated progress' 'resolved [key=other]: unrelated answer' 'working: continuing another task' 'done: another task completed' 'failed: another task failed' $'done: another task completed\nnote: cleanup complete' $'failed: another task failed\nnote: cleanup complete'; do
    printf 'blocked [key=access]: need release access\n%s\n' "$suffix" > "$d/state/mate.status"
    out=$(run_crew_state "$d" mate)
    assert_contains "$out" "state: blocked" "open blocker survives '$suffix' with a busy endpoint"
    assert_contains "$out" "need release access" "the open blocker's reason remains visible"
  done
  printf 'resolved [key=access]: access granted\n' >> "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "matching resolution clears the blocker"
  assert_not_contains "$out" "need release access" "closed blocker is not resurrected"
  pass "a busy secondmate keeps its open blocker until that exact key closes"
}

test_newest_open_decision_supplies_the_reported_detail() {
  reset_fakes
  local d out gen
  d=$(new_case newest-open-decision)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "harness=claude"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" mate)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" mate busy --gen "$gen" --source claude-hook --event user-prompt-submit
  printf 'blocked [key=a]: staging is down\nneeds-decision [key=b]: pick a rollout order\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: parked" "the newer open decision is the reported state"
  assert_contains "$out" "pick a rollout order" "the newer open decision supplies the detail"
  printf 'blocked [key=c]: the deploy host went away\n' >> "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: blocked" "a newer blocker takes the report back"
  assert_contains "$out" "the deploy host went away" "the newest blocker supplies the detail"
  printf 'resolved [key=c]: host restored\n' >> "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: parked" "closing the newest decision falls back to the next open one"
  assert_contains "$out" "pick a rollout order" "the still-open older decision is not lost"
  pass "the most recently opened decision supplies the reported state and detail"
}

test_single_owner_terminal_declaration_supersedes_stale_decision() {
  reset_fakes
  local d kind opener terminal out key expected
  d=$(new_case terminal-stale-decision)
  make_repo_on_branch "$d/wt" fm/task
  make_fakebin "$d" >/dev/null
  arm_idle_record "$d/state" task
  for kind in scout ship; do
    fm_write_meta "$d/state/task.meta" "window=fm:fm-task" "worktree=$d/wt" "kind=$kind" "harness=claude"
    for opener in needs-decision blocked; do
      for terminal in 'done' failed; do
        printf '%s [key=choice]: an earlier decision\n%s: final outcome\nContinuation prose.\n\n' \
          "$opener" "$terminal" > "$d/state/task.status"
        out=$(run_crew_state "$d" task)
        assert_contains "$out" "state: $terminal" "$kind terminal declaration supersedes stale $opener"
        assert_contains "$out" "final outcome" "the terminal declaration supplies the detail"
        printf 'note: cleanup complete\n' >> "$d/state/task.status"
        out=$(run_crew_state "$d" task)
        assert_contains "$out" "state: unknown" "$kind cleanup note does not revive a pre-terminal $opener"
        assert_not_contains "$out" "an earlier decision" "superseded decision detail stays absent after cleanup"
        expected=parked
        [ "$opener" != blocked ] || expected=blocked
        for key in choice new-choice; do
          printf '%s [key=%s]: reopened after completion\nnote: more cleanup\n' "$opener" "$key" >> "$d/state/task.status"
          out=$(run_crew_state "$d" task)
          assert_contains "$out" "state: $expected" "$kind retains a post-terminal $opener for $key"
          assert_contains "$out" "reopened after completion" "the reopened decision supplies the detail"
          printf 'resolved [key=%s]: answered\n' "$key" >> "$d/state/task.status"
          out=$(run_crew_state "$d" task)
          assert_contains "$out" "state: unknown" "matching resolution clears the reopened decision"
          assert_not_contains "$out" "an earlier decision" "closing a reopened decision cannot revive pre-terminal decisions"
        done
      done
    done
  done
  pass "ship and scout terminal declarations supersede stale decisions"
}

test_latest_status_preserves_legacy_completions() {
  local d event line
  d=$(new_case latest-legacy)
  for event in 'PR ready https://example.com/pull/1' 'checks green' 'ready in branch fm/topic' merged 'PR READY https://example.com/pull/1'; do
    printf 'paused: awaiting release\n%s\nMore detail: cleanup complete.\n\n' "$event" > "$d/state/task.status"
    line=$(last_status_line "$d/state/task.status")
    [ "$line" = "$event" ] || fail "legacy completion '$event' was hidden by an earlier pause"
    status_is_captain_relevant "$line" || fail "legacy completion is no longer captain-relevant"
    status_is_paused "$line" && fail "legacy completion retained pause handling"
    printf 'working: following up on merged work\n' >> "$d/state/task.status"
    line=$(last_status_line "$d/state/task.status")
    [ "$line" = 'working: following up on merged work' ] || fail "later working event did not supersede legacy completion"
    status_is_captain_relevant "$line" && fail "legacy prose made a working event captain-relevant"
    printf 'paused: waiting on upstream PR #123 to land\nOnce it is %s I will rebase and continue.\n\n' "$event" > "$d/state/task.status"
    line=$(last_status_line "$d/state/task.status")
    [ "$line" = 'paused: waiting on upstream PR #123 to land' ] || fail "continuation prose mentioning '$event' hid a multi-line pause: $line"
    status_is_paused "$line" || fail "a multi-line pause lost pause handling behind prose mentioning '$event'"
  done
  (
    shopt -u nocasematch
    FM_CAPTAIN_RE='custom-event:' status_is_captain_relevant 'CUSTOM-EVENT: ready' || fail "custom captain regex lost case-insensitive matching"
    shopt -q nocasematch && fail "captain matching changed caller shell options"
    FM_CAPTAIN_RE='custom-event:' status_is_captain_relevant 'done: ready' && fail "custom captain regex did not replace defaults"
    shopt -s nocasematch
    status_is_captain_relevant 'unrelated prose' && fail "ordinary prose became captain-relevant"
    shopt -q nocasematch || fail "captain matching cleared caller shell options"
  ) || fail "captain matching changed regex or shell-option behavior"
  pass "latest status retains legacy completion events and shared captain matching"
}

test_latest_status_subshell_work_does_not_grow_with_history() {
  local d size i level small large window
  d=$(new_case latest-processes)
  window=${FM_CLASSIFY_EVENT_WINDOW_LINES:-200}
  for size in "$window" "$((window * 10))"; do
    {
      for ((i = 0; i < size; i++)); do
        printf 'working corr=0123456789abcdef [key=phase]: progress\nMore detail: still working.\n'
      done
      printf 'PR ready https://example.com/pull/1\npaused corr=0123456789abcdef [key=release]: awaiting release\n\n'
    } > "$d/state/task.status"
    : > "$d/children-$size"
    (
      level=$BASH_SUBSHELL
      set -T
      trap 'if [ "$BASH_SUBSHELL" -gt "$level" ]; then printf x >> "$d/children-$size"; fi' DEBUG
      last_status_line "$d/state/task.status" > "$d/output"
    )
    [ "$(cat "$d/output")" = 'paused corr=0123456789abcdef [key=release]: awaiting release' ] \
      || fail "latest status lost correlation-token parsing on a long log"
  done
  small=$(wc -c < "$d/children-$window")
  large=$(wc -c < "$d/children-$((window * 10))")
  [ "$large" -le "$((small + 20))" ] || fail "latest status shell work grows with history ($small -> $large)"
  printf 'paused: awaiting a long quiet tail\n' > "$d/state/task.status"
  for ((i = 0; i < 500; i++)); do printf 'continuation prose %s\n' "$i" >> "$d/state/task.status"; done
  [ "$(last_status_line "$d/state/task.status")" = 'paused: awaiting a long quiet tail' ] \
    || fail "a declared pause buried under a long prose tail was hidden"
  pass "latest status subprocess work stays bounded and still reads past a long prose tail"
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

# The same ledger with the newest row TERMINAL keeps the strict rule: a finished
# run on a diverged head is history, not this worktree's current run.
test_coarse_terminal_row_at_foreign_head_not_attributed() {
  reset_fakes
  local d; d=$(new_case f10-coarse-terminal)
  make_repo_on_branch "$d/wt" fm/feat-f10h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10h.meta" "window=fm:fm-feat-f10h" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-f10h.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-27 14:00
  failed     fm/feat-f10h f0f0f0f0  2026-08-27 13:53
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-f10h
  local out; out=$(run_crew_state "$d" feat-f10h)
  assert_not_contains "$out" "source: run-step" "a terminal row at an unresolvable head must not bind"
  assert_not_contains "$out" "state: failed" "an unattributed terminal row must not read as failure"
  assert_contains "$out" "source: status-log" "the status log answers without an attributable run"
  pass "coarse terminal row at a foreign head is not attributed"
}

# An EXECUTING run on the task's branch binds whatever branch_sync says and
# whatever its head, so the pipeline_owned exemption is no longer the only way a
# live run with an unresolvable lane head is attributed.
test_executing_run_binds_without_pipeline_owned_sync() {
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
  assert_contains "$out" "source: run-step" "an executing run binds without the pipeline_owned label"
  assert_contains "$out" "state: working" "the executing run reads working"
  pass "an executing run binds regardless of branch_sync state"
}

# Negative control: a run PARKED at a gate keeps the strict head rule, so a
# non-pipeline_owned parked run at an unresolvable head is not attributed. The
# ledger carries a live same-branch row at that same unresolvable head - the
# coarse fallback must not revive the rejected run's gate detail through it,
# because a bare `running` row cannot tell working from waiting at a gate.
test_non_pipeline_owned_parked_unresolvable_head_not_attributed() {
  reset_fakes
  local d; d=$(new_case f10-parked-not-owned)
  make_repo_on_branch "$d/wt" fm/feat-f10p
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f10p.meta" "window=fm:fm-feat-f10p" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-f10p.status"
  FM_FAKE_RUN_HEAD=f0f0f0f0
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-f10p)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST="  running    fm/feat-f10p f0f0f0f0  2026-08-27 13:53"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-f10p
  local out; out=$(run_crew_state "$d" feat-f10p)
  assert_not_contains "$out" "source: run-step" "a non-pipeline-owned parked run at an unresolvable head must not bind"
  assert_not_contains "$out" "parked at" "a live ledger row must not revive the rejected run's gate detail"
  assert_contains "$out" "source: status-log" "falls back to the status log for the unbound parked run"
  pass "a parked run keeps the strict head rule without pipeline_owned"
}

# The CLI leaves the top-level `status:` word at `running` while a run WAITS at
# a gate, so the word alone cannot decide "executing". A gate-parked run at an
# unresolvable head, on a branch the pipeline has released, must keep the strict
# head rule in both gate shapes - otherwise the crew reports a stale
# `parked at <gate>` from a run whose code identity was never verified.
test_gate_parked_run_with_live_status_word_not_attributed() {
  local fixture d out
  for fixture in run_parked_scalar_gate_running run_parked_in_gate_block; do
    reset_fakes
    d=$(new_case "f10-gate-parked-$fixture")
    make_repo_on_branch "$d/wt" fm/feat-f10q
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/feat-f10q.meta" "window=fm:fm-feat-f10q" "worktree=$d/wt" "kind=ship" "harness=claude"
    printf 'working: implementing\n' > "$d/state/feat-f10q.status"
    FM_FAKE_RUN_HEAD=f0f0f0f0
    FM_FAKE_AXI_STATUS="$($fixture fm/feat-f10q)
branch_sync:
  state: synced"
    FM_FAKE_RUNS_LIST=""
    FM_FAKE_BUSY=0
    arm_idle_record "$d/state" feat-f10q
    out=$(run_crew_state "$d" feat-f10q)
    assert_not_contains "$out" "source: run-step" "$fixture: a gate-parked run at an unresolvable head must not bind"
    assert_not_contains "$out" "parked at" "$fixture: no gate detail may come from an unverified run"
    assert_contains "$out" "source: status-log" "$fixture: the status log answers for the unbound parked run"
    pass "$fixture keeps the strict head rule despite its live status word"
  done
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

# A live run on the task's branch is authoritative regardless of head, so an
# active row with an unverifiable head binds even when the ledger cannot anchor
# it to this worktree's head: the older row and the historical status-log
# `failed:` event never answer for the live run.
test_unanchored_unfetched_active_row_still_binds() {
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
  # head: the ledger anchor proves nothing, and the live run binds anyway.
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other aaaaaaa  2026-07-30 22:10
  running    fm/feat-noanchor $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-noanchor $(git -C "$d/wt" rev-parse --short=7 HEAD~1)  2026-07-29 20:00
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" noanchor
  out=$(run_crew_state "$d" noanchor)
  assert_contains "$out" "source: run-step" "an unanchored active row on the branch still binds"
  assert_contains "$out" "state: working" "the live run reads working"
  assert_not_contains "$out" "state: failed" "neither the older failed row nor the stale status-log event answers"
  pass "unanchored unverifiable active row is attributed because it is live"
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

# The AXI overview supplies run ids in creation order; the plain runs listing
# cannot identify a replacement or carry its review gate.
make_competing_runs_case() {  # <name> <new-status> <old-status>
  local d=$TMP_ROOT/$1 short
  reset_fakes
  mkdir -p "$d/state"
  make_repo_on_branch "$d/wt" fm/competing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/competing.meta" "window=fm:fm-competing" "worktree=$d/wt" "kind=ship"
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  FM_FAKE_AXI_HOME="count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  \"01NEW\",fm/competing,$2,$short,\"\"
  \"01OLD\",fm/competing,$3,$short,\"\""
  FM_FAKE_RUNS_LIST="  $2 fm/competing $short 2026-09-14 12:01
  $3 fm/competing $short 2026-09-14 12:00"
}

make_capped_runs_case() {
  make_competing_runs_case "$1" "$2" "$3"
  local d=$TMP_ROOT/$1
  NM_HOME="$d/nm"
  mkdir -p "$NM_HOME"
  FM_FAKE_AXI_HOME=$(python3 - "$NM_HOME/state.sqlite" "$d/wt" "$2" "$3" "$FM_FAKE_RUN_HEAD" "${4:-visible}" <<'PY'
import csv
import json
import sqlite3
import sys

database, worktree, newest, oldest, head, placement = sys.argv[1:]
with sqlite3.connect(database) as db:
    db.executescript("""
        CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
        CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                           status TEXT NOT NULL, head_sha TEXT NOT NULL, created_at INTEGER NOT NULL);
    """)
    db.executemany("INSERT INTO repos VALUES (?, ?)", [("repo", worktree), ("other-repo", worktree + "-other")])
    db.executemany("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)", [
        ("01NEW", "repo", "fm/competing", newest, head, 12 if placement == "visible" else 1),
        ("01OLD", "repo", "fm/competing", oldest, head, 0),
        ("01FOREIGN", "other-repo", "fm/competing", "running", head, 20),
    ] + [("01OTHER%02d" % i, "repo", "fm/other-%d" % i, "running", head, i + 2)
         for i in range(9 if placement == "visible" else 10)])
    rows = db.execute("SELECT id, branch, status, head_sha FROM runs WHERE repo_id = 'repo' "
                      "ORDER BY created_at DESC, id DESC").fetchall()
print("repo: " + json.dumps(worktree))
print("count: 10 of %d total" % len(rows))
print("runs[10]{id,branch,status,head,pr}:")
for row in rows[:10]:
    sys.stdout.write("  ")
    csv.writer(sys.stdout, lineterminator="\n").writerow([*row, ""])
PY
  ) || fail 'could not create the persisted run inventory fixture'
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01NEW/')"
  FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
}

test_capped_competing_live_runs_report_both_ids() {
  make_capped_runs_case capped-competing running running
  local d=$TMP_ROOT/capped-competing out
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'a capped overview must not hide the competing live run'
  assert_contains "$out" '01NEW' 'capped ambiguity names the visible run'
  assert_contains "$out" '01OLD' 'capped ambiguity names the run beyond nine other branches'
  assert_not_contains "$out" '01FOREIGN' 'another repository cannot claim this branch'
  pass 'capped overview retains both competing same-branch run ids'
}

test_capped_overview_without_branch_rows_reports_both_ids() {
  make_capped_runs_case capped-absent running pending hidden
  local d=$TMP_ROOT/capped-absent out
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'no visible branch rows cannot establish absence'
  assert_contains "$out" '01NEW' 'the newer hidden run is identified'
  assert_contains "$out" '01OLD' 'the older hidden pending run is identified'
  pass 'same-branch identity survives both runs falling outside the overview'
}

# A branch with zero rows anywhere in a capped overview must read as
# truthfully absent, not as an unreadable table: the rebuilt zero-row
# inventory re-parses as `runs[0]`.
test_capped_overview_with_no_branch_runs_reports_absent() {
  reset_fakes
  local d; d=$TMP_ROOT/capped-no-branch-runs
  mkdir -p "$d/state"
  make_repo_on_branch "$d/wt" fm/orphan-branch
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/orphan.meta" "window=fm:fm-orphan" "worktree=$d/wt" "kind=ship" "harness=claude"
  NM_HOME="$d/nm"
  mkdir -p "$NM_HOME"
  local head; head=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  FM_FAKE_AXI_HOME=$(python3 - "$NM_HOME/state.sqlite" "$d/wt" "$head" <<'PY'
import json
import sqlite3
import sys

database, worktree, head = sys.argv[1:]
with sqlite3.connect(database) as db:
    db.executescript("""
        CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
        CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                           status TEXT NOT NULL, head_sha TEXT NOT NULL, created_at INTEGER NOT NULL);
    """)
    db.execute("INSERT INTO repos VALUES ('repo', ?)", (worktree,))
    db.executemany("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)",
                    [("01OTHER%02d" % i, "repo", "fm/other-%d" % i, "running", head, i)
                     for i in range(11)])
print("repo: " + json.dumps(worktree))
print("count: 10 of 11 total")
print("runs[10]{id,branch,status,head,pr}:")
for i in range(10):
    print('  "01OTHER%02d",fm/other-%d,running,%s,""' % (i, i, head))
PY
)
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" orphan)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" orphan busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" orphan)
  assert_not_contains "$out" "state: unknown" 'a zero-row branch in a capped overview is absent, not unreadable'
  assert_not_contains "$out" "unreadable" 'a zero-row branch must not read as an unreadable table'
  assert_contains "$out" "state: working" 'absence of a run falls through to the pane/busy verdict'
  assert_contains "$out" "source: pane" 'the working verdict still comes from the pane source'
  pass 'a capped overview with zero same-branch rows reports absent, not unreadable'
}

# The same capped shape, but reached through the code path that actually
# consumes the same-branch selection: fm-crew-state only consults the overview
# once `axi status` answers with a run, so a branch of its own with no run at
# all is only reported while SOME run exists elsewhere. Pre-fix this read
# `unknown - complete same-branch run inventory unreadable`, which is the
# healthy-home-reports-itself-untrustworthy symptom.
test_no_branch_run_beside_a_live_run_elsewhere_reads_absent() {
  reset_fakes
  local d; d=$TMP_ROOT/capped-live-elsewhere
  mkdir -p "$d/state"
  make_repo_on_branch "$d/wt" fm/orphan-branch
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/orphan.meta" "window=fm:fm-orphan" "worktree=$d/wt" "kind=ship" "harness=claude"
  NM_HOME="$d/nm"
  mkdir -p "$NM_HOME"
  local head; head=$(git -C "$d/wt" rev-parse HEAD)
  FM_FAKE_AXI_HOME=$(python3 - "$NM_HOME/state.sqlite" "$d/wt" "$head" <<'PY'
import json
import sqlite3
import sys

database, worktree, head = sys.argv[1:]
with sqlite3.connect(database) as db:
    db.executescript("""
        CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
        CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                           status TEXT NOT NULL, head_sha TEXT NOT NULL, created_at INTEGER NOT NULL);
    """)
    db.execute("INSERT INTO repos VALUES ('repo', ?)", (worktree,))
    db.executemany("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)",
                   [("01OTHER%02d" % i, "repo", "fm/other-%d" % i, "running", head, i)
                    for i in range(11)])
print("repo: " + json.dumps(worktree))
print("count: 10 of 11 total")
print("runs[10]{id,branch,status,head,pr}:")
for i in range(10):
    print('  "01OTHER%02d",fm/other-%d,running,%s,""' % (i, i, head))
PY
)
  FM_FAKE_AXI_STATUS=$(run_running fm/other-0)
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" orphan)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" orphan busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" orphan)
  assert_not_contains "$out" "unreadable" 'a branch with no run of its own is not an unreadable runs table'
  assert_not_contains "$out" "state: unknown" 'a healthy home does not report itself untrustworthy'
  assert_contains "$out" "state: working" 'absence of a same-branch run falls through to the pane verdict'
  assert_contains "$out" "source: pane" 'the working verdict still comes from the pane source'
  pass 'no run for this branch beside a live run elsewhere reads absent, not unreadable'
}

# The capped-overview sqlite reader runs inside the same per-read budget as
# every other no-mistakes state read, so a contended database cannot stall a
# crew poll: a reader that never returns must be killed and fall through to the
# reader-unavailable verdict.
test_capped_inventory_reader_is_time_bounded() {
  make_capped_runs_case capped-slow-reader running pending hidden
  local d=$TMP_ROOT/capped-slow-reader out started elapsed
  cat > "$d/fakebin/python3" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$d/fakebin/python3"
  FM_CREW_STATE_NM_TIMEOUT=1
  export FM_CREW_STATE_NM_TIMEOUT
  started=$SECONDS
  out=$(run_crew_state "$d" competing)
  elapsed=$((SECONDS - started))
  unset FM_CREW_STATE_NM_TIMEOUT
  [ "$elapsed" -lt 10 ] || fail "the capped inventory reader ran unbounded for ${elapsed}s"
  assert_contains "$out" 'state: unknown' 'an unreachable inventory reader cannot establish a verdict'
  assert_contains "$out" 'reader unavailable' 'a killed reader reports the same unavailable reader path'
  pass 'the capped inventory reader is bounded by the crew read budget'
}

# Repo identity is the overview's own `repo:` line matched exactly against the
# recorded `working_path`; a spelling the inventory does not record is not
# guessed at, and reads as an unreadable inventory that still names every
# candidate run id.
test_capped_inventory_requires_exact_repo_path() {
  make_capped_runs_case capped-noncanonical running pending hidden
  local d=$TMP_ROOT/capped-noncanonical out
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed "s|^repo: .*|repo: \"$d/wt/./\"|")
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'an unmatched repo spelling cannot establish a verdict'
  assert_contains "$out" 'unreadable' 'an unmatched repo lookup reports the inventory unreadable'
  assert_contains "$out" '01NEW' 'an unmatched repo lookup still names the candidate run'
  assert_not_contains "$out" 'absent' 'an unmatched repo lookup never reads as a branch without runs'
  pass 'a repo spelling the inventory does not record reads unreadable'
}

# The 2026-09-22 PR #5317 shape on no-mistakes v1.79.0. A task copy is a linked
# git worktree of its home clone, and the CLI registers the repository once, by
# the clone's path, which the overview reports as `repo:`. Past ten runs the
# overview is capped, so selection goes through the inventory reader, which must
# key on that `repo:` line: keyed on the task worktree path it matched no row and
# every read reported the inventory unreadable. The run is in ci merge
# monitoring with every check green, and main advanced while it waited for the
# merge, so its ci log ends in re-arm lines. It must read as a green PR held for
# the merge decision, naming the PR, rather than unknown or still validating.
test_linked_worktree_green_merge_monitoring_reads_held_for_merge() {
  reset_fakes
  local d out overview
  d=$(new_case linked-worktree-green)
  mkdir -p "$d/clone"
  git -C "$d/clone" init -q
  git -C "$d/clone" commit -q --allow-empty -m init
  git -C "$d/clone" worktree add -q -b fm/feat-green "$d/wt"
  FM_FAKE_RUN_HEAD=$(git -C "$d/wt" rev-parse HEAD)
  export FM_FAKE_RUN_HEAD
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-green.meta" "window=fm:fm-feat-green" "worktree=$d/wt" "kind=ship"
  NM_HOME="$d/nm"
  mkdir -p "$NM_HOME"
  overview=$(python3 - "$NM_HOME/state.sqlite" "$d/clone" "$FM_FAKE_RUN_HEAD" <<'PY'
import json
import sqlite3
import sys

database, clone, head = sys.argv[1:]
pr = "https://github.com/o/r/pull/2"
with sqlite3.connect(database) as db:
    db.executescript("""
        CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
        CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                           status TEXT NOT NULL, head_sha TEXT NOT NULL, created_at INTEGER NOT NULL);
    """)
    db.execute("INSERT INTO repos VALUES ('repo', ?)", (clone,))
    db.execute("INSERT INTO runs VALUES ('01GREEN', 'repo', 'fm/feat-green', 'running', ?, 100)", (head,))
    db.executemany("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)",
                   [("01DONE%02d" % i, "repo", "fm/done-%d" % i, "completed", head, i)
                    for i in range(11)])
print("repo: " + json.dumps(clone))
print("current_branch: fm/feat-green")
print("daemon: running")
print("count: 10 of 12 total")
print("runs[10]{id,branch,status,head,pr}:")
print('  "01GREEN",fm/feat-green,running,%s,"%s"' % (head[:8], pr))
for i in reversed(range(2, 11)):
    print('  "01DONE%02d",fm/done-%d,completed,%s,""' % (i, i, head[:8]))
PY
) || fail 'could not create the linked-worktree run inventory fixture'
  # Guard the divergence this case exists for, so it cannot go vacuous.
  [ "$(git -C "$d/wt" rev-parse --show-toplevel)" != "$(git -C "$d/clone" rev-parse --show-toplevel)" ] \
    || fail 'the fixture task copy must not be the registered clone'
  assert_contains "$overview" 'count: 10 of 12 total' 'the fixture overview must be capped'
  FM_FAKE_AXI_HOME=$overview
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-green | sed 's/01RUN/01GREEN/')"
  FM_FAKE_AXI_STATUS_RUN=$FM_FAKE_AXI_STATUS
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
monitoring CI for PR #2 (timeout: 4h0m0s)...
CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
base branch advanced (f9f74a1d91cc..6f0f139962ea), re-arming CI monitor timeout
base branch advanced (6f0f139962ea..c5131a33a1b2), re-arming CI monitor timeout
EOF
)
  out=$(run_crew_state "$d" feat-green)
  assert_not_contains "$out" 'unreadable' 'a linked worktree reads its run through the repo line'
  assert_not_contains "$out" 'state: unknown' 'a green PR in merge monitoring is never unknown'
  assert_contains "$out" 'state: done' 'a green PR in merge monitoring reads done'
  assert_contains "$out" 'source: run-step' 'the green reading comes from the selected run'
  assert_contains "$out" 'checks green: PR ready for review' 'the reading is held for the merge decision'
  assert_contains "$out" 'https://github.com/o/r/pull/2' 'the reading names the PR to ask about'
  pass 'a linked worktree green PR in merge monitoring reads held for merge'
}

test_capped_replacement_keeps_gate_and_inventory_unchanged() {
  make_capped_runs_case "capped reviewer's replacement" running cancelled
  local d="$TMP_ROOT/capped reviewer's replacement" out before after
  before=$(git hash-object "$NM_HOME/state.sqlite")
  FM_FAKE_AXI_STATUS="$(run_failed fm/competing | sed 's/01RUN/01OLD/; s/failed/cancelled/')"
  out=$(run_crew_state "$d" competing)
  after=$(git hash-object "$NM_HOME/state.sqlite")
  assert_contains "$out" 'state: parked' 'the live replacement keeps its review gate beyond the history cap'
  assert_contains "$out" 'parked at review: 2 finding(s)' 'full replacement gate details survive inventory selection'
  assert_contains "$out" '01NEW' 'the replacement run is identified'
  assert_not_contains "$out" '01FOREIGN' 'same-branch runs in another repository do not make authority ambiguous'
  [ "$after" = "$before" ] || fail 'current-state reporting modified the persisted inventory'
  NM_HOME=../nm
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: parked' 'relative NM_HOME resolves from the queried worktree'
  pass 'complete inventory preserves the replacement gate without writes'
}

test_capped_inventory_failures_report_unknown() {
  local mode rc=0 overview
  for mode in missing corrupt schema repo count norepo; do
    (
      make_capped_runs_case "capped-unreadable-$mode" running running
      d=$TMP_ROOT/capped-unreadable-$mode
      overview=$FM_FAKE_AXI_HOME
      case "$mode" in
        missing) rm "$NM_HOME/state.sqlite" ;;
        corrupt) printf 'invalid database\n' > "$NM_HOME/state.sqlite" ;;
        schema|repo)
          python3 - "$NM_HOME/state.sqlite" "$mode" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    if sys.argv[2] == "schema":
        db.execute("DROP TABLE runs")
    else:
        db.execute("DELETE FROM repos WHERE id = 'repo'")
PY
          ;;
        count) overview=$(printf '%s\n' "$overview" | sed '/^count:/d') ;;
        norepo) overview=$(printf '%s\n' "$overview" | sed '/^repo:/d') ;;
      esac
      out=$(FM_FAKE_AXI_HOME="$overview" run_crew_state "$d" competing)
      assert_contains "$out" 'state: unknown' "$mode cannot fall back to a confident verdict from capped rows"
      assert_contains "$out" '01NEW' "$mode preserves the available run identity"
      if [ "$mode" = missing ]; then
        [ ! -e "$NM_HOME/state.sqlite" ] || fail 'the read-only lookup created a missing inventory'
      fi
      pass "$mode complete-inventory failure reports unknown"
    ) || rc=1
  done
  [ "$rc" = 0 ] || fail 'capped inventory failures'
}

make_no_python_toolbin() {
  local tb=$1/no-python tool real
  mkdir -p "$tb"
  for tool in bash git grep sed head cut tail dirname perl awk tr date stat ps uname readlink sleep; do
    real=$(command -v "$tool") || fail "missing fixture tool: $tool"
    ln -s "$real" "$tb/$tool"
  done
  PATH="$tb" bash -c '! command -v python3 && ! command -v sqlite3' || fail 'fixture exposes optional inventory readers'
  printf '%s\n' "$tb"
}

test_complete_inventory_ignores_unrelated_semantics() {
  local branch encoded d toolbin out i=0
  for branch in 'fix/c++' 'fix/a,b' 'fix/a"b'; do
    i=$((i + 1))
    make_competing_runs_case "unrelated-semantics-$i" running cancelled
    d=$TMP_ROOT/unrelated-semantics-$i
    git -C "$d/wt" check-ref-format --branch "$branch" >/dev/null || fail 'fixture branch must be valid Git syntax'
    encoded=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$branch")
    FM_FAKE_AXI_HOME="$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's/2 of 2/3 of 3/; s/runs\[2\]/runs[3]/')
  01OTHER,$encoded,running,$FM_FAKE_RUN_HEAD,\"\""
    FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01NEW/')"
    FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
    toolbin=$(make_no_python_toolbin "$d")
    out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
    assert_contains "$out" 'state: parked' 'R6 unrelated branch syntax must not suppress the requested gate'
    assert_contains "$out" '01NEW' 'selection retains the requested run identity'
    FM_FAKE_AXI_HOME="$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed '/^  01OTHER,/d')
  foreign.id,$encoded,FUTURE,unresolved,\"\""
    out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
    assert_contains "$out" 'state: parked' 'unrelated id status and head semantics cannot suppress the requested gate'
    assert_not_contains "$out" 'foreign.id' 'unrelated identities are not candidates'
  done
  pass 'R6 complete selection ignores unrelated branch semantics'
}

test_requested_branch_has_no_character_whitelist() {
  local branch encoded d out i=0
  for branch in 'fix/c++' 'fix/a,b'; do
    i=$((i + 1))
    make_competing_runs_case "requested-branch-syntax-$i" running cancelled
    d=$TMP_ROOT/requested-branch-syntax-$i
    git -C "$d/wt" branch -m "$branch"
    encoded=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$branch")
    FM_FAKE_AXI_HOME="count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  01NEW,$encoded,running,$FM_FAKE_RUN_HEAD,\"\"
  01OLD,$encoded,cancelled,$FM_FAKE_RUN_HEAD,\"\""
    FM_FAKE_AXI_STATUS="$(run_running "$branch" | sed 's/01RUN/01NEW/')"
    FM_FAKE_AXI_STATUS_RUN="$(run_parked "$branch" | sed 's/01RUN/01NEW/')"
    out=$(run_crew_state "$d" competing)
    assert_contains "$out" 'state: parked' 'R6 requested branch identity must not depend on a character whitelist'
    assert_contains "$out" '01NEW' 'the requested branch keeps its selected run'
  done
  pass 'R6 requested branches use exact identity without a whitelist'
}

test_capped_inventory_ignores_unrelated_semantics() {
  make_capped_runs_case capped-unrelated-semantics running running
  local d=$TMP_ROOT/capped-unrelated-semantics out
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's@01OTHER00,fm/other-0,running,[^,]*,@foreign.id,"fix/a,b",FUTURE,unresolved,@')
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'competing runs remain ambiguous beside unrelated metadata'
  assert_contains "$out" '01NEW' 'capped ambiguity retains the visible id'
  assert_contains "$out" '01OLD' 'R6 unrelated semantics cannot hide an id beyond the history window'
  assert_not_contains "$out" 'foreign.id' 'unrelated runs do not claim this branch'
  pass 'R6 capped inventory ignores unrelated semantics and names both ids'
}

test_capped_requested_semantics_do_not_hide_ids() {
  make_capped_runs_case capped-requested-semantics running running
  local d=$TMP_ROOT/capped-requested-semantics out
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's@01NEW,fm/competing,running,[^,]*,@01NEW,fm/competing,FUTURE,unresolved,@')
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'readable competing identities remain ambiguous'
  assert_contains "$out" '01NEW' 'the visible requested run remains identified'
  assert_contains "$out" '01OLD' 'R6 partial requested-row semantics cannot preempt complete identity lookup'
  pass 'R6 complete identity lookup precedes partial-row semantic rejection'
}

test_capped_requested_branch_with_comma_names_both_ids() {
  make_capped_runs_case capped-comma-branch running running
  local d=$TMP_ROOT/capped-comma-branch out branch=fix/a,b
  git -C "$d/wt" branch -m "$branch"
  python3 - "$NM_HOME/state.sqlite" "$branch" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE runs SET branch = ? WHERE repo_id = 'repo' AND branch = 'fm/competing'", (sys.argv[2],))
PY
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's@fm/competing@"fix/a,b"@g')
  FM_FAKE_AXI_STATUS="$(run_running "$branch" | sed 's/01RUN/01NEW/')"
  FM_FAKE_AXI_STATUS_RUN="$(run_parked "$branch" | sed 's/01RUN/01NEW/')"
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'quoted branch fields retain ambiguous authority'
  assert_contains "$out" '01NEW' 'the quoted requested branch retains its visible run'
  assert_contains "$out" '01OLD' 'R6 complete inventory preserves quoted branch identity and both ids'
  pass 'R6 capped inventory preserves quoted requested-branch identity'
}

test_inventory_structure_and_requested_semantics_remain_checked() {
  local mode d out
  for mode in columns count status head; do
    make_competing_runs_case "requested-validation-$mode" running cancelled
    d=$TMP_ROOT/requested-validation-$mode
    FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01NEW/')"
    FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
    case "$mode" in
      columns) FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed '/01NEW/s/,""$//') ;;
      count) FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's/2 of 2/1 of 2/') ;;
      status) FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's/,running,/,FUTURE,/') ;;
      head) FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed '/01NEW/s/,[a-f0-9]*,""$/,unresolved,""/') ;;
    esac
    out=$(run_crew_state "$d" competing)
    assert_contains "$out" 'state: unknown' "$mode still prevents a confident selection"
    assert_contains "$out" '01NEW' "$mode preserves the available newer identity"
    assert_contains "$out" '01OLD' "$mode preserves the available older identity"
  done
  pass 'R6 structural completeness and requested-run validation remain enforced'
}

test_complete_inventory_without_python_keeps_gate() {
  make_competing_runs_case no-python-complete running cancelled
  local d=$TMP_ROOT/no-python-complete toolbin out
  toolbin=$(make_no_python_toolbin "$d")
  FM_FAKE_AXI_STATUS="$(run_failed fm/competing | sed 's/01RUN/01OLD/; s/failed/cancelled/')"
  FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
  out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
  assert_contains "$out" 'state: parked' 'R5 complete inventory keeps its gate without Python'
  assert_contains "$out" 'parked at review: 2 finding(s)' 'optional dependencies do not remove gate detail'
  assert_contains "$out" '01NEW' 'complete inventory retains the selected id without Python'
  pass 'R5 complete inventory without Python keeps the replacement gate'
}

test_complete_ambiguity_without_python_names_both_ids() {
  make_competing_runs_case no-python-ambiguous running pending
  local d=$TMP_ROOT/no-python-ambiguous toolbin out
  toolbin=$(make_no_python_toolbin "$d")
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01NEW/')"
  out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
  assert_contains "$out" 'state: unknown' 'complete competing runs remain ambiguous without Python'
  assert_contains "$out" '01NEW' 'R5 complete ambiguity retains the newer id without Python'
  assert_contains "$out" '01OLD' 'complete ambiguity retains the older id without Python'
  pass 'R5 complete ambiguity without Python names both ids'
}

test_capped_without_python_preserves_available_ids() {
  local placement d toolbin out
  for placement in visible hidden; do
    make_capped_runs_case "no-python-capped-$placement" running pending "$placement"
    d=$TMP_ROOT/no-python-capped-$placement
    toolbin=$(make_no_python_toolbin "$d")
    out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
    assert_contains "$out" 'state: unknown' 'unreadable complete inventory must fail closed'
    assert_contains "$out" '01NEW' 'R5 capped lookup retains available ids without Python'
    assert_contains "$out" 'inventory' 'unknown explains that complete inventory could not be read'
    assert_not_contains "$out" '01FOREIGN' 'unreadable inventory does not invent foreign authority'
  done
  pass 'R5 capped lookup without Python preserves available ids'
}

test_capped_without_sqlite_preserves_available_ids() {
  make_capped_runs_case no-sqlite-capped running running
  local d=$TMP_ROOT/no-sqlite-capped out
  mkdir -p "$d/no-sqlite"
  printf 'raise ImportError("sqlite support unavailable")\n' > "$d/no-sqlite/sqlite3.py"
  out=$(PYTHONPATH="$d/no-sqlite" run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'missing SQLite support must fail closed'
  assert_contains "$out" '01NEW' 'R5 capped lookup retains available ids without SQLite support'
  assert_contains "$out" 'inventory' 'missing SQLite support leaves an explicit inventory diagnostic'
  pass 'R5 capped lookup without SQLite support preserves available ids'
}

test_live_to_terminal_inventory_disagreement_is_unknown() {
  make_competing_runs_case live-to-terminal running cancelled
  local d=$TMP_ROOT/live-to-terminal out
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01NEW/')"
  FM_FAKE_AXI_STATUS_RUN="$(run_failed fm/competing | sed 's/01RUN/01NEW/; s/failed/cancelled/')"
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'R1 live selection becoming terminal cannot publish a stale failure'
  assert_contains "$out" 'status disagrees with inventory' 'the selection race is identified'
  assert_contains "$out" '01NEW' 'the changing run remains identifiable'
  assert_not_contains "$out" 'state: failed' 'a cancelled stale selection is not a work failure'
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's/,running,/,cancelled,/')
  FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'terminal-to-live disagreement remains rejected'
  pass 'R1 both directions of inventory liveness disagreement read unknown'
}

make_uninitialized_worker_case() {
  local d=$TMP_ROOT/$1 gen
  reset_fakes
  mkdir -p "$d/state"
  make_repo_on_branch "$d/wt" fm/no-gate
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/worker.meta" "window=fm:fm-worker" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=$(cat "$ROOT/tests/captures/no-mistakes-v1.70.1/uninitialized.toon")
  FM_FAKE_AXI_STATUS_ERROR=1
  FM_FAKE_AXI_HOME_ERROR=1
  printf 'working: implementation continues\n' > "$d/state/worker.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" worker)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" worker "$2" --gen "$gen" \
    --source claude-hook --event "${3:-stop}"
}

test_uninitialized_busy_worker_uses_pane() {
  make_uninitialized_worker_case uninitialized-busy busy user-prompt-submit
  local d=$TMP_ROOT/uninitialized-busy out
  out=$(run_crew_state "$d" worker)
  assert_contains "$out" 'state: working' 'R2 an uninitialized gate must preserve a busy worker'
  assert_contains "$out" 'source: pane' 'a busy worker without a gate uses current pane evidence'
  assert_not_contains "$out" 'source: run-step' 'an initialization error is not a run'
  FM_FAKE_AXI_STATUS='error: "database locked"'
  out=$(run_crew_state "$d" worker)
  assert_contains "$out" 'state: unknown' 'other inventory errors must not be mistaken for no gate'
  pass 'R2 uninitialized busy workers retain pane reporting'
}

test_uninitialized_idle_worker_uses_status() {
  make_uninitialized_worker_case uninitialized-idle idle
  local d=$TMP_ROOT/uninitialized-idle out
  out=$(run_crew_state "$d" worker)
  assert_contains "$out" 'state: working' 'R2 an uninitialized gate must preserve current worker status'
  assert_contains "$out" 'source: status-log' 'an idle worker without a gate uses its current status'
  assert_contains "$out" 'implementation continues' 'current worker detail remains available'
  pass 'R2 uninitialized idle workers retain status reporting'
}

make_historical_inventory_case() {
  make_competing_runs_case "$1" completed cancelled
  local d=$TMP_ROOT/$1 gen
  FM_FAKE_AXI_STATUS="$(run_passed fm/competing | sed 's/01RUN/01NEW/')"
  FM_FAKE_AXI_STATUS_RUN=$FM_FAKE_AXI_STATUS
  git -C "$d/wt" commit -q --allow-empty -m 'current work after completed validation'
  fm_write_meta "$d/state/competing.meta" "window=fm:fm-competing" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementation after validation\n' > "$d/state/competing.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" competing)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" competing "$2" --gen "$gen" \
    --source claude-hook --event "${3:-stop}"
}

test_historical_inventory_uses_current_pane() {
  make_historical_inventory_case historical-inventory-busy busy user-prompt-submit
  local d=$TMP_ROOT/historical-inventory-busy out
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: working' 'R3 a proven historical run must preserve a busy worker'
  assert_contains "$out" 'source: pane' 'a historical inventory row yields to current pane evidence'
  assert_not_contains "$out" 'source: run-step' 'historical rows cannot be reattributed through the ledger'
  pass 'R3 historical inventory yields to the current busy pane'
}

test_historical_inventory_uses_current_status() {
  make_historical_inventory_case historical-inventory-idle idle
  local d=$TMP_ROOT/historical-inventory-idle out
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: working' 'R3 a proven historical run must preserve current worker status'
  assert_contains "$out" 'source: status-log' 'historical inventory yields to the current status log'
  assert_contains "$out" 'implementation after validation' 'the current work detail is preserved'
  pass 'R3 historical inventory yields to current worker status'
}

test_superseded_cancelled_run_preserves_replacement_gate() {
  make_competing_runs_case superseded-gate running cancelled
  local d=$TMP_ROOT/superseded-gate out
  FM_FAKE_AXI_STATUS="$(run_failed fm/competing | sed 's/01RUN/01OLD/; s/failed/cancelled/')
error: \"cancelled: superseded by new push\""
  # The rerun's rebased head is not in the submitted worktree's object store.
  FM_FAKE_RUN_HEAD=0123abcd
  FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')
branch_sync:
  state: pipeline_owned"
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed '/01NEW/s/,[a-f0-9]*,""$/,0123abcd,""/')
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: parked' 'superseded cancelled run must expose the live review gate'
  assert_contains "$out" 'parked at review: 2 finding(s)' 'replacement gate detail survives selection'
  assert_contains "$out" '01NEW' 'the selected replacement run is identified'
  pass 'superseded cancelled run preserves the replacement review gate'
}

# A commit the task copy HAS but that is neither the local head, an ancestor,
# nor a descendant of it: exactly what a pipeline rebase leaves as the run head.
make_rebased_head() {  # <worktree> -> echoes the diverged commit's short sha
  local wt=$1 tree commit
  tree=$(git -C "$wt" hash-object -t tree -w /dev/null)
  commit=$(git -C "$wt" commit-tree "$tree" -m 'pipeline rebased head')
  git -C "$wt" merge-base --is-ancestor HEAD "$commit" && fail "rebased head must not descend from local head"
  git -C "$wt" merge-base --is-ancestor "$commit" HEAD && fail "rebased head must not be an ancestor of local head"
  git -C "$wt" rev-parse --short=8 "$commit"
}

# A live run whose head diverged from the local head because the pipeline
# rebased the branch is this task's current run. The newest overview row is the
# live run, and an older FAILED run still matches the local head; the failed run
# must not be read as the task's state (2026-08-23 billing-cycle-crash-safety).
test_live_rebased_run_beats_older_failed_run_at_local_head() {
  make_competing_runs_case live-rebased running failed
  local d=$TMP_ROOT/live-rebased out rebased
  rebased=$(make_rebased_head "$d/wt")
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed "/01NEW/s/,[a-f0-9]*,\"\"\$/,$rebased,\"\"/")
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01NEW/')
branch_sync:
  state: synced"
  FM_FAKE_AXI_STATUS_RUN=$FM_FAKE_AXI_STATUS
  printf 'working: validating\n' > "$d/state/competing.status"
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: working' 'a live run on the branch reads working despite its rebased head'
  assert_contains "$out" 'source: run-step' 'the live run is the authoritative source'
  assert_not_contains "$out" 'state: failed' 'the older failed run must not be read as current'
  pass 'a live rebased run beats an older failed run at the local head'
}

# The same live run reads working for every EXECUTING status word the CLI can
# actually deliver here. `fm_nm_select_run` validates the overview status column
# against pending|running|completed|failed|cancelled, so those are the only live
# words that reach the predicate; the overview and the id-addressed detail read
# the same runs.status column, so the fixture carries one word in BOTH surfaces.
test_live_rebased_run_reads_working_for_every_executing_status() {
  local status d rebased out
  for status in pending running; do
    make_competing_runs_case "live-rebased-$status" "$status" failed
    d=$TMP_ROOT/live-rebased-$status
    rebased=$(make_rebased_head "$d/wt")
    FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed "/01NEW/s/,[a-f0-9]*,\"\"\$/,$rebased,\"\"/")
    FM_FAKE_RUN_HEAD=$rebased
    FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed "s/01RUN/01NEW/; s/status: running/status: $status/")"
    FM_FAKE_AXI_STATUS_RUN=$FM_FAKE_AXI_STATUS
    out=$(run_crew_state "$d" competing)
    assert_contains "$out" 'state: working' "$status run with a rebased head reads working"
    assert_contains "$out" 'source: run-step' "$status run with a rebased head is run-step sourced"
    assert_not_contains "$out" 'state: failed' "$status run with a rebased head is never failed"
    pass "$status run with a rebased head reads working"
  done
}

# The LEGACY bare-status surface carries run-level `fixing` and `ci`, which the
# overview table's vocabulary does not include. The selector never validates a
# word there (it answers `unavailable` with no table), so those runs are the
# crew's own live run and must bind at a rebased head like any other.
test_legacy_surface_binds_fixing_and_ci_at_a_rebased_head() {
  local status d rebased out
  for status in fixing ci; do
    reset_fakes
    d=$(new_case "legacy-live-$status")
    make_repo_on_branch "$d/wt" fm/feat-legacylive
    rebased=$(make_rebased_head "$d/wt")
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/feat-legacylive.meta" "window=fm:fm-feat-legacylive" "worktree=$d/wt" "kind=ship" "harness=claude"
    printf 'failed: earlier stage run\n' > "$d/state/feat-legacylive.status"
    FM_FAKE_RUN_HEAD=$rebased
    FM_FAKE_AXI_STATUS="$(run_running fm/feat-legacylive | sed "s/status: running/status: $status/")
branch_sync:
  state: synced"
    FM_FAKE_RUNS_LIST=""
    FM_FAKE_BUSY=0
    arm_idle_record "$d/state" feat-legacylive
    out=$(run_crew_state "$d" feat-legacylive)
    assert_contains "$out" "source: run-step" "a legacy $status run at a rebased head binds"
    assert_contains "$out" "state: working" "a legacy $status run reads working"
    assert_not_contains "$out" "state: failed" "the stale failed event must not answer for a live $status run"
    pass "legacy surface binds a $status run at a rebased head"
  done
}

# Legacy CLI surface (no overview table): the bare `axi status` run is live on
# this branch with a rebased head, while the runs ledger still holds an older
# failed row at the local head.
test_legacy_live_rebased_run_is_authoritative() {
  reset_fakes
  local d rebased short out; d=$(new_case legacy-live-rebased)
  make_repo_on_branch "$d/wt" fm/feat-rebased
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-rebased.meta" "window=fm:fm-feat-rebased" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/feat-rebased.status"
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-rebased)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-rebased ${rebased}  2026-08-23 13:53
  failed     fm/feat-rebased ${short}  2026-08-23 12:09
EOF
)"
  out=$(run_crew_state "$d" feat-rebased)
  assert_contains "$out" 'state: working' 'legacy live rebased run reads working'
  assert_contains "$out" 'source: run-step' 'legacy live rebased run is run-step sourced'
  assert_not_contains "$out" 'state: failed' 'the older failed row must not read as current'
  pass 'legacy live rebased run is authoritative over an older failed row'
}

# The head-free route is licensed by the daemon being reachable. Once the daemon
# answers down AND no ledger row anchors the run, nothing ties the record to this
# worktree at all, so it stops answering and the status log takes over.
test_live_record_at_diverged_head_does_not_bind_an_unproven_record() {
  reset_fakes
  local d rebased out; d=$(new_case zombie-daemon-down)
  make_repo_on_branch "$d/wt" fm/feat-zombie
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-zombie.meta" "window=fm:fm-feat-zombie" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/feat-zombie.status"
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-zombie)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-zombie
  out=$(run_crew_state "$d" feat-zombie)
  assert_not_contains "$out" "source: run-step" "a record with neither head nor anchor identity must not bind"
  assert_contains "$out" "source: status-log" "the crew's own evidence answers instead"
  pass "an unproven record at a diverged head does not answer for the crew"
}

# A run PARKED at a gate keeps its gate and findings when the daemon dies. The
# ledger word stays `running` while a run waits (parked.toon), so classifying
# off the ledger would relabel an open decision as a dead live record and the
# findings would never reach the supervisor.
test_parked_gate_survives_a_dead_daemon() {
  reset_fakes
  local d local_short out; d=$(new_case parked-dead-daemon)
  make_repo_on_branch "$d/wt" fm/feat-parkdd
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-parkdd.meta" "window=fm:fm-feat-parkdd" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/feat-parkdd.status"
  FM_FAKE_RUN_HEAD=f0f0f0f0
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-parkdd)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-parkdd f0f0f0f0  2026-08-27 13:53
  completed  fm/feat-parkdd ${local_short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-parkdd
  out=$(run_crew_state "$d" feat-parkdd)
  assert_contains "$out" "state: parked" "an open gate stays parked when the instrument dies"
  assert_contains "$out" "parked at review" "the gate itself still reaches the supervisor"
  assert_contains "$out" "finding(s)" "the gate findings still reach the supervisor"
  assert_not_contains "$out" "state: unknown" "a parked run is not a dead live record"
  pass "a parked gate survives a dead daemon with its findings intact"
}

# The modern selected-run route reaches the same diverged-head shape: the run
# head RESOLVES but diverged after the pipeline rebased, and no ledger row
# anchors it, so identity is unproven and the record must not answer at all.
test_selected_run_diverged_head_does_not_bind_an_unproven_record() {
  reset_fakes
  local d rebased out; d=$(new_case selected-diverged-down)
  make_repo_on_branch "$d/wt" fm/feat-seldiv
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/seldiv.meta" "window=fm:fm-seldiv" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/seldiv.status"
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-seldiv,running,$rebased,\"\""
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-seldiv)"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" seldiv
  out=$(run_crew_state "$d" seldiv)
  assert_not_contains "$out" "source: run-step" "an unproven record must not bind on the selected route either"
  assert_contains "$out" "source: status-log" "the crew's own evidence answers instead"
  pass "an unproven record at a diverged head does not answer on the selected route"
}

# The crew observed the refused socket itself. The ledger anchor BINDS a record
# here and the dead daemon makes it unverified, so this drives the dead-daemon
# verdict directly - and the blocker must still outrank it.
test_socket_refused_log_survives_the_dead_daemon_verdict() {
  reset_fakes
  local d local_short out; d=$(new_case socket-refused-anchored)
  make_repo_on_branch "$d/wt" fm/feat-sockdiv
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-sockdiv.meta" "window=fm:fm-feat-sockdiv" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: no-mistakes daemon socket refused connections\n' > "$d/state/feat-sockdiv.status"
  FM_FAKE_RUN_HEAD=f0f0f0f0
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-sockdiv)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-sockdiv f0f0f0f0  2026-08-27 13:53
  completed  fm/feat-sockdiv ${local_short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-sockdiv
  out=$(run_crew_state "$d" feat-sockdiv)
  assert_contains "$out" "state: blocked" "a first-hand socket refusal is not demoted to a generic unknown"
  assert_contains "$out" "socket refused" "the crew's own blocker reaches the supervisor"
  assert_not_contains "$out" "state: unknown" "the unverified record must not replace the blocker"
  pass "a socket-refused blocker survives the dead-daemon verdict"
}

# The selected route's anchored shape with an ORDINARY blocker: the header rule
# says a blocked tip stays blocked with the unverified record named, and nothing
# else reaches that path with a `blocked:` tip.
test_ordinary_blocked_tip_survives_the_dead_daemon_verdict() {
  reset_fakes
  local d h2 short out; d=$(new_case ordinary-blocked-anchored)
  make_repo_on_branch "$d/wt" fm/feat-obanch
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-obanch.meta" "window=fm:fm-feat-obanch" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: database upload failed with broken pipe\n' > "$d/state/feat-obanch.status"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-obanch,running,$h2,\"\""
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-obanch)"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-obanch $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-obanch ${short}  2026-07-29 20:00
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-obanch
  out=$(run_crew_state "$d" feat-obanch)
  assert_contains "$out" "state: blocked" "an ordinary blocker stays blocked when the record is unverified"
  assert_contains "$out" "broken pipe" "the crew's own blocker reaches the supervisor"
  assert_contains "$out" "daemon unreachable" "the unverified record is named as the reason"
  assert_not_contains "$out" "superseded" "an unverified record never supersedes an open blocker"
  pass "an ordinary blocked tip survives the dead-daemon verdict"
}


# A visibly working crew must never be overridden by a stale record that merely
# names its branch. Identity is proven by neither head nor ledger anchor here,
# so the busy pane answers - the base behaviour before the daemon guard existed.
test_unproven_record_with_dead_daemon_does_not_override_a_busy_pane() {
  reset_fakes
  local d rebased out gen; d=$(new_case unproven-busy-pane)
  make_repo_on_branch "$d/wt" fm/feat-unproven
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-unproven.meta" "window=fm:fm-feat-unproven" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-unproven.status"
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-unproven)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=1
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-unproven)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-unproven busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  out=$(run_crew_state "$d" feat-unproven)
  assert_contains "$out" "state: working" "a busy crew keeps reading working"
  assert_contains "$out" "source: pane" "the live pane answers, not the stale record"
  assert_not_contains "$out" "state: unknown" "an unproven record must not blank out a working crew"
  pass "an unproven record with a dead daemon never overrides a busy pane"
}

# Only a gate is ambiguous under a coarse live row. An ordinary blocker keeps the
# pre-existing reading, exactly as it does on the full route.
test_coarse_live_row_over_ordinary_blocked_keeps_superseded_reading() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-ordinary-blocked)
  make_repo_on_branch "$d/wt" fm/feat-cob
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cob.meta" "window=fm:fm-feat-cob" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'blocked: database upload failed with broken pipe\n' > "$d/state/feat-cob.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  running    fm/feat-cob ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cob
  out=$(run_crew_state "$d" feat-cob)
  assert_contains "$out" "state: working" "an ordinary blocker over a live coarse row keeps working"
  assert_contains "$out" "superseded by active run" "the generic superseded reading is kept"
  assert_not_contains "$out" "state: blocked" "a validating crew must not read blocked"
  pass "an ordinary blocked tip over a coarse live row keeps the superseded reading"
}

# The head-free route still binds while the daemon answers: the daemon probe
# narrows the zombie case only, it does not undo the rebase fix.
test_live_record_at_diverged_head_binds_while_daemon_answers() {
  reset_fakes
  local d rebased out; d=$(new_case live-daemon-up)
  make_repo_on_branch "$d/wt" fm/feat-livedaemon
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-livedaemon.meta" "window=fm:fm-feat-livedaemon" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/feat-livedaemon.status"
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-livedaemon)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_DAEMON_DOWN=0
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-livedaemon
  out=$(run_crew_state "$d" feat-livedaemon)
  assert_contains "$out" "source: run-step" "a reachable daemon keeps the rebased live run authoritative"
  assert_contains "$out" "state: working" "the live rebased run still reads working"
  pass "a live record at a diverged head binds while the daemon answers"
}


# Same anchored shape with the daemon answering: the guard narrows the dead
# instrument only, the unfetched-head fix round still binds.
test_anchored_continuation_binds_while_daemon_answers() {
  reset_fakes
  local d local_short out; d=$(new_case anchored-daemon-up)
  make_repo_on_branch "$d/wt" fm/feat-anchorup
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-anchorup.meta" "window=fm:fm-feat-anchorup" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: validating\n' > "$d/state/feat-anchorup.status"
  FM_FAKE_RUN_HEAD=f0f0f0f0
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-anchorup)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-anchorup f0f0f0f0  2026-08-27 13:53
  completed  fm/feat-anchorup ${local_short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_DAEMON_DOWN=0
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-anchorup
  out=$(run_crew_state "$d" feat-anchorup)
  assert_contains "$out" "source: run-step" "the anchored continuation still binds with the daemon answering"
  assert_contains "$out" "state: working" "the anchored live run reads working"
  pass "the anchored continuation binds while the daemon answers"
}

# A record that just declared itself unverified cannot also declare an open
# decision superseded.
test_unverified_coarse_record_makes_no_supersede_claim() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-unknown-supersede)
  make_repo_on_branch "$d/wt" fm/feat-cus
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cus.meta" "window=fm:fm-feat-cus" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/feat-cus.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  running    fm/feat-cus ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cus
  out=$(run_crew_state "$d" feat-cus)
  assert_contains "$out" "state: working" "a head-tied coarse row keeps its working reading whatever the daemon answers"
  assert_contains "$out" "superseded by active run" "the coarse route keeps its original supersede note"
  pass "a head-tied coarse record keeps its working reading and its original note"
}

# The modern selected-run route reaches the anchored-continuation rule through
# its own `elif` (the run head is not an object in this copy). That route binds
# on ledger evidence which proves IDENTITY, not liveness, so the daemon rule
# has to hold there too.
test_selected_run_anchored_continuation_needs_a_live_daemon() {
  reset_fakes
  local d h2 short out
  d=$(new_case selected-anchored-down)
  make_repo_on_branch "$d/wt" fm/feat-selanchor
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/selanchor.meta" "window=fm:fm-selanchor" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/selanchor.status"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-selanchor,running,$h2,\"\""
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-selanchor)"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-selanchor $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-selanchor ${short}  2026-07-29 20:00
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" selanchor
  out=$(run_crew_state "$d" selanchor)
  assert_not_contains "$out" "state: working" "the selected anchored route must not read working with the daemon answering down"
  assert_contains "$out" "daemon unreachable" "the ledger anchor proved identity, so liveness is what is reported"
  assert_not_contains "$out" "code identity unverified" "an anchored run's identity is proven, not unverified"
  assert_contains "$out" "run: 01RUN" "the verdict still names the run for a later --run read"
  pass "the selected-run anchored continuation reports the dead daemon, not an identity failure"
}

# The selected route honours the parked exemption too: an anchored PARKED run
# with a dead daemon keeps its gate and findings, exactly as the legacy route
# does on the same evidence.
test_selected_run_anchored_parked_keeps_its_gate_with_a_dead_daemon() {
  reset_fakes
  local d local_short out; d=$(new_case selected-anchored-parked)
  make_repo_on_branch "$d/wt" fm/feat-selpark
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/selpark.meta" "window=fm:fm-selpark" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/selpark.status"
  FM_FAKE_RUN_HEAD=f0f0f0f0
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-selpark,running,f0f0f0f0,\"\""
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-selpark)
branch_sync:
  state: synced"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-selpark f0f0f0f0  2026-08-27 13:53
  completed  fm/feat-selpark ${local_short}  2026-08-27 12:09
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" selpark
  out=$(run_crew_state "$d" selpark)
  assert_contains "$out" "state: parked" "an anchored parked run stays parked when the instrument dies"
  assert_contains "$out" "parked at review" "the gate reaches the supervisor on the selected route too"
  assert_contains "$out" "finding(s)" "the gate findings reach the supervisor"
  assert_not_contains "$out" "state: unknown" "a parked run is not a dead live record"
  pass "the selected route keeps an anchored parked run's gate with a dead daemon"
}

# An open decision outranks the unverified record on the selected route as well.
# The ledger anchor binds the run here, so the dead-daemon verdict is genuinely
# produced and the reconciliation is what keeps the decision visible.
test_selected_run_dead_daemon_leaves_the_open_decision_open() {
  reset_fakes
  local d h2 short out; d=$(new_case selected-dead-decision)
  make_repo_on_branch "$d/wt" fm/feat-seldec
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/seldec.meta" "window=fm:fm-seldec" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/seldec.status"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-seldec,running,$h2,\"\""
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-seldec)"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-seldec $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-seldec ${short}  2026-07-29 20:00
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" seldec
  out=$(run_crew_state "$d" seldec)
  assert_contains "$out" "state: parked" "the open decision is not hidden behind the unverified record"
  assert_contains "$out" "approve the schema change" "the crew's own decision note reaches the supervisor"
  assert_contains "$out" "daemon unreachable" "the unverified record is named as the reason"
  assert_contains "$out" "run: 01RUN" "the verdict names the run so a human can go look at it"
  assert_not_contains "$out" "superseded" "an unverified record never supersedes an open decision"
  pass "an open decision survives the dead-daemon verdict on the selected route"
}

# A probe that did not ANSWER proves nothing, so it must not hand the verdict to
# a stale open decision: a genuinely failed run would be reported as awaiting a
# human on probe latency alone. The record still degrades to unknown, which is
# ambiguous but not falsely actionable.
test_unanswered_probe_does_not_turn_a_failed_coarse_record_into_a_gate() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-failed-probe-timeout)
  make_repo_on_branch "$d/wt" fm/feat-cfpt
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cfpt.meta" "window=fm:fm-feat-cfpt" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/feat-cfpt.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  failed     fm/feat-cfpt ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_DAEMON_TIMEOUT=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cfpt
  out=$(run_crew_state "$d" feat-cfpt)
  assert_contains "$out" "state: unknown" "an unanswered probe still degrades the terminal record"
  assert_not_contains "$out" "state: parked" "probe latency must not assert an open gate over a failed run"
  pass "an unanswered probe never turns a failed coarse record into a gate"
}



# The selected route already appends `run: <id>` to every ordinary verdict, so
# the dead-daemon detail must not carry its own copy.
test_selected_route_dead_daemon_names_the_run_once() {
  reset_fakes
  local d h2 short out ids; d=$(new_case selected-id-once)
  make_repo_on_branch "$d/wt" fm/feat-selonce
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/selonce.meta" "window=fm:fm-selonce" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/selonce.status"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-selonce,running,$h2,\"\""
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-selonce)"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-selonce $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-selonce ${short}  2026-07-29 20:00
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" selonce
  out=$(run_crew_state "$d" selonce)
  ids=$(printf '%s\n' "$out" | grep -o '01RUN' | wc -l | tr -d ' ')
  assert_contains "$out" "daemon unreachable" "the dead instrument is still named"
  assert_contains "$out" "01RUN" "the verdict still names the run"
  assert_equals "1" "$ids" "the run id appears exactly once"
  pass "the selected-route dead-daemon verdict names the run once"
}

# The same run, the same head, the same dead daemon must read the same way
# whichever run the shared daemon's bare `axi status` happens to name - that is
# routine once several crews validate one repo. The ledger row sits at this
# worktree's own head, so the head rule exempts it either way.
test_head_tied_row_reads_the_same_whichever_run_axi_names() {
  local who d local_short out
  for who in self other; do
    reset_fakes
    d=$(new_case "head-tied-$who")
    make_repo_on_branch "$d/wt" fm/feat-htied
    local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/feat-htied.meta" "window=fm:fm-feat-htied" "worktree=$d/wt" "kind=ship" "harness=claude"
    printf 'working: implementing\n' > "$d/state/feat-htied.status"
    if [ "$who" = self ]; then
      FM_FAKE_AXI_STATUS="$(run_running fm/feat-htied)
branch_sync:
  state: synced"
    else
      FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
    fi
    FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  running    fm/feat-htied ${local_short}  2026-08-23 13:53
EOF
)"
    FM_FAKE_DAEMON_DOWN=1
    FM_FAKE_BUSY=0
    arm_idle_record "$d/state" feat-htied
    out=$(run_crew_state "$d" feat-htied)
    assert_contains "$out" "state: working" "$who: a head-tied run reads working with the daemon down"
    assert_not_contains "$out" "state: unknown" "$who: the head rule exempts a head-tied record"
    pass "a head-tied row reads working when axi names the $who run"
  done
}

# The record's head and the ledger row's head are INDEPENDENT. A same-branch
# record whose own head diverged still reaches the coarse fallback, where the
# newest ledger row can sit at this worktree's own head - a head-tied row the
# head rule exempts. The coarse route carries no dead-daemon verdict, so that
# row keeps its working reading.
test_coarse_head_tied_row_is_exempt_even_when_the_record_head_diverged() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-head-tied-diverged-record)
  make_repo_on_branch "$d/wt" fm/feat-chtd
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-chtd.meta" "window=fm:fm-feat-chtd" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-chtd.status"
  FM_FAKE_RUN_HEAD=f0f0f0f0
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-chtd)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST="  running    fm/feat-chtd ${local_short}  2026-08-23 13:53"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-chtd
  out=$(run_crew_state "$d" feat-chtd)
  assert_contains "$out" "state: working" "a head-tied ledger row keeps its working reading"
  assert_not_contains "$out" "state: unknown" "the head rule exempts a head-tied row whatever the record head says"
  assert_not_contains "$out" "daemon unreachable" "the coarse route carries no dead-instrument verdict"
  pass "a head-tied coarse row is exempt even when the record head diverged"
}

# An unrecognised ledger word yields an unknown verdict from a LIVE daemon, so it
# is not an unverified record: the ordinary supersede note applies, as it did
# before the coarse-unknown special case existed.
test_unrecognised_ledger_word_keeps_the_ordinary_supersede_note() {
  reset_fakes
  local d local_short out; d=$(new_case unrecognised-word-supersede)
  make_repo_on_branch "$d/wt" fm/feat-uws
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-uws.meta" "window=fm:fm-feat-uws" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/feat-uws.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  pending    fm/feat-uws ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_DAEMON_DOWN=0
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-uws
  out=$(run_crew_state "$d" feat-uws)
  assert_contains "$out" "state: unknown" "an unrecognised word still reads unknown"
  assert_contains "$out" "runs list status: pending" "the unrecognised word is reported as itself"
  assert_contains "$out" "superseded (run unknown)" "a live daemon's unknown keeps the ordinary supersede note"
  pass "an unrecognised ledger word keeps the ordinary supersede note"
}

# The coarse ledger word `pending` is not an acceptance: it keeps its unknown
# reading rather than claiming the crew is validating.
test_coarse_pending_ledger_word_reads_unknown() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-pending)
  make_repo_on_branch "$d/wt" fm/feat-cpend
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cpend.meta" "window=fm:fm-feat-cpend" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-cpend.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  pending    fm/feat-cpend ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cpend
  out=$(run_crew_state "$d" feat-cpend)
  assert_contains "$out" "state: unknown" "a pending ledger word is not a working claim"
  assert_contains "$out" "runs list status: pending" "the unrecognised word is reported as itself"
  pass "a coarse pending ledger word reads unknown"
}

# The same anchored selected-run shape with the daemon answering still binds.
test_selected_run_anchored_continuation_binds_while_daemon_answers() {
  reset_fakes
  local d h2 short out
  d=$(new_case selected-anchored-up)
  make_repo_on_branch "$d/wt" fm/feat-selanchorup
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  h2=$(mint_unfetched_fix_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/selanchorup.meta" "window=fm:fm-selanchorup" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/selanchorup.status"
  FM_FAKE_RUN_HEAD="$h2"
  FM_FAKE_AXI_HOME="count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  \"01RUN\",fm/feat-selanchorup,running,$h2,\"\""
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-selanchorup)"
  FM_FAKE_AXI_STATUS_RUN="$FM_FAKE_AXI_STATUS"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/feat-selanchorup $(git -C "$d/wt.pipe" rev-parse --short=7 HEAD)  2026-07-30 22:05
  failed     fm/feat-selanchorup ${short}  2026-07-29 20:00
EOF
)"
  FM_FAKE_DAEMON_DOWN=0
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" selanchorup
  out=$(run_crew_state "$d" selanchorup)
  assert_contains "$out" "source: run-step" "the selected anchored route binds with the daemon answering"
  assert_contains "$out" "state: working" "the anchored fix round still reads working"
  pass "the selected-run anchored continuation binds while the daemon answers"
}

# A coarse TERMINAL record whose daemon is down is degraded to unknown, and that
# is where it stops: the ledger row is head-tied, so its identity is PROVEN and
# it records a run that reached a terminal failure at this worktree's own head.
# A daemon dying afterwards does not unmake that outcome, so the reading must
# not become a claim that a human decision is pending.
test_coarse_failed_record_with_dead_daemon_reads_unknown() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-failed-supersede)
  make_repo_on_branch "$d/wt" fm/feat-cfs
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cfs.meta" "window=fm:fm-feat-cfs" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: approve the schema change\n' > "$d/state/feat-cfs.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  failed     fm/feat-cfs ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cfs
  out=$(run_crew_state "$d" feat-cfs)
  assert_contains "$out" "state: unknown" "a dead daemon degrades the terminal record to unknown"
  assert_contains "$out" "unverified" "the unverified record is named"
  assert_not_contains "$out" "state: parked" "a recorded terminal failure is never relabelled an open decision"
  pass "a coarse failed record with a dead daemon reads unknown"
}

# A probe that does not ANSWER proves nothing about the daemon, so it must not
# suppress a live rebased run: otherwise a slow `daemon status` on a busy fleet
# drops the crew back to a stale `failed:` log line, and the crew flaps between
# working and failed on probe latency alone.
test_unanswered_daemon_probe_does_not_suppress_live_run() {
  reset_fakes
  local d rebased out; d=$(new_case probe-timeout)
  make_repo_on_branch "$d/wt" fm/feat-probeto
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-probeto.meta" "window=fm:fm-feat-probeto" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'failed: earlier run failed\n' > "$d/state/feat-probeto.status"
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-probeto)
branch_sync:
  state: synced"
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_DAEMON_TIMEOUT=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-probeto
  out=$(run_crew_state "$d" feat-probeto)
  assert_contains "$out" "source: run-step" "an unanswered probe must not unbind the live run"
  assert_contains "$out" "state: working" "the live rebased run still reads working"
  assert_not_contains "$out" "state: failed" "the stale failed event must not answer on probe latency"
  pass "an unanswered daemon probe leaves a live rebased run bound"
}

# The coarse ledger row sits at this worktree's own head, so the head rule has
# already proven its identity and exempts it from the dead-instrument verdict:
# a dead daemon does not change what a head-tied row says about this crew.
test_coarse_live_row_is_exempt_from_the_dead_daemon_verdict() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-live-daemon-down)
  make_repo_on_branch "$d/wt" fm/feat-cldd
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cldd.meta" "window=fm:fm-feat-cldd" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-cldd.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  running    fm/feat-cldd ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_DAEMON_DOWN=1
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cldd
  out=$(run_crew_state "$d" feat-cldd)
  assert_contains "$out" "state: working" "a head-tied coarse row keeps its working reading"
  assert_not_contains "$out" "daemon unreachable" "the head rule exempts a head-tied record from the dead-instrument verdict"
  assert_not_contains "$out" "01RUN" "the foreign crew's run id is never offered as this crew's"
  pass "a head-tied coarse live row is exempt from the dead-daemon verdict"
}

# The coarse route carries no special reading for an open decision: a live row
# over a needs-decision tip keeps the pre-existing supersede note, and the crew
# reads working rather than awaiting a human.
test_coarse_live_row_keeps_the_original_supersede_note() {
  reset_fakes
  local d local_short out; d=$(new_case coarse-gate-signal)
  make_repo_on_branch "$d/wt" fm/feat-cg
  local_short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cg.meta" "window=fm:fm-feat-cg" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: review gate has an ask-user finding\n' > "$d/state/feat-cg.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  running    fm/feat-cg ${local_short}  2026-08-23 13:53
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-cg
  out=$(run_crew_state "$d" feat-cg)
  assert_contains "$out" "state: working" "a genuinely validating crew is not reported as awaiting a human"
  assert_contains "$out" "superseded by active run" "the coarse route keeps its original supersede note"
  pass "a coarse live row over an open decision keeps the original supersede note"
}

# Coarse negative control (axi answers another branch): a live row on the task's
# branch at a rebased head is not tied to this worktree by anything but the
# branch name, so the ledger must not answer for it and the older failed row
# must not answer either.
test_coarse_live_rebased_row_is_not_attributed() {
  reset_fakes
  local d rebased short out; d=$(new_case coarse-live-rebased)
  make_repo_on_branch "$d/wt" fm/feat-rebased2
  short=$(git -C "$d/wt" rev-parse --short=8 HEAD)
  rebased=$(make_rebased_head "$d/wt")
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-rebased2.meta" "window=fm:fm-feat-rebased2" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-rebased2.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-08-23 14:00
  running    fm/feat-rebased2 ${rebased}  2026-08-23 13:53
  failed     fm/feat-rebased2 ${short}  2026-08-23 12:09
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-rebased2
  out=$(run_crew_state "$d" feat-rebased2)
  assert_not_contains "$out" 'source: run-step' 'a branch-name-only live row must not bind'
  assert_not_contains "$out" 'state: failed' 'the older failed row must not answer either'
  assert_contains "$out" 'source: status-log' 'the status log answers without an attributable run'
  pass 'a coarse live row at a rebased head is not attributed'
}

# Negative control: once the rebased run has FAILED it is finished history on a
# head this worktree does not match, so it is not attributed and never reads as
# the task's failure.
test_terminal_rebased_run_is_not_attributed() {
  make_competing_runs_case terminal-rebased failed completed
  local d=$TMP_ROOT/terminal-rebased out rebased
  rebased=$(make_rebased_head "$d/wt")
  FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed "/01NEW/s/,[a-f0-9]*,\"\"\$/,$rebased,\"\"/")
  FM_FAKE_RUN_HEAD=$rebased
  FM_FAKE_AXI_STATUS="$(run_failed fm/competing | sed 's/01RUN/01NEW/')"
  FM_FAKE_AXI_STATUS_RUN=$FM_FAKE_AXI_STATUS
  fm_write_meta "$d/state/competing.meta" "window=fm:fm-competing" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: implementing\n' > "$d/state/competing.status"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" competing
  out=$(run_crew_state "$d" competing)
  assert_not_contains "$out" 'source: run-step' 'a terminal run on a diverged head is not attributed'
  assert_contains "$out" 'source: status-log' 'the status log answers when only a foreign terminal run exists'
  pass 'a terminal run at a diverged head keeps the strict head rule'
}

test_competing_live_runs_report_unknown_with_both_ids() {
  make_competing_runs_case ambiguous-runs running running
  local d=$TMP_ROOT/ambiguous-runs out
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01OLD/')"
  FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
  printf 'done: old completion event\n' > "$d/state/competing.status"
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'two live runs cannot establish exclusive authority'
  assert_contains "$out" '01NEW' 'ambiguity names the newer candidate'
  assert_contains "$out" '01OLD' 'ambiguity names the older candidate'
  pass 'competing live runs report unknown with both run ids'
}

test_newer_failed_run_is_not_hidden_by_older_live_run() {
  make_competing_runs_case newest-failed failed running
  local d=$TMP_ROOT/newest-failed out
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01OLD/')"
  FM_FAKE_AXI_STATUS_RUN="$(run_failed fm/competing | sed 's/01RUN/01NEW/')"
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: failed' 'the newer failed run must not be hidden by an older live run'
  assert_contains "$out" '01NEW' 'the genuine failure identifies its run'
  pass 'newer failed run remains failed beside an older live run'
}

test_unverifiable_run_selection_reports_unknown() {
  local mode rc=0
  for mode in missing wrong-id wrong-branch wrong-head missing-status malformed-table inventory-error selected-error; do
    (
      make_competing_runs_case "unverified-$mode" running cancelled
      d=$TMP_ROOT/unverified-$mode
      FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01OLD/')"
      FM_FAKE_AXI_STATUS_RUN="$(run_parked fm/competing | sed 's/01RUN/01NEW/')"
      case "$mode" in
        missing) FM_FAKE_AXI_STATUS_RUN='' ;;
        wrong-id) FM_FAKE_AXI_STATUS_RUN=$(printf '%s\n' "$FM_FAKE_AXI_STATUS_RUN" | sed 's/01NEW/01OLD/') ;;
        wrong-branch) FM_FAKE_AXI_STATUS_RUN=$(printf '%s\n' "$FM_FAKE_AXI_STATUS_RUN" | sed 's@fm/competing@fm/another-task@') ;;
        wrong-head)
          FM_FAKE_AXI_STATUS_RUN="$(FM_FAKE_RUN_HEAD=0123abcd run_parked fm/competing | sed 's/01RUN/01NEW/')"
          ;;
        missing-status) FM_FAKE_AXI_STATUS_RUN=$(printf '%s\n' "$FM_FAKE_AXI_STATUS_RUN" | sed '/status:/d') ;;
        malformed-table) FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's/runs\[2\]/runs[3]/') ;;
        inventory-error) FM_FAKE_AXI_HOME_ERROR=1 ;;
        selected-error) FM_FAKE_AXI_STATUS_RUN_ERROR=1 ;;
      esac
      out=$(run_crew_state "$d" competing)
      assert_contains "$out" 'state: unknown' "$mode selection must not assert a run state"
      assert_contains "$out" '01NEW' "$mode selection preserves the replacement id"
      assert_contains "$out" '01OLD' "$mode selection preserves the original id"
      pass "$mode run selection reports unknown with candidate ids"
    ) || rc=1
  done
  [ "$rc" = 0 ] || fail 'unverifiable run selections'
}

test_legacy_conflicting_run_records_report_unknown() {
  make_competing_runs_case legacy-conflict failed running
  local d=$TMP_ROOT/legacy-conflict out
  FM_FAKE_AXI_STATUS="$(run_running fm/competing | sed 's/01RUN/01OLD/')"
  FM_FAKE_AXI_HOME=$FM_FAKE_AXI_STATUS
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'conflicting records without identities cannot prove authority'
  assert_contains "$out" '01OLD' 'legacy ambiguity preserves the available run id'
  assert_contains "$out" 'unavailable' 'legacy ambiguity states that the competing id is unavailable'
  pass 'legacy conflicting run records report unknown'
}

# Captured AXI stdout is a serialized input contract, not implementation source.
# Only the run identity is rebound to each disposable git repository; status,
# outcome, steps, findings, and gate bytes stay as emitted. The capture README
# distinguishes genuine histories from deliberately composed scenarios.
captured_axi_status() {  # <capture> [branch] [run-id]
  awk -v branch="${2:-fm/competing}" -v id="${3:-01NEW}" -v head="$FM_FAKE_RUN_HEAD" '
    /^  id:/ { print "  id: \"" id "\""; next }
    /^  branch:/ { print "  branch: " branch; next }
    /^  head:/ { print "  head: " head; next }
    /^  head_sha:/ { print "  head_sha: " head; next }
    { print }
  ' "$ROOT/tests/captures/no-mistakes-v1.70.1/$1.toon"
}

test_captured_axi_status_shapes() {
  local shape status expected d out toolbin
  for shape in replacement parked failed; do
    status=running; expected=working
    case "$shape" in parked) expected=parked ;; failed) status=failed; expected=failed ;; esac
    make_competing_runs_case "captured-$shape" "$status" cancelled
    d=$TMP_ROOT/captured-$shape
    FM_FAKE_AXI_STATUS=$(captured_axi_status superseded fm/competing 01OLD)
    FM_FAKE_AXI_STATUS_RUN=$(captured_axi_status "$shape")
    # A newer failure must remain visible even with an older live record.
    if [ "$shape" = failed ]; then
      FM_FAKE_AXI_HOME=$(printf '%s\n' "$FM_FAKE_AXI_HOME" | sed 's/,cancelled,/,running,/')
      FM_FAKE_AXI_STATUS=$(captured_axi_status replacement fm/competing 01OLD)
    fi
    out=$(run_crew_state "$d" competing)
    assert_contains "$out" "state: $expected" "captured $shape status is understood"
    assert_contains "$out" '01NEW' "captured $shape preserves the selected identity"
    if [ "$shape" = parked ]; then
      assert_contains "$out" 'parked at test: 1 finding(s)' 'the captured gate retains its actual step and finding count'
      assert_contains "$out" ' · ask-user: authority decision' \
        'the captured gate mints the human-decision component from the real column layout'
      toolbin=$(make_no_python_toolbin "$d")
      out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
      assert_contains "$out" 'parked at test: 1 finding(s)' 'a complete captured gate remains readable without Python'
      assert_contains "$out" ' · ask-user: authority decision' \
        'the captured gate mints the human-decision component without Python'
      assert_contains "$out" '01NEW' 'the captured gate retains its id without Python'
    fi
    pass "captured AXI $shape status replays through crew-state"
  done
}

test_captured_inventory_replay() {
  make_capped_runs_case captured-inventory running cancelled
  local d=$TMP_ROOT/captured-inventory out before after branch newer older toolbin
  branch=fm/fm-bearings-board-loses-owner-state-and-links
  newer=01M2GAWMSDQK4B5EA9GZW35RXE
  older=01M20MQ02N69VJKXW9N8321SQW
  git -C "$d/wt" checkout -q -b "$branch"
  python3 - "$NM_HOME/state.sqlite" "$ROOT/tests/captures/no-mistakes-v1.70.1/same-branch-inventory.json" <<'PY'
import json
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("DELETE FROM runs")
    db.executemany("INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)", [
        (r["id"], "repo", r["branch"], r["status"], r["head_sha"], r["created_at"])
        for r in json.load(open(sys.argv[2]))
    ])
PY
  FM_FAKE_AXI_HOME="repo: $d/wt
$(cat "$ROOT/tests/captures/no-mistakes-v1.70.1/overview.toon")"
  FM_FAKE_AXI_STATUS=$(captured_axi_status superseded "$branch" 01M2FNFPK984YP0EHFTD1XEF8P)
  FM_FAKE_AXI_STATUS_RUN=$(captured_axi_status replacement "$branch" "$newer")
  before=$(git hash-object "$NM_HOME/state.sqlite")
  out=$(run_crew_state "$d" competing)
  after=$(git hash-object "$NM_HOME/state.sqlite")
  assert_contains "$out" 'state: working' 'the recorded live successor outranks its superseded cancellation'
  assert_contains "$out" "$newer" 'the recorded successor keeps its real run id'
  [ "$before" = "$after" ] || fail 'captured inventory replay wrote to the database'
  assert_not_contains "$FM_FAKE_AXI_HOME" "$older" 'the competing candidate is outside the real overview window'
  # Counterfactual, not a recorded competing-live history: revive one hidden
  # cancelled row, keeping its captured id, branch, head, and creation order.
  python3 - "$NM_HOME/state.sqlite" "$older" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE runs SET status = 'running' WHERE id = ?", (sys.argv[2],))
PY
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'a hidden counterfactual live competitor prevents selection'
  assert_contains "$out" "$newer" 'captured ambiguity retains the visible id'
  assert_contains "$out" "$older" 'captured ambiguity retains the hidden id'
  toolbin=$(make_no_python_toolbin "$d")
  out=$(PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" "$CREW_STATE" competing)
  assert_contains "$out" 'state: unknown' 'missing optional lookup cannot imply exclusive authority'
  assert_contains "$out" "$newer" 'unavailable lookup retains the captured visible id'
  assert_contains "$out" 'inventory' 'unavailable lookup reports its evidence gap'
  pass 'captured capped inventory replays selection, ambiguity, and unavailable lookup'
}

test_captured_authority_transition() {
  make_competing_runs_case captured-transition running cancelled
  local d=$TMP_ROOT/captured-transition out
  FM_FAKE_AXI_STATUS=$(captured_axi_status replacement)
  FM_FAKE_AXI_STATUS_RUN=$(captured_axi_status superseded)
  out=$(run_crew_state "$d" competing)
  assert_contains "$out" 'state: unknown' 'captured terminal output cannot validate a live selection'
  assert_contains "$out" '01NEW' 'the changing selected id is preserved'
  assert_contains "$out" '01OLD' 'the other available id is preserved'
  pass 'captured status formats reject a synthetic authority transition'
}

test_captured_completed_history() {
  local activity d out source
  for activity in busy idle; do
    make_historical_inventory_case "captured-history-$activity" "$activity"
    d=$TMP_ROOT/captured-history-$activity
    FM_FAKE_AXI_STATUS=$(captured_axi_status completed)
    FM_FAKE_AXI_STATUS_RUN=$FM_FAKE_AXI_STATUS
    source=pane; [ "$activity" = busy ] || source='status-log'
    out=$(run_crew_state "$d" competing)
    assert_contains "$out" 'state: working' 'captured completion does not hide subsequent development'
    assert_contains "$out" "source: $source" 'captured historical validation yields to current worker evidence'
  done
  pass 'captured completed status yields to synthetic subsequent development'
}

test_captured_axi_status_shapes
test_captured_inventory_replay
test_captured_authority_transition
test_captured_completed_history
test_active_run_is_authoritative
test_stale_needs_decision_superseded
test_stale_blocked_superseded
test_daemon_claim_over_live_run_reads_run_alive
test_socket_refusal_over_stale_fixing_run_reports_blocked
test_socket_refusal_over_terminal_run_reports_blocked
test_socket_refusal_override_expires_when_the_crew_moves_on
test_ordinary_blocked_over_live_run_keeps_plain_superseded
test_genuine_daemon_down_reports_blocked
test_secondmate_open_block_survives_unrelated_append
test_newest_open_decision_supplies_the_reported_detail
test_single_owner_terminal_declaration_supersedes_stale_decision
test_latest_status_preserves_legacy_completions
test_latest_status_subshell_work_does_not_grow_with_history
test_genuine_parked_not_superseded
test_parked_human_decision_comes_from_the_action_column
test_scalar_gate_parked_not_superseded
test_gate_block_parked_not_superseded
test_ci_ready_done_log_beats_monitoring_run
test_ci_monitoring_checks_green_surfaces_done
test_top_level_ci_checks_green_surfaces_done
test_ci_monitoring_no_checks_terminal_surfaces_done
test_ci_monitoring_green_then_rearm_stays_green
test_ci_monitoring_green_before_log_tail_stays_green
test_ci_monitoring_no_checks_yet_stays_working
test_ci_monitoring_still_waiting_stays_working
test_ci_monitoring_green_then_new_issue_stays_working
test_ci_ready_done_log_relapse_stays_working
test_ci_fixing_after_green_stays_working
test_top_level_fixing_ci_running_after_green_stays_working
test_top_level_fixing_done_log_stays_working
test_terminal_passed
test_terminal_passed_with_override
test_terminal_passed_with_skips
test_terminal_passed_uses_matching_retirement_receipt_without_forge
test_terminal_passed_no_forge_switch_skips_read_but_keeps_receipt
test_terminal_passed_with_open_pr_does_not_claim_merged
test_terminal_passed_run_pr_overrides_stale_metadata
test_terminal_passed_without_readable_pr_identity_reports_unknown
test_terminal_passed_with_open_gitlab_mr_does_not_claim_merged
test_terminal_passed_with_merged_gitlab_mr_reports_merged
test_terminal_passed_with_failed_gitlab_read_reports_unknown
test_terminal_failed
test_terminal_failed_ci_orphan_after_green_reads_done
test_terminal_failed_ci_orphan_status_only_reads_done
test_terminal_failed_ci_genuine_red_stays_failed
test_terminal_failed_ci_orphan_second_failed_step_stays_failed
test_cross_branch_attribution_via_runs_list
test_coarse_socket_refusal_reports_blocked
test_coarse_failed_ledger_with_daemon_down_reports_unknown
test_cross_branch_attribution_picks_most_recent_row
test_terminal_run_keeps_newer_failure_over_live_sibling
test_runs_list_newer_failure_outranks_older_live_row
test_unfetched_older_live_sibling_does_not_hide_failure
test_only_terminal_rows_keep_newest_first_precedence
test_unknown_status_row_keeps_newest_first_precedence
test_terminal_run_without_live_sibling_is_unchanged
test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status
test_other_branch_run_ignored
test_unpushed_ship_done_is_blocked
test_merged_pr_reads_done_under_captured_meta
test_no_mistakes_prevalidation_done_stays_done
test_moved_remote_branch_without_named_head_is_blocked
test_no_run_busy_pane
test_no_run_launch_prompt_parked_is_not_working
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
test_coarse_terminal_row_at_foreign_head_not_attributed
test_executing_run_binds_without_pipeline_owned_sync
test_non_pipeline_owned_parked_unresolvable_head_not_attributed
test_gate_parked_run_with_live_status_word_not_attributed
test_pipeline_owned_terminal_run_not_exempt
test_missing_run_head_falls_back_to_current_state
test_active_fix_round_unfetched_pipeline_head_reports_current
test_unanchored_unfetched_active_row_still_binds
test_unresolved_terminal_row_is_history_not_current
test_runs_list_continuation_found_when_axi_answers_other_branch
test_no_run_herdr_stale_registration_over_shell_reads_agent_gone
test_no_run_herdr_stale_working_record_is_never_busy
test_capped_competing_live_runs_report_both_ids
test_capped_overview_without_branch_rows_reports_both_ids
test_capped_overview_with_no_branch_runs_reports_absent
test_no_branch_run_beside_a_live_run_elsewhere_reads_absent
test_capped_inventory_reader_is_time_bounded
test_capped_inventory_requires_exact_repo_path
test_linked_worktree_green_merge_monitoring_reads_held_for_merge
test_capped_replacement_keeps_gate_and_inventory_unchanged
test_capped_inventory_failures_report_unknown
test_complete_inventory_ignores_unrelated_semantics
test_requested_branch_has_no_character_whitelist
test_capped_inventory_ignores_unrelated_semantics
test_capped_requested_semantics_do_not_hide_ids
test_capped_requested_branch_with_comma_names_both_ids
test_inventory_structure_and_requested_semantics_remain_checked
test_complete_inventory_without_python_keeps_gate
test_complete_ambiguity_without_python_names_both_ids
test_capped_without_python_preserves_available_ids
test_capped_without_sqlite_preserves_available_ids
test_live_to_terminal_inventory_disagreement_is_unknown
test_uninitialized_busy_worker_uses_pane
test_uninitialized_idle_worker_uses_status
test_historical_inventory_uses_current_pane
test_historical_inventory_uses_current_status
test_superseded_cancelled_run_preserves_replacement_gate
test_live_rebased_run_beats_older_failed_run_at_local_head
test_live_rebased_run_reads_working_for_every_executing_status
test_legacy_live_rebased_run_is_authoritative
test_legacy_surface_binds_fixing_and_ci_at_a_rebased_head
test_live_record_at_diverged_head_does_not_bind_an_unproven_record
test_unproven_record_with_dead_daemon_does_not_override_a_busy_pane
test_coarse_live_row_over_ordinary_blocked_keeps_superseded_reading
test_socket_refused_log_survives_the_dead_daemon_verdict
test_ordinary_blocked_tip_survives_the_dead_daemon_verdict
test_parked_gate_survives_a_dead_daemon
test_selected_run_diverged_head_does_not_bind_an_unproven_record
test_live_record_at_diverged_head_binds_while_daemon_answers
test_anchored_continuation_binds_while_daemon_answers
test_unverified_coarse_record_makes_no_supersede_claim
test_coarse_failed_record_with_dead_daemon_reads_unknown
test_selected_run_anchored_continuation_needs_a_live_daemon
test_selected_run_anchored_continuation_binds_while_daemon_answers
test_selected_run_anchored_parked_keeps_its_gate_with_a_dead_daemon
test_selected_run_dead_daemon_leaves_the_open_decision_open
test_coarse_pending_ledger_word_reads_unknown
test_unanswered_probe_does_not_turn_a_failed_coarse_record_into_a_gate
test_selected_route_dead_daemon_names_the_run_once
test_head_tied_row_reads_the_same_whichever_run_axi_names
test_coarse_head_tied_row_is_exempt_even_when_the_record_head_diverged
test_unrecognised_ledger_word_keeps_the_ordinary_supersede_note
test_unanswered_daemon_probe_does_not_suppress_live_run
test_coarse_live_row_is_exempt_from_the_dead_daemon_verdict
test_coarse_live_row_keeps_the_original_supersede_note
test_coarse_live_rebased_row_is_not_attributed
test_terminal_rebased_run_is_not_attributed
test_competing_live_runs_report_unknown_with_both_ids
test_newer_failed_run_is_not_hidden_by_older_live_run
test_unverifiable_run_selection_reports_unknown
test_legacy_conflicting_run_records_report_unknown

echo "all fm-crew-state tests passed"
