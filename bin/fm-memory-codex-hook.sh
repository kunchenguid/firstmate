#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=${1:-}
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

case "$MODE" in
  pre)
    printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-memory.sh" boundary --reason pre-compact --runtime codex >/dev/null 2>&1 || true
    ;;
  post)
    printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-memory.sh" codex-stage-recovery >/dev/null 2>&1 || true
    ;;
  stop)
    STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | node -e '
let value = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { value += chunk; });
process.stdin.on("end", () => {
  try { process.stdout.write(JSON.parse(value).stop_hook_active ? "true" : "false"); } catch { process.stdout.write("invalid"); }
});
')
    if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
      printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-memory.sh" codex-claim-recovery --event Stop >/dev/null 2>&1 || true
      exit 0
    fi
    [ "$STOP_HOOK_ACTIVE" = "false" ] || exit 0
    CAPSULE=$(printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-memory.sh" codex-claim-recovery --event Stop --retain 2>/dev/null) || exit 0
    [ -n "$CAPSULE" ] || exit 0
    printf '%s\n' "$CAPSULE" >&2
    exit 2
    ;;
  prompt)
    CAPSULE=$(printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-memory.sh" codex-claim-recovery --event UserPromptSubmit 2>/dev/null) || exit 0
    [ -n "$CAPSULE" ] || exit 0
    printf '%s' "$CAPSULE" | node -e '
let value = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { value += chunk; });
process.stdin.on("end", () => process.stdout.write(`${JSON.stringify({ hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: value } })}\n`));
'
    ;;
  *)
    exit 0
    ;;
esac
