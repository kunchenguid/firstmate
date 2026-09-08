#!/usr/bin/env bash
# fm-idle-compact.sh - shared eligibility + action owner for opt-in idle-worker
# pre-cache-expiry compaction.
#
# Sourced identically by bin/fm-watch.sh's main loop and
# bin/fm-supervise-daemon.sh's housekeeping tick (fm_idle_compact_tick), so the
# eligibility test and the action sequence have exactly one owner and the two
# supervision paths cannot drift, the same "one shared classifier, two
# callers" shape bin/fm-classify-lib.sh already uses.
#
# Ships inert: an absent local, gitignored config/idle-compact means
# fm_idle_compact_tick returns immediately after one [ -f ] check, with no
# state mutation anywhere. Present, its first non-empty, non-comment line is
# the idle threshold in whole minutes (an empty-but-present file enables the
# feature at the documented 15-minute default); an invalid value is treated
# exactly like an absent file, because a config typo must never fail a
# watcher/daemon loop. See docs/configuration.md "Idle-worker pre-compaction"
# for the full contract.
#
# Eligibility, re-checked every FM_IDLE_COMPACT_INTERVAL seconds for every
# task under state/*.meta, is strictly the intersection of:
#   - kind != secondmate (a secondmate's idle pane is its normal healthy
#     state, and it holds its own fleet) and harness = claude (the only
#     harness with a verified /compact slash command today - every other
#     verified harness is reviewed and not applicable, see
#     docs/configuration.md "Harness compatibility");
#   - bin/fm-crew-state.sh's reconciled current state is parked, done,
#     blocked, or paused - never working (an active no-mistakes run step or a
#     busy pane, even behind a quiet-looking pane) or unknown;
#   - last activity - the newest of the task's meta, status, turn-ended, and
#     observed-pane-activity stamps, through bin/fm-wake-lib.sh's shared
#     fm_last_activity_age - is at least the configured threshold old;
#   - a live safety gate right before typing anything: an exact idle verdict
#     from bin/fm-busy-lib.sh's fm_busy_classify and an exact `empty` verdict
#     from bin/fm-backend.sh's fm_backend_composer_state - the identical
#     primitives the away-mode daemon's own injection boundary uses.
#
# A durable per-task marker at state/.idle-compact-<task> (named after the
# existing .hb-surfaced-<task>/.seen-* convention) drives a 4-phase state
# machine so one idle episode produces at most one compaction:
#   1. no marker: send a guarded message asking the crewmate to write its
#      working state to data/<id>/precompact-notes.md, then record
#      phase=save-sent with the current state/<id>.turn-ended signature.
#      Declared-state fast path: when the task's own status log's LATEST
#      line STARTS WITH the phrase `paused: awaiting compaction before
#      validation` (a ship brief tells a no-mistakes worker to append that
#      line and end its turn right after its implementation commit, before
#      starting no-mistakes, and to note its measured lane size with it, so
#      trailing detail after the phrase is the norm rather than the
#      exception), fm_idle_compact_eligible ignores the idle-minutes
#      threshold entirely - the worker has already declared itself done and
#      waiting, so there is nothing to wait out - while every other exclusion
#      (kind, harness, reconciled crew state) and the live safety gate still
#      apply. This path also skips the notes-save turn (there is nothing left
#      to save; the worker already stopped) and sends `/compact` directly,
#      marking the episode `declared=1`.
#   2. phase=save-sent: wait for a NEW turn-ended signature - proof the save
#      turn actually completed, the same signal bin/fm-watch.sh's signal scan
#      already trusts - then re-run the full eligibility check (the crew may
#      have been steered back to work during the wait) and the live safety
#      gate before sending /compact with focus text; a bounded
#      FM_IDLE_COMPACT_SAVE_TIMEOUT_SECS abandons a turn that never
#      completes. Once sent, record phase=settling with the send epoch.
#   3. phase=settling: wait FM_IDLE_COMPACT_SETTLE_SECS (default one sweep
#      interval) for the compaction summary to finish rendering, then record
#      phase=done with the status-line and pane-tail signatures - captured
#      after the render so the compaction's own output is baked into the
#      baseline and never reads as new worker activity.
#   4. phase=done: a changed status or pane-tail signature (a new status
#      append or new pane activity) ends the episode, replacing the marker
#      with a phase=reset activity stamp so the next episode is evaluated
#      fresh - and only after a full new idle window measured from that stamp.
#      An UNCHANGED phase=done marker runs the ring backstop below.
#
# The ring, and why it is not a live send. A worker whose latest status line
# declares the compaction pause is waiting on firstmate, not on an external
# event, so it is rung once at the settling->done transition with
# "compacted - start the validation run now". Two properties keep that ring
# from being lost, both learned from 2026-09-06, when pt-checkin-fidelity-lane3
# and pt-checkin-fidelity-lane8 were compacted, never rung, and sat idle 35 to
# 60 minutes until firstmate rang them by hand:
#   - it is DURABLE. It goes out on fm-send's inbox plane as a record the
#     watcher's re-ring ladder covers, so it is never gated behind a live pane
#     verdict, and the episode advances to phase=done only once that record
#     exists. Gating a durable record behind fm_idle_compact_safe_to_send was
#     the deferred-and-never-retried seam.
#   - it does not depend on WHICH path the episode took. The declared=1 marker
#     field rings, and so does a status log that still declares the pause at
#     the transition - the ordinary save-then-compact path leaves exactly the
#     same waiting worker, and that is the path both 2026-09-06 lanes took,
#     because their status lines carried the trailing detail the brief asks for
#     and the old whole-line equality test missed them.
# fm_idle_compact_ring_backstop is the last line of defence: an unchanged
# phase=done marker older than FM_IDLE_COMPACT_RING_BACKSTOP_SECS whose status
# still declares the pause, with no ring record in the inbox, gets one re-send
# and one log line. It is the only thing in this file that logs, because it
# firing at all means the primary path missed.
#
# The two turns an episode induces (the notes save and the /compact) would
# each otherwise surface as an actionable turn-end wake. fm_idle_compact_absorbs_signal
# is the narrow, episode-scoped exemption bin/fm-watch.sh's signal triage asks
# this owner about; see its own comment for the conditions it requires.
#
# Every message is delivered through bin/fm-send.sh exactly as any other
# steer, with the same plane selection fm-send.sh itself applies to any
# unmarked task-selector text: only the leading-`/` `/compact` command rides
# the typed plane, while the plain-text notes save and the ring both ride
# fm-send's durable inbox plane - so this file never calls a backend
# primitive or raw tmux command directly, and a deferred or failed attempt at
# any phase is silent routine, retried on the next sweep and never a
# captain-facing escalation.
#
# CLI:
#   fm-idle-compact.sh tick     - mainly for standalone testing/inspection;
#                                 production callers (the watcher, the
#                                 away-mode daemon) source this file and call
#                                 fm_idle_compact_tick directly instead.
#   fm-idle-compact.sh enabled  - a genuine production entry point: the
#                                 no-mistakes ship brief (bin/fm-dod-lib.sh)
#                                 tells a worker to run this directly, right
#                                 before deciding whether to pause for a
#                                 compaction ring, so the decision reads
#                                 config/idle-compact live instead of trusting
#                                 a generation-time snapshot baked into the
#                                 brief. Exits 0 (armed) or 1 (not armed).
set -u

