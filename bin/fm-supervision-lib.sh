# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision (fm_supervision_status
# below is the single owner of that condition set), and whether its watcher has
# a fresh liveness beacon (state/.last-watcher-beat, touched every poll cycle,
# within the grace window). fm_supervision_home_verdict lets a primary judge
# ANOTHER home's supervision from the outside (its session lock, startup
# completion, and beacon), which is what detects a secondmate that is alive but
# unsupervised after a restart.
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

FM_SUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fm_sup_endpoint_agent_age <endpoint-pid>: seconds since the endpoint's
# current agent started - the youngest of <endpoint-pid> itself and each
# verified harness process in its subtree with no harness among its ancestors
# below <endpoint-pid> (the
# classifier in bin/fm-agent-process-lib.sh), so a relaunch typed into a
# long-lived pane shell is measured from its new agent, while an old agent's
# own tool or MCP children never make it look young. Ages come from the
# portable `ps -o etime=` ([[dd-]hh:]mm:ss). Fails when the endpoint pid is
# gone or the process table is unreadable.
fm_sup_endpoint_agent_age() {
  local root=$1 rows pid ppid secs name args argv0 agents=' ' parents=' ' up age=''
  if ! command -v fm_agent_process_classify >/dev/null 2>&1; then
    # shellcheck source=bin/fm-agent-process-lib.sh
    . "$FM_SUP_LIB_DIR/fm-agent-process-lib.sh"
  fi
  rows=$(LC_ALL=C ps -axo pid=,ppid=,etime=,comm= 2>/dev/null) || return 1
  rows=$(printf '%s\n' "$rows" | awk -v root="$root" '
    {
      pid[NR] = $1; ppid[NR] = $2
      etime = $3
      days = 0
      if (index(etime, "-")) { days = substr(etime, 1, index(etime, "-") - 1); etime = substr(etime, index(etime, "-") + 1) }
      k = split(etime, part, ":")
      secs[NR] = 0
      for (i = 1; i <= k; i++) secs[NR] = secs[NR] * 60 + part[i]
      secs[NR] += days * 86400
      line = $0
      sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9:-]+[ \t]+/, "", line)
      comm[NR] = line
    }
    END {
      want[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (n = 1; n <= NR; n++) {
          if ((ppid[n] in want) && !(pid[n] in want)) { want[pid[n]] = 1; changed = 1 }
        }
      }
      for (n = 1; n <= NR; n++) {
        if (pid[n] in want) { printf "%s\t%s\t%s\t%s\n", pid[n], ppid[n], secs[n], comm[n]; found = 1 }
      }
      exit(found ? 0 : 1)
    }') || return 1
  while IFS=$'\t' read -r pid ppid secs name; do
    [ "$pid" != "$root" ] || continue
    parents="$parents$pid:$ppid "
    args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
    args=${args#"${args%%[![:space:]]*}"}
    argv0=${args%%[[:space:]]*}
    [ "$(fm_agent_process_classify "$name" "$argv0" "$args" "$pid")" != agent ] || agents="$agents$pid "
  done <<EOF
$rows
EOF
  while IFS=$'\t' read -r pid ppid secs name; do
    case "$secs" in ''|*[!0-9]*) continue ;; esac
    if [ "$pid" != "$root" ]; then
      case "$agents" in *" $pid "*) ;; *) continue ;; esac
      up=$ppid
      while [ "$up" != "$root" ]; do
        case "$agents" in *" $up "*) continue 2 ;; esac
        case "$parents" in *" $up:"*) ;; *) break ;; esac
        up=${parents##*" $up:"}
        up=${up%% *}
      done
    fi
    if [ -z "$age" ] || [ "$secs" -lt "$age" ]; then age=$secs; fi
  done <<EOF
$rows
EOF
  [ -n "$age" ] || return 1
  printf '%s\n' "$age"
}

