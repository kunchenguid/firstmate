#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed under bin/fm-nm-run-lib.sh's contract, else
# the pane busy-signature) and reconciles the possibly-stale log against it.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|remote-endpoint|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta. A meta
#      recording remote_host= is a remote secondmate: its worktree and endpoint
#      live on that host, so the local worktree and pane reads are skipped and
#      the remote host is asked for the endpoint's recovery-grade state
#      (fm-on.sh + fm-remote-secondmate-control.sh state). alive falls through
#      to the routed status log; dead/missing report the remote verdict; an
#      unreachable or unreadable remote reports unknown-remote, never a false
#      gone/dead.
#   2. Matching no-mistakes run for this crew's branch AND current code identity,
#      active or terminal (from `axi status`, or the coarse `no-mistakes runs`
#      fallback)? Branch name alone is not enough: a historical run on a reused
#      branch whose head was rewritten or diverged must not be attributed.
#      A run matches when its head equals the worktree HEAD, or the worktree HEAD
#      is an ancestor of the run head (pipeline fix commits advanced the run on
#      the same line of history). Local work that advanced past the run head, or
#      diverged from it, invalidates attribution. While the pipeline owns the
#      branch (branch_sync.state=pipeline_owned), its own custody attribution
#      binds an ACTIVE run without head equality (fm_nm_run_is_pipeline_owned_active
#      in bin/fm-nm-run-lib.sh).
#      A run head whose commit object the task copy never fetched (the pipeline
#      committed its fix round in its own checkout) cannot be verified locally;
#      that row is recognized only as a provable pipeline-owned continuation -
#      the branch's ACTIVE newest ledger row, anchored by the row immediately
#      before it having ended at exactly this worktree's head - so an active fix
#      round never reads as an older failed run (rule owned by
#      fm_nm_runs_status_for_worktree in bin/fm-nm-run-lib.sh).
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see nm_ci_checks_state) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating.
#   2b. A TERMINAL FAILED reading (failed/cancelled) is authoritative only while
#      nothing newer contradicts it, because head identity binds whatever run
#      last sat on this head, not necessarily this branch's current one - and a
#      stale failure here is promoted into a captain-facing terminal outcome by
#      bin/fm-inactive-reconcile.sh. Three records may outrank it: a later run
#      the ledger PROVES is current (answering from that run), a later
#      self-declared pause or done in the status log that the ledger's date
#      proves post-dates the failed run by clearing its whole minute, and finally
#      a later run on this branch that cannot be bound here (reported as unknown
#      - history, but no proof of the present). Because the ledger has no run ID,
#      an equal head does not identify a rerun; a terminal row supplies newer
#      truth when its observable
#      status, head, or PR differs, or when the state came from the coarse
#      fallback. Nothing else does, and with no ordering evidence the failure
#      stands, so a real failure is never hidden. Independently of outcome, a
#      terminal reading publishes a PR only when the current-run evidence still
#      attributes that reading; otherwise it publishes none.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this crew (pre-validation, or kind=scout): fall back to the
#      recorded backend's pane busy state, then the status log's last line only
#      when its verb maps to a recognized run-state. Decision-only events such as
#      `resolved` never become current state or detail.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

# Fleet snapshot composition supplies its captured metadata path here so every
# state read resolves the same task generation selected by that snapshot.
META=${FM_CREW_STATE_META_OVERRIDE:-"$STATE/$ID.meta"}
LOG=${FM_CREW_STATE_STATUS_OVERRIDE:-"$STATE/$ID.status"}
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (fm_nm_runs_status_for_worktree in bin/fm-nm-run-lib.sh) scans. Generous
# enough to still find a branch's own run on a busy multi-crew fleet without
# listing the entire history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

