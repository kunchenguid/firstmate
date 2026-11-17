#!/usr/bin/env bash
# fm-goal.sh - the one owner of the drive-goal record: its schema, its mark
# grammar, the projection read from those marks, the bounded brief, and the
# archive at close.
#
# WHY. During a drive (docs/secondmate-parent-channel.md; the away posture in
# bin/fm-afk-contract.sh) the parent firstmate runs open-ended work across
# secondmates. A merged PR is the strongest landing signal and it arrives per
# task; the drive itself - "Miko I1 live in production" - is a different
# shape: several items, each owned by one mate, with a definition of done that
# is a state of the world rather than one merged PR. Without a record the
# drive lives in the parent's chat context alone: it is invisible to every
# secondmate, it is lost when the session ends, and there is no mechanical
# answer to "which items are startable right now?" or "did anything land
# without a goal update?" The goal record is that answer. It is one file per
# goal plus append-only marks, read by every renderer that needs it, and
# written by exactly one script: this one.
#
# THE RECORD (state/goals/<id>.goal; written only by this script):
#   version: 1 (or 2: see SCHEMA V2 below)
#   id: I1
#   title: <one line>
#   state: active
#   started: <UTC ISO 8601>
#   started_epoch: <seconds>
#   named_by: <words naming who asked for this>
#   plan: <path or URL the plan lives at>
#   done_when: <the world-state that ends the goal>
#   items:
#     item [id=node-refresh] [owner=terp] [class=drive] [task=miko-node-refresh]: refresh control-1 node bundle
#     item [id=grafana-secret] [owner=main] [class=captain]: rotate the grafana secret
#
# Item grammar: `item [id=<id>] [owner=<owner>] [after=<ids>] [class=<drive|captain>] [task=<task-id>] [project=<p>] [target=<stage>] [until=<epoch>] [stop-on=<words>]: <title>`.
# id and owner are required; after lists item ids (comma separated) that must
# reach done or dropped first; class defaults to drive (a captain item is a
# decision or action only the captain can take, and is never startable); task
# names the landing item when the item is "merge task X's PR". Every id,
# owner, task, project, and target must be path-safe: no empty value, leading
# dot, slash, or character outside [A-Za-z0-9._-]. A closed record appends:
#   closed: <UTC ISO 8601>
#   closed_epoch: <seconds>
#   closed_reason: done | captain
#   closed_words: <the captain's words for an early close> | -
#   projection:
#     <the item projection lines as fm_goal_project printed them at close>
#
# SCHEMA V2. The four trailing item fields are optional and independent of
# version 1 items: a record whose items use none of them is written as version
# 1 and stays readable by a version 1 reader, and every version 1 record this
# script reads keeps working unchanged. project names the project the item's
# work lands in; target is the stage (a rung of that project's ladder, see
# bin/fm-stage-ladder-lib.sh) the drive carries the item to, and needs a
# project; until is an epoch after which the item stops being startable;
# stop-on is a comma list of words the driver stops on (for example
# prod-deploy-failed, spend) that `show` carries to it verbatim. When the
# project has a ladder file, `start` and `edit` refuse a target that is not on
# it, and `close --done` refuses while a non-dropped item has not reached its
# target. The stage is not a state: an item marked done at stage merged is
# still short of target deployed, which `show` and `brief` say.
#
# MARKS. Progress is append-only lines in two places, folded by this script
# into one state per item:
#   - state/goals/<id>.marks, appended by `mark` in the parent home;
#   - each owner's stream (state/<owner>.status, or data/<owner>/status.log
#     once the state file is gone), where a secondmate's marks arrive through
#     the parent channel (bin/fm-parent-channel-lib.sh).
# Mark grammar: `goal [goal=<id>] [item=<item>] [state=<s>] [stage=<stage>] [task=<task>] [at=<epoch>]: <note>`
# with states open|running|waiting|blocked|done|dropped. `open` resets an item
# to unstarted. A mark carries a state, a stage, or both; the stage folds on
# its own newest-wins clock, so a stage-only mark never changes the item's
# state or since. A secondmate runs `mark` in its own home; the command routes
# the line through fm_parent_channel_report (stamped, deduplicated,
# appended), and on a local route validates the item against the parent's
# record read-only first. The fold keeps, per item, the mark with the newest
# at; the later line wins a tie; marks without a valid at, or with an at more
# than 300 s in the future, are ignored and counted in `show`. Marks that
# reference an item the record does not list are kept as unplanned drift,
# shown by `show` and excluded from the projection.
#
# PROJECTION. Derived state per item: the item's fields, the folded mark
# state, since (the winning mark's epoch), startable (state open, class drive,
# every after id done or dropped), waiting_on (the unmet after ids), and a
# landing hint (the item's task merged with no newer goal update: for a task
# with a state/<task>.meta record, the merge-notified marker bin/fm-pr-lib.sh
# owns, read the way bin/fm-afk-return.sh's landed-work scan reads it;
# otherwise a done [key=merged-<task>] line in an owner's stream). `show`
# renders the projection unbounded; `brief` renders it bounded (~1.5 KB per
# goal, 3 KB total, later goals collapsed to one line); `window` renders the
# since-epoch view a return brief needs. The brief also reads drive_goals
# from state/.afk-contract when that field is present (bin/fm-afk-contract.sh
# owns it): named goals come first, and every active goal is labeled as driven
# while away, named or not (the captain's goal-drive-always decision).
#
# CLOSE. `close --done` archives the record and marks to state/goals/closed/
# (<id>-<closed_epoch>.goal carrying a projection snapshot, and .marks with
# every valid mark folded so far, owner-stream marks copied in), and refuses
# while any item is not done or dropped. `close --captain --words <text>` is
# the early close at the captain's word, main actor only. A closed id may be
# started again.
#
# AUTHORITY. The parent home's main actor may run everything. The supervision
# branch (FM_SUPERVISION_ACTOR=branch, bin/fm-lease-lib.sh) may run `mark` and
# `close --done` - the away session acts on the goal it is left - and is
# refused by `start`, `edit`, and `close --captain` (a captain close is the
# captain's own words). A secondmate home may run `mark` (routed) and the read
# commands, and is refused by `start`, `edit`, and `close`; `brief` there
# renders the parent's goals filtered to that mate's items, read-only, and
# refuses symlinked parent records. Cross-home reads are read-only and refuse
# symlinks: a secondmate never rewrites the parent's record.
#
# LOCK. Record rewrites (start, edit, close) and mark appends serialize on
# state/goals/.lock through bin/fm-wake-lib.sh's bounded acquire; the lock
# never spans a network call. The lock timeout is 30 s (FM_TEST_GOAL_LOCK_TIMEOUT
# overrides it in tests).
#
# Usage:
#   fm-goal.sh start <id> --title <text> --done-when <text> --named-by <text> \
#                      --plan <path-or-url> --items-file <path>
#   fm-goal.sh edit <id> --items-file <path> [--title <text>] [--done-when <text>]
#   fm-goal.sh mark <id> <item> <state> [--stage <stage>] [--task <task-id>] -- <note>
#   fm-goal.sh mark <id> <item> stage=<stage> [--task <task-id>] -- <note>
#   fm-goal.sh probe [<id> [<item>]] [--dry-run]
#   fm-goal.sh close <id> --done | --captain --words <text>
#   fm-goal.sh show [<id>]
#   fm-goal.sh brief
#   fm-goal.sh active
#   fm-goal.sh startable
#   fm-goal.sh exists <id>
#   fm-goal.sh window <id> --since <epoch>
#
# `probe` runs each item's project stage ladder (<config>/stage-ladders/<project>,
# home-local, owned by bin/fm-stage-ladder-lib.sh) from the rung above its
# stage up to its target, stops at the first rung whose probe is not reached
# (a probe is one command; exit 0 reached, bound FM_GOAL_PROBE_TIMEOUT seconds,
# default 60), and records the highest rung reached as a stage mark whose note
# carries the probe's first output line. It marks nothing when no probe passes,
# prints one line per probed item, takes no goal lock while a probe runs, and
# is main or supervision-branch only. With no id it probes every active goal;
# --dry-run prints what it would mark. bin/fm-goal-probe-pr-merged.sh is the
# shared probe for a "PR merged" rung.
#
# `startable` prints one tab-separated row per startable item of every active
# goal - goal, item, owner, task (- when none), since (the folded mark epoch, or
# the goal's started epoch for an item no mark touched) - and nothing when no
# item is startable; it is the machine read the watcher's goal-stall tick uses
# (bin/fm-watch.sh), so that tick never invents what startable means.
#
# Exit codes: 0 success; 1 operational refusal (unknown goal or item, items
# still open, unwritable channel, no active goal); 2 usage error (bad flags,
# unsafe ids, malformed items file).

set -u

FM_GOAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_GOAL_DIR/.." && pwd)}"
FM_GOAL_HOME="${FM_HOME:-$FM_ROOT}"
FM_GOAL_STATE="${FM_STATE_OVERRIDE:-$FM_GOAL_HOME/state}"
FM_GOAL_DATA="${FM_DATA_OVERRIDE:-$FM_GOAL_HOME/data}"
FM_GOAL_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_GOAL_HOME/config}"

# shellcheck source=bin/fm-parent-channel-lib.sh
. "$FM_GOAL_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$FM_GOAL_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$FM_GOAL_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$FM_GOAL_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-stage-ladder-lib.sh
. "$FM_GOAL_DIR/fm-stage-ladder-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_GOAL_DIR/fm-timeout-lib.sh"

_FM_GOAL_LOCK_TIMEOUT=30
_FM_GOAL_MARK_FUTURE_TOLERANCE=300
FM_GOAL_BRIEF_PER_GOAL_BYTES=1536
FM_GOAL_BRIEF_TOTAL_BYTES=3072
FM_GOAL_BRIEF_ITEM_LIST=5
FM_GOAL_FIELD_MAX=300
FM_GOAL_ITEM_TITLE_MAX=300


# Accumulator line separator for the brief's category lists (never a byte a
# status line carries).
FM_GOAL_BRIEF_SEP=$'\x01'

fm_goal_usage() {
  sed -n '/^# Usage:/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

fm_goal_log() { printf 'fm-goal: %s\n' "$*" >&2; }

_fm_goal_die() {  # <exit-code> <message...>
  local code=$1
  shift
  fm_goal_log "$*"
  exit "$code"
}

# --- paths, ids, and time ----------------------------------------------------

fm_goal_id_valid() {  # <id> - path-safe as a state file name (same rule as a mate id)
  local id=${1-} LC_ALL=C
  case "$id" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_goal_state_valid() {  # <mark-or-item-state word>
  case "$1" in
    open|running|waiting|blocked|done|dropped) return 0 ;;
  esac
  return 1
}

fm_goal_dir() {  # [state-dir]
  printf '%s/goals\n' "${1:-$FM_GOAL_STATE}"
}

fm_goal_closed_dir() {  # [state-dir]
  printf '%s/closed\n' "$(fm_goal_dir "${1:-$FM_GOAL_STATE}")"
}

fm_goal_path() {  # <id> [state-dir]
  printf '%s/%s.goal\n' "$(fm_goal_dir "${2:-$FM_GOAL_STATE}")" "$1"
}

fm_goal_marks_path() {  # <id> [state-dir]
  printf '%s/%s.marks\n' "$(fm_goal_dir "${2:-$FM_GOAL_STATE}")" "$1"
}

fm_goal_lock_path() {  # [state-dir]
  printf '%s/.lock\n' "$(fm_goal_dir "${1:-$FM_GOAL_STATE}")"
}

# A regular, non-symlink file (a cross-home read refuses symlinks);
# 0 = exists and safe, 2 = missing, 1 = present but unusable.
_fm_goal_regular_file() {  # <path>
  if [ -e "$1" ] || [ -L "$1" ]; then
    [ -f "$1" ] && [ ! -L "$1" ] && return 0
    return 1
  fi
  return 2
}

# Its kind as stdout ('0' safe, '1' unusable, '2' missing) for one-shot use
# inside a test where the exit status is hard to reach.
_fm_goal_regular_file_kind() {  # <path>
  _fm_goal_regular_file "$1"
  printf '%s' "$?"
  return 0
}

fm_goal_epoch_iso() {  # <epoch> -> UTC ISO (the epoch itself when date refuses it)
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$1"
}

fm_goal_age() {  # <seconds> -> short human stretch (3d2h, 4h12m, 35m, 12s)
  local s=$1
  [ "$s" -ge 0 ] || s=0
  if [ "$s" -ge 86400 ]; then
    printf '%dd%dh' $((s / 86400)) $(((s % 86400) / 3600))
  elif [ "$s" -ge 3600 ]; then
    printf '%dh%dm' $((s / 3600)) $(((s % 3600) / 60))
  elif [ "$s" -ge 60 ]; then
    printf '%dm' $((s / 60))
  else
    printf '%ds' "$s"
  fi
}

# --- the lock (bin/fm-wake-lib.sh bounded acquire, never across a network call)

FM_GOAL_LOCK_HELD=

_fm_goal_lock_helpers() {
  [ -n "${_FM_GOAL_WAKE_LIB_LOADED:-}" ] && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_GOAL_DIR/fm-wake-lib.sh" || return 1
  _FM_GOAL_WAKE_LIB_LOADED=1
}

fm_goal_lock_hold() {  # [state-dir]
  local lock rc=0 STATE timeout
  STATE=${1:-$FM_GOAL_STATE}
  lock=$(fm_goal_lock_path "$STATE")
  timeout=${FM_TEST_GOAL_LOCK_TIMEOUT:-$_FM_GOAL_LOCK_TIMEOUT}
  _fm_goal_lock_helpers || {
    fm_goal_log "could not load the lock primitive for $lock"
    return 1
  }
  [ ! -L "$(dirname "$lock")" ] || { fm_goal_log 'refused: symlinked goals directory'; return 1; }
  mkdir -p "$(dirname "$lock")" || return 1
  fm_lock_acquire_wait_bounded "$lock" "$timeout" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ] && [ -n "${FM_LOCK_HELD_PID:-}" ]; then
      fm_goal_log "the goal records are locked by live process $FM_LOCK_HELD_PID; nothing was changed"
    else
      fm_goal_log "could not take the goal-record lock at $lock; nothing was changed"
    fi
    return 1
  fi
  FM_GOAL_LOCK_HELD=$lock
}

fm_goal_lock_release() {
  local lock=$FM_GOAL_LOCK_HELD
  [ -n "$lock" ] || return 0
  FM_GOAL_LOCK_HELD=
  _fm_goal_lock_helpers || return 1
  fm_lock_release "$lock"
}

# --- one-line fields ---------------------------------------------------------

_fm_goal_clean_field() {  # <text> -> single line, bounded
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-$FM_GOAL_FIELD_MAX
}

# --- the item line grammar ---------------------------------------------------

