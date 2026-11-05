#!/usr/bin/env bash
# Executable registration tests for Droid's tracked primary project settings.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETTINGS="$ROOT/.factory/settings.json"
CLAUDE_SETTINGS="$ROOT/.claude/settings.json"
TMP_ROOT=$(fm_test_tmproot fm-droid-primary)

[ -f "$SETTINGS" ] || fail "tracked Droid primary settings are missing"
[ -f "$CLAUDE_SETTINGS" ] || fail "tracked Claude primary settings are missing"

test_claude_shaped_hook_contract() {
  local droid_root="$TMP_ROOT/droid-ab" claude_root="$TMP_ROOT/claude-ab"
  local event script payload droid_args claude_args expected_status expected_out expected_err
  local droid_log="$TMP_ROOT/droid-ab.log" claude_log="$TMP_ROOT/claude-ab.log"
  local droid_out="$TMP_ROOT/droid-ab.out" claude_out="$TMP_ROOT/claude-ab.out"
  local droid_err="$TMP_ROOT/droid-ab.err" claude_err="$TMP_ROOT/claude-ab.err"
  local droid_status claude_status expected_record
  make_ab_probe_root "$droid_root"
  make_ab_probe_root "$claude_root"

  for event in SessionStart PreToolUse Stop; do
    case "$event" in
      SessionStart)
        script=fm-sessionstart-run.sh
        payload='{"hook_event_name":"SessionStart","source":"startup"}'
        droid_args='' claude_args='' expected_status=0
        expected_out=SHARED_SESSIONSTART_OUTPUT expected_err=''
        ;;
      PreToolUse)
        script=fm-arm-pretool-check.sh
        payload='{"hook_event_name":"PreToolUse","tool_name":"Execute"}'
        droid_args=--primary-only claude_args=--claude expected_status=21
        expected_out='' expected_err=SHARED_PRETOOL_BLOCK
        ;;
      Stop)
        script=fm-turnend-guard.sh
        payload='{"hook_event_name":"Stop","stop_hook_active":false}'
        droid_args='' claude_args=--claude expected_status=22
        expected_out='' expected_err=SHARED_STOP_BLOCK
        ;;
    esac

    : > "$droid_out"
    : > "$claude_out"
    : > "$droid_err"
    : > "$claude_err"
    set +e
    run_ab_registered_hook "$SETTINGS" "$event" DROID_PROJECT_DIR "$droid_root" "$droid_log" "$payload" \
      > "$droid_out" 2> "$droid_err"
    droid_status=$?
    run_ab_registered_hook "$CLAUDE_SETTINGS" "$event" CLAUDE_PROJECT_DIR "$claude_root" "$claude_log" "$payload" \
      > "$claude_out" 2> "$claude_err"
    claude_status=$?
    set -e

    expect_code "$expected_status" "$droid_status" "Droid $event registration must preserve shared-owner status"
    expect_code "$expected_status" "$claude_status" "Claude $event registration must preserve shared-owner status"
    [ "$(cat "$droid_out")" = "$expected_out" ] \
      || fail "Droid $event registration did not preserve shared-owner stdout"
    [ "$(cat "$claude_out")" = "$expected_out" ] \
      || fail "Claude $event registration did not preserve shared-owner stdout"
    [ "$(cat "$droid_err")" = "$expected_err" ] \
      || fail "Droid $event registration did not preserve shared-owner stderr"
    [ "$(cat "$claude_err")" = "$expected_err" ] \
      || fail "Claude $event registration did not preserve shared-owner stderr"

    expected_record=$(printf '%s\t%s\t%s' "$script" "$droid_args" "$payload")
    grep -Fqx "$expected_record" "$droid_log" \
      || fail "Droid $event registration did not execute $script with its expected arguments and stdin"
    expected_record=$(printf '%s\t%s\t%s' "$script" "$claude_args" "$payload")
    grep -Fqx "$expected_record" "$claude_log" \
      || fail "Claude $event registration did not execute $script with its expected arguments and stdin"
  done
  pass "Droid SessionStart, PreToolUse, and blocking Stop retain Claude's shared hook owners"
}

