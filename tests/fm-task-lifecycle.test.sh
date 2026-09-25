#!/usr/bin/env bash
# Exercise goal CAS, explicit stop/reopen, evidence, action replay and budgets.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-lifecycle)
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/data/a" "$FM_HOME/data/b" "$FM_HOME/state"
printf 'outcome: deliver the full result\n' > "$FM_HOME/data/a/brief.md"
cp "$FM_HOME/data/a/brief.md" "$FM_HOME/data/b/brief.md"
printf 'spawn_gen=s1\nkind=scout\n' > "$FM_HOME/state/a.meta"
printf 'spawn_gen=s2\nkind=scout\n' > "$FM_HOME/state/b.meta"
CLI="$ROOT/bin/fm-task-state.sh"
LIB="$ROOT/bin/fm-task-lifecycle.py"
python3 "$LIB" init a >/dev/null
python3 "$LIB" init b >/dev/null
"$CLI" lifecycle a > "$TMP_ROOT/input.json"
chmod 600 "$TMP_ROOT/input.json"
python3 - "$TMP_ROOT/input.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p));d['assessment']['outcome']='Partial milestone'
d['assessment']['remaining_gap']='Full CSV still absent'
json.dump(d,open(p,'w'))
PY
"$CLI" reconcile a --expected-revision 1 --record "$TMP_ROOT/input.json" >/dev/null
"$CLI" lifecycle a | jq -e '.revision==2 and .disposition=="open" and .assessment.remaining_gap=="Full CSV still absent"' >/dev/null
"$CLI" lifecycle b | jq -e '.revision==1 and .task_id=="b"' >/dev/null
if "$CLI" reconcile a --expected-revision 1 --record "$TMP_ROOT/input.json" >/dev/null 2>&1; then fail 'stale CAS accepted'; fi
pass 'new topic preserves prior unfinished goal; stale reconciliation refuses'

"$CLI" lifecycle a > "$TMP_ROOT/input.json"
python3 - "$TMP_ROOT/input.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));a=d['assessment'];d['next_action']={
'id':'a.g1.a1','kind':'steer','phase':'prepared','expected_execution_generation':'s1',
'payload_ref':a['evidence'][0]['ref'],'payload_sha256':a['evidence'][0]['sha256'],
'receipt_ref':None,'attempts':0,'attempt_limit':2,'recheck_at':'2000-01-01T00:00:00Z','deadline':'2099-01-01T00:00:00Z'}
d['next_action_seq']=2;json.dump(d,open(p,'w'))
PY
"$CLI" reconcile a --expected-revision 2 --record "$TMP_ROOT/input.json" >/dev/null
"$CLI" action a --action-id a.g1.a1 --phase attempted >/dev/null
"$CLI" action a --action-id a.g1.a1 --phase attempted >/dev/null
"$CLI" lifecycle a | jq -e '.next_action.attempts==1 and .revision==4' >/dev/null
"$CLI" lifecycle a > "$TMP_ROOT/input.json"
jq '.next_action.payload_sha256="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' "$TMP_ROOT/input.json" > "$TMP_ROOT/bad.json"
chmod 600 "$TMP_ROOT/bad.json"
if "$CLI" reconcile a --expected-revision 4 --record "$TMP_ROOT/bad.json" >/dev/null 2>&1; then fail 'unconfirmed action overwritten'; fi
pass 'attempt replay is idempotent and payload mutation is rejected'

"$CLI" lifecycle a | jq '.disposition="archived"' > "$TMP_ROOT/input.json"
if "$CLI" reconcile a --expected-revision 4 --record "$TMP_ROOT/input.json" >/dev/null 2>&1; then fail 'archive accepted without stop authority'; fi
printf 'Explicitly stop this task\n' > "$FM_HOME/data/a/stop.txt"
"$CLI" lifecycle a | jq --arg ref "$FM_HOME/data/a/stop.txt" '.disposition="archived" | .assessment.authority_ref=$ref' > "$TMP_ROOT/input.json"
"$CLI" reconcile a --expected-revision 4 --record "$TMP_ROOT/input.json" >/dev/null
test "$(python3 "$LIB" mode a)" = archived
if "$CLI" action a --action-id a.g1.a1 --phase prepared >/dev/null 2>&1; then fail 'archived action restarted'; fi
"$CLI" lifecycle a | jq '.disposition="open"' > "$TMP_ROOT/input.json"
if "$CLI" reconcile a --expected-revision 5 --record "$TMP_ROOT/input.json" >/dev/null 2>&1; then fail 'archive reopened without authority'; fi
pass 'explicit archive retains pending effects without authorizing recovery'

