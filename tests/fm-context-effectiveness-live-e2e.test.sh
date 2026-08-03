#!/usr/bin/env bash
# Credentialed Pi behavior checks for the agent-owned evidence and fresh-session contracts.
set -u

if [ "${FM_CONTEXT_EFFECTIVENESS_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CONTEXT_EFFECTIVENESS_LIVE_E2E=1 to run the credentialed Pi context-effectiveness regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL=${FM_CONTEXT_EFFECTIVENESS_MODEL:-openai-codex/gpt-5.6-sol}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-context-effectiveness-live.XXXXXX")

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
[ "$(pi --version)" = 0.83.0 ] || fail "live context fixture is measured only on exact Pi 0.83.0"

run_context_case() {
  local project=$1 prompt=$2
  (
    cd "$project" || exit 1
    pi --print --approve --no-session --no-extensions --no-skills --no-tools \
      --model "$MODEL" --thinking medium "$prompt"
  )
}

run_skill_case() {
  local project=$1 skill=$2 prompt=$3
  (
    cd "$project" || exit 1
    pi --print --approve --no-session --no-context-files --no-extensions --no-skills --no-tools \
      --skill "$skill" --model "$MODEL" --thinking medium "$prompt"
  )
}

test_root_keeps_only_the_evidence_trigger() {
  local actual mutant out
  actual="$LAB/root-actual"
  mutant="$LAB/root-mutant"
  mkdir -p "$actual" "$mutant"
  git -C "$actual" init -q
  git -C "$mutant" init -q
  cp "$ROOT/AGENTS.md" "$actual/AGENTS.md"
  cp "$ROOT/AGENTS.md" "$mutant/AGENTS.md"
  cat >> "$mutant/AGENTS.md" <<'MD'

## Duplicated evidence procedure mutation

Before a long report, read only its first three headings, call narrow GitHub fields, run bounded process output, and compare a live fingerprint before rereading.
MD

  out=$(run_context_case "$actual" \
    'This is a disposable read-only instruction-classification test, not an operational Firstmate session. Do not run startup, use tools, or take project action. Inspect only the root AGENTS.md instructions already in context. If the root contains only a load trigger and pointer for evidence consumption, return exactly these three lines: Captain, contract classification:; ROOT_EVIDENCE_OWNER=evidence-consumption; ROOT_PROCEDURE=TRIGGER_ONLY. If it contains any detailed targeted-report, narrow-GitHub, bounded-process, or changed-fingerprint procedure, replace the last value with DUPLICATED. Add nothing else.') \
    || fail "Pi root-owner classification failed"
  printf '%s\n' "$out" | grep -Fxq 'ROOT_EVIDENCE_OWNER=evidence-consumption' \
    || fail "root instructions did not expose the evidence-consumption owner: $out"
  printf '%s\n' "$out" | grep -Fxq 'ROOT_PROCEDURE=TRIGGER_ONLY' \
    || fail "root instructions duplicated the evidence procedure: $out"

  out=$(run_context_case "$mutant" \
    'This is a disposable read-only instruction-classification test, not an operational Firstmate session. Do not run startup, use tools, or take project action. Inspect only the root AGENTS.md instructions already in context. If the root contains only a load trigger and pointer for evidence consumption, return exactly these three lines: Captain, contract classification:; ROOT_EVIDENCE_OWNER=evidence-consumption; ROOT_PROCEDURE=TRIGGER_ONLY. If it contains any detailed targeted-report, narrow-GitHub, bounded-process, or changed-fingerprint procedure, replace the last value with DUPLICATED. Add nothing else.') \
    || fail "Pi root-owner mutation classification failed"
  printf '%s\n' "$out" | grep -Fxq 'ROOT_PROCEDURE=DUPLICATED' \
    || fail "root-owner behavior check survived a realistic duplicated-procedure mutation: $out"
  pass "Pi sees one evidence owner and rejects a realistic root-procedure duplication"
}

test_stow_refuses_context_only_state_and_emits_durable_resume_receipt() {
  local project out prompt
  project="$LAB/stow"
  mkdir -p "$project"
  git -C "$project" init -q
  prompt='Apply only the loaded internal stow completion contract to two already-swept hypothetical cases. Do not use tools or write files. Case A is within memory budget, but a binding merge authority, OPEN decision key route-choice, exact head abc123, validation receipt 47-tests-pass, active change src/sample.ts, and next action run-focused-tests exist only in this prompt. Case B has every goal, requirement, authority, decision state, exact head, active change, validation receipt, and next action durably recorded in data/checkpoint.md and structured data/backlog.md; its decision completion owner passed, nothing is active or queued, and the first next action is run the named focused test. Return exactly three lines and nothing else. Line one must be CASE_A_RESET_SAFE=<YES|NO>. Line two must be CASE_A_RESUME_POINTER=<EMITTED|WITHHELD>. Line three must use the literal format RESUME POINTER: Load <named durable files>; inspect <structured fleet source>; continue with <first next action>. and fill it with the supplied durable files, structured source, and next action.'
  out=$(run_skill_case "$project" "$ROOT/.agents/skills/stow/SKILL.md" "$prompt") \
    || fail "Pi stow completion classification failed"
  printf '%s\n' "$out" | grep -Fxq 'CASE_A_RESET_SAFE=NO' \
    || fail "stow called conversation-only authority reset-safe: $out"
  printf '%s\n' "$out" | grep -Fxq 'CASE_A_RESUME_POINTER=WITHHELD' \
    || fail "stow emitted a resume pointer for conversation-only state: $out"
  printf '%s\n' "$out" | grep -Eq '^RESUME POINTER: Load .*data/checkpoint\.md.*; inspect .*data/backlog\.md; continue with run the named focused test\.$' \
    || fail "stow omitted the copy-pasteable durable resume receipt: $out"

  pass "Pi stow refuses conversation-only authority and emits the required durable resume receipt"
}

test_small_summary_alone_cannot_prove_token_savings() {
  local project out
  project="$LAB/evidence"
  mkdir -p "$project"
  git -C "$project" init -q
  out=$(run_skill_case "$project" "$ROOT/.agents/skills/evidence-consumption/SKILL.md" \
    'Apply only the loaded evidence-consumption contract. A compaction artifact is 300 characters, but no next provider-reported input, current context usage, or cache fields were observed. Return exactly two lines and nothing else. Line one must be TOKEN_SAVINGS_CLAIM=<ACCEPTED|REJECTED>. Line two must be REQUIRED_EVIDENCE=<summary-only|provider-input-and-current-context>.') \
    || fail "Pi evidence classification failed"
  printf '%s\n' "$out" | grep -Fxq 'TOKEN_SAVINGS_CLAIM=REJECTED' \
    || fail "evidence skill accepted a small-summary-only savings claim: $out"
  printf '%s\n' "$out" | grep -Fxq 'REQUIRED_EVIDENCE=provider-input-and-current-context' \
    || fail "evidence skill omitted provider input and current context: $out"
  pass "Pi rejects token-saving claims based only on a small summary"
}

test_root_keeps_only_the_evidence_trigger
test_stow_refuses_context_only_state_and_emits_durable_resume_receipt
test_small_summary_alone_cannot_prove_token_savings
