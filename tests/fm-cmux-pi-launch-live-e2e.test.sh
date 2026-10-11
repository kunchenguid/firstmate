#!/usr/bin/env bash
# Real Pi plus cmux launch-confirmation guard.
# Run explicitly with FM_CMUX_PI_LAUNCH_LIVE=1 from a process that can access
# cmux's socket.
# The test creates one exact fm-test- workspace through the normal scout path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TASK="test-cmux-pi-launch-$$"
LABEL="fm-$TASK"
LAB=
WORKSPACE_ID=
SURFACE_ID=

cleanup() {
  local wsid=$WORKSPACE_ID
  [ -n "$LAB" ] || return 0
  FM_HOME="$LAB"
  export FM_HOME
  if [ -n "$wsid" ] && [ -n "$SURFACE_ID" ]; then
    # shellcheck source=tests/cmux-test-safety.sh
    . "$ROOT/tests/cmux-test-safety.sh"
    if ! cmux_safe_close_workspace "$wsid:$SURFACE_ID" "$LABEL"; then
      printf 'cmux Pi cleanup could not confirm closure; lab preserved at %s\n' "$LAB" >&2
      return 1
    fi
  fi
  printf 'cmux Pi lab preserved at %s\n' "$LAB" >&2
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fm_live_gate opt-in FM_CMUX_PI_LAUNCH_LIVE jq treehouse pi python3
# shellcheck source=bin/backends/cmux.sh
. "$ROOT/bin/backends/cmux.sh"
ping_out=$(fm_backend_cmux_cli ping 2>&1) \
  || fail "FM_CMUX_PI_LAUNCH_LIVE=1 but the cmux socket is unavailable: $ping_out"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-cmux-pi-launch.XXXXXX") \
  || fail "could not create an isolated cmux Pi lab"
mkdir -p "$LAB/config" "$LAB/data/$TASK" "$LAB/projects/probe" "$LAB/state"
printf '%s\n' cmux > "$LAB/config/backend"
printf '%s\n' manual > "$LAB/config/backlog-backend"
touch "$LAB/state/.last-watcher-beat"

git -C "$LAB/projects/probe" init -q -b main \
  || fail "could not initialize the isolated probe repository"
git -C "$LAB/projects/probe" config user.email 'cmux-pi-test@example.invalid'
git -C "$LAB/projects/probe" config user.name 'cmux Pi test'
printf '%s\n' 'cmux Pi launch probe' > "$LAB/projects/probe/README.md"
git -C "$LAB/projects/probe" add README.md
git -C "$LAB/projects/probe" commit -qm 'fixture: initialize cmux Pi launch probe'

FM_HOME="$LAB" "$ROOT/bin/fm-brief.sh" "$TASK" probe --scout \
  || fail "could not scaffold the Pi probe brief"
python3 - "$LAB/data/$TASK/brief.md" "$LAB/data/$TASK/report.md" <<'PY'
from pathlib import Path
import sys

brief = Path(sys.argv[1])
report = sys.argv[2]
brief.write_text(brief.read_text().replace("{TASK}", f'''Run a cmux Pi launch probe.

Write exactly `cmux Pi launch probe passed` followed by a newline to `{report}`.
Then append `done [at=<epoch>]: cmux Pi launch probe passed` to the task status file as the instructions require.
Do not change project files or make a commit.''').replace(
    "{FIRSTMATE_SPEC}", "Complete only the launch probe described above."
))
PY

FM_HOME="$LAB" "$ROOT/bin/fm-spawn.sh" "$TASK" "$LAB/projects/probe" \
  --scout --harness pi --backend cmux \
  || fail "the real Pi cmux spawn did not confirm that Pi began processing its launch brief"
assert_present "$LAB/state/$TASK.meta" "confirmed real Pi spawn did not publish metadata"
WORKSPACE_ID=$(sed -n 's/^cmux_workspace_id=//p' "$LAB/state/$TASK.meta" | head -1)
[ -n "$WORKSPACE_ID" ] || fail "confirmed real Pi spawn did not record its exact cmux workspace"
SURFACE_ID=$(sed -n 's/^cmux_surface_id=//p' "$LAB/state/$TASK.meta" | head -1)
[ -n "$SURFACE_ID" ] || fail "confirmed real Pi spawn did not record its exact cmux surface"

for _ in $(seq 1 60); do
  grep -Eq '^done( \[at=[0-9]+\])?: cmux Pi launch probe passed$' "$LAB/state/$TASK.status" 2>/dev/null && break
  sleep 1
done
assert_grep 'done' "$LAB/state/$TASK.status" \
  "real Pi did not complete the launch probe after spawn confirmation"
[ "$(cat "$LAB/data/$TASK/report.md" 2>/dev/null)" = 'cmux Pi launch probe passed' ] \
  || fail "real Pi did not process the probe instructions"
if ! cleanup; then
  trap - EXIT INT TERM
  exit 1
fi
trap - EXIT INT TERM
pass "a real cmux Pi scout reports processing the launch brief before fm-spawn returns success"
