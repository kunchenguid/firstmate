#!/usr/bin/env bash
# Copilot CLI harness adapter behavior and tracked-hook registration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_fake_ps() {
  local dir=$1 mode=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_FAKE_PS_MODE:?}
field=
pid=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$mode:$field:$pid" in
  copilot:comm=:*) printf '/opt/copilot/bin/copilot\n' ;;
  copilot:args=:*) printf 'copilot\n' ;;
  copilot:ppid=:*) printf '1\n' ;;
  zsh-parent:comm=:4242) printf '/opt/copilot/bin/copilot\n' ;;
  zsh-parent:comm=:*) printf '%s\n' '-zsh' ;;
  zsh-parent:args=:4242) printf 'copilot\n' ;;
  zsh-parent:args=:*) printf '%s\n' '-zsh' ;;
  zsh-parent:ppid=:4242) printf '1\n' ;;
  zsh-parent:ppid=:*) printf '4242\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_detection_and_marker_precedence() {
  local fakebin out
  fakebin=$(make_fake_ps "$TMP_ROOT/detection" copilot)
  out=$(COPILOT_CLI=1 FM_FAKE_PS_MODE=copilot PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" = copilot ] || fail "Copilot marker plus ancestry detected '$out'"

  out=$(COPILOT_CLI=1 CLAUDECODE=1 FM_FAKE_PS_MODE=copilot PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "explicit Claude child marker did not beat inherited Copilot marker"

  fakebin=$(make_fake_ps "$TMP_ROOT/zsh-parent" zsh-parent)
  out=$(COPILOT_CLI=1 FM_FAKE_PS_MODE=zsh-parent PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh" 2>&1)
  [ "$out" = copilot ] || fail "Copilot ancestry behind a -zsh process detected '$out'"
  assert_not_contains "$out" "illegal option" "dash-prefixed process name reached basename option parsing"
  pass "fm-harness detects Copilot without misclassifying explicit child harnesses"
}

test_session_lock_accepts_copilot() {
  local home fakebin
  home="$TMP_ROOT/lock-home"
  mkdir -p "$home/state"
  fakebin=$(make_fake_ps "$TMP_ROOT/lock-ps" copilot)
  FM_HOME="$home" FM_FAKE_PS_MODE=copilot PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" >/dev/null \
    || fail "fm-lock did not accept Copilot ancestry"
  case "$(cat "$home/state/.lock")" in
    ''|*[!0-9]*) fail "fm-lock did not record a numeric Copilot owner" ;;
  esac
  pass "session ownership recognizes Copilot"
}

test_native_hook_adapter_translates_context_and_stop() {
  local fixture out status
  fixture="$TMP_ROOT/hook-fixture"
  mkdir -p "$fixture/bin"
  cp "$ROOT/bin/fm-copilot-hook.sh" "$fixture/bin/"
  cat > "$fixture/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'FIRSTMATE_SESSION_START'
SH
  cat > "$fixture/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' 'restore supervision now' >&2
exit 2
SH
  chmod +x "$fixture/bin/"*.sh

  out=$(printf '{}' | "$fixture/bin/fm-copilot-hook.sh" session-start)
  [ "$(printf '%s' "$out" | jq -r '.additionalContext')" = FIRSTMATE_SESSION_START ] \
    || fail "Copilot session-start adapter did not emit additionalContext"

  status=0
  out=$(printf '{"stop_hook_active":false}' | "$fixture/bin/fm-copilot-hook.sh" agent-stop) || status=$?
  expect_code 0 "$status" "Copilot agentStop adapter should return a native decision"
  [ "$(printf '%s' "$out" | jq -r '.decision')" = block ] \
    || fail "Copilot agentStop adapter did not block"
  assert_contains "$(printf '%s' "$out" | jq -r '.reason')" "restore supervision now" \
    "Copilot agentStop decision lost the shared guard reason"
  pass "Copilot hooks translate shared startup and turn-end contracts"
}

test_native_pretool_payloads_reach_shared_guards() {
  local out status

  status=0
  out=$(printf '{"toolName":"bash","toolArgs":{"command":"bin/fm-watch-arm.sh &"}}' \
    | "$ROOT/bin/fm-arm-pretool-check.sh" --claude 2>&1) || status=$?
  expect_code 2 "$status" "Copilot watcher-arm anti-pattern should be denied"
  assert_contains "$out" "watcher-background" "Copilot watcher deny lost its reason code"

  status=0
  out=$(printf '{"toolName":"bash","toolArgs":{"command":"cd projects/example"}}' \
    | "$ROOT/bin/fm-cd-pretool-check.sh" --claude 2>&1) || status=$?
  expect_code 2 "$status" "Copilot persistent cd should be denied"
  assert_contains "$out" "persistent-cd" "Copilot cd deny lost its reason code"

  status=0
  out=$(printf '{"toolName":"task","toolArgs":{}}' \
    | "$ROOT/bin/fm-subagent-pretool-check.sh" --claude 2>&1) || status=$?
  expect_code 2 "$status" "Copilot built-in task delegation should be denied in the primary"
  assert_contains "$out" "subagent-dispatch" "Copilot delegation deny lost its reason code"
  pass "Copilot camelCase PreToolUse payloads reach all shared primary guards"
}

test_copilot_busy_signature_is_scoped() {
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  printf '%s\0' '◉ Working · 86 B esc interrupt' | fm_busy_lines_match copilot \
    || fail "Copilot busy footer was not recognized"
  if printf '%s\0' '← open sidebar · / commands · ? help' | fm_busy_lines_match copilot; then
    fail "Copilot idle footer was classified busy"
  fi
  pass "Copilot busy detection uses its observed esc-interrupt footer"
}

test_tracked_hook_registration() {
  local hooks="$ROOT/.github/hooks/fm-primary.json" claude_commands command out status
  jq -e '.version == 1' "$hooks" >/dev/null || fail "Copilot hook schema version is missing"
  jq -e 'any(.hooks.sessionStart[]?; .bash | contains("session-start"))' "$hooks" >/dev/null \
    || fail "Copilot sessionStart hook is missing"
  jq -e 'any(.hooks.agentStop[]?; .bash | contains("agent-stop"))' "$hooks" >/dev/null \
    || fail "Copilot agentStop hook is missing"
  jq -e '[.hooks.preToolUse[]? | select(.matcher == "bash")] | length == 2' "$hooks" >/dev/null \
    || fail "Copilot shell guards are not both registered"
  jq -e 'any(.hooks.preToolUse[]?; .matcher == ".*" and (.bash | contains("pretool-subagent")))' "$hooks" >/dev/null \
    || fail "Copilot delegation guard is missing"
  claude_commands=$(jq -r '.. | objects | .command? // empty' "$ROOT/.claude/settings.json")
  [ "$(printf '%s\n' "$claude_commands" | grep -c 'COPILOT_CLI')" -eq 6 ] \
    || fail "Claude hooks do not all step aside for a native Copilot session"
  while IFS= read -r command; do
    status=0
    out=$(printf '{}' | env -u CLAUDE_PROJECT_DIR COPILOT_CLI=1 sh -c "$command" 2>&1) || status=$?
    expect_code 0 "$status" "Claude compatibility hook should step aside in Copilot"
    [ -z "$out" ] || fail "Claude compatibility hook wrote output in Copilot: $out"
  done <<EOF
$claude_commands
EOF
  pass "tracked Copilot hooks own the session while Claude compatibility hooks step aside"
}

test_detection_and_marker_precedence
test_session_lock_accepts_copilot
test_native_hook_adapter_translates_context_and_stop
test_native_pretool_payloads_reach_shared_guards
test_copilot_busy_signature_is_scoped
test_tracked_hook_registration

echo "# all fm-copilot-harness tests passed"
