#!/usr/bin/env bash
# fm-progress-lib.sh - the single owner of the per-task progress phase model,
# the display-only remaining-time guess, the per-task observation record, the
# per-home phase-duration history, and the label suffix grammar.
#
# Sourced, never executed. bin/fm-progress.sh is the executable surface, and
# bin/fm-watch.sh, bin/fm-fleet-snapshot.sh, and bin/fm-teardown.sh consume
# these helpers through it or by sourcing this file.
#
# WHY THIS EXISTS. The captain sees a worker's endpoint and its last status line
# but nothing that says how far along the task is or how long it is likely to
# need. Everything here is DISPLAY ONLY: no function in this file changes a
# task's lifecycle, writes a file another script owns, waits on the network, or
# makes a decision. A wrong guess costs nothing but a wrong impression, which is
# why every rendered estimate carries a range or a "~" and the word guess.
#
# PHASE MODEL. A live task is in exactly one phase, derived deterministically
# from sources that already exist (never from prose):
#   implementing         spawned, no run attributed, no terminal done yet
#   validating           a no-mistakes run is active on the task's branch and is
#                        running a step (the step is reported beside the phase),
#                        or is parked at a gate the worker itself answers
#   fixing               that run is in a fix step after a gate decision
#   ci                   the run's push/pr/ci step is active, or a PR is
#                        recorded on the task while its worker is still working
#   waiting on captain   the task is held for the captain (bin/fm-captain-hold.sh
#                        `open`), an ask-user gate is parked, or a keyed
#                        needs-decision is still open in the status fold
#   ready                a terminal done is reported (PR checks green, scout
#                        report written, or local branch ready), awaiting merge
#   blocked | paused | failed | unknown
#                        the crew's current state as bin/fm-crew-state.sh reads
#                        it; none of these carries an estimate
# fm_progress_phase is the one function that maps a bin/fm-crew-state.sh line,
# the status fold owned by bin/fm-classify-lib.sh, and the captain-hold
# predicate onto that phase. It never re-reads raw run logs.
#
# OBSERVATION RECORD, state/.progress-<id>, key=value lines, atomically
# replaced by the watcher tick (fm_progress_tick, its only writer) and removed
# by teardown through `fm-progress.sh record`. A fleet snapshot, /bearings, or
# `show` read advances it in memory only and never writes it, so two observers
# can never overwrite each other's record:
#   v=1
#   observed=<epoch>        when the current accumulators were last advanced
#   phase=<phase>           the phase observed then
#   step=<step>             the run step or gate beside that phase, or empty
#   since=<epoch>           when the current phase was first observed
#   fix_rounds=<n>          fix rounds seen so far (the run's own round count
#                           wins when bin/fm-crew-state.sh reports it)
#   secs_implementing=<n> secs_validating=<n> secs_fixing=<n> secs_ci=<n>
#   secs_waiting=<n> secs_ready=<n> secs_other=<n>
#                           seconds attributed to each phase so far; the
#                           interval between two observations is attributed to
#                           the phase seen at the earlier one
#   label=<suffix>          the last label suffix applied to the worker's Herdr
#                           workspace, empty when none was applied
#   label_attempt=<epoch>   when the last failed label refresh was attempted
#                           (0 when none is pending), so a failing rename
#                           retries on the cadence rather than every poll
#   label_warned=<reason>   the failure reason last warned about (empty when
#                           the last refresh succeeded), so one reason warns
#                           once and warns again only after it changes or a
#                           later success
#   tick_at=<epoch>         when the watcher tick last re-read this task's
#                           phase (0 before the first tick); fm_progress_tick
#                           keys its FM_PROGRESS_REFRESH_SECS cadence on this
#                           field alone, so no other read can postpone a
#                           label refresh
#   spawn_gen=<gen>         the meta's spawn_gen this record belongs to; a
#                           record whose spawn_gen differs from the meta's
#                           current one (or has none while the meta has one)
#                           is treated as absent, so a re-dispatched or
#                           relaunched incarnation of the same id starts its
#                           accumulators again from its own spawn instant
# The first observation seeds observed= from the task's spawn instant (the
# epoch inside spawn_gen=s<epoch>.<pid>.<random>, else the record's mtime), so
# time before the first observation counts as implementing.
# A record is only ever written while state/<id>.meta still exists, checked
# right before the write, so a read that was in flight while teardown retired
# the record cannot recreate it.
# An observation whose derived phase is unknown (an unreadable current state)
# charges its interval to secs_other and leaves phase=, step=, since=, and the
# fix-round count untouched: the caller displays unknown with no estimate, but
# a transient blip never resets the last known phase's clock or counts a round.
#
# HISTORY RECORD, data/phase-history.jsonl, one JSON object per finished task,
# appended by `fm-progress.sh record` at teardown and never rewritten:
#   {"v":1,"id":"<task>","kind":"ship","mode":"no-mistakes","finished":<epoch>,
#    "secs":{"implementing":N,"validating":N,"fixing":N,"ci":N,"waiting":N},
#    "fix_rounds":N}
# Medians are computed per (kind, mode) over the newest FM_PROGRESS_HISTORY_MAX
# records; a phase needs FM_PROGRESS_MIN_SAMPLES finished tasks with time in it
# before its median replaces the default band. The sample count reported beside
# a guess is the number of matching records, never a sum over phases.
#
# DEFAULT BANDS (minutes), used for any phase with fewer samples than that:
#   implementing 10 to 60, validating 15 to 40, each fix round 5 to 15 (one
#   round expected), ci 5 to 15; waiting on captain has no estimate.
#
# ESTIMATE. The remaining guess is the remainder of the current phase plus the
# expected time of every phase still ahead in the task's delivery sequence:
#   scout, local-only         implementing
#   direct-PR                 implementing, ci
#   no-mistakes (default)     implementing, validating+fixing, ci
# validating and fixing are one interleaved block whose elapsed time is their
# sum. A current phase that has already outlived its threshold contributes
# nothing and is reported as running long: the threshold is the default band's
# upper bound, or, once history supplies the median, the 75th percentile of the
# matching samples (the largest sample when fewer than four exist), so a task
# on a normal pace is not called late the moment it passes the median. Medians
# give a "~N min" point guess; default
# bands give an "N to M min" range; a mix gives a range. Each bound is rounded
# to the nearest five minutes so a label moves at most once per five elapsed
# minutes rather than every poll.
#
# LABEL SUFFIX. " · <phase>" followed by " · <short estimate>" when one exists,
# for example " · validating · ~25 min" or " · waiting on captain". The Herdr
# adapter (bin/backends/herdr.sh, fm_backend_herdr_projection_progress_apply)
# owns where that suffix sits inside a projected workspace label and how it is
# stripped again; this file only composes it.
#
# ENVIRONMENT
#   FM_PROGRESS_REFRESH_SECS   seconds between phase re-reads per task in the
#                              watcher tick, keyed on the record's tick_at=
#                              (default 60; 0 disables the tick)
#   FM_PROGRESS_TICK_MAX_SECS  age past which bin/fm-watch.sh treats its
#                              state/.progress-tick.pid marker as stale even
#                              while the pid it names is alive, and terminates
#                              and relaunches its own tick child (default 600)
#   FM_PROGRESS_MIN_SAMPLES    finished tasks a phase needs before its median
#                              is used (default 3)
#   FM_PROGRESS_HISTORY_MAX    newest history records considered (default 200)
#   FM_PROGRESS_NOW            epoch override for tests
#   FM_CREW_STATE_BIN          current-state reader (bin/fm-classify-lib.sh)
#   FM_CAPTAIN_HOLD_BIN        captain-hold predicate script (tests stub it)
set -u

