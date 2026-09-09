#!/usr/bin/env bash
# tests/fm-crew-remote-control-live-e2e.test.sh - opt-in drift guard proving the
# INSTALLED claude still advertises `--remote-control`, and that firstmate
# therefore still types it onto a claude crewmate launch.
#
# Why this file exists: whether the flag is typed is decided by claude's own
# rendered `--help`, a surface the vendor controls and changes without notice,
# and claude refuses an unknown option outright rather than ignoring it. So the
# capability verdict has two failure directions that only a real claude can
# show: the option disappearing (firstmate would keep typing a fatal flag if it
# read a version table instead) and the help wording drifting far enough that
# the probe stops recognizing an option that is still there (every worker
# silently loses its phone link). A stubbed claude cannot see either; it can
# only confirm the assumption already written into the stub.
#
# The portable counterpart, tests/fm-crew-remote-control.test.sh, pins the
# classifier and every fallback direction in CI with a stub claude.
#
# This guard consumes no model tokens: the only real claude invocation is
# `--help`, and the launch command is captured from a fake tmux instead of being
# run. That is why it is default-on rather than opt-in: it runs wherever claude
# is installed, notably the machine the fleet actually launches workers on, and
# skips on a standard CI host that has no claude binary. Requesting it
# explicitly, with FM_CREW_REMOTE_CONTROL_LIVE=1 or FM_LIVE=1, turns an absent
# claude into a hard failure, which is how "run it after a claude upgrade" keeps
# proving the guard actually ran.
# Run it after any claude upgrade and before trusting the dated evidence in
# docs/verification/remote-control.md.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_CREW_REMOTE_CONTROL_LIVE claude

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-remote-control-live)

# fm_live_gate owns the claude presence decision above. The bounded runner is
# this guard's own additional requirement, and an absent one is reported rather
# than passed over: a guard that checked nothing must not look like a guard that
# checked something.
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 \
  || fail "no bounded runner (timeout or gtimeout) is installed, so fm-spawn cannot probe claude at all"

CLAUDE_BIN=$(command -v claude)
CLAUDE_VERSION=$(claude --version 2>&1 | head -n 1)
printf '# subject: claude %s at %s\n' "$CLAUDE_VERSION" "$CLAUDE_BIN"

HOME_DIR="$TMP_ROOT/home"
PROJ_DIR="$TMP_ROOT/project"
WT_DIR="$TMP_ROOT/wt"
LAUNCH_LOG="$TMP_ROOT/launch.log"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
ID=rc-live-guard

# Only tmux and treehouse are stubbed. claude itself is deliberately the real
# installed binary, which is the entire point of this guard.
fm_test_fake_tmux_spawn "$FAKEBIN"
fm_fake_exit0 "$FAKEBIN" treehouse

fm_test_spawn_home "$HOME_DIR" claude
fm_test_spawn_brief "$HOME_DIR" "$ID"
fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-rc-live"
: > "$LAUNCH_LOG"

# The knob is absent, which is the default every home lands on.
out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
  PATH="$FAKEBIN:$PATH" \
  "$SPAWN" "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1) \
  || fail "fm-spawn failed against the installed claude ($CLAUDE_VERSION)"$'\n'"$out"

LAUNCH=$(cat "$LAUNCH_LOG")
[ -n "$LAUNCH" ] || fail "no launch command was captured, so nothing was checked"

case "$LAUNCH" in
  *"--remote-control '"*)
    NAME=$(printf '%s' "$LAUNCH" | sed -n "s/.*--remote-control '\([^']*\)'.*/\1/p")
    case "$NAME" in
      "$ID".*.*) ;;
      *) fail "claude $CLAUDE_VERSION: the Remote Control session name lost its <task-id>.<home>.<launch-token> shape: '$NAME'" ;;
    esac
    printf '# session name: %s (%s characters)\n' "$NAME" "${#NAME}"
    pass "claude $CLAUDE_VERSION advertises --remote-control and firstmate types it with a per-launch name"
    ;;
  *)
    fail "harness claude, version $CLAUDE_VERSION: firstmate typed NO --remote-control flag. Either this claude no longer advertises the option in its own --help (Remote Control is gone or renamed) or its help wording drifted past the probe in bin/fm-spawn.sh. Launch command was: $LAUNCH"
    ;;
esac

echo "# all fm-crew-remote-control-live-e2e checks passed"
