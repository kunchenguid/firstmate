#!/usr/bin/env bash
# Portable contract tests for the Paseo adapter.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-paseo-tests)
FB="$TMP_ROOT/bin"
mkdir -p "$FB"
STATUS="$TMP_ROOT/status"
printf 'running\n' >"$STATUS"
LOG="$TMP_ROOT/log"
cat > "$FB/paseo" <<'SH'
#!/usr/bin/env bash
printf 'agent=%s workspace=%s|%s\n' "${PASEO_AGENT_ID-unset}" "${PASEO_WORKSPACE_ID-unset}" "$*" >> "$FM_PASEO_LOG"
case "$*" in
  "daemon status") exit 0 ;;
  "provider diagnostic claude --json")
    case "${FM_PASEO_CLAUDE_DIAGNOSTIC:-failed}" in
      available) printf '%s\n' '{"provider":"claude","diagnostic":"Status: Ready\n"}' ;;
      unavailable) printf '%s\n' '{"provider":"claude","diagnostic":"Status: Unavailable\n"}' ;;
      empty) printf '%s\n' '{}' ;;
      unknown) printf '%s\n' '{"provider":"claude","diagnostic":"Status: Unknown\n"}' ;;
      json-disabled) printf '%s\n' '{"provider":"claude","enabled":false,"diagnostic":"Status: Ready\n"}' ;;
      *) exit 1 ;;
    esac
    ;;
  "provider ls --json")
    if [ "${FM_PASEO_CLAUDE_DIAGNOSTIC:-failed}" = available ]; then
      printf '%s\n' '[{"provider":"claude","status":"available","enabled":"Enabled"}]'
    else
      printf '%s\n' '[{"provider":"claude","status":"unavailable","enabled":"Disabled"}]'
    fi
    ;;
  inspect\ *) printf '{"status":"%s"}\n' "$(cat "$FM_PASEO_STATUS")" ;;
  logs\ *)
    [ "${FM_PASEO_LOGS_FAIL:-0}" = 1 ] && exit 1
    [ "${FM_PASEO_LOGS_EMPTY:-0}" = 1 ] && exit 0 || printf 'Paseo transcript: timeline\n'
    ;;
  send\ *)
    [ "${FM_PASEO_SEND_FAIL:-0}" = 1 ] && exit 1
    printf 'accepted by paseo\n'
    ;;
  stop\ *) printf 'stopped\n' >> "$FM_PASEO_LOG"; printf 'idle\n' >"$FM_PASEO_STATUS" ;;
  archive\ *) printf 'archived\n' >> "$FM_PASEO_LOG"; printf 'archived\n' >"$FM_PASEO_STATUS" ;;
  workspace\ archive\ *) printf 'workspace-archived\n' >> "$FM_PASEO_LOG" ;;
  "run "*)
    if [ "${FM_PASEO_RUN_FAIL:-0}" = 1 ]; then
      printf 'Created workspace wks-partial\nPaseo run failed after workspace creation\n'
      exit 1
    fi
    printf 'Created workspace wks-test\n{"agentId":"agent-test","cwd":"/tmp/fm-test"}\n'
    ;;
esac
exit 0
SH
chmod +x "$FB/paseo"
export PATH="$FB:$PATH" FM_PASEO_LOG="$LOG" FM_PASEO_STATUS="$STATUS"
# shellcheck source=bin/fm-backend.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-backend.sh"
fm_backend_source paseo

assert_contains "$(fm_backend_paseo_provider codex)" codex "Codex maps to Paseo"
if fm_backend_paseo_provider claude >/dev/null 2>&1; then fail "disabled Claude provider was accepted"; fi
export FM_PASEO_CLAUDE_DIAGNOSTIC=unavailable
if fm_backend_paseo_provider claude >/dev/null 2>&1; then fail "semantically unavailable Claude provider was accepted"; fi
for diagnostic in empty unknown json-disabled; do
  export FM_PASEO_CLAUDE_DIAGNOSTIC=$diagnostic
  if fm_backend_paseo_provider claude >/dev/null 2>&1; then fail "$diagnostic Claude diagnostic was accepted"; fi
