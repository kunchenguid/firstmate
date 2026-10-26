#!/usr/bin/env bash
# fm-herdr-husk-lib.sh - the session-start sweep that closes orphan Herdr task
# panes ("husks"), sourced by bin/fm-bootstrap.sh's herdr_husk_sweep.
#
# A Herdr server restart restores every workspace, tab, and label but none of
# the processes, so a task tab comes back as a bare shell in the tab's creation
# directory. A spawn that aborted before closing its tab leaves the same shape.
# When no local Firstmate home still records the task, that tab is a husk:
# nothing will ever reuse it, and a bare shell parked in a pool slot keeps
# treehouse from handing the slot on. docs/herdr-backend.md "Husks after a
# server restart" owns the contract in prose; this header owns the mechanics.
#
# fm_herdr_husk_sweep <session> <state-dir>
#   Scans every tab of <session> and prints one record per CANDIDATE, a tab
#   whose label parses as a task label `fm-<id>` and whose task has no
#   `<id>.meta` in any local Firstmate home (fm_local_firstmate_state_dirs,
#   rooted at <state-dir>). A tab with a live record is a live task, not a
#   candidate, and prints nothing.
#     closed<TAB>fm-<id><TAB><session>:<pane-id>
#     kept<TAB>fm-<id><TAB><session>:<pane-id or ->><TAB><failing condition>
#   A candidate is closed only when EVERY condition below holds, and the first
#   failing condition is the kept reason:
#     1. no `.herdr-presentation` journal for <id> in any local home binds a
#        different pane that is still present in this session;
#     2. the tab holds exactly one pane, that pane positively reads no-agent,
#        and fm_backend_herdr_pane_idle_shell_pid proves one lone idle shell
#        with no child process;
#     3. the pane's foreground cwd is not inside a treehouse pool slot that a
#        live task record (`worktree=` in any local home) or a `.fm-slot-owner`
#        claim names: that shell is the slot's only protection against
#        reassignment while its task is parked;
#     4. fm_backend_herdr_projection_target_tab_mutation_allowed permits the
#        close (never the captain's active tab with a viewer attached);
#     5. the task's spawn lock and the named-session presentation lock can both
#        be taken, and conditions 2 and 4 still hold under them.
#   The close is fm_backend_herdr_close_idle_endpoint, the same exact-pane
#   focus-preserving close every other pane retirement uses; a refused or
#   unconfirmed close keeps the pane. Only after the pane is confirmed gone are
#   the task's orphan journals retired: a version 2 journal bound to exactly
#   that pane, or a version 1 journal whose token no workspace label still
#   carries. This sweep never closes a tab, never runs `workspace close`, and
#   never signals a process; a server that is not running, an unreadable
#   listing, or an unprovable set of local homes makes the whole sweep a
#   silent no-op (one warning on stderr) rather than a guess.
set -u

FM_HERDR_HUSK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$FM_HERDR_HUSK_LIB_DIR/fm-backend.sh"
fm_backend_source herdr
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$FM_HERDR_HUSK_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh disable=SC1091
. "$FM_HERDR_HUSK_LIB_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$FM_HERDR_HUSK_LIB_DIR/fm-pr-lib.sh"

fm_herdr_husk_warn() {
  printf 'warning: herdr husk sweep: %s\n' "$*" >&2
}

fm_herdr_husk_real_path() {  # <path>
  [ -d "$1" ] || return 1
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

# fm_herdr_husk_task_id: the task id a tab label names, or nothing when the
# label is not a creation-valid `fm-<id>` task label.
fm_herdr_husk_task_id() {  # <label>
  local label=$1 id
  case "$label" in fm-?*) ;; *) return 1 ;; esac
  id=${label#fm-}
  fm_task_id_creation_valid "$id" || return 1
  printf '%s' "$id"
}

# fm_herdr_husk_meta_present: a `<id>.meta` exists in any local home.
fm_herdr_husk_meta_present() {  # <id>
  local id=$1 dir
  for dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ -e "$dir/$id.meta" ] || [ -L "$dir/$id.meta" ]; then
      return 0
    fi
  done
  return 1
}

