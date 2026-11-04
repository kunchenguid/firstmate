#!/usr/bin/env bash
# Retire leftover restored-shell Herdr task workspaces at locked session start.
#
# Usage: fm-herdr-session-cleanup.sh
#
# The caller must already own this Firstmate home's session lock. This script
# considers only the current named Herdr session.
# docs/herdr-backend.md "Leftover task workspaces" owns the contract, and
# bin/backends/herdr.sh's leftover helpers own the shared topology, agent,
# process, recheck, and exact-pane close proof.
#
# A visible title is discovery only. Every candidate must carry the exact
# current "└ <concise-task> · p:<22-char-token>" grammar and then takes one of
# two record paths:
# - Journal-correlated: exactly one home-local state/*.herdr-presentation
#   journal in the effective FM_HOME derives the title, and a version 2 journal
#   also binds the exact workspace, tab, and pane. The task's metadata must be
#   absent. The candidate is serialized by the existing state/.spawn-<task>.lock
#   and then the shared named-session presentation lock, and the matching
#   journal is removed only after the exact pane is confirmed gone.
# - Unjournaled: only when this home's resolved backend is herdr and no journal
#   matched. No journal or task record in any local Firstmate home
#   (fm_local_firstmate_state_dirs) may claim it, and that claim check repeats
#   under the shared named-session presentation lock right before mutation.
#   That locked recheck also requires ownership proof: every cwd Herdr reports
#   for the pane resolves inside a local home's own directory or inside a git
#   worktree listed by that home or by a project clone under its projects/.
#   A pane with no such proof may belong to another Firstmate home sharing the
#   named session, so it is preserved with a warning.
# Both paths then require one tab, one pane, no registered agent, and a process
# proof that the pane holds only one idle recognized shell with no child
# process, and both close only that exact pane through the focus-preserving
# helper. The script never calls `workspace close`, never touches a worktree,
# branch, or task record, and never removes another home's journal. Every error
# warns and returns success so session startup continues conservatively.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

FM_HERDR_CLEANUP_UNJOURNALED=0
FM_HERDR_CLEANUP_OWNED_ROOTS=()

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

fm_herdr_cleanup_journal_matches() { # <title> <session> <home-real>
  local title=$1 session=$2 home_real=$3 journal id expected journal_home
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

# fm_herdr_cleanup_journal_unchanged: the journal path's record recheck. The
# task's metadata is still absent and the same one journal still matches with
# the same token, version, and binding captured before the snapshot.
fm_herdr_cleanup_journal_unchanged() {
  [ ! -e "$STATE/$FM_HERDR_CLEANUP_EXPECT_ID.meta" ] \
    && [ ! -L "$STATE/$FM_HERDR_CLEANUP_EXPECT_ID.meta" ] || return 1
  fm_herdr_cleanup_unique_match \
    "$FM_HERDR_CLEANUP_EXPECT_TITLE" "$FM_HERDR_CLEANUP_EXPECT_SESSION" "$FM_HERDR_CLEANUP_EXPECT_HOME" || return 1
  [ "$FM_HERDR_CLEANUP_JOURNAL" = "$FM_HERDR_CLEANUP_EXPECT_JOURNAL" ] \
    && [ "$FM_HERDR_CLEANUP_ID" = "$FM_HERDR_CLEANUP_EXPECT_ID" ] \
    && [ "$FM_HERDR_CLEANUP_TOKEN" = "$FM_HERDR_CLEANUP_EXPECT_TOKEN" ] \
    && [ "$FM_HERDR_CLEANUP_VERSION" = "$FM_HERDR_CLEANUP_EXPECT_VERSION" ] \
    && [ "$FM_HERDR_CLEANUP_BOUND_WORKSPACE" = "$FM_HERDR_CLEANUP_EXPECT_BOUND_WORKSPACE" ] \
    && [ "$FM_HERDR_CLEANUP_BOUND_TAB" = "$FM_HERDR_CLEANUP_EXPECT_BOUND_TAB" ] \
    && [ "$FM_HERDR_CLEANUP_BOUND_PANE" = "$FM_HERDR_CLEANUP_EXPECT_BOUND_PANE" ]
}

# fm_herdr_cleanup_retire_warn <label> <retire-status>: the one warning for a
# leftover the shared retirement helper preserved.
fm_herdr_cleanup_retire_warn() { # <label> <status>
  case "$2" in
    2) fm_herdr_cleanup_warn "$1 preserved because its locked candidate snapshot was ambiguous" ;;
    3) fm_herdr_cleanup_warn "$1 preserved because its pane is not a provably idle childless shell" ;;
    4) fm_herdr_cleanup_warn "$1 preserved because immediate revalidation changed or was unreadable" ;;
    5) fm_herdr_cleanup_warn "$1 preserved because exact focus-safe pane closure was refused or unconfirmed" ;;
    *) fm_herdr_cleanup_warn "$1 preserved because exact pane closure could not be confirmed" ;;
  esac
}