# fm_goal_item_parse <line>: 0 iff <line> is a valid item line; sets
# FM_GOAL_ITEM_ID, FM_GOAL_ITEM_OWNER, FM_GOAL_ITEM_AFTER (comma list, or ''),
# FM_GOAL_ITEM_CLASS (drive when absent), FM_GOAL_ITEM_TASK (or ''),
# FM_GOAL_ITEM_PROJECT, FM_GOAL_ITEM_TARGET, FM_GOAL_ITEM_UNTIL,
# FM_GOAL_ITEM_STOPON (each '' when absent; the schema v2 fields),
# FM_GOAL_ITEM_TITLE.
fm_goal_item_parse() {  # <line>
  local line=$1 head rest token key value title
  local seen_id=0 seen_owner=0 seen_after=0 seen_class=0 seen_task=0
  local seen_project=0 seen_target=0 seen_until=0 seen_stopon=0
  FM_GOAL_ITEM_ID=''; FM_GOAL_ITEM_OWNER=''; FM_GOAL_ITEM_AFTER=''
  FM_GOAL_ITEM_CLASS=''; FM_GOAL_ITEM_TASK=''; FM_GOAL_ITEM_TITLE=''
  FM_GOAL_ITEM_PROJECT=''; FM_GOAL_ITEM_TARGET=''; FM_GOAL_ITEM_UNTIL=''
  FM_GOAL_ITEM_STOPON=''
  case "$line" in
    'item '*) ;;
    *) return 1 ;;
  esac
  case "$line" in
    *:*) head=${line%%:*}; title=${line#*:} ;;
    *) return 1 ;;
  esac
  title=${title# }
  title=${title%"${title##*[![:space:]]}"}
  case "$(printf '%s' "$title" | LC_ALL=C tr -d '[:space:]')" in
    '') return 1 ;;
  esac
  rest=${head#item }
  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    token=${rest%%[[:space:]]*}
    rest=${rest#"$token"}
    case "$token" in
      \[*\]) token=${token#\[}; token=${token%\]} ;;
      *) return 1 ;;
    esac
    case "$token" in
      *=*) key=${token%%=*}; value=${token#*=} ;;
      *) return 1 ;;
    esac
    case "$key" in
      id)
        [ "$seen_id" -eq 0 ] || return 1; seen_id=1
        fm_goal_id_valid "$value" || return 1
        FM_GOAL_ITEM_ID=$value
        ;;
      owner)
        [ "$seen_owner" -eq 0 ] || return 1; seen_owner=1
        fm_goal_id_valid "$value" || return 1
        FM_GOAL_ITEM_OWNER=$value
        ;;
      after)
        [ "$seen_after" -eq 0 ] || return 1; seen_after=1
        _fm_goal_after_list_valid "$value" || return 1
        FM_GOAL_ITEM_AFTER=$value
        ;;
      class)
        [ "$seen_class" -eq 0 ] || return 1; seen_class=1
        case "$value" in
          drive|captain) FM_GOAL_ITEM_CLASS=$value ;;
          *) return 1 ;;
        esac
        ;;
      task)
        [ "$seen_task" -eq 0 ] || return 1; seen_task=1
        fm_goal_id_valid "$value" || return 1
        FM_GOAL_ITEM_TASK=$value
        ;;
      project)
        [ "$seen_project" -eq 0 ] || return 1; seen_project=1
        fm_goal_id_valid "$value" || return 1
        FM_GOAL_ITEM_PROJECT=$value
        ;;
      target)
        [ "$seen_target" -eq 0 ] || return 1; seen_target=1
        fm_goal_id_valid "$value" || return 1
        FM_GOAL_ITEM_TARGET=$value
        ;;
      until)
        [ "$seen_until" -eq 0 ] || return 1; seen_until=1
        case "$value" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
        [ "${#value}" -le 12 ] || return 1
        FM_GOAL_ITEM_UNTIL=$value
        ;;
      stop-on)
        [ "$seen_stopon" -eq 0 ] || return 1; seen_stopon=1
        _fm_goal_after_list_valid "$value" || return 1
        FM_GOAL_ITEM_STOPON=$value
        ;;
      *) return 1 ;;
    esac
  done
  [ "$seen_id" -eq 1 ] && [ "$seen_owner" -eq 1 ] || return 1
  # a target names a rung of a project's ladder, so it needs the project
  [ -z "$FM_GOAL_ITEM_TARGET" ] || [ -n "$FM_GOAL_ITEM_PROJECT" ] || return 1
  [ -n "$FM_GOAL_ITEM_CLASS" ] || FM_GOAL_ITEM_CLASS=drive
  FM_GOAL_ITEM_TITLE=$(printf '%s' "$title" | cut -c1-$FM_GOAL_ITEM_TITLE_MAX)
  return 0
}

_fm_goal_after_list_valid() {  # <comma list>
  local list=$1 part
  [ -n "$list" ] || return 1
  local LC_ALL=C IFS=,
  for part in $list; do
    fm_goal_id_valid "$part" || return 1
  done
  case "$list" in ,*|*,|*,,*) return 1 ;; esac
  return 0
}

# The normalized item line for item <idx> of the loaded arrays (no indent).
_fm_goal_item_line() {  # <idx>
  local i=$1 out
  out="item [id=${FM_GOAL_ITEMS_IDS[$i]}] [owner=${FM_GOAL_ITEMS_OWNERS[$i]}]"
  [ -z "${FM_GOAL_ITEMS_AFTERS[$i]}" ] || out="$out [after=${FM_GOAL_ITEMS_AFTERS[$i]}]"
  [ "${FM_GOAL_ITEMS_CLASSES[$i]}" = drive ] || out="$out [class=${FM_GOAL_ITEMS_CLASSES[$i]}]"
  [ -z "${FM_GOAL_ITEMS_TASKS[$i]}" ] || out="$out [task=${FM_GOAL_ITEMS_TASKS[$i]}]"
  [ -z "${FM_GOAL_ITEMS_PROJECTS[$i]}" ] || out="$out [project=${FM_GOAL_ITEMS_PROJECTS[$i]}]"
  [ -z "${FM_GOAL_ITEMS_TARGETS[$i]}" ] || out="$out [target=${FM_GOAL_ITEMS_TARGETS[$i]}]"
  [ -z "${FM_GOAL_ITEMS_UNTILS[$i]}" ] || out="$out [until=${FM_GOAL_ITEMS_UNTILS[$i]}]"
  [ -z "${FM_GOAL_ITEMS_STOPONS[$i]}" ] || out="$out [stop-on=${FM_GOAL_ITEMS_STOPONS[$i]}]"
  printf '%s: %s' "$out" "${FM_GOAL_ITEMS_TITLES[$i]}"
}

# --- the record parser (the only one) ----------------------------------------

FM_GOAL_REC_ID='' FM_GOAL_REC_TITLE='' FM_GOAL_REC_STATE=''
FM_GOAL_REC_STARTED='' FM_GOAL_REC_STARTED_EPOCH='' FM_GOAL_REC_NAMED_BY=''
FM_GOAL_REC_PLAN='' FM_GOAL_REC_DONE_WHEN='' FM_GOAL_REC_CLOSED=''
FM_GOAL_REC_CLOSED_EPOCH='' FM_GOAL_REC_CLOSED_REASON='' FM_GOAL_REC_CLOSED_WORDS=''
FM_GOAL_ITEM_COUNT=0
FM_GOAL_ITEMS_IDS=() FM_GOAL_ITEMS_OWNERS=() FM_GOAL_ITEMS_AFTERS=()
FM_GOAL_ITEMS_CLASSES=() FM_GOAL_ITEMS_TASKS=() FM_GOAL_ITEMS_TITLES=()
FM_GOAL_ITEMS_PROJECTS=() FM_GOAL_ITEMS_TARGETS=() FM_GOAL_ITEMS_UNTILS=()
FM_GOAL_ITEMS_STOPONS=()
_FM_GOAL_READ_ERROR=''
FM_GOAL_PROJECTION=()

# Empty every loaded item array (the record loader and the items-file loader).
_fm_goal_items_reset() {
  FM_GOAL_ITEM_COUNT=0
  FM_GOAL_ITEMS_IDS=() FM_GOAL_ITEMS_OWNERS=() FM_GOAL_ITEMS_AFTERS=()
  FM_GOAL_ITEMS_CLASSES=() FM_GOAL_ITEMS_TASKS=() FM_GOAL_ITEMS_TITLES=()
  FM_GOAL_ITEMS_PROJECTS=() FM_GOAL_ITEMS_TARGETS=() FM_GOAL_ITEMS_UNTILS=()
  FM_GOAL_ITEMS_STOPONS=()
}

# Append the item fm_goal_item_parse just parsed to the loaded arrays.
_fm_goal_items_append() {
  FM_GOAL_ITEMS_IDS[${#FM_GOAL_ITEMS_IDS[@]}]=$FM_GOAL_ITEM_ID
  FM_GOAL_ITEMS_OWNERS[${#FM_GOAL_ITEMS_OWNERS[@]}]=$FM_GOAL_ITEM_OWNER
  FM_GOAL_ITEMS_AFTERS[${#FM_GOAL_ITEMS_AFTERS[@]}]=$FM_GOAL_ITEM_AFTER
  FM_GOAL_ITEMS_CLASSES[${#FM_GOAL_ITEMS_CLASSES[@]}]=$FM_GOAL_ITEM_CLASS
  FM_GOAL_ITEMS_TASKS[${#FM_GOAL_ITEMS_TASKS[@]}]=$FM_GOAL_ITEM_TASK
  FM_GOAL_ITEMS_TITLES[${#FM_GOAL_ITEMS_TITLES[@]}]=$FM_GOAL_ITEM_TITLE
  FM_GOAL_ITEMS_PROJECTS[${#FM_GOAL_ITEMS_PROJECTS[@]}]=$FM_GOAL_ITEM_PROJECT
  FM_GOAL_ITEMS_TARGETS[${#FM_GOAL_ITEMS_TARGETS[@]}]=$FM_GOAL_ITEM_TARGET
  FM_GOAL_ITEMS_UNTILS[${#FM_GOAL_ITEMS_UNTILS[@]}]=$FM_GOAL_ITEM_UNTIL
  FM_GOAL_ITEMS_STOPONS[${#FM_GOAL_ITEMS_STOPONS[@]}]=$FM_GOAL_ITEM_STOPON
  FM_GOAL_ITEM_COUNT=$((FM_GOAL_ITEM_COUNT + 1))
}

_fm_goal_read_error() {  # <reason> - records why and fails the load
  _FM_GOAL_READ_ERROR=$1
  return 1
}

_fm_goal_load_record() {  # <path>
  local path=$1 line field value
  local seen_items=0 seen_closed=0 seen_projection=0 have_closed_epoch=0 have_closed_reason=0 have_closed_words=0
  local version='' id='' state='' started='' started_epoch='' title=''
  local named_by='' plan='' done_when='' closed='' closed_epoch='' closed_reason='' closed_words=''
  local have_version=0 have_id=0 have_state=0 have_started=0 have_started_epoch=0
  local have_title=0 have_named_by=0 have_plan=0 have_done_when=0
  _fm_goal_items_reset
  FM_GOAL_PROJECTION=()
  _FM_GOAL_READ_ERROR=''
  if ! { [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ]; }; then
    _FM_GOAL_READ_ERROR="record is missing, unreadable, or a symlink: $path"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if [ "$seen_projection" -eq 1 ]; then
      case "$line" in
        '  '*) FM_GOAL_PROJECTION[${#FM_GOAL_PROJECTION[@]}]=${line#  } ;;
        *) _fm_goal_read_error "unindented line inside the projection block: $line"; return 1 ;;
      esac
      continue
    fi
    if [ "$seen_items" -eq 0 ]; then
      case "$line" in
        ' '*) _fm_goal_read_error "indented line before items: $line"; return 1 ;;
      esac
      case "$line" in
        *:*) field=${line%%:*}; value=${line#*: }; value=${value# } ;;
        *) _fm_goal_read_error "unrecognized record line: $line"; return 1 ;;
      esac
      case "$field" in
        version)
          [ "$have_version" -eq 0 ] || { _fm_goal_read_error "duplicate version"; return 1; }
          have_version=1; version=$value
          ;;
        id)
          [ "$have_id" -eq 0 ] || { _fm_goal_read_error "duplicate id"; return 1; }
          have_id=1; id=$value
          ;;
        title)
          [ "$have_title" -eq 0 ] || { _fm_goal_read_error "duplicate title"; return 1; }
          have_title=1; title=$value
          ;;
        state)
          [ "$have_state" -eq 0 ] || { _fm_goal_read_error "duplicate state"; return 1; }
          have_state=1; state=$value
          ;;
        started)
          [ "$have_started" -eq 0 ] || { _fm_goal_read_error "duplicate started"; return 1; }
          have_started=1; started=$value
          ;;
        started_epoch)
          [ "$have_started_epoch" -eq 0 ] || { _fm_goal_read_error "duplicate started_epoch"; return 1; }
          have_started_epoch=1; started_epoch=$value
          ;;
        named_by)
          [ "$have_named_by" -eq 0 ] || { _fm_goal_read_error "duplicate named_by"; return 1; }
          have_named_by=1; named_by=$value
          ;;
        plan)
          [ "$have_plan" -eq 0 ] || { _fm_goal_read_error "duplicate plan"; return 1; }
          have_plan=1; plan=$value
          ;;
        done_when)
          [ "$have_done_when" -eq 0 ] || { _fm_goal_read_error "duplicate done_when"; return 1; }
          have_done_when=1; done_when=$value
          ;;
        items)
          seen_items=1
          ;;
        *) _fm_goal_read_error "unknown record field: $line"; return 1 ;;
      esac
    else
      case "$line" in
        '  item '*)
          fm_goal_item_parse "${line#  }" || {
            _fm_goal_read_error "malformed item line: $line"
            return 1
          }
          _fm_goal_items_append
          ;;
        '  '*)
          _fm_goal_read_error "indented non-item line in the items section: $line"; return 1
          ;;
        'closed:'*)
          [ "$seen_closed" -eq 0 ] || { _fm_goal_read_error "duplicate closed"; return 1; }
          seen_closed=1; closed=${line#closed: }; closed=${closed# }
          ;;
        'closed_epoch:'*)
          [ "$have_closed_epoch" -eq 0 ] || { _fm_goal_read_error "duplicate closed_epoch"; return 1; }
          have_closed_epoch=1; closed_epoch=${line#closed_epoch: }; closed_epoch=${closed_epoch# }
          ;;
        'closed_reason:'*)
          [ "$have_closed_reason" -eq 0 ] || { _fm_goal_read_error "duplicate closed_reason"; return 1; }
          have_closed_reason=1; closed_reason=${line#closed_reason: }; closed_reason=${closed_reason# }
          ;;
        'closed_words:'*)
          [ "$have_closed_words" -eq 0 ] || { _fm_goal_read_error "duplicate closed_words"; return 1; }
          have_closed_words=1; closed_words=${line#closed_words: }; closed_words=${closed_words# }
          ;;
        'projection:')
          seen_projection=1
          ;;
        *)
          _fm_goal_read_error "unrecognized line after items: $line"; return 1
          ;;
      esac
    fi
  done < "$path"
  [ "$have_version" -eq 1 ] || { _FM_GOAL_READ_ERROR='no version'; return 1; }
  case "$version" in
    1|2) ;;
    *) _FM_GOAL_READ_ERROR="unsupported version: $version"; return 1 ;;
  esac
  [ "$have_id" -eq 1 ] || { _FM_GOAL_READ_ERROR='no id'; return 1; }
  fm_goal_id_valid "$id" || { _FM_GOAL_READ_ERROR="unsafe id: $id"; return 1; }
  [ "$have_title" -eq 1 ] && [ -n "$title" ] || { _FM_GOAL_READ_ERROR='no title'; return 1; }
  [ "$have_state" -eq 1 ] || { _FM_GOAL_READ_ERROR='no state'; return 1; }
  case "$state" in
    active|closed) ;;
    *) _FM_GOAL_READ_ERROR="unknown state: $state"; return 1 ;;
  esac
  [ "$have_started" -eq 1 ] || { _FM_GOAL_READ_ERROR='no started'; return 1; }
  [ "$have_started_epoch" -eq 1 ] || { _FM_GOAL_READ_ERROR='no started_epoch'; return 1; }
  case "$started_epoch" in ''|*[!0-9]*|0[0-9]*) _FM_GOAL_READ_ERROR='malformed started_epoch'; return 1 ;; esac
  [ "${#started_epoch}" -le 12 ] || { _FM_GOAL_READ_ERROR='oversized started_epoch'; return 1; }
  [ "$have_named_by" -eq 1 ] && [ -n "$named_by" ] || { _FM_GOAL_READ_ERROR='no named_by'; return 1; }
  [ "$have_plan" -eq 1 ] && [ -n "$plan" ] || { _FM_GOAL_READ_ERROR='no plan'; return 1; }
  [ "$have_done_when" -eq 1 ] && [ -n "$done_when" ] || { _FM_GOAL_READ_ERROR='no done_when'; return 1; }
  [ "$FM_GOAL_ITEM_COUNT" -ge 1 ] || { _FM_GOAL_READ_ERROR='no items'; return 1; }
  _fm_goal_items_graph_ok || return 1
  if [ "$state" = closed ]; then
    [ "$seen_closed" -eq 1 ] || { _FM_GOAL_READ_ERROR='closed record without closed:'; return 1; }
    case "$closed_epoch" in ''|*[!0-9]*|0[0-9]*) _FM_GOAL_READ_ERROR='closed record without a valid closed_epoch'; return 1 ;; esac
    [ "${#closed_epoch}" -le 12 ] || { _FM_GOAL_READ_ERROR='oversized closed_epoch'; return 1; }
    case "$closed_reason" in
      done|captain) ;;
      *) _FM_GOAL_READ_ERROR="unknown closed_reason: $closed_reason"; return 1 ;;
    esac
    [ "$seen_projection" -eq 1 ] || { _FM_GOAL_READ_ERROR='closed record without a projection block'; return 1; }
    if [ "$closed_reason" = captain ]; then
      case "$closed_words" in ''|'-') _FM_GOAL_READ_ERROR='captain close without words'; return 1 ;; esac
    fi
  else
    [ "$seen_closed" -eq 0 ] || { _FM_GOAL_READ_ERROR='active record carries closed fields'; return 1; }
    [ "$seen_projection" -eq 0 ] || { _FM_GOAL_READ_ERROR='active record carries a projection block'; return 1; }
  fi
  FM_GOAL_REC_ID=$id
  FM_GOAL_REC_TITLE=$title
  FM_GOAL_REC_STATE=$state
  FM_GOAL_REC_STARTED=$started
  FM_GOAL_REC_STARTED_EPOCH=$started_epoch
  FM_GOAL_REC_NAMED_BY=$named_by
  FM_GOAL_REC_PLAN=$plan
  FM_GOAL_REC_DONE_WHEN=$done_when
  FM_GOAL_REC_CLOSED=$closed
  FM_GOAL_REC_CLOSED_EPOCH=$closed_epoch
  FM_GOAL_REC_CLOSED_REASON=$closed_reason
  FM_GOAL_REC_CLOSED_WORDS=$closed_words
  return 0
}