printf 'spawn_gen=s3\n' > "$FM_HOME/state/a.meta"
if python3 "$LIB" mode a > "$TMP_ROOT/mode" 2>/dev/null; then fail 'old disposition crossed generation'; fi
test "$(cat "$TMP_ROOT/mode")" = unknown
printf 'spawn_gen=s1\n' > "$FM_HOME/state/a.meta"
mv "$FM_HOME/data/a/lifecycle.json" "$TMP_ROOT/preserved.json"
ln -s "$TMP_ROOT/preserved.json" "$FM_HOME/data/a/lifecycle.json"
if "$CLI" lifecycle a >/dev/null 2>&1; then fail 'symlink accepted'; fi
test -f "$TMP_ROOT/preserved.json"
pass 'generation mismatch and unsafe record retain evidence and fail closed'

# Real publication through the existing bounded scan. No endpoint/provider
# command is needed to rediscover an open goal after its notification vanished.
"$ROOT/bin/fm-inactive-reconcile.sh" scan --startup >/dev/null
count=$(wc -l < "$FM_HOME/state/.wake-queue")
"$ROOT/bin/fm-inactive-reconcile.sh" scan --startup >/dev/null
test "$count" = "$(wc -l < "$FM_HOME/state/.wake-queue")"
printf 'New artifact with an unfinished acceptance item\n' > "$FM_HOME/data/b/report.md"
"$ROOT/bin/fm-inactive-reconcile.sh" scan --startup >/dev/null
test "$(wc -l < "$FM_HOME/state/.wake-queue")" -gt "$count"
pass 'lost wake recovers through bounded existing scan; unchanged observations do not duplicate queue rows'

# Repeating an outcome reuses its original delivery sequence, including while
# it is still unprocessed by main. No pending captain outcome is discarded.
OUTCOME="$ROOT/bin/fm-branch-outcome.sh"
one=$("$OUTCOME" append --task b --verdict captain --summary 'Artifact needs completion')
two=$("$OUTCOME" append --task b --verdict captain --summary 'Same evidence, changed wording')
test "$one" = "$two"
"$OUTCOME" mark-read --through "$one"
"$OUTCOME" unprocessed | jq -e --argjson seq "$one" '.seq==$seq' >/dev/null
"$OUTCOME" mark-processed --through "$one"
test -z "$("$OUTCOME" unprocessed)"
pass 'same evidence reuses original outcome and retains unprocessed acknowledgement'

