#!/usr/bin/env bash
# fm-cold-cache-lib.sh - the ONE owner of firstmate's cold prompt-cache policy:
# when a worker session counts as cold, when it may be parked, and what the
# note for its fresh replacement says.
#
# Why: a harness prompt cache lives about one hour. A worker idle longer than
# that pays for its whole context again on its next turn, so a short steer to an
# old, large session is the most expensive way to deliver a small instruction.
# A fresh session that starts from the brief on disk plus a short note costs a
# fraction of that. The tools for the cheap path already exist -
# `bin/fm-control.sh <id> exit` keeps all work, and `relaunch --note` starts a
# fresh small session - and this policy makes them the default:
#   bin/fm-send.sh     refuses a text steer to a cold or cold-parked worker and
#                      prints the relaunch command to use instead
#   bin/fm-control.sh  owns the `park` verb (verified exit plus the marker) and
#                      builds relaunch's default note for a parked worker
#   bin/fm-watch.sh    parks an eligible worker on its own
#   bin/fm-park-stopped.sh  parks every already-stopped worker of one home
#
# Cold: the task's semantic busy record (bin/fm-busy-lib.sh) is valid for the
# current incarnation, says idle, and was written longer ago than the threshold.
# Only that positive evidence counts. A busy, unknown, missing, malformed, or
# stale record is never cold, so a harness with no semantic busy writer is never
# refused or parked by this policy, and a busy worker is never parked.
#
# Threshold: config/cold-cache-minutes holds one positive integer of minutes, or
# `off` to disable the send guard and auto-park together. Absent means the
# default, 55 minutes, just inside the one-hour cache lifetime. Any other value
# is malformed: callers refuse and name the file rather than guess.
#
# Scope: ship and scout workers only. A secondmate is left out on purpose:
# relaunching one does not deliver the message that found it cold, so a refusal
# would strand a routed request, and the automatic steers that reach a
# secondmate (startup nudges, pending-reply recovery, backlog handoff, config
# re-reads) have no relaunch-then-resend path. A remote secondmate also has no
# local lifecycle control at all. An idle secondmate endpoint is healthy by
# design (AGENTS.md section 8), so it is never parked either.
#
# Cold-parked marker: state/<id>.cold-parked, written only by `fm-control.sh
# <id> park` after its exit postcondition held, and removed by a successful
# relaunch. Fields, one per line: parked_at=<epoch>, status=<the latest status
# event when it was parked>, and endpoint=closed|kept|gone (closed: park closed
# the terminal and proved it gone; kept: a tmux window stays open with a shell;
# gone: the endpoint was already gone). While it exists the watcher skips the task entirely -
# no stale, dead-agent, or steering-inbox wake - because the stopped agent was
# stopped on purpose, and fm-send refuses every text steer to it, --cold-ok
# included, because no agent is running to read one.
#
# Park eligibility (fm_cold_cache_park_check): kind ship or scout, not already
# parked, cold, latest status event a declared wait (paused, done,
# needs-decision, blocked, failed, or captain-held), no unread steering-inbox
# record, and no relaunch transaction in progress. A worker whose agent already
# stopped needs only the scope checks: no cache is left to save, and parking it
# just closes its idle terminal (bin/fm-control.sh owns that path). `park` itself also leaves a
# worker alone whose harness reports background work still running, because
# that work is how a paused worker resumes on its own (bin/fm-control.sh).
#
# Callers source bin/fm-backend.sh, bin/fm-busy-lib.sh, bin/fm-classify-lib.sh,
# and bin/fm-task-inbox-lib.sh; this file sources whichever is not yet loaded.

_FM_COLD_CACHE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F fm_meta_get >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh
  . "$_FM_COLD_CACHE_LIB_DIR/fm-backend.sh"
fi
if ! declare -F fm_busy_record_idle_since >/dev/null 2>&1; then
  # shellcheck source=bin/fm-busy-lib.sh
  . "$_FM_COLD_CACHE_LIB_DIR/fm-busy-lib.sh"
