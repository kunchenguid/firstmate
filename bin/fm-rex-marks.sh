#!/usr/bin/env bash
# fm-rex-marks.sh - Firstmate's per-worker attention marks on Rex panes.
#
# docs/rex-backend.md "Attention marks" owns the public contract (setting,
# state mapping, limits). This header owns the mechanics.
#
# Each Rex task of this home (ship, scout, or second mate) gets Firstmate's own
# OSC 7501 record (app=firstmate, id=fm; bin/backends/rex.sh
# fm_backend_rex_mark) from its status log through the shared classifier:
#
#   needs-decision or a captain hold -> blocked, kind question
#   blocked                          -> blocked, kind permission, or kind auth
#                                       when the note names a credential
#   failed                           -> error
#   done                             -> done ("PR ready" when the note has a URL)
#   anything else                    -> clear (no record)
#
# The record's msg is the status note, clipped. Rex then shows the tab's
# blocked symbol, session-picker indicator, Activity sidebar entry, and Dock
# badge. Because the app notifies only for a pane's main program status, a
# mark that changes to a new non-clear state also carries one OSC 777 desktop
# notification titled with the tab label; a repair of a dropped record does
# not notify again.
#
# config/rex-status-marks (local, gitignored) turns the marks on or off; its
# first non-comment word is `on` (also when the file is absent) or `off`. An
# unrecognized word warns once per value and reads as on.
#
# Producers:
#   bin/fm-watch.sh     sync, once per poll cycle while this home records a
#                       rex task or still holds a mark cache
#   bin/fm-teardown.sh  clear <task>, before the task's pane closes
#
# Usage:
#   fm-rex-marks.sh plan [<task>]
#   fm-rex-marks.sh sync [<task>]
#   fm-rex-marks.sh clear <task>
#
# plan prints "<task>\t<state>\t<kind>\t<msg>" per recorded rex task without
# contacting Rex. sync keeps a per-task cache, state/.rex-mark-<task>, holding
# "<state>\t<kind>\t<msg>" of the last mark it wrote. A task whose planned and
# cached marks are both clear costs no Rex call; otherwise sync reads the live
# record and writes only when it differs, so a record Rex dropped at a prompt
# mark or process exit is repaired on the next cycle. Turning the marks off
# clears every cached mark. clear removes the task's mark and its cache.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE resolve the
# home exactly as the other bin/ scripts do.
#
# Exit status: 0 on success or when nothing applies, 2 on a usage error, 1
# when a requested write failed. Producers ignore a failure so it never
# changes theirs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export STATE

FM_REX_MARKS_CONFIG="rex-status-marks"
FM_REX_MARKS_CACHE_PREFIX=".rex-mark-"
FM_REX_MARKS_UNKNOWN_PREFIX=".rex-marks-unknown-"
FM_REX_MARKS_NOTE_MAX=100
FM_REX_MARKS_AUTH_RE='credential|login|log in|sign[ -]?in|auth|token|password|api key'

usage() {
  echo "usage: fm-rex-marks.sh plan [<task>] | sync [<task>] | clear <task>" >&2
  exit 2
}

warn() {
  printf 'warning: rex status marks: %s\n' "$*" >&2
}

task_ok() {
  case "$1" in '' | .* | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

# channel: on or off from config/rex-status-marks.
channel() {
  local file="$CONFIG/$FM_REX_MARKS_CONFIG" line word marker
  [ -f "$file" ] || {
    printf 'on'
    return 0
  }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in '' | '#'*) continue ;; esac
    word=$(printf '%s' "${line%%[[:space:]]*}" | tr '[:upper:]' '[:lower:]')
    case "$word" in
      on | off)
        printf '%s' "$word"
        return 0
        ;;
    esac
    case "$word" in *[!a-z0-9_-]*) word=invalid ;; esac
    marker="$STATE/$FM_REX_MARKS_UNKNOWN_PREFIX$word"
    if [ ! -e "$marker" ]; then
      warn "$file: unknown value; using on (on or off)"
      : >"$marker" 2>/dev/null || true
    fi
    break
  done <"$file"
  printf 'on'
}

meta_value() { # <meta> <key>
  local line value=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done <"$1" 2>/dev/null
  printf '%s' "$value"
}

LIBS_LOADED=0
load_status_libs() {
  [ "$LIBS_LOADED" = 1 ] && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh" || return 1
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh" || return 1
  LIBS_LOADED=1
}

BACKEND_LOADED=0
load_backend() {
  [ "$BACKEND_LOADED" = 1 ] && return 0
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" || return 1
  fm_backend_source rex || return 1
  BACKEND_LOADED=1
}

# plan_mark <task> <kind>: sets P_STATE, P_KIND, and P_MSG.
plan_mark() {
  local line verb note held
  P_STATE=clear
  P_KIND=
  P_MSG=
  load_status_libs || return 0
  line=$(status_current_line "$STATE/$1.status" "$2" 2>/dev/null) || line=
  verb=$(status_line_verb "$line" 2>/dev/null) || verb=
  note=$(status_line_note "$line" 2>/dev/null) || note=
  note=$(printf '%s' "$note" | tr '\t\r\n' '   ')
  note=${note:0:$FM_REX_MARKS_NOTE_MAX}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  case "$verb" in
    needs-decision | "$held")
      P_STATE=blocked
      P_KIND=question
      P_MSG="Needs your decision: $note"
      ;;
    blocked)
      P_STATE=blocked
      P_KIND=permission
      if printf '%s' "$note" | grep -Eiq "$FM_REX_MARKS_AUTH_RE"; then P_KIND=auth; fi
      P_MSG="Blocked: $note"
      ;;
    failed)
      P_STATE=error
      P_MSG="Failed: $note"
      ;;
    done)
      P_STATE="done"
      case "$note" in
        *https://*) P_MSG="PR ready: $note" ;;
        *) P_MSG="Done: $note" ;;
      esac
      ;;
  esac
  P_MSG=${P_MSG:0:$FM_REX_MARKS_NOTE_MAX}
}

