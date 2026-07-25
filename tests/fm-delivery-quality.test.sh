#!/usr/bin/env bash
# Deterministic contract tests for model-routing precedence, concrete unavailable-
# model fallback, proportional validation, and browser/media evidence triggers.
# Single-quoted assertion needles deliberately retain literal Markdown backticks.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/delivery-quality/SKILL.md"
EXAMPLE="$ROOT/docs/examples/crew-dispatch.json"

assert_file_contains() {
  local file=$1 needle=$2 message=$3
  grep -F "$needle" "$file" >/dev/null || fail "$message"
}

assert_file_not_contains() {
  local file=$1 needle=$2 message=$3
  if grep -F "$needle" "$file" >/dev/null; then
    fail "$message"
  fi
}

test_trigger_and_precedence_contract() {
  assert_file_contains "$ROOT/AGENTS.md" \
    'load before writing any ship or scout instructions and before treating a PR as review-ready' \
    "AGENTS.md lost the delivery-quality load trigger"
  assert_file_contains "$SKILL" \
    'an explicit per-task captain instruction, then the best-fit `config/crew-dispatch.json` rule, then its configured default, then the static crew harness' \
    "dispatch precedence no longer keeps explicit captain instructions first"
  assert_file_contains "$SKILL" \
    'including its requested harness or interface, model, and effort axes' \
    "explicit per-task interface and model requests no longer override standing routes"
  assert_file_contains "$SKILL" \
    'A configured fallback never overrides an explicit per-task captain model instruction' \
    "unavailable-model fallback can override a per-task captain route"
  assert_file_not_contains "$SKILL" 'fm-dispatch-select.sh' \
    "delivery-quality reintroduced the vestigial selector"
  pass "delivery-quality is discoverable and preserves per-task routing precedence"
}

test_exact_standing_routes_and_fallbacks() {
  jq -e '
    def rule($text): [.rules[] | select(.when | test($text; "i"))][0];
    (rule("trivial") | .use == {harness:"pi",model:"anthropic/claude-haiku-4-5-20251001",effort:"low"}) and
    (rule("well-understood backend") | .use == {harness:"pi",model:"openai/gpt-5.5",effort:"low"}) and
    (rule("substantive frontend implementation whose") | .use == {harness:"pi",model:"anthropic/claude-opus-5",effort:"high"}) and
    (rule("substantive frontend implementation whose") | .fallback == {harness:"pi",model:"openai/gpt-5.6-sol",effort:"high"}) and
    (rule("focused cross-model validation") | .use == {harness:"pi",model:"openai/gpt-5.6-sol",effort:"high"}) and
    (rule("medium engineering") | .use == {harness:"pi",model:"openai/gpt-5.6-sol",effort:"medium"}) and
    (rule("complex") | .use == {harness:"pi",model:"openai/gpt-5.6-sol",effort:"high"}) and
    (.rules | all((.fallback | type) == "object" and (.fallback.model | type) == "string"))
  ' "$EXAMPLE" >/dev/null || fail "copyable dispatch config lost an exact preferred route or concrete fallback"
  assert_file_contains "$ROOT/docs/verification/model-routing.md" 'claude-opus-5' \
    "verification record lost Claude Opus 5 evidence"
  assert_file_contains "$ROOT/docs/verification/model-routing.md" 'gpt-5.5' \
    "verification record lost GPT-5.5 evidence"
  assert_file_contains "$ROOT/docs/verification/model-routing.md" 'gpt-5.6-sol' \
    "verification record lost GPT-5.6 evidence"
  pass "copyable config carries exact locally verified routes and concrete fallbacks"
}

test_proportional_validation_and_visual_triggers() {
  assert_file_contains "$SKILL" \
    'It gets no extra worker, broad review, browser pass, screenshot, or video unless the changed behavior itself makes one materially useful.' \
    "trivial work no longer has a cheap validation ceiling"
  assert_file_contains "$SKILL" \
    'use one focused validation scout on Pi and `openai/gpt-5.6-sol` when it can answer a distinct correctness' \
    "focused cross-model validation has no exact bounded scout route"
  assert_file_contains "$SKILL" \
    'Do not turn it into a second generic code reviewer, repeat checks already answered by the implementation worker, or add another review after it.' \
    "focused cross-model validation can become redundant ceremony"
  assert_file_contains "$SKILL" \
    'For `direct-PR`, push only the task branch and open or update its PR through `gh-axi`; never push the default branch and never merge.' \
    "direct delivery lost its task-branch PR boundary"
  assert_file_contains "$SKILL" \
    'Require browser verification with `chrome-devtools-axi` for user-facing behavior when a real browser can materially validate the changed result.' \
    "browser verification trigger changed"
  assert_file_contains "$SKILL" \
    'Require a screenshot in a frontend PR when it materially improves review' \
    "screenshot trigger changed"
  assert_file_contains "$SKILL" \
    'Require video only when motion, interaction, responsiveness over time, or a state transition is materially clearer in motion' \
    "video trigger changed"
  assert_file_contains "$SKILL" \
    'Do not commit disposable screenshots or recordings unless that existing owner requires committed evidence.' \
    "disposable evidence can be committed without an owner"
  assert_file_contains "$SKILL" \
    'including CodeRabbit when the repository configures it or it has posted on the PR' \
    "automated review reconciliation lost CodeRabbit"
  assert_file_contains "$SKILL" \
    'make one final refresh after required CI turns green and then treat its absence as non-blocking' \
    "optional automated review has no bounded absence behavior"
  pass "validation depth and visual evidence remain proportional to task-relevant value"
}

test_ship_brief_preserves_delivery_discipline() {
  local brief_script="$ROOT/bin/fm-brief.sh"
  assert_file_contains "$brief_script" '# Delivery discipline' \
    "ship brief lost its delivery discipline section"
  assert_file_contains "$brief_script" 'existing pre-commit hooks and quality gates' \
    "ship brief no longer preserves repository quality hooks"
  assert_file_contains "$brief_script" 'do not make drive-by changes' \
    "ship brief no longer forbids discovery-driven scope expansion"
  assert_file_contains "$brief_script" 'push only that branch' \
    "direct PR brief lost the task-branch push boundary"
  assert_file_contains "$brief_script" 'required CI, and configured review feedback are reconciled' \
    "direct PR brief reports ready before CI and review reconciliation"
  assert_file_contains "$ROOT/AGENTS.md" 'reconcile required CI and configured review, then report the concise review-ready outcome' \
    "always-loaded lifecycle still treats PR creation as review-ready"
  assert_file_contains "$ROOT/AGENTS.md" 'clean branch without push or PR' \
    "always-loaded lifecycle lost the local-only boundary"
  pass "ship brief scaffolding carries the compact worker-facing delivery invariants"
}

test_trigger_and_precedence_contract
test_exact_standing_routes_and_fallbacks
test_proportional_validation_and_visual_triggers
test_ship_brief_preserves_delivery_discipline

echo "# all fm-delivery-quality tests passed"
