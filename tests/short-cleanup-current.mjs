// Present-state retirement through the public MAIN recovery interface.
import fs from 'node:fs';
import net from 'node:net';
import assert from 'node:assert/strict';
import {spawnSync,spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
export async function currentCleanupCases({root,tmp,live,setup,run,snap,write,read,cmd,git,shellQuote,processIdentity,basePath}) {
 const sockets=[];
 const hash=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
 const names=['request.json','result.json','operation-0.intent.json','operation-0.effect.json','operation-0.output.json'];
 const state=(f,op,...args)=>JSON.parse(cmd('bash',[root+'/bin/fm-task-state.sh',op,'task',...args],f.env));
 const generation='s1790772537.1906761.31007';
 async function stage(label,backlog=false){
  const f=setup(label,false,backlog,generation),session=f.request.operationBindings[0].herdr_session;
  if(!live){
   const socket=f.base+'/owned.sock',server=net.createServer();sockets.push(server);const previousCwd=process.cwd();process.chdir(f.base);await new Promise(resolve=>server.listen('owned.sock',resolve));process.chdir(previousCwd);
   const anchor=f.h('workspace','create','--cwd',f.base,'--label','anchor','--no-focus').result;
   const old=f.base+'/bin/herdr-fixture';fs.renameSync(f.base+'/bin/herdr',old);
   // The fixture uses a real socket and real kernel process identity, and
   // doubles only Herdr's protocol. Real Herdr uses the same owner path below.
   fs.writeFileSync(f.base+'/bin/herdr',`#!/usr/bin/env bash
set -eu
case "$1 \${2:-}" in
 'status --json') jq -n --arg s ${shellQuote(session)} --arg socket ${shellQuote(socket)} '{client:{version:"0.8.0",protocol:20},server:{running:true,session:$s,socket:$socket,version:"0.8.0",protocol:20}}';;
 'session list') jq -n --arg s ${shellQuote(session)} --arg socket ${shellQuote(socket)} '{sessions:[{name:$s,running:true,socket_path:$socket}]}';;
 'pane get') ${shellQuote(old)} "$@" | jq 'if .result.pane then .result.pane.terminal_id=(env.FM_TEST_TERMINAL // "terminal-fixture") else . end';;
 'pane close') if [ -e ${shellQuote(f.base+'/close-refusal')} ]; then echo injected-close-refusal >&2;exit 1;fi;exec ${shellQuote(old)} "$@";;
 'pane process-info') jq -n --arg pane "\${4:-}" --argjson pid ${process.pid} '{result:{process_info:{pane_id:$pane,shell_pid:$pid,foreground_processes:[]}}}';;
 'workspace list') ${shellQuote(old)} "$@" | jq --arg ws ${shellQuote(anchor.workspace.workspace_id)} --arg tab ${shellQuote(anchor.tab.tab_id)} '.result.workspaces |= map(.+{focused:(.workspace_id==$ws),active_tab_id:(if .workspace_id==$ws then $tab else (.workspace_id+":t2") end)})';;
 'tab list') ${shellQuote(old)} "$@" | jq --arg tab ${shellQuote(anchor.tab.tab_id)} '.result.tabs |= map(.+{focused:(.tab_id==$tab)})';;
 *) exec ${shellQuote(old)} "$@";;
esac
`,{mode:0o755});
  }
  f.h('tab','create','--workspace',f.request.operationBindings[0].herdr_workspace_id,'--cwd',f.base,'--label','unrelated-sibling','--no-focus');
  const journal=f.home+'/state/task.herdr-presentation';
  const info=f.h('pane','get',f.pane).result.pane,processInfo=f.h('pane','process-info','--pane',f.pane).result.process_info;
  const instance=cmd('bash',['-c','. "$1/bin/backends/herdr.sh"; fm_backend_herdr_session_instance "$2"','fixture',root,session],f.env);
  const start=cmd('ps',['-p',String(processInfo.shell_pid),'-o','lstart='],{...f.env,LC_ALL:'C'});
  write(journal,`version=3\ntask_id=task\nprojection_id=abcdefghijklmnopqrstuv\nhome=${f.home}\nsession=${session}\nworkspace_id=${info.workspace_id}\ntab_id=${info.tab_id}\npane_id=${f.pane}\nspawn_gen=${generation}\nterminal_id=${info.terminal_id}\nsession_instance=${instance}\nshell_pid=${processInfo.shell_pid}\nshell_start=${start}\n`);
  const initial=state(f,'inspect','--evidence','data/task/report.md','--evidence','state/task.meta');
  assert.equal(spawnSync('bash',[root+'/bin/fm-task-state.sh','assess','task','--basis',initial.basis,'--judgment',JSON.stringify({disposition:'accepted',outcome:'initial acceptance',remaining_gap:'',authority_ref:'data/task/report.md',evidence:['data/task/report.md','state/task.meta']})],{env:f.env,encoding:'utf8'}).status,0);
  write(f.home+'/state/task.meta',fs.readFileSync(f.home+'/state/task.meta','utf8')+'pr=local:fixture\npr_head='+git('-C',f.copy,'rev-parse','HEAD')+'\n');
  assert.equal(run(f).state,'blocked');assert.match(read(f.dir+'/operation-0.output.json').stderr,/evidence digest changed/);
  write(f.home+'/data/task/current-authority.md','Independent MAIN acceptance and unconditional copy retention\n');
  const refs=['data/task/brief.md','data/task/report.md','state/task.meta','state/task.herdr-presentation'];
  const authority='data/task/current-authority.md',inspection=state(f,'inspect',...refs.concat(authority).flatMap(ref=>['--evidence',ref])),record=f.life('read');
  const q={schema:'fm-cleanup-current-judgment.v1',home:f.home,id:f.request.id,index:0,nonce:f.request.nonce,task:'task',spawn_gen:generation,goal_revision:record.goal_revision,brief_sha256:record.brief_sha256,hashes:Object.fromEntries(names.map(n=>[n,hash(f.dir+'/'+n)])),copy_binding:f.life('cleanup-copy-inspect'),candidate:record.owner_receipts.merge[0].facts,basis:inspection.basis,judgment:{disposition:'accepted',outcome:'Current MAIN accepts delivered fixture and authorizes exact endpoint retirement, preserving all copies and original uncertainty',remaining_gap:'',authority_ref:authority,evidence:refs.concat(authority)},evidence:inspection.evidence};
  f.qfile=f.home+'/data/task/current-judgment.json';write(f.qfile,q);f.q=q;f.journal=journal;return f;
 }
 const recover=(f,index=0,env=f.env)=>spawnSync(process.execPath,[root+'/bin/fm-short-agent.mjs','settle-cleanup',f.request.id,String(index),'--current-judgment',f.qfile],{env,encoding:'utf8',timeout:60000});
 const refuse=(f,pattern,index=0,env=f.env)=>{const r=recover(f,index,env);assert.notEqual(r.status,0,r.stdout);assert.match(r.stderr,pattern);assert(fs.existsSync(f.marker));assert(!fs.existsSync(f.dir+'/operation-0.receipt.json'));return r;};
 try {
  if(live)cmd(process.env.HERDR_LAB_HELPER,['viewer','start',process.env.HERDR_LAB_SESSION],{...process.env,PATH:basePath});
  const f=await stage('current-present',true),original=Object.fromEntries(names.map(n=>[n,fs.readFileSync(f.dir+'/'+n)]));
  // This path preserves shared, dirty and unmerged copies without even asking
  // the disposal owner whether those bytes qualify for return.
  write(f.copy+'/dirty.txt','retain dirty bytes\n');git('-C',f.copy,'checkout','-b','current-unmerged');write(f.copy+'/unmerged.txt','retain committed bytes\n');git('-C',f.copy,'add','unmerged.txt');git('-C',f.copy,'commit','-m','unmerged');
  write(f.home+'/state/shared.meta',`worktree=${f.copy}\n`);const before=snap(f);
  refuse(f,/index is not a cleanup step/,1);refuse(f,/belongs to MAIN/,0,{...f.env,FM_SUPERVISION_ACTOR:'branch'});
  for(const [file,key,value,pattern] of [[f.qfile,'home',tmp+'/other',/judgment identity/],[f.qfile,'id','short-'+'a'.repeat(64),/judgment identity/],[f.qfile,'nonce','wrong',/judgment identity/],[f.qfile,'task','wrong',/judgment identity/],[f.qfile,'goal_revision',2,/intent\/generation/],[f.qfile,'brief_sha256','wrong',/intent\/generation/],[f.qfile,'index',1,/judgment identity/],[f.qfile,'spawn_gen','wrong',/judgment identity/],[f.qfile,'candidate',{url:'wrong',head:'a'.repeat(40)},/candidate/],[f.marker,'nonce','wrong',/reservation identity/],[f.marker,'index',1,/reservation identity/],[f.marker,'id','wrong',/reservation identity/],[f.marker,'home',tmp+'/other',/reservation identity/],[f.dir+'/operation-0.effect.json','index',1,/effect identity/]]){
   const bytes=fs.readFileSync(file);write(file,{...JSON.parse(bytes),[key]:value});refuse(f,pattern);fs.writeFileSync(file,bytes);
  }
  for(const file of [f.home+'/data/task/brief.md',f.home+'/data/task/report.md',f.home+'/data/task/current-authority.md',f.journal,...names.map(n=>f.dir+'/'+n)]){
   const bytes=fs.readFileSync(file);fs.appendFileSync(file,'changed\n');refuse(f,/changed|JSON/);fs.writeFileSync(file,bytes);
  }
  const journalBytes=fs.readFileSync(f.journal);fs.unlinkSync(f.journal);refuse(f,/ENOENT/);fs.writeFileSync(f.journal,journalBytes);
  const meta=f.home+'/state/task.meta',metaBytes=fs.readFileSync(meta);fs.unlinkSync(meta);refuse(f,/current metadata|ENOENT/);fs.writeFileSync(meta,metaBytes);
  const started=f.dir+'/started.json',startedBytes=fs.readFileSync(started);write(started,{...JSON.parse(startedBytes),pid:process.pid,identity:processIdentity(process.pid)});refuse(f,/executor to be dead/);fs.writeFileSync(started,startedBytes);
  const child=spawn('sleep',['30'],{env:{...f.env,FM_SHORT_TASK:f.request.id},cwd:tmp,stdio:'ignore'});try{refuse(f,/live executor\/child/);}finally{child.kill();await new Promise(resolve=>child.on('exit',resolve));}
  for(const lock of [f.dir+'/reconcile.lock',f.marker+'.lock',cmd('bash',['-c','. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"','fixture',root,f.project],f.env)]){
   fs.mkdirSync(lock);write(lock+'/pid',String(process.pid));refuse(f,/lock|owner/);fs.unlinkSync(lock+'/pid');fs.rmdirSync(lock);
  }
  const shared=f.home+'/state/shared.meta',sharedBytes=fs.readFileSync(shared);fs.appendFileSync(shared,`herdr_session=${f.request.operationBindings[0].herdr_session}\nherdr_pane_id=${f.pane}\n`);refuse(f,/claimed by another task/);fs.writeFileSync(shared,sharedBytes);
  // A freshly inspected historical journal still cannot supply missing launch
  // identity. Acceptance of bytes does not replace endpoint ownership proof.
  const savedQ=fs.readFileSync(f.qfile),savedJournal=fs.readFileSync(f.journal);
  write(f.journal,savedJournal.toString().split('\n').filter(l=>! /^(spawn_gen|terminal_id|session_instance|shell_pid|shell_start)=/.test(l)).join('\n'));
  const legacy=state(f,'inspect',...f.q.judgment.evidence.flatMap(ref=>['--evidence',ref]));write(f.qfile,{...f.q,basis:legacy.basis,evidence:legacy.evidence});refuse(f,/launch-owner identity/);fs.writeFileSync(f.qfile,savedQ);fs.writeFileSync(f.journal,savedJournal);
  const moved=f.copy+'-saved';fs.renameSync(f.copy,moved);fs.mkdirSync(f.copy);try{refuse(f,/directory\/Git ownership/);}finally{fs.rmdirSync(f.copy);fs.renameSync(moved,f.copy);}
  if(!live)refuse(f,/terminal\/process identity/,0,{...f.env,FM_TEST_TERMINAL:'reused-terminal'});
  const result=recover(f);assert.equal(result.status,0,result.stderr);const recovered=JSON.parse(result.stdout);assert.equal(recovered.originalAttempt,'uncertain');assert.equal(recovered.result,'blocked');assert.equal(recovered.settlement,'main-current-cleanup-readback');assert(!fs.existsSync(f.marker));assert(!fs.existsSync(meta));assert.deepEqual(snap(f),before);
  for(const [n,bytes] of Object.entries(original))assert.deepEqual(fs.readFileSync(f.dir+'/'+n),bytes);
  assert.equal(f.life('due').due,false);const calls=fs.readFileSync(f.base+'/herdr.log');assert.equal(recover(f).status,0);assert.deepEqual(fs.readFileSync(f.base+'/herdr.log'),calls,'completed recovery makes no endpoint calls');
  write(f.dir+'/operation-0.output.json','changed original');assert.notEqual(recover(f).status,0);assert.equal(f.life('due').due,true);fs.writeFileSync(f.dir+'/operation-0.output.json',original['operation-0.output.json']);
  const notificationCalls=fs.readFileSync(f.base+'/herdr.log');
  const notification=spawnSync(process.execPath,['--experimental-strip-types',root+'/tests/short-notification-consumer.mjs',root,f.home,f.request.id,f.base+'/notification-code'],{env:f.env,encoding:'utf8',timeout:45000});assert.equal(notification.status,0,notification.stderr);process.stdout.write(notification.stdout);assert.deepEqual(fs.readFileSync(f.base+'/herdr.log'),notificationCalls,'notification never repeats endpoint effects');
  const absent=await stage('current-absent');cmd(absent.base+'/bin/herdr',['pane','close',absent.pane],absent.env);const absentCalls=fs.readFileSync(absent.base+'/herdr.log','utf8').split('\n').filter(l=>/pane[\x1f ]close/.test(l));assert.equal(recover(absent).status,0);assert.deepEqual(fs.readFileSync(absent.base+'/herdr.log','utf8').split('\n').filter(l=>/pane[\x1f ]close/.test(l)),absentCalls);
  const interrupted=await stage('current-bookkeeping',true),stopFile=interrupted.base+'/stop-backlog';write(stopFile,'fail once');
  const realTasks=cmd('which',['tasks-axi'],{...process.env,PATH:basePath});
  fs.writeFileSync(interrupted.base+'/bin/tasks-axi',`#!/usr/bin/env bash\nif [ "$1" = done ] && [ -e ${shellQuote(stopFile)} ]; then rm ${shellQuote(stopFile)};echo injected-backlog-failure >&2;exit 1;fi\nexec ${shellQuote(realTasks)} "$@"\n`,{mode:0o755});
  refuse(interrupted,/backlog .*pending/);assert(!fs.existsSync(interrupted.home+'/state/task.meta'));assert.equal(interrupted.life('due').due,true);
  const interruptedCalls=fs.readFileSync(interrupted.base+'/herdr.log','utf8').split('\n').filter(l=>/pane[\x1f ]close/.test(l));assert.equal(recover(interrupted).status,0);assert.equal(interrupted.life('due').due,false);assert.deepEqual(fs.readFileSync(interrupted.base+'/herdr.log','utf8').split('\n').filter(l=>/pane[\x1f ]close/.test(l)),interruptedCalls);
  if(!live){
   const pending=await stage('current-pending');write(pending.base+'/close-refusal','refuse close');refuse(pending,/Command failed/);fs.unlinkSync(pending.base+'/close-refusal');refuse(pending,/close is uncertain/);assert.equal(pending.life('due').due,true);
   cmd(pending.base+'/bin/herdr',['pane','close',pending.pane],pending.env);assert.equal(recover(pending).status,0);assert.equal(pending.life('due').due,false);
  }
  console.log(`PASS ${live?'live':'portable'}: separately judged current retirement, original uncertainty/files retained, dirty/shared/unmerged copy preserved, absent endpoint no close, identity/evidence/live/concurrent refusals`);
 } finally {for(const server of sockets)await new Promise(resolve=>server.close(resolve));}
}
