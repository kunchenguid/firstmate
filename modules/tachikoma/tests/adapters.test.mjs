import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test, after } from 'node:test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'tachikoma-adapters-')));
after(() => fs.rmSync(temporary, { recursive: true, force: true }));
const taskClass = 'bounded-implementation-proven-root-fix';
function fixture(name) {
  const home = path.join(temporary, name);
  fs.mkdirSync(path.join(home, 'config/tachikoma'), { recursive: true }); fs.mkdirSync(path.join(home, 'data'));
  const put = (file, value) => fs.writeFileSync(path.join(home, file), typeof value === 'string' ? value : JSON.stringify(value));
  const profiles = ['a','b'].map(model => ({ harness:'pi', model:`subscription/${model}`, effort:'high' }));
  put('config/model-catalog.json', { pools: ['a','b'].map(pool => ({ pool,provider:pool,plan:'paid',harness:'pi',account:'PRIVATE ACCOUNT DESCRIPTION',models:[pool],quota_readable:true })) });
  put('config/crew-dispatch.json', { default: profiles });
  const sha = file => crypto.createHash('sha256').update(fs.readFileSync(path.join(home, file))).digest('hex');
  const policy = { schemaVersion:1,enabled:false,catalogSha256:sha('config/model-catalog.json'),dispatchSha256:sha('config/crew-dispatch.json'),allowedHarnesses:['pi'],disabledPools:[],maxLoadPerCpu:100000,rules:['example','artemis'].map(repo => ({repo,taskClass,matchedRule:'default',horizonSeconds:60,strongestOnly:false,selectionStrategy:'quota-weighted'})),bindings:profiles.map((profile,i) => ({...profile,pool:['a','b'][i],catalogModel:['a','b'][i],quotaProvider:['a','b'][i],modelFamily:['a','b'][i],quotaScopes:['all_models'],strongest:i===1,qualityPrior:0.7})) };
  const save = () => put('config/tachikoma/policy.json', policy);
  const quota = (a=4,b=2,age=0) => put('data/quota.toon', `generatedAt: "${new Date(Date.now()-age).toISOString()}"\nquota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:\n  a,all_models,60,${a},through_reset,established,weekly,"2026-12-01T00:00:00Z"\n  b,all_models,80,${b},${b==='unknown'?'unknown':'through_reset'},established,weekly,"2026-12-01T00:00:00Z"\n`);
  save(); quota(); put('data/brief.md', 'PRIVATE PROMPT MUST NOT BE LOGGED');
  const env = { ...process.env, FM_HOME: home, FM_DATA_OVERRIDE: path.join(home,'data'), FM_STATE_OVERRIDE: path.join(home,'state') };
  const args = (repo='example', seed='0') => ['route','--task','case-a','--class',taskClass,'--repo',repo,'--brief',path.join(home,'data/brief.md'),'--snapshot',path.join(home,'data/quota.toon'),'--seed',seed];
  const call = (argv, status=0) => {
    const result = spawnSync('node', [path.join(root,'modules/tachikoma/src/adapters/cli.mjs'),...argv], { env, encoding:'utf8', timeout:20000 });
    assert.equal(result.status,status,`${argv.join(' ')}: ${result.stderr} ${result.stdout} ${result.error || ''}`);
    return result.stdout;
  };
  return {home,env,args,call,put,policy,save,quota};
}