emit_run() {  # <state> <detail> [pr]
  local detail=$2
  case "$1" in
    done|failed) [ -z "${3:-}" ] || detail="$detail${SEP}pr=$3" ;;
  esac
  emit "$1" run-step "$detail"
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
HARNESS=$(meta_value harness)
REMOTE_HOST=$(meta_value remote_host)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read. A
# remote secondmate's recorded worktree is a path on ITS host, so the local
# probe proves nothing for it - the remote arm below reads the true source.
if [ -z "$REMOTE_HOST" ] && { [ -z "$WT" ] || [ ! -d "$WT" ]; }; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line; fm-classify-lib.sh owns leading-verb normalization.
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the deliberate-external-wait verb (fm-classify-lib.sh's FM_CLASSIFY_PAUSED_VERB):
# a crew with no active run and an idle pane that declared a known external wait
# reports `paused` distinctly, so a supervisor reading this sees a declared pause
# and its reason rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(status_line_verb "$LOG_LINE")

snapshot_ordered_log() {
  local before_mtime before_size before_ident line after_mtime after_size after_ident
  ORDERED_LOG_LINE=
  ORDERED_LOG_MTIME=
  [ -f "$LOG" ] || return 1
  before_mtime=$(_fm_status_file_mtime "$LOG") || return 1
  before_size=$(_fm_status_file_size "$LOG") || return 1
  before_ident=$(_fm_open_decisions_file_ident "$LOG") || return 1
  line=$(log_last_line || true)
  after_mtime=$(_fm_status_file_mtime "$LOG") || return 1
  after_size=$(_fm_status_file_size "$LOG") || return 1
  after_ident=$(_fm_open_decisions_file_ident "$LOG") || return 1
  before_size=${before_size//[[:space:]]/}
  after_size=${after_size//[[:space:]]/}
  case "$before_mtime:$after_mtime:$before_size:$after_size" in
    *[!0-9:]*) return 1 ;;
  esac
  [ "$before_mtime" = "$after_mtime" ] \
    && [ "$before_size" = "$after_size" ] \
    && [ "$before_ident" = "$after_ident" ] \
    || return 1
  ORDERED_LOG_LINE=$line
  ORDERED_LOG_MTIME=$before_mtime
}

# --- remote secondmate: the true source is the remote endpoint ---------------
# A remote mate's recorded worktree and backend target live on its own host, so
# the local worktree probe above and the local pane reads below would misreport
# a healthy remote mate as gone or dead. Ask the remote host for the endpoint's
# recovery-grade state over the same fm-on.sh transport fm-send uses, then read
# current activity from the routed status log exactly as for a local
# secondmate (an idle endpoint is healthy for a secondmate either way). An
# unreachable host or unreadable endpoint is reported as unknown-remote -
# explicitly NOT proof of death - so a transport blip never reads as a torn
# down or dead mate; only the remote host's own dead/missing verdict may say
# the endpoint is actually gone.
if [ -n "$REMOTE_HOST" ]; then
  if ! REMOTE_STATE=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$ID" \
    fm-remote-secondmate-control.sh state "$ID" < /dev/null 2>/dev/null); then
    REMOTE_STATE=
  fi
  REMOTE_STATE=$(printf '%s\n' "$REMOTE_STATE" | tail -1)
  case "$REMOTE_STATE" in
    alive)
      if [ -n "$LOG_VERB" ]; then
        LOG_STATE=$(map_log_state "$LOG_LINE")
        if [ "$LOG_STATE" != unknown ]; then
          emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")${SEP}remote endpoint alive on $REMOTE_HOST"
        fi
      fi
      emit unknown remote-endpoint "alive on $REMOTE_HOST (an idle secondmate is healthy)"
      ;;
    dead|missing)
      emit unknown remote-endpoint "remote endpoint $REMOTE_STATE on $REMOTE_HOST"
      ;;
    '')
      emit unknown remote-endpoint "unknown-remote: $REMOTE_HOST unreachable or endpoint unreadable (not proof of death)"
      ;;
    *)
      emit unknown remote-endpoint "unknown-remote: endpoint state '$REMOTE_STATE' on $REMOTE_HOST (not proof of death)"
      ;;
  esac
fi

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose endpoint has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown. Backend-aware
# (fm_backend_of_meta defaults absent backend= to tmux, the P1 contract): a
# herdr task is read through fm_backend_capture instead of a bare tmux probe.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    tmux) tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1 ;;
    *) fm_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# crew_busy_verdict: the crew's semantic busy state from the one contract
# owner (bin/fm-busy-lib.sh), as "<busy|idle|unknown> <source>". A converted
# adapter answers from its own lifecycle record; Grok answers from its
# isolated rendered-tail fallback; a herdr crew's native `busy` is accepted
# when no record exists, but its native `idle` is NOT, because agent.get
# reports generation state (idle while a crew blocks on its own long-running
# foreground tool call) rather than turn state.
crew_busy_verdict() {  # <target>
  local tail40=''
  case "$HARNESS" in
    grok*) tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || tail40='' ;;
  esac
  fm_busy_classify "$TASK_BACKEND" "$1" "$HARNESS" "$ID" "$STATE" "$tail40"
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --
# trim, strip_quotes, the bounded nm_run call, nm_field's TOON parse, and the
# attribution helpers below are thin wrappers over the ONE owner in
# bin/fm-nm-run-lib.sh, shared with fm-teardown.sh's pre-teardown run abort.

