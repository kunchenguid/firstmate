#!/usr/bin/env bash
# Opt-in credentialed Pi/Herdr proof for Calm's real-model current-step presentation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CALM_PI_REAL_MODEL_E2E herdr jq pi python3

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name calm-real-model-pane)
TMP_ROOT=$(fm_test_tmproot fm-calm-pi-real-model-live-e2e)
PROJECT="$TMP_ROOT/project"
HOME_DIR="$TMP_ROOT/home"
SESSIONS="$TMP_ROOT/sessions"
EVIDENCE="$TMP_ROOT/evidence"
PANE=

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$HERDR_LAB_SESSION" ]; then
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || rc=1
  fi
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab session"

mkdir -p "$PROJECT" "$HOME_DIR/config" "$SESSIONS" "$EVIDENCE"
printf 'on\n' >"$HOME_DIR/config/calm"
printf 'alpha probe\n' >"$PROJECT/.calm-probe-a"
printf 'beta probe\n' >"$PROJECT/.calm-probe-b"
printf 'gamma probe\n' >"$PROJECT/.calm-probe-c"
printf 'REAL_MODEL_FINAL_RESPONSE\n' >"$PROJECT/.calm-final"

pi auth check --provider openai-codex --model gpt-5.6-sol --json >/dev/null 2>&1 \
  || fail "the existing user Pi configuration is not authenticated for openai-codex/gpt-5.6-sol"

OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create \
  --cwd "$PROJECT" --label calm-real-model --no-focus)
PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id')
PI_CMD=$(printf 'env FM_HOME=%q pi --approve --no-context-files --no-extensions -e %q -e %q -e %q -e %q --model openai-codex/gpt-5.6-sol --thinking xhigh --session-dir %q' \
  "$HOME_DIR" \
  "$ROOT/.pi/extensions/fm-branch-supervision.ts" \
  "$ROOT/.pi/extensions/fm-calm.ts" \
  "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" \
  "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" \
  "$SESSIONS")
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PANE" "$PI_CMD" >/dev/null \
  || fail "could not launch authenticated Pi in the isolated Herdr pane"

pane_text() {
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$PANE" \
    --source recent --lines 160 2>/dev/null || true
}

ready=0
for _ in $(seq 1 300); do
  text=$(pane_text)
  if printf '%s' "$text" | grep -Fq '(openai-codex) gpt-5.6-sol'; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" -eq 1 ] || { printf '%s\n' "$text" >&2; fail "authenticated Pi did not reach its ready composer"; }

PROMPT='Read .calm-probe-a, then .calm-probe-b, then .calm-probe-c, one call at a time. Narrate a new plan before each. Then read .calm-final and reply with its exact content.'
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" "$PROMPT" >/dev/null
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" enter >/dev/null

seen_step_numbers=
settled_polls=0
final_text=
frame=0
for _ in $(seq 1 1200); do
  text=$(pane_text)
  frame=$((frame + 1))
  printf '%s\n' "$text" >"$EVIDENCE/frame-$frame.txt"
  step_count=$( (printf '%s\n' "$text" | grep -Eo 'Step [0-9]+:' || true) | wc -l | tr -d ' ')
  if [ "$step_count" -gt 1 ]; then
    printf '%s\n' "$text" >&2
    fail "external pane frame $frame accumulated $step_count numbered step rows"
  fi
  step_line=$(printf '%s\n' "$text" | grep -E 'Step [0-9]+:' | tail -1 || true)
  if [ -n "$step_line" ]; then
    step_number=$(printf '%s\n' "$step_line" | sed -E 's/.*Step ([0-9]+):.*/\1/')
    if ! printf '%s\n' "$seen_step_numbers" | grep -Fxq "$step_number"; then
      seen_step_numbers=$(printf '%s\n%s' "$seen_step_numbers" "$step_number")
      printf 'proof - working Step %s: %s\n' "$step_number" "$step_line"
    fi
  fi
  if printf '%s' "$text" | grep -Fq 'REAL_MODEL_FINAL_RESPONSE' && [ "$step_count" -eq 0 ]; then
    settled_polls=$((settled_polls + 1))
    final_text=$text
    [ "$settled_polls" -ge 3 ] && break
  else
    settled_polls=0
  fi
  sleep 0.1
done
[ "$settled_polls" -ge 3 ] || { printf '%s\n' "$text" >&2; fail "real model did not settle to a final response without a step row"; }
unique_steps=$(printf '%s\n' "$seen_step_numbers" | grep -Ec '^[0-9]+$' || true)
[ "$unique_steps" -ge 2 ] \
  || fail "external pane observed only $unique_steps distinct numbered steps"

session_file=$(find "$SESSIONS" -type f -name '*.jsonl' \
  -exec grep -l 'REAL_MODEL_FINAL_RESPONSE' {} + 2>/dev/null | head -1)
[ -n "$session_file" ] || fail "real Pi did not persist the authenticated model session"
grep -Fq '.calm-probe-a' "$session_file" || fail "first real-model tool turn was not persisted"
grep -Fq '.calm-probe-b' "$session_file" || fail "second real-model tool turn was not persisted"
grep -Fq '.calm-probe-c' "$session_file" || fail "third real-model tool turn was not persisted"

printf 'proof - final: %s\n' "$(printf '%s\n' "$final_text" | grep -F 'REAL_MODEL_FINAL_RESPONSE' | tail -1)"
printf 'ok - real Pi %s with gpt-5.6-sol xhigh and the full Firstmate extension set exposed one externally read numbered step at a time across %s steps, then no step row after the final response\n' \
  "$(pi --version)" "$unique_steps"
