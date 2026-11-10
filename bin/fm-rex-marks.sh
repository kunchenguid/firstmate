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
# The record's msg is the status note, clipped, and its title is the task's
# tab label, fm-<task>. Rex then shows the tab's
# blocked symbol, session-picker indicator, Activity sidebar entry, and Dock
# badge. Because the app notifies only for a pane's main program status, a
# mark that changes to a new non-clear state also carries one OSC 777 desktop
# notification titled with the tab label; a repair of a dropped record does
# not notify again.
#
# Validation progress: while a no-mistakes ship's mark is clear and the
# no-mistakes run on its branch is in flight, the task also gets a working
# child record (id=fm/validate, fm_backend_rex_progress) whose progress is the
# share of pipeline steps done (fm_nm_run_progress in bin/fm-nm-run-lib.sh)
# and whose msg names the active step, for example
# "Validating: review 3/9, auto-fix 1/3". The run is read with one bounded
# `no-mistakes axi status` in the task worktree at most once per
# FM_REX_PROGRESS_INTERVAL seconds (default 30) per task; the record is
# removed once the run ends or the task's mark is set.
#
# State tint: when config/rex-tint enables it, a task whose mark is blocked
# (waiting on the captain or on help) or error (failed) also gets a subtle
# background tint (OSC 11, fm_backend_rex_tint), and the tint is reset (OSC
# 111) when the mark leaves that state, at clear, and when the tint is turned
# off. A running task is never tinted.
#
# config/rex-status-marks (local, gitignored) turns the marks and progress on
# or off; its first non-comment word is `on` or `off` (also when the file is
# absent). An unrecognized word warns once per value and reads as off.
# config/rex-tint (local, gitignored) picks the tint; its first non-comment
# word is `off` (also when the file is absent), `subtle` (colors for a dark
# theme), or `subtle-light` (colors for a light theme). An unrecognized word
# warns once per value and reads as off.
#
# Producers:
#   bin/fm-watch.sh     sync, once per poll cycle while config/rex-status-marks
#                       or config/rex-tint exists or a mark cache remains
#   bin/fm-teardown.sh  clear <task>, before the task's pane closes
#
# Usage:
#   fm-rex-marks.sh plan [<task>]
#   fm-rex-marks.sh sync [<task>]
#   fm-rex-marks.sh clear <task>
#
# plan prints "<task>\t<state>\t<kind>\t<msg>" per recorded rex task without
# contacting Rex. sync keeps per-task caches: state/.rex-mark-<task> holds
# "<state>\t<kind>\t<msg>" of the last mark it wrote, state/.rex-progress-<task>
# holds "<percent>\t<msg>" of the last planned progress (`clear` when none),
# and state/.rex-tint-<task> holds "<target>\t<color>" of the tint it wrote. A
# task whose planned and cached records are clear costs no Rex call;
# otherwise sync reads the live record and writes only when it differs, so a
# record Rex dropped at a prompt mark or process exit is repaired on the next
# cycle. A tint cannot be read back, so it is written only when its cache
# differs. Turning the marks off clears every cached mark and progress record.
# clear removes the task's mark, progress record, and tint, and their caches.
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
FM_REX_PROGRESS_CACHE_PREFIX=".rex-progress-"
FM_REX_PROGRESS_INTERVAL=${FM_REX_PROGRESS_INTERVAL:-30}
FM_REX_PROGRESS_NM_TIMEOUT=5
FM_REX_TINT_CONFIG="rex-tint"
FM_REX_TINT_CACHE_PREFIX=".rex-tint-"
FM_REX_TINT_UNKNOWN_PREFIX=".rex-tint-unknown-"
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

