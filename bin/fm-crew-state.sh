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
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta.
#   2. Matching no-mistakes run for this crew's branch AND current code identity,
#      active or terminal (from `axi status`, or the coarse `no-mistakes runs`
#      fallback)? Branch name alone is not enough: a historical run on a reused
#      branch whose head was rewritten or diverged must not be attributed.
#      A run matches when its head equals the worktree HEAD, or the worktree HEAD
#      is an ancestor of the run head (pipeline fix commits advanced the run on
#      the same line of history). It also matches in two cases the pipeline's own
#      commits create, both narrowed to the run that is demonstrably current:
#      an ACTIVELY-EXECUTING run whose head the tip has advanced past (it
#      authored that advance), and a LIVE run answered for this branch whose head
#      is not an object in this worktree at all (the pipeline owns the branch and
#      commits in a copy this worktree has never fetched). Local work that
#      advanced past a parked or terminal run head, a rewritten or diverged tip,
#      and an unresolvable sha read out of the historical runs listing all still
#      invalidate attribution. nm_head_attributable owns the exact rule.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see nm_ci_checks_state) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating.
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
# A run LOOKUP FAILURE is not a run ABSENCE. The bounded no-mistakes call can
# fail to complete - it times out under a saturated daemon, errors, or cannot be
# bounded at all - and that used to be indistinguishable from "this branch has no
# run", collapsing a crew that was demonstrably mid-validation to unknown · none.
# Because fm-classify-lib.sh's crew_is_provably_working() reads this same line, a
# working crew stopped being provably working exactly during the longest phase of
# a run, and every idle repaint raised a fresh possible-wedge escalation. A
# failure now degrades to the LAST KNOWN run-step (see the run-step record below)
# and reports source `run-step-degraded`; only a completed lookup that found no
# run falls through to the pane/log sources.
#
# Writes exactly one thing: state/<id>.run-step, the last known run-step record
# that makes that degrade possible (runstep_record_write below is the only
# writer). Every other read is side-effect free. Always exits 0 on a successful
# read regardless of state; exit 2 only on a usage error (no id).
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
# How long a recorded run-step stays usable as the degraded answer after the run
# lookup starts failing. This is the bound that keeps the degrade from becoming a
# worse bug than the one it fixes: a permanently broken no-mistakes daemon would
# otherwise let every idle crew claim it is still validating forever, and a real
# wedge would never surface again. Past this age the record is ignored and the
# crew falls through to the pane/log sources exactly as it does today. 0 disables
# the degrade entirely, restoring the strict "cannot re-confirm it, do not claim
# it" reading for a home that wants it.
FM_CREW_STATE_DEGRADED_MAX_AGE=${FM_CREW_STATE_DEGRADED_MAX_AGE:-900}
case "$FM_CREW_STATE_DEGRADED_MAX_AGE" in ''|*[!0-9]*) FM_CREW_STATE_DEGRADED_MAX_AGE=900 ;; esac
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
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
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

# --- last known run-step record ---------------------------------------------
# state/<id>.run-step: one line, "<epoch>\t<state>\t<detail>", atomically
# replaced on every successful run-derived verdict and read back ONLY when a
# later lookup could not complete. It is what lets a lookup FAILURE answer
# "still validating, lookup unavailable" instead of "unknown", without ever
# inventing evidence: nothing is degraded for a crew that was never seen
# validating in the first place, so a crew that genuinely stopped before any run
# has no record to fall back on and still surfaces as a wedge suspect.
RUNSTEP_RECORD="$STATE/$ID.run-step"

# Record a run-derived verdict. Never fails the read: a state dir that is
# read-only or already torn down just leaves the previous record in place.
runstep_record_write() {  # <state> <detail>
  local tmp flat
  case "$1" in working|parked|done|failed) ;; *) return 0 ;; esac
  [ -d "$STATE" ] || return 0
  flat=$(printf '%s' "${2:-}" | tr '\t\n' '  ')
  tmp="$RUNSTEP_RECORD.$$.tmp"
  if printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$flat" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$RUNSTEP_RECORD" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

runstep_record_clear() {
  rm -f "$RUNSTEP_RECORD" 2>/dev/null || true
}

