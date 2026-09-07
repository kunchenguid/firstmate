#!/usr/bin/env bash
# Opt-in development evaluation for the harness-adapters routing instructions.
# It sends the directly loaded router and a complete scenario set
# to a local Ollama model, then compares the generated routing plan as normalized
# JSON.
# It makes no external-provider or remote CI call and does not claim that an absent or
# unconfigured native harness loaded the references itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_HARNESS_ADAPTER_INSTRUCTION_EVAL curl jq

ROUTER="$ROOT/.agents/skills/harness-adapters/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-harness-adapter-instructions)
EXPECTED_JSON="$TMP_ROOT/expected.json"
PROMPT_FILE="$TMP_ROOT/prompt.txt"
RESPONSE_JSON="$TMP_ROOT/response.json"

curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags > "$TMP_ROOT/tags.json" \
  || fail "local Ollama is unavailable at 127.0.0.1:11434; no remote provider fallback is allowed"

MODEL=${FM_HARNESS_ADAPTER_LOCAL_MODEL:-}
[ -n "$MODEL" ] || fail "FM_HARNESS_ADAPTER_LOCAL_MODEL must name an explicit local evaluator"
jq -e --arg model "$MODEL" '.models | any(.name == $model)' "$TMP_ROOT/tags.json" >/dev/null \
  || fail "requested local Ollama model is unavailable: $MODEL"

cat > "$EXPECTED_JSON" <<'JSON'
{
  "cases": [
    {"id":"start.default","common":["references/common/dispatch.md","references/common/model-and-effort.md"],"harness":"references/harness/claude.md"},
    {"id":"start.trust-dialog","common":["references/common/control-and-recovery.md"],"harness":"references/harness/codex.md"},
    {"id":"trust.default","common":["references/common/control-and-recovery.md"],"harness":"references/harness/opencode.md"},
    {"id":"skill.default","common":["references/common/control-and-recovery.md"],"harness":"references/harness/pi.md"},
    {"id":"interrupt.default","common":["references/common/control-and-recovery.md"],"harness":"references/harness/pi.md"},
    {"id":"exit.default","common":["references/common/control-and-recovery.md"],"harness":"references/harness/grok.md"},
    {"id":"resume.default","common":["references/common/control-and-recovery.md"],"harness":"references/harness/kimi.md"},
    {"id":"recovery.default","common":["references/common/control-and-recovery.md"],"harness":"references/harness/cursor.md"},
    {"id":"recovery.replacement-profile","common":["references/common/control-and-recovery.md","references/common/dispatch.md","references/common/model-and-effort.md"],"harness":"references/harness/muse.md"},
    {"id":"recovery.secondmate","common":["references/common/control-and-recovery.md","references/common/primary-hooks.md"],"harness":"references/harness/claude.md"},
    {"id":"recovery.replacement-secondmate","common":["references/common/control-and-recovery.md","references/common/dispatch.md","references/common/model-and-effort.md","references/common/primary-hooks.md"],"harness":"references/harness/codex.md"},
    {"id":"primary.default","common":["references/common/primary-hooks.md"],"harness":"references/harness/opencode.md"},
    {"id":"model-effort.default","common":["references/common/model-and-effort.md"],"harness":"references/harness/pi.md"},
    {"id":"model-effort.configured-profile","common":["references/common/model-and-effort.md","references/common/dispatch.md"],"harness":"references/harness/pi.md"},
    {"id":"verify.default","common":["references/common/dispatch.md","references/common/control-and-recovery.md","references/common/primary-hooks.md","references/common/model-and-effort.md"],"harness":"references/harness/grok.md"}
  ]
}
JSON

{
  printf '%s\n' 'Act only as an evaluator of the directly loaded harness-adapters router below.'
  printf '%s\n' 'For each requested operation.scenario, copy the common reference list in router order and append the requested harness reference in the harness field.'
  printf '%s\n' 'Copy harness paths literally from the router map; never construct a filename from an identity, including when two identities share one path.'
  printf '%s\n' 'The requests, in output order, are:'
  printf '%s\n' \
    'start.default claude' \
    'start.trust-dialog codex' \
    'trust.default opencode' \
    'skill.default pi' \
    'interrupt.default pi-signed' \
    'exit.default grok' \
    'resume.default kimi' \
    'recovery.default cursor' \
    'recovery.replacement-profile muse' \
    'recovery.secondmate claude' \
    'recovery.replacement-secondmate codex' \
    'primary.default opencode' \
    'model-effort.default pi' \
    'model-effort.configured-profile pi-signed' \
    'verify.default grok'
  printf '%s\n' 'Return only one JSON object with a cases array; each item must have id, common, and harness fields.'
  printf '%s\n' 'ROUTER START'
  cat "$ROUTER"
  printf '%s\n' 'ROUTER END'
} > "$PROMPT_FILE"

PAYLOAD=$(jq -n \
  --arg model "$MODEL" \
  --rawfile prompt "$PROMPT_FILE" \
  '{model:$model,prompt:$prompt,stream:false,format:"json",options:{temperature:0,num_predict:4096}}')
curl -fsS --max-time "${FM_HARNESS_ADAPTER_EVAL_TIMEOUT_SECONDS:-120}" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" http://127.0.0.1:11434/api/generate \
  | jq -er '.response | fromjson' > "$RESPONSE_JSON" \
  || fail "local model $MODEL did not return parseable routing JSON"
jq '(.cases[]?.id) |= split(" ")[0]' "$RESPONSE_JSON" > "$TMP_ROOT/normalized-response.json" \
  || fail "local model $MODEL returned an invalid routing case shape"

if ! diff -u \
  <(jq -S . "$EXPECTED_JSON") \
  <(jq -S . "$TMP_ROOT/normalized-response.json") > "$TMP_ROOT/diff"; then
  fail "local model $MODEL did not follow the routing instructions: $(tr '\n' ' ' < "$TMP_ROOT/diff")"
fi
pass "local model $MODEL selected every operation scenario and all nine harness identities"

CHECKED=0
MISSING=
. "$ROOT/bin/fm-cursor-lib.sh"
resolve_native_binary() {
  local harness=$1 candidate
  if [ "$harness" = cursor ]; then
    fm_cursor_resolve_binary 2>/dev/null
    return
  fi
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}

for harness in claude codex opencode pi pi-signed grok kimi cursor muse; do
  if binary=$(resolve_native_binary "$harness"); then
    version=$("$binary" --version 2>/dev/null | head -1 | tr -d '\r') || version=unknown
    printf '# native loader not claimed: %s %s is installed, but this harness-neutral evaluation does not exercise its provider transport\n' "$harness" "$version"
    CHECKED=$((CHECKED + 1))
  else
    MISSING="$MISSING $harness"
    printf '# unverified native loader: %s is not installed on this machine\n' "$harness"
  fi
done
printf '# installed native tools recorded without overstating loader coverage: %s\n' "$CHECKED"
[ -z "$MISSING" ] || printf '# unavailable native tools:%s\n' "$MISSING"
