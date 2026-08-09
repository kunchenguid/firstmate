#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/evaluate-idea-fit"

test_canonical_skill_package_is_bundled() {
  local expected actual relative
  assert_present "$SKILL/SKILL.md" "evaluate-idea-fit SKILL.md missing"
  assert_present "$SKILL/agents/openai.yaml" "evaluate-idea-fit OpenAI metadata missing"
  assert_present "$SKILL/VERSION" "evaluate-idea-fit VERSION missing"
  while read -r expected relative; do
    actual=$(shasum -a 256 "$SKILL/$relative" | awk '{print $1}')
    [ "$actual" = "$expected" ] || fail "bundled $relative differs from the Grok-authoritative manifest"
  done <<'EOF'
bb13441197b53fa4d854a0b77558e753c092259e59d6a64fee3fe39a5130a470 agents/openai.yaml
dfe2c9c2d33053692b489a6289bbf11ef56eb9117c59003e45834782b72ff0f9 SKILL.md
59b3e65ebc38c80363d602cf7fbc3921b87d83220230bcb636a4113c9508a7e9 VERSION
EOF
  assert_grep 'source_of_truth: /root/.grok/skills/evaluate-idea-fit' "$SKILL/VERSION" "Grok provenance missing"
  pass "Firstmate bundles the exact canonical evaluate-idea-fit package"
}

test_canonical_skill_package_is_bundled