test('CLI gates, seeded decisions, actual cooldown owner, privacy, service telemetry, and help', () => {
  const f=fixture('routing');
  assert.deepEqual(JSON.parse(f.call([...f.args(),'--if-enabled'])), {status:'disabled',fallback:'profiles'});
  assert(!fs.existsSync(path.join(f.home,'state')));
  for (const args of [['-h'],['route','-h'],['learn','--help'],['stats','-h'],['status','--help']]) assert.match(f.call(args),/--request-id/);
  const first=JSON.parse(f.call(f.args())); assert.equal(first.model,'subscription/a');
  assert.equal(JSON.parse(f.call(f.args('example','4294967295'))).model,'subscription/b');
  f.policy.disabledPools=['a']; f.save(); assert.equal(JSON.parse(f.call(f.args())).model,'subscription/b');
  f.policy.disabledPools=[]; f.policy.allowedHarnesses=['claude']; f.save(); assert.equal(JSON.parse(f.call(f.args(),3)).model,null);
  f.policy.allowedHarnesses=['pi']; f.save(); assert.equal(JSON.parse(f.call(f.args('artemis'))).model,'subscription/b');
  f.put('data/quota-cooldowns.json',{schema_version:1,cooldowns:[{id:'qcd_test',scope:{kind:'provider',provider:'a'},evidence:{kind:'provider-refusal',quote:'PRIVATE PROVIDER REFUSAL'},recorded_at:new Date().toISOString(),expires_at:'2099-01-01T00:00:00Z',overrides:[]}]});
  const cooling = JSON.parse(f.call(f.args()));
  assert.equal(cooling.model,'subscription/b');
  assert.equal(cooling.poolRecovery.find(row=>row.pool==='a').cooldownUntil,'2099-01-01T00:00:00Z');
  assert.equal(JSON.parse(f.call(['stats'])).pools.find(row=>row.pool==='a').recheckDue,false);
  assert.match(f.call(['status','--clean']),/fresh evidence required/);
  fs.unlinkSync(path.join(f.home,'data/quota-cooldowns.json'));
  f.quota(2,2); assert.equal(JSON.parse(f.call(f.args('example','4294967295'))).model,'subscription/b');
  f.quota(4,2,600000); f.call(f.args(),2); f.quota();
  f.call(f.args('unknown'),2); f.call([...f.args(),'--require-enabled'],2);
  f.policy.unexpected=true; f.save(); f.call(f.args(),2); delete f.policy.unexpected; f.save();
  const history=fs.readFileSync(path.join(f.home,'data/tachikoma/decisions.jsonl'),'utf8');
  const logs=fs.readdirSync(path.join(f.home,'state/tachikoma/telemetry')).map(name=>fs.readFileSync(path.join(f.home,'state/tachikoma/telemetry',name),'utf8')).join('');
  for (const secret of ['PRIVATE PROMPT','PRIVATE ACCOUNT','PRIVATE PROVIDER']) assert(!(history+logs).includes(secret));
  const events=logs.trim().split('\n').map(JSON.parse);
  assert(events.some(row=>row.event==='port.enter')); assert(events.some(row=>row.event==='port.exit' && row.stepsMs.evidence>=0));
  assert(events.some(row=>row.outcome==='error' && row.reasons.includes('stale or invalid quota snapshot')));
  assert.equal(JSON.parse(f.call(['stats'])).usage.inputTokens,null);
  assert.match(f.call(['status','--clean']),/Pick:/); assert(!f.call(['status','--no-ui']).includes('\x1b'));
  assert.equal(fs.statSync(path.join(f.home,'data/tachikoma/decisions.jsonl')).mode & 0o777,0o600);
});

test('Pi Cursor families rotate with OpenAI, Qwen and reactivated Kimi while respecting explicit pool pauses', () => {
  const f=fixture('cursor-pools');
  const models=[['cursor/grok-4.6','cursor'],['cursor/glm-5.2','cursor'],['cursor/composer','cursor'],['openai-codex/gpt-5.6-sol','codex'],['qwen-token-plan-individual/qwen3.8-max','qwen'],['kimi-coding/k3','kimi']];
  const profiles=models.map(([model])=>({harness:'pi',model,effort:model==='cursor/composer'?null:'high'}));
  f.put('config/model-catalog.json',{pools:['cursor','codex','qwen','kimi'].map(pool=>({pool,provider:pool,plan:'paid',harness:'pi',account:'fixture',models:models.filter(row=>row[1]===pool).map(row=>row[0]),quota_readable:pool!=='qwen'}))});
  f.put('config/crew-dispatch.json',{default:profiles.map(profile=>profile.effort===null?{harness:profile.harness,model:profile.model}:profile)});
  const sha=file=>crypto.createHash('sha256').update(fs.readFileSync(path.join(f.home,file))).digest('hex');
  Object.assign(f.policy,{catalogSha256:sha('config/model-catalog.json'),dispatchSha256:sha('config/crew-dispatch.json'),disabledPools:['kimi'],bindings:profiles.map((profile,i)=>({...profile,pool:models[i][1],catalogModel:profile.model,quotaProvider:models[i][1],modelFamily:profile.model,quotaScopes:['all_models'],strongest:true,qualityPrior:0.7}))});
  f.save();
  f.put('data/quota.toon',`generatedAt: "${new Date().toISOString()}"\nquota[4]{provider,scope,effectivePercentRemaining,spendPriority,runway}:\n  cursor,all_models,44,2.6,through_reset\n  codex,all_models,70,-2,through_reset\n  kimi,all_models,78,-1,through_reset\n  grok,all_models,0,-9,exhausted_now\n`);
  const pick=JSON.parse(f.call(f.args()));
  for (const [model] of models.slice(0,5)) assert(pick.selection.weights.find(row=>row.model===model).probability>0);
  assert.equal(pick.alternatives.find(row=>row.model==='kimi-coding/k3').eligibility,'blocked');
  assert.equal(pick.poolRecovery.find(row=>row.pool==='cursor').quota[0].headroom,44);
  assert.equal(pick.selection.weights.find(row=>row.pool==='qwen').runway,'unmeasured');
  f.policy.disabledPools=[]; f.save();
  const kimi=JSON.parse(f.call(f.args())).selection.weights.find(row=>row.model==='kimi-coding/k3');
  assert(kimi.probability>0); assert.equal(kimi.runway,'proven');
});

