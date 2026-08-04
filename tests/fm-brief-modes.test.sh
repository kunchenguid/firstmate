#!/usr/bin/env bash
# Behavior tests for fm-brief.sh scaffolding across delivery modes.
#
# Regression coverage for the bash 3.2 parse bug: the mode-specific
# Definition-of-Done blocks used to be built with `DOD=$(cat <<EOF ... EOF)`, and
# the no-mistakes DoD text contains literal apostrophes ("no-mistakes'"). Inside a
# command substitution, bash 3.2 (the macOS system bash) tracks those as
# unbalanced single quotes and aborts the whole script with "unexpected EOF" - so
# the default (no-mistakes) brief never scaffolded at all. These tests assert that
# every delivery mode and the scout brief scaffold cleanly and carry their
# expected contract text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-brief-modes)

# A firstmate home with a registry pinning per-project delivery modes, so the
# mode-specific DoD branches are all exercised deterministically (no-mistakes is
# also the default when a project is absent from the registry).
HOME_D="$TMP_ROOT/home"
mkdir -p "$HOME_D/data"
cat > "$HOME_D/data/projects.md" <<'REG'
- nmrepo [no-mistakes] - test (added 2026-06-29)
- dprrepo [direct-PR] - test (added 2026-06-29)
- lorepo [local-only] - test (added 2026-06-29)
- tieredrepo [no-mistakes +tiered] - test (added 2026-07-07)
- tieredcirepo [no-mistakes +tiered +ci-tests] - test (added 2026-07-07)
REG

run_brief() {
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOME="$HOME_D" "$BRIEF" "$@" 2>&1
}

# The load-bearing regression: the no-mistakes default brief scaffolds without the
# apostrophe-driven parse error, and the full no-mistakes DoD lands in the file.
test_no_mistakes_brief_scaffolds() {
  local id=nm-default-z1 out status brief
  out=$(run_brief "$id" nmrepo --mode no-mistakes); status=$?
  expect_code 0 "$status" "no-mistakes brief should scaffold (status)"
  assert_not_contains "$out" "unexpected EOF" "no-mistakes brief tripped the bash 3.2 parse bug"
  assert_contains "$out" "mode=no-mistakes" "no-mistakes brief did not report its mode"
  brief="$HOME_D/data/$id/brief.md"
  assert_present "$brief" "no-mistakes brief file was not written"
  assert_grep "You then drive no-mistakes exactly as usual" "$brief" \
    "no-mistakes DoD body is missing from the brief"
  assert_grep "After /no-mistakes reports CI green" "$brief" \
    "no-mistakes DoD tail is missing from the brief"
  # Fallback for the axi-run #351/#396 first-run bug: the primary path is
  # `no-mistakes axi run --intent`, with the git-push-to-start workaround
  # documented as a fallback when that known bug is hit.
  assert_grep "git push no-mistakes fm/$id" "$brief" \
    "no-mistakes DoD is missing the git-push-to-start fallback"
  assert_grep "#351" "$brief" \
    "no-mistakes DoD is missing the axi-run bug reference"
  assert_grep "stale no-mistakes mirror ref" "$brief" \
    "no-mistakes DoD is missing the stale-mirror-ref blocked instruction"
  # The validation-discipline hard rule (drive ONE run, no thrash) must be baked in.
  assert_grep "Validation discipline (hard rule" "$brief" \
    "no-mistakes DoD is missing the validation-discipline hard rule"
  assert_grep "Drive ONE run to completion" "$brief" \
    "no-mistakes DoD is missing the one-run instruction"
  # The apostrophe-bearing DoD line lives in a read -r -d '' assembly, not the
  # $(cat <<EOF) command substitution the bash 3.2 bug lived in (guarded
  # separately by fm-brief.test.sh's heredoc-in-substitution regression test).
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "the no-mistakes guidance-reference sentence did not make it into the brief"
  pass "fm-brief: no-mistakes default brief scaffolds with its full DoD"
}

