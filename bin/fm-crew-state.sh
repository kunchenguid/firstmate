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
#   state: <working|parked|done|blocked|paused|failed|stopped|exited|unknown> · source: <run-step|pane|status-log|declared-stop|remote-endpoint|none> · <detail>
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
#      More than one recorded run can bind to this worktree at once, and
#      bin/fm-nm-run-lib.sh also owns which of them wins: a LIVE run always
#      outranks a terminal one, so a terminal answer here is provisional until
#      the ledger has been asked whether a live sibling run exists.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see nm_ci_checks_state) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating. And a
#      terminal FAILED run whose only failure is the ci monitor step, after
#      every substantive step completed and the ci log's last marker reads
#      checks green, also reads done (held-for-merge), never failed: a monitor
#      whose only remaining job is to observe a human merge decision must not
#      convert the absence of that decision into a failure verdict
#      (nm_failed_run_is_green_held_ci; 2026-09-05 jr-voice incident). In the
#      coarse runs-ledger fallback (no steps table, no ci log), a terminal
#      FAILED record whose daemon an explicit probe proves down reads unknown,
#      never failed: an instrument failure must not read as work failure
#      (nm_daemon_probe_down).
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked. A `blocked:` line that reports a
#      refused or missing daemon socket remains blocked even if an attributed
#      run record is stale or terminal. Other daemon, timeout, or unreachability
#      claims are superseded BECAUSE THE RUN IS ALIVE when the run is
#      running/fixing with recent reported activity: a killed or timed-out drive
#      call is not daemon death, so that claim is answered by steering the crew
#      to reattach, not by escalating.
#   4. No run for this crew (pre-validation, or kind=scout): ask the endpoint
#      what is actually there before believing any record about it. A readable
#      target proves only that the SHELL survives, so a frozen agent reports
#      suspended, an agent firstmate itself stopped through the control plane
#      reports `stopped`, and an agent that EXITED with no terminal status line
#      reports `exited` - none of them may fall through to a record its own
#      writer is no longer around to advance. An agent that is merely idle or
#      unreachable is never reported gone, and neither is one whose record was
#      published so recently that its harness cannot be expected to have
#      started yet (the registration grace at within_spawn_grace, below). Then
#      the recorded backend's pane busy state, then the status log's last line
#      only when its verb maps to a recognized run-state. A busy opencode lane
#      whose own record event is still session-retry and whose retry-backoff
#      horizon is quota-scale reads `blocked`, not working
#      (fm_crew_opencode_cap_detail, contract in bin/fm-opencode-retry.sh).
#      Decision-only events such as `resolved` never become current state or
#      detail.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log. On tmux and herdr, which own a
#      recovery-grade classifier, only its positive death evidence reads as gone
#      (the endpoint is authoritatively absent, or its pane holds no agent); an
#      endpoint that merely failed to answer reports unknown · none as
#      unreachable, and an alive endpoint whose scrollback read failed is still
#      classified by step 4. Backends with no classifier keep reading a failed
#      capture as gone. The fallback's own comment owns the per-verdict rules.
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
# shellcheck source=bin/fm-stopped-lib.sh
. "$SCRIPT_DIR/fm-stopped-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

