#!/usr/bin/env bash
# I4: the revise cap + fail-closed panel. Revise #2 escalates (no infinite
# revise loop); an at-cap intake escalates without invoking any thinker; a
# thinker that emits no PANEL line escalates and never proceeds.
# Mutation (LEDGER_MUTATE=1): seed NO prior revise - a correct cap then does
# NOT escalate on the next revise, failing the escalate assertions.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-intake-lib.sh
. "$ROOT/bin/fm-intake-lib.sh"

TMP=$(fm_test_tmproot fm-wd-i4)
S="$TMP/state"; D="$TMP/data"; PROJ="$TMP/proj"
mkdir -p "$S" "$D/i4task" "$D/i4cap" "$D/i4mute" "$PROJ"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
printf '# Task\nWidget A.\n' > "$D/i4task/brief.md"
printf '# Task\nWidget B.\n' > "$D/i4cap/brief.md"
printf '# Task\nWidget C.\n' > "$D/i4mute/brief.md"

cat > "$TMP/think-revise.sh" <<SH
#!/usr/bin/env bash
touch "$TMP/thinker-ran"
echo "PANEL: revise - still not provable"
SH
cat > "$TMP/think-mute.sh" <<'SH'
#!/usr/bin/env bash
echo "I have opinions but no verdict line."
SH
chmod +x "$TMP/think-revise.sh" "$TMP/think-mute.sh"
export FM_LENS_CMD="echo stub-lens"

# 1. seeded revise + revising panel -> revise #2 AND escalate, exit 3
[ "${LEDGER_MUTATE:-}" = 1 ] || fm_intake_append "$S" i4task revise "(revise 1 of 2) seeded"
FM_INTAKE_CMD="$TMP/think-revise.sh" "$ROOT/bin/fm-intake.sh" i4task "$PROJ" >/dev/null 2>&1; code=$?
V=$(fm_intake_file "$S" i4task)
expect_code 3 "$code" "second revise must exit 3 (escalate)"
assert_grep "revise: (revise 2 of 2)" "$V" "second revise line recorded before the escalate"
assert_grep "escalate: revise cap reached" "$V" "escalate recorded at the cap"
[ "$(fm_intake_last "$S" i4task)" = escalate ] || fail "last decision must be escalate"

# 2. already at the cap -> immediate escalate, thinkers never invoked
rm -f "$TMP/thinker-ran"
fm_intake_append "$S" i4cap revise "1"
fm_intake_append "$S" i4cap revise "2"
FM_INTAKE_CMD="$TMP/think-revise.sh" "$ROOT/bin/fm-intake.sh" i4cap "$PROJ" >/dev/null 2>&1; code=$?
expect_code 3 "$code" "at-cap intake must escalate immediately"
assert_absent "$TMP/thinker-ran" "thinkers must not run for an at-cap intake"
assert_grep "escalate: revise cap reached" "$(fm_intake_file "$S" i4cap)" "at-cap escalate recorded"

# 3. PANEL-less thinker -> escalate, never proceed
FM_INTAKE_CMD="$TMP/think-mute.sh" "$ROOT/bin/fm-intake.sh" i4mute "$PROJ" >/dev/null 2>&1; code=$?
expect_code 3 "$code" "PANEL-less thinker must exit 3"
V=$(fm_intake_file "$S" i4mute)
assert_grep "thinker infrastructure failure" "$V" "fail-closed reason recorded"
assert_no_grep "proceed:" "$V" "no proceed may appear on infra failure"

pass "I4 revise cap + fail closed"
