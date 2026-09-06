#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background), or - for a Claude
# primary - inside the Stop asyncRewake hook's foreground process tree
# (bin/fm-claude-stop-autoarm.sh), where the harness owns the process group and
# the hook's exit-2 rewake is the notification. Run it as its own standalone
# background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
# On a harness with a PreToolUse-equivalent hook, bin/fm-arm-pretool-check.sh
# applies the command-position policy before the command runs; see
# docs/arm-pretool-check.md for the blessed tree and deny reason codes. It is a
# pre-execution seatbelt, not a substitute for the verification here.
#
# This script forks the watcher as a tracked child, then VERIFIES the outcome
# before it settles in. It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the
# single source of truth, shared with fm-watch.sh and fm-guard.sh), and prints
# exactly one unambiguous TERMINAL status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: attached pid=<N> (beacon <age>s, verified <W>s[, beacon advanced])
#                                                        - a live+fresh successor holds the lock
#                                                          and STAYED this home's live watcher for
#                                                          the whole verification window; this arm
#                                                          attaches and follows it
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
#   watcher: FAILED - cycle ended without an actionable reason
#                                                        - a clean cycle ended with no wake and no
#                                                          verified healthy successor
# A failed attach prints one non-terminal line before that terminal line, exactly
# one of:
#   watcher: restarting after a failed attach - <why>    - the target stopped verifying inside the
#                                                          verification window, so this arm
#                                                          re-executes itself as --restart and the
#                                                          terminal line is the exec'd arm's own
#   watcher: attach abandoned - <why> (no restart budget left)
#                                                        - the restart budget is spent, so this arm
#                                                          starts its own watcher and the terminal
#                                                          line is the started/FAILED one it reports
# Neither non-terminal line matches the adapters' `^watcher: (started|attached)`
# readiness pattern, so a restart is spent out of the adapter's arm-readiness
# budget (FM_PI_ARM_READY_TIMEOUT_MS / FM_OPENCODE_ARM_READY_TIMEOUT_MS).
# Every FAILED line carries concrete evidence in parentheses - exit code, trapped
# signal, watcher-reported step, stderr tail, lock pid and liveness, beacon age,
# queued-wake count, and the last recorded lifecycle row for the watcher - because
# a failure an operator cannot act on is the same as no report at all.
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started it waits the child and propagates the wake
# reason; on attached it stays live across identity-matched successors. A cycle
# that ends with no reason line and no healthy successor is resolved against the
# watcher's identity-bound delivery record: a matching record reports that wake
# and exits 0, and only a cycle that delivered nothing is the typed nonzero
# failure. Neither is ever a clean empty completion. On FAILED it exits non-zero
# so the failure is loud. A live cycle already present means re-arm attaches - do
# not start a second watcher.
#
# ATTACH IS NOT A SINGLE READ. One healthy read proves the target was alive
# RECENTLY, not that it is alive now, and a fresh beacon inside the grace can
# coexist with no watcher process at all. Every attach therefore holds its claim
# for FM_ARM_ATTACH_VERIFY seconds and keeps re-checking process liveness, lock
# identity, and beacon freshness before the attached line is printed; when the
# beacon advances inside that window the line says so, because that is positive
# proof of progress rather than of recent existence. A target that stops
# verifying inside the window is a FAILED attach, and this arm re-executes itself
# as `--restart` (bounded by FM_ARM_RESTART_MAX, tracked through
# FM_ARM_RESTART_DEPTH) so supervision is genuinely restored instead of reported
# restored. A lock that MOVES inside the window to a different pid which passes
# that same gate is not a failed attach at all - that successor is healthy, and
# `--restart` would TERM it - so the arm retargets onto it and verifies it from
# scratch, bounded by FM_ARM_ATTACH_RETARGET_MAX so a flapping lock cannot loop
# forever. A lock whose pid is live but whose identity is not published yet is
# that same successor caught mid-claim: it is SETTLING, not unhealthy, so the
# window keeps polling instead of restarting over it, while a dead pid, a foreign
# home, or a published identity that does not match still fails fast.
# Past the window the attached poll keeps re-checking the same three
# facts every FM_ARM_ATTACH_POLL, so a later death is caught within one poll.
#
# Every observed watcher cycle appends one tab-separated lifecycle record to
# state/.watch-cycle-exits.log. The arm layer owns that bounded ledger; it records
# arm/watcher identities, timestamps, exit/signal classification, beacon age,
# lock identity before and after close, and successor disposition. The separate
# state/.watch-triage.log remains exclusively the watcher's absorbed-wake debug
# log and is never written here.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and own a fresh cycle, or attach if a verified live peer
# wins the singleton while the duplicate child stands down. It
# resolves and signals exactly that pid, so it can never touch another home's
# watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
# Git Bash/MSYS pays a much higher fork cost while the watcher completes its
# required pre-lock migration, so its bounded default covers that cold start.
case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*) ARM_CONFIRM_DEFAULT=30 ;;
  *) ARM_CONFIRM_DEFAULT=10 ;;
