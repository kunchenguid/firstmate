#!/usr/bin/env bash
# I3: fm-intake panel round-trip with stubbed seams. Both thinkers proceed ->
# proceed: line, exit 0, synthesis file. A revising thinker -> revise: with
# count, exit 2. Placeholder briefs are refused.
# Mutation (LEDGER_MUTATE=1): the revising stub emits proceed - the revise-path
# assertions then fail on a correct implementation.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-intake-lib.sh
. "$ROOT/bin/fm-intake-lib.sh"

TMP=$(fm_test_tmproot fm-wd-i3)
S="$TMP/state"; D="$TMP/data"; PROJ="$TMP/proj"
mkdir -p "$S" "$D/i3task" "$PROJ"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
printf '# Task\nBuild the widget.\n# Definition of done\nwidget test green.\n' > "$D/i3task/brief.md"

cat > "$TMP/think-proceed.sh" <<'SH'
#!/usr/bin/env bash
echo "Plan looks sound."
echo "PANEL: proceed - seam and DoD check out"
SH
REVISE_WORD=revise
[ "${LEDGER_MUTATE:-}" = 1 ] && REVISE_WORD=proceed
cat > "$TMP/think-revise.sh" <<SH
#!/usr/bin/env bash
echo "Plan has a hole."
echo "PANEL: $REVISE_WORD - the DoD is not machine-provable"
SH
chmod +x "$TMP/think-proceed.sh" "$TMP/think-revise.sh"
export FM_LENS_CMD="echo stub-lens-review"

# 1. both thinkers proceed -> proceed, exit 0, synthesis written
out=$(FM_INTAKE_CMD="$TMP/think-proceed.sh" "$ROOT/bin/fm-intake.sh" i3task "$PROJ" 2>&1); code=$?
expect_code 0 "$code" "both-proceed must exit 0"
f=$(fm_intake_file "$S" i3task)
assert_grep "panel: lens custom" "$f" "lens evidence recorded"
[ "$(fm_intake_last "$S" i3task)" = proceed ] || fail "last decision must be proceed"
assert_present "$D/i3task/intake-review.md" "synthesis written"
assert_present "$D/i3task/intake-architecture.md" "architecture thinker trace written"
assert_present "$D/i3task/intake-risk.md" "risk thinker trace written"

# 2. a revising thinker -> revise with count, exit 2 (fresh id)
mkdir -p "$D/i3rev"
printf '# Task\nBuild the other widget.\n' > "$D/i3rev/brief.md"
out=$(FM_INTAKE_CMD="$TMP/think-revise.sh" "$ROOT/bin/fm-intake.sh" i3rev "$PROJ" 2>&1); code=$?
expect_code 2 "$code" "revise must exit 2"
assert_grep "revise: (revise 1 of 2)" "$(fm_intake_file "$S" i3rev)" "revise recorded with count"

# 3. a brief still carrying {TASK} is refused before any panel runs
mkdir -p "$D/i3ph"
printf '# Task\n{TASK}\n' > "$D/i3ph/brief.md"
out=$(FM_INTAKE_CMD="$TMP/think-proceed.sh" "$ROOT/bin/fm-intake.sh" i3ph "$PROJ" 2>&1); code=$?
expect_code 1 "$code" "placeholder brief must be refused"
assert_contains "$out" "{TASK}" "refusal names the placeholder"

pass "I3 panel round-trip"
