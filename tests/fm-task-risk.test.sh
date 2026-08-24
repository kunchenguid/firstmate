#!/usr/bin/env bash
# Behavior tests for explicit Firstmate task-risk records and snapshot projection.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-risk)
HOME_ROOT="$TMP_ROOT/home"
mkdir -p "$HOME_ROOT/data" "$HOME_ROOT/state" "$HOME_ROOT/config" "$HOME_ROOT/projects"
cp "$ROOT/.tasks.toml" "$HOME_ROOT/.tasks.toml"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

tasks_in() {
  (cd "$HOME_ROOT" && tasks-axi "$@")
}

tasks_in add risk-sample "Protect the sample" --repo sample --kind ship \
  --body "Preserve this original task context." >/dev/null \
  || fail "could not create the risk fixture"

out=$(FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-task-risk.sh" set risk-sample \
  --level medium --rationale "Contained production change with a tested rollback.") \
  || fail "could not record a medium risk"
assert_contains "$out" "risk: risk-sample medium" "risk command did not confirm the assessment"

snapshot=$(FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
  || fail "snapshot failed after risk recording"
printf '%s' "$snapshot" | jq -e '
  .backlog.records[] | select(.id == "risk-sample")
  | .risk == {
      level:"medium",
      rationale:"Contained production change with a tested rollback.",
      source:"task-body"
    }
    and (.body_lines | index("Preserve this original task context.") != null)
    and .body_excerpt == "Preserve this original task context."
' >/dev/null || fail "snapshot did not project the explicit risk and preserved body"
pass "explicit risk is projected without replacing task context"

FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-task-risk.sh" set risk-sample \
  --level high --rationale "Material data impact if rollback evidence is wrong." >/dev/null \
  || fail "could not replace the risk assessment"
snapshot=$(FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
  || fail "snapshot failed after risk replacement"
printf '%s' "$snapshot" | jq -e '
  .backlog.records[] | select(.id == "risk-sample")
  | .risk.level == "high"
    and .risk.rationale == "Material data impact if rollback evidence is wrong."
    and ([.body_lines[] | select(. == "Risk assessment recorded by fm-task-risk.")] | length) == 1
    and (.body_lines | index("Preserve this original task context.") != null)
' >/dev/null || fail "replacement did not remain single-owner or preserve context"
pass "reassessment replaces only the helper-owned block"

before=$(printf '%s' "$snapshot" | jq -c '.backlog.records[] | select(.id == "risk-sample") | .risk')
if FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-task-risk.sh" set risk-sample \
  --level high --rationale $'invalid\nsecond line' >/dev/null 2>&1; then
  fail "multiline rationale was accepted"
fi
after=$(FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --json \
  | jq -c '.backlog.records[] | select(.id == "risk-sample") | .risk')
[ "$before" = "$after" ] || fail "a refused assessment changed canonical risk"
pass "invalid risk input is rejected without mutation"

tasks_in add unassessed-sample "Leave risk unknown" --repo sample --kind scout >/dev/null \
  || fail "could not create the unassessed fixture"
snapshot=$(FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
  || fail "snapshot failed for unassessed risk"
printf '%s' "$snapshot" | jq -e '
  .backlog.records[] | select(.id == "unassessed-sample")
  | .risk == {level:"unknown",rationale:null,source:"absent"}
' >/dev/null || fail "unassessed task did not remain explicitly unknown"
pass "missing risk is disclosed as unknown rather than inferred"

tasks_in add invalid-risk-sample "Reject malformed risk" --repo sample --kind ship \
  --body $'Risk assessment recorded by fm-task-risk.\nRisk level: urgent\nRisk rationale: Unsupported level.' >/dev/null \
  || fail "could not create the malformed-risk fixture"
snapshot=$(FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
  || fail "snapshot failed for malformed risk"
printf '%s' "$snapshot" | jq -e '
  .backlog.records[] | select(.id == "invalid-risk-sample")
  | .risk == {level:"unknown",rationale:null,source:"invalid"}
' >/dev/null || fail "malformed risk was not disclosed as invalid"
pass "malformed risk remains unknown with explicit invalid provenance"

printf 'manual\n' > "$HOME_ROOT/config/backlog-backend"
if FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-task-risk.sh" set unassessed-sample \
  --level low --rationale "Would bypass the selected backend." >/dev/null 2>&1; then
  fail "risk helper bypassed the configured manual backend"
fi
snapshot=$(FM_HOME="$HOME_ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
  || fail "snapshot failed after manual-backend refusal"
printf '%s' "$snapshot" | jq -e '
  .backlog.records[] | select(.id == "unassessed-sample")
  | .risk.level == "unknown"
' >/dev/null || fail "manual-backend refusal mutated risk"
pass "risk helper respects the configured manual backlog backend"