# Fleet snapshot composition supplies its captured metadata path here so every
# state read resolves the same task generation selected by that snapshot.
META=${FM_CREW_STATE_META_OVERRIDE:-"$STATE/$ID.meta"}
LOG=${FM_CREW_STATE_STATUS_OVERRIDE:-"$STATE/$ID.status"}
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows each ledger read
# (fm_nm_runs_status_for_worktree in bin/fm-nm-run-lib.sh) scans, whether it is
# the cross-branch fallback or the live-sibling probe behind a terminal `axi
# status` answer (docs/configuration.md owns the setting). Generous enough to
# still find a branch's own run on a busy multi-crew fleet without listing the
# entire history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
# Seconds after a task's endpoint record is published during which an
# agent-free endpoint is NOT yet evidence that the agent left. See
# within_spawn_grace below for what it guards; the value is bounded from both
# sides by constants this fleet already lives with:
#   floor - bin/fm-spawn.sh already allows a launched harness 30s to become
#     usable in its endpoint (kimi_wait_for_ready: 60 polls x 0.5s), which is
#     firstmate's own standing statement of how slow a start may legitimately
#     be. The grace has to cover at least that, plus the launch line's delivery,
#     which happens after the record is published.
#   ceiling - the watcher does not escalate an idle worker as a possible wedge
#     until FM_STALE_ESCALATE_SECS (240s, bin/fm-watch.sh), so any grace well
#     under that costs a worker that really did die on arrival no supervision
#     latency it did not already have.
# 60 doubles the known startup budget for cold-start headroom (first run after
# an upgrade, a cold binary, a loaded machine) and stays at a quarter of the
# escalation floor. Cheap to be generous here and expensive to be tight: being
# late to notice a dead-on-arrival worker costs one poll interval, while being
# early to call a starting worker gone licenses a second agent on its worktree.
FM_CREW_STATE_SPAWN_GRACE=${FM_CREW_STATE_SPAWN_GRACE:-60}
case "$FM_CREW_STATE_SPAWN_GRACE" in ''|*[!0-9]*) FM_CREW_STATE_SPAWN_GRACE=60 ;; esac
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

# --- spawn-registration grace ----------------------------------------------
# Epoch seconds at which THIS incarnation's endpoint record was published.
# bin/fm-spawn.sh stamps spawned_at= on every fresh spawn and every relaunch. A
# record written by an older spawn carries none, and the record file's own mtime
# bounds the same thing instead - a later writer (bin/fm-pr-check.sh records pr=
# into it) can only move that forward, which lengthens the grace rather than
# shortening it, and long is the safe direction for a guard whose failure mode
# is a duplicate agent.
record_published_at() {
  local at
  at=$(meta_value spawned_at)
  case "$at" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$at"; return 0 ;;
  esac
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f %m "$META" 2>/dev/null
  else
    stat -c %Y "$META" 2>/dev/null
  fi
}

