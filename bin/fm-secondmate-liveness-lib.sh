#!/usr/bin/env bash
# shellcheck disable=SC2034 # Probe/relaunch output globals are read by sourcing callers.
# fm-secondmate-liveness-lib.sh - shared persistent-secondmate endpoint liveness
# probing and recovery. bin/fm-bootstrap.sh owns the session-start sweep and
# bin/fm-watch.sh owns the ordinary-supervision poll tick; both drive this
# library so classification handling and the guarded relaunch path stay
# single-sourced here.
#
# A secondmate's recorded endpoint is the tmux window, herdr pane, or remote
# peer it runs in. Probing classifies that endpoint through the owning backend
# adapter's fm_backend_agent_state (local) or the remote control script's
# state verb (remote), which returns one of:
#
#   alive       - a primary-agent runtime is positively running
#   dead        - the endpoint exists, but no agent is running in it
#   missing     - the endpoint itself is gone
#   ambiguous   - backend inventory could not prove either way
#   unreadable  - backend state exists but could not be parsed
#   unverified  - the endpoint is recorded under a session this home does not
#                 own, so probing is not authorized
#
# Only `dead` and `missing` are recovery-authorizing states: they prove the
# agent is not running, so relaunching cannot produce a duplicate endpoint.
# `ambiguous`, `unreadable`, and `unverified` leave the endpoint untouched -
# relaunching on inconclusive evidence could create a second endpoint beside a
# live one - and an unreachable remote host is never evidence of death, so a
# remote route is never replaced by a local endpoint.
#
# `wedged` is a further recovery-authorizing state this library adds on top of
# that classifier, for Herdr-backed secondmates only. An agent whose process is
# running and registered but which has stopped making progress classifies
# `alive` above, correctly and permanently, so it fell through every recovery
# path and needed a human SIGKILL. When the backend classifier says `alive`,
# this library asks bin/fm-herdr-wedge-lib.sh - which owns the progress signals,
# the configurable no-progress window, the evidence capture, and the agent-only
# kill - whether that liveness is real. A `wedged` verdict is relaunchable;
# every other wedge verdict (`progressing`, `not-working`, `baseline`,
# `unreadable`) leaves the mate alive and untouched.
#
# Unlike `dead`, recovery from `wedged` kills a LIVE process, so three limits
# apply and all three are deliberate. The no-progress window must elapse, as
# observed time, with every signal that library reads frozen - both herdr
# progress counters, the agent's consumed CPU time, and the absence of any live
# non-MCP child process - because each one alone has a legitimate quiet case.
# Non-destructive evidence is captured BEFORE the kill
# and recorded in the ledger, because the three freezes that motivated this left
# no sample and so no proven mechanism. The caller's existing relaunch bound
# applies unchanged, so even a systematically mis-detecting probe cannot
# kill-loop a healthy mate. And because the recovery is automatic and
# destructive, it raises the shared wedge alarm (docs/wedge-alarm.md) rather
# than recovering silently.
#
# Out of scope, deliberately, and not implemented here: ordinary crewmates,
# every non-Herdr backend, holding a steer until the pane is idle, and the Stop
# hook's asyncRewake timeout.
#
# Relaunch goes through `bin/fm-spawn.sh <id> --secondmate` with
# FM_SPAWN_NO_GUARD=1, the same guarded path every recovery uses. That path
# re-resolves placement from the task's own metadata and registry route, so a
# remote mate is relaunched on its recorded remote host through bin/fm-on.sh -
# never as a local replacement - behind fm-spawn's own readiness gate and
# per-task spawn lock.
#
# Modes:
#   full - session-start sweep: remote routes run the full readiness repair
#          sequence before probing, and an alive remote route is revalidated
#          (route readable, backend herdr) so the sweep reports drift.
#   poll - watcher tick: remote routes take one read-only state probe per
#          check; repair still happens, but inside fm-spawn's launch gate only
#          when a relaunch is actually authorized.
#
# Concurrency: fm_secondmate_liveness_lock serializes probe+kill+relaunch per
# task across the bootstrap sweep and the watcher tick, so a concurrent
# relaunch can never be observed mid-flight as a dead endpoint and killed.
# The attempt ledger (.secondmate-relaunch-<id>, one line per attempt plus one
# per outcome) is both the durable relaunch record and the input to the
# watcher's relaunch bound; teardown removes it.

set -u