done
export FM_PASEO_CLAUDE_DIAGNOSTIC=available
assert_contains "$(fm_backend_paseo_provider claude)" claude "available Claude provider maps to Paseo"
if fm_backend_paseo_provider muse >/dev/null 2>"$TMP_ROOT/provider-error"; then fail "unsupported Muse provider was accepted"; fi
assert_contains "$(cat "$TMP_ROOT/provider-error")" muse "unsupported provider refusal names the harness"
assert_contains "$(fm_backend_paseo_agent_state agent-test)" unverified "Paseo liveness stays unverified"
assert_contains "$(fm_backend_paseo_busy_state agent-test)" busy "Paseo running status is busy"
printf 'error\n' >"$STATUS"
assert_contains "$(fm_backend_paseo_busy_state agent-test)" unknown "Paseo error status is not healthy idle"
printf 'running\n' >"$STATUS"
assert_contains "$(fm_backend_paseo_capture agent-test 4)" timeline "Paseo capture retains timeline logs"
if fm_backend_paseo_capture agent-test 4 | grep -q 'Paseo status'; then fail "Paseo status leaked into diagnostics"; fi
export FM_PASEO_LOGS_EMPTY=1
[ -z "$(fm_backend_paseo_capture agent-test 4)" ] || fail "valid empty Paseo logs should remain empty"
export FM_PASEO_LOGS_FAIL=1
if fm_backend_paseo_capture agent-test 4 >/dev/null 2>&1; then fail "failed Paseo logs command was treated as empty success"; fi
unset FM_PASEO_LOGS_EMPTY FM_PASEO_LOGS_FAIL
if [ -n "$(fm_backend_paseo_send_text_submit agent-test hello)" ]; then fail "Paseo send leaked provider output as a verdict"; fi
export FM_PASEO_SEND_FAIL=1
if fm_backend_paseo_send_text_submit agent-test hello >/dev/null 2>&1; then fail "failed Paseo send was treated as success"; fi
unset FM_PASEO_SEND_FAIL
if fm_backend_paseo_terminal_proof agent-test; then fail "idle Paseo status was treated as terminal proof"; fi
if fm_backend_paseo_stop_status_proof agent-test 1 0.01; then fail "idle Paseo status was treated as a successful stop proof"; fi
printf 'closed\n' >"$STATUS"
fm_backend_paseo_terminal_proof agent-test || fail "closed Paseo status did not prove the endpoint terminal"
printf 'idle\n' >"$STATUS"
fm_backend_paseo_archive_agent agent-test
assert_contains "$(fm_backend_paseo_busy_state agent-test)" idle "Paseo archive leaves a native terminal status"
export PASEO_AGENT_ID=parent-agent PASEO_WORKSPACE_ID=parent-workspace
fm_backend_paseo_create_task task-test "$PWD" "$PWD/README.md" codex default default home-tag wks-existing A=1 B=2 >/dev/null
assert_contains "$(cat "$LOG")" '--workspace wks-existing' "Paseo relaunch targets its workspace"
assert_contains "$(cat "$LOG")" 'agent=unset workspace=unset|run' "Paseo workers are independent roots without the caller workspace"
assert_contains "$(cat "$LOG")" '--env A=1 --env B=2' "Paseo preserves repeated env values"
assert_not_contains "$(cat "$LOG")" 'BASH_ENV=' "Paseo does not rely on a shell environment file"
assert_not_contains "$(cat "$LOG")" '--mode auto-review' "Codex does not receive a forced review mode"
fm_backend_paseo_create_task opencode-test "$PWD" "$PWD/README.md" opencode default default home-tag wks-existing >/dev/null
assert_contains "$(cat "$LOG")" '--mode build' "OpenCode retains its build mode"

SOURCE="$TMP_ROOT/source"
fresh_run=
mkdir -p "$SOURCE"
git -C "$SOURCE" init -q
git -C "$SOURCE" config user.email test@example.com
git -C "$SOURCE" config user.name test
printf 'base\n' >"$SOURCE/file"
git -C "$SOURCE" add file
git -C "$SOURCE" commit -qm base
git -C "$SOURCE" branch -M main
git -C "$SOURCE" checkout -qb feature
if FM_PASEO_RUN_FAIL=1 fm_backend_paseo_create_task partial-run "$SOURCE" "$PWD/README.md" codex default default home-tag '' >/dev/null 2>"$TMP_ROOT/run-failure"; then
  fail "Paseo run failure after workspace creation was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/run-failure")" 'workspace wks-partial' "Paseo run failure did not report its created workspace"
assert_not_contains "$(cat "$LOG")" 'workspace archive wks-partial' "Paseo auto-archived a partially created workspace"
fm_backend_paseo_create_task fresh-task "$SOURCE" "$PWD/README.md" codex default default home-tag '' >/dev/null
fresh_run=$(grep '|run .*fm-fresh-task' "$LOG" | tail -n 1)
assert_contains "$(cat "$LOG")" '--base main' "Paseo fresh spawn uses the local default branch, not the feature branch"
assert_contains "$(cat "$LOG")" '--new-workspace worktree' "Paseo fresh spawn owns a new isolated worktree"
assert_not_contains "$fresh_run" 'parent-workspace' "Paseo fresh spawn ignores the ambient caller workspace"
unset PASEO_AGENT_ID PASEO_WORKSPACE_ID
fm_backend_paseo_kill agent-test wks-test
agent_archive_line=$(grep -n 'archive agent-test' "$LOG" | tail -n 1 | cut -d: -f1)
workspace_archive_line=$(grep -n 'workspace archive wks-test' "$LOG" | tail -n 1 | cut -d: -f1)
[ -n "$agent_archive_line" ] && [ -n "$workspace_archive_line" ] && [ "$agent_archive_line" -lt "$workspace_archive_line" ] \
  || fail "Paseo kill must archive the agent before its task workspace"
if fm_backend_paseo_send_key agent-test Escape >/dev/null 2>&1; then fail "unsupported Paseo key was accepted"; fi
fm_backend_paseo_send_key agent-test C-c >/dev/null
assert_contains "$(cat "$LOG")" agent-test "Paseo control calls reached the stub"
pass "Paseo adapter provider, liveness, root-agent, status, workspace, and control contracts"
