#!/usr/bin/env bash
# fm-herdr-groups.sh - opt-in Herdr project groups: display-only metadata tags
# and a sorted agents view for this home's Herdr tasks.
#
# docs/herdr-backend.md "Project groups" owns the public contract (setting,
# rule syntax, tokens, status order, limits). This header owns the mechanics.
#
# Off by default. Every producer guards its call with one file test on the
# home's config/herdr-project-groups, so while that file is absent this script
# is never run. It re-reads the setting so a direct invocation of an absent or
# "off" setting does nothing except `clear` and `sidebar-config`.
#
# Producers:
#   bin/fm-watch.sh   sync, once per poll cycle
#   bin/fm-spawn.sh   order-key before a projected task is ordered, then
#                     sync <task> once its metadata is published
#
# Usage:
#   fm-herdr-groups.sh plan [<task>]
#   fm-herdr-groups.sh sync [<task>]
#   fm-herdr-groups.sh clear
#   fm-herdr-groups.sh order-key <task> <project-path>
#   fm-herdr-groups.sh sidebar-config [--apply <herdr-config.toml>]
#
# plan prints one "<task>\t<group>\t<state>\t<sort>\t<order>" line per
# ship or scout Herdr task recorded in this home, without contacting Herdr.
# sync reads each recorded session's workspace and pane lists once, reports
# only the tokens whose live value differs from the planned value through
# `herdr pane|workspace report-metadata --source firstmate`, and sets the
# agents view through bin/backends/herdr-agent-view.py whenever it reported a
# pane token, so a Herdr restart that dropped every token and the view is
# repaired by the next sync. Workspace tokens are reported only for a task's
# own projected workspace: an exact version 2 presentation journal binding the
# task's recorded session, workspace, and pane, whose live workspace holds that
# one pane. A pane missing from the live list is skipped.
# clear removes this home's tokens from live panes and projected workspaces and
# clears the agents view for every recorded session.
# order-key prints the "<rank>.<group>" key bin/fm-spawn.sh passes to
# fm_backend_herdr_projection_order_best_effort, or nothing when off.
# sidebar-config prints the suggested Herdr sidebar rows; with --apply it
# copies the named file to <file>.bak-<epoch> and appends the rows, refusing
# when the file already defines [ui.sidebar.spaces] or [ui.sidebar.agents].
# It never reloads Herdr; `herdr server reload-config` stays the operator's call.
#
# A Herdr client below protocol FM_HERDR_GROUPS_MIN_PROTOCOL warns once per
# protocol through state/.herdr-groups-unsupported-<protocol> and is skipped.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE resolve the
# home exactly as the other bin/ scripts do. FM_HERDR_GROUPS_AGENT_VIEW
# replaces the socket helper in tests.
#
# Exit status: 0 on success or when off, 2 on a usage error, 1 when a requested
# write failed. Producers ignore a failure so it never changes theirs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_HERDR_GROUPS_CONFIG="herdr-project-groups"
FM_HERDR_GROUPS_SOURCE="firstmate"
# agent.view.set, workspace.report_metadata, and pane.report_metadata with
# token readback in workspace and pane lists are verified on protocol 22
# (Herdr 0.9.5, wire schema from Herdr 0.9.3); no earlier protocol is verified.
FM_HERDR_GROUPS_MIN_PROTOCOL=22
FM_HERDR_GROUPS_UNSUPPORTED_PREFIX=".herdr-groups-unsupported-"
FM_HERDR_GROUPS_UNMATCHED_RANK=999
FM_HERDR_GROUPS_TOKEN_MAX=80
FM_HERDR_GROUPS_PANE_TOKENS="fm_group fm_state fm_task fm_sort"
FM_HERDR_GROUPS_WORKSPACE_TOKENS="fm_group fm_state fm_group_order"

usage() {
  echo "usage: fm-herdr-groups.sh plan [<task>] | sync [<task>] | clear | order-key <task> <project-path> | sidebar-config [--apply <herdr-config.toml>]" >&2
  exit 2
}

warn() {
  printf 'warning: herdr project groups: %s\n' "$*" >&2
}

task_ok() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

# Parsed setting: GROUPS_MODE is off, on (one group per project), or rules.
# Rules keep file order; RULE_GROUP[i] owns the space-separated
# RULE_SELECTORS[i], and RULE_RANK[i] is the order in which that group name
# first appears, so a group may span several lines.
GROUPS_MODE=off
RULE_GROUP=()
RULE_SELECTORS=()
RULE_RANK=()

