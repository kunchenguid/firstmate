#!/usr/bin/env bash
# shellcheck disable=SC2034
# fm-diagnostic-report-lib.sh - shared diagnostic-report hypothesis-table contract.
#
# The semantic policy lives once in .agents/skills/diagnostic-reasoning/SKILL.md.
# This library owns the closed verdict vocabulary, the hidden-aware single-owner
# scan, and the constants wired into generated briefs and fm-diagnostic-report.sh.
#
# Sourced by bin/fm-diagnostic-report.sh and behavior tests; do not execute directly.
# shellcheck disable=SC2034
set -u

FM_DIAGNOSTIC_HYPOTHESIS_POLICY_OWNER='.agents/skills/diagnostic-reasoning/SKILL.md'
FM_DIAGNOSTIC_HYPOTHESIS_POLICY_DECLARATION='policy-owner: diagnostic-hypothesis-table'
FM_DIAGNOSTIC_HYPOTHESIS_TABLE_MARKER='Hypothesis table'
FM_DIAGNOSTIC_HYPOTHESIS_COLUMNS='hypothesis prediction experiment outcome verdict'
FM_DIAGNOSTIC_HYPOTHESIS_VERDICTS='supported refuted inconclusive'

# Return 0 when verdict is one of the closed vocabulary values.
fm_diagnostic_hypothesis_verdict_valid() {
  local verdict=$1 candidate
  for candidate in $FM_DIAGNOSTIC_HYPOTHESIS_VERDICTS; do
    [ "$verdict" = "$candidate" ] && return 0
  done
  return 1
}

# Verify the one structural owner declaration and report any extra declarations.
# This proves the declared-owner shape only, not semantic paraphrase uniqueness.
fm_diagnostic_hypothesis_policy_scan() {
  local root=$1 owner_rel=${2:-$FM_DIAGNOSTIC_HYPOTHESIS_POLICY_OWNER}
  local owner_abs="$root/$owner_rel"
  local declarations count

  if ! command -v rg >/dev/null 2>&1; then
    printf 'fm-diagnostic-report-lib: rg is required on PATH\n' >&2
    return 2
  fi
  if [ ! -f "$owner_abs" ]; then
    printf 'fm-diagnostic-report: declared hypothesis-table owner is missing: %s\n' "$owner_rel"
    return 1
  fi

  declarations=$(rg -l --hidden -N "^[[:space:]]*${FM_DIAGNOSTIC_HYPOTHESIS_POLICY_DECLARATION}[[:space:]]*$" "$root" \
    --glob '!**/.git/**' \
    --glob '!**/.claude/**' \
    --glob '!**/data/**' \
    --glob '!**/state/**' \
    --glob '!**/projects/**' \
    --glob '!**/tests/**' \
    --glob '!**/bin/fm-diagnostic-report-lib.sh' \
    --glob '!**/bin/fm-diagnostic-report.sh' \
    2>/dev/null || true)
  count=$(printf '%s\n' "$declarations" | awk 'NF { count++ } END { print count + 0 }')
  if [ "$count" -ne 1 ] || [ "$declarations" != "$owner_abs" ]; then
    printf 'fm-diagnostic-report: expected exactly one declared hypothesis-table owner at %s; found:\n%s\n' \
      "$owner_rel" "$declarations"
    return 1
  fi
  return 0
}
