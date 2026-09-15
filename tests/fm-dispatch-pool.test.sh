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
jq '.pools.test[0].model="opencode-go-responses/muse-spark-1.3-contributor"' "$TMP_ROOT/config.json" > "$TMP_ROOT/slashed.json"
"$ROOT/bin/fm-dispatch-pool.sh" validate "$TMP_ROOT/slashed.json" "$TMP_ROOT/state" >/dev/null || fail 'provider/id model refused'
jq '.pools.test[0].model="../escape"' "$TMP_ROOT/config.json" > "$TMP_ROOT/bad.json"
refused "$ROOT/bin/fm-dispatch-pool.sh" validate "$TMP_ROOT/bad.json" "$TMP_ROOT/state"
pass 'provider/id model accepted; traversal refused'
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

# Wrapper carriers admit PATH executables through their own --list-models
# discovery surface; pinned wrappers take model default and nothing positional.
mkdir -p "$TMP_ROOT/wbin"
cat > "$TMP_ROOT/wbin/wrap-multi" <<'SH'
#!/usr/bin/env sh
if [ "${1:-}" = --list-models ]; then printf '%s\n' 'alpha Alpha model' 'beta Beta model'; exit 0; fi
exit 0
SH
cat > "$TMP_ROOT/wbin/wrap-pinned" <<'SH'
#!/usr/bin/env sh
echo "error: unknown option '--list-models'" >&2; exit 1
SH
cat > "$TMP_ROOT/wbin/wrap-single" <<'SH'
#!/usr/bin/env sh
if [ "${1:-}" = --list-models ]; then printf '%s\n' 'solo Solo model'; exit 0; fi
exit 0
SH
chmod +x "$TMP_ROOT/wbin"/wrap-*
cat > "$TMP_ROOT/wrap.json" <<'JSON'
{"schemaVersion":1,"defaults":{},"pools":{"wrap":[
{"id":"m","harness":"wrap-multi","model":"beta","effort":"high","provider":"t","authCarrier":"t","carrier":"wrapper","weight":1},
{"id":"p","harness":"wrap-pinned","model":"default","effort":"high","provider":"t","authCarrier":"t","carrier":"wrapper","weight":1},
{"id":"s","harness":"wrap-single","model":"default","effort":"high","provider":"t","authCarrier":"t","carrier":"wrapper","weight":1},
{"id":"gone","harness":"wrap-missing","model":"default","effort":"high","provider":"t","authCarrier":"t","carrier":"wrapper","weight":1}
]}}
JSON
wpool() { PATH="$TMP_ROOT/wbin:$PATH" "$ROOT/bin/fm-dispatch-pool.sh" "$1" "$TMP_ROOT/wrap.json" "$TMP_ROOT/state" "${@:2}"; }
wpool validate >/dev/null
probe_out=$(wpool probe inspection wrap)
[ "$(printf '%s' "$probe_out" | jq -r '.candidates[]|select(.candidate=="m")|.viable')" = true ] || fail 'listed wrapper alias not viable'
[ "$(printf '%s' "$probe_out" | jq -r '.candidates[]|select(.candidate=="p")|.viable')" = true ] || fail 'pinned wrapper not viable'
[ "$(printf '%s' "$probe_out" | jq -r '.candidates[]|select(.candidate=="s")|.viable')" = true ] || fail 'single-row wrapper default not viable'
[ "$(printf '%s' "$probe_out" | jq -r '.candidates[]|select(.candidate=="gone")|.reason')" = wrapper_not_installed ] || fail 'missing wrapper not refused'
[ "$(wpool reserve wtask wrap | jq -r .candidate.id)" = m ] || fail 'wrapper reserve did not select listed candidate'
wr=$(wpool reserve wverify wrap)
wpool verify wverify "$(printf '%s' "$wr" | jq -r .id)" >/dev/null || fail 'wrapper receipt revalidation failed'
wpool finish wverify "$(printf '%s' "$wr" | jq -r .id)" launched >/dev/null
pass 'wrapper carriers admit listed, pinned and single-row models and refuse missing binaries'
printf '%s' '{"schemaVersion":1,"defaults":{},"pools":{"w":[ {"id":"x","harness":"wrap-multi","model":"gamma","effort":"high","provider":"t","authCarrier":"t","carrier":"wrapper","weight":1} ]}}' > "$TMP_ROOT/wbad.json"
cp "$TMP_ROOT/wbad.json" "$TMP_ROOT/wbad-one.json"
cat > "$TMP_ROOT/wbad-run.sh" <<SH
#!/usr/bin/env sh
PATH="$TMP_ROOT/wbin:\$PATH" "$ROOT/bin/fm-dispatch-pool.sh" reserve "$TMP_ROOT/wbad-one.json" "$TMP_ROOT/state" badtask w
SH
chmod +x "$TMP_ROOT/wbad-run.sh"
refused "$TMP_ROOT/wbad-run.sh"
printf '%s' '{"schemaVersion":1,"defaults":{},"pools":{"w":[ {"id":"x","harness":"wrap-single","model":"solo","effort":"high","provider":"t","authCarrier":"t","carrier":"wrapper","weight":1} ]}}' > "$TMP_ROOT/wbad-one.json"
refused "$TMP_ROOT/wbad-run.sh"
printf '%s' '{"schemaVersion":1,"defaults":{},"pools":{"w":[ {"id":"x","harness":"wrap-pinned","model":"solo","effort":"high","provider":"t","authCarrier":"t","carrier":"wrapper","weight":1} ]}}' > "$TMP_ROOT/wbad-one.json"
refused "$TMP_ROOT/wbad-run.sh"
pass 'unlisted alias, alias on pinned wrapper and alias on single-row wrapper refuse'