load_setting() {
  local file="$CONFIG/$FM_HERDR_GROUPS_CONFIG" line trimmed lower group selectors selector rank i groups=0
  local -a lines=() sels=()
  GROUPS_MODE=off
  RULE_GROUP=()
  RULE_SELECTORS=()
  RULE_RANK=()
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    case "$trimmed" in ''|'#'*) continue ;; esac
    lines+=("$trimmed")
  done < "$file"
  if [ "${#lines[@]}" -eq 0 ]; then
    GROUPS_MODE=on
    return 0
  fi
  if [ "${#lines[@]}" -eq 1 ]; then
    lower=$(printf '%s' "${lines[0]}" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      off) return 0 ;;
      on) GROUPS_MODE=on; return 0 ;;
    esac
  fi
  GROUPS_MODE=rules
  for line in "${lines[@]}"; do
    read -r group selectors <<EOF
$line
EOF
    case "$group" in
      *[!A-Za-z0-9._+-]*|'')
        warn "$file: ignoring rule with invalid group name \"$group\" (letters, digits, . _ + - only)"
        continue
        ;;
    esac
    if [ "${#group}" -gt 32 ]; then
      warn "$file: ignoring rule for group \"$group\" (at most 32 characters)"
      continue
    fi
    read -r -a sels <<EOF
$selectors
EOF
    for selector in ${sels[@]+"${sels[@]}"}; do
      case "$selector" in
        'task:'?*|'repo:'?*|'*') ;;
        *) warn "$file: group \"$group\": ignoring unknown selector \"$selector\" (task:<prefix>, repo:<name>, or *)" ;;
      esac
    done
    rank=
    i=0
    while [ "$i" -lt "${#RULE_GROUP[@]}" ]; do
      [ "${RULE_GROUP[i]}" = "$group" ] && { rank=${RULE_RANK[i]}; break; }
      i=$((i + 1))
    done
    [ -n "$rank" ] || { groups=$((groups + 1)); rank=$groups; }
    RULE_GROUP+=("$group")
    RULE_SELECTORS+=("$selectors")
    RULE_RANK+=("$rank")
  done
}

# resolve_group <task> <project-path>: sets GROUP and RANK.
# Task-id prefixes win over repository names, which win over "*", in that order
# across all rules; within one selector kind the first matching line wins.
resolve_group() {
  local task=$1 project=${2%/} repo i selector kind
  local -a sels=()
  repo=${project##*/}
  [ -n "$repo" ] || repo=unknown
  GROUP=$repo
  RANK=0
  [ "$GROUPS_MODE" = rules ] || return 0
  for kind in task repo any; do
    i=0
    while [ "$i" -lt "${#RULE_GROUP[@]}" ]; do
      read -r -a sels <<EOF
${RULE_SELECTORS[i]}
EOF
      for selector in ${sels[@]+"${sels[@]}"}; do
        case "$kind:$selector" in
          task:task:?*)
            case "$task" in "${selector#task:}"|"${selector#task:}"-*) ;; *) continue ;; esac
            ;;
          repo:repo:?*)
            [ "$repo" = "${selector#repo:}" ] || continue
            ;;
          'any:*') ;;
          *) continue ;;
        esac
        GROUP=${RULE_GROUP[i]}
        RANK=${RULE_RANK[i]}
        return 0
      done
      i=$((i + 1))
    done
  done
  RANK=$FM_HERDR_GROUPS_UNMATCHED_RANK
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

# resolve_state <task> <kind>: sets STATE_LABEL and STATE_RANK from the task's
# status log through the shared classifier: an open decision or a captain-held
# transfer waits on the captain, blocked or failed is a problem, done is done,
# and everything else is running.
resolve_state() {
  local line verb
  STATE_LABEL=running
  STATE_RANK=3
  load_status_libs || return 0
  line=$(status_current_line "$STATE/$1.status" "$2" 2>/dev/null) || line=
  verb=$(status_line_verb "$line" 2>/dev/null) || verb=
  case "$verb" in
    needs-decision|"${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}")
      STATE_LABEL=needs-captain; STATE_RANK=1 ;;
    blocked|failed) STATE_LABEL=problem; STATE_RANK=2 ;;
    done) STATE_LABEL="done"; STATE_RANK=4 ;;
  esac
}

