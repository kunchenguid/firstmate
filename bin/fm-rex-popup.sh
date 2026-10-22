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
#   fm-rex-popup.sh plan <action> [--session <id>] [--block <id>] [--server <name>]
#                                 [--task <id>]
#   fm-rex-popup.sh fleet
#   fm-rex-popup.sh this <task>
#   fm-rex-popup.sh peek <task>
#   fm-rex-popup.sh answer [<task>]
#   fm-rex-popup.sh note [<task>]
#   fm-rex-popup.sh merge [<task>]
#
# plan actions: fleet, this, peek, goto, away, answer, note, merge.
# --session and --block are the action's ctx.session_id and ctx.block_id;
# --server is ctx.server, the name the app gives another host's server when
# the focused pane lives there. plan prints one JSON object:
#   {"action", "task", "pane", "message",
#    "layer": {"session_id", "command": [argv]},   (open this popup)
#    "select": {"session_id", "window_id"?},       (show this session)
#    "away": "shown" | "hidden"}
# and exits 1 with one line on stderr when the action cannot apply, which the
# palette shows as the action's error.
#
# The focused pane resolves to a task through this home's records only:
#   - a pane on the local server: the task whose meta records rex_block_id=;
#   - a pane on another host (--server set): a remote second mate recorded
#     with remote_backend=rex, either its own pane (remote_target's block) or
#     a pane in its fm-<id> session (remote_target's session), which resolves
#     to that second mate because the main home never supervises a second
#     mate's own workers.
# A popup always runs on this machine, because a popup in another host's
# session would run there. For a pane on another host the popup opens in the
# local session labeled fm-local and the plan asks the app to show it.
#
# goto selects --task, or else the first task waiting on the captain, ranked
# decision or captain hold, then blocked, then failed, then a done PR, ties by
# task id. A remote second mate's session lives on another host's server, so
# for one goto selects this machine's fm-local session instead. away toggles
# the away supervisor's detached pane: it shows it beside a pane of its session
# (move_block) or hides it again (detach_block), and never closes it.
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
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_REX_SERVER resolve the home
# and the local Rex server as the other bin/ scripts do. The popup command
# carries PATH, FM_HOME, and FM_REX_SERVER explicitly, because a Rex server
# started by the app runs with a minimal PATH.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export STATE

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

FM_REX_POPUP_LOCAL_SESSION=fm-local

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '14,21p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

task_ok() {
  case "$1" in '' | .* | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

uuid_of() { # <typed-or-bare-id>
  printf '%s' "${1#*:}"
}

rex_ready() {
  fm_backend_source rex >/dev/null 2>&1 || die "Rex support is not available in this Firstmate copy"
}

# --- resolution ----------------------------------------------------------------

# Sets R_TASK and R_PANE (local, remote-mate, remote-worker) for the focused
# pane, or leaves R_TASK empty.
resolve_pane() { # <server-name> <session> <block>
  local server=$1 sid bid meta id target
  sid=$(uuid_of "$2")
  bid=$(uuid_of "$3")
  R_TASK=
  R_PANE=
  [ -n "$bid$sid" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    task_ok "$id" || continue
    if [ -z "$server" ]; then
      [ "$(fm_meta_get "$meta" backend)" = rex ] || continue
      [ -n "$bid" ] && [ "$(fm_meta_get "$meta" rex_block_id)" = "$bid" ] || continue
      R_TASK=$id
      R_PANE=local
      return 0
    fi
    [ "$(fm_meta_get "$meta" remote_backend)" = rex ] || continue
    target=$(fm_meta_get "$meta" remote_target)
    if [ -n "$bid" ] && [ "${target#*:}" = "$bid" ]; then
      R_TASK=$id
      R_PANE=remote-mate
      return 0
    fi
    if [ -n "$sid" ] && [ "${target%%:*}" = "$sid" ]; then
      R_TASK=$id
      R_PANE=remote-worker
    fi
  done
  return 0
}

# The one live local session labeled fm-local, or fails naming <why>.
local_session() { # <why>
  local out sid count
  rex_ready
  out=$(fm_backend_rex_cli_json ls --json) || die "cannot read this machine's Rex sessions"
  count=$(printf '%s' "$out" | jq --arg l "$FM_REX_POPUP_LOCAL_SESSION" '[.sessions[]? | select(.label == $l)] | length')
  [ "$count" = 1 ] || die "$1; Firstmate uses this machine's $FM_REX_POPUP_LOCAL_SESSION session for that, and $count are open"
  sid=$(printf '%s' "$out" | jq -r --arg l "$FM_REX_POPUP_LOCAL_SESSION" '.sessions[] | select(.label == $l) | .session_id')
  printf '%s' "$sid"
}

# The session the popup opens in: the focused one when it is local, else the
# local fm-local session, which the app is then asked to show.
popup_session() { # <server-name> <session>
  local server=$1 session=$2
  if [ -z "$server" ]; then
    case "$session" in session:?*) ;; *) die "the palette gave no session to open the popup in" ;; esac
    printf '%s' "$session"
    return 0
  fi
  local_session "this pane is on $server and a popup runs on this machine"
}

