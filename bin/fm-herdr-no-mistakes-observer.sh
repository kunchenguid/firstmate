#!/usr/bin/env bash
# fm-herdr-no-mistakes-observer.sh - own the optional Herdr validation viewer.
#
# Usage: fm-herdr-no-mistakes-observer.sh reconcile <task-id>
#
# This is deliberately a visual-only lifecycle.  It never invokes a pipeline
# command other than the read-only `no-mistakes axi status`, and it never makes
# a sidecar authoritative for a task endpoint, recovery, or delivery.
#
# With local config/herdr-no-mistakes-observer-panes present, reconcile creates
# one unfocused right split beside an ordinary Herdr ship task whose own branch
# has a non-terminal no-mistakes run.  The private sidecar is the exact binding
# required to reuse or close that split.  Any malformed, stale, or conflicting
# sidecar is quarantined in place: it never licenses a duplicate viewer or a
# close.  Normal task teardown calls `retire`, so an exact viewer is retired
# before the task pane is removed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
NM_TIMEOUT=${FM_HERDR_NM_OBSERVER_TIMEOUT:-10}
FM_HERDR_NM_OBSERVER_CONFIG="herdr-no-mistakes-observer-panes"
FM_HERDR_NM_OBSERVER_SUFFIX=".herdr-no-mistakes-observer"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
fm_backend_source herdr

warn() { printf 'warning: herdr no-mistakes observer: %s\n' "$*" >&2; }

usage() { echo "usage: fm-herdr-no-mistakes-observer.sh reconcile|retire <task-id>" >&2; }

meta_exact() { fm_backend_meta_exact_value "$1" "$2"; }

observer_enabled() {
  [ -f "$CONFIG/$FM_HERDR_NM_OBSERVER_CONFIG" ] && [ ! -L "$CONFIG/$FM_HERDR_NM_OBSERVER_CONFIG" ]
}

# Parse exactly one version-1 sidecar.  Values are held in OBS_* globals.
sidecar_snapshot_for_state() { # <path> <task-id> <state>
  local path=$1 id=$2 expected_state=$3 version state attach_state task_id run_id session task_pane observer_pane worktree
  OBS_ATTACH_STATE='' OBS_RUN_ID='' OBS_SESSION='' OBS_TASK_PANE='' OBS_PANE='' OBS_WORKTREE=''
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  version=$(meta_exact "$path" version) || return 1
  state=$(meta_exact "$path" state) || return 1
  attach_state=$(meta_exact "$path" attach_state) || return 1
  task_id=$(meta_exact "$path" task_id) || return 1
  run_id=$(meta_exact "$path" run_id) || return 1
  session=$(meta_exact "$path" session) || return 1
  task_pane=$(meta_exact "$path" task_pane) || return 1
  observer_pane=$(meta_exact "$path" observer_pane) || return 1
  worktree=$(meta_exact "$path" worktree) || return 1
  [ "$version" = 1 ] && [ "$state" = "$expected_state" ] && [ "$task_id" = "$id" ] || return 1
  case "$state:$attach_state" in bound:pending|bound:ready|quarantined:quarantined) ;; *) return 1 ;; esac
  case "$run_id$session$task_pane$observer_pane" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  [ "$task_pane" != "$observer_pane" ] || return 1
  [ -d "$worktree" ] && [ ! -L "$worktree" ] || return 1
  OBS_ATTACH_STATE=$attach_state OBS_RUN_ID=$run_id OBS_SESSION=$session OBS_TASK_PANE=$task_pane
  OBS_PANE=$observer_pane OBS_WORKTREE=$(cd "$worktree" && pwd -P)
}

sidecar_snapshot() { sidecar_snapshot_for_state "$1" "$2" bound; }

sidecar_reservation_snapshot() { sidecar_snapshot_for_state "$1" "$2" quarantined; }

