#!/usr/bin/env bash
# Behavioral coverage for the durable context-mode WebFetch compatibility patch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FIX="$ROOT/bin/fm-context-mode-webfetch-fix.sh"

write_routing_fixture() {
  local path=$1
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'MJS'
function mcpRedirect(result) {
  return result;
}

function getWebFetchUrl(toolInput) {
  if (!toolInput || typeof toolInput !== "object") return "";
  if (typeof toolInput.url === "string") return toolInput.url;
  if (typeof toolInput.URL === "string") return toolInput.URL;
  if (typeof toolInput.Url === "string") return toolInput.Url;
  return "";
}

function getCodexConfigDir(env = process.env) {
  return env.CODEX_HOME;
}

export function routePreToolUse(toolName, toolInput) {
  const canonical = toolName;
  const t = name => name;

  // ─── WebFetch: deny + redirect to sandbox ───
  if (canonical === "WebFetch") {
    const url = getWebFetchUrl(toolInput);
    return mcpRedirect({
      action: "deny",
      reason: `context-mode: WebFetch redirected. Call ${t("ctx_fetch_and_index")}(url: "${url}")`,
    });
  }
  return null;
}
MJS
}

write_plugin_fixture() {
  local claude_dir=$1 cache_dir
  cache_dir="$claude_dir/plugins/cache/context-mode/context-mode/1.2.3"
  write_routing_fixture "$claude_dir/plugins/marketplaces/context-mode/hooks/core/routing.mjs"
  write_routing_fixture "$cache_dir/hooks/core/routing.mjs"
  mkdir -p "$claude_dir/plugins"
  cat > "$claude_dir/plugins/installed_plugins.json" <<JSON
{
  "version": 2,
  "plugins": {
    "context-mode@context-mode": [
      {"scope": "user", "installPath": "$cache_dir", "version": "1.2.3"}
    ]
  }
}
JSON
}

webfetch_matrix() {
  local routing=$1
  node --input-type=module - "$routing" <<'JS'
import { pathToFileURL } from "node:url";

const routing = await import(pathToFileURL(process.argv[2]).href);
const cases = [
  ["claude.ai", "https://claude.ai/artifact"],
  ["sub.claude.ai", "https://sub.claude.ai/path"],
  ["example.com", "https://example.com"],
  ["notclaude.ai.evil.com", "https://notclaude.ai.evil.com"],
  ["myclaude.ai", "https://myclaude.ai"],
];
for (const [host, url] of cases) {
  const result = routing.routePreToolUse("WebFetch", { url });
  console.log(`${host}=${result === null ? "allowed" : result.action}`);
}
JS
}

test_applies_to_both_copies_and_refuses_suffix_spoofs() {
  local tmp claude_dir marketplace cache output
  tmp=$(fm_test_tmproot fm-context-mode-webfetch)
  claude_dir="$tmp/.claude"
  marketplace="$claude_dir/plugins/marketplaces/context-mode/hooks/core/routing.mjs"
  cache="$claude_dir/plugins/cache/context-mode/context-mode/1.2.3/hooks/core/routing.mjs"
  write_plugin_fixture "$claude_dir"

  output=$("$FIX" --claude-dir "$claude_dir") || fail "patch application failed: $output"
  assert_contains "$output" "$marketplace" "patcher did not report the marketplace checkout"
  assert_contains "$output" "$cache" "patcher did not report the active cache"
  output=$(webfetch_matrix "$marketplace") || fail "marketplace fixture did not load: $output"
  assert_contains "$output" "claude.ai=allowed" "claude.ai must be allowed"
  assert_contains "$output" "sub.claude.ai=allowed" "claude.ai subdomains must be allowed"
  assert_contains "$output" "example.com=deny" "unrelated hosts must remain denied"
  assert_contains "$output" "notclaude.ai.evil.com=deny" "suffix spoofing must remain denied"
  assert_contains "$output" "myclaude.ai=deny" "lookalike suffixes must remain denied"
  output=$(webfetch_matrix "$cache") || fail "cache fixture did not load: $output"
  assert_contains "$output" "claude.ai=allowed" "cache copy must allow claude.ai"
  assert_contains "$output" "notclaude.ai.evil.com=deny" "cache copy must refuse suffix spoofing"
  "$FIX" --claude-dir "$claude_dir" --check >/dev/null || fail "check mode rejected both patched copies"
  output=$("$FIX" --claude-dir "$claude_dir") || fail "second patch application failed: $output"
  assert_contains "$output" "already applied" "patcher must be idempotent"
  pass "context-mode patch applies to both copies and preserves the WebFetch boundary"
}

test_refuses_drift_before_writing_either_copy() {
  local tmp claude_dir marketplace output rc
  tmp=$(fm_test_tmproot fm-context-mode-webfetch-drift)
  claude_dir="$tmp/.claude"
  marketplace="$claude_dir/plugins/marketplaces/context-mode/hooks/core/routing.mjs"
  write_plugin_fixture "$claude_dir"
  sed -i.bak 's/function getCodexConfigDir/function getCodexConfigDirectory/' \
    "$claude_dir/plugins/cache/context-mode/context-mode/1.2.3/hooks/core/routing.mjs"
  rm -f "$claude_dir/plugins/cache/context-mode/context-mode/1.2.3/hooks/core/routing.mjs.bak"
  rc=0
  output=$("$FIX" --claude-dir "$claude_dir" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "patcher accepted a drifted active cache"
  assert_contains "$output" "expected WebFetch URL helper anchor exactly once" \
    "patcher did not name the drifted source shape"
  output=$(webfetch_matrix "$marketplace") || fail "unmodified marketplace fixture did not load: $output"
  assert_contains "$output" "claude.ai=deny" "drift preflight must leave the marketplace copy untouched"
  pass "context-mode patch refuses changed source before writing either copy"
}

test_applies_to_both_copies_and_refuses_suffix_spoofs
test_refuses_drift_before_writing_either_copy