_FM_PROGRESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F status_open_decisions >/dev/null 2>&1; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "$_FM_PROGRESS_LIB_DIR/fm-classify-lib.sh"
fi
FM_CAPTAIN_HOLD_BIN="${FM_CAPTAIN_HOLD_BIN:-$_FM_PROGRESS_LIB_DIR/fm-captain-hold.sh}"

FM_PROGRESS_REFRESH_SECS=${FM_PROGRESS_REFRESH_SECS:-60}
case "$FM_PROGRESS_REFRESH_SECS" in ''|*[!0-9]*) FM_PROGRESS_REFRESH_SECS=60 ;; esac
FM_PROGRESS_MIN_SAMPLES=${FM_PROGRESS_MIN_SAMPLES:-3}
case "$FM_PROGRESS_MIN_SAMPLES" in ''|*[!0-9]*|0) FM_PROGRESS_MIN_SAMPLES=3 ;; esac
FM_PROGRESS_HISTORY_MAX=${FM_PROGRESS_HISTORY_MAX:-200}
case "$FM_PROGRESS_HISTORY_MAX" in ''|*[!0-9]*|0) FM_PROGRESS_HISTORY_MAX=200 ;; esac

# Default bands in minutes. One owner, documented in docs/configuration.md.
FM_PROGRESS_DEFAULT_IMPLEMENTING_LOW=10
FM_PROGRESS_DEFAULT_IMPLEMENTING_HIGH=60
FM_PROGRESS_DEFAULT_VALIDATING_LOW=15
FM_PROGRESS_DEFAULT_VALIDATING_HIGH=40
FM_PROGRESS_DEFAULT_FIX_ROUND_LOW=5
FM_PROGRESS_DEFAULT_FIX_ROUND_HIGH=15
FM_PROGRESS_DEFAULT_FIX_ROUNDS=1
FM_PROGRESS_DEFAULT_CI_LOW=5
FM_PROGRESS_DEFAULT_CI_HIGH=15

fm_progress_now() {
  case "${FM_PROGRESS_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_PROGRESS_NOW" ;;
  esac
}

fm_progress_record_path() {  # <state-dir> <id>
  printf '%s/.progress-%s' "$1" "$2"
}

fm_progress_history_path() {  # <data-dir>
  printf '%s/phase-history.jsonl' "$1"
}

fm_progress_id_valid() {  # <id>
  case "${1:-}" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

_fm_progress_meta_get() {  # <meta> <key>
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

_fm_progress_mtime() {  # <file>
  local t
  t=$(stat -c %Y "$1" 2>/dev/null) || t=$(stat -f %m "$1" 2>/dev/null) || t=
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$t"
}

# The task's spawn instant: the epoch embedded in spawn_gen=s<epoch>.<pid>.<n>
# (bin/fm-spawn.sh), else the record's mtime, else now.
fm_progress_spawn_epoch() {  # <meta>
  local gen epoch
  gen=$(_fm_progress_meta_get "$1" spawn_gen)
  case "$gen" in
    s[0-9]*.*)
      epoch=${gen#s}
      epoch=${epoch%%.*}
      case "$epoch" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) printf '%s\n' "$epoch"; return 0 ;;
      esac
      ;;
  esac
  _fm_progress_mtime "$1" && return 0
  fm_progress_now
}

# --- phase derivation -------------------------------------------------------

# fm_progress_phase <crew-state-line> <status-file> [captain-held 0|1] [pr-recorded 0|1]
# Prints "<phase>\t<step>\t<fix-round>". The crew-state line is the one
# bin/fm-crew-state.sh prints; an unparseable line is phase unknown.
fm_progress_phase() {
  local line=$1 status_file=$2 held=${3:-0} pr=${4:-0}
  local state=unknown source=none detail='' rest step='' round='' phase=unknown
  local open='' open_needs=0 open_blocked=0 gate provably_working=0
  case "$line" in
    state:\ *)
      rest=${line#state: }
      state=${rest%% *}
      case "$rest" in
        *"source: "*)
          rest=${rest#*source: }
          case "$rest" in
            *" · "*) source=${rest%% · *}; detail=${rest#* · } ;;
            *) source=$rest ;;
          esac
          ;;
      esac
      ;;
  esac
  case "$detail" in
    *" · step: "*)
      step=${detail#* · step: }
      step=${step%% · *}
      ;;
  esac
  case "$detail" in
    *" · fix round: "*)
      round=${detail#* · fix round: }
      round=${round%% · *}
      round=${round%% *}
      case "$round" in ''|*[!0-9]*) round='' ;; esac
      ;;
  esac
  # A crew whose run step or pane proves it is working outranks every
  # declaration: a backlog hold or an old keyed decision cannot make a busy
  # worker read as waiting, the same rule bin/fm-fleet-snapshot.sh applies.
  if [ "$state" = working ] && { [ "$source" = run-step ] || [ "$source" = pane ]; }; then
    provably_working=1
  fi
  # The durable keyed open set (bin/fm-classify-lib.sh owns the fold), cleared
  # under that lifecycle rule: a crew that provably moved past a gate, or
  # reached a terminal state, is not still waiting on that decision.
  open=$(status_open_decisions "$status_file")
  if { [ "$source" = run-step ] || [ "$source" = pane ]; } \
     && [ "$state" != parked ] && [ "$state" != blocked ]; then
    open=''
  fi
  case "$state" in done|failed) open='' ;; esac
  if [ -n "$open" ]; then
    case "$open" in
      *$'\t'needs-decision$'\t'*) open_needs=1 ;;
    esac
    case "$open" in
      *$'\t'blocked$'\t'*) open_blocked=1 ;;
    esac
  fi
  if [ "$held" = 1 ] && [ "$provably_working" = 0 ]; then
    phase='waiting on captain'
  else
    case "$state" in
      parked)
        if [ "$open_needs" = 1 ] || [ "$source" = status-log ] || [ "$source" = none ]; then
          phase='waiting on captain'
        else
          case "$detail" in
            *ask-user*) phase='waiting on captain' ;;
            *)
              phase=validating
              if [ -z "$step" ]; then
                case "$detail" in
                  "parked at "*)
                    gate=${detail#parked at }
                    gate=${gate%%:*}
                    gate=${gate%% *}
                    step=$gate
                    ;;
                esac
              fi
              ;;
          esac
        fi
        ;;
      blocked) phase=blocked ;;
      paused) phase=paused ;;
      failed) phase=failed ;;
      done) phase=ready ;;
      working)
        if [ "$open_needs" = 1 ]; then
          phase='waiting on captain'
        elif [ "$open_blocked" = 1 ]; then
          phase=blocked
        else
          case "$source" in
            run-step)
              case "$detail" in
                "validating (fixing)"*) phase=fixing ;;
                "ci running"*) phase=ci ;;
                *) phase=validating ;;
              esac
              if [ "$phase" = validating ]; then
                case "$step" in push|pr|ci) phase=ci ;; esac
              fi
              ;;
            *)
              if [ "$pr" = 1 ]; then phase=ci; else phase=implementing; fi
              ;;
          esac
        fi
        ;;
      *) phase=unknown ;;
    esac
  fi
  printf '%s\t%s\t%s' "$phase" "$step" "$round"
}

