#!/usr/bin/env bash
# Shared guard: refuse a merge whose commits carry a "Co-authored-by:" (or
# "Co-Authored-By:") trailer naming an AI agent, so the trailer is caught
# before it lands on a project's default branch rather than found after.
# This is a mechanical string check, not history rewriting: it never edits or
# strips a commit, it only decides whether the caller may proceed with a merge.
#
# Source this file, then pipe the candidate commit messages (one commit's full
# message per call is fine, or all of them concatenated) to:
#   fm_agent_coauthor_scan <<<"$commit_messages"
# It prints each offending trailer line to stderr and returns 1 if any is
# found, or returns 0 silently otherwise.

FM_AGENT_COAUTHOR_PATTERN='^(co-authored-by|co-author):.*(claude|anthropic|chatgpt|openai|copilot|codex|gemini|cursor-agent|noreply@anthropic\.com|noreply@openai\.com)'

fm_agent_coauthor_scan() {
  local hits line
  hits=$(grep -Eio "$FM_AGENT_COAUTHOR_PATTERN" || true)
  [ -z "$hits" ] && return 0
  echo "error: commit(s) carry an agent co-author trailer, which is never allowed:" >&2
  while IFS= read -r line; do
    echo "  $line" >&2
  done <<<"$hits"
  return 1
}
