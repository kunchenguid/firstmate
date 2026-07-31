#!/usr/bin/env bash
# Credentialed behavior regression for the agent-owned quota-array-dispatch skill.
#
# This drives the public Pi skill-loading interface against a fake quota-axi
# executable rather than parsing instruction source bytes or recreating the
# selector in test code.
set -u

if [ "${FM_QUOTA_ARRAY_DISPATCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_QUOTA_ARRAY_DISPATCH_LIVE_E2E=1 to run the credentialed Pi dispatch-selection regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="$ROOT/.agents/skills/quota-array-dispatch/SKILL.md"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
[ -f "$OWNER" ] || fail "quota-array-dispatch skill not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-array-dispatch-live.XXXXXX")
PROJECT="$LAB/project"
FAKEBIN="$LAB/fakebin"
FIXTURE="$LAB/quota.json"
CALLS="$LAB/quota-axi.calls"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.agents/skills/quota-array-dispatch" "$FAKEBIN"
cp "$OWNER" "$PROJECT/.agents/skills/quota-array-dispatch/SKILL.md"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" != --json ] || [ "$#" -ne 1 ]; then
  printf 'unexpected quota-axi invocation: %s\n' "$*" >&2
  exit 64
fi
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"

write_fixture() {
  cat > "$FIXTURE"
}

run_case() {
  local label=$1 expected=$2 prompt=$3 out calls required
  shift 3
  : > "$CALLS"
  out=$(
    cd "$PROJECT" &&
      PATH="$FAKEBIN:$PATH" QUOTA_AXI_CALLS="$CALLS" QUOTA_AXI_FIXTURE="$FIXTURE" \
        pi --print --approve --no-session --no-context-files --no-extensions \
          --no-skills --skill .agents/skills --tools bash \
          --model openai-codex/gpt-5.6-sol --thinking high \
          "$prompt"
  ) || fail "$label: Pi skill run failed: $out"
  calls=$(cat "$CALLS")
  [ "$calls" = "--json" ] || fail "$label: skill did not use one quota-axi --json snapshot: $calls"
  printf '%s\n' "$out" | grep -Fxq "$expected" \
    || fail "$label: expected final line $expected, got: $out"
  for required in "$@"; do
    printf '%s\n' "$out" | grep -Fxq "$required" \
      || fail "$label: expected accounting line $required, got: $out"
  done
  printf '%s\n' "$out"
  printf 'ok - %s\n' "$label"
}

write_fixture <<'JSON'
{"schemaVersion":3,"providers":[{"provider":"claude","quotaSemantics":{"description":"The all_models scope bounds every Claude model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":1,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":600,"projectedExhaustedAt":"2030-01-01T00:10:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]},"effectivePace":[{"scope":"all_models","pace":"ahead","worstReservePercentPoints":-1}]},{"provider":"codex","quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":55,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]},"effectivePace":[{"scope":"all_models","pace":"ahead","worstReservePercentPoints":-40}]}]}
JSON
run_case \
  "higher headroom and viable runway beat a less-negative reserve" \
  "SELECTED=codex" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove Claude/Sonnet and Codex/GPT models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Return exact lines FACT=claude|headroom=1|runway_seconds=600|reserve=-1 and FACT=codex|headroom=55|runway_seconds=14400|reserve=-40 to preserve candidate accounting, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|headroom=1|runway_seconds=600|reserve=-1" \
  "FACT=codex|headroom=55|runway_seconds=14400|reserve=-40"

write_fixture <<'JSON'
{"schemaVersion":3,"providers":[{"provider":"claude","quotaSemantics":{"description":"The all_models scope bounds every Claude model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":55,"boundedBy":["weekly"],"runway":{"status":"unknown","unmeasurableWindowIds":["weekly"]}}]}},{"provider":"codex","quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":45,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}}]}
JSON
run_case \
  "unmeasurable runway stays eligible and is accounted for explicitly" \
  "DECISION=CODEX" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove both models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Claude has higher known headroom but explicitly unmeasurable runway, while Codex has lower known headroom and established runway that supports completion. The snapshot cannot prove Pareto dominance in either direction, but the known completion-supporting runway justifies Codex while Claude remains eligible and its uncertainty must be disclosed. Return exact lines FACT=claude|eligible=yes|headroom=55|runway=unknown|unmeasurable=weekly and FACT=codex|eligible=yes|headroom=45|runway_seconds=14400|supports_horizon=yes, then an exact final line DECISION=CODEX. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|eligible=yes|headroom=55|runway=unknown|unmeasurable=weekly" \
  "FACT=codex|eligible=yes|headroom=45|runway_seconds=14400|supports_horizon=yes"

write_fixture <<'JSON'
{"schemaVersion":3,"providers":[{"provider":"claude","quotaSemantics":{"description":"The all_models scope bounds every Claude model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":1,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":10800,"projectedExhaustedAt":"2030-01-01T03:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}},{"provider":"codex","quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"2030-01-01T08:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}}]}
JSON
run_case \
  "required strongest reasoning class is not downgraded for quota" \
  "SELECTED=claude" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. The likely task-completion horizon is two hours with established confidence. Claude/Sonnet is catalog-supported with usable authentication and is the only profile that meets the task's required strongest reasoning class. Codex/GPT is catalog-supported with usable authentication but is a weaker reasoning class and cannot meet the requirement. Return exact lines FACT=claude|reasoning=required|headroom=1|runway_seconds=10800 and FACT=codex|reasoning=weaker|headroom=80|runway_seconds=28800, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|reasoning=required|headroom=1|runway_seconds=10800" \
  "FACT=codex|reasoning=weaker|headroom=80|runway_seconds=28800"

echo "# all quota-array-dispatch live behavior tests passed"
