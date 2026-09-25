#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for bin/fm-attribution-pretool-check.sh, the matcher that
# refuses AI self-attribution in a worker's commits and PRs, for the task
# worktree commit-msg hook that runs it on every harness, and for its wiring
# into a claude task worker's worktree PreToolUse hooks by bin/fm-spawn.sh.
#
# No harness is spawned: the guard is driven with Claude-shaped payloads, and
# the spawn cases run the real fm-spawn against a fake tmux pane, then run the
# exact PreToolUse command it registered and make real git commits in the task
# worktree, its primary checkout, and a sibling worktree. The live proof that
# real Claude Code is refused is tests/fm-attribution-guard-live-e2e.test.sh.
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
  expect_allow $'git commit -m "a\n\nCo-authored-by: Devin Smith <devin@example.com>"' "a human co-author named Devin"
  expect_allow $'git commit -m "a\n\nCo-authored-by: Kimi Raikkonen <k@example.fi>"' "a human co-author named Kimi"
  expect_allow $'git commit -m "a\n\nCo-authored-by: Gemini Grok <gg@example.org>"' "a human co-author with agent-like names"
  expect_deny $'git commit -m "a\n\nCo-authored-by: devin-ai-integration[bot] <158243242+devin-ai-integration[bot]@users.noreply.github.com>"' \
    "Devin's bot account"
  expect_deny $'git commit -m "a\n\nCo-authored-by: Cursor Agent <cursoragent@cursor.com>"' "Cursor's agent address"
  expect_deny $'git commit -m "a\n\nCo-authored-by: Gemini CLI <gemini@example.com>"' "a Gemini product qualifier"
  expect_allow 'gh pr list --search "Generated with Claude Code"' "a gh pr search that quotes the pattern"
  expect_allow 'gh pr view 12 --json body | grep -ci "co-authored-by: claude <x>"' "a gh pr read piped into a search"
  expect_allow 'gh api -X GET search/issues -f q="Generated with Claude Code"' "a GET gh api search with fields"
  expect_allow 'gh api repos/o/r/pulls/1 --jq ".body" | grep "Generated with Claude Code"' "a plain GET gh api read"
  expect_deny 'gh -R o/r pr create --title t --body "Generated with Claude Code"' "a gh pr create after -R"
  expect_deny 'gh api -X PATCH repos/o/r/pulls/1 --input body.json -f body="Generated with Claude Code"' "a PATCH gh api write"
  expect_deny 'gh-axi api repos/o/r/issues/1/comments -f body="Generated with Claude Code"' "a gh api field write with the default POST"
  expect_deny 'gh api repos/o/r/pulls/1 -f body="to read, pass -X GET. Generated with Claude Code"' \
    "a default-POST gh api write whose quoted body mentions -X GET"
  expect_deny 'gh api -X GET --method PATCH repos/o/r/pulls/1 -f body="Generated with Claude Code"' \
    "a gh api call naming any non-GET method"
  expect_allow 'git log --format=%B | grep -i "Co-Authored-By: Claude"' "searching history for the pattern"
  expect_allow 'grep -rn "Co-Authored-By: Claude" docs' "grepping for the pattern outside git"
  expect_allow 'echo "Co-Authored-By: Claude <noreply@anthropic.com>" > notes.txt' "a command that writes no commit or PR"
  expect_allow 'git log --oneline --grep="Co-Authored-By: Claude <x>" | grep merge' "a git read whose pipeline names a writing verb"
  expect_allow 'echo "git commit" | grep -c "Co-Authored-By: Claude <x>"' "a writing verb that is only an argument"
  expect_deny $'cd /repo && git -c user.name=x --no-pager commit -m "a\n\nCo-Authored-By: Claude <x>"' \
    "a commit after a separator and git global options"
  expect_deny $'/usr/bin/git tag -a v1 -m "Generated with Claude Code"' "a tag through an absolute git path"
  pass "human-written messages and read-only searches are allowed"
}

test_scans_message_files_the_command_names() {
  local dir=$TMP_ROOT/files
  mkdir -p "$dir"
  printf 'fix\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' >"$dir/msg.txt"
  printf 'fix: plain\n' >"$dir/clean.txt"
  expect_deny "git commit -F $dir/msg.txt" "an attributed message file passed to -F"
  expect_deny "gh pr create --title t --body-file=$dir/msg.txt" "an attributed --body-file=path"
  printf 'fix\n\nGenerated with [Claude Code](https://claude.com/claude-code)\n' >"$dir/body.md"
  expect_allow "git commit -F $dir/clean.txt" "a clean message file"
  expect_deny "git commit --file=$dir/msg.txt" "an attributed --file=path"
  expect_deny "gh pr create -t t -F $dir/body.md" "an attributed gh -F body file"
  expect_deny "gh api repos/o/r/pulls -f title=t --field body=@$dir/body.md" "an attributed gh api body=@file field"
  expect_allow "git add $dir/msg.txt && git commit -m 'docs: refresh verification notes'" \
    "a clean message alongside a staged file that quotes the pattern"
  expect_allow "git commit $dir/msg.txt -m 'docs: plain'" "a clean message with a pathspec that quotes the pattern"
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
  assert_contains "$out" "Remove these lines and try again" "the denial did not tell the model how to recover"
  assert_contains "$out" "Co-Authored-By: Claude <noreply@anthropic.com>" "the denial did not name the line to remove"
  out=$(payload $'git commit -m "x\n\nCo-Authored-By: Claude <a@b>"' | "$GUARD" 2>/dev/null)
  [ -z "$out" ] || fail "a denial must keep stdout empty for Claude, got: $out"
  pass "empty, unparsable, and --command inputs behave as documented"
}

