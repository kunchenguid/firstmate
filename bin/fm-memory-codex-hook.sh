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
    CAPSULE=$("$SCRIPT_DIR/fm-memory.sh" recover --max-events 20 2>/dev/null) || exit 0
    printf '%s' "$CAPSULE" | node -e '
let value = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { value += chunk; });
process.stdin.on("end", () => process.stdout.write(`${JSON.stringify({ continue: true, systemMessage: value })}\n`));
'
    ;;
  *)
    exit 0
    ;;
esac