fi
if ! declare -F last_status_line >/dev/null 2>&1; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "$_FM_COLD_CACHE_LIB_DIR/fm-classify-lib.sh"
fi
if ! declare -F fm_task_inbox_dir >/dev/null 2>&1; then
  # shellcheck source=bin/fm-task-inbox-lib.sh
  . "$_FM_COLD_CACHE_LIB_DIR/fm-task-inbox-lib.sh"
fi

FM_COLD_CACHE_DEFAULT_MINUTES=55

# fm_cold_cache_threshold_secs: the threshold in seconds, or `off`. A malformed
# config prints the reason on stderr and returns 2.
fm_cold_cache_threshold_secs() {  # <config-dir>
  local f="$1/cold-cache-minutes" v=''
  if [ ! -e "$f" ]; then
    printf '%s' "$((FM_COLD_CACHE_DEFAULT_MINUTES * 60))"
    return 0
  fi
  v=$(tr -d '[:space:]' < "$f" 2>/dev/null) || v=''
  case "$v" in
    off) printf 'off'; return 0 ;;
    '' | *[!0-9]* | 0 | 0*)
      echo "error: $f must hold a positive whole number of minutes or 'off', not '${v}'" >&2
      return 2
      ;;
  esac
  printf '%s' "$((v * 60))"
}

fm_cold_cache_kind_in_scope() {  # <meta-file>
  case "$(fm_meta_get "$1" kind)" in
    '' | ship | scout) return 0 ;;
  esac
  return 1
}

# fm_cold_cache_idle_secs: seconds since the task provably went idle; fails
# for every record that is not a valid idle one.
fm_cold_cache_idle_secs() {  # <state-dir> <id>
  local since now
  since=$(fm_busy_record_idle_since "$1" "$2") || return 1
  now=$(date +%s)
  [ "$now" -ge "$since" ] || return 1
  printf '%s' "$((now - since))"
}

# fm_cold_cache_is_cold: 0 and the idle seconds when the task is cold, 1 when
# it is not (or the policy is off), 2 when the threshold config is malformed.
fm_cold_cache_is_cold() {  # <config-dir> <state-dir> <id>
  local threshold idle
  threshold=$(fm_cold_cache_threshold_secs "$1") || return 2
  [ "$threshold" != off ] || return 1
  idle=$(fm_cold_cache_idle_secs "$2" "$3") || return 1
  [ "$idle" -gt "$threshold" ] || return 1
  printf '%s' "$idle"
}

fm_cold_cache_parked_path() {  # <state-dir> <id>
  printf '%s/%s.cold-parked' "$1" "$2"
}

fm_cold_cache_is_parked() {  # <state-dir> <id>
  [ -f "$(fm_cold_cache_parked_path "$1" "$2")" ]
}

fm_cold_cache_parked_field() {  # <state-dir> <id> <key>
  local line path
  path=$(fm_cold_cache_parked_path "$1" "$2")
  [ -f "$path" ] || return 1
  while IFS= read -r line; do
    case "$line" in "$3="*) printf '%s' "${line#"$3="}"; return 0 ;; esac
  done < "$path"
  return 1
}

# fm_cold_cache_declared_wait: 0 when the status event declares the worker is
# waiting for someone else rather than working.
fm_cold_cache_declared_wait() {  # <status-line>
  local verb
  status_line_verb "$1" verb
  case "$verb" in
    done | needs-decision | blocked | failed | \
      "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" | \
      "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}")
      return 0
      ;;
  esac
  return 1
}

