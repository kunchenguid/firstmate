#!/usr/bin/env bash
# Verify a resumed ordinary task before firstmate sends it any instruction that
# could mutate its project.
# Usage: fm-recovery-verify.sh <task-id>
#
# New task metadata contains project_git_common_dir=, written by fm-spawn.sh
# from the selected project clone; legacy metadata derives it from project=.
# This command reads the live foreground process cwd from the recorded backend,
# then requires its Git top-level to equal worktree= and its canonical Git
# common directory to equal project_git_common_dir=.
# A missing field, unreadable backend cwd, unsupported live-cwd backend, path
# mismatch, or clone-identity mismatch fails closed and requires a fresh launch
# in the recorded worktree instead of continuing the resumed session.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
[ "$#" -eq 1 ] || { usage >&2; exit 2; }

ID=$1
case "$ID" in
  *[!A-Za-z0-9._-]*|'') echo "error: invalid task id" >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-worktree-identity-lib.sh
. "$SCRIPT_DIR/fm-worktree-identity-lib.sh"

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no task metadata for $ID; refusing recovery resume" >&2; exit 1; }

KIND=$(fm_meta_get "$META" kind)
case "$KIND" in
  ship|scout) ;;
  *) echo "error: task $ID is kind=${KIND:-unknown}; recovery resume verification is only defined for ordinary ship/scout tasks" >&2; exit 1 ;;
esac

WT=$(fm_meta_get "$META" worktree)
EXPECTED_COMMON=$(fm_meta_get "$META" project_git_common_dir)
[ -n "$WT" ] || { echo "error: task $ID metadata has no worktree=; refusing recovery resume" >&2; exit 1; }
if [ -z "$EXPECTED_COMMON" ]; then
  PROJECT=$(fm_meta_get "$META" project)
  EXPECTED_COMMON=$(fm_git_common_dir_canonical "$PROJECT" 2>/dev/null || true)
fi
[ -n "$EXPECTED_COMMON" ] || { echo "error: task $ID metadata has no usable selected-clone identity; refusing recovery resume" >&2; exit 1; }

WT_ROOT=$(fm_git_worktree_root_canonical "$WT") || {
  echo "error: task $ID recorded worktree is not an available Git worktree: $WT" >&2
  exit 1
}
WT_COMMON=$(fm_git_common_dir_canonical "$WT") || {
  echo "error: task $ID recorded worktree clone identity cannot be resolved: $WT" >&2
  exit 1
}
if [ "$WT_COMMON" != "$EXPECTED_COMMON" ]; then
  echo "error: task $ID recorded worktree belongs to clone '$WT_COMMON', not recorded selected clone '$EXPECTED_COMMON'; refusing recovery resume" >&2
  exit 1
fi

BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
[ -n "$TARGET" ] || { echo "error: task $ID metadata has no backend target; refusing recovery resume" >&2; exit 1; }
fm_backend_source "$BACKEND" || exit 1

case "$BACKEND" in
  tmux) ACTUAL=$(fm_backend_tmux_current_path "$TARGET" || true) ;;
  herdr) ACTUAL=$(fm_backend_herdr_current_path "$TARGET" || true) ;;
  zellij|orca|cmux)
    echo "error: backend=$BACKEND does not expose a verified passive live foreground cwd; refusing recovery resume for task $ID" >&2
    exit 1
    ;;
  *)
    echo "error: backend=$BACKEND has no verified recovery cwd check; refusing recovery resume for task $ID" >&2
    exit 1
    ;;
esac

[ -n "$ACTUAL" ] || { echo "error: could not read task $ID live foreground cwd from backend=$BACKEND target=$TARGET; refusing recovery resume" >&2; exit 1; }
if ! fm_git_path_matches_worktree_identity "$ACTUAL" "$WT_ROOT" "$EXPECTED_COMMON"; then
  ACTUAL_ROOT=$(fm_git_worktree_root_canonical "$ACTUAL" 2>/dev/null || printf 'none')
  ACTUAL_COMMON=$(fm_git_common_dir_canonical "$ACTUAL" 2>/dev/null || printf 'none')
  echo "error: resumed task $ID foreground cwd '$ACTUAL' resolves to worktree '$ACTUAL_ROOT' and clone '$ACTUAL_COMMON', expected worktree '$WT_ROOT' and selected clone '$EXPECTED_COMMON'; exit this resumed agent and relaunch fresh in '$WT_ROOT'" >&2
  exit 1
fi

printf 'verified task %s worktree=%s clone=%s\n' "$ID" "$WT_ROOT" "$EXPECTED_COMMON"
