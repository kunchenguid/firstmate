#!/usr/bin/env bash
# Static regressions for the explicitly selected alternate no-mistakes path.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

alternate_contract() {
  awk '
    /^## Alternate no-mistakes delivery$/ { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "$ROOT/.agents/skills/task-lifecycle/SKILL.md"
}

test_worker_owns_synchronous_driver() {
  local contract
  contract=$(alternate_contract)

  assert_contains "$contract" 'The task worker that starts a no-mistakes run drives the pipeline' \
    "alternate contract does not assign the run to its initiating task worker"
  assert_contains "$contract" "owns every \`no-mistakes axi run\` and \`no-mistakes axi respond\` call through the next gate or outcome" \
    "alternate contract does not assign every synchronous driver call to the task worker"
  assert_contains "$contract" 'process every synchronous return until completion or a genuinely new escalation' \
    "alternate contract does not require every synchronous return to be processed"
  pass "alternate validation assigns the synchronous driver loop to its task worker"
}

test_firstmate_never_responds_for_crew_run() {
  local contract
  contract=$(alternate_contract)

  assert_contains "$contract" 'Firstmate never invokes `no-mistakes axi respond` for a crew-owned run' \
    "alternate contract permits Firstmate to respond for a crew-owned run"
  pass "alternate validation forbids Firstmate from responding for a crew-owned run"
}

test_alternate_is_not_the_active_default() {
  assert_grep 'Use this section only when the project' "$ROOT/.agents/skills/task-lifecycle/SKILL.md" \
    "alternate validation lacks its selected-mode boundary"
  assert_grep 'it is not the active default' "$ROOT/.agents/skills/task-lifecycle/SKILL.md" \
    "alternate validation is still presented as active"
  assert_no_grep 'no-mistakes' "$ROOT/AGENTS.md" \
    "always-loaded instructions present the alternate as active"
  pass "no-mistakes remains supported only behind explicit project selection"
}

test_worker_owns_synchronous_driver
test_firstmate_never_responds_for_crew_run
test_alternate_is_not_the_active_default