# The argv a popup runs: this script with the environment it needs.
popup_command() { # <body> [args...]
  local env_args=("PATH=$PATH" "FM_HOME=$FM_HOME")
  [ -z "${FM_REX_SERVER:-}" ] || env_args+=("FM_REX_SERVER=$FM_REX_SERVER")
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

# Sets G_SESSION and G_WINDOW for a task with a Rex tab, and G_REMOTE to 1
# for a remote second mate, or fails.
goto_target() { # <task>
  local meta="$STATE/$1.meta" out
  G_SESSION=
  G_WINDOW=
  G_REMOTE=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  if [ "$(fm_meta_get "$meta" backend)" = rex ]; then
    [ -n "$(fm_meta_get "$meta" rex_session_id)" ] || return 1
    G_SESSION="session:$(fm_meta_get "$meta" rex_session_id)"
    G_WINDOW=$(fm_meta_get "$meta" rex_window_id)
    [ -z "$G_WINDOW" ] || G_WINDOW="window:$G_WINDOW"
    rex_ready
    # The recorded window is advisory: a moved pane keeps its block id.
    out=$(FM_BACKEND_REX_SERVER=$(fm_meta_get "$meta" rex_server) fm_backend_rex_block_inspect "$(fm_meta_get "$meta" window)") \
      && out=$(printf '%s' "$out" | jq -r '.block.window_id // empty' 2>/dev/null) \
      && [ -n "$out" ] && G_WINDOW=$out
    return 0
  fi
  if [ "$(fm_meta_get "$meta" remote_backend)" = rex ]; then
    G_SESSION=$(local_session "$1 runs on another host, whose session the app may not show") || exit 1
    G_REMOTE=1
    return 0
  fi
  return 1
}

first_waiting() {
  local meta id kind rank best='' best_rank=9
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    task_ok "$id" || continue
    [ "$(fm_meta_get "$meta" backend)" = rex ] || [ "$(fm_meta_get "$meta" remote_backend)" = rex ] || continue
    kind=$(fm_meta_get "$meta" kind)
    rank=$(waiting_rank "$id" "${kind:-ship}")
    [ -n "$rank" ] && [ "$rank" -lt "$best_rank" ] || continue
    best=$id
    best_rank=$rank
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# --- away pane -------------------------------------------------------------------

plan_away() { # <server-name> <session> <block>
  local server=$1 session=$2 block=$3 record backend target rserver rest out placement sid bid anchor=''
  record="$STATE/.afk-daemon-terminal"
  [ -f "$record" ] || die "away mode is not running in a hidden Rex pane"
  IFS=$'\t' read -r backend target rserver rest <"$record" || true
  [ "$backend" = rex ] && [ -n "$target" ] && [ -n "$rserver" ] && [ -z "${rest:-}" ] \
    || die "away mode is not running in a hidden Rex pane"
  rex_ready
  fm_backend_rex_parse_target "$target" || die "the away pane record is malformed"
  sid=$FM_BACKEND_REX_SESSION_ID
  bid=$FM_BACKEND_REX_BLOCK_ID
  out=$(FM_BACKEND_REX_SERVER=$rserver fm_backend_rex_block_inspect "$target") || die "the away pane is gone or its Rex server is unreachable"
  placement=$(printf '%s' "$out" | jq -r '.block.placement // empty')
  if [ "$placement" != detached ]; then
    FM_BACKEND_REX_SERVER=$rserver fm_backend_rex_cli_json api call -s "$sid" session.detach_block \
      "$(jq -nc --arg b "$bid" '{block_id:$b}')" >/dev/null || die "Rex could not hide the away pane"
    jq -nc '{action:"away", task:null, pane:null, away:"hidden", message:"Away pane hidden; it keeps running."}'
    return 0
  fi
  if [ -z "$server" ] && [ "$session" = "$sid" ] && [ -n "$block" ] && [ "$block" != "$bid" ]; then
    anchor=$block
  else
    out=$(FM_BACKEND_REX_SERVER=$rserver fm_backend_rex_cli_json api call -s "$sid" session.list_blocks '{}') \
      || die "cannot read the away pane's session"
    anchor=$(printf '%s' "$out" | jq -r --arg b "$bid" \
      '[.blocks[]? | select(.block_id != $b and .placement == "placed") | .block_id][0] // empty')
  fi
  [ -n "$anchor" ] || die "the away pane's session has no pane to show it beside"
  FM_BACKEND_REX_SERVER=$rserver fm_backend_rex_cli_json api call -s "$sid" session.move_block \
    "$(jq -nc --arg b "$bid" --arg a "$anchor" '{block_id:$b, anchor_block_id:$a, direction:"vertical", side:"after", ratio:0.7}')" \
    >/dev/null || die "Rex could not show the away pane"
  if [ -z "$server" ] && [ "$session" = "$sid" ]; then
    jq -nc '{action:"away", task:null, pane:null, away:"shown", message:"Away pane shown below; run the action again to hide it."}'
  else
    jq -nc --arg s "$sid" '{action:"away", task:null, pane:null, away:"shown", select:{session_id:$s}, message:"Away pane shown in the supervisor session; run the action again to hide it."}'
  fi
}

# --- plan ------------------------------------------------------------------------

cmd_plan() {
  local action=${1:-} session='' block='' server='' task='' layer_session command message pane select=
  [ -n "$action" ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session | --block | --server | --task) [ "$#" -ge 2 ] || die "$1 needs a value" ;;
    esac
    case "$1" in
      --session) session=$2; shift 2 ;;
      --block) block=$2; shift 2 ;;
      --server) server=$2; shift 2 ;;
      --task) task=$2; shift 2 ;;
      *) die "unknown plan option: $1" ;;
    esac
  done
  [ -z "$task" ] || task_ok "$task" || die "invalid task id: $task"
  case "$action" in
    away)
      plan_away "$server" "$session" "$block"
      return
      ;;
    goto)
      if [ -z "$task" ]; then
        task=$(first_waiting) || die "no worker is waiting on you"
      fi
      goto_target "$task" || die "$task has no Rex tab to go to"
      message="Showing $task"
      [ "$G_REMOTE" = 0 ] || message="Second mate $task runs on another host; showing this machine's $FM_REX_POPUP_LOCAL_SESSION session"
      jq -nc --arg t "$task" --arg s "$G_SESSION" --arg w "$G_WINDOW" --arg m "$message" \
        '{action:"goto", task:$t, pane:null, select:({session_id:$s} + (if $w == "" then {} else {window_id:$w} end)), message:$m}'
      return
      ;;
    fleet | this | peek | answer | note | merge) ;;
    *) die "unknown palette action: $action" ;;
  esac
  pane=
  if [ -z "$task" ]; then
    resolve_pane "$server" "$session" "$block"
    task=$R_TASK
    pane=$R_PANE
  fi
  case "$action" in
    this | peek) [ -n "$task" ] || die "the focused pane is not a Firstmate worker; use Show Fleet" ;;
  esac
  layer_session=$(popup_session "$server" "$session") || exit 1
  [ -z "$server" ] || select=$layer_session
  case "$action" in
    fleet) command=$(popup_command fleet) ;;
    this | peek) command=$(popup_command "$action" "$task") ;;
    *) if [ -n "$task" ]; then command=$(popup_command "$action" "$task"); else command=$(popup_command "$action"); fi ;;
  esac
  message=
  [ "$pane" != remote-worker ] || message="This pane belongs to second mate $task on $server."
  jq -nc --arg a "$action" --arg t "$task" --arg p "$pane" --arg s "$layer_session" --argjson c "$command" \
    --arg sel "$select" --arg m "$message" \
    '{action:$a, task:(if $t == "" then null else $t end), pane:(if $p == "" then null else $p end),
      layer:{session_id:$s, command:$c}, message:$m}
     + (if $sel == "" then {} else {select:{session_id:$sel}} end)'
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
        (if $r.remote then "Runs on:   \($r.remote.host // "another host") (second mate)" else empty end),
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
    -h | --help | help) sed -n '2,66p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) usage ;;
  esac
}

main "$@"