FM_SM_LIVE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=bin/fm-backend.sh
. "$FM_SM_LIVE_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$FM_SM_LIVE_LIB_DIR/fm-remote-readiness-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_SM_LIVE_LIB_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-herdr-wedge-lib.sh
. "$FM_SM_LIVE_LIB_DIR/fm-herdr-wedge-lib.sh"
# shellcheck source=bin/fm-wedge-alarm-lib.sh
. "$FM_SM_LIVE_LIB_DIR/fm-wedge-alarm-lib.sh"

# Per-task probe+kill+relaunch serialization. A busy lock means another
# supervisor (the other sweep, or a racing tick) is mid-episode on this mate;
# callers skip and let that episode finish rather than probe a moving target.
# The lock helpers live in bin/fm-wake-lib.sh, which creates the state
# directory when sourced; load it only when a lock is actually taken so that
# sourcing this library stays side-effect free for read-only bootstrap runs.
fm_sm_live_require_locks() {
  command -v fm_lock_try_acquire >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_SM_LIVE_LIB_DIR/fm-wake-lib.sh"
}

fm_secondmate_liveness_lock() {  # <id>
  fm_sm_live_require_locks || return 1
  fm_lock_try_acquire "$STATE/.secondmate-liveness-$1.lock"
}

fm_secondmate_liveness_unlock() {  # <id>
  fm_sm_live_require_locks || return 0
  fm_lock_release "$STATE/.secondmate-liveness-$1.lock" 2>/dev/null || true
}

fm_sm_live_first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

# One line per relaunch attempt and one per outcome, keyed by epoch, plus a
# `rearmed` row when a live probe lifts a parked mate. The watcher bound counts
# `attempt` rows inside its window and after the last `rearmed` row; the whole
# file is the durable per-mate relaunch record the captain can count to see
# frequency. Fails when the row cannot be appended.
fm_secondmate_liveness_ledger_add() {  # <id> <attempt|relaunched|failed|rearmed|wedge-capture> [detail]
  if [ -n "${3:-}" ]; then
    printf '%s\t%s\t%s\n' "$(date +%s)" "$2" "$3" >> "$STATE/.secondmate-relaunch-$1" 2>/dev/null
    return
  fi
  printf '%s\t%s\n' "$(date +%s)" "$2" >> "$STATE/.secondmate-relaunch-$1" 2>/dev/null
}

# Count of attempt rows no older than <window-secs> that follow the last
# `rearmed` row. An absent ledger counts
# zero; an existing ledger that cannot be read fails rather than counting zero.
fm_secondmate_liveness_recent_attempts() {  # <id> <window-secs>
  local id=$1 window=$2 now cutoff ledger
  ledger="$STATE/.secondmate-relaunch-$id"
  if [ ! -e "$ledger" ] && [ ! -L "$ledger" ]; then
    printf '0\n'
    return 0
  fi
  now=$(date +%s)
  cutoff=$((now - window))
  awk -F '\t' -v cutoff="$cutoff" \
    '$2 == "rearmed" { n = 0; next } $1 ~ /^[0-9]+$/ && $1 >= cutoff && $2 == "attempt" { n++ } END { print n + 0 }' \
    "$ledger" 2>/dev/null
}