# Confirm current Herdr identities, including the exact task pane's tab/workspace.
task_binding() { # <meta> <id>
  local meta=$1 id=$2 kind session task_pane workspace tab worktree pane_json
  TASK_SESSION='' TASK_PANE='' TASK_WORKSPACE='' TASK_TAB='' TASK_WORKTREE=''
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 || return 1
  [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] || return 1
  kind=$(meta_exact "$meta" kind) || return 1
  [ "$kind" = ship ] || return 1
  session=$(meta_exact "$meta" herdr_session) || return 1
  task_pane=$(meta_exact "$meta" herdr_pane_id) || return 1
  workspace=$(meta_exact "$meta" herdr_workspace_id) || return 1
  tab=$(meta_exact "$meta" herdr_tab_id) || return 1
  worktree=$(meta_exact "$meta" worktree) || return 1
  [ "$FM_BACKEND_VALIDATED_TARGET" = "$session:$task_pane" ] || return 1
  [ -d "$worktree" ] && [ ! -L "$worktree" ] || return 1
  worktree=$(cd "$worktree" && pwd -P) || return 1
  pane_json=$(fm_backend_herdr_cli "$session" pane get "$task_pane" 2>/dev/null) || return 1
  printf '%s' "$pane_json" | jq -e --arg pane "$task_pane" --arg workspace "$workspace" --arg tab "$tab" '
    .result.pane.pane_id == $pane
    and .result.pane.workspace_id == $workspace
    and .result.pane.tab_id == $tab
  ' >/dev/null 2>&1 || return 1
  TASK_SESSION=$session TASK_PANE=$task_pane TASK_WORKSPACE=$workspace TASK_TAB=$tab TASK_WORKTREE=$worktree
}

# Bind the current run to a worktree by its branch and code identity.  This is
# read-only. MATCH_RUN_ACTIVE distinguishes a live validation from a terminal
# result so terminal cleanup can still prove that its sidecar belongs to this
# task rather than an old run on a reused branch.
matching_run() { # <worktree>
  local wt=$1 out branch run_id run_branch run_head outcome status
  MATCH_RUN_ID='' MATCH_RUN_ACTIVE=0
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  out=$(fm_nm_run "$wt" "$NM_TIMEOUT" axi status)
  [ -n "$out" ] || return 1
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  [ -n "$run_id" ] && [ "$run_branch" = "$branch" ] || return 1
  fm_nm_head_matches_worktree "$wt" "$run_head" || return 1
  MATCH_RUN_ID=$run_id
  if [ -n "$outcome" ]; then
    case "$outcome" in passed|checks-passed|failed|cancelled) return 0 ;; *) return 1 ;; esac
  fi
  case "$status" in
    completed|failed|cancelled) return 0 ;;
    ci|running|fixing|awaiting_approval|fix_review) MATCH_RUN_ACTIVE=1 ;;
    *) return 1 ;;
  esac
}

active_run() { # <worktree>
  ACTIVE_RUN_ID=
  matching_run "$1" || return 1
  [ "$MATCH_RUN_ACTIVE" = 1 ] || return 1
  ACTIVE_RUN_ID=$MATCH_RUN_ID
}

observer_pane_matches() { # <session> <observer-pane> <workspace> <tab>
  local session=$1 pane=$2 workspace=$3 tab=$4 out
  out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e --arg pane "$pane" --arg workspace "$workspace" --arg tab "$tab" '
    .result.pane.pane_id == $pane
    and .result.pane.workspace_id == $workspace
    and .result.pane.tab_id == $tab
  ' >/dev/null 2>&1
}

# A split can share the task tab, so tab focus is not captain-pane authority.
# Closing the observer is safe only when this exact pane response says it is not
# focused.  The task pane is separately bound and must always differ.
observer_close_safe() { # <session> <observer-pane> <task-pane>
  local session=$1 pane=$2 task_pane=$3 out
  [ "$pane" != "$task_pane" ] || return 1
  out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e --arg pane "$pane" '
    .result.pane.pane_id == $pane
    and .result.pane.focused != true
  ' >/dev/null 2>&1
}

sidecar_publish() { # <path> <task-id> <run-id> <session> <task-pane> <observer-pane> <worktree> <state> <attach-state> <replace-state>
  local path=$1 id=$2 run_id=$3 session=$4 task_pane=$5 observer_pane=$6 worktree=$7 state=$8 attach_state=$9 replace_state=${10} tmp
  case "$state:$attach_state:$replace_state" in
    bound:pending:reservation|bound:ready:bound|quarantined:quarantined:absent) ;;
    *) return 1 ;;
  esac
  tmp=$(umask 077; mktemp "$STATE/.${id}.herdr-no-mistakes-observer.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! {
    printf 'version=1\n'
    printf 'state=%s\n' "$state"
    printf 'attach_state=%s\n' "$attach_state"
    printf 'task_id=%s\n' "$id"
    printf 'run_id=%s\n' "$run_id"
    printf 'session=%s\n' "$session"
    printf 'task_pane=%s\n' "$task_pane"
    printf 'observer_pane=%s\n' "$observer_pane"
    printf 'worktree=%s\n' "$worktree"
  } > "$tmp"; then rm -f -- "$tmp"; return 1; fi
  case "$replace_state" in
    absent) [ ! -e "$path" ] && [ ! -L "$path" ] || { rm -f -- "$tmp"; return 1; } ;;
    reservation) sidecar_reservation_snapshot "$path" "$id" || { rm -f -- "$tmp"; return 1; } ;;
    bound) sidecar_snapshot "$path" "$id" || { rm -f -- "$tmp"; return 1; } ;;
  esac
  mv -f -- "$tmp" "$path"
}