# config_word: the first non-comment word of config/<name> when it is one of
# <words>, else <default>; an unrecognized word warns once per value (marker
# state/<unknown-prefix><word>).
config_word() { # <name> <unknown-prefix> <default> <words...>
  local file="$CONFIG/$1" prefix=$2 default=$3 line word marker allowed
  shift 3
  [ -f "$file" ] || {
    printf '%s' "$default"
    return 0
  }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in '' | '#'*) continue ;; esac
    word=$(printf '%s' "${line%%[[:space:]]*}" | tr '[:upper:]' '[:lower:]')
    for allowed in "$@"; do
      if [ "$word" = "$allowed" ]; then
        printf '%s' "$word"
        return 0
      fi
    done
    case "$word" in *[!a-z0-9_-]*) word=invalid ;; esac
    marker="$STATE/$prefix$word"
    if [ ! -e "$marker" ]; then
      allowed="$*"
      warn "$file: unknown value; using $default (${allowed// / or })"
      : >"$marker" 2>/dev/null || true
    fi
    break
  done <"$file"
  printf '%s' "$default"
}

# channel: on or off from config/rex-status-marks.
channel() { config_word "$FM_REX_MARKS_CONFIG" "$FM_REX_MARKS_UNKNOWN_PREFIX" off on off; }

# tint_style: off, subtle, or subtle-light from config/rex-tint.
tint_style() { config_word "$FM_REX_TINT_CONFIG" "$FM_REX_TINT_UNKNOWN_PREFIX" off off subtle subtle-light; }

# tint_color <style> <mark-state>: the background for a mark state under a
# style, empty for none. Only waiting (blocked) and failed (error) tint.
tint_color() {
  case "$1:$2" in
    subtle:blocked) printf '#2b2614' ;;
    subtle:error) printf '#301a1c' ;;
    subtle-light:blocked) printf '#fbf4dd' ;;
    subtle-light:error) printf '#fbe8e8' ;;
  esac
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

NM_LOADED=0
load_nm_lib() {
  [ "$NM_LOADED" = 1 ] && return 0
  # shellcheck source=bin/fm-nm-run-lib.sh
  . "$SCRIPT_DIR/fm-nm-run-lib.sh" || return 1
  NM_LOADED=1
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

# plan_progress <task> <kind> <meta>: sets G_PCT ("clear" for no record, empty
# for indeterminate) and G_MSG from the no-mistakes run on the task's branch.
plan_progress() {
  local wt branch out run_branch line pct position total step round
  G_PCT=clear
  G_MSG=
  [ "$2" = ship ] && [ "$(meta_value "$3" mode)" = no-mistakes ] || return 0
  wt=$(meta_value "$3" worktree)
  branch=$(meta_value "$3" branch)
  [ -n "$branch" ] && [ -d "$wt" ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  load_nm_lib || return 0
  out=$(fm_nm_run "$wt" "$FM_REX_PROGRESS_NM_TIMEOUT" axi status)
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  [ "$run_branch" = "$branch" ] && fm_nm_run_is_active "$out" || return 0
  line=$(fm_nm_run_progress "$out") || return 0
  IFS=$'\t' read -r pct position total step round <<EOF
$line
EOF
  G_PCT=$pct
  G_MSG="Validating"
  [ -z "$step" ] || G_MSG="$G_MSG: $step $position/$total"
  case "$round" in '' | starting) ;; *) G_MSG="$G_MSG, $round" ;; esac
  if fm_nm_run_is_parked "$out"; then G_MSG="$G_MSG, waiting at a gate"; fi
  return 0
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
    TASKS+=("$id"$'\t'"${kind:-ship}"$'\t'"$target"$'\t'"fm-$id")
  done
}

cache_path() { printf '%s/%s%s' "$STATE" "$FM_REX_MARKS_CACHE_PREFIX" "$1"; }
progress_cache_path() { printf '%s/%s%s' "$STATE" "$FM_REX_PROGRESS_CACHE_PREFIX" "$1"; }
tint_cache_path() { printf '%s/%s%s' "$STATE" "$FM_REX_TINT_CACHE_PREFIX" "$1"; }

