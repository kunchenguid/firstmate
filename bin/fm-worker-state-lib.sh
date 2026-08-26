#!/usr/bin/env bash
# fm-worker-state-lib.sh - the ONE computed worker-state projection.
#
# Why this exists: bin/fm-crew-state.sh's careful reconciliation (a
# no-mistakes run-step, else the semantic busy-state contract, else the
# status log) used to live entirely inside that one script's body, so any
# OTHER surface that wanted a worker's current state either shelled out to
# it and re-parsed its free-text line, or read one raw signal directly - a
# pane-idleness heuristic, or a single `axi status` snapshot - which reads
# identically for "slow but genuinely computing" and "actually hung."
# Different surfaces built on different raw reads can then disagree about
# the same worker's state at the same instant.
#
# This library moves that reconciliation into fm_worker_state_project, one
# function every surface calls to get the SAME decision, carrying its own
# provenance: which source produced the verdict (run-step, pane, status-log,
# remote-endpoint, or none) and when it was computed. bin/fm-crew-state.sh is
# now a thin renderer over this function (its CLI output is unchanged, so
# every existing caller keeps working); bin/fm-peek.sh calls the same
# function to annotate its raw capture with the authoritative verdict
# instead of leaving a reader to (mis)judge busy-vs-hung from pane text
# alone.
#
# Record shape - fm_worker_state_project prints this to stdout and always
# returns 0 (read-only and side-effect free beyond the same bounded
# no-mistakes call bin/fm-crew-state.sh always made):
#
#   id=<task id>
#   state=<working|parked|done|blocked|paused|failed|unknown>
#   source=<run-step|pane|status-log|remote-endpoint|none>
#   detail=<free text, one line, may be empty>
#   computed_at=<UTC ISO-8601 instant the projection was computed>
#
# fm_worker_state_field <record> <key> reads one field back out (mirrors
# fm_meta_get's grep/cut shape, operating on a string instead of a file).
# fm_worker_state_render_line <record> renders the single stable human line
# every CLI surface prints:
#
#   state: <state> · source: <source> · <detail>
#
# The reconciliation logic below is UNCHANGED from bin/fm-crew-state.sh's
# original body (moved here verbatim; see that file's git history for the
# case-by-case rationale pinned by tests/fm-crew-state.test.sh), in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta. A
#      remote_host= meta is a remote secondmate: its worktree and endpoint
#      live on that host, so the remote host is asked for the endpoint's
#      recovery-grade state instead of reading local files.
#   2. A matching no-mistakes run for this crew's branch AND current code
#      identity, active or terminal, is AUTHORITATIVE.
#   3. Reconcile the status log against a matched run: a stale
#      needs-decision/blocked line the run has moved past is flagged
#      superseded; a genuinely parked run plus a needs-decision log agree
#      and are not.
#   4. No run for this crew: fall back to the semantic busy-state contract,
#      then the status log's last line when its verb maps to a recognized
#      state.
#   5. Missing meta, a torn-down worktree, or no source at all: unknown/none.
set -u

# Directory of this library, used to locate sibling libraries and to derive
# FM_ROOT the same way bin/fm-crew-state.sh always did. Resolved at source
# time from BASH_SOURCE so it works whether sourced by a bin/ script or a
# test.
_FM_WORKER_STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_WORKER_STATE_LIB_DIR="."

# shellcheck source=bin/fm-tmux-lib.sh
. "$_FM_WORKER_STATE_LIB_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$_FM_WORKER_STATE_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_WORKER_STATE_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$_FM_WORKER_STATE_LIB_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$_FM_WORKER_STATE_LIB_DIR/fm-nm-run-lib.sh"

fm_worker_state_field() {  # <record> <key>
  printf '%s\n' "$1" | grep "^$2=" | tail -1 | cut -d= -f2-
}

