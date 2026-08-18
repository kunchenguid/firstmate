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
#      fallback)? For a TERMINAL run, branch name alone is not enough: a
#      historical run on a reused branch whose head was rewritten or diverged
#      must not be attributed. Such a run matches when its head equals the
#      worktree HEAD, or the worktree HEAD is an ancestor of the run head
#      (pipeline fix commits advanced the run on the same line of history).
#      Local work that advanced past the run head, or diverged from it,
#      invalidates attribution. An EXECUTING run on this crew's branch is
#      attributed with no head condition, because a run the pipeline is running
#      right now cannot be history, and it also outranks any older terminal run
#      for the branch - a cancelled or failed run that a newer running one
#      replaced is never the current state (see nm_runs_status_for_branch for
#      the evidence). A run parked at a gate is waiting, not executing, and
#      still needs its head to bind.
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
#      For harness=claude, a pane parked on Claude Code's account/usage-limit
#      banner (claude_limit_scan below, over bin/fm-busy-lib.sh's
#      fm_busy_claude_limit_banner) never overrides an attributed run's own
#      state: a parked or actively running/fixing/ci run keeps its state and
#      gate detail and only gains an appended `worker pane limit-blocked` note,
#      and a terminal done/failed run is left alone. The pane's paused verdict
#      applies only when no run is attributed (case 4 below) or the attributed
#      run is in none of those states.
#   4. No run for this crew (pre-validation, or kind=scout): fall back to the
#      recorded backend's pane busy state, then the status log's last line only
#      when its verb maps to a recognized run-state. Decision-only events such as
#      `resolved` never become current state or detail. For harness=claude, a
#      busy pane verdict is overridden to paused when the pane's composer region
#      shows Claude Code's blocking account/usage-limit widget (see bin/fm-busy-
#      lib.sh's fm_busy_claude_limit_banner for the verified wordings, the
#      anchoring, and why a bare limit notice is deliberately NOT a pause): the
#      worker is stalled on an external wait, not a working turn, even though
#      its UserPromptSubmit hook already opened a turn. A bare notice instead
#      annotates the working detail with `limit notice visible in pane`.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log.
#
# Read-only towards the crew, its worktree and its pipeline: nothing here can
# start, resume, answer or abort a run. The one write is the bounded negative
# cache state/.run-superseded-<id> described at nm_supersession_absent_cached.
# Always exits 0 on a successful read regardless of state; exit 2 only on a
# usage error (no id).
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
FM_RUN_SUPERSEDED_TTL=${FM_RUN_SUPERSEDED_TTL:-120}
case "$FM_RUN_SUPERSEDED_TTL" in ''|*[!0-9]*) FM_RUN_SUPERSEDED_TTL=120 ;; esac
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
# claude_limit_scan: the pane-derived Claude account/usage-limit override's one
# reader, captured once per resolution. For a harness=claude crew with a
# readable pane it sets, from that single capture:
#   LIMIT_DETAIL - the BLOCKING banner detail (a blocking widget in the pane's
#                  composer region); the only signal that reports paused.
#   LIMIT_NOTICE - a limit name merely visible in that region with no blocking
#                  widget; annotates a working verdict, never changes it.
# Both empty (and non-zero) for any other harness, an unreadable pane, or a
# pane with neither signal. bin/fm-busy-lib.sh's fm_busy_claude_limit_banner
# header owns the verified wordings, the composer-region anchoring, and the
# deliberate limitation that a bare notice is not a pause; every path below
# consults this one helper so the override cannot drift between them.
claude_limit_scan() {
  local tail_text
  LIMIT_DETAIL=''
  LIMIT_NOTICE=''
  case "$HARNESS" in claude*) ;; *) return 1 ;; esac
  [ -n "$BACKEND_TARGET" ] || return 1
  pane_readable "$BACKEND_TARGET" || return 1
  tail_text=$(fm_backend_capture "$TASK_BACKEND" "$BACKEND_TARGET" 40 "$EXPECTED_LABEL" 2>/dev/null) || return 1
  LIMIT_DETAIL=$(printf '%s' "$tail_text" | fm_busy_claude_limit_banner) || LIMIT_DETAIL=''
  if [ -n "$LIMIT_DETAIL" ]; then
    return 0
  fi
  if printf '%s' "$tail_text" | fm_busy_claude_limit_notice; then
    LIMIT_NOTICE='limit notice visible in pane'
  fi
  [ -n "$LIMIT_NOTICE" ]
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
  fm_nm_run_has_gate "$RUN_OUT"
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
# `no-mistakes --help` lists it separately from `axi`; both halves of this split
# re-confirmed on v1.48.0, 2026-08-16). It is plain, human-
# oriented text - no run id, no JSON/TOON, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]" separated by runs of
# spaces (verified: no quoting, so splitting on the first two whitespace runs
# is exact) - but branch + coarse status is exactly what this predicate needs:
# is a run for THIS branch active right now. Echoes the matched row's status
# word (running/completed/cancelled/failed), or empty when the branch has no
# usable run within FM_CREW_STATE_RUNS_LIMIT rows.
#
# Rows are newest-first, and the precedence among them is ONE rule, stated here
# and nowhere else. A still-running row wins if and only if the branch's NEWEST
# row is itself running, and such a row needs no head match. Otherwise the answer
# is the first row that binds to this worktree, by its own status word. Otherwise
# the answer is empty.
#
# Why a running newest row needs no head match: the head rule exists to stop a
# HISTORICAL run on a reused branch from being attributed, and a run that is
# still executing cannot be history. A pipeline that rebased or rewrote its head
# (what `no-mistakes rerun` from a preserved head does) is exactly the case that
# must still be attributed to the crew whose branch it holds. A terminal or
# parked row still has to bind, exactly as before.
#
# Why the newest row decides: without running-wins, a crew whose cancelled or
# failed run was immediately replaced by a fresh one kept reporting the dead run
# as its current state (2026-08-16: snacksuite run 01M03RWN cancelled and
# replaced by 01M0492M running still read as "failed: run cancelled"; lensclash
# run 01M0490J failed and replaced by 01M04KJJ still read as "failed: run
# failed" while `axi status` showed running/fixing), and the watcher turned that
# into an inactive-crew false alarm. In both cases the branch's newest row IS the
# running replacement. Without the newest-row condition, an OLDER row left stuck
# at running would suppress a newer real terminal verdict, and a genuinely dead
# crew would read as working forever.
#
# Accepted residual risk: a row stuck at running at the TOP of the list is still
# read as working. The counterweight is the wedge-escalation progress probe
# (crew_run_progressed in bin/fm-classify-lib.sh), which goes through `axi
# status` and absorbs only on actual movement.
#
# Exit status separates "the listing answered" (0) from "the listing produced
# nothing at all" (1), because nm_run is fail-open: a timed-out or erroring CLI
# is indistinguishable from a clean answer by the printed word alone. Callers
# that only need the word can keep ignoring the status - an unanswered listing
# prints nothing either way - but a caller that would REMEMBER the answer must
# not remember a non-answer.
nm_runs_status_for_branch() {  # <branch>
  local branch=$1 out row st rest br sha newest=1
  out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
  [ -n "$out" ] || return 1
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
    [ "$br" = "$branch" ] || continue
    if [ "$newest" = 1 ]; then
      newest=0
      if [ "$st" = running ]; then
        printf 'running'
        return 0
      fi
    fi
    if nm_coarse_head_matches_worktree "$sha"; then
      printf '%s' "$st"
      return 0
    fi
  done <<< "$out"
  return 0
}

