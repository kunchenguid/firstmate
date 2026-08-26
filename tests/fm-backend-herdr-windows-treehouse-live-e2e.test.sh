#!/usr/bin/env bash
# Opt-in native Windows proof for fm-spawn's Herdr Treehouse lease path.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER=${HERDR_LAB_HELPER:-"$ROOT/bin/fm-herdr-lab.sh"}

[ "${FM_HERDR_WINDOWS_TREEHOUSE_LIVE:-0}" = 1 ] \
  || { echo "skip: set FM_HERDR_WINDOWS_TREEHOUSE_LIVE=1 for native Windows Herdr Treehouse verification"; exit 0; }
case "$(uname -s 2>/dev/null || true)" in
  MSYS*|MINGW*|CYGWIN*) ;;
  *) echo "skip: native Windows Git Bash required"; exit 0 ;;
esac
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
[ -x "$HELPER" ] || { echo "skip: Herdr lab helper not executable at $HELPER"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ID='windows-treehouse-live'
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-win-treehouse-live.XXXXXX")
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
META="$HOME_DIR/state/$ID.meta"
LAB=
WORKTREE=

cleanup() {
  status=$?
  [ -n "$WORKTREE" ] || WORKTREE=$(grep '^worktree=' "$META" 2>/dev/null | cut -d= -f2- || true)
  if [ -n "$LAB" ]; then
    "$HELPER" teardown "$LAB" >/dev/null 2>&1 || true
  fi
  if [ -n "$WORKTREE" ] \
     && [ -d "$WORKTREE" ] \
     && [ -z "$(git -C "$WORKTREE" status --porcelain 2>/dev/null || printf dirty)" ]; then
    treehouse return --force "$WORKTREE" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

LAB=$("$HELPER" name windows-treehouse)
"$HELPER" provision "$LAB" >/dev/null

mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/state" "$HOME_DIR/config"
touch "$HOME_DIR/state/.last-watcher-beat"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
printf 'Native Windows Herdr Treehouse launch fixture.\n' > "$HOME_DIR/data/$ID/brief.md"

mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
git -C "$PROJECT" branch -M main
printf '# live fixture\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJECT" "$TMP_ROOT/origin.git"
git -C "$PROJECT" remote add origin "file://$TMP_ROOT/origin.git"

FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  HERDR_SESSION="$LAB" "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" \
  "sh -c 'sleep 120'" --mode no-mistakes --yolo off --backend herdr

[ -f "$META" ]
TARGET=$(grep '^window=' "$META" | cut -d= -f2-)
WORKTREE=$(grep '^worktree=' "$META" | cut -d= -f2-)
PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)

FM_HOME="$HOME_DIR"
export FM_HOME
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
CURRENT=$(fm_backend_herdr_current_path "$TARGET")
CURRENT_REAL=$(cd "$CURRENT" && pwd -P)
WORKTREE_REAL=$(cd "$WORKTREE" && pwd -P)
[ "$CURRENT_REAL" = "$WORKTREE_REAL" ]

INFO=$("$HELPER" run "$LAB" pane process-info --pane "$PANE")
GROUP_ID=$(printf '%s' "$INFO" | jq -r '.result.process_info.foreground_process_group_id')
LEADER_NAME=$(printf '%s' "$INFO" | jq -r --argjson gid "$GROUP_ID" \
  '.result.process_info.foreground_processes[] | select(.pid == $gid) | .name')
LEADER_CWD=$(printf '%s' "$INFO" | jq -r --argjson gid "$GROUP_ID" \
  '.result.process_info.foreground_processes[] | select(.pid == $gid) | .cwd')
LEADER_REAL=$(cd "$LEADER_CWD" && pwd -P)
[ "$LEADER_REAL" = "$WORKTREE_REAL" ]

"$HELPER" teardown "$LAB" >/dev/null
LAB=
[ -z "$(git -C "$WORKTREE" status --porcelain)" ]
VERIFIED_WORKTREE=$WORKTREE
treehouse return --force "$WORKTREE" >/dev/null
WORKTREE=

printf 'herdr_version=%s\n' "$(herdr --version)"
printf 'treehouse_version=%s\n' "$(treehouse --version)"
printf 'treehouse_mode=%s\n' "$(fm_backend_herdr_treehouse_acquisition_mode)"
printf 'target=%s\n' "$TARGET"
printf 'worktree=%s\n' "$VERIFIED_WORKTREE"
printf 'adapter_path=%s\n' "$CURRENT"
printf 'leader_name=%s\n' "$LEADER_NAME"
printf 'leader_cwd=%s\n' "$LEADER_CWD"
printf 'cleanup=guarded-lab-and-treehouse-return\n'
printf 'result=pass\n'
