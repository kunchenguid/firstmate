#!/usr/bin/env bash
# fm-startup-network.sh - the deferred startup stage of a session start.
#
# WHY THIS EXISTS. Every external-network call a session start makes used to run
# BEFORE the digest printed, on a hook that blocks session initialization: `gh
# auth status`, the secondmate liveness and convergence sweeps (per-secondmate
# remote probes, which bootstrap runs concurrently), pending remote
# handoff delivery, and the fleet-sync fetch of every project clone. None of
# those calls is individually bounded, so one unreachable host could consume the
# whole FM_SESSION_START_TIMEOUT budget and truncate the digest outright, turning
# a slow network into a startup that never printed the work queue at all.
# This script runs exactly that work OFF the blocking path: the digest is
# composed from bounded local reads while these checks run concurrently in a
# detached worker, and their result is reported back inline when it finishes in
# time, or as a durable wake when it does not. The locked startup's bounded
# inactive-outcome scan also runs here because its local current-state reads can
# be just as slow; that scan publishes its own findings to the durable wake queue.
#
# WHAT IS PRESERVED. Nothing is dropped. bin/fm-bootstrap.sh remains the single
# owner of every network sweep and still runs all of them, unchanged, via its
# FM_BOOTSTRAP_NETWORK=only phase. bin/fm-inactive-reconcile.sh remains the
# owner of the startup scan and its separate watcher cadence. Deferral changes
# WHEN they run, not WHETHER, and three properties make the later run safe:
#   - The work is idempotent detection. A run whose report is lost (killed
#     worker, truncated digest, crashed session) loses no finding: the next run
#     re-derives the same inactive terminal child, dead secondmate, stuck clone,
#     or undelivered handoff. There is no once-only signal to miss.
#   - Results are durable and always surface. Network sweep output lands in
#     state/.startup-network.report and reaches the agent either inline in the
#     digest or, when it finishes too late for the digest to inline it, as a
#     `check: startup-network` wake. Inactive-scan findings land directly in the
#     ordinary durable wake queue. The report wakes only when the late result is
#     itself actionable (state is not "done", or bootstrap emitted something
#     other than its explicit BOOTSTRAP_INFO no-action record;
#     report_requires_wake owns that transport test). A late-finishing clean run is not captain-facing progress
#     (AGENTS.md section 8) and never becomes a wake row; it is still durable
#     in the report file for `... report` to read on demand. Only a durable
#     acknowledgement written after harvest prints the finished result
#     suppresses the wake, so a claimant that exits first cannot lose the
#     result. While the worker is still running the digest states by name what
#     is not yet confirmed.
#   - Mutation authority is leased. The worker outlives the command that launched
#     it, so it takes the same acquisition lease a new session must hold before
#     replacing a dead owner, re-checks the captured owner under that lease, and
#     holds it through the bounded mutating run. A takeover stays read-only until
#     that run settles, so old and new owners can never sweep concurrently.
#
# Usage: fm-startup-network.sh start --locked <0|1> --harvest-pid <pid>
#          Launch the detached worker and return immediately. Single-flight: a
#          running worker is reused only when its phases cover this request and,
#          for locked work, it belongs to the same lock owner. A probe-only
#          worker therefore cannot satisfy a later locked request; the later
#          request gets a distinct generation and runs the locked phases. A new
#          owner also gets a distinct generation. --locked 1 asks
#          for the inactive-outcome scan and mutating sweeps as well as the
#          read-only probe; --locked 0 asks for the probe only. --harvest-pid
#          names the session-start process
#          that will try to print the result inline, so the worker can tell
#          whether a wake is still needed.
#        fm-startup-network.sh run --locked <0|1>
#          Run the checks in the foreground and publish the result. This is what
#          `start` detaches with its private generation reservation; run it
#          directly to redo the stage by hand from the lock-owning harness.
#        fm-startup-network.sh harvest --pid <pid>
#          Print the digest's NETWORK CHECKS section and release the inline-print
#          claim. Called by bin/fm-session-start.sh, not by hand.
#        fm-startup-network.sh report
#          Print the current state and report without changing anything, then the
#          last run's per-step elapsed times. This is the ONLY command that prints
#          those timings: `harvest` composes the session-start digest, and adding
#          diagnostic detail there would make every startup pay for a question
#          only a slow run raises.
#        fm-startup-network.sh wait [<seconds>]
#          Block until the report is published, up to <seconds> (default 120).
#          For operators and tests only; a session start never waits.
#
# STATE, all under this home's state/ and gitignored with it:
#   .startup-network.status   key=value record - generation, lock_pid, state,
#                             pid, started, finished, rc, locked, phases, and
#                             whether the report was published. The single
#                             source of truth for what ran and how it ended.
#   .startup-network.report   the sweep output, byte for byte as
#                             bin/fm-bootstrap.sh produced it, plus a
#                             NETWORK_CHECKS: line whenever the stage itself
#                             could not complete or had to downgrade.
#   .startup-network.claim    the generation and pid of a session start that
#                             intends to print the result inline; a matching live
#                             claimant gives harvest a bounded chance to finish.
#   .startup-network.delivered
#                             a durable acknowledgement that harvest printed the
#                             current finished result; only this suppresses its
#                             wake.
#   .startup-network.timings  per-step elapsed times for the last run, in
#                             bin/fm-timing-lib.sh's tab-separated format: the
#                             stage total, one record per network phase (gh auth,
#                             secondmate liveness, secondmate convergence, handoff
#                             delivery, fleet sync), one per secondmate for the
#                             remote-touching steps (id and host), and one per
#                             project clone. Published for a timed-out or failed
#                             run too, where a partial record is the answer.
#                             Diagnostic only: nothing reads it to make a
#                             decision, and losing it never downgrades a run.
#   .startup-network.lock     serializes publication, harvest acknowledgement,
#                             and the wake decision.
#
# The whole stage is bounded by FM_STARTUP_NETWORK_TIMEOUT (default 120s), one
# aggregate deadline covering both the inactive-outcome scan and network sweeps.
# Hitting the bound is reported as an actionable NETWORK_CHECKS: line, never as
# silence. bin/fm-timeout-lib.sh remains the single owner of bounded execution.
#
# The worker also ends its run when this home's state directory is gone. It
# outlives the command that launched it by design, so the home can be removed
# underneath it - a retired home, a torn-down fixture - and every lock it still
# needs then lives in a directory nothing will recreate. Waiting there is
# unbounded, so a vanished home ends the run instead: there is nowhere left to
# publish a report or queue a wake, and the work is idempotent detection the
# next session re-derives in full.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

