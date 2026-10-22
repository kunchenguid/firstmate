#!/usr/bin/env bash
# Real Claude Code plus Rex end-to-end guard, run on a private Rex lab server.
# Run explicitly with FM_REX_CLAUDE_LIVE=1 (it submits prompts). It spawns one
# scout through the normal lifecycle with config/backend=rex in a lab home,
# proves the agent alive, steers it with fm-send --resolve-key past a keyed
# decision, checks the idle composer reads empty, the steer landed once, and the composer is empty again,
# then tears it down and proves the endpoint gone. It also reports which
# program states (OSC 7501) Claude published, as evidence only.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK="fm-test-rex-claude-$$"
LAB=
REX_LAB=
SPAWNED=0
LAB_HELPER="$ROOT/bin/fm-rex-lab.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

untimed_status() { sed -E 's/ \[at=[0-9]+\]//g' "$1" 2>/dev/null; }

cleanup() {
  [ "$SPAWNED" -eq 0 ] || {
    mkdir -p "$LAB/data/$TASK"
    : > "$LAB/data/$TASK/report.md"
    if untimed_status "$LAB/state/$TASK.status" | grep -q '^needs-decision \[key=probe-decision\]' \
      && ! untimed_status "$LAB/state/$TASK.status" | grep -q '^resolved \[key=probe-decision\]'; then
      printf '%s\n' 'resolved [key=probe-decision]: live guard cleanup' >> "$LAB/state/$TASK.status"
    fi
    FM_HOME="$LAB" "$ROOT/bin/fm-decision-hold.sh" complete "$TASK" --none >/dev/null 2>&1 || true
    FM_HOME="$LAB" "$ROOT/bin/fm-teardown.sh" "$TASK" >/dev/null 2>&1 || true
  }
  [ -z "$REX_LAB" ] || "$LAB_HELPER" teardown "$REX_LAB" || printf 'not ok - the Rex lab teardown or its live-server tripwire failed\n' >&2
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fm_live_gate opt-in FM_REX_CLAUDE_LIVE claude rex jq treehouse python3

unset TMUX HERDR_ENV REX_SESSION REX_BLOCK REX_SERVER REX_CLIENT FM_BACKEND_REX_SERVER 2>/dev/null || true
VERSIONS="claude $(claude --version 2>/dev/null | head -1); $(rex version 2>/dev/null | head -1)"

trap cleanup EXIT
REX_LAB=$("$LAB_HELPER" name rexclaude)
"$LAB_HELPER" provision "$REX_LAB" || fail "could not provision a private Rex lab server"
FM_REX_SERVER=$("$LAB_HELPER" server "$REX_LAB")
export FM_REX_SERVER

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-rex-claude.XXXXXX") || fail "could not create an isolated Rex Claude lab home"
mkdir -p "$LAB/config" "$LAB/data/$TASK" "$LAB/projects/comms" "$LAB/state"
printf 'rex\n' > "$LAB/config/backend"

git -C "$LAB/projects/comms" init -q -b main || fail "could not initialize the isolated probe repository"
git -C "$LAB/projects/comms" config user.email 'rex-claude-test@example.invalid'
git -C "$LAB/projects/comms" config user.name 'rex claude test'
printf 'Rex Claude probe\n' > "$LAB/projects/comms/README.md"
git -C "$LAB/projects/comms" add README.md
git -C "$LAB/projects/comms" commit -qm 'fixture: initialize Rex Claude probe'

STATUS="$LAB/state/$TASK.status"
FM_HOME="$LAB" "$ROOT/bin/fm-brief.sh" "$TASK" comms --scout || fail "could not scaffold the Claude probe brief"
python3 - "$LAB/data/$TASK/brief.md" "$STATUS" <<'PY'
from pathlib import Path
import sys

brief = Path(sys.argv[1])
status = sys.argv[2]
brief.write_text(brief.read_text().replace("{TASK}", f'''Run a Rex communication probe.

Immediately append `working [at=<epoch>]: rex probe ready` to `{status}`, substituting `<epoch>` as rule 4 instructs.
Then append exactly `needs-decision [at=<epoch>] [key=probe-decision]: awaiting codeword` to that file and stop to wait for a firstmate message.
When you receive a firstmate message containing `ALBATROSS`, append `done [at=<epoch>]: received ALBATROSS` to that status file and stop.
Do not change project files or make a commit.''').replace("{FIRSTMATE_SPEC}", "Nothing beyond the steps above."))
PY

FM_HOME="$LAB" "$ROOT/bin/fm-spawn.sh" "$TASK" "$LAB/projects/comms" --scout --harness claude --model haiku \
  || fail "could not launch the real Claude Rex probe ($VERSIONS)"
SPAWNED=1
grep -qx 'backend=rex' "$LAB/state/$TASK.meta" || fail "config/backend=rex did not record backend=rex"
grep -qx "rex_server=$FM_REX_SERVER" "$LAB/state/$TASK.meta" || fail "the task did not record the lab server"

FM_HOME="$LAB"
export FM_HOME
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source rex || fail "could not source the rex adapter"
TARGET=$(awk -F= '/^window=/{print $2}' "$LAB/state/$TASK.meta")
[ -n "$TARGET" ] || fail "the Rex probe did not record its endpoint"
LABEL="fm-$TASK"

STATES=
note_program_status() {
  local s
  s=$(fm_backend_rex_block_call "$TARGET" program_status 2>/dev/null \
    | jq -r '[.. | objects | select(has("state")) | .state] | unique | join(",")' 2>/dev/null)
  [ -z "$s" ] || STATES="$STATES,$s"
}

for _ in $(seq 1 60); do
  CAPTURE=$(fm_backend_rex_capture "$TARGET" 200 "$LABEL" 2>/dev/null || true)
  case "$CAPTURE" in
    *'Yes, I trust this folder'*) FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" "$TASK" --key Enter || fail "could not accept Claude's folder-trust prompt" ;;
  esac
  note_program_status
  untimed_status "$STATUS" | grep -q '^needs-decision \[key=probe-decision\]' && break
  sleep 2