# Intake may have a brief and accepted goal before an executor is assigned.
# Discover it through the existing backlog owner, never by scanning data dirs.
mkdir -p "$FM_HOME/data/queued" "$TMP_ROOT/backlog-bin"
printf 'Finish the accepted queued request\n' > "$FM_HOME/data/queued/brief.md"
printf '# Backlog\n' > "$FM_HOME/data/backlog.md"
"$CLI" init queued >/dev/null
cat > "$TMP_ROOT/backlog-bin/tasks-axi" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list) printf 'count: 1\ntasks[1]{id,state,kind,repo,title}:\n  queued,queued,task,"-",Queued goal\n' ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$TMP_ROOT/backlog-bin/tasks-axi"
PATH="$TMP_ROOT/backlog-bin:$PATH" "$ROOT/bin/fm-inactive-reconcile.sh" scan --startup >/dev/null
if ! grep -q 'child=queued disposition=open' "$FM_HOME/state/.wake-queue"; then fail 'queued goal without metadata lost'; fi
pending=$(grep -l '^task_id=queued$' "$FM_HOME/state/terminal-outcomes/"*.pending)
fp=${pending##*/}; fp=${fp%.pending}
if "$ROOT/bin/fm-inactive-reconcile.sh" acknowledge "$fp" >/dev/null 2>&1; then fail 'goal wake acknowledged before durable reconciliation'; fi
"$CLI" lifecycle queued | jq '.assessment.remaining_gap="Need an authorized executor"' > "$TMP_ROOT/input.json"
"$CLI" reconcile queued --expected-revision 1 --record "$TMP_ROOT/input.json" >/dev/null
"$ROOT/bin/fm-inactive-reconcile.sh" acknowledge "$fp"
test -f "${pending%.pending}.presented"
pass 'unassigned accepted request survives lost wake; acknowledge follows persisted reconciliation'

"$CLI" lifecycle queued > "$TMP_ROOT/input.json"
python3 - "$TMP_ROOT/input.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); e=d['assessment']['evidence'][0]
d['next_action']={'id':'queued.g1.a1','kind':'readback','phase':'prepared',
 'expected_execution_generation':'unassigned-g1','payload_ref':e['ref'],'payload_sha256':e['sha256'],
 'receipt_ref':None,'attempts':0,'attempt_limit':2,'recheck_at':'2000-01-01T00:00:00Z','deadline':'2099-01-01T00:00:00Z'}
d['next_action_seq']=2; json.dump(d,open(p,'w'))
PY
"$CLI" reconcile queued --expected-revision 2 --record "$TMP_ROOT/input.json" >/dev/null
"$CLI" action queued --action-id queued.g1.a1 --phase attempted >/dev/null
sha=$(python3 - "$FM_HOME/data/queued/brief.md" <<'PY'
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PY
)
"$CLI" action queued --action-id queued.g1.a1 --phase confirmed --receipt-ref data/queued/brief.md --receipt-sha256 "$sha" >/dev/null
python3 "$LIB" due queued | jq -e '.due and .record.disposition=="open"' >/dev/null
pass 'confirmed readback keeps unfinished goal supervised'

# Exact new authority can reopen a historical Done goal; old status events
# cannot change the structured disposition or inherit its old acceptance.
"$CLI" lifecycle b | jq '.disposition="accepted" | .assessment.remaining_gap=""' > "$TMP_ROOT/input.json"
"$CLI" reconcile b --expected-revision 1 --record "$TMP_ROOT/input.json" >/dev/null
printf 'Explicit new requested outcome\n' > "$FM_HOME/data/b/reopen.txt"
printf 'done: old completion\nready: old awaiting merge\n' > "$FM_HOME/state/b.status"
"$CLI" lifecycle b | jq --arg ref "$FM_HOME/data/b/reopen.txt" '.disposition="open" | .goal_revision=2 | .assessment.authority_ref=$ref | .assessment.remaining_gap="New requested deliverable"' > "$TMP_ROOT/input.json"
"$CLI" reconcile b --expected-revision 2 --record "$TMP_ROOT/input.json" >/dev/null
[ "$(python3 "$LIB" mode b)" = open ] || fail 'old Done closed reopened goal'
pass 'historical completion and old ready events cannot close a newly authorized goal'

# A bounded healthy wait is not execution inactivity. Deadline expiry asks for
# assessment only and cannot spend/restart automatically.
report_sha=$(shasum -a 256 "$FM_HOME/data/b/report.md" | cut -d' ' -f1)
"$CLI" lifecycle b | jq --arg ref "$FM_HOME/data/b/report.md" --arg sha "$report_sha" '.assessment.evidence += [{ref:$ref,sha256:$sha}] | .next_action={id:"b.g2.a1",kind:"wait",phase:"prepared",expected_execution_generation:"s2",payload_ref:.assessment.evidence[0].ref,payload_sha256:.assessment.evidence[0].sha256,receipt_ref:null,attempts:0,attempt_limit:1,recheck_at:"2099-01-01T00:00:00Z",deadline:"2099-01-01T00:00:00Z"} | .next_action_seq=2' > "$TMP_ROOT/input.json"
"$CLI" reconcile b --expected-revision 3 --record "$TMP_ROOT/input.json" >/dev/null
python3 "$LIB" due b | jq -e '.due==false' >/dev/null
"$CLI" action b --action-id b.g2.a1 --phase refused --receipt-ref data/b/report.md --receipt-sha256 "$report_sha" >/dev/null
"$CLI" lifecycle b | jq '.next_action.id="b.g2.a2" | .next_action.phase="prepared" | .next_action.attempts=0 | .next_action_seq=3' > "$TMP_ROOT/input.json"
if "$CLI" reconcile b --expected-revision 5 --record "$TMP_ROOT/input.json" >/dev/null 2>&1; then fail 'same effect evaded refusal budget'; fi
pass 'healthy bounded wait does not restart; refused effect cannot reset its retry budget'

# Scale cannot extend one reconciliation turn indefinitely. Use hundreds of
# private records and the supported one-second scan budget, no backend calls.
python3 - "$FM_HOME" <<'PYBOUNDED'
import pathlib,sys
h=pathlib.Path(sys.argv[1])
for i in range(300):
 t='bounded%04d'%i;(h/'data'/t).mkdir();(h/'data'/t/'brief.md').write_text('pending goal')
 (h/'state'/(t+'.meta')).write_text('kind=scout\nspawn_gen=s1\n')
 (h/'data'/t/'lifecycle.json').write_text('{}');(h/'data'/t/'lifecycle.json').chmod(0o600)
PYBOUNDED
start=$(date +%s)
FM_INACTIVE_RECONCILE_BUDGET_SECS=1 "$ROOT/bin/fm-inactive-reconcile.sh" scan --startup >/dev/null
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 4 ] || fail "bounded scan exceeded allowance: $elapsed seconds"
printf 'ok - 300-record scan elapsed=%ss with one-second budget and backstop\n' "$elapsed"

