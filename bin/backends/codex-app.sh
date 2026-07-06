#!/usr/bin/env bash
# bin/backends/codex-app.sh - Codex Desktop thread backend adapter.
#
# Target string shape: the Codex thread id accepted by bin/fm-codex-bridge.
# The bridge owns app-server protocol details; this file only adapts stable
# bridge verbs to firstmate's backend function names.

FM_BACKEND_CODEX_APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fm_backend_codex_app_bridge() {
  printf '%s\n' "${FM_CODEX_BRIDGE:-$FM_BACKEND_CODEX_APP_ROOT/bin/fm-codex-bridge}"
}

fm_backend_codex_app_tool_check() {
  local bridge
  bridge=$(fm_backend_codex_app_bridge)
  [ -x "$bridge" ] || { echo "error: backend=codex-app selected but bridge is not executable: $bridge" >&2; return 1; }
  command -v node >/dev/null 2>&1 || { echo "error: backend=codex-app selected but node is not installed" >&2; return 1; }
}

fm_backend_codex_app_json_field() {  # <field>
  local field=$1
  node -e '
const field = process.argv[1];
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  let data;
  try {
    data = JSON.parse(input || "{}");
  } catch (err) {
    process.exit(2);
  }
  const value = field.split(".").reduce((acc, key) => acc == null ? undefined : acc[key], data);
  if (value == null) process.exit(1);
  if (typeof value === "object") process.stdout.write(JSON.stringify(value));
  else process.stdout.write(String(value));
});
' "$field"
}

fm_backend_codex_app_prompt_tmp() {  # <text> -> echoes temp path
  local text=$1 tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-codex-prompt.XXXXXX") || return 1
  printf '%s\n' "$text" > "$tmp"
  printf '%s\n' "$tmp"
}

fm_backend_codex_app_capture() {  # <thread-id> <lines> [expected-label]
  local thread_id=$1 lines=${2:-40} bridge out text
  fm_backend_codex_app_tool_check || return 1
  bridge=$(fm_backend_codex_app_bridge)
  out=$("$bridge" turns-list --thread-id "$thread_id" --limit "$lines" --items-view summary) || return 1
  text=$(printf '%s' "$out" | fm_backend_codex_app_json_field text 2>/dev/null || true)
  if [ -n "$text" ]; then
    printf '%s' "$text"
  else
    printf '%s' "$out"
  fi
}

fm_backend_codex_app_send_text_submit() {  # <thread-id> <text> <retries> <enter-sleep> <settle> [expected-label]
  local thread_id=$1 text=$2 bridge tmp
  fm_backend_codex_app_tool_check || { printf 'send-failed'; return 0; }
  bridge=$(fm_backend_codex_app_bridge)
  tmp=$(fm_backend_codex_app_prompt_tmp "$text") || { printf 'send-failed'; return 0; }
  if "$bridge" send-turn --thread-id "$thread_id" --prompt-file "$tmp" >/dev/null; then
    rm -f "$tmp"
    printf 'empty'
    return 0
  fi
  rm -f "$tmp"
  printf 'send-failed'
}

fm_backend_codex_app_send_key() {  # <thread-id> <key> [expected-label]
  local key=${2:-}
  case "$key" in
    Enter) return 0 ;;
    *) echo "error: unsupported Codex app key '$key'" >&2; return 1 ;;
  esac
}

fm_backend_codex_app_kill() {  # <thread-id>
  local thread_id=$1 bridge
  fm_backend_codex_app_tool_check || return 1
  bridge=$(fm_backend_codex_app_bridge)
  "$bridge" archive-thread --thread-id "$thread_id" >/dev/null
}

fm_backend_codex_app_busy_state() {  # <thread-id> -> busy|idle|unknown
  local thread_id=$1 bridge out status
  fm_backend_codex_app_tool_check || { printf 'unknown'; return 0; }
  bridge=$(fm_backend_codex_app_bridge)
  out=$("$bridge" thread-status --thread-id "$thread_id" 2>/dev/null) || { printf 'unknown'; return 0; }
  status=$(printf '%s' "$out" | fm_backend_codex_app_json_field status 2>/dev/null || true)
  case "$status" in
    active) printf 'busy' ;;
    idle) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_codex_app_composer_state() {
  printf 'empty'
}

fm_backend_codex_app_target_exists() {  # <thread-id> [expected-label]
  local thread_id=$1 bridge
  fm_backend_codex_app_tool_check || return 1
  bridge=$(fm_backend_codex_app_bridge)
  "$bridge" thread-status --thread-id "$thread_id" >/dev/null
}

fm_backend_codex_app_ensure_running() {
  local bridge
  fm_backend_codex_app_tool_check || return 1
  bridge=$(fm_backend_codex_app_bridge)
  "$bridge" ensure-running
}
