#!/usr/bin/env bash
# Credentialed behavior regression for the agent-owned policy-service dispatch
# selector in AGENTS.md section 4.
#
# This drives the real AGENTS.md intake contract through the public Pi interface
# against a fake local policy skill rather than parsing instruction source bytes
# or recreating the delegation rules in test code.
set -u

if [ "${FM_POLICY_SERVICE_DISPATCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_POLICY_SERVICE_DISPATCH_LIVE_E2E=1 to run the credentialed Pi policy-service dispatch regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACT="$ROOT/AGENTS.md"
QUOTA_OWNER="$ROOT/.agents/skills/quota-array-dispatch/SKILL.md"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
[ -f "$CONTRACT" ] || fail "AGENTS.md contract not found"
[ -f "$QUOTA_OWNER" ] || fail "quota-array-dispatch skill not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-policy-service-dispatch-live.XXXXXX")
HOME_DIR="$LAB/home"
FAKEBIN="$LAB/fakebin"
VERDICT="$LAB/policy-verdict"
POLICY_CALLS="$LAB/policy-axi.calls"
QUOTA_CALLS="$LAB/quota-axi.calls"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p \
  "$HOME_DIR/config" \
  "$HOME_DIR/.agents/skills/quota-array-dispatch" \
  "$HOME_DIR/.agents/skills/governor-admission" \
  "$FAKEBIN"

# The instruction under test is the repository's own always-loaded contract, not
# a test-authored paraphrase of it.
cp "$CONTRACT" "$HOME_DIR/AGENTS.md"
cp "$QUOTA_OWNER" "$HOME_DIR/.agents/skills/quota-array-dispatch/SKILL.md"

# A static crewmate harness that a silent fallback would reach for. No case may
# ever resolve to it.
printf '%s\n' claude > "$HOME_DIR/config/crew-harness"

# Test-only stand-in for a captain's local economic policy skill. It owns
# selection for its intake and answers only from the candidates it is handed.
printf '%s\n' \
  '---' \
  'name: governor-admission' \
  'description: Test-only economic admission policy for policy-service dispatch.' \
  'user-invocable: false' \
  '---' \
  '' \
  '# governor-admission' \
  '' \
  'This skill is the single owner of profile selection for the intake that names it.' \
  'Run `policy-axi --candidates <json>` exactly once, passing the complete candidate' \
  'array you were handed as one compact JSON array, in the order you received it.' \
  'Never drop, reorder, or preselect a candidate before that call.' \
  'The command prints either `ROUTE <harness>/<model>/<effort>` or `NO_ROUTE <reason>`.' \
  'Report that answer as the policy result and never substitute your own choice for it.' \
  > "$HOME_DIR/.agents/skills/governor-admission/SKILL.md"

cat > "$FAKEBIN/policy-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" != --candidates ] || [ "$#" -ne 2 ]; then
  printf 'unexpected policy-axi invocation: %s\n' "$*" >&2
  exit 64
fi
printf '%s\n' "$2" >> "${POLICY_AXI_CALLS:?}"
cat "${POLICY_AXI_VERDICT:?}"
SH
chmod +x "$FAKEBIN/policy-axi"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
if [ "${1:-}" != --json ] || [ "$#" -ne 1 ]; then
  printf 'unexpected quota-axi invocation: %s\n' "$*" >&2
  exit 64
