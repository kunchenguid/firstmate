import { pluginFixture } from './fm-short-plugin-fixture.mjs';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
const [root, tmp] = process.argv.slice(2);
const { ShortAgents, reader, snapshot, publish } = await import(pathToFileURL(path.join(root, 'bin/fm-short-agent.mjs')));
const wait = ms => new Promise(r => setTimeout(r, ms));
const home = path.join(tmp, 'home'), pkg = path.join(tmp, 'sdk');
fs.mkdirSync(home); fs.mkdirSync(path.join(pkg, 'dist'), { recursive: true });
process.env.FM_PI_PACKAGE_DIR = pkg;
// Fake model session only; executable store, processes, tools and outcome path
// are production code. The live guard separately verifies the actual Pi API.
fs.writeFileSync(path.join(pkg, 'package.json'), '{"name":"@earendil-works/pi-coding-agent","main":"dist/index.js","type":"module"}');
fs.mkdirSync(path.join(pkg,'dist/core'));
fs.writeFileSync(path.join(pkg,'dist/core/http-dispatcher.js'),'export function configureHttpDispatcher() {}');
fs.writeFileSync(path.join(pkg, 'dist/index.js'), `
import { execFile as execFileCallback } from 'node:child_process';
import { promisify } from 'node:util';
const execFile = promisify(execFileCallback);
${pluginFixture(pkg)}
export const createExtensionRuntime = () => ({});
export function createBashToolDefinition(cwd) { return {name:'bash',label:'bash',description:'Execute Bash in the configured cwd.',parameters:{type:'object',properties:{command:{type:'string'},timeout:{type:'number'}},required:['command'],additionalProperties:false},async execute(_id,args){
 if(args.command==='uncertain-write') { await execFile('bash',['-c','printf x >> uncertain.txt'],{cwd}); throw Error('fixture lost command completion'); }
 if(args.command==='cancel-write') { await execFile('bash',['-c','printf c >> cancelled.txt'],{cwd}); await new Promise((_resolve,reject)=>arguments[2].addEventListener('abort',()=>reject(Error('aborted')),{once:true})); }
 try { const result=await execFile('bash',['-c',args.command],{cwd}); return {content:[{type:'text',text:result.stdout||'(no output)'}],details:undefined,structuredContent:{output:result.stdout,exit_code:0,wall_time_seconds:0,truncated:false}}; }
 catch(error) { return {content:[{type:'text',text:(error.stdout||'')+(error.stderr||'')+'Command exited with code '+(error.code||1)}],details:undefined,structuredContent:{output:(error.stdout||'')+(error.stderr||''),exit_code:Number(error.code)||1,wall_time_seconds:0,truncated:false},isError:true}; }
}};}
export const ModelRuntime = { create: async () => ({provider:{},getProvider(){return this.provider;},getAvailable: async () => [{provider:'fixture',id:'fixture'},{provider:'fixture',id:'fixture-two'}],streamSimple:async (_m,_c,opts)=> {
 if(Object.hasOwn(opts,'maxTokens')) throw Error('application output cap still present');
 if(_c.transport) await opts.fetch('https://unused.invalid');
 if(_c.replay) {await opts.fetch();await opts.fetch();}
}}) };
export const SessionManager = {inMemory: () => ({getBranch:()=>[]})};
export const SettingsManager = {inMemory: x => ({...x,getCacheWarmingMode:()=>x.cacheWarming})};
export async function createAgentSession(o) {
 if(!['read_material','read_material,bash'].includes(o.tools.join()) || o.resourceLoader.getAgentsFiles().agentsFiles.length || o.resourceLoader.getExtensions().extensions.length!==1) throw Error('isolation violated');
 if(o.settingsManager.getCacheWarmingMode() !== 'off') throw Error('cache warming enabled');
 const messages=[], subscribers=[],controller=new AbortController();let answer='answer 42 m1';
 return {session:{ messages, systemPrompt:o.resourceLoader.getSystemPrompt(), getActiveToolNames:()=>o.tools,setActiveToolsByName(){},async bindExtensions(options){if(process.env.FM_FIXTURE_BIND_ERROR)options.onError({event:'session_start',error:'fixture'});o.modelRuntime.provider={};},

 subscribe: cb=>subscribers.push(cb),dispose(){controller.abort();},getLastAssistantText:()=>answer,
 async prompt(prompt){
  const goal=JSON.parse(prompt).goal;
  if(goal==='crash') process.exit(19);
  if(goal==='oversize') for(const cb of subscribers) cb({type:'message_update',assistantMessageEvent:{type:'text_delta',delta:'x'.repeat(100)}});
  if(goal==='wait') await new Promise(r=>setTimeout(r,10000));
  if(goal==='delayed') await new Promise(r=>setTimeout(r,1000));
  if(goal.startsWith('transport')) {
   const nested=new Error('PRIVATE_PROXY_URL PRIVATE_TOKEN');nested.code='ECONNRESET';
   const unknown=new Error('PRIVATE_CAUSE');unknown.code='PRIVATE_CODE';
   const cause=new AggregateError([nested,unknown,nested],'PRIVATE_AGGREGATE');cause.cause=cause;
   const fetch=async()=>{throw new TypeError('fetch failed',{cause});};
   await o.modelRuntime.streamSimple({}, {transport:true}, {fetch});
  }
  if(goal==='provider-replay') await o.modelRuntime.streamSimple({}, {replay:true}, {fetch:async()=>({status:200})});
  await o.modelRuntime.streamSimple({}, {}, {});
  if(goal==='modelbudget') await o.modelRuntime.streamSimple({}, {}, {});
  if(goal==='toolbudget') {for(let i=0;i<4;i++) await o.customTools[0].execute('a',{material:'m1'});}
  if(goal==='bash-fixture') {const bash=o.customTools.find(tool=>tool.name==='bash');await bash.execute('b1',{command:'printf changed > value.txt'},controller.signal);const verified=await bash.execute('b2',{command:'cat value.txt'},controller.signal);answer='Verified final content: '+verified.structuredContent.output;}
  if(goal==='bash-uncertain') {const bash=o.customTools.find(tool=>tool.name==='bash');await bash.execute('b1',{command:'uncertain-write'},controller.signal);}
  if(goal==='bash-cancel') {const bash=o.customTools.find(tool=>tool.name==='bash');await bash.execute('b1',{command:'cancel-write'},controller.signal);}
  if(goal.startsWith('large-output')) answer='x'.repeat(4096);
  if(JSON.parse(prompt).materials.length) {const result=await o.customTools[0].execute('a',{material:'m1'});if(!result.content[0].text.includes('42')) throw Error('fixture missing');}
  const message={role:'assistant',stopReason:'stop',content:[{type:'text',text:'42'}]};messages.push(message);
  for(const cb of subscribers) cb({type:'message_end',message});
 }}};
}
`);
const fixture = path.join(tmp, 'evidence.txt'); fs.writeFileSync(fixture, 'value = 42\n');
const largeFixture = path.join(tmp, 'large-evidence.txt'); fs.writeFileSync(largeFixture, 'value = 42\n' + 'x'.repeat(40000));
fs.mkdirSync(path.join(home, 'config'));fs.writeFileSync(path.join(home, 'config/short-agent.json'),'{"provider":"fixture","model":"fixture"}\n');
const service = new ShortAgents(home, root);
const request = (key, goal='delayed', budget) => ({key,goal,acceptance:'return value with evidence',materials:[fixture],...(budget ? {budget} : {})});
for (const [name,contents,pattern] of [
  ['missing',null,/config missing/],
  ['malformed','{',/malformed JSON/],
  ['fields','{"provider":"fixture","model":"fixture","extra":true}',/exactly provider and model/],
  ['unavailable','{"provider":"fixture","model":"absent"}',/configured short-agent model fixture\/absent is unavailable/],
]) {
  const invalidHome=path.join(tmp,`config-${name}`);fs.mkdirSync(path.join(invalidHome,'config'),{recursive:true});
  if(contents!==null)fs.writeFileSync(path.join(invalidHome,'config/short-agent.json'),contents);
  assert.throws(()=>new ShortAgents(invalidHome,root).submit(request(`config-${name}`),false),pattern);
}
assert.throws(()=>service.submit({...request('override-provider'),provider:'fixture'},false),/provider\/model request overrides are unsupported/);
assert.throws(()=>service.submit({...request('override-model'),model:'fixture'},false),/provider\/model request overrides are unsupported/);
const accepted = service.submit(request('one'));
assert.equal(accepted.state, 'accepted');assert.equal(accepted.provider,'fixture');assert.equal(accepted.model,'fixture');assert.ok(accepted.submitMs < 1000);
fs.writeFileSync(path.join(home,'config/short-agent.json'),'{"provider":"fixture","model":"fixture-two"}\n');
const changedSelection=service.submit(request('config-changed'),false);assert.equal(changedSelection.model,'fixture-two');
assert.equal(JSON.parse(fs.readFileSync(path.join(service.dir(changedSelection.id),'request.json'))).input.model,'fixture-two');
assert.equal(service.submit(request('one')).model,'fixture','retry retains the model resolved at original acceptance');
assert.equal(JSON.parse(fs.readFileSync(path.join(service.dir(accepted.id),'request.json'))).input.model,'fixture','live request identity is immutable across config edits');
fs.writeFileSync(path.join(home,'config/short-agent.json'),'{"provider":"fixture","model":"fixture"}\n');
assert.throws(()=>service.submit(request('one','different')), /different request/);
const cliRequestFile=path.join(tmp,'cli-request.json');fs.writeFileSync(cliRequestFile,JSON.stringify(request('cli-config')));
const cliAccepted=JSON.parse(execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'submit',cliRequestFile],{env:{...process.env,FM_HOME:home},encoding:'utf8'}));
assert.deepEqual({provider:cliAccepted.provider,model:cliAccepted.model},{provider:'fixture',model:'fixture'},'CLI returns its configured selection receipt');
const cliOverrideFile=path.join(tmp,'cli-override.json');fs.writeFileSync(cliOverrideFile,JSON.stringify({...request('cli-override'),provider:'fixture',model:'fixture'}));
assert.throws(()=>execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'submit',cliOverrideFile],{env:{...process.env,FM_HOME:home},encoding:'utf8'}),/provider\/model request overrides are unsupported/);
assert.throws(()=>service.status('../escape'), /invalid/);
let ticks=0; const tick=setInterval(()=>ticks++,10);
const until = async (id, state) => {for(let n=0;n<200;n++){const s=service.status(id);if(s.state===state)return s;await wait(50);}throw Error('did not reach '+state+' '+JSON.stringify(service.status(id)));};
const done=await until(accepted.id,'completed');clearInterval(tick);assert.ok(ticks>20);assert.deepEqual({provider:done.provider,model:done.model},{provider:'fixture',model:'fixture'});
const started=JSON.parse(fs.readFileSync(path.join(service.dir(accepted.id),'started.json')));
assert.ok(started.at >= accepted.acceptedAt);
const runtime=JSON.parse(fs.readFileSync(path.join(service.dir(accepted.id),'runtime.json')));
assert.equal(runtime.extensions.length,1);assert.equal(runtime.cacheWarming,'off');assert.equal(runtime.parentMessages,0);
process.env.FM_FIXTURE_BIND_ERROR='1';
const bindFailure=service.submit(request('bind-failure'));delete process.env.FM_FIXTURE_BIND_ERROR;
const bindResult=await until(bindFailure.id,'blocked');assert.equal(bindResult.stage,'plugin-initialization');assert.equal(bindResult.requests,0);assert.equal(bindResult.toolCalls,0);
const failed=service.submit(request('transport','transport'));
const failure=await until(failed.id,'blocked');
assert.equal(failure.requests,1);assert.equal(failure.toolCalls,0);assert.equal(failure.stage,'model-execution');
const failureJournal=fs.readFileSync(path.join(service.dir(failed.id),'journal.jsonl'),'utf8');
const failureEvents=failureJournal.trim().split('\n').map(JSON.parse);
assert.deepEqual(failureEvents,[{type:'transport_error',request:1,phase:'before_headers',codes:['ECONNRESET'],toolsStarted:0}]);
assert.ok(!failureJournal.includes('PRIVATE_'),'transport diagnostics exclude arbitrary causes and messages');
const replay=service.submit(request('provider-replay','provider-replay'));
const replayResult=await until(replay.id,'blocked');assert.equal(replayResult.requests,1);assert.equal(replayResult.toolCalls,0);
assert.deepEqual(fs.readFileSync(path.join(service.dir(replay.id),'journal.jsonl'),'utf8').trim().split('\n').map(JSON.parse),[{type:'http_response',request:1,status:200}]);
assert.equal(service.submit(request('transport','transport')).finishedAt,failure.finishedAt,'no automatic or duplicate-key replay');
assert.ok(!fs.existsSync(path.join(home,'projects')));
assert.equal(fs.readdirSync(path.join(home,'state')).filter(x=>x.endsWith('.meta')).length,0);
const fresh=new ShortAgents(home,root);assert.equal(fresh.status(accepted.id).state,'completed');
assert.equal(fresh.cancel(accepted.id).state,'completed');
const r={ input:request('reader','read'), materials:[{id:'m1',...snapshot(fixture)}] };
const read=reader(r);
assert.equal((await read('a',{material:'m1',offset:8,bytes:2})).content[0].text,'42');
for(let n=0;n<40;n++)assert.equal((await read('unlimited',{material:'m1',offset:0,bytes:100000})).content[0].text,'value = 42\n');
for(const args of [{material:fixture},{material:'../../etc/passwd'},{material:'m1',write:'bad'},{material:'m1',offset:-1}]) await assert.rejects(()=>read('a',args));
assert.equal(fs.readFileSync(fixture,'utf8'),'value = 42\n');
fs.writeFileSync(fixture,'changed on disk');
assert.equal((await read('snapshot',{material:'m1'})).content[0].text,'value = 42\n');
fs.writeFileSync(fixture,'value = 42\n');
for(const name of ['auth.json','auth.production.json','tokens.json','.env','secret.key','.git-credentials']) {const f=path.join(tmp,name);fs.writeFileSync(f,'sensitive');assert.throws(()=>snapshot(f));}
const link=path.join(tmp,'linked');fs.symlinkSync(fixture,link);assert.throws(()=>snapshot(link), /symlink/);
const hard=path.join(tmp,'hard');fs.linkSync(fixture,hard);assert.throws(()=>snapshot(hard), /single-link/);fs.unlinkSync(hard);
assert.throws(()=>snapshot(tmp+'/sub/../evidence.txt'), /denied/);
const secret=path.join(tmp,'innocent.txt');fs.writeFileSync(secret,'-----BEGIN PRIVATE KEY-----');assert.throws(()=>snapshot(secret), /credential/);
const cancelled=service.submit(request('wait-cancelled','wait'));service.cancel(cancelled.id);
await until(cancelled.id,'cancelled');service.finish(cancelled.id,'completed','late success');assert.equal(service.status(cancelled.id).state,'cancelled');
for(const goal of ['delayed','toolbudget','modelbudget','oversize']) {
 const began=Date.now(),a=service.submit(request('removed-'+goal,goal,{timeMs:1,tools:1,outputTokens:1,requests:1}));
 const result=await until(a.id,'completed');
 assert.ok(!Object.hasOwn(JSON.parse(fs.readFileSync(path.join(service.dir(a.id),'request.json'))).input,'budget'));
 if(goal==='delayed')assert.ok(result.finishedAt-began>=800,'legacy wall budget does not stop execution');
}
const large=service.submit({key:'k'.repeat(200),goal:'large-output'+('g'.repeat(9000)),acceptance:'a'.repeat(5000),materials:Array(5).fill(largeFixture)});
const largeResult=await until(large.id,'completed');assert.equal(largeResult.summary.length,4096);assert.ok(JSON.parse(fs.readFileSync(path.join(service.dir(large.id),'request.json'))).materials[0].content.length>40000);
const legacy=service.submit(request('legacy-readable'),false),legacyFile=path.join(service.dir(legacy.id),'request.json');
const legacyRecord=JSON.parse(fs.readFileSync(legacyFile));legacyRecord.version=1;legacyRecord.input.budget={timeMs:1,tools:1,outputTokens:1,requests:1};fs.writeFileSync(legacyFile,JSON.stringify(legacyRecord));
assert.equal(service.status(legacy.id).state,'accepted','legacy wall budget is ignored');
assert.equal(service.submit(request('legacy-readable')).id,legacy.id,'legacy budget does not change duplicate identity');
assert.equal(service.submit({...request('legacy-readable'),provider:'fixture',model:'fixture'}).id,legacy.id,'historical retry may repeat its original selected identity');
assert.throws(()=>service.submit({...request('legacy-readable'),provider:'fixture',model:'fixture-two'}),/different request/);
assert.ok(!fs.existsSync(path.join(service.dir(legacy.id),'started.json')),'legacy duplicate is never replayed');
fs.writeFileSync(path.join(service.dir(legacy.id),'heartbeat'),'old');fs.utimesSync(path.join(service.dir(legacy.id),'heartbeat'),new Date(0),new Date(0));
assert.equal(service.status(legacy.id).state,'interrupted');
const legacyTerminal=service.submit(request('legacy-terminal'),false),legacyTerminalFile=path.join(service.dir(legacyTerminal.id),'request.json');
const legacyTerminalRecord=JSON.parse(fs.readFileSync(legacyTerminalFile));legacyTerminalRecord.version=1;legacyTerminalRecord.input.budget={timeMs:1000,tools:1,outputTokens:64,requests:1};fs.writeFileSync(legacyTerminalFile,JSON.stringify(legacyTerminalRecord));
service.finish(legacyTerminal.id,'budget','historical budget result');assert.equal(service.status(legacyTerminal.id).state,'budget');
const crash=service.submit(request('crash','crash'));await wait(500);
// Age only the specific crashed lease; do not rely on broad process scans.
const crashDir=service.dir(crash.id);fs.writeFileSync(path.join(crashDir,'heartbeat'),'old');fs.utimesSync(path.join(crashDir,'heartbeat'),new Date(0),new Date(0));
assert.equal(new ShortAgents(home,root).status(crash.id).state,'interrupted');
const lost=service.submit(request('lost'),false);const lostDir=service.dir(lost.id);
fs.writeFileSync(path.join(lostDir,'heartbeat'),'old');fs.utimesSync(path.join(lostDir,'heartbeat'),new Date(0),new Date(0));
assert.equal(fresh.status(lost.id).state,'interrupted');
fs.mkdirSync(path.join(home,'state'),{recursive:true});fs.writeFileSync(path.join(home,'state/.lock'),String(process.pid));
const bashDir=path.join(tmp,'bash-fixture');fs.mkdirSync(bashDir);fs.writeFileSync(path.join(bashDir,'value.txt'),'original');
const bashGrant={authority:'write and verify this disposable fixture only',cwd:bashDir,scope:'Replace value.txt with changed and read it back',exclusions:['No access outside this fixture','No deletion, merge, sync, cleanup, credential use, security change, or service restart'],expiresAt:Date.now()+60000};
const bashTask=service.submit({key:'bash-fixture',goal:'bash-fixture',acceptance:'Write changed to value.txt, then verify its final contents with a separate Bash readback.',materials:[],bash:bashGrant});
const bashResult=await until(bashTask.id,'completed');assert.equal(fs.readFileSync(path.join(bashDir,'value.txt'),'utf8'),'changed');
assert.deepEqual(bashResult.bash.map(({index,state,exitCode})=>({index,state,exitCode})),[{index:0,state:'completed',exitCode:0},{index:1,state:'completed',exitCode:0}]);
const bashStored=JSON.parse(fs.readFileSync(path.join(service.dir(bashTask.id),'request.json')));assert.deepEqual(bashStored.input.bash,bashGrant);
const bashContext=JSON.parse(fs.readFileSync(path.join(service.dir(bashTask.id),'context.json')));assert.deepEqual(bashContext.tools,['read_material','bash']);assert.deepEqual(JSON.parse(bashContext.prompt).bash,bashGrant);assert.equal(bashContext.parentMessages,0);
assert.equal(JSON.parse(fs.readFileSync(path.join(service.dir(bashTask.id),'bash-0.receipt.json'))).output.output,'');
assert.equal(JSON.parse(fs.readFileSync(path.join(service.dir(bashTask.id),'bash-1.receipt.json'))).output.output,'changed');
await service.notify(bashTask.id);const bashOutcome=fs.readFileSync(path.join(home,'state/branch-outcomes.jsonl'),'utf8').trim().split('\n').map(JSON.parse).find(row=>row.task===bashTask.id);assert.match(bashOutcome.summary,/Verified Bash command receipts: 2/);
const {provider:_storedProvider,model:_storedModel,...bashRetryInput}=bashStored.input;
assert.throws(()=>service.submit({...bashRetryInput,bash:{...bashGrant,scope:'a broader scope'}}),/different request/);
const retryDir=path.join(tmp,'bash-retry');fs.mkdirSync(retryDir);const retryInput={...request('bash-retry'),bash:{...bashGrant,cwd:retryDir,expiresAt:Date.now()+10}};const retryTask=service.submit(retryInput,false);fs.rmSync(retryDir,{recursive:true});await wait(20);
assert.equal(service.submit(retryInput).id,retryTask.id,'identical retry survives grant expiry and cwd removal');assert.throws(()=>service.submit({...retryInput,bash:{...retryInput.bash,scope:'changed'}}),/different request/);
assert.throws(()=>service.submit({...request('bash-root'),bash:{...bashGrant,cwd:'/'}}),/non-root canonical/);
assert.throws(()=>service.submit({...request('bash-no-exclusions'),bash:{...bashGrant,exclusions:[]}}),/exclusions/);
assert.throws(()=>service.submit({...request('bash-expired'),bash:{...bashGrant,expiresAt:1}}),/expired/);
assert.throws(()=>service.submit({...request('bash-mixed'),bash:bashGrant,operations:{authority:'fixture',expiresAt:Date.now()+60000,steps:[{action:'sync',project:bashDir}]}}),/cannot be combined/);
const replacedDir=path.join(tmp,'bash-replaced'),replacement=path.join(tmp,'bash-replacement');fs.mkdirSync(replacedDir);fs.mkdirSync(replacement);
const reboundInput={key:'bash-rebound',goal:'bash-fixture',acceptance:'Refuse a changed cwd identity.',materials:[],bash:{...bashGrant,cwd:replacedDir,expiresAt:Date.now()+60000}};
const rebound=service.submit(reboundInput,false);fs.renameSync(replacedDir,replacedDir+'-old');fs.symlinkSync(replacement,replacedDir);execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'_run',home,rebound.id]);const reboundResult=service.status(rebound.id);assert.equal(reboundResult.state,'blocked');assert.match(reboundResult.summary,/working directory identity changed/);assert.deepEqual(reboundResult.bash,[]);
const uncertainInput={key:'bash-uncertain',goal:'bash-uncertain',acceptance:'Preserve uncertain effect evidence.',materials:[],bash:{...bashGrant,expiresAt:Date.now()+60000}};
const uncertain=service.submit(uncertainInput);
const uncertainResult=await until(uncertain.id,'blocked');assert.equal(fs.readFileSync(path.join(bashDir,'uncertain.txt'),'utf8'),'x');assert.equal(uncertainResult.bash[0].state,'uncertain');assert.match(uncertainResult.summary,/effects are uncertain and were not replayed/);
const uncertainAt=uncertainResult.finishedAt;assert.equal(service.submit(uncertainInput).finishedAt,uncertainAt);execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'_run',home,uncertain.id]);assert.equal(fs.readFileSync(path.join(bashDir,'uncertain.txt'),'utf8'),'x','restart does not replay uncertain write');
const cancelInput={key:'bash-cancel',goal:'bash-cancel',acceptance:'Preserve cancellation evidence.',materials:[],bash:{...bashGrant,expiresAt:Date.now()+60000}};
const cancelling=service.submit(cancelInput);for(let n=0;n<200&&!fs.existsSync(path.join(service.dir(cancelling.id),'bash-0.intent.json'));n++)await wait(20);assert.ok(fs.existsSync(path.join(service.dir(cancelling.id),'bash-0.intent.json')));service.cancel(cancelling.id);await wait(500);
const cancelledBash=service.status(cancelling.id);assert.equal(cancelledBash.state,'cancelled');assert.equal(cancelledBash.bash[0].state,'uncertain');assert.equal(fs.readFileSync(path.join(bashDir,'cancelled.txt'),'utf8'),'c');assert.equal(service.submit(cancelInput).finishedAt,cancelledBash.finishedAt,'cancelled write is not replayed');execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'_run',home,cancelling.id]);assert.equal(fs.readFileSync(path.join(bashDir,'cancelled.txt'),'utf8'),'c','restart does not replay cancelled write');
// A duplicate child cannot claim an already-started job or replace its result.
execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'_run',home,accepted.id]);
assert.equal(fresh.status(accepted.id).finishedAt,done.finishedAt);
await Promise.all([service.notify(accepted.id),fresh.notify(accepted.id)]);
let rows=fs.readFileSync(path.join(home,'state/branch-outcomes.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
assert.equal(rows.filter(x=>x.task===accepted.id).length,1);
fs.unlinkSync(path.join(service.dir(accepted.id),'notified.json'));await fresh.notify(accepted.id);
rows=fs.readFileSync(path.join(home,'state/branch-outcomes.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
const row=rows.find(x=>x.task===accepted.id);assert.equal(rows.filter(x=>x.task===accepted.id).length,1);
assert.match(row.summary,/Result:\nanswer 42 m1/);
assert.match(row.summary,/Durable result: .*\/result\.json$/);
assert.ok(!row.summary.includes('Full result:'),'successful notification must not require a result lookup');
await fresh.notify(cancelled.id);
const cancelledRow=fs.readFileSync(path.join(home,'state/branch-outcomes.jsonl'),'utf8').trim().split('\n').map(JSON.parse).find(x=>x.task===cancelled.id);
assert.match(cancelledRow.summary,/cancelled\. Full result:/);
assert.ok(!cancelledRow.summary.includes(': completed.'),'cancellation must not be relabeled successful');
const outcome=args=>execFileSync('bash',[path.join(root,'bin/fm-branch-outcome.sh'),...args],{env:{...process.env,FM_HOME:home,FM_STATE_OVERRIDE:path.join(home,'state')},encoding:'utf8'});
outcome(['mark-read','--through',String(row.seq)]);outcome(['mark-processed','--through',String(row.seq)]);
assert.ok(!outcome(['unprocessed']).includes(accepted.id));
// CLI result/status preserve the full public result across a new process.
const cli=JSON.parse(execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'result',large.id],{env:{...process.env,FM_HOME:home},encoding:'utf8'}));
assert.equal(cli.state,'completed');assert.equal(cli.summary.length,4096);
console.log(JSON.stringify({submitMs:accepted.submitMs,eventLoopTicks:ticks,resultBytes:Buffer.byteLength(JSON.stringify(cli)),before:`${accepted.id}: completed. Full result: ${service.dir(accepted.id)}/result.json`,after:row.summary,noTerminalOrWorktree:true}));
