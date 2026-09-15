#!/usr/bin/env bash
# Token-free native Codex account/catalog/quota guard; no task or backend launch.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_DISPATCH_POOL_LIVE codex node
node - "$ROOT" <<'JS'
const {codexProbe,codexEvidence}=require(process.argv[2]+'/bin/fm-dispatch-pool.js');
(async()=>{
 const raw=await codexProbe();
 const candidate={id:'astra-low',model:'gpt-6-astra',effort:'low'};
 const e=codexEvidence(candidate,raw);
 if(!e.viable && e.reason!=='quota_exhausted')throw new Error(e.reason);
 console.log(`ok - ${raw.version}: native Astra low auth/catalog/quota ${e.viable?'viable':'exhausted (correctly rejected)'}`);
 console.log('unsupported - Claude native, Muse, Gemini and Luna carrier proof are not claimed by this guard');
})().catch(e=>{console.error('not ok - installed Codex native pool guard: '+e.message);process.exitCode=1;});
JS

# One bounded real Codex turn proves the actual vendor notify payload, only
# when explicitly requested. It neither creates nor drives a runtime backend.
if [ "${FM_POOL_NOTIFY_LIVE:-0}" = 1 ]; then
  fm_live_gate opt-in FM_POOL_NOTIFY_LIVE codex node jq
  TMP_ROOT=$(fm_test_tmproot fm-pool-notify-live)
  mkdir -p "$TMP_ROOT/state" "$TMP_ROOT/worktree"
  TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
  cat > "$TMP_ROOT/config.json" <<'JSON'
{"schemaVersion":1,"defaults":{},"pools":{"live":[{"id":"astra","harness":"codex","model":"gpt-6-astra","effort":"low","provider":"openai","authCarrier":"codex-chatgpt","carrier":"codex-native","weight":1}]}}
JSON
  route=$("$ROOT/bin/fm-dispatch-pool.sh" reserve "$TMP_ROOT/config.json" "$TMP_ROOT/state" live-task live)
  receipt=$(printf '%s' "$route" | jq -r .id)
  printf 'route_pool=live\nroute_candidate=astra\nroute_generation=1\nroute_receipt=%s\nspawn_gen=live-generation\nworktree=%s\n' "$receipt" "$TMP_ROOT/worktree" > "$TMP_ROOT/state/live-task.meta"
  notify=$(jq -cn --arg script "$ROOT/bin/fm-dispatch-pool-notify.sh" --arg config "$TMP_ROOT/config.json" --arg state "$TMP_ROOT/state" --arg receipt "$receipt" '["bash",$script,$config,$state,"live-task",$receipt,"live-generation"]')
  codex exec --skip-git-repo-check -C "$TMP_ROOT/worktree" --model gpt-6-astra \
    -c 'model_reasoning_effort="low"' -c "notify=$notify" \
    'Reply with OK only. Do not use any tools.' > "$TMP_ROOT/turn.log" 2>&1 \
    || fail 'Codex live notify turn failed; no terminal-quota claim is inferred'
  [ -f "$TMP_ROOT/state/live-task.turn-ended" ] || fail 'Codex live notify did not deliver a verified generation-bound marker'
  jq -e '.receipts[0].nativeThread.source=="codex-notify"' "$TMP_ROOT/state/dispatch-pools.json" >/dev/null \
    || fail 'Codex live notification did not bind its native thread'
  pass 'native Codex notify producer bound task/generation/thread and preserved turn-end signal'
fi
