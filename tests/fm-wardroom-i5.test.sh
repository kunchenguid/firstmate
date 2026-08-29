#!/usr/bin/env bash
# I5: intake lens degrade. With no custom lens, no Fugu key, and codex absent
# from PATH, the intake lens degrades to none LOUDLY (stderr warning +
# 'panel: lens none' evidence line) and the intake still completes.
# Mutation (LEDGER_MUTATE=1): a fake codex is planted on PATH - a correct chain
# then records 'panel: lens codex', failing the 'lens none' assertions.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-intake-lib.sh
. "$ROOT/bin/fm-intake-lib.sh"

TMP=$(fm_test_tmproot fm-wd-i5)
S="$TMP/state"; D="$TMP/data"; PROJ="$TMP/proj"
mkdir -p "$S" "$D/i5task" "$PROJ"
printf '# Task\nWidget D.\n' > "$D/i5task/brief.md"

cat > "$TMP/think-proceed.sh" <<'SH'
#!/usr/bin/env bash
echo "PANEL: proceed - fine"
SH
chmod +x "$TMP/think-proceed.sh"

FB=$(fm_fakebin "$TMP")
for t in git grep sed head tail cut mktemp cat tr sh dirname basename; do
  p=$(command -v "$t") && ln -sf "$p" "$FB/$t"
done
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  cat > "$FB/codex" <<'SH'
#!/usr/bin/env bash
echo "fake codex lens review"
SH
  chmod +x "$FB/codex"
fi

out=$(env -i HOME="$HOME" PATH="$FB:/usr/bin:/bin" \
      FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D" \
      FM_INTAKE_CMD="$TMP/think-proceed.sh" \
      "$ROOT/bin/fm-intake.sh" i5task "$PROJ" 2>&1); code=$?
expect_code 0 "$code" "intake must complete despite lens degrade"
assert_contains "$out" "degraded to none" "degradation is announced, never silent"
V=$(fm_intake_file "$S" i5task)
assert_grep "panel: lens none" "$V" "lens none recorded as panel evidence"
[ "$(fm_intake_last "$S" i5task)" = proceed ] || fail "thinker decision still recorded"

pass "I5 intake lens degrade"