esac
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-$ARM_CONFIRM_DEFAULT}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}
# How long an attach candidate must keep verifying as this home's live watcher
# before the attached line may claim it, how many times one attach may retarget
# onto a healthy successor that takes the lock mid-window, and how many times one
# arm may re-execute itself as --restart after a failed attach.
ATTACH_VERIFY=${FM_ARM_ATTACH_VERIFY:-2}
ATTACH_RETARGET_MAX=${FM_ARM_ATTACH_RETARGET_MAX:-2}
ARM_RESTART_MAX=${FM_ARM_RESTART_MAX:-1}
# How many CONSECUTIVE replacement candidates may fail verification while this
# arm is still following a healthy watcher, before the arm stops re-evaluating
# and returns a terminal result. Counted consecutively and reset by any candidate
# that does verify, so ordinary handovers never accumulate toward it.
ATTACH_REPLACEMENT_MAX=${FM_ARM_ATTACH_REPLACEMENT_MAX:-20}
ARM_RESTART_DEPTH=${FM_ARM_RESTART_DEPTH:-0}
STDERR_TAIL_LINES=${FM_ARM_STDERR_TAIL_LINES:-5}
# A zero window would collapse the gate to the single healthy read this script
# exists to stop trusting, while still printing "verified 0s" as if it passed.
case "$ATTACH_VERIFY" in *[!0-9]*|''|0) ATTACH_VERIFY=2 ;; esac
# A zero retarget budget would make the first mid-window lock move a failed
# attach again, so the arm would TERM a verified-healthy successor: retargeting
# is a correctness property, not a tunable-off feature.
case "$ATTACH_RETARGET_MAX" in *[!0-9]*|''|0) ATTACH_RETARGET_MAX=2 ;; esac
case "$ARM_RESTART_MAX" in *[!0-9]*|'') ARM_RESTART_MAX=1 ;; esac
# A zero bound would make the first flap terminal, which is the opposite failure:
# an arm that abandons a healthy watcher over one unlucky sample.
case "$ATTACH_REPLACEMENT_MAX" in *[!0-9]*|''|0) ATTACH_REPLACEMENT_MAX=20 ;; esac
case "$ARM_RESTART_DEPTH" in *[!0-9]*|'') ARM_RESTART_DEPTH=0 ;; esac
case "$STDERR_TAIL_LINES" in *[!0-9]*|''|0) STDERR_TAIL_LINES=5 ;; esac
CYCLE_LOG="$STATE/.watch-cycle-exits.log"
CYCLE_LOG_LOCK="$STATE/.watch-cycle-exits.lock"
CYCLE_LOG_MAX_BYTES=${FM_WATCH_CYCLE_LOG_MAX_BYTES:-262144}
CYCLE_LOG_KEEP_LINES=${FM_WATCH_CYCLE_LOG_KEEP_LINES:-1000}
ARM_PID=${BASHPID:-$$}
case "$CYCLE_LOG_MAX_BYTES" in ''|*[!0-9]*|0) CYCLE_LOG_MAX_BYTES=262144 ;; esac
case "$CYCLE_LOG_KEEP_LINES" in ''|*[!0-9]*|0) CYCLE_LOG_KEEP_LINES=1000 ;; esac

# The lifecycle ledger is diagnostic evidence, not a supervision dependency.
# Writes are bounded and best-effort so an observability failure cannot stall an
# otherwise healthy watcher cycle.
cycle_clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-512
}

lock_snapshot() {
  local pid identity
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  printf 'pid:%s|identity:%s' "$(cycle_clean_field "${pid:-none}")" "$(cycle_clean_field "${identity:-none}")"
}

WATCH_DELIVERY_LOG="$STATE/.watch-deliveries.log"
WATCH_DELIVERY_LOCK="$STATE/.watch-deliveries.lock"

cycle_active=0
cycle_watcher_pid=none
cycle_watcher_identity=none
cycle_origin=unknown
cycle_started_at=0
cycle_lock_before='pid:none|identity:none'

cycle_begin() {
  cycle_watcher_pid=$1
  cycle_origin=$2
  cycle_watcher_identity=$3
  cycle_started_at=$(date +%s)
  cycle_lock_before=$(lock_snapshot)
  cycle_active=1
}

cycle_refresh_lock_before() {
  [ "$cycle_active" -eq 1 ] || return 0
  if [ "$HEALTHY_PID" = "$cycle_watcher_pid" ] && [ -n "$HEALTHY_IDENTITY" ]; then
    cycle_watcher_identity=$HEALTHY_IDENTITY
  fi
  cycle_lock_before=$(lock_snapshot)
}

cycle_signal_name() {
  local rc=$1 signal_number
  case "$rc" in
    ''|*[!0-9]*) printf 'unknown'; return ;;
  esac
  [ "$rc" -gt 128 ] || { printf 'none'; return; }
  signal_number=$((rc - 128))
  kill -l "$signal_number" 2>/dev/null || printf '%s' "$signal_number"
}

cycle_log_append() {
  local exit_code=$1 signal=$2 reason=$3 successor=$4 ended_at beacon_age lock_after size tmp raw i
  [ "$cycle_active" -eq 1 ] || return 0
  ended_at=$(date +%s)
  beacon_age=$(fm_path_age "$BEAT")
  lock_after=$(lock_snapshot)

  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  printf 'arm_pid=%s\twatcher_pid=%s\torigin=%s\tstarted_at=%s\tended_at=%s\texit_code=%s\tsignal=%s\treason=%s\tbeacon_age=%s\tlock_before=%s\tlock_after=%s\tsuccessor=%s\n' \
    "$ARM_PID" \
    "$(cycle_clean_field "$cycle_watcher_pid")" \
    "$(cycle_clean_field "$cycle_origin")" \
    "$cycle_started_at" \
    "$ended_at" \
    "$(cycle_clean_field "$exit_code")" \
    "$(cycle_clean_field "$signal")" \
    "$(cycle_clean_field "$reason")" \
    "$beacon_age" \
    "$(cycle_clean_field "$cycle_lock_before")" \
    "$(cycle_clean_field "$lock_after")" \
    "$(cycle_clean_field "$successor")" >> "$CYCLE_LOG" 2>/dev/null || true

  size=$(wc -c < "$CYCLE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$CYCLE_LOG_MAX_BYTES" ]; then
        tmp="$CYCLE_LOG.tmp.$ARM_PID"
        raw="$tmp.raw"
        tail -n "$CYCLE_LOG_KEEP_LINES" "$CYCLE_LOG" 2>/dev/null \
          | tail -c "$CYCLE_LOG_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^arm_pid=/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$CYCLE_LOG_LOCK"
  cycle_active=0
}