# The accumulator key a phase's time is charged to.
fm_progress_phase_key() {  # <phase>
  case "$1" in
    implementing|validating|fixing|ci|ready) printf '%s' "$1" ;;
    'waiting on captain') printf 'waiting' ;;
    *) printf 'other' ;;
  esac
}

# --- observation record -----------------------------------------------------

_fm_progress_rec_reset() {
  FM_PROGRESS_REC_OBSERVED=
  FM_PROGRESS_REC_PHASE=
  FM_PROGRESS_REC_STEP=
  FM_PROGRESS_REC_SINCE=
  FM_PROGRESS_REC_FIX_ROUNDS=0
  FM_PROGRESS_REC_SECS_IMPLEMENTING=0
  FM_PROGRESS_REC_SECS_VALIDATING=0
  FM_PROGRESS_REC_SECS_FIXING=0
  FM_PROGRESS_REC_SECS_CI=0
  FM_PROGRESS_REC_SECS_WAITING=0
  FM_PROGRESS_REC_SECS_READY=0
  FM_PROGRESS_REC_SECS_OTHER=0
  FM_PROGRESS_REC_LABEL=
  FM_PROGRESS_REC_LABEL_ATTEMPT=
  FM_PROGRESS_REC_LABEL_WARNED=
  FM_PROGRESS_REC_TICK_AT=0
  FM_PROGRESS_REC_SPAWN_GEN=
}

_fm_progress_num() {  # <value> -> value or 0
  case "${1:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac
}

# fm_progress_record_load <state-dir> <id>: sets FM_PROGRESS_REC_*; 1 when absent,
# unreadable, or written for another incarnation of the id (its spawn_gen
# differs from the meta's current one); every field is then reset.
fm_progress_record_load() {
  local rec key value line meta
  _fm_progress_rec_reset
  rec=$(fm_progress_record_path "$1" "$2")
  [ -f "$rec" ] && [ ! -L "$rec" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *=*) ;; *) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      observed) FM_PROGRESS_REC_OBSERVED=$(_fm_progress_num "$value") ;;
      phase) FM_PROGRESS_REC_PHASE=$value ;;
      step) FM_PROGRESS_REC_STEP=$value ;;
      since) FM_PROGRESS_REC_SINCE=$(_fm_progress_num "$value") ;;
      fix_rounds) FM_PROGRESS_REC_FIX_ROUNDS=$(_fm_progress_num "$value") ;;
      secs_implementing) FM_PROGRESS_REC_SECS_IMPLEMENTING=$(_fm_progress_num "$value") ;;
      secs_validating) FM_PROGRESS_REC_SECS_VALIDATING=$(_fm_progress_num "$value") ;;
      secs_fixing) FM_PROGRESS_REC_SECS_FIXING=$(_fm_progress_num "$value") ;;
      secs_ci) FM_PROGRESS_REC_SECS_CI=$(_fm_progress_num "$value") ;;
      secs_waiting) FM_PROGRESS_REC_SECS_WAITING=$(_fm_progress_num "$value") ;;
      secs_ready) FM_PROGRESS_REC_SECS_READY=$(_fm_progress_num "$value") ;;
      secs_other) FM_PROGRESS_REC_SECS_OTHER=$(_fm_progress_num "$value") ;;
      label) FM_PROGRESS_REC_LABEL=$value ;;
      label_attempt) FM_PROGRESS_REC_LABEL_ATTEMPT=$(_fm_progress_num "$value") ;;
      label_warned) FM_PROGRESS_REC_LABEL_WARNED=$value ;;
      tick_at) FM_PROGRESS_REC_TICK_AT=$(_fm_progress_num "$value") ;;
      spawn_gen) FM_PROGRESS_REC_SPAWN_GEN=$value ;;
    esac
  done < "$rec"
  [ -n "$FM_PROGRESS_REC_OBSERVED" ] && [ -n "$FM_PROGRESS_REC_PHASE" ] || {
    _fm_progress_rec_reset
    return 1
  }
  meta="$1/$2.meta"
  if [ -f "$meta" ] && [ "$FM_PROGRESS_REC_SPAWN_GEN" != "$(_fm_progress_meta_get "$meta" spawn_gen)" ]; then
    _fm_progress_rec_reset
    return 1
  fi
  [ -n "$FM_PROGRESS_REC_SINCE" ] || FM_PROGRESS_REC_SINCE=$FM_PROGRESS_REC_OBSERVED
  return 0
}