# Self-referencing fallbacks (the bin/fm-wake-lib.sh idiom): a caller that
# already sourced its own copy of these globals before sourcing this file
# keeps its value untouched, since every caller derives the identical formula
# from the same FM_HOME/override anyway.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
CONFIG="${FM_CONFIG_OVERRIDE:-${CONFIG:-$FM_HOME/config}}"
DATA="${FM_DATA_OVERRIDE:-${DATA:-$FM_HOME/data}}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

FM_IDLE_COMPACT_DEFAULT_MINUTES=15
FM_IDLE_COMPACT_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

# The declared-state phrase a no-mistakes ship brief tells the worker to append
# right after its implementation commit (bin/fm-dod-lib.sh is the phrase's one
# owner). Matched as a PREFIX of the status line, never as the whole line: the
# same brief asks the worker to note its measured lane size, so the line that
# actually lands in production routinely carries trailing detail
# ("paused: awaiting compaction before validation (commit 3985d693a, 1292
# changed lines, over-cap accepted)"). Requiring the whole line to equal the
# phrase is what silently dropped two workers onto the ordinary episode path
# overnight on 2026-09-06; see the ring contract below.
FM_IDLE_COMPACT_DECLARED_PHRASE='paused: awaiting compaction before validation'

# --- config parsing ---------------------------------------------------------

# First non-empty, non-comment line of <file>, whitespace-trimmed - the same
# idiom bin/fm-harness.sh's secondmate_line uses for config/secondmate-harness.
fm_idle_compact_first_content_line() {  # <file>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    printf '%s' "$line"
    return 0
  done < "$1"
  return 0
}

# Prints the effective idle threshold in whole minutes and returns 0 when the
# feature is enabled; returns 1 (disabled, prints nothing) when config/idle-
# compact is absent, empty-but-invalid is never a case (empty means the
# documented default), or its first content line is not a positive integer.
fm_idle_compact_threshold_minutes() {  # <config-dir>
  local config=$1 file line
  file="$config/idle-compact"
  [ -f "$file" ] || return 1
  line=$(fm_idle_compact_first_content_line "$file")
  if [ -z "$line" ]; then
    printf '%s' "$FM_IDLE_COMPACT_DEFAULT_MINUTES"
    return 0
  fi
  case "$line" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$line" -gt 0 ] || return 1
  printf '%s' "$line"
}

# --- task context ------------------------------------------------------------

# Resolves <state>/<task>.meta into FM_IDLE_COMPACT_{BACKEND,TARGET,HARNESS,
# KIND,LABEL}. Returns 1 when the meta is missing or records no backend
# target, leaving those globals empty.
FM_IDLE_COMPACT_BACKEND=
FM_IDLE_COMPACT_TARGET=
FM_IDLE_COMPACT_HARNESS=
FM_IDLE_COMPACT_KIND=
FM_IDLE_COMPACT_LABEL=
fm_idle_compact_task_context() {  # <state> <task>
  local state=$1 task=$2 meta
  meta="$state/$task.meta"
  FM_IDLE_COMPACT_BACKEND=
  FM_IDLE_COMPACT_TARGET=
  FM_IDLE_COMPACT_HARNESS=
  FM_IDLE_COMPACT_KIND=
  FM_IDLE_COMPACT_LABEL=
  [ -f "$meta" ] || return 1
  FM_IDLE_COMPACT_BACKEND=$(fm_backend_of_meta "$meta")
  FM_IDLE_COMPACT_TARGET=$(fm_backend_target_of_meta "$meta")
  [ -n "$FM_IDLE_COMPACT_TARGET" ] || return 1
  FM_IDLE_COMPACT_HARNESS=$(fm_meta_get "$meta" harness)
  FM_IDLE_COMPACT_KIND=$(fm_meta_get "$meta" kind)
  [ -n "$FM_IDLE_COMPACT_KIND" ] || FM_IDLE_COMPACT_KIND=ship
  FM_IDLE_COMPACT_LABEL="fm-$task"
  return 0
}