# Damping for the terminal-run supersession probe in the run-step path below. A
# terminal run that nothing ever
# replaces answers "not superseded" forever, and without a memory every single
# state read would pay another bounded `no-mistakes runs` call - worst for
# bin/fm-inactive-reconcile.sh, which calls this helper on exactly the done and
# failed children it exists to report, under a shared scan budget.
#
# Only the NEGATIVE answer is remembered, in state/.run-superseded-<id> holding
# the worktree head and the epoch it was written; a positive supersession is
# never served from cache. A recorded head other than the current one
# invalidates the entry outright, and an entry older than
# FM_RUN_SUPERSEDED_TTL is re-probed, so a real replacement is still detected
# well inside a heartbeat.
nm_supersession_cache_file() {
  printf '%s/.run-superseded-%s' "$STATE" "$ID"
}

# 0 when a still-valid "not superseded" answer is on record for this worktree head.
nm_supersession_absent_cached() {
  local file head recorded_head recorded_epoch now
  file=$(nm_supersession_cache_file)
  [ -f "$file" ] || return 1
  head=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || return 1
  [ -n "$head" ] || return 1
  read -r recorded_head recorded_epoch < "$file" || return 1
  [ "$recorded_head" = "$head" ] || return 1
  case "${recorded_epoch:-}" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s 2>/dev/null) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(( now - recorded_epoch ))" -lt "$FM_RUN_SUPERSEDED_TTL" ]
}

