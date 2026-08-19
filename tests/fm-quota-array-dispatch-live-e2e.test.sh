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
command -v jq >/dev/null 2>&1 || fail "jq not found"
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
  jq -e '
    .schemaVersion == 5
    and (.generatedAt | type == "string")
    and (.providers | type == "array")
    and all(.providers[];
      . as $provider
      | [$provider.windows[].id] as $window_ids
      | ($provider.provider | type == "string")
        and ($provider.windows | type == "array")
        and ($provider.state.status | type == "string")
        and all($provider.quotaSemantics.effectiveAvailability[]?;
          (.boundedBy | type == "array")
          and (((.boundedBy - $window_ids) | length) == 0))
        and (if $provider.provider == "traex" then
          ($provider.models | type == "array")
          and all($provider.models[];
            . as $model
            | ($model.catalogId | type == "string")
              and ($model.load.status == "known" or $model.load.status == "unknown")
              and ($model.load.stale | type == "boolean")
              and (if $model.quota.status == "authoritative" then
                $model.quota.scope as $scope
                | (($provider.quotaSemantics.effectiveAvailability | map(.scope) | index($scope)) != null)
                  and ((($model.quota.windowIds - $window_ids) | length) == 0)
              else true end))
        else true end))
  ' "$FIXTURE" >/dev/null || fail "fixture is not normalized quota-axi schema 5 JSON"
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
{"schemaVersion":5,"generatedAt":"2030-01-01T00:00:00Z","providers":[{"provider":"claude","windows":[{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":1,"resetsAt":"2030-01-02T00:00:00Z","windowSeconds":604800,"pace":{"status":"ahead","reservePercentPoints":-1}}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":1,"boundedBy":["weekly"],"pace":{"status":"ahead","worstReservePercentPoints":-1},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":600,"projectedExhaustedAt":"2030-01-01T00:10:00Z","limitingWindowId":"weekly","projectionConfidence":"established"}}]},"state":{"status":"fresh","stale":false,"authStatus":"usable"}},{"provider":"codex","windows":[{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":55,"resetsAt":"2030-01-02T00:00:00Z","windowSeconds":604800,"pace":{"status":"ahead","reservePercentPoints":-40}}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":55,"boundedBy":["weekly"],"pace":{"status":"ahead","worstReservePercentPoints":-40},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established"}}]},"state":{"status":"fresh","stale":false,"authStatus":"usable"}}]}
JSON
run_case \
  "higher headroom and viable runway beat a less-negative reserve" \
  "SELECTED=codex" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove Claude/Sonnet and Codex/GPT models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Return exact lines FACT=claude|headroom=1|runway_seconds=600|reserve=-1 and FACT=codex|headroom=55|runway_seconds=14400|reserve=-40 to preserve candidate accounting, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|headroom=1|runway_seconds=600|reserve=-1" \
  "FACT=codex|headroom=55|runway_seconds=14400|reserve=-40"

