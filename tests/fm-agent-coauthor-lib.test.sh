#!/usr/bin/env bash
# Tests for bin/fm-agent-coauthor-lib.sh: the shared scan that fm-pr-merge.sh
# and fm-merge-local.sh both use to refuse a merge whose commits carry a
# "Co-authored-by:" trailer naming an AI agent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-agent-coauthor-lib.sh
. "$ROOT/bin/fm-agent-coauthor-lib.sh"

if printf 'fix: do a thing\n\nSome unrelated body text.\n' | fm_agent_coauthor_scan; then
  pass "fm-agent-coauthor-lib: a commit with no co-author trailer is allowed"
else
  fail "fm-agent-coauthor-lib: a commit with no co-author trailer is allowed"
fi

if printf 'feat: add x\n\nCo-authored-by: Jane Doe <jane@example.com>\n' | fm_agent_coauthor_scan; then
  pass "fm-agent-coauthor-lib: a human co-author trailer is allowed"
else
  fail "fm-agent-coauthor-lib: a human co-author trailer is allowed"
fi

if printf 'feat: add x\n\nCo-authored-by: Claude Sonnet 5 <noreply@anthropic.com>\n' | fm_agent_coauthor_scan 2>/dev/null; then
  fail "fm-agent-coauthor-lib: a Claude co-author trailer is refused"
else
  pass "fm-agent-coauthor-lib: a Claude co-author trailer is refused"
fi

if printf 'fix: y\n\nCo-Authored-By: some-bot <noreply@openai.com>\n' | fm_agent_coauthor_scan 2>/dev/null; then
  fail "fm-agent-coauthor-lib: case-varied trailer and an OpenAI address are still caught"
else
  pass "fm-agent-coauthor-lib: case-varied trailer and an OpenAI address are still caught"
fi

if printf 'fix: multi\n\nCo-authored-by: Jane Doe <jane@example.com>\nCo-authored-by: Codex <codex@example.com>\n' \
    | fm_agent_coauthor_scan 2>/dev/null; then
  fail "fm-agent-coauthor-lib: one offending trailer among several is still caught"
else
  pass "fm-agent-coauthor-lib: one offending trailer among several is still caught"
fi