# fm_secondmate_liveness_probe <meta> <id> <full|poll>
#
# Read-only probe of one registered secondmate's recorded endpoint. Populates:
#
#   FM_SM_LIVE_STATUS  silent | alive | relaunchable | skipped
#   FM_SM_LIVE_STATE   the raw classifier/state word, including `wedged`
#   FM_SM_LIVE_KILL    1 when relaunch must first kill a confirmed-dead local
#                      endpoint (its shell husk occupies the name), or `wedged`
#                      when it must instead capture evidence and SIGKILL only
#                      the live agent process in the pane
#   FM_SM_LIVE_CAUSE   relaunch cause phrase, on relaunchable
#   FM_SM_LIVE_WHERE   backend=<b> or host=<h>, on relaunchable
#   FM_SM_LIVE_REASON  exact skip suffix, on skipped
#   FM_SM_LIVE_LINE    verbose already-live line body, on alive
#   FM_SM_LIVE_WEDGE   the raw wedge verdict whenever one was taken, so a
#                      caller can log an `unreadable` one. A vendor shape change
#                      can only ever DISABLE wedge recovery (an unreadable
#                      counter never produces a wedged verdict), which would
#                      otherwise degrade silently.
#
# `silent` means the meta records no endpoint at all - that shape is owned by
# secondmate-provisioning recovery, not liveness.
#
# The caller must hold fm_secondmate_liveness_lock for <id> whenever a
# relaunchable verdict could be acted on.
fm_secondmate_liveness_probe() {  # <meta> <id> <full|poll>
  local meta=$1 id=$2 mode=$3
  FM_SM_LIVE_STATUS=skipped FM_SM_LIVE_STATE=unknown FM_SM_LIVE_KILL=0
  FM_SM_LIVE_CAUSE='' FM_SM_LIVE_WHERE='' FM_SM_LIVE_REASON='' FM_SM_LIVE_LINE=''
  FM_SM_LIVE_WEDGE=''
  local window harness remote_host remote_rc out agent_state readiness_reason route_out remote_backend
  local wedge_mode wedge_window
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] || { FM_SM_LIVE_STATUS=silent; return 0; }
  harness=$(fm_meta_get "$meta" harness)
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    if [ "$mode" = full ]; then
      remote_rc=0
      fm_remote_readiness_ensure "$FM_SM_LIVE_LIB_DIR" "$id" || remote_rc=$?
      if [ "$remote_rc" -eq 255 ]; then
        FM_SM_LIVE_REASON="remote host unavailable or endpoint state unknown; route preserved on $remote_host"
        return 0
      fi
      if [ "$remote_rc" -ne 0 ]; then
        readiness_reason=$(printf '%s\n' "$FM_REMOTE_READINESS_OUT" \
          | awk '/^check [^=]+=(fixable|human):|^action:|^error:/ { print; exit }')
        [ -n "$readiness_reason" ] || readiness_reason=$(fm_sm_live_first_line "$FM_REMOTE_READINESS_OUT")
        [ -n "$readiness_reason" ] || readiness_reason="unknown readiness failure"
        FM_SM_LIVE_REASON="remote readiness failed on $remote_host: $readiness_reason"
        return 0
      fi
    fi
    if out=$("$FM_SM_LIVE_LIB_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null); then
      remote_rc=0
    else
      remote_rc=$?
    fi
    if [ "$remote_rc" -eq 255 ]; then
      FM_SM_LIVE_REASON="remote host unavailable or endpoint state unknown; route preserved on $remote_host"
      return 0
    fi
    if [ "$remote_rc" -ne 0 ]; then
      FM_SM_LIVE_REASON="remote endpoint probe unreadable on $remote_host"
      return 0
    fi
    agent_state=$(printf '%s\n' "$out" | tail -1)
    FM_SM_LIVE_STATE=$agent_state
    case "$agent_state" in
      alive)
        if [ "$mode" = full ]; then
          if route_out=$("$FM_SM_LIVE_LIB_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh route "$id" < /dev/null 2>/dev/null); then
            remote_rc=0
          else
            remote_rc=$?
          fi
          if [ "$remote_rc" -eq 255 ]; then
            FM_SM_LIVE_REASON="remote host unavailable or endpoint route unknown; route preserved on $remote_host"
            return 0
          fi
          if [ "$remote_rc" -ne 0 ]; then
            FM_SM_LIVE_REASON="alive remote endpoint route is unreadable on $remote_host; inspect and migrate or retire it explicitly"
            return 0
          fi
          remote_backend=$(printf '%s\n' "$route_out" | sed -n 's/^backend=//p' | tail -1)
          if [ "$remote_backend" != herdr ]; then
            FM_SM_LIVE_REASON="alive remote endpoint is recorded on backend '${remote_backend:-missing}'; migrate or retire it explicitly"
            return 0
          fi
        fi
        # The progress probe runs on the mate's OWN host, through the same
        # transport: the parent never reads a counter or signals a pid across
        # hosts. The parent still owns the POLICY - its own config and cadence
        # resolve the window and the largest observed-sample gap and pass them,
        # so a remote mate is not governed by whatever another home's config
        # file on that host happens to say. A transport
        # failure leaves the mate alive, exactly like every other inconclusive
        # remote read.
        wedge_window=$(fm_herdr_wedge_window "${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}")
        if [ "$wedge_window" != off ]; then
          case "$mode" in full) wedge_mode=baseline ;; *) wedge_mode=judge ;; esac
          if out=$("$FM_SM_LIVE_LIB_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh \
            wedge-state "$id" "$wedge_window" "$wedge_mode" "$(fm_herdr_wedge_max_sample_gap)" \
            < /dev/null 2>/dev/null); then
            FM_SM_LIVE_WEDGE=$(printf '%s\n' "$out" | tail -1)
          else
            FM_SM_LIVE_WEDGE=unreadable
          fi
          if [ "$FM_SM_LIVE_WEDGE" = wedged ]; then
            FM_SM_LIVE_STATE=wedged
            FM_SM_LIVE_STATUS=relaunchable
            FM_SM_LIVE_KILL=wedged
            FM_SM_LIVE_CAUSE="remote agent wedged: running but no progress for at least ${wedge_window}s"
            FM_SM_LIVE_WHERE="host=$remote_host"
            return 0
          fi
        fi
        FM_SM_LIVE_STATUS=alive
        FM_SM_LIVE_LINE="remote secondmate $id already live (host=$remote_host)"
        ;;
      dead|missing)
        FM_SM_LIVE_STATUS=relaunchable
        FM_SM_LIVE_CAUSE="remote endpoint $agent_state on its configured host"
        FM_SM_LIVE_WHERE="host=$remote_host"
        ;;
      ambiguous|unreadable|unverified)
        FM_SM_LIVE_REASON="remote endpoint state is $agent_state on $remote_host"
        ;;
      *)
        FM_SM_LIVE_REASON="remote endpoint returned an invalid state"
        ;;
    esac
    return 0
  fi

  local backend target
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target="$window"
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|omp) ;;
    *)
      case "$agent_state" in dead|missing) agent_state=unverified-harness ;; esac
      ;;
  esac
  FM_SM_LIVE_STATE=$agent_state
  case "$agent_state" in
    alive)
      if [ "$backend" = herdr ]; then
        wedge_window=$(fm_herdr_wedge_window "${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}")
        if [ "$wedge_window" != off ]; then
          # `full` (the session-start sweep) only re-bases the window; the
          # watcher's continuous `poll` tick is the sole producer of a wedged
          # verdict, because one sweep sample - or a record left over from
          # before a shutdown or a suspend - cannot distinguish a frozen agent
          # from an unobserved one.
          case "$mode" in full) wedge_mode=baseline ;; *) wedge_mode=judge ;; esac
          FM_SM_LIVE_WEDGE=$(fm_herdr_wedge_classify "$STATE" "$id" "$target" "$wedge_window" "$wedge_mode")
          if [ "$FM_SM_LIVE_WEDGE" = wedged ]; then
            FM_SM_LIVE_STATE=wedged
            FM_SM_LIVE_STATUS=relaunchable
            FM_SM_LIVE_KILL=wedged
            FM_SM_LIVE_CAUSE="agent wedged: running but no progress for at least ${wedge_window}s"
            FM_SM_LIVE_WHERE="backend=$backend"
            return 0
          fi
        fi
      fi
      FM_SM_LIVE_STATUS=alive
      FM_SM_LIVE_LINE="secondmate $id already live (backend=$backend)"
      ;;
    dead|missing)
      FM_SM_LIVE_STATUS=relaunchable
      if [ "$agent_state" = dead ]; then
        FM_SM_LIVE_KILL=1
        FM_SM_LIVE_CAUSE="confirmed agent absence on existing endpoint"
      else
        FM_SM_LIVE_CAUSE="recorded endpoint confidently missing"
      fi
      FM_SM_LIVE_WHERE="backend=$backend"
      ;;
    ambiguous)
      FM_SM_LIVE_REASON="existing endpoint has ambiguous agent process (backend=$backend)"
      ;;
    unreadable)
      FM_SM_LIVE_REASON="endpoint probe unreadable (backend=$backend)"
      ;;
    unverified-harness)
      FM_SM_LIVE_REASON="recorded harness '$harness' is unverified for recovery (backend=$backend)"
      ;;
    *)
      FM_SM_LIVE_REASON="agent recovery classifier unverified (backend=$backend)"
      ;;
  esac
  return 0
}