# A persistent adapter passes the arm pid that just closed. Once this new arm
# verifies its watcher, update that predecessor's final record in place so the
# one-record-per-cycle ledger captures the actual successor outcome without an
# extra synthetic lifecycle row.
cycle_mark_predecessor_successor() {
  local successor=$1 predecessor=${FM_WATCH_PREDECESSOR_ARM_PID:-} i tmp
  case "$predecessor" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ -f "$CYCLE_LOG" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  tmp="$CYCLE_LOG.link.$ARM_PID"
  awk -v target="arm_pid=$predecessor" -v replacement="successor=$(cycle_clean_field "$successor")" '
    {
      lines[NR] = $0
      count = split($0, fields, "\t")
      if (fields[1] == target) {
        for (i = 1; i <= count; i += 1) {
          if (fields[i] == "successor=none") last = NR
        }
      }
    }
    END {
      for (i = 1; i <= NR; i += 1) {
        if (i == last) sub(/\tsuccessor=none$/, "\t" replacement, lines[i])
        print lines[i]
      }
    }
  ' "$CYCLE_LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  fm_lock_release "$CYCLE_LOG_LOCK"
}

clear_stale_recorded_watcher_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$WATCH" ] || return 0
  [ -n "$lock_identity" ] || return 0
  fm_recovery_transition "$STATE/.watcher-down" clear-stale-lock "$WATCH_LOCK" downtime
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
HEALTHY_IDENTITY=
healthy_watcher() {
  HEALTHY_PID=
  HEALTHY_IDENTITY=
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" || return 1
  HEALTHY_PID=$FM_WATCHER_HEALTHY_PID
  HEALTHY_IDENTITY=$FM_WATCHER_HEALTHY_IDENTITY
}

# Bounded post-attach verification. A single healthy read proves the target was
# alive RECENTLY; it does not prove the target is alive now, and a beacon still
# inside the grace can coexist with no watcher process at all. Keep re-checking
# liveness, lock identity, and beacon freshness for the whole window, and record
# whether the beacon actually advanced - the one positive proof of progress
# rather than of recent existence. Sets ATTACH_VERIFY_REASON on failure and
# ATTACH_VERIFIED_PID to the pid the window actually ended on, which is not the
# pid passed in when the lock was handed to a healthy successor mid-window.
#
# A failing sample needs no tolerance for a half-published lock: the watcher
# publishes its identity as part of the claim itself (bin/fm-wake-lib.sh's
# _fm_lock_publish_watcher_identity), so a lock this arm can see is always a lock
# it can verify, and an unverifiable one is genuinely unhealthy rather than new.
ATTACH_VERIFY_REASON=
ATTACH_VERIFY_BEACON_ADVANCED=0
ATTACH_VERIFIED_PID=
# Set when verification ended while the lock still named a pid that had just
# passed healthy_watcher. The only recovery a failed attach has is --restart,
# whose first act is TERM on the current lock pid, so restarting on this outcome
# would kill a watcher this arm had just certified as healthy. That is the harm
# the retarget branch exists to prevent, reached through budget expiry instead of
# through a missing retarget.
ATTACH_VERIFY_HEALTHY_HOLDER=0
attach_verified() {  # <pid>
  local pid=$1 deadline before now retargets=0
  ATTACH_VERIFY_REASON=
  ATTACH_VERIFY_BEACON_ADVANCED=0
  ATTACH_VERIFIED_PID=$pid
  ATTACH_VERIFY_HEALTHY_HOLDER=0
  before=$(fm_path_mtime "$BEAT" 2>/dev/null || true)
  # date(1) exposes whole seconds. Add one rounding second so the window cannot
  # collapse to a fraction of the configured budget when it opens just before the
  # next second boundary, which would make the reported "verified Ns" a claim the
  # arm did not actually hold.
  deadline=$(( $(date +%s) + ATTACH_VERIFY + 1 ))
  while :; do
    if ! healthy_watcher; then
      HEALTHY_PID=$pid
      ATTACH_VERIFY_REASON="attach target pid=$pid stopped verifying as this home's live watcher within ${ATTACH_VERIFY}s (pid $(pid_liveness "$pid"), beacon $(fm_path_age "$BEAT")s)"
      return 1
    fi
    if [ "$HEALTHY_PID" != "$pid" ]; then
      # The lock now names a DIFFERENT pid that just passed the same liveness,
      # identity, and beacon gate. That is a handover to a healthy successor, not
      # a failed attach: restarting here would TERM a watcher that is fine.
      # Retarget onto it and verify it from scratch, bounded so a lock that keeps
      # flapping still resolves to an honest failure instead of looping.
      if [ "$retargets" -ge "$ATTACH_RETARGET_MAX" ]; then
        # Budget spent, but $HEALTHY_PID passed healthy_watcher on the sample that
        # ended this window. Record that, so the failed attach cannot route into
        # --restart and TERM it. A flapping lock is still an honest failure; it is
        # just never a reason to kill the watcher currently holding it.
        ATTACH_VERIFY_REASON="the watcher lock kept moving during verification (pid=$pid to pid=$HEALTHY_PID after ${ATTACH_RETARGET_MAX} retargets, ${ATTACH_VERIFY}s each), and pid=$HEALTHY_PID holds it and is healthy"
        ATTACH_VERIFY_HEALTHY_HOLDER=1
        HEALTHY_PID=$pid
        return 1
      fi
      retargets=$((retargets + 1))
      pid=$HEALTHY_PID
      ATTACH_VERIFIED_PID=$pid
      ATTACH_VERIFY_BEACON_ADVANCED=0
      before=$(fm_path_mtime "$BEAT" 2>/dev/null || true)
      deadline=$(( $(date +%s) + ATTACH_VERIFY + 1 ))
      continue
    fi
    now=$(fm_path_mtime "$BEAT" 2>/dev/null || true)
    if [ -n "$now" ] && [ "$now" != "$before" ]; then
      ATTACH_VERIFY_BEACON_ADVANCED=1
    fi
    [ "$(date +%s)" -ge "$deadline" ] && return 0
    sleep 0.1
  done
}

