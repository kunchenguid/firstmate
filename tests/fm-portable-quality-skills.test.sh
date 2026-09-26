#!/usr/bin/env bash
# Test family: pure-contract-unit
# Public packaging-check interface: valid fixtures and deliberately broken packages.
set -eu
source "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/.agents/skills" "$fixture/.claude"
ln -s ../.agents/skills "$fixture/.claude/skills"
for name in mobile-tablet-ui ui-quality-evidence api-contract-evidence; do
  mkdir -p "$fixture/.agents/skills/$name/references"
  cat > "$fixture/.agents/skills/$name/SKILL.md" <<EOF
---
name: $name
description: Exercise portable package validation.
metadata:
  internal: true
---

Read [case](references/case.md).
EOF
  echo 'A fixture reference.' > "$fixture/.agents/skills/$name/references/case.md"
done
"$ROOT/bin/fm-portable-quality-skills-check.sh" --root "$ROOT"
"$ROOT/bin/fm-portable-quality-skills-check.sh" --root "$fixture"
rm "$fixture/.agents/skills/mobile-tablet-ui/references/case.md"
if "$ROOT/bin/fm-portable-quality-skills-check.sh" --root "$fixture" > "$fixture/result" 2>&1; then
  fail 'missing reference accepted'
fi
echo 'Restored reference.' > "$fixture/.agents/skills/mobile-tablet-ui/references/case.md"
sed 's/name: mobile-tablet-ui/name: different-name/' "$fixture/.agents/skills/mobile-tablet-ui/SKILL.md" > "$fixture/changed"
cp "$fixture/changed" "$fixture/.agents/skills/mobile-tablet-ui/SKILL.md"
if "$ROOT/bin/fm-portable-quality-skills-check.sh" --root "$fixture" > "$fixture/result" 2>&1; then
  fail 'mismatched name accepted'
fi
sed 's/name: different-name/name: mobile-tablet-ui/' "$fixture/changed" > "$fixture/.agents/skills/mobile-tablet-ui/SKILL.md"
sed 's/description: Exercise portable package validation./description: # malformed YAML scalar/' "$fixture/.agents/skills/mobile-tablet-ui/SKILL.md" > "$fixture/malformed"
cp "$fixture/.agents/skills/mobile-tablet-ui/SKILL.md" "$fixture/original"
cp "$fixture/malformed" "$fixture/.agents/skills/mobile-tablet-ui/SKILL.md"
if "$ROOT/bin/fm-portable-quality-skills-check.sh" --root "$fixture" > "$fixture/result" 2>&1; then
  fail 'malformed YAML description accepted'
fi
cp "$fixture/original" "$fixture/.agents/skills/mobile-tablet-ui/SKILL.md"
rm "$fixture/.claude/skills"
mkdir "$fixture/.claude/skills"
cp -R "$fixture/.agents/skills/mobile-tablet-ui" "$fixture/.claude/skills/"
if "$ROOT/bin/fm-portable-quality-skills-check.sh" --root "$fixture" > "$fixture/result" 2>&1; then
  fail 'divergent Claude copy accepted'
fi
printf '%s\n' 'PASS invalid references, names and divergent discovery fail closed'