STATUS_FILE="$STATE/.startup-network.status"
REPORT_FILE="$STATE/.startup-network.report"
CLAIM_FILE="$STATE/.startup-network.claim"
DELIVERED_FILE="$STATE/.startup-network.delivered"
TIMINGS_FILE="$STATE/.startup-network.timings"
PUBLISH_LOCK="$STATE/.startup-network.lock"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# fm-timing-lib.sh owns the per-step elapsed record this stage publishes beside
# its report. Recording is opt-in per run: it stays inert until cmd_run points
# FM_TIMING_LOG at a file, so nothing else that sources these scripts pays for it.
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# fm-wake-lib.sh owns both the portable lock helpers used below and the durable
# wake queue this stage publishes into.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-startup-network.sh" | sed 's/^# \{0,1\}//; $d'
}

status_get() {  # <key>
  [ -f "$STATUS_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATUS_FILE" 2>/dev/null | tail -1
}

write_atomic() {  # <dest>, content on stdin
  local dest=$1 tmp
  tmp=$(mktemp "$dest.XXXXXX" 2>/dev/null) || return 1
  if cat > "$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

now() { date +%s; }

age_of() {  # <epoch> - seconds since, or empty when unreadable
  local then=$1
  case "$then" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$(( $(now) - then ))"
}

stage_budget() {
  local budget=${FM_STARTUP_NETWORK_TIMEOUT:-120}
  case "$budget" in ''|*[!0-9]*|0) budget=120 ;; esac
  printf '%s' "$budget"
}

delivery_budget() {
  local budget=${FM_SESSION_START_TIMEOUT:-120}
  case "$budget" in ''|*[!0-9]*|0) budget=120 ;; esac
  printf '%s' "$budget"
}