report_attached() {
  local age note=''
  age=$(fm_path_age "$BEAT")
  [ "$ATTACH_VERIFY_BEACON_ADVANCED" -eq 1 ] && note=', beacon advanced'
  echo "watcher: attached pid=$HEALTHY_PID (beacon ${age}s, verified ${ATTACH_VERIFY}s$note)"
}

pid_liveness() {  # <pid>
  if fm_pid_alive "$1"; then printf 'alive'; else printf 'gone'; fi
}

queued_wake_count() {
  local n
  [ -f "$FM_WAKE_QUEUE" ] || { printf '0'; return; }
  n=$(wc -l < "$FM_WAKE_QUEUE" 2>/dev/null | tr -d '[:space:]')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# One bounded line of whatever the cycle wrote to stderr. The watcher's own
# refusals (a blocked check migration, a stale live lock, a `set -u` abort) all
# land there, and losing them is what made an unexplained exit unexplained.
child_stderr_tail() {  # <stderr-file>
  local err=${1:-} text
  { [ -n "$err" ] && [ -s "$err" ]; } || { printf 'none'; return; }
  text=$(tail -n "$STDERR_TAIL_LINES" "$err" 2>/dev/null | tr '\t\r\n' '   ' | cut -c1-500)
  [ -n "$text" ] || text=none
  printf '%s' "$text"
}

# The last lifecycle row that actually classified this watcher pid. It is often
# the missing half of the story - an owning arm recorded exit_code=143
# signal=TERM reason=arm-interrupted while an attached arm saw only that the
# cycle vanished.
last_cycle_record() {  # <watcher-pid>
  local pid=$1 out
  [ -f "$CYCLE_LOG" ] || { printf 'none'; return; }
  out=$(awk -F'\t' -v want="watcher_pid=$pid" '
    $2 == want {
      ec = ""; sg = ""; rs = ""
      for (i = 1; i <= NF; i += 1) {
        if ($i ~ /^exit_code=/) ec = substr($i, 11)
        if ($i ~ /^signal=/) sg = substr($i, 8)
        if ($i ~ /^reason=/) rs = substr($i, 8)
      }
      if (ec != "" && ec != "unknown") last = "exit_code=" ec " signal=" sg " reason=" rs
    }
    END { if (last != "") print last }
  ' "$CYCLE_LOG" 2>/dev/null)
  [ -n "$out" ] || out=none
  printf '%s' "$out"
}

# Why no watcher could be confirmed, in the terms an operator would check by
# hand: who holds the lock, whether that pid is alive, whether it is really this
# home's watcher, and how old the beacon is.
no_fresh_watcher_detail() {
  local lock_pid identity=mismatch
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  [ -n "$lock_pid" ] || lock_pid=none
  if [ "$lock_pid" != none ] && fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$lock_pid" "$FM_HOME"; then
    identity=match
  fi
  printf 'lock pid=%s %s, watcher identity %s, beacon %ss' \
    "$lock_pid" "$(pid_liveness "$lock_pid")" "$identity" "$(fm_path_age "$BEAT")"
}

# Give a successor the same bounded confirmation window used for a fresh child.
# Adapter-owned continuations normally win immediately, but the bound avoids a
# false failure when process-close delivery and lock publication cross briefly.
wait_for_healthy_successor() {
  local deadline
  # date(1) exposes whole seconds. Add one rounding second so a timeout of one
  # second cannot collapse to a few milliseconds when called near a boundary.
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
  while :; do
    healthy_watcher && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

# The attached chain ended with no verified successor. Report the facts an
# operator would otherwise have to reconstruct: whether the target process is
# still there, how old the beacon is, whether wakes are already queued (the
# normal case when the cycle simply exited on an actionable wake it owned), and
# how that watcher's own lifecycle row classified it.
fail_attached_cycle() {  # <attached-pid>
  local pid=$1
  echo "watcher: FAILED - cycle ended without an actionable reason (attached watcher pid=$pid $(pid_liveness "$pid"), beacon $(fm_path_age "$BEAT")s, queued wakes: $(queued_wake_count), last recorded cycle for it: $(last_cycle_record "$pid"))"
  return 1
}

# An owned child returned 0 with no wake reason and no healthy successor.
fail_owned_clean_cycle() {  # <watcher-pid> <stderr-file>
  local pid=$1 err=${2:-}
  echo "watcher: FAILED - cycle ended without an actionable reason (owned watcher pid=$pid exited 0 with no wake reason, $(no_fresh_watcher_detail), queued wakes: $(queued_wake_count), stderr: $(child_stderr_tail "$err"))"
  return 1
}

# Close a cycle whose reason line this arm could not read against the bounded
# terminal-delivery ledger the watcher publishes before releasing its lock. This
# is the FIRST question asked whenever a cycle ends without an observable reason:
# a cycle the ledger proves delivered a wake is a success and must never be
# reported as a failure. It prints only that delivered reason, and returns
# non-zero silently so the caller - which holds the evidence about its own
# attached or owned cycle - reports the typed failure.
close_unobserved_cycle() {
  local i reason clean_identity record_pid record_identity record_reason
  clean_identity=$(printf '%s' "$cycle_watcher_identity" | tr '\t\r\n' '   ')
  i=0
  while ! fm_lock_try_acquire "$WATCH_DELIVERY_LOCK"; do
    [ "$i" -lt 20 ] || return 1
    sleep 0.02
    i=$((i + 1))
  done
  reason=
  if [ -f "$WATCH_DELIVERY_LOG" ]; then
    while IFS=$'\t' read -r record_pid record_identity record_reason; do
      if [ "$record_pid" = "$cycle_watcher_pid" ] && [ "$record_identity" = "$clean_identity" ]; then
        reason=$record_reason
      fi
    done < "$WATCH_DELIVERY_LOG"
  fi
  fm_lock_release "$WATCH_DELIVERY_LOCK"
  [ -n "$reason" ] || return 1
  printf '%s\n' "$reason"
}

# A verified-then-dead attach target is a FAILED attach, not a healthy one.
# Rather than return success against a cycle that is already gone, hand this
# process to a fresh --restart arm so supervision is genuinely restored. Bounded
# by ARM_RESTART_MAX so a watcher that dies on every launch reports the failure
# instead of looping. Returns non-zero when the budget is spent, leaving the
# caller to report honestly.
restart_after_failed_attach() {
  # Never restart over a lock that a healthy watcher currently holds. --restart
  # opens by TERMing that exact pid, so this is the difference between "recover
  # supervision" and "kill the supervision that is already running".
  [ "$ATTACH_VERIFY_HEALTHY_HOLDER" -eq 0 ] || return 1
  [ "$ARM_RESTART_DEPTH" -lt "$ARM_RESTART_MAX" ] || return 1
  echo "watcher: restarting after a failed attach - $ATTACH_VERIFY_REASON"
  trap - HUP TERM INT
  cleanup_child
  export FM_ARM_RESTART_DEPTH=$((ARM_RESTART_DEPTH + 1))
  exec "$SCRIPT_DIR/fm-watch-arm.sh" --restart
}

# The single owner of a failed attach, so the budget-spent semantics are the same
# wherever verification fails. The restart never returns when it fires; with the
# budget spent the disposition decides what this arm says. "abandon" leaves the
# caller to start its own watcher, "fail" is the typed nonzero cycle failure.
handle_failed_attach() {  # <abandon|fail> [exit-code] [signal]
  local disposition=$1 exit_code=${2:-unknown} signal=${3:-unknown} why
  cycle_log_append "$exit_code" "$signal" attach-verification-failed none
  restart_after_failed_attach || true
  # Say which of the two reasons stopped the restart, so an operator can tell a
  # spent budget from a deliberate refusal to signal a healthy holder.
  if [ "$ATTACH_VERIFY_HEALTHY_HOLDER" -eq 1 ]; then
    why="a healthy watcher holds the lock"
  else
    why="no restart budget left"
  fi
  if [ "$disposition" = abandon ]; then
    echo "watcher: attach abandoned - $ATTACH_VERIFY_REASON ($why)"
    return 0
  fi
  echo "watcher: FAILED - cycle ended without an actionable reason ($ATTACH_VERIFY_REASON; $why)"
  return 1
}

# Stay alive across identity-matched healthy holders. If one cycle ends, attach
# to a verified successor. With no successor, report the wake that cycle durably
# delivered, or fail loudly - never a clean empty completion that an adapter
# could mistake for a no-op. Every candidate holder passes attach_verified before
# it is reported, so a successor that is itself in the act of dying is never
# announced as healthy.
attach_and_wait() {
  local attached_pid=$1 candidate replacement_failures=0
  while :; do
    if healthy_watcher; then
      if [ "$HEALTHY_PID" != "$attached_pid" ] || [ "$HEALTHY_IDENTITY" != "$cycle_watcher_identity" ]; then
        candidate=$HEALTHY_PID
        if ! attach_verified "$candidate"; then
          # Do not announce a replacement that did not survive verification;
          # re-evaluate on the ordinary cadence rather than spinning on a
          # flapping lock. That re-evaluation is BOUNDED: each attempt starts a
          # fresh verification with a fresh retarget budget, so a lock held in a
          # flapping-but-sampled-healthy state could otherwise keep this arm
          # re-attempting forever and never reach a terminal result. An arm that
          # never terminates is the same quiet failure as a cycle that exits
          # without saying why, which is what this whole change exists to remove.
          replacement_failures=$((replacement_failures + 1))
          if [ "$replacement_failures" -ge "$ATTACH_REPLACEMENT_MAX" ]; then
            cycle_log_append unknown unknown replacement-verification-exhausted none
            echo "watcher: FAILED - ${ATTACH_REPLACEMENT_MAX} consecutive replacement watchers failed verification while attached to pid=$attached_pid, so this arm stopped re-attempting (last: $ATTACH_VERIFY_REASON; $(no_fresh_watcher_detail), queued wakes: $(queued_wake_count))"
            return 1
          fi
          sleep "$ATTACH_POLL"
          continue
        fi
        replacement_failures=0
        candidate=$ATTACH_VERIFIED_PID
        cycle_log_append unknown unknown lock-replaced "attached:$candidate"
        attached_pid=$candidate
        # HEALTHY_IDENTITY is the identity attach_verified just proved for this
        # pid, so the recorded cycle identity can never lag the attached one and
        # read as yet another successor on the next poll.
        cycle_begin "$attached_pid" attached "$HEALTHY_IDENTITY"
        report_attached
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    if wait_for_healthy_successor; then
      candidate=$HEALTHY_PID
      if attach_verified "$candidate"; then
        candidate=$ATTACH_VERIFIED_PID
        cycle_log_append unknown unknown attached-cycle-ended "attached:$candidate"
        attached_pid=$candidate
        cycle_begin "$attached_pid" attached "$HEALTHY_IDENTITY"
        report_attached
        continue
      fi
      # The successor did not survive verification. The cycle this arm was
      # attached to may still have durably delivered a wake before it ended, so
      # the ledger is resolved before any failure is reported.
      if close_unobserved_cycle; then
        cycle_log_append unknown unknown attached-delivered-wake none
        return 0
      fi
      handle_failed_attach fail
      return 1
    fi
    if close_unobserved_cycle; then
      cycle_log_append unknown unknown attached-delivered-wake none
      return 0
    fi
    cycle_log_append unknown unknown attached-cycle-ended none
    fail_attached_cycle "$attached_pid"
    return 1
  done
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_attached_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  cycle_log_append "$rc" "$signal" arm-interrupted none
  exit "$rc"
}

trap 'handle_attached_signal HUP 129' HUP
trap 'handle_attached_signal TERM 143' TERM
trap 'handle_attached_signal INT 130' INT

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

watch_output_reason_type() {
  local out=$1 line
  line=$(grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null | head -1 || true)
  case "$line" in
    signal:*) printf 'actionable-signal' ;;
    stale:*) printf 'actionable-stale' ;;
    check:*) printf 'actionable-check' ;;
    heartbeat*) printf 'actionable-heartbeat' ;;
    *) printf 'none' ;;
  esac
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

