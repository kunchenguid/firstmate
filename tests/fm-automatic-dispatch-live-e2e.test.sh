#!/usr/bin/env bash
# Read-only live catalog/quota and simulation-selector verification.
set -u

if [ "${FM_AUTOMATIC_DISPATCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_AUTOMATIC_DISPATCH_LIVE_E2E=1 to run read-only automatic-dispatch verification"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in jq claude codex pi; do
  command -v "$tool" >/dev/null 2>&1 || fail "live automatic dispatch: missing runtime $tool"
done

LAB=$(fm_test_tmproot fm-automatic-dispatch-live)
HOME_DIR="$LAB/home"
REQUEST="$LAB/request.json"
CANDIDATES="$LAB/candidates.json"
DECISION="$LAB/decision.json"
PI_CATALOG="$LAB/pi-models.txt"
QUOTA_REPORT="$LAB/quota.txt"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"

capture_version() {
  local destination=$1
  shift
  "$@" >"$destination" 2>&1 || return 1
  sed -n '1p' "$destination"
}

safe_version() {
  local value=$1
  [ -n "$value" ] || fail "live automatic dispatch: empty version output"
  printf '%s\n' "$value" | grep -Eiq 'token|secret|password|cookie|authorization|api[-_]?key' \
    && fail "live automatic dispatch: unsafe version output"
  printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9 ._()+/@:-]*$' \
    || fail "live automatic dispatch: unsafe version output"
}

cp "$ROOT/docs/examples/crew-dispatch.json" "$HOME_DIR/config/crew-dispatch.json"
jq '.routing.mode="simulate"' "$HOME_DIR/config/crew-dispatch.json" >"$LAB/policy.json"
mv "$LAB/policy.json" "$HOME_DIR/config/crew-dispatch.json"

if ! claude_version=$(capture_version "$LAB/claude.version" claude --version); then
  fail "live automatic dispatch: Claude version probe failed"
fi
if ! codex_version=$(capture_version "$LAB/codex.version" codex --version); then
  fail "live automatic dispatch: Codex version probe failed"
fi
if ! pi_version=$(capture_version "$LAB/pi.version" pi --version); then
  fail "live automatic dispatch: Pi version probe failed"
fi
safe_version "$claude_version"
safe_version "$codex_version"
safe_version "$pi_version"
printf 'runtime claude version=%s\n' "$claude_version"
printf 'runtime codex version=%s\n' "$codex_version"
printf 'runtime pi version=%s\n' "$pi_version"
command -v quota-axi >/dev/null 2>&1 \
  || fail "live automatic dispatch: missing runtime quota-axi"
if ! quota_version=$(capture_version "$LAB/quota-axi.version" quota-axi --version); then
  fail "live automatic dispatch: quota-axi version probe failed"
fi
safe_version "$quota_version"

pi --list-models >"$PI_CATALOG" 2>/dev/null \
  || fail "live automatic dispatch: Pi catalog probe failed"
while IFS=$'\t' read -r id harness model; do
  case "$harness" in
    pi|pi-signed)
      provider=${model%%/*}
      model_id=${model#*/}
      awk -v provider="$provider" -v model="$model_id" 'NR > 1 && $1 == provider && $2 == model {found=1} END {exit !found}' "$PI_CATALOG" \
        || fail "live automatic dispatch: configured Pi model unavailable: $id"
      ;;
  esac
done < <(jq -r '.profiles|to_entries[]|[.key,.value.harness,(.value.model//"")]|@tsv' "$HOME_DIR/config/crew-dispatch.json")

claude --help >"$LAB/claude-help.txt" 2>&1 \
  || fail "live automatic dispatch: Claude catalog probe failed"
grep -Fq "sonnet" "$LAB/claude-help.txt" \
  || fail "live automatic dispatch: configured Claude alias unavailable: sonnet"
codex_cache=${CODEX_HOME:-$HOME/.codex}/models_cache.json
[ -r "$codex_cache" ] || fail "live automatic dispatch: Codex model catalog cache unavailable"
for model in gpt-5.6-sol gpt-5.6-luna; do
  jq -e --arg model "$model" '[.models[]? | .slug // .id // empty] | index($model) != null' "$codex_cache" >/dev/null \
    || fail "live automatic dispatch: configured Codex model unavailable: $model"
done

quota-axi --json >"$QUOTA_REPORT" 2>/dev/null \
  || fail "live automatic dispatch: quota-axi read-only snapshot failed"
jq -e 'type == "object"' "$QUOTA_REPORT" >/dev/null \
  || fail "live automatic dispatch: quota-axi returned invalid JSON"

jq -n '{taskId:"live-readonly",taskClass:"standard",workType:"verification",risk:"low",independent:false,requestedWorkers:1,requiredReasoningClass:"strong",estimatedSeconds:300}' >"$REQUEST"
jq '[.profiles|to_entries[]|.key as $id|.value|{
  profile:$id,harness:.harness,model:(.model//"default"),provider:.provider,lane:.lane,
  account:(.account//"none"),fitTier:3,reasoningClass:.reasoningClass,
  catalogSupported:true,authState:null,spendPriority:null,runwaySeconds:null,
  activeLane:0,historySuccesses:0,historyAttempts:0,costTier:null
}]' "$HOME_DIR/config/crew-dispatch.json" >"$CANDIDATES"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  "$ROOT/bin/fm-route.sh" select --request "$REQUEST" --candidates "$CANDIDATES" --now 1000 >"$DECISION" \
  || fail "live automatic dispatch: simulation selection failed"
jq -e '.action == "selected" or .action == "escalate"' "$DECISION" >/dev/null \
  || fail "live automatic dispatch: unexpected route decision"

printf 'catalog claude alias-sonnet=available\n'
printf 'catalog codex gpt-5.6-sol,gpt-5.6-luna=available\n'
printf 'catalog pi configured-aliases=available\n'
printf 'runtime quota-axi version=%s snapshot=read-only-valid\n' "$quota_version"
printf 'route action=%s reason=%s selected=%s\n' \
  "$(jq -r .action "$DECISION")" "$(jq -r .reason "$DECISION")" "$(jq -r '.selected.profile // "none"' "$DECISION")"
pass "live automatic dispatch verified catalogs, quota, and simulation selection without launch"
