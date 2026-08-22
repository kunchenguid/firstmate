#!/usr/bin/env bash
# Add the missing endpoint_task_id binding to one pre-binding Herdr task record,
# but only after a positive, fail-closed identity proof. This command repairs
# metadata only: it never starts, stops, focuses, sends to, or closes Herdr, and
# it never retires the task. A later fm-teardown.sh invocation still owns every
# landed-work, captain-hold, report, and destructive-cleanup gate.
#
# Eligibility and proof:
#   * FM_HOME must be explicitly set; <task-id> must name one regular meta file.
#   * An existing exact binding is an idempotent no-op after the ordinary
#     endpoint validator accepts it. Empty, wrong, or duplicate bindings refuse.
#   * Only backend=herdr is recoverable. Every structured Herdr endpoint field
#     must be singular, internally consistent, and safe as an endpoint atom.
#   * The recorded worktree and project must be physical paths. The worktree
#     must be a distinct linked Git worktree registered exactly once by that
#     project, and both must resolve to the same Git common directory.
#   * No other regular state/*.meta may claim the same endpoint or canonical
#     worktree. Unsafe metadata inventory refuses instead of being skipped.
#   * Two direct, read-only `herdr pane get <exact-pane>` responses must each
#     repeat the recorded pane, tab, and workspace ids and report a live
#     foreground_cwd that resolves exactly to the recorded worktree.
#
# Labels, a shared workspace, the stored pane id by itself, pane creation cwd,
# and ambient Herdr state are never identity evidence. Metadata is published by
# an atomic rename only when it is unchanged since proof began and the staged
# record passes fm_backend_validate_task_endpoint.
#
# Usage: FM_HOME=/path/to/firstmate-home fm-repair-legacy-endpoint-binding.sh <task-id>
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}

die_usage() {
  echo "usage: FM_HOME=/path/to/firstmate-home $0 <task-id>" >&2
  exit 2
}

refuse() {
  echo "REFUSED: $*; preserving task state." >&2
  exit 1
}

[ "${FM_HOME+x}" = x ] && [ -n "$FM_HOME" ] || die_usage
[ "$#" -eq 1 ] || die_usage
ID=$1
case "$ID" in
  ''|*[!A-Za-z0-9._-]*) die_usage ;;
esac

HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) \
  || refuse "FM_HOME is not an existing physical directory"
[ "$FM_HOME" = "$HOME_REAL" ] \
  || refuse "FM_HOME must be its physical path, not an alias"
[ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] \
  || refuse "FM_HOME has no regular state directory"
STATE="$FM_HOME/state"
META="$STATE/$ID.meta"
CONTROL_LOCK="$STATE/.control-$ID.lock"
TASK_SET_LOCK=
TASK_SET_LOCK_HELD=0
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
SNAPSHOT=

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent "$FM_ROOT"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

cleanup() {
  local status=$?
  [ -z "$SNAPSHOT" ] || rm -f -- "$SNAPSHOT" 2>/dev/null || true
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CONTROL_LOCK" || true
    CONTROL_LOCK_HELD=0
  fi
  if [ "$TASK_SET_LOCK_HELD" = 1 ]; then
    fm_lock_release "$TASK_SET_LOCK" || true
    TASK_SET_LOCK_HELD=0
  fi
  return "$status"
}
trap cleanup EXIT

TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") \
  || refuse "task $ID has an unsafe task-inventory lock identity"
fm_lock_try_acquire "$TASK_SET_LOCK" \
  || refuse "this home's task inventory is changing during legacy binding recovery"
TASK_SET_LOCK_HELD=1
fm_lock_try_acquire "$CONTROL_LOCK" || \
  refuse "another lifecycle action is already running for task $ID"
CONTROL_LOCK_HELD=1

[ -f "$META" ] && [ ! -L "$META" ] \
  || refuse "task $ID has no regular endpoint metadata at $META"
META_LOCK=$(fm_meta_lock_path "$META") || refuse "task $ID has an unsafe metadata lock identity"
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] \
  || refuse "task $ID endpoint metadata changed before it could be locked"

file_link_count() {  # <file>
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

[ "$(file_link_count "$META" 2>/dev/null || true)" = 1 ] \
  || refuse "task $ID endpoint metadata is hardlinked or unreadable"

binding_count=$(grep -c '^endpoint_task_id=' "$META" 2>/dev/null || true)
case "$binding_count" in
  1)
    binding=$(fm_backend_meta_exact_value "$META" endpoint_task_id 2>/dev/null || true)
    [ "$binding" = "$ID" ] \
      || refuse "task $ID has an empty or conflicting endpoint task binding"
    fm_backend_validate_task_endpoint "$META" "$ID" \
      || refuse "task $ID already has a binding but its endpoint metadata is invalid"
    printf 'endpoint binding already valid for task %s; nothing changed\n' "$ID"
    exit 0
    ;;
  0) ;;
  *) refuse "task $ID has an ambiguous endpoint task binding" ;;