# True while this task's record is too young for an agent-free endpoint to mean
# anything. The record is published the moment the endpoint exists, and the
# harness only enters that endpoint's foreground process group once it has
# actually started - so until it does, the endpoint is shells alone, which is
# byte-for-byte what a departed agent leaves behind. fm_backend_agent_state is
# right either way; it is being asked a question it cannot answer.
#
# That gap is why this exists and why it guards `exited` alone: `exited` is the
# one verdict that licenses a relaunch, and a relaunch onto a worker that is
# merely still starting puts a SECOND agent on one worktree. Elapsed time is
# the only thing that separates the two cases - no further endpoint evidence
# can, because a harness that has not started has painted nothing to read.
# A timestamp that cannot be read at all, or one in the future (clock skew),
# holds the grace rather than dropping it, and says which case it is in
# SPAWN_GRACE_REASON so the emitted detail names what is actually unknown
# instead of implying a measured age.
SPAWN_GRACE_REASON=
within_spawn_grace() {
  local at now age
  SPAWN_GRACE_REASON=
  at=$(record_published_at)
  case "$at" in
    ''|*[!0-9]*)
      SPAWN_GRACE_REASON="this task's record carries no readable publication time, so how long ago it was published cannot be established"
      return 0
      ;;
  esac
  now=$(date +%s)
  age=$((now - at))
  [ "$age" -lt "$FM_CREW_STATE_SPAWN_GRACE" ] || return 1
  [ "$age" -ge 0 ] || age=0
  SPAWN_GRACE_REASON="this task's record was published ${age}s ago, inside the ${FM_CREW_STATE_SPAWN_GRACE}s a launched harness is allowed to finish starting"
  return 0
}

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
# A line predating THIS incarnation's publication is not this crew's: after a
# relaunch the log still ends with the previous incarnation's last line until
# the replacement appends its own, and reading it would misattribute the old
# verdict to the new worker. The publication clock is spawned_at= content when
# the record carries it (bin/fm-spawn.sh stamps it on every fresh spawn and
# every relaunch, and content survives later meta rewrites and snapshot
# copies), falling back to the record file's own mtime for older records -
# whose staleness proof is weaker but still rejects an ancient log.
# The mtime fallback compares against the ORIGINAL record's mtime: the fleet
# snapshot must preserve it when capturing metadata (cp -p), because a
# freshly copied meta would discard lines this incarnation actually wrote.
log_last_line() {
  [ -f "$LOG" ] || return 1

  local at log_mtime
  at=$(record_published_at)
  case "$at" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
        log_mtime=$(stat -f %m "$LOG" 2>/dev/null || true)
      else
        log_mtime=$(stat -c %Y "$LOG" 2>/dev/null || true)
      fi
      if [ -n "$log_mtime" ] && [ "$log_mtime" -lt "$at" ]; then
        return 1
      fi
      ;;
  esac

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

# fm_crew_opencode_cap_detail: the usage-cap override. A capped opencode lane
# still reports busy - the vendor holds the session in `retry` with an
# hours-long backoff instead of failing - so a busy verdict alone cannot tell
# it from a working lane. Prints the blocked detail and returns 0 on either
# shape: the structural one (all three hold: the task runs on opencode, its
# semantic record's own event is still the latched `session-retry` - a
# genuinely resumed turn writes `session-busy` first, which drops this verdict
# even if a stale sidecar survives - and bin/fm-opencode-retry.sh, contract
# owned there, classifies the vendor's own backoff horizon as quota-scale),
# or the idle one (2026-09-14: the record says the turn ended on the plugin's
# idle event and the pane tail carries the cap verbatim through the same
# helper's scan-text; a working lane's scrollback never counts). Anything else
# returns 1, keeping the existing working verdict. Reads only the task's own
# record, sidecar, and pane tail.
fm_retry_horizon_human() {  # <seconds>
  local s=$1 h m
  case "$s" in ''|*[!0-9]*) printf '~?'; return ;; esac
  if [ "$s" -ge 3600 ]; then
    h=$((s / 3600)); m=$(((s % 3600) / 60))
    printf '~%sh%sm' "$h" "$m"
  elif [ "$s" -ge 60 ]; then
    m=$((s / 60)); s=$((s % 60))
    printf '~%sm%ss' "$m" "$s"
  else
    printf '~%ss' "$s"
  fi
}

fm_crew_opencode_cap_detail() {
  local rec rest r_state r_source r_event retry_out f cap_tail
  local r_status='' r_attempt='' r_horizon='' r_model='' r_match=''
  case "$HARNESS" in opencode*) ;; *) return 1 ;; esac
  rec=$(fm_busy_record_read "$STATE" "$ID") || return 1
  r_state=${rec%% *}; rest=${rec#* }
  r_source=${rest%% *}; rest=${rest#* }
  r_event=${rest%% *}
  [ "$r_source" = opencode-plugin ] || return 1
  if [ "$r_state" = busy ] && [ "$r_event" = session-retry ]; then
    retry_out=$("$SCRIPT_DIR/fm-opencode-retry.sh" check "$STATE" "$ID" 2>/dev/null) || return 1
    for f in $retry_out; do
      case "$f" in
        status=*) r_status=${f#status=} ;;
        attempt=*) r_attempt=${f#attempt=} ;;
        horizon_s=*) r_horizon=${f#horizon_s=} ;;
        model=*) r_model=${f#model=} ;;
      esac
    done
    [ "$r_status" = blocked ] || return 1
    case "$r_attempt" in ''|*[!0-9]*) return 1 ;; esac
    case "$r_horizon" in ''|*[!0-9]*) return 1 ;; esac
    if [ -n "$r_model" ]; then
      r_model=", model $r_model"
    fi
    printf 'opencode quota-scale retry backoff (attempt %s, next retry in %s%s): vendor holds the session in retry, no forward progress until then' \
      "$r_attempt" "$(fm_retry_horizon_human "$r_horizon")" "$r_model"
    return 0
  fi
  # The idle shape: the turn ended on the plugin's idle event with no sidecar
  # left, and the pane tail still shows the cap verbatim. A busy lane never
  # reaches here, so old scrollback on a working lane cannot report blocked.
  [ "$r_state" = idle ] || return 1
  case "$r_event" in session-idle|session-status-idle) ;; *) return 1 ;; esac
  case "${TASK_BACKEND:-}" in '' ) return 1 ;; esac
  case "${BACKEND_TARGET:-}" in '' ) return 1 ;; esac
  cap_tail=$(mktemp "${TMPDIR:-/tmp}/fm-opencode-cap.XXXXXX") || return 1
  if ! fm_backend_capture "$TASK_BACKEND" "$BACKEND_TARGET" \
    "${FM_OPENCODE_CAP_TEXT_LINES:-60}" "$EXPECTED_LABEL" > "$cap_tail" 2>/dev/null; then
    rm -f "$cap_tail"
    return 1
  fi
  retry_out=$("$SCRIPT_DIR/fm-opencode-retry.sh" scan-text --file "$cap_tail" 2>/dev/null) \
    || { rm -f "$cap_tail"; return 1; }
  rm -f "$cap_tail"
  for f in $retry_out; do
    case "$f" in match=*) r_match=${f#match=} ;; esac
  done
  [ -n "$r_match" ] || return 1
  printf 'opencode free-tier cap shown in pane (idle after the refusal, %s, no retry horizon on record): vendor parked the session with no forward progress' \
    "$r_match"
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

# 0 when a status-log line reports positive daemon socket failure rather than a
# client-side timeout or generic unreachability.
log_reports_daemon_socket_down() {  # <line>
  local line
  line=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$line" in
    *daemon*|*no-mistakes*) ;;
    *) return 1 ;;
  esac
  case "$line" in
    *"connection refused"*|*"connections refused"*|*"socket refused connection"*|*"socket refuses connection"*|*"socket refusing connection"*|*"socket missing"*|*"socket is missing"*|*"missing socket"*) return 0 ;;
  esac
  return 1
}

