#!/usr/bin/env bash
# Retire stale restored-shell Herdr presentation children at locked session start.
#
# Usage: fm-herdr-session-cleanup.sh
#
# The caller must already own this Firstmate home's session lock. This script is
# home-local and considers only the current named Herdr session and ordinary
# state/*.herdr-presentation journals in the effective FM_HOME. Each candidate
# is additionally serialized by the existing state/.spawn-<task>.lock and the
# shared named-session Herdr presentation lock, in that order.
#
# A visible title is discovery only. Cleanup requires the exact current
# "└ <concise-task> · p:<22-char-token>" grammar, one token occurrence across
# the named-session snapshot, exactly one matching home-local journal, one tab,
# one idle shell pane with at most one owned sidebar pane, absent task metadata,
# and no registered agent in either pane. A sidebar requires its metadata token,
# exact foreground argv and an OS-proven shell with only that child and no jobs.
# Version 2 journals bind the exact home, session, workspace, tab, and agent pane.
# Every pane closure rechecks identity, topology, processes and focus under locks.
# Sidebar closes first; the existing focus-preserving helper closes each pane.
# A separate journal sweep retires only version 2 bindings proven absent in two
# complete snapshots, with no matching workspace token or surviving endpoint.
# Every error preserves the candidate so session startup continues conservatively.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

fm_herdr_cleanup_warn() {
  printf 'warning: herdr session-start projection cleanup: %s\n' "$*" >&2
}

fm_herdr_cleanup_canonical_title() { # <visible-title>
  local title=$1
  if [[ "$title" =~ ^\[[0-9]+\]\ (.*)$ ]]; then
    title=${BASH_REMATCH[1]}
  fi
  printf '%s' "$title"
}

fm_herdr_cleanup_title_token() { # <workspace-title>
  local title=$1 prefix token rest
  title=$(fm_herdr_cleanup_canonical_title "$title")
  case "$title" in
    '└ '*' · p:'*) ;;
    *) return 1 ;;
  esac
  token=${title##*' · p:'}
  prefix=${title%" · p:$token"}
  [ "$prefix" != "$title" ] && [ -n "${prefix#'└ '}" ] || return 1
  [ "${#token}" -eq 22 ] || return 1
  case "$token" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  rest=${title#*p:}
  [ "$rest" != "$title" ] || return 1
  case "$rest" in *p:*) return 1 ;; esac
  printf '%s' "$token"
}

fm_herdr_cleanup_home_identity() {
  [ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] || return 1
  (cd "$FM_HOME" 2>/dev/null && pwd -P)
}