# Run the actual Pi routing reader. A stale archived execution goes to main;
# its late result stays deliverable and the queue bytes are never consumed.
mode_home="$TMP_ROOT/routing-home"
mkdir -p "$mode_home/data/stopped" "$mode_home/state"
printf 'Explicitly stopped request\n' > "$mode_home/data/stopped/brief.md"
printf 'spawn_gen=s-stop\nkind=ship\nproject=%s\nwindow=fm-stopped\n' "$ROOT" > "$mode_home/state/stopped.meta"
FM_HOME="$mode_home" "$CLI" init stopped >/dev/null
fm_test_archive_goal "$mode_home" stopped
printf '1\t1\tstale\tfm-stopped\told idle\n2\t2\tsignal\tstopped.status\tlate result\n' > "$mode_home/state/.wake-queue"
NODE_NO_WARNINGS=1 LIFECYCLE_ROOT="$ROOT" LIFECYCLE_HOME="$mode_home" node --input-type=module <<'JS'
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const root=process.env.LIFECYCLE_ROOT, home=process.env.LIFECYCLE_HOME, state=home+'/state';
const lib=await import(pathToFileURL(root+'/.pi/extensions/lib/fm-branch-dispatch.ts'));
const before=readFileSync(state+'/.wake-queue','utf8');
const modes=await lib.lifecycleModesForWake(root,home,state);
if(modes.stopped!=='archived') throw new Error('reader did not validate stopped generation');
const scope=lib.scopeForUnreadWake(state,false,modes);
if(JSON.stringify(scope.eligibleSeqs)!=='["2"]' || !scope.needsDecisionKeys.includes('fm-stopped')) throw new Error('archive routing lost late result or resumed stale work');
if(readFileSync(state+'/.wake-queue','utf8')!==before) throw new Error('routing consumed a pending result');
JS
pass 'Pi excludes archived stale recovery while preserving late result and every queue row'

# Same task name in a reassigned slot is still a different execution.
mkdir -p "$TMP_ROOT/pool/1/checkout"
ROOT="$ROOT" SLOT="$TMP_ROOT/pool/1/checkout" bash <<'SHSLOT'
set -eu
. "$ROOT/bin/fm-wake-lib.sh"
fm_treehouse_slot_owner_claim "$SLOT" same "$FM_HOME" s-new
fm_treehouse_slot_owner_state "$SLOT" same s-old
[ "$FM_TREEHOUSE_SLOT_OWNER" = unsafe ]
fm_treehouse_slot_owner_release "$SLOT" same s-old
fm_treehouse_slot_owner_state "$SLOT" same s-new
[ "$FM_TREEHOUSE_SLOT_OWNER" = mine ]
fm_treehouse_slot_owner_claim "$SLOT" same "$FM_HOME"
fm_treehouse_slot_owner_state "$SLOT" same s-new
[ "$FM_TREEHOUSE_SLOT_OWNER" = unsafe ]
fm_treehouse_slot_owner_release "$SLOT" same s-new
[ -f "$(fm_treehouse_slot_owner_marker "$SLOT")" ]
fm_treehouse_slot_owner_claim "$SLOT" same "$FM_HOME" s-new
printf 'spawn_gen=s-duplicate\n' >> "$(fm_treehouse_slot_owner_marker "$SLOT")"
fm_treehouse_slot_owner_state "$SLOT" same s-new
[ "$FM_TREEHOUSE_SLOT_OWNER" = unsafe ]
SHSLOT
pass 'missing or old generation cannot release a reused same-task slot; duplicate claim remains unsafe'
