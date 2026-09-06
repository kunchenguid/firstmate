#!/usr/bin/env bash
# fm-parent-channel-lib.sh - single owner of "which channel does THIS home use to
# escalate to its parent, and how is a line put there".
#
# A secondmate home has exactly one escalation channel toward its parent, and
# both directions of a decision must use it: the line that OPENS a decision and
# the line that CLOSES it. Opening in one channel and closing in another leaves
# the parent's open-decision fold showing an answered decision forever, which
# degrades the one surface the captain reads to know what is still waiting on
# them. Resolving the channel in one place is what makes the two directions
# provably the same channel.
#
# Route per bin/fm-secondmate-parent-lib.sh:
#   local   -> <parent_home>/state/<self>.status, the parent's own log. The
#              parent reads it directly, so a plain append is the delivery.
#   remote  -> <this home>/state/parent-replies.status, the mirror the parent's
#              ingest adapter copies into its own log at most once
#              (bin/fm-procevent-remote-reply.sh). A remote home cannot write
#              the parent's filesystem, so the mirror IS its channel.
#
# The tri-state return is the point of this library: callers must be able to
# tell "this home has no parent" apart from "this home has a parent but the
# channel cannot be resolved", because the first is normal for a primary home
# and the second must fail visibly rather than let a close land in the wrong
# channel in silence.
#
# Every write chooses exactly one category through fm_parent_channel_append:
#   transition -> a decision open or close is appended only when the folded
#                 live state needs that transition, under the channel lock;
#                 when an origin task is supplied, the current and new
#                 transitions must carry that exact task provenance
#   receipt    -> an immutable unique receipt is deduplicated by exact content
#   event      -> every occurrence is appended, including identical repeats
# Missing and unknown categories are refused.
#
# This file is sourced and has no side effects on source.

_FM_PARENT_CHANNEL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_PARENT_CHANNEL_LIB_DIR="."
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$_FM_PARENT_CHANNEL_LIB_DIR/fm-secondmate-parent-lib.sh"

# Read this home's secondmate identity marker.
# 0 + prints the id; 1 = no parent evidence; 2 = parent evidence is unusable.
fm_parent_channel_self_id() {  # <home>
  local marker="$1/.fm-secondmate-home" binding="$1/.fm-secondmate-parent" id
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    if [ -e "$binding" ] || [ -L "$binding" ]; then
      return 2
    fi
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  # bash's read drops NUL bytes and different generations disagree on the
  # result, so reject a NUL-bearing marker before trusting any id it names.
  [ "$(wc -c < "$marker")" -eq "$(LC_ALL=C tr -d '\0' < "$marker" | wc -c)" ] || return 2
  # Read the WHOLE marker, not just its first line: a marker carrying more than
  # one line is corrupt, and taking line one would route on a guess instead of
  # surfacing the corruption. Command substitution strips the trailing newline,
  # so a well-formed single-line marker passes and anything else keeps an
  # embedded newline that the charset check below rejects.
  id=$(cat "$marker" 2>/dev/null) || return 2
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  printf '%s\n' "$id"
}

fm_parent_channel_path_usable() {  # <path>
  local path=$1 dir
  dir=$(dirname "$path")
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -w "$dir" ] && [ -x "$dir" ] \
    || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] && [ -w "$path" ]
    return
  fi
  return 0
}

# Resolve this home's parent escalation channel.
# 0 + prints the absolute destination path; 1 = this home has no parent;
# 2 = this home has a parent but its channel cannot be resolved (fail visibly).
fm_parent_channel_path() {  # <home> <state-dir>
  local home=$1 state=$2 self rc=0 path dir
  self=$(fm_parent_channel_self_id "$home") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # An identified secondmate home with no readable parent binding is the
  # unresolvable case, never the no-parent case: it HAS a parent by definition.
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 2
  case "$FM_SECONDMATE_PARENT_ROUTE" in
    local)
      [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 2
      # The home itself must exist - a binding naming a moved or deleted parent
      # is unresolvable, not a silent no-op.
      [ -d "$FM_SECONDMATE_PARENT_HOME" ] || return 2
      path="$FM_SECONDMATE_PARENT_HOME/state/$self.status"
      ;;
    remote)
      [ -n "$state" ] || return 2
      path="$state/parent-replies.status"
      ;;
    *) return 2 ;;
  esac
  dir=$(dirname "$path")
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    mkdir "$dir" 2>/dev/null || return 2
  fi
  fm_parent_channel_path_usable "$path" || return 2
  printf '%s\n' "$path"
}

