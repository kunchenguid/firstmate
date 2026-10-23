#!/usr/bin/env bash
# fm-rex-popup.sh - the runtime behind Firstmate's Rex command-palette actions.
#
# docs/rex-backend.md "Command palette" owns the public contract. This header
# owns the mechanics.
#
# bin/backends/rex-palette.lua defines the palette actions. Each one runs
# `plan` (a Rex action has 30 seconds, so plan reads only local records and at
# most a few Rex calls) and then does what the plan says: open a floating popup
# whose command is one of the bodies below, or ask the captain's Rex app to show
# a session. The bodies are interactive and have no time limit.
#
# Usage:
#   fm-rex-popup.sh plan <action> [--session <id>] [--block <id>] [--task <id>]
#   fm-rex-popup.sh fleet
#   fm-rex-popup.sh this <task>
#   fm-rex-popup.sh peek <task>
#   fm-rex-popup.sh answer [<task>]
#   fm-rex-popup.sh note [<task>]
#   fm-rex-popup.sh merge [<task>]
#
# plan actions: fleet, this, peek, goto, answer, note, merge.
# --session and --block are the action's ctx.session_id and ctx.block_id.
# plan prints one JSON object:
#   {"action", "task", "message",
#    "layer": {"session_id", "command": [argv]},   (open this popup)
#    "select": {"session_id", "window_id"?}}       (show this session)
# and exits 1 with one line on stderr when the action cannot apply, which the
# palette shows as the action's error.
#
# The focused pane resolves to a task through this home's records only: the
# Rex task whose meta records that pane's rex_block_id. The popup opens in the
# focused pane's session, on this machine's Rex server.
#
# goto selects --task, or else the first Rex task waiting on the captain,
# ranked decision or captain hold, then blocked, then failed, then a done PR,
# ties by task id, and asks the app to show its recorded session and tab.
#
# The answer, note, and merge bodies only ever file a captain inbox note through
# bin/fm-inbox.sh (with a fresh request id), in these shapes:
#   Answer for <task> [key=<key>]: <text>     (an open keyed decision)
#   Answer for <task>: <text>                 (a captain hold)
#   About <task>: <text>                      (note with a focused task)
#   <text>                                    (note without one)
#   Merge request: <PR URL> (task <task>)
# Firstmate then answers through bin/fm-send.sh or merges through
# bin/fm-pr-merge.sh with its usual checks. Nothing here steers a worker or
# merges.
#
# Environment: FM_HOME and FM_STATE_OVERRIDE resolve the home as the other
# bin/ scripts do, and REX_SERVER names the Rex server. The popup command
# carries PATH, FM_HOME, and REX_SERVER explicitly, because a Rex server
# started by the app runs with a minimal PATH.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export STATE

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '14,20p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

task_ok() {
  case "$1" in '' | .* | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

uuid_of() { # <typed-or-bare-id>
  printf '%s' "${1#*:}"
}

# --- resolution ----------------------------------------------------------------

# Sets R_TASK for the focused pane, or leaves it empty.
resolve_pane() { # <block>
  local bid meta id
  bid=$(uuid_of "$1")
  R_TASK=
  [ -n "$bid" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    task_ok "$id" || continue
    [ "$(fm_meta_get "$meta" backend)" = rex ] || continue
    [ "$(uuid_of "$(fm_meta_get "$meta" rex_block_id)")" = "$bid" ] || continue
    R_TASK=$id
    return 0
  done
  return 0
}

# The argv a popup runs: this script with the environment it needs.
popup_command() { # <body> [args...]
  local env_args=("PATH=$PATH" "FM_HOME=$FM_HOME")
  [ -z "${REX_SERVER:-}" ] || env_args+=("REX_SERVER=$REX_SERVER")
  [ -z "${FM_STATE_OVERRIDE:-}" ] || env_args+=("FM_STATE_OVERRIDE=$FM_STATE_OVERRIDE")
  jq -nc --args '$ARGS.positional' /usr/bin/env "${env_args[@]}" "$SCRIPT_DIR/fm-rex-popup.sh" "$@"
}

# Rank of a task's latest status for goto: 1 decision or hold, 2 blocked,
# 3 failed, 4 done with a URL, empty otherwise.
LIBS_LOADED=0
waiting_rank() { # <task> <kind>
  local line verb note held
  if [ "$LIBS_LOADED" = 0 ]; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh" || return 0
    # shellcheck source=bin/fm-classify-lib.sh
    . "$SCRIPT_DIR/fm-classify-lib.sh" || return 0
    LIBS_LOADED=1
  fi
  line=$(status_current_line "$STATE/$1.status" "$2" 2>/dev/null) || line=
  verb=$(status_line_verb "$line" 2>/dev/null) || verb=
  note=$(status_line_note "$line" 2>/dev/null) || note=
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  case "$verb" in
    needs-decision | "$held") printf 1 ;;
    blocked) printf 2 ;;
    failed) printf 3 ;;
    done) case "$note" in *https://*) printf 4 ;; esac ;;
  esac
}

