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
  local lifecycle="$ROOT/.agents/skills/task-lifecycle/SKILL.md"

  assert_grep 'Load `task-lifecycle` before any backlog mutation' "$agents" \
    "AGENTS.md does not trigger the backlog contract owner"
  assert_grep 'current `tasks-axi --help` own the backlog schema' "$lifecycle" \
    "task-lifecycle does not point exact task-note mechanics to the command owner"
  assert_grep 'Inspect the current task note before replacing its considered body' "$lifecycle" \
    "task-lifecycle does not require inspecting task notes before replacement"
  assert_grep 'archive the superseded body when recoverability matters rather than appending by default' "$lifecycle" \
    "task-lifecycle lost recoverable replacement and no-append semantics"
  assert_no_grep 'Inspect the current task note before replacing its considered body' "$agents" \
    "AGENTS.md duplicates task-note hygiene from its conditional owner"
  assert_no_grep 'tasks-axi show <id> --full' "$agents" \
    "AGENTS.md duplicates exact task-note read syntax from its conditional owner"
  assert_no_grep 'tasks-axi update <id> --body-file <path>' "$agents" \
    "AGENTS.md duplicates exact task-note update syntax from its conditional owner"
  pass "AGENTS.md triggers the conditional task-note owner without duplicating it"
}

test_stow_skill_task_note_contract
test_agents_backlog_task_note_contract
