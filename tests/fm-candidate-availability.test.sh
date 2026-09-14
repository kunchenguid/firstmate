#!/usr/bin/env bash
# Unit tests for bin/fm-candidate-availability-lib.sh, the generic
# candidate-availability layer shared by fm-quota-choose.sh and fm-spawn.sh's
# final pre-launch gate.
#
# Drives fm_candidate_availability, fm_candidate_provider_for_harness, and
# fm_candidate_effective_for_provider_model directly against deterministic
# quota-axi JSON fixtures and a fake Copilot snapshot; no fm-spawn.sh or
# fm-quota-choose.sh invocation here (those are covered by
# tests/fm-spawn-dispatch-profile.test.sh and tests/fm-quota-choose.test.sh
# respectively, which exercise this library through their public interfaces).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-candidate-availability.XXXXXX")
trap 'rm -rf "$LAB"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

export FM_COPILOT_QUOTA_SNAPSHOT="$LAB/copilot-quota.json"
export FM_COPILOT_CLI="$LAB/no-such-copilot-cli"

# shellcheck source=bin/fm-candidate-availability-lib.sh
. "$BIN/fm-candidate-availability-lib.sh"

write_copilot_snapshot() {
  local has=$1 remaining=$2
  jq -n --arg retrieved "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson has "$has" --argjson remaining "$remaining" '{
    provider: "copilot", quotaType: "premium_interactions", entitlement: 1500,
    used: (1500 - $remaining), remaining: $remaining,
    percentRemaining: (($remaining / 1500) * 100), hasQuota: $has,
    usageAllowedWithExhaustedQuota: false, retrievedAt: $retrieved,
    source: "live account.getQuota", resetReliable: false
  }' > "$FM_COPILOT_QUOTA_SNAPSHOT"
}

QUOTA_JSON=$(cat <<'JSON'
{
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {"scope": "all_models", "status": "known", "effectivePercentRemaining": 42, "runway": {"status": "through_reset"}},
          {"scope": "model:fable", "status": "known", "effectivePercentRemaining": 0, "runway": {"status": "exhausted_now"}}
        ]
      }
    },
    {
      "provider": "codex",
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {"scope": "all_models", "status": "known", "effectivePercentRemaining": 0, "runway": {"status": "exhausted_now"}}
        ]
      }
    },
    {
      "provider": "copilot",
      "quotaSemantics": {"status": "unknown", "effectiveAvailability": []}
    }
  ]
}
JSON
)

# --- Claude: quota-axi is authoritative -------------------------------------

out=$(fm_candidate_availability "$QUOTA_JSON" claude default)
[ "$(printf '%s' "$out" | jq -r '.provider,.source,.status,.eligible' | tr '\n' ' ')" = "claude quota-axi known true " ] \
  || fail "Claude default candidate: unexpected result: $out"
ok "Claude reads quota-axi's known, positive provider-wide window as eligible"

out=$(fm_candidate_availability "$QUOTA_JSON" claude fable)
[ "$(printf '%s' "$out" | jq -r '.eligible')" = false ] \
  || fail "Claude fable candidate should be ineligible: $out"
[ "$(printf '%s' "$out" | jq -r '.status')" = known ] \
  || fail "Claude fable candidate should still report known status: $out"
ok "Claude reads a named-model exhausted window as ineligible, still known"

# --- Codex: quota-axi is authoritative ---------------------------------------

out=$(fm_candidate_availability "$QUOTA_JSON" codex default)
[ "$(printf '%s' "$out" | jq -r '.provider,.source,.eligible' | tr '\n' ' ')" = "codex quota-axi false " ] \
  || fail "Codex exhausted candidate: unexpected result: $out"
ok "Codex reads quota-axi's exhausted_now window as ineligible"

# --- Copilot: fallback producer, never quota-axi -----------------------------

write_copilot_snapshot true 1500
out=$(fm_candidate_availability "$QUOTA_JSON" claude github-copilot/kimi-k3)
[ "$(printf '%s' "$out" | jq -r '.provider,.source,.status,.eligible' | tr '\n' ' ')" = "copilot copilot known true " ] \
  || fail "Copilot available candidate: unexpected result: $out"
ok "Copilot candidate is eligible when its live snapshot has quota"

write_copilot_snapshot false 0
out=$(fm_candidate_availability "$QUOTA_JSON" claude github-copilot/kimi-k3)
[ "$(printf '%s' "$out" | jq -r '.source,.eligible' | tr '\n' ' ')" = "copilot false " ] \
  || fail "Copilot exhausted candidate: unexpected result: $out"
