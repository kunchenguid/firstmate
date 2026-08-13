#!/usr/bin/env bash
# Exercise the public vendored-skill validator against the checked-in snapshot
# and a tampered Firstmate-shaped fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-skills-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-skills-lock-tests)

out=$($CHECK 2>&1)
status=$?
[ "$status" -eq 0 ] || fail "checked-in vendored snapshot failed validation: $out"
assert_contains "$out" \
  "ok - skills lock: 21 adapted skills and Firstmate discovery paths match" \
  "checked-in snapshot did not report its complete discovery result"
pass "checked-in vendored snapshot and discovery paths validate through the public checker"

fixture="$TMP_ROOT/tampered"
mkdir -p "$fixture/.agents" "$fixture/.claude"
cp "$ROOT/skills-lock.json" "$fixture/skills-lock.json"
cp -R "$ROOT/.agents/skills" "$fixture/.agents/skills"
ln -s ../.agents/skills "$fixture/.claude/skills"
printf '\ntampered\n' >> "$fixture/.agents/skills/code-review/SKILL.md"

out=$(FM_ROOT_OVERRIDE="$fixture" "$CHECK" 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "tampered vendored snapshot unexpectedly validated"
assert_contains "$out" "code-review: lock=" \
  "tampered snapshot did not identify the changed skill"
pass "public checker rejects a changed vendored skill without trusting its lock"

cp "$ROOT/.agents/skills/code-review/SKILL.md" \
  "$fixture/.agents/skills/code-review/SKILL.md"
cp "$fixture/.agents/skills/code-review/agents/openai.yaml" "$TMP_ROOT/openai.yaml"
mv "$fixture/.agents/skills/code-review/agents/openai.yaml" \
  "$fixture/.agents/skills/code-review/agents/openai.yam"
{
  printf 'l'
  cat "$fixture/.agents/skills/code-review/agents/openai.yam"
} > "$fixture/.agents/skills/code-review/agents/openai.yaml.tmp"
mv "$fixture/.agents/skills/code-review/agents/openai.yaml.tmp" \
  "$fixture/.agents/skills/code-review/agents/openai.yam"

out=$(FM_ROOT_OVERRIDE="$fixture" "$CHECK" 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "boundary-colliding vendored snapshot unexpectedly validated"
assert_contains "$out" "code-review: lock=" \
  "boundary-colliding snapshot did not identify the changed skill"
pass "public checker rejects a filename/content-boundary collision"

rm "$fixture/.agents/skills/code-review/agents/openai.yam"
cp "$TMP_ROOT/openai.yaml" "$fixture/.agents/skills/code-review/agents/openai.yaml"
printf '\ntampered\n' >> "$fixture/.agents/skills/VENDORED-ENGINEERING-LICENSE.md"

out=$(FM_ROOT_OVERRIDE="$fixture" "$CHECK" 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "tampered third-party notice unexpectedly validated"
assert_contains "$out" "vendored source-license hash mismatch" \
  "tampered third-party notice was not identified"
pass "public checker integrity-binds the upstream redistribution notice"

out=$($CHECK --help 2>&1)
status=$?
[ "$status" -eq 0 ] || fail "skills lock help failed: $out"
assert_contains "$out" "--source-root" \
  "skills lock help omitted the pinned-upstream verification path"
pass "public checker documents optional pinned-upstream verification"

echo "# all fm-skills-lock tests passed"
