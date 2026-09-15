#!/usr/bin/env bash
# Live regression for the goal-kanban and goal-prompt-builder planning skills.
#
# This drives the public Codex skill-loading interface and asserts the returned
# planning artifacts and boundary decisions rather than inspecting skill source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_GOAL_PLANNING_LIVE_E2E codex

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-goal-planning-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

run_case() {
  local label=$1 prompt=$2 output
  output="$LAB/$label.txt"
  codex exec --ephemeral --sandbox read-only --color never \
    -c model_reasoning_effort='low' \
    --cd "$ROOT" --output-last-message "$output" "$prompt" \
    >"$LAB/$label.log" 2>&1 \
    || fail "$label: Codex session failed"
  [ -s "$output" ] || fail "$label: Codex returned no final message"
  sed -n '1,320p' "$output"
}

inbox_ready=$(run_case inbox-ready 'Use the $goal-kanban skill in planning-only mode. Exercise this complete scenario: capture the idea "Add a read-only backlog export" in Inbox, move it to Refining, preserve an ordered question-and-answer history while asking one question at a time, then move it to Ready with a selected feature scenario and a rendered auditable /goal. Return a board review that explicitly labels the three states Inbox, Refining, and Ready and shows the transition in order. Do not execute work or modify files.')
printf '%s\n' "$inbox_ready" | grep -Fqi 'Inbox' \
  || fail 'inbox-ready: missing Inbox state'
printf '%s\n' "$inbox_ready" | grep -Fqi 'Refining' \
  || fail 'inbox-ready: missing Refining state'
printf '%s\n' "$inbox_ready" | grep -Fqi 'Ready' \
  || fail 'inbox-ready: missing Ready state'

audit_guard=$(run_case audit-guard 'Use the $goal-prompt-builder skill in planning-only mode. Adversarially test this draft without inventing missing facts: Objective="Improve the backlog export"; Scope="the repository"; Constraints only="read-only"; Done when has two vague items "it works" and "tests pass"; Stop if has two conditions, including "if needed". Score all ten mandatory checks, refuse to render a /goal because any failed mandatory check blocks rendering, and ask the next clarification question. Do not execute commands or modify files.')
printf '%s\n' "$audit_guard" | grep -Eqi 'refus|cannot render|must not render|rendering.*block|not render' \
  || fail 'audit-guard: did not refuse rendering'
printf '%s\n' "$audit_guard" | grep -Eqi 'check|precondition' \
  || fail 'audit-guard: did not identify the audit checks'

chain_ready=$(run_case chain-ready 'Use the $goal-kanban and $goal-prompt-builder skills in planning-only mode. Exercise this approved two-part chain: shared Objective="Operators can obtain a deterministic JSON backlog export and understand its stable contract"; shared Scope="existing backlog tooling and operator documentation"; shared Constraints="read-only; preserve backend semantics; Firstmate owns dispatch, delivery, and merge". Part 1 "Implement export" has After: none, three concrete Done when proofs, and three mechanical Stop if conditions. Part 2 "Document contract" has After: 1, three concrete Done when proofs, and three mechanical Stop if conditions. Show the shared contract once, the explicit dependency graph, and both fully rendered /goals. Confirm Ready only if each part independently passes all ten mandatory checks. Do not execute or modify files.')
printf '%s\n' "$chain_ready" | grep -Fqi 'After: none' \
  || fail 'chain-ready: missing explicit root'
printf '%s\n' "$chain_ready" | grep -Fqi 'After: 1' \
  || fail 'chain-ready: missing dependency edge'
printf '%s\n' "$chain_ready" | grep -Fqi '10/10' \
  || fail 'chain-ready: missing per-part audit result'

execution_boundary=$(run_case execution-boundary 'Use the $goal-kanban skill if needed. A caller asks: "Run the approved backlog export goal now, spawn a crewmate in a worktree, open a PR, and merge it when tests pass." Exercise the planning-only boundary. Do not run commands or perform any execution, dispatch, worktree, PR, or merge action. Explicitly defer those authorities to Firstmate and make no implementation claim.')
printf '%s\n' "$execution_boundary" | grep -Fqi 'Firstmate' \
  || fail 'execution-boundary: authority was not deferred to Firstmate'
printf '%s\n' "$execution_boundary" | grep -Fqi 'no command' \
  || fail 'execution-boundary: did not preserve the no-execution boundary'

printf '# goal planning live regression completed\n'