# Print "<state>\t<detail>\t<age-seconds>" for a record still inside the
# freshness bound; return 1 for a missing, malformed, or expired record.
runstep_record_read() {
  local ts st detail now age
  [ -f "$RUNSTEP_RECORD" ] || return 1
  IFS=$'\t' read -r ts st detail < "$RUNSTEP_RECORD" 2>/dev/null || return 1
  case "${ts:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "${st:-}" in working|parked|done|failed) ;; *) return 1 ;; esac
  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( now - ts ))
  [ "$age" -ge 0 ] || return 1
  [ "$age" -lt "$FM_CREW_STATE_DEGRADED_MAX_AGE" ] || return 1
  printf '%s\t%s\t%s' "$st" "${detail:-}" "$age"
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
strip_quotes() {
  local s
  s=$(trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  trim "$s"
}

# Bounded no-mistakes call in the worktree; stdout only, never fails the script
# (there is no `set -e`). The EXIT STATUS is deliberately propagated rather than
# swallowed: 124 from a timeout, or any other non-zero, is what tells the caller
# the lookup could not COMPLETE, which must never be read as "this branch has no
# run". With no bounding mechanism available at all the call is not made, and 127
# reports that same inability rather than a silent empty answer.
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
nm_run() {  # <args...>
  case "$HAVE_TIMEOUT" in
    timeout)  ( cd "$WT" && timeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null ;;
    gtimeout) ( cd "$WT" && gtimeout "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null ;;
    perl)     ( cd "$WT" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$NM_TIMEOUT" no-mistakes "$@" ) 2>/dev/null ;;
    *)        return 127 ;;
  esac
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT).
RUN_OUT=""
nm_field() {  # <key>
  printf '%s\n' "$RUN_OUT" | sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)/\1/p" | head -1
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
# when the branch has no attributable run in the listing.
#
# A PURE PARSER over a listing the caller already captured. The call itself is
# made by the caller so a listing that could not be fetched is classified as a
# lookup failure there; parsing an empty string here would otherwise report the
# same "no run for this branch" as a listing that genuinely lacks the branch.
nm_runs_status_for_branch() {  # <branch> <runs-listing>
  local branch=$1 out=${2:-} row st rest br sha authoring
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
      # Same code-identity rule as axi status, including the fix-round case: an
      # actively-executing run authors its own commits, so a tip that advanced
      # past this row's sha is still that run's work.
      case "$st" in running|fixing) authoring=1 ;; *) authoring=0 ;; esac
      # Never branch-scoped: this is the historical listing, not an answer about
      # the worktree's current branch, so an unresolvable sha stays rejected.
      nm_head_attributable "$sha" "$authoring" 0 || continue
      printf '%s' "$st"
      return 0
    fi
  done <<< "$out"
  return 0
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
# scratch worktree); with no branch there is no run to attribute to this crew.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# How a run's recorded head <sha> relates to this worktree's HEAD. One owner for
# the commit-relationship test both the `axi status` head field and the coarse
# runs-list short sha are judged by. Prints exactly one token:
#   equal       the run head IS the worktree HEAD
#   run-ahead   worktree HEAD is an ancestor of the run head - pipeline fix
#               commits advanced the run tip past what this worktree has read
#   run-behind  the run head is a strict ancestor of the worktree HEAD - the tip
#               advanced past the sha this run recorded
#   unresolved  the sha is not an object in this worktree at all, so no
#               relationship can be computed (the pipeline is committing in a
#               copy this worktree has never fetched from)
#   missing     no sha to judge, or this worktree has no readable HEAD
#   diverged    resolvable but on neither side of the worktree HEAD - a
#               rewritten branch tip
nm_head_relation() {  # <sha>
  local run_head=${1:-} local_full run_full
  [ -n "$run_head" ] || { printf 'missing'; return; }
  local_full=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || { printf 'missing'; return; }
  run_full=$(git -C "$WT" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || { printf 'unresolved'; return; }
  if [ "$run_full" = "$local_full" ]; then printf 'equal'; return; fi
  if git -C "$WT" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    printf 'run-ahead'; return
  fi
  if git -C "$WT" merge-base --is-ancestor "$run_full" "$local_full" 2>/dev/null; then
    printf 'run-behind'; return
  fi
  printf 'diverged'
}

# 0 when a run recorded at <sha> may be attributed to this worktree's current
# code. Branch match is a precondition (caller). <authoring> is 1 only while the
# run sits in an actively-executing step - the states in which the pipeline
# commits its OWN fixes. <branch-scoped> is 1 only for an answer the CLI gave for
# THIS worktree's current branch, never for a row read out of the historical
# runs listing.
#
# `run-behind` is the fix-round case. When a review finding is answered
# `--action fix`, the pipeline commits that fix and the branch tip advances past
# the sha the run recorded; rejecting the row outright made the run that was
# CURRENTLY authoring those commits stop matching its own worktree, and the crew
# read as unknown for the rest of the fix round. An actively-executing run is the
# author of that advance and keeps attribution. A PARKED run is by definition
# waiting on a response and commits nothing, so a tip that advanced past it is
# local work outside the run and must still invalidate - as must a terminal run.
#
# `unresolved` is the pipeline-owned case, and is NOT the same evidence as a
# rewritten tip. While the pipeline owns the branch it commits in its own copy,
# so the head it reports is simply an object this worktree has never fetched;
# refusing it made a crew parked at a live fix_review gate read as having no run
# at all. Only a LIVE run answered for THIS branch earns that benefit: the
# historical runs listing has no notion of "current", so an unresolvable sha
# there stays rejected, and a terminal run's unseen head is evidence of nothing.
# `missing` and `diverged` are always rejected - an absent sha cannot bind, and a
# resolvable sha on neither side of HEAD is a genuinely rewritten branch.
nm_head_attributable() {  # <sha> <authoring:0|1> <branch-scoped-live:0|1>
  case "$(nm_head_relation "$1")" in
    equal|run-ahead) return 0 ;;
    run-behind)      [ "${2:-0}" = 1 ] && return 0; return 1 ;;
    unresolved)      [ "${3:-0}" = 1 ] && return 0; return 1 ;;
    *)               return 1 ;;
  esac
}

