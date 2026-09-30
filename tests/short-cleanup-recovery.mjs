// Portable owner behavior and optional named-lab Herdr/Treehouse recovery.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync,spawnSync,spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
const [root,tmp,mode='portable']=process.argv.slice(2);
if(process.platform!=='linux'){console.log('skip: cleanup recovery requires Linux process identity');process.exit(0);}
const {executeOperations,bindOperations,processIdentity,resource}=await import(pathToFileURL(root+'/bin/fm-short-operations.mjs'));
const write=(file,obj)=>fs.writeFileSync(file,typeof obj==='string'?obj:JSON.stringify(obj)+'\n',{mode:0o600});
const read=file=>JSON.parse(fs.readFileSync(file,'utf8'));
const shellQuote=value=>"'"+String(value).replaceAll("'","'\\''")+"'";
const mkdir=dir=>fs.mkdirSync(dir,{recursive:true});
const cmd=(exe,args,env=process.env,cwd=root)=>execFileSync(exe,args,{env,cwd,encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:45000}).trim();
if(mode==='child'){
  const home=process.argv[5],dir=process.argv[6],request=read(dir+'/request.json');
  write(dir+'/started.json',{nonce:request.nonce,pid:process.pid,identity:processIdentity(process.pid),at:Date.now()});
  try{await executeOperations({home,root,dir:()=>dir},request,()=>{});write(dir+'/result.json',{id:request.id,state:'completed',finishedAt:Date.now(),evidence:dir});}
  catch(error){write(dir+'/result.json',{id:request.id,state:'blocked',summary:error.message,finishedAt:Date.now(),evidence:dir});}
  if(process.env.FM_FIXTURE_ORPHAN){
    const orphan=spawn('sleep',['60'],{env:{PATH:process.env.PATH},cwd:tmp,stdio:'ignore'});write(dir+'/orphan.pid',String(orphan.pid));orphan.unref();
  }
  process.exit(0);
}
const live=mode==='live';
if(live)assert(/^fm-lab-/.test(process.env.HERDR_LAB_SESSION??'')&&process.env.HERDR_LAB_HELPER,'named lab required');
for(const role of ['AUTHOR','COMMITTER']){process.env[`GIT_${role}_NAME`]='fixture';process.env[`GIT_${role}_EMAIL`]='fixture@example.invalid';}
process.env.GIT_CONFIG_GLOBAL='/dev/null';process.env.GIT_CONFIG_NOSYSTEM='1';
mkdir(tmp);const basePath=process.env.FM_SHORT_TEST_BASE_PATH??process.env.PATH;
const git=(...args)=>cmd('git',args);
function setup(label,interrupt=false,backlog=false,generation='g-fixture',goal=1){
  const base=tmp+'/'+label,home=base+'/home',project=base+'/project',remote=base+'/remote.git',bin=base+'/bin',pool=base+'/pool',alias=base+'/alias';
  for(const dir of [home+'/state',home+'/data/task',home+'/config',bin,pool])mkdir(dir);
  write(home+'/state/.lock',String(process.pid));fs.symlinkSync(pool,alias);
  git('init','--bare','--initial-branch=main',remote);git('clone',remote,project);
  write(project+'/treehouse.toml',`max_trees = 1\nroot = ${JSON.stringify(alias)}\n`);
  write(project+'/base.txt','landed base\n');git('-C',project,'add','.');git('-C',project,'commit','-m','fixture');git('-C',project,'push','origin','main');git('-C',project,'remote','set-head','origin','main');
  let copy,managed;
  if(live){const lease=JSON.parse(cmd('treehouse',['get','--lease','--json','--lease-holder',label],{...process.env,PATH:basePath},project));managed=lease.path;copy=fs.realpathSync(managed);assert(copy.startsWith(tmp+'/'));}
  else{copy=pool+'/1/project';git('-C',project,'worktree','add','-b',label,copy);managed=alias+'/1/project';write(pool+'/treehouse-state.json',{worktrees:[{name:'1',path:managed}]});}
  const treehouse=live?cmd('which',['treehouse'],{...process.env,PATH:basePath}):'treehouse';
  fs.writeFileSync(bin+'/treehouse',`#!/usr/bin/env bash
set -eu
if [ "$1" = return ]; then
  printf '%s\\n' "$*" >> ${shellQuote(base+'/effects.log')}
  if [ -f ${shellQuote(base+'/interrupt')} ]; then echo ${shellQuote('worktree '+copy+' is not managed by treehouse')} >&2; exit 1; fi
  [ "\${3:-}" = ${shellQuote(managed)} ] || { echo wrong-managed-path >&2; exit 1; }
fi
${live?'exec '+shellQuote(treehouse)+' "$@"':`case "$1" in status) echo '1 available' ;; enter) echo ${shellQuote(managed)} ;; return) ;; *) exit 1 ;; esac`}
`,{mode:0o755});
  if(interrupt)write(base+'/interrupt','injected unmanaged refusal\n');
  const session=live?process.env.HERDR_LAB_SESSION:'fixture';
  if(live){
    fs.writeFileSync(bin+'/herdr',`#!/usr/bin/env bash
set -eu
args=(); while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then [ "$2" = "$HERDR_LAB_SESSION" ] || exit 70; shift 2
  else args+=("$1");shift;fi
done
printf '%s\\n' "\${args[*]}" >> ${shellQuote(base+'/herdr.log')}
PATH=${shellQuote(basePath)} exec "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "\${args[@]}"
`,{mode:0o755});
  }else cmd('bash',['-c','. "$1/tests/fixtures.sh"; fm_test_fake_herdr_spawn "$2"','fixture',root,bin]);
  const env={...process.env,PATH:bin+':'+basePath,FM_HOME:home,FM_ROOT_OVERRIDE:root,FM_STATE_OVERRIDE:home+'/state',FM_DATA_OVERRIDE:home+'/data',FM_CONFIG_OVERRIDE:home+'/config',FM_BACKEND_HERDR_BIN:bin+'/herdr',HERDR_SESSION:session,FM_SUPERVISION_ACTOR:'main',FM_FAKE_HERDR_STATE:base+'/state.json',FM_HERDR_LOG:base+'/herdr.log'};
  delete env.FM_SHORT_TASK;delete env.FM_SHORT_STEP;
  const h=(...args)=>JSON.parse(cmd(bin+'/herdr',args,env));
  const ws=h('workspace','create','--cwd',base,'--label',label,'--no-focus').result;
  const pane=ws.root_pane.pane_id;
  write(home+'/state/task.meta',`kind=ship\nmode=local-only\nspawn_gen=${generation}\nworktree=${copy}\nproject=${project}\nbackend=herdr\nwindow=${session}:${pane}\nherdr_session=${session}\nherdr_workspace_id=${ws.workspace.workspace_id}\nherdr_tab_id=${ws.tab.tab_id}\nherdr_pane_id=${pane}\nendpoint_task_id=task\n`);
  write(home+'/data/task/brief.md','Synthetic accepted cleanup fixture\n');write(home+'/data/task/report.md','Retained report\n');
  const life=(op,...args)=>JSON.parse(cmd('python3',[root+'/bin/fm-task-lifecycle.py',op,'task',...args],env));
  life('init');life('owner-receipt','--execution-generation',generation,'--kind','merge','--facts',JSON.stringify({url:'local:fixture',head:git('-C',copy,'rev-parse','HEAD')}));
  for(let n=2;n<=goal;n++){const revision=life('read');write(home+'/goal.json',{...revision,goal_revision:n});cmd('bash',[root+'/bin/fm-task-state.sh','reconcile','task','--expected-revision',String(revision.revision),'--record',home+'/goal.json'],env);}
  const record=life('read');record.disposition='accepted';record.assessment.remaining_gap='';
  record.assessment.evidence.push({ref:home+'/data/task/report.md',sha256:createHash('sha256').update(fs.readFileSync(home+'/data/task/report.md')).digest('hex')});write(home+'/accepted.json',record);
  cmd('bash',[root+'/bin/fm-task-state.sh','reconcile','task','--expected-revision',String(record.revision),'--record',home+'/accepted.json'],env);
  cmd('bash',['-c','. "$1/bin/fm-wake-lib.sh"; fm_treehouse_slot_owner_claim "$2" task "$3" "$4"','fixture',root,copy,home,generation],env);
  if(backlog){write(home+'/.tasks.toml','backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n');cmd('tasks-axi',['add','task','Recovery fixture','--kind','ship','--repo','sample','--start','--file',home+'/data/backlog.md'],env);}
  const step={action:'cleanup',task:'task'},id='short-'+createHash('sha256').update(label).digest('hex'),dir=home+'/state/short-agents/'+id;mkdir(dir);
  const request={version:2,id,input:{key:label,goal:'fixture',acceptance:'owner proof',materials:[],operations:{authority:'isolated fixture',expiresAt:Date.now()+600000,steps:[step]}},operationBindings:bindOperations(home,{expiresAt:Date.now()+600000,steps:[step]}),acceptedAt:Date.now(),nonce:'fixture-'+label};
  write(dir+'/request.json',request);
  return {base,home,project,copy,dir,request,env,pane,h,life,marker:resource(home,step).file};
}
const run=f=>{const child=spawnSync(process.execPath,[root+'/tests/short-cleanup-recovery.mjs',root,tmp,'child',f.home,f.dir],{env:f.env,detached:true,encoding:'utf8',timeout:45000});assert.equal(child.status,0,child.stderr);return read(f.dir+'/result.json');};
const snap=f=>({head:git('-C',f.copy,'rev-parse','HEAD'),branch:git('-C',f.copy,'branch','--show-current'),status:git('-C',f.copy,'status','--porcelain'),inode:fs.statSync(f.copy).ino,files:git('-C',f.copy,'ls-files','--cached','--others','--exclude-standard','-z').split('\0').filter(Boolean).map(n=>[n,fs.readFileSync(f.copy+'/'+n).toString('base64')])});
const recover=(f,index=0,env=f.env)=>spawnSync(process.execPath,[root+'/bin/fm-short-agent.mjs','settle-cleanup',f.request.id,String(index)],{env,encoding:'utf8',timeout:30000});
const fail=(f,pattern,index=0,env=f.env)=>{const p=recover(f,index,env);assert.notEqual(p.status,0,p.stdout);assert.match(p.stderr,pattern);assert(fs.existsSync(f.marker));assert(!fs.existsSync(f.dir+'/operation-0.receipt.json'));};
// Historical owner fixture: the same facts were hashed before preservation
// fields existed. Python's JSON serialization is the persisted digest format.
function historicalObservation(f){
  const file=f.home+'/data/task/lifecycle.json',record=read(file),receipt=f.life('cleanup-read');
  assert.equal(record.cleanup_ref,f.home+'/state/task.cleanup.json');
  assert.equal(receipt.phases.directory_return.reason_code,'copy-disposal-attempt');
  const key=cmd('python3',['-c',`import json,hashlib,sys
c=json.load(open(sys.argv[1]));o={k:c.get(k) for k in ('task_id','spawn_gen','goal_revision','journal_sha256','launch_binding','copy_binding')}
o['phases']={n:{k:p.get(k) for k in ('state','reason_code')} for n,p in c['phases'].items() if n!='record_close'}
print(hashlib.sha256(json.dumps(o,sort_keys=True).encode()).hexdigest())`,record.cleanup_ref],f.env);
  assert.notEqual(key,record.cleanup_observation_key,'historical/current projection must diverge');
  write(file,{...record,cleanup_observation_key:key});
  return file;
}
const success=setup('alias-success');assert.equal(run(success).state,'completed');assert(!fs.existsSync(success.marker));assert(!fs.existsSync(success.home+'/state/task.meta'));assert.equal(read(success.dir+'/operation-0.receipt.json').evidence.copyDisposition,'returned-or-already-absent');
const f=setup('pending-recovery',true,true);assert.equal(run(f).state,'blocked');assert.equal(f.life('cleanup-read').phases.directory_return.state,'pending');
const legacyLifecycle=historicalObservation(f),legacyBytes=fs.readFileSync(legacyLifecycle,'utf8');
assert.equal(f.life('completion-read').disposition,'accepted');assert.equal(fs.readFileSync(legacyLifecycle,'utf8'),legacyBytes,'readback must not rewrite historical evidence');
const ordinary=spawnSync('bash',[root+'/bin/fm-task-state.sh','assess','task'],{env:f.env,encoding:'utf8'});assert.equal(ordinary.status,6);assert.match(ordinary.stderr,/pending short-operation receipt/);
write(f.copy+'/uncommitted.txt','preserve dirty content\n');git('-C',f.copy,'checkout','-b','unmerged');write(f.copy+'/committed.txt','preserve unmerged content\n');git('-C',f.copy,'add','committed.txt');git('-C',f.copy,'commit','-m','unmerged');
write(f.home+'/state/shared.meta',`worktree=${f.copy}\n`);
const original=Object.fromEntries(['request.json','result.json','operation-0.intent.json','operation-0.effect.json','operation-0.output.json'].map(n=>[n,fs.readFileSync(f.dir+'/'+n,'utf8')])),before=snap(f),effects=fs.readFileSync(f.base+'/effects.log','utf8');
fail(f,/index is not a cleanup step/,1);
for(const [file,key,value,pattern] of [[f.marker,'nonce','wrong',/reservation identity/],[f.marker,'home',tmp+'/other',/reservation identity/],[f.marker,'index',1,/reservation identity/],[f.dir+'/operation-0.effect.json','nonce','wrong',/effect identity/]]){
  const bytes=fs.readFileSync(file,'utf8');write(file,{...JSON.parse(bytes),[key]:value});fail(f,pattern);fs.writeFileSync(file,bytes);
}
fail(f,/belongs to MAIN/,0,{...f.env,FM_SUPERVISION_ACTOR:'branch'});
const bypass=spawnSync('bash',[root+'/bin/fm-teardown.sh','task','--preserve-copy-recovery','--expect-spawn-gen','g-fixture'],{env:{...f.env,FM_SHORT_CLEANUP_RECOVERY:f.request.id,FM_SHORT_CLEANUP_STEP:'0'},encoding:'utf8'});assert.notEqual(bypass.status,0);assert.match(bypass.stderr,/reconcile.lock|serialization/);assert(fs.existsSync(f.marker));assert(fs.existsSync(f.home+'/state/task.meta'));
const reqBytes=fs.readFileSync(f.dir+'/request.json','utf8');write(f.dir+'/request.json',{...JSON.parse(reqBytes),input:{...f.request.input,operations:{...f.request.input.operations,steps:[{action:'cleanup',task:'wrong'}]}}});fail(f,/step\/task\/generation changed/);write(f.dir+'/request.json',reqBytes);
const meta=f.home+'/state/task.meta',metaBytes=fs.readFileSync(meta,'utf8');
for(const replacement of ['spawn_gen=wrong','endpoint_task_id=wrong']){write(meta,metaBytes.replace(replacement.split('=')[0]+'='+ (replacement.startsWith('spawn')?'g-fixture':'task'),replacement));fail(f,/task binding changed/);write(meta,metaBytes);}
const cleanupFile=f.home+'/state/task.cleanup.json',cleanupBytes=fs.readFileSync(cleanupFile,'utf8');
for(const edit of [c=>({...c,spawn_gen:'wrong'}),c=>({...c,goal_revision:c.goal_revision+1}),c=>({...c,phases:{...c.phases,pane_close:{state:'confirmed',reason_code:'changed'}}}),c=>({...c,phases:{...c.phases,directory_return:{state:'retained',reason_code:'changed'}}}),c=>({...c,journal_sha256:'a'.repeat(64)}),c=>({...c,preservation_ref:null}),c=>({...c,preservation_sha256:null})]){
  write(cleanupFile,edit(JSON.parse(cleanupBytes)));fail(f,/cleanup facts changed|receipt identity conflict/);assert(!fs.existsSync(f.dir+'/operation-0.preservation.json'));write(cleanupFile,cleanupBytes);
}
write(f.home+'/data/task/report.md','changed unrelated acceptance evidence\n');fail(f,/evidence digest changed/);write(f.home+'/data/task/report.md','Retained report\n');
fs.renameSync(f.copy,f.copy+'-original');mkdir(f.copy);fail(f,/identity changed/);fs.rmdirSync(f.copy);fs.renameSync(f.copy+'-original',f.copy);
const gitDir=f.project+'/.git';fs.renameSync(gitDir,gitDir+'-original');mkdir(gitDir);fail(f,/Git owner unreadable|Git owner changed/);fs.rmdirSync(gitDir);fs.renameSync(gitDir+'-original',gitDir);
const started=f.dir+'/started.json',startedBytes=fs.readFileSync(started,'utf8');write(started,{...JSON.parse(startedBytes),pid:process.pid,identity:processIdentity(process.pid)});fail(f,/executor to be dead/);write(started,startedBytes);
const child=spawn('sleep',['30'],{env:{...f.env,FM_SHORT_TASK:f.request.id},cwd:tmp,stdio:'ignore'});
try{fail(f,/live executor\/child/);}finally{child.kill();await new Promise(resolve=>child.on('exit',resolve));}
write(f.home+'/state/.lease-task',`branch\t${process.pid}\t${Math.floor(Date.now()/1000)}\n`);fail(f,/leased to the branch/);fs.unlinkSync(f.home+'/state/.lease-task');
const copyLock=cmd('bash',['-c','. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"','fixture',root,f.project],f.env);mkdir(copyLock);write(copyLock+'/pid',String(process.pid));fail(f,/another copy owner/);fs.unlinkSync(copyLock+'/pid');fs.rmdirSync(copyLock);
for(const lock of [f.dir+'/reconcile.lock',f.marker+'.lock']){mkdir(lock);write(lock+'/pid',String(process.pid));fail(f,/lock/);fs.unlinkSync(lock+'/pid');fs.rmdirSync(lock);}
const shared=f.home+'/state/shared.meta',sharedBytes=fs.readFileSync(shared,'utf8');write(shared,sharedBytes+`herdr_session=${f.request.operationBindings[0].herdr_session}\nherdr_pane_id=${f.pane}\n`);fail(f,/claimed by another task/);write(shared,sharedBytes);
const closes=fs.readFileSync(f.base+'/herdr.log','utf8').split('\n').filter(line=>/pane[\x1f ]close/.test(line));
const p=recover(f);assert.equal(p.status,0,p.stderr);const settled=JSON.parse(p.stdout);assert.equal(settled.evidence.copyDisposition,'retained-unverified');assert.equal(settled.result,'blocked');assert(!fs.existsSync(f.marker));assert(!fs.existsSync(meta));assert.deepEqual(snap(f),before);assert.equal(fs.readFileSync(f.base+'/effects.log','utf8'),effects);
assert.deepEqual(fs.readFileSync(f.base+'/herdr.log','utf8').split('\n').filter(line=>/pane[\x1f ]close/.test(line)),closes);
for(const [n,bytes] of Object.entries(original))assert.equal(fs.readFileSync(f.dir+'/'+n,'utf8'),bytes);
assert.match(cmd('tasks-axi',['show','task','--file',f.home+'/data/backlog.md'],f.env),/state:\s+done/);
assert.equal(f.life('due').due,false);
const calls=fs.readFileSync(f.base+'/herdr.log','utf8');assert.equal(recover(f).status,0);assert.equal(fs.readFileSync(f.base+'/herdr.log','utf8'),calls);
write(f.dir+'/operation-0.output.json',JSON.stringify({...JSON.parse(original['operation-0.output.json']),stderr:'changed failure evidence'}));assert.notEqual(recover(f).status,0);assert.equal(f.life('due').due,true);write(f.dir+'/operation-0.output.json',original['operation-0.output.json']);assert.equal(f.life('due').due,false);
const copyOnly=spawnSync('bash',[root+'/bin/fm-teardown.sh','task','--copy-only','--expect-spawn-gen','g-fixture'],{env:f.env,encoding:'utf8'});assert.equal(copyOnly.status,0,copyOnly.stderr);assert.match(copyOnly.stdout,/no disposal replay/);assert.deepEqual(snap(f),before);
// A real orphan in the runner's kernel session remains excluded after its
// parent exits, even with no inherited owner environment and an unrelated cwd.
const orphanFixture=setup('orphan-child',true);orphanFixture.env.FM_FIXTURE_ORPHAN='1';assert.equal(run(orphanFixture).state,'blocked');
const orphanPid=Number(fs.readFileSync(orphanFixture.dir+'/orphan.pid','utf8'));
try{fail(orphanFixture,/live executor\/child session/);}finally{process.kill(orphanPid,'SIGTERM');}
for(let n=0;n<100;n++){try{processIdentity(orphanPid);}catch{break;}await new Promise(resolve=>setTimeout(resolve,100));if(n===99)throw Error('orphan did not stop');}
assert.equal(recover(orphanFixture).status,0);
// Failure after metadata removal resumes only the exact pending close marker.
const interrupted=setup('bookkeeping-retry',true,true);assert.equal(run(interrupted).state,'blocked');
const realTasks=cmd('which',['tasks-axi'],{...process.env,PATH:basePath}),stopFile=interrupted.base+'/stop-backlog';write(stopFile,'fail once');
fs.writeFileSync(interrupted.base+'/bin/tasks-axi',`#!/usr/bin/env bash\nif [ "$1" = done ] && [ -e ${shellQuote(stopFile)} ]; then rm ${shellQuote(stopFile)};echo injected-backlog-failure >&2;exit 1;fi\nexec ${shellQuote(realTasks)} "$@"\n`,{mode:0o755});
const savedResult=fs.readFileSync(interrupted.dir+'/result.json','utf8'),savedCopy=snap(interrupted),savedEffects=fs.readFileSync(interrupted.base+'/effects.log','utf8');
fail(interrupted,/backlog .*pending/);assert(!fs.existsSync(interrupted.home+'/state/task.meta'));assert(fs.existsSync(interrupted.home+'/state/task.backlog-close'));assert.equal(interrupted.life('due').due,true);
assert.equal(recover(interrupted).status,0);assert.equal(interrupted.life('due').due,false);assert.equal(fs.readFileSync(interrupted.dir+'/result.json','utf8'),savedResult);assert.deepEqual(snap(interrupted),savedCopy);assert.equal(fs.readFileSync(interrupted.base+'/effects.log','utf8'),savedEffects);
const chain=setup('chain-recovery',true,false,'s1790725410.4156501.4288',3),steps=[{action:'sync',project:chain.project},{action:'cleanup',task:'task'},{action:'sync',project:chain.project}];
const realGit=cmd('which',['git'],{...process.env,PATH:basePath}),gitCalls=chain.base+'/git-calls';
fs.writeFileSync(chain.base+'/bin/git',`#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> ${shellQuote(gitCalls)}\nexec ${shellQuote(realGit)} "$@"\n`,{mode:0o755});
chain.request.input.operations.steps=steps;chain.request.operationBindings=bindOperations(chain.home,chain.request.input.operations);write(chain.dir+'/request.json',chain.request);assert.equal(run(chain).state,'blocked');
historicalObservation(chain);assert.equal(chain.life('read').goal_revision,3);assert.equal(chain.life('read').execution_generation,'s1790725410.4156501.4288');
const chainOriginal=Object.fromEntries(['request.json','result.json','operation-1.intent.json','operation-1.effect.json','operation-1.output.json'].map(n=>[n,fs.readFileSync(chain.dir+'/'+n,'utf8')])),chainCopy=snap(chain);
const syncCalls=()=>fs.readFileSync(gitCalls,'utf8').split('\n').filter(line=>/(^| )(fetch|merge|checkout|reset)( |$)/.test(line)),syncBefore=syncCalls();assert(syncBefore.length>0,'the first sync exercised real Git effects');
const early=fs.readFileSync(chain.dir+'/operation-0.receipt.json','utf8'),chainEffects=fs.readFileSync(chain.base+'/effects.log','utf8');assert.equal(recover(chain,1).status,0);assert.equal(fs.readFileSync(chain.dir+'/operation-0.receipt.json','utf8'),early);assert(!fs.existsSync(chain.dir+'/operation-2.intent.json'));assert.equal(fs.readFileSync(chain.base+'/effects.log','utf8'),chainEffects);
assert.deepEqual(syncCalls(),syncBefore);
for(const [name,bytes] of Object.entries(chainOriginal))assert.equal(fs.readFileSync(chain.dir+'/'+name,'utf8'),bytes);
assert.deepEqual(snap(chain),chainCopy);assert(!fs.existsSync(chain.marker));assert(!fs.existsSync(chain.home+'/state/task.meta'));assert.equal(chain.life('due').due,false);
console.log(`PASS ${mode}: pre-preservation cleanup observation, exact original generation and step 1, changed facts/acceptance refusals`);
console.log(`PASS ${mode}: alias return, exact pending preservation, unchanged failure/content, identity/live-child/lease/project-owner refusals, idempotent settlement and lifecycle completion`);