# fresh <file>: 0 when <file> was written less than FM_REX_PROGRESS_INTERVAL
# seconds ago.
fresh() {
  local mtime
  [ -f "$1" ] || return 1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then mtime=$(/usr/bin/stat -f %m "$1" 2>/dev/null); else mtime=$(stat -c %Y "$1" 2>/dev/null); fi
  case "$mtime" in '' | *[!0-9]*) return 1 ;; esac
  [ $(($(date +%s) - mtime)) -lt "$FM_REX_PROGRESS_INTERVAL" ]
}

# sync_task <channel> <tint-style> <record>: converge one task's mark, then its
# progress record (a cleared mark also removes it), then its tint; 1 on a
# failed write.
sync_task() {
  local task kind target tab rc=0
  IFS=$'\t' read -r task kind target tab <<EOF
$3
EOF
  plan_mark "$task" "$kind"
  sync_mark "$1" "$task" "$target" "${tab:-$task}" || rc=1
  sync_progress "$1" "$task" "$kind" "$target" "${tab:-$task}" || rc=1
  sync_tint "$2" "$task" "$target" || rc=1
  return "$rc"
}

# sync_mark <channel> <task> <target> <title>: converge the mark planned in
# P_STATE, P_KIND, and P_MSG.
sync_mark() {
  local mode=$1 task=$2 target=$3 title=$4 cache cached='' c_state c_kind c_msg live live_want want notify=
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
  if [ "$P_STATE" = clear ]; then
    live_want=$'clear\t\t\t\t'
  else
    live_want="$P_STATE"$'\t'"$P_KIND"$'\t'"$(fm_backend_rex_status_text "$P_MSG" "$FM_BACKEND_REX_MSG_MAX")"
    live_want="$live_want"$'\t'"$(fm_backend_rex_status_text "$title" "$FM_BACKEND_REX_TITLE_MAX")"$'\t'
  fi
  if [ "$live" != "$live_want" ]; then
    if [ "$P_STATE" != clear ] && [ "$P_STATE $P_KIND $P_MSG" != "$c_state $c_kind $c_msg" ]; then
      notify=$title
    fi
    fm_backend_rex_mark "$target" "$P_STATE" "$P_KIND" "$P_MSG" "fm-$task" "$notify" "$title" || return 1
  fi
  if [ "$P_STATE" = clear ]; then
    rm -f "$cache"
  else
    printf '%s\n' "$want" >"$cache" 2>/dev/null || return 1
  fi
  return 0
}

# sync_progress <channel> <task> <kind> <target> <title>: converge the
# validation-progress record. The plan is reused from its cache while fresh,
# so the run is read at most once per FM_REX_PROGRESS_INTERVAL.
sync_progress() {
  local mode=$1 task=$2 kind=$3 target=$4 title=$5 cache cached='' c_pct c_msg live live_want
  cache=$(progress_cache_path "$task")
  [ ! -f "$cache" ] || cached=$(head -1 "$cache" 2>/dev/null)
  c_pct=$(printf '%s' "$cached" | cut -f1)
  c_msg=$(printf '%s' "$cached" | cut -f2)
  [ -n "$cached" ] || c_pct=clear
  G_PCT=clear
  G_MSG=
  if [ "$mode" = on ] && [ "$P_STATE" = clear ]; then
    if fresh "$cache"; then
      G_PCT=$c_pct
      G_MSG=$c_msg
    else
      plan_progress "$task" "$kind" "$STATE/$task.meta"
    fi
  fi
  if [ "$G_PCT" = clear ] && [ "$c_pct" = clear ]; then
    # Keep a fresh cache so an idle ship's run is not re-read every cycle.
    if [ "$mode" = on ] && [ "$P_STATE" = clear ] && [ "$kind" = ship ]; then
      fresh "$cache" || printf 'clear\t\n' >"$cache" 2>/dev/null || true
    else
      rm -f "$cache"
    fi
    return 0
  fi
  load_backend || return 1
  if [ "$G_PCT" = clear ]; then
    live_want=$'clear\t\t\t\t'
  else
    G_MSG=$(fm_backend_rex_status_text "$G_MSG" "$FM_BACKEND_REX_MSG_MAX")
    live_want=$'working\t\t'"$G_MSG"$'\t'"$(fm_backend_rex_status_text "$title" "$FM_BACKEND_REX_TITLE_MAX")"$'\t'"$G_PCT"
  fi
  live=$(fm_backend_rex_mark_read "$target" "$FM_BACKEND_REX_PROGRESS_ID") || return 1
  if [ "$live" != "$live_want" ]; then
    fm_backend_rex_progress "$target" "$G_PCT" "$G_MSG" "fm-$task" "$title" || return 1
  fi
  if [ "$G_PCT" = clear ] && { [ "$mode" != on ] || [ "$P_STATE" != clear ]; }; then
    rm -f "$cache"
  elif [ "$G_PCT" != "$c_pct" ] || [ "$G_MSG" != "$c_msg" ] || ! fresh "$cache"; then
    printf '%s\t%s\n' "$G_PCT" "$G_MSG" >"$cache" 2>/dev/null || return 1
  fi
  return 0
}

