#!/usr/bin/env bash
# Native pool contract through the executable API and a protocol-only Codex
# fixture. No harness or backend is started; live claims have a separate guard.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-pool)
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/state" "$TMP_ROOT/auth"
export CODEX_HOME="$TMP_ROOT/auth"
fm_test_pool_codex "$TMP_ROOT/bin"
export PATH="$TMP_ROOT/bin:$PATH"
fm_test_pool_config "$TMP_ROOT/config.json"
pool() { "$ROOT/bin/fm-dispatch-pool.sh" "$1" "$TMP_ROOT/config.json" "$TMP_ROOT/state" "${@:2}"; }
refused() { if "$@" >"$TMP_ROOT/refusal" 2>&1; then fail 'expected refusal'; fi; }
pool validate >/dev/null
[ "$(pool default secondmate | jq -r .pool)" = test ] || fail 'secondmate default'
[ "$(pool default ship | jq -r .pool)" = test ] || fail 'crewmate default'
seq=
for n in 1 2 3 4 5 6; do seq="$seq$(pool reserve "task$n" test | jq -r .candidate.id)"; done
[ "$seq" = abaaba ] || fail "weighted restart sequence: $seq"
pass 'weighted sequence persists across six separate processes'
first=$(pool reserve replay test)
id=$(printf '%s' "$first" | jq -r .id)
before=$(pool inspect | jq '.receipts|length')
[ "$(pool reserve replay test | jq -r .id)" = "$id" ] || fail 'replayed admission changed receipt'
[ "$(pool inspect | jq '.receipts|length')" = "$before" ] || fail 'replay advanced state'
pool finish replay "$id" failed >/dev/null
[ "$(pool reserve replay test | jq -r .id)" = "$id" ] || fail 'launch failure redrew candidate'
pass 'replay and failed launch retain reservation'
POOL_NO_AUTH=1 refused pool reserve missing-auth test
POOL_STALE=1 refused pool reserve stale-quota test
POOL_USED=100 refused pool reserve exhausted test
[ "$(pool inspect | jq '.receipts|length')" = "$before" ] || fail 'rejections consumed a slot'
pass 'unknown auth, stale quota and exhausted quota fail closed'
# A bad candidate is excluded without blocking an independently viable candidate.
jq '.pools.test[0].authCarrier="wrong-account"' "$TMP_ROOT/config.json" > "$TMP_ROOT/new.json"
mv "$TMP_ROOT/new.json" "$TMP_ROOT/config.json"
[ "$(pool reserve excluded test | jq -r .candidate.id)" = b ] || fail 'excluded candidate selected'
jq '.pools.test[0].weight=0' "$TMP_ROOT/config.json" > "$TMP_ROOT/bad.json"
refused "$ROOT/bin/fm-dispatch-pool.sh" validate "$TMP_ROOT/bad.json" "$TMP_ROOT/state"
jq '.pools.test[0].weight="1"' "$TMP_ROOT/config.json" > "$TMP_ROOT/bad.json"
refused "$ROOT/bin/fm-dispatch-pool.sh" validate "$TMP_ROOT/bad.json" "$TMP_ROOT/state"
pass 'invalid weights and unusable carrier identity rejected'
# Concurrent reservations serialize through the existing Firstmate lock.
for n in 1 2 3 4; do pool reserve "concurrent$n" test > "$TMP_ROOT/c$n" & done
wait
[ "$(pool inspect | jq '[.receipts[]|select(.task|startswith("concurrent"))]|length')" = 4 ] || fail 'concurrent writes lost'
for n in 1 2 3; do pool reserve same-task test > "$TMP_ROOT/s$n" & done
wait
[ "$(pool inspect | jq '[.receipts[]|select(.task=="same-task")]|length')" = 1 ] || fail 'concurrent replay consumed extra slots'
pass 'concurrent independent and replayed admissions serialize'
r=$(pool reserve pinned test)
rid=$(printf '%s' "$r" | jq -r .id)
cat > "$TMP_ROOT/state/pinned.meta" <<META
route_pool=test
route_candidate=b
route_generation=1
route_receipt=$rid
spawn_gen=fixture-generation
native_thread_id=fixture-thread
worktree=/retained/worktree
META
refused pool reserve pinned test fresh
[ "$(pool reserve pinned test pinned | jq -r .candidate.id)" = b ] || fail 'pinned relaunch changed candidate'
refused pool reserve pinned test exhausted "$TMP_ROOT/no-event.json"
pass 'existing task remains pinned; unknown interruption cannot fail over'
# Re-enable both candidates and exercise a bound terminal transition on a new task.
jq '.pools.test[0].authCarrier="codex-chatgpt"' "$TMP_ROOT/config.json" > "$TMP_ROOT/new.json"
mv "$TMP_ROOT/new.json" "$TMP_ROOT/config.json"
r=$(pool reserve terminal test)
printf '%s' "$r" > "$TMP_ROOT/route.json"
node - "$TMP_ROOT" <<'JS'
const fs=require('fs'),root=process.argv[2],r=JSON.parse(fs.readFileSync(root+'/route.json'));
fs.writeFileSync(root+'/state/terminal.meta',`route_pool=test\nroute_candidate=${r.candidate.id}\nroute_generation=1\nroute_receipt=${r.id}\nspawn_gen=fixture-generation\nnative_thread_id=fixture-thread\nworktree=/retained/worktree\n`);
fs.writeFileSync(root+'/state/exhaustion.json',JSON.stringify({schemaVersion:1,task:'terminal',generation:1,candidate:r.candidate.id,receipt:r.id,provider:r.candidate.provider,authIdentity:r.evidence.identity,terminal:true,kind:'quota_exhausted',observedAt:Date.now(),spawnGeneration:'fixture-generation',nativeEvent:{method:'error',params:{threadId:'fixture-thread',willRetry:false,error:{codexErrorInfo:'usageLimitExceeded'}}}}));
JS
meta_before=$(shasum -a 256 "$TMP_ROOT/state/terminal.meta")
old=$(printf '%s' "$r" | jq -r .candidate.id)
new=$(pool reserve terminal test exhausted "$TMP_ROOT/state/exhaustion.json" | jq -r .candidate.id)
[ "$old" != "$new" ] || fail 'terminal failover reused exhausted candidate'
[ "$meta_before" = "$(shasum -a 256 "$TMP_ROOT/state/terminal.meta")" ] || fail 'selector modified task state'
[ "$(pool inspect | jq '[.events[]|select(.type=="terminal_quota_exhausted")]|length')" = 1 ] || fail 'missing terminal receipt'
pass 'bound terminal exhaustion selects next viable candidate and preserves task metadata'