# fm_progress_record_write <state-dir> <id>: atomically publish FM_PROGRESS_REC_*;
# a successful no-op once state/<id>.meta is gone, so a read in flight during
# teardown never recreates a retired record.
fm_progress_record_write() {
  local rec tmp
  [ -f "$1/$2.meta" ] || return 0
  rec=$(fm_progress_record_path "$1" "$2")
  tmp=$(mktemp "$1/.progress-$2.XXXXXX" 2>/dev/null) || return 1
  if ! {
    printf 'v=1\n'
    printf 'observed=%s\n' "$FM_PROGRESS_REC_OBSERVED"
    printf 'phase=%s\n' "$FM_PROGRESS_REC_PHASE"
    printf 'step=%s\n' "$FM_PROGRESS_REC_STEP"
    printf 'since=%s\n' "$FM_PROGRESS_REC_SINCE"
    printf 'fix_rounds=%s\n' "$FM_PROGRESS_REC_FIX_ROUNDS"
    printf 'secs_implementing=%s\n' "$FM_PROGRESS_REC_SECS_IMPLEMENTING"
    printf 'secs_validating=%s\n' "$FM_PROGRESS_REC_SECS_VALIDATING"
    printf 'secs_fixing=%s\n' "$FM_PROGRESS_REC_SECS_FIXING"
    printf 'secs_ci=%s\n' "$FM_PROGRESS_REC_SECS_CI"
    printf 'secs_waiting=%s\n' "$FM_PROGRESS_REC_SECS_WAITING"
    printf 'secs_ready=%s\n' "$FM_PROGRESS_REC_SECS_READY"
    printf 'secs_other=%s\n' "$FM_PROGRESS_REC_SECS_OTHER"
    printf 'label=%s\n' "$FM_PROGRESS_REC_LABEL"
    printf 'label_attempt=%s\n' "$FM_PROGRESS_REC_LABEL_ATTEMPT"
    printf 'label_warned=%s\n' "$FM_PROGRESS_REC_LABEL_WARNED"
    printf 'tick_at=%s\n' "$FM_PROGRESS_REC_TICK_AT"
    printf 'spawn_gen=%s\n' "$FM_PROGRESS_REC_SPAWN_GEN"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$rec" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

_fm_progress_rec_add() {  # <key> <secs>
  case "$1" in
    implementing) FM_PROGRESS_REC_SECS_IMPLEMENTING=$((FM_PROGRESS_REC_SECS_IMPLEMENTING + $2)) ;;
    validating) FM_PROGRESS_REC_SECS_VALIDATING=$((FM_PROGRESS_REC_SECS_VALIDATING + $2)) ;;
    fixing) FM_PROGRESS_REC_SECS_FIXING=$((FM_PROGRESS_REC_SECS_FIXING + $2)) ;;
    ci) FM_PROGRESS_REC_SECS_CI=$((FM_PROGRESS_REC_SECS_CI + $2)) ;;
    waiting) FM_PROGRESS_REC_SECS_WAITING=$((FM_PROGRESS_REC_SECS_WAITING + $2)) ;;
    ready) FM_PROGRESS_REC_SECS_READY=$((FM_PROGRESS_REC_SECS_READY + $2)) ;;
    *) FM_PROGRESS_REC_SECS_OTHER=$((FM_PROGRESS_REC_SECS_OTHER + $2)) ;;
  esac
}

# fm_progress_observe <state-dir> <id> <meta> <phase> <step> <fix-round> [now]
# Advance the record in memory: charge the interval since the last observation
# to the phase seen then and open a new phase when it changed. Nothing is
# written here: fm_progress_tick, the record's only writer, persists
# FM_PROGRESS_REC_* after its read, and every other reader (the fleet snapshot,
# /bearings, `show`) leaves the file untouched, so concurrent observers can
# never overwrite each other's record. Leaves FM_PROGRESS_REC_* describing the
# record as advanced.
fm_progress_observe() {
  local state=$1 id=$2 meta=$3 phase=$4 step=$5 round=$6 now=${7:-} prev delta
  [ -n "$now" ] || now=$(fm_progress_now)
  if ! fm_progress_record_load "$state" "$id"; then
    _fm_progress_rec_reset
    FM_PROGRESS_REC_SPAWN_GEN=$(_fm_progress_meta_get "$meta" spawn_gen)
    FM_PROGRESS_REC_OBSERVED=$(fm_progress_spawn_epoch "$meta")
    [ "$FM_PROGRESS_REC_OBSERVED" -le "$now" ] || FM_PROGRESS_REC_OBSERVED=$now
    FM_PROGRESS_REC_PHASE=implementing
    FM_PROGRESS_REC_SINCE=$FM_PROGRESS_REC_OBSERVED
  fi
  prev=$FM_PROGRESS_REC_PHASE
  delta=$((now - FM_PROGRESS_REC_OBSERVED))
  [ "$delta" -ge 0 ] || delta=0
  if [ "$phase" = unknown ]; then
    # An unreadable state is displayed as unknown but is not a transition: the
    # last known phase keeps its clock, step, and round count.
    _fm_progress_rec_add other "$delta"
    FM_PROGRESS_REC_OBSERVED=$now
    return 0
  fi
  _fm_progress_rec_add "$(fm_progress_phase_key "$prev")" "$delta"
  if [ "$phase" != "$prev" ]; then
    FM_PROGRESS_REC_SINCE=$now
    [ "$phase" != fixing ] || FM_PROGRESS_REC_FIX_ROUNDS=$((FM_PROGRESS_REC_FIX_ROUNDS + 1))
  fi
  case "$round" in
    ''|*[!0-9]*) ;;
    *) [ "$round" -le "$FM_PROGRESS_REC_FIX_ROUNDS" ] || FM_PROGRESS_REC_FIX_ROUNDS=$round ;;
  esac
  FM_PROGRESS_REC_OBSERVED=$now
  FM_PROGRESS_REC_PHASE=$phase
  FM_PROGRESS_REC_STEP=$step
}

# --- history ----------------------------------------------------------------