done
untimed_status "$STATUS" | grep -q '^needs-decision \[key=probe-decision\]' \
  || fail "Claude did not reach the communication decision ($VERSIONS)"

STATE=$(fm_backend_agent_state rex "$TARGET")
[ "$STATE" = alive ] || fail "the live Claude worker read '$STATE', expected alive ($VERSIONS)"
pass "rex agent_state reads the real Claude worker as alive"

COMPOSER=
for _ in $(seq 1 10); do
  COMPOSER=$(fm_backend_rex_composer_state "$TARGET" "$LABEL")
  [ "$COMPOSER" = empty ] && break
  sleep 1
done
[ "$COMPOSER" = empty ] || {
  fm_backend_rex_composer_capture "$TARGET" "$LABEL" | tail -n 12 | sed 's/\x1b\[[0-9;]*m//g; s/^/# /' >&2
  fail "rex classified the real Claude idle composer as '$COMPOSER' ($VERSIONS)"
}
pass "rex classifies the real Claude idle composer as empty"

FM_SEND_SETTLE=0 FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key probe-decision ALBATROSS \
  || fail "rex did not confirm the real Claude steer ($VERSIONS)"
for _ in $(seq 1 45); do
  note_program_status
  untimed_status "$STATUS" | grep -q '^done: received ALBATROSS' && break
  sleep 2
done
untimed_status "$STATUS" | grep -q '^resolved \[key=probe-decision\]: answered: ALBATROSS' \
  || fail "confirmed rex delivery did not close the keyed decision"
untimed_status "$STATUS" | grep -q '^done: received ALBATROSS' \
  || fail "the real Claude worker did not complete after the confirmed steer ($VERSIONS)"

# Steers ride the durable inbox (bin/fm-task-inbox-lib.sh): the pane only ever
# receives the constant doorbell, so the text is counted in the inbox records.
COUNT=$(grep -lF ALBATROSS "$LAB/state/$TASK.inbox"/*.msg "$LAB/state/$TASK.inbox"/handled/*.msg 2>/dev/null | wc -l | tr -d ' ')
[ "$COUNT" -eq 1 ] || fail "expected exactly one ALBATROSS inbox record, found $COUNT ($VERSIONS)"
COMPOSER=$(fm_backend_rex_composer_state "$TARGET" "$LABEL")
[ "$COMPOSER" = empty ] || fail "the doorbell left the real Claude composer '$COMPOSER' after the steer ($VERSIONS)"
pass "rex confirms one steer, closes the keyed decision, and leaves the composer empty"

mkdir -p "$LAB/data/$TASK"
: > "$LAB/data/$TASK/report.md"
FM_HOME="$LAB" "$ROOT/bin/fm-decision-hold.sh" complete "$TASK" --none >/dev/null 2>&1 || true
FM_HOME="$LAB" "$ROOT/bin/fm-teardown.sh" "$TASK" || fail "teardown of the Rex probe failed ($VERSIONS)"
SPAWNED=0
fm_backend_rex_cli block inspect "block:${TARGET#*:}" --json >/dev/null 2>&1
[ "$?" -eq 3 ] || fail "the torn-down Rex block still answers ($VERSIONS)"
pass "rex teardown closes the worker's block and proves it gone"

printf 'info - Claude program states observed on Rex: %s (%s)\n' "$(printf '%s' "${STATES#,}" | tr ',' '\n' | sort -u | paste -sd, -)" "$VERSIONS"