# The no-mistakes DoD supplies the run's intent (the crew's own Task section) as
# a base64 push option on the same starting push, instead of letting the
# pipeline spend an agent step re-inferring it from the transcript. Malformed
# or empty intent must never reach the gate: the snippet falls back to a plain
# push when extraction yields nothing.
test_no_mistakes_brief_supplies_intent() {
  local id=nm-intent-z6 brief b64
  run_brief "$id" nmrepo --mode no-mistakes >/dev/null
  brief="$HOME_D/data/$id/brief.md"
  assert_grep 'no-mistakes.intent=' "$brief" \
    "no-mistakes DoD is missing the intent push option"
  # shellcheck disable=SC2016  # single quotes are deliberate: $intent_b64 is literal brief text, matched not expanded
  assert_grep 'git push -o "no-mistakes.intent=$intent_b64" no-mistakes fm/'"$id" "$brief" \
    "no-mistakes DoD does not push the intent option to start the run"
  assert_grep "awk 'f&&/^# Setup\$/{exit} f; /^# Task\$/{f=1}'" "$brief" \
    "no-mistakes DoD is missing the Task-section extraction"
  assert_grep '| base64 | tr -d '"'"'\n'"'"'' "$brief" \
    "no-mistakes DoD is missing the base64 encode step"
  # Safe fallback: an empty/failed extraction must never push a malformed option.
  # shellcheck disable=SC2016  # single quotes are deliberate: $intent_b64 is literal brief text, matched not expanded
  assert_grep 'if [ -n "$intent_b64" ]; then' "$brief" \
    "no-mistakes DoD is missing the empty-intent guard"
  assert_grep "git push no-mistakes fm/$id" "$brief" \
    "no-mistakes DoD is missing the plain-push fallback for empty intent"
  # Extraction must run against this task's own absolute brief path.
  assert_grep "awk 'f&&/^# Setup\$/{exit} f; /^# Task\$/{f=1}' \"$brief\"" "$brief" \
    "no-mistakes DoD extraction does not target this task's own brief file"
  # The primary starting path (not just the fallback) must also name --intent.
  # shellcheck disable=SC2016  # single quotes are deliberate: backticks and quotes are literal brief text, matched not expanded
  assert_grep 'Start with `no-mistakes axi run --intent "<task text>"`' "$brief" \
    "no-mistakes DoD is missing the primary --intent starting path"

  # The extraction snippet, run for real against this brief once its {TASK}
  # placeholder is filled, must actually produce the Task text, base64-encoded
  # and single-line - proving the generated command works, not just its text.
  b64=$(awk 'f&&/^# Setup$/{exit} f; /^# Task$/{f=1}' "$brief" | base64 | tr -d '\n')
  case "$b64" in
    *$'\n'*) fail "extracted intent base64 is not single-line" ;;
  esac
  [ -n "$b64" ] || fail "extraction produced no intent from a brief with a Task section"
  assert_contains "$(printf '%s' "$b64" | base64 -d)" '{TASK}' \
    "decoded intent does not round-trip the brief's Task section"
  pass "fm-brief: no-mistakes DoD supplies base64 intent on the starting push with a safe fallback"
}