meta_value() { # <meta> <key>
  local line value=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$1" 2>/dev/null
  printf '%s' "$value"
}

# Collected ship and scout Herdr tasks, one tab-separated record each:
# task, kind, project, session, workspace, pane.
TASKS=()
collect_tasks() { # [<task>]
  local only=${1:-} meta id kind project session workspace pane
  TASKS=()
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    task_ok "$id" || continue
    [ -z "$only" ] || [ "$id" = "$only" ] || continue
    [ "$(meta_value "$meta" backend)" = herdr ] || continue
    kind=$(meta_value "$meta" kind)
    case "${kind:-ship}" in ship|scout) ;; *) continue ;; esac
    project=$(meta_value "$meta" project)
    session=$(meta_value "$meta" herdr_session)
    workspace=$(meta_value "$meta" herdr_workspace_id)
    pane=$(meta_value "$meta" herdr_pane_id)
    case "$session$workspace$pane" in *[[:space:]]*) continue ;; esac
    [ -n "$session" ] && [ -n "$workspace" ] && [ -n "$pane" ] || continue
    TASKS+=("$id"$'\t'"${kind:-ship}"$'\t'"$project"$'\t'"$session"$'\t'"$workspace"$'\t'"$pane")
  done
}

# task_sessions: the distinct sessions of the collected tasks, one per line.
task_sessions() {
  local record session
  for record in ${TASKS[@]+"${TASKS[@]}"}; do
    IFS=$'\t' read -r _ _ _ session _ _ <<EOF
$record
EOF
    printf '%s\n' "$session"
  done | awk '!seen[$0]++'
}

clip() { # <value>
  printf '%s' "${1:0:$FM_HERDR_GROUPS_TOKEN_MAX}"
}

# plan_task <record>: sets every planned value for one collected task.
plan_task() {
  IFS=$'\t' read -r P_TASK P_KIND P_PROJECT P_SESSION P_WORKSPACE P_PANE <<EOF
$1
EOF
  resolve_group "$P_TASK" "$P_PROJECT"
  resolve_state "$P_TASK" "$P_KIND"
  P_GROUP=$GROUP
  P_STATE=$STATE_LABEL
  P_ORDER=$(printf '%03d.%s' "$RANK" "$GROUP")
  P_SORT=$(clip "$P_ORDER.$STATE_RANK.$P_TASK")
}

cmd_plan() {
  local record
  collect_tasks "${1:-}"
  for record in ${TASKS[@]+"${TASKS[@]}"}; do
    plan_task "$record"
    printf '%s\t%s\t%s\t%s\t%s\n' "$P_TASK" "$P_GROUP" "$P_STATE" "$P_SORT" "$P_ORDER"
  done
}

BACKEND_LOADED=0
load_backend() {
  [ "$BACKEND_LOADED" = 1 ] && return 0
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" || return 1
  fm_backend_source herdr || return 1
  BACKEND_LOADED=1
}

# session_supported <session>: 0 when the client protocol is new enough.
session_supported() {
  local session=$1 protocol marker
  protocol=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.client.protocol // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*)
      warn "could not read the Herdr client protocol for session $session; skipping"
      return 1
      ;;
  esac
  [ "$protocol" -ge "$FM_HERDR_GROUPS_MIN_PROTOCOL" ] && return 0
  marker="$STATE/$FM_HERDR_GROUPS_UNSUPPORTED_PREFIX$protocol"
  if [ ! -e "$marker" ]; then
    warn "Herdr protocol $protocol is below the verified protocol $FM_HERDR_GROUPS_MIN_PROTOCOL (Herdr 0.9.5); tags and the agents view stay off until Herdr is upgraded"
    : > "$marker" 2>/dev/null || true
  fi
  return 1
}

# projected_workspace <task> <session> <workspace> <pane>: 0 when <workspace> is
# the task's own projected workspace under an exact version 2 journal binding.
projected_workspace() {
  local task=$1 session=$2 workspace=$3 pane=$4
  fm_backend_herdr_projection_journal_snapshot \
    "$STATE/$task$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX" "$task" 2>/dev/null || return 1
  [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" = "$session" ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" = "$workspace" ] \
    && [ "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" = "$pane" ]
}