# --- signatures (drive the marker's reset-on-new-activity rule) ------------

# Portable hash of stdin. Mirrors bin/fm-watch.sh's hash_pane idiom; kept
# local because it is a tiny leaf-level portability shim, the same class of
# duplication bin/fm-lock-lib.sh and bin/fm-wake-lib.sh already each carry
# their own portable stat wrapper for.
fm_idle_compact_hash() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

fm_idle_compact_pane_sig() {  # <backend> <target> <label>
  fm_backend_capture "$1" "$2" 40 "$3" 2>/dev/null | fm_idle_compact_hash
}

# The size:mtime signature bin/fm-wake-lib.sh owns for exactly this question -
# "did this file gain new bytes since I last looked" - and that the watcher's
# own .seen-* dedup already uses for .status and .turn-ended. A line's TEXT is
# not a usable append signature: a second, textually identical status append
# (a repeated "blocked: waiting on the gate") is a genuinely new append that
# must reset the episode, and comparing text would silently miss it.
# Empty when the file does not exist, which compares equal to an equally
# absent recorded baseline.
fm_idle_compact_status_sig() {  # <state> <task>
  fm_wake_signal_sig "$1/$2.status" 2>/dev/null || true
}

# turn-ended is touch(1)ed by the harness's turn-end hook on every completed
# turn (AGENTS.md's state/<id>.turn-ended). Same signature owner and same
# empty-means-absent contract as the status signature above, so a recorded
# baseline can be compared against the watcher's .seen-* marker byte for byte.
fm_idle_compact_turnended_sig() {  # <state> <task>
  fm_wake_signal_sig "$1/$2.turn-ended" 2>/dev/null || true
}

# --- marker (state/.idle-compact-<task>) ------------------------------------

fm_idle_compact_marker_path() {  # <state> <task>
  local key
  key=$(printf '%s' "$2" | tr ':/.' '___')
  printf '%s/.idle-compact-%s' "$1" "$key"
}

# The one mutual-exclusion boundary around every marker write in this file:
# the sweep holds it for a whole sweep, and the watcher's signal path holds it
# for its read-modify-write. One owner for the path so the two callers cannot
# drift onto different locks.
fm_idle_compact_lock_path() {  # <state>
  printf '%s/.idle-compact.lock' "$1"
}

fm_idle_compact_marker_field() {  # <marker-file> <key>
  [ -f "$1" ] || return 1
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Atomic write (temp file + rename), mirroring bin/fm-classify-lib.sh's
# cursor-write pattern, so a crash mid-write never leaves a half-written
# marker. Each argument is one complete "key=value" line.
fm_idle_compact_marker_write() {  # <marker-file> <key=value>...
  local f=$1 tmp kv
  shift
  tmp="$f.tmp.$$"
  {
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$tmp" && mv -f "$tmp" "$f"
}

# Set one field on an EXISTING marker, leaving every other field byte-identical
# and the phase untouched. Same atomic temp-then-rename discipline as the full
# write above.
fm_idle_compact_marker_set() {  # <marker-file> <key> <value>
  local f=$1 key=$2 value=$3 tmp
  [ -f "$f" ] || return 1
  tmp="$f.tmp.$$"
  {
    grep -v "^$key=" "$f" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value"
  } > "$tmp" && mv -f "$tmp" "$f"
}

# --- eligibility and the live safety gate -----------------------------------

# Seconds since this task's last activity of ANY kind - the idle-duration
# basis the threshold is measured against. bin/fm-wake-lib.sh's
# fm_last_activity_age is the one owner of the newest-of-mtimes rule, shared
# with bin/fm-inactive-reconcile.sh's own inactivity scan, so the two cannot
# answer "how long has this crew been quiet" differently.
#
# state/<id>.status alone is NOT that basis: a status line is a wake event
# written on wake-worthy transitions, not on every turn (AGENTS.md's sparse
# status-reporting contract), so a crewmate steered back to work, doing it,
# and ending its turn can leave a 3-hour-old status file untouched. Measuring
# from that file alone would arm a fresh episode seconds after real activity -
# compacting a crewmate whose cache is at its warmest, the exact opposite of
# this feature's purpose.
#
# Two adjustments to the plain newest-of rule:
#   - an in-flight episode's turn-ends are this feature's OWN induced turns
#     (the notes save and the /compact), so turn-ended is excluded while
#     phase is save-sent or settling - otherwise the eligibility re-check
#     before /compact would read the save turn it is explicitly waiting for as
#     fresh worker activity and never compact at all. Foreign activity during
#     that window is still caught by the reconciled crew state and the live
#     safety gate, which both run on every send;
#   - a phase=reset stamp is included. It is written the moment a finished
#     episode's reset condition is observed and carries the only durable
#     record of PANE activity, which leaves no mtime of its own.
fm_idle_compact_activity_age() {  # <state> <task>
  local state=$1 task=$2 marker phase
  marker=$(fm_idle_compact_marker_path "$state" "$task")
  phase=$(fm_idle_compact_marker_field "$marker" phase) || phase=
  set -- "$state/$task.meta" "$state/$task.status"
  case "$phase" in
    save-sent|settling) ;;
    reset) set -- "$@" "$state/$task.turn-ended" "$marker" ;;
    *) set -- "$@" "$state/$task.turn-ended" ;;
  esac
  fm_last_activity_age "$(date +%s)" "$@"
}