test_registration_inventory() {
  jq -e '
    (.hooks.SessionStart | length) == 1 and
    (.hooks.PreToolUse | length) == 1 and
    (.hooks.Stop | length) == 1 and
    .hooks.PreToolUse[0].matcher == "Execute" and
    (.hooks.SessionStart[0].hooks | length) == 1 and
    (.hooks.PreToolUse[0].hooks | length) == 1 and
    (.hooks.Stop[0].hooks | length) == 1 and
    (.hooks.SessionStart[0].hooks[0] | .type == "command" and (.command | type == "string" and length > 0) and .timeout == 180) and
    (.hooks.PreToolUse[0].hooks[0] | .type == "command" and (.command | type == "string" and length > 0)) and
    (.hooks.Stop[0].hooks[0] | .type == "command" and (.command | type == "string" and length > 0))
  ' "$SETTINGS" >/dev/null \
    || fail "Droid settings do not carry the one SessionStart, Execute PreToolUse, and Stop primary registration"
  pass "Droid primary settings register the three verified hook transports"
}

make_probe_root() {
  local dir=$1 script
  mkdir -p "$dir/bin"
  for script in fm-sessionstart-run.sh fm-arm-pretool-check.sh fm-turnend-guard.sh; do
    cat > "$dir/bin/$script" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\t%s\n' "${0##*/}" "$payload" >> "$DROID_PROBE_LOG"
case "${0##*/}" in
  fm-sessionstart-run.sh) printf '%s\n' DROID_SESSIONSTART_OUTPUT ;;
  fm-arm-pretool-check.sh) printf '%s\n' DROID_PRETOOL_DENY >&2; exit 2 ;;
  fm-turnend-guard.sh) printf '%s\n' DROID_STOP_BLOCK >&2; exit 2 ;;
esac
SH
    chmod +x "$dir/bin/$script"
  done
}

make_ab_probe_root() {
  local dir=$1 script
  mkdir -p "$dir/bin"
  for script in fm-sessionstart-run.sh fm-arm-pretool-check.sh fm-turnend-guard.sh; do
    cat > "$dir/bin/$script" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\t%s\t%s\n' "${0##*/}" "$*" "$payload" >> "$HOOK_AB_LOG"
case "${0##*/}" in
  fm-sessionstart-run.sh) printf '%s\n' SHARED_SESSIONSTART_OUTPUT ;;
  fm-arm-pretool-check.sh) printf '%s\n' SHARED_PRETOOL_BLOCK >&2; exit 21 ;;
  fm-turnend-guard.sh) printf '%s\n' SHARED_STOP_BLOCK >&2; exit 22 ;;
esac
SH
    chmod +x "$dir/bin/$script"
  done
}

run_ab_registered_hook() {
  local settings=$1 event=$2 project_var=$3 root=$4 log=$5 payload=$6 command
  command=$(jq -r --arg event "$event" '.hooks[$event][0].hooks[0].command' "$settings")
  printf '%s' "$payload" \
    | env "$project_var=$root" HOOK_AB_LOG="$log" GROK_AGENT= GROK_HOOK_EVENT= bash -c "$command"
}

run_registered_hook() {  # <event> <payload> <root> <log>
  local event=$1 payload=$2 root=$3 log=$4 command
  command=$(jq -r --arg event "$event" '.hooks[$event][0].hooks[0].command' "$SETTINGS")
  printf '%s' "$payload" | DROID_PROJECT_DIR="$root" DROID_PROBE_LOG="$log" bash -c "$command"
}

