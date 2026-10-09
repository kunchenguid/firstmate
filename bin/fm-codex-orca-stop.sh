#!/usr/bin/env bash
# Codex Stop glue: ensure the verified attended Orca owner, then always call
# fm-turnend-guard.sh with the original payload. A failed ensure blocks once
# even when a watcher survives; the existing stop_hook_active safety wins on
# the repeated Stop. Other backends, workers, away/host homes retain the guard.
# Usage: FM_HOME=<home> fm-codex-orca-stop.sh < <Codex-hook-JSON>
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
payload=$(cat 2>/dev/null || true)
ensure_status=0
if [ -n "${ORCA_TERMINAL_HANDLE:-}" ] && command -v python3 >/dev/null 2>&1 \
  && python3 -c 'import fcntl, sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
  python3 "$SCRIPT_DIR/fm-codex-orca-continuation.py" ensure --home "$FM_HOME" --code-root "$FM_ROOT" >/dev/null || ensure_status=$?
fi
guard_status=0
printf '%s' "$payload" | "$SCRIPT_DIR/fm-turnend-guard.sh" || guard_status=$?
[ "$guard_status" -eq 0 ] || exit "$guard_status"
if [ "$ensure_status" -ne 0 ] && command -v jq >/dev/null 2>&1 \
  && printf '%s' "$payload" | jq -e 'type == "object" and ((if has("stopHookActive") then .stopHookActive elif has("stop_hook_active") then .stop_hook_active else false end) == false)' >/dev/null 2>&1; then
  echo 'continuation: Orca owner/delivery is unconfirmed; inspect its status and exact receipt before ending.' >&2
  exit 2
fi
exit 0