handling_successor_generation() {
  [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ] || return 0
  fm_recovery_marker_snapshot "$STATE/.watcher-down" || return 1
  case "$FM_RECOVERY_MARKER_TOKEN" in
    pending:downtime:*|pending:handling:*|announced:downtime:*|announced:handling:*) printf '%s' "${FM_RECOVERY_MARKER_TOKEN##*:}" ;;
    acked:*|'') ;;
    *) return 1 ;;
  esac
}

# The watcher's stderr is captured to a file rather than inherited so a failure
# line can quote it, then replayed to this arm's stderr so nothing an operator
# used to see is lost.
print_watch_stderr() {
  local err=${1:-}
  { [ -n "$err" ] && [ -s "$err" ]; } || return 0
  cat "$err" >&2
}

# The watcher's own step-naming failure line lands on ITS stdout, which the arm
# captures. When the arm is torn down mid-cycle that capture is deleted, so the
# line has to be replayed first - but only the `watcher: FAILED` lines. The arm's
# stdout is what the Pi and OpenCode adapters and bin/fm-claude-stop-autoarm.sh
# classify, and an unfiltered replay could surface a wake reason line those
# matchers would read as an actionable wake for a cycle that is being torn down
# on purpose. The surviving lines go to stderr, the same stream the stderr replay
# uses, so the two behave consistently.
# shellcheck disable=SC2329 # Invoked indirectly by the arm's signal traps.
print_watch_failure_lines() {  # <stdout-file>
  local out=${1:-}
  { [ -n "$out" ] && [ -s "$out" ]; } || return 0
  grep '^watcher: FAILED' "$out" >&2 || true
}

