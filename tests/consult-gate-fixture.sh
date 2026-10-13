#!/usr/bin/env bash
# tests/consult-gate-fixture.sh - seed the stored ChatGPT consultation prompt
# that bin/fm-consult-gate-lib.sh's dispatch-time gate reads before a ship or
# scout launch.
#
# Source this from a suite that builds its own spawn world:
#   # shellcheck source=tests/consult-gate-fixture.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/consult-gate-fixture.sh"
# tests/lib.sh sources it for every suite that sources that, so most suites
# already have it; a suite that keeps its own standalone world (the Herdr e2e
# suites, which source only tests/herdr-test-safety.sh) sources it directly.
#
# A seeded record is what the gate reads as "the consultation already ran", so a
# fixture behaves the same whether or not a bridge answers on the machine and no
# launch pays a channel probe. The seed is skipped when a record already exists,
# so a case that writes its own stage keeps it.

# fm_test_seed_consult_record_at <data-dir> <id> [phase] [prompt]
# Seed <data-dir>/<id>/chatgpt-loop.json with a non-empty prompt for the stage
# the phase names - audit_prompt and plan both, so either stage in play reads as
# satisfied.
fm_test_seed_consult_record_at() {
  local data=$1 id=$2 phase=${3:-audit-dispatch} prompt=${4:-seeded ChatGPT consultation prompt for $2}
  local file="$data/$id/chatgpt-loop.json"
  if [ -e "$file" ] || [ -L "$file" ]; then
    return 0
  fi
  mkdir -p "$data/$id"
  jq -n --arg t "$id" --arg p "$phase" --arg a "$prompt" --arg u "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{task_id: $t, phase: $p, audit_prompt: $a, plan: $a, updated_at: $u}' >"$file"
}

# fm_test_seed_consult_record <home> <id> [phase] [prompt]
# The same seed for a home whose data directory is the usual <home>/data.
fm_test_seed_consult_record() {
  fm_test_seed_consult_record_at "$1/data" "$2" "${3:-}" "${4:-}"
}
