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
${pluginFixture(pkg)}
export const createExtensionRuntime = () => ({});
export const ModelRuntime = { create: async () => ({provider:{},getProvider(){return this.provider;},getAvailable: async () => [{provider:'fixture',id:'fixture'}],streamSimple:async (_m,_c,opts)=> {
 if(Object.hasOwn(opts,'maxTokens')) throw Error('application output cap still present');
 if(_c.transport) await opts.fetch('https://unused.invalid');
 if(_c.replay) {await opts.fetch();await opts.fetch();}
}}) };
export const SessionManager = {inMemory: () => ({getBranch:()=>[]})};
export const SettingsManager = {inMemory: x => ({...x,getCacheWarmingMode:()=>x.cacheWarming})};
export async function createAgentSession(o) {
 if(o.tools.join() !== 'read_material' || o.resourceLoader.getAgentsFiles().agentsFiles.length || o.resourceLoader.getExtensions().extensions.length!==1) throw Error('isolation violated');
 if(o.settingsManager.getCacheWarmingMode() !== 'off') throw Error('cache warming enabled');
 const messages=[], subscribers=[];let answer='answer 42 m1';
 return {session:{ messages, systemPrompt:o.resourceLoader.getSystemPrompt(), getActiveToolNames:()=>o.tools,async bindExtensions(options){if(process.env.FM_FIXTURE_BIND_ERROR)options.onError({event:'session_start',error:'fixture'});o.modelRuntime.provider={};},

 subscribe: cb=>subscribers.push(cb),dispose(){},getLastAssistantText:()=>answer,
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
  if(goal.startsWith('large-output')) answer='x'.repeat(4096);
  const result=await o.customTools[0].execute('a',{material:'m1'});
  if(!result.content[0].text.includes('42')) throw Error('fixture missing');
  const message={role:'assistant',stopReason:'stop',content:[{type:'text',text:'42'}]};messages.push(message);
  for(const cb of subscribers) cb({type:'message_end',message});
 }}};
}
`);
const fixture = path.join(tmp, 'evidence.txt'); fs.writeFileSync(fixture, 'value = 42\n');
const largeFixture = path.join(tmp, 'large-evidence.txt'); fs.writeFileSync(largeFixture, 'value = 42\n' + 'x'.repeat(40000));
const service = new ShortAgents(home, root);
const request = (key, goal='delayed', budget) => ({key,goal,acceptance:'return value with evidence',provider:'fixture',model:'fixture',materials:[fixture],...(budget ? {budget} : {})});
const accepted = service.submit(request('one'));
assert.equal(accepted.state, 'accepted'); assert.ok(accepted.submitMs < 1000);
assert.equal(service.submit(request('one')).id, accepted.id);
assert.throws(()=>service.submit(request('one','different')), /different request/);
assert.throws(()=>service.status('../escape'), /invalid/);
let ticks=0; const tick=setInterval(()=>ticks++,10);
const until = async (id, state) => {for(let n=0;n<200;n++){const s=service.status(id);if(s.state===state)return s;await wait(50);}throw Error('did not reach '+state+' '+JSON.stringify(service.status(id)));};
const done=await until(accepted.id,'completed'); clearInterval(tick); assert.ok(ticks>20);
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
const large=service.submit({key:'k'.repeat(200),goal:'large-output'+('g'.repeat(9000)),acceptance:'a'.repeat(5000),provider:'fixture',model:'fixture',materials:Array(5).fill(largeFixture)});
const largeResult=await until(large.id,'completed');assert.equal(largeResult.summary.length,4096);assert.ok(JSON.parse(fs.readFileSync(path.join(service.dir(large.id),'request.json'))).materials[0].content.length>40000);
const legacy=service.submit(request('legacy-readable'),false),legacyFile=path.join(service.dir(legacy.id),'request.json');
const legacyRecord=JSON.parse(fs.readFileSync(legacyFile));legacyRecord.version=1;legacyRecord.input.budget={timeMs:1,tools:1,outputTokens:1,requests:1};fs.writeFileSync(legacyFile,JSON.stringify(legacyRecord));
assert.equal(service.status(legacy.id).state,'accepted','legacy wall budget is ignored');
assert.equal(service.submit(request('legacy-readable')).id,legacy.id,'legacy budget does not change duplicate identity');
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
// A duplicate child cannot claim an already-started job or replace its result.
execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'_run',home,accepted.id]);
assert.equal(fresh.status(accepted.id).finishedAt,done.finishedAt);
await Promise.all([service.notify(accepted.id),fresh.notify(accepted.id)]);
let rows=fs.readFileSync(path.join(home,'state/branch-outcomes.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
assert.equal(rows.filter(x=>x.task===accepted.id).length,1);
fs.unlinkSync(path.join(service.dir(accepted.id),'notified.json'));await fresh.notify(accepted.id);
rows=fs.readFileSync(path.join(home,'state/branch-outcomes.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
const row=rows.find(x=>x.task===accepted.id);assert.equal(rows.filter(x=>x.task===accepted.id).length,1);
const outcome=args=>execFileSync('bash',[path.join(root,'bin/fm-branch-outcome.sh'),...args],{env:{...process.env,FM_HOME:home,FM_STATE_OVERRIDE:path.join(home,'state')},encoding:'utf8'});
outcome(['mark-read','--through',String(row.seq)]);outcome(['mark-processed','--through',String(row.seq)]);
assert.ok(!outcome(['unprocessed']).includes(accepted.id));
// CLI result/status preserve the full public result across a new process.
const cli=JSON.parse(execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'result',large.id],{env:{...process.env,FM_HOME:home},encoding:'utf8'}));
assert.equal(cli.state,'completed');assert.equal(cli.summary.length,4096);
console.log(JSON.stringify({submitMs:accepted.submitMs,eventLoopTicks:ticks,resultBytes:Buffer.byteLength(JSON.stringify(cli)),noTerminalOrWorktree:true}));
