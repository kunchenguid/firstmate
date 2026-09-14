#!/usr/bin/env bash
# Deterministic proof for the fleet-wide Copilot premium pre-dispatch gate.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-copilot-quota-gate.XXXXXX")
SNAPSHOT="$LAB/quota.json"
FAKEBIN="$LAB/bin"
FAKE_CLI="$LAB/copilot/bin/copilot"
FAKE_SDK="$LAB/copilot/lib/github-copilot-cli/copilot-sdk/index.js"
trap 'rm -rf "$LAB"' EXIT

mkdir -p "$FAKEBIN" "$(dirname "$FAKE_CLI")" "$(dirname "$FAKE_SDK")"
cat > "$FAKEBIN/node" <<'SH'
#!/usr/bin/env bash
[ "${FM_COPILOT_TEST_FAIL:-0}" = 1 ] && exit 1
printf '%s\n' "${FM_COPILOT_TEST_RESPONSE:?}"
SH
chmod +x "$FAKEBIN/node"
printf '#!/bin/sh\n' > "$FAKE_CLI"
chmod +x "$FAKE_CLI"
printf '// test SDK marker\n' > "$FAKE_SDK"

export PATH="$FAKEBIN:$PATH"
export FM_COPILOT_QUOTA_SNAPSHOT="$SNAPSHOT"
export FM_COPILOT_CLI="$FAKE_CLI"
export FM_COPILOT_REFRESH_AFTER_SECONDS=300
# shellcheck source=bin/fm-copilot-quota-lib.sh
. "$BIN/fm-copilot-quota-lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

fresh=$(date -u +%Y-%m-%dT%H:%M:%SZ)
write_snapshot() {
  local retrieved=$1 has=$2 remaining=$3
  jq -n --arg retrieved "$retrieved" --argjson has "$has" --argjson remaining "$remaining" '{
    provider: "copilot", quotaType: "premium_interactions", entitlement: 1500,
    used: (1500 - $remaining), remaining: $remaining,
    percentRemaining: (($remaining / 1500) * 100), hasQuota: $has,
    usageAllowedWithExhaustedQuota: false, retrievedAt: $retrieved,
    source: "live account.getQuota", resetReliable: false
  }' > "$SNAPSHOT"
}

LIVE_EXHAUSTED='{"quotaSnapshots":{"premium_interactions":{"entitlementRequests":1500,"usedRequests":1500,"remainingPercentage":0,"hasQuota":false,"usageAllowedWithExhaustedQuota":false,"tokenBasedBilling":true,"resetDate":"2030-01-01T00:00:00Z"},"chat":{"isUnlimitedEntitlement":true},"completions":{"isUnlimitedEntitlement":true}}}'
LIVE_AVAILABLE='{"quotaSnapshots":{"premium_interactions":{"entitlementRequests":1500,"usedRequests":0,"remainingPercentage":100,"hasQuota":true,"usageAllowedWithExhaustedQuota":false,"tokenBasedBilling":true,"resetDate":"2030-01-01T00:00:00Z"},"chat":{"isUnlimitedEntitlement":true},"completions":{"isUnlimitedEntitlement":true}}}'

# A. Fresh available state must not refresh.
write_snapshot "$fresh" true 1500
export FM_COPILOT_TEST_FAIL=1
if ! fm_copilot_model_available github-copilot/kimi-k3; then
  fail "fresh available snapshot was not accepted without refresh"
fi
ok "fresh available snapshot avoids live refresh"

# B. Fresh exhausted state must block without refreshing.
write_snapshot "$fresh" false 0
if fm_copilot_model_available github-copilot/gemini-3.8-flash; then
  fail "fresh exhausted snapshot was allowed"
fi
ok "fresh exhausted snapshot blocks before invocation"

# C. Stale available state refreshes to exhausted and blocks.
write_snapshot 2000-01-01T00:00:00Z true 1500
export FM_COPILOT_TEST_FAIL=0 FM_COPILOT_TEST_RESPONSE="$LIVE_EXHAUSTED"
if fm_copilot_model_available github-copilot/kimi-k3; then
  fail "stale available state remained eligible after exhausted refresh"
fi
jq -e '.hasQuota == false and .remaining == 0' "$SNAPSHOT" >/dev/null || fail "exhausted refresh was not written"
ok "stale available state refreshes and blocks on exhaustion"

# D. Stale exhausted state refreshes to available automatically.
write_snapshot 2000-01-01T00:00:00Z false 0
export FM_COPILOT_TEST_RESPONSE="$LIVE_AVAILABLE"
if ! fm_copilot_model_available github-copilot/kimi-k3; then
  fail "stale exhausted state did not recover after available refresh"
fi
jq -e '.hasQuota == true and .remaining == 1500' "$SNAPSHOT" >/dev/null || fail "available refresh was not written"
ok "stale exhausted state refreshes and recovers automatically"

# E. Failed refresh fails closed.
write_snapshot 2000-01-01T00:00:00Z true 1500
export FM_COPILOT_TEST_FAIL=1
if fm_copilot_model_available github-copilot/kimi-k3; then
  fail "failed refresh allowed Copilot"
fi
ok "missing or stale state with failed refresh fails closed"

# F. Local Qwen is not gated by Copilot state.
if ! fm_copilot_model_available ollama/qwen3:8b; then
  fail "local Qwen was blocked by the Copilot gate"
fi
ok "local Qwen remains eligible"

cat > "$LAB/quota-axi.json" <<'JSON'
{
  "schemaVersion": 5,
  "providers": [
    {"provider":"pi","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}},
    {"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}},
    {"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]}}
  ]
}
JSON

# G. Existing Claude/Codex quota-aware path remains unchanged, and Copilot is skipped.
write_snapshot "$fresh" false 0
export FM_COPILOT_TEST_FAIL=1
out=$("$BIN/fm-quota-choose.sh" --snapshot "$LAB/quota-axi.json" \
  --candidate pi:github-copilot/kimi-k3 --candidate pi:ollama/qwen3:8b) || fail "candidate chooser rejected Qwen fallback"
[ "$out" = "pi ollama/qwen3:8b" ] || fail "expected Qwen fallback, got $out"
ok "candidate chooser skips Copilot and selects Qwen"
out=$("$BIN/fm-quota-choose.sh" --snapshot "$LAB/quota-axi.json" --candidate claude:default) || fail "Claude path failed"
[ "$out" = "claude default" ] || fail "unexpected Claude result: $out"
out=$("$BIN/fm-quota-choose.sh" --snapshot "$LAB/quota-axi.json" --candidate codex:default) || fail "Codex path failed"
[ "$out" = "codex default" ] || fail "unexpected Codex result: $out"
ok "Claude/Codex native quota-aware paths remain intact"

# H. A SecondMate/worker context uses the identical shared gate.
if FM_HOME="$LAB/secondmate-home" fm_copilot_model_available github-copilot/kimi-k3; then
  fail "SecondMate context bypassed the shared Copilot gate"
fi
ok "SecondMate/worker context uses the same gate"