# fm_goal_validate <path> [<expected-id>]: 0 iff the record at <path> parses
# as a valid version 1 or 2 record; with <expected-id>, its id field must match and
# its file name must be <id>.goal or <id>-<epoch>.goal.
fm_goal_validate() {  # <path> [expected-id]
  local path=$1 expected=${2-} base
  _fm_goal_load_record "$path" || {
    fm_goal_log "invalid goal record $path: $_FM_GOAL_READ_ERROR"
    return 1
  }
  [ -z "$expected" ] && return 0
  if [ "$FM_GOAL_REC_ID" != "$expected" ]; then
    fm_goal_log "record id '$FM_GOAL_REC_ID' does not match the expected '$expected'"
    return 1
  fi
  base=$(basename "$path")
  case "$base" in
    .*) return 0 ;;  # a staged file under validation; its name is temporary
  esac
  case "$base" in
    "$expected.goal"|"$expected"-*.goal) return 0 ;;
  esac
  fm_goal_log "record file name '$base' does not match its id '$expected'"
  return 1
}

# fm_goal_items <path>: print the stored item lines, normalized, one per line,
# in record order (the two-space record prefix stripped).
fm_goal_items() {  # <path>
  local path=$1 i=0
  _fm_goal_load_record "$path" || return 1
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    _fm_goal_item_line "$i"
    printf '\n'
    i=$((i + 1))
  done
  return 0
}

# fm_goal_marks <id> [state-dir]: print the local marks file as stored (the
# parent-home half of the fold; owner streams are the other half).
fm_goal_marks() {  # <id> [state-dir]
  local path
  path=$(fm_goal_marks_path "$1" "${2:-$FM_GOAL_STATE}")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  cat "$path"
}