# Every lock this worker waits for lives inside the home's state directory, so
# every wait for one is also a wait on that directory still existing. A lock
# whose parent is gone can never be created and no holder can ever release it,
# while fm_lock_acquire_wait waits for a holder that will never appear - which
# turns a removed home into a detached process polling for as long as the
# machine stays up.
#
# So this waits on the same 0.1s cadence but re-tests the home on every tick.
# Ordinary contention is exactly as patient as fm_lock_acquire_wait, because a
# lock that is merely held keeps the loop going; only a home that has actually
# vanished ends it, and it ends as a refusal the caller acts on rather than as a
# hang. Callers MUST check the return value - continuing would mean acting on a
# lock this never took.
home_lock_acquire() {  # <lockdir> - 1 once this home's state directory is gone
  local lockdir=$1
  while [ -d "$STATE" ]; do
    fm_lock_try_acquire "$lockdir" && return 0
    sleep 0.1
  done
  return 1
}

# Is a `running` record a stage that is genuinely still in flight? Two
# independent proofs are required, because either one alone can lie: a recorded
# pid can be reused by an unrelated process, and a worker killed with its process
# group (which is what a truncated digest does) leaves the record behind
# untouched. A record that outlives the stage's own aggregate bound is therefore
# treated as abandoned no matter what its pid says, which keeps "in progress"
# from becoming a permanent state.
worker_alive() {
  local pid started age
  pid=$(status_get pid)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  started=$(status_get started)
  age=$(age_of "$started")
  case "$age" in ''|*[!0-9]*) return 0 ;; esac
  [ "$age" -le "$(( $(stage_budget) + 30 ))" ]
}

# The exact phase names the digest and the report use, so "what has not been
# confirmed yet" is always answerable from the status record alone.
phase_label() {  # <phases>
  case "$1" in
    probe) printf 'GitHub authentication' ;;
    probe,sweeps) printf 'GitHub authentication, dead-secondmate relaunch, secondmate convergence, pending handoff delivery, project clone refresh with its drift reporting, and inactive terminal-outcome reconciliation' ;;
    *) printf 'the deferred network checks' ;;
  esac
}

# --- start -------------------------------------------------------------------

worker_covers_request() {  # <locked> <lock-pid>
  local locked=$1 lock_pid=$2
  [ "$locked" != 1 ] && return 0
  [ "$(status_get lock_pid)" = "$lock_pid" ] \
    && [ "$(status_get phases)" = probe,sweeps ]
}