# True only when the task's own status log's latest line is the declared-state
# phrase a no-mistakes ship brief tells a worker to append right after its
# implementation commit, before starting no-mistakes, matched as a prefix
# ending on a word boundary. See this file's header comment ("Declared-state
# fast path") for the full contract; bin/fm-dod-lib.sh's no-mistakes block is
# the phrase's one owner.
fm_idle_compact_declared_paused() {  # <state> <task>
  local statusf="$1/$2.status" line
  [ -f "$statusf" ] || return 1
  line=$(tail -n 1 "$statusf" 2>/dev/null || true)
  case "$line" in
    "$FM_IDLE_COMPACT_DECLARED_PHRASE") return 0 ;;
    "$FM_IDLE_COMPACT_DECLARED_PHRASE"[!A-Za-z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_idle_compact_eligible() {  # <state> <task> <threshold-minutes>
  local state=$1 task=$2 threshold_min=$3 statusf age crewline crewstate

  fm_idle_compact_task_context "$state" "$task" || return 1
  [ "$FM_IDLE_COMPACT_KIND" != secondmate ] || return 1
  [ "$FM_IDLE_COMPACT_HARNESS" = claude ] || return 1

  statusf="$state/$task.status"
  [ -f "$statusf" ] || return 1
  if ! fm_idle_compact_declared_paused "$state" "$task"; then
    age=$(fm_idle_compact_activity_age "$state" "$task")
    [ "$age" -ge $(( threshold_min * 60 )) ] || return 1
  fi

  # Explicit override passthrough, not ambient-environment reliance: FM_HOME
  # may be a computed default (never exported) rather than an inherited env
  # var, especially in a secondmate home, so the same explicit-override idiom
  # bin/fm-fleet-snapshot.sh's crew_state_json uses is required here too -
  # otherwise a secondmate sweep would silently reconcile against the wrong
  # home's state.
  crewline=$(FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$state" \
    "$FM_IDLE_COMPACT_CREW_STATE_BIN" "$task" 2>/dev/null) || return 1
  case "$crewline" in state:*) ;; *) return 1 ;; esac
  crewstate=${crewline#state: }; crewstate=${crewstate%% *}
  case "$crewstate" in
    parked|done|blocked|paused) return 0 ;;
    *) return 1 ;;
  esac
}

# Requires FM_IDLE_COMPACT_{BACKEND,TARGET,HARNESS,LABEL} already resolved by
# a caller's fm_idle_compact_task_context call. 0 only on an exact idle busy
# verdict (never busy, never an unproven unknown/dead) with an exactly-empty
# composer - the same conservative "only an exact verdict permits action"
# discipline bin/fm-crew-state.sh and bin/fm-supervise-daemon.sh's
# inject_msg already apply.
fm_idle_compact_safe_to_send() {  # <state> <task>
  local state=$1 task=$2 verdict
  verdict=$(fm_busy_classify "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" \
    "$FM_IDLE_COMPACT_HARNESS" "$task" "$state")
  [ "${verdict%% *}" = idle ] || return 1
  [ "$(fm_backend_composer_state "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" \
    "$FM_IDLE_COMPACT_LABEL" 2>/dev/null)" = empty ]
}

# --- messages and delivery ---------------------------------------------------

fm_idle_compact_save_message() {  # <task>
  printf 'Idle-compact: your context cache is about to be compacted while you wait. Before that happens, write your open decision keys, current gate/step, next actions, and key file paths to %s/%s/precompact-notes.md (create it if absent), then stop for this turn.' \
    "$DATA" "$1"
}

fm_idle_compact_compact_message() {  # <task>
  printf '/compact Preserve the pointer to %s/%s/brief.md, the AGENTS.md status-append protocol, and the precompact notes at %s/%s/precompact-notes.md - re-read that notes file after compaction to resume.' \
    "$DATA" "$1" "$DATA" "$1"
}

# The declared-state fast path's /compact message: the worker already ended
# its turn with nothing left to save, so this names the branch, the brief
# path, and the delivery contract (mode) instead of a notes file.
fm_idle_compact_declared_compact_message() {  # <state> <task>
  local state=$1 task=$2 mode
  mode=$(fm_meta_get "$state/$task.meta" mode 2>/dev/null) || mode=
  [ -n "$mode" ] || mode=no-mistakes
  printf '/compact Preserve your branch fm/%s, the pointer to %s/%s/brief.md, and the delivery contract (mode=%s) - you are about to be rung to start the no-mistakes validation run.' \
    "$task" "$DATA" "$task" "$mode"
}

fm_idle_compact_ring_message() {
  printf 'compacted - start the validation run now'
}

# Delivers through bin/fm-send.sh's verified type-once-retried-Enter path,
# never a raw backend/tmux call. Silent on either outcome: a deferred or
# failed send is retried on a later sweep, never a captain-facing escalation.
# Explicit override passthrough (the same idiom as the crew-state call above)
# so a caller's <state> - which may differ from $FM_HOME/state under test
# isolation - is exactly what fm-send.sh resolves against.
fm_idle_compact_send() {  # <state> <task> <message>
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$1" \
    "$SCRIPT_DIR/fm-send.sh" "$2" "$3" >/dev/null 2>&1
}