# fm_progress_history_append <data-dir> <id> <kind> <mode> [finished-epoch]
# Appends one record from the loaded FM_PROGRESS_REC_* accumulators.
fm_progress_history_append() {
  local data=$1 id=$2 kind=$3 mode=$4 finished=${5:-} file
  fm_progress_id_valid "$id" || return 1
  case "$kind" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$mode" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -n "$finished" ] || finished=$(fm_progress_now)
  [ -d "$data" ] || return 1
  file=$(fm_progress_history_path "$data")
  [ ! -L "$file" ] || return 1
  printf '{"v":1,"id":"%s","kind":"%s","mode":"%s","finished":%s,"secs":{"implementing":%s,"validating":%s,"fixing":%s,"ci":%s,"waiting":%s},"fix_rounds":%s}\n' \
    "$id" "$kind" "$mode" "$finished" \
    "$FM_PROGRESS_REC_SECS_IMPLEMENTING" "$FM_PROGRESS_REC_SECS_VALIDATING" \
    "$FM_PROGRESS_REC_SECS_FIXING" "$FM_PROGRESS_REC_SECS_CI" \
    "$FM_PROGRESS_REC_SECS_WAITING" "$FM_PROGRESS_REC_FIX_ROUNDS" \
    >> "$file"
}

# fm_progress_history_medians <data-dir> <kind> <mode>
# Prints "<name>\t<median>\t<count>\t<p75>" for implementing, validating, ci
# (seconds), block (validating plus fixing seconds per task), fix_round (seconds
# per round), and fix_rounds (rounds per task), plus one "tasks\t<n>\t<n>\t<n>"
# row counting the matching records, over the newest FM_PROGRESS_HISTORY_MAX
# matching records. p75 is the nearest-rank 75th percentile, the largest sample
# when fewer than four exist. Prints nothing without jq or without a history file.
fm_progress_history_medians() {
  local data=$1 kind=$2 mode=$3 file
  file=$(fm_progress_history_path "$data")
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  tail -n "$FM_PROGRESS_HISTORY_MAX" "$file" 2>/dev/null \
    | jq -R -r --arg kind "$kind" --arg mode "$mode" -s '
      def median:
        sort | if length == 0 then null
               elif length % 2 == 1 then .[(length / 2) | floor]
               else ((.[length / 2 - 1] + .[length / 2]) / 2) end;
      def p75:
        sort | if length == 0 then null
               elif length < 4 then .[-1]
               else .[((length * 3 + 3) / 4 | floor) - 1] end;
      def row($name; $values):
        ($values | map(select(type == "number" and . >= 0))) as $v
        | [$name, (($v | median) // 0 | round), ($v | length), (($v | p75) // 0 | round)] | @tsv;
      [ split("\n")[] | select(length > 0) | (fromjson? // empty)
        | select(.v == 1 and .kind == $kind and .mode == $mode) ] as $rows
      | (["tasks", ($rows | length), ($rows | length), ($rows | length)] | @tsv),
        row("implementing"; [$rows[] | .secs.implementing | select(. > 0)]),
        row("validating"; [$rows[] | .secs.validating | select(. > 0)]),
        row("block"; [$rows[] | select(.secs.validating > 0) | (.secs.validating + .secs.fixing)]),
        row("ci"; [$rows[] | .secs.ci | select(. > 0)]),
        row("fix_round"; [$rows[] | select((.fix_rounds // 0) > 0) | (.secs.fixing / .fix_rounds)]),
        row("fix_rounds"; [$rows[] | select(.secs.validating > 0) | (.fix_rounds // 0)])
    ' 2>/dev/null || true
}

# --- estimate ---------------------------------------------------------------

_fm_progress_median_lookup() {  # <medians-tsv> <name> -> "<median>\t<count>\t<p75>"
  local line
  while IFS= read -r line; do
    case "$line" in "$2"$'\t'*) line=${line#*$'\t'}; printf '%s' "$line"; return 0 ;; esac
  done <<EOF
$1
EOF
  printf '0\t0\t0'
}

_fm_progress_secs_to_min() {  # <secs>
  printf '%s' "$(( ($1 + 30) / 60 ))"
}

# Expected minutes for one unit as
# "<low>\t<high>\t<history|default|mixed>\t<threshold>": the threshold is the
# minute count past which the unit reads as running long (the default band's
# upper bound, or the history 75th percentile once the unit's median applies).
_fm_progress_unit_expected() {  # <medians-tsv> <unit>
  local m=$1 unit=$2 rec median count p75 rounds rounds_count per per_count vlow vhigh vbasis threshold
  case "$unit" in
    impl|ci)
      if [ "$unit" = impl ]; then
        rec=$(_fm_progress_median_lookup "$m" implementing)
      else
        rec=$(_fm_progress_median_lookup "$m" ci)
      fi
      median=${rec%%$'\t'*}; rec=${rec#*$'\t'}
      count=${rec%%$'\t'*}; p75=${rec#*$'\t'}
      if [ "$count" -ge "$FM_PROGRESS_MIN_SAMPLES" ]; then
        median=$(_fm_progress_secs_to_min "$median")
        printf '%s\t%s\thistory\t%s' "$median" "$median" "$(_fm_progress_secs_to_min "$p75")"
      elif [ "$unit" = impl ]; then
        printf '%s\t%s\tdefault\t%s' "$FM_PROGRESS_DEFAULT_IMPLEMENTING_LOW" "$FM_PROGRESS_DEFAULT_IMPLEMENTING_HIGH" "$FM_PROGRESS_DEFAULT_IMPLEMENTING_HIGH"
      else
        printf '%s\t%s\tdefault\t%s' "$FM_PROGRESS_DEFAULT_CI_LOW" "$FM_PROGRESS_DEFAULT_CI_HIGH" "$FM_PROGRESS_DEFAULT_CI_HIGH"
      fi
      ;;
    block)
      rec=$(_fm_progress_median_lookup "$m" validating)
      median=${rec%%$'\t'*}; rec=${rec#*$'\t'}
      count=${rec%%$'\t'*}
      if [ "$count" -ge "$FM_PROGRESS_MIN_SAMPLES" ]; then
        vlow=$(_fm_progress_secs_to_min "$median"); vhigh=$vlow; vbasis=history
        rec=$(_fm_progress_median_lookup "$m" block)
        rec=${rec#*$'\t'}
        threshold=$(_fm_progress_secs_to_min "${rec#*$'\t'}")
      else
        vlow=$FM_PROGRESS_DEFAULT_VALIDATING_LOW; vhigh=$FM_PROGRESS_DEFAULT_VALIDATING_HIGH; vbasis=default
        threshold=''
      fi
      rec=$(_fm_progress_median_lookup "$m" fix_rounds)
      rounds=${rec%%$'\t'*}; rec=${rec#*$'\t'}
      rounds_count=${rec%%$'\t'*}
      [ "$rounds_count" -ge "$FM_PROGRESS_MIN_SAMPLES" ] || rounds=$FM_PROGRESS_DEFAULT_FIX_ROUNDS
      rec=$(_fm_progress_median_lookup "$m" fix_round)
      per=${rec%%$'\t'*}; rec=${rec#*$'\t'}
      per_count=${rec%%$'\t'*}
      if [ "$per_count" -ge "$FM_PROGRESS_MIN_SAMPLES" ]; then
        per=$(_fm_progress_secs_to_min "$per")
        vlow=$((vlow + rounds * per)); vhigh=$((vhigh + rounds * per))
        [ "$vbasis" = history ] || vbasis=mixed
      else
        vlow=$((vlow + rounds * FM_PROGRESS_DEFAULT_FIX_ROUND_LOW))
        vhigh=$((vhigh + rounds * FM_PROGRESS_DEFAULT_FIX_ROUND_HIGH))
        [ "$vbasis" = default ] || vbasis=mixed
      fi
      # A history threshold below the expected block would call every task late;
      # keep whichever is larger.
      if [ -z "$threshold" ] || [ "$threshold" -lt "$vhigh" ]; then threshold=$vhigh; fi
      printf '%s\t%s\t%s\t%s' "$vlow" "$vhigh" "$vbasis" "$threshold"
      ;;
  esac
}

# The delivery sequence of units for a task, space separated.
fm_progress_sequence() {  # <kind> <mode>
  case "$1" in
    scout) printf 'impl' ;;
    *)
      case "$2" in
        local-only) printf 'impl' ;;
        direct-PR) printf 'impl ci' ;;
        *) printf 'impl block ci' ;;
      esac
      ;;
  esac
}

fm_progress_unit_of_phase() {  # <phase>
  case "$1" in
    implementing) printf 'impl' ;;
    validating|fixing) printf 'block' ;;
    ci) printf 'ci' ;;
    *) printf '' ;;
  esac
}

_fm_progress_basis_merge() {  # <a> <b>
  if [ -z "$1" ]; then printf '%s' "$2"
  elif [ "$1" = "$2" ]; then printf '%s' "$1"
  else printf 'mixed'; fi
}

# fm_progress_estimate <data-dir> <kind> <mode> <phase> <elapsed-secs> <block-secs>
# <elapsed-secs> is time in the current phase; <block-secs> is validating plus
# fixing time so far (the block's elapsed when the phase is either).
# Prints "<cur_low>\t<cur_high>\t<rest_low>\t<rest_high>\t<basis>\t<overrun>\t<samples>\t<expected_low>\t<expected_high>"
# in minutes, or "none" when the phase carries no estimate.
fm_progress_estimate() {
  local data=$1 kind=$2 mode=$3 phase=$4 elapsed=$5 block=$6
  local unit seq medians found=0 u exp low high basis threshold elapsed_min rec
  local cur_low=0 cur_high=0 rest_low=0 rest_high=0 all_basis='' overrun=0 exp_low=0 exp_high=0 total_samples=0
  unit=$(fm_progress_unit_of_phase "$phase")
  [ -n "$unit" ] || { printf 'none'; return 0; }
  seq=$(fm_progress_sequence "$kind" "$mode")
  case " $seq " in *" $unit "*) ;; *) printf 'none'; return 0 ;; esac
  medians=$(fm_progress_history_medians "$data" "$kind" "$mode")
  # The sample count is the number of matching finished tasks, never a sum.
  rec=$(_fm_progress_median_lookup "$medians" tasks)
  total_samples=${rec%%$'\t'*}
  for u in $seq; do
    if [ "$found" = 0 ]; then
      [ "$u" = "$unit" ] || continue
      found=1
      exp=$(_fm_progress_unit_expected "$medians" "$u")
      low=${exp%%$'\t'*}; exp=${exp#*$'\t'}
      high=${exp%%$'\t'*}; exp=${exp#*$'\t'}
      basis=${exp%%$'\t'*}; threshold=${exp#*$'\t'}
      exp_low=$low; exp_high=$high
      if [ "$u" = block ]; then elapsed_min=$(( block / 60 )); else elapsed_min=$(( elapsed / 60 )); fi
      cur_low=$((low - elapsed_min)); [ "$cur_low" -ge 0 ] || cur_low=0
      cur_high=$((high - elapsed_min)); [ "$cur_high" -ge 0 ] || cur_high=0
      [ "$elapsed_min" -le "$threshold" ] || overrun=1
      all_basis=$(_fm_progress_basis_merge "$all_basis" "$basis")
      continue
    fi
    exp=$(_fm_progress_unit_expected "$medians" "$u")
    low=${exp%%$'\t'*}; exp=${exp#*$'\t'}
    high=${exp%%$'\t'*}; exp=${exp#*$'\t'}
    basis=${exp%%$'\t'*}
    rest_low=$((rest_low + low)); rest_high=$((rest_high + high))
    all_basis=$(_fm_progress_basis_merge "$all_basis" "$basis")
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$cur_low" "$cur_high" "$rest_low" "$rest_high" "$all_basis" "$overrun" "$total_samples" "$exp_low" "$exp_high"
}

# Minutes rendered as "~N min" or "N to M min", each bound on the nearest
# five-minute grid so a bound moves only every five elapsed minutes.
fm_progress_minutes_text() {  # <low> <high>
  local low=$1 high=$2
  low=$(( (low + 2) / 5 * 5 ))
  high=$(( (high + 2) / 5 * 5 ))
  [ "$low" -ge 5 ] || low=5
  [ "$high" -ge "$low" ] || high=$low
  if [ "$low" -eq "$high" ]; then
    printf '~%s min' "$low"
  else
    printf '%s to %s min' "$low" "$high"
  fi
}

# fm_progress_estimate_short <estimate-record>: the label form.
fm_progress_estimate_short() {
  local e=$1 cur_low cur_high rest_low rest_high overrun
  [ "$e" != none ] && [ -n "$e" ] || { printf ''; return 0; }
  cur_low=${e%%$'\t'*}; e=${e#*$'\t'}
  cur_high=${e%%$'\t'*}; e=${e#*$'\t'}
  rest_low=${e%%$'\t'*}; e=${e#*$'\t'}
  rest_high=${e%%$'\t'*}; e=${e#*$'\t'}
  e=${e#*$'\t'}
  overrun=${e%%$'\t'*}
  if [ "$overrun" = 1 ]; then
    printf 'running long'
    return 0
  fi
  fm_progress_minutes_text "$((cur_low + rest_low))" "$((cur_high + rest_high))"
}

# fm_progress_estimate_text <estimate-record> <phase>: the prose form, which
# always says guess and names its basis.
fm_progress_estimate_text() {
  local e=$1 phase=$2 cur_low cur_high rest_low rest_high basis overrun samples exp_low exp_high basis_text
  case "$phase" in
    'waiting on captain') printf 'no estimate while waiting on the captain'; return 0 ;;
    ready) printf 'ready, awaiting merge'; return 0 ;;
    unknown) printf 'unknown'; return 0 ;;
  esac
  [ "$e" != none ] && [ -n "$e" ] || { printf 'no estimate'; return 0; }
  cur_low=${e%%$'\t'*}; e=${e#*$'\t'}
  cur_high=${e%%$'\t'*}; e=${e#*$'\t'}
  rest_low=${e%%$'\t'*}; e=${e#*$'\t'}
  rest_high=${e%%$'\t'*}; e=${e#*$'\t'}
  basis=${e%%$'\t'*}; e=${e#*$'\t'}
  overrun=${e%%$'\t'*}; e=${e#*$'\t'}
  samples=${e%%$'\t'*}; e=${e#*$'\t'}
  exp_low=${e%%$'\t'*}; exp_high=${e#*$'\t'}
  case "$basis" in
    history) basis_text="from $samples finished tasks" ;;
    mixed) basis_text="partly from $samples finished tasks, partly default bands" ;;
    *) basis_text="default bands, fewer than $FM_PROGRESS_MIN_SAMPLES finished tasks" ;;
  esac
  if [ "$overrun" = 1 ]; then
    if [ "$exp_low" -eq "$exp_high" ]; then
      printf 'running long: past the 75th percentile of finished tasks for %s (guess was %s)' "$phase" "$(fm_progress_minutes_text "$exp_low" "$exp_high")"
    else
      printf 'running long: past the %s guess for %s' "$(fm_progress_minutes_text "$exp_low" "$exp_high")" "$phase"
    fi
    if [ "$((rest_low + rest_high))" -gt 0 ]; then
      printf ', then %s more' "$(fm_progress_minutes_text "$rest_low" "$rest_high")"
    fi
    printf ' (%s)' "$basis_text"
    return 0
  fi
  printf '%s guess (%s)' "$(fm_progress_minutes_text "$((cur_low + rest_low))" "$((cur_high + rest_high))")" "$basis_text"
}

# fm_progress_label_suffix <phase> <short-estimate>
fm_progress_label_suffix() {
  local phase=$1 short=${2:-}
  [ -n "$phase" ] || phase=unknown
  if [ -n "$short" ]; then
    printf ' · %s · %s' "$phase" "$short"
  else
    printf ' · %s' "$phase"
  fi
}

# --- captain hold predicate -------------------------------------------------

# 0 when the task's backlog row is held for the captain (the one owner is
# bin/fm-captain-hold.sh `open`); 1 otherwise, including when the predicate
# cannot run at all (no backlog, no compatible tasks-axi).
fm_progress_captain_held() {  # <data-dir> <id>
  local data=$1 id=$2
  [ -f "$data/backlog.md" ] || return 1
  [ -x "$FM_CAPTAIN_HOLD_BIN" ] || return 1
  FM_DATA_OVERRIDE="$data" "$FM_CAPTAIN_HOLD_BIN" open "$id" >/dev/null 2>&1
}

# --- one full read for one task --------------------------------------------

# fm_progress_read <state-dir> <data-dir> <id> [crew-state-line] [captain-held 0|1|""] [now]
# Derives the phase (reading the crew's current state through FM_CREW_STATE_BIN
# when no line is supplied and the captain-hold predicate when no flag is
# supplied), advances the observation record in memory without writing it, and
# sets:
#   FM_PROGRESS_PHASE FM_PROGRESS_STEP FM_PROGRESS_SINCE FM_PROGRESS_ELAPSED
#   FM_PROGRESS_ESTIMATE (raw record or none) FM_PROGRESS_SHORT FM_PROGRESS_TEXT
#   FM_PROGRESS_LABEL_SUFFIX FM_PROGRESS_KIND FM_PROGRESS_MODE
#   FM_PROGRESS_LOW FM_PROGRESS_HIGH (total minutes, empty without an estimate)
#   FM_PROGRESS_BASIS (history|default|mixed) FM_PROGRESS_SAMPLES FM_PROGRESS_OVERRUN
# Returns 1 when the task has no record or is a secondmate. Never writes the
# observation record: fm_progress_tick persists what this read derived.
# shellcheck disable=SC2034  # FM_PROGRESS_* are this function's outputs, read by callers.
fm_progress_read() {
  local state=$1 data=$2 id=$3 line=${4:-} held=${5:-} now=${6:-}
  local meta kind mode pr=0 derived phase step round elapsed block e cur_low cur_high rest_low rest_high
  FM_PROGRESS_PHASE=unknown; FM_PROGRESS_STEP=; FM_PROGRESS_SINCE=; FM_PROGRESS_ELAPSED=0
  FM_PROGRESS_ESTIMATE=none; FM_PROGRESS_SHORT=; FM_PROGRESS_TEXT=unknown
  FM_PROGRESS_LABEL_SUFFIX=' · unknown'; FM_PROGRESS_KIND=; FM_PROGRESS_MODE=
  FM_PROGRESS_LOW=; FM_PROGRESS_HIGH=; FM_PROGRESS_BASIS=; FM_PROGRESS_SAMPLES=0; FM_PROGRESS_OVERRUN=0
  fm_progress_id_valid "$id" || return 1
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  kind=$(_fm_progress_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" != secondmate ] || return 1
  [ -z "$(_fm_progress_meta_get "$meta" remote_host)" ] || return 1
  mode=$(_fm_progress_meta_get "$meta" mode)
  [ -n "$mode" ] || { [ "$kind" = scout ] && mode=scout || mode=no-mistakes; }
  [ -z "$(_fm_progress_meta_get "$meta" pr)" ] || pr=1
  [ -n "$now" ] || now=$(fm_progress_now)
  if [ -z "$line" ]; then
    line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || line=
    line=$(printf '%s\n' "$line" | head -1)
  fi
  if [ -z "$held" ]; then
    held=0
    case "$line" in
      "state: working · source: run-step"*|"state: working · source: pane"*) ;;
      *) fm_progress_captain_held "$data" "$id" && held=1 ;;
    esac
  fi
  derived=$(fm_progress_phase "$line" "$state/$id.status" "$held" "$pr")
  phase=${derived%%$'\t'*}; derived=${derived#*$'\t'}
  step=${derived%%$'\t'*}; round=${derived#*$'\t'}
  fm_progress_observe "$state" "$id" "$meta" "$phase" "$step" "$round" "$now" || return 1
  elapsed=$((now - FM_PROGRESS_REC_SINCE)); [ "$elapsed" -ge 0 ] || elapsed=0
  block=$((FM_PROGRESS_REC_SECS_VALIDATING + FM_PROGRESS_REC_SECS_FIXING))
  FM_PROGRESS_KIND=$kind
  FM_PROGRESS_MODE=$mode
  FM_PROGRESS_PHASE=$phase
  FM_PROGRESS_STEP=$step
  FM_PROGRESS_SINCE=$FM_PROGRESS_REC_SINCE
  FM_PROGRESS_ELAPSED=$elapsed
  FM_PROGRESS_ESTIMATE=$(fm_progress_estimate "$data" "$kind" "$mode" "$phase" "$elapsed" "$block")
  FM_PROGRESS_SHORT=$(fm_progress_estimate_short "$FM_PROGRESS_ESTIMATE")
  FM_PROGRESS_TEXT=$(fm_progress_estimate_text "$FM_PROGRESS_ESTIMATE" "$phase")
  FM_PROGRESS_LABEL_SUFFIX=$(fm_progress_label_suffix "$phase" "$FM_PROGRESS_SHORT")
  if [ "$FM_PROGRESS_ESTIMATE" != none ]; then
    e=$FM_PROGRESS_ESTIMATE
    cur_low=${e%%$'\t'*}; e=${e#*$'\t'}
    cur_high=${e%%$'\t'*}; e=${e#*$'\t'}
    rest_low=${e%%$'\t'*}; e=${e#*$'\t'}
    rest_high=${e%%$'\t'*}; e=${e#*$'\t'}
    FM_PROGRESS_BASIS=${e%%$'\t'*}; e=${e#*$'\t'}
    FM_PROGRESS_OVERRUN=${e%%$'\t'*}; e=${e#*$'\t'}
    FM_PROGRESS_SAMPLES=${e%%$'\t'*}
    FM_PROGRESS_LOW=$((cur_low + rest_low))
    FM_PROGRESS_HIGH=$((cur_high + rest_high))
  fi
  return 0
}

# --- label refresh ----------------------------------------------------------

# fm_progress_label_refresh <state-dir> <id> <suffix> [now]
# Applies the suffix to the worker's projected Herdr workspace when it differs
# from the last applied one. Silent on every non-Herdr backend and on a Herdr
# task without a bound projection. A failure warns once per distinct reason
# (the adapter reports the reason in FM_BACKEND_HERDR_PROGRESS_REASON), stays
# silent while that reason persists, warns again after the reason changes or a
# later success, and retries on the cadence; a hand-changed label is only
# re-read on that cadence, never renamed, until its journaled base returns.
# Never touches task or endpoint records.
fm_progress_label_refresh() {
  local state=$1 id=$2 suffix=$3 now=${4:-} meta backend rc reason
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 0
  backend=$(_fm_progress_meta_get "$meta" backend)
  [ "$backend" = herdr ] || return 0
  fm_progress_record_load "$state" "$id" || return 0
  [ "$FM_PROGRESS_REC_LABEL" != "$suffix" ] || return 0
  [ -n "$now" ] || now=$(fm_progress_now)
  if [ "${FM_PROGRESS_REC_LABEL_ATTEMPT:-0}" -gt 0 ] \
     && [ $((now - FM_PROGRESS_REC_LABEL_ATTEMPT)) -lt "$FM_PROGRESS_REFRESH_SECS" ]; then
    return 0
  fi
  if ! declare -F fm_backend_source >/dev/null 2>&1; then
    # shellcheck source=bin/fm-backend.sh
    . "$_FM_PROGRESS_LIB_DIR/fm-backend.sh"
  fi
  fm_backend_source herdr 2>/dev/null || return 0
  declare -F fm_backend_herdr_projection_progress_apply >/dev/null 2>&1 || return 0
  fm_backend_herdr_projection_progress_apply "$state" "$id" "$suffix"
  rc=$?
  case "$rc" in
    0)
      FM_PROGRESS_REC_LABEL=$suffix
      FM_PROGRESS_REC_LABEL_ATTEMPT=0
      FM_PROGRESS_REC_LABEL_WARNED=
      ;;
    2) return 0 ;;
    *)
      reason=${FM_BACKEND_HERDR_PROGRESS_REASON:-failed}
      if [ "$FM_PROGRESS_REC_LABEL_WARNED" != "$reason" ]; then
        echo "warning: herdr progress label for $id: ${FM_BACKEND_HERDR_PROGRESS_MESSAGE:-$reason} (this repeats only if the reason changes)" >&2
        FM_PROGRESS_REC_LABEL_WARNED=$reason
      fi
      FM_PROGRESS_REC_LABEL_ATTEMPT=$now
      ;;
  esac
  fm_progress_record_write "$state" "$id" || true
  return 0
}

# fm_progress_tick <state-dir> <data-dir> [now]
# The observation record's only writer (teardown's `record` retires it). One
# pass over every local task, launched by the watcher as a detached child
# each poll (bin/fm-watch.sh progress_tick_detached) so no current-state read
# ever sits on the poll loop's path: re-read the phase no more often than
# FM_PROGRESS_REFRESH_SECS, keyed on the record's own tick_at= so a fleet
# snapshot read in between never postpones the next re-read, then refresh the
# label when the phase or rounded estimate changed. Bounded, no network, never
# fails the caller.
fm_progress_tick() {
  local state=$1 data=$2 now=${3:-} meta id
  [ "$FM_PROGRESS_REFRESH_SECS" -gt 0 ] || return 0
  [ -n "$now" ] || now=$(fm_progress_now)
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_progress_id_valid "$id" || continue
    if fm_progress_record_load "$state" "$id" \
       && [ $((now - FM_PROGRESS_REC_TICK_AT)) -lt "$FM_PROGRESS_REFRESH_SECS" ]; then
      continue
    fi
    fm_progress_read "$state" "$data" "$id" '' '' "$now" || continue
    FM_PROGRESS_REC_TICK_AT=$now
    fm_progress_record_write "$state" "$id" || true
    fm_progress_label_refresh "$state" "$id" "$FM_PROGRESS_LABEL_SUFFIX" "$now" || true
  done
  return 0
}