fm_cold_cache_inbox_unread() {  # <state-dir> <id>
  local f
  for f in "$(fm_task_inbox_dir "$1" "$2")"/*.msg; do
    [ -e "$f" ] && return 0
  done
  return 1
}

# fm_cold_cache_park_check: 0 when the task may be parked now. Otherwise 1 with
# the reason on stdout, or 2 for a malformed threshold config.
fm_cold_cache_park_check() {  # <config-dir> <state-dir> <id>
  local config=$1 state=$2 id=$3 meta idle rc=0 last
  meta="$state/$id.meta"
  [ -f "$meta" ] || { printf 'no task record'; return 1; }
  fm_cold_cache_kind_in_scope "$meta" \
    || { printf 'kind %s is out of scope' "$(fm_meta_get "$meta" kind)"; return 1; }
  ! fm_cold_cache_is_parked "$state" "$id" || { printf 'already parked'; return 1; }
  [ -n "$(fm_meta_get "$meta" remote_host)" ] && { printf 'remotely placed'; return 1; }
  idle=$(fm_cold_cache_is_cold "$config" "$state" "$id") || rc=$?
  case "$rc" in
    0) ;;
    2) return 2 ;;
    *) printf 'not provably idle past the cold-cache threshold'; return 1 ;;
  esac
  last=$(last_status_line "$state/$id.status")
  fm_cold_cache_declared_wait "$last" \
    || { printf 'latest status is not a declared wait'; return 1; }
  ! fm_cold_cache_inbox_unread "$state" "$id" \
    || { printf 'an unread steering-inbox record is waiting'; return 1; }
  ! fm_cold_cache_relaunch_pending "$state" "$id" \
    || { printf 'a relaunch transaction is in progress'; return 1; }
  printf 'idle %ss' "$idle"
}

# fm_cold_cache_relaunch_pending: 0 when the task's relaunch journal
# (bin/fm-control.sh) records a transaction that neither completed nor failed.
# The journal outlives a finished relaunch, so its presence alone means nothing.
fm_cold_cache_relaunch_pending() {  # <state-dir> <id>
  local f="$1/$2.control-relaunch" line
  [ -e "$f" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      phase=complete | phase=failed:*) return 1 ;;
      phase=*) return 0 ;;
    esac
  done < "$f" 2>/dev/null
  return 0
}

# fm_cold_cache_note: the default progress note for a fresh replacement worker:
# where its instructions are, its last three status events, and the branch and
# commit its local copy holds. Facts only, so the note never claims progress
# the records do not show.
fm_cold_cache_note() {  # <state-dir> <data-dir> <id>
  local state=$1 data=$2 id=$3 meta wt branch head dirty status parked_at
  meta="$state/$id.meta"
  wt=$(fm_meta_get "$meta" worktree)
  status="$state/$id.status"
  printf 'This is a fresh session replacing an earlier worker on this task. Its conversation is gone; the local copy, its commits, and its uncommitted changes are all still here.\n'
  if parked_at=$(fm_cold_cache_parked_field "$state" "$id" parked_at); then
    printf 'The earlier worker was stopped on purpose at %s after a long idle wait, to save tokens. Nothing went wrong.\n' \
      "$(date -u -r "$parked_at" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$parked_at" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s' "$parked_at")"
  fi
  printf 'Instructions: %s\n' "$data/$id/brief.md"
  if [ -n "$wt" ] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch='(detached)'
    head=$(git -C "$wt" log -1 --format='%h %s' 2>/dev/null) || head='(no commit)'
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    printf 'Branch: %s\nHEAD: %s\nUncommitted paths: %s\n' "$branch" "$head" "$dirty"
  fi
  printf 'Last status events:\n'
  if [ -s "$status" ]; then
    grep -v '^[[:space:]]*$' "$status" | tail -n 3 | sed 's/^/  /'
  else
    printf '  (none)\n'
  fi
  printf 'Read the instructions, check the local copy, then continue from the latest status. Firstmate may send a follow-up message right after this one.\n'
}

# fm_cold_cache_write_note: write the default note to state/<id>.cold-relaunch-note
# and print that path, for a caller that hands it to `relaunch --note-file`.
fm_cold_cache_write_note() {  # <state-dir> <data-dir> <id>
  local path="$1/$3.cold-relaunch-note" tmp
  tmp="$path.tmp.$$"
  if ! fm_cold_cache_note "$1" "$2" "$3" > "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s' "$path"
}