# The ring is a DURABLE record, not typed text. fm-send routes plain text to
# the task's steering inbox (bin/fm-task-inbox-lib.sh), where the watcher's
# re-ring ladder covers a swallowed doorbell and escalates a worker that never
# acknowledges. So unlike the `/compact` command - which must reach the
# harness's own parser through the live typed plane - the ring deliberately
# does NOT wait on fm_idle_compact_safe_to_send: a busy pane is exactly the
# case the durable record was designed for, and gating the record behind a
# live pane verdict reintroduced the silent-defer seam this feature exists to
# close. Success here means the record exists.
fm_idle_compact_ring_worker() {  # <state> <task>
  fm_idle_compact_send "$1" "$2" "$(fm_idle_compact_ring_message)"
}

# Portable RFC3339/Zulu -> epoch, the same BSD/GNU date fallback idiom
# bin/fm-public-followup-lib.sh's fm_pf_rfc3339_to_epoch already uses. Empty
# input or an unparseable timestamp fails rather than guessing.
_fm_idle_compact_rfc3339_to_epoch() {  # <rfc3339>
  local ts=$1
  [ -n "$ts" ] || return 1
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null \
    || date -u -d "$ts" +%s 2>/dev/null \
    || return 1
}

# The record's own header `at=` field (bin/fm-task-inbox-lib.sh's record
# format), read up to the `--` body separator so a body that happens to start
# with literal text "at=" can never be mistaken for the header.
_fm_idle_compact_inbox_record_at() {  # <record-path>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    [ "$line" != -- ] || return 1
    case "$line" in
      at=*) printf '%s' "${line#at=}"; return 0 ;;
    esac
  done < "$1"
  return 1
}

# True when this task's inbox already holds the ring for the CURRENT episode,
# unhandled or acknowledged. Sequence numbers - and so handled/ records - are
# never reused for a task's whole lifetime (bin/fm-task-inbox-lib.sh), so a
# task that runs several idle-compact episodes across its life keeps every
# earlier episode's ring record in handled/ too. Matching on the constant ring
# body text alone would therefore find a PRIOR episode's already-acknowledged
# ring and report "already recorded" for a later episode whose own ring
# enqueue genuinely failed - silently reintroducing the never-rung failure
# this backstop exists to close. <episode-epoch>, when given, scopes the match
# to records whose `at=` timestamp is no older than the current episode's own
# settle_epoch (stamped on every phase=done write this backstop's caller is
# examining - carried forward from the settling->done transition, or set
# fresh by the save-sent timeout's direct abandon to done), so an earlier
# episode's ring never satisfies this check. Absent or unparseable data - a
# legacy marker predating settle_epoch,
# or a record missing/malformed `at=` - falls back to the unscoped match
# rather than risk the reverse failure (never ringing at all).
fm_idle_compact_ring_recorded() {  # <state> <task> [episode-epoch]
  local state=$1 task=$2 episode_epoch=${3:-} dir f ring at at_epoch
  ring=$(fm_idle_compact_ring_message)
  for dir in "$(fm_task_inbox_dir "$state" "$task")" \
             "$(fm_task_inbox_handled_dir "$state" "$task")"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.msg; do
      [ -e "$f" ] || continue
      [ "$(fm_task_inbox_body "$f" 2>/dev/null)" = "$ring" ] || continue
      if [ -n "$episode_epoch" ]; then
        at=$(_fm_idle_compact_inbox_record_at "$f") || continue
        at_epoch=$(_fm_idle_compact_rfc3339_to_epoch "$at") || continue
        [ "$at_epoch" -ge "$episode_epoch" ] || continue
      fi
      return 0
    done
  done
  return 1
}

# Size-capped, this feature's own; the watcher's state/.watch-triage.log stays
# exclusively the watcher's absorbed-wake debug log (bin/fm-watch-arm.sh).
# Only the backstop writes here: an ordinary episode stays silent routine.
fm_idle_compact_log() {  # <state> <line>
  local f="$1/.idle-compact.log" max sz
  max=${FM_IDLE_COMPACT_LOG_MAX_BYTES:-65536}
  case "$max" in ''|*[!0-9]*|0) max=65536 ;; esac
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$2" >> "$f" 2>/dev/null || return 0
  sz=$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$max" ]; then
    tail -n 200 "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null
    rm -f "$f.tmp" 2>/dev/null || true
  fi
  return 0
}

# Last line of defence for the one worker state that cannot recover itself: an
# episode that reached phase=done while the worker's own latest status line
# still declares the compaction pause. That worker is waiting on firstmate, not
# on an external event, so a ring that was never sent (a pre-fix episode that
# took the ordinary path) or never recorded (a failed enqueue at the
# settling->done transition) leaves it idle indefinitely - 35 to 60 minutes,
# twice, on 2026-09-06.
#
# Fires at most once per episode and only on all four conditions: the status
# line still declares the pause, this marker has not already backstopped, the
# phase=done marker is at least FM_IDLE_COMPACT_RING_BACKSTOP_SECS old (so a
# freshly-rung worker that simply has not taken its turn yet is left alone),
# and the inbox holds no ring record at all. Unlike an ordinary episode step it
# logs, because a backstop firing means the primary path missed.
fm_idle_compact_ring_backstop() {  # <state> <task> <marker>
  local state=$1 task=$2 marker=$3 grace age episode_epoch
  fm_idle_compact_declared_paused "$state" "$task" || return 0
  [ -z "$(fm_idle_compact_marker_field "$marker" ring_backstop)" ] || return 0
  grace=${FM_IDLE_COMPACT_RING_BACKSTOP_SECS:-600}
  case "$grace" in ''|*[!0-9]*) grace=600 ;; esac
  age=$(fm_path_age "$marker")
  [ "$age" -ge "$grace" ] || return 0
  episode_epoch=$(fm_idle_compact_marker_field "$marker" settle_epoch)
  case "$episode_epoch" in ''|*[!0-9]*) episode_epoch= ;; esac
  ! fm_idle_compact_ring_recorded "$state" "$task" "$episode_epoch" || return 0
  fm_idle_compact_ring_worker "$state" "$task" || return 0
  fm_idle_compact_marker_set "$marker" ring_backstop "$(date +%s)" || true
  fm_idle_compact_log "$state" \
    "$task: ring backstop re-sent - phase=done for ${age}s, status still declares the compaction pause, no ring record in the inbox"
  return 0
}