test_commands_anchor_and_preserve_transport() {
  local root="$TMP_ROOT/root" log="$TMP_ROOT/invoked" payload out status
  make_probe_root "$root"

  payload='{"hook_event_name":"SessionStart","source":"startup"}'
  out=$(run_registered_hook SessionStart "$payload" "$root" "$log")
  [ "$out" = DROID_SESSIONSTART_OUTPUT ] \
    || fail "Droid SessionStart registration did not preserve hook stdout"

  payload='{"hook_event_name":"PreToolUse","tool_name":"Execute","tool_input":{"command":"bin/fm-watch-arm.sh &"}}'
  set +e
  out=$(run_registered_hook PreToolUse "$payload" "$root" "$log" 2>&1)
  status=$?
  set -e
  expect_code 2 "$status" "Droid PreToolUse registration must preserve checker exit 2"
  [ "$out" = DROID_PRETOOL_DENY ] \
    || fail "Droid PreToolUse registration did not preserve checker stderr"

  payload='{"hook_event_name":"Stop","stop_hook_active":false}'
  set +e
  out=$(run_registered_hook Stop "$payload" "$root" "$log" 2>&1)
  status=$?
  set -e
  expect_code 2 "$status" "Droid Stop registration must preserve guard exit 2"
  [ "$out" = DROID_STOP_BLOCK ] \
    || fail "Droid Stop registration did not preserve guard stderr"

  grep -Fqx $'fm-sessionstart-run.sh\t{"hook_event_name":"SessionStart","source":"startup"}' "$log" \
    || fail "Droid SessionStart command did not pass the exact payload"
  grep -Fqx $'fm-arm-pretool-check.sh\t{"hook_event_name":"PreToolUse","tool_name":"Execute","tool_input":{"command":"bin/fm-watch-arm.sh &"}}' "$log" \
    || fail "Droid PreToolUse command did not pass the exact payload"
  grep -Fqx $'fm-turnend-guard.sh\t{"hook_event_name":"Stop","stop_hook_active":false}' "$log" \
    || fail "Droid Stop command did not pass the exact payload"
  pass "Droid tracked hook commands anchor through DROID_PROJECT_DIR and preserve stdin, output, and status"
}

test_pretool_registration_is_inert_in_crewmate_worktrees() {
  local primary="$TMP_ROOT/primary" child="$TMP_ROOT/child" command payload out err status
  mkdir -p "$primary/bin" "$primary/state"
  cp "$ROOT/bin/fm-arm-pretool-check.sh" \
     "$ROOT/bin/fm-arm-command-policy.mjs" \
     "$ROOT/bin/fm-hook-host-lib.sh" \
     "$ROOT/bin/fm-primary-scope-lib.sh" \
     "$primary/bin/"
  printf '# fixture\n' > "$primary/AGENTS.md"
  git -C "$primary" init -q
  git -C "$primary" config user.name fixture
  git -C "$primary" config user.email fixture@example.test
  git -C "$primary" add AGENTS.md bin
  git -C "$primary" commit -qm fixture
  command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$SETTINGS")
  payload='{"hook_event_name":"PreToolUse","tool_name":"Execute","tool_input":{"command":"bin/fm-watch-arm.sh &"}}'
  out="$TMP_ROOT/primary.out"
  err="$TMP_ROOT/primary.err"

  set +e
  printf '%s' "$payload" | DROID_PROJECT_DIR="$primary" FM_HOME="$primary" \
    bash -c "$command" > "$out" 2> "$err"
  status=$?
  set -e
  expect_code 2 "$status" "Droid primary PreToolUse registration must deny unsafe watcher arming"
  jq -e '.decision == "deny"' "$out" >/dev/null \
    || fail "Droid primary PreToolUse registration did not preserve its deny response"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$err" >/dev/null \
    || fail "Droid primary PreToolUse registration did not preserve its deny diagnostic"

  git -C "$primary" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/state"
  : > "$out"
  : > "$err"
  set +e
  printf '%s' "$payload" | DROID_PROJECT_DIR="$child" FM_HOME="$primary" \
    bash -c "$command" > "$out" 2> "$err"
  status=$?
  set -e
  expect_code 0 "$status" "Droid PreToolUse registration must be inert in a crewmate worktree"
  [ ! -s "$out" ] || fail "Droid crewmate-scope no-op wrote stdout: $(cat "$out")"
  [ ! -s "$err" ] || fail "Droid crewmate-scope no-op wrote stderr: $(cat "$err")"
  pass "Droid PreToolUse registration denies only in genuine primary homes"
}

test_claude_shaped_hook_contract
test_registration_inventory
test_commands_anchor_and_preserve_transport
test_pretool_registration_is_inert_in_crewmate_worktrees
