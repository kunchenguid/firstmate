#!/usr/bin/env bash
# Token-free real-server guard. FM_T3CODE_LIVE_E2E=1 forces it on, =0 off.
# FM_T3CODE_PROMPT_LIVE=1 (or FM_LIVE=1) additionally submits a short prompt.
# Uses the configured bearer and owns only its fresh temporary project/threads.
# Refresh: FM_CONFIG_OVERRIDE=<home>/config bin/fm-test-run.sh tests/fm-backend-t3code-live-e2e.test.sh
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source t3code
if [ -n "${FM_T3CODE_ORIGIN:-}" ] || [ -f "$(fm_backend_t3code_runtime_file)" ] \
  || command -v t3 >/dev/null 2>&1 || [ -d "/Applications/T3 Code.app" ] \
  || [ -d "/Applications/T3 Code (Nightly).app" ]; then
  t3code-server() { :; }
fi
fm_live_gate default-on FM_T3CODE_LIVE_E2E node treehouse t3code-server
version=unknown
project=''
thread=''
checked=0
TMP_ROOT=$(fm_test_tmproot fm-t3code-live)
cleanup() {
  local rc=$? cmd
  trap - EXIT
  if [ -n "$thread" ]; then
    fm_backend_t3code_agent_stop "$thread" || rc=1
    cmd=$(fm_backend_t3code_command thread.delete "threadId=$thread")
    fm_backend_t3code_dispatch "$cmd" >/dev/null || rc=1
  fi
  if [ -n "$project" ]; then
    cmd=$(fm_backend_t3code_command project.delete "projectId=$project")
    fm_backend_t3code_dispatch "$cmd" >/dev/null || rc=1
    if fm_backend_t3code_api GET /api/orchestration/shell | node -e '
const d=JSON.parse(require("fs").readFileSync(0,"utf8"));
process.exit((d.projects || []).some(p => p.id === process.argv[1] && !p.deletedAt) ? 1 : 0);
' "$project"; then :; else rc=1; fi
  fi
  fm_test_cleanup
  if [ "$rc" -ne 0 ]; then
    printf 'not ok - T3 Code %s live guard failed (including cleanup)\n' "$version" >&2
  elif [ "$checked" -ne 1 ]; then
    printf 'not ok - T3 Code %s live guard checked nothing\n' "$version" >&2
    rc=1
  else
    pass "T3 Code $version live lifecycle and cleanup"
  fi
  exit "$rc"
}
trap cleanup EXIT
version=$(fm_backend_t3code_api GET /.well-known/t3/environment | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).serverVersion)')
fm_backend_t3code_runtime_check
project=$(fm_backend_t3code_project_ensure "$TMP_ROOT")
selection=$(fm_backend_t3code_model_selection codex "${FM_T3CODE_LIVE_MODEL:-gpt-5.6-sol}" default "$project")
thread=$(fm_backend_t3code_thread_create "$project" fm-live-guard '' '' "$selection")
fm_backend_t3code_thread_read "$thread" 1 | node -e '
const t=JSON.parse(require("fs").readFileSync(0,"utf8")).thread;
if (t.id !== process.argv[1] || t.projectId !== process.argv[2] || t.worktreePath !== null) process.exit(1);
' "$thread" "$project"
[ "$(fm_backend_t3code_probe "$thread")" = idle ]
[ "$(fm_backend_t3code_state_row "$(fm_backend_t3code_probe "$thread")")" = 'idle alive' ]
[ "$(fm_backend_capture t3code "$thread" 20)" = 't3code: session=none turn=none' ]
# A real subscribed snapshot proves the installed server still speaks the
# reader protocol. No thread beyond this guard is selected for output.
FM_T3CODE_RUNTIME_FILE=$(fm_backend_t3code_runtime_file) \
FM_T3CODE_TOKEN_FILE="$(fm_backend_t3code_config_dir)/t3code-token" \
  node "$ROOT/bin/backends/t3code-eventwait.cjs" 1 "$thread" > "$TMP_ROOT/events"
assert_grep 'subscribed' "$TMP_ROOT/events" "T3 Code $version did not acknowledge the stream"
assert_grep "$thread" "$TMP_ROOT/events" "T3 Code $version stream checked no owned thread"
# The token-free lifecycle has passed even when the nested prompt gate skips.
checked=1
(
  fm_live_gate opt-in FM_T3CODE_PROMPT_LIVE node
  fm_backend_t3code_turn_start "$thread" 'Reply with exactly FM_T3_LIVE_OK. Do not use tools.' "$selection"
  for _ in $(seq 1 120); do
    capture=$(fm_backend_capture t3code "$thread" 20)
    if [[ "$capture" == *'[assistant] FM_T3_LIVE_OK'* ]]; then
      pass "T3 Code $version prompt and capture"
      exit 0
    fi
    sleep 1
  done
  fail "T3 Code $version prompt did not produce the expected reply"
) | sed 's/^skip: live:/T3 prompt subtest skipped:/'
fm_backend_t3code_agent_stop "$thread"
