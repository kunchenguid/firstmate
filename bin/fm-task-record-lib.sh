# shellcheck shell=bash
# Retain a finished task's supervisor-side record before cleanup removes it.
# Usage: . bin/fm-task-record-lib.sh; fm_task_record_retain <state> <data> <id>
#
# ONE OWNER for what survives cleanup, where it lands, and what bounds it.
#
# Cleanup removes state/<id>.meta, state/<id>.status, and state/<id>.busy-state
# (bin/fm-teardown.sh, bin/fm-classify-lib.sh's status_retire_presentation_task,
# and bin/fm-busy-event.sh retire). The worker's own transcript survives under
# its harness session directory, but firstmate's side of the task did not: which
# model ran it, on which backend and endpoint, under which delivery mode and
# merge posture, the status-event stream, and the last turn-activity record.
# Copying those three files into the task's existing durable directory keeps
# cleanup doing its job and lets the record outlive it.
#
# WHERE: data/<id>/record/, beside the brief that already survives cleanup
# there. A finished task therefore has one directory holding what it was asked
# to do and what actually ran for it.
#
#   data/<id>/record/meta         state/<id>.meta, byte for byte
#   data/<id>/record/status       the status-event stream, newest lines
#   data/<id>/record/busy-state   the last turn-activity record, or empty
#   data/<id>/record/retained     when retention ran and what it elided
#
# The copies keep their source mtimes, because status lines carry no timestamp
# of their own and the file's mtime is the only record of when the last one
# landed.
#
# WHAT IS RETAINED: the meta whole, rather than a chosen subset. A filter is a
# list that rots: the next field added to the record would be dropped silently,
# and silence is the failure this whole path exists to end. Retaining by default
# inverts that, and costs nothing, since the meta is a small fixed-shape record
# and every secret firstmate holds for a task lives in a file of its own
# (state/<id>.grok-turnend-token, state/<id>.kimi-turnend-token, .env), none of
# which is copied here. Locks, turn-end and progress markers, generated harness
# extensions, busy-source bindings, the steering inbox, and per-task caches are
# scaffolding for a live endpoint and are not retained.
#
# WHAT BOUNDS IT: the status stream is the only part a task controls the size
# of, so it is capped at FM_TASK_RECORD_STATUS_MAX_LINES newest lines and the
# retained record discloses how many older ones were dropped. The cap is far
# above any real log - a status line is meant to be a phase change a supervisor
# would act on, and observed logs run to single digits against a session-start
# digest that tails five. Everything else is fixed: the meta is one spawn
# record, the turn-activity record is one line, and the provenance file is five.
# Across tasks this adds no growth axis, because data/<id>/ already exists per
# task and already retains a brief many times this size. Re-running cleanup
# replaces the record rather than appending to it.
#
# FAILS CLOSED: retention runs before the first removal, and a caller that
# cannot retain must refuse rather than continue, because a cleanup that
# silently retained nothing loses the evidence invisibly - nobody finds out
# until they go looking, by which time it is gone. Every copy is read back and
# compared against its source, and the whole record is asserted present before
# this reports success. On any failure the partial record is discarded, so a
# rerun starts clean while the sources are still in place.
#
# RUNS TWICE SAFELY: the record is staged beside its destination and moved into
# place whole, a rerun replaces an earlier record rather than merging into it,
# staging left by a killed run is swept on the next attempt, and a task whose
# records are already gone is a no-op success.

FM_TASK_RECORD_SCHEMA=fm-task-record.v1
FM_TASK_RECORD_STATUS_MAX_LINES=400

# fm_task_record_dir <data> <id>: where <id>'s retained record lives.
fm_task_record_dir() {
  printf '%s\n' "$1/$2/record"
}

# fm_task_record_present <data> <id>: true when every file of a complete record
# is in place. A partial record is not a record: it reads as evidence while
# missing the part someone came for.
fm_task_record_present() {
  local dir
  dir=$(fm_task_record_dir "$1" "$2")
  [ -f "$dir/meta" ] && [ -f "$dir/status" ] \
    && [ -f "$dir/busy-state" ] && [ -f "$dir/retained" ]
}

_fm_task_record_abandon() {  # <staging-dir> <message>
  FM_TASK_RECORD_ERROR=$2
  rm -rf -- "$1" 2>/dev/null || true
  return 1
}

# _fm_task_record_identical <expected> <copy> <label>: true when the copy holds
# the bytes it should. A comparison that could not run is reported as its own
# failure rather than as a mismatch, because the two ask for different repairs.
_fm_task_record_identical() {
  local rc=0
  cmp -s -- "$1" "$2" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) FM_TASK_RECORD_COMPARE_ERROR="the retained copy of $3 does not match it" ;;
    *) FM_TASK_RECORD_COMPARE_ERROR="the retained copy of $3 could not be compared against it" ;;
  esac
  return 1
}