fm_worker_state_render_line() {  # <record>
  local record=$1 state source detail line
  state=$(fm_worker_state_field "$record" state)
  source=$(fm_worker_state_field "$record" source)
  detail=$(fm_worker_state_field "$record" detail)
  line="state: $state · source: $source"
  [ -n "$detail" ] && line="$line · $detail"
  printf '%s\n' "$line"
}

# fm_worker_state_project: compute the authoritative current-state record for
# <id> and print it in the key=value shape documented above. The whole
# computation runs in a subshell so every early "done deciding" point below
# can just `exit 0` (exactly as bin/fm-crew-state.sh's original body did)
# without exiting the CALLER's process - the caller may be fm-peek.sh, which
# still has a raw capture to print afterward.
#
# Optional second argument <skip-live-probe>: when "1", skip every tier's own
# live round trip - the remote-secondmate tier's `fm-remote-secondmate-control.sh
# state` call, the fallback tier's pane_readable/busy-state check (including
# the herdr-native fm_backend_busy_state check inside fm_busy_classify when no
# semantic busy record exists) - and go straight to the file-only status-log
# fallback instead. bin/fm-peek.sh passes this because it is ABOUT to make
# that exact same live capture call itself for the raw tail it prints -
# without this, every peek of a no-run crew or remote secondmate would cost a
# second live backend round-trip and, for a backend whose mock or transport is
# call-order-sensitive (proven by tests/fm-backend-orca.test.sh's queued fake
# responses), could consume the response meant for the real capture or mask
# its error text. The run-step and status-log tiers never touch a live
# endpoint, so they are unaffected and still answer for free.
#
# Optional third argument <precaptured-tail>: the raw pane text a
# skip-live-probe=1 caller already captured for its own purposes (e.g.
# bin/fm-peek.sh's raw stdout tail). When set, the Grok busy-check arm (the
# ONLY tier that would otherwise need its own live capture) classifies busy
# vs. idle from this text instead of skipping the check - recovering the true
# state for a recordless Grok crew with no status log to fall back on, WITHOUT
# a second live round trip, since it reuses the one capture the caller already
# made. Absent (the default), that recordless/no-log case still cannot be
# answered and reports unknown, exactly as when skip-live-probe alone is set.
fm_worker_state_project() {  # <id> [skip-live-probe] [precaptured-tail]
  local _fm_ws_id=$1 _fm_ws_skip_live=${2:-0} _fm_ws_tail=${3-}
  (
  # bin/fm-crew-state.sh's original body relies on plain (non-erroring) greps
  # and pipelines returning nonzero as ordinary control flow (no match found,
  # no run attributed, ...), the same way it always ran as a standalone
  # `set -u`-only script. Bash's inherit_errexit (default since 4.4)
  # propagates a CALLER's `set -e` into this command-substitution subshell,
  # which would turn those expected non-matches into a premature exit - so
  # this explicitly stays off regardless of what the caller (e.g. fm-peek.sh,
  # which runs under `set -eu`) has enabled.
  set +e
  set -u
  ID=$_fm_ws_id
  FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$_FM_WORKER_STATE_LIB_DIR/.." && pwd)}"
  FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

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

  # Emit the one canonical record and exit the subshell. Detail is optional.
  emit() {  # <state> <source> [detail]
    printf 'id=%s\n' "$ID"
    printf 'state=%s\n' "$1"
    printf 'source=%s\n' "$2"
    printf 'detail=%s\n' "${3:-}"
    printf 'computed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
    if [ "$_fm_ws_skip_live" = 1 ]; then
      # The caller (bin/fm-peek.sh) is about to make this exact remote
      # `capture` round trip itself moments later - skip this tier's own
      # remote `state` round trip (see fm_worker_state_project's header
      # comment) rather than asking the remote host twice, and fall back to
      # the status log the same way an unreachable host would below.
      if [ -n "$LOG_VERB" ]; then
        LOG_STATE=$(map_log_state "$LOG_LINE")
        if [ "$LOG_STATE" != unknown ]; then
          emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")${SEP}remote endpoint probe skipped on $REMOTE_HOST (live capture pending)"
        fi
      fi
      emit unknown remote-endpoint "remote endpoint probe skipped on $REMOTE_HOST (live capture pending)"
    fi
    if ! REMOTE_STATE=$(FM_HOME="$FM_HOME" "$_FM_WORKER_STATE_LIB_DIR/fm-on.sh" "$ID" \
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
    if [ "$_fm_ws_skip_live" != 1 ]; then
      case "$HARNESS" in
        grok*) tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || tail40='' ;;
      esac
    elif [ -n "$_fm_ws_tail" ]; then
      # The caller already made its own live capture (see this function's
      # header and fm_worker_state_project's <precaptured-tail> doc above) -
      # reuse it instead of asking fm_busy_classify to skip the check.
      case "$HARNESS" in
        grok*) tail40=$_fm_ws_tail ;;
      esac
    fi
    fm_busy_classify "$TASK_BACKEND" "$1" "$HARNESS" "$ID" "$STATE" "$tail40" "$_fm_ws_skip_live"
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

    emit "$RUN_STATE" run-step "$RUN_DETAIL"
  fi

  # --- fallback: no run attributed to this crew ------------------------------
  # The run-step path above already handled any crew with a run, regardless of pane
  # liveness, so a finished-but-pane-closed crew never reaches here. Down here there
  # is no run to consult, so a dead/unreadable target means the crew is gone: report
  # unknown rather than trusting a possibly-stale status log as the current state.
  [ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"

  # pane_readable's own live probe is skipped when the caller is about to
  # make this exact capture itself (see fm_worker_state_project's header
  # comment) - proceed as if reachable rather than paying for it twice. The
  # busy verdict still runs: for a converted adapter it is a pure record-file
  # read with no live probe at all, and crew_busy_verdict passes the same flag
  # into fm_busy_classify, which gates its own live paths (grok's isolated
  # tail fallback, and the no-record herdr-native fm_backend_busy_state check)
  # on it, so this tier still answers for free whenever a semantic record
  # exists and otherwise reports unknown rather than paying for a live probe -
  # UNLESS the caller also passed a <precaptured-tail>, in which case Grok's
  # tail check answers from that instead of skipping.
  if [ "$_fm_ws_skip_live" != 1 ]; then
    pane_readable "$BACKEND_TARGET" || emit unknown none "backend target gone: $BACKEND_TARGET"
  fi

  # Secondmates idle on their own watcher (idle pane = healthy), so the busy
  # state is not meaningful for them; read their state from the status log only.
  # Only an exact busy verdict reports working here, and only an exact idle
  # verdict permits the status-log fallback below. Missing, malformed, stale, or
  # unverified semantic state remains unknown - EXCEPT `unknown live-probe-skipped`,
  # which means fm_busy_classify deliberately declined to try (skip_live is set and
  # no semantic record existed to answer for free), not that it tried and failed.
  # Treating that as authoritative unknown would make skip_live callers (fm-peek.sh)
  # report a different state than skip_live=0 callers (fm-crew-state.sh) for the
  # exact same worker; fall through to the status-log tier below instead, same as idle.
  PANE_PROBE_SKIPPED=0
  if [ "$KIND" != secondmate ]; then
    BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
    case "$BUSY_VERDICT" in
      busy\ *) emit working pane "harness busy (${BUSY_VERDICT#* })" ;;
      idle\ *) ;;
      "unknown live-probe-skipped") PANE_PROBE_SKIPPED=1 ;;
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

  # A skipped pane probe that the status-log tier above could not corroborate
  # is NOT the same fact as "no source exists at all" (source=none below): a
  # live signal exists, skip_live's caller (fm-peek.sh) just deliberately
  # declined to read it to avoid a second live round trip. Reporting it as
  # source=none would erase that provenance and read as "every tier was
  # checked and came up empty", when really one tier was never asked.
  [ "$PANE_PROBE_SKIPPED" != 1 ] || emit unknown pane "harness state unavailable (live pane probe skipped)"

  emit unknown none "no current-state source available"
  )
}