# fm_supervision_home_verdict <home> [grace-seconds] [endpoint-pid] [harness]
# The cross-home supervision check a primary can run against a secondmate home
# it does not itself occupy: a home is supervised only when its session lock
# names a live harness process, its startup completion record names that same
# pid, and - when the home actually needs a watcher - its beacon is fresh.
# Endpoint liveness cannot decide this, because the leaked/restored session this
# predicate exists to catch has a genuinely running agent. Sets
# FM_SUP_HOME_OK=yes|no|starting and, on no or starting, FM_SUP_HOME_REASON to
# a short cause. starting means that home's own session start may still be
# running, so it is neither healthy nor a reason to relaunch: either the live
# lock is younger than the session-start runtime bound (FM_SESSION_START_TIMEOUT,
# default 120s) with no completion yet, or the lock is absent or names a dead
# pid while the agent on the endpoint-pid process (the secondmate's backend
# endpoint, see fm_backend_endpoint_pid; aged by fm_sup_endpoint_agent_age) is
# younger than that same bound - a freshly restored or relaunched agent that has
# not reached its own lock yet. Past that bound the same shapes
# are failures. The watcher leg is fm_watcher_supervision_verdict (from
# bin/fm-wake-lib.sh, which the caller has loaded) on that home's own state and
# root under the supervision model of <harness>, its recorded harness, so a
# Claude mate mid-turn under auto-arm is judged exactly as its own pull guard
# judges it; only its stale-beacon verdict fails, because this check samples the
# home at arbitrary times and a fresh beacon with no watcher process is an
# ordinary handling turn. Always returns 0; the caller reads the vars. An unreadable or
# absent home is a failure with its own reason, never treated as healthy.
# shellcheck disable=SC2034  # FM_SUP_HOME_OK/FM_SUP_HOME_REASON are read by callers after the call.
fm_supervision_home_verdict() {
  local home=$1 grace=${2:-${FM_GUARD_GRACE:-300}} endpoint_pid=${3:-} harness=${4:-unknown}
  local lock_pid complete_pid model
  local start_bound=${FM_SESSION_START_TIMEOUT:-120} lock_mtime endpoint_age=''
  FM_SUP_HOME_OK=no
  FM_SUP_HOME_REASON=""
  if [ -z "$home" ] || [ ! -d "$home/state" ]; then
    FM_SUP_HOME_REASON="its own state directory is unreadable"
    return 0
  fi
  if ! command -v fm_harness_pid_alive >/dev/null 2>&1; then
    # shellcheck source=bin/fm-session-lock-lib.sh
    . "$FM_SUP_LIB_DIR/fm-session-lock-lib.sh"
  fi
  case "$start_bound" in ''|*[!0-9]*) start_bound=120 ;; esac
  [ "$start_bound" -gt 0 ] || start_bound=120
  lock_pid=$(cat "$home/state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*)
      FM_SUP_HOME_REASON="its own session lock is absent or malformed"
      ;;
    *)
      fm_harness_pid_alive "$lock_pid" \
        || FM_SUP_HOME_REASON="its own session lock names pid $lock_pid, which is not a live harness"
      ;;
  esac
  if [ -n "$FM_SUP_HOME_REASON" ]; then
    case "$endpoint_pid" in
      ''|*[!0-9]*) ;;
      *) endpoint_age=$(fm_sup_endpoint_agent_age "$endpoint_pid") || endpoint_age='' ;;
    esac
    if [ -n "$endpoint_age" ] && [ "$endpoint_age" -lt "$start_bound" ]; then
      FM_SUP_HOME_OK=starting
      FM_SUP_HOME_REASON="its endpoint agent started ${endpoint_age}s ago and its own session start has not taken its lock yet"
    fi
    return 0
  fi
  complete_pid=$(cat "$home/state/.session-start-complete" 2>/dev/null || true)
  if [ "$complete_pid" != "$lock_pid" ]; then
    lock_mtime=$(fm_sup_stat_mtime "$home/state/.lock")
    case "$lock_mtime" in
      ''|*[!0-9]*) ;;
      *)
        if [ $(( $(date +%s) - lock_mtime )) -lt "$start_bound" ]; then
          FM_SUP_HOME_OK=starting
          FM_SUP_HOME_REASON="its own session start is still in progress for live lock pid $lock_pid"
          return 0
        fi
        ;;
    esac
    FM_SUP_HOME_REASON="its own startup completion is not recorded for live lock pid $lock_pid"
    return 0
  fi
  # A secondmate with no in-flight work, relay poll, registered source, or
  # registered custom check legitimately holds its lock with no fresh beacon.
  fm_supervision_status "$home/state" "$grace"
  if [ "$FM_SUP_NEEDED" = true ]; then
    model=$(fm_supervision_model "$harness")
    FM_SUPERVISION_MODEL=$model fm_watcher_supervision_verdict \
      "$home/state" "$home/bin/fm-watch.sh" "$grace" "$home" "$home"
    if [ "$FM_WATCHER_VERDICT_OK" != true ] && [ "$FM_WATCHER_VERDICT_REASON" = stale-beacon ]; then
      FM_SUP_HOME_REASON="its watcher beacon is ${FM_SUP_BEACON_DESC} while supervision is required"
      return 0
    fi
  fi
  FM_SUP_HOME_OK=yes
  return 0
}