# 0 when a status-log line blames the pipeline's transport rather than the work.
# None of these claims alone is evidence the daemon died: a drive call is only
# waiting for a read while the fix round runs in the background.
log_claims_pipeline_unreachable() {  # <line>
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *daemon*|*timeout*|*"timed out"*|*unreachab*) return 0 ;;
  esac
  return 1
}

# Rows of the `active_steps[N]{...}:` table in the captured run output
# ($RUN_OUT), which the pipeline emits only while a step is actually running or
# fixing. Column order is deliberately not assumed: the header's own indentation
# bounds the block, and callers below read the table as text.
nm_active_steps_rows() {
  printf '%s\n' "$RUN_OUT" | awk '
    /^[[:space:]]*active_steps\[[0-9]+\]\{/ { hdr = index($0, "active_steps"); inblock = 1; next }
    inblock {
      if ($0 ~ /^[[:space:]]*$/) { inblock = 0; next }
      match($0, /[^ \t]/)
      if (RSTART <= hdr) { inblock = 0; next }
      print
    }
  '
}

# Rows of the `steps[N]{step,status,findings,duration_ms}:` table in the
# captured run output ($RUN_OUT) - the full per-step ledger, present on
# terminal runs too, unlike active_steps[] which the pipeline emits only while
# a step is actually running or fixing. Column order is deliberately not
# assumed: the header's own indentation bounds the block, and callers below
# read the table as text.
nm_steps_rows() {
  printf '%s\n' "$RUN_OUT" | awk '
    /^[[:space:]]*steps\[[0-9]+\]\{/ { hdr = index($0, "steps"); inblock = 1; next }
    inblock {
      if ($0 ~ /^[[:space:]]*$/) { inblock = 0; next }
      match($0, /[^ \t]/)
      if (RSTART <= hdr) { inblock = 0; next }
      print
    }
  '
}

# 0 when the pipeline itself reports RECENT activity on an actively running or
# fixing step. The client prefixes a step's `last_activity` with `quiet` once no
# step log or native-agent lifecycle event has arrived for longer than its
# configured quiet warning, so its own recency verdict is the signal here rather
# than a second threshold invented in firstmate. Positive evidence is required:
# an absent table is not recency, so a run record that merely still says
# `running` while nothing executes it never reads as alive.
nm_run_activity_is_recent() {
  local rows
  rows=$(nm_active_steps_rows)
  [ -n "$rows" ] || return 1
  ! printf '%s\n' "$rows" | grep -q 'quiet'
}

# 0 when a terminal FAILED run's only failure is the ci monitor step and the
# ci log's last recognized marker reads checks green. Requires the exact
# shape, all on positive evidence: a steps[] table where every step completed
# except exactly `ci` failed (any other non-completed status, or a second
# failed step, disqualifies), plus nm_ci_checks_state=green (a genuinely red
# check, or an unreadable ci log, keeps the failure a failure). This is the
# orphaned-CI-monitor gap (2026-09-05 jr-voice): a run held for a captain
# merge decision polls until the shared daemon restarts under it and marks
# the run failed, although GitHub's own check state - the actual shippability
# authority - is green and every substantive step completed.
nm_failed_run_is_green_held_ci() {
  local rows row rest step status saw_ci_failed
  rows=$(nm_steps_rows)
  [ -n "$rows" ] || return 1
  saw_ci_failed=0
  while IFS= read -r row; do
    row=$(trim "$row")
    step=$(trim "${row%%,*}")
    rest=${row#*,}
    status=$(strip_quotes "$(trim "${rest%%,*}")")
    case "$status" in
      completed) continue ;;
      failed)
        [ "$step" = ci ] || return 1
        saw_ci_failed=1
        continue
        ;;
      *) return 1 ;;
    esac
  done <<EOF
$rows
EOF
  [ "$saw_ci_failed" = 1 ] || return 1
  [ "$(nm_ci_checks_state)" = green ]
}