sidecar_reserve() { # <path> <task-id> <run-id> <session> <task-pane> <worktree>
  sidecar_publish "$1" "$2" "$3" "$4" "$5" unresolved "$6" quarantined quarantined absent
}

sidecar_bind_reservation() { # <path> <task-id> <run-id> <session> <task-pane> <observer-pane> <worktree>
  local path=$1 id=$2 run_id=$3 session=$4 task_pane=$5 observer_pane=$6 worktree=$7
  sidecar_reservation_snapshot "$path" "$id" \
    && [ "$OBS_RUN_ID" = "$run_id" ] \
    && [ "$OBS_SESSION" = "$session" ] \
    && [ "$OBS_TASK_PANE" = "$task_pane" ] \
    && [ "$OBS_WORKTREE" = "$worktree" ] \
    || return 1
  sidecar_publish "$path" "$id" "$run_id" "$session" "$task_pane" "$observer_pane" "$worktree" bound pending reservation
}

sidecar_mark_ready() { # <path> <task-id> <run-id> <session> <task-pane> <observer-pane> <worktree>
  local path=$1 id=$2 run_id=$3 session=$4 task_pane=$5 observer_pane=$6 worktree=$7
  sidecar_snapshot "$path" "$id" \
    && [ "$OBS_ATTACH_STATE" = pending ] \
    && [ "$OBS_RUN_ID" = "$run_id" ] \
    && [ "$OBS_SESSION" = "$session" ] \
    && [ "$OBS_TASK_PANE" = "$task_pane" ] \
    && [ "$OBS_PANE" = "$observer_pane" ] \
    && [ "$OBS_WORKTREE" = "$worktree" ] \
    || return 1
  sidecar_publish "$path" "$id" "$run_id" "$session" "$task_pane" "$observer_pane" "$worktree" bound ready bound
}

observer_attach() { # <sidecar> <task-id>
  local sidecar=$1 id=$2
  sidecar_snapshot "$sidecar" "$id" && [ "$OBS_ATTACH_STATE" = pending ] || return 1
  if fm_backend_herdr_cli "$OBS_SESSION" pane run "$OBS_PANE" no-mistakes attach --run "$OBS_RUN_ID" >/dev/null 2>&1; then
    sidecar_mark_ready "$sidecar" "$id" "$OBS_RUN_ID" "$OBS_SESSION" "$OBS_TASK_PANE" "$OBS_PANE" "$OBS_WORKTREE" \
      || warn "$id observer attach started but its ready state could not be recorded"
  else
    warn "$id observer attach command could not start; retaining its exact sidecar for retry"
  fi
}