fm_herdr_cleanup_one() { # <session> <workspace> <title> <home-real>
  local session=$1 workspace=$2 title=$3 home_real=$4 token journal id task_lock
  local version bound_workspace bound_tab bound_pane presentation_lock status=0
  token=$(fm_herdr_cleanup_title_token "$title") || return 0
  if ! fm_herdr_cleanup_unique_match "$title" "$session" "$home_real"; then
    [ "$FM_HERDR_CLEANUP_UNJOURNALED" != 1 ] \
      || fm_herdr_cleanup_unjournaled_one "$session" "$workspace" "$title" "$token"
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
  FM_HERDR_CLEANUP_EXPECT_TITLE=$title
  FM_HERDR_CLEANUP_EXPECT_SESSION=$session
  FM_HERDR_CLEANUP_EXPECT_HOME=$home_real
  FM_HERDR_CLEANUP_EXPECT_JOURNAL=$journal
  FM_HERDR_CLEANUP_EXPECT_ID=$id
  FM_HERDR_CLEANUP_EXPECT_TOKEN=$token
  FM_HERDR_CLEANUP_EXPECT_VERSION=$version
  FM_HERDR_CLEANUP_EXPECT_BOUND_WORKSPACE=$bound_workspace
  FM_HERDR_CLEANUP_EXPECT_BOUND_TAB=$bound_tab
  FM_HERDR_CLEANUP_EXPECT_BOUND_PANE=$bound_pane
  if [ -n "$bound_workspace" ] && [ "$bound_workspace" != "$workspace" ]; then
    status=2
  else
    # This unconditional retirement is the authorized containment documented
    # with the presentation floor ownership in bin/backends/herdr.sh.
    fm_backend_herdr_projection_retire_leftover \
      "$session" "$workspace" "$title" "$token" "$bound_tab" "$bound_pane" \
      fm_herdr_cleanup_journal_unchanged || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    if [ -f "$journal" ] && [ ! -L "$journal" ] \
      && fm_herdr_cleanup_journal_unchanged; then
      rm -f -- "$journal" || fm_herdr_cleanup_warn "$id pane closed but its journal could not be retired"
    else
      fm_herdr_cleanup_warn "$id pane closed but its journal changed and was preserved"
    fi
  else
    fm_herdr_cleanup_retire_warn "$id" "$status"
  fi
  fm_lock_release "$presentation_lock" || true
  fm_lock_release "$task_lock" || true
  return 0
}