# --- induced-turn absorption -------------------------------------------------

# Each episode makes the crewmate take two turns it never asked for: the
# precompact-notes save and the /compact itself. Every completed turn touches
# state/<id>.turn-ended, which bin/fm-watch.sh's signal scan surfaces as an
# actionable no-verb wake whenever the crew is not provably working - and a
# parked crew never is. Left alone, opting into this quota-saving feature would
# spend two extra firstmate wake-handling turns per crewmate per episode on
# housekeeping the captain never requested, which contradicts the "a deferred
# or failed compact is silent routine, never an escalation" contract.
#
# So the wake triage asks this owner - the same single owner both supervision
# paths already share, so bin/fm-watch.sh and bin/fm-supervise-daemon.sh cannot
# drift - whether one specific pending turn-ended signal is exactly the turn
# THIS feature induced. The exemption is deliberately as narrow as it can be:
#   - only state/<id>.turn-ended, never a status file (a status append is the
#     crew's own captain-facing report and always wakes);
#   - only while that task's own marker is in an in-flight phase (save-sent or
#     settling), so it expires with the episode - a phase=done, phase=reset, or
#     absent marker absorbs nothing;
#   - only within FM_IDLE_COMPACT_SAVE_TIMEOUT_SECS of the send that induced
#     it, the same bound the state machine abandons a never-completing save
#     turn on;
#   - at most ONE turn per send. The absorbed signature is recorded, so
#     re-seeing that exact signature (the watcher scans twice across its signal
#     grace window) is idempotent, while any LATER turn-end - real crew work
#     landing in the same window - carries a different signature and wakes
#     normally;
#   - only when the watcher's .seen-* marker still matches the signature
#     recorded when the message was sent, i.e. every earlier turn-end was
#     already surfaced or deliberately absorbed. This is the provenance gate
#     bin/fm-wake-lib.sh's fm_wake_status_append_self_announced applies to the
#     same marker format, and it fails toward waking: an unannounced foreign
#     turn-end pending on the file means this signal is not provably ours;
#   - only while no sweep holds this home's idle-compact lock, under which the
#     whole read-modify-write below then runs.
# Every other condition - a missing marker, an unreadable signature, a
# malformed epoch, clock skew - returns 1, and the signal wakes the captain
# exactly as it does today.
fm_idle_compact_absorbs_signal() {  # <state> <signal-file> [signature]
  local state=$1 file=$2 sig=${3:-} task marker lock rc

  case "$file" in *.turn-ended) ;; *) return 1 ;; esac
  task=$(basename "$file"); task=${task%.turn-ended}
  [ -n "$task" ] || return 1

  marker=$(fm_idle_compact_marker_path "$state" "$task")
  [ -f "$marker" ] || return 1

  [ -n "$sig" ] || sig=$(fm_wake_signal_sig "$file" 2>/dev/null || true)
  [ -n "$sig" ] || return 1

  # This runs from bin/fm-watch.sh's triage loop, NOT from fm_idle_compact_tick,
  # so it holds no lock of its own: without this the away-mode daemon's
  # concurrent housekeeping sweep and this rewrite can interleave on the same
  # marker, and a stale phase=save-sent restored over a landed phase=settling
  # would send a SECOND /compact for one episode. A lock already held means a
  # sweep is mid-flight on this home, which is exactly when this signal is not
  # provably ours - so decline and let it wake, the direction every other arm
  # of this predicate already fails toward.
  lock=$(fm_idle_compact_lock_path "$state")
  fm_lock_try_acquire "$lock" || return 1
  fm_idle_compact_absorbs_signal_locked "$state" "$file" "$sig" "$marker"
  rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

# The decision itself, with the episode marker held still by the caller's lock:
# every field read below and the write that follows them are one atomic
# read-modify-write, so a concurrent sweep can neither be read half-applied nor
# have its own marker write clobbered by a stale rewrite from here.
fm_idle_compact_absorbs_signal_locked() {  # <state> <signal-file> <signature> <marker>
  local state=$1 file=$2 sig=$3 marker=$4 phase epoch baseline absorbed now

  phase=$(fm_idle_compact_marker_field "$marker" phase)
  case "$phase" in
    save-sent) epoch=$(fm_idle_compact_marker_field "$marker" sent_epoch) ;;
    settling)  epoch=$(fm_idle_compact_marker_field "$marker" settle_epoch) ;;
    *) return 1 ;;
  esac
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ "$now" -ge "$epoch" ] || return 1
  [ $(( now - epoch )) -lt "${FM_IDLE_COMPACT_SAVE_TIMEOUT_SECS:-900}" ] || return 1

  absorbed=$(fm_idle_compact_marker_field "$marker" absorbed_turnended)
  if [ -n "$absorbed" ]; then
    [ "$sig" = "$absorbed" ] || return 1
    return 0
  fi

  baseline=$(fm_idle_compact_marker_field "$marker" baseline_turnended)
  [ "$sig" != "$baseline" ] || return 1
  [ "$(cat "$(fm_wake_signal_seen_path "$state" "$file")" 2>/dev/null || true)" = "$baseline" ] || return 1

  fm_idle_compact_marker_set "$marker" absorbed_turnended "$sig" || return 1
  return 0
}

