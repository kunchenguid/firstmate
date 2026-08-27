#!/usr/bin/env bash
# Opt-in credentialed Codex regression proving the continuity path and max
# reasoning-effort launch configuration against the real installed harness.
set -u

if [ "${FM_CODEX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVE_E2E=1 to run the Codex continuity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail "codex not found"

LAB="$ROOT/.codex-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/codex.jsonl"
CODEX_VERSION=$(codex --version)
VERIFIED_CODEX_VERSION="codex-cli 0.149.1"

[ "$CODEX_VERSION" = "$VERIFIED_CODEX_VERSION" ] \
  || fail "unverified Codex version: $CODEX_VERSION (expected $VERIFIED_CODEX_VERSION)"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
PROMPT='Run exactly `bin/fm-watch-checkpoint.sh --seconds 1` as one foreground shell call. Do not use a background task and do not run fm-watch-arm.sh. After the checkpoint returns, reply briefly.'

(
  cd "$PROJECT" || exit 1
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model="gpt-5.6-sol"' \
    -c 'model_reasoning_effort="max"' \
    --json \
    "$PROMPT"
) > "$TRANSCRIPT" 2>&1 || fail "Codex credentialed checkpoint turn failed: $(tail -20 "$TRANSCRIPT")"

THREAD_ID=$(jq -Rr 'fromjson? | select(.type == "thread.started") | .thread_id' "$TRANSCRIPT" | head -1)
[ -n "$THREAD_ID" ] || fail "Codex $CODEX_VERSION transcript omitted the session id"
SESSION_FILE=$(find "${CODEX_HOME:-$HOME/.codex}/sessions" -type f -name "*-$THREAD_ID.jsonl" -print -quit 2>/dev/null)
[ -n "$SESSION_FILE" ] || fail "Codex $CODEX_VERSION omitted persisted metadata for session $THREAD_ID"
jq -e --arg model "gpt-5.6-sol" --arg effort "max" \
  'select(.type == "turn_context" and .payload.model == $model and .payload.effort == $effort)' \
  "$SESSION_FILE" >/dev/null \
  || fail "Codex $CODEX_VERSION session metadata did not select gpt-5.6-sol max"

grep -F 'checkpoint: no actionable wake within 1s' "$TRANSCRIPT" >/dev/null \
  || fail "Codex transcript omitted the real foreground checkpoint result"
if grep -F 'watcher: started pid=' "$TRANSCRIPT" >/dev/null; then
  fail "Codex switched to the background arm path"
fi

printf 'ok - %s live E2E selected max and preserved the one-second foreground checkpoint path\n' "$CODEX_VERSION"
