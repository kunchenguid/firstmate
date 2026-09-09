#!/usr/bin/env bash
# Opt-in credentialed Codex regression proving a Codex session nested under a
# foreign harness still receives Codex's bounded foreground-checkpoint path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_LIVE_E2E codex

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

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
printf 'task=codex-nested-harness-live-e2e\n' > "$HOME_DIR/state/in-flight.meta"
PROMPT='Reply briefly without using tools.'

(
  cd "$PROJECT" || exit 1
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed \
    FM_CODEX_WATCH_CHECKPOINT=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    "$PROMPT"
) > "$TRANSCRIPT" 2>&1 || fail "nested Codex credentialed checkpoint turn failed: $(tail -20 "$TRANSCRIPT")"

grep -F 'checkpoint: no actionable wake within 1s' "$TRANSCRIPT" >/dev/null \
  || fail "Codex transcript omitted the real foreground checkpoint result"
if grep -F 'watcher: started pid=' "$TRANSCRIPT" >/dev/null; then
  fail "Codex switched to the background arm path"
fi
if grep -F 'fm_watch_arm_pi' "$TRANSCRIPT" >/dev/null; then
  fail "Codex inherited Pi's extension repair path"
fi

printf 'ok - %s nested-harness live E2E selected the one-second Codex foreground checkpoint path\n' "$CODEX_VERSION"
