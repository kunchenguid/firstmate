#!/usr/bin/env bash
# Behavior tests for fm-llm-budget.sh and the Pi gateway-meter adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-llm-budget)
SCRIPT="$ROOT/bin/fm-llm-budget.sh"
EXT="$ROOT/.pi/extensions/fm-llm-budget.ts"
NOW=$(python3 -c 'import time; print(int(time.time()))')

write_cache() {
  local home=$1
  mkdir -p "$home/state"
  cat > "$home/state/llm-budget-cache.json" <<EOF
{"version":1,"source":"gateway-402","email":"tester@rippling.com","cap":2000,"spend":2000.07,"remaining":0,"exhausted":true,"fetched_at_unix":$NOW,"month_start_unix":$NOW}
EOF
}

run_budget() {
  local home=$1
  shift
  HOME="$home" WAVECODE_CONFIG_PATH="$home/.wavecode" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$SCRIPT" "$@"
}

test_print_from_cache_includes_dollars_under_two_seconds() {
  local home out elapsed
  home="$TMP_ROOT/print-cache"
  write_cache "$home"
  elapsed=$(python3 - "$SCRIPT" "$home" <<'PY'
import os, subprocess, sys, time
script, home = sys.argv[1], sys.argv[2]
env = os.environ.copy()
env["FM_HOME"] = home
env["FM_STATE_OVERRIDE"] = os.path.join(home, "state")
start = time.perf_counter()
out = subprocess.check_output([script, "print"], env=env, text=True)
elapsed = time.perf_counter() - start
open(os.path.join(home, "out"), "w").write(out)
print(f"{elapsed:.4f}")
PY
)
  out=$(cat "$home/out")
  printf '%s\n' "$out" | grep -Fq '$' || fail "print did not include a dollar amount: $out"
  printf '%s\n' "$out" | grep -Fq 'exhausted' || fail "exhausted cache should mark exhausted: $out"
  python3 -c 'import sys; elapsed=float(sys.argv[1]); raise SystemExit(0 if elapsed < 2 else 1)' "$elapsed" \
    || fail "print took ${elapsed}s, expected well under 2s"
  pass "print reads cache dollars in well under 2s"
}

test_missing_cache_prints_ellipsis() {
  local home out
  home="$TMP_ROOT/missing-cache"
  mkdir -p "$home/state"
  out=$(run_budget "$home" print)
  [ "$out" = "LLM budget: …" ] || fail "missing cache should print ellipsis, got: $out"
  pass "missing cache prints LLM budget: …"
}

test_non_gateway_print_is_empty() {
  local home out
  home="$TMP_ROOT/non-gateway"
  write_cache "$home"
  out=$(run_budget "$home" print --if-gateway --provider anthropic --model claude-opus)
  [ -z "$out" ] || fail "non-gateway print should be empty, got: $out"
  pass "non-gateway print is empty"
}

test_gateway_print_shows_meter() {
  local home out
  home="$TMP_ROOT/gateway"
  write_cache "$home"
  out=$(run_budget "$home" print --if-gateway --provider rippling-openai --model gpt-5.6-sol)
  printf '%s\n' "$out" | grep -Fq '$' || fail "gateway print missing remaining dollars: $out"
  printf '%s\n' "$out" | grep -Fq 'exhausted' || fail "gateway print missing exhausted mark: $out"
  pass "gateway print shows remaining dollars"
}

test_claude_statusline_empty_for_non_gateway_stdin() {
  local home out
  home="$TMP_ROOT/claude-empty"
  write_cache "$home"
  out=$(printf '%s\n' '{"model":{"id":"claude-opus","display_name":"Opus"}}' \
    | run_budget "$home" claude-statusline)
  [ -z "$out" ] || fail "claude-statusline should be empty off-gateway, got: $out"
  pass "claude-statusline is empty for a non-gateway model"
}

test_claude_statusline_prints_for_rippling_provider() {
  local home out
  home="$TMP_ROOT/claude-gateway"
  write_cache "$home"
  out=$(printf '%s\n' '{"model":{"provider":"rippling-bedrock","id":"claude-sonnet"}}' \
    | run_budget "$home" claude-statusline)
  printf '%s\n' "$out" | grep -Fq '$' || fail "claude-statusline gateway missing dollars: $out"
  pass "claude-statusline prints dollars for a Rippling provider"
}

