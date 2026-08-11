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

for command_name in cursor-agent herdr jq; do
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

cleanup() {
  "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR" "$PROJECT"
git -C "$PROJECT" init -q
printf '# Cursor Herdr live test\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name='Firstmate Tests' \
  -c user.email='tests@example.invalid' commit -qm initial

HERDR_SESSION="$SESSION" "$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION" \
  || fail "could not provision isolated Herdr lab session"

lab() { "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "$@"; }
CREATE=$(lab workspace create --cwd "$PROJECT" --label "$ID" --no-focus) \
  || fail "could not create an isolated Herdr evidence workspace"
PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') \
  || fail "could not resolve the isolated Herdr evidence pane"
TARGET="$SESSION:$PANE"

FM_HOME=$HOME_DIR
FM_ROOT_OVERRIDE=$ROOT
export FM_HOME FM_ROOT_OVERRIDE
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "could not load the Herdr backend adapter"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

CURSOR_BIN=$(command -v cursor-agent)
LAUNCH="env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT $(shell_quote "$CURSOR_BIN") --yolo --trust $(shell_quote 'Reply only: HERDRCURSORREADY')"
fm_backend_herdr_send_text_line "$TARGET" "$LAUNCH" \
  || fail "could not launch Cursor Agent in the isolated Herdr evidence pane"

wait_for_exact_response() {
  local expected=$1 output
  for _ in $(seq 1 60); do
    output=$(lab pane read "$PANE" 2>/dev/null || true)
    if printf '%s\n' "$output" \
      | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
      | grep -Fx "$expected" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  printf '%s\n' "$output" >&2
  return 1
}
wait_for_exact_response HERDRCURSORREADY \
  || fail "Cursor Agent did not produce the Herdr launch response"

verdict=$(FM_COMPOSER_IDLE_RE='^(Type a message\.\.\.|Add a follow-up)$' \
  FM_BACKEND_HERDR_IDLE_RE='^(Type a message\.\.\.|Add a follow-up)$' \
  fm_backend_send_text_submit herdr "$TARGET" "Reply only: HERDRCURSORSEND" \
  3 0.4 0.3 '' cursor)
[ "$verdict" = empty ] \
  || fail "Cursor Agent Herdr evidence delivery was not confirmed: $verdict"

wait_for_exact_response HERDRCURSORSEND \
  || fail "Cursor Agent did not receive the Herdr delivery"

VERSION=$(cursor-agent --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || fail "cursor-agent --version produced no output"
pass "live Cursor+Herdr evidence passed on $VERSION"
