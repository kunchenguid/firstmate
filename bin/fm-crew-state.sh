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
#   state: <state> · source: <run-step|pane|status-log|none> · <detail>
#
# `--json` emits the SAME derivation as typed fields for machine consumers, so
# no caller has to recover structure by substring-matching the prose above. The
# prose mode is unchanged and remains the default.
#
# STATE VOCABULARY. Every condition this reader can encounter has its own
# verdict; none borrows another's, because a borrowed verdict is a confident
# answer to a question the evidence did not answer:
#   working      a run step is executing, or the harness is mid-turn
#   parked       waiting at a pipeline gate for a decision
#   blocked      stopped and needs firstmate
#   paused       a declared, expected external wait
#   done         terminal success
#   failed       the pipeline JUDGED the work and rejected it
#   aborted      the run was deliberately cancelled - no verdict on the work
#   interrupted  the run died without reaching a verdict (the pipeline broke,
#                e.g. "daemon crashed during execution"); the work was never
#                judged, so this is a re-run condition, not a rejection
#   idle         endpoint alive, nothing running, and no state-bearing event
#   stale        the winning evidence exists but has aged out of validity
#   unknown      genuinely no usable evidence
# `failed` vs `aborted` vs `interrupted` and `idle` vs `stale` vs `unknown` are
# the distinctions this reader used to collapse. Collapsing them made an
# infrastructure kill read as a rejection, a deliberate abort read as a failure,
# a dead worker read as working, and an ordinary decision-closing `resolved:`
# line read as "no current-state source available".
#
# FRESHNESS. A verdict names both which source won (precedence_applied) and how
# old that evidence was (evidence_age_secs). Evidence past its bound yields
# `stale`, never a live-looking answer - the busy record in particular carries a
# timestamp that was previously parsed for format only and never compared to the
# clock (see FM_BUSY_MAX_BUSY_AGE_SECS in bin/fm-busy-lib.sh).
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta.
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
#      passed/checks-passed -> done, cancelled -> aborted, and failed -> failed
#      unless the run carries positive evidence the pipeline broke without
#      judging the work, which reports interrupted
#      (nm_run_broke_without_verdict). EXCEPT: while
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
#      `resolved` never become current state or detail; a live endpoint whose
#      last event only closed a decision reports `idle`, not `unknown`.
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

# Output mode. Only `--json` is a recognized flag; every other argument is the
# task id, exactly as before. `--help` therefore stays an unknown id and still
# reports `state: unknown · source: none`, which is the contract callers that
# pass an arbitrary string already depend on.
MODE=prose
if [ "${1:-}" = --json ]; then
  MODE=json
  shift
fi
ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh [--json] <id>" >&2; exit 2; }

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
SEP=' · '

# Schema version for the structured mode. Bump when a field's MEANING changes;
# adding a field is backward compatible and does not need a bump.
FM_CREW_STATE_SCHEMA=1

# Typed context for the structured mode, set at the point each answer is
# derived. Empty means "this reader did not measure it for this answer" - never
# a fabricated zero or a stand-in value, so a consumer can always distinguish an
# unmeasured field from a measured one.
#
# PRECEDENCE names the rule that SELECTED this answer. Lane B's Law 3 requires
# precedence between disagreeing deterministic sources to be declared in code
# rather than left implicit; emitting it makes the declaration visible to the
# consumer instead of hiding it in this file's control flow.
PRECEDENCE=""
BUSY_SIGNAL=""
RUN_STEP=""
EVIDENCE_AGE=""
TERMINAL_ERROR=""
RUN_ID=""
# The busy record's strictly-increasing sequence number: this architecture's own
# advancing-evidence counter. A consumer comparing it across two reads learns
# whether the worker's turn state actually moved, which is what a rendered-pane
# hash used to approximate - less reliably, since the semantic busy-state
# redesign exists precisely because rendered output is not turn state.
BUSY_SEQ=""

# Every C0 control character that the named escapes below do not cover, in one
# string. JSON forbids a RAW control character inside a string, and this object
# carries verbatim tool output: terminal_error is the pipeline's own `error:`
# text, which routinely contains ANSI escape sequences. One raw byte of that
# produced an object bin/fm-fleet-snapshot.sh's jq validation rejected, which
# replaced a correct failed/interrupted verdict with `unknown` - a reader
# defeated by the shape of the evidence it was quoting. NUL is absent because a
# bash variable cannot hold one.
FM_CREW_STATE_JSON_CONTROLS=$'\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037'

