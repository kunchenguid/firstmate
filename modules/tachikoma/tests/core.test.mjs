// Pure routing against an in-memory snapshot adapter; no credentials or runtimes.
import assert from 'node:assert/strict';
import { decide, synchronize, tupleKey } from '../src/core/routing.mjs';
import { qualityForClass } from '../src/core/quality.mjs';

const profiles = ['a', 'b'].map(model => ({ harness: 'pi', model: `subscription/${model}`, effort: 'high' }));
const fixture = {
  policy: { allowedHarnesses: ['pi'], disabledPools: [], maxLoadPerCpu: 2,
    bindings: profiles.map((profile, i) => ({ ...profile, pool: ['a','b'][i], quotaProvider: ['a','b'][i], modelFamily: ['a','b'][i], quotaScopes: ['all_models'], strongest: i === 1 })) },
  rule: { matchedRule: 'default', horizonSeconds: 60, strongestOnly: false },
  candidates: profiles,
  snapshot: { ageSeconds: 0, quota: ['a','b'].map((provider, i) => ({provider, scope:'all_models',effectivePercentRemaining:80,spendPriority:4-i,runway:'through_reset'})), exhaustion: [] },
  machine: {loadAverage1m:1,logicalCpuCount:4}, cooldowns: {}, repo:'example',
};
const fakeState = { read: () => structuredClone(fixture) };
let checked = 0;
function check(name, body) { body(fakeState.read()); checked++; console.log(`ok - ${name}`); }
check('highest known scalar wins without modifying the input snapshot', input => {
  const before=structuredClone(input); assert.equal(decide(input).model,'subscription/a'); assert.deepEqual(input,before);
});
check('disabled pool, adapter, and cooldown each independently exclude the highest spender', input => {
  input.policy.disabledPools=['a']; assert.equal(decide(input).model,'subscription/b');
  input.policy.disabledPools=[]; input.cooldowns[tupleKey(profiles[0])]=true; assert.equal(decide(input).model,'subscription/b');
  input.cooldowns={}; input.policy.allowedHarnesses=['claude']; assert.equal(decide(input).model,null);
});
check('Artemis and explicit reasoning floors never downgrade', input => {
  input.repo='ArTeMiS'; assert.equal(decide(input).model,'subscription/b');
  input.policy.disabledPools=['b']; assert.equal(decide(input).model,null);
  input.repo='example'; input.rule.strongestOnly=true; assert.equal(decide(input).model,null);
});
check('ties refuse rather than choosing by array order', input => {
  input.snapshot.quota[1].spendPriority=4; assert.deepEqual(decide(input).reasons,['spend-priority-tie']);
  input.candidates.reverse(); assert.equal(decide(input).model,null);
});
check('projected runway ages across the completion horizon, whereas reset is not exhaustion', input => {
  input.snapshot.quota[0].runway='projected_exhaustion'; input.snapshot.exhaustion=[{provider:'a',scope:'all_models',usableRunwaySeconds:80}];
  input.snapshot.ageSeconds=20; assert.equal(decide(input).model,'subscription/a');
  input.snapshot.ageSeconds=21; assert.equal(decide(input).model,'subscription/b');
  input.snapshot.quota[0].runway='through_reset'; input.snapshot.quota[0].resetsAt='2000-01-01'; assert.equal(decide(input).model,'subscription/a');
});
check('unknown or exhausted quota never becomes healthy zero', input => {
  for (const value of [null, 'unknown', 0]) { input.snapshot.quota[0].effectivePercentRemaining=value; assert.equal(decide(input).model,'subscription/b'); }
  input.snapshot.quota[0].effectivePercentRemaining=90; input.snapshot.quota[0].spendPriority='unknown'; assert.equal(decide(input).model,'subscription/b');
  input.snapshot.quota[0].spendPriority=0; input.snapshot.quota[1].spendPriority=-1; assert.equal(decide(input).model,'subscription/a');
});
check('unknown quota stays eligible with disclosed uncertainty rather than becoming an unsupported model', input => {
  input.snapshot.quota[0].effectivePercentRemaining=null;
  input.snapshot.quota[0].runway='unknown'; input.snapshot.quota[0].spendPriority='unknown';
  const result=decide(input); assert.equal(result.model,'subscription/b');
  assert.equal(result.alternatives[0].eligibility,'eligible');
  assert.equal(result.alternatives[0].feasibility,'unproven');
  assert.ok(result.alternatives[0].uncertainties.includes('runway-unknown'));
  input.snapshot.quota[1].runway='unknown'; assert.equal(decide(input).model,null);
});
check('known exhaustion is a veto even when the remaining percentage disagrees', input => {
  input.snapshot.quota[0].runway='exhausted_now';
  assert.equal(decide(input).model,'subscription/b');
  assert.equal(decide(input).alternatives[0].eligibility,'blocked');
});
check('provider-wide bounds apply in addition to explicit model scopes', input => {
  input.policy.bindings[0].quotaScopes=['model:a']; input.snapshot.quota.push({provider:'a',scope:'model:a',effectivePercentRemaining:100,spendPriority:10,runway:'through_reset'});
  input.snapshot.quota[0].effectivePercentRemaining=0; assert.equal(decide(input).model,'subscription/b');
});
check('overload refuses every candidate, and recovery uses the unchanged policy', input => {
  input.machine.loadAverage1m=9; assert.equal(decide(input).model,null);
  input.machine.loadAverage1m=8; assert.equal(decide(input).model,'subscription/a');
});
check('learning uses sealed real outcomes and exact decision identity, never a similar task name', () => {
  const base={...profiles[0],recordType:'attempt',state:'terminal',attemptClass:'real',taskClass:'bounded',modelVersion:'v1',cliVersion:'cli-1',classification:'accepted',wallSeconds:60,cost:null,currency:null,tachikomaDecision:'decision-1'};
  const decisions=[{...profiles[0],decisionId:'decision-1'}];
  const observations=[base,{...base,state:'open'},{...base,attemptClass:'synthetic'},{...base,model:null},{...base,tachikomaDecision:'unrelated',classification:'failed',endedAt:'2026-09-11T00:00:00Z',primaryFailureClass:'quota',parentAttemptId:'previous',wallSeconds:null}];
  const card=synchronize(observations,decisions).get(base.model); const cell=Object.values(card.classes)[0];
  assert.equal(card.attempts,2); assert.equal(card.joinedDecisions,1); assert.equal(cell.successRate,0.5); assert.equal(cell.relaunchRate,0.5); assert.equal(cell.meanWallSeconds,60); assert.deepEqual(cell.costByCurrency,{});
  assert.equal(card.lastSeenFailure.cause,'quota'); assert.deepEqual(synchronize(observations,decisions),synchronize(observations,decisions));
});
check('effort and model/CLI versions remain separate evidence cells; currency is not mixed', () => {
  const base={...profiles[0],recordType:'attempt',state:'terminal',attemptClass:'real',taskClass:'bounded',modelVersion:'v1',cliVersion:'cli-1',classification:'accepted',cost:0,currency:'USD'};
  const card=synchronize([base,{...base,effort:'medium'},{...base,modelVersion:'v2'},{...base,cliVersion:'cli-2'},{...base,currency:'EUR',cost:2}],[]).get(base.model);
  assert.equal(Object.keys(card.classes).length,4); const cell=Object.values(card.classes)[0]; assert.deepEqual(cell.costByCurrency,{USD:0,EUR:2}); assert.equal(cell.meanWallSeconds,null);
});
check('coding rules use logged weighted exploration after gates; other rules retain their deterministic policy', input => {
  input.rule.selectionStrategy='quota-weighted'; input.policy.explorationRate=0.1;
  for (const binding of input.policy.bindings) binding.qualityPrior=0.7;
  input.seed=0; assert.equal(decide(input).model,'subscription/a');
  input.seed=0xffffffff; const result=decide(input); assert.equal(result.model,'subscription/b');
  assert.equal(result.selection.seed,0xffffffff); assert.equal(result.confidence,'weighted-policy');
  input.policy.disabledPools=['b']; assert.equal(decide(input).model,'subscription/a');
  input.policy.disabledPools=[]; input.repo='Artemis'; input.seed=0; assert.equal(decide(input).model,'subscription/b');
  delete input.rule.selectionStrategy; assert.equal(decide(input).confidence,'deterministic-policy');
});
check('unmeasured coding exploration observes pool caps and never escapes the reasoning floor', input => {
  input.rule.selectionStrategy='quota-weighted'; input.policy.explorationRate=0.1;
  for (const binding of input.policy.bindings) binding.qualityPrior=0.7;
  input.snapshot.quota[1].spendPriority=null; input.snapshot.quota[1].runway='unknown';
  input.seed=0xffffffff; const result=decide(input); assert.equal(result.model,'subscription/b');
  assert.equal(result.selection.weights[1].runway,'unmeasured');
  input.dailyPicks={b:1}; assert.equal(decide(input).model,'subscription/a');
  input.dailyPicks={}; input.policy.bindings[1].strongest=false; input.policy.bindings[0].strongest=true;
  input.repo='Artemis'; assert.equal(decide(input).model,'subscription/a');
});
check('class quality uses independent tasks and exact versions, excludes environment faults, and attributes a relaunch to the attempt needing it', () => {
  const base={...profiles[0],recordType:'attempt',state:'terminal',attemptClass:'real',taskClass:'bounded',modelVersion:'v1',cliVersion:'cli-1',classification:'failed',primaryFailureClass:'capability',attemptId:'a',taskRootId:'root',wallSeconds:60,cost:null,currency:null,metrics:{reviewFindings:2}};
  const card=synchronize([base,{...base,attemptId:'b',parentAttemptId:'a',classification:'accepted',metrics:{reviewFindings:0}},{...base,attemptId:'env',taskRootId:'other',primaryFailureClass:'environment',wallSeconds:999}],[]).get(base.model);
  const quality=qualityForClass(card,base,'bounded',0.7);
  assert.equal(quality.source,'class-card'); assert.equal(quality.observations,1);
  assert.equal(quality.acceptanceRate,0.5); assert.equal(quality.relaunchRate,0.5);
  assert.equal(quality.meanWallSeconds,60); assert.equal(quality.meanReviewFindings,1);
  assert.ok(quality.score<0.7); assert.equal(quality.meanCost,null);
  assert.equal(qualityForClass(card,{...base,cliVersion:'new'},'bounded',0.7).source,'profile-prior');
  assert.equal(qualityForClass(card,base,'other-class',0.7).source,'profile-prior');
  assert.throws(()=>qualityForClass(card,base,'bounded',undefined));
});
console.log(`${checked} core checks passed`);