# 1 when the `axi status` run in $RUN_OUT is in an actively-executing step and so
# able to author pipeline fix commits; 0 for a parked, terminal, or unrecognized
# run. A run parked at a gate reports a plain `running` status in some shapes, so
# the gate markers are checked before the status word.
nm_run_is_authoring() {
  local outcome status
  outcome=$(strip_quotes "$(nm_field outcome)")
  [ -z "$outcome" ] || { printf '0'; return; }
  if printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*awaiting_agent:'; then
    printf '0'; return
  fi
  if nm_has_gate; then printf '0'; return; fi
  status=$(strip_quotes "$(nm_field status)")
  case "$status" in
    awaiting_approval|fix_review) printf '0' ;;
    running|fixing|ci)            printf '1' ;;
    *)                            printf '0' ;;
  esac
}

# 1 when the `axi status` run in $RUN_OUT has not reached a terminal result, so
# it is still this branch's current run whether it is executing or parked at a
# gate. Broader than nm_run_is_authoring on purpose: a run parked at fix_review
# commits nothing right now but is emphatically still live.
nm_run_is_live() {
  local outcome status
  outcome=$(strip_quotes "$(nm_field outcome)")
  [ -z "$outcome" ] || { printf '0'; return; }
  status=$(strip_quotes "$(nm_field status)")
  case "$status" in completed|failed|cancelled) printf '0' ;; *) printf '1' ;; esac
}

# 0 if the axi-status run's head field is attributable to this worktree. The
# caller has already established this answer is for the crew's own branch, which
# is what makes it branch-scoped for the pipeline-owned rule above.
nm_run_head_matches_worktree() {
  nm_head_attributable "$(strip_quotes "$(nm_field head)")" \
    "$(nm_run_is_authoring)" "$(nm_run_is_live)"
}