# fm_herdr_cleanup_owned_roots_load: set FM_HERDR_CLEANUP_OWNED_ROOTS to the
# real path of every local home in FM_LOCAL_FIRSTMATE_STATES and of every git
# worktree listed by that home or by a project clone under its projects/. A
# directory whose git top level is not itself lists nothing, so an enclosing
# unrelated repository never widens the set.
fm_herdr_cleanup_owned_roots_load() {
  local state home repo top listed line root
  FM_HERDR_CLEANUP_OWNED_ROOTS=()
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    home=$(CDPATH='' cd -- "$(dirname "$state")" 2>/dev/null && pwd -P) || continue
    FM_HERDR_CLEANUP_OWNED_ROOTS+=("$home")
    for repo in "$home" "$home"/projects/*/; do
      repo=$(CDPATH='' cd -- "$repo" 2>/dev/null && pwd -P) || continue
      top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || continue
      top=$(CDPATH='' cd -- "$top" 2>/dev/null && pwd -P) || continue
      [ "$top" = "$repo" ] || continue
      listed=$(git -C "$repo" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || continue
      while IFS= read -r line; do
        case "$line" in
          'worktree '*)
            root=$(CDPATH='' cd -- "${line#worktree }" 2>/dev/null && pwd -P) || continue
            FM_HERDR_CLEANUP_OWNED_ROOTS+=("$root")
            ;;
        esac
      done <<< "$listed"
    done
  done
}

# fm_herdr_cleanup_pane_owned <session> <pane>: true only when Herdr reports at
# least one cwd for the exact pane and every reported cwd resolves inside one
# of FM_HERDR_CLEANUP_OWNED_ROOTS.
fm_herdr_cleanup_pane_owned() {
  local session=$1 pane=$2 info paths path real root owned
  [ "${#FM_HERDR_CLEANUP_OWNED_ROOTS[@]}" -gt 0 ] || return 1
  info=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  paths=$(printf '%s' "$info" | jq -er --arg pane "$pane" '
    .result.pane
    | select(.pane_id == $pane)
    | [.cwd, .foreground_cwd]
    | map(select(type == "string" and length > 0))
    | select(length > 0)
    | .[]
  ' 2>/dev/null) || return 1
  while IFS= read -r path; do
    real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || return 1
    owned=0
    for root in "${FM_HERDR_CLEANUP_OWNED_ROOTS[@]}"; do
      case "$real/" in
        "$root"/*) owned=1; break ;;
      esac
    done
    [ "$owned" -eq 1 ] || return 1
  done <<< "$paths"
}

# fm_herdr_cleanup_unjournaled_eligible: the unjournaled path's claim check,
# re-run under the presentation lock with the candidate's snapshot tab and
# pane, where it also requires the pane's ownership proof. The local home set
# is re-read so a home registered since discovery still counts as a claimant.
fm_herdr_cleanup_unjournaled_eligible() {
  if ! fm_local_firstmate_state_dirs "$STATE" \
    || ! fm_backend_herdr_projection_unclaimed \
      "$FM_HERDR_CLEANUP_UNJOURNALED_WORKSPACE" \
      "${FM_BACKEND_HERDR_LEFTOVER_TAB:-}" "${FM_BACKEND_HERDR_LEFTOVER_PANE:-}" \
      "$FM_HERDR_CLEANUP_UNJOURNALED_CONCISE" "$FM_HERDR_CLEANUP_UNJOURNALED_TOKEN" \
      '' '' "${FM_LOCAL_FIRSTMATE_STATES[@]}"; then
    FM_HERDR_CLEANUP_UNJOURNALED_CLAIMED=1
    return 1
  fi
  [ -n "${FM_BACKEND_HERDR_LEFTOVER_PANE:-}" ] || return 0
  if ! fm_herdr_cleanup_pane_owned \
    "$FM_HERDR_CLEANUP_UNJOURNALED_SESSION" "$FM_BACKEND_HERDR_LEFTOVER_PANE"; then
    FM_HERDR_CLEANUP_UNJOURNALED_UNOWNED=1
    return 1
  fi
}

fm_herdr_cleanup_unjournaled_one() { # <session> <workspace> <title> <token>
  local session=$1 workspace=$2 title=$3 token=$4 concise presentation_lock status=0
  concise=${title#'└ '}
  concise=${concise%" · p:$token"}
  FM_HERDR_CLEANUP_UNJOURNALED_SESSION=$session
  FM_HERDR_CLEANUP_UNJOURNALED_WORKSPACE=$workspace
  FM_HERDR_CLEANUP_UNJOURNALED_CONCISE=$concise
  FM_HERDR_CLEANUP_UNJOURNALED_TOKEN=$token
  FM_BACKEND_HERDR_LEFTOVER_TAB=
  FM_BACKEND_HERDR_LEFTOVER_PANE=
  FM_HERDR_CLEANUP_UNJOURNALED_CLAIMED=0
  FM_HERDR_CLEANUP_UNJOURNALED_UNOWNED=0
  # A claimed workspace belongs to live or journal-correlated work and is
  # skipped silently; only the locked recheck below can authorize mutation.
  fm_herdr_cleanup_unjournaled_eligible || return 0
  presentation_lock=$(fm_backend_herdr_presentation_session_lock_path "$session" 2>/dev/null) || {
    fm_herdr_cleanup_warn "leftover '$title' skipped because the shared presentation lock is unavailable"
    return 0
  }
  if ! fm_lock_try_acquire "$presentation_lock"; then
    fm_herdr_cleanup_warn "leftover '$title' skipped because the shared presentation lock is busy"
    return 0
  fi
  fm_backend_herdr_projection_retire_leftover \
    "$session" "$workspace" "$title" "$token" '' '' \
    fm_herdr_cleanup_unjournaled_eligible || status=$?
  if [ "$FM_HERDR_CLEANUP_UNJOURNALED_UNOWNED" = 1 ]; then
    fm_herdr_cleanup_warn "leftover '$title' preserved because its pane cwd is not proven to be inside a local Firstmate home or its worktrees"
  elif [ "$status" -ne 0 ] && [ "$FM_HERDR_CLEANUP_UNJOURNALED_CLAIMED" != 1 ]; then
    fm_herdr_cleanup_retire_warn "leftover '$title'" "$status"
  fi
  fm_lock_release "$presentation_lock" || true
  return 0
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
  FM_HERDR_CLEANUP_UNJOURNALED=0
  [ "$(fm_backend_name 2>/dev/null)" != herdr ] || FM_HERDR_CLEANUP_UNJOURNALED=1
  [ "$found" -eq 1 ] || [ "$FM_HERDR_CLEANUP_UNJOURNALED" -eq 1 ] || return 0
  command -v herdr >/dev/null 2>&1 \
    && command -v jq >/dev/null 2>&1 || return 0
  home_real=$(fm_herdr_cleanup_home_identity) || {
    fm_herdr_cleanup_warn 'home identity is unreadable; preserving every candidate'
    return 0
  }
  if [ "$FM_HERDR_CLEANUP_UNJOURNALED" -eq 1 ] && ! fm_local_firstmate_state_dirs "$STATE"; then
    fm_herdr_cleanup_warn "local Firstmate homes are unreadable (${FM_LOCAL_FIRSTMATE_ERROR:-unknown}); preserving every unjournaled leftover"
    FM_HERDR_CLEANUP_UNJOURNALED=0
    [ "$found" -eq 1 ] || return 0
  fi
  [ "$FM_HERDR_CLEANUP_UNJOURNALED" -ne 1 ] || fm_herdr_cleanup_owned_roots_load
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