_fm_goal_index_of() {  # <item-id> -> index printed, or rc 1 when absent
  local id=$1 i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    if [ "${FM_GOAL_ITEMS_IDS[$i]}" = "$id" ]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# Item ids unique, after refs known, and the after graph acyclic. The
# cycle test is a relaxation: an item is orderable once every after ref is
# orderable; items never orderable sit on a cycle.
_fm_goal_items_graph_ok() {
  local i j id ref part refs rounds
  local -a ordered=()
  i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    ordered[${#ordered[@]}]=0
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    id=${FM_GOAL_ITEMS_IDS[$i]}
    j=0
    while [ "$j" -lt "$FM_GOAL_ITEM_COUNT" ]; do
      if [ "$j" -ne "$i" ] && [ "${FM_GOAL_ITEMS_IDS[$j]}" = "$id" ]; then
        _FM_GOAL_READ_ERROR="duplicate item id: $id"
        return 1
      fi
      j=$((j + 1))
    done
    refs=${FM_GOAL_ITEMS_AFTERS[$i]}
    if [ -n "$refs" ]; then
      local LC_ALL=C IFS=,
      for part in $refs; do
        _fm_goal_index_of "$part" >/dev/null || {
          _FM_GOAL_READ_ERROR="unknown after item: $part"
          return 1
        }
      done
    fi
    i=$((i + 1))
  done
  rounds=0
  while [ "$rounds" -le "$FM_GOAL_ITEM_COUNT" ]; do
    i=0
    while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
      [ "${ordered[$i]}" -eq 0 ] || { i=$((i + 1)); continue; }
      refs=${FM_GOAL_ITEMS_AFTERS[$i]}
      local ready=1
      if [ -n "$refs" ]; then
        local LC_ALL=C IFS=,
        for part in $refs; do
          ref=$(_fm_goal_index_of "$part") || return 1
          [ "${ordered[$ref]}" -eq 1 ] || { ready=0; break; }
        done
      fi
      ordered[i]=$ready
      i=$((i + 1))
    done
    rounds=$((rounds + 1))
  done
  i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    [ "${ordered[$i]}" -eq 1 ] || {
      _FM_GOAL_READ_ERROR="after dependency cycle through item: ${FM_GOAL_ITEMS_IDS[$i]}"
      return 1
    }
    i=$((i + 1))
  done
  return 0
}

# --- the mark fold -----------------------------------------------------------

FM_GOAL_M_STATES=() FM_GOAL_M_ATS=() FM_GOAL_M_NOTES=() FM_GOAL_M_TASKS=()
FM_GOAL_FOLD_IGNORED=0
FM_GOAL_PROGRESS_ATS=()
FM_GOAL_FOLD_LAST_AT=''
FM_GOAL_FOLD_LAST_OWNER=''
FM_GOAL_UNPLANNED_IDS=() FM_GOAL_UNPLANNED_STATES=() FM_GOAL_UNPLANNED_ATS=()
FM_GOAL_MERGED_TASKS=() FM_GOAL_MERGED_ATS=()
_FM_GOAL_FOLD_NOW=0

_fm_goal_fold_reset() {
  local i=0
  FM_GOAL_M_STATES=(); FM_GOAL_M_ATS=(); FM_GOAL_M_NOTES=(); FM_GOAL_M_TASKS=()
  FM_GOAL_S_STAGES=(); FM_GOAL_S_ATS=()
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    FM_GOAL_S_STAGES[${#FM_GOAL_S_STAGES[@]}]=''
    FM_GOAL_S_ATS[${#FM_GOAL_S_ATS[@]}]=''
    FM_GOAL_M_STATES[${#FM_GOAL_M_STATES[@]}]=open
    FM_GOAL_M_ATS[${#FM_GOAL_M_ATS[@]}]=''
    FM_GOAL_M_NOTES[${#FM_GOAL_M_NOTES[@]}]=''
    FM_GOAL_M_TASKS[${#FM_GOAL_M_TASKS[@]}]=''
    i=$((i + 1))
  done
  FM_GOAL_FOLD_IGNORED=0
  FM_GOAL_PROGRESS_ATS=()
  FM_GOAL_FOLD_LAST_AT=''
  FM_GOAL_FOLD_LAST_OWNER=''
  FM_GOAL_UNPLANNED_IDS=(); FM_GOAL_UNPLANNED_STATES=(); FM_GOAL_UNPLANNED_ATS=()
  FM_GOAL_MERGED_TASKS=(); FM_GOAL_MERGED_ATS=()
}

# Apply one parsed mark to the fold. rc 1 = invalid (counted by the caller),
# rc 2 = a mark for another goal (skipped silently).
# A mark carries a state, a stage, or both; each folds on its own newest-wins
# clock, so a stage-only mark never touches the item's state, since or note.
_fm_goal_fold_apply_mark() {  # <goal-id> <item> <state> <at> <task> <note> <now> <owner> <stage>
  local item=$2 state=$3 at=$4 task=$5 note=$6 now=$7 owner=$8 stage=${9-}
  local idx u known=0
  [ -z "$state" ] || fm_goal_state_valid "$state" || return 1
  [ -n "$state" ] || [ -n "$stage" ] || return 1
  [ -z "$stage" ] || fm_stage_name_valid "$stage" || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ "$at" -le $((now + _FM_GOAL_MARK_FUTURE_TOLERANCE)) ] || return 1
  FM_GOAL_PROGRESS_ATS[${#FM_GOAL_PROGRESS_ATS[@]}]=$at
  if idx=$(_fm_goal_index_of "$item"); then
    if [ -n "$state" ] && { [ -z "${FM_GOAL_M_ATS[$idx]}" ] || [ "$at" -ge "${FM_GOAL_M_ATS[$idx]}" ]; }; then
      FM_GOAL_M_STATES[idx]=$state
      FM_GOAL_M_ATS[idx]=$at
      FM_GOAL_M_NOTES[idx]=$note
      FM_GOAL_M_TASKS[idx]=$task
    fi
    if [ -n "$stage" ] && { [ -z "${FM_GOAL_S_ATS[$idx]}" ] || [ "$at" -ge "${FM_GOAL_S_ATS[$idx]}" ]; }; then
      FM_GOAL_S_STAGES[idx]=$stage
      FM_GOAL_S_ATS[idx]=$at
    fi
  else
    for u in ${FM_GOAL_UNPLANNED_IDS[@]+"${FM_GOAL_UNPLANNED_IDS[@]}"}; do
      [ "$u" != "$item" ] || { known=1; break; }
    done
    if [ "$known" -eq 0 ]; then
      FM_GOAL_UNPLANNED_IDS[${#FM_GOAL_UNPLANNED_IDS[@]}]=$item
      FM_GOAL_UNPLANNED_STATES[${#FM_GOAL_UNPLANNED_STATES[@]}]=${state:-stage $stage}
      FM_GOAL_UNPLANNED_ATS[${#FM_GOAL_UNPLANNED_ATS[@]}]=$at
    fi
  fi
  if [ -z "$FM_GOAL_FOLD_LAST_AT" ] || [ "$at" -ge "$FM_GOAL_FOLD_LAST_AT" ]; then
    FM_GOAL_FOLD_LAST_AT=$at
    FM_GOAL_FOLD_LAST_OWNER=$owner
  fi
  return 0
}

# Parse one `goal [...]` line and hand it to _fm_goal_fold_apply_mark.
_fm_goal_fold_goal_line() {  # <line> <goal-id> <now> <owner>
  local line=$1 goal=$2 now=$3 owner=$4
  local head verb token key value item='' state='' task='' at='' stage='' note seen_goal=0
  verb=${line%% *}
  [ "$verb" = goal ] || return 2
  case "$line" in *:*) head=${line%%:*}; note=${line#*:} ;; *) return 1 ;; esac
  head=${head#goal }
  while :; do
    head=${head#"${head%%[![:space:]]*}"}
    [ -n "$head" ] || break
    token=${head%%[[:space:]]*}
    head=${head#"$token"}
    case "$token" in
      \[*\]) token=${token#\[}; token=${token%\]} ;;
      *) return 1 ;;
    esac
    case "$token" in
      *=*) key=${token%%=*}; value=${token#*=} ;;
      *) return 1 ;;
    esac
    case "$key" in
      goal)
        [ "$seen_goal" -eq 0 ] || return 1
        seen_goal=1
        [ "$value" = "$goal" ] || return 2 ;;
      item) [ -z "$item" ] || return 1; item=$value ;;
      state) [ -z "$state" ] || return 1; state=$value ;;
      task) [ -z "$task" ] || return 1; task=$value ;;
      stage) [ -z "$stage" ] || return 1; stage=$value ;;
      at) [ -z "$at" ] || return 1; at=$value ;;
      *) return 1 ;;
    esac
  done
  [ "$seen_goal" -eq 1 ] && [ -n "$item" ] && { [ -n "$state" ] || [ -n "$stage" ]; } && [ -n "$at" ] || return 1
  fm_goal_id_valid "$item" || return 1
  [ -z "$task" ] || fm_goal_id_valid "$task" || return 1
  case "$at" in *[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#at}" -le 12 ] || return 1
  _fm_goal_fold_apply_mark "$goal" "$item" "$state" "$at" "$task" "${note# }" "$now" "$owner" "$stage"
}

# Track a done [key=merged-<task>] landing line in an owner stream.
_fm_goal_fold_landing_line() {  # <line>
  local line=$1 key='' at_epoch token head rest verb i
  case "$line" in *:*) head=${line%%:*} ;; *) return 0 ;; esac
  status_line_verb "$line" verb
  [ "$verb" = "done" ] || return 0
  rest=${head#done }
  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    token=${rest%%[[:space:]]*}
    rest=${rest#"$token"}
    case "$token" in
      '[key=merged-'*)
        [ -z "$key" ] || return 0
        key=${token#'[key=merged-'}; key=${key%\]}
        ;;
    esac
  done
  [ -n "$key" ] || return 0
  fm_goal_id_valid "$key" || return 0
  _fm_status_at_epoch "$line" at_epoch || return 0
  case "$at_epoch" in ''|*[!0-9]*) return 0 ;; esac
  [ "$at_epoch" -le $((_FM_GOAL_FOLD_NOW + _FM_GOAL_MARK_FUTURE_TOLERANCE)) ] || return 0
  i=0
  while [ "$i" -lt "${#FM_GOAL_MERGED_TASKS[@]}" ]; do
    if [ "${FM_GOAL_MERGED_TASKS[$i]}" = "$key" ]; then
      [ "$at_epoch" -le "${FM_GOAL_MERGED_ATS[i]}" ] || FM_GOAL_MERGED_ATS[i]=$at_epoch
      return 0
    fi
    i=$((i + 1))
  done
  FM_GOAL_MERGED_TASKS[${#FM_GOAL_MERGED_TASKS[@]}]=$key
  FM_GOAL_MERGED_ATS[${#FM_GOAL_MERGED_ATS[@]}]=$at_epoch
  return 0
}

# The owner-stream file for <owner>: state/<owner>.status, or the archived
# data/<owner>/status.log once the state file is gone. Refuses symlinks.
_fm_goal_owner_stream() {  # <state-dir> <data-dir> <owner>
  local state=$1 data=$2 owner=$3 path
  path="$state/$owner.status"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    path="$data/$owner/status.log"
  fi
  _fm_goal_regular_file "$path" || return 1
  printf '%s' "$path"
}

_fm_goal_fold_stream() {  # <state> <data> <owner> <id> <now>
  local state=$1 data=$2 owner=$3 id=$4 now=$5 path line rc
  path=$(_fm_goal_owner_stream "$state" "$data" "$owner") || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    _fm_goal_fold_goal_line "$line" "$id" "$now" "$owner"
    rc=$?
    [ "$rc" -ne 1 ] || FM_GOAL_FOLD_IGNORED=$((FM_GOAL_FOLD_IGNORED + 1))
    _fm_goal_fold_landing_line "$line"
  done < "$path"
  return 0
}

# Fold goal <id> from its sources. Requires the record loaded. When
# <marks-override> is set, it replaces the marks file and the owner streams
# are not scanned (the closed-archive read).
fm_goal_fold() {  # <id> [state-dir] [data-dir] [now] [marks-override]
  local id=$1 state=${2:-$FM_GOAL_STATE} data=${3:-$FM_GOAL_DATA}
  local now=${4:-$(date +%s)} override=${5-}
  local path line rc owner i seen_owners=''
  _fm_goal_fold_reset
  _FM_GOAL_FOLD_NOW=$now
  if [ -n "$override" ]; then
    path=$override
  else
    path=$(fm_goal_marks_path "$id" "$state")
  fi
  if [ -n "$override" ]; then
    # the closed-archive read: archived marks only, owner streams not re-scanned
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in *[![:space:]]*) ;; *) continue ;; esac
      _fm_goal_fold_goal_line "$line" "$id" "$now" '-'
      rc=$?
      [ "$rc" -ne 1 ] || FM_GOAL_FOLD_IGNORED=$((FM_GOAL_FOLD_IGNORED + 1))
    done < "$path" 2>/dev/null || true
    _fm_goal_fold_tasks
    return 0
  fi
  # Local marks first, then distinct owners in item order. Later lines win
  # equal timestamps, including across these ordered sources.
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in *[![:space:]]*) ;; *) continue ;; esac
      _fm_goal_fold_goal_line "$line" "$id" "$now" '-'
      rc=$?
      [ "$rc" -ne 1 ] || FM_GOAL_FOLD_IGNORED=$((FM_GOAL_FOLD_IGNORED + 1))
    done < "$path"
  fi
  i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    owner=${FM_GOAL_ITEMS_OWNERS[$i]}
    case " $seen_owners " in
      *" $owner "*) ;;
      *)
        seen_owners="$seen_owners $owner"
        _fm_goal_fold_stream "$state" "$data" "$owner" "$id" "$now"
        ;;
    esac
    i=$((i + 1))
  done
  _fm_goal_fold_tasks
  return 0
}

# A mark may bind an item to the child that actually does the work.
_fm_goal_fold_tasks() {
  local i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    [ -z "${FM_GOAL_M_TASKS[$i]}" ] || FM_GOAL_ITEMS_TASKS[i]=${FM_GOAL_M_TASKS[$i]}
    i=$((i + 1))
  done
}

# --- derived projection ------------------------------------------------------

_fm_goal_item_doneish() {  # <idx>
  case "${FM_GOAL_M_STATES[$1]}" in
    done|dropped) return 0 ;;
  esac
  return 1
}

# waiting_on for item <idx> in FM_GOAL_WAITING: the after ids not done or
# dropped (comma separated), or ''.
_fm_goal_item_waiting() {  # <idx>
  local idx=$1 refs part out='' ref
  FM_GOAL_WAITING=''
  refs=${FM_GOAL_ITEMS_AFTERS[$idx]}
  [ -z "$refs" ] && return 0
  local LC_ALL=C IFS=,
  for part in $refs; do
    ref=$(_fm_goal_index_of "$part") || continue
    _fm_goal_item_doneish "$ref" && continue
    case ",$out," in *",$part,"*) continue ;; esac
    if [ -n "$out" ]; then out="$out,$part"; else out=$part; fi
  done
  FM_GOAL_WAITING=$out
  return 0
}

# 0 iff item <idx> carries an `until=` limit that has passed.
_fm_goal_item_expired() {  # <idx>
  local until=${FM_GOAL_ITEMS_UNTILS[$1]}
  [ -n "$until" ] && [ "$_FM_GOAL_FOLD_NOW" -gt "$until" ]
}

# The folded stage of item <idx>, or '' when no stage mark exists.
_fm_goal_item_stage() {  # <idx>
  printf '%s' "${FM_GOAL_S_STAGES[$1]}"
}

# 0 iff item <idx> has a target and its stage has reached it: the same rung,
# or a higher rung of the project's ladder when the ladder file is readable.
_fm_goal_item_target_reached() {  # <idx>
  local idx=$1 target stage cur want
  target=${FM_GOAL_ITEMS_TARGETS[$idx]}
  [ -n "$target" ] || return 1
  stage=${FM_GOAL_S_STAGES[$idx]}
  [ -n "$stage" ] || return 1
  [ "$stage" != "$target" ] || return 0
  fm_stage_ladder_load "$FM_GOAL_CONFIG" "${FM_GOAL_ITEMS_PROJECTS[$idx]}" || return 1
  cur=$(fm_stage_ladder_rank "$stage") || return 1
  want=$(fm_stage_ladder_rank "$target") || return 1
  [ "$cur" -ge "$want" ]
}

_fm_goal_item_startable() {  # <idx>
  [ "${FM_GOAL_ITEMS_CLASSES[$1]}" = drive ] || return 1
  [ "${FM_GOAL_M_STATES[$1]}" = open ] || return 1
  ! _fm_goal_item_expired "$1" || return 1
  _fm_goal_item_waiting "$1"
  [ -z "$FM_GOAL_WAITING" ] || return 1
  return 0
}

# The landing hint for item <idx>: its task merged with no newer goal update.
# For a main-home task (state/<task>.meta exists), validate the merge-notified
# marker through its owner and compare its modification epoch with the mark.
# Otherwise a done [key=merged-<task>] line supplies the landing epoch.
_fm_goal_item_landing() {  # <idx> [state-dir]
  local idx=$1 state=${2:-$FM_GOAL_STATE}
  local task at i merged
  task=${FM_GOAL_ITEMS_TASKS[$idx]}
  [ -n "$task" ] || return 1
  at=${FM_GOAL_M_ATS[$idx]}
  if [ -f "$state/$task.meta" ] && [ ! -L "$state/$task.meta" ]; then
    fm_pr_metadata_identity_parse "$state/$task.meta" || return 1
    fm_pr_poll_merge_already_notified "$state" "$task" \
      "$FM_PR_META_PROVIDER" "$FM_PR_META_HOST" "$FM_PR_META_PATH" "$FM_PR_META_NUMBER" || return 1
    _fm_goal_lock_helpers || return 1
    merged=$(fm_path_mtime "$state/$task.pr-poll-merge-notified") || return 1
    [ -z "$at" ] || [ "$merged" -gt "$at" ]
    return
  fi
  merged=''
  i=0
  while [ "$i" -lt "${#FM_GOAL_MERGED_TASKS[@]}" ]; do
    if [ "${FM_GOAL_MERGED_TASKS[$i]}" = "$task" ]; then
      merged=${FM_GOAL_MERGED_ATS[$i]}
      break
    fi
    i=$((i + 1))
  done
  [ -n "$merged" ] || return 1
  [ -z "$at" ] && return 0
  [ "$merged" -gt "$at" ]
}

_fm_goal_closed_count() {
  local i=0 n=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    _fm_goal_item_doneish "$i" && n=$((n + 1))
    i=$((i + 1))
  done
  printf '%s' "$n"
}

# fm_goal_project <id> [state-dir] [data-dir] [now]: print the projection:
# a header line, one line per item, and a progress line. For a closed goal the
# newest closed archive is read (its archived marks; owner streams are not
# re-scanned - their marks were copied in at close).
fm_goal_project() {  # <id> [state-dir] [data-dir] [now]
  local id=$1 state=${2:-$FM_GOAL_STATE} data=${3:-$FM_GOAL_DATA} now=${4:-$(date +%s)}
  local i path startable landing
  if ! _fm_goal_open_record "$id" "$state" >/dev/null 2>&1; then
    path=$(_fm_goal_newest_closed "$id" "$state" 2>/dev/null) || return 1
    _fm_goal_load_record "$path" || return 1
    fm_goal_fold "$id" "$state" "$data" "$now" "${path%.goal}.marks"
    printf 'goal %s state=closed started=%s closed=%s closed_reason=%s\n' \
      "$FM_GOAL_REC_ID" "$FM_GOAL_REC_STARTED_EPOCH" "$FM_GOAL_REC_CLOSED_EPOCH" "${FM_GOAL_REC_CLOSED_REASON}"
  else
    fm_goal_fold "$id" "$state" "$data" "$now"
    printf 'goal %s state=active started=%s\n' "$FM_GOAL_REC_ID" "$FM_GOAL_REC_STARTED_EPOCH"
  fi
  i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    _fm_goal_item_waiting "$i"
    if _fm_goal_item_startable "$i"; then startable=yes; else startable=no; fi
    if _fm_goal_item_landing "$i" "$state"; then landing=yes; else landing=no; fi
    printf 'item %s owner=%s class=%s state=%s since=%s task=%s startable=%s waiting_on=%s landing_hint=%s\n' \
      "${FM_GOAL_ITEMS_IDS[$i]}" "${FM_GOAL_ITEMS_OWNERS[$i]}" "${FM_GOAL_ITEMS_CLASSES[$i]}" \
      "${FM_GOAL_M_STATES[$i]}" "${FM_GOAL_M_ATS[$i]:--}" "${FM_GOAL_ITEMS_TASKS[$i]:--}" \
      "$startable" "${FM_GOAL_WAITING:--}" "$landing"
    # a v2 item appends its stage fields; a v1 item's line is unchanged
    [ -z "${FM_GOAL_ITEMS_PROJECTS[$i]}" ] || printf 'item %s project=%s stage=%s target=%s\n' \
      "${FM_GOAL_ITEMS_IDS[$i]}" "${FM_GOAL_ITEMS_PROJECTS[$i]}" \
      "${FM_GOAL_S_STAGES[$i]:--}" "${FM_GOAL_ITEMS_TARGETS[$i]:--}"
    i=$((i + 1))
  done
  if [ -n "$FM_GOAL_FOLD_LAST_AT" ]; then
    printf 'progress last=%s age=%s ignored=%s\n' \
      "$FM_GOAL_FOLD_LAST_AT" "$(fm_goal_age $((now - FM_GOAL_FOLD_LAST_AT)))" "$FM_GOAL_FOLD_IGNORED"
  else
    printf 'progress last=- age=- ignored=%s\n' "$FM_GOAL_FOLD_IGNORED"
  fi
  return 0
}

# --- record discovery --------------------------------------------------------

# Open the live record for <id>: 0 and loaded, or 1 (missing, damaged, or not
# active) with a message on stderr.
_fm_goal_open_record() {  # <id> [state-dir]
  local id=$1 state=${2:-$FM_GOAL_STATE} path
  fm_goal_id_valid "$id" || return 1
  [ ! -L "$(fm_goal_dir "$state")" ] || return 1
  path=$(fm_goal_path "$id" "$state")
  case "$(_fm_goal_regular_file_kind "$path")" in
    0) ;;
    2) fm_goal_log "no active goal record for '$id' at $path"; return 1 ;;
    *) fm_goal_log "the goal record path is not a regular file: $path"; return 1 ;;
  esac
  fm_goal_validate "$path" "$id" || return 1
  [ "$FM_GOAL_REC_STATE" = active ] || {
    fm_goal_log "goal '$id' is not active (${FM_GOAL_REC_STATE})"
    return 1
  }
  return 0
}

# The newest closed archive for <id>, printed, or 1 with none.
_fm_goal_newest_closed() {  # <id> [state-dir]
  local id=$1 state=${2:-$FM_GOAL_STATE} dir path best='' best_epoch='' epoch
  fm_goal_id_valid "$id" || return 1
  dir=$(fm_goal_closed_dir "$state")
  [ ! -L "$dir" ] && [ ! -L "$(fm_goal_dir "$state")" ] || return 1
  for path in "$dir/$id"-*.goal "$dir/$id.goal"; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    [ -r "$path" ] || continue
    epoch=${path##*/}; epoch=${epoch#"$id"-}; epoch=${epoch%.goal}
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$best" ] || [ "$epoch" -gt "$best_epoch" ]; then
      best=$path
      best_epoch=$epoch
    fi
  done
  [ -n "$best" ] || { fm_goal_log "no closed record for '$id' in $dir"; return 1; }
  printf '%s\n' "$best"
  return 0
}

# Every active goal record path, printed in start order (started_epoch, then
# id); rc 1 with none. Damaged records are logged and skipped: an unreadable
# record must not hide the readable ones behind it.
fm_goal_active_records() {  # [state-dir]
  local state=${1:-$FM_GOAL_STATE} dir path rows=''
  dir=$(fm_goal_dir "$state")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  for path in "$dir"/*.goal; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    if ! _fm_goal_load_record "$path"; then
      fm_goal_log "skipping unreadable goal record $path: $_FM_GOAL_READ_ERROR"
      continue
    fi
    [ "$FM_GOAL_REC_STATE" = active ] || continue
    rows="$rows$(printf '%010d\t%s\t%s' "$FM_GOAL_REC_STARTED_EPOCH" "$FM_GOAL_REC_ID" "$path")"$'\n'
  done
  [ -n "$rows" ] || return 1
  printf '%s' "$rows" | LC_ALL=C sort | cut -f3
  return 0
}

# Every active goal id, printed in start order; rc 1 with none.
fm_goal_active_ids() {  # [state-dir]
  local rows path
  rows=$(fm_goal_active_records "${1:-$FM_GOAL_STATE}") || return 1
  printf '%s\n' "$rows" | while IFS= read -r path; do
    path=${path##*/}
    printf '%s\n' "${path%.goal}"
  done
  return 0
}

# --- the away record's named goals (bin/fm-afk-contract.sh owns the field) ---

# When state/.afk-contract carries a drive_goals field naming ids, print them
# in the recorded order; rc 1 when there is no away record or it names none.
_fm_goal_away_named() {  # [state-dir]
  local state=${1:-$FM_GOAL_STATE} record value count=0 id
  record="$state/.afk-contract"
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  value=$(sed -n 's/^drive_goals: //p' "$record" | head -1)
  case "$value" in ''|'-') return 1 ;; esac
  for id in $(printf '%s' "$value" | LC_ALL=C tr ',' ' '); do
    fm_goal_id_valid "$id" || continue
    printf '%s\n' "$id"
    count=$((count + 1))
  done
  [ "$count" -ge 1 ] || return 1
  return 0
}

# --- rendering: show ---------------------------------------------------------

_fm_goal_note_bounded() {  # <text> -> note cut for one indented line
  printf '%s' "$1" | LC_ALL=C tr '\t' ' ' | cut -c1-120
}

# The stage, target and limits lines of one item in `show` (nothing for a v1
# item that carries none of them).
_fm_goal_show_stage_lines() {  # <idx> <now>
  local idx=$1 now=$2 stage target line
  stage=${FM_GOAL_S_STAGES[$idx]}
  target=${FM_GOAL_ITEMS_TARGETS[$idx]}
  if [ -n "$stage" ] || [ -n "$target" ]; then
    line="    stage: ${stage:-none yet}"
    [ -z "${FM_GOAL_S_ATS[$idx]}" ] || line="$line since ${FM_GOAL_S_ATS[$idx]} ($(fm_goal_age $((now - FM_GOAL_S_ATS[idx]))) ago)"
    [ -z "$target" ] || line="$line, target: $target"
    if _fm_goal_item_target_reached "$idx"; then line="$line (reached)"; fi
    printf '%s\n' "$line"
  fi
  line=''
  if [ -n "${FM_GOAL_ITEMS_UNTILS[$idx]}" ]; then
    line="until $(fm_goal_epoch_iso "${FM_GOAL_ITEMS_UNTILS[$idx]}")"
    ! _fm_goal_item_expired "$idx" || line="$line (passed: not startable)"
  fi
  [ -z "${FM_GOAL_ITEMS_STOPONS[$idx]}" ] || line="${line:+$line, }stop on ${FM_GOAL_ITEMS_STOPONS[$idx]}"
  [ -z "$line" ] || printf '    limits: %s\n' "$line"
}

fm_goal_render_show() {  # <id> [state-dir] [data-dir]
  local id=$1 state=${2:-$FM_GOAL_STATE} data=${3:-$FM_GOAL_DATA}
  local now i startable landing line
  now=$(date +%s)
  _fm_goal_open_record "$id" "$state" || return 1
  fm_goal_fold "$id" "$state" "$data" "$now"
  printf 'GOAL %s: %s\n' "$FM_GOAL_REC_ID" "$FM_GOAL_REC_TITLE"
  printf '  state: %s, started %s (%s ago), named by %s\n' \
    "$FM_GOAL_REC_STATE" "$FM_GOAL_REC_STARTED" \
    "$(fm_goal_age $((now - FM_GOAL_REC_STARTED_EPOCH)))" "$FM_GOAL_REC_NAMED_BY"
  printf '  plan: %s\n' "$FM_GOAL_REC_PLAN"
  printf '  done when: %s\n' "$FM_GOAL_REC_DONE_WHEN"
  printf '  progress: %s/%s items done or dropped; last goal update %s\n' \
    "$(_fm_goal_closed_count)" "$FM_GOAL_ITEM_COUNT" \
    "$([ -n "$FM_GOAL_FOLD_LAST_AT" ] && printf '%s ago (%s)' "$(fm_goal_age $((now - FM_GOAL_FOLD_LAST_AT)))" "${FM_GOAL_FOLD_LAST_OWNER:--}" || printf 'never')"
  i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    _fm_goal_item_waiting "$i"
    if _fm_goal_item_startable "$i"; then startable=yes; else startable=no; fi
    if _fm_goal_item_landing "$i" "$state"; then landing=yes; else landing=no; fi
    line="  item ${FM_GOAL_ITEMS_IDS[$i]} [owner=${FM_GOAL_ITEMS_OWNERS[$i]} class=${FM_GOAL_ITEMS_CLASSES[$i]}"
    [ -z "${FM_GOAL_ITEMS_TASKS[$i]}" ] || line="$line task=${FM_GOAL_ITEMS_TASKS[$i]}"
    [ -z "${FM_GOAL_ITEMS_PROJECTS[$i]}" ] || line="$line project=${FM_GOAL_ITEMS_PROJECTS[$i]}"
    line="$line]: ${FM_GOAL_ITEMS_TITLES[$i]}"
    printf '%s\n' "$line"
    _fm_goal_show_stage_lines "$i" "$now"
    if [ -n "${FM_GOAL_M_ATS[$i]}" ]; then
      printf '    state: %s since %s (%s ago) - %s\n' \
        "${FM_GOAL_M_STATES[$i]}" "${FM_GOAL_M_ATS[$i]}" \
        "$(fm_goal_age $((now - FM_GOAL_M_ATS[i])))" \
        "$(_fm_goal_note_bounded "${FM_GOAL_M_NOTES[$i]}")"
    else
      printf '    state: open (no mark yet)\n'
    fi
    line="    startable: $startable"
    [ -z "$FM_GOAL_WAITING" ] || line="$line (waiting on: $FM_GOAL_WAITING)"
    printf '%s\n' "$line"
    [ "$landing" = no ] || printf '    landing: %s merged with no newer goal update\n' "${FM_GOAL_ITEMS_TASKS[$i]}"
    i=$((i + 1))
  done
  if [ "${#FM_GOAL_UNPLANNED_IDS[@]}" -gt 0 ]; then
    line='  unplanned items (marked but not in the record):'
    i=0
    while [ "$i" -lt "${#FM_GOAL_UNPLANNED_IDS[@]}" ]; do
      line="$line ${FM_GOAL_UNPLANNED_IDS[$i]} (${FM_GOAL_UNPLANNED_STATES[$i]})"
      i=$((i + 1))
    done
    printf '%s\n' "$line"
  fi
  [ "$FM_GOAL_FOLD_IGNORED" -eq 0 ] || printf '  ignored marks: %s (malformed or future-stamped)\n' "$FM_GOAL_FOLD_IGNORED"
  return 0
}

# --- rendering: brief (bounded) ----------------------------------------------

# Print each accumulated \x01-separated brief line, capped.
_fm_goal_brief_print_lines() {  # <accumulated>
  printf '%s' "$1" | tr "$FM_GOAL_BRIEF_SEP" '\n' | while IFS= read -r line; do
    [ -n "$line" ] || continue
    fm_cap_line_var "$line"
    printf '%s\n' "$FM_LINE_CAP_LINE"
  done
}

# One goal's brief block (parent-home form), ~FM_GOAL_BRIEF_PER_GOAL_BYTES.
# <away> is '' (no away record), 'named', or 'unnamed'.
_fm_goal_brief_block() {  # <id> <state> <data> <away>
  local id=$1 state=$2 data=$3 away=$4
  local now i line startable_n=0 more=0 startable_list=''
  local running='' waiting='' blocked='' captain='' landing='' short=''
  now=$(date +%s)
  _fm_goal_open_record "$id" "$state" || return 1
  fm_goal_fold "$id" "$state" "$data" "$now"
  line="GOAL $id (active since $FM_GOAL_REC_STARTED"
  case "$away" in
    named) line="$line; driven while away: yes, named)" ;;
    unnamed) line="$line; driven while away: yes, active goal)" ;;
    *) line="$line)" ;;
  esac
  line="$line: $FM_GOAL_REC_TITLE"
  fm_cap_line_var "$line"; printf '%s\n' "$FM_LINE_CAP_LINE"
  fm_cap_line_var "  done when: $FM_GOAL_REC_DONE_WHEN"; printf '%s\n' "$FM_LINE_CAP_LINE"
  if [ -n "$FM_GOAL_FOLD_LAST_AT" ]; then
    line="  progress: $(_fm_goal_closed_count)/$FM_GOAL_ITEM_COUNT items done or dropped; last goal update $(fm_goal_age $((now - FM_GOAL_FOLD_LAST_AT))) ago (${FM_GOAL_FOLD_LAST_OWNER:--})"
  else
    line="  progress: $(_fm_goal_closed_count)/$FM_GOAL_ITEM_COUNT items done or dropped; last goal update never"
  fi
  fm_cap_line_var "$line"; printf '%s\n' "$FM_LINE_CAP_LINE"
  i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    _fm_goal_item_waiting "$i"
    if _fm_goal_item_startable "$i"; then
      if [ "$startable_n" -lt "$FM_GOAL_BRIEF_ITEM_LIST" ]; then
        if [ -n "$startable_list" ]; then startable_list="$startable_list, "; fi
        startable_list="$startable_list${FM_GOAL_ITEMS_IDS[$i]} [${FM_GOAL_ITEMS_OWNERS[$i]}]"
      else
        more=$((more + 1))
      fi
      startable_n=$((startable_n + 1))
    fi
    case "${FM_GOAL_M_STATES[$i]}" in
      running)
        line="  running: ${FM_GOAL_ITEMS_IDS[$i]} [${FM_GOAL_ITEMS_OWNERS[$i]}"
        [ -z "${FM_GOAL_ITEMS_TASKS[$i]}" ] || line="$line, task ${FM_GOAL_ITEMS_TASKS[$i]}"
        [ -z "${FM_GOAL_M_ATS[$i]}" ] || line="$line, $(fm_goal_age $((now - FM_GOAL_M_ATS[i])))"
        running="$running$line]$FM_GOAL_BRIEF_SEP"
        ;;
      open)
        _fm_goal_item_waiting "$i"
        [ -z "$FM_GOAL_WAITING" ] || waiting="$waiting  waiting: ${FM_GOAL_ITEMS_IDS[$i]} after $FM_GOAL_WAITING$FM_GOAL_BRIEF_SEP"
        ;;
      waiting)
        waiting="$waiting  waiting: ${FM_GOAL_ITEMS_IDS[$i]} [${FM_GOAL_ITEMS_OWNERS[$i]}] (marked waiting)$FM_GOAL_BRIEF_SEP"
        ;;
      blocked)
        blocked="$blocked  blocked: ${FM_GOAL_ITEMS_IDS[$i]} [${FM_GOAL_ITEMS_OWNERS[$i]}]$FM_GOAL_BRIEF_SEP"
        ;;
    esac
    if [ "${FM_GOAL_ITEMS_CLASSES[$i]}" = captain ] && ! _fm_goal_item_doneish "$i"; then
      case "$away" in
        named|unnamed)
          captain="$captain  needs the captain: ${FM_GOAL_ITEMS_IDS[$i]} - never advanced while away$FM_GOAL_BRIEF_SEP"
          ;;
        *)
          captain="$captain  needs the captain: ${FM_GOAL_ITEMS_IDS[$i]}$FM_GOAL_BRIEF_SEP"
          ;;
      esac
    fi
    if _fm_goal_item_landing "$i" "$state"; then
      landing="$landing  unrecorded landing: ${FM_GOAL_ITEMS_TASKS[$i]} merged (item ${FM_GOAL_ITEMS_IDS[$i]}), no goal update since$FM_GOAL_BRIEF_SEP"
    fi
    if [ -n "${FM_GOAL_ITEMS_TARGETS[$i]}" ] && [ "${FM_GOAL_M_STATES[$i]}" != dropped ] && ! _fm_goal_item_target_reached "$i"; then
      short="$short  short of target: ${FM_GOAL_ITEMS_IDS[$i]} at ${FM_GOAL_S_STAGES[$i]:-no stage}, target ${FM_GOAL_ITEMS_TARGETS[$i]}$FM_GOAL_BRIEF_SEP"
    fi
    i=$((i + 1))
  done
  if [ "$startable_n" -gt 0 ]; then
    line="  startable, nobody on it: $startable_list"
    [ "$more" -eq 0 ] || line="$line, +$more more"
    fm_cap_line_var "$line"; printf '%s\n' "$FM_LINE_CAP_LINE"
  fi
  _fm_goal_brief_print_lines "$running"
  _fm_goal_brief_print_lines "$waiting"
  _fm_goal_brief_print_lines "$blocked"
  _fm_goal_brief_print_lines "$captain"
  _fm_goal_brief_print_lines "$landing"
  _fm_goal_brief_print_lines "$short"
  return 0
}