retire_exact() { # <sidecar> <task-id> [<metadata-present>]
  local sidecar=$1 id=$2 meta_present=${3:-0} session pane task_pane
  sidecar_snapshot "$sidecar" "$id" || { warn "$id sidecar is unreadable; preserving it"; return 0; }
  session=$OBS_SESSION pane=$OBS_PANE task_pane=$OBS_TASK_PANE
  if [ "$meta_present" = 1 ]; then
    task_binding "$STATE/$id.meta" "$id" || { warn "$id sidecar does not agree with current task metadata; preserving it"; return 0; }
    [ "$TASK_SESSION" = "$session" ] && [ "$TASK_PANE" = "$task_pane" ] && [ "$TASK_WORKTREE" = "$OBS_WORKTREE" ] || {
      warn "$id sidecar conflicts with current task binding; preserving it"; return 0;
    }
    matching_run "$TASK_WORKTREE" && [ "$MATCH_RUN_ID" = "$OBS_RUN_ID" ] || {
      warn "$id sidecar run binding is stale or unreadable; preserving it"; return 0;
    }
  elif [ "$(fm_backend_herdr_pane_presence_state "$session" "$task_pane")" != dead ]; then
    warn "$id task metadata is absent while its task pane remains live or unreadable; preserving sidecar"
    return 0
  fi
  [ "$pane" != "$task_pane" ] || { warn "$id sidecar names the task pane as observer; preserving it"; return 0; }
  observer_pane_matches "$session" "$pane" "${TASK_WORKSPACE:-$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')}" "${TASK_TAB:-$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null | jq -r '.result.pane.tab_id // empty')}" || {
    # A stale/missing observer is not a closure authority.  Retire only a
    # sidecar whose exact pane is positively gone, never an unreadable one.
    [ "$(fm_backend_herdr_pane_presence_state "$session" "$pane")" = dead ] || { warn "$id observer pane is unreadable or mismatched; preserving sidecar"; return 0; }
  }
  if [ "$(fm_backend_herdr_pane_presence_state "$session" "$pane")" = dead ]; then
    sidecar_snapshot "$sidecar" "$id" && rm -f -- "$sidecar"
    return 0
  fi
  observer_close_safe "$session" "$pane" "$task_pane" || {
    warn "$id observer is the captain pane or has an ambiguous identity; preserving sidecar"; return 0;
  }
  fm_backend_herdr_explicit_close_pane_confirmed "$session" "$pane" || {
    warn "$id observer close was refused or unconfirmed; preserving sidecar"; return 0;
  }
  [ "$(fm_backend_herdr_pane_presence_state "$session" "$pane")" = dead ] || { warn "$id observer close was not confirmed; preserving sidecar"; return 0; }
  sidecar_snapshot "$sidecar" "$id" && rm -f -- "$sidecar"
}

retire() { # <task-id> [<held-task-lock-pid> <held-task-lock-identity>]
  local id=$1 sidecar="$STATE/$1$FM_HERDR_NM_OBSERVER_SUFFIX" task_lock session_lock meta_present=0 lock_pid=${2:-} lock_identity=${3:-} acquired_task_lock=0
  fm_task_id_creation_valid "$id" || return 0
  [ -f "$sidecar" ] && [ ! -L "$sidecar" ] || return 0
  sidecar_snapshot "$sidecar" "$id" || { warn "$id sidecar is unreadable; preserving it"; return 0; }
  task_lock="$STATE/.spawn-$id.lock"
  if [ -n "$lock_pid$lock_identity" ]; then
    case "$lock_pid" in ''|*[!0-9]*) return 0 ;; esac
    [ -n "$lock_identity" ] \
      && [ "$(cat "$task_lock/pid" 2>/dev/null || true)" = "$lock_pid" ] \
      && [ "$(cat "$task_lock/pid-identity" 2>/dev/null || true)" = "$lock_identity" ] \
      && [ "$(fm_pid_identity "$lock_pid" 2>/dev/null || true)" = "$lock_identity" ] \
      || return 0
  else
    fm_lock_try_acquire "$task_lock" || return 0
    acquired_task_lock=1
  fi
  session_lock=$(fm_backend_herdr_presentation_session_lock_path "$OBS_SESSION" 2>/dev/null) || {
    [ "$acquired_task_lock" = 1 ] && fm_lock_release "$task_lock" || true; return 0;
  }
  if ! fm_lock_try_acquire "$session_lock"; then
    [ "$acquired_task_lock" = 1 ] && fm_lock_release "$task_lock" || true
    return 0
  fi
  [ -f "$STATE/$id.meta" ] && meta_present=1
  retire_exact "$sidecar" "$id" "$meta_present"
  fm_lock_release "$session_lock" || true
  [ "$acquired_task_lock" = 1 ] && fm_lock_release "$task_lock" || true
}

