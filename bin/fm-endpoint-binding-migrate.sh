#!/usr/bin/env bash
# Recover the cleanup binding for one ordinary non-tmux task record written before
# endpoint_task_id= was published by fm-spawn.sh.
#
# This is a narrow cleanup-time compatibility path, not a general metadata
# upgrader. It accepts only the complete legacy spawn shape, proves that the
# recorded live endpoint still carries the exact task and home identity exposed
# by that backend, then atomically adds endpoint_task_id=<task-id>. The ordinary
# metadata-only validator remains the sole cleanup authorization check and runs
# again after publication.
#
# Herdr proof requires the exact recorded workspace, tab, and pane topology,
# the exact task label, one unambiguous home or projection workspace, and the
# live foreground cwd matching the recorded Git worktree. Zellij and cmux proof
# requires their exact home-scoped task title plus the recorded tab/pane or
# workspace/surface topology. Orca exposes no verified read-only relation from
# a terminal handle to its named worktree, so legacy Orca records remain
# quarantined by refusal rather than receiving an invented binding.
#
# Usage: fm-endpoint-binding-migrate.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() { echo "usage: fm-endpoint-binding-migrate.sh <task-id>" >&2; }

[ "$#" -eq 1 ] || { usage; exit 2; }
ID=$1
case "$ID" in ''|.*|*[!A-Za-z0-9._-]*) usage; exit 2 ;; esac
META="$STATE/$ID.meta"
LOCK="$STATE/.spawn-$ID.lock"
TMP=
LOCK_HELD=0

cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP"
  [ "$LOCK_HELD" -ne 1 ] || fm_lock_release "$LOCK" || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

refuse() {
  echo "REFUSED: legacy endpoint metadata for task $ID cannot be bound safely: $1; preserving task state." >&2
  return 1
}

canonical_dir() {  # <path>
  (cd "$1" 2>/dev/null && pwd -P)
}

git_common_dir() {  # <worktree-or-repo>
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) canonical_dir "$common" ;;
    *) canonical_dir "$dir/$common" ;;
  esac
}

meta_required() {  # <key>
  fm_backend_meta_exact_value "$META" "$1"
}

meta_core_shape_valid() {
  local key value
  for key in harness kind mode yolo tasktmp model effort; do
    value=$(meta_required "$key") || return 1
    case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  done
  [ "$(meta_required tasktmp)" = "/tmp/fm-$ID" ] || return 1
  [ "$(meta_required kind)" != secondmate ]
}

