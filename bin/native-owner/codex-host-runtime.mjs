import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {confirmAutomaticNotificationOffer,createNotificationGate} from './codex-tool-gate.mjs';
import {createHostLifecycle,reconciliationWarning} from './host-lifecycle.mjs';
import {saveHostEvidence} from './host-evidence.mjs';
import {discoverMcpServerNames,isolatedAppServerArgs,verifyExternalToolConfiguration,verifyExternalToolIsolation} from './app-server-policy.mjs';

export async function runCodexHost(options={}) {
 const env=options.env??process.env;
 const runtime=env.FM_PROBE_HOME,root=env.FM_PROBE_CODE_ROOT;
 const inputStream=options.input??process.stdin,outputStream=options.output??process.stdout,errorStream=options.error??process.stderr;
 const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
 let closing=false,gate=null,server=null,alive=false,thread=null,activeTurn=null,ended=false;
 let lifecycle=null,terminal=null,announced=null,next=0,nativeWaiter=null,nativeTail=Promise.resolve();
 let socket=null,channel=null;
 const input=[],pending=new Map(),turns=new Map();
 const evidence={ready:false,turns:[],tools:[],automatic:[],digestDeliveredBeforeDeferred:false};
 const save=()=>saveHostEvidence(runtime,evidence);
 const consoleInput=createInterface({input:inputStream});
 consoleInput.on('line',line=>{
  if(line==='/quit'){void stop();return;}
  if(line==='/interrupt'){void interrupt().catch(fail);return;}
  input.push(line);
 });
 consoleInput.on('close',()=>{ended=true;});
 const onSigint=()=>{if(activeTurn)void interrupt().catch(fail);else void stop();};
 const onSigterm=()=>{void stop();};
 if(options.installSignalHandlers!==false){process.on('SIGINT',onSigint);process.on('SIGTERM',onSigterm);}

 let connection;
 if(options.native){
  connection=Promise.resolve();
 }else{
  socket=net.createConnection('\\\\.\\pipe\\'+env.FM_PROBE_PIPE);
  connection=new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>{socket.destroy();reject(Error('Native connection timed out'));},10000);
   socket.once('connect',()=>{clearTimeout(timer);resolve();});socket.once('error',error=>{clearTimeout(timer);reject(error);});
  });
  channel=createInterface({input:socket});
  channel.on('line',line=>{
   if(!nativeWaiter){fail(Error('Unexpected native response'));return;}
   const waiter=nativeWaiter;nativeWaiter=null;
   try {const value=JSON.parse(line);if(!value.notificationAuthorized)throw Error('Native host authorization refused');waiter.resolve(value);}catch(error){waiter.reject(error);}
  });
  socket.on('error',error=>{nativeWaiter?.reject(error);nativeWaiter=null;if(!closing)fail(error);});
  socket.on('close',()=>{const error=Error('Native controller connection closed');nativeWaiter?.reject(error);nativeWaiter=null;if(!closing)fail(error);});
 }
 function native(action,extra={},signal){
  if(options.native)return Promise.resolve().then(()=>options.native(action,extra,signal));
  const run=async()=>{
   await connection;if(socket.destroyed||signal?.aborted||(closing&&action!=='shutdown'))throw Error('Native session unavailable');
   return new Promise((resolve,reject)=>{
    let timer;
    const abort=()=>{socket.destroy();finish(reject,Error('Native request interrupted; durable work preserved'));};
    const finish=(callback,value)=>{clearTimeout(timer);signal?.removeEventListener('abort',abort);callback(value);};
    nativeWaiter={resolve:value=>finish(resolve,value),reject:error=>finish(reject,error)};
    timer=setTimeout(abort,10000);signal?.addEventListener('abort',abort,{once:true});
    socket.write(JSON.stringify({kind:'notification',session:env.FM_PROBE_SESSION,home:runtime,nonce:env.FM_PROBE_NONCE,action,...extra})+'\n');
   });
  };
  const result=nativeTail.then(run);nativeTail=result.catch(()=>{});return result;
 }
 function send(frame){if(!alive)throw Error('App-server is not live');server.stdin.write(JSON.stringify(frame)+'\n');}
 function request(method,params,signal){
  return new Promise((resolve,reject)=>{
   if(signal?.aborted){reject(Error('Request cancelled'));return;}
   const id=++next;let timer;
   const clean=()=>{clearTimeout(timer);signal?.removeEventListener('abort',abort);};
   const abort=()=>{pending.delete(id);clean();reject(Error('App-server request cancelled'));};
   timer=setTimeout(()=>{pending.delete(id);clean();reject(Error('App-server '+method+' timed out'));},30000);
   pending.set(id,{method,resolve:value=>{clean();resolve(value);},reject:error=>{clean();reject(error);}});
   signal?.addEventListener('abort',abort,{once:true});
   try {send({id,method,params});}catch(error){pending.delete(id);clean();reject(error);}
  });
 }
 async function interrupt(signal){
  if(!activeTurn||!alive)return;
  const target=activeTurn;
  await request('turn/interrupt',{threadId:thread,turnId:target},signal);
  const limit=Date.now()+10000;
  while(alive&&!turns.has(target)&&!signal?.aborted&&Date.now()<limit)await pause(20);
  if(signal?.aborted||(alive&&!turns.has(target)))throw Error('Turn interruption was not confirmed');
 }
 async function operation(action,extra={}){
  if(action==='check'){
   const status=await native('status');
   if(status.operationState==='starting')return status;
   if(status.operationState!=='ready')throw Error('Native work unavailable: '+status.operationState);
   const previous=await native('result');if(previous.operationState==='delivered')return previous;
  }
  const started=await native(action,extra);
  if(started.operationState!=='pending')throw Error('Operation refused: '+started.operationState);
  for(let count=0;count<650&&!closing;count++){
   await pause(100);const value=await native('result');
   if(value.operationState==='failed')throw Error('Fixed operation failed; inspect '+path.join(runtime,'operations.log'));
   if(value.operationState!=='pending')return value;
  }
  throw Error('Operation interrupted or exceeded its bound; durable work preserved');
 }
 async function tool(frame){
  const result=gate?await gate.handle(frame.params):{success:false,value:{denied:'primary-not-ready'}};
  evidence.tools.push({thread:frame.params.threadId,turn:frame.params.turnId,tool:frame.params.tool,success:result.success});save();
  if(!closing&&alive)send({id:frame.id,result:{success:result.success,contentItems:[{type:'inputText',text:JSON.stringify(result.value)}]}});
 }
 async function turn(text){
  const started=await request('turn/start',{threadId:thread,input:[{type:'text',text,text_elements:[]}]});
  const id=started.turn.id;
  const limit=Date.now()+180000;
  while(alive&&!closing&&!turns.has(id)&&Date.now()<limit)await pause(50);
  const result=turns.get(id);
  if(!closing&&(!result||!['completed','interrupted'].includes(result.status)))throw Error('The model turn did not complete');
  outputStream.write('\n');
  return result;
 }
 function fail(error){if(!terminal)terminal=error;void stop();}
 function stop(){
  if(lifecycle)return lifecycle.shutdown();
  closing=true;consoleInput.close();inputStream.destroy?.();
  lifecycle=createHostLifecycle({gate:{close:()=>gate?.close()},interrupt,
   stopOperations:async signal=>{const value=await native('shutdown',{},signal);return {stopped:value.operationState==='stopped',reconciliationRequired:value.reconciliationRequired===true};},
   closeInput:()=>{if(server)server.stdin.end();},
   waitForExit:signal=>!alive?Promise.resolve(true):new Promise(resolve=>{
    const exit=()=>{signal.removeEventListener('abort',abort);resolve(true);};
    const abort=()=>{server.removeListener('exit',exit);resolve(false);};
    server.once('exit',exit);signal.addEventListener('abort',abort,{once:true});
   }),terminate:()=>server?.kill(),graceMs:3000});
  const result=lifecycle.shutdown();
  void result.then(value=>{
   fs.writeFileSync(path.join(runtime,'shutdown.json'),JSON.stringify(value));
   if(value.reconciliationRequired)errorStream.write(reconciliationWarning(path.join(env.FM_HOME,'owner-receipts.jsonl'))+'\n');
   if(!value.stopped){
    if(terminal)errorStream.write('Shutdown was not fully confirmed; durable work was preserved.\n');
    else terminal=Error('Shutdown was not fully confirmed; durable work was preserved.');
   }
   channel?.close();socket?.destroy();
  });
  return result;
 }
 try {
  await connection;
  let status=await native('status');
  if(status.operationState==='reconciliation-required')throw Error('An earlier acknowledgement is incomplete. Its records are preserved; review '+path.join(env.FM_HOME,'owner-receipts.jsonl')+' before starting more work.');
  const limit=Date.now()+200000;
  while(!closing&&!fs.existsSync(path.join(runtime,'digest.ready'))){
   status=await native('status');if(status.operationState==='startup-failed'||Date.now()>limit)throw Error('Startup failed; inspect '+path.join(runtime,'startup.log'));
   await pause(100);
  }
  if(!closing){
   const executable=path.join(env.APPDATA,'npm/node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe');
   const mcpServerNames=options.mcpServerNames??await discoverMcpServerNames(executable,root,env);
   server=options.spawnAppServer?options.spawnAppServer({executable,mcpServerNames,root,env}):spawn(executable,isolatedAppServerArgs(mcpServerNames,['-c','windows.sandbox=unelevated']),{cwd:root,stdio:['pipe','pipe','pipe'],detached:true,windowsHide:true});alive=true;
   server.stderr.on('data',data=>fs.appendFileSync(path.join(runtime,'app-server.stderr'),data));
   const lost=error=>{alive=false;for(const waiter of pending.values())waiter.reject(error);pending.clear();if(!closing)fail(error);};
   server.on('error',lost);server.on('exit',()=>lost(Error('App-server exited')));server.stdin.on('error',error=>{if(!closing)fail(error);});
   createInterface({input:server.stdout}).on('line',line=>{
    try {
     const frame=JSON.parse(line);
     if(frame.method==='item/tool/call'&&frame.id!==undefined){void tool(frame).catch(fail);return;}
     if(frame.id!==undefined&&pending.has(frame.id)){
      const waiter=pending.get(frame.id);pending.delete(frame.id);
      if(frame.error)waiter.reject(Error(JSON.stringify(frame.error)));
      else {if(waiter.method==='turn/start'){activeTurn=frame.result.turn.id;evidence.activeTurn=activeTurn;save();gate.beginTurn(thread,activeTurn);}waiter.resolve(frame.result);}return;
     }
     if(frame.method==='turn/completed'&&frame.params.threadId===thread){turns.set(frame.params.turn.id,frame.params.turn);evidence.turns.push({id:frame.params.turn.id,status:frame.params.turn.status});save();gate?.endTurn(thread,frame.params.turn.id);if(activeTurn===frame.params.turn.id){activeTurn=null;evidence.activeTurn=null;save();}}
     if(frame.method==='item/agentMessage/delta'&&frame.params.threadId===thread)outputStream.write(frame.params.delta);
     if(frame.id!==undefined&&frame.method)send({id:frame.id,error:{code:-32601,message:'No other host operations are authorized'}});
    }catch(error){fail(error);}
   });
   await request('initialize',{clientInfo:{name:'firstmate-native',version:'0.1.0'},capabilities:{experimentalApi:true}});send({method:'initialized',params:{}});
   const dynamicTools=[
    {name:'fm_notification_check',description:'Read pending Firstmate notifications. Quiet means there is no new delivery.',inputSchema:{type:'object',properties:{},additionalProperties:false}},
    {name:'fm_notification_ack',description:'Acknowledge an observed and handled delivery. Never acknowledge unresolved decisions or unperformed work.',inputSchema:{type:'object',properties:{receipt:{type:'string'},observed:{type:'string'}},required:['receipt','observed'],additionalProperties:false}},
   ];
   const instructions='The native host already ran startup exactly once. Do not rerun startup or arm another supervisor. This experimental empty-fleet session exposes two privileged notification tools. Ordinary Codex tools remain confined to the read-only, network-disabled sandbox and have no native host authority; do not claim to dispatch project work. The host continues notification checks after startup finishes. Use the supplied receipt and observed challenge only after handling the entire delivery. Unresolved work must remain pending. Startup digest follows:\n'+fs.readFileSync(path.join(runtime,'startup.log'),'utf8');
   const externalConfiguration=await verifyExternalToolConfiguration(request,mcpServerNames);
   const started=await request('thread/start',{cwd:root,sandbox:'read-only',approvalPolicy:'never',ephemeral:true,developerInstructions:instructions,dynamicTools});
   if(started.sandbox?.type!=='readOnly'||started.sandbox.networkAccess!==false||started.approvalPolicy!=='never')throw Error('App-server returned an unexpected security policy');
   thread=started.thread.id;evidence.thread=thread;evidence.externalTools=await verifyExternalToolIsolation(request,thread,externalConfiguration);evidence.ready=true;evidence.policy={sandbox:started.sandbox,approval:started.approvalPolicy};evidence.digestDeliveredBeforeDeferred=!fs.existsSync(path.join(runtime,'startup.finished'));save();
   gate=createNotificationGate({primaryThread:thread,operate:operation,isAlive:()=>alive&&!closing});
   errorStream.write('Experimental native session ready. /interrupt stops the current turn; /quit ends the session.\n');
   while(!closing&&alive){
    if(env.FM_PROBE_VERIFY_ONLY==='1'){
     if(input.length)throw Error('Verify-only mode does not start model turns');
     if(ended)break;await pause(100);continue;
    }
    if(input.length){await turn(input.shift());continue;}
    if(ended)break;
    const result=await operation('check');
    if(result.operationState==='delivered'&&result.notification.receipt!==announced){
     const receipt=result.notification.receipt;
     const handled=await turn('A new durable notification is available. Read it with fm_notification_check, handle it within the available authority, and acknowledge only if fully handled.');
     let outcome='interrupted';
     if(!closing&&alive&&handled?.status==='completed'){
      if(confirmAutomaticNotificationOffer(gate,thread,handled,receipt)){announced=receipt;outcome='offered';}
     }else if(!closing&&alive&&handled?.status==='interrupted')await pause(1000);
     evidence.automatic.push({turn:handled?.id,status:handled?.status,receipt,outcome});save();
     if(options.afterAutomaticTurn&&await options.afterAutomaticTurn({handled,receipt,outcome,evidence})===false)break;
    }else await pause(1000);
   }
  }
 }catch(error){if(!closing)fail(error);}finally{
  await stop();
  if(options.installSignalHandlers!==false){process.removeListener('SIGINT',onSigint);process.removeListener('SIGTERM',onSigterm);}
 }
 if(terminal)throw terminal;
 return evidence;
}