# One goal's brief block (secondmate form): the parent's goal filtered to
# this mate's items. rc 2 when the mate owns no item of this goal.
_fm_goal_brief_block_mate() {  # <id> <state> <data> <mate> <away>
  local id=$1 state=$2 data=$3 mate=$4 away=$5
  local now i line closed=0 mine=0 running='' waiting='' captain='' landing=''
  now=$(date +%s)
  _fm_goal_open_record "$id" "$state" || return 1
  fm_goal_fold "$id" "$state" "$data" "$now"
  i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    [ "${FM_GOAL_ITEMS_OWNERS[$i]}" = "$mate" ] || { i=$((i + 1)); continue; }
    mine=$((mine + 1))
    i=$((i + 1))
  done
  [ "$mine" -ge 1 ] || return 2
  fm_cap_line_var "PARENT GOAL $id (your items; the parent firstmate owns the record): $FM_GOAL_REC_TITLE"
  printf '%s\n' "$FM_LINE_CAP_LINE"
  fm_cap_line_var "  done when: $FM_GOAL_REC_DONE_WHEN"; printf '%s\n' "$FM_LINE_CAP_LINE"
  i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    [ "${FM_GOAL_ITEMS_OWNERS[$i]}" = "$mate" ] || { i=$((i + 1)); continue; }
    _fm_goal_item_doneish "$i" && closed=$((closed + 1))
    if _fm_goal_item_startable "$i"; then
      fm_cap_line_var "  startable, nobody on it: ${FM_GOAL_ITEMS_IDS[$i]} [$mate]"
      printf '%s\n' "$FM_LINE_CAP_LINE"
    fi
    case "${FM_GOAL_M_STATES[$i]}" in
      running)
        line="  running: ${FM_GOAL_ITEMS_IDS[$i]} [${FM_GOAL_ITEMS_OWNERS[$i]}"
        [ -z "${FM_GOAL_ITEMS_TASKS[$i]}" ] || line="$line, task ${FM_GOAL_ITEMS_TASKS[$i]}"
        [ -z "${FM_GOAL_M_ATS[$i]}" ] || line="$line, $(fm_goal_age $((now - FM_GOAL_M_ATS[i])))"
        running="$running$line]$FM_GOAL_BRIEF_SEP"
        ;;
      waiting)
        waiting="$waiting  waiting: ${FM_GOAL_ITEMS_IDS[$i]} (marked waiting)$FM_GOAL_BRIEF_SEP"
        ;;
      open)
        _fm_goal_item_waiting "$i"
        [ -z "$FM_GOAL_WAITING" ] || waiting="$waiting  waiting: ${FM_GOAL_ITEMS_IDS[$i]} after $FM_GOAL_WAITING$FM_GOAL_BRIEF_SEP"
        ;;
    esac
    if [ "${FM_GOAL_ITEMS_CLASSES[$i]}" = captain ] && ! _fm_goal_item_doneish "$i"; then
      case "$away" in
        named|unnamed)
          captain="$captain  needs the captain: ${FM_GOAL_ITEMS_IDS[$i]} - never advanced while away$FM_GOAL_BRIEF_SEP"
          ;;
        *)
          captain="$captain  needs the captain: ${FM_GOAL_ITEMS_IDS[$i]}$FM_GOAL_BRIEF_SEP"
          ;;
      esac
    fi
    if _fm_goal_item_landing "$i" "$state"; then
      landing="$landing  unrecorded landing: ${FM_GOAL_ITEMS_TASKS[$i]} merged (item ${FM_GOAL_ITEMS_IDS[$i]}), no goal update since$FM_GOAL_BRIEF_SEP"
    fi
    i=$((i + 1))
  done
  if [ -n "$FM_GOAL_FOLD_LAST_AT" ]; then
    line="  progress (your items): $closed/$mine done or dropped; last goal update $(fm_goal_age $((now - FM_GOAL_FOLD_LAST_AT))) ago"
  else
    line="  progress (your items): $closed/$mine done or dropped; last goal update never"
  fi
  fm_cap_line_var "$line"; printf '%s\n' "$FM_LINE_CAP_LINE"
  _fm_goal_brief_print_lines "$running"
  _fm_goal_brief_print_lines "$waiting"
  _fm_goal_brief_print_lines "$captain"
  _fm_goal_brief_print_lines "$landing"
  return 0
}

