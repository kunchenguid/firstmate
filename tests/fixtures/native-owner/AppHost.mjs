// Disposable host adapter. Only this process owns the app-server connection.
// Dynamic tool arguments never select a thread, executable, home, or command.
import {createNotificationGate} from './codex-tool-gate.mjs';
import {createHostLifecycle,reconciliationWarning} from './host-lifecycle.mjs';
import {discoverMcpServerNames,isolatedAppServerArgs,verifyExternalToolConfiguration,verifyExternalToolIsolation} from './app-server-policy.mjs';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
const home=process.env.FM_PROBE_HOME;
const executable=path.join(process.env.APPDATA,'npm/node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe');
const evidence={frames:[],tools:[],native:[],primary:null,foreign:null,passed:false};
const save=()=>fs.writeFileSync(path.join(home,'app-host-evidence.json'),JSON.stringify(evidence,null,2));
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const base={kind:'notification',session:process.env.FM_PROBE_SESSION,home,nonce:process.env.FM_PROBE_NONCE};
async function native(action,extra={},signal) {
 const until=Date.now()+12000;
 for(;;) {
  if(signal?.aborted)throw Error('Native request cancelled');
  try {
   const result=await new Promise((resolve,reject)=>{
    const socket=net.createConnection('\\\\.\\pipe\\'+process.env.FM_PROBE_PIPE);let buffer='',done=false;
    socket.setTimeout(9000,()=>socket.destroy(Error('Native operation query timed out')));
    socket.on('connect',()=>socket.write(JSON.stringify({...base,action,...extra})+'\n'));
    socket.on('data',chunk=>{buffer+=chunk;const end=buffer.indexOf('\n');if(end>=0&&!done){done=true;try{resolve(JSON.parse(buffer.slice(0,end)));}catch(error){reject(error);}socket.end();}});
    const abort=()=>socket.destroy(Error('Native request cancelled'));signal?.addEventListener('abort',abort,{once:true});
    socket.on('error',reject);socket.on('close',()=>{signal?.removeEventListener('abort',abort);if(!done)reject(Error('Native channel closed without a result'));});
   });
   if(!result.notificationAuthorized)throw Error('Native controller denied host adapter');
    evidence.native.push({action,state:result.operationState,startupExpired:result.startupExpired,operationExit:result.operationExit});
   return result;
  } catch(error) {if(!['EBUSY','ENOENT'].includes(error.code)||Date.now()>until)throw error;await pause(40);}
 }
}
async function operation(action,extra={}) {
 const start=await native(action,extra);
 if(start.operationState!=='pending')throw Error('Operation did not start: '+start.operationState);
 for(let i=0;i<700;i++) {
  await pause(100);
  if(action==='ack'&&process.env.FM_PROBE_ACK_FAULT&&fs.existsSync(path.join(home,'ack-fault-ready'))) {
   const stopped=await native('shutdown');
   if(stopped.operationState!=='stopped')throw Error('Interrupted operation did not stop');
   if(!stopped.reconciliationRequired)throw Error('Interrupted acknowledgement did not require reconciliation');
   return {operationState:'interrupted'};
  }
  const result=await native('result');
  if(result.operationState==='failed')throw Error('Native notification command failed');
  if(result.operationState!=='pending')return result;
 }
 throw Error('Bounded operation exceeded 70 seconds');
}
const mcpServerNames=await discoverMcpServerNames(executable,home);
const child=spawn(executable,isolatedAppServerArgs(mcpServerNames,['-c','windows.sandbox=unelevated','-c','model_reasoning_effort=high']),{cwd:home,stdio:['pipe','pipe','pipe']});
let alive=true,next=0,stderr='',primary=null,receipt=null,challenge=null,acknowledged=false;
let gate=null,activeTurn=null,closing=false;
const pending=new Map(),completed=new Map();
const failPending=error=>{for(const value of pending.values())value.reject(error);pending.clear();};
const timer=setTimeout(()=>{child.kill();process.exitCode=1;},220000);
child.stderr.on('data',chunk=>stderr+=chunk);
child.on('error',error=>{alive=false;failPending(error);});
child.on('exit',code=>{alive=false;failPending(Error('App-server exited '+code));});
const send=value=>{if(!alive)throw Error('App-server is no longer live');child.stdin.write(JSON.stringify(value)+'\n');};
const request=(method,params)=>new Promise((resolve,reject)=>{const id=++next;pending.set(id,{resolve,reject,method,params});send({id,method,params});});
async function tool(frame) {
 const p=frame.params;
 const record={requestId:frame.id,threadId:p.threadId,turnId:p.turnId,callId:p.callId,tool:p.tool,arguments:p.arguments};
 evidence.tools.push(record);
 const respond=(success,value)=>{record.success=success;record.result=value;if(!closing&&alive)send({id:frame.id,result:{success,contentItems:[{type:'inputText',text:JSON.stringify(value)}]}});save();};
 if(!gate)return respond(false,{denied:'primary-not-registered'});
 const result=await gate.handle(p);
 if(result.success&&p.tool==='fm_notification_check'){receipt=result.value.receipt;challenge=result.value.challenge;}
 if(result.success&&p.tool==='fm_notification_ack')acknowledged=true;
 respond(result.success,result.value);
}
createInterface({input:child.stdout}).on('line',line=>{
 let event;try{event=JSON.parse(line);}catch{alive=false;failPending(Error('Invalid app-server frame'));return;}
 evidence.frames.push(event);
 if(event.method==='item/tool/call'&&event.id!==undefined){tool(event).catch(error=>{evidence.fatal=error.message;save();child.kill();});return;}
 if(event.id!==undefined&&pending.has(event.id)) {
  const value=pending.get(event.id);pending.delete(event.id);
  if(event.error)value.reject(Error(JSON.stringify(event.error)));
  else {if(value.method==='turn/start'&&value.params.threadId===primary){gate.beginTurn(primary,event.result.turn.id);activeTurn=event.result.turn.id;}value.resolve(event.result);}
 } else if(event.method==='turn/completed'){completed.set(event.params.turn.id,event.params.turn);gate?.endTurn(event.params.threadId,event.params.turn.id);if(event.params.turn.id===activeTurn)activeTurn=null;}
 else if(event.id!==undefined&&event.method)send({id:event.id,error:{code:-32601,message:'No other host operations are authorized'}});
});
const tools=[
 {name:'fm_notification_check',description:'Read exactly one controlled notification through the registered Firstmate operation.',inputSchema:{type:'object',properties:{},additionalProperties:false}},
 {name:'fm_notification_ack',description:'After observing the notification, acknowledge its receipt and exact observed challenge. Receipts are single use.',inputSchema:{type:'object',properties:{receipt:{type:'string'},observed:{type:'string'}},required:['receipt','observed'],additionalProperties:false}},
];
async function turn(threadId,text) {
 const started=await request('turn/start',{threadId,input:[{type:'text',text,text_elements:[]}]});
 for(let i=0;i<1500;i++){if(!alive)throw Error('App-server lost during turn');if(completed.has(started.turn.id)){const end=completed.get(started.turn.id);if(end.status!=='completed')throw Error('Turn failed: '+JSON.stringify(end));return started.turn.id;}await pause(100);}
 throw Error('Turn exceeded bounded wait');
}
try {
  if(process.env.FM_PROBE_STARTUP_QUEUED==='1') {
   const status=await native('status'),unavailable=await native('check');
   const note=process.env.FM_PROBE_STARTUP_NOTE;
   const preserved=fs.existsSync(path.join(process.env.FM_HOME,'state','inbox',note+'.note'));
   if(status.operationState!=='starting'||unavailable.operationState!=='busy'||!preserved)throw Error('Queued startup notification was not preserved while work was unavailable');
   evidence.startupQueued={status:status.operationState,unavailable:unavailable.operationState,preserved,note};save();
   fs.writeFileSync(path.join(home,'startup-unavailable-observed'),'observed');
  }
  await request('initialize',{clientInfo:{name:'firstmate-scoped-notification-test',version:'0.0.0'},capabilities:{experimentalApi:true}});
 send({method:'initialized',params:{}});
 let ready=false;
 for(let i=0;i<1200;i++){const state=await native('result');if(state.startupExpired){ready=true;break;}await pause(100);}
 if(!ready||!fs.existsSync(path.join(home,'owner-operation.complete')))throw Error('Startup did not finish and expire');
 const protectedFiles=[path.join(process.env.FM_HOME,'owner-receipts.jsonl'),path.join(process.env.FM_HOME,'state','.wake-queue')];
 const protectedSnapshot=()=>protectedFiles.map(file=>fs.existsSync(file)?fs.readFileSync(file).toString('base64'):null);
 const beforeOrdinaryTool=protectedSnapshot();
 const ordinaryTool=await request('command/exec',{command:[process.env.FM_PROBE_EXE,'privilege-probe'],cwd:home,sandboxPolicy:{type:'readOnly',access:{type:'fullAccess'}},timeoutMs:10000});
 if(ordinaryTool.exitCode!==0)throw Error('Ordinary sandbox command did not execute: '+ordinaryTool.stderr);
 const ordinaryLines=ordinaryTool.stdout.trim().split(/\r?\n/).filter(Boolean);
 if(ordinaryLines.length!==2)throw Error('Ordinary sandbox command returned unexpected evidence');
 const ordinaryToken=JSON.parse(ordinaryLines[0]),ordinaryVerdict=JSON.parse(ordinaryLines[1]);
 if(!Array.isArray(ordinaryToken.restricting)||ordinaryToken.restricting.length===0)throw Error('Command did not execute under the ordinary restricted sandbox token');
 if(ordinaryVerdict.association!=='associated'||ordinaryVerdict.hostClassification!=='unclassified-descendant')throw Error('Ordinary sandbox command did not reach the controller with copied claims as a session descendant');
 if(ordinaryVerdict.notificationAuthorized!==false||ordinaryVerdict.authorityGranted!==false)throw Error('Ordinary sandbox command acquired privileged host authority');
 await pause(250);
 const primaryControl=await native('result');
 if(primaryControl.operationState!=='quiet'||JSON.stringify(protectedSnapshot())!==JSON.stringify(beforeOrdinaryTool))throw Error('Ordinary sandbox command caused a protected notification effect');
 evidence.ordinaryToolRefusal={exitCode:ordinaryTool.exitCode,association:ordinaryVerdict.association,hostClassification:ordinaryVerdict.hostClassification,restricted:true,protectedEffects:false,registeredPrimaryState:primaryControl.operationState};save();
 const params={cwd:home,model:'gpt-5.6-terra',sandbox:'read-only',approvalPolicy:'never',ephemeral:true,dynamicTools:tools};
 const externalConfiguration=await verifyExternalToolConfiguration(request,mcpServerNames);
 primary=(await request('thread/start',params)).thread.id;evidence.primary=primary;
 evidence.externalTools=await verifyExternalToolIsolation(request,primary,externalConfiguration);
 gate=createNotificationGate({primaryThread:primary,operate:operation,isAlive:()=>alive});
 evidence.foreign=(await request('thread/start',params)).thread.id;
 if(process.env.FM_PROBE_API_DRY==='1') {
  const delivery=await operation('check');
  const ack=await operation('ack',{receipt:delivery.notification.receipt,observed:delivery.notification.challenge});
   if(['partial','complete'].includes(process.env.FM_PROBE_ACK_FAULT)) {
    if(ack.operationState!=='interrupted')throw Error('Fault injection did not interrupt the acknowledgement');
    evidence.ackFault=process.env.FM_PROBE_ACK_FAULT;
   } else if(process.env.FM_PROBE_ACK_FAULT) {
    if(ack.operationState!=='reconciliation-required')throw Error('Zero-exit acknowledgement without exact completion evidence was accepted');
    evidence.ackFault=process.env.FM_PROBE_ACK_FAULT;
   } else {
   const replay=await native('ack',{receipt:delivery.notification.receipt,observed:delivery.notification.challenge});
   if(ack.operationState!=='acknowledged'||replay.operationState!=='denied')throw Error('Native bridge preflight failed');
  }
  evidence.passed=true;evidence.modelFree=true;
  console.log(evidence.ackFault?'PASS: fixed acknowledgement fault preserved the reconciliation obligation; model-free only.':'PASS: registered post-startup operations deliver and acknowledge using the native bridge; model-free only.');
 } else {
 evidence.primaryTurn=await turn(primary,'This is a bounded integration test in an empty disposable Firstmate home. Use only the supplied fm_notification tools; do not use shell, file, browser, or other tools. Call fm_notification_check once. Read the message, then call fm_notification_ack with its receipt and the observed challenge. After successful acknowledgement, repeat that same acknowledgement exactly once to test replay rejection. Report the three results and stop. Do not retry anything else.');
 if(!acknowledged)throw Error('Primary did not acknowledge notification');
 const primaryCalls=evidence.tools.filter(row=>row.threadId===primary);
 if(primaryCalls.length!==3||!primaryCalls[0].success||!primaryCalls[1].success||primaryCalls[2].result?.denied!=='receipt-already-consumed')throw Error('Primary/check/ack/replay sequence differed');
 // The native owner independently refuses a replay even from the trusted host.
 const nativeReplay=await native('ack',{receipt,observed:challenge});
 if(nativeReplay.operationState!=='denied')throw Error('Native owner accepted replay');
 evidence.nativeReplayDenied=true;
 evidence.foreignTurn=await turn(evidence.foreign,'This is a deliberate authorization negative control. Call fm_notification_check exactly once with no arguments. It should be denied because this is not the registered primary thread. Do not use any other tool, retry, or change settings. Report the result and stop.');
 const foreignCalls=evidence.tools.filter(row=>row.threadId===evidence.foreign);
 if(foreignCalls.length!==1||foreignCalls[0].success||foreignCalls[0].result?.denied!=='wrong-thread-turn-or-replay')throw Error('Foreign thread rejection not demonstrated');
 evidence.passed=true;evidence.receipt=receipt;evidence.challenge=challenge;
 console.log('PASS: primary received and acknowledged the notification; receipt replay and a second real thread were denied.');
 }
} catch(error) {evidence.fatal=error.stack;process.exitCode=1;console.error(error.stack);} finally {
 closing=true;
 const lifecycle=createHostLifecycle({
  gate:{close:()=>gate?.close()},
  interrupt:()=>{if(activeTurn&&alive)void request('turn/interrupt',{threadId:primary,turnId:activeTurn}).catch(()=>{});},
  stopOperations:async signal=>{const value=await native('shutdown',{},signal);return {stopped:value.operationState==='stopped',reconciliationRequired:value.reconciliationRequired===true};},
  closeInput:()=>child.stdin.end(),
  waitForExit:signal=>!alive?Promise.resolve(true):new Promise(resolve=>{const stop=()=>{child.removeListener('exit',exit);resolve(false);};const exit=()=>{signal.removeEventListener('abort',stop);resolve(true);};child.once('exit',exit);signal.addEventListener('abort',stop,{once:true});}),
  terminate:()=>child.kill(),graceMs:5000,
 });
 evidence.shutdown=await lifecycle.shutdown();
 if(evidence.shutdown.reconciliationRequired)console.error(reconciliationWarning(path.join(process.env.FM_HOME,'owner-receipts.jsonl')));
 if(!evidence.shutdown.stopped){evidence.passed=false;process.exitCode=1;}
 clearTimeout(timer);
 save();fs.writeFileSync(path.join(home,'app-server.stderr'),stderr);
}
