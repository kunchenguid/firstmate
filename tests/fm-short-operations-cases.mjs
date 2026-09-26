import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const [root,tmp]=process.argv.slice(2);
const {ShortAgents,validate}=await import(pathToFileURL(path.join(root,'bin/fm-short-agent.mjs')));
const {resource}=await import(pathToFileURL(path.join(root,'bin/fm-short-operations.mjs')));
const home=path.join(tmp,'home'),pkg=path.join(tmp,'sdk');
fs.mkdirSync(path.join(home,'state'),{recursive:true});
fs.writeFileSync(path.join(home,'state/.lock'),String(process.pid));
fs.mkdirSync(path.join(pkg,'dist/core'),{recursive:true});
fs.writeFileSync(path.join(pkg,'package.json'),JSON.stringify({name:'@earendil-works/pi-coding-agent',main:'dist/index.js',type:'module'}));
fs.writeFileSync(path.join(pkg,'dist/core/http-dispatcher.js'),'export function configureHttpDispatcher() {}');
fs.writeFileSync(path.join(pkg,'dist/index.js'),`
export const createExtensionRuntime=()=>({});
export const ModelRuntime={create:async()=>({getAvailable:async()=>[{provider:'openai-codex',id:'gpt-5.6-luna'}],streamSimple:async()=>{}})};
export const SessionManager={inMemory:()=>({})};
export const SettingsManager={inMemory:x=>x};
export async function createAgentSession(o) {
 const messages=[];
 return {session:{messages,systemPrompt:o.resourceLoader.getSystemPrompt(),getActiveToolNames:()=>o.tools,subscribe(){},dispose(){},getLastAssistantText:()=> 'complete',
 async prompt(prompt) {
  const p=JSON.parse(prompt);
  if(p.goal.startsWith('delay')) await new Promise(r=>setTimeout(r,500));
  await o.modelRuntime.streamSimple({}, {}, {});
  const tool=o.customTools.find(t=>t.name==='run_operations');
  if(!tool) throw Error('operations absent');
  const first=await tool.execute('op',p.goal==='inject'?{command:'touch BAD'}:{});
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
const req=(key,steps=[{action:'sync',project}],goal='run')=>({key,goal,acceptance:'owner receipt',materials:[],operations:{authority:'isolated test fixture',expiresAt:Date.now()+60000,steps},budget:{timeMs:30000,outputTokens:3072}});
const wait=ms=>new Promise(r=>setTimeout(r,ms));
async function terminal(id){for(let n=0;n<12000;n++){const s=service.status(id);if(s.finishedAt)return s;await wait(25);}throw Error('task did not terminate');}
assert.equal(validate({key:'default',goal:'read',acceptance:'answer',materials:[]}).model,'gpt-5.6-luna');
assert.equal(validate({key:'override',goal:'read',acceptance:'answer',materials:[],provider:'explicit',model:'chosen'}).provider,'explicit');
assert.throws(()=>service.submit(req('unknown',[{action:'restart',task:'foo'}])),/unsupported/);
const missingAuthority=req('no-authority');delete missingAuthority.operations.authority;assert.throws(()=>service.submit(missingAuthority),/authority/);
fs.writeFileSync(path.join(home,'state/.lock'),'1');assert.throws(()=>service.submit(req('wrong-primary')),/primary/);fs.writeFileSync(path.join(home,'state/.lock'),String(process.pid));
const expired=req('expired');expired.operations.expiresAt=1;assert.throws(()=>service.submit(expired),/expired/);
const request=req('sync');const a=service.submit(request);assert.equal(service.submit(request).id,a.id);
assert.equal(git('-C',project,'rev-parse','HEAD'),old,'submit did not execute the effect');
const done=await terminal(a.id);assert.equal(done.state,'completed',JSON.stringify(done));
assert.equal(git('-C',project,'rev-parse','HEAD'),expected);
const receipts=done.operations;assert.deepEqual(receipts,[{index:0,action:'sync',state:'completed'}]);
assert.ok(!fs.existsSync(resource(home,request.operations.steps[0]).file));
const child=JSON.parse(fs.readFileSync(path.join(service.dir(a.id),'started.json')));assert.notEqual(child.pid,process.pid);
const receipt=JSON.parse(fs.readFileSync(path.join(service.dir(a.id),'operation-0.receipt.json')));assert.notEqual(receipt.executor.pid,process.pid);assert.equal(receipt.evidence.head,expected);
assert.equal(new ShortAgents(home,root).submit(request).id,a.id);
const replay=await terminal(a.id);assert.equal(replay.finishedAt,done.finishedAt);
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
const verb=process.argv[5];let head='c'.repeat(40);if(verb==='status'){s.statusReads=(s.statusReads||0)+1;fs.writeFileSync(f,JSON.stringify(s));if(s.bad){console.log('null');process.exit(0);}if(s.changed&&s.statusReads>1)head='d'.repeat(40);}
const url='https://code.byted.org/example/shortlab/merge_requests/7';
if(verb==='merge'){s.calls++;s.merged=true;fs.writeFileSync(f,JSON.stringify(s));if(s.crash){
 const path=require('path'),effect=JSON.parse(fs.readFileSync(path.join(process.env.FM_HOME,'state/short-agents',process.env.FM_SHORT_TASK,'operation-0.effect.json')));
 const cmd=fs.readFileSync('/proc/'+effect.owner.pid+'/cmdline','utf8');
 if(!cmd.includes('/bin/fm-pr-merge.sh'))throw Error('refuse killing an unverified fixture owner');
 process.kill(effect.owner.pid,'SIGKILL');process.exit(9);
}if(s.lost)process.exit(9);console.log(JSON.stringify({status:'success',data:{merged:true}}));}
else if(verb==='status') console.log(JSON.stringify({status:'success',data:{repository:{path:'example/shortlab'},merge_request:{id:'123',number:7,status:s.merged?'merged':'open',url,source_branch:'topic',target_branch:'main',source_commit_id:head},mergeability:{mergeable:!s.red,checks:[{passed:!s.red}],failed_checks:s.red?['red']:[]},review:{status:'passed'},check_runs:{summary:'no_checks',total_count:0,page_size:100,passed_count:0,failed_count:0,running_count:0,items:[]}}}));
else if(verb==='get')console.log(JSON.stringify({status:'success',data:{repository:{path:'example/shortlab'},merge_request:{Id:'123',Number:7,Status:s.merged?'merged':'open',URL:url,SourceBranchName:'topic',TargetBranchName:'main',MergeCommitId:'d'.repeat(40)},version:{SourceCommitId:head}}}));
else process.exit(2);
`,{mode:0o755});
process.env.PATH=fakebin+path.delimiter+process.env.PATH;
fs.mkdirSync(path.join(home,'data'),{recursive:true});fs.mkdirSync(path.join(home,'config'),{recursive:true});
fs.writeFileSync(path.join(home,'data/backlog.md'),'## In flight\n\n## Queued\n\n## Done\n');
fs.writeFileSync(path.join(home,'config/backlog-backend'),'manual\n');
const writeTask=(name)=>fs.writeFileSync(path.join(home,'state',name+'.meta'),`kind=ship\nmode=no-mistakes\nspawn_gen=g1\nwindow=unused-fixture\nworktree=${tmp}/absent\nproject=${project}\npr=https://code.byted.org/example/shortlab/merge_requests/7\npr_head=${'c'.repeat(40)}\n`);
writeTask('merge-one');
const mergeStep={action:'merge',task:'merge-one',url:'https://code.byted.org/example/shortlab/merge_requests/7'};
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
// Reset only this isolated fixture's proven-dead attempt before unrelated cases.
for(const file of fs.readdirSync(path.join(home,'state')).filter(x=>x.startsWith('.short-')&&x.endsWith('.json'))) {const f=path.join(home,'state',file),r=JSON.parse(fs.readFileSync(f));if(r.id===crashed.id)fs.unlinkSync(f);}
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
if(process.env.FM_SHORT_CLEANUP_TARGET) {
  const target=JSON.parse(fs.readFileSync(process.env.FM_SHORT_CLEANUP_TARGET));
  assert.ok(/^fm-lab-/.test(target.session) && target.session===process.env.HERDR_LAB_SESSION,'cleanup requires the generated named lab');
  fs.writeFileSync(path.join(home,'state/cleanup-one.meta'),`kind=ship\nmode=local-only\nspawn_gen=g-lab\nwindow=${target.session}:${target.pane}\nendpoint_task_id=cleanup-one\nworktree=${tmp}/absent-cleaned-worktree\nproject=${project}\nbackend=herdr\nherdr_session=${target.session}\nherdr_workspace_id=${target.workspace}\nherdr_tab_id=${target.tab}\nherdr_pane_id=${target.pane}\n`);
  const cleanMeta=fs.readFileSync(path.join(home,'state/cleanup-one.meta'),'utf8');
  const dirtyCopy=path.join(tmp,'dirty-copy');git('-C',project,'worktree','add','-b','unlanded-lab',dirtyCopy);
  fs.writeFileSync(path.join(dirtyCopy,'unlanded'),'preserve');
  for(const [label,copy] of [['dirty',dirtyCopy],['unlanded',dirtyCopy],['shared',dirtyCopy]]) {
    if(label==='unlanded') {git('-C',dirtyCopy,'add','.');git('-C',dirtyCopy,'commit','-m','unlanded fixture');}
    if(label==='shared') fs.writeFileSync(path.join(home,'state/other-task.meta'),`worktree=${copy}\n`);
    const task='cleanup-'+label;
    fs.writeFileSync(path.join(home,'state',task+'.meta'),cleanMeta.replace('cleanup-one',task).replace(`${tmp}/absent-cleaned-worktree`,copy));
    const negative=service.submit(req(task,[{action:'cleanup',task}]));
    const refused=await terminal(negative.id);assert.equal(refused.state,'blocked',JSON.stringify(refused));
    assert.ok(fs.existsSync(path.join(home,'state',task+'.meta')));
    assert.ok(fs.existsSync(path.join(dirtyCopy,'unlanded')));
    assert.ok(!fs.existsSync(path.join(service.dir(negative.id),'operation-0.effect.json')),'cleanup preflight refused before effects');
    if(label==='shared') fs.unlinkSync(path.join(home,'state/other-task.meta'));
    fs.unlinkSync(path.join(home,'state',task+'.meta')); // isolated rejected fixture only
  }
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
  execFileSync('bash',['-c','. "$1/bin/fm-wake-lib.sh"; fm_treehouse_slot_owner_claim "$2" cleanup-landed "$3"','fixture',root,lease.path,home]);
  const herdr=(...args)=>JSON.parse(execFileSync(process.env.HERDR_LAB_HELPER,['run',target.session,...args],{encoding:'utf8',env:{...process.env,PATH:process.env.FM_SHORT_TEST_BASE_PATH}}));
  const pane=herdr('tab','create','--workspace',target.workspace,'--cwd',path.join(tmp,'idle'),'--label','fm-cleanup-landed','--no-focus').result;
  const beforePanes=herdr('pane','list','--workspace',target.workspace).result.panes.map(p=>p.pane_id);
  const beforePool=JSON.parse(treehouse('status','--json'));
  const beforeCopy={path:lease.path,exists:fs.existsSync(lease.path),head:git('-C',lease.path,'rev-parse','HEAD'),status:git('-C',lease.path,'status','--porcelain')};
  const landedMeta=cleanMeta.replaceAll('cleanup-one','cleanup-landed').replace(`${tmp}/absent-cleaned-worktree`,lease.path).replace(`project=${project}`,`project=${cleanupProject}`).replaceAll(target.pane,pane.root_pane.pane_id).replaceAll(target.tab,pane.tab.tab_id);
  fs.writeFileSync(path.join(home,'state/cleanup-landed.meta'),landedMeta);
  const unrelatedMeta=`kind=ship\nspawn_gen=g-other\nworktree=${unrelated.path}\nproject=${cleanupProject}\n`;
  fs.writeFileSync(path.join(home,'state/unrelated-lab.meta'),unrelatedMeta);
  const landedRequest=req('cleanup-landed',[{action:'cleanup',task:'cleanup-landed'}]);landedRequest.budget.timeMs=120000;landedRequest.operations.expiresAt=Date.now()+120000;
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
}
if(process.env.FM_SHORT_INSTALL_LIVE==='1') {
  const destination=path.join(tmp,'installed');fs.mkdirSync(destination);
  const installRequest=req('install',[{action:'install-shellcheck',destination}],'repeat');installRequest.budget.timeMs=300000;installRequest.operations.expiresAt=Date.now()+300000;
  const install=service.submit(installRequest),result=await terminal(install.id);
  assert.equal(result.state,'completed',JSON.stringify(result));
  assert.match(execFileSync(path.join(destination,'shellcheck'),['--version'],{encoding:'utf8'}),/version: 0.11.0/);
  console.log(JSON.stringify({installEvidence:service.dir(install.id),result}));
}
console.log(JSON.stringify({kind:'fixture',submitMs:a.submitMs,mainExecutionCalls:0,coordinationCallMetric:'not measured; fixture observer polls are not a parent model workflow',childToolCalls:done.toolCalls,childRequests:done.requests,ownerPid:receipt.executor.pid,parentPid:process.pid,head:expected,receiptBytes:Buffer.byteLength(JSON.stringify(receipt)),cases:['sync effect','duplicate submit','restart result','typed arguments','expiry','cancellation','dirty refusal','bounded detached recovery','actor spoof refusal']}));

await service.reconcile();
await Promise.all([service.notify(a.id),new ShortAgents(home,root).notify(a.id)]);
const outcomes=()=>fs.readFileSync(path.join(home,'state/branch-outcomes.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
assert.equal(outcomes().filter(r=>r.task===a.id).length,1);
fs.unlinkSync(path.join(service.dir(a.id),'notified.json'));await new ShortAgents(home,root).notify(a.id);
const row=outcomes().find(r=>r.task===a.id);assert.equal(outcomes().filter(r=>r.task===a.id).length,1);
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
