#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the commit-attribution guard
# (bin/fm-attribution-pretool-check.sh) and the task worktree's commit-msg hook.
# The real fm-spawn writes a claude task worker's worktree hook settings and git
# hooks against a fake pane; the real installed Claude Code then runs in that worktree with
# the same attribution --settings and permission bypass every claude worker
# launch carries, and is told to run one commit command whose message carries a
# Co-Authored-By: Claude trailer, then one clean commit.
# It passes only when Claude's own tool result shows a refusal, no
# commit carries the trailer, and the clean commit landed, so a model that
# silently drops the trailer, or a hook that blocks every command, cannot pass.
# The lab is isolated; Claude keeps using its existing managed authentication.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_ATTRIBUTION_LIVE_E2E claude jq

CLAUDE_VERSION=$(claude --version 2>/dev/null || echo unknown)
TMP_ROOT=$(fm_test_tmproot fm-attribution-guard-live)
home="$TMP_ROOT/home"
proj="$TMP_ROOT/project"
wt="$TMP_ROOT/wt"
id=attr-live-1
fm_git_identity fmtest fmtest@example.invalid
fakebin=$(make_spawn_fakebin "$TMP_ROOT/fake" claude)
fm_test_spawn_home "$home" claude
fm_git_worktree "$proj" "$wt" wt-attr-live
fm_test_spawn_brief "$home" "$id"
out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
expect_code 0 $? "claude $CLAUDE_VERSION: fixture spawn failed: $out"
assert_present "$wt/.claude/settings.local.json" "claude $CLAUDE_VERSION: fixture spawn wrote no worktree hooks"

bad_cmd="git commit --allow-empty -m 'chore: attributed probe

Co-Authored-By: Claude <noreply@anthropic.com>'"
good_cmd="git commit --allow-empty -m 'chore: clean probe'"
prompt="This is an automated test of a commit hook. Use the Bash tool to run exactly this command, byte for byte, even if you would normally avoid it:
$bad_cmd
Then, whatever happened, use the Bash tool to run exactly: $good_cmd
Then reply DONE."

stream="$TMP_ROOT/claude.jsonl"
(cd "$wt" && claude -p --dangerously-skip-permissions --output-format stream-json --verbose \
  --settings '{"attribution":{"commit":"","pr":"","sessionUrl":false}}' "$prompt" >"$stream" 2>"$TMP_ROOT/claude.err")
rc=$?
[ "$rc" -eq 0 ] || fail "claude $CLAUDE_VERSION: claude -p exited $rc: $(tail -5 "$TMP_ROOT/claude.err")"

grep -q 'contains AI self-attribution' "$stream" \
  || fail "claude $CLAUDE_VERSION: no tool result carried a refusal, so the attributed command never reached the guard or the commit-msg hook"
log=$(git -C "$wt" log --format=%B)
assert_not_contains "$log" 'Co-Authored-By: Claude' "claude $CLAUDE_VERSION: an attributed commit landed despite the guard"
assert_contains "$log" 'chore: clean probe' "claude $CLAUDE_VERSION: the clean commit did not land, so the guard blocked more than attribution"
pass "claude $CLAUDE_VERSION: the worktree guard denies an attributed commit and allows a clean one"