esac

backend=$(fm_backend_meta_exact_value "$META" backend 2>/dev/null || true)
[ "$backend" = herdr ] \
  || refuse "task $ID is not singular legacy Herdr endpoint metadata"

window=$(fm_backend_meta_exact_value "$META" window 2>/dev/null || true)
worktree=$(fm_backend_meta_exact_value "$META" worktree 2>/dev/null || true)
project=$(fm_backend_meta_exact_value "$META" project 2>/dev/null || true)
session=$(fm_backend_meta_exact_value "$META" herdr_session 2>/dev/null || true)
workspace=$(fm_backend_meta_exact_value "$META" herdr_workspace_id 2>/dev/null || true)
tab=$(fm_backend_meta_exact_value "$META" herdr_tab_id 2>/dev/null || true)
pane=$(fm_backend_meta_exact_value "$META" herdr_pane_id 2>/dev/null || true)
[ -n "$window" ] && [ -n "$worktree" ] && [ -n "$project" ] \
  && [ -n "$session" ] && [ -n "$workspace" ] && [ -n "$tab" ] && [ -n "$pane" ] \
  || refuse "task $ID has missing, empty, or ambiguous legacy Herdr identity fields"
case "$window$worktree$project$session$workspace$tab$pane" in
  *$'\n'*|*$'\r'*|*$'\t'*) refuse "task $ID has control characters in legacy Herdr identity fields" ;;
esac
if ! fm_backend_endpoint_atom_valid "$session" \
  || ! fm_backend_endpoint_atom_valid "$workspace" \
  || ! fm_backend_endpoint_atom_valid "${tab//:/_}" \
  || ! fm_backend_endpoint_atom_valid "${pane//:/_}"; then
  refuse "task $ID has malformed legacy Herdr endpoint atoms"
fi
[ "$window" = "$session:$pane" ] \
  || refuse "task $ID window and Herdr pane identities disagree"
case "$tab" in "$workspace":*) ;; *) refuse "task $ID tab and workspace identities disagree" ;; esac
case "$pane" in "$workspace":*) ;; *) refuse "task $ID pane and workspace identities disagree" ;; esac

canonical_dir() {  # <existing-directory>
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

canonical_git_common_dir() {  # <repository-directory>
  local root=$1 common
  common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) ;;
    *) common="$root/$common" ;;
  esac
  canonical_dir "$common"
}

worktree_real=$(canonical_dir "$worktree") \
  || refuse "task $ID worktree is not a physical directory"
project_real=$(canonical_dir "$project") \
  || refuse "task $ID project is not a physical directory"
[ "$worktree" = "$worktree_real" ] && [ "$project" = "$project_real" ] \
  || refuse "task $ID worktree or project uses a non-physical alias"
[ "$worktree_real" != "$project_real" ] \
  || refuse "task $ID worktree is not distinct from its project checkout"

