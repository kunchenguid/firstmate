#!/usr/bin/env bash
# Shared pre-dispatch gate for GitHub Copilot premium routes.
#
# Usage: . bin/fm-copilot-quota-lib.sh
#        fm_copilot_model_available <model>
#
# Only models beginning with github-copilot/ use this gate. The normalized
# snapshot is refreshed from account.getQuota when older than five minutes.
# This helper never invokes a model, polls an LLM, or changes route selection.

FM_COPILOT_QUOTA_SNAPSHOT=${FM_COPILOT_QUOTA_SNAPSHOT:-${HOME}/.cache/copilot/usage-dashboard-quota-normalized.json}
FM_COPILOT_REFRESH_AFTER_SECONDS=${FM_COPILOT_REFRESH_AFTER_SECONDS:-300}
FM_COPILOT_CLI=${FM_COPILOT_CLI:-${HOME}/.nix-profile/bin/copilot}

fm_copilot_model_is_premium() {
  case ${1:-} in
    github-copilot/*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_copilot_epoch() {
  date -u -d "$1" +%s 2>/dev/null ||
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null
}

fm_copilot_snapshot_fresh() {
  local retrieved now parsed age
  retrieved=$(jq -er '.retrievedAt | select(type == "string" and length > 0)' \
    "$FM_COPILOT_QUOTA_SNAPSHOT" 2>/dev/null) || return 1
  now=$(date -u +%s) || return 1
  parsed=$(fm_copilot_epoch "$retrieved") || return 1
  age=$((now - parsed))
  [ "$age" -ge 0 ] && [ "$age" -le "$FM_COPILOT_REFRESH_AFTER_SECONDS" ]
}

fm_copilot_snapshot_structurally_valid() {
  jq -e '
    type == "object" and
    .provider == "copilot" and
    .quotaType == "premium_interactions" and
    .source == "live account.getQuota" and
    (.retrievedAt | type) == "string" and (.retrievedAt | length) > 0 and
    (.hasQuota | type) == "boolean" and
    (.usageAllowedWithExhaustedQuota | type) == "boolean" and
    (.remaining | type) == "number" and
    (.percentRemaining | type) == "number"
  ' "$FM_COPILOT_QUOTA_SNAPSHOT" >/dev/null 2>&1
}

fm_copilot_snapshot_eligible() {
  fm_copilot_snapshot_structurally_valid || return 1
  jq -e '.hasQuota == true and
    (.usageAllowedWithExhaustedQuota == true or .remaining > 0)
  ' "$FM_COPILOT_QUOTA_SNAPSHOT" >/dev/null 2>&1
}

fm_copilot_refresh_snapshot() {
  local cli sdk raw retrieved tmp normalized
  cli=$(readlink -f "$FM_COPILOT_CLI" 2>/dev/null || realpath "$FM_COPILOT_CLI" 2>/dev/null) || return 1
  [ -x "$cli" ] || return 1
  sdk="$(dirname "$(dirname "$cli")")/lib/github-copilot-cli/copilot-sdk/index.js"
  [ -f "$sdk" ] || return 1
  raw=$(FM_COPILOT_CLI_PATH="$cli" FM_COPILOT_SDK_PATH="$sdk" \
    timeout 45 node --input-type=module -e '
      const { CopilotClient, RuntimeConnection } = await import(process.env.FM_COPILOT_SDK_PATH);
      const client = new CopilotClient({connection: RuntimeConnection.forStdio({path: process.env.FM_COPILOT_CLI_PATH})});
      try { await client.start(); process.stdout.write(JSON.stringify(await client.rpc.account.getQuota())); }
      finally { await client.stop().catch(() => {}); }
    ' 2>/dev/null) || return 1
  retrieved=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1
  normalized=$(printf '%s\n' "$raw" | jq -e --arg retrieved "$retrieved" '
    .quotaSnapshots.premium_interactions as $p |
    .quotaSnapshots.chat as $chat |
    .quotaSnapshots.completions as $completions |
    if ($p.entitlementRequests | type) != "number" or
       ($p.usedRequests | type) != "number" or
       ($p.remainingPercentage | type) != "number" or
       ($p.hasQuota | type) != "boolean" or
       ($p.usageAllowedWithExhaustedQuota | type) != "boolean" or
       ($p.tokenBasedBilling | type) != "boolean" then
      error("incomplete Copilot quota response")
    else {
      provider: "copilot",
      quotaType: "premium_interactions",
      entitlement: $p.entitlementRequests,
      used: $p.usedRequests,
      remaining: ([0, ($p.entitlementRequests - $p.usedRequests)] | max),
      percentRemaining: $p.remainingPercentage,
      hasQuota: $p.hasQuota,
      usageAllowedWithExhaustedQuota: $p.usageAllowedWithExhaustedQuota,
      tokenBasedBilling: $p.tokenBasedBilling,
      rawResetDate: ($p.resetDate // null),
      resetsAt: null,
      resetReliable: false,
      retrievedAt: $retrieved,
      source: "live account.getQuota",
      chatUnlimited: (($chat.isUnlimitedEntitlement // false) == true),
      completionsUnlimited: (($completions.isUnlimitedEntitlement // false) == true)
    }
    end
  ' 2>/dev/null) || return 1
  mkdir -p "$(dirname "$FM_COPILOT_QUOTA_SNAPSHOT")" || return 1
  tmp=$(mktemp "${FM_COPILOT_QUOTA_SNAPSHOT}.tmp.XXXXXX") || return 1
  if ! printf '%s\n' "$normalized" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$FM_COPILOT_QUOTA_SNAPSHOT"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_copilot_model_available() {
  local model=${1:-}
  fm_copilot_model_is_premium "$model" || return 0
  if fm_copilot_snapshot_fresh && fm_copilot_snapshot_structurally_valid; then
    fm_copilot_snapshot_eligible
    return $?
  fi
  fm_copilot_refresh_snapshot || return 1
  fm_copilot_snapshot_eligible
}

fm_copilot_model_refusal() {
  printf 'Copilot premium quota unavailable or exhausted for %s; no model invocation attempted\n' "${1:-unknown}" >&2
}