# Reclassify a terminal failed run as done (held-for-merge) when
# nm_failed_run_is_green_held_ci matches, surfacing the run's PR URL so the
# supervisor reads the concrete review-ready outcome instead of a failure.
nm_reclassify_failed_run_as_held_green() {
  nm_failed_run_is_green_held_ci || return 1
  RUN_STATE="done"
  RUN_DETAIL="checks green: PR held for merge (ci monitor ended)"
  local pr_url
  pr_url=$(strip_quotes "$(nm_field pr)")
  [ -n "$pr_url" ] && RUN_DETAIL="$RUN_DETAIL: $pr_url"
  return 0
}

# 0 when an explicit probe proves the shared daemon down: `no-mistakes daemon
# status` is the canonical down-probe (the same one fm-brief.sh hands crews
# before a blocked append) and exits non-zero when the daemon is not running.
# Bounded like every other CLI call; a probe that fails for any reason -
# refused socket, timeout, non-zero answer - means the daemon is not provably
# up, which is the only fact the coarse fallback needs.
nm_daemon_probe_down() {
  fm_nm_run_checked "$WT" "$NM_TIMEOUT" daemon status >/dev/null || return 0
  return 1
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
# the ledger format, the newest-row-decides rule, its live-over-terminal
# exception, and the anchored pipeline-continuation recognition
# (model-routing-benchmark-hardening: an active fix round whose head object the
# task copy never fetched used to be rejected here, letting the older failed row
# answer as current), so both attribution routes share one rule.
# The same reader is also consulted when `axi status` DID bind this branch's run
# but that run is terminal, to find a live sibling run for this worktree.
nm_runs_list() {
  nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT"
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
      # Live-over-terminal (bin/fm-nm-run-lib.sh). Bare `axi status` answers
      # with the most-recently-touched run, which after a pipeline crash is the
      # dead run sitting at this worktree's exact commit while the live run
      # that replaced it validates a descendant commit on the same branch. Both
      # bind, so a terminal answer is provisional until the ledger has been
      # asked whether this worktree also has a live run. Only a live word
      # displaces it: a terminal run with no live sibling keeps its full
      # `axi status` step and gate detail rather than degrading to the ledger.
      if ! fm_nm_run_is_active "$RUN_OUT"; then
        live_status=$(fm_nm_runs_status_for_worktree "$WT" "$CREW_BRANCH" "$(nm_runs_list)")
        if [ "$(fm_nm_run_status_class "$live_status")" = live ]; then
          COARSE_STATUS=$live_status
          RUN_SOURCE=coarse
        fi
      fi
    else
      # The active-or-most-recent run is for another branch, or it names this
      # branch with a head this copy cannot verify (a pipeline-advanced fix
      # round, or a rewritten tip). Deliberately nested inside
      # `[ -n "$RUN_OUT" ]`: an empty/timed-out primary call means the CLI
      # itself did not respond, so retrying it immediately with a second
      # bounded call would just double the wait for no better answer.
      COARSE_STATUS=$(fm_nm_runs_status_for_worktree "$WT" "$CREW_BRANCH" "$(nm_runs_list)")
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
      failed)
        # The ledger row is terminal but the coarse path has no steps table
        # and no ci log, so the orphaned-monitor shape cannot be recognized
        # here. With the daemon provably down, the row is unverified evidence
        # from a dead instrument and must not read as work failure.
        if nm_daemon_probe_down; then
          RUN_STATE=unknown
          RUN_DETAIL="no-mistakes daemon unreachable; last ledger record failed - unverified"
        else
          RUN_STATE=failed; RUN_DETAIL="run failed"
        fi ;;
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
        failed)
          if nm_reclassify_failed_run_as_held_green; then :; else
            RUN_STATE=failed; RUN_DETAIL="run failed"
          fi ;;
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
        failed)
          if nm_reclassify_failed_run_as_held_green; then :; else
            RUN_STATE=failed; RUN_DETAIL="run failed"
          fi ;;
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
  #
  # A refused or missing daemon socket is positive daemon-down evidence and
  # outranks any attributed run record, including a terminal one left behind
  # after the daemon stopped. Other blocked claims caused by a timed-out drive
  # call are contradicted only when the run reports recent
  # activity; the answer is then to steer the crew to reattach without touching
  # the shared daemon.
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$LOG_VERB" = blocked ] \
        && log_reports_daemon_socket_down "$LOG_LINE"; then
        emit blocked status-log "$(status_line_note "$LOG_LINE")${SEP}daemon socket down despite attributed run record"
      fi
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          if [ "$LOG_VERB" = blocked ] \
            && log_claims_pipeline_unreachable "$LOG_LINE" \
            && { [ "$RUN_STATUS" = running ] || [ "$RUN_STATUS" = fixing ]; } \
            && nm_run_activity_is_recent; then
            RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded: run alive, not a daemon failure (steer reattach)"
          else
            RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
          fi
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
# is no run to consult, so only positive evidence that the target is gone may
# read as death - a backend that failed to answer is unknown, never death, for
# both classifier-backed backends (tmux and herdr) - and every death-class
# verdict reports unknown rather than trusting a possibly-stale status log as
# the current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
if ! pane_readable "$BACKEND_TARGET"; then
  # A failed probe is not itself evidence the pane is gone: the herdr CLI can
  # error or stall under load, and tmux can fail to be executed at all (a
  # trimmed PATH) or answer non-definitively, while the pane is alive - a busy
  # box would otherwise score dozens of live claims dead. Both backends own a
  # recovery-grade classifier (fm_backend_agent_state), which separates the
  # outcomes:
  #   missing - the endpoint is authoritatively absent: herdr's pane get
  #             answered pane_not_found; tmux's successful window inventory
  #             omitted the exact recorded window, or tmux gave one of its
  #             definitive no-session/no-server/no-socket responses (which
  #             fm_backend_tmux_agent_state owns as death, since fm-bootstrap
  #             and fm-session-start depend on it to license a respawn after a
  #             genuine server death - a socket-connection failure is NOT
  #             covered by the unknown-never-death rule above).
  #   dead    - the endpoint exists but confidently has no agent (herdr's agent
  #             get answered agent_not_found, or its registration lingers over a
  #             pane whose processes are nothing but shells - issue #4115;
  #             tmux's readable foreground process group is nothing but
  #             shells), still positive death evidence.
  #   alive   - the endpoint and its agent answered and only the heavy
  #             scrollback read failed, so the live state is classified by the
  #             normal flow below instead of being discarded.
  #   anything else - the cheap probes themselves failed to answer or
  #             contradicted themselves, which is unknown, never death.
  # Backends with no classifier (orca, zellij, and cmux all report unverified)
  # keep their historical capture-failure-means-gone reading.
  #
  # An unreadable target is still not proof the crew is gone. A backend whose
  # endpoint identifiers are generated (Herdr pane ids) re-issues them when it
  # rebuilds its layout, and the recorded one then names nothing while the
  # crew keeps running under a new one. Ask whether a live endpoint still
  # carries this task's identity before reporting the crew as gone; the
  # recorded worktree is the same directory the endpoint was created in.
  if [ "$(fm_backend_agent_state "$TASK_BACKEND" "$BACKEND_TARGET" \
      "$EXPECTED_LABEL" "$WT" 2>/dev/null)" = drifted ]; then
    emit unknown pane "recorded endpoint identifier is stale; a live endpoint still carries this task's identity - correct the record with bin/fm-control.sh $ID rebind"
  fi
  case "$TASK_BACKEND" in
    tmux|herdr) AGENT_STATE=$(fm_backend_agent_state "$TASK_BACKEND" "$BACKEND_TARGET") ;;
    *) AGENT_STATE=none ;;
  esac
  case "$TASK_BACKEND:$AGENT_STATE" in
    tmux:alive|herdr:alive)
      ;;
    tmux:missing|herdr:missing)
      emit unknown none "backend target gone: $BACKEND_TARGET"
      ;;
    tmux:dead|herdr:dead)
      emit unknown none "backend target gone: $BACKEND_TARGET (agent gone, pane shell remains)"
      ;;
    tmux:*|herdr:*)
      emit unknown none "backend unreachable ($TASK_BACKEND endpoint state: $AGENT_STATE)"
      ;;
    *)
      emit unknown none "backend target gone: $BACKEND_TARGET"
      ;;
  esac
