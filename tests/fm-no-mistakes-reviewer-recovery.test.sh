#!/usr/bin/env bash
# Static contract tests for reviewer-health routing and incident visibility.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/no-mistakes-reviewer-recovery/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

test_precise_trigger_and_metadata() {
  assert_present "$SKILL" "reviewer recovery skill is missing"
  assert_grep 'name: no-mistakes-reviewer-recovery' "$SKILL" "skill metadata has the wrong name"
  assert_grep 'user-invocable: false' "$SKILL" "reviewer recovery skill must not be user-invocable"
  assert_grep '  internal: true' "$SKILL" "reviewer recovery skill must be internal"
  assert_grep "\`no-mistakes-reviewer-recovery\` - load before starting no-mistakes validation when Claude is degraded, and on a review or document step that is quiet, failed, or cancelled." "$AGENTS" \
    "AGENTS.md lost the reviewer recovery trigger"
  pass "reviewer recovery skill has one precise firstmate trigger"
}

test_preflight_preserves_shared_daemon_safety() {
  for phrase in \
    'no-mistakes axi run --help' \
    'run-scoped agent override' \
    'claude auth status --json' \
    'quota-axi --json' \
    'Codex-only' \
    'no lane has an active pipeline run' \
    'restart the shared daemon once' \
    "run \`no-mistakes doctor\`" \
    'Never perform that recovery while any lane is active' \
    'never ask a crewmate to perform it' \
    'Configuration written after the daemon started is not proof' \
    'Compare the configuration modification time with the daemon start record' \
    'If the installed help lacks a run-scoped agent override' \
    'safe fallback is shared-daemon routing only'; do
    assert_grep "$phrase" "$SKILL" "reviewer recovery preflight lost '$phrase'"
  done
  pass "reviewer recovery preflight protects the shared daemon"
}

test_failure_is_loud_and_diagnosable() {
  for phrase in \
    'bin/fm-crew-state.sh <crew-id>' \
    'state: failed · source: run-step' \
    'state/<crew-id>.meta' \
    "capture its \`id\` as \`<run-id>\`" \
    'no-mistakes axi status --run <run-id>' \
    'no-mistakes axi logs --run <run-id> --step review --full' \
    "or the corresponding \`document\` log" \
    'start and completion timestamps' \
    'selected agent sequence' \
    'terminal error' \
    'context canceled' \
    'do not loop restarts' \
    'github.com/kunchenguid/no-mistakes/issues/474'; do
    assert_grep "$phrase" "$SKILL" "reviewer recovery diagnostics lost '$phrase'"
  done
  pass "reviewer incidents are visible from attributed run state and logs"
}

test_precise_trigger_and_metadata
test_preflight_preserves_shared_daemon_safety
test_failure_is_loud_and_diagnosable
