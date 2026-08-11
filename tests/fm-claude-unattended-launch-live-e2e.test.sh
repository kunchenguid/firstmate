#!/usr/bin/env bash
# Real Claude Code unattended-launch guard.
# Run explicitly with FM_CLAUDE_UNATTENDED_LAUNCH_LIVE=1; it creates and cleans
# up only one isolated scout task in a scratch treehouse worktree and a scratch
# CLAUDE_CONFIG_DIR that has never accepted a trust or bypass-permissions
# dialog, so it never touches the operator's real ~/.claude.json or
# ~/.claude/settings.json.
#
# Why this file exists: workspace trust and the "Bypass Permissions mode"
# warning are dialogs Claude Code itself renders, controlled by CLI flags and a
# store format the vendor can change without notice. bin/fm-spawn.sh answers
# both unattended (docs/verification/runtime-backends.md "Claude unattended
# launch"); a regression there silently reintroduces the stuck-pane failure
# mode this fix removed, and only a real Claude Code release can cause or
# reveal it. tests/fm-spawn-dispatch-profile.test.sh pins the launch-string
# logic in portable CI; this guard proves the real dialogs actually stay gone.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK="fm-test-claude-unattended-$$"
LAB=
SPAWNED=0

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup() {
  [ "$SPAWNED" -eq 0 ] || {
    mkdir -p "$LAB/data/$TASK"
    : > "$LAB/data/$TASK/report.md"
    FM_HOME="$LAB" "$ROOT/bin/fm-decision-hold.sh" complete "$TASK" --none >/dev/null 2>&1 || true
    FM_HOME="$LAB" "$ROOT/bin/fm-teardown.sh" "$TASK" >/dev/null 2>&1 || true
  }
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

if [ "${FM_CLAUDE_UNATTENDED_LAUNCH_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_UNATTENDED_LAUNCH_LIVE=1 to run the real Claude unattended-launch guard"
  exit 0
fi

command -v claude >/dev/null 2>&1 || fail "FM_CLAUDE_UNATTENDED_LAUNCH_LIVE=1 but Claude Code is not installed"
command -v tmux >/dev/null 2>&1 || fail "FM_CLAUDE_UNATTENDED_LAUNCH_LIVE=1 but tmux is not installed"
command -v jq >/dev/null 2>&1 || fail "FM_CLAUDE_UNATTENDED_LAUNCH_LIVE=1 but jq is not installed"
command -v treehouse >/dev/null 2>&1 || fail "FM_CLAUDE_UNATTENDED_LAUNCH_LIVE=1 but treehouse is not installed"
command -v python3 >/dev/null 2>&1 || fail "FM_CLAUDE_UNATTENDED_LAUNCH_LIVE=1 but python3 is not installed"
REAL_CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -f "$REAL_CLAUDE_CONFIG_DIR/.credentials.json" ] \
  || fail "FM_CLAUDE_UNATTENDED_LAUNCH_LIVE=1 but $REAL_CLAUDE_CONFIG_DIR/.credentials.json is missing; run 'claude auth login' first"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-unattended.XXXXXX") || fail "could not create an isolated lab"
trap cleanup EXIT
mkdir -p "$LAB/config" "$LAB/data/$TASK" "$LAB/projects/comms" "$LAB/state"
printf 'tmux\n' > "$LAB/config/backend"

# A scratch CLAUDE_CONFIG_DIR that has NEVER accepted either dialog for this
# lab's worktree, seeded only with real credentials (copied, never the real
# store's project-trust or permission-prompt state) so this guard actually
# exercises the fresh-worktree case bin/fm-spawn.sh must handle unattended.
CLAUDE_LAB_CONFIG="$LAB/claude-config"
mkdir -p "$CLAUDE_LAB_CONFIG"
cp "$REAL_CLAUDE_CONFIG_DIR/.credentials.json" "$CLAUDE_LAB_CONFIG/.credentials.json"
chmod 600 "$CLAUDE_LAB_CONFIG/.credentials.json"
printf '{"hasCompletedOnboarding": true}\n' > "$CLAUDE_LAB_CONFIG/.claude.json"
export CLAUDE_CONFIG_DIR="$CLAUDE_LAB_CONFIG"

git init -q --bare "$LAB/origin-comms.git" || fail "could not initialize the isolated probe's local origin"
git -C "$LAB/origin-comms.git" symbolic-ref HEAD refs/heads/main || fail "could not set the isolated probe's local origin default branch"
git -C "$LAB/projects/comms" init -q -b main || fail "could not initialize the isolated probe repository"
git -C "$LAB/projects/comms" config user.email 'claude-unattended-test@example.invalid'
git -C "$LAB/projects/comms" config user.name 'claude unattended test'
printf 'Claude unattended-launch probe\n' > "$LAB/projects/comms/README.md"
git -C "$LAB/projects/comms" add README.md
git -C "$LAB/projects/comms" commit -qm 'fixture: initialize Claude unattended-launch probe'
git -C "$LAB/projects/comms" remote add origin "$LAB/origin-comms.git" || fail "could not add the isolated probe's local origin"
git -C "$LAB/projects/comms" push -q origin main || fail "could not seed the isolated probe's local origin"

STATUS="$LAB/state/$TASK.status"
FM_HOME="$LAB" "$ROOT/bin/fm-brief.sh" "$TASK" comms --scout || fail "could not scaffold the Claude probe brief"
python3 - "$LAB/data/$TASK/brief.md" "$STATUS" <<'PY'
from pathlib import Path
import sys

brief = Path(sys.argv[1])
status = sys.argv[2]
brief.write_text(brief.read_text().replace("{TASK}", f'''Run an unattended-launch probe.

Immediately append `done: unattended launch probe ready` to `{status}` and stop.
Do not change project files or make a commit.'''))
PY

FM_HOME="$LAB" "$ROOT/bin/fm-spawn.sh" "$TASK" "$LAB/projects/comms" --scout --harness claude --backend tmux \
  || fail "could not launch the real Claude unattended-launch probe"
SPAWNED=1

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "could not source the tmux adapter"
TARGET=$(awk -F= '/^window=/{print $2}' "$LAB/state/$TASK.meta")
[ -n "$TARGET" ] || fail "the unattended-launch probe did not record its endpoint"

for _ in $(seq 1 60); do
  CAPTURE=$(fm_backend_tmux_capture "$TARGET" 200 2>/dev/null || true)
  case "$CAPTURE" in
    *'Is this a project you created or one you trust'*)
      fail "Claude $(claude --version) showed the workspace-trust dialog on a fresh worktree; the unattended pre-trust write regressed" ;;
    *'Bypass Permissions mode'*)
      fail "Claude $(claude --version) showed the Bypass Permissions mode warning; the --settings launch flag regressed" ;;
  esac
  grep -q '^done: unattended launch probe ready' "$STATUS" 2>/dev/null && break
  sleep 2
done
grep -q '^done: unattended launch probe ready' "$STATUS" 2>/dev/null \
  || fail "Claude $(claude --version) did not reach the probe's done line within the settle window (capture: $CAPTURE)"
pass "Claude $(claude --version) launched unattended in a fresh worktree with no trust or bypass-permissions dialog"

CAPTURE=$(fm_backend_tmux_capture "$TARGET" 200 2>/dev/null || true)
case "$CAPTURE" in
  *'bypass permissions on'*) pass "the real Claude session confirms bypass-permissions mode is active, not a per-tool approval regression" ;;
  *) fail "the real Claude session's status line no longer shows bypass-permissions mode active (capture: $CAPTURE)" ;;
esac
