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
# one pane, absent task metadata, no registered agent, and a process proof that
# the pane contains only one idle recognized shell with no child process. A
# version 2 journal must also bind the exact workspace, tab, and pane.
# Every home-local journal is parsed once per cleanup pass into a title-keyed
# index; the mutation guards re-read live state by digesting once per check
# exactly the ordinary journal files, plus one deliberately unparseable line
# while the state directory is missing or a symlink, and re-parsing exactly
# any journal whose digest changed since the index, so no guard rescans every
# journal;
# fm_herdr_cleanup_index_refresh documents its one deliberate exception, the
# full rebuild on an unparseable digest line.
# Topology is first checked from one locked API snapshot, then every mutation
# prerequisite is immediately rechecked before the existing exact-pane
# focus-preserving close helper is called.
# The script never closes a workspace. It removes only the matching journal,
# and only after the exact pane is confirmed gone. Every error warns and returns
# success so session startup continues conservatively.
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

fm_herdr_cleanup_title_token() { # <workspace-title>
  local title=$1 prefix token rest
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

# One journal parse per cleanup pass: every candidate journal is snapshotted
# once into a title-keyed in-memory index, and each candidate workspace
# matches against that index instead of rescanning every journal per workspace.
# A matched record's journal stays existence-tested at lookup time, and the
# mutation guards reconcile the index with the live journal directory instead
# of rescanning: the digest checksums only ordinary journal files and gains a
# deliberately unparseable line whenever the state directory stops being an
# ordinary directory, so every file-type or directory transition either
# changes a digest line or forces the full index rebuild on that line. A
# matching digest therefore proves every row still mirrors its journal byte
# for byte, while any divergence names exactly the journals that must be
# re-read, and only those are re-parsed. Anything stale or contested
# degrades to conservative preservation, never to a silently stale row.
fm_herdr_cleanup_fingerprint() {
  local journal
  set --
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
    printf '%s\n' 'fm-herdr-session-cleanup: state directory is missing or a symlink'
    return 0
  }
  for journal in "$STATE"/*"$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"; do
    [ -f "$journal" ] && [ ! -L "$journal" ] || continue
    set -- "$@" "$journal"
  done
  [ "$#" -eq 0 ] || cksum "$@" 2>/dev/null
}

fm_herdr_cleanup_journal_validate() { # <journal> <id> <session> <home-real>
  local journal=$1 id=$2 session=$3 home_real=$4 journal_home
  fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || return 1
  if [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ]; then
    journal_home=$(fm_backend_herdr_projection_home_identity \
      "$FM_BACKEND_HERDR_JOURNAL_HOME" 2>/dev/null) || return 1
    [ "$journal_home" = "$home_real" ] \
      && [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" = "$session" ] || return 1
  fi
}

# Guard-grade unique match: reconcile the index against the live journal
# directory first (one digest pass, re-parsing only journals whose bytes
# changed so the rows are provably current), then resolve the one journal
# still matching the title from that reconciled index.
fm_herdr_cleanup_unique_match() { # <title> <session> <home-real>
  local title=$1 session=$2 home_real=$3
  fm_herdr_cleanup_index_refresh "$session" "$home_real"
  fm_herdr_cleanup_index_match "$title" "$session" "$home_real"
}

fm_herdr_cleanup_index_build() { # <session> <home-real>
  local session=$1 home_real=$2 journal id
  FM_HERDR_CLEANUP_INDEX=
  FM_HERDR_CLEANUP_FINGERPRINT=$(fm_herdr_cleanup_fingerprint)
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  for journal in "$STATE"/*"$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"; do
    [ -f "$journal" ] && [ ! -L "$journal" ] || continue
    id=$(basename "$journal" "$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX")
    fm_task_id_creation_valid "$id" || continue
    fm_herdr_cleanup_index_row_append "$journal" "$id" "$session" "$home_real" || continue
  done
}

# Parse one journal once into a fresh index row. Shared by the index build and
# the digest-driven reconciliation so both produce byte-identical rows.
fm_herdr_cleanup_index_row_append() { # <journal> <id> <session> <home-real>
  local journal=$1 id=$2 session=$3 home_real=$4 label
  fm_herdr_cleanup_journal_validate "$journal" "$id" "$session" "$home_real" || return 1
  label=$(fm_backend_herdr_projection_workspace_label \
    "$id" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID")
  FM_HERDR_CLEANUP_INDEX+="$label"$'\t'"$journal"$'\t'"$id"$'\t'
  FM_HERDR_CLEANUP_INDEX+="${FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID}"$'\t'
  FM_HERDR_CLEANUP_INDEX+="${FM_BACKEND_HERDR_JOURNAL_VERSION}"$'\t'
  FM_HERDR_CLEANUP_INDEX+="${FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID}"$'\t'
  FM_HERDR_CLEANUP_INDEX+="${FM_BACKEND_HERDR_JOURNAL_TAB_ID}"$'\t'
  FM_HERDR_CLEANUP_INDEX+="${FM_BACKEND_HERDR_JOURNAL_PANE_ID}"$'\n'
}

# Refresh exactly one journal path from live bytes: its previous rows are
# dropped, then the journal is re-parsed into fresh rows only while it is
# still an ordinary readable file with a valid task id and payload. A removed
# or invalid journal ends with no rows at all.
fm_herdr_cleanup_index_row_replace() { # <journal> <session> <home-real>
  local journal=$1 session=$2 home_real=$3 id
  local r_label r_journal r_id r_token r_version r_workspace r_tab r_pane
  local index=
  while IFS=$'\t' read -r r_label r_journal r_id r_token r_version r_workspace r_tab r_pane; do
    [ -n "$r_journal" ] || continue
    [ "$r_journal" = "$journal" ] && continue
    index+="$r_label"$'\t'"$r_journal"$'\t'"$r_id"$'\t'"$r_token"$'\t'
    index+="$r_version"$'\t'"$r_workspace"$'\t'"$r_tab"$'\t'"$r_pane"$'\n'
  done <<< "$FM_HERDR_CLEANUP_INDEX"
  FM_HERDR_CLEANUP_INDEX=$index
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 0
  id=$(basename "$journal" "$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX")
  fm_task_id_creation_valid "$id" || return 0
  fm_herdr_cleanup_index_row_append "$journal" "$id" "$session" "$home_real" || return 0
  return 0
}

# Reconcile the index with the live directory before a guard relies on it.
# A matching digest proves every row still mirrors the live bytes; otherwise
# exactly the digest lines that differ name their journals, and each one is
# re-read. An unparseable digest line falls back to a full index rebuild so a
# change can never be silently missed.
fm_herdr_cleanup_index_refresh() { # <session> <home-real>
  local session=$1 home_real=$2 next changed line journal seen
  local recorded=${FM_HERDR_CLEANUP_FINGERPRINT:-}
  local cksum_re='^([0-9]+)[[:space:]]([0-9]+)[[:space:]]+(.*)$'
  local NLPAD=$'\n'
  next=$(fm_herdr_cleanup_fingerprint)
  [ "$next" = "$recorded" ] && return 0
  changed=$(
    {
      printf '%s\n' "$recorded"
      printf '%s\n' "$next"
    } | LC_ALL=C sort | LC_ALL=C uniq -u
  )
  FM_HERDR_CLEANUP_FINGERPRINT=$next
  seen=$NLPAD
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! [[ "$line" =~ $cksum_re ]]; then
      fm_herdr_cleanup_index_build "$session" "$home_real"
      return 0
    fi
    journal=${BASH_REMATCH[3]}
    case "$seen" in *"$NLPAD$journal$NLPAD"*) continue ;; esac
    seen+="$journal$NLPAD"
    fm_herdr_cleanup_index_row_replace "$journal" "$session" "$home_real"
  done <<< "$changed"
}

fm_herdr_cleanup_index_match() { # <title> <session> <home-real>
  local title=$1 session=$2 home_real=$3
  local label journal id token version bound_workspace bound_tab bound_pane matches=0
  FM_HERDR_CLEANUP_JOURNAL=
  FM_HERDR_CLEANUP_ID=
  FM_HERDR_CLEANUP_TOKEN=
  FM_HERDR_CLEANUP_VERSION=
  FM_HERDR_CLEANUP_BOUND_WORKSPACE=
  FM_HERDR_CLEANUP_BOUND_TAB=
  FM_HERDR_CLEANUP_BOUND_PANE=
  if [ "${FM_HERDR_CLEANUP_INDEX_READY:-0}" != 1 ]; then
    fm_herdr_cleanup_index_build "$session" "$home_real"
    FM_HERDR_CLEANUP_INDEX_READY=1
  fi
  while IFS=$'\t' read -r label journal id token version bound_workspace bound_tab bound_pane; do
    [ "$label" = "$title" ] || continue
    [ -f "$journal" ] && [ ! -L "$journal" ] || continue
    matches=$((matches + 1))
    FM_HERDR_CLEANUP_JOURNAL=$journal
    FM_HERDR_CLEANUP_ID=$id
    FM_HERDR_CLEANUP_TOKEN=$token
    FM_HERDR_CLEANUP_VERSION=$version
    FM_HERDR_CLEANUP_BOUND_WORKSPACE=$bound_workspace
    FM_HERDR_CLEANUP_BOUND_TAB=$bound_tab
    FM_HERDR_CLEANUP_BOUND_PANE=$bound_pane
  done <<< "$FM_HERDR_CLEANUP_INDEX"
  [ "$matches" -eq 1 ] || return 1
  [ -n "$FM_HERDR_CLEANUP_JOURNAL" ] \
    && [ -n "$FM_HERDR_CLEANUP_ID" ] \
    && [ -n "$FM_HERDR_CLEANUP_TOKEN" ] || return 1
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
    | select($workspaces[0].tab_count == 1 and $workspaces[0].pane_count == 1)
    | select($tabs | length == 1)
    | select($panes | length == 1)
    | select($panes[0].tab_id == $tabs[0].tab_id)
    | select($bound_workspace == "" or $workspace == $bound_workspace)
    | select($bound_tab == "" or $tabs[0].tab_id == $bound_tab)
    | select($bound_pane == "" or $panes[0].pane_id == $bound_pane)
    | select($token_count == 1)
    | select(($s.focused_workspace_id | type) == "string")
    | select(($s.focused_tab_id | type) == "string")
    | select(($s.focused_pane_id | type) == "string")
    | select($s.focused_tab_id != $tabs[0].tab_id)
    | [$tabs[0].tab_id, $panes[0].pane_id] | @tsv
  ' 2>/dev/null) || return 1
  [ -n "$record" ] && [ "${record#*$'\t'}" != "$record" ] || return 1
  FM_HERDR_CLEANUP_TAB=${record%%$'\t'*}
  FM_HERDR_CLEANUP_PANE=${record#*$'\t'}
  [ -n "$FM_HERDR_CLEANUP_TAB" ] && [ -n "$FM_HERDR_CLEANUP_PANE" ]
}

fm_herdr_cleanup_revalidate() { # <session> <workspace> <tab> <pane> <title> <token> <home-real> <journal> <task-id> <version> <bound-workspace> <bound-tab> <bound-pane>
  local session=$1 workspace=$2 tab=$3 pane=$4 title=$5 token=$6 home_real=$7
  local journal=$8 id=$9 version=${10} bound_workspace=${11} bound_tab=${12} bound_pane=${13}
  local workspaces workspace_info tabs panes focus
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
  workspace_info=$(fm_backend_herdr_cli "$session" workspace get "$workspace" 2>/dev/null) || return 1
  printf '%s' "$workspace_info" | jq -e --arg workspace "$workspace" --arg title "$title" '
    .result.workspace.workspace_id == $workspace
    and .result.workspace.label == $title
    and .result.workspace.tab_count == 1
    and .result.workspace.pane_count == 1
  ' >/dev/null 2>&1 || return 1
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e --arg workspace "$workspace" --arg tab "$tab" '
    (.result.tabs | type) == "array"
    and (.result.tabs | length) == 1
    and .result.tabs[0].workspace_id == $workspace
    and .result.tabs[0].tab_id == $tab
  ' >/dev/null 2>&1 || return 1
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e --arg workspace "$workspace" --arg tab "$tab" --arg pane "$pane" '
    (.result.panes | type) == "array"
    and (.result.panes | length) == 1
    and .result.panes[0].workspace_id == $workspace
    and .result.panes[0].tab_id == $tab
    and .result.panes[0].pane_id == $pane
  ' >/dev/null 2>&1 || return 1
  [ "$(fm_backend_herdr_pane_agent_state "$session" "$pane")" = no-agent ] || return 1
  fm_backend_herdr_pane_idle_shell_pid "$session" "$pane" >/dev/null || return 1
  focus=$(fm_backend_herdr_projection_focus_snapshot "$session") || return 1
  [ "${focus#*$'\t'}" != "$tab" ]
}

fm_herdr_cleanup_one() { # <session> <workspace> <title> <home-real>
  local session=$1 workspace=$2 title=$3 home_real=$4 token journal id task_lock
  local version bound_workspace bound_tab bound_pane presentation_lock snapshot
  local tab pane state close_status=0
  token=$(fm_herdr_cleanup_title_token "$title") || return 0
  if ! fm_herdr_cleanup_index_match "$title" "$session" "$home_real"; then
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
  if [ "$(fm_backend_herdr_pane_agent_state "$session" "$pane")" != no-agent ] \
    || ! fm_backend_herdr_pane_idle_shell_pid "$session" "$pane" >/dev/null; then
    fm_herdr_cleanup_warn "$id preserved because its pane is not a provably idle childless shell"
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

  # This unconditional retirement is the authorized containment documented
  # with the presentation floor ownership in bin/backends/herdr.sh.
  fm_backend_herdr_projection_close_pane_focus_preserving \
    "$session" "$pane" no-agent || close_status=$?
  state=$(fm_backend_herdr_pane_agent_state "$session" "$pane")
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

fm_herdr_session_cleanup() {
  local session home_real list candidates workspace title journal found=0
  FM_HERDR_CLEANUP_INDEX=
  FM_HERDR_CLEANUP_INDEX_READY=0
  FM_HERDR_CLEANUP_FINGERPRINT=
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
