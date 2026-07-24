# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# True exactly when a firstmate home has actively progressing work that still
# needs continuous live supervision, but no watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-guard.sh uses this grace-based warning predicate directly;
# bin/fm-turnend-guard.sh uses the status fields here for its banner but performs
# its end-of-turn block decision with the live watcher lock check in
# bin/fm-wake-lib.sh.
#
# FM_SUP_IN_FLIGHT counts only tasks that can still make autonomous progress
# (working / validating / fixing / just launched / unknown mid-work). Terminal,
# parked captain-decision, blocked, and declared-pause states do not force
# continuous foreground checkpoints; PR merge polls and other durable checks keep
# running through the existing watcher check path when supervision is live for
# active work or other reasons (X mode). Persistent secondmates are idle by
# default unless a parent request remains unresolved or their status shows live
# progress.

# Directory of this library (works when sourced from bin/ or tests/).
_FM_SUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_SUP_LIB_DIR="."

# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_SUP_LIB_DIR/fm-classify-lib.sh"

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_sup_meta_value <meta-file> <key>
# Last matching key= value from a task meta file (empty when absent).
fm_sup_meta_value() {
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^${key}=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_sup_secondmate_has_pending_reply() {
  local state=$1 id=$2 rec task_id phase
  for rec in "$state/pending-replies"/*; do
    [ -f "$rec" ] || continue
    task_id=$(fm_sup_meta_value "$rec" task_id)
    [ "$task_id" = "$id" ] || continue
    phase=$(fm_sup_meta_value "$rec" phase)
    [ "$phase" = resolved ] || return 0
  done
  return 1
}

# fm_sup_task_needs_live_supervision <state-dir> <task-id>
# Exit 0 when continuous live supervision is still required for this task.
# Cheap status-log / meta classification only (no pane or no-mistakes calls):
#   - kind=secondmate: yes only for unresolved parent replies or live status
#   - missing or empty status: yes for ordinary tasks, no for idle secondmates
#   - last verb working or resolved: yes (active or just resumed)
#   - last verb done, needs-decision, blocked, failed, paused, captain-held: no
#   - any other / unreadable last line: yes (fail closed toward supervision)
fm_sup_task_needs_live_supervision() {
  local state=$1 id=$2 meta status kind last verb
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1

  kind=$(fm_sup_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" = secondmate ] && fm_sup_secondmate_has_pending_reply "$state" "$id"; then
    return 0
  fi

  status="$state/$id.status"
  if [ ! -s "$status" ]; then
    [ "$kind" = secondmate ] && return 1
    return 0
  fi

  last=$(last_status_line "$status")
  if [ -z "$last" ]; then
    [ "$kind" = secondmate ] && return 1
    return 0
  fi

  if status_is_paused "$last" || status_is_paused_or_captain_held "$last"; then
    return 1
  fi

  verb=$(status_line_verb "$last")
  case "$verb" in
    working|resolved) return 0 ;;
    idle)
      [ "$kind" = secondmate ] && return 1
      return 0
      ;;
    done|needs-decision|blocked|failed) return 1 ;;
    *) return 0 ;;
  esac
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of tasks still needing continuous live supervision
#   FM_SUP_META_COUNT     count of all state/*.meta records (inventory size)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta beat m age id
  FM_SUP_IN_FLIGHT=0
  FM_SUP_META_COUNT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_META_COUNT=$((FM_SUP_META_COUNT + 1))
    id=$(basename "$meta" .meta)
    if fm_sup_task_needs_live_supervision "$state" "$id"; then
      FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
    fi
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: actively supervised work or a
# queued wake exists and no watcher has a fresh beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  { [ "$FM_SUP_IN_FLIGHT" -gt 0 ] || [ "$FM_SUP_QUEUE_PENDING" = true ]; } \
    && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