cmd_start() {  # <locked> <harvest-pid>
  local locked=$1 harvest_pid=$2 lock_pid generation worker_pid phases started
  mkdir -p "$STATE" 2>/dev/null || return 1
  # Captured HERE, at the moment the caller still holds the lock, and carried to
  # the worker: re-reading the lock later would only prove that SOME session
  # holds it, which is exactly the case this guard exists to reject.
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  if [ "$locked" = 1 ] && ! fm_session_lock_owned_by_self "$STATE"; then
    return 1
  fi

  fm_lock_acquire_wait "$PUBLISH_LOCK"
  if [ "$(status_get state)" = running ] && worker_alive \
    && worker_covers_request "$locked" "$lock_pid"; then
    # A worker whose phases cover this request is still going. Starting another
    # would duplicate its work and, for a locked request, race the same mutating
    # sweeps, so leave it alone and let harvest report its real state.
    generation=$(status_get generation)
    printf '%s\t%s\n' "$generation" "$harvest_pid" > "$CLAIM_FILE" 2>/dev/null || true
    fm_lock_release "$PUBLISH_LOCK"
    return 0
  fi

  generation="$(now).$$.$harvest_pid"
  started=$(now)
  phases=probe
  [ "$locked" != 1 ] || phases=probe,sweeps
  if ! write_atomic "$STATUS_FILE" <<EOF
state=running
pid=0
started=$started
locked=$locked
phases=$phases
generation=$generation
lock_pid=$lock_pid
EOF
  then
    fm_lock_release "$PUBLISH_LOCK"
    return 1
  fi

  # Detached three ways, each closing a different failure:
  #   - stdio to /dev/null, because the digest's stdout is a pipe the harness
  #     reads to EOF; a worker holding that pipe open would strand session
  #     initialization behind the very work this stage exists to take off the
  #     blocking path.
  #   - nohup, so the worker outlives the shell that launched it.
  #   - its OWN process group (monitor mode), because the caller runs inside the
  #     digest's bounded child and that bound terminates its whole process group.
  #     Sharing the group would kill the worker on a truncated startup and, worse,
  #     orphan the bootstrap child it had already launched into a separate group -
  #     leaving unbounded network work running with nothing left to bound it. Its
  #     own group means a truncated digest leaves this stage running under its own
  #     deadline, which is exactly the independence deferral is for.
  local monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  nohup "$SCRIPT_DIR/fm-startup-network.sh" run --locked "$locked" --lock-pid "$lock_pid" \
    --generation "$generation" \
    >/dev/null 2>&1 </dev/null &
  worker_pid=$!
  if ! write_atomic "$STATUS_FILE" <<EOF
state=running
pid=$worker_pid
started=$started
locked=$locked
phases=$phases
generation=$generation
lock_pid=$lock_pid
EOF
  then
    kill "$worker_pid" 2>/dev/null || true
    fm_lock_release "$PUBLISH_LOCK"
    [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
    return 1
  fi
  printf '%s\t%s\n' "$generation" "$harvest_pid" > "$CLAIM_FILE" 2>/dev/null || true
  fm_lock_release "$PUBLISH_LOCK"
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  return 0
}

# --- run ---------------------------------------------------------------------

# Re-verify mutation authority immediately before the mutating sweeps: "my
# session held the lock a moment ago" is not enough for a worker that outlives
# the command which launched it.
#
# The question is deliberately "does the lock still name the session that asked
# for this work?", not "is that session still alive". The hazard being closed is
# a SECOND session sweeping concurrently, and taking the lock is exactly what
# rewrites this value - bin/fm-lock.sh overwrites a dead holder's pid with its
# own. An unchanged value therefore proves no one else owns the sweeps, which is
# the whole guarantee. Requiring liveness instead would refuse to finish work
# nobody else has claimed, and the sweeps are idempotent, so finishing it is
# strictly better than abandoning it. A missing, unreadable, or replaced lock all
# fail closed to the read-only probe.
lock_unchanged() {  # <expected-pid>
  local expected=$1 current
  case "$expected" in ''|*[!0-9]*) return 1 ;; esac
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  current=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$current" = "$expected" ]
}

# Bootstrap owns the meaning of its output protocol: silence is success,
# BOOTSTRAP_INFO is an explicit completed no-action fact, and every other line
# is a diagnostic. This delivery layer does not maintain a second semantic
# prefix list or decide what a diagnostic means; it only applies that producer-
# supplied transport type. Unknown non-empty output fails safe by waking.
report_requires_wake() {  # <state>
  local state=$1
  [ "$state" = "done" ] || return 0
  [ -s "$REPORT_FILE" ] || return 1
  awk 'NF && $0 !~ /^BOOTSTRAP_INFO:/ { found=1; exit } END { exit !found }' \
    "$REPORT_FILE" 2>/dev/null
}

