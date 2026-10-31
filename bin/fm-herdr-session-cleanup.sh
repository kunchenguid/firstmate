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
# Topology is first checked from one locked API snapshot, then every mutation
# prerequisite is immediately rechecked before the existing exact-pane
# focus-preserving close helper is called.
# The script never closes a workspace. It removes the matching journal only
# after the exact pane is confirmed gone. Separately, while reading the journal
# index once per run, it prunes each dead-projection journal as it is read:
# valid version 2, bound to this home and session, whose token and workspace
# id appear on no workspace in the snapshot, removed only while holding
# state/.spawn-<task>.lock with task metadata still absent and the journal's
# projection token unchanged; a busy lock skips the journal. A version 1
# journal is never pruned, since its liveness cannot be disproved. The whole
# pass runs under one wall budget (FM_HERDR_CLEANUP_BUDGET_SECS, default 30).
# Every error warns and returns success so session startup continues
# conservatively.
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
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

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

fm_herdr_cleanup_expired() {
  [ "$SECONDS" -ge "$fm_herdr_cleanup_deadline" ]
}

# One pass over every presentation journal. A dead projection journal
# (version 2, bound to this home and session, its token on no workspace label
# and its workspace id on no workspace) is pruned as soon as it is read, so a
# pass stopped by the budget still makes progress. Every other bound journal is
# collected into fm_herdr_cleanup_rows as "title<TAB>journal<TAB>id<TAB>token".
# A version 1 journal carries no workspace binding, so its liveness cannot be
# disproved and it is never pruned.
fm_herdr_cleanup_index() { # <session> <home-real> <live-workspace-ids> <labels>
  local session=$1 home_real=$2 live_ws=$'\n'$3$'\n' live_labels=$4
  local journal id expected journal_home token row
  fm_herdr_cleanup_rows=""
  for journal in "$STATE"/*"$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"; do
    [ -f "$journal" ] && [ ! -L "$journal" ] || continue
    if fm_herdr_cleanup_expired; then
      fm_herdr_cleanup_warn "projection journal index build exceeded budget; stopping early"
      break
    fi
    id=$(basename "$journal" "$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX")
    fm_task_id_creation_valid "$id" || continue
    fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || continue
    token=$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID
    # Version 1 carries no home/session binding, so the binding check is
    # satisfied by construction; version 2 must bind the real home identity
    # and the live named session.
    if [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ]; then
      journal_home=$(fm_backend_herdr_projection_home_identity \
        "$FM_BACKEND_HERDR_JOURNAL_HOME" 2>/dev/null) || journal_home=""
      { [ "$journal_home" = "$home_real" ] \
        && [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" = "$session" ]; } || continue
      case "$live_labels" in *"p:$token"*) ;; *)
        case "$live_ws" in *$'\n'"${FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID:-}"$'\n'*) ;; *)
          fm_herdr_cleanup_prune "$id" "$journal" "$token"
          continue ;;
        esac ;;
      esac
    fi
    expected=$(fm_backend_herdr_projection_workspace_label "$id" "$token")
    printf -v row '%s\t%s\t%s\t%s\n' "$expected" "$journal" "$id" "$token"
    fm_herdr_cleanup_rows=$fm_herdr_cleanup_rows$row
  done
}

# One awk join of the journal index against the title candidates. Prints
# "workspace<TAB>title<TAB>journal<TAB>id<TAB>token" for each candidate whose
# title matches exactly one live, bound journal.
fm_herdr_cleanup_join() { # <candidates> <rows>
  [ -n "$2" ] || return 0
  awk -F '\t' '
    FNR == NR { n++; ws[n] = $1; title[n] = $2; next }
    { count[$1]++; rec[$1] = $2 "\t" $3 "\t" $4 }
    END {
      for (i = 1; i <= n; i++)
        if (count[title[i]] == 1) print ws[i] "\t" title[i] "\t" rec[title[i]]
    }
  ' <(printf '%s\n' "$1") <(printf '%s' "$2")
}

# Remove one dead projection journal while holding its spawn lock, with task
# metadata still absent and the journal's token unchanged; a busy lock skips it.
fm_herdr_cleanup_prune() { # <task-id> <journal> <token>
  local id=$1 journal=$2 token=$3
  fm_lock_try_acquire "$STATE/.spawn-$id.lock" || return 0
  if [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] \
    && fm_backend_herdr_projection_journal_snapshot "$journal" "$id" \
    && [ "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" = "$token" ]; then
    rm -f -- "$journal"
    fm_herdr_cleanup_pruned_count=$((fm_herdr_cleanup_pruned_count + 1))
    [ "$fm_herdr_cleanup_pruned_count" -le 3 ] \
      && fm_herdr_cleanup_pruned_ids="${fm_herdr_cleanup_pruned_ids:+$fm_herdr_cleanup_pruned_ids, }$id"
  fi
  fm_lock_release "$STATE/.spawn-$id.lock" || true
}

# Immediate re-read of the one journal the join matched (no rescan).
fm_herdr_cleanup_reread() { # <journal> <task-id> <token>
  FM_HERDR_CLEANUP_VERSION=
  FM_HERDR_CLEANUP_BOUND_WORKSPACE=
  FM_HERDR_CLEANUP_BOUND_TAB=
  FM_HERDR_CLEANUP_BOUND_PANE=
  fm_backend_herdr_projection_journal_snapshot "$1" "$2" || return 1
  [ "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" = "$3" ] || return 1
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

fm_herdr_cleanup_revalidate() { # <session> <workspace> <tab> <pane> <title> <token> <journal> <task-id> <version> <bound-workspace> <bound-tab> <bound-pane>
  local session=$1 workspace=$2 tab=$3 pane=$4 title=$5 token=$6
  local journal=$7 id=$8 version=$9 bound_workspace=${10} bound_tab=${11} bound_pane=${12}
  local workspaces workspace_info tabs panes focus
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || return 1
  fm_herdr_cleanup_reread "$journal" "$id" "$token" || return 1
  [ "$FM_HERDR_CLEANUP_VERSION" = "$version" ] \
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

fm_herdr_cleanup_one() { # <session> <workspace> <title> <journal> <task-id> <journal-token>
  local session=$1 workspace=$2 title=$3 journal=$4 id=$5 token
  local version bound_workspace bound_tab bound_pane task_lock presentation_lock snapshot
  local tab pane state close_status=0
  token=$(fm_herdr_cleanup_title_token "$title") || return 0
  [ "$6" = "$token" ] || return 0
  fm_herdr_cleanup_reread "$journal" "$id" "$token" || return 0
  version=$FM_HERDR_CLEANUP_VERSION
  bound_workspace=$FM_HERDR_CLEANUP_BOUND_WORKSPACE
  bound_tab=$FM_HERDR_CLEANUP_BOUND_TAB
  bound_pane=$FM_HERDR_CLEANUP_BOUND_PANE
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
    "$session" "$workspace" "$tab" "$pane" "$title" "$token" \
    "$journal" "$id" "$version" "$bound_workspace" "$bound_tab" "$bound_pane"; then
    fm_herdr_cleanup_warn "$id preserved because immediate revalidation changed or was unreadable"
    fm_lock_release "$presentation_lock" || true
    fm_lock_release "$task_lock" || true
    return 0
  fi
  if fm_herdr_cleanup_expired; then
    fm_herdr_cleanup_warn "$id preserved because the cleanup budget expired before its pane close"
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
      && fm_herdr_cleanup_reread "$journal" "$id" "$token" \
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
  local session home_real list live_ws live_labels candidates joined a b c d e journal found=0 budget
  budget=$(fm_herdr_cleanup_budget_secs)
  fm_herdr_cleanup_deadline=$((SECONDS + budget))
  fm_herdr_cleanup_pruned_count=0
  fm_herdr_cleanup_pruned_ids=""
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
  if ! { candidates=$(printf '%s' "$list" | jq -er '
      .result.workspaces
      | select(type == "array")
      | .[]
      | select((.workspace_id | type) == "string" and (.workspace_id | length) > 0)
      | select((.label | type) == "string" and (.label | length) > 0)
      | [.workspace_id, .label] | @tsv
    ' 2>/dev/null) && live_ws=$(printf '%s' "$list" | jq -r '
      .result.workspaces[] | .workspace_id? // empty | tostring
    ' 2>/dev/null) && live_labels=$(printf '%s' "$list" | jq -r '
      .result.workspaces[] | .label? // empty | tostring
    ' 2>/dev/null); }; then
    fm_herdr_cleanup_warn "session '$session' workspace discovery was unreadable; preserving every candidate"
    return 0
  fi
  fm_herdr_cleanup_index "$session" "$home_real" "$live_ws" "$live_labels"
  joined=$(fm_herdr_cleanup_join "$candidates" "$fm_herdr_cleanup_rows") || {
    fm_herdr_cleanup_warn 'projection journal index could not be joined; preserving every candidate'
    return 0
  }
  while IFS=$'\t' read -r a b c d e; do
    [ -n "$a" ] || continue
    if fm_herdr_cleanup_expired; then
      fm_herdr_cleanup_warn "cleanup exceeded budget (${budget}s); stopping early"
      break
    fi
    fm_herdr_cleanup_one "$session" "$a" "$b" "$c" "$d" "$e"
  done <<< "$joined"
  if [ "$fm_herdr_cleanup_pruned_count" -gt 0 ]; then
    [ "$fm_herdr_cleanup_pruned_count" -gt 3 ] && fm_herdr_cleanup_pruned_ids="$fm_herdr_cleanup_pruned_ids, ..."
    fm_herdr_cleanup_warn "pruned $fm_herdr_cleanup_pruned_count dead projection journal(s): $fm_herdr_cleanup_pruned_ids"
  fi
  return 0
}

# One wall budget bounds the whole pass. The cooperative deadline stops at
# safe points; the entrypoint also runs the pass under fm_run_timed, bounded
# a short grace past the budget so the safe-point stop wins the
# race, and so a blocking Herdr call cannot hold session start much longer.
# Locks are pid-owned, so a killed pass leaves them recoverable.
fm_herdr_cleanup_grace_secs=3

fm_herdr_cleanup_budget_secs() {
  case "${FM_HERDR_CLEANUP_BUDGET_SECS:-}" in
    ''|*[!0-9]*|0) printf '30' ;;
    *) printf '%s' "$FM_HERDR_CLEANUP_BUDGET_SECS" ;;
  esac
}

if [ "${FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY:-0}" != 1 ]; then
  if [ "${FM_HERDR_CLEANUP_BOUNDED:-0}" = 1 ]; then
    fm_herdr_session_cleanup
    exit 0
  fi
  fm_herdr_cleanup_budget=$(fm_herdr_cleanup_budget_secs)
  fm_herdr_cleanup_bound=$((fm_herdr_cleanup_budget + fm_herdr_cleanup_grace_secs))
  fm_run_timed "$fm_herdr_cleanup_bound" env FM_HERDR_CLEANUP_BOUNDED=1 \
    "${BASH_SOURCE[0]}" || {
    fm_timed_out $? \
      && fm_herdr_cleanup_warn "pass exceeded its ${fm_herdr_cleanup_bound}s wall budget and was stopped"
  }
  exit 0
fi
