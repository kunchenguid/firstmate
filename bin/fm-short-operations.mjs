// Narrow operation grants for fm-short-agent.mjs. This module never evaluates
// model-supplied commands. The immutable request owns the ordered grants; the
// child can request the recorded finite chain once. Existing scripts own actions.
// Operations require Linux /proc, a submitting primary lock ancestor, canonical
// targets and an explicit expiry/provenance. Defaults and SDK lifecycle remain
// in fm-short-agent.mjs. No restart/discard authority is inferred from cleanup.
// state/short-agents/<id>/operation-N.{intent,effect,receipt,output}.json owns
// attempt evidence. Intent precedes owner execution; effect records its exact
// process identity before mutation; receipt follows authoritative readback.
// Resource markers are atomic reservations; existing owner locks and leases
// arbitrate effects with MAIN/BRANCH. A missing receipt after an effect remains
// reserved across restart, never replayed. Reconcile releases verified completed
// reservations and proven no-effect reservations after their processes stop.
// Internal CLI verify/effect/receipt is called only by fm-short-owner-lib.sh;
// it checks the immutable grant, kernel process ancestry and exact owner args.
// This is a tool/owner boundary, not isolation against same-user arbitrary code.
import * as fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { publish as atomicPublish } from './fm-short-agent.mjs';
const CODEBASE_MERGE_READBACK_TIMEOUT_MS=180000;
function publish(file,value) {
  const created=atomicPublish(file,value);
  if(created) {
    const fd=fs.openSync(path.dirname(file),'r');
    try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  }
  return created;
}
const exec = promisify(execFile);
const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const exists = file => fs.existsSync(file);
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const fail = message => { throw Error(message); };
const cleanupDispositions = new Set(['returned-or-already-absent','retained-shared','retained-primary','retained-dirty','retained-unlanded','retained-unverified']);
const completeCleanupEvidence = evidence => evidence?.taskRecordRemoved===true && evidence.endpointConfirmedGone===true && evidence.bookkeepingComplete===true && cleanupDispositions.has(evidence.copyDisposition);
function fields(value, names) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(k => !names.includes(k))) fail('unsupported operation fields');
}
function str(value, label) {
  if (typeof value !== 'string' || !value || value.includes('\0')) fail(`invalid operation ${label}`);
  return value;
}
function canonical(value) {
  str(value,'path');
  if (!path.isAbsolute(value) || fs.realpathSync(value) !== value) fail('operation requires canonical absolute path');
  return value;
}
export function processIdentity(pid) {
  // Operation execution currently requires Linux's structural process identity.
  // Read-only jobs retain their portable SDK path.
  const stat=fs.readFileSync(`/proc/${pid}/stat`,'utf8');
  const parts=stat.slice(stat.lastIndexOf(')')+2).split(' ');
  if (parts[0]==='Z') fail('operation process is a zombie');
  return {pid:Number(pid),parent:Number(parts[1]),start:parts[19],boot:fs.readFileSync('/proc/sys/kernel/random/boot_id','utf8').trim()};
}
export function primaryOwner(home) {
  const holder=Number(fs.readFileSync(path.join(home,'state/.lock'),'utf8').trim());
  if (!Number.isSafeInteger(holder) || holder<=1) fail('operation requires primary session lock');
  for(let p=process.pid,n=0;p>1 && n<16;n++) {
    const identity=processIdentity(p);
    if(p===holder) return identity;
    p=identity.parent;
  }
  fail('operation submission/control requires the owning primary process');
}
export function validateOperations(value) {
  if (value === undefined) return undefined;
  fields(value,['expiresAt','authority','steps']);
  str(value.authority,'authority provenance');
  if(!Number.isSafeInteger(value.expiresAt) || value.expiresAt<=0) fail('invalid operation expiry');
  if(!Array.isArray(value.steps) || value.steps.length<1 || value.steps.length>4) fail('operation needs one to four finite steps');
  const steps=value.steps.map(s=>{
    fields(s,['action','project','destination','task','url']);
    switch(s.action) {
      case 'sync': case 'recover-sync':
        fields(s,['action','project']); str(s.project,'project');
        return {action:s.action,project:s.project};
      case 'install-shellcheck':
        fields(s,['action','destination']); str(s.destination,'destination');
        return {action:s.action,destination:s.destination};
      case 'merge':
        fields(s,['action','task','url']);
        if(!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(s.task)) fail('invalid operation task');
        str(s.url,'merge URL');
        return {action:s.action,task:s.task,url:s.url};
      case 'cleanup':
        fields(s,['action','task']);
        if(!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(s.task)) fail('invalid operation task');
        return {action:s.action,task:s.task};
      default: fail('unsupported operation action; no shell fallback');
    }
  });
  return {expiresAt:value.expiresAt,authority:value.authority,steps};
}
function git(project,...args) {return execFileSync('git',['-C',project,...args],{encoding:'utf8',timeout:10000,stdio:['ignore','pipe','pipe']}).trim();}
function metadata(home,task,cleanup=false) {
  const file=path.join(home,'state',task+'.meta');
  if(fs.lstatSync(file).isSymbolicLink()) fail('symlink task metadata refused');
  const text=fs.readFileSync(file,'utf8'), data=Object.create(null), audit=[];
  for(const line of text.split('\n')) {
    if(line.startsWith('#')) continue;
    const at=line.indexOf('='); if(at<1) continue;
    const key=line.slice(0,at);
    if(cleanup && !['spawn_gen','kind','worktree','project','backend','window','herdr_session','herdr_pane_id','herdr_workspace_id','herdr_tab_id','endpoint_task_id'].includes(key)) continue;
    if(key==='decisions_reviewed' || key==='decision_keys') audit.push([key,line.slice(at+1)]);
    else if(Object.hasOwn(data,key)) fail('duplicate task metadata field');
    data[key]=line.slice(at+1);
  }
  // Compatibility is limited to the completion owner's old append-only audit
  // pairs: reviewed=1 followed by an inventory that never loses an earlier id.
  // Every other repeated field remains ambiguous, including identical values.
  if(audit.length>2) {
    let previous=[];
    if(audit.length%2) fail('ambiguous completion audit history');
    for(let i=0;i<audit.length;i+=2) {
      if(audit[i][0]!=='decisions_reviewed' || audit[i][1]!=='1' || audit[i+1][0]!=='decision_keys') fail('ambiguous completion audit history');
      const keys=audit[i+1][1]?audit[i+1][1].split(','):[];
      if(keys.some(k=>!(/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(k))) || new Set(keys).size!==keys.length || previous.some(k=>!keys.includes(k))) fail('ambiguous completion audit history');
      previous=keys;
    }
  } else if(new Set(audit.map(([key])=>key)).size!==audit.length) fail('duplicate task metadata field');
  if(!cleanup && !data.spawn_gen) fail('operation requires an existing task generation; legacy identity refused');
  // Merge binds the entire audit record. Cleanup binds structural ownership;
  // unrelated completion history cannot invalidate an exact cleanup target.
  return {...(cleanup?{}:{sha256:createHash('sha256').update(text).digest('hex')}),...Object.fromEntries(['pr','pr_head','spawn_gen','kind','worktree','project','backend','window','herdr_session','herdr_pane_id','herdr_workspace_id','herdr_tab_id','endpoint_task_id','harness','tmux_pane_id'].map(k=>[k,data[k]??'']))};
}
function binaryIdentity(destination) {
  const file=path.join(destination,'shellcheck');
  if(!exists(file)) {
    // existsSync follows symlinks; lstat still refuses a dangling link.
    try {fs.lstatSync(file);fail('install target is not a regular file');} catch(error) {if(error.code!=='ENOENT') throw error;}
    return null;
  }
  const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
  try {
    const st=fs.fstatSync(fd);
    if(!st.isFile()||st.nlink!==1||st.size>134217728) fail('install target must be a bounded single-link regular file');
    return {dev:st.dev,ino:st.ino,sha256:createHash('sha256').update(fs.readFileSync(fd)).digest('hex')};
  } finally {fs.closeSync(fd);}
}
export function bindOperations(home,operations) {
  if(!operations) return undefined;
  if(process.platform!=='linux') fail('operation process identity requires Linux /proc; read-only tasks remain supported');
  primaryOwner(home);
  if(operations.expiresAt<=Date.now()) fail('operation authority expired');
  return operations.steps.map(step=>{
    if(step.project) {
      const project=canonical(step.project);
      if(git(project,'rev-parse','--show-toplevel')!==project) fail('operation target must be a clone root');
      return {project,origin:git(project,'remote','get-url','origin'),gitDir:fs.realpathSync(git(project,'rev-parse','--absolute-git-dir'))};
    }
    if(step.destination) {
      const destination=canonical(step.destination);
      if(!fs.statSync(destination).isDirectory()) fail('install destination must exist');
      return {destination,previous:binaryIdentity(destination)};
    }
    if(step.action==='merge') {
      if(!step.url.startsWith('https://code.byted.org/')) fail('short merge currently supports canonical Codebase requests only; this forge is unsupported');
      const library=path.join(path.dirname(fileURLToPath(import.meta.url)),'fm-pr-lib.sh');
      const canonicalUrl=execFileSync('bash',['-c','. "$1"; fm_pr_url_parse "$2" || exit 1; printf "%s" "$FM_PR_URL"','short-url',library,step.url],{encoding:'utf8',timeout:10000});
      if(canonicalUrl!==step.url) fail('merge requires the canonical owner URL');
    }
    const identity=metadata(home,step.task,step.action==='cleanup');
    if(step.action==='merge' && (identity.pr!==step.url || !/^[a-f0-9]{40,64}$/.test(identity.pr_head))) fail('merge requires the exact registered URL and candidate head before granting authority');
    if(step.action==='cleanup' && identity.backend!=='herdr') fail('short cleanup requires the Herdr owner with confirmed endpoint removal; this backend is unsupported');
    if(identity.kind==='secondmate') fail('short operations do not retire secondmate homes');
    return identity;
  });
}
export function resource(home,step) {
  if(step.project) {
    const common=git(step.project,'rev-parse','--git-common-dir');
    const directory=fs.realpathSync(path.resolve(step.project,common));
    return {target:`project:${directory}`,file:path.join(directory,'fm-short-operation.json')};
  }
  if(step.destination) {
    const directory=fs.realpathSync(step.destination);
    return {target:`binary:${directory}/shellcheck`,file:path.join(directory,'.fm-short-shellcheck.json')};
  }
  const directory=path.join(fs.realpathSync(home),'state');
  return {target:`task:${directory}:${step.task}`,file:path.join(directory,`.short-operation-${step.task}.json`)};
}
function resources(home,step) {
  const keys=[resource(home,step)];
  if(step.action==='merge') keys.push({target:`merge:${step.url}`,file:path.join(fs.realpathSync(home),'state',`.short-merge-${createHash('sha256').update(step.url).digest('hex')}.json`)});
  return keys.sort((a,b)=>a.file.localeCompare(b.file));
}
export function operationCurrent(home,request,index,{terminal=false}={}) {
  const dir=path.join(home,'state/short-agents',request.id);
  if(!equal(read(path.join(dir,'request.json')),request)) fail('short task request/generation changed');
  if(!terminal && exists(path.join(dir,'result.json'))) fail('short task is terminal');
  if(exists(path.join(dir,'revoked.json'))) fail('operation authority revoked');
  if(Date.now()>=request.input.operations.expiresAt) fail('operation authority expired');
  const step=request.input.operations.steps[index], binding=request.operationBindings[index];
  if(!step || !binding) fail('operation outside grant');
  if(step.project) {
    canonical(step.project);
    if(git(step.project,'status','--porcelain')) fail('dirty operation project refused');
    if(step.action==='sync') {
      const branch=git(step.project,'symbolic-ref','--short','HEAD');
      const target=git(step.project,'symbolic-ref','--short','refs/remotes/origin/HEAD').replace(/^origin\//,'');
      if(branch!==target) fail('sync does not authorize branch recovery');
    }
    if(git(step.project,'remote','get-url','origin')!==binding.origin || fs.realpathSync(git(step.project,'rev-parse','--absolute-git-dir'))!==binding.gitDir) fail('operation project identity changed');
  } else if(step.destination) {canonical(step.destination);if(!equal(binaryIdentity(step.destination),binding.previous)) fail('install target identity changed');}
  else if(!equal(metadata(home,step.task,step.action==='cleanup'),binding)) fail('operation task/process/generation identity changed');
  return step;
}

// Inspecting an operation is safe even after expiry/cancellation. Recovery never
// executes a previous intent again; it retains uncertainty for a decision.
export function operationReceipts(dir) {
  const request=read(path.join(dir,'request.json'));
  return fs.readdirSync(dir).filter(x=>/^operation-\d+\.receipt\.json$/.test(x)).sort().map(x=>{
    const receipt=read(path.join(dir,x)), step=request.input.operations?.steps[receipt.index];
    if(!step || x!==`operation-${receipt.index}.receipt.json` || receipt.id!==request.id || receipt.nonce!==request.nonce || !['completed','refused'].includes(receipt.state) || receipt.action!==commandFor(step).action) fail('malformed operation receipt');
    if(receipt.settlement!==undefined) {
      if(!((receipt.settlement==='dead-owner-codebase-readback'&&receipt.action==='merge')||(['dead-owner-cleanup-readback','dead-owner-legacy-cleanup-preflight-readback','main-current-cleanup-readback','main-archived-cleanup-readback'].includes(receipt.settlement)&&receipt.action==='cleanup'))) fail('malformed operation settlement');
      recordedProcessIdentity(receipt.effectExecutor,`settled ${receipt.action} executor`);
      if(receipt.settlement==='dead-owner-legacy-cleanup-preflight-readback' &&
         (receipt.state!=='refused'||receipt.evidence?.reason!=='legacy cleanup acceptance preflight refused before owner effects'||receipt.evidence?.taskBindingUnchanged!==true||receipt.evidence?.endpointStillPresent!==true)) fail('malformed legacy cleanup preflight settlement');
    }
    if(receipt.state==='completed') {
      const e=receipt.evidence;
      if(!e || ((receipt.action==='sync'||receipt.action==='merge') && !/^[a-f0-9]{40,64}$/.test(e.head)) || (receipt.action==='install-shellcheck' && (!/^[a-f0-9]{64}$/.test(e.sha256)||typeof e.version!=='string')) || (receipt.action==='cleanup' && !completeCleanupEvidence(e))) fail('malformed operation postcondition');
    }
    return receipt;
  });
}

function sameLiveProcess(identity) {
  try {const now=processIdentity(identity.pid);return ['pid','start','boot'].every(k=>now[k]===identity[k]);}
  catch(error) {if(error.code==='ENOENT'||error.code==='ESRCH'||error.message.includes('zombie')) return false;throw error;}
}

function recordedProcessIdentity(identity,label) {
  fields(identity,['pid','parent','start','boot']);
  if(!Number.isSafeInteger(identity.pid)||identity.pid<=1||!Number.isSafeInteger(identity.parent)||identity.parent<1||!/^\d+$/.test(identity.start??'')||!/^[a-f0-9-]{36}$/.test(identity.boot??'')) fail(`invalid ${label} identity`);
  return identity;
}

function codebaseMergeReadback(root,url,head) {
  const library=path.join(root,'bin/fm-pr-lib.sh');
  let output;
  try {
    output=execFileSync('bash',['-c',
      '. "$1"; fm_pr_url_parse "$2" && [ "$FM_PR_PROVIDER" = codebase ] || exit 2; FM_PR_MERGE_HEAD=$3; command -v bytedcli >/dev/null && command -v jq >/dev/null || exit 2; fm_pr_codebase_read_identity && fm_pr_codebase_confirm_merged || exit $?; printf "%s\\t%s\\n" "$FM_PR_MERGE_HEAD" "$FM_PR_CODEBASE_MERGE_COMMIT"',
      'short-merge-readback',library,url,head],{encoding:'utf8',timeout:CODEBASE_MERGE_READBACK_TIMEOUT_MS,stdio:['ignore','pipe','pipe']}).trim();
  } catch(error) {
    if(error?.code==='ETIMEDOUT') fail(`Codebase merge readback refused: timed out after ${CODEBASE_MERGE_READBACK_TIMEOUT_MS}ms`);
    const detail=String(error.stderr??'').trim();
    fail(detail?`Codebase merge readback refused: ${detail}`:'Codebase merge readback refused');
  }
  const parts=output.split('\t');
  if(parts.length!==2||parts[0]!==head||!(/^[a-f0-9]{40}$|^[a-f0-9]{64}$/).test(parts[1])) fail('Codebase merge readback returned invalid evidence');
  return {head:parts[0],mergeCommit:parts[1]};
}

function cleanupOwnerReadback(home,root,step,binding) {
  if(binding.backend!=='herdr'||!binding.spawn_gen||(binding.endpoint_task_id&&binding.endpoint_task_id!==step.task)) fail('cleanup settlement task binding is invalid');
  const meta=path.join(home,'state',step.task+'.meta');
  try {fs.lstatSync(meta);return null;}
  catch(error) {if(error.code!=='ENOENT') throw error;}
  const cleanupFile=path.join(home,'state',step.task+'.cleanup.json');
  if(!exists(cleanupFile)) return null;
  const cleanupBytes=fs.readFileSync(cleanupFile,'utf8'),record=JSON.parse(cleanupBytes);
  if(record?.schema!=='fm-task-cleanup.v1'||record.task_id!==step.task||record.spawn_gen!==binding.spawn_gen) fail('cleanup owner generation changed');
  const proof=record.completion;
  if(!proof||proof.spawn_gen!==binding.spawn_gen||!completeCleanupEvidence(proof.facts)) return null;
  return {evidence:proof.facts,cleanupFile,cleanupBytes};
}

function legacyCleanupPreflightReadback(home,root,request,started,index,step,binding,intent,effect,resultBytes) {
  // a70ee10e wrote the cleanup marker in the ShortTask runner before invoking
  // teardown.  The current owner marker is instead a direct child of that
  // runner.  Only the legacy shape can use this compatibility readback.
  if(!equal(effect.owner,started.identity)) return null;
  const dir=path.join(home,'state/short-agents',request.id),outputFile=path.join(dir,`operation-${index}.output.json`);
  const cleanupFile=path.join(home,'state',step.task+'.cleanup.json'),metaFile=path.join(home,'state',step.task+'.meta');
  if(exists(cleanupFile)||!exists(outputFile)||!equal(metadata(home,step.task,true),binding)) return null;
  const outputStat=fs.lstatSync(outputFile);
  if(!outputStat.isFile()||outputStat.isSymbolicLink()||outputStat.nlink!==1||outputStat.size>1048576) fail('unsafe legacy cleanup output evidence');
  const outputBytes=fs.readFileSync(outputFile,'utf8'),output=JSON.parse(outputBytes);
  fields(output,['stdout','stderr','error']);
  const refusals=new Set([
    `REFUSED: compact task ${step.task} is not MAIN-accepted; clear its current remaining gap or explicitly archive it before cleanup\n`,
    `REFUSED: task ${step.task} is not MAIN-accepted; clear its current remaining gap or explicitly archive it before cleanup\n`,
  ]);
  if(output.stdout!==''||!refusals.has(output.stderr)||typeof output.error!=='string') return null;
  let presence;
  try {
    presence=execFileSync('bash',['-c',
      '. "$1"; fm_backend_validate_task_endpoint "$2" "$3" >/dev/null && fm_backend_source herdr && session=$(fm_backend_meta_exact_value "$2" herdr_session) && pane=$(fm_backend_meta_exact_value "$2" herdr_pane_id) && fm_backend_herdr_pane_presence_state "$session" "$pane"',
      'legacy-cleanup-readback',path.join(root,'bin/fm-backend.sh'),metaFile,step.task],
    {encoding:'utf8',env:{...process.env,FM_HOME:home,FM_ROOT_OVERRIDE:root,FM_STATE_OVERRIDE:path.join(home,'state')},stdio:['ignore','pipe','pipe']}).trim();
  } catch(error) {
    const detail=String(error.stderr??'').trim();
    fail(detail?`legacy cleanup endpoint readback refused: ${detail}`:'legacy cleanup endpoint readback refused');
  }
  if(presence!=='present') return null;
  if(!equal(read(path.join(dir,'request.json')),request)||fs.readFileSync(path.join(dir,'result.json'),'utf8')!==resultBytes||
     !equal(read(path.join(dir,`operation-${index}.intent.json`)),intent)||!equal(read(path.join(dir,`operation-${index}.effect.json`)),effect)||
     fs.readFileSync(outputFile,'utf8')!==outputBytes||exists(cleanupFile)||!equal(metadata(home,step.task,true),binding)) fail('legacy cleanup preflight evidence changed during readback');
  return {reason:'legacy cleanup acceptance preflight refused before owner effects',taskBindingUnchanged:true,endpointStillPresent:true};
}

function settleCleanupLocked(home,request,started,index,step) {
  const root=path.dirname(path.dirname(fileURLToPath(import.meta.url))),dir=path.join(home,'state/short-agents',request.id);
  const requestFile=path.join(dir,'request.json'),resultFile=path.join(dir,'result.json'),intentFile=path.join(dir,`operation-${index}.intent.json`),effectFile=path.join(dir,`operation-${index}.effect.json`),receiptFile=path.join(dir,`operation-${index}.receipt.json`);
  if(!exists(resultFile)) return null;
  const resultBytes=fs.readFileSync(resultFile,'utf8'),result=JSON.parse(resultBytes),binding=request.operationBindings?.[index];
  if(result.id!==request.id||!['blocked','cancelled','timeout','interrupted','budget'].includes(result.state)||result.evidence!==dir||!Number.isSafeInteger(result.finishedAt)) fail('cleanup settlement requires the preserved unsuccessful terminal result');
  if(!binding||step.action!=='cleanup') return null;
  recordedProcessIdentity(started.identity,'short runner');
  const intent=read(intentFile),effect=read(effectFile);
  fields(intent,['nonce','index','step','at']);fields(effect,['id','nonce','index','owner','at']);
  if(intent.nonce!==request.nonce||intent.index!==index||!equal(intent.step,step)||!Number.isSafeInteger(intent.at)) fail('operation intent identity changed');
  if(effect.id!==request.id||effect.nonce!==request.nonce||effect.index!==index||!Number.isSafeInteger(effect.at)) fail('operation effect identity changed');
  recordedProcessIdentity(effect.owner,'cleanup executor');
  const legacyEffect=equal(effect.owner,started.identity);
  if((!legacyEffect&&(effect.owner.parent!==started.pid||effect.owner.boot!==started.identity.boot))||sameLiveProcess(effect.owner)) fail('cleanup executor is not bound to the dead original runner');
  if(!(request.acceptedAt<=started.at&&started.at<=intent.at&&intent.at<=effect.at&&effect.at<=result.finishedAt)) fail('short cleanup settlement chronology is invalid');
  const expectedMarkers=resources(home,step).map(({file,target})=>({file,record:{home,id:request.id,nonce:request.nonce,index,target}}));
  for(const marker of expectedMarkers) if(!equal(read(marker.file),marker.record)) fail('operation reservation identity changed');
  const noEffect=legacyCleanupPreflightReadback(home,root,request,started,index,step,binding,intent,effect,resultBytes);
  if(noEffect) {
    if(!publish(receiptFile,{id:request.id,nonce:request.nonce,index,action:'cleanup',state:'refused',at:Date.now(),executor:processIdentity(process.pid),settlement:'dead-owner-legacy-cleanup-preflight-readback',effectExecutor:effect.owner,evidence:noEffect})) fail('operation refusal receipt changed during settlement');
    return operationReceipts(dir).find(value=>value.index===index);
  }
  const readback=cleanupOwnerReadback(home,root,step,binding);
  if(!readback) return null;
  if(!equal(read(requestFile),request)||fs.readFileSync(resultFile,'utf8')!==resultBytes||!equal(read(intentFile),intent)||!equal(read(effectFile),effect)||fs.readFileSync(readback.cleanupFile,'utf8')!==readback.cleanupBytes) fail('short cleanup settlement evidence changed during readback');
  for(const marker of expectedMarkers) if(!equal(read(marker.file),marker.record)) fail('operation reservation identity changed during readback');
  if(!publish(receiptFile,{id:request.id,nonce:request.nonce,index,action:'cleanup',state:'completed',at:Date.now(),executor:processIdentity(process.pid),settlement:'dead-owner-cleanup-readback',effectExecutor:effect.owner,evidence:readback.evidence})) fail('operation completion receipt changed during settlement');
  return operationReceipts(dir).find(value=>value.index===index);
}

function settleMergeLocked(home,root,id,index,expectedMergeCommit) {
  const dir=path.join(home,'state/short-agents',id);
  const requestFile=path.join(dir,'request.json'),startedFile=path.join(dir,'started.json'),resultFile=path.join(dir,'result.json');
  const request=read(requestFile),started=read(startedFile),resultBytes=fs.readFileSync(resultFile,'utf8'),result=JSON.parse(resultBytes);
  if(![1,2].includes(request.version)||request.id!==id||!request.input?.operations||!Array.isArray(request.operationBindings)||request.operationBindings.length!==request.input.operations.steps.length) fail('short merge settlement request identity is invalid');
  if(!Number.isSafeInteger(index)||index<0||index>=request.input.operations.steps.length) fail('short merge settlement index is invalid');
  if(!(/^[a-f0-9]{40}$|^[a-f0-9]{64}$/).test(expectedMergeCommit??'')) fail('short merge settlement requires the independently observed merge commit');
  const step=request.input.operations.steps[index],binding=request.operationBindings[index];
  if(step?.action!=='merge'||!step.url?.startsWith('https://code.byted.org/')) fail('short merge settlement supports Codebase merge effects only');
  if(binding.pr!==step.url||!(/^[a-f0-9]{40}$|^[a-f0-9]{64}$/).test(binding.pr_head??'')||!equal(metadata(home,step.task),binding)) fail('operation task/process/generation identity changed');
  if(result.id!==id||!['blocked','cancelled','timeout','interrupted','budget'].includes(result.state)||result.evidence!==dir||!Number.isSafeInteger(result.finishedAt)) fail('short merge settlement requires the preserved unsuccessful terminal result');
  if(started.nonce!==request.nonce||started.pid!==started.identity?.pid||!Number.isSafeInteger(started.at)) fail('short runner identity changed');
  recordedProcessIdentity(started.identity,'short runner');
  if(sameLiveProcess(started.identity)) fail('short merge settlement requires the original runner to be dead');
  const intentFile=path.join(dir,`operation-${index}.intent.json`),effectFile=path.join(dir,`operation-${index}.effect.json`),receiptFile=path.join(dir,`operation-${index}.receipt.json`);
  const intent=read(intentFile),effect=read(effectFile);
  fields(intent,['nonce','index','step','at']);fields(effect,['id','nonce','index','owner','at']);
  if(intent.nonce!==request.nonce||intent.index!==index||!equal(intent.step,step)||!Number.isSafeInteger(intent.at)) fail('operation intent identity changed');
  if(effect.id!==id||effect.nonce!==request.nonce||effect.index!==index||!Number.isSafeInteger(effect.at)) fail('operation effect identity changed');
  recordedProcessIdentity(effect.owner,'merge executor');
  if(effect.owner.parent!==started.pid||effect.owner.boot!==started.identity.boot) fail('merge executor is not bound to the original runner');
  if(sameLiveProcess(effect.owner)) fail('short merge settlement requires the original executor to be dead');
  if(!(request.acceptedAt<=started.at&&started.at<=intent.at&&intent.at<=effect.at&&effect.at<=result.finishedAt)) fail('short merge settlement chronology is invalid');
  const expectedMarkers=resources(home,step).map(({file,target})=>({file,record:{home,id,nonce:request.nonce,index,target}}));
  if(exists(receiptFile)) {
    const receipt=operationReceipts(dir).find(value=>value.index===index);
    if(receipt?.settlement!=='dead-owner-codebase-readback'||receipt.evidence.head!==binding.pr_head||receipt.evidence.mergeCommit!==expectedMergeCommit) fail('operation already has a different completion receipt');
    for(const marker of expectedMarkers) if(exists(marker.file)&&!equal(read(marker.file),marker.record)) fail('operation reservation identity changed');
  } else {
    for(const marker of expectedMarkers) if(!equal(read(marker.file),marker.record)) fail('operation reservation identity changed');
    const evidence=codebaseMergeReadback(root,step.url,binding.pr_head);
    if(evidence.mergeCommit!==expectedMergeCommit) fail('Codebase merge commit does not match the independently observed merge commit');
    if(!equal(read(requestFile),request)||fs.readFileSync(resultFile,'utf8')!==resultBytes||!equal(metadata(home,step.task),binding)||!equal(read(intentFile),intent)||!equal(read(effectFile),effect)) fail('short merge settlement evidence changed during readback');
    for(const marker of expectedMarkers) if(!equal(read(marker.file),marker.record)) fail('operation reservation identity changed during readback');
    if(!publish(receiptFile,{id,nonce:request.nonce,index,action:'merge',state:'completed',at:Date.now(),executor:processIdentity(process.pid),settlement:'dead-owner-codebase-readback',effectExecutor:effect.owner,evidence})) fail('operation completion receipt changed during settlement');
  }
  const receipt=operationReceipts(dir).find(value=>value.index===index);
  for(const marker of expectedMarkers) {
    if(!exists(marker.file)) continue;
    if(!equal(read(marker.file),marker.record)) fail('operation reservation identity changed after settlement');
    fs.unlinkSync(marker.file);
  }
  return {id,index,state:'completed',action:'merge',settlement:receipt.settlement,evidence:receipt.evidence,result:result.state,reservationsReleased:expectedMarkers.length};
}

export function settleMergeReceipt(home,root,id,index,expectedMergeCommit) {
  primaryOwner(home);
  const dir=path.join(home,'state/short-agents',id),script=fileURLToPath(import.meta.url);
  const output=execFileSync('bash',['-c',
    '. "$1"; fm_lock_acquire_wait_bounded "$2" 5 || exit 1; trap \'fm_lock_release "$2"\' EXIT; "$3" "$4" _settle-merge-locked "$5" "$6" "$7" "$8" "$9"',
    'short-settle',path.join(root,'bin/fm-wake-lib.sh'),path.join(dir,'reconcile.lock'),process.execPath,script,home,root,id,String(index),expectedMergeCommit],
  {encoding:'utf8',env:{...process.env,FM_HOME:home,FM_ROOT_OVERRIDE:root,FM_STATE_OVERRIDE:path.join(home,'state')}});
  return JSON.parse(output);
}
export function reconcileOperationReceipts(home,request) {
  if(!request.input.operations) return;
  const dir=path.join(home,'state/short-agents',request.id);
  operationReceipts(dir);
  const startedFile=path.join(dir,'started.json');
  if(!exists(startedFile) || sameLiveProcess(read(startedFile).identity)) return;
  if(!request.input.operations.steps.some(step=>resources(home,step).some(({file})=>exists(file)&&read(file).id===request.id))) return;
  const script=fileURLToPath(import.meta.url);
  execFileSync('bash',['-c',
    '. "$1"; fm_lock_acquire_wait_bounded "$2" 5 || exit; trap \'fm_lock_release "$2"\' EXIT; "$3" "$4" reconcile "$5"',
    'short-reconcile',path.join(path.dirname(script),'fm-wake-lib.sh'),path.join(dir,'reconcile.lock'),process.execPath,script,home],
  {input:JSON.stringify(request),encoding:'utf8',env:{...process.env,FM_HOME:home,FM_ROOT_OVERRIDE:path.dirname(path.dirname(script)),FM_STATE_OVERRIDE:path.join(home,'state')}});
}
function reconcileLocked(home,request) {
  const dir=path.join(home,'state/short-agents',request.id),startedFile=path.join(dir,'started.json');
  if(!equal(read(path.join(dir,'request.json')),request)) fail('short task request/generation changed');
  const started=read(startedFile);
  if(started.nonce!==request.nonce || started.pid!==started.identity?.pid) fail('short runner identity changed');
  if(sameLiveProcess(started.identity)) return;
  const receipts=operationReceipts(dir);
  for(const [index,step] of request.input.operations.steps.entries()) {
    let receipt=receipts.find(r=>r.index===index);
    const intentFile=path.join(dir,`operation-${index}.intent.json`),effectFile=path.join(dir,`operation-${index}.effect.json`);
    if(!receipt&&step.action==='cleanup'&&exists(effectFile)) receipt=settleCleanupLocked(home,request,started,index,step);
    if(receipt?.state==='completed') {
      if(receipt.settlement==='main-current-cleanup-readback') fail('removed rich-lifecycle settlement cannot authorize a current effect');
      if(receipt.settlement===undefined&&sameLiveProcess(receipt.executor)) continue;
    } else {
      if(exists(effectFile)&&receipt?.settlement!=='dead-owner-legacy-cleanup-preflight-readback') continue;
      if(exists(intentFile)) {
        const intent=read(intentFile);
        if(receipt?.state!=='refused' || intent.nonce!==request.nonce || intent.index!==index || !equal(intent.step,step)) continue;
      }
    }
    for(const {file,target} of resources(home,step)) {
      if(!exists(file)) continue;
      const marker=read(file);
      if(marker.id!==request.id || marker.nonce!==request.nonce || marker.index!==index || marker.home!==home || marker.target!==target) continue;
      if(!equal(read(path.join(dir,'request.json')),request) || !equal(read(startedFile),started)) fail('short task recovery identity changed');
      fs.unlinkSync(file);
    }
  }
}

// The guarded owner calls this immediately before effects. An actor string is
// insufficient: the request, bound child process, intent and exact owner args
// must all agree. No model tool can set these environment variables.
export function verifyOwner(action,args,{receipt=false}={}) {
  const home=fs.realpathSync(process.env.FM_HOME);
  const id=process.env.FM_SHORT_TASK;
  if(!/^short-[a-f0-9]{64}$/.test(id??'')) fail('missing short execution binding');
  const dir=path.join(home,'state/short-agents',id),request=read(path.join(dir,'request.json'));
  const index=Number(process.env.FM_SHORT_STEP);
  const step=receipt ? request.input.operations.steps[index] : operationCurrent(home,request,index);
  const started=read(path.join(dir,'started.json'));
  if(started.nonce!==request.nonce || !started.identity || !['pid','start','boot'].every(k=>processIdentity(started.pid)[k]===started.identity[k])) fail('short runner identity changed');
  let descendent=false;
  for(let p=process.ppid,n=0;p>1 && n<16;n++) {
    if(p===started.pid) {descendent=true;break;}
    p=processIdentity(p).parent;
  }
  if(!descendent) fail('owner caller is not the bound short runner descendant');
  const caller=fs.readFileSync(`/proc/${process.ppid}/cmdline`,'utf8').split('\0').filter(Boolean);
  const expected=path.join(path.dirname(fileURLToPath(import.meta.url)),commandFor(step).script);
  if(!caller.includes(expected)) fail('caller is not the granted action owner');
  const invocation=commandFor(step);
  if(action!==invocation.action || !equal(args,invocation.args)) fail('owner action/target outside grant');
  const intent=read(path.join(dir,`operation-${index}.intent.json`));
  if(intent.nonce!==request.nonce || intent.index!==index) fail('operation intent identity changed');
  for(const r of resources(home,step)) {
    const marker=read(r.file);
    if(marker.id!==id || marker.nonce!==request.nonce || marker.index!==index || marker.home!==home) fail('operation resource ownership changed');
  }
  return {home,dir,request,index,step,started};
}
function commandFor(step) {
  switch(step.action) {
    case 'sync': case 'recover-sync':return {action:'sync',script:'fm-fleet-sync.sh',args:[step.project]};
    case 'install-shellcheck':return {action:'install-shellcheck',script:'fm-install-shellcheck.sh',args:[step.destination]};
    case 'merge':return {action:'merge',script:'fm-pr-merge.sh',args:[step.task,step.url]};
    case 'cleanup':return {action:'cleanup',script:'fm-teardown.sh',args:[step.task]};
    default:fail('unsupported operation');
  }
}
export async function executeOperations(service,request,check) {
  const dir=service.dir(request.id),results=[];
  for(let index=0;index<request.input.operations.steps.length;index++) {
    check();
    const step=request.input.operations.steps[index];
    if(!equal(read(path.join(dir,'request.json')),request)) fail('short task request/generation changed');
    const receiptFile=path.join(dir,`operation-${index}.receipt.json`);
    if(exists(receiptFile)) {const receipt=operationReceipts(dir).find(r=>r.index===index);results.push(receipt);if(receipt.state!=='completed') fail('prior operation did not complete');continue;}
    operationCurrent(service.home,request,index);
    const intentFile=path.join(dir,`operation-${index}.intent.json`);
    if(exists(intentFile)) fail('uncertain prior operation; reconcile receipt before any new effect');
    const held=[], invocation=commandFor(step);
    const release=()=>{for(const file of held.splice(0)) if(exists(file)) {
      const marker=read(file);
      if(marker.id!==request.id || marker.nonce!==request.nonce || marker.index!==index || marker.home!==service.home) fail('operation resource ownership changed; preserving marker');
      fs.unlinkSync(file);
    }};
    try {
      for(const r of resources(service.home,step)) {
        fs.mkdirSync(path.dirname(r.file),{recursive:true,mode:0o700});
        if(!publish(r.file,{home:service.home,id:request.id,nonce:request.nonce,index,target:r.target})) fail('resource already has a short operation; no concurrent effect');
        held.push(r.file);
      }
      operationCurrent(service.home,request,index);
      if(!publish(intentFile,{nonce:request.nonce,index,step,at:Date.now()})) fail('operation intent already exists');
      const env={...process.env,FM_HOME:service.home,FM_ROOT_OVERRIDE:service.root,FM_STATE_OVERRIDE:path.join(service.home,'state'),FM_CONFIG_OVERRIDE:path.join(service.home,'config'),FM_SUPERVISION_ACTOR:'short',FM_SHORT_TASK:request.id,FM_SHORT_STEP:String(index),FM_FLEET_PRUNE:'0'};
      // Never inherit caller overrides that could redirect a guarded owner.
      for(const key of ['FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_LEASE_HOLDER_PID']) delete env[key];
      let output;
      try {output=await exec('bash',[path.join(service.root,'bin',invocation.script),...invocation.args],{env,cwd:dir,maxBuffer:Number.POSITIVE_INFINITY});}
      catch(error) {output={stdout:error.stdout??'',stderr:error.stderr??'',error:String(error.message)};}
      fs.writeFileSync(path.join(dir,`operation-${index}.output.json`),JSON.stringify(output)+'\n',{mode:0o600});
      // Owners write verified postconditions, not a free-form success string.
      if(!exists(receiptFile)) {
        if(!exists(path.join(dir,`operation-${index}.effect.json`))) {
          publish(receiptFile,{id:request.id,nonce:request.nonce,index,action:invocation.action,state:'refused',at:Date.now(),evidence:{reason:'owner refused before a guarded effect'}});
          release();
        }
        fail('owner returned without a completed receipt; inspect output and effect intent');
      }
      const receipt=operationReceipts(dir).find(r=>r.index===index);results.push(receipt);
      if(receipt.state!=='completed') fail('owner postcondition is incomplete');
      release();
    } catch(error) {
      // A resource with no intent has not acted and can be released safely.
      if(!exists(intentFile)) release();
      throw error;
    }
  }
  return results;
}

if(process.argv[1] && fs.realpathSync(process.argv[1])===fs.realpathSync(fileURLToPath(import.meta.url))) {
  try {
    const [command,action,...args]=process.argv.slice(2);
    if(command==='reconcile') reconcileLocked(action,JSON.parse(fs.readFileSync(0,'utf8')));
    else if(command==='_settle-merge-locked') console.log(JSON.stringify(settleMergeLocked(action,args[0],args[1],Number(args[2]),args[3])));
    else if(command==='verify') verifyOwner(action,args);
    else if(command==='effect') {
      const v=verifyOwner(action,args);
      const owner=action==='cleanup'?v.started.identity:processIdentity(process.ppid);
      publish(path.join(v.dir,`operation-${v.index}.effect.json`),{id:v.request.id,nonce:v.request.nonce,index:v.index,owner,at:Date.now()});
    }
    else if(command==='receipt') {
      const evidence=JSON.parse(args.pop());
      const v=verifyOwner(action,args,{receipt:true});
      publish(path.join(v.dir,`operation-${v.index}.receipt.json`),{id:v.request.id,nonce:v.request.nonce,index:v.index,action,state:'completed',at:Date.now(),executor:processIdentity(process.ppid),evidence});
    } else fail('unsupported operation owner command');
  } catch(error) {console.error(error.message);process.exitCode=1;}
}
