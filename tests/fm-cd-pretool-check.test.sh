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
  printf '%s\n' '# primary fixture' > "$PRIMARY/AGENTS.md"
  cp "$ROOT/bin/fm-cd-pretool-check.sh" "$PRIMARY/bin/"
  cp "$ROOT/bin/fm-cd-command-policy.mjs" "$PRIMARY/bin/"
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
  assert_present "$ROOT/.grok/hooks/fm-primary-cd-check.json" "Grok cd hook snippet is missing"
  assert_present "$ROOT/.codex/hooks.json" "Codex hook snippet is missing"
  jq -e '.hooks.PreToolUse | any(.[]; any(.hooks[]?; .type == "command" and (.command | contains("fm-cd-pretool-check.sh"))))' \
    "$ROOT/.grok/hooks/fm-primary-cd-check.json" >/dev/null \
    || fail "Grok hook has no executable cd-guard command"
  jq -e '.hooks.PreToolUse | any(.[]; any(.hooks[]?; .type == "command" and (.command | contains("fm-cd-pretool-check.sh"))))' \
    "$ROOT/.codex/hooks.json" >/dev/null \
    || fail "Codex hook has no executable cd-guard command"
  pass "parsed Grok and Codex hook contracts point at the cd guard"
}

test_primary_blocks_persistent_project_cd
test_primary_blocks_dynamic_project_cd
test_subshell_worktree_and_unrelated_commands_are_allowed
test_stdin_transport_blocks_harness_payload
test_tracked_hook_snippets_are_present