# --- per-task state machine --------------------------------------------------

# Phase 2: waits for the turn-ended signature to advance past the recorded
# baseline (proof the save turn completed), re-checks full eligibility (the
# reconciled crew state may have flipped to working during the wait - the
# never-mid-task rule applies to the /compact send exactly as it does to the
# first send), then sends /compact.
fm_idle_compact_advance_save_sent() {  # <state> <task> <marker> <threshold-minutes>
  local state=$1 task=$2 marker=$3 threshold_min=$4
  local baseline sent_epoch save_timeout age cur_turnended

  fm_idle_compact_task_context "$state" "$task" || { rm -f "$marker"; return 0; }
  baseline=$(fm_idle_compact_marker_field "$marker" baseline_turnended)
  sent_epoch=$(fm_idle_compact_marker_field "$marker" sent_epoch)
  save_timeout=${FM_IDLE_COMPACT_SAVE_TIMEOUT_SECS:-900}

  case "$sent_epoch" in
    ''|*[!0-9]*) rm -f "$marker"; return 0 ;;
  esac
  age=$(( $(date +%s) - sent_epoch ))
  if [ "$age" -ge "$save_timeout" ]; then
    # A save turn that never completes must not wait forever either; abandon
    # this episode silently. A later genuinely new status append or pane
    # activity still clears phase=done the normal way.
    fm_idle_compact_marker_write "$marker" phase=done \
      "status_sig=$(fm_idle_compact_status_sig "$state" "$task")" \
      "pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")" \
      "settle_epoch=$(date +%s)"
    return 0
  fi

  cur_turnended=$(fm_idle_compact_turnended_sig "$state" "$task")
  [ "$cur_turnended" != "$baseline" ] || return 0

  fm_idle_compact_eligible "$state" "$task" "$threshold_min" || return 0
  fm_idle_compact_safe_to_send "$state" "$task" || return 0

  if fm_idle_compact_send "$state" "$task" "$(fm_idle_compact_compact_message "$task")"; then
    fm_idle_compact_marker_write "$marker" phase=settling \
      "settle_epoch=$(date +%s)" \
      "baseline_turnended=$cur_turnended"
  fi
  return 0
}

# Phase 3: the /compact went out, but its summary has not necessarily finished
# rendering yet. Capturing the done-phase baseline immediately would record a
# pre-render pane hash, and the compaction summary's own render would then
# read as "new pane activity" - clearing the marker and self-triggering a
# brand-new save+compact episode every couple of sweeps. So the baseline is
# captured on a LATER sweep, one settle window after the send, so the
# feature's own output is baked into the recorded signatures and never counts
# as worker activity.
fm_idle_compact_advance_settling() {  # <state> <task> <marker>
  local state=$1 task=$2 marker=$3 settle_epoch settle_secs age declared

  fm_idle_compact_task_context "$state" "$task" || { rm -f "$marker"; return 0; }
  settle_epoch=$(fm_idle_compact_marker_field "$marker" settle_epoch)
  case "$settle_epoch" in
    ''|*[!0-9]*) rm -f "$marker"; return 0 ;;
  esac
  settle_secs=${FM_IDLE_COMPACT_SETTLE_SECS:-${FM_IDLE_COMPACT_INTERVAL:-300}}
  age=$(( $(date +%s) - settle_epoch ))
  [ "$age" -ge "$settle_secs" ] || return 0

  declared=$(fm_idle_compact_marker_field "$marker" declared)

  # A worker waiting on firstmate - not on an external event - is rung once,
  # right at the settling->done transition, so it never sits idle past its own
  # compaction. The declared=1 marker field is not the only trigger: an episode
  # that took the ORDINARY save-then-compact path over a worker whose status
  # still declares the compaction pause leaves exactly the same worker waiting,
  # which is how both 2026-09-06 lanes went unrung. The status log is therefore
  # re-read here and either signal rings. The ring is a durable inbox record, so
  # this transition advances to phase=done only once that record exists; a failed
  # enqueue keeps the marker in phase=settling for a later sweep.
  if [ "$declared" = 1 ] || fm_idle_compact_declared_paused "$state" "$task"; then
    fm_idle_compact_ring_worker "$state" "$task" || return 0
  fi

  fm_idle_compact_marker_write "$marker" phase=done \
    "status_sig=$(fm_idle_compact_status_sig "$state" "$task")" \
    "pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")" \
    "settle_epoch=$settle_epoch"
  return 0
}