# Malformed state must not be silently reset to a different rotation.
cp "$TMP_ROOT/state/dispatch-pools.json" "$TMP_ROOT/good-state.json"
jq '.pools |= with_entries(.value.a="bad")' "$TMP_ROOT/good-state.json" > "$TMP_ROOT/state/dispatch-pools.json"
refused pool reserve corrupt test
mv "$TMP_ROOT/good-state.json" "$TMP_ROOT/state/dispatch-pools.json"
# No configuration at all is the legacy path; it does not create routing state.
[ "$("$ROOT/bin/fm-dispatch-pool.sh" default "$TMP_ROOT/absent.json" "$TMP_ROOT/state" ship | jq -r .pool)" = '' ] || fail 'legacy default changed'
# Wrong native thread and stale terminal event cannot migrate an existing task.
jq '.nativeEvent.params.threadId="another-task"' "$TMP_ROOT/state/exhaustion.json" > "$TMP_ROOT/state/wrong-thread.json"
refused pool reserve terminal test exhausted "$TMP_ROOT/state/wrong-thread.json"
jq '.observedAt=1' "$TMP_ROOT/state/exhaustion.json" > "$TMP_ROOT/state/stale-event.json"
refused pool reserve terminal test exhausted "$TMP_ROOT/state/stale-event.json"
pass 'malformed persisted scores, unrelated terminal event and stale event refuse; legacy remains opt-in'

mkdir -p "$TMP_ROOT/worktree"
# The actual callback executable consumes the native notification envelope,
# binds the generation, and preserves Firstmate's existing turn-end signal.
r=$(pool reserve notify-task test)
rid=$(printf '%s' "$r" | jq -r .id)
candidate=$(printf '%s' "$r" | jq -r .candidate.id)
printf 'route_pool=test\nroute_candidate=%s\nroute_generation=1\nroute_receipt=%s\nspawn_gen=notify-generation\nworktree=%s\n' "$candidate" "$rid" "$TMP_ROOT/worktree" > "$TMP_ROOT/state/notify-task.meta"
notice=$(jq -cn --arg cwd "$TMP_ROOT/worktree" '{type:"agent-turn-complete","thread-id":"native-thread","turn-id":"native-turn",cwd:$cwd,"last-assistant-message":"PRIVATE MUST NOT BE LOGGED"}')
"$ROOT/bin/fm-dispatch-pool-notify.sh" "$TMP_ROOT/config.json" "$TMP_ROOT/state" notify-task "$rid" notify-generation "$notice"
[ -f "$TMP_ROOT/state/notify-task.turn-ended" ] || fail 'notification marker lost'
[ "$(pool inspect | jq -r '.receipts[]|select(.task=="notify-task")|.nativeThread.id')" = native-thread ] || fail 'native notification binding missing'
if pool inspect | grep -q 'PRIVATE MUST NOT BE LOGGED'; then fail 'notification body leaked'; fi
refused "$ROOT/bin/fm-dispatch-pool-notify.sh" "$TMP_ROOT/config.json" "$TMP_ROOT/state" notify-task "$rid" old-generation "$notice"
pass 'native notification adapter binds exact generation and preserves signal without storing message bodies'
