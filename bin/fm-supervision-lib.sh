# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has actionable
# active work or an X-mode relay poll
# (state/x-watch.check.sh), and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-guard.sh keeps its task-specific grace-based warning predicate;
# bin/fm-turnend-guard.sh uses the status fields here for its banner but performs
# its end-of-turn block decision with the live watcher lock check in
# bin/fm-wake-lib.sh.

_FM_SUPERVISION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_SUPERVISION_LIB_DIR="."
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_SUPERVISION_LIB_DIR/fm-crew-state.sh}"

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_sup_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_sup_current_state() {  # <id>
  local line state
  line=$("$FM_CREW_STATE_BIN" "$1" 2>/dev/null) || return 1
  case "$line" in state:*) ;; *) return 1 ;; esac
  state=${line#state: }
  printf '%s\n' "${state%% *}"
}

# Return true when one metadata record still needs primary supervision.
# Ordinary tasks stay active by default; only a trailing done event earns the
# bounded authoritative current-state read that can disprove completion.
# Secondmates are cheap to reconcile because fm-crew-state skips no-mistakes for
# them, and their canonical unknown/none state means the persistent endpoint is
# healthy and idle.
# Missing or malformed evidence remains active so supervision still fails closed.
fm_sup_meta_needs_supervision() {  # <state-dir> <meta>
  local state=$1 meta=$2 id kind last current
  id=${meta##*/}
  id=${id%.meta}
  kind=$(fm_sup_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship

  if [ "$kind" = secondmate ]; then
    current=$(fm_sup_current_state "$id") || return 0
    case "$current" in
      done|unknown) return 1 ;;
      *) return 0 ;;
    esac
  fi

  last=$(grep -v '^[[:space:]]*$' "$state/$id.status" 2>/dev/null | tail -1 || true)
  case "$last" in done:*) ;; *) return 0 ;; esac
  current=$(fm_sup_current_state "$id") || return 0
  case "$current" in
    done|unknown) return 1 ;;
    *) return 0 ;;
  esac
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of tasks that still need primary supervision
#   FM_SUP_NEEDED         true/false - in-flight work or an X-mode relay poll
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    fm_sup_meta_needs_supervision "$state" "$meta" || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] || [ -f "$state/x-watch.check.sh" ]; then
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
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