fi

# A stopped agent is checked before anything else here, and for every kind.
# It is the one endpoint fact that makes every OTHER source untrustworthy at
# once: the process that writes the semantic record is frozen, so the record
# says whatever it last said forever, and the status log stopped where the
# worker stopped. It is checked for a secondmate too, even though the busy
# state below is not - a secondmate's idle pane is healthy, but a secondmate
# frozen mid-turn is not idle, and the live incident that produced this check
# was a secondmate.
if fm_backend_endpoint_suspended "$TASK_BACKEND" "$BACKEND_TARGET" 2>/dev/null; then
  emit unknown pane "harness process is suspended, not gone; resume it in its own endpoint before trusting any recorded state"
fi

# An agent that EXITED is checked next, and for the same reason: a readable
# endpoint proves the SHELL is there, not the agent. pane_readable above only
# asked whether the target resolves, so a worker whose agent left behind a live
# prompt reached the busy verdict and the status log below with no one to
# contradict them - the semantic record kept the `idle` its own shutdown hook
# wrote, and the log kept the last line the worker appended BEFORE it left.
# That pre-exit line then became the reported CURRENT state, which is how four
# workers on 2026-08-20 each went on reporting `working` for up to an hour
# after their agent was gone.
#
# fm_backend_agent_state is the one source that separates the three ways a
# quiet endpoint looks identical from the outside, and it is deliberately the
# ONLY thing consulted here: `dead` means the endpoint's foreground process
# group is shells alone, `suspended` means the agent is present but frozen
# (handled just above), and `alive` means the agent is right there - between
# turns, or unable to accept input behind its own overlay. Only `dead` is
# consumed, so an agent that is merely unreachable is never reported as gone,
# and a live worker can never be relaunched onto its own worktree on this
# evidence.
#
# The status log still decides whether the exit was a REPORT or a departure.
# A worker that wrote done:/failed: (or a captain-relevant needs-decision: or
# blocked:) and then exited said what happened, and keeps its own verdict from
# the log below. This verdict answers only the case the log cannot: the
# terminal line was never written at all. That distinction is the whole
# defect - not the exit, which is normal, but the missing line, which is what
# leaves firstmate unable to tell a finished worker from a stopped one.
AGENT_STATE=$(fm_backend_agent_state "$TASK_BACKEND" "$BACKEND_TARGET" \
  "$EXPECTED_LABEL" "$WT" 2>/dev/null) || AGENT_STATE=unknown

