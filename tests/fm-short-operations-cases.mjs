import { pluginFixture } from './fm-short-plugin-fixture.mjs';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {execFile,execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const [root,tmp]=process.argv.slice(2);
const {ShortAgents,validate}=await import(pathToFileURL(path.join(root,'bin/fm-short-agent.mjs')));
const {resource,processIdentity,bindOperations,settleMergeReceipt}=await import(pathToFileURL(path.join(root,'bin/fm-short-operations.mjs')));
const home=path.join(tmp,'home'),pkg=path.join(tmp,'sdk');
fs.mkdirSync(path.join(home,'state'),{recursive:true});
fs.writeFileSync(path.join(home,'state/.lock'),String(process.pid));
fs.mkdirSync(path.join(pkg,'dist/core'),{recursive:true});
fs.writeFileSync(path.join(pkg,'package.json'),JSON.stringify({name:'@earendil-works/pi-coding-agent',main:'dist/index.js',type:'module'}));
fs.writeFileSync(path.join(pkg,'dist/core/http-dispatcher.js'),'export function configureHttpDispatcher() {}');
fs.writeFileSync(path.join(pkg,'dist/index.js'),`
${pluginFixture(pkg)}
export const createExtensionRuntime=()=>({});
export const ModelRuntime={create:async()=>({provider:{},getProvider(){return this.provider;},getAvailable:async()=>[{provider:'openai-codex',id:'gpt-5.6-luna'}],streamSimple:async(_m,c,opts)=>{if(c.fail) await opts.fetch();}})};
export const SessionManager={inMemory:()=>({getBranch:()=>[]})};
export const SettingsManager={inMemory:x=>x};
export async function createAgentSession(o) {
 const messages=[];
 return {session:{messages,systemPrompt:o.resourceLoader.getSystemPrompt(),getActiveToolNames:()=>o.tools,async bindExtensions(options){if(process.env.FM_FIXTURE_BIND_ERROR)options.onError({event:'session_start',error:'fixture'});o.modelRuntime.provider={};},subscribe(){},dispose(){},getLastAssistantText:()=> 'complete',
 async prompt(prompt) {
  const p=JSON.parse(prompt);
  const transportFailure=()=>o.modelRuntime.streamSimple({}, {fail:true}, {fetch:async()=>{throw new TypeError('fetch failed',{cause:Object.assign(new Error('hidden'),{code:'ECONNRESET'})});}});
  if(p.goal==='transport-before') await transportFailure();
  if(p.goal.startsWith('delay')) await new Promise(r=>setTimeout(r,500));
  await o.modelRuntime.streamSimple({}, {}, {});
  const tool=o.customTools.find(t=>t.name==='run_operations');
  if(!tool) throw Error('operations absent');
  const first=await tool.execute('op',p.goal==='inject'?{command:'touch BAD'}:{});
  if(p.goal==='transport-after') await transportFailure();
  if(p.goal==='repeat' && JSON.stringify(await tool.execute('again',{}))!==JSON.stringify(first)) throw Error('receipt replay changed');
  messages.push({role:'assistant',stopReason:'stop'});
 }}};
}
`);
process.env.FM_PI_PACKAGE_DIR=pkg;
process.env.GIT_CONFIG_NOSYSTEM='1';process.env.GIT_CONFIG_GLOBAL='/dev/null';
for(const role of ['AUTHOR','COMMITTER']) {process.env[`GIT_${role}_NAME`]='test';process.env[`GIT_${role}_EMAIL`]='test@example.invalid';}
const git=(...a)=>execFileSync('git',a,{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();
const remote=path.join(tmp,'remote.git'), seed=path.join(tmp,'seed'),project=path.join(tmp,'project');
git('init','--bare','--initial-branch=main',remote);git('clone',remote,seed);
fs.writeFileSync(path.join(seed,'one'),'1');git('-C',seed,'add','.');git('-C',seed,'commit','-m','one');git('-C',seed,'push','origin','main');git('clone',remote,project);
const old=git('-C',project,'rev-parse','HEAD');
fs.writeFileSync(path.join(seed,'one'),'2');git('-C',seed,'commit','-am','two');git('-C',seed,'push','origin','main');const expected=git('-C',seed,'rev-parse','HEAD');
const service=new ShortAgents(home,root);
const submittedIds=new Set(), originalSubmit=service.submit.bind(service);
service.submit=(...args)=>{const result=originalSubmit(...args);submittedIds.add(result.id);return result;};
const req=(key,steps=[{action:'sync',project}],goal='run')=>({key,goal,acceptance:'owner receipt',materials:[],operations:{authority:'isolated test fixture',expiresAt:Date.now()+60000,steps}});
const wait=ms=>new Promise(r=>setTimeout(r,ms));
async function terminal(id){for(let n=0;n<12000;n++){const s=service.status(id);if(s.finishedAt)return s;await wait(25);}throw Error('task did not terminate');}
assert.equal(validate({key:'default',goal:'read',acceptance:'answer',materials:[]}).model,'gpt-5.6-luna');
assert.equal(validate({key:'override',goal:'read',acceptance:'answer',materials:[],provider:'explicit',model:'chosen'}).provider,'explicit');
assert.throws(()=>service.submit(req('unknown',[{action:'restart',task:'foo'}])),/unsupported/);
const missingAuthority=req('no-authority');delete missingAuthority.operations.authority;assert.throws(()=>service.submit(missingAuthority),/authority/);
fs.writeFileSync(path.join(home,'state/.lock'),'1');assert.throws(()=>service.submit(req('wrong-primary')),/primary/);fs.writeFileSync(path.join(home,'state/.lock'),String(process.pid));
const expired=req('expired');expired.operations.expiresAt=1;assert.throws(()=>service.submit(expired),/expired/);
const initProject=path.join(tmp,'plugin-init-project');git('clone',remote,initProject);const initBefore=git('-C',initProject,'rev-parse','HEAD');
process.env.FM_FIXTURE_BIND_ERROR='1';
const initFailure=service.submit(req('plugin-init-failure',[{action:'sync',project:initProject}]));
delete process.env.FM_FIXTURE_BIND_ERROR;
const initResult=await terminal(initFailure.id);
assert.equal(initResult.state,'blocked');assert.equal(initResult.stage,'plugin-initialization');assert.equal(initResult.requests,0);assert.equal(initResult.toolCalls,0);
assert.ok(!fs.existsSync(path.join(service.dir(initFailure.id),'operation-0.intent.json')));assert.ok(!fs.existsSync(path.join(service.dir(initFailure.id),'operation-0.receipt.json')));
assert.equal(git('-C',initProject,'rev-parse','HEAD'),initBefore,'plugin initialization failure made no operation effect');
const request={...req('sync'),budget:{timeMs:1,tools:1,outputTokens:1,requests:1}};const operationBegan=Date.now(),a=service.submit(request);assert.equal(service.submit(request).id,a.id);
assert.equal(git('-C',project,'rev-parse','HEAD'),old,'submit did not execute the effect');
const done=await terminal(a.id);assert.equal(done.state,'completed',JSON.stringify(done));assert.ok(done.finishedAt-operationBegan>1,'legacy wall budget does not stop an operation');assert.ok(!Object.hasOwn(JSON.parse(fs.readFileSync(path.join(service.dir(a.id),'request.json'))).input,'budget'));
assert.equal(git('-C',project,'rev-parse','HEAD'),expected);
const receipts=done.operations;assert.deepEqual(receipts,[{index:0,action:'sync',state:'completed'}]);
assert.ok(!fs.existsSync(resource(home,request.operations.steps[0]).file));
const child=JSON.parse(fs.readFileSync(path.join(service.dir(a.id),'started.json')));assert.notEqual(child.pid,process.pid);
const receipt=JSON.parse(fs.readFileSync(path.join(service.dir(a.id),'operation-0.receipt.json')));assert.notEqual(receipt.executor.pid,process.pid);assert.equal(receipt.evidence.head,expected);
assert.equal(new ShortAgents(home,root).submit(request).id,a.id);
const replay=await terminal(a.id);assert.equal(replay.finishedAt,done.finishedAt);
for(const when of ['before','after']) {
 const input=req('transport-'+when,undefined,'transport-'+when), accepted=service.submit(input);
 const failed=await terminal(accepted.id);assert.equal(failed.state,'blocked');
 assert.equal(failed.toolCalls,when==='before'?0:1);assert.equal(failed.requests,when==='before'?1:2);
 const dir=service.dir(accepted.id), receiptFile=path.join(dir,'operation-0.receipt.json');
 assert.equal(fs.existsSync(path.join(dir,'operation-0.intent.json')),when==='after');
 if(when==='after') assert.equal(JSON.parse(fs.readFileSync(receiptFile)).state,'completed');
 const events=fs.readFileSync(path.join(dir,'journal.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
 assert.deepEqual(events.filter(e=>e.type==='transport_error').map(e=>e.toolsStarted),[when==='before'?0:1]);
 const receiptBefore=fs.existsSync(receiptFile)?fs.readFileSync(receiptFile,'utf8'):null;
 assert.equal(service.submit(input).finishedAt,failed.finishedAt);
 await service.reconcile();
 assert.equal(fs.existsSync(receiptFile)?fs.readFileSync(receiptFile,'utf8'):null,receiptBefore,'transport failure never replays effects');
}
const inject=service.submit(req('inject',undefined,'inject'));assert.equal((await terminal(inject.id)).state,'blocked');
assert.ok(!fs.existsSync(path.join(service.dir(inject.id),'operation-0.intent.json')));
const cancelled=service.submit(req('cancel',undefined,'delay'));service.cancel(cancelled.id);await wait(700);assert.equal(service.status(cancelled.id).state,'cancelled');assert.ok(!fs.existsSync(path.join(service.dir(cancelled.id),'operation-0.intent.json')));
fs.writeFileSync(path.join(project,'dirty'),'preserve');
const dirty=service.submit(req('dirty'));assert.equal((await terminal(dirty.id)).state,'blocked');assert.equal(fs.readFileSync(path.join(project,'dirty'),'utf8'),'preserve');fs.unlinkSync(path.join(project,'dirty'));
git('-C',project,'checkout','--detach',old);
const recovery=service.submit(req('recover',[{action:'recover-sync',project}]));assert.equal((await terminal(recovery.id)).state,'completed');assert.equal(git('-C',project,'symbolic-ref','--short','HEAD'),'main');assert.equal(git('-C',project,'rev-parse','HEAD'),expected);
// Source material cannot grant a tool or alter any bound operation.
const invalid=req('badargs',[{action:'sync',project,command:'true'}]);assert.throws(()=>service.submit(invalid),/fields/);
const spoof=execFileSync('bash',['-c',`if FM_SUPERVISION_ACTOR=short FM_HOME="$1" bash "$2/bin/fm-fleet-sync.sh" "$3" >"$1/spoof.log" 2>&1; then exit 9; fi`,'fixture',home,root,project],{encoding:'utf8'});assert.equal(spoof,'');

// The real merge owner talks only to this controlled forge executable.
// Merge mutates a fixture record; its status/get responses use official shapes.
const fakebin=path.join(tmp,'fakebin');fs.mkdirSync(fakebin);fs.writeFileSync(path.join(fakebin,'package.json'),'{"type":"commonjs"}');
const forge=path.join(tmp,'forge.json');
fs.writeFileSync(forge,JSON.stringify({merged:false,calls:0,red:false,lost:false}));
process.env.FM_SHORT_TEST_FORGE=forge;
fs.writeFileSync(path.join(fakebin,'bytedcli'),`#!/usr/bin/env node
const fs=require('fs');const f=process.env.FM_SHORT_TEST_FORGE,s=JSON.parse(fs.readFileSync(f));
const verb=process.argv[5];let head='c'.repeat(40);if(verb==='status'){s.statusReads=(s.statusReads||0)+1;fs.writeFileSync(f,JSON.stringify(s));if(s.statusDelayMs)Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,s.statusDelayMs);if(s.bad){console.log('null');process.exit(0);}if(s.changed&&s.statusReads>1)head='d'.repeat(40);}
const url='https://code.byted.org/example/shortlab/merge_requests/7';
if(verb==='merge'){s.calls++;s.merged=true;fs.writeFileSync(f,JSON.stringify(s));if(s.crash){
 const path=require('path'),effect=JSON.parse(fs.readFileSync(path.join(process.env.FM_HOME,'state/short-agents',process.env.FM_SHORT_TASK,'operation-0.effect.json')));
 const cmd=fs.readFileSync('/proc/'+effect.owner.pid+'/cmdline','utf8');
 if(!cmd.includes('/bin/fm-pr-merge.sh'))throw Error('refuse killing an unverified fixture owner');
 process.kill(effect.owner.pid,'SIGKILL');process.exit(9);
}if(s.lost)process.exit(9);console.log(JSON.stringify({status:'success',data:{merged:true}}));}
else if(verb==='status') console.log(JSON.stringify({status:'success',data:{repository:{path:'example/shortlab'},merge_request:{id:s.statusMissingId?undefined:'123',number:7,status:s.merged?'merged':'open',url,source_branch:'topic',target_branch:s.statusTarget||'main',source_commit_id:head},mergeability:{mergeable:!s.red,checks:[{passed:!s.red}],failed_checks:s.red?['red']:[]},review:{status:'passed'},check_runs:{summary:'no_checks',total_count:0,page_size:100,passed_count:0,failed_count:0,running_count:0,items:[]}}}));
else if(verb==='get'){if(s.getDelayMs)Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,s.getDelayMs);if(s.getFails)process.exit(9);console.log(JSON.stringify(s.getMalformed?{status:'success',data:[]}:{status:'success',data:{repository:{path:s.getRepo||'example/shortlab'},merge_request:{Id:s.getId||'123',Number:7,Status:s.merged?'merged':'open',URL:s.getUrl||url,SourceBranchName:'topic',TargetBranchName:s.getTarget||'main',MergeCommitId:s.getMerge||'d'.repeat(40)},version:{SourceCommitId:s.getHead||head}}}));}
else process.exit(2);
`,{mode:0o755});
const timeoutHook=path.join(tmp,'short-readback-timeout-hook.mjs');
fs.writeFileSync(timeoutHook,`import childProcess from 'node:child_process';
import fs from 'node:fs';
import {syncBuiltinESMExports} from 'node:module';
const original=childProcess.execFileSync;
childProcess.execFileSync=function(command,args,options={}) {
  if(command==='bash'&&Array.isArray(args)&&args.includes('short-merge-readback')) {
    fs.writeFileSync(process.env.FM_SHORT_TIMEOUT_PROBE,String(options.timeout));
    return original.call(this,command,args,{...options,timeout:50});
  }
  return original.call(this,command,args,options);
};
syncBuiltinESMExports();
`);
process.env.PATH=fakebin+path.delimiter+process.env.PATH;
fs.mkdirSync(path.join(home,'data'),{recursive:true});fs.mkdirSync(path.join(home,'config'),{recursive:true});
fs.writeFileSync(path.join(home,'data/backlog.md'),'## In flight\n\n## Queued\n\n## Done\n');
fs.writeFileSync(path.join(home,'config/backlog-backend'),'manual\n');
const writeTask=(name)=>fs.writeFileSync(path.join(home,'state',name+'.meta'),`kind=ship\nmode=no-mistakes\nspawn_gen=g1\nwindow=unused-fixture\nworktree=${tmp}/absent\nproject=${project}\npr=https://code.byted.org/example/shortlab/merge_requests/7\npr_head=${'c'.repeat(40)}\n`);
writeTask('audit-reader');
const auditFile=path.join(home,'state/audit-reader.meta'),baseMeta=fs.readFileSync(auditFile,'utf8');
const auditStep={action:'merge',task:'audit-reader',url:'https://code.byted.org/example/shortlab/merge_requests/7'};
const bindAudit=()=>bindOperations(home,validate(req('audit-reader',[auditStep])).operations);
const legacyAudit='decisions_reviewed=1\ndecision_keys=\ndecisions_reviewed=1\ndecision_keys=choice-a\ndecisions_reviewed=1\ndecision_keys=choice-a,choice-b\n';
fs.writeFileSync(auditFile,baseMeta+legacyAudit);assert.equal(bindAudit().length,1,'legacy monotone audit pairs are compatible');
for(const [field,value] of [['spawn_gen','g1'],['backend','herdr'],['window','unused-fixture'],['herdr_pane_id','w1:p1'],['endpoint_task_id','audit-reader'],['project',project],['worktree',tmp+'/absent'],['pr_head','c'.repeat(40)],['authority','same'],['__proto__','same']]) {
 const single=baseMeta.includes(field+'=')?baseMeta:baseMeta+field+'='+value+'\n';
 fs.writeFileSync(auditFile,single+legacyAudit+field+'='+value+'\n');assert.throws(bindAudit,/duplicate task metadata field/,field);
}
for(const invalid of [
 'decisions_reviewed=1\ndecisions_reviewed=1\n',
 'decisions_reviewed=1\ndecision_keys=a\ndecisions_reviewed=1\ndecision_keys=\n',
 'decisions_reviewed=0\ndecision_keys=\ndecisions_reviewed=1\ndecision_keys=a\n',
 'decisions_reviewed=1\ndecision_keys=\ndecision_keys=a\n',
 'decisions_reviewed=1\ndecision_keys=\ndecisions_reviewed=1\ndecision_keys=a,a\n',
]) {fs.writeFileSync(auditFile,baseMeta+invalid);assert.throws(bindAudit,/duplicate task metadata field|ambiguous completion audit history/);}
fs.writeFileSync(auditFile,baseMeta+legacyAudit);
writeTask('merge-one');
const mergeStep={action:'merge',task:'merge-one',url:'https://code.byted.org/example/shortlab/merge_requests/7'};
const expectedMergeCommit='d'.repeat(40);
writeTask('merge-leased');
const lease=command=>execFileSync('bash',[path.join(root,'bin/fm-lease.sh'),command,'merge-leased','--actor','main'],{env:{...process.env,FM_HOME:home,FM_STATE_OVERRIDE:path.join(home,'state'),FM_SUPERVISION_ACTOR:'main'},stdio:'pipe'});
lease('claim');
const leased=service.submit(req('leased',[{...mergeStep,task:'merge-leased'}]));assert.equal((await terminal(leased.id)).state,'blocked');assert.equal(JSON.parse(fs.readFileSync(forge)).calls,0);lease('release');
assert.throws(()=>service.submit(req('unsupported-cleanup',[{action:'cleanup',task:'merge-one'}])),/backend is unsupported/);
const merged=service.submit(req('merge-sync',[mergeStep,{action:'sync',project}]));
assert.equal((await terminal(merged.id)).state,'completed',JSON.stringify(service.status(merged.id)));
assert.equal(JSON.parse(fs.readFileSync(forge)).calls,1);
const mergeReceipt=JSON.parse(fs.readFileSync(path.join(service.dir(merged.id),'operation-0.receipt.json')));assert.equal(mergeReceipt.evidence.head,'c'.repeat(40));
// Provider accepted the merge but lost its response: owner readback proves it,
// so the chain succeeds without issuing the merge again.
fs.writeFileSync(forge,JSON.stringify({merged:false,calls:0,red:false,lost:true}));writeTask('merge-lost');
const lost=service.submit(req('merge-lost',[{...mergeStep,task:'merge-lost'}]));
assert.equal((await terminal(lost.id)).state,'completed',JSON.stringify(service.status(lost.id)));
assert.equal(JSON.parse(fs.readFileSync(forge)).calls,1);
fs.writeFileSync(forge,JSON.stringify({merged:false,calls:0,red:true,lost:false}));writeTask('merge-red');
const red=service.submit(req('merge-red',[{...mergeStep,task:'merge-red'}]));assert.equal((await terminal(red.id)).state,'blocked');assert.equal(JSON.parse(fs.readFileSync(forge)).calls,0);

for(const [name,flag] of [['malformed','bad'],['changed-head','changed']]) {
  writeTask(name);fs.writeFileSync(forge,JSON.stringify({merged:false,calls:0,[flag]:true}));
  const denied=service.submit(req(name,[{...mergeStep,task:name}]));assert.equal((await terminal(denied.id)).state,'blocked');assert.equal(JSON.parse(fs.readFileSync(forge)).calls,0);
}
// Kill only this fixture's verified owner after the forged external effect.
// Restart retains uncertainty and never repeats that possibly completed merge.
writeTask('merge-crash');fs.writeFileSync(forge,JSON.stringify({merged:false,calls:0,crash:true}));
const crashRequest=req('crash-effect',[{...mergeStep,task:'merge-crash'}]);const crashed=service.submit(crashRequest);
assert.equal((await terminal(crashed.id)).state,'blocked');assert.equal(JSON.parse(fs.readFileSync(forge)).calls,1);
await new ShortAgents(home,root).reconcile();assert.equal(new ShortAgents(home,root).submit(crashRequest).state,'blocked');assert.equal(JSON.parse(fs.readFileSync(forge)).calls,1);assert.ok(fs.existsSync(resource(home,crashRequest.operations.steps[0]).file));
const crashedDir=service.dir(crashed.id),crashedEffect=JSON.parse(fs.readFileSync(path.join(crashedDir,'operation-0.effect.json')));
const crashedMarkers=[resource(home,crashRequest.operations.steps[0]),{target:`merge:${mergeStep.url}`,file:path.join(home,'state',`.short-merge-${createHash('sha256').update(mergeStep.url).digest('hex')}.json`)}];
for(const marker of crashedMarkers)assert.ok(fs.existsSync(marker.file),'blocked lifecycle retains exact reservation');
const settleCallsBefore=JSON.parse(fs.readFileSync(forge)).calls;
const crashedResultBefore=fs.readFileSync(path.join(crashedDir,'result.json'),'utf8');
const settled=JSON.parse(execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'settle-merge',crashed.id,`0:${expectedMergeCommit}`],{encoding:'utf8',env:{...process.env,FM_HOME:home}}));
assert.deepEqual(settled.evidence,{head:'c'.repeat(40),mergeCommit:'d'.repeat(40)});assert.equal(settled.result,'blocked');assert.equal(settled.reservationsReleased,2);
assert.equal(JSON.parse(fs.readFileSync(forge)).calls,settleCallsBefore,'settlement issued no merge');
for(const marker of crashedMarkers)assert.ok(!fs.existsSync(marker.file),'settlement released only matching reservation');
const settledReceipt=JSON.parse(fs.readFileSync(path.join(crashedDir,'operation-0.receipt.json')));
assert.equal(settledReceipt.settlement,'dead-owner-codebase-readback');assert.deepEqual(settledReceipt.effectExecutor,crashedEffect.owner);assert.equal(service.status(crashed.id).state,'blocked');
assert.equal(fs.readFileSync(path.join(crashedDir,'result.json'),'utf8'),crashedResultBefore,'settlement retains the original failed model result');
fs.writeFileSync(crashedMarkers[0].file,JSON.stringify({home,id:crashed.id,nonce:JSON.parse(fs.readFileSync(path.join(crashedDir,'request.json'))).nonce,index:0,target:crashedMarkers[0].target}));
assert.deepEqual(settleMergeReceipt(home,root,crashed.id,0,expectedMergeCommit),settled,'repeated settlement converges');
assert.ok(!fs.existsSync(crashedMarkers[0].file),'retry finishes reservation cleanup after receipt publication');
writeTask('merge-settle-refusal');fs.writeFileSync(forge,JSON.stringify({merged:false,calls:0,crash:true}));
const refusalRequest=req('settle-refusal',[{...mergeStep,task:'merge-settle-refusal'}]),refusal=service.submit(refusalRequest);
assert.equal((await terminal(refusal.id)).state,'blocked');const refusalDir=service.dir(refusal.id),refusalMarker=resource(home,refusalRequest.operations.steps[0]).file;
const refusalRunner=JSON.parse(fs.readFileSync(path.join(refusalDir,'started.json'))).identity;
for(let n=0;n<400;n++){try{if(processIdentity(refusalRunner.pid).start!==refusalRunner.start)break;}catch{break;}if(n===399)throw Error('refusal fixture runner did not exit');await wait(25);}
const refusalEffectPath=path.join(refusalDir,'operation-0.effect.json'),refusalEffectText=fs.readFileSync(refusalEffectPath,'utf8');
const refusalStartedPath=path.join(refusalDir,'started.json'),refusalStartedText=fs.readFileSync(refusalStartedPath,'utf8'),liveRunner=processIdentity(process.pid);
const settleRefusalCli=()=>execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'settle-merge',refusal.id,`0:${expectedMergeCommit}`],{encoding:'utf8',env:{...process.env,FM_HOME:home}});
fs.writeFileSync(refusalStartedPath,JSON.stringify({...JSON.parse(refusalStartedText),pid:liveRunner.pid,identity:liveRunner}));assert.throws(()=>settleMergeReceipt(home,root,refusal.id,0,expectedMergeCommit),/runner to be dead/);fs.writeFileSync(refusalStartedPath,refusalStartedText);
fs.writeFileSync(forge,JSON.stringify({merged:false,calls:1}));assert.throws(()=>settleMergeReceipt(home,root,refusal.id,0,expectedMergeCommit),/not merged|readback refused/i);assert.ok(fs.existsSync(refusalMarker));
fs.writeFileSync(forge,JSON.stringify({merged:true,calls:1,getFails:true}));assert.throws(()=>settleMergeReceipt(home,root,refusal.id,0,expectedMergeCommit),/could not be confirmed|readback refused/i);assert.ok(fs.existsSync(refusalMarker));
fs.writeFileSync(forge,JSON.stringify({merged:true,calls:1,getHead:'e'.repeat(40)}));assert.throws(()=>settleMergeReceipt(home,root,refusal.id,0,expectedMergeCommit),/source head|readback refused/i);assert.ok(fs.existsSync(refusalMarker));
fs.writeFileSync(forge,JSON.stringify({merged:true,calls:1,getMalformed:true}));assert.throws(()=>settleMergeReceipt(home,root,refusal.id,0,expectedMergeCommit),/could not be confirmed|readback refused/i);assert.ok(fs.existsSync(refusalMarker));
fs.writeFileSync(forge,JSON.stringify({merged:true,calls:1}));assert.throws(()=>settleMergeReceipt(home,root,refusal.id,0,'f'.repeat(40)),/merge commit does not match/);assert.ok(fs.existsSync(refusalMarker));
const mismatchedMarker=JSON.parse(fs.readFileSync(refusalMarker));fs.writeFileSync(refusalMarker,JSON.stringify({...mismatchedMarker,nonce:'wrong'}));assert.throws(()=>settleMergeReceipt(home,root,refusal.id,0,expectedMergeCommit),/reservation identity changed/);fs.writeFileSync(refusalMarker,JSON.stringify(mismatchedMarker));
const refusalEffect=JSON.parse(refusalEffectText),live=processIdentity(process.pid);fs.writeFileSync(refusalEffectPath,JSON.stringify({...refusalEffect,owner:{...live,parent:JSON.parse(fs.readFileSync(path.join(refusalDir,'started.json'))).pid}}));assert.throws(()=>settleMergeReceipt(home,root,refusal.id,0,expectedMergeCommit),/executor to be dead/);fs.writeFileSync(refusalEffectPath,refusalEffectText);
fs.writeFileSync(forge,JSON.stringify({merged:true,calls:1,getRepo:'other/repo'}));assert.throws(()=>settleMergeReceipt(home,root,refusal.id,0,expectedMergeCommit),/repository.*changed|readback refused/i);assert.ok(fs.existsSync(refusalMarker));
for(const identityFailure of [{statusMissingId:true},{getId:'other-id'},{getTarget:'release'}]) {
 fs.writeFileSync(forge,JSON.stringify({merged:true,calls:1,...identityFailure}));assert.throws(settleRefusalCli,/identity.*changed|could not be confirmed|readback refused/i);assert.ok(fs.existsSync(refusalMarker));assert.ok(!fs.existsSync(path.join(refusalDir,'operation-0.receipt.json')));
}
const timeoutProbe=path.join(tmp,'short-readback-timeout-probe');
fs.writeFileSync(forge,JSON.stringify({merged:true,calls:1,statusDelayMs:5000}));
const timeoutProtectedFiles=[path.join(refusalDir,'request.json'),path.join(refusalDir,'result.json'),refusalEffectPath,refusalMarker,crashedMarkers[1].file];
const timeoutProtectedBytes=timeoutProtectedFiles.map(file=>fs.readFileSync(file,'utf8'));
const timeoutAt=Date.now();
assert.throws(()=>execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'settle-merge',refusal.id,`0:${expectedMergeCommit}`],{encoding:'utf8',env:{...process.env,FM_HOME:home,NODE_OPTIONS:`--import=${pathToFileURL(timeoutHook).href}`,FM_SHORT_TIMEOUT_PROBE:timeoutProbe}}),/Codebase merge readback refused: timed out after 180000ms/);
assert.ok(Date.now()-timeoutAt<5000,'bounded readback timeout refuses the public settlement command');
assert.equal(fs.readFileSync(timeoutProbe,'utf8'),'180000');assert.equal(JSON.parse(fs.readFileSync(forge)).calls,1);assert.deepEqual(timeoutProtectedFiles.map(file=>fs.readFileSync(file,'utf8')),timeoutProtectedBytes,'timeout preserves exact operation evidence and reservations');assert.ok(!fs.existsSync(path.join(refusalDir,'operation-0.receipt.json')));
const refusalMeta=path.join(home,'state/merge-settle-refusal.meta'),refusalMetaText=fs.readFileSync(refusalMeta,'utf8');fs.writeFileSync(refusalMeta,refusalMetaText.replace('spawn_gen=g1','spawn_gen=g2'));assert.throws(()=>settleMergeReceipt(home,root,refusal.id,0,expectedMergeCommit),/identity changed/);fs.writeFileSync(refusalMeta,refusalMetaText);
assert.throws(()=>settleMergeReceipt(home,root,a.id,0,expectedMergeCommit),/Codebase merge effects only/,'unsupported effects cannot be settled');
const unrelatedReservation=path.join(home,'state/.short-operation-unrelated.json');fs.writeFileSync(unrelatedReservation,'{"unrelated":true}');
fs.writeFileSync(forge,JSON.stringify({merged:true,calls:1,statusDelayMs:15500,getDelayMs:15500}));const slowReadbackAt=Date.now();settleMergeReceipt(home,root,refusal.id,0,expectedMergeCommit);assert.ok(Date.now()-slowReadbackAt>=30000,'legitimate aggregate readback may exceed the former 30s budget');assert.ok(!fs.existsSync(refusalMarker));assert.equal(fs.readFileSync(unrelatedReservation,'utf8'),'{"unrelated":true}');assert.equal(JSON.parse(fs.readFileSync(forge)).calls,1,'slow settlement never replays the merge');fs.unlinkSync(unrelatedReservation);
// A completed first action survives a refused later action.
fs.writeFileSync(forge,JSON.stringify({merged:false,calls:0,red:false,lost:false}));writeTask('merge-partial');
fs.writeFileSync(path.join(project,'dirty'),'preserved');
const partial=service.submit(req('partial',[{...mergeStep,task:'merge-partial'},{action:'sync',project}]));
const partialResult=await terminal(partial.id);assert.equal(partialResult.state,'blocked');assert.equal(partialResult.operations[0].state,'completed');assert.match(partialResult.summary,/1\/2 steps completed/);assert.equal(JSON.parse(fs.readFileSync(forge)).calls,1);fs.unlinkSync(path.join(project,'dirty'));
// Changed task incarnation and request generation cannot authorize a write.
writeTask('merge-changed');fs.writeFileSync(forge,JSON.stringify({merged:false,calls:0,red:false,lost:false}));
const changed=service.submit(req('changed',[{...mergeStep,task:'merge-changed'}],'delay'));
const changedMeta=path.join(home,'state/merge-changed.meta');fs.writeFileSync(changedMeta,fs.readFileSync(changedMeta,'utf8').replace('spawn_gen=g1','spawn_gen=g2'));
assert.equal((await terminal(changed.id)).state,'blocked');assert.equal(JSON.parse(fs.readFileSync(forge)).calls,0);
for(const change of ['inventory','history']) {
 fs.writeFileSync(auditFile,baseMeta+legacyAudit);
 const accepted=service.submit(req('audit-drift-'+change,[auditStep],'delay'));
 fs.writeFileSync(auditFile,baseMeta+(change==='inventory'?legacyAudit+'decisions_reviewed=1\ndecision_keys=choice-a,choice-b,choice-c\n':legacyAudit.replace('decision_keys=\n','decision_keys=choice-a\n')));
 // The history edit preserves the latest effective inventory and is still valid.
 assert.equal(bindAudit().length,1);
 const refused=await terminal(accepted.id);assert.equal(refused.state,'blocked');assert.equal(JSON.parse(fs.readFileSync(forge)).calls,0);
 assert.ok(!fs.existsSync(path.join(service.dir(accepted.id),'operation-0.effect.json')),'audit drift refuses before effects');
}
const altered=service.submit(req('altered',undefined,'delay'));
const alteredPath=path.join(service.dir(altered.id),'request.json');
for(let n=0;n<100 && !fs.existsSync(path.join(service.dir(altered.id),'started.json'));n++)await wait(10);
const alteredOriginal=fs.readFileSync(alteredPath,'utf8'),alteredRequest=JSON.parse(alteredOriginal);alteredRequest.nonce='changed';fs.writeFileSync(alteredPath,JSON.stringify(alteredRequest));
assert.equal((await terminal(altered.id)).state,'blocked');assert.ok(!fs.existsSync(path.join(service.dir(altered.id),'operation-0.effect.json')));fs.writeFileSync(alteredPath,alteredOriginal);
const processChanged=service.submit(req('process-changed',undefined,'delay'));
const processFile=path.join(service.dir(processChanged.id),'started.json');
for(let n=0;n<100 && !fs.existsSync(processFile);n++)await wait(10);
const originalProcess=fs.readFileSync(processFile,'utf8'),corruptProcess=JSON.parse(originalProcess);corruptProcess.identity.start='wrong';fs.writeFileSync(processFile,JSON.stringify(corruptProcess));
assert.equal((await terminal(processChanged.id)).state,'blocked');assert.ok(!fs.existsSync(path.join(service.dir(processChanged.id),'operation-0.effect.json')));fs.writeFileSync(processFile,originalProcess);
// Expiry and revocation are checked again inside the child, not just at submit.
const expiringRequest=req('expires-during-delay',undefined,'delay');expiringRequest.operations.expiresAt=Date.now()+250;
const expiring=service.submit(expiringRequest);assert.equal((await terminal(expiring.id)).state,'blocked');assert.ok(!fs.existsSync(path.join(service.dir(expiring.id),'operation-0.effect.json')));
// Malformed receipts cannot turn a provider assertion into success.
const malformedPath=path.join(service.dir(a.id),'operation-0.receipt.json'),originalReceipt=fs.readFileSync(malformedPath,'utf8');
fs.writeFileSync(malformedPath,'{"state":"completed"}');assert.throws(()=>service.status(a.id),/malformed/);
const separate=service.submit(req('separate-notification'),false);service.finish(separate.id,'blocked','fixture task intentionally not launched');
await assert.rejects(()=>service.reconcile(),/malformed/);
assert.ok(fs.existsSync(path.join(service.dir(separate.id),'notified.json')),'one corrupt receipt does not block another task outcome');
fs.writeFileSync(malformedPath,originalReceipt);
// A marker without a receipt stays quarantined across restart. The same key
// never launches a replacement child or repeats an uncertain effect.
const uncertainRequest=req('uncertain',undefined,'delay');const uncertain=service.submit(uncertainRequest,false),uncertainDir=service.dir(uncertain.id),uncertainStored=JSON.parse(fs.readFileSync(path.join(uncertainDir,'request.json')));
fs.writeFileSync(path.join(uncertainDir,'operation-0.intent.json'),JSON.stringify({nonce:uncertainStored.nonce,index:0}));
fs.writeFileSync(path.join(uncertainDir,'heartbeat'),'old');fs.utimesSync(path.join(uncertainDir,'heartbeat'),new Date(0),new Date(0));
const marker=resource(home,uncertainRequest.operations.steps[0]).file;fs.writeFileSync(marker,JSON.stringify({home,id:uncertain.id,nonce:uncertainStored.nonce,index:0}));
assert.equal(new ShortAgents(home,root).submit(uncertainRequest).state,'interrupted');await service.reconcile();assert.ok(fs.existsSync(marker));assert.ok(!fs.existsSync(path.join(uncertainDir,'started.json')));
// Test-only cleanup: no executor was launched in this constructed crash state.
fs.unlinkSync(marker);
// Reconstruct the durable protocol at the two no-effect crash windows.
const deadIdentity=JSON.parse(execFileSync(process.execPath,['--input-type=module','-e',`import {processIdentity} from ${JSON.stringify(pathToFileURL(path.join(root,'bin/fm-short-operations.mjs')).href)};console.log(JSON.stringify(processIdentity(process.pid)))`],{encoding:'utf8'}));
for(const window of ['before-intent','refused']) {
  const submitted=service.submit(req('crash-'+window),false),dir=service.dir(submitted.id);
  const stored=JSON.parse(fs.readFileSync(path.join(dir,'request.json')));
  const held={home,id:stored.id,nonce:stored.nonce,index:0,target:resource(home,stored.input.operations.steps[0]).target};
  const startedFile=path.join(dir,'started.json');
  fs.writeFileSync(startedFile,JSON.stringify({pid:process.pid,identity:processIdentity(process.pid),nonce:stored.nonce}));
  fs.writeFileSync(marker,JSON.stringify(held));
  if(window==='refused') {
    fs.writeFileSync(path.join(dir,'operation-0.intent.json'),JSON.stringify({nonce:stored.nonce,index:0,step:stored.input.operations.steps[0]}));
    fs.writeFileSync(path.join(dir,'operation-0.receipt.json'),JSON.stringify({id:stored.id,nonce:stored.nonce,index:0,action:'sync',state:'refused',evidence:{reason:'owner refused before a guarded effect'}}));
  }
  await service.reconcile();assert.ok(fs.existsSync(marker),'live runner retains reservation');
  fs.writeFileSync(startedFile,JSON.stringify({pid:deadIdentity.pid,identity:deadIdentity,nonce:stored.nonce}));
  const effectFile=path.join(dir,'operation-0.effect.json');fs.writeFileSync(effectFile,JSON.stringify({id:stored.id,nonce:stored.nonce,index:0,owner:deadIdentity}));
  await service.reconcile();assert.ok(fs.existsSync(marker),'effect without authoritative completion remains reserved');fs.unlinkSync(effectFile);
  const reconcile=()=>new Promise((resolve,reject)=>execFile(process.execPath,['--input-type=module','-e',`import {reconcileOperationReceipts} from ${JSON.stringify(pathToFileURL(path.join(root,'bin/fm-short-operations.mjs')).href)};reconcileOperationReceipts(${JSON.stringify(home)},${JSON.stringify(stored)})`],error=>error?reject(error):resolve()));
  await Promise.all([reconcile(),reconcile()]);assert.ok(!fs.existsSync(marker),window+' reservation is released after runner death');
  fs.writeFileSync(marker,JSON.stringify({...held,nonce:'another-generation'}));
  await service.reconcile();assert.equal(JSON.parse(fs.readFileSync(marker)).nonce,'another-generation');
  fs.unlinkSync(marker);
}
// Concurrent jobs contend only for the canonical resource, not for the home.
const realGit=execFileSync('which',['git'],{encoding:'utf8'}).trim();process.env.FM_SHORT_REAL_GIT=realGit;
const fetchLog=path.join(tmp,'fetch-events');process.env.FM_SHORT_FETCH_LOG=fetchLog;
fs.writeFileSync(path.join(fakebin,'git'),`#!/usr/bin/env bash
if [ "\${3:-}" = fetch ]; then
  printf 'start %s\\n' "$2" >> "$FM_SHORT_FETCH_LOG"
  sleep 2
  "$FM_SHORT_REAL_GIT" "$@"
  result=$?
  printf 'end %s\\n' "$2" >> "$FM_SHORT_FETCH_LOG"
  exit "$result"
fi
exec "$FM_SHORT_REAL_GIT" "$@"
`,{mode:0o755});
const another=path.join(tmp,'another');git('clone',remote,another);
const concurrent1=service.submit(req('concurrent1'));
for(let n=0;n<500 && !fs.existsSync(fetchLog);n++)await wait(10);
assert.ok(fs.existsSync(fetchLog),'first owner began its fetch');
const concurrent2=service.submit(req('concurrent2')),independent=service.submit(req('independent',[{action:'sync',project:another}]));
assert.equal((await terminal(concurrent2.id)).state,'blocked');
assert.equal((await terminal(concurrent1.id)).state,'completed');assert.equal((await terminal(independent.id)).state,'completed');
const fetchEvents=fs.readFileSync(fetchLog,'utf8').trim().split('\n');assert.equal(fetchEvents.length,4);assert.ok(fetchEvents[0].startsWith('start ')&&fetchEvents[1].startsWith('start '),'independent resources overlap');
fs.unlinkSync(path.join(fakebin,'git'));
const replayHome=path.join(tmp,'cleanup-replay-home'),replayState=path.join(replayHome,'state'),replayData=path.join(replayHome,'data'),replayTask='cleanup-backlog-replay',replayGeneration='g-cleanup-replay';
for(const directory of [replayHome,replayState,replayData,path.join(replayHome,'config'),path.join(replayData,replayTask),path.join(replayHome,'user-home')])fs.mkdirSync(directory,{recursive:true});
fs.writeFileSync(path.join(replayHome,'.tasks.toml'),'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n');
fs.writeFileSync(path.join(replayData,'backlog.md'),'## In flight\n\n## Queued\n\n## Done\n');
fs.writeFileSync(path.join(replayState,'.lock'),String(process.pid));
fs.writeFileSync(path.join(replayData,replayTask,'brief.md'),'Completed cleanup backlog replay fixture\n');
fs.writeFileSync(path.join(replayData,replayTask,'report.md'),'Preserved replay report\n');
const replayProject=path.join(tmp,'cleanup-replay-project'),replayRemote=path.join(tmp,'cleanup-replay-remote.git'),replayCopy=path.join(tmp,'cleanup-replay-copy');
git('init','--bare','--initial-branch=main',replayRemote);git('clone',replayRemote,replayProject);
fs.writeFileSync(path.join(replayProject,'base.txt'),'base\n');git('-C',replayProject,'add','.');git('-C',replayProject,'commit','-m','cleanup replay base');git('-C',replayProject,'push','origin','main');
git('-C',replayProject,'worktree','add','-b','cleanup-replay-fixture',replayCopy);fs.writeFileSync(path.join(replayCopy,'retained.txt'),'retain cleanup replay changes\n');
const replayCopySnapshot=()=>({head:git('-C',replayCopy,'rev-parse','HEAD'),status:git('-C',replayCopy,'status','--porcelain'),content:fs.readFileSync(path.join(replayCopy,'retained.txt'),'utf8')});
const replayCopyBefore=replayCopySnapshot(),recoveryRoot=path.join(tmp,'cleanup-replay-runtime'),recoveryBin=path.join(recoveryRoot,'bin');
execFileSync('bash',['-c','. "$1/tests/fixtures.sh"; fm_test_fake_herdr_spawn "$2"','fixture',root,recoveryBin]);
const replayEnv={...process.env,FM_HOME:replayHome,FM_ROOT_OVERRIDE:root,FM_STATE_OVERRIDE:replayState,FM_DATA_OVERRIDE:replayData,FM_CONFIG_OVERRIDE:path.join(replayHome,'config'),FM_FAKE_HERDR_STATE:path.join(recoveryRoot,'state.json'),FM_HERDR_LOG:path.join(recoveryRoot,'herdr.log'),HERDR_SESSION:'fixture'};
const compactAccept=(task,env)=>{
  const current=JSON.parse(execFileSync('bash',[path.join(root,'bin/fm-task-state.sh'),'progress',task],{env,encoding:'utf8'}));
  execFileSync('bash',[path.join(root,'bin/fm-task-state.sh'),'update-progress',task,'--progress',JSON.stringify({acceptance:'The completed cleanup behavior is verified',current_state:'The task result is semantically accepted',remaining_gap:'',next_step:''})],{env});
};
const canonicalTasks=(env,...args)=>execFileSync('bash',[path.join(root,'bin/fm-tasks-axi.sh'),...args],{env,encoding:'utf8'});
const addCompactTask=(task,title,env)=>canonicalTasks(env,'add',task,title,'--kind','ship','--repo','sample','--start');
const recordMerge=(task,generation,project,env)=>execFileSync('bash',['-c','. "$1"; fm_merge_receipt_record "$2" "$3" local:fixture "$4"','fixture',path.join(root,'bin/fm-merge-receipt-lib.sh'),task,generation,git('-C',project,'rev-parse','HEAD')],{env});
const replayEndpoint=JSON.parse(execFileSync(path.join(recoveryBin,'herdr'),['workspace','create','--cwd',path.join(tmp,'idle'),'--label','cleanup-replay'],{env:replayEnv,encoding:'utf8'})).result;
fs.writeFileSync(path.join(replayState,replayTask+'.meta'),`kind=ship\nmode=local-only\nspawn_gen=${replayGeneration}\nwindow=fixture:${replayEndpoint.root_pane.pane_id}\nendpoint_task_id=${replayTask}\nworktree=${replayCopy}\nproject=${replayProject}\nbackend=herdr\nherdr_session=fixture\nherdr_workspace_id=${replayEndpoint.workspace.workspace_id}\nherdr_tab_id=${replayEndpoint.tab.tab_id}\nherdr_pane_id=${replayEndpoint.root_pane.pane_id}\n`);
const realPython=execFileSync('which',['python3'],{env:replayEnv,encoding:'utf8'}).trim(),tasksFailure=path.join(recoveryRoot,'done-failed');
addCompactTask(replayTask,'Cleanup backlog replay',replayEnv);
compactAccept(replayTask,replayEnv);
recordMerge(replayTask,replayGeneration,replayProject,replayEnv);
fs.writeFileSync(path.join(recoveryBin,'python3'),`#!/usr/bin/env bash\nif [ "\${4:-}" = done ] && [ ! -e ${JSON.stringify(tasksFailure)} ]; then : > ${JSON.stringify(tasksFailure)}; exit 1; fi\nexec ${JSON.stringify(realPython)} "$@"\n`,{mode:0o755});
const replayService=new ShortAgents(replayHome,root),replayInput=req('cleanup-backlog-replay',[{action:'cleanup',task:replayTask}]),priorPath=process.env.PATH;
process.env.PATH=recoveryBin+path.delimiter+priorPath;
try {
  const closeCount=pane=>{
    const log=path.join(recoveryBin,'herdr.log');
    return fs.existsSync(log)?fs.readFileSync(log,'utf8').split('\n').filter(line=>line.includes(`\x1fpane\x1fclose\x1f${pane}\x1f`)).length:0;
  };
  const replayOperation=replayService.submit(replayInput);let replayResult;
  for(let n=0;n<12000;n++){replayResult=replayService.status(replayOperation.id);if(replayResult.finishedAt)break;await wait(25);}
  assert.equal(replayResult.state,'blocked');
  const replayDir=replayService.dir(replayOperation.id),replayMarker=path.join(replayState,replayTask+'.backlog-close'),reservation=resource(replayHome,replayInput.operations.steps[0]).file;
  assert.ok(fs.existsSync(replayMarker));assert.ok(!fs.existsSync(path.join(replayState,replayTask+'.meta')));assert.ok(fs.existsSync(reservation));assert.ok(!fs.existsSync(path.join(replayDir,'operation-0.receipt.json')));
  assert.deepEqual(replayCopySnapshot(),replayCopyBefore);
  const replayStarted=JSON.parse(fs.readFileSync(path.join(replayDir,'started.json'))).identity;
  for(let n=0;n<400;n++){try{if(processIdentity(replayStarted.pid).start!==replayStarted.start)break;}catch{break;}if(n===399)throw Error('cleanup replay fixture runner did not exit');await wait(25);}
  const closeCallsBefore=closeCount(replayEndpoint.root_pane.pane_id);assert.equal(closeCallsBefore,1);
  execFileSync('bash',[path.join(root,'bin/fm-bootstrap.sh')],{env:{...replayEnv,PATH:process.env.PATH,FM_BOOTSTRAP_NETWORK:'skip',HOME:path.join(replayHome,'user-home')},encoding:'utf8',timeout:30000});
  assert.ok(!fs.existsSync(replayMarker));
  assert.match(canonicalTasks(replayEnv,'show',replayTask),/state:\s+done/);
  const cleanupAfterReplay=JSON.parse(fs.readFileSync(path.join(replayState,replayTask+'.cleanup.json'))),cleanupFacts=cleanupAfterReplay.completion.facts;
  assert.equal(cleanupAfterReplay.completion.spawn_gen,replayGeneration);assert.equal(cleanupFacts.copyDisposition,'retained-dirty');
  await replayService.reconcile();
  const replayReceipt=JSON.parse(fs.readFileSync(path.join(replayDir,'operation-0.receipt.json')));
  assert.equal(replayReceipt.state,'completed');assert.equal(replayReceipt.settlement,'dead-owner-cleanup-readback');assert.deepEqual(replayReceipt.evidence,cleanupFacts);
  assert.ok(!fs.existsSync(reservation));assert.deepEqual(replayCopySnapshot(),replayCopyBefore);assert.equal(closeCount(replayEndpoint.root_pane.pane_id),closeCallsBefore);
  const boundaryTask='cleanup-success-boundary',boundaryGeneration='g-cleanup-success-boundary',boundaryCopy=path.join(tmp,'cleanup-success-boundary-copy');
  git('-C',replayProject,'worktree','add','-b','cleanup-success-boundary-fixture',boundaryCopy);fs.writeFileSync(path.join(boundaryCopy,'retained.txt'),'retain success-boundary changes\n');
  const boundaryCopySnapshot=()=>({head:git('-C',boundaryCopy,'rev-parse','HEAD'),status:git('-C',boundaryCopy,'status','--porcelain'),content:fs.readFileSync(path.join(boundaryCopy,'retained.txt'),'utf8')}),boundaryCopyBefore=boundaryCopySnapshot();
  fs.mkdirSync(path.join(replayData,boundaryTask));fs.writeFileSync(path.join(replayData,boundaryTask,'brief.md'),'Completed cleanup success-boundary fixture\n');fs.writeFileSync(path.join(replayData,boundaryTask,'report.md'),'Preserved success-boundary report\n');
  const boundaryEndpoint=JSON.parse(execFileSync(path.join(recoveryBin,'herdr'),['workspace','create','--cwd',path.join(tmp,'idle'),'--label','cleanup-success-boundary'],{env:replayEnv,encoding:'utf8'})).result;
  fs.writeFileSync(path.join(replayState,boundaryTask+'.meta'),`kind=ship\nmode=local-only\nspawn_gen=${boundaryGeneration}\nwindow=fixture:${boundaryEndpoint.root_pane.pane_id}\nendpoint_task_id=${boundaryTask}\nworktree=${boundaryCopy}\nproject=${replayProject}\nbackend=herdr\nherdr_session=fixture\nherdr_workspace_id=${boundaryEndpoint.workspace.workspace_id}\nherdr_tab_id=${boundaryEndpoint.tab.tab_id}\nherdr_pane_id=${boundaryEndpoint.root_pane.pane_id}\n`);
  addCompactTask(boundaryTask,'Cleanup success boundary',replayEnv);
  compactAccept(boundaryTask,replayEnv);
  recordMerge(boundaryTask,boundaryGeneration,replayProject,replayEnv);
  const receiptFailure=path.join(recoveryRoot,'receipt-failed');
  fs.writeFileSync(path.join(recoveryBin,'python3'),`#!/usr/bin/env bash\nif [ "\${2:-}" = completion-record ] && [ ! -e ${JSON.stringify(receiptFailure)} ]; then : > ${JSON.stringify(receiptFailure)}; kill -KILL "\$\$"; fi\nexec ${JSON.stringify(realPython)} "$@"\n`,{mode:0o755});
  const boundaryInput=req('cleanup-success-boundary',[{action:'cleanup',task:boundaryTask}]),boundaryOperation=replayService.submit(boundaryInput);let boundaryResult;
  for(let n=0;n<12000;n++){boundaryResult=replayService.status(boundaryOperation.id);if(boundaryResult.finishedAt)break;await wait(25);}
  assert.equal(boundaryResult.state,'blocked');
  const boundaryDir=replayService.dir(boundaryOperation.id),boundaryMarker=path.join(replayState,boundaryTask+'.backlog-close'),boundaryReservation=resource(replayHome,boundaryInput.operations.steps[0]).file;
  assert.ok(fs.existsSync(boundaryMarker));assert.ok(!fs.existsSync(path.join(replayState,boundaryTask+'.meta')));assert.ok(fs.existsSync(boundaryReservation));assert.ok(!fs.existsSync(path.join(boundaryDir,'operation-0.receipt.json')));
  assert.match(canonicalTasks(replayEnv,'show',boundaryTask),/state:\s+done/);
  const boundaryBeforeReplay=JSON.parse(fs.readFileSync(path.join(replayState,boundaryTask+'.cleanup.json')));assert.equal(boundaryBeforeReplay.completion,undefined);
  const boundaryStarted=JSON.parse(fs.readFileSync(path.join(boundaryDir,'started.json'))).identity;
  for(let n=0;n<400;n++){try{if(processIdentity(boundaryStarted.pid).start!==boundaryStarted.start)break;}catch{break;}if(n===399)throw Error('cleanup success-boundary fixture runner did not exit');await wait(25);}
  const boundaryCloseCalls=closeCount(boundaryEndpoint.root_pane.pane_id);assert.equal(boundaryCloseCalls,1);assert.deepEqual(boundaryCopySnapshot(),boundaryCopyBefore);
  execFileSync('bash',[path.join(root,'bin/fm-bootstrap.sh')],{env:{...replayEnv,PATH:process.env.PATH,FM_BOOTSTRAP_NETWORK:'skip',HOME:path.join(replayHome,'user-home')},encoding:'utf8',timeout:30000});
  assert.ok(!fs.existsSync(boundaryMarker));
  const boundaryAfterReplay=JSON.parse(fs.readFileSync(path.join(replayState,boundaryTask+'.cleanup.json'))),boundaryFacts=boundaryAfterReplay.completion.facts;
  assert.equal(boundaryAfterReplay.completion.spawn_gen,boundaryGeneration);assert.equal(boundaryFacts.copyDisposition,'retained-dirty');
  await replayService.reconcile();
  const boundaryReceipt=JSON.parse(fs.readFileSync(path.join(boundaryDir,'operation-0.receipt.json')));
  assert.equal(boundaryReceipt.state,'completed');assert.equal(boundaryReceipt.settlement,'dead-owner-cleanup-readback');assert.deepEqual(boundaryReceipt.evidence,boundaryFacts);
  assert.ok(!fs.existsSync(boundaryReservation));assert.deepEqual(boundaryCopySnapshot(),boundaryCopyBefore);assert.equal(closeCount(boundaryEndpoint.root_pane.pane_id),boundaryCloseCalls);
  const refusedTask='cleanup-preflight-refusal',refusedGeneration='g-cleanup-preflight-refusal';
  const refusedEndpoint=JSON.parse(execFileSync(path.join(recoveryBin,'herdr'),['workspace','create','--cwd',path.join(tmp,'idle'),'--label','cleanup-preflight-refusal'],{env:replayEnv,encoding:'utf8'})).result;
  fs.mkdirSync(path.join(replayData,refusedTask));
  fs.writeFileSync(path.join(replayData,refusedTask,'brief.md'),'Cleanup preflight refusal fixture\n');
  fs.writeFileSync(path.join(replayData,refusedTask,'report.md'),'Preserved preflight refusal report\n');
  fs.writeFileSync(path.join(replayState,refusedTask+'.meta'),`kind=ship\nmode=local-only\nspawn_gen=${refusedGeneration}\nwindow=fixture:${refusedEndpoint.root_pane.pane_id}\nendpoint_task_id=${refusedTask}\nworktree=${tmp}/absent-preflight-refusal-copy\nproject=${replayProject}\nbackend=herdr\nherdr_session=fixture\nherdr_workspace_id=${refusedEndpoint.workspace.workspace_id}\nherdr_tab_id=${refusedEndpoint.tab.tab_id}\nherdr_pane_id=${refusedEndpoint.root_pane.pane_id}\n`);
  addCompactTask(refusedTask,'Cleanup preflight refusal',replayEnv);
  recordMerge(refusedTask,refusedGeneration,replayProject,replayEnv);
  const refusedInput=req('cleanup-preflight-refusal',[{action:'cleanup',task:refusedTask}]);
  const refusedOperation=replayService.submit(refusedInput);let refusedResult;
  for(let n=0;n<12000;n++){refusedResult=replayService.status(refusedOperation.id);if(refusedResult.finishedAt)break;await wait(25);}
  const refusedDir=replayService.dir(refusedOperation.id);
  assert.equal(refusedResult.state,'blocked');
  const refusedOutput=JSON.parse(fs.readFileSync(path.join(refusedDir,'operation-0.output.json')));
  assert.match(refusedOutput.stderr,/not MAIN-accepted/);
  assert.ok(!fs.existsSync(path.join(refusedDir,'operation-0.effect.json')),'preflight refusal was misrecorded as an effect');
  assert.equal(JSON.parse(fs.readFileSync(path.join(refusedDir,'operation-0.receipt.json'))).state,'refused');
  assert.ok(!fs.existsSync(resource(replayHome,refusedInput.operations.steps[0]).file),'proven no-effect refusal retained the resource reservation');
  assert.ok(fs.existsSync(path.join(replayState,refusedTask+'.meta')),'preflight refusal changed task metadata');
  assert.equal(closeCount(refusedEndpoint.root_pane.pane_id),0,'preflight refusal closed the endpoint');
  compactAccept(refusedTask,replayEnv);
  const acceptedInput=req('cleanup-after-preflight-refusal',[{action:'cleanup',task:refusedTask}]);
  const acceptedOperation=replayService.submit(acceptedInput);let acceptedResult;
  for(let n=0;n<12000;n++){acceptedResult=replayService.status(acceptedOperation.id);if(acceptedResult.finishedAt)break;await wait(25);}
  const acceptedDir=replayService.dir(acceptedOperation.id);
  assert.equal(acceptedResult.state,'completed',JSON.stringify(acceptedResult));
  assert.equal(JSON.parse(fs.readFileSync(path.join(acceptedDir,'operation-0.receipt.json'))).state,'completed');
  assert.equal(closeCount(refusedEndpoint.root_pane.pane_id),1,'accepted retry did not close the exact endpoint once');
  assert.ok(!fs.existsSync(resource(replayHome,acceptedInput.operations.steps[0]).file),'completed retry retained the resource reservation');
} finally {process.env.PATH=priorPath;}
if(process.env.FM_SHORT_CLEANUP_TARGET) {
  const target=JSON.parse(fs.readFileSync(process.env.FM_SHORT_CLEANUP_TARGET));
  assert.ok(/^fm-lab-/.test(target.session) && target.session===process.env.HERDR_LAB_SESSION,'cleanup requires the generated named lab');
  fs.writeFileSync(path.join(home,'state/cleanup-one.meta'),`kind=ship\nmode=local-only\nspawn_gen=g-lab\nwindow=${target.session}:${target.pane}\nendpoint_task_id=cleanup-one\nworktree=${tmp}/absent-cleaned-worktree\nproject=${project}\nbackend=herdr\nherdr_session=${target.session}\nherdr_workspace_id=${target.workspace}\nherdr_tab_id=${target.tab}\nherdr_pane_id=${target.pane}\n`);
  const cleanMeta=fs.readFileSync(path.join(home,'state/cleanup-one.meta'),'utf8');
  const herdrLive=(...args)=>{const output=execFileSync(process.env.HERDR_LAB_HELPER,['run',target.session,...args],{encoding:'utf8',env:{...process.env,PATH:process.env.FM_SHORT_TEST_BASE_PATH}});return output.trim()?JSON.parse(output):{};};
  const liveTask='cleanup-live',liveGeneration='s-live-cleanup';
  const livePane=herdrLive('tab','create','--workspace',target.workspace,'--cwd',path.join(tmp,'idle'),'--label','fm-cleanup-live','--no-focus').result;
  const livePaneId=livePane.root_pane.pane_id,liveTabId=livePane.tab.tab_id;
  fs.writeFileSync(path.join(home,'state',liveTask+'.meta'),cleanMeta.replaceAll('cleanup-one',liveTask).replaceAll(target.pane,livePaneId).replaceAll(target.tab,liveTabId).replace('spawn_gen=g-lab',`spawn_gen=${liveGeneration}`)+'harness=traex\n');
  fs.mkdirSync(path.join(home,'data',liveTask),{recursive:true});
  fs.writeFileSync(path.join(home,'data',liveTask,'brief.md'),'Disposable completed live cleanup fixture\n');
  fs.writeFileSync(path.join(home,'data',liveTask,'report.md'),'Retained completed-task report\n');
  const liveEnv={...process.env,FM_HOME:home,FM_ROOT_OVERRIDE:root,FM_STATE_OVERRIDE:path.join(home,'state'),FM_DATA_OVERRIDE:path.join(home,'data'),FM_SUPERVISION_ACTOR:'main'};
  addCompactTask(liveTask,'Live cleanup fixture',liveEnv);
  fs.writeFileSync(path.join(home,'state',liveTask+'.herdr-presentation'),`version=1\ntask_id=${liveTask}\nprojection_id=abcdefghijklmnopqrstuv\n`);
  execFileSync('bash',['-c',`. "$1/bin/backends/herdr.sh"; journal="$FM_HOME/state/$2.herdr-presentation"; fm_backend_herdr_projection_journal_write_v2 "$journal" "$2" abcdefghijklmnopqrstuv "$FM_HOME" "$3" "$4" "$5" "$6" "$4" anchor "$(fm_backend_herdr_projection_workspace_label "$2" abcdefghijklmnopqrstuv)" "fm-$2"; fm_backend_herdr_projection_bind_execution "$journal" "$2" "$7"`,'fixture',root,liveTask,target.session,target.workspace,liveTabId,livePaneId,liveGeneration],{env:liveEnv});
  compactAccept(liveTask,liveEnv);
  recordMerge(liveTask,liveGeneration,project,liveEnv);
  herdrLive('pane','run',livePaneId,'traex -y');
  const probe=()=>execFileSync('bash',['-c','. "$1/bin/backends/herdr.sh"; fm_backend_herdr_agent_state "$2:$3"; fm_backend_herdr_composer_state "$2:$3"','fixture',root,target.session,livePaneId],{env:liveEnv,encoding:'utf8'}).trim();
  let liveState;
  for(let n=0;n<120;n++){liveState=probe();if(['aliveempty','alivepending'].includes(liveState))break;await wait(250);}
  assert.ok(['aliveempty','alivepending'].includes(liveState),'real TraeX reached a structurally live agent in the exact named-lab pane');
  const liveInput=req('cleanup-live',[{action:'cleanup',task:liveTask}]);liveInput.operations.expiresAt=Date.now()+180000;
  const liveCleanup=service.submit(liveInput),liveResult=await terminal(liveCleanup.id);
  const liveDir=service.dir(liveCleanup.id);
  const liveOutput=JSON.parse(fs.readFileSync(path.join(liveDir,'operation-0.output.json')));
  fs.writeFileSync(path.join(tmp,'live-cleanup-evidence.json'),JSON.stringify({liveState,result:liveResult,output:liveOutput,receipt:JSON.parse(fs.readFileSync(path.join(liveDir,'operation-0.receipt.json')))},null,2));
  assert.equal(liveResult.state,'completed',JSON.stringify(liveOutput));
  assert.ok(!fs.existsSync(path.join(home,'state',liveTask+'.meta')));
  assert.ok(!herdrLive('pane','list','--workspace',target.workspace).result.panes.some(p=>p.pane_id===livePaneId));
  assert.equal(fs.readFileSync(path.join(home,'data',liveTask,'report.md'),'utf8'),'Retained completed-task report\n');
  const liveReceipt=fs.readFileSync(path.join(liveDir,'operation-0.receipt.json'),'utf8');
  assert.equal(service.submit(liveInput).finishedAt,liveResult.finishedAt,'completed cleanup is not replayed');
  assert.equal(fs.readFileSync(path.join(liveDir,'operation-0.receipt.json'),'utf8'),liveReceipt);
  const completedFixture=(task,meta)=>{
    fs.writeFileSync(path.join(home,'state',task+'.meta'),meta);
    fs.mkdirSync(path.join(home,'data',task),{recursive:true});
    fs.writeFileSync(path.join(home,'data',task,'brief.md'),'Disposable completed cleanup fixture\n');
    fs.writeFileSync(path.join(home,'data',task,'report.md'),'Preserved report\n');
    addCompactTask(task,`Completed cleanup fixture ${task}`,liveEnv);
    compactAccept(task,liveEnv);
    const targetProject=meta.split('\n').find(line=>line.startsWith('project=')).slice(8);
    const generation=meta.split('\n').find(line=>line.startsWith('spawn_gen=')).slice(10);
    recordMerge(task,generation,targetProject,liveEnv);
  };
  const copySnapshot=copy=>({
    head:git('-C',copy,'rev-parse','HEAD'),branch:git('-C',copy,'rev-parse','--abbrev-ref','HEAD'),status:git('-C',copy,'status','--porcelain'),
    files:Object.fromEntries(git('-C',copy,'ls-files','--cached','--others','--exclude-standard','-z').split('\0').filter(Boolean).map(file=>[file,fs.readFileSync(path.join(copy,file)).toString('base64')]))
  });
  for(const label of ['dirty','unlanded','pushed-unmerged','shared','primary','primary-child','contended','clean']) {
    const task='cleanup-'+label,copy=label==='primary'?project:label==='primary-child'?path.join(project,'protected-child'):path.join(tmp,label+'-copy');
    if(label==='primary-child') {
      fs.mkdirSync(copy);fs.writeFileSync(path.join(copy,'retained.txt'),'primary checkout content');
      git('-C',project,'add','.');git('-C',project,'commit','-m','primary subtree fixture');git('-C',project,'push','origin','HEAD');
    } else if(label!=='primary') {
      git('-C',project,'worktree','add','-b',label+'-fixture',copy);
      if(!['clean','contended'].includes(label))fs.writeFileSync(path.join(copy,'unlanded'),'retained task content');
      if(label==='unlanded'||label==='pushed-unmerged') {git('-C',copy,'add','.');git('-C',copy,'commit','-m','unmerged task content');if(label==='pushed-unmerged')git('-C',copy,'push','origin','HEAD');}
    }
    if(label==='shared')fs.writeFileSync(path.join(home,'state/other-task.meta'),`worktree=${copy}\n`);
    const pane=herdrLive('tab','create','--workspace',target.workspace,'--cwd',path.join(tmp,'idle'),'--label',task,'--no-focus').result;
    const meta=cleanMeta.replaceAll('cleanup-one',task).replace(`${tmp}/absent-cleaned-worktree`,copy).replaceAll(target.pane,pane.root_pane.pane_id).replaceAll(target.tab,pane.tab.tab_id);
    completedFixture(task,meta);
    const beforeCopy=copySnapshot(copy);
    let copyLock;
    if(label==='contended') {
      copyLock=execFileSync('bash',['-c','. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"','fixture',root,project],{env:liveEnv,encoding:'utf8'}).trim();
      fs.mkdirSync(copyLock);fs.writeFileSync(path.join(copyLock,'pid'),String(process.pid)+'\n');
    }
    const input=req(task,[{action:'cleanup',task}]),operation=service.submit(input),result=await terminal(operation.id);
    if(copyLock)fs.rmSync(copyLock,{recursive:true});
    const dir=service.dir(operation.id),output=JSON.parse(fs.readFileSync(path.join(dir,'operation-0.output.json')));
    assert.equal(result.state,'completed',JSON.stringify(output));
    assert.ok(!fs.existsSync(path.join(home,'state',task+'.meta')));
    assert.ok(!herdrLive('pane','list','--workspace',target.workspace).result.panes.some(p=>p.pane_id===pane.root_pane.pane_id));
    assert.equal(fs.readFileSync(path.join(home,'data',task,'report.md'),'utf8'),'Preserved report\n');
    const receipt=JSON.parse(fs.readFileSync(path.join(dir,'operation-0.receipt.json')));
    if(label!=='clean') {
      assert.ok(fs.existsSync(copy));assert.equal(receipt.evidence.copyDisposition,'retained-'+(label==='pushed-unmerged'?'unlanded':label==='contended'?'unverified':label==='primary-child'?'primary':label));
      assert.deepEqual(copySnapshot(copy),beforeCopy,'retained working files, head, branch and status are unchanged');
    } else assert.ok(!fs.existsSync(copy),'exclusive clean integrated copy was actually removed');
    fs.writeFileSync(path.join(tmp,label+'-cleanup-evidence.json'),JSON.stringify({copy,beforeCopy,afterCopy:label==='clean'?null:copySnapshot(copy),result,receipt,output},null,2));
  }
  completedFixture('cleanup-one',cleanMeta);
  const cleanup=service.submit(req('cleanup',[{action:'cleanup',task:'cleanup-one'}]));
  const result=await terminal(cleanup.id);
  if(result.state!=='completed') console.log(fs.readFileSync(path.join(service.dir(cleanup.id),'operation-0.output.json'),'utf8'));
  assert.equal(result.state,'completed',JSON.stringify(result));assert.ok(!fs.existsSync(path.join(home,'state/cleanup-one.meta')));
  console.log(JSON.stringify({cleanupEvidence:service.dir(cleanup.id),result}));

  // A second positive case starts with a real leased, clean, landed copy.
  // Treehouse's root is inside this lab, never the user's shared pool.
  const cleanupProject=path.join(tmp,'cleanup-project'),cleanupRemote=path.join(tmp,'cleanup-remote.git');
  const poolRoot=path.join(cleanupProject,'pool');
  git('init','--bare','--initial-branch=main',cleanupRemote);git('clone',cleanupRemote,cleanupProject);
  fs.writeFileSync(path.join(cleanupProject,'treehouse.toml'),`max_trees = 2\nroot = ${JSON.stringify(poolRoot)}\n`);
  fs.writeFileSync(path.join(cleanupProject,'.gitignore'),'/pool/.treehouse\n');
  fs.writeFileSync(path.join(cleanupProject,'base.txt'),'landed base\n');
  git('-C',cleanupProject,'add','.');git('-C',cleanupProject,'commit','-m','cleanup fixture base');git('-C',cleanupProject,'push','origin','main');git('-C',cleanupProject,'remote','set-head','origin','main');
  const treehouse=(...args)=>execFileSync('treehouse',args,{cwd:cleanupProject,encoding:'utf8',timeout:30000,stdio:['ignore','pipe','pipe']});
  const lease=JSON.parse(treehouse('get','--lease','--lease-holder','cleanup-landed','--json'));
  const unrelated=JSON.parse(treehouse('get','--lease','--lease-holder','unrelated-lab','--json'));
  for(const allocated of [lease,unrelated]) assert.ok(fs.realpathSync(allocated.path).startsWith(poolRoot+path.sep),'Treehouse allocation stayed inside the lab');
  assert.notEqual(lease.path,unrelated.path);
  git('-C',lease.path,'checkout','-b','landed-cleanup-fixture');
  fs.writeFileSync(path.join(lease.path,'done.txt'),'completed task content\n');
  git('-C',lease.path,'add','.');git('-C',lease.path,'commit','-m','completed disposable task');
  git('-C',cleanupProject,'merge','--ff-only','landed-cleanup-fixture');git('-C',cleanupProject,'push','origin','main');
  const landedHead=git('-C',lease.path,'rev-parse','HEAD');
  assert.equal(landedHead,git('-C',cleanupProject,'rev-parse','origin/main'));
  assert.equal(git('-C',lease.path,'status','--porcelain'),'');
  const unrelatedHead=git('-C',unrelated.path,'rev-parse','HEAD');
  fs.writeFileSync(path.join(unrelated.path,'keep.txt'),'unrelated content must survive');
  execFileSync('bash',['-c','. "$1/bin/fm-wake-lib.sh"; fm_treehouse_slot_owner_claim "$2" cleanup-landed "$3" g-lab','fixture',root,lease.path,home]);
  const herdr=(...args)=>JSON.parse(execFileSync(process.env.HERDR_LAB_HELPER,['run',target.session,...args],{encoding:'utf8',env:{...process.env,PATH:process.env.FM_SHORT_TEST_BASE_PATH}}));
  const pane=herdr('tab','create','--workspace',target.workspace,'--cwd',path.join(tmp,'idle'),'--label','fm-cleanup-landed','--no-focus').result;
  const beforePanes=herdr('pane','list','--workspace',target.workspace).result.panes.map(p=>p.pane_id);
  const beforePool=JSON.parse(treehouse('status','--json'));
  const beforeCopy={path:lease.path,exists:fs.existsSync(lease.path),head:git('-C',lease.path,'rev-parse','HEAD'),status:git('-C',lease.path,'status','--porcelain')};
  const landedMeta=cleanMeta.replaceAll('cleanup-one','cleanup-landed').replace(`${tmp}/absent-cleaned-worktree`,lease.path).replace(`project=${project}`,`project=${cleanupProject}`).replaceAll(target.pane,pane.root_pane.pane_id).replaceAll(target.tab,pane.tab.tab_id);
  completedFixture('cleanup-landed',landedMeta);
  const unrelatedMeta=`kind=ship\nspawn_gen=g-other\nworktree=${unrelated.path}\nproject=${cleanupProject}\n`;
  fs.writeFileSync(path.join(home,'state/unrelated-lab.meta'),unrelatedMeta);
  const landedRequest=req('cleanup-landed',[{action:'cleanup',task:'cleanup-landed'}]);landedRequest.operations.expiresAt=Date.now()+120000;
  const landed=service.submit(landedRequest),landedResult=await terminal(landed.id);
  if(landedResult.state!=='completed')console.log(fs.readFileSync(path.join(service.dir(landed.id),'operation-0.output.json'),'utf8'));
  assert.equal(landedResult.state,'completed',JSON.stringify(landedResult));
  const afterPool=JSON.parse(treehouse('status','--json'));
  const returned=afterPool.find(s=>s.path===lease.path),preserved=afterPool.find(s=>s.path===unrelated.path);
  assert.ok(returned,'returned pool slot remains discoverable');
  assert.equal(returned.status,'available',JSON.stringify(returned));assert.ok(!returned.lease_id);
  assert.equal(git('-C',lease.path,'status','--porcelain'),'');
  assert.equal(git('-C',lease.path,'rev-parse','HEAD'),landedHead);
  assert.equal(preserved.lease_id,unrelated.lease_id);assert.equal(preserved.status,'leased');
  assert.equal(git('-C',unrelated.path,'rev-parse','HEAD'),unrelatedHead);
  assert.equal(fs.readFileSync(path.join(unrelated.path,'keep.txt'),'utf8'),'unrelated content must survive');
  assert.equal(fs.readFileSync(path.join(home,'state/unrelated-lab.meta'),'utf8'),unrelatedMeta);
  assert.equal(git('-C',cleanupProject,'rev-parse','HEAD'),landedHead);assert.equal(git('-C',cleanupProject,'status','--porcelain'),'');
  assert.ok(!fs.existsSync(path.join(home,'state/cleanup-landed.meta')));
  const afterPanes=herdr('pane','list','--workspace',target.workspace).result.panes.map(p=>p.pane_id);
  assert.deepEqual(afterPanes.sort(),beforePanes.filter(id=>id!==pane.root_pane.pane_id).sort());
  const ownerReceipt=JSON.parse(fs.readFileSync(path.join(service.dir(landed.id),'operation-0.receipt.json')));
  assert.notEqual(ownerReceipt.executor.pid,process.pid);
  const afterCopy={path:lease.path,exists:fs.existsSync(lease.path),head:git('-C',lease.path,'rev-parse','HEAD'),status:git('-C',lease.path,'status','--porcelain')};
  const copyEvidence={landedHead,beforeCopy,afterCopy,beforePool,afterPool,beforePanes,afterPanes,ownerReceipt,result:landedResult,mainExecutionCalls:0,unrelatedPreserved:true};
  fs.writeFileSync(path.join(tmp,'landed-cleanup-evidence.json'),JSON.stringify(copyEvidence,null,2));
  console.log(JSON.stringify({landedCleanupEvidence:path.join(tmp,'landed-cleanup-evidence.json'),returned,unrelatedPreserved:true,result:landedResult}));

  // Real completion owner -> short intake -> guarded scout cleanup. Keep the
  // captain choices pending throughout, including the source task's own hold.
  const auditHome=path.join(tmp,'audit-home'),auditTask='audit-cleanup';
  for(const sub of ['state','data','config',`data/${auditTask}`])fs.mkdirSync(path.join(auditHome,sub),{recursive:true});
  fs.copyFileSync(path.join(root,'.tasks.toml'),path.join(auditHome,'.tasks.toml'));
  fs.writeFileSync(path.join(auditHome,'data/backlog.md'),'## In flight\n\n## Queued\n\n## Done\n');
  fs.writeFileSync(path.join(auditHome,'state/.lock'),String(process.pid));
  const auditEnv={...process.env,FM_HOME:auditHome,FM_ROOT_OVERRIDE:root,FM_STATE_OVERRIDE:path.join(auditHome,'state'),FM_DATA_OVERRIDE:path.join(auditHome,'data'),FM_CONFIG_OVERRIDE:path.join(auditHome,'config')};
  const tasks=(...args)=>execFileSync('bash',[path.join(root,'bin/fm-tasks-axi.sh'),...args],{cwd:auditHome,env:auditEnv,encoding:'utf8'});
  const completion=(...args)=>execFileSync('bash',[path.join(root,'bin/fm-captain-hold.sh'),...args],{env:auditEnv,encoding:'utf8'});
  const auditPane=herdr('tab','create','--workspace',target.workspace,'--cwd',path.join(tmp,'idle'),'--label','fm-audit-cleanup','--no-focus').result;
  const auditMeta=path.join(auditHome,'state',auditTask+'.meta');
  fs.writeFileSync(auditMeta,cleanMeta.replace('kind=ship','kind=scout').replaceAll('cleanup-one',auditTask).replaceAll(target.pane,auditPane.root_pane.pane_id).replaceAll(target.tab,auditPane.tab.tab_id));
  fs.writeFileSync(path.join(auditHome,'data',auditTask,'report.md'),'# Synthetic completed scout\nA held implementation choice remains.\n');
  tasks('add',auditTask,'Synthetic cleanup with pending choice','--kind','scout','--repo','sample','--start');
  compactAccept(auditTask,auditEnv);
  completion('complete',auditTask,'--none');
  completion('hold',auditTask,'--title','Synthetic cleanup with pending choice','--reason','Synthetic implementation choice remains open');
  completion('complete',auditTask,auditTask);
  const firstReview=fs.readFileSync(auditMeta,'utf8');
  assert.equal(firstReview.split('\n').filter(l=>l.startsWith('decisions_reviewed=')).length,1);
  assert.equal(firstReview.split('\n').filter(l=>l.startsWith('decision_keys=')).length,1);
  assert.ok(firstReview.includes('# previous completion: decision_keys=\n'),'empty reviewed inventory remains in the audit trail');
  completion('complete',auditTask,auditTask);assert.equal(fs.readFileSync(auditMeta,'utf8'),firstReview,'repeated review is byte-idempotent');
  const auditService=new ShortAgents(auditHome,root);
  const cleanupInput=(key)=>({key,goal:'run',acceptance:'owner receipt',materials:[],operations:{authority:'synthetic named-lab scout only',expiresAt:Date.now()+120000,steps:[{action:'cleanup',task:auditTask}]}});
  // Emulate the historical writer's extra pair, then let the real completion
  // owner canonicalize it without dropping the pending choice or audit bytes.
  const oldPair=`decisions_reviewed=1\ndecision_keys=${auditTask}\n`;
  fs.appendFileSync(auditMeta,oldPair);
  assert.equal(bindOperations(auditHome,cleanupInput('legacy-bind').operations).length,1);
  completion('complete',auditTask,auditTask);
  const normalizedLegacy=fs.readFileSync(auditMeta,'utf8');
  assert.equal(normalizedLegacy.split('\n').filter(l=>l.startsWith('decision_keys=')).length,1);
  assert.equal(normalizedLegacy.split('\n').filter(l=>l===`# previous completion: decision_keys=${auditTask}`).length,2);
  completion('open',auditTask);
  const drift=auditService.submit(cleanupInput('audit-owner-drift'),false);
  completion('hold','audit-second-choice','--title','Second synthetic choice','--reason','Unanswered synthetic choice','--origin',auditTask);
  completion('complete',auditTask,auditTask,'audit-second-choice');
  fs.appendFileSync(auditMeta,'endpoint_task_id=another-task\n');
  execFileSync(process.execPath,[path.join(root,'bin/fm-short-agent.mjs'),'_run',auditHome,drift.id],{env:auditEnv,timeout:30000});
  assert.equal(auditService.status(drift.id).state,'blocked');assert.ok(fs.existsSync(auditMeta));
  assert.ok(!fs.existsSync(path.join(auditService.dir(drift.id),'operation-0.effect.json')));
  fs.writeFileSync(auditMeta,fs.readFileSync(auditMeta,'utf8').replace('endpoint_task_id=another-task\n',''));
  const currentReview=fs.readFileSync(auditMeta,'utf8');
  assert.ok(currentReview.includes('# previous completion: decision_keys='+auditTask+'\n'));
  completion('verify',auditTask);completion('open',auditTask);completion('open','audit-second-choice');
  const approved=auditService.submit(cleanupInput('audit-owner-cleanup'));
  let completed;
  for(let n=0;n<6000;n++){completed=auditService.status(approved.id);if(completed.finishedAt)break;await wait(25);}
  if(completed.state!=='completed')console.log(fs.readFileSync(path.join(auditService.dir(approved.id),'operation-0.output.json'),'utf8'));
  assert.equal(completed.state,'completed',JSON.stringify(completed));assert.ok(!fs.existsSync(auditMeta));
  assert.ok(!herdr('pane','list','--workspace',target.workspace).result.panes.some(p=>p.pane_id===auditPane.root_pane.pane_id));
  completion('open',auditTask);completion('open','audit-second-choice');
  assert.ok(fs.existsSync(path.join(auditHome,'data',auditTask,'report.md')));
  const auditReceipt=JSON.parse(fs.readFileSync(path.join(auditService.dir(approved.id),'operation-0.receipt.json')));
  assert.equal(auditReceipt.state,'completed');assert.notEqual(auditReceipt.executor.pid,process.pid);
  await auditService.reconcile();
  fs.writeFileSync(path.join(tmp,'audit-cleanup-evidence.json'),JSON.stringify({firstReview,normalizedLegacy,currentReview,driftResult:auditService.status(drift.id),cleanupResult:completed,receipt:auditReceipt,openChoices:[auditTask,'audit-second-choice'],reportPreserved:true,endpointRemoved:true},null,2));
  console.log(JSON.stringify({auditCleanupEvidence:path.join(tmp,'audit-cleanup-evidence.json'),openChoicesPreserved:true}));
}
if(process.env.FM_SHORT_INSTALL_LIVE==='1') {
  const originalPath=process.env.PATH,hashPath=path.join(tmp,'shasum-only');fs.mkdirSync(hashPath);
  for(const name of fs.readdirSync('/usr/bin')) {
    if(name==='sha256sum'||name==='shasum'||name==='node')continue;
    const source=path.join('/usr/bin',name);
    try {if(fs.statSync(source).isFile())fs.symlinkSync(source,path.join(hashPath,name));} catch(error) {if(error.code!=='ENOENT')throw error;}
  }
  fs.symlinkSync(process.execPath,path.join(hashPath,'node'));
  const realShasum=execFileSync('which',['shasum'],{encoding:'utf8'}).trim(),hashLog=path.join(tmp,'hash-calls');
  fs.writeFileSync(path.join(hashPath,'shasum'),`#!/bin/bash\nprintf '%s\\n' "$*" >> "$FM_SHORT_HASH_LOG"\nexec "$FM_SHORT_REAL_SHASUM" "$@"\n`,{mode:0o755});
  process.env.PATH=hashPath;process.env.FM_SHORT_HASH_LOG=hashLog;process.env.FM_SHORT_REAL_SHASUM=realShasum;
  assert.equal(execFileSync('bash',['-c','command -v sha256sum || true'],{encoding:'utf8'}),'');
  const destination=path.join(tmp,'installed');fs.mkdirSync(destination);
  const installRequest=req('install',[{action:'install-shellcheck',destination}],'repeat');installRequest.operations.expiresAt=Date.now()+300000;
  const install=service.submit(installRequest),result=await terminal(install.id);
  assert.equal(result.state,'completed',JSON.stringify(result));
  assert.match(execFileSync(path.join(destination,'shellcheck'),['--version'],{encoding:'utf8'}),/version: 0.11.0/);
  const hashes=fs.readFileSync(hashLog,'utf8').trim().split('\n');assert.equal(hashes.length,3,'archive and both post-install hashes use the fallback exactly once');
  assert.ok(hashes.some(line=>line===`-a 256 ${destination}/shellcheck`));
  process.env.PATH=originalPath;
  console.log(JSON.stringify({installEvidence:service.dir(install.id),result}));
}
console.log(JSON.stringify({kind:'fixture',submitMs:a.submitMs,mainExecutionCalls:0,coordinationCallMetric:'not measured; fixture observer polls are not a parent model workflow',childToolCalls:done.toolCalls,childRequests:done.requests,ownerPid:receipt.executor.pid,parentPid:process.pid,head:expected,receiptBytes:Buffer.byteLength(JSON.stringify(receipt)),cases:['sync effect','duplicate submit','restart result','typed arguments','expiry','cancellation','dirty refusal','bounded detached recovery','actor spoof refusal']}));

