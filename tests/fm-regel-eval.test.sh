#!/usr/bin/env bash
# tests/fm-regel-eval.test.sh - the rule-TDD gate must catch structural
# breaches, disclose debt without failing on it, and run the golden suite:
#
#   1. A malformed manifest row and a row naming a missing test file are
#      breaches; prose-only rows are disclosed debt, never a breach.
#   2. An opted-in rulebook fails on a rule bullet without an accepted anchor
#      and on more than 200 lines; passes fully anchored and under the cap;
#      a rulebook without the marker skips the anchor gate explicitly.
#   3. run executes the mapped tests: a failing target fails the suite by
#      name; all-green passes.
#   4. THE REAL manifest passes check against this repo (every named test
#      exists) - this is what makes CI enforce the manifest continuously.
#
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVAL="$REPO/bin/fm-regel-eval.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root/tests"
T=$(printf '\t')

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }
run_eval() { FM_ROOT_OVERRIDE="$TMP/root" "$EVAL" "$@"; }

printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/root/tests/gruen.test.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/root/tests/rot.test.sh"
printf '# leeres regelwerk ohne marker\n' > "$TMP/root/AGENTS.md"

# --- 1. manifest breaches vs disclosed debt --------------------------------
printf 'kaputt%sL01%snur drei felder\n' "$T" "$T" > "$TMP/m1.tsv"
if run_eval check --manifest "$TMP/m1.tsv" >/dev/null 2>&1; then
  fail "a malformed manifest row must fail the gate"
else
  ok "a malformed manifest row fails the gate"
fi
printf 'fehlt%sL01%sclaim%stest:tests/nicht-da.test.sh\n' "$T" "$T" "$T" > "$TMP/m2.tsv"
if out=$(run_eval check --manifest "$TMP/m2.tsv" 2>&1); then
  fail "a missing test target must fail by name"
elif printf '%s' "$out" | grep -q 'missing test'; then
  ok "a missing test target fails the gate by name"
else
  fail "a missing test target must fail by name (wrong reason: $out)"
fi
printf 'debt%sL02%sclaim%sprose:noch nicht mechanisiert\n' "$T" "$T" "$T" > "$TMP/m3.tsv"
if out=$(run_eval check --manifest "$TMP/m3.tsv" 2>&1) && printf '%s' "$out" | grep -q 'prose-only'; then
  ok "prose-only rows are disclosed debt, not a breach"
else
  fail "prose debt must be disclosed without failing (got: $out)"
fi

# --- 2. rulebook anchor gate ------------------------------------------------
printf 'gut%sL01%sclaim%stest:tests/gruen.test.sh\n' "$T" "$T" "$T" > "$TMP/m-ok.tsv"
{
  echo '# Regelwerk'
  echo 'regel-eval: enforced'
  echo '## Ordnung'
  echo '- **Alles wird gemessen** (L01).'
  echo '- **Diese Regel traegt keinen Anker.**'
} > "$TMP/root/AGENTS.md"
if out=$(run_eval check --manifest "$TMP/m-ok.tsv" 2>&1); then
  fail "an unanchored rule must fail"
elif printf '%s' "$out" | grep -q 'without an anchor'; then
  ok "an unanchored rule fails the opted-in rulebook"
else
  fail "an unanchored rule must fail (wrong reason: $out)"
fi
{
  echo '# Regelwerk'
  echo 'regel-eval: enforced'
  echo '## Ordnung'
  echo '- **Alles wird gemessen** (L01).'
  echo '1. **Harte Regel bleibt.** (HR1)'
  echo '- **Uebernommene Haertung.** (hardening 3)'
} > "$TMP/root/AGENTS.md"
run_eval check --manifest "$TMP/m-ok.tsv" >/dev/null 2>&1 \
  && ok "an anchored rulebook under the cap passes" || fail "an anchored rulebook must pass"
{
  echo 'regel-eval: enforced'
  for _ in $(seq 1 201); do echo '- gefuellt (L01)'; done
} > "$TMP/root/AGENTS.md"
if out=$(run_eval check --manifest "$TMP/m-ok.tsv" 2>&1); then
  fail "the 200-line cap must be enforced"
elif printf '%s' "$out" | grep -q 'limit 200'; then
  ok "more than 200 lines fails the gate"
else
  fail "the 200-line cap must be enforced (wrong reason: $out)"
fi
printf '# ohne marker\n- regellos\n' > "$TMP/root/AGENTS.md"
if out=$(run_eval check --manifest "$TMP/m-ok.tsv" 2>&1) && printf '%s' "$out" | grep -q 'anchor gate skipped'; then
  ok "a rulebook without the marker skips the anchor gate explicitly"
else
  fail "the pre-landing rulebook must skip explicitly (got: $out)"
fi

# --- 3. the golden suite runs the mapped tests ------------------------------
{
  printf 'a%sL01%sclaim%stest:tests/gruen.test.sh\n' "$T" "$T" "$T"
  printf 'b%sL02%sclaim%stest:tests/rot.test.sh\n' "$T" "$T" "$T"
} > "$TMP/m-run.tsv"
if out=$(run_eval run --manifest "$TMP/m-run.tsv" 2>&1); then
  fail "a failing case must fail by name"
elif printf '%s' "$out" | grep -q 'FAIL: tests/rot.test.sh'; then
  ok "a failing golden case fails the suite by name"
else
  fail "a failing case must fail by name (wrong reason: $out)"
fi
printf 'a%sL01%sclaim%stest:tests/gruen.test.sh\n' "$T" "$T" "$T" > "$TMP/m-run2.tsv"
run_eval run --manifest "$TMP/m-run2.tsv" >/dev/null 2>&1 \
  && ok "an all-green suite passes" || fail "an all-green suite must pass"

# --- 4. the REAL manifest is valid against this repo ------------------------
"$EVAL" check >/dev/null 2>&1 \
  && ok "the repo's real manifest passes (every named test exists)" \
  || fail "the repo manifest must pass its own gate"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-regel-eval.test.sh: all checks passed"
  exit 0
fi
echo "fm-regel-eval.test.sh: $FAILS check(s) FAILED"
exit 1
