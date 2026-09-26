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
export const createExtensionRuntime = () => ({});
export const ModelRuntime = { create: async () => ({getAvailable: async () => [{provider:'fixture',id:'fixture'}],streamSimple:async (_m,_c,opts)=> {if(!opts.maxTokens) throw Error('missing provider token cap');}}) };
export const SessionManager = {inMemory: () => ({})};
export const SettingsManager = {inMemory: x => x};
export async function createAgentSession(o) {
 if(o.tools.join() !== 'read_material' || o.resourceLoader.getAgentsFiles().agentsFiles.length || o.resourceLoader.getExtensions().extensions.length) throw Error('isolation violated');
 const messages=[], subscribers=[];
 return {session:{ messages, systemPrompt:o.resourceLoader.getSystemPrompt(), getActiveToolNames:()=>o.tools,

 subscribe: cb=>subscribers.push(cb),dispose(){},getLastAssistantText:()=> 'answer 42 m1',
 async prompt(prompt){
  const goal=JSON.parse(prompt).goal;
  if(goal==='crash') process.exit(19);
  if(goal==='oversize') for(const cb of subscribers) cb({type:'message_update',assistantMessageEvent:{type:'text_delta',delta:'x'.repeat(100)}});
  if(goal==='wait') await new Promise(r=>setTimeout(r,10000));
  if(goal==='delayed') await new Promise(r=>setTimeout(r,1000));
  await o.modelRuntime.streamSimple({}, {}, {});
  if(goal==='modelbudget') await o.modelRuntime.streamSimple({}, {}, {});
  if(goal==='toolbudget') {for(let i=0;i<4;i++) await o.customTools[0].execute('a',{material:'m1'});}
  const result=await o.customTools[0].execute('a',{material:'m1'});
  if(!result.content[0].text.includes('42')) throw Error('fixture missing');
  const message={role:'assistant',stopReason:'stop',content:[{type:'text',text:'42'}]};messages.push(message);
  for(const cb of subscribers) cb({type:'message_end',message});
 }}};
}
`);
const fixture = path.join(tmp, 'evidence.txt'); fs.writeFileSync(fixture, 'value = 42\n');
const service = new ShortAgents(home, root);
const request = (key, goal='delayed', budget={}) => ({key,goal,acceptance:'return value with evidence',provider:'fixture',model:'fixture',materials:[fixture],budget:{timeMs:30000,...budget}});
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
assert.ok(!fs.existsSync(path.join(home,'projects')));
assert.equal(fs.readdirSync(path.join(home,'state')).filter(x=>x.endsWith('.meta')).length,0);
const fresh=new ShortAgents(home,root);assert.equal(fresh.status(accepted.id).state,'completed');
assert.equal(fresh.cancel(accepted.id).state,'completed');
const r={ input:request('reader','read',{tools:20}), materials:[{id:'m1',...snapshot(fixture)}] };
const read=reader(r);
assert.equal((await read('a',{material:'m1',offset:8,bytes:2})).content[0].text,'42');
for(const args of [{material:fixture},{material:'../../etc/passwd'},{material:'m1',write:'bad'},{material:'m1',bytes:999999},{material:'m1',offset:-1}]) await assert.rejects(()=>read('a',args));
assert.equal(fs.readFileSync(fixture,'utf8'),'value = 42\n');
fs.writeFileSync(fixture,'changed on disk');
assert.equal((await read('snapshot',{material:'m1'})).content[0].text,'value = 42\n');
fs.writeFileSync(fixture,'value = 42\n');
for(const name of ['auth.json','auth.production.json','tokens.json','.env','secret.key','.git-credentials']) {const f=path.join(tmp,name);fs.writeFileSync(f,'sensitive');assert.throws(()=>snapshot(f));}
const link=path.join(tmp,'linked');fs.symlinkSync(fixture,link);assert.throws(()=>snapshot(link), /symlink/);
const hard=path.join(tmp,'hard');fs.linkSync(fixture,hard);assert.throws(()=>snapshot(hard), /single-link/);fs.unlinkSync(hard);
assert.throws(()=>snapshot(tmp+'/sub/../evidence.txt'), /denied/);
const secret=path.join(tmp,'innocent.txt');fs.writeFileSync(secret,'-----BEGIN PRIVATE KEY-----');assert.throws(()=>snapshot(secret), /credential/);
for(const [goal,state,budget] of [['wait','cancelled',{}],['wait','timeout',{timeMs:1000}],['toolbudget','budget',{tools:1}],['modelbudget','budget',{outputTokens:64}],['oversize','budget',{outputTokens:64}]]) {
 const a=service.submit(request(goal+state,goal,budget));if(state==='cancelled')service.cancel(a.id);
 await until(a.id,state);service.finish(a.id,'completed','late success');assert.equal(service.status(a.id).state,state);
}
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
// CLI result/status preserve the bounded public contract across a new process.
const cli=JSON.parse(execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'result',accepted.id],{env:{...process.env,FM_HOME:home},encoding:'utf8'}));
assert.equal(cli.state,'completed');assert.ok(Buffer.byteLength(JSON.stringify(cli))<4096);
console.log(JSON.stringify({submitMs:accepted.submitMs,eventLoopTicks:ticks,resultBytes:Buffer.byteLength(JSON.stringify(cli)),noTerminalOrWorktree:true}));