# Minimal JSON string escaping. Hand-rolled rather than shelling out to jq
# because this reader runs on every heartbeat and jq is not a required tool for
# a home that has not opted into the features that need it.
json_escape() {  # <text>
  local s=$1 c hex i
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  # The scan runs only when a control byte actually survived the named escapes
  # above, so the ordinary all-printable answer pays one glob match.
  case "$s" in
    *[[:cntrl:]]*)
      for (( i = 0; i < ${#FM_CREW_STATE_JSON_CONTROLS}; i++ )); do
        c=${FM_CREW_STATE_JSON_CONTROLS:i:1}
        case "$s" in
          *"$c"*)
            printf -v hex '\\u%04x' "'$c"
            s=${s//"$c"/"$hex"}
            ;;
        esac
      done
      ;;
  esac
  printf '%s' "$s"
}

# Emit the one canonical answer and exit 0. Detail is optional. Both modes
# render the SAME derivation: the structured mode adds typed fields, and never
# reaches a verdict the prose mode would not.
emit() {  # <state> <source> [detail]
  if [ "$MODE" = json ]; then
    printf '{"schema":%s,"id":"%s","state":"%s","source":"%s","precedence_applied":"%s"' \
      "$FM_CREW_STATE_SCHEMA" "$(json_escape "$ID")" "$(json_escape "$1")" \
      "$(json_escape "$2")" "$(json_escape "$PRECEDENCE")"
    printf ',"busy_signal":%s' "$(json_field_or_null "$BUSY_SIGNAL")"
    printf ',"busy_seq":%s' "${BUSY_SEQ:-null}"
    printf ',"run_step":%s' "$(json_field_or_null "$RUN_STEP")"
    printf ',"run_id":%s' "$(json_field_or_null "$RUN_ID")"
    printf ',"terminal_error":%s' "$(json_field_or_null "$TERMINAL_ERROR")"
    printf ',"evidence_age_secs":%s' "${EVIDENCE_AGE:-null}"
    printf ',"detail":%s}\n' "$(json_field_or_null "${3:-}")"
    exit 0
  fi
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# A JSON string, or bare null when this reader did not measure the field.
json_field_or_null() {  # <text>
  [ -n "${1:-}" ] || { printf 'null'; return; }
  printf '"%s"' "$(json_escape "$1")"
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || { PRECEDENCE='no-metadata'; emit unknown none "no metadata for $ID"; }

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
HARNESS=$(meta_value harness)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  PRECEDENCE='worktree-gone'
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
# The pipeline's own top-level `error:` on a terminal run, unquoted. Verified
# against the installed no-mistakes v1.40.3 across real terminal runs:
#   error: "step review failed: refusing to commit review changes: ..."
#   error: "step test failed: agent run tests: claude exited: exit status 1: "
#   error: daemon crashed during execution
# Both quoted and bare forms occur, so strip_quotes normalizes them.
nm_terminal_error() {
  local line
  line=$(printf '%s\n' "$RUN_OUT" | grep -E '^error:[[:space:]]*' | head -1) || true
  [ -n "$line" ] || return 0
  strip_quotes "$(trim "${line#error:}")"
}

# 0 when the run carries POSITIVE evidence that the pipeline itself broke rather
# than judging the work: a terminal error exists, and it is NOT attributed to one
# of the pipeline's own steps. The pipeline prefixes step-attributed errors with
# "step <name> failed:"; the measured unattributed case is "daemon crashed
# during execution", which appeared five times in one recent run history and
# reached firstmate as a rejection every time.
#
# Positive evidence is REQUIRED. A terminal failure with no error field at all
# proves nothing about which happened, so it keeps the plain `failed` verdict
# instead of being upgraded to `interrupted` on the strength of a missing field.
# Absence of evidence must not manufacture a claim in either direction, and the
# conservative direction is to leave the pre-existing verdict alone.
#
# This tests only the pipeline's own STRUCTURAL attribution marker. It
# deliberately does NOT read the error prose to decide whether a given step
# failure was "really" the code's fault: that is a semantic judgement, and
# encoding it as message-matching here would be exactly the brittle guesswork
# this reader exists to avoid. The full text travels to the caller as
# terminal_error so a reader that needs the reason has it verbatim.
nm_run_broke_without_verdict() {  # <error-text>
  [ -n "$1" ] || return 1
  case "$1" in
    "step "*" failed:"*) return 1 ;;
    *) return 0 ;;
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
    # The coarse runs list is plain text with no run id and no error field, so
    # a terminal failure here CANNOT be attributed to a step or to the pipeline
    # breaking. It stays `failed` rather than guessing, and says so in the
    # detail; precedence_applied reports the degraded source so a consumer can
    # see the attribution was unavailable rather than absent-because-clean. A
    # cancelled run needs no error field to be recognized as a deliberate stop.
    case "$COARSE_STATUS" in
      running)   RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      completed) RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)    RUN_STATE=failed;  RUN_DETAIL="run failed (runs list: failure reason unattributed)" ;;
      cancelled) RUN_STATE=aborted; RUN_DETAIL="run cancelled: stopped deliberately, work not judged" ;;
      *)         RUN_STATE=unknown; RUN_DETAIL="unrecognized runs list status: $COARSE_STATUS" ;;
    esac
  else
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    RUN_ID=$(strip_quotes "$(nm_field id)")
    # The step the pipeline is actually on, so a consumer never has to recover
    # it by matching the detail prose.
    RUN_STEP=$status
    outcome=$(strip_quotes "$(nm_field outcome)")
    awaiting=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
    gate_status=$(nm_gate_status)
    has_gate=0
    nm_has_gate && has_gate=1

    if [ -n "$outcome" ]; then
      TERMINAL_ERROR=$(nm_terminal_error)
      case "$outcome" in
        passed)        RUN_STATE="done"; RUN_DETAIL="run passed: PR merged/closed" ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
        # A terminal failure is only a REJECTION when a pipeline step reached a
        # verdict on the work. When the pipeline itself broke, the work was
        # never judged: reporting that as `failed` told firstmate the change was
        # rejected and sent it to fix code that nothing had criticised. It is a
        # re-run condition, so it gets its own verdict.
        failed)
          if nm_run_broke_without_verdict "$TERMINAL_ERROR"; then
            RUN_STATE=interrupted
            RUN_DETAIL="run stopped without judging the work: $TERMINAL_ERROR"
          else
            RUN_STATE=failed
            RUN_DETAIL="run failed: the pipeline judged the work and rejected it"
          fi
          ;;
        # A deliberate abort is not a failure. Supersession (AGENTS.md's
        # validate contract) aborts a run on purpose, and reporting that as
        # `failed` made an intended stop look like rejected work.
        cancelled)     RUN_STATE=aborted; RUN_DETAIL="run cancelled: stopped deliberately, work not judged" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="unrecognized run outcome: $outcome" ;;
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
      # Same failed/aborted/interrupted split as the outcome arm above: this is
      # the full TOON path, so the pipeline's own error attribution is
      # available here too and must not be discarded just because the run
      # reported a terminal status without a separate outcome field.
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
        failed)
          TERMINAL_ERROR=$(nm_terminal_error)
          if nm_run_broke_without_verdict "$TERMINAL_ERROR"; then
            RUN_STATE=interrupted
            RUN_DETAIL="run stopped without judging the work: $TERMINAL_ERROR"
          else
            RUN_STATE=failed
            RUN_DETAIL="run failed: the pipeline judged the work and rejected it"
          fi
          ;;
        cancelled)      RUN_STATE=aborted; RUN_DETAIL="run cancelled: stopped deliberately, work not judged" ;;
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
    PRECEDENCE='status-log-ci-ready-over-monitoring-run'
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
  PRECEDENCE='run-step-over-status-log'
  [ "$RUN_SOURCE" = coarse ] && PRECEDENCE='coarse-runs-list-over-status-log'
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        PRECEDENCE='run-step-supersedes-status-log'
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
[ -n "$BACKEND_TARGET" ] || { PRECEDENCE='no-backend-target'; emit unknown none "no backend target recorded"; }
if ! pane_readable "$BACKEND_TARGET"; then
  PRECEDENCE='endpoint-gone'
  emit unknown none "backend target gone: $BACKEND_TARGET"