# The owned child's bookkeeping is declared before the attach path because a
# failed attach may restart through cleanup_child while no child exists yet.
child=
child_out=
child_err=
cleanup_child() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
  if [ -n "$child_err" ]; then
    rm -f "$child_err" 2>/dev/null || true
  fi
}

drop_child_capture() {
  rm -f "$child_out" "$child_err" 2>/dev/null || true
  child=
  child_out=
  child_err=
}

mode=arm
handling_generation=
handling_watcher_pid=
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  --handling-delivered)
    mode=handling-delivered
    handling_generation=${2:-}
    [ "${3:-}" = --watcher-pid ] || { echo "watcher: invalid handling delivery confirmation" >&2; exit 2; }
    handling_watcher_pid=${4:-}
    case "$handling_generation" in ''|*[!A-Za-z0-9._-]*) echo "watcher: invalid recovery generation" >&2; exit 2 ;; esac
    case "$handling_watcher_pid" in ''|*[!0-9]*) echo "watcher: invalid successor watcher pid" >&2; exit 2 ;; esac
    [ "$#" -eq 4 ] || { echo "watcher: unexpected handling delivery arguments" >&2; exit 2; }
    ;;
  *) echo "usage: $(basename "$0") [--restart | --handling-delivered GENERATION --watcher-pid PID]" >&2; exit 2 ;;
esac

if [ "$mode" = handling-delivered ]; then
  fm_pid_alive "$handling_watcher_pid" \
    && fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$handling_watcher_pid" "$FM_HOME" \
    && fm_recovery_marker_begin_handling "$STATE/.watcher-down" "$handling_generation"
  exit $?
fi

# Sub-second beacon stamp, used only to decide whether the beacon ADVANCED
# between the moment this arm judged a holder and the moment it stops it.
# fm_path_mtime is whole seconds, which is too coarse for that comparison: a
# refresh inside the same second would be invisible. Falls back to whole seconds
# where the finer format is unavailable, which weakens the comparison without
# breaking it.
beacon_stamp() {
  local v
  if [ "${_FM_UNAME:-}" = Darwin ]; then
    v=$(stat -f %Fm "$BEAT" 2>/dev/null)
  else
    v=$(stat -c %.9Y "$BEAT" 2>/dev/null)
  fi
  [ -n "$v" ] || v=$(fm_path_mtime "$BEAT" 2>/dev/null)
  printf '%s' "${v:-none}"
}

# The stop precondition, re-evaluated at the instant of stopping rather than
# sampled once and trusted. No check placed BEFORE a stop can close a
# check-to-stop window, so this does not pretend to: it converts "stopped a
# watcher that had come back" into "declined because it came back". The holder
# must still be the pid this arm judged, and its beacon must not have advanced
# since that judgement.
stop_precondition_holds() {  # <judged-pid> <judged-beacon-stamp>
  local pid=$1 beat=$2 now_pid now_beat
  now_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  [ "$now_pid" = "$pid" ] || return 1
  now_beat=$(beacon_stamp)
  [ "$now_beat" = "$beat" ] || return 1
}