# fm_task_record_retain <state> <data> <id>: copy <id>'s supervisor-side records
# into data/<id>/record/. Sets FM_TASK_RECORD_ERROR and returns non-zero when
# the record could not be written whole. A task whose meta is already gone has
# nothing left to copy and is a no-op success, so a rerun after an interrupted
# cleanup converges instead of refusing.
fm_task_record_retain() {
  local state=$1 data=$2 id=$3
  local meta="$state/$id.meta" status="$state/$id.status" busy="$state/$id.busy-state"
  local dir staging stale total kept elided retained_at
  FM_TASK_RECORD_ERROR=

  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    return 0
  fi
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    FM_TASK_RECORD_ERROR="$meta is not a regular file"
    return 1
  fi

  dir=$(fm_task_record_dir "$data" "$id")
  staging="$data/$id/.record.staging.$$"
  # A retention killed between the staging write and the move leaves its
  # staging directory behind, under a pid this run does not reuse. Sweeping
  # them here is what keeps a crash from accumulating one per attempt.
  for stale in "$data/$id"/.record.staging.*; do
    { [ -e "$stale" ] || [ -L "$stale" ]; } || continue
    rm -rf -- "$stale" || {
      FM_TASK_RECORD_ERROR="could not clear an abandoned staging directory at $stale"
      return 1
    }
  done
  mkdir -p -- "$staging" || {
    FM_TASK_RECORD_ERROR="could not create $staging"
    return 1
  }

  cp -p -- "$meta" "$staging/meta" \
    || _fm_task_record_abandon "$staging" "could not copy $meta" || return 1
  _fm_task_record_identical "$meta" "$staging/meta" "$meta" \
    || _fm_task_record_abandon "$staging" "$FM_TASK_RECORD_COMPARE_ERROR" || return 1

  total=0
  kept=0
  elided=0
  if [ -f "$status" ] && [ ! -L "$status" ]; then
    total=$(LC_ALL=C command awk 'END { print NR }' "$status" 2>/dev/null) || total=
    case "${total:-}" in
      ''|*[!0-9]*) _fm_task_record_abandon "$staging" "could not count the status events in $status" || return 1 ;;
    esac
    if [ "$total" -le "$FM_TASK_RECORD_STATUS_MAX_LINES" ]; then
      kept=$total
      cp -p -- "$status" "$staging/status" \
        || _fm_task_record_abandon "$staging" "could not copy $status" || return 1
      _fm_task_record_identical "$status" "$staging/status" "$status" \
        || _fm_task_record_abandon "$staging" "$FM_TASK_RECORD_COMPARE_ERROR" || return 1
    else
      kept=$FM_TASK_RECORD_STATUS_MAX_LINES
      elided=$((total - kept))
      LC_ALL=C command tail -n "$kept" < "$status" > "$staging/status" \
        || _fm_task_record_abandon "$staging" "could not copy the newest events of $status" || return 1
      LC_ALL=C command tail -n "$kept" < "$status" > "$staging/.status.reread" \
        || _fm_task_record_abandon "$staging" "could not re-read the newest events of $status" || return 1
      _fm_task_record_identical "$staging/.status.reread" "$staging/status" "the newest events of $status" \
        || _fm_task_record_abandon "$staging" "$FM_TASK_RECORD_COMPARE_ERROR" || return 1
      rm -f -- "$staging/.status.reread" \
        || _fm_task_record_abandon "$staging" "could not clear the re-read of $status" || return 1
    fi
  elif [ -e "$status" ] || [ -L "$status" ]; then
    _fm_task_record_abandon "$staging" "$status is not a regular file" || return 1
  else
    : > "$staging/status" \
      || _fm_task_record_abandon "$staging" "could not record an empty status stream" || return 1
  fi

  if [ -f "$busy" ] && [ ! -L "$busy" ]; then
    cp -p -- "$busy" "$staging/busy-state" \
      || _fm_task_record_abandon "$staging" "could not copy $busy" || return 1
    _fm_task_record_identical "$busy" "$staging/busy-state" "$busy" \
      || _fm_task_record_abandon "$staging" "$FM_TASK_RECORD_COMPARE_ERROR" || return 1
  else
    : > "$staging/busy-state" \
      || _fm_task_record_abandon "$staging" "could not record an absent turn-activity record" || return 1
  fi

  # Read before the write, so a clock this cannot read refuses instead of
  # stamping the record with an empty time nobody would notice.
  retained_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || retained_at=
  [ -n "$retained_at" ] \
    || _fm_task_record_abandon "$staging" "could not read the time to stamp the record with" || return 1
  {
    printf 'schema=%s\n' "$FM_TASK_RECORD_SCHEMA" \
      && printf 'task=%s\n' "$id" \
      && printf 'retained_at=%s\n' "$retained_at" \
      && printf 'status_lines=%s\n' "$kept" \
      && printf 'status_lines_elided=%s\n' "$elided"
  } > "$staging/retained" \
    || _fm_task_record_abandon "$staging" "could not record the retention itself" || return 1

  if [ -e "$dir" ] || [ -L "$dir" ]; then
    rm -rf -- "$dir" \
      || _fm_task_record_abandon "$staging" "could not replace the earlier record at $dir" || return 1
  fi
  mv -- "$staging" "$dir" \
    || _fm_task_record_abandon "$staging" "could not move the record into $dir" || return 1
  fm_task_record_present "$data" "$id" || {
    FM_TASK_RECORD_ERROR="the record at $dir is incomplete"
    return 1
  }
  return 0
}
