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
#   (d3) cancelled green deliveries retain done, skipped rebase is allowed;
#       other cancellations read unknown without a false fleet contradiction
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
  cat > "$fb/gerrit-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  show)
    [ -z "${FM_FAKE_GERRIT_READ_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_GERRIT_READ_LOG"
    [ "${FM_FAKE_GERRIT_READ_FAIL:-0}" = 1 ] && exit 1
    # url defaults to null, the shape a server whose gerrit.canonicalWebUrl is
    # unset returns, so every case here reads a record that carries no URL.
    printf '{"ok":true,"op":"show","changes":[{"change":%s,"subject":"fixture change","status":"%s","url":%s}]}\n' \
      "${FM_FAKE_GERRIT_CHANGE:-${2:-0}}" "${FM_FAKE_GERRIT_STATUS:-MERGED}" \
      "${FM_FAKE_GERRIT_URL_JSON:-null}"
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
  chmod +x "$fb/no-mistakes" "$fb/gh" "$fb/gh-axi" "$fb/glab" "$fb/gerrit-axi" "$fb/tmux" "$fb/herdr"
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
  FM_FAKE_GERRIT_STATUS=MERGED
  FM_FAKE_GERRIT_CHANGE=
  FM_FAKE_GERRIT_URL_JSON=
  FM_FAKE_GERRIT_READ_FAIL=0
  FM_FAKE_GERRIT_READ_LOG=
  unset FM_FAKE_PR_47_STATE FM_FAKE_PR_47_MERGED FM_FAKE_PR_48_STATE FM_FAKE_PR_48_MERGED
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_BUSY FM_FAKE_BUSY_TEXT FM_FAKE_TMUX_MISSING FM_FAKE_TMUX_UNREADABLE
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_READ_FAIL FM_FAKE_HERDR_HUSK FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_HERDR_PROCESS FM_FAKE_HERDR_SHELL_PID FM_FAKE_CI_LOGS
  export FM_FAKE_DAEMON_DOWN FM_FAKE_DAEMON_TIMEOUT FM_FAKE_DAEMON_PROBE_LOG FM_FAKE_AXI_HOME
  export FM_FAKE_AXI_HOME_ERROR FM_FAKE_AXI_STATUS_RUN_ERROR FM_FAKE_AXI_STATUS_ERROR
  export FM_FAKE_PR_STATE FM_FAKE_PR_MERGED FM_FAKE_PR_READ_FAIL FM_FAKE_PR_READ_LOG FM_FAKE_PR_STATE_AXI
  export FM_FAKE_GLAB_STATE FM_FAKE_GLAB_READ_FAIL FM_FAKE_GLAB_READ_LOG
  export FM_FAKE_GERRIT_STATUS FM_FAKE_GERRIT_CHANGE FM_FAKE_GERRIT_URL_JSON
  export FM_FAKE_GERRIT_READ_FAIL FM_FAKE_GERRIT_READ_LOG
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

# (b) needs-decision log + a resumed (running/fixing) run = SUPERSEDED

# blocked log + a resumed run is also superseded

# A crew whose drive call timed out or was killed by its harness command limit
# routinely blocks claiming the pipeline died. The daemon accepts `respond`
# immediately and runs the fix round in the background, so such a claim over a
# run that is fixing WITH fresh activity is contradicted by the run itself: the
# supervisor answer is to steer a reattach, not to escalate a dead pipeline.

# A genuine refused socket outranks the persisted fixing record, which can
# survive after the daemon exits.

# A terminal run record can be the final persisted state after the daemon exits.
# Positive socket-failure evidence must not be discarded merely because that
# attributed record no longer has an active status.

# The socket-down override is evidence about the log's CURRENT tip, not a latch:
# once the crew appends any later event the attributed run is the better witness.

# And the claim half: an ordinary blocked line over the same live run keeps the
# generic reading, so the sharper one cannot fire on every superseded block.

# The genuine daemon-down case still reaches the supervisor as blocked: the
# socket refused connections and no run is executing anywhere.

# (c) genuine parked run + needs-decision log AGREE -> parked, NOT superseded

# Which HUMAN owes a parked gate its answer is the distinction the watcher's
# wedge deferral rests on, so the component that carries it must come from the
# findings table's `action` column and from nothing else. Both directions, plus
# the counterexample a text match would have accepted.




# Regression for the PR #252 incident: the crew's own status log never got a
# "done: ... checks green" line (log_reports_ci_ready above does not apply),
# but the ci step's log shows CI is actually green and only waiting on
# merge/close. fm-crew-state must surface this as done, not "validating
# (running)", so a green PR is never silently absorbed as still-in-progress.



# The monitor logs a checks state only when it changes, and a base-branch
# advance re-arms only its idle timeout, so a green PR on a busy base ends its
# ci log with re-arm lines (the 2026-09-22 PR #5317 shape: green, then main
# advanced while it waited for merge). The green marker before them is current.

# The same green-then-re-arm shape, but monitored long enough that the base
# advanced past the CLI's 40-line log tail: `axi logs` without --full would
# answer with re-arm lines only, hiding the green marker entirely, and the
# green PR would read as still working for as long as main kept moving.



# A later merge-conflict auto-fix round after an earlier green reading must
# not be masked: the MOST RECENT marker in the ci log wins.





# (d) terminal run-step is authoritative















# Recovered delivery cases, varying only the terminal route and the optional
# rebase step. The already-fixed passed-run case remains a control.


# Cancellation carries no verdict without the positive delivery safeguard.
# Exercise both detailed routes, selected-run attribution, and the coarse ledger.

# The real inventory consumer must not confuse a cancellation with a failed
# child contradicting an In flight row. Unknown remains explicitly partial.

# Replay the recorded producer output through both public consumers, without
# starting or aborting a daemon run or claiming live cancellation evidence.





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

# The runs list is newest-first; a branch with an OLDER completed run must not
# shadow its own newer active one - the first (topmost) matching row wins.

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


# The plain ledger is ordered by creation time, not the time a status changed.
# A newer failure must not be hidden by an older live run, even when both heads
# bind to the worktree. These legacy CLI cases lack the AXI identity table.

# The same creation-order rule on the runs-list path itself: `axi status` answers for
# another crew's branch, and this branch's newest row is terminal while an older
# row is still live.

# An unfetched head on the older live row does not change creation order.
# Exact-head compatibility of the newer terminal row is not supersession proof.

# The preference must not widen: candidates of the SAME liveness class keep the
# listing's existing newest-first precedence, so two terminal rows still resolve
# to the newer one rather than to whichever the scan happens to reach last.

# An unclassifiable status word keeps the ledger's own newest-first precedence:
# the creation-order preference must preserve a status whose liveness is
# unknown, so an unexpected newest row is answered as-is instead of being
# displaced by an older running row and reported as working.

# The other half of the no-widening criterion: a terminal `axi status` run with
# no live sibling on this worktree keeps reporting its own terminal outcome, in
# full run-step detail rather than degraded to the coarse listing.


# A different-branch run with NO matching runs-list row must NOT be
# misattributed, and must not be treated as a false "working" verdict either.

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
    "kind=ship" "mode=direct-PR" "harness=claude"
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

# The same for an active run: an agent pane that crashed mid-validation while the
# daemon-backed run continues must report the live run-step, not unknown.


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
  assert_not_contains "$out" "source: pane" "scout ignores no-mistakes run-step"
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

# Head-binding: an active pipeline whose run head is a descendant of the local
# tip (fix commits on the same history) remains current.

# Head-binding: local work that advanced past the run head invalidates the run.

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

# T1 direction 2: a genuinely-failed run with NO later run on the branch still
# surfaces as failed - hiding real failures is equally wrong.

# The coarse runs-list rows: the branch's newest row is ACTIVE at an
# unresolvable head and the row immediately before it ended at exactly this
# worktree's head - the ledger proves this is this crew's own pipeline-owned
# fix round (axi status answers another branch here, so attribution can only
# go through the coarse list). The anchored active run answers via the
# run-step, and the older failed row never surfaces.

# Coarse negative control: the anchor must end at EXACTLY this worktree's
# head. The newest same-branch row is active at an unresolvable head, but the
# row immediately before it sits at an OLDER local commit, so the ledger
# proves nothing - unknown attribution stops the scan, never falls to the
# older failed row, and the busy pane answers instead.

# The same ledger with the newest row TERMINAL keeps the strict rule: a finished
# run on a diverged head is history, not this worktree's current run.

# An EXECUTING run on the task's branch binds whatever branch_sync says and
# whatever its head, so the pipeline_owned exemption is no longer the only way a
# live run with an unresolvable lane head is attributed.

# Negative control: a run PARKED at a gate keeps the strict head rule, so a
# non-pipeline_owned parked run at an unresolvable head is not attributed. The
# ledger carries a live same-branch row at that same unresolvable head - the
# coarse fallback must not revive the rejected run's gate detail through it,
# because a bare `running` row cannot tell working from waiting at a gate.

# The CLI leaves the top-level `status:` word at `running` while a run WAITS at
# a gate, so the word alone cannot decide "executing". A gate-parked run at an
# unresolvable head, on a branch the pipeline has released, must keep the strict
# head rule in both gate shapes - otherwise the crew reports a stale
# `parked at <gate>` from a run whose code identity was never verified.

# Negative control: the exemption also requires an ACTIVE run - a terminal run
# released the branch, so an inconsistent pipeline_owned label must not bind a
# terminal run by branch name alone.


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

# A live run on the task's branch is authoritative regardless of head, so an
# active row with an unverifiable head binds even when the ledger cannot anchor
# it to this worktree's head: the older row and the historical status-log
# `failed:` event never answer for the live run.

# Negative control: a TERMINAL row whose commit object is gone from the task
# copy is history even when it is the branch's newest row - an ancient or
# rewritten run whose commit was pruned must never read as current state.

# The same continuation recognition must work when bare `axi status` answers
# with ANOTHER branch's run: this branch's own active run is then visible only
# in the ledger, with coarse (status-word) detail.

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



# A branch with zero rows anywhere in a capped overview must read as
# truthfully absent, not as an unreadable table: the rebuilt zero-row
# inventory re-parses as `runs[0]`.

# The same capped shape, but reached through the code path that actually
# consumes the same-branch selection: fm-crew-state only consults the overview
# once `axi status` answers with a run, so a branch of its own with no run at
# all is only reported while SOME run exists elsewhere. Pre-fix this read
# `unknown - complete same-branch run inventory unreadable`, which is the
# healthy-home-reports-itself-untrustworthy symptom.

# The capped-overview sqlite reader runs inside the same per-read budget as
# every other no-mistakes state read, so a contended database cannot stall a
# crew poll: a reader that never returns must be killed and fall through to the
# reader-unavailable verdict.

# Repo identity is the overview's own `repo:` line matched exactly against the
# recorded `working_path`; a spelling the inventory does not record is not
# guessed at, and reads as an unreadable inventory that still names every
# candidate run id.

# The 2026-09-22 PR #5317 shape on no-mistakes v1.79.0. A task copy is a linked
# git worktree of its home clone, and the CLI registers the repository once, by
# the clone's path, which the overview reports as `repo:`. Past ten runs the
# overview is capped, so selection goes through the inventory reader, which must
# key on that `repo:` line: keyed on the task worktree path it matched no row and
# every read reported the inventory unreadable. The run is in ci merge
# monitoring with every check green, and main advanced while it waited for the
# merge, so its ci log ends in re-arm lines. It must read as a green PR held for
# the merge decision, naming the PR, rather than unknown or still validating.



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

# The same live run reads working for every EXECUTING status word the CLI can
# actually deliver here. `fm_nm_select_run` validates the overview status column
# against pending|running|completed|failed|cancelled, so those are the only live
# words that reach the predicate; the overview and the id-addressed detail read
# the same runs.status column, so the fixture carries one word in BOTH surfaces.

# The LEGACY bare-status surface carries run-level `fixing` and `ci`, which the
# overview table's vocabulary does not include. The selector never validates a
# word there (it answers `unavailable` with no table), so those runs are the
# crew's own live run and must bind at a rebased head like any other.

# Legacy CLI surface (no overview table): the bare `axi status` run is live on
# this branch with a rebased head, while the runs ledger still holds an older
# failed row at the local head.

# The head-free route is licensed by the daemon being reachable. Once the daemon
# answers down AND no ledger row anchors the run, nothing ties the record to this
# worktree at all, so it stops answering and the status log takes over.

# A run PARKED at a gate keeps its gate and findings when the daemon dies. The
# ledger word stays `running` while a run waits (parked.toon), so classifying
# off the ledger would relabel an open decision as a dead live record and the
# findings would never reach the supervisor.

# The modern selected-run route reaches the same diverged-head shape: the run
# head RESOLVES but diverged after the pipeline rebased, and no ledger row
# anchors it, so identity is unproven and the record must not answer at all.

# The crew observed the refused socket itself. The ledger anchor BINDS a record
# here and the dead daemon makes it unverified, so this drives the dead-daemon
# verdict directly - and the blocker must still outrank it.

# The selected route's anchored shape with an ORDINARY blocker: the header rule
# says a blocked tip stays blocked with the unverified record named, and nothing
# else reaches that path with a `blocked:` tip.


# A visibly working crew must never be overridden by a stale record that merely
# names its branch. Identity is proven by neither head nor ledger anchor here,
# so the busy pane answers - the base behaviour before the daemon guard existed.

# Only a gate is ambiguous under a coarse live row. An ordinary blocker keeps the
# pre-existing reading, exactly as it does on the full route.

# The head-free route still binds while the daemon answers: the daemon probe
# narrows the zombie case only, it does not undo the rebase fix.


# Same anchored shape with the daemon answering: the guard narrows the dead
# instrument only, the unfetched-head fix round still binds.

# A record that just declared itself unverified cannot also declare an open
# decision superseded.

# The modern selected-run route reaches the anchored-continuation rule through
# its own `elif` (the run head is not an object in this copy). That route binds
# on ledger evidence which proves IDENTITY, not liveness, so the daemon rule
# has to hold there too.

# The selected route honours the parked exemption too: an anchored PARKED run
# with a dead daemon keeps its gate and findings, exactly as the legacy route
# does on the same evidence.

# An open decision outranks the unverified record on the selected route as well.
# The ledger anchor binds the run here, so the dead-daemon verdict is genuinely
# produced and the reconciliation is what keeps the decision visible.

# A probe that did not ANSWER proves nothing, so it must not hand the verdict to
# a stale open decision: a genuinely failed run would be reported as awaiting a
# human on probe latency alone. The record still degrades to unknown, which is
# ambiguous but not falsely actionable.



# The selected route already appends `run: <id>` to every ordinary verdict, so
# the dead-daemon detail must not carry its own copy.

# The same run, the same head, the same dead daemon must read the same way
# whichever run the shared daemon's bare `axi status` happens to name - that is
# routine once several crews validate one repo. The ledger row sits at this
# worktree's own head, so the head rule exempts it either way.

# The record's head and the ledger row's head are INDEPENDENT. A same-branch
# record whose own head diverged still reaches the coarse fallback, where the
# newest ledger row can sit at this worktree's own head - a head-tied row the
# head rule exempts. The coarse route carries no dead-daemon verdict, so that
# row keeps its working reading.

# An unrecognised ledger word yields an unknown verdict from a LIVE daemon, so it
# is not an unverified record: the ordinary supersede note applies, as it did
# before the coarse-unknown special case existed.

# The coarse ledger word `pending` is not an acceptance: it keeps its unknown
# reading rather than claiming the crew is validating.

# The same anchored selected-run shape with the daemon answering still binds.

# A coarse TERMINAL record whose daemon is down is degraded to unknown, and that
# is where it stops: the ledger row is head-tied, so its identity is PROVEN and
# it records a run that reached a terminal failure at this worktree's own head.
# A daemon dying afterwards does not unmake that outcome, so the reading must
# not become a claim that a human decision is pending.

# A probe that does not ANSWER proves nothing about the daemon, so it must not
# suppress a live rebased run: otherwise a slow `daemon status` on a busy fleet
# drops the crew back to a stale `failed:` log line, and the crew flaps between
# working and failed on probe latency alone.

# The coarse ledger row sits at this worktree's own head, so the head rule has
# already proven its identity and exempts it from the dead-instrument verdict:
# a dead daemon does not change what a head-tied row says about this crew.

# The coarse route carries no special reading for an open decision: a live row
# over a needs-decision tip keeps the pre-existing supersede note, and the crew
# reads working rather than awaiting a human.

# Coarse negative control (axi answers another branch): a live row on the task's
# branch at a rebased head is not tied to this worktree by anything but the
# branch name, so the ledger must not answer for it and the older failed row
# must not answer either.

# Negative control: once the rebased run has FAILED it is finished history on a
# head this worktree does not match, so it is not attributed and never reads as
# the task's failure.





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





test_unpushed_ship_done_is_blocked
test_merged_pr_reads_done_under_captured_meta
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
test_scout_skips_run_lookup
test_torn_down_worktree
test_remote_alive_with_log_uses_status_log
test_remote_alive_idle_is_healthy_not_gone
test_remote_unreachable_is_unknown_remote_not_dead
test_remote_dead_reports_remote_verdict
test_missing_meta
test_not_provably_working_when_stopped
test_usage_error
test_no_run_herdr_stale_registration_over_shell_reads_agent_gone
test_no_run_herdr_stale_working_record_is_never_busy

echo "all fm-crew-state tests passed"