metadata_endpoint_unique_in_home() {  # <backend> <window> <worktree-id> <terminal>
  local backend=$1 window=$2 worktree_id=$3 terminal=$4 other
  for other in "$STATE"/*.meta; do
    [ -e "$other" ] || continue
    [ "$other" != "$META" ] || continue
    [ -f "$other" ] && [ ! -L "$other" ] || return 1
    if grep -Fqx "window=$window" "$other" 2>/dev/null; then
      return 1
    fi
    if [ "$backend" = orca ]; then
      [ -z "$worktree_id" ] || ! grep -Fqx "orca_worktree_id=$worktree_id" "$other" 2>/dev/null || return 1
      [ -z "$terminal" ] || ! grep -Fqx "terminal=$terminal" "$other" 2>/dev/null || return 1
    fi
  done
}

legacy_shape_valid_with_binding() {  # <mode>
  local mode=$1
  TMP=$(mktemp "$STATE/.fm-endpoint-binding.XXXXXX") || return 1
  chmod "$mode" "$TMP" || return 1
  {
    cat "$META"
    printf 'endpoint_task_id=%s\n' "$ID"
  } > "$TMP" || return 1
  fm_backend_validate_task_endpoint "$TMP" "$ID" >/dev/null 2>&1
}

herdr_flat_identity_proven() {  # <session> <workspace> <tab> <pane>
  local session=$1 workspace=$2 tab=$3 pane=$4 expected_workspace workspaces tabs panes
  expected_workspace=$(fm_backend_herdr_workspace_label)
  workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$workspaces" | jq -e --arg workspace "$workspace" --arg label "$expected_workspace" '
    (.result.workspaces | type) == "array"
    and ([.result.workspaces[] | select(.workspace_id == $workspace and .label == $label)] | length) == 1
    and ([.result.workspaces[] | select(.label == $label)] | length) == 1
  ' >/dev/null 2>&1 || return 1
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e --arg workspace "$workspace" --arg tab "$tab" --arg label "fm-$ID" '
    (.result.tabs | type) == "array"
    and ([.result.tabs[] | select(.tab_id == $tab and .workspace_id == $workspace and .label == $label)] | length) == 1
    and ([.result.tabs[] | select(.label == $label)] | length) == 1
  ' >/dev/null 2>&1 || return 1
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e --arg tab "$tab" --arg pane "$pane" '
    (.result.panes | type) == "array"
    and ([.result.panes[] | select(.pane_id == $pane and .tab_id == $tab)] | length) == 1
  ' >/dev/null 2>&1
}

herdr_projection_identity_proven() {  # <session> <workspace> <tab> <pane>
  local session=$1 workspace=$2 tab=$3 pane=$4 concise prefix workspaces tabs panes
  concise=$(fm_backend_herdr_projection_concise_task_label "$ID")
  prefix="└ $concise · p:"
  workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$workspaces" | jq -e --arg workspace "$workspace" --arg prefix "$prefix" '
    def exact_projection:
      (.label | type) == "string"
      and (.label | startswith($prefix))
      and ((.label | ltrimstr($prefix)) | test("^[A-Za-z0-9_-]{22}$"));
    (.result.workspaces | type) == "array"
    and ([.result.workspaces[] | select(.workspace_id == $workspace and exact_projection)] | length) == 1
    and ([.result.workspaces[] | select(exact_projection)] | length) == 1
  ' >/dev/null 2>&1 || return 1
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" --arg label "fm-$ID" '
    (.result.tabs | type) == "array"
    and (.result.tabs | length) == 1
    and .result.tabs[0].tab_id == $tab
    and .result.tabs[0].label == $label
  ' >/dev/null 2>&1 || return 1
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e --arg tab "$tab" --arg pane "$pane" '
    (.result.panes | type) == "array"
    and (.result.panes | length) == 1
    and .result.panes[0].pane_id == $pane
    and .result.panes[0].tab_id == $tab
  ' >/dev/null 2>&1
}

herdr_identity_proven() {  # <worktree-real>
  local worktree_real=$1 session workspace tab pane pane_info foreground foreground_real
  session=$(meta_required herdr_session) || return 1
  workspace=$(meta_required herdr_workspace_id) || return 1
  tab=$(meta_required herdr_tab_id) || return 1
  pane=$(meta_required herdr_pane_id) || return 1
  herdr_flat_identity_proven "$session" "$workspace" "$tab" "$pane" \
    || herdr_projection_identity_proven "$session" "$workspace" "$tab" "$pane" \
    || return 1
  pane_info=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  foreground=$(printf '%s' "$pane_info" | jq -er --arg pane "$pane" '
    .result.pane
    | select(.pane_id == $pane)
    | .foreground_cwd
    | select(type == "string" and length > 0)
  ' 2>/dev/null) || return 1
  foreground_real=$(canonical_dir "$foreground") || return 1
  [ "$foreground_real" = "$worktree_real" ]
}

zellij_identity_proven() {
  local session tab pane expected tabs panes
  session=$(meta_required zellij_session) || return 1
  tab=$(meta_required zellij_tab_id) || return 1
  pane=$(meta_required zellij_pane_id) || return 1
  fm_backend_zellij_session_exists "$session" || return 1
  expected=$(fm_backend_zellij_scoped_title "fm-$ID")
  tabs=$(fm_backend_zellij_cli "$session" action list-tabs --json 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e --argjson tab "$tab" --arg title "$expected" '
    type == "array"
    and ([.[] | select(.tab_id == $tab and .name == $title)] | length) == 1
    and ([.[] | select(.name == $title)] | length) == 1
  ' >/dev/null 2>&1 || return 1
  panes=$(fm_backend_zellij_cli "$session" action list-panes --json 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e --argjson tab "$tab" --argjson pane "$pane" '
    type == "array"
    and ([.[] | select(.tab_id == $tab and .id == $pane and .is_plugin == false)] | length) == 1
  ' >/dev/null 2>&1
}

cmux_identity_proven() {
  local workspace surface expected windows window workspaces id_count=0 title_count=0 count panes
  workspace=$(meta_required cmux_workspace_id) || return 1
  surface=$(meta_required cmux_surface_id) || return 1
  expected=$(fm_backend_cmux_scoped_title "fm-$ID")
  windows=$(fm_backend_cmux_cli list-windows --json --id-format uuids 2>/dev/null) || return 1
  while IFS= read -r window; do
    [ -n "$window" ] || continue
    workspaces=$(fm_backend_cmux_cli workspace list --json --id-format uuids --window "$window" 2>/dev/null) || return 1
    count=$(printf '%s' "$workspaces" | jq -r --arg id "$workspace" --arg title "$expected" \
      '[.workspaces[]? | select(.id == $id and .title == $title)] | length' 2>/dev/null) || return 1
    case "$count" in ''|*[!0-9]*) return 1 ;; esac
    id_count=$((id_count + count))
    count=$(printf '%s' "$workspaces" | jq -r --arg title "$expected" \
      '[.workspaces[]? | select(.title == $title)] | length' 2>/dev/null) || return 1
    case "$count" in ''|*[!0-9]*) return 1 ;; esac
    title_count=$((title_count + count))
  done < <(printf '%s' "$windows" | jq -r '.[]? | .id // empty' 2>/dev/null)
  [ "$id_count" -eq 1 ] && [ "$title_count" -eq 1 ] || return 1
  panes=$(fm_backend_cmux_cli list-panes --workspace "$workspace" --json --id-format uuids 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e --arg surface "$surface" '
    (.panes | type) == "array"
    and ([.panes[]? | select((.surface_ids // []) | index($surface))] | length) == 1
  ' >/dev/null 2>&1
}

[ -d "$STATE" ] && [ ! -L "$STATE" ] || { refuse "state directory is not a private ordinary directory"; exit 1; }
[ -f "$META" ] && [ ! -L "$META" ] || { refuse "metadata is not an ordinary file"; exit 1; }
STATE_DEVICE=$(fm_pr_file_device "$STATE") || { refuse "state device is unreadable"; exit 1; }
[ "$(fm_pr_file_device "$META")" = "$STATE_DEVICE" ] \
  && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { refuse "metadata has an unsafe file identity"; exit 1; }
MODE=$(fm_pr_file_mode "$META") || { refuse "metadata mode is unreadable"; exit 1; }
case "$MODE" in 600|640|644) ;; *) refuse "metadata permissions are not a trusted legacy mode"; exit 1 ;; esac
[ "$(grep -c '^endpoint_task_id=' "$META" 2>/dev/null || true)" -eq 0 ] \
  || { refuse "endpoint binding is already present or ambiguous"; exit 1; }
[ "$(tail -c 1 "$META" 2>/dev/null | od -An -t u1 | tr -d '[:space:]')" = 10 ] \
  || { refuse "metadata is not a complete newline-terminated record"; exit 1; }

if ! fm_lock_try_acquire "$LOCK"; then
  refuse "task publication is still in progress"
  exit 1
fi
LOCK_HELD=1

# Recheck and snapshot the exact source before parsing or live proof.
[ -f "$META" ] && [ ! -L "$META" ] \
  && [ "$(fm_pr_file_device "$META")" = "$STATE_DEVICE" ] \
  && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  && [ "$(grep -c '^endpoint_task_id=' "$META" 2>/dev/null || true)" -eq 0 ] \
  || { refuse "metadata changed while acquiring its task lock"; exit 1; }
SOURCE_IDENTITY=$(fm_pr_file_identity "$META") || { refuse "metadata identity is unreadable"; exit 1; }
SOURCE_HASH=$(fm_pr_sha256 "$META") || { refuse "metadata bytes are unreadable"; exit 1; }

BACKEND=$(meta_required backend) || { refuse "backend identity is missing or ambiguous"; exit 1; }
fm_backend_is_known "$BACKEND" && [ "$BACKEND" != tmux ] \
  || { refuse "record is not an eligible non-tmux legacy endpoint"; exit 1; }
meta_core_shape_valid || { refuse "record does not match the complete trusted legacy spawn shape"; exit 1; }

HOME_REAL=$(canonical_dir "$FM_HOME") || { refuse "firstmate home is unavailable"; exit 1; }
STATE_REAL=$(canonical_dir "$STATE") || { refuse "state directory is unavailable"; exit 1; }
case "$STATE_REAL/" in "$HOME_REAL/"*) ;; *) refuse "state directory is outside the active firstmate home"; exit 1 ;; esac
WORKTREE=$(meta_required worktree) || { refuse "worktree identity is missing or ambiguous"; exit 1; }
PROJECT=$(meta_required project) || { refuse "project identity is missing or ambiguous"; exit 1; }
WORKTREE_REAL=$(canonical_dir "$WORKTREE") || { refuse "recorded worktree is unavailable"; exit 1; }
PROJECT_REAL=$(canonical_dir "$PROJECT") || { refuse "recorded project is unavailable"; exit 1; }
ROOT_REAL=$(canonical_dir "$FM_ROOT") || { refuse "firstmate code root is unavailable"; exit 1; }
if [ "$PROJECT_REAL" = "$ROOT_REAL" ]; then
  [ "$HOME_REAL" = "$ROOT_REAL" ] \
    || { refuse "shared code root is not this firstmate home's own project"; exit 1; }
else
  case "$PROJECT_REAL" in
    "$HOME_REAL/projects/"*) ;;
    *) refuse "recorded project is outside this firstmate home"; exit 1 ;;
  esac
fi
[ "$WORKTREE_REAL" != "$PROJECT_REAL" ] || { refuse "recorded worktree is not isolated from its project"; exit 1; }
WT_TOP=$(git -C "$WORKTREE_REAL" rev-parse --show-toplevel 2>/dev/null) \
  || { refuse "recorded worktree is not a Git worktree"; exit 1; }
WT_TOP=$(canonical_dir "$WT_TOP") || { refuse "recorded worktree root is unavailable"; exit 1; }
[ "$WT_TOP" = "$WORKTREE_REAL" ] || { refuse "recorded worktree is not its Git top level"; exit 1; }
WT_COMMON=$(git_common_dir "$WORKTREE_REAL") || { refuse "worktree Git identity is unavailable"; exit 1; }
PROJECT_COMMON=$(git_common_dir "$PROJECT_REAL") || { refuse "project Git identity is unavailable"; exit 1; }
[ "$WT_COMMON" = "$PROJECT_COMMON" ] || { refuse "worktree does not belong to the recorded project"; exit 1; }
git -C "$PROJECT_REAL" worktree list --porcelain 2>/dev/null \
  | grep -Fqx "worktree $WORKTREE_REAL" \
  || { refuse "worktree is not registered by the recorded project"; exit 1; }
BRIEF="$DATA/$ID/brief.md"
[ -f "$BRIEF" ] && [ ! -L "$BRIEF" ] && [ "$(fm_pr_file_link_count "$BRIEF")" = 1 ] \
  || { refuse "task instructions are unavailable or unsafe"; exit 1; }

WINDOW=$(meta_required window) || { refuse "window identity is missing or ambiguous"; exit 1; }
ORCA_WORKTREE_ID=$(fm_meta_get "$META" orca_worktree_id)
ORCA_TERMINAL=$(fm_meta_get "$META" terminal)
metadata_endpoint_unique_in_home "$BACKEND" "$WINDOW" "$ORCA_WORKTREE_ID" "$ORCA_TERMINAL" \
  || { refuse "another local record references the same endpoint"; exit 1; }
legacy_shape_valid_with_binding "$MODE" \
  || { refuse "record is malformed or backend-inconsistent"; exit 1; }

case "$BACKEND" in
  herdr)
    fm_backend_source herdr || { refuse "Herdr adapter is unavailable"; exit 1; }
    herdr_identity_proven "$WORKTREE_REAL" \
      || { refuse "live Herdr topology, home, task label, and worktree do not all agree"; exit 1; }
    ;;
  zellij)
    fm_backend_source zellij || { refuse "Zellij adapter is unavailable"; exit 1; }
    zellij_identity_proven \
      || { refuse "live Zellij home-scoped title and endpoint topology do not agree"; exit 1; }
    ;;
  cmux)
    fm_backend_source cmux || { refuse "cmux adapter is unavailable"; exit 1; }
    cmux_identity_proven \
      || { refuse "live cmux home-scoped title and endpoint topology do not agree"; exit 1; }
    ;;
  orca)
    refuse "Orca has no verified read-only terminal-to-named-worktree identity proof"
    exit 1
    ;;
  *)
    refuse "backend has no bounded legacy identity proof"
    exit 1
    ;;
esac

# Bind publication to the exact bytes and inode that were parsed and proven live.
[ "$(fm_pr_file_identity "$META")" = "$SOURCE_IDENTITY" ] \
  && [ "$(fm_pr_sha256 "$META")" = "$SOURCE_HASH" ] \
  && [ "$(grep -c '^endpoint_task_id=' "$META" 2>/dev/null || true)" -eq 0 ] \
  || { refuse "metadata changed during live identity proof"; exit 1; }
if ! { [ -n "$TMP" ] && [ -f "$TMP" ] && [ ! -L "$TMP" ] \
  && [ "$(fm_pr_file_device "$TMP")" = "$STATE_DEVICE" ] \
  && [ "$(fm_pr_file_link_count "$TMP")" = 1 ] \
  && fm_backend_validate_task_endpoint "$TMP" "$ID" >/dev/null 2>&1; }; then
  refuse "bound replacement record failed final validation"
  exit 1
fi
mv -f -- "$TMP" "$META" || { refuse "bound replacement record could not be published"; exit 1; }
TMP=
fm_backend_validate_task_endpoint "$META" "$ID" >/dev/null 2>&1 \
  || { refuse "published binding did not pass the cleanup validator"; exit 1; }
printf 'ENDPOINT_BINDING_MIGRATION: task %s: exact live %s identity bound for cleanup\n' "$ID" "$BACKEND"
