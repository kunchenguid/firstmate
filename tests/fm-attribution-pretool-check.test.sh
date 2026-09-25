#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for bin/fm-attribution-pretool-check.sh, the Bash PreToolUse
# guard that refuses AI self-attribution in a worker's commits and PRs, and for
# its wiring into a claude task worker's worktree hooks by bin/fm-spawn.sh.
#
# No harness is spawned: the guard is driven with Claude-shaped payloads, and
# the spawn case runs the real fm-spawn against a fake tmux pane and then runs
# the exact hook command it registered. The live proof that real Claude Code
# honors the hook's denial is tests/fm-attribution-guard-live.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-attribution-pretool-check)
GUARD="$ROOT/bin/fm-attribution-pretool-check.sh"

payload() {  # <command> [cwd]
  jq -cn --arg c "$1" --arg d "${2:-}" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}} + (if $d == "" then {} else {cwd:$d} end)'
}

guard_code() {  # <command> [cwd] -> prints the guard's exit status
  local rc
  payload "$@" | "$GUARD" >/dev/null 2>&1
  rc=$?
  printf '%s\n' "$rc"
}

expect_deny() {  # <command> <why>
  assert_equals 2 "$(guard_code "$1")" "guard did not deny: $2"
}

expect_allow() {  # <command> <why>
  assert_equals 0 "$(guard_code "$1")" "guard did not allow: $2"
}

test_denies_attributed_commit_and_pr_commands() {
  expect_deny $'git commit -m "fix: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>"' \
    "the exact trailer a real worker commit carried"
  expect_deny $'git commit -m "$(cat <<EOF\nfix\n\nCo-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>\nEOF\n)"' \
    "a heredoc commit message naming a Claude model"
  expect_deny $'git -C /some/where commit --amend -m "a\n\nco-authored-by: Codex <codex@openai.com>"' \
    "a lower-case trailer naming another AI through git -C"
  expect_deny $'git commit -m "a\n\nCo-Authored-By: Claude"' "a bare Claude trailer at the end of the message"
  expect_deny $'gh pr create --title x --body "stuff\n\n\xf0\x9f\xa4\x96 Generated with [Claude Code](https://claude.com/claude-code)"' \
    "a Generated with line in a PR body"
  expect_deny 'gh-axi pr edit 12 --body "see https://claude.ai/code/session_abc"' "a Claude session link through gh-axi"
  expect_deny $'git commit -m "x\n\nClaude-Session: abc"' "a Claude-Session trailer"
  pass "attributed commit and PR commands are denied"
}

test_allows_human_messages_and_reads() {
  expect_allow 'git commit -m "fix: a plain message"' "an ordinary commit"
  expect_allow $'git commit -m "a\n\nCo-Authored-By: Claude Dupont <claude@example.fr>"' "a human co-author named Claude"
  expect_allow $'git commit -m "a\n\nCo-Authored-By: Brian Aiken <brian@example.com>"' "a human whose name contains 'an ai'"
  expect_allow 'git log --format=%B | grep -i "Co-Authored-By: Claude"' "searching history for the pattern"
  expect_allow 'grep -rn "Co-Authored-By: Claude" docs' "grepping for the pattern outside git"
  expect_allow 'echo "Co-Authored-By: Claude <noreply@anthropic.com>" > notes.txt' "a command that writes no commit or PR"
  pass "human-written messages and read-only searches are allowed"
}

test_scans_message_files_the_command_names() {
  local dir=$TMP_ROOT/files
  mkdir -p "$dir"
  printf 'fix\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' >"$dir/msg.txt"
  printf 'fix: plain\n' >"$dir/clean.txt"
  expect_deny "git commit -F $dir/msg.txt" "an attributed message file passed to -F"
  expect_deny "gh pr create --title t --body-file=$dir/msg.txt" "an attributed --body-file=path"
  expect_allow "git commit -F $dir/clean.txt" "a clean message file"
  assert_equals 2 "$(guard_code 'git commit -F msg.txt' "$dir")" \
    "a relative message file was not resolved from the payload cwd"
  pass "message files named by the command are scanned, relative to the payload cwd"
}

test_transport_edges() {
  local out rc
  out=$(printf '' | "$GUARD" 2>&1)
  rc=$?
  expect_code 0 "$rc" "empty stdin must allow"
  printf 'not json: git commit -m "x Co-Authored-By: Claude <x>"' | "$GUARD" >/dev/null 2>&1
  expect_code 2 $? "unparsable stdin must be scanned as raw text rather than allowed"
  out=$("$GUARD" --command $'git commit -m "x\n\nCo-Authored-By: Claude <noreply@anthropic.com>"' 2>&1)
  rc=$?
  expect_code 2 "$rc" "--command mode must deny an attributed commit"
  assert_contains "$out" "Remove that text and run the command again" "the denial did not tell the model how to recover"
  out=$(payload $'git commit -m "x\n\nCo-Authored-By: Claude <a@b>"' | "$GUARD" 2>/dev/null)
  [ -z "$out" ] || fail "a denial must keep stdout empty for Claude, got: $out"
  pass "empty, unparsable, and --command inputs behave as documented"
}

test_claude_spawn_registers_the_guard() {
  local case_dir=$TMP_ROOT/spawn home proj wt fakebin out settings cmd rc id=attr-cl-1
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-attr
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  expect_code 0 $? "claude spawn should succeed: $out"
  settings="$wt/.claude/settings.local.json"
  assert_present "$settings" "claude spawn wrote no worktree hook settings"
  assert_equals Bash "$(jq -r '.hooks.PreToolUse[0].matcher' "$settings")" "the guard is not scoped to the Bash tool"
  cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "claude spawn registered no PreToolUse hook command"
  payload $'git commit -m "x\n\nCo-Authored-By: Claude <noreply@anthropic.com>"' | sh -c "$cmd" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "the registered hook command did not deny an attributed commit"
  payload 'git commit -m "x"' | sh -c "$cmd" >/dev/null 2>&1
  expect_code 0 $? "the registered hook command denied a clean commit"
  pass "a claude task spawn registers the attribution guard as a Bash PreToolUse hook"
}

test_denies_attributed_commit_and_pr_commands
test_allows_human_messages_and_reads
test_scans_message_files_the_command_names
test_transport_edges
test_claude_spawn_registers_the_guard