# One task through the 3-phase marker state machine. Never propagates a
# failure to the caller: every branch that cannot proceed just returns 0 so a
# sweep across many tasks never aborts early on one task's transient issue.
fm_idle_compact_process_task() {  # <state> <task> <threshold-minutes>
  local state=$1 task=$2 threshold_min=$3 marker phase status_sig pane_sig
  local cur_status cur_pane_sig cur_turnended

  marker=$(fm_idle_compact_marker_path "$state" "$task")

  if [ -f "$marker" ]; then
    phase=$(fm_idle_compact_marker_field "$marker" phase)
    case "$phase" in
      save-sent)
        fm_idle_compact_advance_save_sent "$state" "$task" "$marker" "$threshold_min"
        return 0
        ;;
      settling)
        fm_idle_compact_advance_settling "$state" "$task" "$marker"
        return 0
        ;;
      done)
        fm_idle_compact_task_context "$state" "$task" || { rm -f "$marker"; return 0; }
        status_sig=$(fm_idle_compact_marker_field "$marker" status_sig)
        pane_sig=$(fm_idle_compact_marker_field "$marker" pane_sig)
        cur_status=$(fm_idle_compact_status_sig "$state" "$task")
        cur_pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")
        if [ "$cur_status" = "$status_sig" ] && [ "$cur_pane_sig" = "$pane_sig" ]; then
          fm_idle_compact_ring_backstop "$state" "$task" "$marker"
          return 0
        fi
        # The episode is over: a new status append or new pane activity ends
        # it. Replacing the marker with a phase=reset stamp rather than
        # deleting it keeps the ONE durable record of when that activity was
        # observed, which is what makes the next episode wait out a fresh idle
        # window instead of re-arming on the same sweep. Pane activity leaves
        # no mtime anywhere else, so without this stamp a crewmate whose pane
        # just changed reads as idle-since-its-last-status and gets compacted
        # while its cache is at its warmest.
        fm_idle_compact_marker_write "$marker" phase=reset
        return 0
        ;;
      reset)
        # Not an episode: an activity stamp left by the reset above, consumed
        # by fm_idle_compact_activity_age below. Left byte-identical (and so
        # mtime-identical) until a fresh episode overwrites it.
        ;;
      *)
        rm -f "$marker"
        ;;
    esac
  fi

  fm_idle_compact_eligible "$state" "$task" "$threshold_min" || return 0
  fm_idle_compact_safe_to_send "$state" "$task" || return 0

  cur_turnended=$(fm_idle_compact_turnended_sig "$state" "$task")

  if fm_idle_compact_declared_paused "$state" "$task"; then
    # Nothing left to save: the worker already stopped for exactly this
    # reason. Skip the notes-save turn and send /compact directly.
    fm_idle_compact_send "$state" "$task" "$(fm_idle_compact_declared_compact_message "$state" "$task")" || return 0
    fm_idle_compact_marker_write "$marker" phase=settling \
      "settle_epoch=$(date +%s)" \
      "baseline_turnended=$cur_turnended" \
      "declared=1"
    return 0
  fi

  fm_idle_compact_send "$state" "$task" "$(fm_idle_compact_save_message "$task")" || return 0
  fm_idle_compact_marker_write "$marker" phase=save-sent \
    "sent_epoch=$(date +%s)" \
    "baseline_turnended=$cur_turnended"
  return 0
}

# --- sweep entry point (the one thing both callers invoke) -----------------

fm_idle_compact_sweep_due() {  # <state>
  local age
  age=$(fm_path_age "$1/.idle-compact-last-sweep")
  [ "$age" -ge "${FM_IDLE_COMPACT_INTERVAL:-300}" ]
}

# The single entry point bin/fm-watch.sh's main loop and
# bin/fm-supervise-daemon.sh's housekeeping both call, on their own existing
# cadence. Always returns 0: idle-compact is opt-in housekeeping and must
# never fail a caller's loop.
fm_idle_compact_tick() {  # <state> [config-dir]
  local state=$1 config=${2:-$CONFIG} minutes meta task lock

  minutes=$(fm_idle_compact_threshold_minutes "$config") || return 0
  fm_idle_compact_sweep_due "$state" || return 0

  # The watcher's main loop and the away-mode daemon's housekeeping tick both
  # call this against the same state dir, and the due-check above is
  # check-then-touch: without mutual exclusion two concurrent callers can both
  # pass it in the same window, both pass the live safety gate, and interleave
  # keystrokes into the same crewmate pane. fm_lock_try_acquire is the
  # existing WATCH_LOCK idiom (bin/fm-wake-lib.sh: pid-recorded, stale-holder
  # recovery built in); a held lock means the other supervisor is already
  # sweeping, so skipping is silent routine. The due-check re-runs under the
  # lock because the loser of the race may acquire only after the winner
  # released, with the marker already freshly touched.
  lock=$(fm_idle_compact_lock_path "$state")
  fm_lock_try_acquire "$lock" || return 0
  if ! fm_idle_compact_sweep_due "$state"; then
    fm_lock_release "$lock"
    return 0
  fi
  touch "$state/.idle-compact-last-sweep" 2>/dev/null || true

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    task=$(basename "$meta"); task=${task%.meta}
    fm_idle_compact_process_task "$state" "$task" "$minutes"
  done
  fm_lock_release "$lock"
  return 0
}

# --- Main entry: only when executed directly, matching bin/fm-watch.sh's
# sourced-vs-executed split so tests can source this file for its functions
# without triggering a sweep.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-tick}" in
    tick) fm_idle_compact_tick "$STATE" "$CONFIG" ;;
    # enabled: live query for a caller (a worker deciding whether to wait for
    # a compaction ring, not just the sweep itself) that must not trust a
    # generation-time snapshot, since config/idle-compact can be added or
    # removed at any point afterward. Exit 0 and print the threshold minutes
    # when enabled; exit 1 with no output otherwise (absent, invalid/non-
    # numeric, or zero - an empty-but-present file is valid, not a disabling
    # case) - the same validation fm_idle_compact_threshold_minutes
    # already owns, so this never duplicates that logic.
    enabled) fm_idle_compact_threshold_minutes "$CONFIG" ;;
    *)
      echo "usage: fm-idle-compact.sh [tick|enabled]" >&2
      exit 2
      ;;
  esac
fi
