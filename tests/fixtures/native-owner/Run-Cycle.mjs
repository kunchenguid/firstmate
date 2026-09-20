import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {randomUUID,createHash} from 'node:crypto';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../..');
const dir=path.join(repo,'data/native-candidate-validation');
const read=file=>JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));
const posix=value=>value.replaceAll('\\','/').replace(/^([A-Za-z]):/,(_,drive)=>'/'+drive.toLowerCase());
const build=read(path.join(dir,'build.json'));
const dry=process.argv.includes('--dry');
const startupQueued=process.argv.includes('--startup-queued');
const fault=process.argv.find(value=>value.startsWith('--fault='))?.slice(8);
if(fault&&(!dry||!['partial','complete','zero-missing','zero-malformed','zero-mismatched','zero-unproven'].includes(fault)))throw Error('Fault cases require --dry and a registered fault mode');
if(startupQueued&&!dry)throw Error('Queued-startup case requires model-free mode');
if(!dry&&process.env.FM_LIVE_NATIVE_CODEX!=='1')throw Error('Live model test requires FM_LIVE_NATIVE_CODEX=1');
if(!dry){const preflight=read(path.join(dir,'bridge-preflight.json'));if(!preflight.passed||preflight.binaryHash!==createHash('sha256').update(fs.readFileSync(build.binary)).digest('hex'))throw Error('Run model-free bridge preflight for this binary first');}
const home=path.join(build.root,'appserver-'+randomUUID());fs.mkdirSync(home);
fs.writeFileSync(path.join(home,'build.json'),JSON.stringify(build,null,2));
const script=path.join(build.code,'AppHost.mjs');
const leaseHome=path.join(home,'home');
let startupNote=null;
if(startupQueued){
 fs.mkdirSync(leaseHome);
 const env={...process.env,FM_HOME:posix(leaseHome),MSYS:'winsymlinks:nativestrict'};
 const queued=spawnSync('C:/Program Files/Git/bin/bash.exe',['--noprofile','--norc',posix(path.join(build.root,'firstmate/bin/fm-inbox.sh')),'note','Queued before native startup readiness; preserve and deliver this exact note.'],{env,encoding:'utf8',timeout:30000});
 if(queued.status!==0)throw Error('Could not queue the pre-startup note: '+queued.stderr);
 startupNote=queued.stdout.trim().split(/\s+/)[1];
 if(!startupNote)throw Error('Pre-startup note ID was not returned');
}
const spec={home,leaseHome,executable:process.execPath,arguments:'"'+script+'"',registeredHarness:'codex-app-server',timeoutSeconds:280,ownerExercise:true,ownerOperation:true,pipeAcl:'LogonData',apiDry:dry,jqImage:process.env.FM_NATIVE_TEST_JQ_IMAGE};
if(startupQueued){spec.startupQueued=true;spec.startupNote=startupNote;}
if(fault)spec.ackFault=fault;
const file=path.join(home,'spec.json');fs.writeFileSync(file,JSON.stringify(spec,null,2));
const run=spawnSync(build.binary,['run',file],{env:process.env,encoding:'utf8',timeout:310000});
fs.writeFileSync(path.join(home,'controller.stdout'),run.stdout||'');fs.writeFileSync(path.join(home,'controller.stderr'),run.stderr||'');
fs.writeFileSync(path.join(dir,fault?`fault-${fault}-latest.json`:dry?'bridge-latest.json':'cycle-latest.json'),JSON.stringify({home,exit:run.status},null,2));
console.log(JSON.stringify({home,exit:run.status,dry}));
if(run.status!==0)throw Error('Bounded app-server run failed; inspect evidence, do not start another model attempt');
const host=read(path.join(home,'app-host-evidence.json')),native=read(path.join(home,'result.json'));
if(!host.shutdown?.stopped||!host.shutdown.operationsStopped||!host.shutdown.exited)throw Error('Host shutdown was not confirmed');
const starts=action=>host.native.filter(row=>row.action===action&&row.state==='pending').length;
if(!host.passed||host.ordinaryToolRefusal?.restricted!==true||host.ordinaryToolRefusal?.association!=='associated'||host.ordinaryToolRefusal?.hostClassification!=='unclassified-descendant'||host.ordinaryToolRefusal?.protectedEffects!==false||host.ordinaryToolRefusal?.registeredPrimaryState!=='quiet'||starts('check')!==1||starts('ack')!==1||native.notificationConsumed!==!fault)throw Error('Notification cycle or ordinary-tool authority refusal incomplete');
if(!host.native.filter(row=>(row.action==='check'||row.action==='ack')&&row.state==='pending').every(row=>row.startupExpired))throw Error('Startup scope still active');
if(startupQueued){
 const delivered=read(path.join(home,'notification-check.json'));
 if(host.startupQueued?.status!=='starting'||host.startupQueued?.unavailable!=='busy'||!host.startupQueued?.preserved||host.startupQueued.note!==startupNote)throw Error('Queued-startup unavailable response was not demonstrated');
 if(delivered.note!==startupNote||!fs.existsSync(path.join(leaseHome,'state/inbox/handled',startupNote+'.note')))throw Error('Pre-startup note was not normally delivered and acknowledged');
}
if(fault) {
 const queue=path.join(spec.leaseHome,'state/.wake-queue'),before=fs.readFileSync(queue);
 const journal=()=>fs.readFileSync(path.join(spec.leaseHome,'owner-receipts.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
 const historyBefore=journal();
 if(historyBefore.at(-1).event!=='ack-started'||!native.receiptNeedsReconciliation)throw Error('Unresolved acknowledgement intent was not preserved');
 if(!host.shutdown.reconciliationRequired||!run.stderr.includes('Acknowledgement completion is unconfirmed. Its records are preserved and require reconciliation:'))throw Error('Shutdown did not surface the preserved reconciliation requirement');
 if(fault.startsWith('zero-')&&!host.native.some(row=>row.action==='result'&&row.state==='reconciliation-required'&&row.operationExit===0))throw Error('The zero-exit completion refusal was not observed through the native controller');
 if((before.length===0)!==(fault==='complete'))throw Error('Fault did not land at the requested mutation boundary');
 const recovery=path.join(home,'recovery');fs.mkdirSync(recovery);
 const recoverySpec={home:recovery,leaseHome:spec.leaseHome,executable:build.binary,arguments:'sleep 100',timeoutSeconds:10,pipeAcl:'UserOnly'};
 const recoveryFile=path.join(recovery,'spec.json');fs.writeFileSync(recoveryFile,JSON.stringify(recoverySpec));
 const restarted=spawnSync(build.binary,['run',recoveryFile],{env:process.env,encoding:'utf8',timeout:15000});
 fs.writeFileSync(path.join(recovery,'controller.stdout'),restarted.stdout||'');fs.writeFileSync(path.join(recovery,'controller.stderr'),restarted.stderr||'');
 if(restarted.status!==0)throw Error('Recovery controller failed');
 const recovered=read(path.join(recovery,'result.json'));
 if(recovered.recoveredAcknowledgements!==(fault==='complete'?1:0)||recovered.receiptNeedsReconciliation!==(fault==='partial'))throw Error('Incorrect interrupted acknowledgement recovery');
 if(!fs.readFileSync(queue).equals(before))throw Error('Recovery replayed a wake mutation');
 const history=journal();
 if(history.length!==historyBefore.length+(fault==='complete'?1:0))throw Error('Recovery started or recorded an unexpected acknowledgement');
 if(fault==='complete'&&(history.at(-1).event!=='recovered-acknowledged'||history.at(-1).ackGeneration!==native.probeGeneration||history.at(-1).generation!==recovered.probeGeneration))throw Error('Recovery generations are not bound');
 console.log(`PASS: actual ${fault} acknowledgement fault; recovery ${fault==='complete'?'confirmed completed effects without replay':'preserved the unresolved mutation'}.`);
 process.exit(0);
}
if(fs.existsSync(path.join(spec.leaseHome,'state/.wake-queue'))&&fs.readFileSync(path.join(spec.leaseHome,'state/.wake-queue'),'utf8').trim())throw Error('Queue was not acknowledged');
if(dry)fs.writeFileSync(path.join(dir,'bridge-preflight.json'),JSON.stringify({passed:true,home,binaryHash:createHash('sha256').update(fs.readFileSync(build.binary)).digest('hex')},null,2));
console.log(startupQueued?'PASS: queued notification stayed unavailable and preserved until startup, then delivered normally.':dry?'PASS: model-free registered operation bridge.':'PASS: real app-server notification cycle, handling, acknowledgement, replay refusal, and foreign-thread denial.');
