#!/usr/bin/env bash
# Durable record of a task's most recent merge attempt, so cleanup can tell
# whether the merge a supervisor asked for actually happened, however the merge
# and the cleanup commands were chained or piped.
#
# bin/fm-merge-local.sh and bin/fm-pr-merge.sh each record exactly one line in
# state/<id>.meta as they exit, once they have read the task record, replacing
# any earlier one:
#   last_merge_attempt=<outcome> <epoch> <script>[ exit=<status>]
# where <outcome> is one of
#   merged  - the run confirmed the merge landed;
#   queued  - the run exited 0 with the forge holding the request (a merge
#             queue or auto-merge) but not yet confirmed merged;
#   refused - the run exited non-zero; exit= carries that status, and the
#             run's own stderr carries the reason.
# bin/fm-teardown.sh's header owns how cleanup acts on a refused latest attempt.
#
# A record that cannot be written is reported on stderr and never changes the
# merge script's own exit status.
#
# Sourced by bin/fm-merge-local.sh, bin/fm-pr-merge.sh, bin/fm-teardown.sh, and
# tests, with no side effects on source. A writer must also have sourced
# bin/fm-wake-lib.sh and bin/fm-backlog-transition-lib.sh, as both merge scripts
# do; the reader needs neither.

# fm_merge_attempt_record <state> <task-id> <spawn-gen> <outcome> <script> [exit-status]
#
# Writes the record under the task's meta lock, which the caller must not hold,
# only while the task record still carries <spawn-gen> (empty for a legacy
# record with none), so a later incarnation of the same id is never marked.
# Returns 0 when recorded or when the task record is gone, 1 otherwise.
fm_merge_attempt_record() {  # <state> <task-id> <spawn-gen> <outcome> <script> [exit-status]
  local state=$1 id=$2 spawn_gen=$3 outcome=$4 script=$5 rc=${6-}
  local meta lock tmp='' line status=0
  case "$outcome" in merged|queued) ;; refused) [ -n "$rc" ] || return 1 ;; *) return 1 ;; esac
  case "$rc" in *[!0-9]*) return 1 ;; esac
  meta="$state/$id.meta"
  [ -e "$meta" ] || return 0
  line="last_merge_attempt=$outcome $(date +%s) $script${rc:+ exit=$rc}"
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  if [ ! -e "$meta" ]; then
    :
  elif ! fm_backlog_meta_spawn_gen_optional "$meta" "$state" \
      || [ "$FM_BACKLOG_META_SPAWN_GEN" != "$spawn_gen" ]; then
    status=1
  elif ! tmp=$(mktemp "$state/.merge-attempt-$id.XXXXXX"); then
    tmp=
    status=1
  elif ! { awk '!/^last_merge_attempt=/' "$meta" && printf '%s\n' "$line"; } > "$tmp" \
      || ! fm_backlog_record_publish "$tmp" "$meta" 'merge attempt record' "$state"; then
    status=1
  fi
  [ "$status" -eq 0 ] || [ -z "$tmp" ] || rm -f -- "$tmp"
  fm_lock_release "$lock" || status=1
  return "$status"
}

# fm_merge_attempt_report_exit <state> <task-id> <spawn-gen> <script> <exit-status> <confirmed>
#
# The exit-trap form both merge scripts call: a non-zero <exit-status> records
# refused, otherwise <confirmed> true records merged and anything else queued.
# A failed write warns on stderr; the caller's exit status is unaffected.
fm_merge_attempt_report_exit() {  # <state> <task-id> <spawn-gen> <script> <exit-status> <confirmed>
  local state=$1 id=$2 spawn_gen=$3 script=$4 rc=$5 confirmed=$6 outcome
  if [ "$rc" -ne 0 ]; then
    outcome=refused
  elif [ "$confirmed" = true ]; then
    outcome=merged
    rc=
  else
    outcome=queued
    rc=
  fi
  fm_merge_attempt_record "$state" "$id" "$spawn_gen" "$outcome" "$script" "$rc" && return 0
  printf 'warning: could not record this %s merge attempt (%s) in task %s metadata\n' \
    "$script" "$outcome" "$id" >&2
  return 0
}

# fm_merge_attempt_refused <meta>
#
# Prints the latest record's detail (<epoch> <script> exit=<status>) and returns
# 0 when the latest recorded attempt was refused; returns 1 otherwise, including
# when no attempt was ever recorded.
fm_merge_attempt_refused() {  # <meta>
  local value
  value=$(grep '^last_merge_attempt=' "$1" 2>/dev/null | tail -1 | cut -d= -f2-) || true
  case "$value" in
    'refused '*) printf '%s\n' "${value#refused }" ;;
    *) return 1 ;;
  esac
}