# A +tiered project's no-mistakes DoD swaps in the tier-aware starting-the-run
# snippet: it classifies the diff with bin/fm-tier.sh before pushing, trims the
# skip set only at tier=1, and never puts review or ci in that skip set. The
# per-project +ci-tests flag additionally adds `test` to the tier=1 skip list
# (captain decision: skip local test only for projects whose CI runs the same
# suite). An untiered project's brief must not mention tiering at all - the
# byte-for-byte-unchanged-by-default guarantee.
test_tiered_brief_uses_trimmed_skip_set() {
  local brief
  run_brief tier-z7 tieredrepo --mode no-mistakes --tiered on >/dev/null
  brief="$HOME_D/data/tier-z7/brief.md"
  assert_grep "risk/size-tiered validation enabled" "$brief" \
    "tiered DoD is missing its tiered-mode heading"
  assert_grep 'fm-tier.sh" .' "$brief" \
    "tiered DoD does not run the classifier against the crew's own worktree"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal brief text, matched not expanded
  assert_grep 'SKIP_OPT="-o no-mistakes.skip=document"' "$brief" \
    "tiered DoD (no ci-tests) should skip only document at tier=1"
  assert_no_grep "no-mistakes.skip=document,test" "$brief" \
    "tiered DoD without +ci-tests must not also skip test"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal brief text, matched not expanded
  assert_grep '`review` and `ci` are never skipped, at any tier' "$brief" \
    "tiered DoD is missing the review/ci-never-skipped guarantee"
  assert_grep "Report the tier line" "$brief" \
    "tiered DoD does not ask the crew to report its computed tier"
  assert_grep "tier=2 reason=classifier-failed" "$brief" \
    "tiered DoD does not treat a classifier failure as tier=2"

  run_brief tierci-z8 tieredcirepo --mode no-mistakes --tiered on --ci-tests on >/dev/null
  brief="$HOME_D/data/tierci-z8/brief.md"
  assert_grep "no-mistakes.skip=document,test" "$brief" \
    "tiered+ci-tests DoD should skip document and test at tier=1"

  brief="$HOME_D/data/nm-default-z1/brief.md"
  assert_no_grep "fm-tier.sh" "$brief" \
    "an untiered project's brief must not mention the tier classifier at all"
  pass "fm-brief: a +tiered project's DoD classifies the diff and trims only document (plus test under +ci-tests), never review/ci"
}

# direct-PR and local-only DoD blocks (also previously built via command
# substitution) scaffold and carry their mode-specific contract.
test_other_modes_scaffold() {
  local status
  run_brief dpr-z2 dprrepo --mode direct-PR >/dev/null; status=$?
  expect_code 0 "$status" "direct-PR brief should scaffold"
  assert_grep "ships **direct-PR**" "$HOME_D/data/dpr-z2/brief.md" \
    "direct-PR DoD missing from brief"

  run_brief lo-z3 lorepo --mode local-only >/dev/null; status=$?
  expect_code 0 "$status" "local-only brief should scaffold"
  assert_grep "ships **local-only**" "$HOME_D/data/lo-z3/brief.md" \
    "local-only DoD missing from brief"

  run_brief scout-z4 nmrepo --scout >/dev/null; status=$?
  expect_code 0 "$status" "scout brief should scaffold"
  assert_grep "the deliverable is a written report" "$HOME_D/data/scout-z4/brief.md" \
    "scout report contract missing from brief"
  pass "fm-brief: direct-PR, local-only, and scout briefs scaffold with their contracts"
}

# The assembled DoD must not introduce a trailing blank line versus the original
# command-substitution form (which stripped trailing newlines): the brief ends
# with exactly one newline after the final DoD sentence.
test_no_trailing_blank_line() {
  local id=nm-tail-z5 brief lastbytes
  run_brief "$id" nmrepo --mode no-mistakes >/dev/null
  brief="$HOME_D/data/$id/brief.md"
  lastbytes=$(tail -c 2 "$brief" | od -An -c | tr -d ' ')
  case "$lastbytes" in
    *'.\n') : ;;  # last line ends with a period + single newline, no extra blank line
    *) fail "no-mistakes brief has an unexpected trailing blank line (last bytes: $lastbytes)" ;;
  esac
  pass "fm-brief: assembled DoD keeps a single trailing newline (no extra blank line)"
}

test_no_mistakes_brief_scaffolds
test_no_mistakes_brief_supplies_intent
test_tiered_brief_uses_trimmed_skip_set
test_other_modes_scaffold
test_no_trailing_blank_line