worktree_top=$(git -C "$worktree_real" rev-parse --show-toplevel 2>/dev/null || true)
project_top=$(git -C "$project_real" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$worktree_top" ] && [ -n "$project_top" ] \
  || refuse "task $ID worktree or project is not an inspectable Git checkout"
worktree_top=$(canonical_dir "$worktree_top" 2>/dev/null || true)
project_top=$(canonical_dir "$project_top" 2>/dev/null || true)
[ "$worktree_top" = "$worktree_real" ] && [ "$project_top" = "$project_real" ] \
  || refuse "task $ID worktree or project does not name its exact Git top level"
worktree_common=$(canonical_git_common_dir "$worktree_real" 2>/dev/null || true)
project_common=$(canonical_git_common_dir "$project_real" 2>/dev/null || true)
[ -n "$worktree_common" ] && [ "$worktree_common" = "$project_common" ] \
  || refuse "task $ID worktree is not linked to the recorded project"

registered_count=0
listed=$(git -C "$project_real" -c core.quotePath=false worktree list --porcelain 2>/dev/null) \
  || refuse "task $ID project worktree inventory is unreadable"
while IFS= read -r line; do
  case "$line" in
    worktree\ *)
      listed_path=${line#worktree }
      listed_real=$(canonical_dir "$listed_path" 2>/dev/null || true)
      [ "$listed_real" != "$worktree_real" ] || registered_count=$((registered_count + 1))
      ;;
  esac
done <<EOF
$listed
EOF
[ "$registered_count" -eq 1 ] \
  || refuse "task $ID worktree is not registered exactly once by the recorded project"

# Any competing durable claim makes the target ambiguous. Inspect claims before
# consulting Herdr so labels, shared workspace placement, or a live-looking pane
# can never override fleet metadata disagreement.
for other in "$STATE"/*.meta; do
  [ -e "$other" ] || [ -L "$other" ] || continue
  [ "$other" = "$META" ] && continue
  [ -f "$other" ] && [ ! -L "$other" ] \
    || refuse "task metadata inventory contains an unsafe record at $other"
  [ "$(file_link_count "$other" 2>/dev/null || true)" = 1 ] \
    || refuse "task metadata inventory contains a hardlinked or unreadable record at $other"
  other_session_match=0
  other_session_count=0
  other_pane_match=0
  while IFS= read -r line; do
    case "$line" in
      window=*)
        [ "${line#window=}" != "$window" ] \
          || refuse "another task record claims endpoint $window"
        ;;
      worktree=*)
        claimed=${line#worktree=}
        [ "$claimed" != "$worktree" ] \
          || refuse "another task record claims worktree $worktree"
        claimed_real=$(canonical_dir "$claimed" 2>/dev/null || true)
        [ -z "$claimed_real" ] || [ "$claimed_real" != "$worktree_real" ] \
          || refuse "another task record canonically claims worktree $worktree"
        ;;
      herdr_session=*)
        other_session_count=$((other_session_count + 1))
        [ "${line#herdr_session=}" != "$session" ] || other_session_match=1
        ;;
      herdr_pane_id=*)
        [ "${line#herdr_pane_id=}" != "$pane" ] || other_pane_match=1
        ;;
    esac
  done < "$other"
  if [ "$other_pane_match" = 1 ]; then
    [ "$other_session_count" -eq 1 ] \
      || refuse "another task record ambiguously claims Herdr pane $pane"
    [ "$other_session_match" -ne 1 ] \
      || refuse "another task record claims Herdr pane $session:$pane"
  fi
done

last_byte=$(tail -c 1 "$META" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')
[ "$last_byte" = 0a ] || refuse "task $ID metadata lacks a safe terminating newline"
umask 077
SNAPSHOT=$(mktemp "$STATE/.$ID.meta.binding.XXXXXX") \
  || refuse "could not stage a private metadata snapshot for task $ID"
cp -p -- "$META" "$SNAPSHOT" \
  || refuse "could not snapshot task $ID metadata"

fm_backend_source herdr >/dev/null 2>&1 \
  || refuse "the Herdr backend adapter is unavailable"
fm_backend_herdr_tool_check \
  || refuse "the Herdr read-only identity tools are unavailable"

read_live_worktree() {
  local out cwd cwd_real
  out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  cwd=$(printf '%s' "$out" | jq -er \
    --arg workspace "$workspace" --arg tab "$tab" --arg pane "$pane" '
      .result.pane as $p
      | select(($p | type) == "object")
      | select($p.pane_id == $pane)
      | select($p.tab_id == $tab)
      | select($p.workspace_id == $workspace)
      | $p.foreground_cwd
      | select(type == "string" and length > 0)
    ' 2>/dev/null) || return 1
  case "$cwd" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  cwd_real=$(canonical_dir "$cwd" 2>/dev/null) || return 1
  [ "$cwd" = "$cwd_real" ] || return 1
  printf '%s' "$cwd_real"
}

live_one=$(read_live_worktree) \
  || refuse "the exact Herdr pane did not prove its recorded pane, tab, workspace, and live foreground path"
[ "$live_one" = "$worktree_real" ] \
  || refuse "the exact Herdr pane foreground path does not match the recorded worktree"
live_two=$(read_live_worktree) \
  || refuse "the exact Herdr pane identity was not stable across two read-only samples"
[ "$live_two" = "$worktree_real" ] && [ "$live_two" = "$live_one" ] \
  || refuse "the exact Herdr pane foreground path changed during identity proof"

cmp -s "$SNAPSHOT" "$META" \
  || refuse "task $ID metadata changed during identity proof"
printf 'endpoint_task_id=%s\n' "$ID" >> "$SNAPSHOT"
fm_backend_validate_task_endpoint "$SNAPSHOT" "$ID" \
  || refuse "the staged endpoint binding failed the ordinary teardown validator"
cmp -s <(sed '$d' "$SNAPSHOT") "$META" 2>/dev/null \
  || refuse "task $ID metadata changed before binding publication"
mv -f -- "$SNAPSHOT" "$META" \
  || refuse "could not publish the verified endpoint binding for task $ID"
SNAPSHOT=
printf 'repaired endpoint task binding for %s; no lifecycle action was performed\n' "$ID"