# Collected rex tasks: "<task>\t<kind>\t<target>\t<tab-label>" each.
TASKS=()
collect_tasks() { # [<task>]
  local only=${1:-} meta id kind target
  TASKS=()
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    task_ok "$id" || continue
    [ -z "$only" ] || [ "$id" = "$only" ] || continue
    [ "$(meta_value "$meta" backend)" = rex ] || continue
    kind=$(meta_value "$meta" kind)
    case "${kind:-ship}" in ship | scout | secondmate) ;; *) continue ;; esac
    target=$(meta_value "$meta" window)
    case "$target" in '' | *[[:space:]]*) continue ;; esac
    TASKS+=("$id"$'\t'"${kind:-ship}"$'\t'"$target"$'\t'"$(meta_value "$meta" rex_tab_label)")
  done
}

cache_path() { printf '%s/%s%s' "$STATE" "$FM_REX_MARKS_CACHE_PREFIX" "$1"; }

# sync_task <channel> <record>: converge one task's mark; 1 on a failed write.
sync_task() {
  local mode=$1 task kind target tab cache cached='' c_state c_kind c_msg live want notify=
  IFS=$'\t' read -r task kind target tab <<EOF
$2
EOF
  plan_mark "$task" "$kind"
  cache=$(cache_path "$task")
  [ ! -f "$cache" ] || cached=$(head -1 "$cache" 2>/dev/null)
  # cut, not `IFS=$'\t' read`: a tab is IFS whitespace, so read would collapse
  # an empty kind and shift the message into its place.
  c_state=$(printf '%s' "$cached" | cut -f1)
  c_kind=$(printf '%s' "$cached" | cut -f2)
  c_msg=$(printf '%s' "$cached" | cut -f3)
  [ -n "$c_state" ] || c_state=clear
  if [ "$mode" = off ] || [ "$P_STATE" = clear ]; then
    if [ "$c_state" = clear ]; then
      rm -f "$cache"
      return 0
    fi
  fi
  load_backend || return 1
  if [ "$mode" = off ]; then
    fm_backend_rex_mark "$target" clear "" "" "fm-$task" || return 1
    rm -f "$cache"
    return 0
  fi
  want="$P_STATE"$'\t'"$P_KIND"$'\t'"$P_MSG"
  live=$(fm_backend_rex_mark_read "$target") || return 1
  if [ "$live" != "$want" ]; then
    if [ "$P_STATE" != clear ] && [ "$P_STATE $P_KIND $P_MSG" != "$c_state $c_kind $c_msg" ]; then
      notify="Firstmate: ${tab:-$task}"
    fi
    fm_backend_rex_mark "$target" "$P_STATE" "$P_KIND" "$P_MSG" "fm-$task" "$notify" || return 1
  fi
  if [ "$P_STATE" = clear ]; then
    rm -f "$cache"
  else
    printf '%s\n' "$want" >"$cache" 2>/dev/null || return 1
  fi
  return 0
}

cmd_plan() {
  local record task kind
  collect_tasks "${1:-}"
  for record in ${TASKS[@]+"${TASKS[@]}"}; do
    IFS=$'\t' read -r task kind _ _ <<EOF
$record
EOF
    plan_mark "$task" "$kind"
    printf '%s\t%s\t%s\t%s\n' "$task" "$P_STATE" "$P_KIND" "$P_MSG"
  done
}

cmd_sync() {
  local mode record rc=0 cache task
  mode=$(channel)
  collect_tasks "${1:-}"
  for record in ${TASKS[@]+"${TASKS[@]}"}; do
    sync_task "$mode" "$record" || rc=1
  done
  # A cache whose task no longer records a rex endpoint has nothing to mark.
  if [ -z "${1:-}" ]; then
    for cache in "$STATE/$FM_REX_MARKS_CACHE_PREFIX"*; do
      [ -f "$cache" ] || continue
      task=${cache##*/"$FM_REX_MARKS_CACHE_PREFIX"}
      [ -f "$STATE/$task.meta" ] && [ "$(meta_value "$STATE/$task.meta" backend)" = rex ] || rm -f "$cache"
    done
  fi
  return "$rc"
}

cmd_clear() {
  local record task target rc=0
  task_ok "${1:-}" || usage
  collect_tasks "$1"
  for record in ${TASKS[@]+"${TASKS[@]}"}; do
    IFS=$'\t' read -r task _ target _ <<EOF
$record
EOF
    if [ -f "$(cache_path "$task")" ]; then
      load_backend || return 1
      fm_backend_rex_mark "$target" clear "" "" "fm-$task" || rc=1
    fi
  done
  rm -f "$(cache_path "$1")"
  return "$rc"
}

case "${1:-}" in
  plan) cmd_plan "${2:-}" ;;
  sync) cmd_sync "${2:-}" ;;
  clear) cmd_clear "${2:-}" ;;
  *) usage ;;
esac