# changed_tokens <live-json-object> <name=value>...: prints the --token
# arguments whose live value differs, one per line.
changed_tokens() {
  local live=$1 pair name value current
  shift
  for pair in "$@"; do
    name=${pair%%=*}
    value=${pair#*=}
    current=$(printf '%s' "$live" | jq -r --arg n "$name" '.[$n] // empty' 2>/dev/null) || current=
    [ "$current" = "$value" ] || printf '%s\n' "$pair"
  done
}

agent_view() { # <session> set|clear
  local session=$1 action=$2 socket helper
  socket=$(fm_backend_herdr_presentation_session_socket_path "$session") || {
    warn "could not resolve the socket for session $session; agents view not ${action}"
    return 1
  }
  helper=${FM_HERDR_GROUPS_AGENT_VIEW:-$SCRIPT_DIR/backends/herdr-agent-view.py}
  "$helper" "$socket" "$action" >/dev/null 2>&1 || {
    warn "agents view $action failed for session $session"
    return 1
  }
}

cmd_sync() {
  local only=${1:-} record session workspaces panes live_pane live_ws pane_count changed pair diff rc=0
  local -a args=()
  collect_tasks "$only"
  [ "${#TASKS[@]}" -gt 0 ] || return 0
  load_backend || { warn "could not load the Herdr adapter"; return 1; }
  for session in $(task_sessions); do
    session_supported "$session" || continue
    workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
      warn "could not list workspaces for session $session"; rc=1; continue
    }
    panes=$(fm_backend_herdr_cli "$session" pane list 2>/dev/null) || {
      warn "could not list panes for session $session"; rc=1; continue
    }
    changed=0
    for record in "${TASKS[@]}"; do
      plan_task "$record"
      [ "$P_SESSION" = "$session" ] || continue
      live_pane=$(printf '%s' "$panes" | jq -c --arg p "$P_PANE" --arg w "$P_WORKSPACE" '
        [.result.panes[]? | select(.pane_id == $p and .workspace_id == $w)]
        | if length == 1 then (.[0].tokens // {}) else empty end' 2>/dev/null) || live_pane=
      [ -n "$live_pane" ] || continue
      diff=$(changed_tokens "$live_pane" \
        "fm_group=$P_GROUP" "fm_state=$P_STATE" "fm_task=$P_TASK" "fm_sort=$P_SORT")
      if [ -n "$diff" ]; then
        args=()
        while IFS= read -r pair; do args+=(--token "$pair"); done <<EOF
$diff
EOF
        if fm_backend_herdr_cli "$session" pane report-metadata "$P_PANE" \
          --source "$FM_HERDR_GROUPS_SOURCE" "${args[@]}" >/dev/null 2>&1; then
          changed=1
        else
          warn "could not tag pane $P_PANE for task $P_TASK"; rc=1
        fi
      fi
      projected_workspace "$P_TASK" "$P_SESSION" "$P_WORKSPACE" "$P_PANE" || continue
      pane_count=$(printf '%s' "$workspaces" | jq -r --arg w "$P_WORKSPACE" '
        [.result.workspaces[]? | select(.workspace_id == $w)]
        | if length == 1 then .[0].pane_count else empty end' 2>/dev/null) || pane_count=
      [ "$pane_count" = 1 ] || continue
      live_ws=$(printf '%s' "$workspaces" | jq -c --arg w "$P_WORKSPACE" '
        [.result.workspaces[]? | select(.workspace_id == $w)][0].tokens // {}' 2>/dev/null) || live_ws='{}'
      diff=$(changed_tokens "$live_ws" \
        "fm_group=$P_GROUP" "fm_state=$P_STATE" "fm_group_order=$P_ORDER")
      [ -n "$diff" ] || continue
      args=()
      while IFS= read -r pair; do args+=(--token "$pair"); done <<EOF
$diff
EOF
      fm_backend_herdr_cli "$session" workspace report-metadata "$P_WORKSPACE" \
        --source "$FM_HERDR_GROUPS_SOURCE" "${args[@]}" >/dev/null 2>&1 || {
        warn "could not tag workspace $P_WORKSPACE for task $P_TASK"; rc=1
      }
    done
    if [ "$changed" = 1 ]; then
      agent_view "$session" set || rc=1
    fi
  done
  return "$rc"
}

cmd_clear() {
  local record session name rc=0
  local -a pane_args=() ws_args=()
  collect_tasks
  [ "${#TASKS[@]}" -gt 0 ] || return 0
  load_backend || { warn "could not load the Herdr adapter"; return 1; }
  for name in $FM_HERDR_GROUPS_PANE_TOKENS; do pane_args+=(--clear-token "$name"); done
  for name in $FM_HERDR_GROUPS_WORKSPACE_TOKENS; do ws_args+=(--clear-token "$name"); done
  for session in $(task_sessions); do
    session_supported "$session" || continue
    agent_view "$session" clear || rc=1
    for record in "${TASKS[@]}"; do
      IFS=$'\t' read -r P_TASK _ _ P_SESSION P_WORKSPACE P_PANE <<EOF
$record
EOF
      [ "$P_SESSION" = "$session" ] || continue
      clear_task_tokens || rc=1
    done
  done
  return "$rc"
}

clear_task_tokens() {
  local rc=0
  fm_backend_herdr_cli "$P_SESSION" pane report-metadata "$P_PANE" \
    --source "$FM_HERDR_GROUPS_SOURCE" "${pane_args[@]}" >/dev/null 2>&1 || {
    warn "could not clear pane $P_PANE for task $P_TASK"; rc=1
  }
  projected_workspace "$P_TASK" "$P_SESSION" "$P_WORKSPACE" "$P_PANE" || return "$rc"
  fm_backend_herdr_cli "$P_SESSION" workspace report-metadata "$P_WORKSPACE" \
    --source "$FM_HERDR_GROUPS_SOURCE" "${ws_args[@]}" >/dev/null 2>&1 || {
    warn "could not clear workspace $P_WORKSPACE for task $P_TASK"; rc=1
  }
  return "$rc"
}

sidebar_rows() {
  cat <<'EOF'

# Firstmate project groups (docs/herdr-backend.md "Project groups").
[ui.sidebar.spaces]
rows = [
  ["state_icon", "workspace"],
  [{ token = "$fm_group", bold = true }, "$fm_state"],
]

[ui.sidebar.agents]
rows = [
  ["state_icon", { token = "$fm_group", bold = true }, "$fm_state", "$fm_task"],
]
EOF
}

cmd_sidebar_config() {
  local target backup
  if [ "$#" -eq 0 ]; then
    sidebar_rows
    return 0
  fi
  [ "$#" -eq 2 ] && [ "$1" = --apply ] && [ -n "$2" ] || usage
  target=$2
  [ -f "$target" ] && [ ! -L "$target" ] || {
    echo "fm-herdr-groups: $target is not a regular file" >&2
    return 1
  }
  if grep -Eq '^[[:space:]]*\[ui\.sidebar\.(spaces|agents)\]' "$target"; then
    echo "fm-herdr-groups: $target already defines Herdr sidebar rows; merge the suggested rows by hand (fm-herdr-groups.sh sidebar-config prints them)" >&2
    return 1
  fi
  backup="$target.bak-$(date +%s)"
  cp -p "$target" "$backup" || {
    echo "fm-herdr-groups: could not back up $target" >&2
    return 1
  }
  sidebar_rows >> "$target" || {
    echo "fm-herdr-groups: could not append to $target; the original is in $backup" >&2
    return 1
  }
  echo "appended the project-group sidebar rows to $target (backup: $backup); run \`herdr server reload-config\` to apply them"
}

cmd=${1:-}
case "$cmd" in
  plan|sync)
    [ "$#" -le 2 ] || usage
    [ "$#" -lt 2 ] || task_ok "$2" || usage
    ;;
  clear) [ "$#" -eq 1 ] || usage ;;
  order-key) { [ "$#" -eq 3 ] && task_ok "$2"; } || usage ;;
  sidebar-config) ;;
  *) usage ;;
esac

case "$cmd" in
  sidebar-config)
    shift
    cmd_sidebar_config "$@"
    exit
    ;;
  clear)
    cmd_clear
    exit
    ;;
esac

load_setting
[ "$GROUPS_MODE" != off ] || exit 0

case "$cmd" in
  plan) cmd_plan "${2:-}" ;;
  sync) cmd_sync "${2:-}" ;;
  order-key)
    resolve_group "$2" "$3"
    printf '%03d.%s\n' "$RANK" "$GROUP"
    ;;
esac
