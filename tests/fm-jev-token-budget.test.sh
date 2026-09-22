#!/usr/bin/env bash
# tests/fm-jev-token-budget.test.sh - Regression test suite for Pattern 16
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUDGET_ENGINE="${FM_ROOT}/bin/fm-jev-token-budget.py"

echo "=== Running fm-jev-token-budget test suite ==="

# Test 1: Syntax / compilation check
python3 -m py_compile "${BUDGET_ENGINE}"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
shellcheck "${FM_ROOT}/bin/fm-jev-token-budget.sh"
echo "PASS: Test 2 - ShellCheck clean on wrapper"

# Test 3: Unit test token calculation, frontmatter parsing, and section breakdown
python3 -c '
import sys
import tempfile
from pathlib import Path
sys.path.insert(0, "'"${FM_ROOT}"'/bin")
import importlib.util
spec = importlib.util.spec_from_file_location("tb", "'"${BUDGET_ENGINE}"'")
tb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tb)

# 1. Test calculate_tokens
text = "A" * 100
assert tb.calculate_tokens(text) == 25, f"Expected 25 tokens for 100 bytes, got {tb.calculate_tokens(text)}"

# 2. Test section analysis
md_content = """# Preamble Section
Some intro lines here.

## Core Rules
- Rule 1
- Rule 2

## Operations Runbook
Detailed operations here.
"""
sections = tb.analyze_sections(md_content)
assert len(sections) == 3, f"Expected 3 sections, got {len(sections)}"
assert sections[0]["title"] == "Preamble Section"
assert sections[1]["title"] == "Core Rules"
assert sections[2]["title"] == "Operations Runbook"

# 3. Test skill frontmatter parsing
with tempfile.TemporaryDirectory() as td:
    skill_file = Path(td) / "SKILL.md"
    skill_file.write_text("""---
name: sample-skill
description: Comprehensive guide for testing skills.
---
# Skill Body
""")
    fm = tb.parse_skill_frontmatter(skill_file)
    assert fm["name"] == "sample-skill"
    assert "Comprehensive guide" in fm["description"]
    assert fm["tokens"] > 0

print("PASS: Test 3 - Unit tests verified")
'

TDIR=$(mktemp -d)
trap 'rm -rf "$TDIR"' EXIT
mkdir "$TDIR/repo"
printf '# Fixture instructions\nUse deterministic tests.\n' > "$TDIR/repo/AGENTS.md"
"${FM_ROOT}/bin/fm-jev-token-budget.sh" --repo-path "$TDIR/repo"
"${FM_ROOT}/bin/fm-jev-token-budget.sh" --repo-path "$TDIR/repo" --json | python3 -c '
import json, sys
result = json.load(sys.stdin)[0]
assert result["status"] == "COMPLIANT"
assert result["agents_tokens"] > 0
'
if "${FM_ROOT}/bin/fm-jev-token-budget.sh" --repo-path "$TDIR/missing" --json > "$TDIR/error.json"; then
  echo "FAIL: missing repository passed" >&2
  exit 1
fi
python3 - "$TDIR/error.json" <<'PYTEST'
import json, sys
with open(sys.argv[1]) as stream:
    assert "error" in json.load(stream)[0]
PYTEST
echo "PASS: fixture audits reject missing repositories"