ok "Copilot candidate is ineligible when its live snapshot has no quota"

# quota-axi's own copilot row (status unknown, no window) must never be
# consulted: fm-quota-choose.sh and fm-spawn.sh only ever pass the Copilot
# adapter's own live verdict, proving Copilot is a fallback PRODUCER, not a
# quota-axi consumer.
out=$(fm_candidate_availability "$QUOTA_JSON" pi github-copilot/kimi-k3)
[ "$(printf '%s' "$out" | jq -r '.provider')" = copilot ] \
  || fail "Copilot candidate must resolve provider 'copilot' regardless of harness or quota-axi's own copilot row: $out"
ok "Copilot identity comes from the model prefix, never from quota-axi's own (always-unknown) copilot row"

# --- Local Qwen: no paid-quota policy, quota-axi never consulted ------------

out=$(fm_candidate_availability "$QUOTA_JSON" omp ollama/qwen3:8b)
[ "$(printf '%s' "$out" | jq -r '.provider,.source,.status,.eligible' | tr '\n' ' ')" = "local local not_applicable true " ] \
  || fail "local Qwen candidate: unexpected result: $out"
ok "local Qwen (omp ollama/ prefix) is always eligible, not_applicable status"

out=$(fm_candidate_availability "" omp ollama/qwen3:8b)
[ "$(printf '%s' "$out" | jq -r '.eligible')" = true ] \
  || fail "local Qwen must be eligible even with no quota snapshot at all: $out"
ok "local Qwen needs no quota-axi snapshot at all"

out=$(fm_candidate_availability 'not valid json' omp ollama/qwen3:8b)
[ "$(printf '%s' "$out" | jq -r '.eligible')" = true ] \
  || fail "local Qwen must be eligible even when the quota snapshot is garbage: $out"
ok "local Qwen is never blocked by a malformed quota snapshot"

# Pi's own catalog declares one analogous local lane, gx10-vllm/<id>; the
# default local Qwen candidate is gx10-vllm/qwen3.8-27b-fp8 (this is the
# REQUIRED default lane, not just omp's ollama/ prefix).
out=$(fm_candidate_availability "$QUOTA_JSON" pi gx10-vllm/qwen3.8-27b-fp8)
[ "$(printf '%s' "$out" | jq -r '.provider,.source,.status,.eligible' | tr '\n' ' ')" = "local local not_applicable true " ] \
  || fail "Pi local Qwen candidate: unexpected result: $out"
ok "the default local Qwen lane (pi gx10-vllm/qwen3.8-27b-fp8) is always eligible, not_applicable status"

out=$(fm_candidate_availability "" pi gx10-vllm/qwen3.8-27b-fp8)
[ "$(printf '%s' "$out" | jq -r '.eligible')" = true ] \
  || fail "Pi local Qwen must be eligible even with no quota snapshot at all: $out"
ok "Pi local Qwen needs no quota-axi snapshot at all"

out=$(fm_candidate_availability 'not valid json' pi gx10-vllm/qwen3.8-27b-fp8)
[ "$(printf '%s' "$out" | jq -r '.eligible')" = true ] \
  || fail "Pi local Qwen must be eligible even when the quota snapshot is garbage: $out"
ok "Pi local Qwen is never blocked by a malformed quota snapshot"

# Every other Pi model keeps the existing single-family "pi" mapping: an
# exhausted Pi account window still vetoes an ordinary Pi candidate, proving
# the gx10-vllm carve-out did not loosen Pi's general quota-axi behavior.
PI_QUOTA_JSON=$(printf '%s' "$QUOTA_JSON" | jq '.providers += [{"provider":"pi","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}}]')
out=$(fm_candidate_availability "$PI_QUOTA_JSON" pi default)
[ "$(printf '%s' "$out" | jq -r '.provider,.source,.eligible' | tr '\n' ' ')" = "pi quota-axi false " ] \
  || fail "an ordinary Pi candidate must still use Pi's own quota-axi row: $out"
ok "an ordinary Pi model (not gx10-vllm/) keeps the existing single-family quota-axi mapping"

# --- Provider mapping without quota-axi coverage or a Copilot prefix --------

out=$(fm_candidate_availability "$QUOTA_JSON" omp vllm/qwen3:8b)
[ "$(printf '%s' "$out" | jq -r '.provider,.source,.status,.eligible' | tr '\n' ' ')" = "null none unknown false " ] \
  || fail "unmapped omp prefix candidate: unexpected result: $out"
