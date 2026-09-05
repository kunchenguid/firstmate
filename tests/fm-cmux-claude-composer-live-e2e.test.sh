#!/usr/bin/env bash
# Real Claude Code plus cmux submit-confirmation drift guard.
# Run explicitly with FM_CMUX_CLAUDE_COMPOSER_LIVE=1; it creates and cleans up
# only one exact fm-test- workspace through the normal scout lifecycle.
set -u

# Isolate from the ambient fleet environment before anything else runs. This
# suite does not source tests/lib.sh - it owns its own reporters, ROOT and EXIT
# trap - so it calls the shared owner directly. bin/fm-test-env-lib.sh owns the
# pointer list; this is a caller, never a second copy of it.
# shellcheck source=bin/fm-test-env-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-test-env-lib.sh"
fm_test_env_isolate || exit 2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK="fm-test-cmux-claude-composer-$$"
LAB=
SPAWNED=0

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup() {
  [ "$SPAWNED" -eq 0 ] || {
    mkdir -p "$LAB/data/$TASK"
    : > "$LAB/data/$TASK/report.md"
    if grep -q '^needs-decision \[key=probe-decision\]' "$LAB/state/$TASK.status" 2>/dev/null \
      && ! grep -q '^resolved \[key=probe-decision\]' "$LAB/state/$TASK.status" 2>/dev/null; then
      printf '%s\n' 'resolved [key=probe-decision]: live guard cleanup' >> "$LAB/state/$TASK.status"
    fi
    FM_HOME="$LAB" "$ROOT/bin/fm-decision-hold.sh" complete "$TASK" --none >/dev/null 2>&1 || true
    FM_HOME="$LAB" "$ROOT/bin/fm-teardown.sh" "$TASK" >/dev/null 2>&1 || true
  }
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

if [ "${FM_CMUX_CLAUDE_COMPOSER_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_CMUX_CLAUDE_COMPOSER_LIVE=1 to run the real cmux Claude composer drift guard"
  exit 0
fi

command -v claude >/dev/null 2>&1 || fail "FM_CMUX_CLAUDE_COMPOSER_LIVE=1 but Claude Code is not installed"
command -v cmux >/dev/null 2>&1 || fail "FM_CMUX_CLAUDE_COMPOSER_LIVE=1 but cmux is not installed"
command -v jq >/dev/null 2>&1 || fail "FM_CMUX_CLAUDE_COMPOSER_LIVE=1 but jq is not installed"
command -v treehouse >/dev/null 2>&1 || fail "FM_CMUX_CLAUDE_COMPOSER_LIVE=1 but treehouse is not installed"
command -v python3 >/dev/null 2>&1 || fail "FM_CMUX_CLAUDE_COMPOSER_LIVE=1 but python3 is not installed"
cmux ping >/dev/null 2>&1 || fail "FM_CMUX_CLAUDE_COMPOSER_LIVE=1 but the cmux socket is unavailable"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-cmux-claude-composer.XXXXXX") || fail "could not create an isolated cmux Claude lab"
trap cleanup EXIT
mkdir -p "$LAB/config" "$LAB/data/$TASK" "$LAB/projects/comms" "$LAB/state"
printf 'cmux\n' > "$LAB/config/backend"

git -C "$LAB/projects/comms" init -q -b main || fail "could not initialize the isolated probe repository"
git -C "$LAB/projects/comms" config user.email 'cmux-composer-test@example.invalid'
git -C "$LAB/projects/comms" config user.name 'cmux composer test'
printf 'cmux Claude composer probe\n' > "$LAB/projects/comms/README.md"
git -C "$LAB/projects/comms" add README.md
git -C "$LAB/projects/comms" commit -qm 'fixture: initialize cmux Claude composer probe'

STATUS="$LAB/state/$TASK.status"
FM_HOME="$LAB" "$ROOT/bin/fm-brief.sh" "$TASK" comms --scout || fail "could not scaffold the Claude probe brief"
python3 - "$LAB/data/$TASK/brief.md" "$STATUS" <<'PY'
from pathlib import Path
import sys

brief = Path(sys.argv[1])
status = sys.argv[2]
brief.write_text(brief.read_text().replace("{TASK}", f'''Run a cmux communication probe.

Immediately append `working: cmux composer probe ready` to `{status}`.
Then append exactly `needs-decision [key=probe-decision]: awaiting codeword` to that file and stop to wait for a firstmate message.
When you receive a firstmate message containing `ALBATROSS`, append `done: received ALBATROSS` to that status file and stop.
Do not change project files or make a commit.'''))
PY

FM_HOME="$LAB" "$ROOT/bin/fm-spawn.sh" "$TASK" "$LAB/projects/comms" --scout --harness claude --model haiku --backend cmux \
  || fail "could not launch the real Claude cmux probe"
SPAWNED=1

# shellcheck source=bin/fm-backend.sh
FM_HOME="$LAB"
export FM_HOME
. "$ROOT/bin/fm-backend.sh"
fm_backend_source cmux || fail "could not source the cmux adapter"
TARGET=$(awk -F= '/^window=/{print $2}' "$LAB/state/$TASK.meta")
[ -n "$TARGET" ] || fail "the cmux probe did not record its endpoint"

for _ in $(seq 1 45); do
  CAPTURE=$(fm_backend_cmux_capture "$TARGET" 200 "$TASK" 2>/dev/null || true)
  case "$CAPTURE" in
    *'Yes, I trust this folder'*) FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" "$TASK" --key Enter || fail "could not accept Claude's folder-trust prompt" ;;
  esac
  grep -q '^needs-decision \[key=probe-decision\]' "$STATUS" 2>/dev/null && break
  sleep 2
done
grep -q '^needs-decision \[key=probe-decision\]' "$STATUS" 2>/dev/null \
  || fail "Claude $(claude --version) did not reach the communication decision"

COMPOSER=$(fm_backend_cmux_composer_state "$TARGET" "$TASK")
[ "$COMPOSER" = empty ] || fail "cmux classified the real Claude $(claude --version) idle composer as '$COMPOSER'"
pass "cmux classifies the real Claude borderless composer as empty"

FM_SEND_SETTLE=0 FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key probe-decision ALBATROSS \
  || fail "cmux did not confirm the real Claude steer"
for _ in $(seq 1 30); do
  grep -q '^done: received ALBATROSS' "$STATUS" 2>/dev/null && break
  sleep 2
done
grep -q '^resolved \[key=probe-decision\]: answered: ALBATROSS' "$STATUS" \
  || fail "confirmed cmux delivery did not close the keyed decision"
grep -q '^done: received ALBATROSS' "$STATUS" \
  || fail "the real Claude worker did not complete after the confirmed steer"

CAPTURE=$(fm_backend_cmux_capture "$TARGET" 200 "$TASK")
COUNT=$(printf '%s\n' "$CAPTURE" | grep -cF '❯ ALBATROSS' || true)
[ "$COUNT" -eq 1 ] || fail "expected exactly one submitted ALBATROSS steer, found $COUNT"
pass "cmux confirms one steer, closes the keyed decision, and leaves no duplicate"