trim() { fm_nm_trim "$@"; }
strip_quotes() { fm_nm_strip_quotes "$@"; }
nm_run() {  # <args...>
  fm_nm_run "$WT" "$NM_TIMEOUT" "$@"
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT).
RUN_OUT=""
nm_field() {  # <key>
  fm_nm_field "$RUN_OUT" "$1"
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

nm_ci_step_status() {
  local row rest
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
}

nm_effective_ci_step_status() {
  local step_status
  if [ "${RUN_STATUS:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(nm_ci_step_status)
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${RUN_STATUS:-}" = ci ]; then
    printf 'running'
  fi
}

# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the captain, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or failed/cancelled if closed). `axi status`'s steps[] table
# never distinguishes "still waiting on checks" from "checks green, waiting on
# merge": both read as plain `ci,running,...`. The only place that transition is
# recorded is the ci step's own log text, e.g. "all CI checks passed - still
# monitoring until merged or closed" or "no CI checks reported - still
# monitoring until merged or closed" (verified against 360+ real run logs under
# ~/.no-mistakes/logs/*/ci.log on the installed v1.32.2 binary, including the
# actual PR #252 run). Reads the ci step's log tail via `axi logs` and scans it
# for the MOST RECENT recognized marker (the log is append-only/chronological,
# so the last match is current): green with nothing red after it means CI is
# green right now, still only waiting on merge/close.
nm_ci_checks_state() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}
# Coarse fallback when the bare `axi status` answer is not this branch's own
# matching run: either it names another branch (routine once several crews
# validate the same underlying repo concurrently - a worktree with its own
# active run reliably gets that run answered, even under concurrent load), or
# it names this branch's run but the strict head rule rejected it. The real
# run-listing command is the top-level `no-mistakes runs` (the `axi` surface
# has no runs-listing subcommand; tests/fm-crew-state.test.sh owns the
# 2026-07-02 dead-code incident history this fallback replaced).
# fm_nm_runs_status_for_worktree in bin/fm-nm-run-lib.sh is the ONE owner of
# the ledger format, the newest-row-decides rule, and the anchored
# pipeline-continuation recognition (model-routing-benchmark-hardening: an
# active fix round whose head object the task copy never fetched used to be
# rejected here, letting the older failed row answer as current), so both
# attribution routes share one rule.
nm_runs_list() {
  nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT"
}
# The ledger is fetched at most once per read into RUNS_LIST: the coarse
# attribution fallback and the terminal-failed supersession cross-check below
# both need it, and neither is worth a second bounded CLI call. Assigns rather
# than prints, so the cache survives (a command substitution would fetch into a
# subshell every time).
RUNS_LIST=""
RUNS_LIST_FETCHED=0
runs_list_once() {
  [ "$RUNS_LIST_FETCHED" = 1 ] && return 0
  RUNS_LIST=$(nm_runs_list)
  RUNS_LIST_FETCHED=1
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
# scratch worktree); with no branch there is no run to attribute to this crew.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# 0 if the active axi-status run's head field matches this worktree's code
# identity. Branch match is a precondition (caller). Rule owned by
# fm_nm_head_matches_worktree in bin/fm-nm-run-lib.sh.
nm_run_head_matches_worktree() {
  local run_head
  run_head=$(strip_quotes "$(nm_field head)")
  fm_nm_head_matches_worktree "$WT" "$run_head"
}

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail (including a
# same-branch run the strict head rule rejected but the ledger proved is this
# worktree's pipeline-owned continuation); "coarse" means only a bare status
# word came back from the runs-list fallback, so the run-step block below skips
# the TOON field parsing entirely for this crew.
RUN_SOURCE=full
COARSE_STATUS=""
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  if [ -n "$RUN_OUT" ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    # Head equality, or the pipeline-owned-active exemption: while the
    # pipeline owns this branch, the daemon's own branch attribution is
    # authoritative and the lane head need not be a git object here
    # (fm_nm_run_is_pipeline_owned_active in bin/fm-nm-run-lib.sh).
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] \
      && { nm_run_head_matches_worktree || fm_nm_run_is_pipeline_owned_active "$RUN_OUT"; }; then
      HAVE_RUN=1
    else
      # The active-or-most-recent run is for another branch, or it names this
      # branch with a head this copy cannot verify (a pipeline-advanced fix
      # round, or a rewritten tip). Deliberately nested inside
      # `[ -n "$RUN_OUT" ]`: an empty/timed-out primary call means the CLI
      # itself did not respond, so retrying it immediately with a second
      # bounded call would just double the wait for no better answer.
      runs_list_once
      COARSE_STATUS=$(fm_nm_runs_status_for_worktree "$WT" "$CREW_BRANCH" "$RUNS_LIST")
      if [ -n "$COARSE_STATUS" ]; then
        HAVE_RUN=1
        # A branch-matching answer the strict rule rejected is this branch's
        # own current run once the ledger proves the pipeline-owned
        # continuation, so its axi TOON is the authoritative run detail
        # (RUN_SOURCE stays full); only a foreign-branch answer leaves
        # coarse status-word detail.
        [ "$run_branch" = "$CREW_BRANCH" ] || RUN_SOURCE=coarse
      fi
    fi
  fi
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  RUN_PR=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A crew genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced by each supervisor's span classification (fm-classify-lib.sh's
    # status_span_first_actionable) regardless of this coarse-vs-full
    # distinction, so a real gate is never silently missed.
    case "$COARSE_STATUS" in
      running)   RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      completed) RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)    RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled) RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      *)         RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac
  else
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    RUN_ID=$(strip_quotes "$(nm_field id)")
    RUN_HEAD=$(strip_quotes "$(nm_field head)")
    # The pull request THIS run opened, if it reached its pr step at all. A run
    # that never opened one reports no pr field, and that absence is meaningful:
    # it is what keeps a terminal outcome from being lent an older task's PR.
    RUN_PR=$(strip_quotes "$(nm_field pr)")
    outcome=$(strip_quotes "$(nm_field outcome)")
    case "$outcome" in
      passed|checks-passed) ATTRIBUTED_LEDGER_STATUS=completed ;;
      failed|cancelled) ATTRIBUTED_LEDGER_STATUS=$outcome ;;
      *)
        case "$status" in
          ci|running|fixing|awaiting_approval|fix_review) ATTRIBUTED_LEDGER_STATUS=running ;;
          *) ATTRIBUTED_LEDGER_STATUS=$status ;;
        esac
        ;;
    esac
    awaiting=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
    gate_status=$(nm_gate_status)
    has_gate=0
    nm_has_gate && has_gate=1

    if [ -n "$outcome" ]; then
      case "$outcome" in
        passed)        RUN_STATE="done"; RUN_DETAIL="run passed: PR merged/closed" ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
      esac
    elif [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: authority decision)"
      fi
    else
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        "")             RUN_STATE=working; RUN_DETAIL="run active" ;;
        *)              RUN_STATE=working; RUN_DETAIL="run active ($status)" ;;
      esac
      if [ "$RUN_STATE" = working ]; then
        CI_STEP_STATUS=$(nm_effective_ci_step_status)
        case "$CI_STEP_STATUS" in
          running)
            CI_LOG_STATE=$(nm_ci_checks_state)
            if [ "$CI_LOG_STATE" = green ]; then
              RUN_STATE="done"
              RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
            fi
            ;;
          fixing)
            CI_LOG_STATE=not-ready
            ;;
        esac
      fi
    fi
  fi

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
    [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
    if [ "$RUN_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
      CI_LOG_STATE=$(nm_ci_checks_state)
    elif [ "$CI_STEP_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    fi
    if [ "$CI_LOG_STATE" != not-ready ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
  fi

  TERMINAL_PR=""
  case "$RUN_STATE" in
    done|failed)
      runs_list_once
      NEWEST_ROW=$(fm_nm_runs_newest_for_branch "$CREW_BRANCH" "$RUNS_LIST")
      NEWEST_STATUS=${NEWEST_ROW%%|*}
      NEWEST_REST=${NEWEST_ROW#*|}
      NEWEST_SHA=${NEWEST_REST%%|*}
      NEWEST_REST=${NEWEST_REST#*|}
      NEWEST_EPOCH=${NEWEST_REST%%|*}
      NEWEST_PR=${NEWEST_REST#*|}
      NEWEST_ROW_AGREES=0
      LEDGER_STATUS=$(fm_nm_runs_status_for_worktree "$WT" "$CREW_BRANCH" "$RUNS_LIST")
      if [ "$RUN_SOURCE" = full ] && [ -n "$RUN_ID" ] \
        && [ "$run_branch" = "$CREW_BRANCH" ] \
        && [ "$NEWEST_STATUS" = "$ATTRIBUTED_LEDGER_STATUS" ] \
        && [ "$NEWEST_PR" = "$RUN_PR" ]; then
        case "$RUN_HEAD" in
          "$NEWEST_SHA"*) [ -n "$NEWEST_SHA" ] && NEWEST_ROW_AGREES=1 ;;
        esac
      fi
      if [ "$RUN_SOURCE" = coarse ]; then
        case "$LEDGER_STATUS" in
          completed|failed|cancelled) TERMINAL_PR=$NEWEST_PR ;;
        esac
      elif [ "$NEWEST_ROW_AGREES" = 1 ]; then
        TERMINAL_PR=$RUN_PR
      fi
      ;;
  esac

  # Apply the terminal-failure precedence contract owned by header rule 2b.
  if [ "$RUN_STATE" = failed ]; then
    case "$LEDGER_STATUS" in
      running)
        emit working run-step "run superseded by a newer run on this branch (earlier $RUN_DETAIL)"
        ;;
      completed)
        SUPERSEDED_DETAIL="run superseded by a newer completed run on this branch (earlier $RUN_DETAIL)"
        TERMINAL_PR=$NEWEST_PR
        emit_run "done" "$SUPERSEDED_DETAIL" "$TERMINAL_PR"
        ;;
      failed|cancelled)
        if [ "$NEWEST_ROW_AGREES" != 1 ]; then
          LEDGER_DETAIL="run $LEDGER_STATUS"
          [ "$LEDGER_STATUS" = failed ] || LEDGER_DETAIL="run cancelled"
          TERMINAL_PR=$NEWEST_PR
          emit_run failed "$LEDGER_DETAIL" "$TERMINAL_PR"
        fi
        ;;
    esac
    # map_log_state owns the verb->state mapping, including the configurable
    # paused verb; snapshot_ordered_log uses fm-classify-lib.sh's portable file
    # readers to keep the line and its ordering evidence consistent.
    if [ -n "$NEWEST_EPOCH" ] && snapshot_ordered_log; then
      if [ "$ORDERED_LOG_MTIME" -ge "$((NEWEST_EPOCH + 60))" ]; then
        LOG_STATE=$(map_log_state "$ORDERED_LOG_LINE")
        case "$LOG_STATE" in
          paused|done)
            emit "$LOG_STATE" status-log \
              "$(status_line_note "$ORDERED_LOG_LINE")${SEP}later than the run ($RUN_DETAIL)"
            ;;
        esac
      fi
    fi
    case "$NEWEST_STATUS" in
      '') ;;
      *)
        [ "$NEWEST_ROW_AGREES" = 1 ] || emit unknown run-step \
          "a newer $NEWEST_STATUS run on this branch supersedes the earlier $RUN_DETAIL; current state not provable here"
        ;;
    esac
  fi

  # Reconcile the status log. A needs-decision/blocked log line that the run-step
  # has moved past (anything but a genuinely parked run) is deterministically
  # stale: the gate resolved and the run resumed or finished.
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  emit_run "$RUN_STATE" "$RUN_DETAIL" "$TERMINAL_PR"
fi

# --- fallback: no run attributed to this crew ------------------------------
# The run-step path above already handled any crew with a run, regardless of pane
# liveness, so a finished-but-pane-closed crew never reaches here. Down here there
# is no run to consult, so a dead/unreadable target means the crew is gone: report
# unknown rather than trusting a possibly-stale status log as the current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
pane_readable "$BACKEND_TARGET" || emit unknown none "backend target gone: $BACKEND_TARGET"

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# state is not meaningful for them; read their state from the status log only.
# Only an exact busy verdict reports working here, and only an exact idle
# verdict permits the status-log fallback below. Missing, malformed, stale, or
# unverified semantic state remains unknown.
if [ "$KIND" != secondmate ]; then
  BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
  case "${BUSY_VERDICT%% *}" in
    busy) emit working pane "harness busy (${BUSY_VERDICT#* })" ;;
    idle) ;;
    *) emit unknown pane "harness state unavailable ($BUSY_VERDICT)" ;;
  esac
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (fm-classify-lib.sh's
# FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a secondmate, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

emit unknown none "no current-state source available"
