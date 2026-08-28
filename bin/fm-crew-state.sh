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
# no-mistakes run-step attributed to this crew's branch and current code
# identity, else the pane busy-signature) and reconciles the possibly-stale log
# against it.
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
#      diverged from it, invalidates attribution.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. While the
#      active step is ci, `axi status` alone cannot distinguish validating from
#      checks-green monitoring. `forge_zero_check_verdict` owns the exact-head,
#      complete-evidence rule used before that call site becomes terminal.
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
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (nm_runs_status_for_branch, below) scans. Generous enough to still find a
# branch's own run on a busy multi-crew fleet without listing the entire
# history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
# Hard bound on each forge read. Forge calls happen only when a CI marker claims
# a state that would end the wait, never on the ordinary validating path.
FORGE_TIMEOUT=${FM_CREW_STATE_FORGE_TIMEOUT:-8}
case "$FORGE_TIMEOUT" in ''|*[!0-9]*|0) FORGE_TIMEOUT=8 ;; esac
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
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

# Last non-empty status line, and its leading verb (the word before the colon).
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
# branch+head attribution rule below are thin wrappers over the ONE owner in
# bin/fm-nm-run-lib.sh, shared with fm-teardown.sh's pre-teardown run abort.

trim() { fm_nm_trim "$@"; }
strip_quotes() { fm_nm_strip_quotes "$@"; }
nm_run() {  # <args...>
  fm_nm_run "$WT" "$NM_TIMEOUT" "$@"
}
nm_run_checked() {  # <args...>
  fm_nm_run_checked "$WT" "$NM_TIMEOUT" "$@"
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

no_ci_detail() {
  local pr_url=$1
  if [ -n "$pr_url" ]; then
    printf 'no CI configured for this PR: nothing verified this change - %s' "$pr_url"
  else
    printf 'no CI configured for this PR: nothing verified this change'
  fi
}

# --- CI readiness: what the ci step's log actually says ---------------------
#
# The no-mistakes ci step stays running after checks pass because it continues
# monitoring until merge or close. Its log is the only source that records the
# transition from validating to ready, but the log marker is an observation,
# not a verdict. In particular, these two markers state the same fact:
#
#   no CI checks reported - still monitoring until merged or closed
#   no CI checks reported yet, waiting for checks to register...
#
# Both mean that one poll saw zero checks. Neither means checks passed. The last
# recognized whole-line marker is classified as a fact and any fact that could
# end the wait is settled by forge_zero_check_verdict below.
nm_ci_marker_class() {  # <marker-line>
  case "$1" in
    *"all CI checks passed"*)  printf 'passed' ;;
    *"no CI checks reported"*) printf 'zero-checks' ;;
    *) printf 'pending' ;;
  esac
}