nm_supersession_record_absent() {
  local file head now tmp
  head=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || return 0
  [ -n "$head" ] || return 0
  now=$(date +%s 2>/dev/null) || return 0
  file=$(nm_supersession_cache_file)
  # Fixed temp name, not mktemp: a random suffix would force teardown to sweep
  # "$file".* to catch an orphan, and a task id may itself contain a dot
  # (fm_task_id_path_safe allows it), so that glob would delete a live sibling
  # task's records. There is no concurrent writer for one task - the watcher and
  # the away daemon are mutually exclusive by mode - and the rename below is
  # atomic regardless, so the deterministic name is safe. Do not restore mktemp.
  tmp="$file.tmp"
  if ( umask 077; printf '%s %s\n' "$head" "$now" > "$tmp" ); then
    mv -f -- "$tmp" "$file" || rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
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
# 1 when the attributed run is this crew's branch but its head has moved off the
# local line of history. Recorded in the detail so a reader can tell an ordinary
# attribution from this one; see the branch that sets it below.
RUN_HEAD_DIVERGED=0
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  if [ -n "$RUN_OUT" ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] && nm_run_head_matches_worktree; then
      HAVE_RUN=1
    elif [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] && fm_nm_run_is_executing "$RUN_OUT"; then
      # Same branch, executing right now, head off this line of history. A
      # pipeline that rebased its work or resumed from a preserved head leaves
      # exactly this shape, and the run still owns the crew's branch, so it IS
      # the current state. Attributing it here (rather than falling through to
      # the coarse list) keeps the run's own step detail instead of a bare
      # "validating". A parked or terminal run earns no such relaxation
      # (fm_nm_run_is_executing owns that boundary).
      HAVE_RUN=1
      RUN_HEAD_DIVERGED=1
    else
      # The active-or-most-recent run is for another branch, or same branch with
      # a rewritten/diverged head on an already-terminal run (the CLI is alive
      # and answered; only the attribution missed) - try the coarse fallback.
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
  # 1 only when the run OBJECT itself reported a terminal verdict, which the
  # supersession probe below needs to tell apart from the ci-green override -
  # that one reads done off a run that is still executing.
  RUN_TERMINAL=0
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
        passed)        RUN_STATE="done"; RUN_DETAIL="run passed: PR merged/closed"; RUN_TERMINAL=1 ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review"; RUN_TERMINAL=1 ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed"; RUN_TERMINAL=1 ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled"; RUN_TERMINAL=1 ;;
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
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed"; RUN_TERMINAL=1 ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed"; RUN_TERMINAL=1 ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled"; RUN_TERMINAL=1 ;;
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

  # A terminal run is the crew's current state only while nothing has replaced
  # it. The worker's own supersession sequence (abort or crash, recover custody,
  # start again) leaves the dead run as the most recent record for a while, and
  # reporting it as current is what produced the 2026-08-16 inactive-crew false
  # alarms documented on nm_runs_status_for_branch. That function is the ONE
  # owner of the newer-active-run-wins rule; consult it before letting a
  # terminal verdict stand. Both the failed and the done half are checked,
  # because bin/fm-inactive-reconcile.sh raises its inactive-terminal-outcome
  # record off either one (evidence 2026-08-16 10:35, lensclash-datenschutz-
  # loeschung: state=failed surfaced while `axi status` showed running). The
  # ci-green override is deliberately excluded via RUN_TERMINAL - that run is
  # still executing and is its own newest row. The coarse path already applied
  # the same rule when it resolved, and nm_supersession_absent_cached damps the
  # repeat cost for a terminal run nothing ever replaces. Only a listing that
  # actually ANSWERED may be remembered - a timed-out one leaves the cache alone
  # and costs just this read, rather than pinning the terminal verdict for a
  # whole TTL and handing bin/fm-inactive-reconcile.sh the false record this
  # exists to prevent.
  if [ "$RUN_TERMINAL" = 1 ] && [ "$RUN_SOURCE" = full ] \
     && { [ "$RUN_STATE" = failed ] || [ "$RUN_STATE" = "done" ]; } \
     && ! nm_supersession_absent_cached; then
    if REPLACEMENT_STATUS=$(nm_runs_status_for_branch "$CREW_BRANCH"); then
      if [ "$REPLACEMENT_STATUS" = running ]; then
        RUN_DETAIL="validating (background run)${SEP}superseded $RUN_DETAIL"
        RUN_STATE=working
      else
        nm_supersession_record_absent
      fi
    fi
  fi

  if [ "$RUN_HEAD_DIVERGED" = 1 ]; then
    RUN_DETAIL="$RUN_DETAIL${SEP}run head diverged from local copy"
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

  # A limit-blocked Claude pane is an external wait on the worker's side, but a
  # run attributed to this crew stays authoritative: a parked run is waiting on
  # a CAPTAIN decision the worker's quota block does not prevent, and an active
  # step may progress independently of the pane, so both keep their own state
  # and detail and only carry the pane's block as an appended note. A terminal
  # outcome (done/failed) is more informative than paused and is left alone.
  # Only a run whose state is neither parked, active, nor terminal falls
  # through to the pane's paused verdict.
  case "$RUN_STATE" in
    parked|working)
      if claude_limit_scan; then
        if [ -n "$LIMIT_DETAIL" ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}worker pane limit-blocked ($LIMIT_DETAIL)"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}$LIMIT_NOTICE"
        fi
      fi
      ;;
    done|failed)
      ;;
    *)
      if claude_limit_scan && [ -n "$LIMIT_DETAIL" ]; then
        emit paused pane "account limit: $LIMIT_DETAIL"
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
    busy)
      # A Claude worker parked on its own account/usage-limit banner is an
      # external wait, not a working turn - report paused instead of the
      # generic hook-derived busy, per fm_busy_claude_limit_banner's contract
      # (bin/fm-busy-lib.sh). Scoped to harness=claude only; every other
      # harness keeps the plain busy -> working mapping below.
      if claude_limit_scan; then
        if [ -n "$LIMIT_DETAIL" ]; then
          emit paused pane "account limit: $LIMIT_DETAIL"
        fi
        emit working pane "harness busy (${BUSY_VERDICT#* })${SEP}$LIMIT_NOTICE"
      fi
      emit working pane "harness busy (${BUSY_VERDICT#* })"
      ;;
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