fi

# Age of this task's busy record, when it has one. Only a record-backed busy
# verdict has a measurable age; the live sources (herdr native, muse session
# log, grok rendered tail) are read fresh and have none, and reporting a made-up
# age for them would be a freshness reading that was never taken.
# Sets EVIDENCE_AGE and BUSY_SEQ from this task's busy record when it has one.
# fm_busy_record_read prints "<state> <source> <event> <seq> <age>" for a usable
# record, and names its reason on the failure path.
#
# The EXPIRED reason is read too, and that is the point: expiry is a judgement
# ABOUT the evidence, so discarding the evidence that produced it left the one
# verdict whose whole meaning is "this aged out" unable to say by how much. A
# `stale` answer that cannot distinguish a record 61 minutes old from one 3 days
# old is barely better than the boolean this replaced. Every other reason
# (missing, malformed, gen-mismatch) names a record there is nothing to measure.
read_busy_evidence() {
  local rec
  if ! rec=$(fm_busy_record_read "$STATE" "$ID"); then
    case "$rec" in
      'expired '*)
        rec=${rec#expired }
        BUSY_SEQ=${rec%% *}
        EVIDENCE_AGE=${rec##* }
        ;;
    esac
    return 0
  fi
  EVIDENCE_AGE=${rec##* }
  rec=${rec% *}
  BUSY_SEQ=${rec##* }
}

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# state is not meaningful for them; read their state from the status log only.
# Only an exact busy verdict reports working here, and only an exact idle
# verdict permits the status-log fallback below. Missing, malformed, stale, or
# unverified semantic state remains unknown.
if [ "$KIND" != secondmate ]; then
  BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
  BUSY_SIGNAL=$BUSY_VERDICT
  read_busy_evidence
  case "${BUSY_VERDICT%% *}" in
    busy)
      PRECEDENCE='busy-signal-over-status-log'
      emit working pane "harness busy (${BUSY_VERDICT#* })"
      ;;
    idle) ;;
    # The record existed and aged out, which is a different answer from never
    # having had one. What the age establishes is exactly this and no more:
    # nothing has touched the record since its timestamp. It does NOT establish
    # that the worker stopped - nothing observed that - and the detail must not
    # say so, because the record's timestamp is stamped when a turn opens and
    # does not tick within it (see FM_BUSY_MAX_BUSY_AGE_SECS in
    # bin/fm-busy-lib.sh, which records that bound and the advancing-evidence
    # signal that would remove it). Reporting `unknown` here would throw away a
    # measurement that was actually taken, and reporting `working` from that
    # record is the defect this replaces - a stopped worker read as busy forever.
    stale)
      PRECEDENCE='busy-signal-expired'
      emit stale pane "harness turn evidence expired (${BUSY_VERDICT#* }); no evidence of activity since the recorded timestamp (${EVIDENCE_AGE:-unknown}s ago)"
      ;;
    *)
      PRECEDENCE='busy-signal-unusable'
      emit unknown pane "harness state unavailable ($BUSY_VERDICT)"
      ;;
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
    PRECEDENCE='status-log-only'
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