test_claude_statusline_detects_gateway_url() {
  local home out
  home="$TMP_ROOT/claude-url"
  write_cache "$home"
  out=$(printf '%s\n' '{"model":{"id":"claude-sonnet"}}' \
    | ANTHROPIC_BASE_URL='https://llm-gateway.us1.ripplingdev.net/api/v2' \
      run_budget "$home" claude-statusline)
  printf '%s\n' "$out" | grep -Fq '$' || fail "gateway URL should enable the meter: $out"
  pass "claude-statusline treats an llm-gateway base URL as gateway"
}

test_install_claude_patches_only_statusline() {
  local home
  home="$TMP_ROOT/install-claude"
  mkdir -p "$home/claude" "$home/state"
  cat > "$home/claude/settings.json" <<'JSON'
{"permissions":{"defaultMode":"auto"},"hooks":{"Stop":[]}}
JSON
  CLAUDE_CONFIG_DIR="$home/claude" run_budget "$home" install-claude >/dev/null
  python3 - "$home/claude/settings.json" "$SCRIPT" <<'PY' || fail "install-claude clobbered keys or skipped statusLine"
import json, sys
path, script = sys.argv[1], sys.argv[2]
data = json.load(open(path, encoding="utf-8"))
assert data["permissions"]["defaultMode"] == "auto", data
assert data["hooks"] == {"Stop": []}, data
command = data["statusLine"]["command"]
assert command.endswith("fm-llm-budget.sh claude-statusline --kick-refresh"), command
assert script in command, command
assert data["statusLine"]["type"] == "command"
PY
  pass "install-claude patches only statusLine"
}

test_refresh_keeps_last_good_cache_on_failure() {
  local home before after
  home="$TMP_ROOT/keep-last-good"
  write_cache "$home"
  before=$(cat "$home/state/llm-budget-cache.json")
  PATH="/usr/bin:/bin" \
    HOME="$home" WAVECODE_CONFIG_PATH="$home/.wavecode" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    RIPPLING_EMAIL="tester@rippling.com" \
    "$SCRIPT" refresh >/dev/null 2>&1 || true
  after=$(cat "$home/state/llm-budget-cache.json")
  [ "$before" = "$after" ] || fail "failed refresh overwrote last-good cache"
  pass "failed refresh keeps last-good cache"
}

test_refresh_gateway_402_fallback() {
  local home out
  home="$TMP_ROOT/gateway-402"
  mkdir -p "$home/state" "$home/config" "$home/bin" "$home/pypath"
  cat > "$home/bin/wavecode" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "llm-gateway get-api-key" ]; then
  printf '%s\n' 'lg-test-key'
  exit 0
fi
exit 1
SH
  chmod +x "$home/bin/wavecode"
  cat > "$home/pypath/sitecustomize.py" <<'PY'
import urllib.error
import urllib.request

class _PaymentRequired(urllib.error.HTTPError):
    def __init__(self, url):
        super().__init__(url, 402, "Payment Required", {}, None)
        self._body = b"Budget exhausted: consumed 2000.070300, total 2000.000000"

    def read(self, *args, **kwargs):
        return self._body

def urlopen(req, timeout=None):
    url = getattr(req, "full_url", str(req))
    raise _PaymentRequired(url)

urllib.request.urlopen = urlopen
PY
  PATH="$home/bin:$PATH" PYTHONPATH="$home/pypath${PYTHONPATH:+:$PYTHONPATH}" \
    RIPPLING_EMAIL="tester@rippling.com" \
    run_budget "$home" refresh >/dev/null 2>&1 || fail "402 fallback refresh should succeed"
  out=$(run_budget "$home" print)
  printf '%s\n' "$out" | grep -Fq '$' || fail "402 fallback print missing remaining dollars: $out"
  printf '%s\n' "$out" | grep -Fq 'exhausted' || fail "402 fallback print missing exhausted mark: $out"
  python3 - "$home/state/llm-budget-cache.json" <<'PY' || fail "402 fallback cache shape"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["source"] == "gateway-402", data
assert data["exhausted"] is True, data
assert data["remaining"] == 0, data
PY
  pass "refresh 402 fallback writes exhausted cache"
}

