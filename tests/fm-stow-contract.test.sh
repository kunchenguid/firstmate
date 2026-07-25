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

  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep '`task-lifecycle` owns backlog operation' "$agents" \
    "AGENTS.md does not point conditional backlog operation to its owner"
  assert_grep 'Inspect the current item before replacing its considered body' "$lifecycle" \
    "task-lifecycle does not require inspecting task notes before replacement"
  assert_grep 'archive a superseded body when recoverability matters' "$lifecycle" \
    "task-lifecycle lost recoverable replacement semantics"
  assert_grep 'avoid append-only note growth' "$lifecycle" \
    "task-lifecycle lost no-append note hygiene"
  assert_no_grep 'tasks-axi show <id> --full' "$agents" \
    "AGENTS.md duplicates exact task-note read syntax from its conditional owner"
  assert_no_grep 'tasks-axi update <id> --body-file <path>' "$agents" \
    "AGENTS.md duplicates exact task-note update syntax from its conditional owner"
  pass "AGENTS.md points task-note hygiene to one conditional owner"
}

test_stow_skill_task_note_contract
test_agents_backlog_task_note_contract