# A worker FIRSTMATE ITSELF stopped is separated here, before `exited`, because
# the two are byte-identical from the outside and mean opposite things. An
# endpoint that is agent-free because bin/fm-control.sh exit emptied it on
# purpose is not a worker that needs attention; it is a worker that is
# intentionally not running, and until this verdict existed there was no way to
# say so. The declaration is only ever believed alongside a dead agent, and only
# while it still binds to the incarnation it was written for
# (bin/fm-stopped-lib.sh), so an agent that died on its own writes nothing and
# still reports `exited`, an agent that is alive is never called stopped, and a
# relaunch's replacement is supervised normally from its first read.
#
# It outranks the status log deliberately. Whatever the worker last appended, it
# was appended BEFORE firstmate stopped it, so it describes the run rather than
# the present; the stop is the newer fact and the one that explains the empty
# endpoint.
if [ "$AGENT_STATE" = dead ] && fm_stopped_declared "$STATE" "$ID"; then
  STOP_REASON=$(fm_stopped_field "$STATE" "$ID" reason)
  STOP_AGE=$(fm_stopped_age "$STATE" "$ID") || STOP_AGE=
  STOP_DETAIL="stopped by firstmate on purpose"
  [ -z "$STOP_AGE" ] || STOP_DETAIL="$STOP_DETAIL ${STOP_AGE}s ago"
  [ -z "$STOP_REASON" ] || STOP_DETAIL="$STOP_DETAIL: $STOP_REASON"
  emit stopped declared-stop "$STOP_DETAIL; its work is intact at $WT and nothing is running - resume it with bin/fm-control.sh $ID relaunch"