fm_parent_channel_line_task() {  # <status-line>
  local head task rest
  head=${1%%:*}
  case "$head" in *\[task=*\]*) ;; *) return 1 ;; esac
  task=${head#*\[task=}
  task=${task%%\]*}
  rest=${head#*\[task=}
  rest=${rest#*\]}
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
  case "$rest" in *\[task=*\]*) return 2 ;; esac
  printf '%s\n' "$task"
}

fm_parent_channel_open_task() {  # <path> <key>
  local path=$1 wanted=$2 open line verb key note task='' line_task
  open=$(status_open_decisions "$path") || return 2
  _fm_open_set_has "$open" "$wanted" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=$(_fm_decision_key "$line") || continue
    [ "$key" = "$wanted" ] || continue
    note=$(status_line_note "$line")
    _fm_decision_key_transition_allowed "$key" "$note" || continue
    verb=$(status_line_verb "$line")
    case "$verb" in
      needs-decision|blocked)
        if line_task=$(fm_parent_channel_line_task "$line"); then
          task=$line_task
        else
          task=''
        fi
        ;;
      "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}"|"${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}")
        task=''
        ;;
    esac
  done < "$path" || return 2
  [ -n "$task" ] || return 2
  printf '%s\n' "$task"
}

fm_parent_channel_append() {
  [ "$#" -ge 3 ] || return 1
  local category=$1 path=$2 line=$3 action='' key='' self_state='' origin_task=''
  local lock open='' is_open=0 append_rc=0 rc=0 line_task existing_task existing_rc
  shift 3
  case "$category" in
    receipt|event)
      [ "$#" -eq 0 ] || return 1
      ;;
    transition)
      [ "$#" -ge 2 ] && [ "$#" -le 4 ] || return 1
      action=$1
      key=$2
      self_state=${3:-}
      origin_task=${4:-}
      case "$action" in open|close) ;; *) return 1 ;; esac
      [ -n "$key" ] || return 1
      if [ -n "$origin_task" ]; then
        case "$origin_task" in *[!A-Za-z0-9._-]*) return 1 ;; esac
        line_task=$(fm_parent_channel_line_task "$line") || return 1
        [ "$line_task" = "$origin_task" ] || return 1
      fi
      ;;
    *) return 1 ;;
  esac
  fm_parent_channel_path_usable "$path" || return 1
  lock="$path.parent-channel.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if ! fm_parent_channel_path_usable "$path"; then
    rc=1
  else
    case "$category" in
      receipt)
        grep -Fqx -- "$line" "$path" 2>/dev/null \
          || printf '%s\n' "$line" >> "$path" \
          || rc=1
        ;;
      event)
        printf '%s\n' "$line" >> "$path" || rc=1
        ;;
      transition)
        if ! open=$(status_open_decisions "$path"); then
          rc=1
        else
          case "$open" in
            "$key"$'\t'*|*$'\n'"$key"$'\t'*) is_open=1 ;;
          esac
          if [ -n "$origin_task" ] && [ "$is_open" -eq 1 ]; then
            existing_rc=0
            existing_task=$(fm_parent_channel_open_task "$path" "$key") || existing_rc=$?
            if [ "$existing_rc" -ne 0 ] || [ "$existing_task" != "$origin_task" ]; then
              rc=1
            fi
          fi
          if [ "$rc" -eq 0 ] \
            && { { [ "$action" = open ] && [ "$is_open" -eq 0 ]; } \
              || { [ "$action" = close ] && [ "$is_open" -eq 1 ]; }; }; then
            if [ -n "$self_state" ]; then
              fm_wake_status_append_self_announced "$self_state" "$path" "$line" || append_rc=$?
              [ "$append_rc" -ne 2 ] || rc=1
            else
              printf '%s\n' "$line" >> "$path" || rc=1
            fi
          fi
        fi
        ;;
    esac
  fi
  fm_lock_release "$lock"
  return "$rc"
}