# Sets G_SESSION and G_WINDOW from a Rex task's recorded tab, or fails.
goto_target() { # <task>
  local meta="$STATE/$1.meta"
  G_SESSION=
  G_WINDOW=
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_meta_get "$meta" backend)" = rex ] || return 1
  G_SESSION="session:$(uuid_of "$(fm_meta_get "$meta" rex_session_id)")"
  [ "$G_SESSION" != session: ] || return 1
  G_WINDOW=$(uuid_of "$(fm_meta_get "$meta" rex_window_id)")
  [ -z "$G_WINDOW" ] || G_WINDOW="window:$G_WINDOW"
  return 0
}

first_waiting() {
  local meta id kind rank best='' best_rank=9
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    task_ok "$id" || continue
    [ "$(fm_meta_get "$meta" backend)" = rex ] || continue
    kind=$(fm_meta_get "$meta" kind)
    rank=$(waiting_rank "$id" "${kind:-ship}")
    [ -n "$rank" ] && [ "$rank" -lt "$best_rank" ] || continue
    best=$id
    best_rank=$rank
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# --- plan ------------------------------------------------------------------------

cmd_plan() {
  local action=${1:-} session='' block='' task='' command message
  [ -n "$action" ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session | --block | --task) [ "$#" -ge 2 ] || die "$1 needs a value" ;;
    esac
    case "$1" in
      --session) session=$2; shift 2 ;;
      --block) block=$2; shift 2 ;;
      --task) task=$2; shift 2 ;;
      *) die "unknown plan option: $1" ;;
    esac
  done
  [ -z "$task" ] || task_ok "$task" || die "invalid task id: $task"
  case "$action" in
    goto)
      if [ -z "$task" ]; then
        task=$(first_waiting) || die "no worker is waiting on you"
      fi
      goto_target "$task" || die "$task has no Rex tab to go to"
      message="Showing $task"
      jq -nc --arg t "$task" --arg s "$G_SESSION" --arg w "$G_WINDOW" --arg m "$message" \
        '{action:"goto", task:$t, select:({session_id:$s} + (if $w == "" then {} else {window_id:$w} end)), message:$m}'
      return
      ;;
    fleet | this | peek | answer | note | merge) ;;
    *) die "unknown palette action: $action" ;;
  esac
  if [ -z "$task" ]; then
    resolve_pane "$block"
    task=$R_TASK
  fi
  case "$action" in
    this | peek) [ -n "$task" ] || die "the focused pane is not a Firstmate worker; use Show Fleet" ;;
  esac
  case "$session" in session:?*) ;; *) die "the palette gave no session to open the popup in" ;; esac
  case "$action" in
    fleet) command=$(popup_command fleet) ;;
    this | peek) command=$(popup_command "$action" "$task") ;;
    *) if [ -n "$task" ]; then command=$(popup_command "$action" "$task"); else command=$(popup_command "$action"); fi ;;
  esac
  jq -nc --arg a "$action" --arg t "$task" --arg s "$session" --argjson c "$command" \
    '{action:$a, task:(if $t == "" then null else $t end), layer:{session_id:$s, command:$c}, message:""}'
}

# --- popup bodies ----------------------------------------------------------------

pause_close() {
  printf '\nPress Enter to close.'
  read -r _ || true
}

snapshot() {
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null
}

file_note() { # <text>
  local text=$1 rid out rc
  rid="rex-palette-$(date +%s)-$$-$RANDOM"
  out=$("$SCRIPT_DIR/fm-inbox.sh" note --request-id "$rid" -- "$text" 2>&1)
  rc=$?
  case "$rc" in
    0) printf '\nFiled for Firstmate:\n  %s\n' "$text" ;;
    3) printf '\nSaved for Firstmate, but its wake could not be queued; Firstmate sees it at its next inbox read:\n  %s\n' "$text" ;;
    *) printf '\nCould not file the note (%s): %s\n' "$rc" "$out" ;;
  esac
}

# One line from the terminal, empty on cancel.
ask_line() { # <prompt>
  local reply=''
  printf '%s' "$1" >&2
  read -r reply || reply=
  printf '%s' "$reply" | tr -d '\r'
}

body_fleet() {
  "$SCRIPT_DIR/fm-fleet-view.sh" || printf 'Could not render the fleet view.\n'
  pause_close
}

