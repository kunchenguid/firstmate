#!/usr/bin/env bash
# Opt-in credentialed Codex regression proving that an active primary cannot
# end blind after a bounded foreground checkpoint releases its watcher lock.
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

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'synthetic active task\n' > "$HOME_DIR/state/task.meta"
# Keep supervision needed through two Stop-hook attempts.
# The third turn removes the synthetic task only after the second hook feedback,
# so the run proves that a stop_hook_active=true continuation is re-blocked.
PROMPT="Run exactly \`bin/fm-watch-checkpoint.sh --seconds 1\` as one foreground shell call. Do not use a background task and do not run fm-watch-arm.sh. Then reply with exactly FIRST_CHECKPOINT_DONE and stop. If Stop-hook feedback creates a first follow-up turn, reply with exactly SECOND_STOP_DONE and stop without running any command. If a second Stop-hook feedback creates another follow-up turn, run exactly \`rm -f '$HOME_DIR/state/task.meta'\`, reply with exactly THIRD_SUPERVISION_RELEASED, and stop."

(
  cd "$PROJECT" || exit 1
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    "$PROMPT"
) > "$TRANSCRIPT" 2>&1 || fail "Codex credentialed checkpoint turn failed: $(tail -20 "$TRANSCRIPT")"

grep -F 'checkpoint: no actionable wake within 1s' "$TRANSCRIPT" >/dev/null \
  || fail "Codex transcript omitted the real foreground checkpoint result"
if grep -F 'watcher: started pid=' "$TRANSCRIPT" >/dev/null; then
  fail "Codex switched to the background arm path"
fi
grep -F 'FIRST_CHECKPOINT_DONE' "$TRANSCRIPT" >/dev/null \
  || fail "Codex did not complete the initial foreground checkpoint turn"
grep -F 'SECOND_STOP_DONE' "$TRANSCRIPT" >/dev/null \
  || fail "Codex did not receive the first Stop-hook continuation"
grep -F 'THIRD_SUPERVISION_RELEASED' "$TRANSCRIPT" >/dev/null \
  || fail "Codex let a stop_hook_active=true turn end without the required second continuation"

printf 'ok - %s live E2E re-blocked the foreground-checkpoint continuation until supervision was released\n' "$CODEX_VERSION"
