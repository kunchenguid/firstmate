#!/usr/bin/env bash
# Opt-in live guard for Cursor Agent on the real Herdr backend.
# Usage: FM_CURSOR_HERDR_LIVE=1 bin/fm-test-run.sh tests/fm-cursor-herdr-live-e2e.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() { printf 'ok - %s\n' "$1"; }

LIVE_FLAG=$(printenv FM_CURSOR_HERDR_LIVE || true)
if [ "$LIVE_FLAG" != 1 ]; then
  echo "skip: set FM_CURSOR_HERDR_LIVE=1 to run live Cursor+Herdr checks"
  exit 0
fi

for command_name in cursor-agent herdr jq treehouse; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "$command_name is required for the live Cursor+Herdr guard"
done

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMPDIR_VALUE=$(printenv TMPDIR || printf '/tmp')
TMP_ROOT=$(mktemp -d "$TMPDIR_VALUE/fm-cursor-herdr-live.XXXXXX")
SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name fm-cursor-herdr) \
  || fail "could not create an isolated Herdr lab session name"
ID=fm-cursor-herdr-live
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
META="$HOME_DIR/state/$ID.meta"

cleanup() {
  if [ -f "$META" ]; then
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      HERDR_SESSION="$SESSION" "$ROOT/bin/fm-teardown.sh" "$ID" --force \
      >/dev/null 2>&1 || true
  fi
  "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$ID" "$HOME_DIR/projects" \
  "$HOME_DIR/config" "$PROJECT"
printf 'Reply with exactly HERDRCURSORREADY.\n' > "$HOME_DIR/data/$ID/brief.md"
git -C "$PROJECT" init -q
printf '# Cursor Herdr live test\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name='Firstmate Tests' \
  -c user.email='tests@example.invalid' commit -qm initial

HERDR_SESSION="$SESSION" "$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION" \
  || fail "could not provision isolated Herdr lab session"

FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" \
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout --harness cursor \
  --backend herdr >/dev/null 2>"$TMP_ROOT/spawn.err" \
  || fail "Cursor Agent Herdr spawn failed"$'\n'"$(cat "$TMP_ROOT/spawn.err")"

PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
[ -n "$PANE" ] || fail "spawn metadata did not record a Herdr pane"

lab() { "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "$@"; }
wait_for_output() {
  local needle=$1 output
  for _ in $(seq 1 60); do
    output=$(lab pane read "$PANE" 2>/dev/null || true)
    if printf '%s' "$output" | grep -F "$needle" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}
wait_for_output HERDRCURSORREADY \
  || fail "Cursor Agent did not produce the Herdr launch response"

FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  HERDR_SESSION="$SESSION" FM_SEND_SETTLE=0 \
  "$ROOT/bin/fm-send.sh" "$ID" \
  "Reply with exactly HERDRCURSORSEND." >/dev/null 2>"$TMP_ROOT/send.err" \
  || fail "Cursor Agent Herdr send failed"$'\n'"$(cat "$TMP_ROOT/send.err")"

wait_for_output HERDRCURSORSEND \
  || fail "Cursor Agent did not receive the Herdr delivery"

VERSION=$(cursor-agent --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || fail "cursor-agent --version produced no output"
pass "live Cursor+Herdr spawn/send verified on $VERSION"
