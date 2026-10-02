#!/usr/bin/env bash
# Opt-in real OpenCode worker proof using a credential-free, operator-provided
# GLM 5.3 endpoint. FM_SANDBOX_OPENCODE_MODEL must name an existing catalog
# entry ending in /glm-5.3; FM_SANDBOX_OPENCODE_URL must be an unauthenticated
# OpenAI-compatible http://127.0.0.1:<port>/v1 endpoint serving that model.
# Run with FM_LIVE_SANDBOX_OPENCODE=1 after the scoped host prerequisite in
# docs/verification/worker-sandbox.md. No model or credential fallback exists.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_LIVE_SANDBOX_OPENCODE opencode srt jq curl git

model=${FM_SANDBOX_OPENCODE_MODEL:-}
endpoint=${FM_SANDBOX_OPENCODE_URL:-}
[[ "$model" =~ ^[a-zA-Z0-9_-]+/glm-5\.3$ ]] ||
  fail "set FM_SANDBOX_OPENCODE_MODEL to the exact catalog provider/glm-5.3 identifier"
[[ "$endpoint" =~ ^http://127\.0\.0\.1:[0-9]+/v1$ ]] ||
  fail "set FM_SANDBOX_OPENCODE_URL to a credential-free loopback GLM 5.3 endpoint"

lab=$(mktemp -d "$ROOT/.sandbox-opencode-e2e.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$lab")
mkdir -p "$lab/project" "$lab/user-home" "$lab/config" "$lab/data" \
  "$lab/cache" "$lab/tmp" "$lab/fmhome/config" "$lab/denied"
git init -q "$lab/project"
opencode_bin=$(command -v opencode)
provider=${model%/*}
secret="$lab/secret.txt"
secret_value="sandbox-fixture-$RANDOM-$RANDOM"
printf '%s\n' "$secret_value" > "$secret"
: > "$lab/fmhome/config/worker-sandbox"
jq -n --arg lab "$lab" --arg secret "$secret" \
  '{filesystem:{denyRead:[$secret],allowWrite:[$lab],denyWrite:[$lab+"/denied"]},
    network:{allowedDomains:["127.0.0.1"],deniedDomains:[]}}' \
  > "$lab/fmhome/config/worker-sandbox-settings.json"

isolated() {
  env -i PATH="$PATH" HOME="$lab/user-home" XDG_CONFIG_HOME="$lab/config" \
    XDG_DATA_HOME="$lab/data" XDG_CACHE_HOME="$lab/cache" TMPDIR="$lab/tmp" \
    OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_DEFAULT_PLUGINS=1 \
    OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_PURE=1 OPENCODE_CONFIG_CONTENT="$config" \
    FM_HOME="$lab/fmhome" "$@"
}

config=$(jq -nc --arg provider "$provider" \
  '{enabled_providers:[$provider],provider:{($provider):{options:{apiKey:"fixture-not-a-secret"}}}}')
cd "$lab/project"
version=$(isolated "$opencode_bin" --version)
[ "$version" = 1.18.32 ] || fail "this proof requires OpenCode 1.18.32; found $version (use the worktree-local pinned executable on PATH)"
printf 'OpenCode %s\n' "$version"
isolated "$opencode_bin" models "$provider" --refresh > "$lab/catalog.txt"
grep -Fxq "$model" "$lab/catalog.txt" || fail "OpenCode catalog does not contain $model; refusing substitution"
isolated curl -q --fail --silent --show-error --noproxy '*' --max-time 10 "$endpoint/models" \
  > "$lab/endpoint-models.json"
jq -e '.data | any(.id == "glm-5.3")' "$lab/endpoint-models.json" >/dev/null ||
  fail "the credential-free endpoint must advertise glm-5.3"
config=$(jq -nc --arg provider "$provider" --arg model "$model" --arg endpoint "$endpoint" \
  '{model:$model,small_model:$model,enabled_providers:[$provider],share:"disabled",
    provider:{($provider):{npm:"@ai-sdk/openai-compatible",whitelist:["glm-5.3"],
      options:{baseURL:$endpoint,apiKey:"fixture-not-a-secret"}}},
    permission:{"*":"deny",bash:"allow",external_directory:"allow"}}')
isolated "$ROOT/bin/fm-sandbox.sh" probe

run_case() {
  local label=$1 command=$2 expected_exit=$3 transcript
  transcript="$lab/$label.jsonl"
  isolated "$ROOT/bin/fm-sandbox.sh" exec -- env NO_PROXY= no_proxy= OPENCODE_DISABLE_MODELS_FETCH=1 "$opencode_bin" run --pure \
    --format json --model "$model" \
    "Use the bash tool exactly once to execute this exact command: $command . Do not use any other tool or change the command. Then report the result briefly." \
    > "$transcript"
  jq -se --arg command "$command" --arg expected "$expected_exit" '
    all(.[]; .type != "error") and
    any(.[]; .type == "tool_use" and .part.tool == "bash" and
      .part.state.input.command == $command and .part.state.status == "completed" and
      (.part.state.metadata.exit | type == "number") and
      (if $expected == "0" then .part.state.metadata.exit == 0
       elif $expected == "1" then .part.state.metadata.exit != 0
       else .part.state.metadata.exit != 0 or .part.state.output == "" end))
  ' "$transcript" >/dev/null || fail "$label: OpenCode must execute the command with the expected tool exit status"
  if grep -Fq "$secret_value" "$transcript"; then
    fail "$label: denied fixture secret leaked into the OpenCode transcript"
  fi
}

run_case allowed "printf allowed > '$lab/project/allowed.txt'" 0
assert_equals allowed "$(cat "$lab/project/allowed.txt")" "the worker must write inside its allowlist"
run_case denied-write "printf denied > '$lab/denied/denied.txt'" 1
assert_absent "$lab/denied/denied.txt" "the worker must not create a denied file"
run_case denied-read "cat '$secret'" hidden
assert_equals "$secret_value" "$(cat "$secret")" "the synthetic secret must remain unchanged"
pass "real OpenCode $model worker: allowed write, denied write, denied read"