# Owner/repo/number of a GitHub pull request URL, as "<owner>/<repo> <number>".
# Empty for another forge, so an unsupported URL remains nonterminal.
forge_pr_coordinates() {  # <pr-url>
  local url=$1 rest owner repo number
  case "$url" in
    https://github.com/*/*/pull/*) rest=${url#https://github.com/} ;;
    *) return 0 ;;
  esac
  owner=${rest%%/*}; rest=${rest#*/}
  repo=${rest%%/*};  rest=${rest#*/}
  case "$rest" in pull/*) number=${rest#pull/} ;; *) return 0 ;; esac
  number=${number%%/*}
  case "$owner$repo$number" in ''|*' '*) return 0 ;; esac
  case "$number" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s/%s %s' "$owner" "$repo" "$number"
}

# This function owns the terminal CI evidence rule. A verdict is terminal only
# after a complete positive observation of the exact fact claimed, bound to one
# stable PR head. Silence, failed or timed-out reads, incomplete snapshots, and
# a moved head remain nonterminal. Complete successful zero-row reads from both
# Check Suites and combined legacy Status prove the distinct no-CI-configured
# outcome without claiming that validation passed.
forge_zero_check_verdict() {  # <pr-url> <expected-head> -> verdict[ <detail>]
  local url=$1 expected_head=$2 coords repo number pr_head suites total combined
  local final_pr_head combined_state combined_total
  local unfinished=0 runs=0 gated=0 seen=0 snapshot_valid=1
  command -v gh >/dev/null 2>&1 || { printf 'unknown forge could not be reached'; return; }
  coords=$(forge_pr_coordinates "$url")
  [ -n "$coords" ] || { printf 'unknown pull request is not on GitHub'; return; }
  [ -n "$expected_head" ] || { printf 'invalid attributed run has no head'; return; }
  repo=${coords%% *}
  number=${coords##* }
  pr_head=$(fm_run_timed "$FORGE_TIMEOUT" gh api "repos/$repo/pulls/$number" --jq .head.sha) || pr_head=
  pr_head=$(trim "$pr_head")
  [ -n "$pr_head" ] || { printf 'unknown forge could not read the PR head'; return; }
  [ "$pr_head" = "$expected_head" ] || { printf 'invalid PR head changed from the attributed run'; return; }
  suites=$(fm_run_timed "$FORGE_TIMEOUT" gh api "repos/$repo/commits/$expected_head/check-suites?per_page=100" \
    --jq '.total_count, (.check_suites[] | "\(.status)|\(.conclusion)|\(.latest_check_runs_count)")') || suites=
  combined=$(fm_run_timed "$FORGE_TIMEOUT" gh api "repos/$repo/commits/$expected_head/status" \
    --jq '"\(.state)|\(.total_count)"') || combined=
  final_pr_head=$(fm_run_timed "$FORGE_TIMEOUT" gh api "repos/$repo/pulls/$number" --jq .head.sha) || final_pr_head=
  final_pr_head=$(trim "$final_pr_head")
  [ -n "$final_pr_head" ] || { printf 'unknown forge could not re-read the PR head'; return; }
  [ "$final_pr_head" = "$expected_head" ] || { printf 'invalid PR head changed while forge evidence was read'; return; }
  total=$(printf '%s\n' "$suites" | head -1)
  case "$total" in ''|*[!0-9]*) printf 'invalid forge returned a malformed check-suite response'; return ;; esac
  combined_state=${combined%%|*}
  combined_total=${combined#*|}
  [ "$combined_state" != "$combined" ] \
    || { printf 'invalid forge returned a malformed commit-status response'; return; }
  case "$combined_state" in success|pending|failure) ;; *) printf 'invalid forge returned an unknown commit-status state'; return ;; esac
  case "$combined_total" in ''|*[!0-9]*) printf 'invalid forge returned a malformed commit-status count'; return ;; esac
  local status conclusion count
  while IFS='|' read -r status conclusion count; do
    [ -n "$status" ] || continue
    seen=$((seen + 1))
    case "$status" in completed) ;; *) unfinished=1 ;; esac
    case "$conclusion" in success|skipped|neutral) ;; *) unfinished=1 ;; esac
    case "$conclusion" in action_required) gated=1 ;; esac
    case "$count" in
      ''|*[!0-9]*) snapshot_valid=0 ;;
      *) runs=$((runs + count)) ;;
    esac
  done <<EOF
$(printf '%s\n' "$suites" | tail -n +2)
EOF
  [ "$seen" -eq "$total" ] \
    || { printf 'invalid check-suite response was incomplete (%s of %s rows)' "$seen" "$total"; return; }
  [ "$snapshot_valid" = 1 ] \
    || { printf 'invalid check-suite response contained an invalid run count'; return; }
  if [ "$combined_total" -gt 0 ] && [ "$combined_state" != success ]; then
    printf 'ci-pending commit statuses are %s' "$combined_state"
    return
  fi
  if [ "$total" -eq 0 ]; then
    if [ "$combined_total" -gt 0 ] && [ "$combined_state" = success ]; then
      printf 'green'
      return
    fi
    printf 'no-ci-configured'
    return
  fi
  if [ "$unfinished" = 0 ] && [ "$runs" -gt 0 ]; then
    printf 'green'
    return
  fi
  if [ "$gated" = 1 ]; then
    printf 'ci-pending awaiting maintainer approval, no checks have run'
    return
  fi
  printf 'ci-pending no checks have reported yet'
}

# Current readiness for the active monitoring call site. The last recognized
# whole-line marker wins. A marker that could end the wait must pass the single
# forge verdict owner above; pending markers remain cheap and local.
nm_ci_checks_state() {
  local run_id log_tail marker class pr expected_head verdict
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  if ! log_tail=$(nm_run_checked axi logs --step ci --run "$run_id"); then
    printf 'unknown'
    return
  fi
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E '^[[:space:]]*"?(all CI checks passed - still monitoring until merged or closed|no CI checks reported - still monitoring until merged or closed|no CI checks reported yet, waiting for checks to register\.\.\.|CI checks running, waiting for results\.\.\.|checks failed|issues detected(: .+ - (manual fix requested|auto-fixing \(attempt [0-9]+/[0-9]+\)|auto-fix disabled, waiting for manual intervention|max auto-fix attempts \([0-9]+\) reached, waiting for manual intervention)\.\.\.| but checks still pending, waiting for all checks to complete\.\.\.)|base branch advanced \([^)]*\), re-arming CI monitor timeout)"?[[:space:]]*$' \
    | tail -1)
  [ -n "$marker" ] || { printf 'unknown'; return; }
  class=$(nm_ci_marker_class "$marker")
  case "$class" in
    pending) printf 'not-ready'; return ;;
  esac
  pr=$(strip_quotes "$(nm_field pr)")
  expected_head=$(strip_quotes "$(nm_field head)")
  verdict=$(forge_zero_check_verdict "$pr" "$expected_head")
  case "${verdict%% *}" in
    green)            printf 'green' ;;
    no-ci-configured) printf 'no-ci-configured' ;;
    ci-pending)       printf 'not-ready %s' "${verdict#ci-pending }" ;;
    invalid)          printf 'not-ready %s' "${verdict#invalid }" ;;
    *)                printf 'not-ready %s' "${verdict#unknown }" ;;
  esac
}
# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one
# exists, else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating crews on the same underlying repo). A crew whose branch genuinely
# has no run yet therefore sees another branch's answer here.
#
# This fallback used to shell out to `no-mistakes axi` (bare, no subcommand)
# expecting a `runs[N]{id,branch,status,...}:` TOON table and re-query the
# matched id via `axi status --run <id>`. Verified against the real installed
# CLI (v1.32.2): the `axi` surface exposes only abort/logs/respond/run/status -
# there is no runs-listing subcommand under `axi` at all, so that table never
# appears and the lookup was silently dead code; whenever the bare `axi
# status` answer was not this crew's own branch, attribution always failed and
# the caller fell straight through to the pane/log fallback below. (The
# PRIMARY cause of the 2026-07 herdr false-surface incidents turned out to be
# a separate bug in bin/fm-watch.sh's stale_is_terminal precedence - see that
# file's history - but this cross-branch path was independently confirmed
# dead code and is worth having actually work.)
#
# The real run-listing command is the top-level `no-mistakes runs` (verified:
# `no-mistakes --help` lists it separately from `axi`). It is plain, human-
# oriented text - no run id, no JSON/TOON, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]" separated by runs of
# spaces (verified: no quoting, so splitting on the first two whitespace runs
# is exact) - but branch + coarse status is exactly what this predicate needs:
# is a run for THIS branch active right now. Echoes the first (most recent)
# matching row's status word (running/completed/cancelled/failed), or empty
# when the branch has no run within FM_CREW_STATE_RUNS_LIMIT rows.
nm_runs_status_for_branch() {  # <branch>
  local branch=$1 out row st rest br sha
  out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(trim "$rest")
    br=${rest%% *}
    rest=${rest#* }
    rest=$(trim "$rest")
    sha=${rest%% *}
    if [ "$br" = "$branch" ]; then
      # Same code-identity rule as axi status: skip a same-branch row whose
      # short-sha does not match this worktree (rewritten or advanced tip).
      if ! nm_coarse_head_matches_worktree "$sha"; then
        continue
      fi
      printf '%s' "$st"
      return 0
    fi
  done <<< "$out"
  return 0
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

# Coarse runs-list rows are "<status> <branch> <short-sha> ...". 0 if the short
# sha for this branch row matches the worktree head under the same rules as
# nm_run_head_matches_worktree (equal, or local is ancestor of run tip).
nm_coarse_head_matches_worktree() {  # <short-sha>
  fm_nm_head_matches_worktree "$WT" "$1"
}

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a bare status word came back from the runs-list fallback above, so the
# run-step block below skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
COARSE_STATUS=""
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  if [ -n "$RUN_OUT" ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] && nm_run_head_matches_worktree; then
      HAVE_RUN=1
    else
      # The active-or-most-recent run is for another branch, or same branch with
      # a rewritten/diverged head (the CLI is alive and answered; only the
      # attribution missed) - try the coarse fallback.
      # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      COARSE_STATUS=$(nm_runs_status_for_branch "$CREW_BRANCH")
      if [ -n "$COARSE_STATUS" ]; then
        HAVE_RUN=1
        RUN_SOURCE=coarse
      fi
    fi
  fi
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A crew genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced through signal_reason_is_actionable regardless of this
    # coarse-vs-full distinction, so a real gate is never silently missed.
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
    outcome=$(strip_quotes "$(nm_field outcome)")
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
            case "${CI_LOG_STATE%% *}" in
              green)
                if ! log_reports_ci_ready; then
                  RUN_STATE="done"
                  RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
                fi
                ;;
              no-ci-configured)
                RUN_STATE="done"
                RUN_DETAIL=$(no_ci_detail "$(strip_quotes "$(nm_field pr)")")
                ;;
              not-ready)
                [ "$CI_LOG_STATE" = not-ready ] \
                  || RUN_DETAIL="$RUN_DETAIL${SEP}${CI_LOG_STATE#not-ready }"
                ;;
            esac
            ;;
          fixing)
            CI_LOG_STATE=not-ready
            ;;
        esac
      fi
    fi
  fi

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" != coarse ]; then
      [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
      if [ "$RUN_STATUS" = fixing ]; then
        CI_LOG_STATE=not-ready
      elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
        CI_LOG_STATE=$(nm_ci_checks_state)
      elif [ "$CI_STEP_STATUS" = fixing ]; then
        CI_LOG_STATE=not-ready
      fi
      case "${CI_LOG_STATE%% *}" in
        green)
          emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
          ;;
        no-ci-configured)
          RUN_STATE="done"
          RUN_DETAIL=$(no_ci_detail "$(strip_quotes "$(nm_field pr)")")
          ;;
      esac
    fi
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

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
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