body_this() {
  local task=$1 snap
  snap=$(snapshot) || snap='{}'
  printf '%s' "$snap" | jq -r --arg t "$task" '
    (.tasks // []) | map(select(.id == $t)) | .[0] as $r
    | if $r == null then "No record for \($t)."
      else
        "Task:      \($r.id) (\($r.kind // "ship")\(if ($r.project // "") != "" then ", project " + $r.project else "" end))",
        "Latest:    \(if ($r.hints.last_event_text // "") != "" then $r.hints.last_event_text else "no status yet" end)",
        (($r.hints.open_decisions // [])[] | "Decision:  [\(.key // "-")] \(.summary // "")"),
        (if ($r.pr.url // "") != "" then "PR:        \($r.pr.url)" else empty end)
      end'
  pause_close
}

body_peek() {
  local task=$1
  while :; do
    printf '\033[H\033[2J'
    printf 'Peek: %s (refreshes every 3 seconds; press Enter to close)\n\n' "$task"
    "$SCRIPT_DIR/fm-peek.sh" "$task" 40 2>&1 || true
    read -r -t 3 _ && break
  done
}

# Prints "<task>\t<key>\t<summary>" per open decision and captain hold.
decision_rows() { # [<task>]
  snapshot | jq -r --arg t "${1:-}" '
    [ ((.tasks // [])[] | select($t == "" or .id == $t) | . as $r
        | ($r.hints.open_decisions // [])[] | [$r.id, (.key // ""), (.summary // "")]),
      ((.backlog.records // [])[] | select(.captain_actionable == true) | select($t == "" or .id == $t)
        | [.id, "", (.hold_reason // .title // "")]) ]
    | .[] | map(gsub("[\t\n\r]"; " ")) | @tsv'
}

pick_row() { # <rows> <prompt>  -> sets PICKED to the chosen row
  local rows=$1 n i=1 choice row
  PICKED=
  n=$(printf '%s\n' "$rows" | grep -c .)
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    printf '%2d) %s\n' "$i" "$(printf '%s' "$row" | awk -F '\t' '{ printf "%s%s  %s", $1, ($2 == "" ? "" : " [" $2 "]"), $3 }')"
    i=$((i + 1))
  done <<EOF
$rows
EOF
  choice=$(ask_line "$2 [1-$n, Enter cancels]: ")
  case "$choice" in '' | *[!0-9]*) return 1 ;; esac
  [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ] || return 1
  PICKED=$(printf '%s\n' "$rows" | grep . | sed -n "${choice}p")
}

body_answer() {
  local task=${1:-} rows answer t key
  rows=$(decision_rows "$task")
  if [ -z "$rows" ] && [ -n "$task" ]; then
    printf 'Nothing from %s is waiting on your decision; showing every open decision.\n\n' "$task"
    rows=$(decision_rows)
  fi
  if [ -z "$rows" ]; then
    printf 'Nothing is waiting on your decision.\n'
    pause_close
    return 0
  fi
  printf 'Open decisions:\n\n'
  pick_row "$rows" "Answer which" || { printf 'Cancelled.\n'; return 0; }
  t=$(printf '%s' "$PICKED" | cut -f1)
  key=$(printf '%s' "$PICKED" | cut -f2)
  answer=$(ask_line "Your answer for $t (one line, Enter cancels): ")
  [ -n "$answer" ] || { printf 'Cancelled.\n'; return 0; }
  if [ -n "$key" ]; then
    file_note "Answer for $t [key=$key]: $answer"
  else
    file_note "Answer for $t: $answer"
  fi
  pause_close
}

body_note() {
  local task=${1:-} text
  if [ -n "$task" ]; then
    printf 'Message for Firstmate about %s.\n\n' "$task"
  else
    printf 'Message for Firstmate.\n\n'
  fi
  text=$(ask_line "> ")
  [ -n "$text" ] || { printf 'Cancelled.\n'; return 0; }
  if [ -n "$task" ]; then file_note "About $task: $text"; else file_note "$text"; fi
  pause_close
}

body_merge() {
  local task=${1:-} rows url t confirm
  rows=$(snapshot | jq -r --arg t "$task" \
    '(.tasks // [])[] | select($t == "" or .id == $t) | select((.pr.url // "") != "") | [.id, "", .pr.url] | @tsv')
  if [ -z "$rows" ] && [ -n "$task" ]; then
    printf 'No pull request is recorded for %s; showing every recorded one.\n\n' "$task"
    rows=$(snapshot | jq -r '(.tasks // [])[] | select((.pr.url // "") != "") | [.id, "", .pr.url] | @tsv')
  fi
  if [ -z "$rows" ]; then
    printf 'No pull request is recorded for any worker.\n'
    pause_close
    return 0
  fi
  printf 'Pull requests:\n\n'
  pick_row "$rows" "Ask Firstmate to merge which" || { printf 'Cancelled.\n'; return 0; }
  t=$(printf '%s' "$PICKED" | cut -f1)
  url=$(printf '%s' "$PICKED" | cut -f3)
  printf '\nFirstmate merges only after its usual checks, and tells you the outcome.\n'
  confirm=$(ask_line "Request the merge of $url? [y/N]: ")
  case "$confirm" in
    y | Y | yes | YES) file_note "Merge request: $url (task $t)" ;;
    *) printf 'Cancelled.\n'; return 0 ;;
  esac
  pause_close
}

main() {
  local cmd=${1:-}
  [ "$#" -gt 0 ] && shift
  case "$cmd" in
    plan) cmd_plan "$@" ;;
    fleet) body_fleet ;;
    this | peek)
      { [ "$#" -eq 1 ] && task_ok "$1"; } || usage
      "body_$cmd" "$1"
      ;;
    answer | note | merge)
      [ "$#" -le 1 ] || usage
      [ "$#" -eq 0 ] || task_ok "$1" || usage
      "body_$cmd" "$@"
      ;;
    -h | --help | help) sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) usage ;;
  esac
}

main "$@"