write_fixture <<'JSON'
{"schemaVersion":5,"generatedAt":"2030-01-01T00:00:00Z","providers":[{"provider":"claude","windows":[{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":55,"resetsAt":"2030-01-02T00:00:00Z","windowSeconds":604800,"pace":{"status":"unknown","reason":"missing_usage"}}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":55,"boundedBy":["weekly"],"runway":{"status":"unknown","unmeasurableWindowIds":["weekly"]}}]},"state":{"status":"fresh","stale":false,"authStatus":"usable"}},{"provider":"codex","windows":[{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":45,"resetsAt":"2030-01-02T00:00:00Z","windowSeconds":604800,"pace":{"status":"ahead","reservePercentPoints":-5}}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":45,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established"}}]},"state":{"status":"fresh","stale":false,"authStatus":"usable"}}]}
JSON
run_case \
  "unmeasurable runway stays eligible and is accounted for explicitly" \
  "DECISION=CODEX" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove both models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Claude has higher known headroom but explicitly unmeasurable runway, while Codex has lower known headroom and established runway that supports completion. The snapshot cannot prove Pareto dominance in either direction, but the known completion-supporting runway justifies Codex while Claude remains eligible and its uncertainty must be disclosed. Return exact lines FACT=claude|eligible=yes|headroom=55|runway=unknown|unmeasurable=weekly and FACT=codex|eligible=yes|headroom=45|runway_seconds=14400|supports_horizon=yes, then an exact final line DECISION=CODEX. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|eligible=yes|headroom=55|runway=unknown|unmeasurable=weekly" \
  "FACT=codex|eligible=yes|headroom=45|runway_seconds=14400|supports_horizon=yes"

write_fixture <<'JSON'
{"schemaVersion":5,"generatedAt":"2030-01-01T00:00:00Z","providers":[{"provider":"claude","windows":[{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":1,"resetsAt":"2030-01-02T00:00:00Z","windowSeconds":604800,"pace":{"status":"ahead","reservePercentPoints":-60}}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":1,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":10800,"projectedExhaustedAt":"2030-01-01T03:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established"}}]},"state":{"status":"fresh","stale":false,"authStatus":"usable"}},{"provider":"codex","windows":[{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":80,"resetsAt":"2030-01-02T00:00:00Z","windowSeconds":604800,"pace":{"status":"behind","reservePercentPoints":20}}],"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"2030-01-01T08:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established"}}]},"state":{"status":"fresh","stale":false,"authStatus":"usable"}}]}
JSON
run_case \
  "required strongest reasoning class is not downgraded for quota" \
  "SELECTED=claude" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. The likely task-completion horizon is two hours with established confidence. Claude/Sonnet is catalog-supported with usable authentication and is the only profile that meets the task's required strongest reasoning class. Codex/GPT is catalog-supported with usable authentication but is a weaker reasoning class and cannot meet the requirement. Return exact lines FACT=claude|reasoning=required|headroom=1|runway_seconds=10800 and FACT=codex|reasoning=weaker|headroom=80|runway_seconds=28800, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|reasoning=required|headroom=1|runway_seconds=10800" \
  "FACT=codex|reasoning=weaker|headroom=80|runway_seconds=28800"

write_fixture <<'JSON'
{
  "schemaVersion": 5,
  "generatedAt": "2030-01-01T00:00:00Z",
  "providers": [
    {
      "provider": "traex",
      "windows": [{"id":"model:gpt-5.6-sol:weekly","label":"weekly","kind":"model","percentRemaining":50,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"isDepleted":false,"pace":{"status":"behind","reservePercentPoints":15}}],
      "models": [{"catalogId":"gpt-5.6-sol","name":"GPT-5.6-Sol","configName":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","displayNameSource":"catalog","load":{"status":"known","percent":109,"stale":false},"quota":{"status":"authoritative","scope":"model:gpt-5.6-sol","windowIds":["model:gpt-5.6-sol:weekly"],"relationship":"model_scoped","sharing":"unknown","stale":false}}],
      "quotaSemantics": {"status":"partial","effectiveAvailability":[{"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":50,"boundedBy":["model:gpt-5.6-sol:weekly"],"pace":{"status":"behind","worstReservePercentPoints":15,"worstReserveWindowId":"model:gpt-5.6-sol:weekly"},"runway":{"status":"through_reset","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    },
    {
      "provider": "codex",
      "windows": [{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":80,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"pace":{"status":"behind","reservePercentPoints":20}}],
      "quotaSemantics": {"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"boundedBy":["weekly"],"pace":{"status":"behind","worstReservePercentPoints":20,"worstReserveWindowId":"weekly"},"runway":{"status":"through_reset","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    }
  ]
}
JSON
run_case \
  "TraeX below the configured load threshold is preferred without converting load to quota" \
  "SELECTED=traex" \
  "Resolve this matched profile array with quota-array-dispatch and run quota-axi --json exactly once. The profiles are TraeX/gpt-5.6-sol/high with preferWhileLoadBelowPercent=110 and Codex/gpt-5.6-sol/high. Both have equal required fit and reasoning class, and their selected authentication surfaces are usable. The TraeX normalized catalog record and the authoritative Codex catalog evidence prove both models supported. The likely completion horizon is two hours. Return exact lines FACT=traex|eligible=yes|load=109|threshold=110|headroom=50|runway=through_reset|preferred=yes and FACT=codex|eligible=yes|headroom=80|runway=through_reset, then exact final line SELECTED=<traex|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=traex|eligible=yes|load=109|threshold=110|headroom=50|runway=through_reset|preferred=yes" \
  "FACT=codex|eligible=yes|headroom=80|runway=through_reset"

write_fixture <<'JSON'
{
  "schemaVersion": 5,
  "generatedAt": "2030-01-01T00:00:00Z",
  "providers": [
    {
      "provider": "traex",
      "windows": [{"id":"model:gpt-5.6-sol:weekly","label":"weekly","kind":"model","percentRemaining":50,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"isDepleted":false,"pace":{"status":"behind","reservePercentPoints":15}}],
      "models": [{"catalogId":"gpt-5.6-sol","name":"GPT-5.6-Sol","configName":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","displayNameSource":"catalog","load":{"status":"known","percent":110,"stale":false},"quota":{"status":"authoritative","scope":"model:gpt-5.6-sol","windowIds":["model:gpt-5.6-sol:weekly"],"relationship":"model_scoped","sharing":"unknown","stale":false}}],
      "quotaSemantics": {"status":"partial","effectiveAvailability":[{"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":50,"boundedBy":["model:gpt-5.6-sol:weekly"],"pace":{"status":"behind","worstReservePercentPoints":15,"worstReserveWindowId":"model:gpt-5.6-sol:weekly"},"runway":{"status":"through_reset","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    },
    {
      "provider": "codex",
      "windows": [{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":80,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"pace":{"status":"behind","reservePercentPoints":20}}],
      "quotaSemantics": {"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"boundedBy":["weekly"],"pace":{"status":"behind","worstReservePercentPoints":20,"worstReserveWindowId":"weekly"},"runway":{"status":"through_reset","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    }
  ]
}
JSON
run_case \
  "TraeX at the exclusive load threshold is blocked" \
  "SELECTED=codex" \
  "Resolve this matched profile array with quota-array-dispatch and run quota-axi --json exactly once. The profiles are TraeX/gpt-5.6-sol/high with preferWhileLoadBelowPercent=110 and Codex/gpt-5.6-sol/high. Both have equal required fit and reasoning class, usable selected authentication, and supported models. The likely completion horizon is two hours. Return exact lines FACT=traex|eligible=no|load=110|threshold=110|reason=load-threshold and FACT=codex|eligible=yes|headroom=80|runway=through_reset, then exact final line SELECTED=<traex|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=traex|eligible=no|load=110|threshold=110|reason=load-threshold" \
  "FACT=codex|eligible=yes|headroom=80|runway=through_reset"

write_fixture <<'JSON'
{
  "schemaVersion": 5,
  "generatedAt": "2030-01-01T00:00:00Z",
  "providers": [
    {
      "provider": "traex",
      "windows": [{"id":"model:gpt-5.6-sol:weekly","label":"weekly","kind":"model","percentRemaining":0,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"isDepleted":true,"pace":{"status":"ahead","reservePercentPoints":-70}}],
      "models": [{"catalogId":"gpt-5.6-sol","name":"GPT-5.6-Sol","configName":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","displayNameSource":"catalog","load":{"status":"known","percent":20,"stale":false},"quota":{"status":"authoritative","scope":"model:gpt-5.6-sol","windowIds":["model:gpt-5.6-sol:weekly"],"relationship":"model_scoped","sharing":"unknown","stale":false}}],
      "quotaSemantics": {"status":"partial","effectiveAvailability":[{"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":0,"boundedBy":["model:gpt-5.6-sol:weekly"],"pace":{"status":"ahead","aheadWindowIds":["model:gpt-5.6-sol:weekly"],"worstReservePercentPoints":-70,"worstReserveWindowId":"model:gpt-5.6-sol:weekly"},"runway":{"status":"exhausted_now","usableRunwaySeconds":0,"limitingWindowId":"model:gpt-5.6-sol:weekly"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    },
    {
      "provider": "codex",
      "windows": [{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":35,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"pace":{"status":"ahead","reservePercentPoints":-10}}],
      "quotaSemantics": {"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":35,"boundedBy":["weekly"],"pace":{"status":"ahead","aheadWindowIds":["weekly"],"worstReservePercentPoints":-10,"worstReserveWindowId":"weekly"},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":10800,"projectedExhaustedAt":"2030-01-01T03:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    }
  ]
}
JSON
run_case \
  "depleted applicable quota blocks a low-load TraeX candidate" \
  "SELECTED=codex" \
  "Resolve this matched profile array with quota-array-dispatch and run quota-axi --json exactly once. The profiles are TraeX/gpt-5.6-sol/high with preferWhileLoadBelowPercent=110 and Codex/gpt-5.6-sol/high. Both have equal required fit and reasoning class, usable selected authentication, and supported models. The likely completion horizon is two hours. Return exact lines FACT=traex|eligible=no|load=20|headroom=0|runway=exhausted_now|reason=depleted and FACT=codex|eligible=yes|headroom=35|runway_seconds=10800, then exact final line SELECTED=<traex|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=traex|eligible=no|load=20|headroom=0|runway=exhausted_now|reason=depleted" \
  "FACT=codex|eligible=yes|headroom=35|runway_seconds=10800"

write_fixture <<'JSON'
{
  "schemaVersion": 5,
  "generatedAt": "2030-01-01T00:00:00Z",
  "providers": [
    {
      "provider": "codex",
      "windows": [{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":80,"resetsAt":"2030-01-01T04:00:00Z","windowSeconds":604800,"pace":{"status":"ahead","reservePercentPoints":-5}}],
      "quotaSemantics": {"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"boundedBy":["weekly"],"pace":{"status":"ahead","aheadWindowIds":["weekly"],"worstReservePercentPoints":-5,"worstReserveWindowId":"weekly"},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":1800,"projectedExhaustedAt":"2030-01-01T00:30:00Z","limitingWindowId":"weekly","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    },
    {
      "provider": "traex",
      "windows": [{"id":"model:gpt-5.6-sol:weekly","label":"weekly","kind":"model","percentRemaining":20,"resetsAt":"2030-01-01T00:10:00Z","windowSeconds":604800,"isDepleted":false,"pace":{"status":"behind","reservePercentPoints":5}}],
      "models": [{"catalogId":"gpt-5.6-sol","name":"GPT-5.6-Sol","configName":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","displayNameSource":"catalog","load":{"status":"known","percent":130,"stale":false},"quota":{"status":"authoritative","scope":"model:gpt-5.6-sol","windowIds":["model:gpt-5.6-sol:weekly"],"relationship":"model_scoped","sharing":"unknown","stale":false}}],
      "quotaSemantics": {"status":"partial","effectiveAvailability":[{"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":20,"boundedBy":["model:gpt-5.6-sol:weekly"],"pace":{"status":"behind","worstReservePercentPoints":5,"worstReserveWindowId":"model:gpt-5.6-sol:weekly"},"runway":{"status":"through_reset","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    }
  ]
}
JSON
run_case \
  "through-reset evidence beats finite runway ending before completion" \
  "SELECTED=traex" \
  "Resolve this matched profile array with quota-array-dispatch and run quota-axi --json exactly once. Candidate order is Codex/gpt-5.6-sol/high then TraeX/gpt-5.6-sol/high, with no configured load preference. Both have equal required fit and reasoning class, usable selected authentication, and supported models. The established completion horizon is two hours. TraeX's authoritative bound resets ten minutes into that horizon and its runway is through_reset; Codex projects exhaustion after 1800 seconds. Return exact lines FACT=codex|eligible=yes|headroom=80|runway_seconds=1800|supports_horizon=no and FACT=traex|eligible=yes|headroom=20|runway=through_reset|reset_before_completion=yes|supports_horizon=yes, then exact final line SELECTED=<traex|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=codex|eligible=yes|headroom=80|runway_seconds=1800|supports_horizon=no" \
  "FACT=traex|eligible=yes|headroom=20|runway=through_reset|reset_before_completion=yes|supports_horizon=yes"

write_fixture <<'JSON'
{
  "schemaVersion": 5,
  "generatedAt": "2030-01-01T00:00:00Z",
  "providers": [
    {
      "provider": "codex",
      "windows": [{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":50,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"pace":{"status":"ahead","reservePercentPoints":-20}}],
      "quotaSemantics": {"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"boundedBy":["weekly"],"pace":{"status":"ahead","aheadWindowIds":["weekly"],"worstReservePercentPoints":-20,"worstReserveWindowId":"weekly"},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    },
    {
      "provider": "traex",
      "windows": [{"id":"model:gpt-5.6-sol:weekly","label":"weekly","kind":"model","percentRemaining":50,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"isDepleted":false,"pace":{"status":"behind","reservePercentPoints":20}}],
      "models": [{"catalogId":"gpt-5.6-sol","name":"GPT-5.6-Sol","configName":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","displayNameSource":"catalog","load":{"status":"known","percent":75,"stale":false},"quota":{"status":"authoritative","scope":"model:gpt-5.6-sol","windowIds":["model:gpt-5.6-sol:weekly"],"relationship":"model_scoped","sharing":"unknown","stale":false}}],
      "quotaSemantics": {"status":"partial","effectiveAvailability":[{"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":50,"boundedBy":["model:gpt-5.6-sol:weekly"],"pace":{"status":"behind","worstReservePercentPoints":20,"worstReserveWindowId":"model:gpt-5.6-sol:weekly"},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"model:gpt-5.6-sol:weekly","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    },
    {
      "provider": "claude",
      "windows": [{"id":"seven_day","label":"weekly","kind":"weekly","percentRemaining":50,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"pace":{"status":"unknown","reason":"missing_usage"}}],
      "quotaSemantics": {"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"boundedBy":["seven_day"],"pace":{"status":"unknown","unknownWindowIds":["seven_day"]},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"seven_day","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    }
  ]
}
JSON
run_case \
  "behind, ahead, and unknown pace remain diagnostic and explicit" \
  "SELECTED=traex" \
  "Resolve this matched profile array with quota-array-dispatch and run quota-axi --json exactly once. The Codex, TraeX, and Claude profiles have equal required fit, reasoning class, effective headroom, and completion-supporting runway, with no configured load preference. Their supported models and usable selected authentication are established. Pace is therefore the first unresolved comparison: Codex is ahead with reserve -20, TraeX is behind with reserve 20, and Claude pace is unknown. Return exact lines FACT=codex|eligible=yes|pace=ahead|reserve=-20 and FACT=traex|eligible=yes|pace=behind|reserve=20 and FACT=claude|eligible=yes|pace=unknown|uncertainty=pace, then exact final line SELECTED=<claude|codex|traex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=codex|eligible=yes|pace=ahead|reserve=-20" \
  "FACT=traex|eligible=yes|pace=behind|reserve=20" \
  "FACT=claude|eligible=yes|pace=unknown|uncertainty=pace"

write_fixture <<'JSON'
{
  "schemaVersion": 5,
  "generatedAt": "2030-01-01T00:00:00Z",
  "providers": [
    {
      "provider": "codex",
      "windows": [{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":40,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"pace":{"status":"ahead","reservePercentPoints":-10}}],
      "quotaSemantics": {"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":40,"boundedBy":["weekly"],"pace":{"status":"ahead","aheadWindowIds":["weekly"],"worstReservePercentPoints":-10,"worstReserveWindowId":"weekly"},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":10800,"projectedExhaustedAt":"2030-01-01T03:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    },
    {
      "provider": "traex",
      "windows": [{"id":"model:gpt-5.6-sol:weekly","label":"weekly","kind":"model","percentRemaining":60,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"isDepleted":false,"pace":{"status":"ahead","reservePercentPoints":-10}},{"id":"model:other-model:weekly","label":"weekly","kind":"model","percentRemaining":60,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"isDepleted":false,"pace":{"status":"ahead","reservePercentPoints":-10}}],
      "models": [{"catalogId":"gpt-5.6-sol","name":"GPT-5.6-Sol","configName":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","displayNameSource":"catalog","load":{"status":"known","percent":75,"stale":false},"quota":{"status":"authoritative","scope":"model:gpt-5.6-sol","windowIds":["model:gpt-5.6-sol:weekly"],"relationship":"model_scoped","sharing":"unknown","stale":false}},{"catalogId":"other-model","name":"other-model","displayName":"other-model","displayNameSource":"catalog","load":{"status":"known","percent":75,"stale":false},"quota":{"status":"authoritative","scope":"model:other-model","windowIds":["model:other-model:weekly"],"relationship":"model_scoped","sharing":"unknown","stale":false}}],
      "quotaSemantics": {"status":"partial","effectiveAvailability":[{"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":60,"boundedBy":["model:gpt-5.6-sol:weekly"],"pace":{"status":"ahead","aheadWindowIds":["model:gpt-5.6-sol:weekly"],"worstReservePercentPoints":-10,"worstReserveWindowId":"model:gpt-5.6-sol:weekly"},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"model:gpt-5.6-sol:weekly","projectionConfidence":"established"}},{"scope":"model:other-model","status":"known","effectivePercentRemaining":60,"boundedBy":["model:other-model:weekly"],"pace":{"status":"ahead","aheadWindowIds":["model:other-model:weekly"],"worstReservePercentPoints":-10,"worstReserveWindowId":"model:other-model:weekly"},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"model:other-model:weekly","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    }
  ]
}
JSON
run_case \
  "provider-level Codex quota and model-scoped TraeX quota compare only at declared scopes" \
  "SELECTED=traex" \
  "Resolve this Codex versus TraeX matched profile array with quota-array-dispatch and run quota-axi --json exactly once. Both profiles have equal required fit and reasoning class, supported models, usable selected authentication, and a two-hour completion horizon. Codex has no named-model window, so its declared all_models scope applies to its established model. TraeX must use only the exact gpt-5.6-sol scope; its structurally identical other-model window has sharing unknown and must not be merged or applied. Return exact lines FACT=codex|scope=all_models|headroom=40|runway_seconds=10800 and FACT=traex|scope=model:gpt-5.6-sol|headroom=60|runway_seconds=14400|sharing=unknown, then exact final line SELECTED=<traex|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=codex|scope=all_models|headroom=40|runway_seconds=10800" \
  "FACT=traex|scope=model:gpt-5.6-sol|headroom=60|runway_seconds=14400|sharing=unknown"

write_fixture <<'JSON'
{
  "schemaVersion": 5,
  "generatedAt": "2030-01-01T00:00:00Z",
  "providers": [
    {
      "provider": "traex",
      "windows": [],
      "models": [{"catalogId":"gpt-5.6-sol","name":"GPT-5.6-Sol","configName":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","displayNameSource":"catalog","load":{"status":"known","percent":55,"stale":false},"quota":{"status":"not_reported","windowIds":[],"relationship":"unknown","sharing":"unknown","stale":false}}],
      "quotaSemantics": {"status":"partial","effectiveAvailability":[]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    },
    {
      "provider": "codex",
      "windows": [{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":70,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"pace":{"status":"behind","reservePercentPoints":15}}],
      "quotaSemantics": {"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":70,"boundedBy":["weekly"],"pace":{"status":"behind","worstReservePercentPoints":15,"worstReserveWindowId":"weekly"},"runway":{"status":"through_reset","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    }
  ]
}
JSON
run_case \
  "known TraeX load with missing quota stays eligible and never becomes quota remaining" \
  "SELECTED=traex" \
  "Resolve this matched profile array with quota-array-dispatch and run quota-axi --json exactly once. The profiles are TraeX/gpt-5.6-sol/high with preferWhileLoadBelowPercent=110 and Codex/gpt-5.6-sol/high. Both have equal required fit and reasoning class, supported models, and usable selected authentication. TraeX reports fresh known load 55 but quota.status not_reported; Codex has known provider-level quota. There is no known TraeX completion shortfall. Return exact lines FACT=traex|eligible=yes|load=55|threshold=110|quota=not_reported|headroom=unknown|preferred=yes and FACT=codex|eligible=yes|headroom=70|runway=through_reset, then exact final line SELECTED=<traex|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=traex|eligible=yes|load=55|threshold=110|quota=not_reported|headroom=unknown|preferred=yes" \
  "FACT=codex|eligible=yes|headroom=70|runway=through_reset"

write_fixture <<'JSON'
{
  "schemaVersion": 5,
  "generatedAt": "2030-01-01T00:00:00Z",
  "providers": [
    {
      "provider": "traex",
      "windows": [],
      "models": [{"catalogId":"other-model","name":"other-model","displayName":"other-model","displayNameSource":"catalog","load":{"status":"known","percent":20,"stale":false},"quota":{"status":"not_reported","windowIds":[],"relationship":"unknown","sharing":"unknown","stale":false}}],
      "quotaSemantics": {"status":"partial","effectiveAvailability":[]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    },
    {
      "provider": "codex",
      "windows": [{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":70,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"pace":{"status":"behind","reservePercentPoints":15}}],
      "quotaSemantics": {"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":70,"boundedBy":["weekly"],"pace":{"status":"behind","worstReservePercentPoints":15,"worstReserveWindowId":"weekly"},"runway":{"status":"through_reset","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    }
  ]
}
JSON
run_case \
  "fresh normalized TraeX catalog absence blocks an unsupported configured model" \
  "SELECTED=codex" \
  "Resolve this matched profile array with quota-array-dispatch and run quota-axi --json exactly once. The profiles are TraeX/gpt-5.6-sol/high with preferWhileLoadBelowPercent=110 and Codex/gpt-5.6-sol/high. Both have equal required fit and reasoning class and usable selected authentication. The fresh normalized TraeX catalog contains only other-model, while the authoritative Codex catalog proves gpt-5.6-sol supported. Return exact lines FACT=traex|eligible=no|model=gpt-5.6-sol|reason=unsupported-catalog and FACT=codex|eligible=yes|headroom=70|runway=through_reset, then exact final line SELECTED=<traex|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=traex|eligible=no|model=gpt-5.6-sol|reason=unsupported-catalog" \
  "FACT=codex|eligible=yes|headroom=70|runway=through_reset"

write_fixture <<'JSON'
{
  "schemaVersion": 5,
  "generatedAt": "2030-01-01T00:00:00Z",
  "providers": [
    {
      "provider": "codex",
      "windows": [{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":50,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"pace":{"status":"on_pace","reservePercentPoints":0}}],
      "quotaSemantics": {"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"boundedBy":["weekly"],"pace":{"status":"on_pace","onPaceWindowIds":["weekly"],"worstReservePercentPoints":0,"worstReserveWindowId":"weekly"},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    },
    {
      "provider": "traex",
      "windows": [{"id":"model:gpt-5.6-sol:weekly","label":"weekly","kind":"model","percentRemaining":50,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"isDepleted":false,"pace":{"status":"on_pace","reservePercentPoints":0}}],
      "models": [{"catalogId":"gpt-5.6-sol","name":"GPT-5.6-Sol","configName":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","displayNameSource":"catalog","load":{"status":"known","percent":75,"stale":false},"quota":{"status":"authoritative","scope":"model:gpt-5.6-sol","windowIds":["model:gpt-5.6-sol:weekly"],"relationship":"model_scoped","sharing":"unknown","stale":false}}],
      "quotaSemantics": {"status":"partial","effectiveAvailability":[{"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":50,"boundedBy":["model:gpt-5.6-sol:weekly"],"pace":{"status":"on_pace","onPaceWindowIds":["model:gpt-5.6-sol:weekly"],"worstReservePercentPoints":0,"worstReserveWindowId":"model:gpt-5.6-sol:weekly"},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"model:gpt-5.6-sol:weekly","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    }
  ]
}
JSON
run_case \
  "genuine evidence tie is reported with Codex first" \
  "DECISION=TIE" \
  "Resolve this matched profile array with quota-array-dispatch and run quota-axi --json exactly once. Candidate order is Codex/gpt-5.6-sol/high then TraeX/gpt-5.6-sol/high. There is no configured load preference. Both candidates have equal required fit and reasoning class, supported models, usable selected authentication, equal headroom 50, equal finite runway 14400, on-pace reserve 0, and no other differentiator. Return exact lines FACT=codex|eligible=yes|headroom=50|runway_seconds=14400|pace=on_pace and FACT=traex|eligible=yes|headroom=50|runway_seconds=14400|pace=on_pace, then exact final line DECISION=<TIE|CODEX|TRAEX>. Do not use other vendor or model commands and do not modify files." \
  "FACT=codex|eligible=yes|headroom=50|runway_seconds=14400|pace=on_pace" \
  "FACT=traex|eligible=yes|headroom=50|runway_seconds=14400|pace=on_pace"
run_case \
  "genuine evidence tie is reported with TraeX first" \
  "DECISION=TIE" \
  "Resolve this matched profile array with quota-array-dispatch and run quota-axi --json exactly once. Candidate order is TraeX/gpt-5.6-sol/high then Codex/gpt-5.6-sol/high. There is no configured load preference. Both candidates have equal required fit and reasoning class, supported models, usable selected authentication, equal headroom 50, equal finite runway 14400, on-pace reserve 0, and no other differentiator. Return exact lines FACT=traex|eligible=yes|headroom=50|runway_seconds=14400|pace=on_pace and FACT=codex|eligible=yes|headroom=50|runway_seconds=14400|pace=on_pace, then exact final line DECISION=<TIE|CODEX|TRAEX>. Do not use other vendor or model commands and do not modify files." \
  "FACT=traex|eligible=yes|headroom=50|runway_seconds=14400|pace=on_pace" \
  "FACT=codex|eligible=yes|headroom=50|runway_seconds=14400|pace=on_pace"

write_fixture <<'JSON'
{
  "schemaVersion": 5,
  "generatedAt": "2030-01-01T00:00:00Z",
  "providers": [
    {
      "provider": "traex",
      "windows": [{"id":"model:gpt-5.6-sol:weekly","label":"weekly","kind":"model","percentRemaining":1,"resetsAt":"2030-01-03T00:00:00Z","windowSeconds":604800,"isDepleted":false,"pace":{"status":"ahead","reservePercentPoints":-60}}],
      "models": [{"catalogId":"gpt-5.6-sol","name":"GPT-5.6-Sol","configName":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","displayNameSource":"catalog","load":{"status":"known","percent":130,"stale":false},"quota":{"status":"authoritative","scope":"model:gpt-5.6-sol","windowIds":["model:gpt-5.6-sol:weekly"],"relationship":"model_scoped","sharing":"unknown","stale":false}}],
      "quotaSemantics": {"status":"partial","effectiveAvailability":[{"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":1,"boundedBy":["model:gpt-5.6-sol:weekly"],"pace":{"status":"ahead","aheadWindowIds":["model:gpt-5.6-sol:weekly"],"worstReservePercentPoints":-60,"worstReserveWindowId":"model:gpt-5.6-sol:weekly"},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":10800,"projectedExhaustedAt":"2030-01-01T03:00:00Z","limitingWindowId":"model:gpt-5.6-sol:weekly","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    },
    {
      "provider": "codex",
      "windows": [{"id":"weekly","label":"weekly","kind":"weekly","percentRemaining":80,"resetsAt":"2030-01-04T00:00:00Z","windowSeconds":604800,"pace":{"status":"behind","reservePercentPoints":20}}],
      "quotaSemantics": {"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"boundedBy":["weekly"],"pace":{"status":"behind","worstReservePercentPoints":20,"worstReserveWindowId":"weekly"},"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"2030-01-01T08:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established"}}]},
      "state": {"status":"fresh","stale":false,"authStatus":"usable"}
    }
  ]
}
JSON
run_case \
  "all candidates tight does not downgrade the required strongest reasoning class" \
  "SELECTED=traex" \
  "Resolve this matched profile array with quota-array-dispatch and run quota-axi --json exactly once. TraeX/gpt-5.6-sol/xhigh is catalog-supported, authenticated, and the only profile satisfying the required strongest reasoning class. It is tight at headroom 1 but has established three-hour runway for the two-hour horizon. Codex/gpt-5.6-sol/high is catalog-supported and authenticated with much more quota but is a weaker reasoning class that does not meet the requirement. There is no configured load preference. Return exact lines FACT=traex|reasoning=required|headroom=1|runway_seconds=10800 and FACT=codex|reasoning=weaker|headroom=80|runway_seconds=28800, then exact final line SELECTED=<traex|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=traex|reasoning=required|headroom=1|runway_seconds=10800" \
  "FACT=codex|reasoning=weaker|headroom=80|runway_seconds=28800"

echo "# all quota-array-dispatch live behavior tests passed"