reconcile() { # <task-id>
  local id=$1 meta="$STATE/$1.meta" sidecar="$STATE/$1$FM_HERDR_NM_OBSERVER_SUFFIX" task_lock session_lock split observer
  fm_task_id_creation_valid "$id" || return 0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  # A disabled home has no observer lifecycle unless it already owns a sidecar
  # that needs conservative retirement.
  { [ -e "$sidecar" ] || [ -L "$sidecar" ]; } || observer_enabled || return 0
  task_lock="$STATE/.spawn-$id.lock"
  fm_lock_try_acquire "$task_lock" || return 0
  trap 'fm_lock_release "$task_lock" >/dev/null 2>&1 || true' RETURN

  if ! task_binding "$meta" "$id"; then
    # Metadata disappearance may be part of normal cleanup.  The sidecar alone
    # is enough to identify its observer, but never to close a malformed one.
    [ -e "$sidecar" ] || [ -L "$sidecar" ] || return 0
    if [ -e "$meta" ] || [ -L "$meta" ]; then
      warn "$id task metadata is unreadable or conflicting; preserving sidecar"
      return 0
    fi
    sidecar_snapshot "$sidecar" "$id" || { warn "$id sidecar is unreadable; preserving it"; return 0; }
    session_lock=$(fm_backend_herdr_presentation_session_lock_path "$OBS_SESSION" 2>/dev/null) || return 0
    fm_lock_try_acquire "$session_lock" || return 0
    retire_exact "$sidecar" "$id" 0
    fm_lock_release "$session_lock" || true
    return 0
  fi

  session_lock=$(fm_backend_herdr_presentation_session_lock_path "$TASK_SESSION" 2>/dev/null) || return 0
  fm_lock_try_acquire "$session_lock" || return 0
  if ! active_run "$TASK_WORKTREE"; then
    if [ -e "$sidecar" ] || [ -L "$sidecar" ]; then retire_exact "$sidecar" "$id" 1; fi
    fm_lock_release "$session_lock" || true
    return 0
  fi

  if [ -e "$sidecar" ] || [ -L "$sidecar" ]; then
    if sidecar_snapshot "$sidecar" "$id" \
      && [ "$OBS_RUN_ID" = "$ACTIVE_RUN_ID" ] \
      && [ "$OBS_SESSION" = "$TASK_SESSION" ] \
      && [ "$OBS_TASK_PANE" = "$TASK_PANE" ] \
      && [ "$OBS_WORKTREE" = "$TASK_WORKTREE" ] \
      && observer_pane_matches "$OBS_SESSION" "$OBS_PANE" "$TASK_WORKSPACE" "$TASK_TAB"; then
      [ "$OBS_ATTACH_STATE" = ready ] || observer_attach "$sidecar" "$id"
      fm_lock_release "$session_lock" || true
      return 0
    fi
    warn "$id observer sidecar is stale or conflicting; refusing a duplicate viewer"
    fm_lock_release "$session_lock" || true
    return 0
  fi
  observer_enabled || { fm_lock_release "$session_lock" || true; return 0; }

  sidecar_reserve "$sidecar" "$id" "$ACTIVE_RUN_ID" "$TASK_SESSION" "$TASK_PANE" "$TASK_WORKTREE" || {
    warn "$id observer reservation could not be published; refusing a split"; fm_lock_release "$session_lock" || true; return 0;
  }

  split=$(fm_backend_herdr_cli "$TASK_SESSION" pane split "$TASK_PANE" --direction right --ratio 0.30 --cwd "$TASK_WORKTREE" --no-focus 2>/dev/null) || {
    warn "$id split failed; preserving its quarantine reservation"; fm_lock_release "$session_lock" || true; return 0;
  }
  observer=$(printf '%s' "$split" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  if ! { [ -n "$observer" ] && [ "$observer" != "$TASK_PANE" ] \
    && observer_pane_matches "$TASK_SESSION" "$observer" "$TASK_WORKSPACE" "$TASK_TAB"; }; then
    warn "$id split response was ambiguous; preserving its quarantine reservation"
    fm_lock_release "$session_lock" || true
    return 0
  fi
  sidecar_bind_reservation "$sidecar" "$id" "$ACTIVE_RUN_ID" "$TASK_SESSION" "$TASK_PANE" "$observer" "$TASK_WORKTREE" || {
    warn "$id observer sidecar could not be bound; preserving its quarantine reservation"; fm_lock_release "$session_lock" || true; return 0;
  }
  observer_attach "$sidecar" "$id"
  fm_lock_release "$session_lock" || true
}

case "${1:-}" in
  reconcile) [ -n "${2:-}" ] || { usage; exit 2; }; reconcile "$2" ;;
  retire)    [ -n "${2:-}" ] || { usage; exit 2; }; retire "$2" ;;
  retire-locked) [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || { usage; exit 2; }; retire "$2" "$3" "$4" ;;
  *) usage; exit 2 ;;
esac