await_delivery() {  # <generation> <state>
  local generation=$1 state=$2 limit waited=0 claim_record claim_generation claim_pid claim_live
  limit=$(( $(delivery_budget) * 10 ))
  while [ "$waited" -lt "$limit" ]; do
    claim_live=0
    home_lock_acquire "$PUBLISH_LOCK" || return 0
    if [ "$(status_get generation)" != "$generation" ]; then
      fm_lock_release "$PUBLISH_LOCK"
      return 0
    fi
    if [ -f "$DELIVERED_FILE" ]; then
      fm_lock_release "$PUBLISH_LOCK"
      return 0
    fi
    if [ -f "$CLAIM_FILE" ]; then
      claim_record=$(cat "$CLAIM_FILE" 2>/dev/null || true)
      IFS=$'\t' read -r claim_generation claim_pid <<EOF
$claim_record
EOF
      if [ "$claim_generation" = "$generation" ]; then
        case "$claim_pid" in
          ''|*[!0-9]*) ;;
          *) kill -0 "$claim_pid" 2>/dev/null && claim_live=1 ;;
        esac
      fi
      [ "$claim_live" -eq 1 ] || rm -f "$CLAIM_FILE" 2>/dev/null || true
    fi
    if [ "$claim_live" -eq 0 ]; then
      if report_requires_wake "$state"; then
        fm_wake_append check startup-network \
          "check: startup-network: deferred startup network checks finished ($state); read them with $FM_ROOT/bin/fm-startup-network.sh report" \
          || true
      fi
      fm_lock_release "$PUBLISH_LOCK"
      return 0
    fi
    fm_lock_release "$PUBLISH_LOCK"
    sleep 0.1
    waited=$((waited + 1))
  done
  home_lock_acquire "$PUBLISH_LOCK" || return 0
  if [ "$(status_get generation)" != "$generation" ] || [ -f "$DELIVERED_FILE" ]; then
    fm_lock_release "$PUBLISH_LOCK"
    return 0
  fi
  if report_requires_wake "$state"; then
    fm_wake_append check startup-network \
      "check: startup-network: deferred startup network checks finished ($state); read them with $FM_ROOT/bin/fm-startup-network.sh report" \
      || true
  fi
  fm_lock_release "$PUBLISH_LOCK"
}

publish() {  # <generation> <state> <phases> <locked> <started> <rc> <output-file> <timing-file>
  local generation=$1 state=$2 phases=$3 locked=$4 started=$5 rc=$6 out=$7 timings=${8:-} report_published=1
  home_lock_acquire "$PUBLISH_LOCK" || return 0
  if [ "$(status_get generation)" != "$generation" ]; then
    fm_lock_release "$PUBLISH_LOCK"
    return 0
  fi
  # Timings are published for EVERY outcome, including timeout and failure: a run
  # that hit the bound is exactly the run whose per-step record is worth having,
  # and whatever the killed sweeps managed to append is a real partial answer.
  # A timing record is diagnostic only, so a failure to publish it is discarded
  # rather than downgrading the run - the report itself is the contract.
  if [ -n "$timings" ] && [ -f "$timings" ]; then
    write_atomic "$TIMINGS_FILE" < "$timings" || true
  fi
  if ! write_atomic "$REPORT_FILE" < "$out"; then
    state=failed
    rc=1
    report_published=0
  fi
  rm -f "$DELIVERED_FILE" 2>/dev/null || true
  write_atomic "$STATUS_FILE" <<EOF || true
state=$state
pid=$$
started=$started
finished=$(now)
rc=$rc
locked=$locked
phases=$phases
generation=$generation
lock_pid=$(status_get lock_pid)
report_published=$report_published
EOF
  fm_lock_release "$PUBLISH_LOCK"
  await_delivery "$generation" "$state"
}