# fm_goal_render_brief: the bounded brief for this home.
#   - a parent home: every active goal, away-named goals first and labeled;
#   - a secondmate home: the parent's goals filtered to this mate's items
#     (local route, read-only), or the remote-route notice.
# Byte caps: FM_GOAL_BRIEF_PER_GOAL_BYTES per goal, FM_GOAL_BRIEF_TOTAL_BYTES
# overall; goals past the budget collapse to one line.
fm_goal_render_brief() {
  local home=$FM_GOAL_HOME state=$FM_GOAL_STATE data=$FM_GOAL_DATA
  local rc=0 id block out='' used=0 named='' away_kind='' mate away
  local block_len path paths duty invalid=0
  duty='GOAL DUTY: start every startable item now (steer its owner or dispatch it); record with bin/fm-goal.sh mark <goal> <item> <state> -- <note>; full view: bin/fm-goal.sh show <goal>'
  local -a order=()
  fm_parent_channel_destination "$home" "$state" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ "$FM_PARENT_CHANNEL_ROUTE" != local ]; then
      printf 'PARENT GOAL: the parent channel is remote; the parent goal brief is not readable here\n'
      return 0
    fi
    [ -n "${FM_SECONDMATE_PARENT_HOME:-}" ] || return 0
    state="$FM_SECONDMATE_PARENT_HOME/state"
    data="$FM_SECONDMATE_PARENT_HOME/data"
    mate=$FM_PARENT_CHANNEL_ID
    away_kind=''
    [ "$(_fm_goal_regular_file_kind "$state/.afk-contract")" = 0 ] && away_kind=present
    duty='GOAL DUTY: after every landing or item change run bin/fm-goal.sh mark <goal> <item> <state> -- <note>'
  elif [ "$rc" -ne 1 ]; then
    fm_goal_log "the secondmate identity of this home is unreadable; no goal brief"
    return 0
  fi
  # Named goals first in either home.
  away_kind=''
  [ "$(_fm_goal_regular_file_kind "$state/.afk-contract")" = 0 ] && away_kind=present
  if [ "$away_kind" = present ]; then
    named=$(printf ' %s ' "$(_fm_goal_away_named "$state" 2>/dev/null)" | LC_ALL=C tr '\n' ' ')
  fi
  if [ -n "$named" ] && [ "$named" != '  ' ]; then
    for id in $named; do
      order[${#order[@]}]=$id
    done
  fi
  if [ -L "$(fm_goal_dir "$state")" ]; then
    printf 'GOAL SKIPPED: symlinked goals directory\n'
    return 0
  fi
  paths=$(fm_goal_active_records "$state" 2>/dev/null) || true
  for path in "$(fm_goal_dir "$state")"/*.goal; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    id=${path##*/}; id=${id%.goal}
    fm_goal_validate "$path" "$id" >/dev/null 2>&1 || invalid=1
  done
  if [ "$invalid" -eq 1 ]; then
    out=$'GOAL SKIPPED: one or more goal records are invalid or unreadable\n'
    used=${#out}
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    id=${path##*/}; id=${id%.goal}
    case " ${order[@]:-} " in *" $id "*) continue ;; esac
    order[${#order[@]}]=$id
  done <<< "$paths"
  for id in ${order[@]+"${order[@]}"}; do
    away=''
    if [ "$away_kind" = present ]; then
      case "$named" in
        *" $id "*) away=named ;;
        *) away=unnamed ;;
      esac
    fi
    if [ -n "${mate:-}" ]; then
      block=$(_fm_goal_brief_block_mate "$id" "$state" "$data" "$mate" "$away" 2>/dev/null) || continue
    elif ! block=$(_fm_goal_brief_block "$id" "$state" "$data" "$away" 2>/dev/null); then
      path=$(fm_goal_path "$id" "$state")
      if [ -e "$path" ] || [ -L "$path" ]; then continue; fi
      if _fm_goal_newest_closed "$id" "$state" >/dev/null 2>&1; then continue; fi
      block="GOAL $id: named by the away record but no goal record exists"
    fi
    [ -n "$block" ] || continue
    block_len=$(printf '%s' "$block" | wc -c | tr -d ' ')
    if [ "$block_len" -gt "$FM_GOAL_BRIEF_PER_GOAL_BYTES" ]; then
      block=$(printf '%s' "$block" | head -c "$((FM_GOAL_BRIEF_PER_GOAL_BYTES - 40))")$'\n  (more items in the full goal view)'
      block_len=$(printf '%s' "$block" | wc -c | tr -d ' ')
    fi
    if [ $((used + block_len + ${#duty} + 2)) -le "$FM_GOAL_BRIEF_TOTAL_BYTES" ]; then
      out="$out$block
"
      used=$((used + block_len + 1))
    else
      fm_cap_line_var "GOAL $id (active; collapsed): run bin/fm-goal.sh show $id"
      if [ $((used + ${#FM_LINE_CAP_LINE} + ${#duty} + 2)) -le "$FM_GOAL_BRIEF_TOTAL_BYTES" ]; then
        out="$out$FM_LINE_CAP_LINE
"
        used=$((used + ${#FM_LINE_CAP_LINE} + 1))
      fi
    fi
  done
  [ -n "$out" ] || return 0
  printf '%s%s\n' "$out" "$duty"
  return 0
}

# --- authority ---------------------------------------------------------------

# rc 0 in a parent home; rc 1 in a secondmate home or an unreadable one.
_fm_goal_parent_home() {
  local rc=0
  fm_parent_channel_destination "$FM_GOAL_HOME" "$FM_GOAL_STATE" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    1) return 0 ;;
    0) fm_goal_log "refused: this is a secondmate home; the parent firstmate owns the goal record"; return 1 ;;
    *) fm_goal_log "refused: the secondmate identity of this home is unreadable"; return 1 ;;
  esac
}

# The current actor (main or branch), or exits: an unknown actor is a wiring
# bug and must not fall through as main.
_fm_goal_actor() {
  local actor
  actor=$(fm_lease_actor) || exit 1
  printf '%s' "$actor"
}

_fm_goal_require_actor() {  # <allowed-actors, space separated>
  local actor
  actor=$(_fm_goal_actor)
  case " $1 " in
    *" $actor "*) return 0 ;;
  esac
  fm_goal_log "refused: actor '$actor' may not run this command (allowed: $1)"
  return 1
}

# --- subcommands -------------------------------------------------------------

_fm_goal_usage_error() {  # <message>
  fm_goal_log "$1"
  fm_goal_usage >&2
  exit 2
}

# Load an items file into the FM_GOAL_ITEMS_* arrays. rc 2 with a message on
# any malformed line, duplicate id, unknown after id, or cycle. Blank lines
# and #-comments are ignored.
# Refuse an items list whose `target=` is not a rung of its project's ladder.
# A project with no ladder file has nothing to check against, so its target
# stays a free word; a malformed ladder file fails the list closed.
_fm_goal_check_targets() {  # <path-for-messages>
  local i=0 rc
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    if [ -n "${FM_GOAL_ITEMS_TARGETS[$i]}" ]; then
      rc=0
      fm_stage_ladder_load "$FM_GOAL_CONFIG" "${FM_GOAL_ITEMS_PROJECTS[$i]}" || rc=$?
      case "$rc" in
        0)
          fm_stage_ladder_rank "${FM_GOAL_ITEMS_TARGETS[$i]}" >/dev/null || {
            fm_goal_log "item ${FM_GOAL_ITEMS_IDS[$i]} in $1: target ${FM_GOAL_ITEMS_TARGETS[$i]} is not a stage of project ${FM_GOAL_ITEMS_PROJECTS[$i]} (stages: ${FM_STAGE_LADDER_NAMES[*]})"
            return 2
          }
          ;;
        2) fm_goal_log "item ${FM_GOAL_ITEMS_IDS[$i]} in $1: $FM_STAGE_LADDER_ERROR"; return 2 ;;
      esac
    fi
    i=$((i + 1))
  done
  return 0
}

_fm_goal_load_items_file() {  # <path>
  local path=$1 line
  _fm_goal_items_reset
  if ! { [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ]; }; then
    fm_goal_log "items file is missing, unreadable, or a symlink: $path"
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    if ! fm_goal_item_parse "$line"; then
      fm_goal_log "malformed item line in $path: $line"
      return 2
    fi
    _fm_goal_items_append
  done < "$path"
  [ "$FM_GOAL_ITEM_COUNT" -ge 1 ] || {
    fm_goal_log "no items in $path"
    return 2
  }
  _fm_goal_items_graph_ok || {
    fm_goal_log "invalid items in $path: $_FM_GOAL_READ_ERROR"
    return 2
  }
  _fm_goal_check_targets "$path" || return 2
  return 0
}

# The version a record is written at: 2 when any loaded item carries a schema
# v2 field (project, target, until, stop-on), else 1, so a goal that uses none
# stays byte-compatible with a v1 reader.
_fm_goal_record_version() {
  local i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    if [ -n "${FM_GOAL_ITEMS_PROJECTS[$i]}${FM_GOAL_ITEMS_TARGETS[$i]}${FM_GOAL_ITEMS_UNTILS[$i]}${FM_GOAL_ITEMS_STOPONS[$i]}" ]; then
      printf 2
      return 0
    fi
    i=$((i + 1))
  done
  printf 1
}

# Render a full record from the loaded arrays + the meta globals.
_fm_goal_render_record() {
  local i=0
  printf 'version: %s\n' "$(_fm_goal_record_version)"
  printf 'id: %s\n' "$FM_GOAL_REC_ID"
  printf 'title: %s\n' "$FM_GOAL_REC_TITLE"
  printf 'state: %s\n' "$FM_GOAL_REC_STATE"
  printf 'started: %s\n' "$FM_GOAL_REC_STARTED"
  printf 'started_epoch: %s\n' "$FM_GOAL_REC_STARTED_EPOCH"
  printf 'named_by: %s\n' "$FM_GOAL_REC_NAMED_BY"
  printf 'plan: %s\n' "$FM_GOAL_REC_PLAN"
  printf 'done_when: %s\n' "$FM_GOAL_REC_DONE_WHEN"
  printf 'items:\n'
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    printf '  %s\n' "$(_fm_goal_item_line "$i")"
    i=$((i + 1))
  done
  return 0
}

_fm_goal_write_atomic() {  # <path> (content on stdin)
  local path=$1 pending
  mkdir -p "$(dirname "$path")" || return 1
  pending=$(mktemp "$(dirname "$path")/.goal.pending.XXXXXX") || return 1
  if ! cat > "$pending"; then
    rm -f "$pending"
    return 1
  fi
  mv "$pending" "$path" || { rm -f "$pending"; return 1; }
  return 0
}

cmd_start() {
  local id='' title='' done_when='' named_by='' plan='' items_file=''
  local flag value now started staged path
  [ "$#" -ge 1 ] || _fm_goal_usage_error 'start needs a goal id'
  id=$1
  shift
  while [ "$#" -gt 0 ]; do
    flag=$1
    value=${2-}
    case "$flag" in
      --title|--done-when|--named-by|--plan|--items-file)
        [ "$#" -ge 2 ] && [ -n "$value" ] || _fm_goal_usage_error "$flag needs a value"
        case "$flag" in
          --title) title=$value ;;
          --done-when) done_when=$value ;;
          --named-by) named_by=$value ;;
          --plan) plan=$value ;;
          --items-file) items_file=$value ;;
        esac
        shift 2
        ;;
      *) _fm_goal_usage_error "unknown flag for start: $flag" ;;
    esac
  done
  fm_goal_id_valid "$id" || _fm_goal_usage_error "unsafe goal id: '$id'"
  [ -n "$title" ] || _fm_goal_usage_error 'start needs --title'
  [ -n "$done_when" ] || _fm_goal_usage_error 'start needs --done-when'
  [ -n "$named_by" ] || _fm_goal_usage_error 'start needs --named-by'
  case "$named_by" in *$'\n'*|*$'\r'*) _fm_goal_usage_error '--named-by must be one verbatim line' ;; esac
  [ -n "$plan" ] || _fm_goal_usage_error 'start needs --plan'
  [ -n "$items_file" ] || _fm_goal_usage_error 'start needs --items-file'
  _fm_goal_parent_home || exit 1
  _fm_goal_require_actor main || exit 1
  _fm_goal_load_items_file "$items_file" || exit 2
  path=$(fm_goal_path "$id")
  _fm_goal_regular_file "$path"
  if [ "$?" -ne 2 ]; then
    fm_goal_log "refused: a record for goal '$id' already exists at $path"
    exit 1
  fi
  now=$(date +%s)
  started=$(fm_goal_epoch_iso "$now")
  FM_GOAL_REC_ID=$id
  FM_GOAL_REC_TITLE=$(_fm_goal_clean_field "$title")
  FM_GOAL_REC_STATE=active
  FM_GOAL_REC_STARTED=$started
  FM_GOAL_REC_STARTED_EPOCH=$now
  FM_GOAL_REC_NAMED_BY=$named_by
  FM_GOAL_REC_PLAN=$(_fm_goal_clean_field "$plan")
  FM_GOAL_REC_DONE_WHEN=$(_fm_goal_clean_field "$done_when")
  mkdir -p "$(fm_goal_dir)" || _fm_goal_die 1 'could not create the goals directory'
  fm_goal_lock_hold || exit 1
  _fm_goal_regular_file "$path"
  if [ "$?" -ne 2 ]; then
    fm_goal_lock_release
    fm_goal_log "refused: a record for goal '$id' appeared at $path while starting"
    exit 1
  fi
  staged=$(mktemp "$(fm_goal_dir)/.goal.starting.XXXXXX") || {
    fm_goal_lock_release
    _fm_goal_die 1 'could not stage the goal record'
  }
  _fm_goal_render_record > "$staged" || { rm -f "$staged"; fm_goal_lock_release; exit 1; }
  fm_goal_validate "$staged" "$id" || { rm -f "$staged"; fm_goal_lock_release; exit 1; }
  mv "$staged" "$path" || { rm -f "$staged"; fm_goal_lock_release; _fm_goal_die 1 'could not install the goal record'; }
  fm_goal_lock_release
  printf 'started goal %s at %s with %s item%s\n' "$id" "$started" "$FM_GOAL_ITEM_COUNT" "$([ "$FM_GOAL_ITEM_COUNT" -gt 1 ] && printf s)"
  printf 'record: %s\n' "$path"
  printf 'mark with: fm-goal.sh mark %s <item> <state|stage=<stage>> -- <note>\n' "$id"
  return 0
}

