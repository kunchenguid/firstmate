#!/usr/bin/env bash
# Behavior tests for /stow's inspect-then-update memory contract.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_stow_skill_task_note_contract() {
  local stow="$ROOT/.agents/skills/stow/SKILL.md"

  assert_grep 'tasks-axi show <id> --full' "$stow" "stow skill does not require inspecting task notes first"
  assert_grep 'tasks-axi update <id> --body-file <path>' "$stow" "stow skill does not require task body replacement"
  assert_grep '--archive-body' "$stow" "stow skill does not document recoverable task body archival"
  assert_grep 'Never append.' "$stow" "stow skill does not forbid append-first task notes"
  assert_no_grep 'carry that context into the replacement body' "$stow" "stow skill still preserves archive-only context in the replacement body"
  pass "stow skill task-note contract includes recoverable body archival"
}

test_agents_backlog_task_note_contract() {
  local agents="$ROOT/AGENTS.md"

  assert_grep 'tasks-axi show <id> --full' "$agents" "AGENTS.md does not require inspecting task notes first"
  assert_grep 'tasks-axi update <id> --body-file <path>' "$agents" "AGENTS.md does not require task body replacement"
  assert_grep '--archive-body' "$agents" "AGENTS.md does not document recoverable task body archival"
  assert_no_grep 'carry that context into the replacement body' "$agents" "AGENTS.md still preserves archive-only context in the replacement body"
  pass "AGENTS.md task-note contract includes recoverable body archival"
}

test_stow_skill_task_note_contract
test_agents_backlog_task_note_contract