# Everything above declined to answer, but that is NOT the same as having no
# source. To reach here the endpoint was readable, and for an ordinary crew the
# busy signal said idle - both positive facts. The only thing missing is a
# DECLARED state, because the log's last event either closes a decision
# (`resolved:`, `captain-held:`) or the log is empty.
#
# This used to report `unknown · none · no current-state source available`,
# which was measured on the very `resolved:` line every brief instructs workers
# to write. That claimed no source existed when two did, and it fell out of a
# mapping that had no case for the verb rather than from any decision about it.
# An alive, idle crew with nothing to declare is a KNOWN condition and gets its
# own verdict.
#
# `unknown` stays reachable and stays meaningful: a torn-down worktree, missing
# metadata, a dead endpoint, and an unusable busy signal all still report it
# above. This case is carved out because it is genuinely knowable, not to make
# `unknown` unreachable - a reader that cannot say "I do not know" is worse than
# one that says it too often.
if status_verb_is_decision_closing "$LOG_VERB"; then
  PRECEDENCE='decision-event-is-not-a-state'
  emit idle status-log "endpoint alive and idle; last event closed a decision ($LOG_VERB), no state declared since"
fi

# A verb outside the whole recognized vocabulary is the one case here that is
# genuinely unknowable: the log says something this reader has no mapping for,
# and inventing a state from it would be exactly the guess that made the
# decision-closing verbs report "no current-state source available". `idle`
# would be a claim; `unknown` is the truth, and it names the verb so the gap is
# fixable rather than invisible.
if [ -n "$LOG_VERB" ]; then
  PRECEDENCE='unrecognized-status-verb'
  emit unknown status-log "endpoint alive and idle; last event verb is outside the recognized vocabulary ($LOG_VERB)"
fi

PRECEDENCE='endpoint-alive-no-declared-state'
emit idle pane "endpoint alive and idle; no run attributed and no state declared"