# fm_secondmate_liveness_wedge_recover <meta> <id>
#
# The destructive half of a `wedged` verdict, in the one order that matters:
# capture evidence, record where it went, and only then SIGKILL the live agent.
#
# Capture comes first because it is the step that makes the next freeze
# diagnosable, and because it is non-destructive - the kill cannot be undone and
# destroys the very process the evidence describes. The capture path is also
# recorded in the relaunch ledger, so the durable per-mate record points at the
# sample rather than leaving it to be found by name.
#
# A remote mate's capture and kill both run on its OWN host, through the
# existing control transport; the parent never signals across hosts or derives a
# pid from a reading it took locally.
#
# Refusing is always safe: when the agent pids cannot be established, nothing is
# killed and FM_SM_LIVE_REASON says why, so the mate stays alive and the next
# tick re-probes it. Returns nonzero in that case, and the caller must not spawn
# - a spawn beside a still-running agent is exactly the duplicate endpoint the
# whole classifier exists to prevent.
fm_secondmate_liveness_wedge_recover() {  # <meta> <id>
  local meta=$1 id=$2 remote_host out pids capture killed
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    if ! out=$("$FM_SM_LIVE_LIB_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh \
      wedge-recover "$id" < /dev/null 2>&1); then
      FM_SM_LIVE_REASON="wedged remote agent could not be recovered on $remote_host: $(fm_sm_live_first_line "$out"); endpoint left running"
      return 1
    fi
    capture=$(printf '%s\n' "$out" | sed -n 's/^capture=//p' | tail -1)
    killed=$(printf '%s\n' "$out" | sed -n 's/^killed=//p' | tail -1)
    FM_SM_LIVE_WEDGE_CAPTURE="${capture:-unrecorded (on $remote_host)}"
    FM_SM_LIVE_WEDGE_KILLED="${killed:-unrecorded}"
    fm_secondmate_liveness_ledger_add "$id" wedge-capture "$FM_SM_LIVE_WEDGE_CAPTURE" || true
    return 0
  fi

  local backend target
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  if [ "$backend" != herdr ] || [ -z "$target" ]; then
    FM_SM_LIVE_REASON="wedge recovery is implemented only for a herdr endpoint, not backend '${backend:-missing}'; endpoint left running"
    return 1
  fi
  if ! fm_herdr_wedge_require_adapter; then
    FM_SM_LIVE_REASON="the herdr adapter could not be loaded to recover a wedged endpoint; endpoint left running"
    return 1
  fi
  if ! fm_backend_herdr_parse_target "$target"; then
    FM_SM_LIVE_REASON="wedged endpoint target '$target' is unparseable; endpoint left running"
    return 1
  fi
  if ! pids=$(fm_herdr_wedge_agent_pids "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE"); then
    FM_SM_LIVE_REASON="wedged endpoint $target has no attributable agent process to kill; endpoint left running"
    return 1
  fi
  # shellcheck disable=SC2086 # The pid list is newline-separated digits by construction.
  capture=$(fm_herdr_wedge_capture "$STATE" "$id" $pids) || capture=''
  FM_SM_LIVE_WEDGE_CAPTURE="${capture:-unrecorded}"
  [ -z "$capture" ] || fm_secondmate_liveness_ledger_add "$id" wedge-capture "$capture" || true
  # shellcheck disable=SC2086 # Same: deliberate word splitting of the pid list.
  if ! killed=$(fm_herdr_wedge_kill_agent "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" $pids); then
    FM_SM_LIVE_REASON="wedged endpoint $target could not be killed (evidence at $FM_SM_LIVE_WEDGE_CAPTURE); endpoint left running"
    return 1
  fi
  FM_SM_LIVE_WEDGE_KILLED=$(printf '%s' "$killed" | tr '\n' ' ')
  # The relaunched agent must start its no-progress window from scratch rather
  # than inherit the frozen one's counters.
  fm_herdr_wedge_clear "$STATE" "$id"
  return 0
}

# fm_secondmate_liveness_wedge_alarm <id> <spawn-rc>
#
# Raise the shared wedge alarm (bin/fm-wedge-alarm-lib.sh, contract in
# docs/wedge-alarm.md) after a wedged mate was killed. A recovery that SIGKILLs
# a live agent must never be silent, whether or not the relaunch then succeeded.
#
# No separate rate limit is needed: the caller's existing relaunch bound already
# caps how often this can fire for one mate, and the alarm is raised only on an
# actual kill, not on a verdict.
fm_secondmate_liveness_wedge_alarm() {  # <id> <spawn-rc>
  local id=$1 rc=$2 outcome summary
  if [ "$rc" -eq 0 ]; then
    outcome="relaunched"
  else
    outcome="RELAUNCH FAILED (status $rc)"
  fi
  summary="secondmate $id was wedged (running, no progress); killed agent pid(s) ${FM_SM_LIVE_WEDGE_KILLED:-unrecorded} and $outcome. Evidence: ${FM_SM_LIVE_WEDGE_CAPTURE:-unrecorded}"
  FM_WEDGE_ALARM_TITLE="firstmate: secondmate $id WEDGED - auto-recovered" \
    wedge_alarm_notify "$summary" "${FM_SM_LIVE_WEDGE_CAPTURE:-$STATE/.secondmate-relaunch-$id}"
}

# fm_secondmate_liveness_relaunch <meta> <id> [timeout-secs]
#
# Acts on a `relaunchable` probe verdict for <id>: kills a confirmed-dead local
# endpoint first (FM_SM_LIVE_KILL), records the attempt and its outcome in the
# per-mate ledger, then runs the guarded secondmate spawn. A positive timeout
# wraps the spawn in fm_run_timed so a watcher poll stays bounded; 124/137 mean
# the bound fired. Returns the spawn exit status; combined spawn output is in
# FM_SM_LIVE_OUT and the status in FM_SM_LIVE_RC. When the ledger cannot be
# read or the attempt row cannot be appended, nothing is killed or spawned: the verdict becomes
# FM_SM_LIVE_STATUS=skipped with FM_SM_LIVE_REASON set and this returns 1.
# Caller holds the liveness lock and owns reporting.
fm_secondmate_liveness_relaunch() {  # <meta> <id> [timeout-secs]
  local meta=$1 id=$2 timeout=${3:-}
  FM_SM_LIVE_OUT='' FM_SM_LIVE_RC=0
  FM_SM_LIVE_WEDGE_CAPTURE='' FM_SM_LIVE_WEDGE_KILLED=''
  if ! fm_secondmate_liveness_recent_attempts "$id" 0 >/dev/null; then
    FM_SM_LIVE_STATUS=skipped
    FM_SM_LIVE_REASON="relaunch ledger $STATE/.secondmate-relaunch-$id is unreadable; endpoint left $FM_SM_LIVE_STATE"
    FM_SM_LIVE_RC=1
    return 1
  fi
  if ! fm_secondmate_liveness_ledger_add "$id" attempt; then
    FM_SM_LIVE_STATUS=skipped
    FM_SM_LIVE_REASON="relaunch ledger $STATE/.secondmate-relaunch-$id is unwritable; endpoint left $FM_SM_LIVE_STATE"
    FM_SM_LIVE_RC=1
    return 1
  fi
  local backend target window
  if [ "$FM_SM_LIVE_KILL" = 1 ]; then
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      window=$(fm_meta_get "$meta" window)
      target=$window
    fi
    [ -z "$target" ] || fm_backend_kill "$backend" "$target" 2>/dev/null || true
  elif [ "$FM_SM_LIVE_KILL" = wedged ]; then
    fm_secondmate_liveness_wedge_recover "$meta" "$id" || {
      FM_SM_LIVE_STATUS=skipped
      FM_SM_LIVE_RC=1
      return 1
    }
    # The recovery above kills only the agent, so the pane survives as a bare
    # shell - and the spawn below creates a NEW pane rather than reusing it,
    # exactly as it does for a `dead` endpoint. Close the agent-free pane here
    # for the same reason that branch does, or every local wedge recovery would
    # leak a husk pane. This stays inside "SIGKILL only that pane's agent
    # process": nothing is running in the pane any more, and no session server
    # or sibling pane is touched. A remote route needs nothing here - its own
    # host-local launch path already removes a confirmed agent-less endpoint
    # before relaunching.
    if [ -z "$(fm_meta_get "$meta" remote_host)" ]; then
      backend=$(fm_backend_of_meta "$meta")
      target=$(fm_backend_target_of_meta "$meta")
      [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
      [ -z "$target" ] || fm_backend_kill "$backend" "$target" 2>/dev/null || true
    fi
  fi
  local rc=0
  if [ -n "$timeout" ]; then
    FM_SM_LIVE_OUT=$(FM_SPAWN_NO_GUARD=1 fm_run_timed "$timeout" "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1) || rc=$?
  else
    FM_SM_LIVE_OUT=$(FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate 2>&1) || rc=$?
  fi
  FM_SM_LIVE_RC=$rc
  if [ "$rc" -eq 0 ]; then
    fm_secondmate_liveness_ledger_add "$id" relaunched || true
  else
    fm_secondmate_liveness_ledger_add "$id" failed || true
  fi
  # A kill of a LIVE agent is always announced, success or failure. A `dead`
  # endpoint's recovery stays as quiet as it has always been: nothing was
  # running there to lose.
  [ "$FM_SM_LIVE_KILL" != wedged ] || fm_secondmate_liveness_wedge_alarm "$id" "$rc"
  return "$rc"
}
