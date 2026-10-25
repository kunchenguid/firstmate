#!/usr/bin/env bash
# Waiting-state timers, called once per fm-watch.sh poll, independent of pane
# churn, busy proofs, and stale/wedge suppression. Configuration and defaults:
# docs/configuration.md "Waiting-state escalation".
# Each recorded task owns one durable episode under state/.waiting-timers/.
# The effective declaration is an own open blocker/decision, else a declared
# pause. Admitted Herdr agent.list blocked overrides it immediately, scoped to
# recorded panes only (admission policy: configuration reference above).
# Time starts at first observation and survives watcher restarts.
# Changing state/declaration/endpoint clears and re-arms the episode; a paused
# episode instead keys on window, verb and phase key, so reason-text churn on
# the same pause re-arms nothing. A paused wait rechecks at the
# FM_PAUSE_RESURFACE_SECS cadence, never the owner-alert threshold. Parent
# reports use the existing local/remote parent channel, never a captain alert.
# An episode key is waiting-timer-<home>-<task>-g<generation>-<source key>, so a
# resolution names exactly one wait and every report prints its unresolved source.
# A waiting-timer-* key belongs to this library; it resolves that report when
# the episode ends. Main has no parent: its overdue wait gets one escalation wake
# to Main itself, and any human escalation beyond that is judgment.
# Source through fm-watch.sh; the wake library supplies hashing and wake emission.

# Sibling libraries live in the fork's bin/, not beside this add-on file.
_FM_WAIT_TIMER_DIR="${SCRIPT_DIR:-${FM_PUSH_TRANSITION_LIB_DIR:-$FM_HOME/bin}}"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_WAIT_TIMER_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_FM_WAIT_TIMER_DIR/fm-timeout-lib.sh"

fm_wait_timer_save() {  # <record> <signature> <since> <owner> <parent> <key> <misses>
  local file=$1 temp="${1%/*}/.${1##*/}.tmp.$$"
  shift
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" > "$temp" && mv "$temp" "$file"
}

# Stable episode identity: home, task, generation (the arming second) and the
# source key, so a resolution matches only the wait it names and an unrelated
# open decision or a re-armed episode never shares a key.
fm_wait_timer_key() {  # <task> <generation> <source-key>
  local home src
  home=$(printf '%s' "$FM_HOME" | hash_pane) || return 1
  src=$(printf '%s' "${3:-unkeyed}" | tr -c 'A-Za-z0-9._-' '_')
  printf 'waiting-timer-%s-%s-g%s-%s' "${home:0:8}" "$1" "$2" "${src:0:48}"
}

fm_wait_timer_report() {  # <status-line>
  local rc=0
  fm_parent_channel_report "$FM_HOME" "$STATE" "$1" || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "waiting timers: parent channel publication failed (code $rc; inspect identity/binding or destination permissions)" >&2
    return 1
  }
}

fm_wait_timer_owner_delivered() {
  [ "$1" -eq 0 ] || return 0
  fm_wait_timer_save "$FM_WAIT_OWNER_RECORD" "$FM_WAIT_OWNER_SIGNATURE" "$FM_WAIT_OWNER_SINCE" "$(date +%s)" 0 "$FM_WAIT_OWNER_KEY" 0
}

# An immediate native push wake already told the owner about this blocked pane,
# so the episode records that delivery and the poll timer skips its owner wake.
fm_wait_timer_push_delivered() {  # <task> <window>
  local record="$STATE/.waiting-timers/$1" signature now old since owner parent key misses
  now=$(date +%s) || return 1
  signature=$(printf '%s' "$2|herdr-blocked" | hash_pane)
  if [ -e "$record" ] || [ -L "$record" ]; then
    [ -f "$record" ] && [ ! -L "$record" ] || return 1
    IFS=$'\t' read -r old since owner parent key misses < "$record" || return 1
    if [ "$old" = "$signature" ]; then
      [ "$owner" -eq 0 ] || return 0
      fm_wait_timer_save "$record" "$signature" "$since" "$now" "$parent" "$key" 0
      return
    fi
    if [ "$parent" -eq 1 ] && [ -e "$FM_HOME/.fm-secondmate-home" ]; then
      fm_wait_timer_report "resolved [key=$key]: waiting-timer-cleared: $1 changed state" || return 0
    fi
  fi
  mkdir -p "$STATE/.waiting-timers" || return 1
  fm_wait_timer_save "$record" "$signature" "$now" "$now" 0 "$(fm_wait_timer_key "$1" "$now" herdr-blocked)" 0
}

