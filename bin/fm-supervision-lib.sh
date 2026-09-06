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

_FM_SUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ONE owner for "how old is this file": fm_path_age in bin/fm-wake-lib.sh, which
# carries the contract that its result is always either a real non-negative
# base-10 age or the 999999 sentinel - never empty, negative, or non-numeric.
# This library is independently sourceable (tests source it alone), so it pulls
# that owner into scope rather than keeping a second copy of the same arithmetic
# that would have to be extended in lockstep.
#
# Loaded on first use rather than at source time, following the same deferred
# pattern bin/fm-wake-lib.sh uses for its own optional dependencies:
# bin/fm-wake-lib.sh runs `mkdir -p "$STATE"` when it is sourced, and
# bin/fm-turnend-guard.sh sources this library at its top but reads its hook
# payload, degrades without jq, stands down on a foreign host, and checks
# fm_primary_scope_matches - whose last arm is `[ -d "$state" ]` - before it ever
# calls fm_supervision_status.
#
# The ordering constraint that remains, stated rather than assumed away: a
# consumer that calls fm_supervision_status without bin/fm-wake-lib.sh already in
# scope loads it at that point, and takes that mkdir with it.
_fm_sup_require_age() {
  command -v fm_path_age >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_SUP_LIB_DIR/fm-wake-lib.sh"
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, or a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  _fm_sup_require_age
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source beat age
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
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    # Both the freshness verdict and the banner text come from the one contracted
    # read, so an unmeasurable beacon can neither pass as fresh nor be printed to
    # the captain as a duration that was actually observed. A beacon stamped in
    # the future is the case that matters: a raw subtraction made it read as
    # FRESH, and FM_SUP_WATCHER_FRESH gates the away-mode allow path in
    # bin/fm-turnend-guard.sh, so a blind turn end was allowed on an age that was
    # never measurable.
    age=$(fm_path_age "$beat")
    if [ "$age" = 999999 ]; then
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
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
