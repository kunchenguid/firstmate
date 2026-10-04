#!/usr/bin/env bash
# Behavioral regressions for generic worker/parent decision authority in fm-brief.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-ask-user-authority)

test_primary_and_secondmate_instruction_generation() {
  local home ship charter
  home="$TMP_ROOT/home"
  mkdir -p "$home/data"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$BRIEF" authority-worker sample --mode direct-PR >/dev/null 2>&1
  ship="$home/data/authority-worker/brief.md"
  assert_grep 'If a decision belongs above the implementation worker (product choices, destructive actions),' "$ship" \
    "generated implementation brief lets the worker own an above-scope decision"
  assert_grep 'Firstmate will reply with the decision.' "$ship" \
    "generated implementation brief bypasses the parent authority owner"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'A decision or blocker you opened stays open until a `resolved` line carrying its exact key lands' "$ship" \
    "generated implementation brief lets unrelated progress silently resolve a decision"
  assert_grep 'Delivery contract: mode=direct-PR' "$ship" \
    "generated implementation brief lost its native delivery contract"
  assert_grep 'Validate the change with the repository-owned checks appropriate to its risk and blast radius.' "$ship" \
    "generated implementation brief lost repository-owned validation"
  assert_no_grep 'no-mistakes' "$ship" \
    "generated implementation brief revived the retired workflow"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='Handle sample work.' \
    "$BRIEF" authority-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/authority-mate/brief.md"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'The local `AGENTS.md` is your job description' "$charter" \
    "generated secondmate charter does not load the tracked authority boundary"
  assert_no_grep 'continuous frame-by-frame monitoring' "$charter" \
    "generated secondmate charter duplicated the detailed authority procedure"
  pass "primary workers and secondmates receive the authority rule through generated instructions"
}

test_primary_and_secondmate_instruction_generation