# fm_herdr_husk_journal_names_other_live_pane: some local home's journal for
# <id> is a version 2 binding to a pane other than <pane> that is still present
# in <session>. Prints that pane id.
fm_herdr_husk_journal_names_other_live_pane() {  # <session> <id> <pane>
  local session=$1 id=$2 pane=$3 dir journal
  for dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    journal="$dir/$id$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"
    [ -f "$journal" ] && [ ! -L "$journal" ] || continue
    fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || continue
    [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ] || continue
    [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" = "$session" ] || continue
    [ "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" != "$pane" ] || continue
    if [ "$(fm_backend_herdr_pane_presence_state "$session" "$FM_BACKEND_HERDR_JOURNAL_PANE_ID")" = present ]; then
      printf '%s' "$FM_BACKEND_HERDR_JOURNAL_PANE_ID"
      return 0
    fi
  done
  return 1
}

# fm_herdr_husk_cwd_protected: <cwd> is inside a treehouse pool slot that a
# live record or a slot claim names. Prints the protecting fact.
# A pool slot is <pool>/<n>/<checkout> with <pool>/treehouse-state.json beside
# the numbered directories and the claim at <pool>/<n>/.fm-slot-owner
# (bin/fm-wake-lib.sh owns the claim).
fm_herdr_husk_cwd_protected() {  # <cwd>
  local cwd=$1 real dir meta worktree worktree_real ancestor slot pool
  real=$(fm_herdr_husk_real_path "$cwd") || return 1
  for dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for meta in "$dir"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      worktree=$(fm_meta_get "$meta" worktree)
      [ -n "$worktree" ] || continue
      worktree_real=$(fm_herdr_husk_real_path "$worktree") || continue
      case "$real" in
        "$worktree_real"|"$worktree_real"/*)
          printf 'the recorded worktree of task %s' "$(basename "$meta" .meta)"
          return 0
          ;;
      esac
    done
  done
  ancestor=$real
  while [ -n "$ancestor" ] && [ "$ancestor" != / ]; do
    slot=$(dirname "$ancestor")
    pool=$(dirname "$slot")
    if [ -f "$pool/treehouse-state.json" ] && [ ! -L "$pool/treehouse-state.json" ] \
      && { [ -e "$slot/.fm-slot-owner" ] || [ -L "$slot/.fm-slot-owner" ]; }; then
      printf 'claimed pool slot %s' "$slot"
      return 0
    fi
    ancestor=$slot
  done
  return 1
}

# fm_herdr_husk_retire_journals: after <pane> is confirmed gone, remove every
# local journal for <id> that bound exactly that pane, or a version 1 journal
# whose token no workspace label in <session> still carries.
fm_herdr_husk_retire_journals() {  # <session> <id> <pane>
  local session=$1 id=$2 pane=$3 dir journal labels token
  labels=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null | jq -r '.result.workspaces[]?.label // empty' 2>/dev/null) || labels=
  for dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    journal="$dir/$id$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"
    [ -f "$journal" ] && [ ! -L "$journal" ] || continue
    [ ! -e "$dir/$id.meta" ] && [ ! -L "$dir/$id.meta" ] || continue
    fm_backend_herdr_projection_journal_snapshot "$journal" "$id" || continue
    case "$FM_BACKEND_HERDR_JOURNAL_VERSION" in
      2)
        [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" = "$session" ] \
          && [ "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" = "$pane" ] || continue
        ;;
      1)
        token=$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID
        case "$labels" in *"p:$token"*) continue ;; esac
        ;;
      *) continue ;;
    esac
    rm -f -- "$journal" 2>/dev/null \
      || fm_herdr_husk_warn "$id: pane closed but its journal $journal could not be retired"
  done
}

fm_herdr_husk_one() {  # <session> <state-dir> <id> <label> <tab> <pane> <pane-count> <cwd>
  local session=$1 state=$2 id=$3 label=$4 tab=$5 pane=$6 pane_count=$7 cwd=$8
  local other protect shell_pid task_lock presentation_lock target="$session:${pane:--}"
  if other=$(fm_herdr_husk_journal_names_other_live_pane "$session" "$id" "$pane"); then
    printf 'kept\t%s\t%s\tits presentation journal names live pane %s\n' "$label" "$target" "$other"
    return 0
  fi
  if [ "$pane_count" != 1 ] || [ -z "$pane" ]; then
    printf 'kept\t%s\t%s\tthe tab holds %s panes rather than one\n' "$label" "$target" "${pane_count:-0}"
    return 0
  fi
  case "$(fm_backend_herdr_pane_agent_state "$session" "$pane")" in
    no-agent) ;;
    dead)
      printf 'kept\t%s\t%s\tits pane is already gone\n' "$label" "$target"
      return 0
      ;;
    *)
      printf 'kept\t%s\t%s\tits pane is not agent-free\n' "$label" "$target"
      return 0
      ;;
  esac
  shell_pid=$(fm_backend_herdr_pane_idle_shell_pid "$session" "$pane") || {
    printf 'kept\t%s\t%s\tits pane is not a lone idle shell\n' "$label" "$target"
    return 0
  }
  if protect=$(fm_herdr_husk_cwd_protected "$cwd"); then
    printf 'kept\t%s\t%s\tits shell sits in %s\n' "$label" "$target" "$protect"
    return 0
  fi
  if ! fm_backend_herdr_projection_target_tab_mutation_allowed "$session" "$tab" 2>/dev/null; then
    printf "kept\t%s\t%s\tit is the captain's active tab\n" "$label" "$target"
    return 0
  fi
  task_lock="$state/.spawn-$id.lock"
  if ! fm_lock_try_acquire "$task_lock"; then
    printf 'kept\t%s\t%s\tits task lock is busy\n' "$label" "$target"
    return 0
  fi
  presentation_lock=$(fm_backend_herdr_presentation_session_lock_path "$session" 2>/dev/null) || {
    fm_lock_release "$task_lock" || true
    printf 'kept\t%s\t%s\tthe session presentation lock is unavailable\n' "$label" "$target"
    return 0
  }
  if ! fm_lock_try_acquire "$presentation_lock"; then
    fm_lock_release "$task_lock" || true
    printf 'kept\t%s\t%s\tthe session presentation lock is busy\n' "$label" "$target"
    return 0
  fi
  if fm_herdr_husk_meta_present "$id"; then
    printf 'kept\t%s\t%s\ta task record appeared under the locks\n' "$label" "$target"
  elif ! fm_backend_herdr_projection_target_tab_mutation_allowed "$session" "$tab" 2>/dev/null; then
    printf "kept\t%s\t%s\tit is the captain's active tab\n" "$label" "$target"
  elif fm_backend_herdr_close_idle_endpoint "$session" "$pane" "$shell_pid"; then
    fm_herdr_husk_retire_journals "$session" "$id" "$pane"
    printf 'closed\t%s\t%s\n' "$label" "$target"
  else
    printf 'kept\t%s\t%s\t%s\n' "$label" "$target" "${FM_BACKEND_HERDR_CLOSE_IDLE_REASON:-the close was refused}"
  fi
  fm_lock_release "$presentation_lock" || true
  fm_lock_release "$task_lock" || true
  return 0
}

fm_herdr_husk_sweep() {  # <session> <state-dir>
  local session=$1 state=$2 tabs panes records label tab _workspace id pane pane_count cwd pane_record
  command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  [ "$(fm_backend_herdr_server_running_state "$session")" = running ] || return 0
  tabs=$(fm_backend_herdr_cli "$session" tab list 2>/dev/null) || {
    fm_herdr_husk_warn "session '$session' tab listing failed; keeping every tab"
    return 0
  }
  records=$(printf '%s' "$tabs" | jq -er '
    .result.tabs
    | select(type == "array")
    | .[]
    | select((.tab_id | type) == "string" and (.tab_id | length) > 0)
    | select((.label | type) == "string" and (.label | length) > 0)
    | [.tab_id, (.workspace_id // ""), .label] | @tsv
  ' 2>/dev/null) || {
    fm_herdr_husk_warn "session '$session' tab listing was unreadable; keeping every tab"
    return 0
  }
  [ -n "$records" ] || return 0
  panes=$(fm_backend_herdr_cli "$session" pane list 2>/dev/null) || {
    fm_herdr_husk_warn "session '$session' pane listing failed; keeping every tab"
    return 0
  }
  printf '%s' "$panes" | jq -e '(.result.panes | type) == "array"' >/dev/null 2>&1 || {
    fm_herdr_husk_warn "session '$session' pane listing was unreadable; keeping every tab"
    return 0
  }
  if ! fm_local_firstmate_state_dirs "$state"; then
    fm_herdr_husk_warn "${FM_LOCAL_FIRSTMATE_ERROR:-local Firstmate homes could not be proved}; keeping every tab"
    return 0
  fi
  while IFS=$'\t' read -r tab _workspace label; do
    [ -n "$tab" ] && [ -n "$label" ] || continue
    id=$(fm_herdr_husk_task_id "$label") || continue
    fm_herdr_husk_meta_present "$id" && continue
    pane_record=$(printf '%s' "$panes" | jq -r --arg tab "$tab" '
      [.result.panes[] | select(.tab_id == $tab)] as $p
      | [($p | length | tostring), ($p[0].pane_id // ""), ($p[0].foreground_cwd // $p[0].cwd // "")] | @tsv
    ' 2>/dev/null) || pane_record=$'0\t\t'
    IFS=$'\t' read -r pane_count pane cwd <<EOF
$pane_record
EOF
    fm_herdr_husk_one "$session" "$state" "$id" "$label" "$tab" "$pane" "$pane_count" "$cwd"
  done <<EOF
$records
EOF
  return 0
}