ok "an unmapped omp prefix reports unknown/ineligible rather than failing the call"

out=$(fm_candidate_availability "$QUOTA_JSON" agy default)
[ "$(printf '%s' "$out" | jq -r '.provider,.source')" = "$(printf 'null\nnone')" ] \
  || fail "agy (no provider mapping) candidate: unexpected result: $out"
ok "a harness with no provider mapping (agy) is reported unknown, not an error"

# A github-copilot/ model on a harness with no provider mapping is still
# gated correctly: the Copilot check runs before provider resolution, so
# fm-spawn.sh's final gate keeps working for harnesses this optional layer
# does not otherwise map (agy, gemini, rovo, ...).
write_copilot_snapshot false 0
out=$(fm_candidate_availability "$QUOTA_JSON" agy github-copilot/kimi-k3)
[ "$(printf '%s' "$out" | jq -r '.provider,.source,.eligible' | tr '\n' ' ')" = "copilot copilot false " ] \
  || fail "Copilot gate must apply even for a harness with no provider mapping: $out"
ok "the Copilot check applies independently of provider mapping"

# --- fm_candidate_provider_for_harness and fm_candidate_effective_for_provider_model ---

[ "$(fm_candidate_provider_for_harness claude)" = claude ] || fail "claude provider mapping regressed"
[ "$(fm_candidate_provider_for_harness codex)" = codex ] || fail "codex provider mapping regressed"
[ "$(fm_candidate_provider_for_harness opencode)" = codex ] || fail "opencode provider mapping regressed"
[ "$(fm_candidate_provider_for_harness pi)" = pi ] || fail "pi provider mapping regressed"
[ "$(fm_candidate_provider_for_harness pi-signed)" = pi ] || fail "pi-signed provider mapping regressed"
[ "$(fm_candidate_provider_for_harness pi gx10-vllm/qwen3.8-27b-fp8)" = local ] || fail "pi gx10-vllm mapping regressed"
[ "$(fm_candidate_provider_for_harness pi-signed gx10-vllm/qwen3.8-27b-fp8)" = local ] || fail "pi-signed gx10-vllm mapping regressed"
[ "$(fm_candidate_provider_for_harness pi some-other-model)" = pi ] || fail "a non-gx10-vllm Pi model must keep the pi family"
[ "$(fm_candidate_provider_for_harness grok)" = grok ] || fail "grok provider mapping regressed"
[ "$(fm_candidate_provider_for_harness kimi)" = kimi ] || fail "kimi provider mapping regressed"
[ "$(fm_candidate_provider_for_harness cursor)" = cursor ] || fail "cursor provider mapping regressed"
[ "$(fm_candidate_provider_for_harness muse)" = meta ] || fail "muse provider mapping regressed"
[ "$(fm_candidate_provider_for_harness omp openai-codex/foo)" = codex ] || fail "omp openai-codex mapping regressed"
[ "$(fm_candidate_provider_for_harness omp claude-bridge/foo)" = claude ] || fail "omp claude-bridge mapping regressed"
[ "$(fm_candidate_provider_for_harness omp ollama/foo)" = local ] || fail "omp ollama mapping regressed"
if fm_candidate_provider_for_harness omp vllm/foo >/dev/null; then
  fail "omp with an unmapped prefix must fail closed"
fi
if fm_candidate_provider_for_harness bogus >/dev/null; then
  fail "an unknown harness must fail closed"
fi
ok "fm_candidate_provider_for_harness preserves every existing provider mapping plus the new ollama/ and gx10-vllm/ local mappings"

effective=$(fm_candidate_effective_for_provider_model "$QUOTA_JSON" claude fable-2)
[ "$(printf '%s' "$effective" | jq -r '.effectivePercentRemaining,.runway.status' | tr '\n' ' ')" = "42 through_reset " ] \
  || fail "named model without its own window should read the provider-wide scope: $effective"
ok "fm_candidate_effective_for_provider_model applies provider-wide scope to an unnamed model"

effective=$(fm_candidate_effective_for_provider_model "$QUOTA_JSON" nonexistent default)
[ "$(printf '%s' "$effective" | jq -r '.status')" = unknown ] \
  || fail "a provider absent from the snapshot should read unknown: $effective"
ok "fm_candidate_effective_for_provider_model reads a missing provider as unknown"

printf '# all fm-candidate-availability tests passed\n'