test_refresh_wavecode_exhausted_without_key_writes_zero() {
  local home out
  home="$TMP_ROOT/wavecode-exhausted"
  mkdir -p "$home/state" "$home/config" "$home/bin"
  cat > "$home/bin/wavecode" <<'SH'
#!/usr/bin/env bash
printf 'wavecode: error: checking API key health: your budget is exhausted, please go to #ai-dev-quotas\n' >&2
exit 1
SH
  chmod +x "$home/bin/wavecode"
  PATH="$home/bin:$PATH" HOME="$home" \
    RIPPLING_EMAIL="tester@rippling.com" \
    run_budget "$home" refresh >/dev/null 2>&1 || fail "exhausted wavecode refresh should succeed"
  out=$(run_budget "$home" print)
  printf '%s\n' "$out" | grep -Fq '$' || fail "exhausted wavecode print missing remaining dollars: $out"
  printf '%s\n' "$out" | grep -Fq 'exhausted' || fail "exhausted wavecode print missing exhausted mark: $out"
  python3 - "$home/state/llm-budget-cache.json" <<'PY' || fail "exhausted wavecode cache shape"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["source"] == "gateway-402", data
assert data["exhausted"] is True, data
assert data["remaining"] == 0, data
assert float(data["cap"]) == 2000, data
PY
  pass "refresh treats wavecode exhausted stderr as remaining zero"
}

test_pi_extension_sets_dedicated_key_only_on_gateway() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found for Pi meter adapter test"; return 0; }
  local fixture
  fixture="$TMP_ROOT/pi-ext"
  mkdir -p \
    "$fixture/project/.pi/extensions" \
    "$fixture/project/bin" \
    "$fixture/project/node_modules/@earendil-works/pi-coding-agent"
  cp "$EXT" "$fixture/project/.pi/extensions/fm-llm-budget.ts"
  cat > "$fixture/project/bin/fm-llm-budget.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'LLM $0 of $2000 (mtd $2000) exhausted'
SH
  chmod +x "$fixture/project/bin/fm-llm-budget.sh"
  cat > "$fixture/project/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$fixture/project/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export {}
JS
  printf '%s\n' '{"type":"module"}' > "$fixture/project/package.json"
  node --input-type=module 2>"$fixture/err" <<JS
import { pathToFileURL } from "node:url";
const extension = await import(pathToFileURL("$fixture/project/.pi/extensions/fm-llm-budget.ts").href + "?t=" + Date.now());
if (extension.LLM_BUDGET_STATUS_KEY !== "firstmate-llm-budget") {
  throw new Error("dedicated key drifted from firstmate-llm-budget");
}
if (extension.isRipplingGatewayModel({ provider: "rippling-openai", id: "gpt-5.6-sol" }) !== true) {
  throw new Error("rippling-openai should be a gateway model");
}
if (extension.isRipplingGatewayModel({ provider: "anthropic", id: "claude-opus" }) !== false) {
  throw new Error("anthropic should not be a gateway model");
}
const statuses = new Map();
const ctx = {
  model: { provider: "rippling-openai", id: "gpt-5.6-sol" },
  ui: {
    setStatus(key, value) { statuses.set(key, value); },
  },
};
const handlers = new Map();
extension.default({
  on(event, handler) { handlers.set(event, handler); },
});
handlers.get("session_start")({}, ctx);
if (statuses.get("firstmate-llm-budget") !== "LLM \$0 of \$2000 (mtd \$2000) exhausted") {
  throw new Error("gateway session did not set the meter: " + JSON.stringify([...statuses]));
}
if (statuses.has("firstmate-calm")) {
  throw new Error("meter must not write Calm's key");
}
ctx.model = { provider: "anthropic", id: "claude-opus" };
handlers.get("session_start")({}, ctx);
if (statuses.get("firstmate-llm-budget") !== undefined) {
  throw new Error("non-gateway session should clear the meter");
}
JS
  pass "Pi adapter uses firstmate-llm-budget and hides off-gateway"
}

test_print_from_cache_includes_dollars_under_two_seconds
test_missing_cache_prints_ellipsis
test_non_gateway_print_is_empty
test_gateway_print_shows_meter
test_claude_statusline_empty_for_non_gateway_stdin
test_claude_statusline_prints_for_rippling_provider
test_claude_statusline_detects_gateway_url
test_install_claude_patches_only_statusline
test_refresh_keeps_last_good_cache_on_failure
test_refresh_gateway_402_fallback
test_refresh_wavecode_exhausted_without_key_writes_zero
test_pi_extension_sets_dedicated_key_only_on_gateway
