#!/usr/bin/env bash
# Contract test for non-destructive /bearings file snapshots.
# Firing input: today's report path already exists, so the skill selects a new
# timestamped/suffixed path. Legitimate refusal: it never deletes, truncates, or
# replaces the existing gitignored snapshot. The mutation removes the preserve
# guard and must make this checker go RED.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/bearings/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-bearings-skill)
mkdir -p "$TMP_ROOT"

verify_non_destructive_file_mode() {  # <skill-file>
  local file=$1
  # Markdown code spans are literal search text.
  # shellcheck disable=SC2016
  grep -F 'If it already exists, preserve it and select `data/status-report-<YYYY-MM-DD>-<HHMMSS>.md`' "$file" >/dev/null \
    && grep -F 'Never delete, truncate, replace, or derive the new report from an earlier report.' "$file" >/dev/null \
    && ! grep -E 'delete it first|replaces today|replace today' "$file" >/dev/null
}

verify_non_destructive_file_mode "$SKILL" \
  || fail "/bearings file does not preserve an existing same-day snapshot"

mutated="$TMP_ROOT/missing-preserve-guard.md"
sed 's/If it already exists, preserve it and select/If it already exists, select/' "$SKILL" > "$mutated" \
  || fail "could not build the neutralized file-mode fixture"
verify_non_destructive_file_mode "$mutated" \
  && fail "neutralizing the existing-snapshot preserve guard left the checker green"

pass "/bearings file preserves same-day snapshots; neutralizing the guard goes RED"
