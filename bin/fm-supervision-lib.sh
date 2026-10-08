# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision (fm_supervision_status
# below is the single owner of that condition set), and whether its watcher has
# a fresh liveness beacon (state/.last-watcher-beat, touched every poll cycle,
# within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_CHECKS         count of registered custom checks: a state/<id>.check.sh
#                         with the state/<id>.check-trust binding that
#                         bin/fm-check-register.sh writes. Task PR polls carry no
#                         such binding and are torn down with their task, and the
#                         relay shim keeps its own trust path, so neither counts
#                         here. Presence of the binding is the whole test: whether
#                         those bytes are still the registered ones is the check
#                         sweep's call at execution time, and a home whose check
#                         no longer validates needs the watcher precisely so the
#                         sweep can report the rejection instead of going quiet.
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata),
#                         or a registered custom check
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source check id beat m age
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
  FM_SUP_CHECKS=0
  for check in "$state"/*.check.sh; do
    [ -e "$check" ] || continue
    id=${check##*/}
    id=${id%.check.sh}
    if [ "$id" = x-watch ]; then
      continue
    fi
    [ -e "$state/$id.check-trust" ] || continue
    FM_SUP_CHECKS=$((FM_SUP_CHECKS + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ] \
    || [ "$FM_SUP_CHECKS" -gt 0 ]; then
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

# Build a content-sensitive snapshot of every inventory that contributes to
# FM_SUP_NEEDED or FM_SUP_QUEUE_PENDING.  Unlike fm_supervision_status, this
# helper fails when an inventory is unreadable or structurally unsafe; startup
# reservation must distinguish a proven idle home from one it merely failed to
# inspect.  Callers serialize the wake queue with its existing queue lock while
# taking the two snapshots below.
fm_supervision_inventory_snapshot() {  # <state-dir>
  local state=$1 path rel id kind digest listing
  [ -d "$state" ] && [ ! -L "$state" ] && [ -r "$state" ] && [ -x "$state" ] || return 1
  if [ -e "$state/procevent" ] || [ -L "$state/procevent" ]; then
    [ -d "$state/procevent" ] && [ ! -L "$state/procevent" ] \
      && [ -r "$state/procevent" ] && [ -x "$state/procevent" ] || return 1
  fi
  listing=$(
    set -o pipefail
    for path in "$state"/*.meta "$state"/*.check.sh "$state"/*.check-trust \
      "$state"/procevent/*.source "$state/.wake-queue"; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || exit 1
      rel=${path#"$state"/}
      if [[ "$rel" = *.meta ]]; then
        kind=meta
      elif [[ "$rel" = *.check.sh ]]; then
        id=${path##*/}
        id=${id%.check.sh}
        if [ "$id" != x-watch ] && [ ! -e "$state/$id.check-trust" ]; then
          continue
        fi
        kind=check
      elif [[ "$rel" = *.check-trust ]]; then
        id=${path##*/}
        id=${id%.check-trust}
        [ -e "$state/$id.check.sh" ] || continue
        kind=trust
      elif [[ "$rel" = procevent/*.source ]]; then
        kind=source
      elif [ "$rel" = .wake-queue ]; then
        kind=queue
      else
        exit 1
      fi
      digest=$(LC_ALL=C cksum < "$path" 2>/dev/null) || exit 1
      printf '%s\t%s\t%s\n' "$kind" "${path#"$state"/}" "$digest"
    done | LC_ALL=C sort
  ) || return 1
  printf '%s\n' "$listing"
}

# Strict reservation-time form of fm_supervision_status.  The ordinary helper
# stays always-zero for reporting callers; this form succeeds only when the
# inventories were readable and byte-stable around that status calculation.
# Sets FM_SUP_SNAPSHOT to the verified snapshot on success.
# shellcheck disable=SC2034 # Output global, read by strict reservation callers.
FM_SUP_SNAPSHOT=
fm_supervision_status_strict() {  # <state-dir> [grace-seconds]
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} before after
  FM_SUP_SNAPSHOT=
  before=$(fm_supervision_inventory_snapshot "$state") || return 1
  fm_supervision_status "$state" "$grace"
  after=$(fm_supervision_inventory_snapshot "$state") || return 1
  [ "$before" = "$after" ] || return 1
  # shellcheck disable=SC2034 # Output global, read by strict reservation callers.
  FM_SUP_SNAPSHOT=$after
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
