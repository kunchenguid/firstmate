#!/usr/bin/env bash
# Contract tests for the primary-shell persistent-cd seatbelt.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-cd-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-cd-guard)
PRIMARY="$TMP_ROOT/primary"
WORKTREE="$TMP_ROOT/worktree"

make_primary() {
  mkdir -p "$PRIMARY"
  git -C "$PRIMARY" init -q
  git -C "$PRIMARY" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm init --allow-empty
  mkdir -p "$PRIMARY/projects/widget" "$PRIMARY/bin"
  mkdir -p "$PRIMARY/.codex"
  printf '%s\n' '# primary fixture' > "$PRIMARY/AGENTS.md"
  cp "$ROOT/bin/fm-cd-pretool-check.sh" "$PRIMARY/bin/"
  cp "$ROOT/bin/fm-cd-command-policy.mjs" "$PRIMARY/bin/"
  cp "$ROOT/.codex/hooks.json" "$PRIMARY/.codex/hooks.json"
  git -C "$PRIMARY" add AGENTS.md bin
  git -C "$PRIMARY" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm guard
  git -C "$PRIMARY" worktree add -q "$WORKTREE"
}

run_guard() {
  FM_ROOT_OVERRIDE="$1" "$GUARD" --command "$2" >/dev/null 2>"$TMP_ROOT/guard.err"
}

test_primary_blocks_persistent_project_cd() {
  assert_present "$GUARD" "cd guard is missing"
  assert_present "$ROOT/bin/fm-cd-command-policy.mjs" "cd policy is missing"
  make_primary
  local rc=0
  run_guard "$PRIMARY" 'cd projects/widget' || rc=$?
  [ "$rc" -eq 2 ] || fail "primary project cd was not denied (exit $rc)"
  grep -Fq 'persistent top-level directory change' "$TMP_ROOT/guard.err" || fail "deny output did not explain the safety boundary"
  pass "primary persistent cd into projects is denied"
}

test_primary_blocks_dynamic_project_cd() {
  local dynamic_command rc=0
  dynamic_command='cd "$FM_HOME/projects/widget"'
  run_guard "$PRIMARY" "$dynamic_command" || rc=$?
  [ "$rc" -eq 2 ] || fail "dynamic primary project cd was not denied (exit $rc)"
  pass "dynamic primary project cd is denied"
}

test_subshell_worktree_and_unrelated_commands_are_allowed() {
  local rc=0
  run_guard "$PRIMARY" '(cd projects/widget && printf ok)' || rc=$?
  [ "$rc" -eq 0 ] || fail "subshell cd was denied (exit $rc)"
  run_guard "$PRIMARY" 'cd /tmp' || rc=$?
  [ "$rc" -eq 0 ] || fail "unrelated cd was denied (exit $rc)"
  run_guard "$WORKTREE" 'cd projects/widget' || rc=$?
  [ "$rc" -eq 0 ] || fail "linked worktree cd was not inert (exit $rc)"
  pass "subshell, unrelated, and linked-worktree commands are allowed"
}

test_stdin_transport_blocks_harness_payload() {
  local output rc=0
  output=$(printf '%s' '{"toolInput":{"command":"cd projects/widget"}}' | FM_ROOT_OVERRIDE="$PRIMARY" "$GUARD" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "PreToolUse JSON payload was not denied (exit $rc)"
  assert_contains "$output" '"decision":"deny"' "PreToolUse deny response is missing"
  pass "PreToolUse JSON transport blocks the persistent project cd"
}

test_tracked_hook_snippets_are_present() {
  local config command out status
  [ -d "$PRIMARY/.git" ] || make_primary
  for config in "$ROOT/.grok/hooks/fm-primary-cd-check.json" "$ROOT/.codex/hooks.json"; do
    jq -e '.hooks.PreToolUse | type == "array" and any(.[]; (.hooks | type) == "array" and any(.hooks[]; .type == "command" and (.command | type == "string")))' \
      "$config" >/dev/null || fail "hook configuration is not a normalized command contract: $config"
    command=$(jq -r '[.hooks.PreToolUse[]?.hooks[]? | select(.type == "command") | .command] | if length == 1 then .[0] else empty end' "$config")
    [ -n "$command" ] || fail "hook command could not be normalized: $config"
    status=0
    if [ "${config##*/}" = hooks.json ]; then
      out=$(cd "$PRIMARY" && printf '{"toolInput":{"command":"cd projects/widget"}}\n' \
        | bash -lc "$command" 2>&1) || status=$?
    else
      out=$(cd "$PRIMARY" && GROK_WORKSPACE_ROOT="$PRIMARY" bash -c \
        'printf "%s\\n" "$1" | bash -lc "$2"' _ \
        '{"toolInput":{"command":"cd projects/widget"}}' "$command" 2>&1) || status=$?
    fi
    [ "$status" -eq 2 ] || fail "configured hook did not deny a persistent project cd: $config (exit $status)"
    assert_contains "$out" '"decision":"deny"' "configured hook denial did not expose the policy result: $config"
  done
  pass "configured Grok and Codex cd hooks execute the primary cd guard"
}

test_primary_blocks_persistent_project_cd
test_primary_blocks_dynamic_project_cd
test_subshell_worktree_and_unrelated_commands_are_allowed
test_stdin_transport_blocks_harness_payload
test_tracked_hook_snippets_are_present
