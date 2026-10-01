// Archived/pruned cleanup bookkeeping through the public MAIN recovery CLI.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {spawnSync,spawn} from 'node:child_process';
import {createHash} from 'node:crypto';

export async function archivedCleanupCases({root,tmp,live,setup,snap,write,cmd,git,processIdentity}) {
  const generation='s1789472265.3949747.1720';
  const names=['request.json','result.json','operation-0.intent.json','operation-0.effect.json','operation-0.output.json'];
  const hash=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  const f=setup('archived-pruned',false,true,generation);
  write(f.home+'/data/task/archive-authority.md','Archived business authority; the original work remains retired.\n');
  write(f.home+'/data/task/current-bookkeeping-authority.md','Current MAIN authorizes bookkeeping only, with every surviving copy retained.\n');
  const inspection=JSON.parse(cmd('bash',[root+'/bin/fm-task-state.sh','inspect','task','--evidence','data/task/archive-authority.md'],f.env));
  const archived=spawnSync('bash',[root+'/bin/fm-task-state.sh','assess','task','--basis',inspection.basis,'--judgment',JSON.stringify({disposition:'archived',outcome:'The fixture is explicitly archived, not successfully completed',remaining_gap:'Physical cleanup bookkeeping remains unverified',authority_ref:'data/task/archive-authority.md',evidence:['data/task/archive-authority.md']})],{env:f.env,encoding:'utf8'});
  assert.equal(archived.status,0,archived.stderr);
  const copyBinding=f.life('cleanup-copy-inspect');
  const projectHead=git('-C',f.project,'rev-parse','HEAD');
  write(f.copy+'/committed.txt','preserve unmerged content\n');git('-C',f.copy,'add','committed.txt');git('-C',f.copy,'commit','-m','unmerged');
  write(f.copy+'/uncommitted.txt','preserve dirty content\n');
  assert.notEqual(git('-C',f.copy,'rev-parse','HEAD'),projectHead,'fixture must contain an unmerged commit');
  assert.match(git('-C',f.copy,'status','--porcelain'),/uncommitted\.txt/,'fixture must contain uncommitted work');
  cmd('tasks-axi',['done','task','--report','data/task/report.md','--file',f.home+'/data/backlog.md'],f.env);
  cmd('tasks-axi',['prune','--keep','0','--file',f.home+'/data/backlog.md'],f.env,f.home);
  assert.match(fs.readFileSync(f.home+'/data/done-archive.md','utf8'),/task/);
  const now=Date.now(),dead={pid:999999,parent:1,start:'1',boot:fs.readFileSync('/proc/sys/kernel/random/boot_id','utf8').trim()};
  write(f.dir+'/started.json',{nonce:f.request.nonce,pid:dead.pid,identity:dead,at:now});
  write(f.dir+'/operation-0.intent.json',{nonce:f.request.nonce,index:0,step:{action:'cleanup',task:'task'},at:now+1});
  write(f.dir+'/operation-0.effect.json',{id:f.request.id,nonce:f.request.nonce,index:0,owner:dead,at:now+2});
  write(f.dir+'/operation-0.output.json',{stdout:'',stderr:'completed cleanup finished endpoint and copy handling, but its backlog close remains pending (Task "task" not found)',error:'historical pruned backlog close refusal'});
  write(f.dir+'/result.json',{id:f.request.id,state:'blocked',summary:'0/1 steps completed; operation chain incomplete',finishedAt:now+3,evidence:f.dir,stage:'model-execution',requests:1,toolCalls:1});
  write(f.marker,{home:f.home,id:f.request.id,nonce:f.request.nonce,index:0,target:'task:'+f.home+'/state:task'});
  fs.unlinkSync(f.home+'/state/task.meta');
  for(const suffix of ['cleanup.json','backlog-close']) assert(!fs.existsSync(f.home+'/state/task.'+suffix));
  const current=f.life('read'),refs=['data/task/brief.md','data/task/report.md','data/done-archive.md','data/task/archive-authority.md','data/task/current-bookkeeping-authority.md'];
  const q={schema:'fm-cleanup-archived-judgment.v1',home:f.home,id:f.request.id,index:0,nonce:f.request.nonce,task:'task',spawn_gen:generation,goal_revision:current.goal_revision,brief_sha256:current.brief_sha256,lifecycle_sha256:hash(f.home+'/data/task/lifecycle.json'),hashes:Object.fromEntries(names.map(name=>[name,hash(f.dir+'/'+name)])),copy_binding:copyBinding,judgment:{disposition:'archived',outcome:'Current MAIN accepts only the archived cleanup bookkeeping settlement',remaining_gap:'',authority_ref:'data/task/current-bookkeeping-authority.md',evidence:refs},evidence:refs.map(ref=>({ref,sha256:hash(f.home+'/'+ref)}))};
  f.qfile=f.home+'/data/task/current-archived-judgment.json';write(f.qfile,q);f.q=q;
  const before={copy:snap(f),archive:fs.readFileSync(f.home+'/data/done-archive.md'),backlog:fs.readFileSync(f.home+'/data/backlog.md'),lifecycle:fs.readFileSync(f.home+'/data/task/lifecycle.json'),original:Object.fromEntries(names.map(name=>[name,fs.readFileSync(f.dir+'/'+name)]))};
  const recover=(env=f.env)=>spawnSync(process.execPath,[root+'/bin/fm-short-agent.mjs','settle-cleanup',f.request.id,'0','--current-judgment',f.qfile],{env,encoding:'utf8',timeout:60000});
  const refuse=(pattern,env=f.env)=>{const result=recover(env);assert.notEqual(result.status,0,result.stdout);assert.match(result.stderr,pattern);assert(fs.existsSync(f.marker));assert(!fs.existsSync(f.dir+'/operation-0.receipt.json'));return result;};
  refuse(/endpoint is present/);
  cmd(f.base+'/bin/herdr',['pane','close',f.pane],f.env);
  for(const [file,key,value,pattern] of [[f.qfile,'home',tmp+'/other',/judgment identity/],[f.qfile,'nonce','wrong',/judgment identity/],[f.qfile,'task','wrong',/judgment identity/],[f.qfile,'spawn_gen','wrong',/judgment identity/],[f.qfile,'lifecycle_sha256','wrong',/lifecycle authority/],[f.marker,'nonce','wrong',/reservation identity/],[f.marker,'id','wrong',/reservation identity/],[f.marker,'index',1,/reservation identity/],[f.dir+'/operation-0.effect.json','index',1,/effect identity/]]) {
    const bytes=fs.readFileSync(file);write(file,{...JSON.parse(bytes),[key]:value});refuse(pattern);fs.writeFileSync(file,bytes);
  }
  refuse(/belongs to MAIN/,{...f.env,FM_SUPERVISION_ACTOR:'branch'});
  const archiveFile=f.home+'/data/done-archive.md',archiveBytes=fs.readFileSync(archiveFile),judgmentBytes=fs.readFileSync(f.qfile);
  fs.writeFileSync(archiveFile,archiveBytes.toString('utf8').replace('data/task/report.md','data/other/report.md'));
  assert.notDeepEqual(fs.readFileSync(archiveFile),archiveBytes,'fixture must remove the exact archived report reference');
  write(f.qfile,{...f.q,evidence:f.q.evidence.map(item=>item.ref==='data/done-archive.md'?{...item,sha256:hash(archiveFile)}:item)});
  refuse(/configured history/);
  fs.writeFileSync(archiveFile,archiveBytes);fs.writeFileSync(f.qfile,judgmentBytes);
  for(const file of [f.home+'/data/task/brief.md',f.home+'/data/task/report.md',f.home+'/data/done-archive.md',f.home+'/data/task/archive-authority.md',f.home+'/data/task/current-bookkeeping-authority.md',...names.map(name=>f.dir+'/'+name)]) {
    const bytes=fs.readFileSync(file);fs.appendFileSync(file,'changed\n');refuse(/changed|JSON|configured history/);fs.writeFileSync(file,bytes);
  }
  const meta=f.home+'/state/task.meta',cleanup=f.home+'/state/task.cleanup.json',pending=f.home+'/state/task.backlog-close';
  for(const [file,pattern] of [[meta,/task binding changed|requires absent task/],[cleanup,/requires absent task/],[pending,/requires absent task/]]) {write(file,'unexpected historical record\n');refuse(pattern);fs.unlinkSync(file);}
  const started=f.dir+'/started.json',startedBytes=fs.readFileSync(started);write(started,{...JSON.parse(startedBytes),pid:process.pid,identity:processIdentity(process.pid)});refuse(/executor to be dead/);fs.writeFileSync(started,startedBytes);
  const child=spawn('sleep',['30'],{env:{...f.env,FM_SHORT_TASK:f.request.id},cwd:tmp,stdio:'ignore'});
  try {refuse(/live executor\/child/);} finally {child.kill();await new Promise(resolve=>child.on('exit',resolve));}
  const conflict=f.home+'/state/conflict.meta';write(conflict,`spawn_gen=other\nbackend=herdr\nherdr_session=${f.request.operationBindings[0].herdr_session}\nherdr_pane_id=${f.pane}\n`);refuse(/claimed by another task/);fs.unlinkSync(conflict);
  const moved=f.copy+'-saved';fs.renameSync(f.copy,moved);fs.mkdirSync(f.copy);try {refuse(/directory\/Git ownership|operation directory identity|Git owner unreadable/);} finally {fs.rmdirSync(f.copy);fs.renameSync(moved,f.copy);}
  const gitDir=f.project+'/.git';fs.renameSync(gitDir,gitDir+'-saved');fs.mkdirSync(gitDir);try {refuse(/Git owner/);} finally {fs.rmdirSync(gitDir);fs.renameSync(gitDir+'-saved',gitDir);}
  for(const lock of [f.dir+'/reconcile.lock',f.marker+'.lock']) {fs.mkdirSync(lock);write(lock+'/pid',String(process.pid));refuse(/lock|owner/);fs.unlinkSync(lock+'/pid');fs.rmdirSync(lock);}
  const closes=()=>fs.readFileSync(f.base+'/herdr.log','utf8').split('\n').filter(line=>/pane[\x1f ]close/.test(line));
  const closeCalls=closes(),result=recover();assert.equal(result.status,0,result.stderr);const settled=JSON.parse(result.stdout);
  assert.equal(settled.settlement,'main-archived-cleanup-readback');assert.equal(settled.originalAttempt,'uncertain');assert.equal(settled.result,'blocked');assert.equal(settled.evidence.archiveDisposition,'archive_done');
  assert(!fs.existsSync(f.marker));assert(!fs.existsSync(meta));assert(!fs.existsSync(cleanup));assert(!fs.existsSync(pending));assert.deepEqual(closes(),closeCalls);
  assert.deepEqual(snap(f),before.copy);assert.deepEqual(fs.readFileSync(f.home+'/data/done-archive.md'),before.archive);assert.deepEqual(fs.readFileSync(f.home+'/data/backlog.md'),before.backlog);assert.deepEqual(fs.readFileSync(f.home+'/data/task/lifecycle.json'),before.lifecycle);
  for(const [name,bytes] of Object.entries(before.original)) assert.deepEqual(fs.readFileSync(f.dir+'/'+name),bytes);
  const repeat=recover();assert.equal(repeat.status,0,repeat.stderr);assert.deepEqual(closes(),closeCalls);assert.deepEqual(snap(f),before.copy);
  console.log(`PASS ${live?'live':'portable'}: archived/pruned bookkeeping settles once with distinct evidence, exact reservation release, retained copy/history/originals and no endpoint or copy effects`);
}