# A pid this arm TERMed during --restart that had not exited by the time the wait
# ran out. The watcher runs its TERM trap only when its current foreground sleep
# returns, and that sleep is bounded by FM_POLL (15s by default), which is longer
# than any wait here can be without blowing the adapters' arm-readiness budgets.
# So the arm must never treat such a pid as an attach candidate: it is not merely
# unverified, it is a process this arm has already told to die.
RESTART_TERMED_PID=
# Set when the restart declined to signal a currently-healthy holder, so the arm
# follows that watcher instead of starting a second one behind it.
RESTART_DECLINED_HEALTHY=0
if [ "$mode" = restart ]; then
  # Home-scoped stop: only the watcher pid recorded in THIS home's lock, re-read
  # HERE rather than carried from any earlier observation. A healthy successor can
  # claim the lock between a verification failing and this restart executing, and
  # signalling a pid decided before that point would terminate a watcher this
  # process never looked at.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$lock_pid" "$FM_HOME"; then
      # Belt and braces, and the single owner of the rule: never signal a process
      # that is healthy AT THE MOMENT OF SIGNALLING. Guards keyed on having
      # OBSERVED a holder as healthy leave a hole for every path that reaches the
      # TERM without that observation, and each such hole is another way to kill
      # a running watcher. This is keyed on current state instead, so it closes
      # them as a class rather than one at a time.
      # This does not strand a wedged watcher: fm_watcher_healthy also requires
      # the liveness beacon to be fresh within FM_GUARD_GRACE, and only the
      # watcher process touches that beacon, on every poll. A wedged watcher stops
      # beating and stops satisfying the predicate, so it remains replaceable.
      # Captured BEFORE the judgement, so the comparison below is against the
      # beacon this arm actually judged rather than against itself.
      beat_at_decision=$(beacon_stamp)
      if healthy_watcher && [ "$HEALTHY_PID" = "$lock_pid" ]; then
        # Non-terminal, and deliberately not matching the adapters' readiness
        # pattern `^watcher: (started|attached)`: the terminal line is the
        # attached one this arm goes on to print for that same healthy watcher.
        echo "watcher: restart declined - pid=$lock_pid holds the lock and is healthy right now, so it was not signalled"
        cycle_log_append unknown unknown restart-declined-healthy-holder none
        RESTART_DECLINED_HEALTHY=1
      elif ! stop_precondition_holds "$lock_pid" "$beat_at_decision"; then
        # The holder changed, or started beating again, between the judgement
        # above and this point. Acting now would stop a watcher this arm has no
        # current evidence against, which is the whole defect class.
        echo "watcher: restart declined - the lock holder changed or resumed beating between the health check and the stop, so pid=$lock_pid was not signalled"
        cycle_log_append unknown unknown restart-declined-precondition-moved none
        RESTART_DECLINED_HEALTHY=1
      else
      kill -TERM "$lock_pid" 2>/dev/null || true
      # Wait for it to actually exit before relaunching, so the fresh watcher
      # either takes a released lock or reclaims a now-dead-pid stale lock instead
      # of seeing the dying one as a live holder and no-opping.
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
      # Only a SELF-triggered restart records this. An operator or guard passing
      # --restart deliberately is entitled to the established behaviour of
      # attaching to a healthy holder that outlived the TERM; the danger is
      # specific to the arm restarting itself after a failed attach, where the
      # pid it is about to re-verify is one it has just told to die.
      if [ "$ARM_RESTART_DEPTH" -gt 0 ] && fm_pid_alive "$lock_pid"; then
        RESTART_TERMED_PID=$lock_pid
      fi
      fi
    else
      if ! clear_stale_recorded_watcher_lock; then
        echo "watcher: FAILED - stale watcher recovery state could not be persisted" >&2
        exit 1
      fi
    fi
  fi
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - attach to that cycle and wait until it ends so the harness notify fires
# then, not as an immediate empty wake. (--restart skips this: it just stopped
# this home's watcher and wants a fresh one.)
# A --restart that TERMed a live holder which has not exited yet must not fall
# through into re-verifying and attaching to that same pid. attach_verified
# cannot see the danger: the deferred-trap window is bounded by FM_POLL and is
# strictly longer than the verification window, so the pid passes every sample
# and the arm announces a verified attach to a process it has itself doomed.
# Scoped to THAT pid. A different holder that is healthy now is a legitimate
# successor and must still be attachable; only the process this arm signalled is
# disqualified. The signal-time check above already declines to signal a healthy
# holder, so this fires for the narrower case where the holder was not healthy
# when it was signalled and is beaconing again by the time the arm falls through.
if [ -n "$RESTART_TERMED_PID" ] && healthy_watcher && [ "$HEALTHY_PID" = "$RESTART_TERMED_PID" ]; then
  cycle_log_append 1 none restart-target-still-exiting none
  echo "watcher: FAILED - the watcher this restart stopped (pid=$RESTART_TERMED_PID) had not exited yet, so no attach was claimed ($(no_fresh_watcher_detail), queued wakes: $(queued_wake_count))"
  exit 1
fi

# A restart that declined to signal a healthy holder follows that watcher rather
# than starting a second one behind it: supervision is already running, and the
# whole point of declining was that killing it would be the harm.
if { [ "$mode" = arm ] || [ "$RESTART_DECLINED_HEALTHY" -eq 1 ]; } && healthy_watcher; then
  attach_candidate=$HEALTHY_PID
  # Captured before attach_verified re-reads the lock, so the abandoned-attach
  # cycle is still recorded against the identity this arm actually saw.
  attach_candidate_identity=$HEALTHY_IDENTITY
  if attach_verified "$attach_candidate"; then
    attach_candidate=$ATTACH_VERIFIED_PID
    cycle_mark_predecessor_successor "attached:$attach_candidate"
    cycle_begin "$attach_candidate" attached "$HEALTHY_IDENTITY"
    report_attached
    attach_and_wait "$attach_candidate"
    exit $?
  fi
  # The target stopped verifying: restart rather than report a healthy attach.
  # With the restart budget spent, fall through to the ordinary start path, which
  # either self-heals a now-dead lock or reports the honest failure below.
  cycle_begin "$attach_candidate" attached "$attach_candidate_identity"
  handle_failed_attach abandon
fi