cmd_run() {  # <locked> <lock-pid> <generation>
  local locked=$1 lock_pid=$2 generation=$3 phases started budget out rc sweep_locked=0 downgraded=0 internal=0 lease_held=0 timings stage_started
  mkdir -p "$STATE" 2>/dev/null || return 1
  started=$(now)
  budget=$(stage_budget)
  phases=probe
  if [ -n "$generation" ]; then
    home_lock_acquire "$PUBLISH_LOCK" || return 1
    if [ "$(status_get generation)" = "$generation" ] && [ "$(status_get pid)" = "$$" ]; then
      internal=1
      started=$(status_get started)
    fi
    fm_lock_release "$PUBLISH_LOCK"
    [ "$internal" -eq 1 ] || return 1
  elif [ "$locked" = 1 ] && ! fm_session_lock_owned_by_self "$STATE"; then
    downgraded=1
    locked=0
  fi
  if [ "$locked" = 1 ]; then
    [ "$internal" -eq 1 ] || lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
    if lock_unchanged "$lock_pid"; then
      sweep_locked=1
      phases=probe,sweeps
    else
      downgraded=1
    fi
  fi

  if [ "$internal" -eq 0 ]; then
    generation="$(now).$$.manual"
    home_lock_acquire "$PUBLISH_LOCK" || return 1
    if [ "$(status_get state)" = running ] && worker_alive; then
      fm_lock_release "$PUBLISH_LOCK"
      return 1
    fi
    write_atomic "$STATUS_FILE" <<EOF || true
state=running
pid=$$
started=$started
locked=$sweep_locked
phases=$phases
generation=$generation
lock_pid=$lock_pid
EOF
    fm_lock_release "$PUBLISH_LOCK"
  fi

  out=$(mktemp "${TMPDIR:-/tmp}/fm-startup-network.XXXXXX" 2>/dev/null) || return 1
  # Recorded into a temp file rather than straight into state/ so a run that is
  # killed mid-sweep cannot leave a half-written artifact where the previous
  # run's complete one used to be; publish() promotes it atomically at the end.
  # Sweeps run in child processes (bin/fm-bootstrap.sh, and bin/fm-fleet-sync.sh
  # below it), so FM_TIMING_LOG is exported and appended to by all of them.
  timings=$(mktemp "${TMPDIR:-/tmp}/fm-startup-network-timings.XXXXXX" 2>/dev/null) || timings=
  [ -z "$timings" ] || fm_timing_start "$timings"
  stage_started=$(fm_timing_now_ms)
  rc=0
  if [ "$sweep_locked" -eq 1 ]; then
    if ! home_lock_acquire "$STATE/.lock.acquire"; then
      # The home vanished while this run waited for the sweep lease. There is
      # nothing left to sweep for or publish into, so the only thing still worth
      # doing is dropping the scratch files this run had already opened.
      rm -f "$out" 2>/dev/null || true
      [ -z "$timings" ] || rm -f "$timings" 2>/dev/null || true
      return 1
    fi
    lease_held=1
    if ! lock_unchanged "$lock_pid"; then
      sweep_locked=0
      phases=probe
      downgraded=1
    fi
  fi
  # One aggregate deadline covers both deferred operations. The inactive scan
  # retains its own tighter per-scan bound inside this outer bound. Findings
  # need no report translation: the scan writes its ordinary durable
  # inactive-outcome wakes directly. A child shell composes the two executable
  # owners only so fm_run_timed can govern them as one process group.
  if [ "$sweep_locked" -eq 1 ]; then
    # shellcheck disable=SC2016  # Child-shell variables expand inside the bound.
    fm_run_timed "$budget" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_NETWORK_LOCK_PID="$lock_pid" \
      bash -c '
        script_dir=$1
        "$script_dir/fm-inactive-reconcile.sh" scan --startup >/dev/null 2>&1 || true
        exec "$script_dir/fm-bootstrap.sh"
      ' _ "$SCRIPT_DIR" >"$out" 2>&1 || rc=$?
  else
    fm_run_timed "$budget" env FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_DETECT_ONLY=1 \
      "$SCRIPT_DIR/fm-bootstrap.sh" >"$out" 2>&1 || rc=$?
  fi
  [ "$lease_held" -eq 0 ] || fm_lock_release "$STATE/.lock.acquire"
  # The bounded run as a whole, so the per-phase records can be read against the
  # total even when the bound cut some of them off.
  fm_timing_record stage network-checks "$stage_started" "$phases"

  if [ "$downgraded" -eq 1 ]; then
    printf 'NETWORK_CHECKS: the fleet lock was no longer held by the session that requested these, so dead-secondmate relaunch, secondmate convergence, pending handoff delivery, and project clone refresh were skipped; they belong to whichever session holds the lock now\n' >> "$out"
  fi
  case "$rc" in
    0) publish "$generation" 'done' "$phases" "$sweep_locked" "$started" "$rc" "$out" "$timings" ;;
    124)
      printf 'NETWORK_CHECKS: hit the %ss bound before finishing, so %s may be incomplete; rerun %s/bin/fm-startup-network.sh run --locked %s\n' \
        "$budget" "$(phase_label "$phases")" "$FM_ROOT" "$sweep_locked" >> "$out"
      publish "$generation" timeout "$phases" "$sweep_locked" "$started" "$rc" "$out" "$timings"
      ;;
    *)
      printf 'NETWORK_CHECKS: the deferred check worker exited %s, so %s may be incomplete; rerun %s/bin/fm-startup-network.sh run --locked %s\n' \
        "$rc" "$(phase_label "$phases")" "$FM_ROOT" "$sweep_locked" >> "$out"
      publish "$generation" failed "$phases" "$sweep_locked" "$started" "$rc" "$out" "$timings"
      ;;
  esac
  rm -f "$out" 2>/dev/null || true
  [ -z "$timings" ] || rm -f "$timings" 2>/dev/null || true
  return 0
}