test_message_file_mode() {
  local dir=$TMP_ROOT/msgmode out
  mkdir -p "$dir"
  printf 'fix: x\n\nCo-authored-by: Claude Sonnet 4 <noreply@anthropic.com>\n' >"$dir/bad"
  printf 'fix: x\n# ------------------------ >8 ------------------------\n+Co-Authored-By: Claude <x>\n' >"$dir/verbose"
  out=$("$GUARD" --message-file "$dir/bad" 2>&1)
  expect_code 2 $? "--message-file must reject an attributed message"
  assert_contains "$out" "Co-authored-by: Claude Sonnet 4 <noreply@anthropic.com>" "the rejection did not name the line to remove"
  "$GUARD" --message-file "$dir/verbose" >/dev/null 2>&1
  expect_code 0 $? "a diff below the scissors line of git commit -v is not the message"
  "$GUARD" --message-file "$dir/missing" >/dev/null 2>&1
  expect_code 0 $? "a missing message file has nothing to reject"
  pass "--message-file rejects an attributed commit message and names what to remove"
}

# commit <dir> <message> [git commit args...] -> commits and returns git's status
commit_in() {
  local dir=$1 msg=$2
  shift 2
  git -C "$dir" commit -q --allow-empty -m "$msg" "$@" 2>"$TMP_ROOT/commit.err"
}