fm_herdr_cleanup_journal_matches() { # <title> <session> <home-real>
  local title=$1 session=$2 home_real=$3 journal id expected journal_home
  title=$(fm_herdr_cleanup_canonical_title "$title")
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  for journal in "$STATE"/*"$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"; do
    [ -f "$journal" ] && [ ! -L "$journal" ] || continue
    id=$(basename "$journal" "$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX")
    fm_task_id_creation_valid "$id" || continue
    fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || continue
    if [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ]; then
      journal_home=$(fm_backend_herdr_projection_home_identity \
        "$FM_BACKEND_HERDR_JOURNAL_HOME" 2>/dev/null) || continue
      [ "$journal_home" = "$home_real" ] \
        && [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" = "$session" ] || continue
    fi
    expected=$(fm_backend_herdr_projection_workspace_label \
      "$id" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID")
    [ "$expected" = "$title" ] || continue
    printf '%s\t%s\t%s\n' "$journal" "$id" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID"
  done
}

fm_herdr_cleanup_unique_match() { # <title> <session> <home-real>
  local title=$1 session=$2 home_real=$3 matches count record
  FM_HERDR_CLEANUP_JOURNAL=
  FM_HERDR_CLEANUP_ID=
  FM_HERDR_CLEANUP_TOKEN=
  FM_HERDR_CLEANUP_VERSION=
  FM_HERDR_CLEANUP_BOUND_WORKSPACE=
  FM_HERDR_CLEANUP_BOUND_TAB=
  FM_HERDR_CLEANUP_BOUND_PANE=
  matches=$(fm_herdr_cleanup_journal_matches "$title" "$session" "$home_real") || return 1
  count=$(printf '%s\n' "$matches" | awk 'NF { n++ } END { print n+0 }')
  [ "$count" -eq 1 ] || return 1
  record=$(printf '%s\n' "$matches" | awk 'NF { print; exit }')
  FM_HERDR_CLEANUP_JOURNAL=${record%%$'\t'*}
  record=${record#*$'\t'}
  FM_HERDR_CLEANUP_ID=${record%%$'\t'*}
  FM_HERDR_CLEANUP_TOKEN=${record#*$'\t'}
  [ -n "$FM_HERDR_CLEANUP_JOURNAL" ] \
    && [ -n "$FM_HERDR_CLEANUP_ID" ] \
    && [ -n "$FM_HERDR_CLEANUP_TOKEN" ] || return 1
  fm_backend_herdr_projection_journal_snapshot \
    "$FM_HERDR_CLEANUP_JOURNAL" "$FM_HERDR_CLEANUP_ID" || return 1
  [ "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" = "$FM_HERDR_CLEANUP_TOKEN" ] || return 1
  FM_HERDR_CLEANUP_VERSION=$FM_BACKEND_HERDR_JOURNAL_VERSION
  if [ "$FM_HERDR_CLEANUP_VERSION" = 2 ]; then
    FM_HERDR_CLEANUP_BOUND_WORKSPACE=$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID
    FM_HERDR_CLEANUP_BOUND_TAB=$FM_BACKEND_HERDR_JOURNAL_TAB_ID
    FM_HERDR_CLEANUP_BOUND_PANE=$FM_BACKEND_HERDR_JOURNAL_PANE_ID
  fi
}

fm_herdr_cleanup_snapshot_candidate() { # <snapshot> <workspace> <title> <token> <bound-workspace> <bound-tab> <bound-pane>
  local snapshot=$1 workspace=$2 title=$3 token=$4
  local bound_workspace=$5 bound_tab=$6 bound_pane=$7 record
  FM_HERDR_CLEANUP_TAB=
  FM_HERDR_CLEANUP_PANE=
  record=$(printf '%s' "$snapshot" | jq -er \
    --arg workspace "$workspace" --arg title "$title" --arg token "$token" \
    --arg bound_workspace "$bound_workspace" --arg bound_tab "$bound_tab" \
    --arg bound_pane "$bound_pane" '
    .result.snapshot as $s
    | [$s.workspaces[]? | select(.workspace_id == $workspace)] as $workspaces
    | [$s.tabs[]? | select(.workspace_id == $workspace)] as $tabs
    | [$s.panes[]? | select(.workspace_id == $workspace)] as $panes
    | ([ $s.workspaces[]?.label? // "" |
         ((split("p:" + $token) | length) - 1) ] | add // 0) as $token_count
    | select($workspaces | length == 1)
    | select($workspaces[0].label == $title)
    | select($workspaces[0].tab_count == 1)
    | select($tabs | length == 1)
    | select(($panes | length) >= 1 and ($panes | length) <= 2)
    | select($workspaces[0].pane_count == ($panes | length))
    | select(all($panes[]; .tab_id == $tabs[0].tab_id))
    | select(($panes | map(.pane_id) | unique | length) == ($panes | length))
    | select($bound_workspace == "" or $workspace == $bound_workspace)
    | select($bound_tab == "" or $tabs[0].tab_id == $bound_tab)
    | select($bound_pane == "" or any($panes[]; .pane_id == $bound_pane))
    | select($token_count == 1)
    | select(($s.focused_workspace_id | type) == "string")
    | select(($s.focused_tab_id | type) == "string")
    | select(($s.focused_pane_id | type) == "string")
    | select($s.focused_tab_id != $tabs[0].tab_id)
    | [$tabs[0].tab_id, ($panes | map(.pane_id) | sort | join(","))] | @tsv
  ' 2>/dev/null) || return 1
  [ -n "$record" ] && [ "${record#*$'\t'}" != "$record" ] || return 1
  FM_HERDR_CLEANUP_TAB=${record%%$'\t'*}
  FM_HERDR_CLEANUP_PANE=${record#*$'\t'}
  [ -n "$FM_HERDR_CLEANUP_TAB" ] && [ -n "$FM_HERDR_CLEANUP_PANE" ]
}

# Sidebar acceptance is cleanup-only: never weaken the backend's shell-death proof.
fm_herdr_cleanup_sidebar() { # <session> <pane>
  local session=$1 pane=$2 info record shell child rows attempt=0
  info=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  printf '%s' "$info" | jq -e --arg pane "$pane" '
    .result.pane.pane_id == $pane
    and (.result.pane.tokens | type == "object")
    and (.result.pane.tokens | has("herdr-sidebar-explorer"))
  ' >/dev/null 2>&1 || return 1
  while [ "$attempt" -lt 10 ]; do
    info=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || return 1
    record=$(printf '%s' "$info" | jq -er --arg pane "$pane" '
      select(.result.type == "pane_process_info") | .result.process_info
      | select(.pane_id == $pane)
      | select((.shell_pid | type) == "number" and .shell_pid > 1)
      | select(.foreground_processes | length == 1)
      | .foreground_processes[0] as $p
      | select($p.pid == .foreground_process_group_id and $p.pid != .shell_pid)
      | select($p.name == "herdr-sidebar" and $p.argv == ["herdr-sidebar"])
      | [.shell_pid, $p.pid] | @tsv
    ' 2>/dev/null) || record=
    if [ -n "$record" ]; then
      shell=${record%%$'\t'*}; child=${record#*$'\t'}
      rows=$("${FM_HERDR_PS_BIN:-ps}" -axo pid=,ppid=,comm= 2>/dev/null) || return 1
      if printf '%s\n' "$rows" | awk -v shell="$shell" -v child="$child" '
        function base(n) { sub(/^.*\//, "", n); sub(/^-/, "", n); return n }
        $1 == shell { n++; if (base($3) !~ /^(sh|bash|zsh|dash|ksh|fish)$/) bad=1 }
        $2 == shell { children++; if ($1 != child) bad=1 }
        $1 == child { c++; if ($2 != shell || base($3) != "herdr-sidebar") bad=1 }
        $2 == child { bad=1 }
        END { exit(n == 1 && c == 1 && children == 1 && !bad ? 0 : 1) }
      '; then
        return 0
      fi
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  return 1
}

fm_herdr_cleanup_processes() { # <session> <comma-separated-panes>
  local session=$1 panes=$2 pane sidebar='' idle='' count=0
  local -a ids
  IFS=, read -r -a ids <<< "$panes"
  for pane in "${ids[@]}"; do
    [ "$(fm_backend_herdr_pane_agent_state "$session" "$pane")" = no-agent ] || return 1
    if fm_backend_herdr_pane_idle_shell_pid "$session" "$pane" >/dev/null; then
      [ -z "$idle" ] || return 1
      idle=$pane
    elif fm_herdr_cleanup_sidebar "$session" "$pane"; then
      [ -z "$sidebar" ] || return 1
      sidebar=$pane
    else
      return 1
    fi
    count=$((count + 1))
  done
  [ "$count" -ge 1 ] && [ "$count" -le 2 ] || return 1
  [ -n "$idle" ] || return 1
  FM_HERDR_CLEANUP_FIRST_PANE=${sidebar:-$idle}
}

fm_herdr_cleanup_revalidate() { # <session> <workspace> <tab> <pane> <title> <token> <home-real> <journal> <task-id> <version> <bound-workspace> <bound-tab> <bound-pane>
  local session=$1 workspace=$2 tab=$3 pane=$4 title=$5 token=$6 home_real=$7
  local journal=$8 id=$9 version=${10} bound_workspace=${11} bound_tab=${12} bound_pane=${13}
  local workspaces snapshot focus
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || return 1
  fm_herdr_cleanup_unique_match "$title" "$session" "$home_real" || return 1
  [ "$FM_HERDR_CLEANUP_JOURNAL" = "$journal" ] \
    && [ "$FM_HERDR_CLEANUP_ID" = "$id" ] \
    && [ "$FM_HERDR_CLEANUP_TOKEN" = "$token" ] \
    && [ "$FM_HERDR_CLEANUP_VERSION" = "$version" ] \
    && [ "$FM_HERDR_CLEANUP_BOUND_WORKSPACE" = "$bound_workspace" ] \
    && [ "$FM_HERDR_CLEANUP_BOUND_TAB" = "$bound_tab" ] \
    && [ "$FM_HERDR_CLEANUP_BOUND_PANE" = "$bound_pane" ] || return 1

  workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$workspaces" | jq -e --arg workspace "$workspace" --arg title "$title" --arg token "$token" '
    ([.result.workspaces[]? | select(.workspace_id == $workspace and .label == $title)] | length) == 1
    and ([.result.workspaces[]?.label? // "" |
          ((split("p:" + $token) | length) - 1)] | add // 0) == 1
  ' >/dev/null 2>&1 || return 1
  snapshot=$(fm_backend_herdr_cli "$session" api snapshot 2>/dev/null) || return 1
  fm_herdr_cleanup_snapshot_candidate "$snapshot" "$workspace" "$title" "$token" \
    "$bound_workspace" "$bound_tab" "$bound_pane" || return 1
  [ "$FM_HERDR_CLEANUP_TAB" = "$tab" ] && [ "$FM_HERDR_CLEANUP_PANE" = "$pane" ] || return 1
  fm_herdr_cleanup_processes "$session" "$pane" || return 1
  focus=$(fm_backend_herdr_projection_focus_snapshot "$session") || return 1
  [ "${focus#*$'\t'}" != "$tab" ]
}

fm_herdr_cleanup_one() { # <session> <workspace> <title> <home-real>
  local session=$1 workspace=$2 title=$3 home_real=$4 token journal id task_lock
  local version bound_workspace bound_tab bound_pane presentation_lock snapshot
  local tab pane state close_status=0 target remaining
  token=$(fm_herdr_cleanup_title_token "$title") || return 0
  if ! fm_herdr_cleanup_unique_match "$title" "$session" "$home_real"; then
    return 0
  fi
  journal=$FM_HERDR_CLEANUP_JOURNAL
  id=$FM_HERDR_CLEANUP_ID
  version=$FM_HERDR_CLEANUP_VERSION
  bound_workspace=$FM_HERDR_CLEANUP_BOUND_WORKSPACE
  bound_tab=$FM_HERDR_CLEANUP_BOUND_TAB
  bound_pane=$FM_HERDR_CLEANUP_BOUND_PANE
  [ "$FM_HERDR_CLEANUP_TOKEN" = "$token" ] || return 0
  task_lock="$STATE/.spawn-$id.lock"
  if ! fm_lock_try_acquire "$task_lock"; then
    fm_herdr_cleanup_warn "$id skipped because its task lock is busy"
    return 0
  fi
  presentation_lock=$(fm_backend_herdr_presentation_session_lock_path "$session" 2>/dev/null) || {
    fm_lock_release "$task_lock" || true
    fm_herdr_cleanup_warn "$id skipped because the shared presentation lock is unavailable"
    return 0
  }
  if ! fm_lock_try_acquire "$presentation_lock"; then
    fm_lock_release "$task_lock" || true
    fm_herdr_cleanup_warn "$id skipped because the shared presentation lock is busy"
    return 0
  fi

  if [ -e "$STATE/$id.meta" ] || [ -L "$STATE/$id.meta" ]; then
    fm_lock_release "$presentation_lock" || true
    fm_lock_release "$task_lock" || true
    return 0
  fi
  snapshot=$(fm_backend_herdr_cli "$session" api snapshot 2>/dev/null) || snapshot=
  if [ -z "$snapshot" ] \
    || ! fm_herdr_cleanup_snapshot_candidate \
      "$snapshot" "$workspace" "$title" "$token" \
      "$bound_workspace" "$bound_tab" "$bound_pane"; then
    fm_herdr_cleanup_warn "$id preserved because its locked candidate snapshot was ambiguous"
    fm_lock_release "$presentation_lock" || true
    fm_lock_release "$task_lock" || true
    return 0
  fi
  tab=$FM_HERDR_CLEANUP_TAB
  pane=$FM_HERDR_CLEANUP_PANE
  if ! fm_herdr_cleanup_processes "$session" "$pane"; then
    fm_herdr_cleanup_warn "$id preserved because its panes are not proven idle shells or owned sidebar"
    fm_lock_release "$presentation_lock" || true
    fm_lock_release "$task_lock" || true
    return 0
  fi
  if ! fm_herdr_cleanup_revalidate \
    "$session" "$workspace" "$tab" "$pane" "$title" "$token" "$home_real" \
    "$journal" "$id" "$version" "$bound_workspace" "$bound_tab" "$bound_pane"; then
    fm_herdr_cleanup_warn "$id preserved because immediate revalidation changed or was unreadable"
    fm_lock_release "$presentation_lock" || true
    fm_lock_release "$task_lock" || true
    return 0
  fi

  remaining=$pane
  while [ -n "$remaining" ]; do
    fm_herdr_cleanup_revalidate \
      "$session" "$workspace" "$tab" "$remaining" "$title" "$token" "$home_real" \
      "$journal" "$id" "$version" "$bound_workspace" "$bound_tab" "$bound_pane" || break
    target=$FM_HERDR_CLEANUP_FIRST_PANE
    fm_backend_herdr_projection_close_pane_focus_preserving \
      "$session" "$target" no-agent || { close_status=$?; break; }
    [ "$(fm_backend_herdr_pane_agent_state "$session" "$target")" = dead ] || break
    case ",$remaining," in
      ",$target,") remaining= ;;
      ",$target,"*) remaining=${remaining#*,} ;;
      *) remaining=${remaining%,*} ;;
    esac
  done
  state=unknown
  if [ -z "$remaining" ]; then
    state=dead
  fi
  if [ "$state" = dead ]; then
    if [ -f "$journal" ] && [ ! -L "$journal" ] \
      && fm_herdr_cleanup_unique_match "$title" "$session" "$home_real" \
      && [ "$FM_HERDR_CLEANUP_JOURNAL" = "$journal" ] \
      && [ "$FM_HERDR_CLEANUP_ID" = "$id" ] \
      && [ "$FM_HERDR_CLEANUP_VERSION" = "$version" ] \
      && [ "$FM_HERDR_CLEANUP_BOUND_WORKSPACE" = "$bound_workspace" ] \
      && [ "$FM_HERDR_CLEANUP_BOUND_TAB" = "$bound_tab" ] \
      && [ "$FM_HERDR_CLEANUP_BOUND_PANE" = "$bound_pane" ] \
      && [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ]; then
      rm -f -- "$journal" || fm_herdr_cleanup_warn "$id pane closed but its journal could not be retired"
    else
      fm_herdr_cleanup_warn "$id pane closed but its journal changed and was preserved"
    fi
  elif [ "$close_status" -ne 0 ]; then
    fm_herdr_cleanup_warn "$id preserved because exact focus-safe pane closure was refused or unconfirmed"
  else
    fm_herdr_cleanup_warn "$id preserved because exact pane closure could not be confirmed"
  fi
  fm_lock_release "$presentation_lock" || true
  fm_lock_release "$task_lock" || true

  return 0
}
fm_herdr_cleanup_orphan_absent() { # <session> <home-real> <journal> <id>
  local session=$1 home_real=$2 journal=$3 id=$4 title snapshot
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || return 1
  fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || return 1
  [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ] || return 1
  title=$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL
  fm_herdr_cleanup_unique_match "$title" "$session" "$home_real" || return 1
  [ "$FM_HERDR_CLEANUP_JOURNAL" = "$journal" ] || return 1
  snapshot=$(fm_backend_herdr_cli "$session" api snapshot 2>/dev/null) || return 1
  printf '%s' "$snapshot" | jq -e \
    --arg workspace "$FM_HERDR_CLEANUP_BOUND_WORKSPACE" \
    --arg tab "$FM_HERDR_CLEANUP_BOUND_TAB" --arg pane "$FM_HERDR_CLEANUP_BOUND_PANE" \
    --arg token "$FM_HERDR_CLEANUP_TOKEN" '
    .result.snapshot
    | select((.workspaces | type) == "array" and (.tabs | type) == "array"
        and (.panes | type) == "array" and (.agents | type) == "array")
    | all(.workspaces[]; (.workspace_id | type) == "string" and (.label | type) == "string")
      and all(.tabs[]; (.tab_id | type) == "string" and (.workspace_id | type) == "string")
      and all(.panes[]; (.pane_id | type) == "string" and (.tab_id | type) == "string"
        and (.workspace_id | type) == "string")
      and all(.workspaces[]; .workspace_id != $workspace and (.label | contains("p:" + $token) | not))
      and all(.tabs[]; .tab_id != $tab and .workspace_id != $workspace)
      and all(.panes[]; .pane_id != $pane and .tab_id != $tab and .workspace_id != $workspace)
      and all(.agents[]; (.pane_id | type) == "string" and .pane_id != $pane)
  ' >/dev/null 2>&1
}

fm_herdr_cleanup_orphan() { # <session> <home-real> <journal>
  local session=$1 home_real=$2 journal=$3 id task_lock presentation_lock before
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 0
  id=$(basename "$journal" "$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX")
  fm_task_id_creation_valid "$id" || return 0
  task_lock="$STATE/.spawn-$id.lock"
  fm_lock_try_acquire "$task_lock" || return 0
  presentation_lock=$(fm_backend_herdr_presentation_session_lock_path "$session" 2>/dev/null) || {
    fm_lock_release "$task_lock" || true
    return 0
  }
  if fm_lock_try_acquire "$presentation_lock"; then
    before=$(cat "$journal" 2>/dev/null) || before=
    if [ -n "$before" ] \
      && fm_herdr_cleanup_orphan_absent "$session" "$home_real" "$journal" "$id" \
      && fm_herdr_cleanup_orphan_absent "$session" "$home_real" "$journal" "$id" \
      && [ -f "$journal" ] && [ ! -L "$journal" ] \
      && [ "$(cat "$journal")" = "$before" ] \
      && [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ]; then
      rm -f -- "$journal" || fm_herdr_cleanup_warn "$id orphan journal could not be retired"
    fi
    fm_lock_release "$presentation_lock" || true
  fi
  fm_lock_release "$task_lock" || true
}

fm_herdr_session_cleanup() {
  local session home_real list candidates workspace title journal found=0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  for journal in "$STATE"/*"$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"; do
    if [ -f "$journal" ] && [ ! -L "$journal" ]; then
      found=1
      break
    fi
  done
  [ "$found" -eq 1 ] || return 0
  command -v herdr >/dev/null 2>&1 \
    && command -v jq >/dev/null 2>&1 || return 0
  home_real=$(fm_herdr_cleanup_home_identity) || {
    fm_herdr_cleanup_warn 'home identity is unreadable; preserving every candidate'
    return 0
  }
  session=$(fm_backend_herdr_session)
  for journal in "$STATE"/*"$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"; do
    fm_herdr_cleanup_orphan "$session" "$home_real" "$journal"
  done
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    fm_herdr_cleanup_warn "session '$session' workspace discovery failed; preserving every candidate"
    return 0
  }
  candidates=$(printf '%s' "$list" | jq -er '
    .result.workspaces
    | select(type == "array")
    | .[]
    | select((.workspace_id | type) == "string" and (.workspace_id | length) > 0)
    | select((.label | type) == "string" and (.label | length) > 0)
    | [.workspace_id, .label] | @tsv
  ' 2>/dev/null) || {
    fm_herdr_cleanup_warn "session '$session' workspace discovery was unreadable; preserving every candidate"
    return 0
  }
  while IFS=$'\t' read -r workspace title; do
    [ -n "$workspace" ] && [ -n "$title" ] || continue
    fm_herdr_cleanup_one "$session" "$workspace" "$title" "$home_real"
  done <<< "$candidates"
  return 0
}

if [ "${FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY:-0}" != 1 ]; then
  fm_herdr_session_cleanup
  exit 0
fi