fm_wait_timers_tick() {
  local alert=${FM_WAIT_ALERT_SECS:-300} escalate=${FM_WAIT_ESCALATE_SECS:-900}
  local paused_alert=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
  local meta task backend window session native sessions='|' blocked='|' unknown='|' rows actor=Main
  local dir="$STATE/.waiting-timers" now record declaration verb signature old since owner parent key misses age reason until bound rc
  local pause_key threshold dkey src source
  for native in "$alert" "$escalate"; do
    case "$native" in ''|*[!0-9]*|0* ) echo "waiting timers: thresholds must be positive decimal seconds" >&2; return 1 ;; esac
    [ "${#native}" -le 9 ] || { echo "waiting timers: threshold exceeds nine digits" >&2; return 1; }
  done
  [ "$escalate" -gt "$alert" ] || { echo "waiting timers: escalation must be later than owner alert" >&2; return 1; }
  now=$(date +%s) || return 1
  [ ! -e "$FM_HOME/.fm-secondmate-home" ] || actor='owning lead'
  # One bounded native read per recorded session, not one per lane. A session whose
  # read fails is unknown for this poll: its lanes keep their episodes untouched
  # while every other lane is still monitored.
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    backend=$(fm_meta_get "$meta" backend)
    [ "$backend" = herdr ] || continue
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] || continue
    fm_backend_source herdr || return 1
    fm_backend_herdr_parse_target "$window" || continue
    session=$FM_BACKEND_HERDR_SESSION
    case "$sessions" in *"|$session|"*) continue ;; esac
    sessions="$sessions$session|"
    bound=$FM_BACKEND_HERDR_READ_TIMEOUT
    case "$bound" in ''|0*|*[!0-9]*) echo "waiting timers: native read timeout must be positive decimal seconds" >&2; return 1 ;; esac
    [ "${#bound}" -le 9 ] || return 1
    # shellcheck disable=SC2016 # The child shell expands its positional parameters.
    if native=$(fm_run_timed "$bound" bash -c '
      . "$1"
      fm_backend_source herdr || exit 1
      FM_BACKEND_HERDR_TIMEOUT= fm_backend_herdr_cli "$2" agent list
    ' fm-wait-native "$_FM_WAIT_TIMER_DIR/fm-backend.sh" "$session"); then
      :
    else
      rc=$?
      echo "waiting timers: agent list for $session failed (code $rc, deadline ${bound}s); its lanes are unknown this poll" >&2
      unknown="$unknown$session|"
      continue
    fi
    rows=$(printf '%s' "$native" | jq -er '
      if (.result.agents | type) != "array" then error("agent.list missing agents array")
      else [.result.agents[] | select(.agent_status == "blocked") |
        if (.pane_id | type) == "string" then .pane_id else error("blocked agent missing pane_id") end] | join("\n") end') || {
      echo "waiting timers: agent list for $session is malformed; its lanes are unknown this poll" >&2
      unknown="$unknown$session|"
      continue
    }
    while IFS= read -r window; do
      [ -z "$window" ] || blocked="$blocked$session:$window|"
    done <<EOF
$rows
EOF
  done
  # Removed tasks also end their parent report, even when cleanup removed the
  # status log and metadata before the next poll.
  for record in "$dir"/*; do
    [ -f "$record" ] || continue
    task=${record##*/}
    [ ! -L "$record" ] || { echo "waiting timers: symlink episode $record" >&2; return 1; }
    [ ! -f "$STATE/$task.meta" ] || continue
    IFS=$'\t' read -r old since owner parent key misses < "$record" || return 1
    if [ "$parent" = 1 ] && [ -e "$FM_HOME/.fm-secondmate-home" ]; then
      fm_wait_timer_report "resolved [key=$key]: waiting-timer-cleared: $task removed" || continue
    fi
    rm -f "$record" || return 1
  done
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}; task=${task%.meta}
    _fm_parent_channel_id_valid "$task" || { echo "waiting timers: invalid task id in $meta" >&2; return 1; }
    window=$(fm_backend_target_of_meta "$meta")
    if [ "$(fm_backend_of_meta "$meta")" = herdr ]; then
      case "$unknown" in *"|${window%%:*}|"*) continue ;; esac
    fi
    declaration=''; dkey=''
    if [ "$(fm_meta_get "$meta" harness)" != cursor ]; then
      case "$blocked" in
        *"|$window|"*) [ -z "$window" ] || declaration=herdr-blocked ;;
      esac
    fi
    if [ -z "$declaration" ]; then
      rows=$(status_own_open_decisions "$STATE/$task.status")
      while IFS=$'\t' read -r old verb native; do
        case "$verb" in blocked|needs-decision) declaration="$verb [key=$old]: $native"; dkey=$old ;; esac
      done <<EOF