test_worktree_commit_msg_hook_on_any_harness() {
  local case_dir=$TMP_ROOT/hook home proj wt sib fakebin out id=attr-hook-1 bad
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  sib="$case_dir/sibling"
  bad=$'fix: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
  fm_git_identity fmtest fmtest@example.invalid
  fakebin=$(make_spawn_fakebin "$case_dir/fake" codex)
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" wt-hook
  git -C "$proj" worktree add --quiet -b sib-hook "$sib"
  mkdir -p "$proj/.git/hooks"
  printf '#!/bin/sh\necho "pre-commit $(pwd)" >>"%s"\n' "$case_dir/project-hooks.log" >"$proj/.git/hooks/pre-commit"
  printf '#!/bin/sh\necho "commit-msg $1" >>"%s"\n! grep -q "^WIP" "$1"\n' "$case_dir/project-hooks.log" >"$proj/.git/hooks/commit-msg"
  chmod +x "$proj/.git/hooks/pre-commit" "$proj/.git/hooks/commit-msg"
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  expect_code 0 $? "codex spawn should succeed: $out"

  commit_in "$wt" "$bad"
  expect_code 1 $? "an attributed -m commit in the task worktree was not rejected"
  assert_contains "$(cat "$TMP_ROOT/commit.err")" "Co-Authored-By: Claude <noreply@anthropic.com>" \
    "the commit-msg rejection did not name the line to remove"
  printf '%s\n' "$bad" >"$case_dir/msg.txt"
  git -C "$wt" commit -q --allow-empty -F "$case_dir/msg.txt" 2>/dev/null
  expect_code 1 $? "an attributed -F commit in the task worktree was not rejected"
  printf '#!/bin/sh\nprintf "fix: y\\n\\nCo-Authored-By: Codex <codex@openai.com>\\n" >"$1"\n' >"$case_dir/editor"
  chmod +x "$case_dir/editor"
  GIT_EDITOR="$case_dir/editor" git -C "$wt" commit -q --allow-empty 2>/dev/null
  expect_code 1 $? "an editor-written attributed commit in the task worktree was not rejected"
  printf 'quoted: Co-Authored-By: Claude <noreply@anthropic.com>\n' >"$wt/rule.md"
  git -C "$wt" add rule.md
  printf '#!/bin/sh\n{ echo "docs: quote the rule"; cat "$1"; } >"$1.new" && mv "$1.new" "$1"\n' >"$case_dir/verbose-editor"
  chmod +x "$case_dir/verbose-editor"
  GIT_EDITOR="$case_dir/verbose-editor" git -C "$wt" commit -q -v 2>"$TMP_ROOT/commit.err"
  expect_code 0 $? "a clean verbose commit of a file quoting the pattern was rejected: $(cat "$TMP_ROOT/commit.err")"
  assert_not_contains "$(git -C "$wt" log --format=%B)" "Co-Authored-By" "an attributed commit landed in the task worktree"
  : >"$case_dir/project-hooks.log"
  commit_in "$wt" "fix: clean"
  expect_code 0 $? "a clean commit in the task worktree was rejected: $(cat "$TMP_ROOT/commit.err")"
  assert_contains "$(cat "$case_dir/project-hooks.log")" "pre-commit $wt" "the project's own pre-commit did not run from the task worktree"
  assert_contains "$(cat "$case_dir/project-hooks.log")" "commit-msg " "the project's own commit-msg did not run from the task worktree"
  commit_in "$wt" "WIP: nope"
  expect_code 1 $? "the project's own commit-msg refusal did not propagate"

  commit_in "$proj" "$bad"
  expect_code 0 $? "the primary checkout's commits must not be guarded"
  commit_in "$sib" "$bad"
  expect_code 0 $? "a sibling worktree's commits must not be guarded"
  assert_equals "" "$(git -C "$proj" config --get core.hooksPath)" "the primary checkout sees a core.hooksPath"
  assert_equals "" "$(git -C "$sib" config --get core.hooksPath)" "the sibling worktree sees a core.hooksPath"

  git -C "$proj" config core.hooksPath .githooks
  mkdir -p "$wt/.githooks"
  printf '#!/bin/sh\necho "project-path commit-msg" >>"%s"\n' "$case_dir/project-hooks.log" >"$wt/.githooks/commit-msg"
  chmod +x "$wt/.githooks/commit-msg"
  : >"$case_dir/project-hooks.log"
  commit_in "$wt" "fix: clean again"
  expect_code 0 $? "a clean commit failed under the project's own core.hooksPath"
  assert_contains "$(cat "$case_dir/project-hooks.log")" "project-path commit-msg" \
    "the hook under the project's relative core.hooksPath did not run"
  commit_in "$wt" "$bad"
  expect_code 1 $? "the attribution check stopped once the project set its own core.hooksPath"
  git -C "$proj" config --unset core.hooksPath

  (. "$ROOT/bin/fm-worktree-hooks-lib.sh" && fm_worktree_git_hooks_clear "$wt")
  assert_equals "" "$(git -C "$wt" config --get core.hooksPath)" "teardown's clear left the task worktree's core.hooksPath"
  commit_in "$wt" "$bad"
  expect_code 0 $? "a cleared worktree still ran the attribution hook"
  pass "a task worktree on any harness rejects attributed commits, keeps the project's hooks, and leaves other checkouts alone"
}

# A project whose primary checkout is itself a linked worktree of a bare repo
# keeps core.bare=true in the shared config, which extensions.worktreeConfig
# would spread to every worktree, so the spawn must refuse before writing it.
test_bare_repo_layout_refuses_before_shared_config_change() {
  local case_dir=$TMP_ROOT/bare home bare primary wt sib fakebin out rc id=attr-bare-1 before
  home="$case_dir/home"
  bare="$case_dir/repo.git"
  primary="$case_dir/primary"
  wt="$case_dir/wt"
  sib="$case_dir/sibling"
  fm_git_identity fmtest fmtest@example.invalid
  fm_git_init_commit "$case_dir/seed"
  fm_git_add_origin "$case_dir/seed" "$case_dir/origin.git"
  git clone -q --bare "file://$(cd "$case_dir/origin.git" && pwd)" "$bare"
  git -C "$bare" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "$bare" fetch -q origin
  git -C "$bare" remote set-head origin main >/dev/null
  git -C "$bare" worktree add --quiet "$primary" main
  git -C "$bare" worktree add --quiet -b wt-bare "$wt"
  git -C "$bare" worktree add --quiet -b sib-bare "$sib"
  before=$(cat "$bare/config")
  fakebin=$(make_spawn_fakebin "$case_dir/fake" codex)
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$primary" --mode no-mistakes --yolo off)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn into a bare-repo layout must be refused: $out"
  assert_contains "$out" "core.bare or core.worktree" "the refusal did not name the layout"
  assert_equals "$before" "$(cat "$bare/config")" "the refused spawn changed the shared repo config"
  git -C "$primary" status --short >/dev/null 2>&1 || fail "git in the primary worktree broke"
  git -C "$wt" status --short >/dev/null 2>&1 || fail "git in the task worktree broke"
  git -C "$sib" status --short >/dev/null 2>&1 || fail "git in the sibling worktree broke"
  pass "a bare-repo layout refuses the spawn before any shared config change and leaves git working"
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
test_message_file_mode
test_worktree_commit_msg_hook_on_any_harness
test_bare_repo_layout_refuses_before_shared_config_change
test_claude_spawn_registers_the_guard
