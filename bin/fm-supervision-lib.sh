# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work (a state/<id>.meta exists) or an X-mode relay poll
# (state/x-watch.check.sh), and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, a
#                         registered event source, or a pending durable wake
#                         (a source is a wait on an external process, not a task,
#                         so it has no metadata)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
#   FM_SUP_CERTAIN        true/false - every demand-bearing state path was safely
#                         classifiable; uncertainty keeps FM_SUP_NEEDED true
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source path beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false
  FM_SUP_CERTAIN=true
  FM_SUP_SOURCES=0

  if [ -e "$state" ] || [ -L "$state" ]; then
    if [ ! -d "$state" ] || [ -L "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; then
      FM_SUP_CERTAIN=false
    else
      # Published task records use the non-hidden state/<id>.meta name. Spawn and
      # relaunch stage dot-prefixed .<id>.meta.* files before atomic publication,
      # so the glob deliberately excludes them. Record contents and endpoint
      # liveness do not affect demand: dead, stalled, and malformed published
      # tasks still need supervision.
      for meta in "$state"/*.meta; do
        [ -e "$meta" ] || [ -L "$meta" ] || continue
        if [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ]; then
          FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
        else
          FM_SUP_CERTAIN=false
        fi
      done

      path="$state/procevent"
      if [ -e "$path" ] || [ -L "$path" ]; then
        if [ ! -d "$path" ] || [ -L "$path" ] || [ ! -r "$path" ] || [ ! -x "$path" ]; then
          FM_SUP_CERTAIN=false
        else
          for source in "$path"/*.source; do
            [ -e "$source" ] || [ -L "$source" ] || continue
            if [ -f "$source" ] && [ ! -L "$source" ] && [ -r "$source" ]; then
              FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
            else
              FM_SUP_CERTAIN=false
            fi
          done
        fi
      fi

      path="$state/.wake-queue"
      if [ -e "$path" ] || [ -L "$path" ]; then
        if [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ]; then
          # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
          [ -s "$path" ] && FM_SUP_QUEUE_PENDING=true
        else
          FM_SUP_CERTAIN=false
        fi
      fi

      path="$state/x-watch.check.sh"
      if [ -e "$path" ] || [ -L "$path" ]; then
        if [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ]; then
          FM_SUP_NEEDED=true
        else
          FM_SUP_CERTAIN=false
        fi
      fi
    fi
  fi

  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ] \
    || [ "$FM_SUP_QUEUE_PENDING" = true ] \
    || [ "$FM_SUP_CERTAIN" = false ]; then
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
