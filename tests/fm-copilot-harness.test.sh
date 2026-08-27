#!/usr/bin/env bash
# Portable regressions for GitHub Copilot CLI primary and worker hook contracts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)
trap 'rm -rf "$TMP_ROOT"' EXIT

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case " $* " in
  *" -W "*)
    printf '%s\n' \
      '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND' \
      "  876543       1  876543     876543  ?         1000 00:00:00 C:\\Tools\\copilot.exe"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

install_primary_fixture() {
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  for f in fm-ghcp-hook.sh fm-turnend-guard-cursor.sh fm-turnend-guard.sh \
           fm-operational-input.sh fm-primary-scope-lib.sh fm-supervision-lib.sh \
           fm-wake-lib.sh fm-session-lock-lib.sh fm-cursor-lib.sh fm-lock.sh \
           fm-gate-refuse-lib.sh fm-busy-event.sh fm-busy-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  chmod +x "$dir"/bin/*.sh
  cat > "$dir/bin/fm-wake-lib.sh" <<'SH'
#!/usr/bin/env bash
fm_lock_try_acquire() {
  mkdir "$1" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$1/pid"
  FM_LOCK_OWNER_DIR=$1
}
fm_lock_release() {
  rm -f "$1/pid"
  rmdir "$1" 2>/dev/null || true
}
fm_watcher_healthy() {
  return 1
}
SH
  cat > "$dir/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'COPILOT SESSION DIGEST\n'
SH
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$FM_HOME/state/arm-ran"
if [ "${FM_FAKE_COPILOT_REPAIR:-0}" = 1 ]; then
  printf 'watcher: fixture could not establish supervision\n'
else
  printf 'stale: copilot fixture needs attention\n'
fi
SH
  chmod +x "$dir/bin/fm-sessionstart-run.sh" "$dir/bin/fm-watch-arm.sh"
  printf '876543\n' > "$dir/state/.lock"
}

run_hook() {  # <fixture> <fakebin> <action> [args...]
  local dir=$1 fakebin=$2 action=$3
  shift 3
  COPILOT_CLI=1 COPILOT_LOADER_PID=876543 COPILOT_AGENT_SESSION_ID=sess-copilot \
    FM_HOME="$dir" PATH="$fakebin:$PATH" \
    FM_COPILOT_PARK_POLL=0 FM_COPILOT_TURNEND_BLOCK_BUDGET=3 \
    "$dir/bin/fm-ghcp-hook.sh" "$action" "$@"
}

decision_reason() {
  jq -r 'select(.decision == "block") | .reason // empty'
}

test_tracked_hook_registration() {
  local config="$ROOT/.github/hooks/firstmate.json"
  jq -e '
    .version == 1 and
    (.hooks.sessionStart | length) == 1 and
    (.hooks.agentStop | length) == 1 and
    ([.hooks.PreToolUse[].matcher] | sort) == ["Agent|Task", "Bash", "Bash"] and
    ([.hooks[][] | select(.bash == null or .powershell == null)] | length) == 0
  ' "$config" >/dev/null || fail "tracked Copilot hook registration is incomplete"
  pass "Copilot tracked hook registration covers session, guard, and stop boundaries on both shells"
}

test_marker_identity_outranks_inherited_harnesses() {
  local dir fakebin out
  dir="$TMP_ROOT/marker"
  fakebin=$(make_fakebin "$dir")
  out=$(PATH="$fakebin:$PATH" COPILOT_CLI=1 COPILOT_LOADER_PID=876543 \
    COPILOT_AGENT_SESSION_ID=sess-copilot CLAUDECODE=1 CURSOR_AGENT=1 \
    "$ROOT/bin/fm-harness.sh")
  [ "$out" = copilot ] || fail "Copilot markers must outrank inherited harness markers, got '$out'"
  out=$(PATH="$fakebin:$PATH" COPILOT_CLI=1 COPILOT_LOADER_PID=876543 \
    COPILOT_AGENT_SESSION_ID='' CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "an incomplete Copilot marker set must not claim the session, got '$out'"
  pass "fm-harness: validated Copilot markers outrank inherited harness identity"
}

test_windows_loader_pid_owns_session_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/identity"
  fakebin=$(make_fakebin "$dir")
  mkdir -p "$dir/state"
  printf '876543\n' > "$dir/state/.lock"
  got=$(COPILOT_CLI=1 COPILOT_LOADER_PID=876543 \
    COPILOT_AGENT_SESSION_ID=sess-copilot PATH="$fakebin:$PATH" \
    bash -c '. "$1"; fm_harness_ancestry_pid' _ "$ROOT/bin/fm-session-lock-lib.sh")
  [ "$got" = 876543 ] || fail "native Windows loader bridge resolved '$got'"
  COPILOT_CLI=1 COPILOT_LOADER_PID=876543 COPILOT_AGENT_SESSION_ID=sess-copilot \
    PATH="$fakebin:$PATH" bash -c \
    '. "$1"; fm_session_lock_owned_by_self "$2"' _ \
    "$ROOT/bin/fm-session-lock-lib.sh" "$dir/state" \
    || fail "the validated native Copilot loader did not own its session lock"
  pass "session lock: Copilot's validated native Windows loader PID bridges the MSYS ancestry gap"
}

test_loader_marker_rejects_foreign_live_process() {
  COPILOT_CLI=1 COPILOT_LOADER_PID=$$ COPILOT_AGENT_SESSION_ID=sess-copilot \
    bash -c '. "$1"; ! fm_copilot_loader_pid >/dev/null 2>&1' _ \
    "$ROOT/bin/fm-session-lock-lib.sh" \
    || fail "Copilot loader markers accepted a live non-Copilot process"
  pass "session identity: Copilot loader markers cannot claim a foreign live process"
}

test_primary_session_start_returns_additional_context() {
  local dir fakebin out
  dir="$TMP_ROOT/session"
  fakebin=$(make_fakebin "$dir")
  install_primary_fixture "$dir"
  out=$(printf '{"hook_event_name":"sessionStart"}' | run_hook "$dir" "$fakebin" session-start)
  [ "$(printf '%s' "$out" | jq -r '.additionalContext')" = "COPILOT SESSION DIGEST" ] \
    || fail "sessionStart did not return the digest as additionalContext: $out"
  out=$(printf '{}' | env -u COPILOT_CLI -u COPILOT_LOADER_PID \
    -u COPILOT_AGENT_SESSION_ID FM_HOME="$dir" "$dir/bin/fm-ghcp-hook.sh" session-start)
  [ -z "$out" ] || fail "the repository hook must be inert outside Copilot CLI"
  pass "Copilot sessionStart injects the authoritative Firstmate digest and stays inert off-host"
}

test_windows_powershell_pretool_transport() {
  local payload out rc script
  case "${OS:-}" in Windows_NT) ;; *) return 0 ;; esac
  command -v powershell.exe >/dev/null 2>&1 || fail "PowerShell is required for Copilot's Windows hook transport"
  script=$(cygpath -w "$ROOT/bin/fm-ghcp-hook.ps1")
  payload='{"session_id":"sess-copilot","tool_name":"Bash","tool_input":{"command":"bin/fm-watch-arm.sh &"}}'
  out=$(printf '%s' "$payload" | COPILOT_CLI=1 FM_HOME="$ROOT" \
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$script" pretool arm)
  rc=$?
  expect_code 0 "$rc" "Copilot's native pre-tool decision should return through PowerShell"
  [ "$(printf '%s' "$out" | jq -r '.permissionDecision')" = deny ] \
    || fail "PowerShell transport did not preserve the watcher policy denial: $out"
  assert_contains "$(printf '%s' "$out" | jq -r '.permissionDecisionReason')" \
    "[watcher-background]" "PowerShell transport lost the watcher policy reason"
  pass "Copilot PowerShell transport preserves native watcher-policy decisions"
}

test_windows_bearings_transport_avoids_ambient_bash() {
  local out rc root
  case "${OS:-}" in Windows_NT) ;; *) return 0 ;; esac
  command -v powershell.exe >/dev/null 2>&1 || fail "PowerShell is required for Copilot's Windows bearings transport"
  root=$(cygpath -w "$ROOT")
  out=$(powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
    \$ErrorActionPreference = 'Stop'
    \$tempRoot = Join-Path \$env:TEMP ('fm-bearings-windows-' + [guid]::NewGuid().ToString('N'))
    \$fakeBin = Join-Path \$tempRoot 'fakebin'
    \$fixtureHome = Join-Path \$tempRoot 'home'
    New-Item -ItemType Directory -Path \$fakeBin, (Join-Path \$fixtureHome 'data'), (Join-Path \$fixtureHome 'state') | Out-Null
    try {
      Add-Type -TypeDefinition @'
using System;
using System.Threading;
public static class WrongBash {
    public static int Main(string[] args) {
        Thread.Sleep(12000);
        return 97;
    }
}
'@ -OutputAssembly (Join-Path \$fakeBin 'bash.exe') -OutputType ConsoleApplication
      \$gitPath = (Get-Command git.exe -CommandType Application -ErrorAction Stop).Source
      \$gitDirectory = Split-Path -Parent \$gitPath
      \$jqPath = (Get-Command jq.exe -CommandType Application -ErrorAction Stop).Source
      \$jqDirectory = Split-Path -Parent \$jqPath
      \$env:Path = \"\$fakeBin;\$gitDirectory;\$jqDirectory;\$env:SystemRoot\\System32\"
      \$ambient = (Get-Command bash.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
      if ((Split-Path -Parent \$ambient) -ne \$fakeBin) {
        throw \"fixture did not put the hanging bash first: \$ambient\"
      }
      \$env:FM_HOME = \$fixtureHome
      \$env:COPILOT_CLI = '1'
      \$env:COPILOT_AGENT_SESSION_ID = 'bearings-windows-regression'
      \$env:COPILOT_LOADER_PID = \$PID
      \$watch = [System.Diagnostics.Stopwatch]::StartNew()
      \$snapshot = & '$root\\bin\\fm-windows-git-bash.ps1' '$root\\bin\\fm-bearings-snapshot.sh' --json
      \$status = \$LASTEXITCODE
      \$watch.Stop()
      if (\$status -ne 0) {
        throw \"bearings snapshot exited \$status\"
      }
      if (\$watch.ElapsedMilliseconds -ge 8000) {
        throw \"bearings snapshot crossed its shell-boundary budget: \$(\$watch.ElapsedMilliseconds)ms\"
      }
      \$parsed = \$snapshot | ConvertFrom-Json
      if (\$parsed.schema -ne 'fm-bearings.v1') {
        throw \"unexpected snapshot schema: \$(\$parsed.schema)\"
      }
      if (\$parsed.home -ne \$fixtureHome) {
        throw \"snapshot lost FM_HOME: \$(\$parsed.home)\"
      }
      Write-Output \"ambient-bash=\$ambient\"
      Write-Output \"snapshot-ms=\$(\$watch.ElapsedMilliseconds)\"
      Write-Output \"snapshot-schema=\$(\$parsed.schema)\"
    }
    finally {
      Remove-Item -LiteralPath \$tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  " 2>&1)
  rc=$?
  expect_code 0 "$rc" \
    "Copilot's native Windows bearings command should bypass ambient bash: $out"
  assert_contains "$out" "snapshot-schema=fm-bearings.v1" \
    "Windows bearings transport did not return the canonical snapshot"
  pass "Copilot Windows bearings transport bypasses a hanging ambient bash"
}

test_primary_stop_parks_and_bounds_forced_continuations() {
  local dir fakebin out reason parent_state parent_id=secondmate-copilot parent_gen
  dir="$TMP_ROOT/primary-stop"
  fakebin=$(make_fakebin "$dir")
  install_primary_fixture "$dir"
  : > "$dir/state/task.meta"
  parent_state="$dir/parent-state"
  mkdir -p "$parent_state"
  parent_gen=$("$dir/bin/fm-busy-event.sh" arm "$parent_state" "$parent_id")
  "$dir/bin/fm-busy-event.sh" apply "$parent_state" "$parent_id" idle \
    --gen "$parent_gen" --source copilot-hook --event agent-stop >/dev/null \
    || fail "could not stage the Copilot secondmate idle event"

  out=$(printf '{"sessionId":"sess-copilot","stop_hook_active":false}' | \
    FM_COPILOT_TURNEND_LOOP_CEILING=2 \
    FM_COPILOT_PARENT_STATE="$parent_state" FM_COPILOT_PARENT_TASK_ID="$parent_id" \
    FM_COPILOT_PARENT_BUSY_GEN="$parent_gen" \
    run_hook "$dir" "$fakebin" primary-stop)
  reason=$(printf '%s' "$out" | decision_reason)
  assert_contains "$reason" "copilot fixture needs attention" \
    "the first stop did not deliver the watcher result"
  [ "$(fm_busy_classify tmux none copilot "$parent_id" "$parent_state")" = "busy copilot-hook" ] \
    || fail "a blocked Copilot secondmate stop did not restore parent-visible busy state"
  [ "$(sed -n '2s/^count=//p' "$dir/state/.turnend-copilot-continuations")" = 1 ] \
    || fail "the first forced continuation was not persisted"

  out=$(printf '{"sessionId":"sess-copilot","stop_hook_active":true}' | \
    FM_COPILOT_TURNEND_LOOP_CEILING=2 run_hook "$dir" "$fakebin" primary-stop)
  reason=$(printf '%s' "$out" | decision_reason)
  assert_contains "$reason" "FOLLOW-UP CEILING REACHED" \
    "the inner ceiling did not warn on the final allowed continuation"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" = 1 ] \
    || fail "the ceiling continuation must not arm another watcher cycle"

  out=$(printf '{"sessionId":"sess-copilot","stop_hook_active":true}' | \
    FM_COPILOT_TURNEND_LOOP_CEILING=2 run_hook "$dir" "$fakebin" primary-stop)
  [ -z "$out" ] || fail "the park must allow stop after its inner ceiling: $out"

  out=$(printf '{"sessionId":"sess-copilot","stop_hook_active":false}' | \
    FM_COPILOT_TURNEND_LOOP_CEILING=2 run_hook "$dir" "$fakebin" primary-stop)
  reason=$(printf '%s' "$out" | decision_reason)
  assert_contains "$reason" "copilot fixture needs attention" \
    "a real captain prompt did not reset the continuation ledger"
  pass "Copilot agentStop parks synchronously, renders decision:block, and stops before vendor override"
}

test_primary_repair_continuation_restores_parent_busy() {
  local dir fakebin out reason parent_state parent_id=secondmate-repair parent_gen current_gen
  dir="$TMP_ROOT/primary-repair"
  fakebin=$(make_fakebin "$dir")
  install_primary_fixture "$dir"
  : > "$dir/state/task.meta"
  parent_state="$dir/parent-state"
  mkdir -p "$parent_state"
  parent_gen=$("$dir/bin/fm-busy-event.sh" arm "$parent_state" "$parent_id")
  "$dir/bin/fm-busy-event.sh" apply "$parent_state" "$parent_id" idle \
    --gen "$parent_gen" --source copilot-hook --event agent-stop >/dev/null \
    || fail "could not stage the repair-path Copilot idle event"

  out=$(printf '{"sessionId":"sess-copilot-repair","stop_hook_active":false}' | \
    FM_FAKE_COPILOT_REPAIR=1 \
    FM_COPILOT_PARENT_STATE="$parent_state" FM_COPILOT_PARENT_TASK_ID="$parent_id" \
    FM_COPILOT_PARENT_BUSY_GEN="$parent_gen" \
    run_hook "$dir" "$fakebin" primary-stop)
  reason=$(printf '%s' "$out" | decision_reason)
  assert_contains "$reason" "TURN WOULD END BLIND" \
    "the repair path did not return a blocked Copilot continuation"
  [ "$(fm_busy_classify tmux none copilot "$parent_id" "$parent_state")" = "busy copilot-hook" ] \
    || fail "a blocked Copilot repair continuation did not restore parent-visible busy state"

  current_gen=$("$dir/bin/fm-busy-event.sh" arm "$parent_state" "$parent_id")
  [ "$current_gen" != "$parent_gen" ] || fail "repair-path stale-generation fixture did not advance"
  out=$(printf '{"sessionId":"sess-copilot-repair","stop_hook_active":false}' | \
    FM_FAKE_COPILOT_REPAIR=1 \
    FM_COPILOT_PARENT_STATE="$parent_state" FM_COPILOT_PARENT_TASK_ID="$parent_id" \
    FM_COPILOT_PARENT_BUSY_GEN="$parent_gen" \
    run_hook "$dir" "$fakebin" primary-stop)
  [ -z "$out" ] || fail "a stale Copilot repair continuation must not force another turn"
  [ "$(fm_busy_classify tmux none copilot "$parent_id" "$parent_state")" = "busy fm-spawn" ] \
    || fail "a stale Copilot repair continuation changed the current incarnation"
  pass "Copilot repair continuations restore parent busy state and reject stale generations"
}

test_worker_hook_semantic_lifecycle() {
  local dir fakebin id=worker-copilot gen stale_gen out prompt_token_1 prompt_token_2
  dir="$TMP_ROOT/worker"
  fakebin=$(make_fakebin "$dir")
  install_primary_fixture "$dir"
  gen=$("$dir/bin/fm-busy-event.sh" arm "$dir/state" "$id")
  run_hook "$dir" "$fakebin" worker-event "$dir/state" "$id" "$gen" \
    busy user-prompt-submitted - \
    >/dev/null || fail "Copilot prompt hook failed"
  out=$(fm_busy_classify tmux none copilot "$id" "$dir/state")
  [ "$out" = "busy copilot-hook" ] || fail "prompt hook did not classify busy, got '$out'"
  prompt_token_1=$(cat "$dir/state/$id.copilot-prompt-submitted")
  [ -n "$prompt_token_1" ] || fail "prompt hook did not publish its submission acknowledgement"
  run_hook "$dir" "$fakebin" worker-event "$dir/state" "$id" "$gen" \
    idle agentStop "$dir/state/$id.turn-ended" \
    >/dev/null || fail "Copilot stop hook failed"
  out=$(fm_busy_classify tmux none copilot "$id" "$dir/state")
  [ "$out" = "idle copilot-hook" ] || fail "stop hook did not classify idle, got '$out'"
  assert_present "$dir/state/$id.turn-ended" "stop hook did not emit the turn-ended notification"
  run_hook "$dir" "$fakebin" worker-event "$dir/state" "$id" "$gen" \
    busy user-prompt-submitted - \
    >/dev/null || fail "Copilot second prompt hook failed"
  prompt_token_2=$(cat "$dir/state/$id.copilot-prompt-submitted")
  [ "$prompt_token_2" != "$prompt_token_1" ] \
    || fail "prompt-hook submission acknowledgement did not advance"
  stale_gen=$gen
  gen=$("$dir/bin/fm-busy-event.sh" arm "$dir/state" "$id")
  rm -f "$dir/state/$id.turn-ended"
  run_hook "$dir" "$fakebin" worker-event "$dir/state" "$id" "$stale_gen" \
    idle agent-stop "$dir/state/$id.turn-ended" \
    >/dev/null || fail "stale Copilot stop hook did not return safely"
  assert_absent "$dir/state/$id.turn-ended" \
    "stale Copilot stop hook emitted a turn-ended notification"
  pass "Copilot worker hooks open busy on prompts and close idle on stop"
}

test_tracked_hook_registration
test_marker_identity_outranks_inherited_harnesses
test_windows_loader_pid_owns_session_lock
test_loader_marker_rejects_foreign_live_process
test_primary_session_start_returns_additional_context
test_windows_powershell_pretool_transport
test_windows_bearings_transport_avoids_ambient_bash
test_primary_stop_parks_and_bounds_forced_continuations
test_primary_repair_continuation_restores_parent_busy
test_worker_hook_semantic_lifecycle

echo "all fm-copilot-harness tests passed"