# Start a watcher as a tracked child and confirm it before settling in. The child
# stays our child for its whole life: we wait on it, so killing this arm (the
# harness-tracked task) tears the watcher down too, and the watcher's eventual
# wake exit propagates out so the harness re-notifies firstmate.
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_arm_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  cycle_log_append "$rc" "$signal" arm-interrupted none
  # The watcher's stderr is captured, not inherited, so an interrupted arm has to
  # replay it before cleanup_child deletes the file. A refusal written at t=0 is
  # exactly what an operator needs when the harness tears the arm down at a turn
  # boundary, and it used to appear live. The watcher's own failure line lands on
  # the captured stdout instead, and is replayed under the same rule.
  print_watch_failure_lines "$child_out"
  print_watch_stderr "$child_err"
  cleanup_child
  exit "$rc"
}

trap 'handle_arm_signal HUP 129' HUP
trap 'handle_arm_signal TERM 143' TERM
trap 'handle_arm_signal INT 130' INT

child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon (could not create the arm's output capture under $STATE)"
  exit 1
}
child_err=$(mktemp "$STATE/.watch-arm-stderr.XXXXXX") || {
  rm -f "$child_out" 2>/dev/null || true
  echo "watcher: FAILED - no live watcher with a fresh beacon (could not create the arm's stderr capture under $STATE)"
  exit 1
}
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" >"$child_out" 2>"$child_err" &
else
  "$WATCH" >"$child_out" 2>"$child_err" &
fi
child=$!
cycle_begin "$child" started "$(fm_pid_identity "$child" 2>/dev/null || true)"
child_done=0

owned_child_finished() {
  local rc=$1 signal reason_type status owned_pid successor
  signal=$(cycle_signal_name "$rc")
  owned_pid=$child
  if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
    reason_type=$(watch_output_reason_type "$child_out")
    cycle_log_append "$rc" "$signal" "$reason_type" none
    print_watch_output "$child_out"
    print_watch_stderr "$child_err"
    drop_child_capture
    return 0
  fi

  if [ "$rc" -eq 0 ]; then
    if wait_for_healthy_successor; then
      successor=$HEALTHY_PID
      if attach_verified "$successor"; then
        successor=$ATTACH_VERIFIED_PID
        cycle_log_append "$rc" "$signal" unexpected-clean-exit "attached:$successor"
        print_watch_output "$child_out"
        print_watch_stderr "$child_err"
        drop_child_capture
        cycle_mark_predecessor_successor "attached:$successor"
        report_attached
        cycle_begin "$successor" attached "$HEALTHY_IDENTITY"
        attach_and_wait "$successor"
        return $?
      fi
      print_watch_output "$child_out"
      print_watch_stderr "$child_err"
      drop_child_capture
      # The successor did not verify, but this child may still have durably
      # delivered a wake before it exited. The ledger answers that before any
      # failure is reported, and a delivered cycle needs no restart.
      if close_unobserved_cycle; then
        cycle_log_append "$rc" "$signal" clean-exit-delivered-wake none
        return 0
      fi
      handle_failed_attach fail "$rc" "$signal"
      return 1
    fi
    print_watch_output "$child_out"
    print_watch_stderr "$child_err"
    if close_unobserved_cycle; then
      cycle_log_append "$rc" "$signal" clean-exit-delivered-wake none
      drop_child_capture
      return 0
    fi
    cycle_log_append "$rc" "$signal" unexpected-clean-exit none
    fail_owned_clean_cycle "$owned_pid" "$child_err" || true
    drop_child_capture
    return 1
  fi

  reason_type="nonzero-exit"
  [ "$signal" = none ] || reason_type="signal-exit"
  cycle_log_append "$rc" "$signal" "$reason_type" none
  print_watch_output "$child_out"
  print_watch_stderr "$child_err"
  # The watcher names its own failing step on stdout. Only when it could not -
  # a kill, an abort before the trap, a lost process - does this arm synthesize
  # the line, and then it carries every fact it still has.
  if ! grep -q '^watcher: FAILED' "$child_out" 2>/dev/null; then
    echo "watcher: FAILED - watcher cycle exited $rc without an actionable reason (watcher pid=$owned_pid, signal=$signal, $(no_fresh_watcher_detail), queued wakes: $(queued_wake_count), stderr: $(child_stderr_tail "$child_err"))"
  fi
  drop_child_capture
  status=$rc
  [ "$status" -gt 0 ] || status=1
  return "$status"
}

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
# date(1) exposes whole seconds. Keep the configured confirmation budget from
# collapsing when startup begins just before the next second boundary.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      cycle_refresh_lock_before
      if ! handling_generation=$(handling_successor_generation); then
        cleanup_child
        wait "$child" 2>/dev/null || true
        cycle_log_append 1 none handling-handoff-failed none
        echo "watcher: FAILED - established successor could not inspect handling state"
        exit 1
      fi
      cycle_mark_predecessor_successor "started:$child"
      if [ -n "$handling_generation" ]; then
        echo "watcher: started pid=$child (beacon fresh) recovery-generation=$handling_generation"
      else
        echo "watcher: started pid=$child (beacon fresh)"
      fi
      wait "$child"
      rc=$?
      owned_child_finished "$rc"
      exit $?
    fi
    # Another watcher won the singleton; our child stood down.
    wait "$child"
    rc=$?
    owned_child_finished "$rc"
    exit $?
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    wait "$child"
    rc=$?
    child_done=1
    owned_child_finished "$rc"
    exit $?
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
print_watch_output "$child_out"
print_watch_stderr "$child_err"
timeout_detail="$(no_fresh_watcher_detail), forked watcher pid=$child $(pid_liveness "$child"), stderr: $(child_stderr_tail "$child_err")"
cleanup_child
wait "$child" 2>/dev/null
rc=$?
cycle_log_append "$rc" "$(cycle_signal_name "$rc")" confirmation-timeout none
echo "watcher: FAILED - no live watcher with a fresh beacon after ${CONFIRM_TIMEOUT}s ($timeout_detail)"
exit 1