test('real immutable telemetry joins by decision ID and learn rebuilds cards idempotently', () => {
  const f=fixture('learning'); const pick=JSON.parse(f.call(f.args()));
  const intake={attemptClass:'real',source:'firstmate',taskRootId:null,parentAttemptId:null,projectRef:'project_0123456789abcdef',taskClass,tuple:{harness:'pi',provider:'a',model:'subscription/a',effort:'high',modelVersion:'a-v1',cliVersion:'pi-test'},selection:{routingSource:'tachikoma',tachikomaDecision:pick.decisionId,matchedRule:'default',configSha256:null,fitReasons:[],candidateAssessments:[],quota:{decision:'selected',headroom:'sufficient',runway:'sufficient',observedAt:null}},neutralExecution:{correlation:null,capabilityProfile:'not-applicable',owner:'not-applicable',phase:null,behavioralResult:'not-applicable'},evaluation:{kind:'none',fixtureId:null,fixtureManifestSha256:null,oracleId:null,oracleSha256:null,sourceCommit:null},startedAt:new Date().toISOString(),privacy:{classification:'operational-minimized',contentPolicy:'ids-codes-hashes-bounded-evidence-only'}};
  const telemetry=args=>{ const r=spawnSync(path.join(root,'bin/fm-model-telemetry.sh'),args,{env:f.env,encoding:'utf8'});assert.equal(r.status,0,r.stderr);return JSON.parse(r.stdout); };
  telemetry(['intake','--task','case-a','--payload',JSON.stringify(intake)]);
  assert.equal(JSON.parse(f.call(['learn'])).sealedAttempts,0);
  telemetry(['terminal-facts','--task','case-a','--payload',JSON.stringify({gate:{source:'delivery',result:'green',stepReruns:null},outcomeLink:{kind:'pull-request',id:'https://github.com/example/repo/pull/1'},usage:{inputTokens:100,outputTokens:20,cost:null,currency:null},wallSeconds:60})]);
  assert.equal(JSON.parse(f.call(['learn'])).joinedDecisions,1);
  const file=path.join(f.home,'data/tachikoma/cards/subscription%2Fa.json'); const before=fs.readFileSync(file,'utf8');
  f.call(['learn']); assert.equal(fs.readFileSync(file,'utf8'),before);
  assert.equal(JSON.parse(before).pools[0].quotaResetAt,'2026-12-01T00:00:00Z');
  const cell=Object.values(JSON.parse(before).classes)[0]; assert.equal(cell.successRate,1); assert.equal(cell.meanWallSeconds,60);
  assert.match(f.call(['status']),/Sealed attempts: 1/);
});

test('concurrent real CLI processes cannot spend an unmeasured pool daily cap twice', async () => {
  const f=fixture('concurrency'); f.quota(4,'unknown');
  const run=()=>new Promise((resolve,reject)=>{
    const child=spawn('node',[path.join(root,'modules/tachikoma/src/adapters/cli.mjs'),...f.args('example','4294967295')],{env:f.env});
    let out='',err='';child.stdout.on('data',s=>{out+=s;});child.stderr.on('data',s=>{err+=s;});child.on('error',reject);
    child.on('close',code=>{try{assert.equal(code,0,err);resolve(JSON.parse(out));}catch(error){reject(error);}});
  });
  const decisions=await Promise.all([run(),run()]);
  assert.equal(decisions.filter(row=>row.model==='subscription/b').length,1);
});

test('broken activation symlinks and corrupt owned history refuse rather than becoming fallback or empty state', () => {
  const f=fixture('unsafe'); const file=path.join(f.home,'config/tachikoma/policy.json');
  fs.unlinkSync(file); fs.symlinkSync('missing.json',file); f.call([...f.args(),'--if-enabled'],2);
  fs.unlinkSync(file); f.save(); f.call(f.args());
  fs.appendFileSync(path.join(f.home,'data/tachikoma/decisions.jsonl'),'broken-json\n'); f.call(['learn'],2);
  f.put('data/tachikoma/decisions.jsonl','');
  fs.renameSync(path.join(f.home,'data/tachikoma'),path.join(f.home,'data/elsewhere'));
  fs.symlinkSync('elsewhere',path.join(f.home,'data/tachikoma'));
  f.call(['status','--json'],2);
});
