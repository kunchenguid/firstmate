#!/usr/bin/env bash
# shellcheck disable=SC2016
# Opt-in real Pi proof that unchanged human-owned evidence never starts a second turn.
# Every Herdr operation is scoped through the guarded non-default lab helper.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_HUMAN_NOTIFY_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_HUMAN_NOTIFY_HERDR_E2E=1 to run the real Pi/Herdr one-shot notification proof"
  exit 0
fi
for tool in herdr jq pi; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=${HERDR_LAB_SESSION:-$("$HERDR_LAB_HELPER" name firstmate-one-shot-human-waits-v1)}
TMP_ROOT=$(fm_test_tmproot fm-human-notify-herdr)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
PROJECT="$TMP_ROOT/project"
CAPTURE="$TMP_ROOT/prompts.jsonl"
PANE=

cleanup() {
  local rc=$?
  trap - EXIT
  if ! "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"; then rc=1; fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
mkdir -p "$STATE" "$HOME_DIR/data" "$HOME_DIR/config" "$PROJECT"
: > "$CAPTURE"
printf '# Isolated notification lifecycle proof\n' > "$PROJECT/AGENTS.md"

CAPTURE_EXT="$TMP_ROOT/capture.ts"
cat > "$CAPTURE_EXT" <<'TS'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync, writeFileSync } from "node:fs";
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("session_start", () => writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`));
  pi.on("before_agent_start", (event, ctx) => {
    appendFileSync(process.env.FM_PI_CAPTURE_PATH!, `${JSON.stringify({ prompt: event.prompt })}\n`);
    ctx.abort();
  });
}
TS

OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$PROJECT" --label one-shot-human-waits --no-focus)
PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id')
PI_CMD=$(printf 'exec env FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_PI_CAPTURE_PATH=%q FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 pi -e %q -e %q -e %q --model github-copilot/gpt-5.6-sol --thinking medium --no-context-files --no-session' \
  "$HOME_DIR" "$ROOT" "$CAPTURE" "$CAPTURE_EXT" \
  "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ROOT/.pi/extensions/fm-primary-pi-watch.ts")
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PANE" "$PI_CMD" >/dev/null

wait_for() { # <predicate> <message>
  local predicate=$1 message=$2
  for _ in $(seq 1 240); do
    eval "$predicate" && return 0
    sleep 0.25
  done
  printf 'not ready - %s\n' "$message" >&2
  return 1
}

wait_for '[ -s "$STATE/.pi-watch-extension-loaded" ] && [ -s "$STATE/.pi-turnend-extension-loaded" ]' \
  "tracked Pi extensions did not load" || fail "tracked Pi extensions did not load"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$PANE" '/fm-watch-arm-pi' >/dev/null
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE" enter >/dev/null
wait_for '[ -s "$STATE/.watch.lock/pid" ]' "Pi watcher did not start" || fail "Pi watcher did not start"

printf 'display_name=CRM · API Shape\nbusy_gen=live-proof-1\nkind=ship\nproject=firstmate\n' > "$STATE/proof.meta"
printf 'needs-decision [key=shape]: choose REST or RPC\n' > "$STATE/proof.status"
if ! wait_for '[ "$(wc -l < "$CAPTURE" 2>/dev/null || echo 0)" -eq 1 ]' "the first decision edge did not reach Pi"; then
  find "$STATE" -maxdepth 2 -type f -print -exec sh -c 'echo --- "$1"; tail -20 "$1"' _ {} \; >&2 || true
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$PANE" --source recent --lines 80 --format text >&2 || true
  fail "the first decision edge did not reach Pi"
fi
FIRST=$(jq -r '.prompt' "$CAPTURE")
printf '%s' "$FIRST" | grep -F 'CRM · API Shape' >/dev/null || fail "first Pi notification omitted the readable label"
printf '%s' "$FIRST" | grep -F 'Action required: inspect the private task record and answer the question' >/dev/null || fail "first Pi notification omitted the action"

# Consume the durable wake exactly as a completed handling turn would.
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" \
  > "$TMP_ROOT/drain.out" 2> "$TMP_ROOT/drain.err" || fail "could not present the first wake"
ACK=$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run //p' "$TMP_ROOT/drain.err" | tail -1)
[ -n "$ACK" ] || fail "first wake omitted its acknowledgement"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" bash -c "cd '$ROOT' && $ACK" || fail "could not acknowledge the first wake"

printf 'needs-decision [key=shape]: choose REST or RPC\n' >> "$STATE/proof.status"
sleep 3
[ "$(wc -l < "$CAPTURE")" -eq 1 ] || fail "unchanged decision evidence started another Pi turn"
kill -0 "$(cat "$STATE/.watch.lock/pid")" 2>/dev/null || fail "Pi supervision stopped while absorbing the unchanged condition"
pass "real Pi absorbs an unchanged human-owned decision before model invocation"

printf 'evidence: herdr-session=%s pi=%s model=github-copilot/gpt-5.6-sol prompts=1 unchanged-replay=0\n' \
  "$HERDR_LAB_SESSION" "$(pi --version)"