await service.reconcile();
await Promise.all([service.notify(a.id),new ShortAgents(home,root).notify(a.id)]);
const outcomes=()=>fs.readFileSync(path.join(home,'state/branch-outcomes.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
assert.equal(outcomes().filter(r=>r.task===a.id).length,1);
fs.unlinkSync(path.join(service.dir(a.id),'notified.json'));await new ShortAgents(home,root).notify(a.id);
const row=outcomes().find(r=>r.task===a.id);assert.equal(outcomes().filter(r=>r.task===a.id).length,1);
assert.match(row.summary,/Result:\ncomplete/);
assert.match(row.summary,/Verified operation receipts:/);
assert.ok(row.summary.includes(JSON.stringify(receipt)),'successful operation notification must include the verified receipt');
assert.ok(!row.summary.includes('Full result:'),'successful operation notification must not require a result lookup');
for(const command of ['mark-read','mark-processed'])execFileSync('bash',[path.join(root,'bin/fm-branch-outcome.sh'),command,'--through',String(row.seq)],{env:{...process.env,FM_HOME:home,FM_STATE_OVERRIDE:path.join(home,'state')}});
for(const id of submittedIds) {
  const file=path.join(service.dir(id),'started.json');
  if(!fs.existsSync(file)) continue;
  const started=JSON.parse(fs.readFileSync(file));
  for(let n=0;n<400;n++) {
    try {
      const stat=fs.readFileSync(`/proc/${started.pid}/stat`,'utf8').split(')')[1].trim().split(' ');
      if(stat[0]==='Z' || stat[19]!==started.identity.start) break;
    } catch(error) {if(error.code==='ENOENT') break;throw error;}
    if(n===399)throw Error('fixture child did not exit after receipt delivery');
    await wait(25);
  }
}