# --- harvest / report --------------------------------------------------------

print_finished() {  # <state>
  local state=$1 phases started finished took=unknown report_published
  phases=$(status_get phases)
  started=$(status_get started)
  finished=$(status_get finished)
  report_published=$(status_get report_published)
  case "$started$finished" in
    ''|*[!0-9]*) ;;
    *) took=$((finished - started)) ;;
  esac
  printf 'completed off the startup path in %ss: %s.\n' "$took" "$(phase_label "$phases")"
  [ "$state" = 'done' ] || printf 'The stage itself did not finish cleanly (%s) - the NETWORK_CHECKS line below names what to rerun.\n' "$state"
  if [ "$report_published" = 0 ]; then
    printf 'NETWORK_CHECKS: could not publish the deferred check report, so %s results are unavailable; rerun %s/bin/fm-startup-network.sh run --locked %s\n' \
      "$(phase_label "$phases")" "$FM_ROOT" "$(status_get locked)"
  elif [ -s "$REPORT_FILE" ]; then
    cat "$REPORT_FILE"
    printf 'These ran AFTER the sections above were composed, so re-read any record a line here names.\n'
  else
    printf '(silent - no problems found)\n'
  fi
}

# Deliberately NOT part of print_state, and so deliberately not part of harvest:
# harvest composes the digest's NETWORK CHECKS section, and this record is
# diagnostic detail nobody needs on an ordinary session start. It is printed only
# by the on-demand `report` command, so the timings cost a reader nothing until
# a run is actually slow enough to ask about.
print_timings() {
  fm_timing_render "$TIMINGS_FILE"
}