cmd_edit() {
  local id='' items_file='' title='' done_when=''
  local flag value path staged
  local r_id r_title r_started r_started_epoch r_named_by r_plan r_done_when old_count
  [ "$#" -ge 1 ] || _fm_goal_usage_error 'edit needs a goal id'
  id=$1
  shift
  while [ "$#" -gt 0 ]; do
    flag=$1
    value=${2-}
    case "$flag" in
      --items-file)
        [ "$#" -ge 2 ] && [ -n "$value" ] || _fm_goal_usage_error "$flag needs a value"
        items_file=$value
        shift 2
        ;;
      --title|--done-when)
        [ "$#" -ge 2 ] && [ -n "$value" ] || _fm_goal_usage_error "$flag needs a value"
        [ "$flag" = --title ] && title=$value || done_when=$value
        shift 2
        ;;
      *) _fm_goal_usage_error "unknown flag for edit: $flag" ;;
    esac
  done
  fm_goal_id_valid "$id" || _fm_goal_usage_error "unsafe goal id: '$id'"
  [ -n "$items_file" ] || _fm_goal_usage_error 'edit needs --items-file'
  _fm_goal_parent_home || exit 1
  _fm_goal_require_actor main || exit 1
  fm_goal_lock_hold || exit 1
  _fm_goal_open_record "$id" || { fm_goal_lock_release; exit 1; }
  r_id=$FM_GOAL_REC_ID
  r_title=$FM_GOAL_REC_TITLE
  r_started=$FM_GOAL_REC_STARTED
  r_started_epoch=$FM_GOAL_REC_STARTED_EPOCH
  r_named_by=$FM_GOAL_REC_NAMED_BY
  r_plan=$FM_GOAL_REC_PLAN
  r_done_when=$FM_GOAL_REC_DONE_WHEN
  old_count=$FM_GOAL_ITEM_COUNT
  _fm_goal_load_items_file "$items_file" || { fm_goal_lock_release; exit 2; }
  FM_GOAL_REC_ID=$r_id
  FM_GOAL_REC_TITLE=$(_fm_goal_clean_field "${title:-$r_title}")
  FM_GOAL_REC_STATE=active
  FM_GOAL_REC_STARTED=$r_started
  FM_GOAL_REC_STARTED_EPOCH=$r_started_epoch
  FM_GOAL_REC_NAMED_BY=$r_named_by
  FM_GOAL_REC_PLAN=$r_plan
  FM_GOAL_REC_DONE_WHEN=$(_fm_goal_clean_field "${done_when:-$r_done_when}")
  path=$(fm_goal_path "$id")
  staged=$(mktemp "$(fm_goal_dir)/.goal.editing.XXXXXX") || {
    fm_goal_lock_release
    _fm_goal_die 1 'could not stage the goal record'
  }
  _fm_goal_render_record > "$staged" || { rm -f "$staged"; fm_goal_lock_release; exit 1; }
  fm_goal_validate "$staged" "$id" || { rm -f "$staged"; fm_goal_lock_release; exit 1; }
  mv "$staged" "$path" || { rm -f "$staged"; fm_goal_lock_release; _fm_goal_die 1 'could not install the goal record'; }
  fm_goal_lock_release
  printf 'edited goal %s: %s items (was %s); marks preserved\n' "$id" "$FM_GOAL_ITEM_COUNT" "$old_count"
  return 0
}

# Build the unstamped mark line head `goal [goal=..] [item=..] [state=..]` and
# cap the full line so the stamped form stays within the status line cap.
_fm_goal_mark_line() {  # <id> <item> <state> <task> <note> [stage] -> printed
  local head="goal [goal=$1] [item=$2]" cap
  [ -z "$3" ] || head="$head [state=$3]"
  [ -z "${6-}" ] || head="$head [stage=$6]"
  [ -z "$4" ] || head="$head [task=$4]"
  cap=$((FM_LINE_CAP_DEFAULT - $(status_stamp_width)))
  [ $((${#head} + 3)) -lt "$cap" ] || { fm_goal_log 'mark tags exceed the status line cap'; return 2; }
  printf '%s: %s' "$head" "$5" | cut -c1-$cap
}

cmd_mark() {
  local id item state='' task='' stage='' note='' dash_seen=0 flag what
  local rc=0 line stamped path
  [ "$#" -ge 3 ] || _fm_goal_usage_error 'mark needs <goal> <item> <state|stage=<stage>> -- <note>'
  id=$1
  item=$2
  case "$3" in
    stage=*) stage=${3#stage=} ;;
    *) state=$3 ;;
  esac
  shift 3
  while [ "$#" -gt 0 ]; do
    flag=$1
    case "$flag" in
      --task)
        [ "$#" -ge 2 ] && [ -n "${2-}" ] || _fm_goal_usage_error '--task needs a value'
        task=$2
        shift 2
        ;;
      --stage)
        [ -z "$stage" ] || _fm_goal_usage_error 'the stage is given once'
        [ "$#" -ge 2 ] && [ -n "${2-}" ] || _fm_goal_usage_error '--stage needs a value'
        stage=$2
        shift 2
        ;;
      --)
        shift
        dash_seen=1
        break
        ;;
      *) _fm_goal_usage_error "unknown flag for mark: $flag" ;;
    esac
  done
  [ "$dash_seen" -eq 1 ] || _fm_goal_usage_error 'mark needs -- before the note'
  note=$(printf '%s' "$*" | LC_ALL=C tr '\t\r\n' '   ')
  fm_goal_id_valid "$id" || _fm_goal_usage_error "unsafe goal id: '$id'"
  fm_goal_id_valid "$item" || _fm_goal_usage_error "unsafe item id: '$item'"
  [ -z "$state" ] || fm_goal_state_valid "$state" || _fm_goal_usage_error "unknown mark state: '$state'"
  [ -n "$state" ] || [ -n "$stage" ] || _fm_goal_usage_error 'mark needs a state or a stage'
  [ -z "$stage" ] || fm_stage_name_valid "$stage" || _fm_goal_usage_error "unsafe stage: '$stage'"
  what=${state:+$state}${stage:+${state:+ }stage=$stage}
  [ -z "$task" ] || fm_goal_id_valid "$task" || _fm_goal_usage_error "unsafe task id: '$task'"
  case "$(printf '%s' "$note" | LC_ALL=C tr -d '[:space:]')" in
    '') _fm_goal_usage_error 'mark needs a note after --' ;;
  esac
  fm_parent_channel_destination "$FM_GOAL_HOME" "$FM_GOAL_STATE" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    # secondmate home: publish through the parent channel.
    line=$(_fm_goal_mark_line "$id" "$item" "$state" "$task" "$note" "$stage") || exit 2
    if [ "$FM_PARENT_CHANNEL_ROUTE" = local ]; then
      path="$FM_SECONDMATE_PARENT_HOME/state/goals/$id.goal"
      _fm_goal_regular_file "$path"
      rc=$?
      case "$rc" in
        0) ;;
        2) fm_goal_log "the parent has no active record for goal '$id'"; exit 1 ;;
        *) fm_goal_log "refused: the parent's goal record is a symlink: $path"; exit 1 ;;
      esac
      _fm_goal_open_record "$id" "$FM_SECONDMATE_PARENT_HOME/state" >/dev/null || {
        fm_goal_log "the parent's goal record for '$id' is invalid"
        exit 1
      }
      [ "$FM_GOAL_REC_STATE" = active ] || { fm_goal_log 'parent goal is not active'; exit 1; }
      _fm_goal_index_of "$item" >/dev/null || {
        fm_goal_log "unknown item '$item' in goal '$id'"
        exit 1
      }
    fi
    fm_parent_channel_report "$FM_GOAL_HOME" "$FM_GOAL_STATE" "$line" || {
      fm_goal_log "could not publish the mark on the parent channel"
      exit 1
    }
    printf 'marked %s/%s %s via the parent channel\n' "$id" "$item" "$what"
    return 0
  fi
  [ "$rc" -eq 1 ] || _fm_goal_die 1 'the secondmate identity of this home is unreadable'
  # parent home: append to the marks file.
  _fm_goal_parent_home || exit 1
  _fm_goal_require_actor 'main branch' || exit 1
  _fm_goal_open_record "$id" || exit 1
  _fm_goal_index_of "$item" >/dev/null || {
    fm_goal_log "unknown item '$item' in goal '$id'"
    exit 1
  }
  line=$(_fm_goal_mark_line "$id" "$item" "$state" "$task" "$note" "$stage") || exit 2
  stamped=$(status_stamp_line "$line")
  path=$(fm_goal_marks_path "$id")
  fm_goal_lock_hold || exit 1
  if ! _fm_goal_open_record "$id" || ! _fm_goal_index_of "$item" >/dev/null; then
    fm_goal_lock_release
    exit 1
  fi
  if [ -e "$path" ] || [ -L "$path" ]; then
    _fm_goal_regular_file "$path" || { fm_goal_lock_release; return 1; }
  fi
  if [ -f "$path" ] && [ ! -L "$path" ] && [ "$(tail -n 1 "$path" 2>/dev/null)" = "$stamped" ]; then
    fm_goal_lock_release
    printf 'marked %s/%s %s (already recorded)\n' "$id" "$item" "$what"
    return 0
  fi
  printf '%s\n' "$stamped" >> "$path" || {
    fm_goal_lock_release
    _fm_goal_die 1 "could not append the mark to $path"
  }
  fm_goal_lock_release
  printf 'marked %s/%s %s\n' "$id" "$item" "$what"
  return 0
}

