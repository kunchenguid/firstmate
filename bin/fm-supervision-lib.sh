# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work (a state/<id>.meta exists) or an X-mode relay poll
# (state/x-watch.check.sh), and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-guard.sh keeps its task-specific grace-based warning predicate;
# bin/fm-turnend-guard.sh uses the status fields here for its banner but performs
# its end-of-turn block decision with the live watcher lock check in
# bin/fm-wake-lib.sh.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# Print the first path that is a symlink or an existing non-directory, and
# succeed; fail when every path is an ordinary directory or absent. This is the
# shape bin/fm-procevent-lib.sh refuses (fm_procevent_state_paths_safe), spelled
# out here rather than sourced because callers copy and source this predicate on
# its own.
fm_sup_first_unsafe_path() {
  local path
  for path in "$@"; do
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources that this
#                         home actually holds - a source reached through a
#                         symlinked state or registry lives outside the home and
#                         is never this home's wait
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, or a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata)
#   FM_SUP_PROCEVENT_UNSAFE      true/false - state, state/procevent, or
#                         state/procevent-inbox is a symlink or a non-directory,
#                         so every process-event command that reaches that path
#                         refuses this home until an operator repairs it. The
#                         path is reported whichever leaf is damaged, because a
#                         home that can still be swept is not a home that can
#                         still serve its sources. Reported separately from the
#                         source count so a damaged home is loud rather than
#                         silent, and so an in-home source behind a damaged inbox
#                         still counts as this home's wait.
#   FM_SUP_PROCEVENT_UNSAFE_PATH the first such path, for an actionable banner
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  FM_SUP_PROCEVENT_UNSAFE=false
  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  FM_SUP_PROCEVENT_UNSAFE_PATH=
  if [ -n "$state" ]; then
    # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
    FM_SUP_PROCEVENT_UNSAFE_PATH=$(fm_sup_first_unsafe_path \
      "$state" "$state/procevent" "$state/procevent-inbox") \
      && FM_SUP_PROCEVENT_UNSAFE=true
    if [ -d "$state/procevent" ] \
      && ! fm_sup_first_unsafe_path "$state" "$state/procevent" >/dev/null; then
      for source in "$state"/procevent/*.source; do
        [ -e "$source" ] || continue
        FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
      done
    fi
  fi
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi

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

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