# sync_tint <style> <task> <target>: converge the tint for the mark planned in
# P_STATE. A cached tint for another target belongs to a pane that is gone.
sync_tint() {
  local style=$1 task=$2 target=$3 cache cached='' c_target c_color want
  cache=$(tint_cache_path "$task")
  [ ! -f "$cache" ] || cached=$(head -1 "$cache" 2>/dev/null)
  c_target=$(printf '%s' "$cached" | cut -f1)
  c_color=$(printf '%s' "$cached" | cut -f2)
  [ "$c_target" = "$target" ] || c_color=
  want=$(tint_color "$style" "$P_STATE")
  if [ "$want" = "$c_color" ]; then
    [ -n "$want" ] || rm -f "$cache"
    return 0
  fi
  load_backend || return 1
  if [ -n "$want" ]; then
    fm_backend_rex_tint "$target" "$want" "fm-$task" || return 1
    printf '%s\t%s\n' "$target" "$want" >"$cache" 2>/dev/null || return 1
  else
    fm_backend_rex_tint "$target" reset "fm-$task" || return 1
    rm -f "$cache"
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
  local mode style record rc=0 cache task prefix
  mode=$(channel)
  style=$(tint_style)
  collect_tasks "${1:-}"
  for record in ${TASKS[@]+"${TASKS[@]}"}; do
    sync_task "$mode" "$style" "$record" || rc=1
  done
  # A cache whose task no longer records a rex endpoint has nothing to mark.
  if [ -z "${1:-}" ]; then
    for prefix in "$FM_REX_MARKS_CACHE_PREFIX" "$FM_REX_PROGRESS_CACHE_PREFIX" "$FM_REX_TINT_CACHE_PREFIX"; do
      for cache in "$STATE/$prefix"*; do
        [ -f "$cache" ] || continue
        task=${cache##*/"$prefix"}
        [ -f "$STATE/$task.meta" ] && [ "$(meta_value "$STATE/$task.meta" backend)" = rex ] || rm -f "$cache"
      done
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
    # Clearing the mark also removes the progress record beneath it.
    if [ -f "$(cache_path "$task")" ] || [ -f "$(progress_cache_path "$task")" ]; then
      load_backend || return 1
      fm_backend_rex_mark "$target" clear "" "" "fm-$task" || rc=1
    fi
    if [ -f "$(tint_cache_path "$task")" ]; then
      load_backend || return 1
      fm_backend_rex_tint "$target" reset "fm-$task" || rc=1
    fi
  done
  rm -f "$(cache_path "$1")" "$(progress_cache_path "$1")" "$(tint_cache_path "$1")"
  return "$rc"
}

case "${1:-}" in
  plan) cmd_plan "${2:-}" ;;
  sync) cmd_sync "${2:-}" ;;
  clear) cmd_clear "${2:-}" ;;
  *) usage ;;
esac