nm_run_invalidates_record() {
  local relation
  [ "$(nm_run_is_live)" = 0 ] && return 0
  relation=$(nm_head_relation "$(strip_quotes "$(nm_field head)")")
  case "$relation" in
    run-behind|diverged) return 0 ;;
    *) return 1 ;;
  esac
}

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a bare status word came back from the runs-list fallback above, so the
# run-step block below skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
COARSE_STATUS=""
# LOOKUP_FAILED=1 means a bounded no-mistakes call could not COMPLETE - it timed
# out under a saturated daemon, errored, or could not be bounded at all. That is
# emphatically NOT the same as a completed lookup that found no run for this
# branch, and only a failure may degrade to the recorded run-step below. A
# genuine absence still falls through to the pane and status-log sources.
LOOKUP_FAILED=0
LOOKUP_COMPLETED=0
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  nm_rc=$?
  # Empty stdout is a failure, not an absence: `axi status` answers a branch with
  # no run of its own with some OTHER branch's run as informational display (the
  # cross-branch case the coarse fallback below exists for), so it has no
  # "nothing to report" empty answer to confuse this with.
  if [ "$nm_rc" != 0 ] || [ -z "$RUN_OUT" ]; then
    RUN_OUT=""
    LOOKUP_FAILED=1
  else
    run_branch=$(strip_quotes "$(nm_field branch)")
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ]; then
      if nm_run_head_matches_worktree; then
        HAVE_RUN=1
        LOOKUP_COMPLETED=1
      elif nm_run_invalidates_record; then
        runstep_record_clear
      fi
    fi
    if [ "$HAVE_RUN" = 0 ]; then
      # The active-or-most-recent run is for another branch, or same branch with
      # a rewritten/diverged head (the CLI is alive and answered; only the
      # attribution missed) - try the coarse fallback.
      # Deliberately reached only when the primary call ANSWERED: a timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      runs_out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
      runs_rc=$?
      if [ "$runs_rc" != 0 ] || [ -z "$runs_out" ]; then
        LOOKUP_FAILED=1
      else
        LOOKUP_COMPLETED=1
        COARSE_STATUS=$(nm_runs_status_for_branch "$CREW_BRANCH" "$runs_out")
        if [ -n "$COARSE_STATUS" ]; then
          HAVE_RUN=1
          RUN_SOURCE=coarse
        fi
      fi
    fi
  fi
fi

if [ "$LOOKUP_COMPLETED" = 1 ] && [ "$HAVE_RUN" = 0 ]; then
  runstep_record_clear
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

  # Remember this verdict so a later lookup that cannot complete degrades to it
  # instead of collapsing to unknown. Recorded from the authoritative run-step
  # path only, so nothing but a genuinely observed run is ever replayed.
  runstep_record_write "$RUN_STATE" "$RUN_DETAIL"

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
fi

# --- fallback: no run attributed to this crew ------------------------------
# The run-step path above already handled any crew with an attributed run,
# regardless of pane liveness, so a finished-but-pane-closed crew never reaches
# here. Down here either the lookup completed and found no run, or it could not
# complete at all; in both cases there is no live run to consult, so a
# dead/unreadable target means the crew is gone: report unknown rather than
# trusting a possibly-stale status log - or a remembered run-step - as the
# current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
pane_readable "$BACKEND_TARGET" || emit unknown none "backend target gone: $BACKEND_TARGET"

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# state is not meaningful for them; read their state from the status log only.
# Only an exact busy verdict reports working here, and only an exact idle
# verdict permits the status-log fallback below. Missing, malformed, stale, or
# unverified semantic state remains unknown - deferred rather than emitted here
# only so the degraded run-step below can answer first; it still outranks the
# status-log fallback exactly as before.
BUSY_STATE=""
BUSY_VERDICT=""
if [ "$KIND" != secondmate ]; then
  BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
  case "${BUSY_VERDICT%% *}" in
    busy) emit working pane "harness busy (${BUSY_VERDICT#* })" ;;
    idle) BUSY_STATE=idle ;;
    *)    BUSY_STATE=unknown ;;
  esac
fi

# The run lookup could not complete, and this crew has a recent run-step on
# record: report that last known step, degraded, rather than unknown. Bounded by
# FM_CREW_STATE_DEGRADED_MAX_AGE so a permanently unreachable daemon stops
# absorbing wedge suspicion instead of hiding it forever, and never reached at
# all on a completed lookup that simply found no run.
#
# Placement is the safety property. It sits BELOW the endpoint checks and the
# exact busy verdict, so live positive evidence - a gone endpoint proving the
# crew stopped, or a busy harness proving it is working right now - always
# outranks a remembered step. It sits ABOVE the unreadable-harness and
# status-log fallbacks, which is the whole point: an observed run-step, even one
# that could not be re-confirmed this poll, is better current-state evidence
# than an append-only event log.
if [ "$LOOKUP_FAILED" = 1 ]; then
  if DEGRADED=$(runstep_record_read); then
    IFS=$'\t' read -r deg_state deg_detail deg_age <<< "$DEGRADED"
    deg_line="run lookup unavailable"
    [ -n "$deg_detail" ] && deg_line="$deg_detail${SEP}$deg_line"
    emit "$deg_state" run-step-degraded "$deg_line (last known ${deg_age}s ago)"
  fi
fi

if [ "$BUSY_STATE" = unknown ]; then
  emit unknown pane "harness state unavailable ($BUSY_VERDICT)"
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