print_pending() {
  local phases started age
  phases=$(status_get phases)
  started=$(status_get started)
  age=$(age_of "$started")
  printf 'IN PROGRESS - the deferred network checks have not finished yet.\n'
  printf 'NOT yet confirmed: %s.\n' "$(phase_label "$phases")"
  [ -z "$age" ] || printf 'Started %ss ago, bounded at %ss.\n' "$age" "$(stage_budget)"
  # shellcheck disable=SC2016  # The backticked wake name is literal digest text.
  printf 'Only a FAILED or otherwise actionable result arrives as a `check: startup-network` wake; a clean success stays silent.\n'
  printf 'The durable result is readable on demand with %s/bin/fm-startup-network.sh report; until it finishes, treat none of it as confirmed.\n' "$FM_ROOT"
}

print_state() {
  case "$(status_get state)" in
    done|timeout|failed) print_finished "$(status_get state)" ;;
    running)
      if worker_alive; then
        print_pending
      else
        printf 'NETWORK_CHECKS: the deferred check worker stopped before publishing, so %s did not complete; rerun %s/bin/fm-startup-network.sh run --locked %s\n' \
          "$(phase_label "$(status_get phases)")" "$FM_ROOT" "$(status_get locked)"
      fi
      ;;
    *) printf 'not started - no deferred network checks have run for this home yet.\n' ;;
  esac
}

cmd_harvest() {  # <pid>
  local pid=$1 generation state claim_record claim_generation claim_pid
  fm_lock_acquire_wait "$PUBLISH_LOCK"
  generation=$(status_get generation)
  # Another session's live claim is left alone; the worker reaps a dead one.
  if [ -f "$CLAIM_FILE" ]; then
    claim_record=$(cat "$CLAIM_FILE" 2>/dev/null || true)
    IFS=$'\t' read -r claim_generation claim_pid <<EOF
$claim_record
EOF
    if [ "$claim_generation" = "$generation" ] \
      && { [ -z "$pid" ] || [ "$claim_pid" = "$pid" ]; }; then
      rm -f "$CLAIM_FILE" 2>/dev/null || true
    fi
  fi
  state=$(status_get state)
  print_state
  case "$state" in
    done|timeout|failed) [ "$(status_get report_published)" = 0 ] || write_atomic "$DELIVERED_FILE" <<EOF || true
delivered
EOF
      ;;
  esac
  fm_lock_release "$PUBLISH_LOCK"
}

cmd_wait() {  # <seconds>
  local limit=$1 waited=0
  case "$limit" in ''|*[!0-9]*) limit=120 ;; esac
  while [ "$waited" -lt "$limit" ]; do
    case "$(status_get state)" in
      done|timeout|failed) return 0 ;;
      running) worker_alive || return 1 ;;
    esac
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# --- entry -------------------------------------------------------------------

LOCKED=0
HARVEST_PID=
LOCK_PID=
GENERATION=
MODE=${1:-}
[ $# -eq 0 ] || shift
while [ $# -gt 0 ]; do
  case "$1" in
    --locked) LOCKED=${2:-0}; shift; [ $# -eq 0 ] || shift ;;
    --harvest-pid|--pid) HARVEST_PID=${2:-}; shift; [ $# -eq 0 ] || shift ;;
    --lock-pid) LOCK_PID=${2:-}; shift; [ $# -eq 0 ] || shift ;;
    --generation) GENERATION=${2:-}; shift; [ $# -eq 0 ] || shift ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done
case "$LOCKED" in 0|1) ;; *) LOCKED=0 ;; esac

case "$MODE" in
  start) cmd_start "$LOCKED" "${HARVEST_PID:-0}" ;;
  run) cmd_run "$LOCKED" "$LOCK_PID" "$GENERATION" ;;
  harvest) cmd_harvest "${HARVEST_PID:-}" ;;
  report) print_state; print_timings ;;
  wait) cmd_wait "${1:-120}" || exit $? ;;
  -h|--help) usage ;;
  *)
    printf 'fm-startup-network: unknown mode: %s\n' "${MODE:-<none>}" >&2
    printf 'usage: fm-startup-network.sh start|run|harvest|report|wait\n' >&2
    exit 2
    ;;
esac
exit 0