fi

if [ "$AGENT_STATE" = dead ] \
  && ! status_is_terminal_verb "$LOG_LINE"; then
  # ... unless the record is still inside its registration window, where the
  # same emptiness is equally consistent with a harness that has not started.
  # Reported as unknown rather than smoothed into working: unknown licenses
  # nothing, so a spawn that really did die on arrival is still surfaced by the
  # next read instead of being absorbed as progress.
  if within_spawn_grace; then
    emit unknown pane "endpoint holds no agent yet, but $SPAWN_GRACE_REASON; a harness that has not started leaves the same empty endpoint as one that left, so this is not proof either way - re-read it before acting, and do not relaunch on it"
  fi
  if [ -n "$LOG_LINE" ]; then
    EXIT_LAST="last event: $(status_line_note "$LOG_LINE")"
  else
    EXIT_LAST="no status events"
  fi
  emit exited pane "harness agent exited without a terminal status line ($EXIT_LAST); its work is intact at $WT - read the deliverable to tell finished from stopped mid-task, and do not assume either"
fi

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# state is not meaningful for them; read their state from the status log only.
# Only an exact busy verdict reports working here, and only an exact idle
# verdict permits the status-log fallback below. Missing, malformed, stale, or
# unverified semantic state remains unknown.
if [ "$KIND" != secondmate ]; then
  COMPOSER_STATE=$(fm_backend_composer_state "$TASK_BACKEND" "$BACKEND_TARGET" 2>/dev/null)
  if [ "$COMPOSER_STATE" = dialog ]; then
    emit blocked pane "modal dialog"
  fi
  BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
  case "${BUSY_VERDICT%% *}" in
    busy)
      if CAP_DETAIL=$(fm_crew_opencode_cap_detail); then
        emit blocked pane "$CAP_DETAIL"
      fi
      emit working pane "harness busy (${BUSY_VERDICT#* })" ;;
    idle) ;;
    *) PANE_UNKNOWN_REASON="harness state unavailable ($BUSY_VERDICT)" ;;
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

if [ -n "${PANE_UNKNOWN_REASON:-}" ]; then
  emit unknown pane "$PANE_UNKNOWN_REASON"
fi

emit unknown none "no current-state source available"