$rows
EOF
      [ -n "$declaration" ] || declaration=$(status_declared_wait_line "$STATE/$task.status")
      status_is_paused "$declaration" || case "$declaration" in blocked*|needs-decision*) ;; *) declaration='' ;; esac
    fi
    if status_is_paused "$declaration" && until=$(status_paused_until "$declaration") && [ "$now" -lt "$until" ]; then
      declaration=''
    fi
    # A captain hold waits on the captain, so a held lane never arms an episode.
    # Checked before the record is read: a check made only once an episode is due
    # would clear it and let the still-declared wait re-arm it on the next poll.
    if [ -n "$declaration" ] && task_captain_call_open "$task"; then
      declaration=''
    fi
    record="$dir/$task"
    src=$dkey
    if [ -z "$src" ] && status_is_paused "$declaration"; then src=$(_fm_decision_key "$declaration") || src=default; fi
    [ "$declaration" != herdr-blocked ] || src=herdr-blocked
    old=''; since=$now; owner=0; parent=0; misses=0; key=$(fm_wait_timer_key "$task" "$now" "$src") || return 1
    if [ -e "$record" ] || [ -L "$record" ]; then
      [ -f "$record" ] && [ ! -L "$record" ] || { echo "waiting timers: invalid episode $record" >&2; return 1; }
      IFS=$'\t' read -r old since owner parent key misses < "$record" || return 1
      case "$since:$owner:$parent:$key" in
        *[!0-9A-Za-z._:-]*) echo "waiting timers: corrupt episode $record" >&2; return 1 ;;
      esac
      case "$since" in ''|*[!0-9]*) echo "waiting timers: invalid episode time $record" >&2; return 1 ;; esac
      [ "${#since}" -le 12 ] && [ -n "$key" ] || { echo "waiting timers: corrupt episode identity $record" >&2; return 1; }
      case "$owner" in ''|*[!0-9]*) echo "waiting timers: invalid owner time $record" >&2; return 1 ;; esac
      [ "${#owner}" -le 12 ] || return 1
      case "$parent" in 0|1) ;; *) echo "waiting timers: invalid episode levels $record" >&2; return 1 ;; esac
      misses=${misses:-0}
      case "$misses" in 0|1) ;; *) echo "waiting timers: invalid episode misses $record" >&2; return 1 ;; esac
      if [ "$owner" -eq 1 ]; then owner=0; fi
    fi
    if status_is_paused "$declaration"; then
      # A paused episode keys on window, verb and phase key, not the full
      # declaration line: a worker refreshing its pause prose (or the [at=]
      # stamp moving) is the same wait, so its original observation time and
      # the one owner recheck per episode survive the rewrite. A different
      # phase key is a different wait and re-arms.
      pause_key=$(_fm_decision_key "$declaration") || pause_key=default
      signature=$(printf '%s' "$window|$(status_line_verb "$declaration")|$pause_key" | hash_pane)
    else
      signature=$(printf '%s' "$window|$declaration" | hash_pane)
    fi
    age=$((now - since))
    if [ -z "$declaration" ] && [ -n "$old" ] && [ "$misses" -eq 0 ]; then
      fm_wait_timer_save "$record" "$old" "$since" "$owner" "$parent" "$key" 1 || return 1
      continue
    fi
    if [ -z "$declaration" ] || [ "$old" != "$signature" ]; then
      if [ "$parent" -eq 1 ] && [ -e "$FM_HOME/.fm-secondmate-home" ]; then
        fm_wait_timer_report "resolved [key=$key]: waiting-timer-cleared: $task changed state" || continue
      fi
      rm -f "$record" || return 1
      [ -n "$declaration" ] || continue
      since=$now; owner=0; parent=0; misses=0; key=$(fm_wait_timer_key "$task" "$now" "$src") || return 1
      mkdir -p "$dir" || return 1
      fm_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" || return 1
    elif [ "$misses" -ne 0 ]; then
      misses=0
      fm_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" || return 1
    fi
    age=$((now - since))
    verb=$(status_line_verb "$declaration")
    [ "$declaration" != herdr-blocked ] || verb=herdr-blocked
    # An open decision names its key so the recipient clears the right one.
    [ -z "$dkey" ] || verb="$verb key=$dkey"
    # A declared pause is an expected wait, so its owner recheck rides the
    # FM_PAUSE_RESURFACE_SECS cadence (the same bound the stale path uses),
    # never the blocked/decision owner-alert threshold.
    # Every report prints the exact unresolved source, not just the episode.
    source=$(printf '%s' "$declaration" | tr '\t\n' '  ' | cut -c1-160)
    threshold=$alert
    status_is_paused "$declaration" && threshold=$paused_alert
    if [ "$age" -ge "$threshold" ] && [ "$owner" -eq 0 ]; then
      reason="check: waiting-state $task ($verb, observed ${age}s, level=owner; $actor must recheck and unblock) id=$key source=[$source]"
      if ! fm_wake_queued_keys check | grep -Fx "$key-owner" >/dev/null; then
        fm_wake_append check "$key-owner" "$reason" || return 1
      fi
      FM_WAIT_OWNER_RECORD=$record
      FM_WAIT_OWNER_SIGNATURE=$signature
      FM_WAIT_OWNER_SINCE=$since
      FM_WAIT_OWNER_KEY=$key
      # shellcheck disable=SC2034 # Consumed by wake() in fm-push-transition-lib.sh.
      FM_WAKE_POST_OUTPUT_ACTION=fm_wait_timer_owner_delivered
      wake "$reason"
    fi
    if ! status_is_paused "$declaration" && [ "$owner" -gt 1 ] && [ "$((now - owner))" -ge "$((escalate - alert))" ] && [ "$parent" -eq 0 ]; then
      if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
        fm_wait_timer_report "blocked [key=$key]: waiting-timer-overdue: $task ($verb, observed ${age}s); owning lead has not cleared the wait; Main must unblock or steer the lead; source=[$source]" || continue
        parent=1
        fm_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" || return 1
      else
        # The reason line's leading word is the wake kind every consumer
        # classifies by, so it must read "check:" like the kind this row is
        # queued under: a prefix outside that taxonomy classifies as no wake at
        # all, and the escalation then reaches nobody.
        reason="check: waiting-state $task ($verb, observed ${age}s, level=main; Main must unblock it now) id=$key source=[$source]"
        fm_wake_append check "$key-escalation" "$reason" || return 1
        parent=1
        fm_wait_timer_save "$record" "$signature" "$since" "$owner" "$parent" "$key" "$misses" || return 1
        wake "$reason"
      fi
    fi
  done
  return 0
}
