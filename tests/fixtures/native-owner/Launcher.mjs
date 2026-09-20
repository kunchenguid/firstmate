// Actual launcher integration, not the fixture controller or a scripted model.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {spawn,spawnSync} from 'node:child_process';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../..');
const area=fs.mkdtempSync(path.join(os.tmpdir(),'fm-launcher-e2e-')),code=path.join(area,'code');
const image=process.env.FM_NATIVE_TEST_JQ_IMAGE;
if(!image)throw Error('FM_NATIVE_TEST_JQ_IMAGE must name an existing local image with jq and GNU timeout');
const read=file=>JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function command(exe,args){const result=spawnSync(exe,args,{encoding:'utf8',timeout:120000});if(result.status!==0)throw Error(result.stderr||result.stdout);return result;}
function contains(root,candidate){const relative=path.relative(root,candidate);return relative===''||(!path.isAbsolute(relative)&&relative!=='..'&&!relative.startsWith('..'+path.sep));}
const localAppData=command('powershell.exe',['-NoProfile','-NonInteractive','-Command','[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)']).stdout.trim();
const windowsTemp=path.resolve(localAppData,'Temp');
const outsideRoot=path.resolve(process.env.FM_NATIVE_TEST_OUTSIDE_ROOT||path.join(repo,'data/native-launcher'));
const outside=path.join(outsideRoot,path.basename(area)+'-outside');
assert.equal(contains(windowsTemp,outside),false,'FM_NATIVE_TEST_OUTSIDE_ROOT must resolve outside the canonical Windows temporary directory');
command('git',['-c','core.symlinks=true','clone','--quiet','--no-local','--single-branch',repo,code]);
fs.cpSync(path.join(repo,'bin/native-owner'),path.join(code,'bin/native-owner'),{recursive:true});
for(const name of ['fm-native-codex.ps1','fm-session-lock-lib.sh','fm-sessionstart-nudge.sh','fm-harness.sh','fm-backlog-transition-lib.sh','fm-supervision-lib.sh','fm-wake-lib.sh','fm-startup-network.sh','fm-inbox.sh','fm-lock.sh'])fs.copyFileSync(path.join(repo,'bin',name),path.join(code,'bin',name));
const launcher=path.join(code,'bin/fm-native-codex.ps1');
command('powershell.exe',['-NoProfile','-File',launcher,'-BuildOnly']);
const removedAlias=spawnSync('powershell.exe',['-NoProfile','-File',launcher,'-BuildOnly','-Home',path.join(area,'alias')],{encoding:'utf8',timeout:120000});
assert.notEqual(removedAlias.status,0,'The removed -Home alias was still accepted');
function start(home,verify=true,env=process.env){
 const args=['-NoProfile','-File',launcher,'-Experimental','-OperationalHome',home,'-JqImage',image];if(verify)args.push('-VerifyOnly');
 const child=spawn('powershell.exe',args,{stdio:['pipe','pipe','pipe'],env});let stdout='',stderr='';
 child.stdout.on('data',data=>stdout+=data);child.stderr.on('data',data=>stderr+=data);child.stdin.on('error',()=>{});
 const done=new Promise((resolve,reject)=>{child.on('error',reject);child.on('exit',exit=>resolve({exit,stdout,stderr}));});
 return {child,done,home};
}
async function bound(promise,session,ms=230000){let timer;try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>{session.child.stdin.write('/quit\n');reject(Error('Launcher exceeded its bound; inspect '+session.home));},ms);})]);}finally{clearTimeout(timer);}}
async function ready(session,previous){
 for(let i=0;i<2200;i++){
  if(session.child.exitCode!==null)throw Error(JSON.stringify(await session.done));
  try {const owner=read(path.join(session.home,'owner-probe.json'));if(owner.state==='live'&&typeof owner.generation==='string'&&owner.generation!==previous){const runtime=path.join(session.home,'state/native-runtime',owner.generation);if(read(path.join(runtime,'host.json')).ready)return {owner,runtime};}}catch(error){if(error.code!=='ENOENT'&&!(error instanceof SyntaxError))throw error;}
  await sleep(100);
 }
 throw Error('Launcher readiness timed out');
}
async function waitUntil(session,label,predicate,ms=40000){
 const limit=Date.now()+ms;
 while(Date.now()<limit){
  if(session.child.exitCode!==null)throw Error(label+': '+JSON.stringify(await session.done));
  try {if(predicate())return;}catch(error){if(error.code!=='ENOENT'&&!(error instanceof SyntaxError))throw error;}
  await sleep(50);
 }
 throw Error(label+' timed out');
}
const records=[];
const live=process.argv.includes('--live');
if(live&&process.env.FM_LIVE_NATIVE_CODEX!=='1')throw Error('Live launcher tests require FM_LIVE_NATIVE_CODEX=1');
const posix=value=>value.replaceAll('\\','/').replace(/^([A-Za-z]):/,(_,drive)=>'/'+drive.toLowerCase());
const contractHome=path.join(area,'predicate-contracts'),contractEnv={...process.env,FM_HOME:posix(contractHome),MSYS:'winsymlinks:nativestrict'};
for(const script of ['fm-inbox.sh','fm-startup-network.sh']){
 const executable=posix(path.join(code,'bin',script)),help=spawnSync('C:/Program Files/Git/bin/bash.exe',['--noprofile','--norc',executable,'--help'],{env:contractEnv,encoding:'utf8',timeout:30000});
 assert.equal(help.status,0,help.stderr);assert(help.stdout.includes('native-admission-predicate <wake-queue>'),help.stdout);
 const invalid=spawnSync('C:/Program Files/Git/bin/bash.exe',['--noprofile','--norc',executable,'native-admission-predicate'],{env:contractEnv,encoding:'utf8',timeout:30000});
 assert.equal(invalid.status,2,invalid.stderr);assert(invalid.stderr.includes('native-admission-predicate <wake-queue>'),invalid.stderr);
}
records.push('internal owner predicates publish and enforce their usage, output, and exit contracts');
function enqueue(home,message){
 fs.mkdirSync(home,{recursive:true});
 const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!key.startsWith('FM_')&&!key.startsWith('PI_')));
 Object.assign(env,{FM_HOME:posix(home),FM_PROBE_JQ_IMAGE:image,MSYS:'winsymlinks:nativestrict'});
 const result=spawnSync('C:/Program Files/Git/bin/bash.exe',['--noprofile','--norc','-c','export PATH="$1/bin/native-owner/tools:/usr/bin:/bin:$PATH"; export FM_HOME; FM_HOME=$(cygpath -u "$3"); exec /usr/bin/bash "$1/bin/fm-inbox.sh" note "$2"','launcher-test',posix(code),message,home],{env,encoding:'utf8',timeout:30000});
 assert.equal(result.status,0,JSON.stringify({error:result.error?.message,stdout:result.stdout,stderr:result.stderr}));return result.stdout.trim().split(/\s+/)[1];
}
function pausedEnqueue(home,message,control){
 const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!key.startsWith('FM_')&&!key.startsWith('PI_')));
 Object.assign(env,{MSYS:'winsymlinks:nativestrict'});
 const child=spawn('C:/Program Files/Git/bin/bash.exe',['--noprofile','--norc','-c','home=$(cygpath -u "$3") || exit; exec /usr/bin/bash "$1" "$2" "$home" "$4" "$5"','paused-inbox',posix(path.join(repo,'tests/fixtures/native-owner/pause-inbox-publication.sh')),posix(code),home,posix(control),message],{env,stdio:['ignore','pipe','pipe']});let stdout='',stderr='';
 child.stdout.on('data',data=>stdout+=data);child.stderr.on('data',data=>stderr+=data);
 return new Promise((resolve,reject)=>{child.on('error',reject);child.on('exit',exit=>resolve({exit,stdout,stderr}));});
}
function appendStartupWake(home,state){
 const env={...process.env,FM_HOME:home,MSYS:'winsymlinks:nativestrict'};
 const result=spawnSync('C:/Program Files/Git/bin/bash.exe',['--noprofile','--norc','-c','export FM_ROOT_OVERRIDE FM_STATE_OVERRIDE; FM_ROOT_OVERRIDE=$(cygpath -u "$1"); FM_STATE_OVERRIDE=$(cygpath -u "$3"); . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"; fm_wake_append_startup_network "$2"','startup-wake',code,state,path.join(home,'state')],{env,encoding:'utf8',timeout:30000});
 assert.equal(result.status,0,JSON.stringify({error:result.error?.message,stdout:result.stdout,stderr:result.stderr}));
}
const journalRows=home=>fs.readFileSync(path.join(home,'owner-receipts.jsonl'),'utf8').trim().split(/\r?\n/).filter(Boolean).map(JSON.parse);
const acknowledgedNote=(home,note)=>journalRows(home).some(row=>row.event==='acknowledged'&&Array.isArray(row.payload?.notes)&&row.payload.notes.includes(note));
const pendingNote=(home,note)=>fs.readFileSync(path.join(home,'state/.wake-queue'),'utf8').split(/\r?\n/).filter(Boolean).some(row=>row.split('\t')[3]===`inbox:${note}`);
const home=path.join(area,'home');fs.mkdirSync(path.join(home,'data'),{recursive:true});
fs.writeFileSync(path.join(home,'data/backlog.md'),'## In flight\n\n## Queued\n\n## Done\n');
const first=start(home);const initial=await ready(first);console.error('first ready',area);
const competitor=start(home);competitor.child.stdin.end();const refused=await bound(competitor.done,competitor,20000);
console.error('competitor returned',refused);assert.notEqual(refused.exit,0);assert.equal(read(path.join(home,'owner-probe.json')).generation,initial.owner.generation);
console.error('quitting first');first.child.stdin.write('/quit\n');assert.equal((await bound(first.done,first,20000)).exit,0);
assert.equal(read(path.join(initial.runtime,'shutdown.json')).stopped,true);
records.push('exclusive launch and confirmed shutdown');
const startup=path.join(code,'bin/native-owner/startup.sh'),startupSource=fs.readFileSync(startup,'utf8');
fs.writeFileSync(startup,'#!/usr/bin/env bash\nexit 7\n');
const failed=start(home);failed.child.stdin.end();assert.notEqual((await bound(failed.done,failed,20000)).exit,0);
assert.equal(fs.readFileSync(path.join(home,'state/.lock'),'utf8').trim(),'native:'+initial.owner.generation);
fs.writeFileSync(startup,startupSource);
const again=start(home);const restarted=await ready(again,initial.owner.generation);assert.notEqual(restarted.owner.generation,initial.owner.generation);
assert.equal(fs.readFileSync(path.join(home,'state/.lock'),'utf8').trim(),'native:'+restarted.owner.generation);
again.child.stdin.end();assert.equal((await bound(again.done,again,20000)).exit,0);
records.push('restart after an intervening failed startup retains proven-dead ownership history');
const titled=path.join(area,'titled-empty');fs.mkdirSync(path.join(titled,'data'),{recursive:true});
fs.writeFileSync(path.join(titled,'data/backlog.md'),'# Backlog\r\n');
const titledSession=start(titled);await ready(titledSession);titledSession.child.stdin.end();
assert.equal((await bound(titledSession.done,titledSession,20000)).exit,0);
records.push('owner-provided backlog admission accepts the canonical CRLF title-only skeleton');
const populated=path.join(area,'populated');fs.mkdirSync(path.join(populated,'state'),{recursive:true});fs.writeFileSync(path.join(populated,'state/work.meta'),'preserve');
const blocked=start(populated);blocked.child.stdin.end();assert.notEqual((await bound(blocked.done,blocked,20000)).exit,0);
assert.equal(fs.readFileSync(path.join(populated,'state/work.meta'),'utf8'),'preserve');assert.equal(fs.existsSync(path.join(populated,'owner-probe.json')),false);
records.push('populated home refused without changing its records');
for(const [name,relative] of [['orphan-status','state/orphan.status'],['interrupted-close','state/orphan.backlog-close'],['residual-turn-end','state/orphan.turn-ended'],['away-marker','state/.afk'],['away-contract','state/.afk-contract']]){
 const residualHome=path.join(area,name),record=path.join(residualHome,relative),contents='preserve residual task state';
 fs.mkdirSync(path.dirname(record),{recursive:true});fs.writeFileSync(record,contents);
 const refusedResidual=start(residualHome);refusedResidual.child.stdin.end();assert.notEqual((await bound(refusedResidual.done,refusedResidual,20000)).exit,0);
 assert.equal(fs.readFileSync(record,'utf8'),contents);assert.equal(fs.existsSync(path.join(residualHome,'owner-probe.json')),false);
}
records.push('orphan status, interrupted-close, turn-end, and away records refused before lease acquisition and preserved');
const namedHarness=path.join(area,'codex.exe'),holderPidFile=path.join(area,'ordinary-holder.pid'),liveLockHome=path.join(area,'live-lock'),liveLock=path.join(liveLockHome,'state/.lock');
fs.copyFileSync('C:/Program Files/Git/usr/bin/sleep.exe',namedHarness);fs.mkdirSync(path.dirname(liveLock),{recursive:true});
const holder=spawn('C:/Program Files/Git/bin/bash.exe',['--noprofile','--norc','-c','"$1" 60 & child=$!; printf "%s\\n" "$child" > "$2"; wait "$child"','lock-holder',posix(namedHarness),posix(holderPidFile)],{stdio:'ignore'});
const holderDone=new Promise(resolve=>holder.on('exit',resolve));
let holderPid;
try {
 await waitUntil({child:holder,done:holderDone,home:liveLockHome},'ordinary lock holder',()=>{holderPid=fs.readFileSync(holderPidFile,'utf8').trim();return /^[0-9]+$/.test(holderPid);},10000);
 const holderAlive=spawnSync('C:/Program Files/Git/bin/bash.exe',['--noprofile','--norc','-c','kill -0 "$1"','holder-check',holderPid],{encoding:'utf8',timeout:10000});assert.equal(holderAlive.status,0,holderAlive.stderr);
 fs.writeFileSync(liveLock,holderPid+'\n');
 const locked=start(liveLockHome);locked.child.stdin.end();const lockedResult=await bound(locked.done,locked,20000);
 assert.notEqual(lockedResult.exit,0);assert.equal(fs.readFileSync(liveLock,'utf8'),holderPid+'\n');assert.equal(fs.existsSync(path.join(liveLockHome,'owner-probe.json')),false);
}finally{
 if(holderPid)spawnSync('C:/Program Files/Git/bin/bash.exe',['--noprofile','--norc','-c','kill "$1" 2>/dev/null || true','holder-stop',holderPid],{encoding:'utf8',timeout:10000});
 await Promise.race([holderDone,sleep(3000)]);
}
const unknownLockHome=path.join(area,'unknown-lock'),unknownLock=path.join(unknownLockHome,'state/.lock');fs.mkdirSync(path.dirname(unknownLock),{recursive:true});fs.writeFileSync(unknownLock,'native:'+'0'.repeat(32)+'\n');
const unknownLocked=start(unknownLockHome);unknownLocked.child.stdin.end();assert.notEqual((await bound(unknownLocked.done,unknownLocked,20000)).exit,0);assert.equal(fs.readFileSync(unknownLock,'utf8'),'native:'+'0'.repeat(32)+'\n');assert.equal(fs.existsSync(path.join(unknownLockHome,'owner-probe.json')),false);
records.push('live ordinary and unresolved native session locks refuse launch before native ownership publication');
const queuedHome=path.join(area,'supported-queued-restart'),queuedNote=enqueue(queuedHome,'Preserve this supported notification across a native restart.');
const queuedBody=fs.readFileSync(path.join(queuedHome,'state/inbox',queuedNote+'.note'),'utf8');
const queuedSession=start(queuedHome);const queuedReady=await ready(queuedSession);queuedSession.child.stdin.end();
assert.equal((await bound(queuedSession.done,queuedSession,20000)).exit,0);
assert.equal(fs.readFileSync(path.join(queuedHome,'state/inbox',queuedNote+'.note'),'utf8'),queuedBody);
assert(fs.readFileSync(path.join(queuedHome,'state/.wake-queue'),'utf8').includes('inbox:'+queuedNote));
const queuedRestart=start(queuedHome);await ready(queuedRestart,queuedReady.owner.generation);queuedRestart.child.stdin.end();
assert.equal((await bound(queuedRestart.done,queuedRestart,20000)).exit,0);
assert.equal(fs.readFileSync(path.join(queuedHome,'state/inbox',queuedNote+'.note'),'utf8'),queuedBody);
records.push('producer-created inbox and native handling recovery remain admissible across restart');
const uncorrelatedHome=path.join(area,'uncorrelated-acked'),uncorrelatedNote=enqueue(uncorrelatedHome,'Preserve this ordinary interrupted acknowledgement.');
const uncorrelatedMarker=path.join(uncorrelatedHome,'state/.watcher-down'),uncorrelatedMarkerBefore=fs.readFileSync(uncorrelatedMarker,'utf8');
const uncorrelatedAcked=uncorrelatedMarkerBefore.replace(/^(pending|announced):/,'acked:');assert.notEqual(uncorrelatedAcked,uncorrelatedMarkerBefore);fs.writeFileSync(uncorrelatedMarker,uncorrelatedAcked);
const uncorrelatedQueue=fs.readFileSync(path.join(uncorrelatedHome,'state/.wake-queue'),'utf8'),uncorrelatedBody=fs.readFileSync(path.join(uncorrelatedHome,'state/inbox',uncorrelatedNote+'.note'),'utf8');
const uncorrelated=start(uncorrelatedHome);uncorrelated.child.stdin.end();assert.notEqual((await bound(uncorrelated.done,uncorrelated,20000)).exit,0);
assert.equal(fs.existsSync(path.join(uncorrelatedHome,'owner-probe.json')),false);assert.equal(fs.readFileSync(uncorrelatedMarker,'utf8'),uncorrelatedAcked);assert.equal(fs.readFileSync(path.join(uncorrelatedHome,'state/.wake-queue'),'utf8'),uncorrelatedQueue);assert.equal(fs.readFileSync(path.join(uncorrelatedHome,'state/inbox',uncorrelatedNote+'.note'),'utf8'),uncorrelatedBody);
records.push('uncorrelated acknowledged recovery is refused and preserved before lease acquisition');
const historicalHome=path.join(area,'historical-startup-completion'),historicalState=path.join(historicalHome,'state'),historicalStatus=path.join(historicalState,'.startup-network.status');
fs.mkdirSync(historicalState,{recursive:true});fs.writeFileSync(historicalStatus,'generation=historical\nstate=failed\n');appendStartupWake(historicalHome,'failed');
const historicalRow=fs.readFileSync(path.join(historicalState,'.wake-queue'),'utf8');fs.writeFileSync(historicalStatus,'generation=newer\nstate=done\n');
const historicalSession=start(historicalHome);await ready(historicalSession);historicalSession.child.stdin.end();assert.equal((await bound(historicalSession.done,historicalSession,20000)).exit,0);
assert(fs.readFileSync(path.join(historicalState,'.wake-queue'),'utf8').includes(historicalRow.trim()));
records.push('queued startup failure survives a newer startup status and remains admissible');
const hostScript=path.join(code,'bin/native-owner/codex-host.mjs'),hostSource=fs.readFileSync(hostScript,'utf8');
fs.copyFileSync(path.join(repo,'tests/fixtures/native-owner/fake-app-server.mjs'),path.join(code,'bin/native-owner/fake-app-server.mjs'));
fs.writeFileSync(hostScript,"import fs from 'node:fs';\nimport path from 'node:path';\nimport {runCodexHost} from './codex-host-runtime.mjs';\nimport {createFakeAppServer} from './fake-app-server.mjs';\nconst pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));\ntry { await runCodexHost({spawnAppServer:()=>createFakeAppServer('success'),mcpServerNames:[],afterAutomaticTurn:async ({evidence})=>{if(evidence.automatic.length===1){fs.writeFileSync(path.join(process.env.FM_PROBE_HOME,'first-automatic-complete'),'ready');while(!fs.existsSync(path.join(process.env.FM_PROBE_HOME,'continue-after-first')))await pause(20);}}}); } catch(error) { console.error(error.message); process.exitCode=1; }\n");
const completedHome=path.join(area,'completed-ack-restart'),completedNote=enqueue(completedHome,'Complete this controlled acknowledgement before restart.');
const publicationControl=path.join(area,'publication-control');fs.mkdirSync(publicationControl);
const completedSession=start(completedHome,false);let completedReady;
try {
 completedReady=await ready(completedSession);
 await waitUntil(completedSession,'completed acknowledgement',()=>acknowledgedNote(completedHome,completedNote)&&fs.existsSync(path.join(completedHome,'state/inbox/handled',completedNote+'.note'))&&!pendingNote(completedHome,completedNote)&&fs.existsSync(path.join(completedReady.runtime,'first-automatic-complete')));
 const transition=pausedEnqueue(completedHome,'Complete this notification after its producer finishes publishing.',publicationControl);
 await waitUntil(completedSession,'producer publication boundary',()=>fs.existsSync(path.join(publicationControl,'paused')));
 fs.writeFileSync(path.join(completedReady.runtime,'continue-after-first'),'continue');
 await sleep(1000);
 fs.writeFileSync(path.join(publicationControl,'release'),'release');
 const publication=await bound(transition,completedSession,15000);assert.equal(publication.exit,0,publication.stderr);
 const transitionNote=publication.stdout.match(/^queued (\S+)/m)?.[1];assert(transitionNote,publication.stdout);
 await waitUntil(completedSession,'notification publication transition',()=>acknowledgedNote(completedHome,transitionNote)&&fs.existsSync(path.join(completedHome,'state/inbox/handled',transitionNote+'.note'))&&!pendingNote(completedHome,transitionNote)&&fs.readFileSync(path.join(completedHome,'state/.wake-queue'),'utf8').trim()==='',60000);
 completedSession.child.stdin.write('/quit\n');assert.equal((await bound(completedSession.done,completedSession,20000)).exit,0);
}finally{
 fs.writeFileSync(path.join(publicationControl,'release'),'release');
 if(completedSession.child.exitCode===null){completedSession.child.stdin.write('/quit\n');if(completedReady)fs.writeFileSync(path.join(completedReady.runtime,'continue-after-first'),'continue');const stopped=await bound(completedSession.done,completedSession,20000);assert.equal(stopped.exit,0,stopped.stderr);}
}
const completedRestart=start(completedHome);await ready(completedRestart,completedReady.owner.generation);completedRestart.child.stdin.end();assert.equal((await bound(completedRestart.done,completedRestart,20000)).exit,0);
records.push('notification publication transitions and completed acknowledgements remain admissible across restart');
// Later scenarios must not inherit the publication-only continuation wait.
fs.writeFileSync(hostScript,"import {runCodexHost} from './codex-host-runtime.mjs';\nimport {createFakeAppServer} from './fake-app-server.mjs';\ntry { await runCodexHost({spawnAppServer:()=>createFakeAppServer('success'),mcpServerNames:[]}); } catch(error) { console.error(error.message); process.exitCode=1; }\n");
const wakeLib=path.join(code,'bin/fm-wake-lib.sh'),wakeLibActual=wakeLib+'.actual';
fs.renameSync(wakeLib,wakeLibActual);fs.copyFileSync(path.join(repo,'tests/fixtures/native-owner/fm-wake-lib-interrupt.sh'),wakeLib);
const interruptedHome=path.join(area,'interrupted-ack-restart'),interruptedNote=enqueue(interruptedHome,'Preserve this interrupted acknowledgement for reconciliation.');
const interruptedQueue=path.join(interruptedHome,'state/.wake-queue'),queueBeforeRestart=fs.readFileSync(interruptedQueue,'utf8'),handledNote=path.join(interruptedHome,'state/inbox/handled',interruptedNote+'.note'),interruptedMarker=path.join(interruptedHome,'state/.watcher-down');
let interruptedSession,interruptedReady,interruptedResult,markerBody,handledBody;
try {
 interruptedSession=start(interruptedHome,false);interruptedReady=await ready(interruptedSession);
 await waitUntil(interruptedSession,'acknowledgement marker boundary',()=>fs.existsSync(path.join(interruptedReady.runtime,'ack-boundary-ready')));
 assert.deepEqual(journalRows(interruptedHome).map(row=>row.event),['session','presented','ack-started']);
 markerBody=fs.readFileSync(interruptedMarker,'utf8');assert.match(markerBody,/^acked:handling:[A-Za-z0-9._-]+\n$/);
 handledBody=fs.readFileSync(handledNote,'utf8');assert.equal(fs.readFileSync(interruptedQueue,'utf8'),queueBeforeRestart);
 interruptedSession.child.stdin.write('/quit\n');interruptedResult=await bound(interruptedSession.done,interruptedSession,20000);assert.equal(interruptedResult.exit,0,interruptedResult.stderr);
}finally{
 if(interruptedSession?.child.exitCode===null){interruptedSession.child.stdin.write('/quit\n');try{await bound(interruptedSession.done,interruptedSession,20000);}catch{}}
 fs.writeFileSync(hostScript,hostSource);fs.unlinkSync(wakeLib);fs.renameSync(wakeLibActual,wakeLib);
}
const interruptedRestart=start(interruptedHome);interruptedRestart.child.stdin.end();const reconciliation=await bound(interruptedRestart.done,interruptedRestart,20000);
assert.notEqual(reconciliation.exit,0);assert(reconciliation.stderr.includes('earlier acknowledgement is incomplete'),reconciliation.stderr);
const reconciledOwner=read(path.join(interruptedHome,'owner-probe.json'));assert.notEqual(reconciledOwner.generation,interruptedReady.owner.generation);
const reconciliationRuntime=path.join(interruptedHome,'state/native-runtime',reconciledOwner.generation);
assert.equal(fs.existsSync(path.join(reconciliationRuntime,'startup.log')),false);assert.equal(fs.existsSync(path.join(reconciliationRuntime,'startup.finished')),false);
assert.equal(fs.readFileSync(interruptedQueue,'utf8'),queueBeforeRestart);assert.equal(fs.readFileSync(interruptedMarker,'utf8'),markerBody);assert.equal(fs.readFileSync(handledNote,'utf8'),handledBody);
records.push('real acknowledgement interrupted after marker commit reaches reconciliation unchanged without restarting startup');
const maskedHome=path.join(area,'bash-env-mask'),maskedStatus=path.join(maskedHome,'state/orphan.status'),mask=path.join(area,'bash-env-exit.sh');
fs.mkdirSync(path.dirname(maskedStatus),{recursive:true});fs.writeFileSync(maskedStatus,'preserve masked residual state');fs.writeFileSync(mask,'exit 0\n');
const masked=start(maskedHome,true,{...process.env,BASH_ENV:mask});masked.child.stdin.end();assert.notEqual((await bound(masked.done,masked,20000)).exit,0);
assert.equal(fs.readFileSync(maskedStatus,'utf8'),'preserve masked residual state');assert.equal(fs.existsSync(path.join(maskedHome,'owner-probe.json')),false);
records.push('ambient Bash startup hooks cannot bypass admission before lease acquisition');
const customHome=path.join(area,'custom-work'),customState=path.join(customHome,'state'),customCheck=path.join(customState,'custom.check.sh'),customTrust=path.join(customState,'custom.check-trust'),canary=path.join(customHome,'executed');
const customCheckBody=`#!/usr/bin/env bash\nprintf executed > "${posix(canary)}"\n`,customTrustBody=`fm-custom-check-v1\n${createHash('sha256').update(customCheckBody).digest('hex')}\n`;
// Registration itself is covered on platforms that support its private-mode contract;
// this native fixture exercises the persisted custom-work admission boundary.
fs.mkdirSync(customState,{recursive:true});fs.writeFileSync(customCheck,customCheckBody);fs.writeFileSync(customTrust,customTrustBody);
const custom=start(customHome);custom.child.stdin.end();assert.notEqual((await bound(custom.done,custom,20000)).exit,0);
assert.equal(fs.existsSync(canary),false);assert.equal(fs.existsSync(path.join(customHome,'owner-probe.json')),false);assert.equal(fs.readFileSync(customCheck,'utf8'),customCheckBody);assert.equal(fs.readFileSync(customTrust,'utf8'),customTrustBody);
records.push('persisted custom work is refused unchanged before lease acquisition without execution');
for(const [name,contents] of [
 ['queued-backlog','## In flight\n\n## Queued\n- [ ] queued-work - preserved project work (repo: firstmate) (kind: ship)\n\n## Done\n'],
 ['unrecognized-backlog','# Backlog\n\nproject work in an unrecognized form\n'],
]){
 const backlogHome=path.join(area,name),backlog=path.join(backlogHome,'data/backlog.md');fs.mkdirSync(path.dirname(backlog),{recursive:true});fs.writeFileSync(backlog,contents);
 const refusedBacklog=start(backlogHome);refusedBacklog.child.stdin.end();assert.notEqual((await bound(refusedBacklog.done,refusedBacklog,20000)).exit,0);
 assert.equal(fs.readFileSync(backlog,'utf8'),contents);assert.equal(fs.existsSync(path.join(backlogHome,'owner-probe.json')),false);
}
records.push('queued and unrecognized backlogs refused before lease acquisition and preserved');
for(const [name,relative] of [['relay-config','config/x-mode.env'],['relay-watch','state/x-watch.check.sh']]){
 const relayHome=path.join(area,name),record=path.join(relayHome,relative),contents='preserve relay state';
 fs.mkdirSync(path.dirname(record),{recursive:true});fs.writeFileSync(record,contents);
 const refusedRelay=start(relayHome);refusedRelay.child.stdin.end();assert.notEqual((await bound(refusedRelay.done,refusedRelay,20000)).exit,0);
 assert.equal(fs.readFileSync(record,'utf8'),contents);assert.equal(fs.existsSync(path.join(relayHome,'owner-probe.json')),false);
}
records.push('generated Relay state refused before lease acquisition and preserved');
for(const [name,row] of [
 ['unsupported-wake','1\t1\tcheck\torphan-work\tcheck: unsupported residual work\n'],
 ['malformed-wake','malformed wake row\n'],
]){
 const wakeHome=path.join(area,name),wakeState=path.join(wakeHome,'state'),queue=path.join(wakeState,'.wake-queue'),marker=path.join(wakeState,'.watcher-down');
 fs.mkdirSync(wakeState,{recursive:true});fs.writeFileSync(path.join(wakeState,'.wake-queue.seq'),'1\n');fs.writeFileSync(queue,row);fs.writeFileSync(marker,'pending:downtime:preserve\n');
 const wakeSession=start(wakeHome);wakeSession.child.stdin.end();assert.notEqual((await bound(wakeSession.done,wakeSession,20000)).exit,0);
 assert.equal(fs.readFileSync(queue,'utf8'),row);assert.equal(fs.readFileSync(marker,'utf8'),'pending:downtime:preserve\n');assert.equal(fs.existsSync(path.join(wakeHome,'owner-probe.json')),false);
}
records.push('unsupported and malformed wake records refused unchanged before lease acquisition');
assert.equal(fs.existsSync(outside),false);
const external=start(outside);external.child.stdin.end();assert.notEqual((await bound(external.done,external,20000)).exit,0);assert.equal(fs.existsSync(outside),false);
const target=path.join(area,'junction-target'),junction=path.join(area,'junction');fs.mkdirSync(target);fs.symlinkSync(target,junction,'junction');
const linked=start(path.join(junction,'home'));linked.child.stdin.end();assert.notEqual((await bound(linked.done,linked,20000)).exit,0);assert.equal(fs.existsSync(path.join(target,'home')),false);
const externalOwner=path.join(area,'external-owner.json'),linkedOwnerHome=path.join(area,'linked-owner'),linkedOwner=path.join(linkedOwnerHome,'owner-probe.json');
const externalOwnerBody=JSON.stringify({deadGenerations:[],state:'live',rootPid:4294967295,rootCreationFileTime:0,generation:'d'.repeat(32),pipe:'unreachable',controllerPid:4294967295,controllerCreated:0});
fs.mkdirSync(linkedOwnerHome);fs.writeFileSync(externalOwner,externalOwnerBody);fs.linkSync(externalOwner,linkedOwner);
const linkedOwnerSession=start(linkedOwnerHome);linkedOwnerSession.child.stdin.end();assert.notEqual((await bound(linkedOwnerSession.done,linkedOwnerSession,20000)).exit,0);assert.equal(fs.readFileSync(externalOwner,'utf8'),externalOwnerBody);
records.push('non-temporary, reparse-point, and hard-linked owner homes are refused without external changes');
// Delay the existing network owner only in this disposable code copy. The
// production launcher has no delay/mock switch and still invokes that owner.
const network=path.join(code,'bin/fm-startup-network.sh');fs.renameSync(network,network+'.actual');
fs.writeFileSync(network,'#!/usr/bin/env bash\nif [ "${1:-}" = run ]; then sleep 15; fi\nexec "$(dirname "$0")/fm-startup-network.sh.actual" "$@"\n');
// Its start command invokes the original script's self path. Delay the worker
// entry inside that preserved copy, before any original script logic executes.
const original=fs.readFileSync(network+'.actual','utf8');fs.writeFileSync(network+'.actual',original.replace(/^#![^\n]*\n/,'#!/usr/bin/env bash\nif [ "${1:-}" = run ]; then sleep 15; fi\n'));
const deferred=start(path.join(area,'deferred'));const early=await ready(deferred);
const earlyEvidence=read(path.join(early.runtime,'host.json'));
assert.equal(earlyEvidence.digestDeliveredBeforeDeferred,true);
const independent=spawn(process.execPath,['-e','setTimeout(()=>{},60000)'],{stdio:'ignore'});
try {
 deferred.child.stdin.write('/quit\n');assert.equal((await bound(deferred.done,deferred,20000)).exit,0);
 assert.equal(read(path.join(early.runtime,'shutdown.json')).stopped,true);assert.equal(independent.exitCode,null);
 records.push('digest delivered before deferred completion; cancellation preserves an independent process');
}finally{independent.kill();}
fs.writeFileSync(network,original);fs.unlinkSync(network+'.actual');
if(live){
 const messageHome=path.join(area,'live-message');
 const model=start(messageHome,false);const liveReady=await ready(model);const runtime=liveReady.runtime;
 const notes=[];
 for(let cycle=1;cycle<=2;cycle++){
  notes.push(enqueue(messageHome,'Launcher integration notification '+cycle+': no project action is requested. Read and acknowledge this notification.'));
  let completed=false;
  for(let i=0;i<1800;i++){
   if(model.child.exitCode!==null)throw Error(JSON.stringify(await model.done));
   const evidence=read(path.join(runtime,'host.json'));
   if(evidence.turns.length>=cycle&&evidence.turns[cycle-1].status==='completed'){completed=true;break;}
   await sleep(100);
  }
  assert(completed,'The notification did not produce a completed model turn');
 }
 model.child.stdin.write('/quit\n');const result=await bound(model.done,model,20000);assert.equal(result.exit,0,result.stderr);
 const host=read(path.join(runtime,'host.json'));assert.equal(host.turns.length,2);
 assert(host.tools.some(tool=>tool.tool==='fm_notification_check'&&tool.success));assert(host.tools.some(tool=>tool.tool==='fm_notification_ack'&&tool.success));
 for(const note of notes)assert(fs.existsSync(path.join(messageHome,'state/inbox/handled',note+'.note')));
  assert.equal(fs.readFileSync(path.join(messageHome,'state/.wake-queue'),'utf8').trim(),'');
  fs.writeFileSync(path.join(runtime,'console.json'),JSON.stringify(result,null,2));
  records.push('two real post-startup notification cycles were automatically delivered, observed, and acknowledged');
  const retryHome=path.join(area,'live-interrupted-redelivery');
  const retryNote=enqueue(retryHome,'Interrupted automatic handling test: read and acknowledge this notification when handling resumes.');
  const retry=start(retryHome,false);const retryReady=await ready(retry);let interruptSent=false,interrupted=false,completed=false;
  for(let i=0;i<1800;i++){
   if(retry.child.exitCode!==null)throw Error(JSON.stringify(await retry.done));
   const host=read(path.join(retryReady.runtime,'host.json'));
   if(host.activeTurn){retry.child.stdin.write('/interrupt\n');interruptSent=true;break;}
   await sleep(50);
  }
  assert(interruptSent,'No automatic notification turn became active for interruption');
  for(let i=0;i<1800;i++){
   if(retry.child.exitCode!==null)throw Error(JSON.stringify(await retry.done));
   const turns=read(path.join(retryReady.runtime,'host.json')).turns;
   interrupted=turns.some(turn=>turn.status==='interrupted');completed=interrupted&&turns.some(turn=>turn.status==='completed');
   if(completed&&fs.existsSync(path.join(retryHome,'state/inbox/handled',retryNote+'.note')))break;
   await sleep(100);
  }
  assert(interrupted,'The automatic notification turn was not interrupted');
  assert(completed,'The interrupted notification was not offered to a later automatic turn');
  await sleep(1500);
  assert.deepEqual(read(path.join(retryReady.runtime,'host.json')).turns.map(turn=>turn.status),['interrupted','completed']);
  retry.child.stdin.write('/quit\n');const retryResult=await bound(retry.done,retry,20000);assert.equal(retryResult.exit,0,retryResult.stderr);
  assert.equal(read(path.join(retryReady.runtime,'host.json')).turns.length,2);
  assert.equal(read(path.join(retryReady.runtime,'shutdown.json')).stopped,true);
  assert.equal(fs.readFileSync(path.join(retryHome,'state/.wake-queue'),'utf8').trim(),'');
  records.push('interrupted automatic handling re-offered the pending receipt once, then stopped after completion and quit');
  const cancelHome=path.join(area,'live-cancel');const pendingNote=enqueue(cancelHome,'Cancellation test: leave this notification pending; do not acknowledge it.');
 const active=start(cancelHome,false);active.child.stdin.write('Call fm_notification_check once, but do not acknowledge anything. Explain what remains pending. Do not use other tools.\n');
 const current=await ready(active);let began=false;
 for(let i=0;i<1200;i++){if(read(path.join(current.runtime,'host.json')).activeTurn){began=true;break;}await sleep(50);}
 assert(began,'No active turn to cancel');active.child.stdin.write('/quit\n');
 const stopped=await bound(active.done,active,20000);assert.equal(stopped.exit,0,stopped.stderr);
 assert(read(path.join(current.runtime,'host.json')).turns.some(turn=>turn.status==='interrupted'));
 assert.equal(read(path.join(current.runtime,'shutdown.json')).stopped,true);
 assert(fs.existsSync(path.join(cancelHome,'state/inbox',pendingNote+'.note')));
 records.push('shutdown interrupted a real active turn and preserved its pending notification');
}
const state=path.join(repo,'data/native-launcher');fs.mkdirSync(state,{recursive:true});
const summary=JSON.stringify({area,code,home,records,live,passed:true},null,2);
fs.writeFileSync(path.join(state,'launcher-latest.json'),summary);
fs.writeFileSync(path.join(state,live?'launcher-live-latest.json':'launcher-smoke-latest.json'),summary);
console.log('PASS: '+records.join('; '));
