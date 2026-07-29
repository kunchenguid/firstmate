# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work (a state/<id>.meta exists), an X-mode relay poll
# (state/x-watch.check.sh), or an enabled Telegram topic board or direct-message
# line, and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-guard.sh keeps its task-or-Telegram grace-based warning predicate;
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

# fm_supervision_status <state-dir> [grace-seconds] [home-dir]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_TOPIC_BOARD    true/false - a local topic-board or direct-message-line credential file exists (both demand a live watcher; docs/dm-line.md)
#   FM_SUP_REQUIRED       true/false - work or Telegram intake needs a live watcher
#   FM_SUP_NEEDED         true/false - required supervision or an X-mode relay poll
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} home=${3:-${FM_HOME:-}} meta beat m age data config
  [ -n "$home" ] || home=$(dirname "$state")
  FM_SUP_IN_FLIGHT=0
  FM_SUP_TOPIC_BOARD=false
  FM_SUP_REQUIRED=false
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  data=${FM_TOPIC_DATA_DIR:-$home/data/fm-telegram-topics}
  if [ -n "${FM_TOPIC_CONFIG:-}" ]; then
    config=$FM_TOPIC_CONFIG
  elif [ -f "$data/config.env" ]; then
    config="$data/config.env"
  else
    config="$data/test-bot-token.txt"
  fi
  if [ -f "$config" ] && [ ! -L "$config" ]; then
    FM_SUP_TOPIC_BOARD=true
  fi
  # The direct-message line's wakes ride the same queue key, so its enabled
  # credential file creates the identical supervision demand.
  config="${FM_DM_DATA_DIR:-$home/data/fm-telegram-dm}/config.env"
  if [ -f "$config" ] && [ ! -L "$config" ]; then
    FM_SUP_TOPIC_BOARD=true
  fi
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] || [ "$FM_SUP_TOPIC_BOARD" = true ]; then
    FM_SUP_REQUIRED=true
  fi
  if [ "$FM_SUP_REQUIRED" = true ] || [ -f "$state/x-watch.check.sh" ]; then
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
# Exit 0 (true) exactly when in-flight work or an X-mode relay poll needs a
# watcher. Exit 1 (false) for an idle home.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: supervision is required and no
# watcher has a fresh beacon.
# Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_REQUIRED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