fi
cat <<'JSON'
{"schemaVersion":3,"providers":[{"provider":"claude","quotaSemantics":{"description":"The all_models scope bounds every Claude model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":9,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":600,"projectedExhaustedAt":"2030-01-01T00:10:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}},{"provider":"codex","quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":72,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"2030-01-01T08:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}}]}
JSON
SH
chmod +x "$FAKEBIN/quota-axi"

write_dispatch() {
  cat > "$HOME_DIR/config/crew-dispatch.json"
}

write_verdict() {
  printf '%s\n' "$1" > "$VERDICT"
}

run_intake() {
  local prompt=$1
  : > "$POLICY_CALLS"
  : > "$QUOTA_CALLS"
  (
    cd "$HOME_DIR" &&
      PATH="$FAKEBIN:$PATH" \
        FM_HOME="$HOME_DIR" \
        POLICY_AXI_CALLS="$POLICY_CALLS" \
        POLICY_AXI_VERDICT="$VERDICT" \
        QUOTA_AXI_CALLS="$QUOTA_CALLS" \
        pi --print --approve --no-session --no-context-files --no-extensions \
          --no-skills --skill .agents/skills --tools bash \
          --model openai-codex/gpt-5.6-sol --thinking high \
          "$prompt"
  )
}

# Every case answers in the same shape, so no prompt states the delegation,
# no-route, or tie rules the contract itself has to supply.
REPORT_CONTRACT='Report an exact final line DISPATCH=<harness>/<model>/<effort> naming the single concrete profile you would pass to fm-spawn, or the exact final line DISPATCH=NONE if you would not dispatch at all, preceded by an exact line REASON=<one line>. Do not spawn anything, do not modify files, and do not run other vendor or model commands.'

INTAKE='A crewmate intake for budgeted feature work has arrived and there is no per-task captain override. Resolve its dispatch profile now from config/crew-dispatch.json in this home.'

# --- Case 1: the complete array reaches the named policy, whose concrete answer wins ---

write_dispatch <<'JSON'
{
  "rules": [
    {
      "when": "budgeted feature work",
      "use": [
        { "harness": "claude", "model": "claude-sonnet-5", "effort": "high" },
        { "harness": "codex", "model": "gpt-5.5", "effort": "high" },
        { "harness": "grok", "model": "grok-4", "effort": "high" }
      ],
      "select": "policy-service",
      "policy": "governor-admission"
    }
  ]
}
JSON
write_verdict 'ROUTE grok/grok-4/high'

out=$(run_intake "$INTAKE $REPORT_CONTRACT") \
  || fail "policy-service delegation: Pi run failed: $out"

[ "$(grep -c . "$POLICY_CALLS")" = 1 ] \
  || fail "policy-service delegation: expected exactly one policy call, got: $(cat "$POLICY_CALLS")"

handed=$(jq -S -c '[.[] | {harness, model, effort}]' < "$POLICY_CALLS") \
  || fail "policy-service delegation: policy did not receive a JSON candidate array: $(cat "$POLICY_CALLS")"
expected=$(jq -S -c '[.rules[0].use[] | {harness, model, effort}]' "$HOME_DIR/config/crew-dispatch.json")
[ "$handed" = "$expected" ] \
  || fail "policy-service delegation: policy did not receive the complete configured array: $handed"

# The policy names the last configured candidate, so array-order or
# first-candidate bias cannot produce this answer.
printf '%s\n' "$out" | grep -Fxq "DISPATCH=grok/grok-4/high" \
  || fail "policy-service delegation: expected the policy's concrete profile, got: $out"
printf '%s\n' "$out"
echo "ok - a policy-service rule hands the complete array to its named policy and dispatches only that answer"

# --- Case 2: an explicit no-route stops the intake instead of falling back ---

write_verdict 'NO_ROUTE admission budget exhausted for this class'

out=$(run_intake "$INTAKE $REPORT_CONTRACT") \
  || fail "policy-service no-route: Pi run failed: $out"

[ "$(grep -c . "$POLICY_CALLS")" = 1 ] \
  || fail "policy-service no-route: expected exactly one policy call, got: $(cat "$POLICY_CALLS")"
printf '%s\n' "$out" | grep -Fxq "DISPATCH=NONE" \
  || fail "policy-service no-route: expected an explicit no-dispatch report, got: $out"
printf '%s\n' "$out" | grep -Eq '^DISPATCH=(claude|codex|grok)' \
  && fail "policy-service no-route: silently fell back to a candidate or the static harness: $out"
printf '%s\n' "$out"
echo "ok - an explicit policy no-route stops the intake instead of falling back to a candidate or config/crew-harness"

# --- Case 3: the built-in quota-balanced selector is untouched by the new field ---

write_dispatch <<'JSON'
{
  "rules": [
    {
      "when": "budgeted feature work",
      "use": [
        { "harness": "claude", "model": "claude-sonnet-5", "effort": "high" },
        { "harness": "codex", "model": "gpt-5.5", "effort": "high" }
      ]
    }
  ]
}
JSON
write_verdict 'ROUTE claude/claude-sonnet-5/high'

out=$(run_intake "$INTAKE The two profiles have comparable required task fit and the same strongest reasoning class, their authoritative catalogs already prove both models supported in their stated provider families, their selected authentication surfaces are usable, and the likely task-completion horizon is two hours with established confidence. $REPORT_CONTRACT") \
  || fail "quota-balanced preservation: Pi run failed: $out"

[ ! -s "$POLICY_CALLS" ] \
  || fail "quota-balanced preservation: a rule without a selector delegated to a policy service: $(cat "$POLICY_CALLS")"
[ "$(cat "$QUOTA_CALLS")" = "--json" ] \
  || fail "quota-balanced preservation: expected one quota-axi --json snapshot, got: $(cat "$QUOTA_CALLS")"
printf '%s\n' "$out" | grep -Fxq "DISPATCH=codex/gpt-5.5/high" \
  || fail "quota-balanced preservation: expected the completion-aware quota choice, got: $out"
printf '%s\n' "$out"
echo "ok - a rule with no selector still resolves through quota-array-dispatch and never reaches a policy service"

echo "# all policy-service dispatch live behavior tests passed"