# Probe one goal's items: for each item with a project that has a ladder, run
# the probes of the rungs above its stage, lowest first, up to its target (the
# whole ladder when it has none), stop at the first rung not reached, and mark
# the highest rung reached. Probes run outside the goal lock; only the mark
# takes it. rc 0 when every probed item was handled, 1 on a malformed ladder, a
# failed mark, or an explicitly named item that cannot be probed.
_fm_goal_probe_goal() {  # <id> <only-item or ''> <dry 0|1>
  local id=$1 only=$2 dry=$3
  local i j rc=0 prc cur cur_rank top first out evidence timeout reached_stage status=0 note label
  _fm_goal_open_record "$id" || return 1
  fm_goal_fold "$id" "$FM_GOAL_STATE" "$FM_GOAL_DATA" "$(date +%s)"
  if [ -n "$only" ]; then
    _fm_goal_index_of "$only" >/dev/null || { fm_goal_log "unknown item '$only' in goal '$id'"; return 1; }
  fi
  timeout=${FM_GOAL_PROBE_TIMEOUT:-60}
  case "$timeout" in ''|*[!0-9]*|0) timeout=60 ;; esac
  i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    if [ -n "$only" ] && [ "${FM_GOAL_ITEMS_IDS[$i]}" != "$only" ]; then
      i=$((i + 1)); continue
    fi
    label="probe $id/${FM_GOAL_ITEMS_IDS[$i]}"
    if [ -z "${FM_GOAL_ITEMS_PROJECTS[$i]}" ]; then
      [ -z "$only" ] || { fm_goal_log "$label: the item has no project"; status=1; }
      i=$((i + 1)); continue
    fi
    if [ "${FM_GOAL_M_STATES[$i]}" = dropped ]; then
      i=$((i + 1)); continue
    fi
    rc=0
    fm_stage_ladder_load "$FM_GOAL_CONFIG" "${FM_GOAL_ITEMS_PROJECTS[$i]}" || rc=$?
    if [ "$rc" -eq 2 ]; then
      fm_goal_log "$label: $FM_STAGE_LADDER_ERROR"; status=1
      i=$((i + 1)); continue
    elif [ "$rc" -eq 1 ]; then
      printf '%s [%s]: no stage ladder for the project, skipped\n' "$label" "${FM_GOAL_ITEMS_PROJECTS[$i]}"
      [ -z "$only" ] || status=1
      i=$((i + 1)); continue
    fi
    cur=${FM_GOAL_S_STAGES[$i]}
    cur_rank=-1
    [ -z "$cur" ] || cur_rank=$(fm_stage_ladder_rank "$cur") || cur_rank=-1
    top=$((${#FM_STAGE_LADDER_NAMES[@]} - 1))
    if [ -n "${FM_GOAL_ITEMS_TARGETS[$i]}" ]; then
      top=$(fm_stage_ladder_rank "${FM_GOAL_ITEMS_TARGETS[$i]}") || top=$((${#FM_STAGE_LADDER_NAMES[@]} - 1))
    fi
    first=$((cur_rank + 1))
    if [ "$first" -gt "$top" ]; then
      printf '%s [%s]: stage %s, nothing above it to probe\n' "$label" "${FM_GOAL_ITEMS_PROJECTS[$i]}" "${cur:-none}"
      i=$((i + 1)); continue
    fi
    reached_stage='' evidence='' prc=0
    j=$first
    while [ "$j" -le "$top" ]; do
      prc=0
      out=$(fm_run_timed "$timeout" env \
        FM_GOAL_ID="$id" FM_GOAL_ITEM="${FM_GOAL_ITEMS_IDS[$i]}" \
        FM_GOAL_PROJECT="${FM_GOAL_ITEMS_PROJECTS[$i]}" FM_GOAL_TASK="${FM_GOAL_ITEMS_TASKS[$i]}" \
        FM_GOAL_STAGE="${FM_STAGE_LADDER_NAMES[$j]}" FM_GOAL_HOME="$FM_GOAL_HOME" \
        bash -c "${FM_STAGE_LADDER_PROBES[$j]}" </dev/null 2>/dev/null) || prc=$?
      [ "$prc" -eq 0 ] || break
      reached_stage=${FM_STAGE_LADDER_NAMES[$j]}
      evidence=$(_fm_goal_note_bounded "$(_fm_goal_clean_field "${out%%$'\n'*}")")
      j=$((j + 1))
    done
    if [ -z "$reached_stage" ]; then
      printf '%s [%s]: stage %s, %s not reached (probe exit %s)\n' "$label" \
        "${FM_GOAL_ITEMS_PROJECTS[$i]}" "${cur:-none}" "${FM_STAGE_LADDER_NAMES[$first]}" "$prc"
    elif [ "$dry" -eq 1 ]; then
      printf '%s [%s]: would move %s -> %s (dry run)\n' "$label" "${FM_GOAL_ITEMS_PROJECTS[$i]}" "${cur:-none}" "$reached_stage"
    else
      note="probe passed for $reached_stage${evidence:+: $evidence}"
      if ( cmd_mark "$id" "${FM_GOAL_ITEMS_IDS[$i]}" "stage=$reached_stage" -- "$note" ) >/dev/null; then
        printf '%s [%s]: stage %s -> %s%s\n' "$label" "${FM_GOAL_ITEMS_PROJECTS[$i]}" "${cur:-none}" "$reached_stage" "${evidence:+ ($evidence)}"
      else
        fm_goal_log "$label: could not record the stage mark"; status=1
      fi
    fi
    i=$((i + 1))
  done
  return "$status"
}

cmd_probe() {
  local id='' only='' dry=0 arg path rc=0 any=0
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --dry-run) dry=1 ;;
      -*) _fm_goal_usage_error "unknown flag for probe: $arg" ;;
      *)
        if [ -z "$id" ]; then id=$arg
        elif [ -z "$only" ]; then only=$arg
        else _fm_goal_usage_error 'probe takes at most a goal id and an item id'
        fi
        ;;
    esac
    shift
  done
  [ -z "$id" ] || fm_goal_id_valid "$id" || _fm_goal_usage_error "unsafe goal id: '$id'"
  [ -z "$only" ] || fm_goal_id_valid "$only" || _fm_goal_usage_error "unsafe item id: '$only'"
  _fm_goal_parent_home || exit 1
  _fm_goal_require_actor 'main branch' || exit 1
  if [ -n "$id" ]; then
    _fm_goal_probe_goal "$id" "$only" "$dry" || exit 1
    return 0
  fi
  while IFS= read -r path; do
    any=1
    id=${path##*/}
    id=${id%.goal}
    _fm_goal_probe_goal "$id" '' "$dry" || rc=1
  done < <(fm_goal_active_records 2>/dev/null)
  [ "$any" -eq 1 ] || _fm_goal_die 1 'no active goal records'
  [ "$rc" -eq 0 ] || exit 1
  return 0
}

cmd_show() {
  local id path any=0
  if [ "$#" -eq 1 ]; then
    fm_goal_render_show "$1" || exit 1
    return 0
  fi
  [ "$#" -eq 0 ] || _fm_goal_usage_error 'show takes at most one goal id'
  while IFS= read -r path; do
    any=1
    id=${path##*/}
    id=${id%.goal}
    fm_goal_render_show "$id" || exit 1
  done < <(fm_goal_active_records 2>/dev/null)
  [ "$any" -eq 1 ] || _fm_goal_die 1 'no active goal records'
  return 0
}

cmd_brief() {
  [ "$#" -eq 0 ] || _fm_goal_usage_error 'brief takes no arguments'
  fm_goal_render_brief
  return 0
}

cmd_active() {
  [ "$#" -eq 0 ] || _fm_goal_usage_error 'active takes no arguments'
  fm_goal_active_ids || _fm_goal_die 1 'no active goal records'
  return 0
}

cmd_startable() {
  local path id i
  [ "$#" -eq 0 ] || _fm_goal_usage_error 'startable takes no arguments'
  while IFS= read -r path; do
    id=${path##*/}
    id=${id%.goal}
    _fm_goal_open_record "$id" >/dev/null 2>&1 || continue
    fm_goal_fold "$id" "$FM_GOAL_STATE" "$FM_GOAL_DATA" "$(date +%s)"
    i=0
    while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
      if _fm_goal_item_startable "$i"; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$FM_GOAL_REC_ID" "${FM_GOAL_ITEMS_IDS[$i]}" \
          "${FM_GOAL_ITEMS_OWNERS[$i]}" "${FM_GOAL_ITEMS_TASKS[$i]:--}" \
          "${FM_GOAL_M_ATS[$i]:-$FM_GOAL_REC_STARTED_EPOCH}"
      fi
      i=$((i + 1))
    done
  done < <(fm_goal_active_records 2>/dev/null)
  return 0
}

cmd_exists() {
  [ "$#" -eq 1 ] || _fm_goal_usage_error 'exists needs a goal id'
  fm_goal_id_valid "$1" || _fm_goal_usage_error "unsafe goal id: '$1'"
  _fm_goal_open_record "$1" >/dev/null 2>&1 || exit 1
  printf '%s\n' "$(fm_goal_path "$1")"
  return 0
}

cmd_close() {
  local id='' mode='' words=''
  local flag value path now closed_iso staged archived_record archived_marks
  [ "$#" -ge 1 ] || _fm_goal_usage_error 'close needs a goal id'
  id=$1
  shift
  while [ "$#" -gt 0 ]; do
    flag=$1
    value=${2-}
    case "$flag" in
      --done)
        [ -z "$mode" ] || _fm_goal_usage_error 'close takes one of --done or --captain'
        mode="done"
        shift
        ;;
      --captain)
        [ -z "$mode" ] || _fm_goal_usage_error 'close takes one of --done or --captain'
        mode=captain
        shift
        ;;
      --words)
        [ "$#" -ge 2 ] && [ -n "$value" ] || _fm_goal_usage_error '--words needs a value'
        words=$value
        shift 2
        ;;
      *) _fm_goal_usage_error "unknown flag for close: $flag" ;;
    esac
  done
  [ -n "$mode" ] || _fm_goal_usage_error 'close needs --done or --captain'
  [ "$mode" = "done" ] || [ -n "$words" ] || _fm_goal_usage_error 'close --captain needs --words <text>'
  fm_goal_id_valid "$id" || _fm_goal_usage_error "unsafe goal id: '$id'"
  _fm_goal_parent_home || exit 1
  if [ "$mode" = "done" ]; then
    _fm_goal_require_actor 'main branch' || exit 1
  else
    _fm_goal_require_actor main || exit 1
  fi
  _fm_goal_open_record "$id" || exit 1
  if [ "$mode" = 'done' ]; then _fm_goal_close_check_done "$id" || exit 1; fi
  path=$(fm_goal_path "$id")
  fm_goal_lock_hold || exit 1
  if ! _fm_goal_open_record "$id" >/dev/null 2>&1; then
    fm_goal_lock_release
    fm_goal_log "refused: goal '$id' changed while closing"
    exit 1
  fi
  if [ "$mode" = 'done' ]; then
    _fm_goal_close_check_done "$id" || { fm_goal_lock_release; exit 1; }
  else
    fm_goal_fold "$id"
  fi
  now=$(date +%s)
  closed_iso=$(fm_goal_epoch_iso "$now")
  FM_GOAL_REC_STATE=closed
  FM_GOAL_REC_CLOSED=$closed_iso
  FM_GOAL_REC_CLOSED_EPOCH=$now
  FM_GOAL_REC_CLOSED_REASON=$mode
  FM_GOAL_REC_CLOSED_WORDS='-'
  [ "$mode" = captain ] && FM_GOAL_REC_CLOSED_WORDS=$(_fm_goal_clean_field "$words")
  staged=$(mktemp "$(fm_goal_dir)/.goal.closing.XXXXXX") || {
    fm_goal_lock_release
    _fm_goal_die 1 'could not stage the closed record'
  }
  _fm_goal_render_record > "$staged"
  {
    printf 'closed: %s\n' "$FM_GOAL_REC_CLOSED"
    printf 'closed_epoch: %s\n' "$FM_GOAL_REC_CLOSED_EPOCH"
    printf 'closed_reason: %s\n' "$FM_GOAL_REC_CLOSED_REASON"
    printf 'closed_words: %s\n' "$FM_GOAL_REC_CLOSED_WORDS"
    printf 'projection:\n'
    fm_goal_project "$id" | sed 's/^/  /'
  } >> "$staged"
  fm_goal_validate "$staged" "$id" || { rm -f "$staged"; fm_goal_lock_release; exit 1; }
  [ ! -L "$(fm_goal_closed_dir)" ] || { rm -f "$staged"; fm_goal_lock_release; _fm_goal_die 1 'refused: symlinked archive directory'; }
  mkdir -p "$(fm_goal_closed_dir)" || { rm -f "$staged"; fm_goal_lock_release; _fm_goal_die 1 'could not create the closed directory'; }
  archived_record=$(fm_goal_closed_dir)/"$id-$now.goal"
  archived_marks=$(fm_goal_closed_dir)/"$id-$now.marks"
  if [ -e "$archived_record" ] || [ -L "$archived_record" ] || [ -e "$archived_marks" ] || [ -L "$archived_marks" ]; then
    rm -f "$staged"
    fm_goal_lock_release
    _fm_goal_die 1 'an archive already exists for this second; retry the close later'
  fi
  if ! _fm_goal_archive_marks "$id" "$archived_marks"; then
    rm -f "$staged" "$archived_marks"
    fm_goal_lock_release
    _fm_goal_die 1 'could not archive the marks'
  fi
  archived_record=$(fm_goal_closed_dir)/"$id-$now.goal"
  if ! mv "$staged" "$archived_record"; then
    rm -f "$staged" "$archived_marks"
    fm_goal_lock_release
    _fm_goal_die 1 'could not install the closed record'
  fi
  rm -f -- "$(fm_goal_marks_path "$id")" "$path"
  fm_goal_lock_release
  printf 'closed goal %s (%s) at %s\n' "$id" "$mode" "$closed_iso"
  [ "$mode" = captain ] && [ -n "$words" ] && printf 'captain words: %s\n' "$FM_GOAL_REC_CLOSED_WORDS"
  printf 'record archived at %s\n' "$archived_record"
  printf 'marks archived at %s\n' "$archived_marks"
  return 0
}

# Refuse close --done while any planned item is not done or dropped.
_fm_goal_close_check_done() {  # <id>
  local id=$1 i offenders='' short=''
  fm_goal_fold "$id"
  i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    _fm_goal_item_doneish "$i" || offenders="$offenders${offenders:+ }${FM_GOAL_ITEMS_IDS[$i]}"
    # a dropped item no longer owes its target; any other item does
    if [ -n "${FM_GOAL_ITEMS_TARGETS[$i]}" ] && [ "${FM_GOAL_M_STATES[$i]}" != dropped ] \
      && ! _fm_goal_item_target_reached "$i"; then
      short="$short${short:+ }${FM_GOAL_ITEMS_IDS[$i]}"
    fi
    i=$((i + 1))
  done
  [ -z "$offenders" ] || {
    fm_goal_log "refused: close --done with items still open: $offenders"
    return 1
  }
  [ -z "$short" ] || {
    fm_goal_log "refused: close --done with items short of their target stage: $short"
    return 1
  }
  return 0
}

# Write every valid mark line from every source, byte-deduplicated, to
# <out-path> (staged then renamed, so a failed write never leaves a partial
# archive at a glob-visible name).
_fm_goal_archive_marks() {  # <id> <out-path>
  local id=$1 out=$2 state=$FM_GOAL_STATE data=$FM_GOAL_DATA now
  local path line rc owner i seen_owners='' staged
  now=$(date +%s)
  staged=$(mktemp "$(dirname "$out")/.goal.archiving.XXXXXX") || return 1
  {
    path=$(fm_goal_marks_path "$id" "$state")
    if [ -f "$path" ] && [ ! -L "$path" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        _fm_goal_fold_goal_line "$line" "$id" "$now" '-'
        rc=$?
        [ "$rc" -eq 0 ] && printf '%s\n' "$line"
      done < "$path"
    fi
    i=0
    while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
      owner=${FM_GOAL_ITEMS_OWNERS[$i]}
      case " $seen_owners " in
        *" $owner "*) ;;
        *)
          seen_owners="$seen_owners $owner"
          path=$(_fm_goal_owner_stream "$state" "$data" "$owner") || { i=$((i + 1)); continue; }
          while IFS= read -r line || [ -n "$line" ]; do
            _fm_goal_fold_goal_line "$line" "$id" "$now" '-'
            rc=$?
            [ "$rc" -eq 0 ] && printf '%s\n' "$line"
          done < "$path"
          ;;
      esac
      i=$((i + 1))
    done
  } | LC_ALL=C awk '!seen[$0]++' > "$staged" || { rm -f "$staged"; return 1; }
  mv "$staged" "$out" || { rm -f "$staged"; return 1; }
  return 0
}

cmd_window() {
  local id='' since='' flag
  local now state_kind='' path i line list='' n=0 more=0
  local end='' gap ats stamp
  [ "$#" -ge 1 ] || _fm_goal_usage_error 'window needs a goal id'
  id=$1
  shift
  while [ "$#" -gt 0 ]; do
    flag=$1
    case "$flag" in
      --since)
        [ "$#" -ge 2 ] && [ -n "${2-}" ] || _fm_goal_usage_error '--since needs an epoch'
        since=$2
        shift 2
        ;;
      *) _fm_goal_usage_error "unknown flag for window: $flag" ;;
    esac
  done
  fm_goal_id_valid "$id" || _fm_goal_usage_error "unsafe goal id: '$id'"
  case "$since" in ''|*[!0-9]*|0[0-9]*) _fm_goal_usage_error '--since needs an epoch (seconds)' ;; esac
  [ "${#since}" -le 12 ] || _fm_goal_usage_error '--since epoch is too large'
  now=$(date +%s)
  if _fm_goal_open_record "$id" >/dev/null 2>&1; then
    state_kind=active
    end=$now
    fm_goal_fold "$id"
  else
    path=$(_fm_goal_newest_closed "$id" 2>/dev/null) || exit 1
    _fm_goal_load_record "$path" || exit 1
    state_kind=closed
    end=$FM_GOAL_REC_CLOSED_EPOCH
    fm_goal_fold "$id" "$FM_GOAL_STATE" "$FM_GOAL_DATA" "$now" "${path%.goal}.marks"
  fi
  printf 'GOAL %s window %s .. %s:\n' "$id" "$(fm_goal_epoch_iso "$since")" "$(fm_goal_epoch_iso "$end")"
  if [ "$state_kind" = active ]; then
    printf '  state: active\n'
  elif [ "$end" -ge "$since" ]; then
    printf '  state: closed (%s) at %s\n' "$FM_GOAL_REC_CLOSED_REASON" "$FM_GOAL_REC_CLOSED"
  else
    printf '  state: closed (%s) at %s (before this window)\n' "$FM_GOAL_REC_CLOSED_REASON" "$FM_GOAL_REC_CLOSED"
  fi
  i=0
  while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
    if _fm_goal_item_doneish "$i" && [ -n "${FM_GOAL_M_ATS[$i]}" ] && [ "${FM_GOAL_M_ATS[$i]}" -ge "$since" ]; then
      if [ "$n" -lt "$FM_GOAL_BRIEF_ITEM_LIST" ]; then
        if [ -n "$list" ]; then list="$list, "; fi
        list="$list${FM_GOAL_ITEMS_IDS[$i]} (at $(fm_goal_epoch_iso "${FM_GOAL_M_ATS[$i]}"))"
      else
        more=$((more + 1))
      fi
      n=$((n + 1))
    fi
    i=$((i + 1))
  done
  if [ "$n" -gt 0 ]; then
    line="  items done in the window: $list"
    [ "$more" -eq 0 ] || line="$line, +$more more"
    fm_cap_line_var "$line"; printf '%s\n' "$FM_LINE_CAP_LINE"
  else
    printf '  items done in the window: none\n'
  fi
  if [ "$state_kind" = active ]; then
    list=''; n=0; more=0
    i=0
    while [ "$i" -lt "$FM_GOAL_ITEM_COUNT" ]; do
      if _fm_goal_item_startable "$i"; then
        if [ "$n" -lt "$FM_GOAL_BRIEF_ITEM_LIST" ]; then
          if [ -n "$list" ]; then list="$list, "; fi
          list="$list${FM_GOAL_ITEMS_IDS[$i]} [${FM_GOAL_ITEMS_OWNERS[$i]}]"
        else
          more=$((more + 1))
        fi
        n=$((n + 1))
      fi
      i=$((i + 1))
    done
    if [ "$n" -gt 0 ]; then
      line="  startable now, nobody on: $list"
      [ "$more" -eq 0 ] || line="$line, +$more more"
      fm_cap_line_var "$line"; printf '%s\n' "$FM_LINE_CAP_LINE"
    fi
  fi
  ats="$since $end"
  for stamp in ${FM_GOAL_PROGRESS_ATS[@]+"${FM_GOAL_PROGRESS_ATS[@]}"}; do
    ats="$ats $stamp"
  done
  # shellcheck disable=SC2086  # ats is a validated space-separated epoch list
  gap=$(printf '%s\n' $ats | LC_ALL=C sort -n | LC_ALL=C uniq | LC_ALL=C awk -v lo="$since" -v hi="$end" '
    $1 >= lo && $1 <= hi {
      if (have) {
        d = $1 - prev
        if (best == "" || d > best) { best = d; from = prev; to = $1 }
      }
      prev = $1
      have = 1
    }
    END { if (best != "") printf "%d %d %d\n", best, from, to }
  ')
  if [ -n "$gap" ]; then
    # shellcheck disable=SC2086  # gap is the awk triple just printed
    set -- $gap
    printf '  longest stretch with no goal progress: %s (%s .. %s)\n' \
      "$(fm_goal_age "$1")" "$(fm_goal_epoch_iso "$2")" "$(fm_goal_epoch_iso "$3")"
  fi
  return 0
}

# --- main --------------------------------------------------------------------

main() {
  local cmd=${1-}
  [ "$#" -ge 1 ] || _fm_goal_usage_error 'needs a subcommand'
  shift
  case "$cmd" in
    start|edit|mark|probe|show|brief|active|startable|exists|window|close) ;;
    help|-h|--help) fm_goal_usage; return 0 ;;
    *) _fm_goal_usage_error "unknown subcommand: $cmd" ;;
  esac
  "cmd_$cmd" "$@"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
