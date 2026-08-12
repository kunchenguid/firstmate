# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision because it has in-flight
# work (a state/<id>.meta exists, except a positively established idle
# secondmate) or an X-mode relay poll (state/x-watch.check.sh), and whether its
# watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh): under the Claude
# Stop auto-arm model, where the watcher only runs between turns, a fresh beacon
# with no live watcher is healthy; under persistent-watcher harnesses a live
# identity-matched watcher is still required. The status fields here retain the
# beacon-age details used in their messages.

# shellcheck source=bin/fm-classify-lib.sh
_FM_SUPERVISION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_SUPERVISION_LIB_DIR="."
. "$_FM_SUPERVISION_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-status-lib.sh
. "$_FM_SUPERVISION_LIB_DIR/fm-status-lib.sh"

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds] [read-only]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of tasks that need a watcher; positively idle
#                         secondmates are excluded so caller banners are truthful
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, or a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
#
# A persistent secondmate is idle only after durable parent evidence positively
# establishes it: a parseable resting status with no open keyed activity or
# decision, and no open parent pending-reply record. Any unreadable, missing, or
# ambiguous evidence returns true from fm_sup_secondmate_needs_supervision, so
# the caller keeps a watcher rather than guessing from a quiet endpoint.
fm_sup_pending_reply_task_has_open() {  # <state-dir> <task-id>
  local state=$1 task_id=$2 dir rec line rec_task phase task_fields phase_fields
  dir="$state/pending-replies"
  [ -e "$dir" ] || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || return 0
  for rec in "$dir"/*; do
    [ -e "$rec" ] || continue
    [ -f "$rec" ] && [ ! -L "$rec" ] && [ -r "$rec" ] || return 0
    rec_task=
    phase=
    task_fields=0
    phase_fields=0
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        task_id=*)
          task_fields=$((task_fields + 1))
          rec_task=${line#task_id=}
          ;;
        phase=*)
          phase_fields=$((phase_fields + 1))
          phase=${line#phase=}
          ;;
      esac
    done < "$rec" || return 0
    [ "$task_fields" -eq 1 ] && [ "$phase_fields" -eq 1 ] || return 0
    [ -n "$rec_task" ] && [ -n "$phase" ] || return 0
    [ "$rec_task" = "$task_id" ] || continue
    [ "$phase" = resolved ] || return 0
  done
  return 1
}

# Reconcile decision-fold process debt for a resting secondmate.
#
# The authoritative status fold intentionally keeps needs-decision and blocked
# records open until a matching resolved/captain-held record exists.  Supervision
# has a narrower concern: a secondmate that subsequently reports a terminal
# state is not waiting for the parent to act.  Append the missing resolutions
# here, at the supervision predicate boundary, without changing that shared fold
# contract for any other consumer.
fm_sup_reconcile_secondmate_ghost_decisions() {  # <status-file>
  local status=$1 last verb decisions line key rc=0 snapshot_bytes heal_id payload='' delta before='' seen=0
  [ -f "$status" ] && [ ! -L "$status" ] && [ -r "$status" ] || return 1
  fm_status_lock_acquire "$status" || return 1
  snapshot_bytes=$(LC_ALL=C wc -c < "$status" | tr -d ' ') || {
    fm_status_lock_release "$status"
    return 1
  }
  case "$snapshot_bytes" in ''|*[!0-9]*) fm_status_lock_release "$status"; return 1 ;; esac
  last=$(last_status_line "$status")
  verb=$(status_line_verb "$last")
  case "$verb" in
    done|resolved|captain-held) ;;
    *) fm_status_lock_release "$status"; return 0 ;;
  esac
  decisions=$(status_open_decisions "$status")
  [ -n "$decisions" ] || { fm_status_lock_release "$status"; return 0; }
  heal_id="${BASHPID:-$$}-$(date +%s)-$snapshot_bytes"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%$'\t'*}
    if [ "$key" = default ]; then
      payload="${payload}resolved: terminal $verb closed an earlier decision [heal=$heal_id]"$'\n'
    else
      payload="${payload}resolved [key=$key]: terminal $verb closed an earlier decision [heal=$heal_id]"$'\n'
    fi
  done <<EOF
$decisions
EOF
  printf '%s' "$payload" >> "$status" || rc=1
  if [ "$rc" -eq 0 ]; then
    delta=$(tail -c "+$((snapshot_bytes + 1))" "$status") || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *"[heal=$heal_id]") seen=1 ;;
        *) [ "$seen" -eq 1 ] || before="${before}${line}"$'\n' ;;
      esac
    done <<EOF
$delta
EOF
    [ "$seen" -eq 1 ] || rc=1
  fi
  if [ "$rc" -eq 0 ] && [ -n "$before" ]; then
    printf '%s' "$before" >> "$status" || rc=1
  fi
  fm_status_lock_release "$status"
  return "$rc"
}

fm_sup_secondmate_needs_supervision() {  # <state-dir> <task-id> [read-only]
  local state=$1 task_id=$2 read_only=${3:-0} status line prefix rest token verb key corr saw=0 decisions activities last have_key=0 have_corr=0
  status="$state/$task_id.status"
  [ -f "$status" ] && [ ! -L "$status" ] && [ -r "$status" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "${line//[[:space:]]/}" ] || continue
    case "$line" in *:*) ;; *) return 0 ;; esac
    prefix=${line%%:*}
    prefix=${prefix#"${prefix%%[![:space:]]*}"}
    prefix=${prefix%"${prefix##*[![:space:]]}"}
    verb=$(status_line_verb "$line")
    case "$verb" in
      working|done|needs-decision|blocked|failed|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
        ;;
      *) return 0 ;;
    esac
    key=$(_fm_decision_key "$line") || return 0
    [ -n "$key" ] || return 0
    have_key=0
    have_corr=0
    case "$prefix" in
      "$verb") ;;
      "$verb"[[:space:]]*)
        # The only permitted prefix decorations are one decision key and one
        # routed-request correlation id, in either order.  Keep this parser
        # deliberately stricter than status_line_verb: idle is an affirmative
        # safety conclusion, so malformed or duplicate tokens stay watched.
        rest=${prefix#"$verb"}
        rest=${rest#"${rest%%[![:space:]]*}"}
        while [ -n "$rest" ]; do
          token=${rest%%[[:space:]]*}
          case "$token" in
            \[key=*\])
              [ "$have_key" = 0 ] || return 0
              [ "$token" = "[key=$key]" ] || return 0
              have_key=1
              ;;
            \[corr=*\])
              [ "$have_corr" = 0 ] || return 0
              corr=${token#\[corr=}
              corr=${corr%\]}
              case "$corr" in
                [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
                *) return 0 ;;
              esac
              have_corr=1
              ;;
            *) return 0 ;;
          esac
          rest=${rest#"$token"}
          rest=${rest#"${rest%%[![:space:]]*}"}
        done
        ;;
      *) return 0 ;;
    esac
    saw=1
  done < "$status" || return 0
  [ "$saw" = 1 ] || return 0

  last=$(last_status_line "$status")
  case "$(status_line_verb "$last")" in
    done|resolved|captain-held) ;;
    *) return 0 ;;
  esac
  if [ "$read_only" != 1 ]; then
    fm_sup_reconcile_secondmate_ghost_decisions "$status" || return 0
  fi
  decisions=$(status_open_decisions "$status")
  [ -z "$decisions" ] || return 0
  activities=$(status_open_activities "$status")
  [ -z "$activities" ] || return 0
  fm_sup_pending_reply_task_has_open "$state" "$task_id" && return 0
  return 1
}

fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} read_only=${3:-0} meta source beat m age task_id
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    if grep -qx 'kind=secondmate' "$meta" 2>/dev/null; then
      task_id=$(basename "$meta")
      task_id=${task_id%.meta}
      fm_sup_secondmate_needs_supervision "$state" "$task_id" "$read_only" || continue
    fi
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

# fm_supervision_needed <state-dir> [grace-seconds] [read-only]
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
