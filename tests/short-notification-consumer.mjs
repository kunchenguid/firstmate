// Execute the Pi tool/event boundary against an updated public receipt owner.
// The stale module fixture represents a primary that loaded the previous owner
// before a home update; private diagnosis separately exercises actual history.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const [root,home,id,fixture]=process.argv.slice(2);
fs.mkdirSync(fixture+'/.pi/extensions/lib',{recursive:true});
fs.mkdirSync(fixture+'/bin');fs.mkdirSync(fixture+'/node_modules/typebox',{recursive:true});
fs.writeFileSync(fixture+'/node_modules/typebox/package.json',JSON.stringify({type:'module',exports:'./index.js'}));
fs.writeFileSync(fixture+'/node_modules/typebox/index.js','export const Type=Object.fromEntries(["Object","String","Integer","Optional","Array","Union","Literal"].map(n=>[n,(...args)=>({kind:n,args})]));');
fs.copyFileSync(root+'/.pi/extensions/fm-short-agent.ts',fixture+'/.pi/extensions/fm-short-agent.ts');
fs.copyFileSync(root+'/.pi/extensions/lib/fm-async-exec.ts',fixture+'/.pi/extensions/lib/fm-async-exec.ts');
fs.writeFileSync(fixture+'/bin/fm-short-agent.mjs','export class ShortAgents { status(){throw Error("malformed operation settlement");} async reconcile(){throw Error("malformed operation settlement");} }');
process.env.FM_HOME=home;process.env.FM_SHORT_AGENT_ENABLED='1';
const handlers=new Map(),tools=new Map(),messages=[];
let ready;
const waitReady=()=>new Promise((resolve,reject)=>{const deadline=setTimeout(()=>reject(Error('notification reconciliation did not return')),15000);ready=()=>{clearTimeout(deadline);resolve();};});
const pi={on:(event,fn)=>handlers.set(event,fn),registerTool:t=>tools.set(t.name,t),sendMessage:m=>messages.push(m),events:{emit:()=>ready?.()}};
const extension=(await import(pathToFileURL(fixture+'/.pi/extensions/fm-short-agent.ts'))).default;
extension(pi);
// Replace the installed owner while this extension stays loaded. Static ESM
// readers remain stale; the public executable reads the current receipt format.
fs.cpSync(root+'/bin',fixture+'/bin',{recursive:true});
const dir=home+'/state/short-agents/'+id;
const names=['request.json','result.json','operation-0.intent.json','operation-0.effect.json','operation-0.output.json','operation-0.receipt.json'];
const original=Object.fromEntries(names.map(n=>[n,fs.readFileSync(dir+'/'+n)]));
const control=tools.get('fm_short_task');assert(control);
const result=await control.execute('fixture',{id,action:'status'});
assert.equal(result.details.state,'blocked');assert.deepEqual(result.details.operations,[{index:0,action:'cleanup',state:'completed'}]);
const reconcileDone=waitReady();handlers.get('session_start')();
try{
 await reconcileDone;
 assert.deepEqual(messages,[],'current receipt is accepted without a stale-parser error');
 assert(fs.existsSync(dir+'/notified.json'));
 const outcome=fs.readFileSync(home+'/state/branch-outcomes.jsonl','utf8').trim().split('\n').map(JSON.parse).filter(row=>row.task===id);
 assert.equal(outcome.length,1);assert.match(outcome[0].summary,/: blocked\./);assert(!outcome[0].summary.includes(': completed.'));
 const again=waitReady();await again;const rows=fs.readFileSync(home+'/state/branch-outcomes.jsonl','utf8').trim().split('\n').map(JSON.parse).filter(row=>row.task===id);assert.equal(rows.length,1,'notification is idempotent');
 const output=dir+'/operation-0.output.json';fs.appendFileSync(output,'changed\n');
 try{await assert.rejects(()=>control.execute('fixture',{id,action:'result'}),/original evidence changed/);}finally{fs.writeFileSync(output,original['operation-0.output.json']);}
 const proof=dir+'/operation-0.preservation.json',proofBytes=fs.readFileSync(proof),qfile=JSON.parse(proofBytes).judgment_ref,qbytes=fs.readFileSync(qfile);fs.appendFileSync(qfile,'changed\n');
 try{await assert.rejects(()=>control.execute('fixture',{id,action:'status'}),/judgment changed/);}finally{fs.writeFileSync(qfile,qbytes);}
 const receipt=dir+'/operation-0.receipt.json';fs.writeFileSync(receipt,JSON.stringify({...JSON.parse(original['operation-0.receipt.json']),nonce:'wrong'}));
 try{
  await assert.rejects(()=>control.execute('fixture',{id,action:'status'}),/malformed operation receipt/);
  const count=messages.length,tick=waitReady();await tick;assert.equal(messages.length,count+1);assert.equal(messages.at(-1).customType,'fm-short-agent-error');assert.match(messages.at(-1).content,/malformed operation receipt/);
  const repeat=waitReady();await repeat;assert.equal(messages.length,count+1,'same invalid evidence error is reported only once');
 }finally{fs.writeFileSync(receipt,original['operation-0.receipt.json']);}
 const lock=home+'/state/.lock',lockBytes=fs.readFileSync(lock);fs.writeFileSync(lock,'1');
 try{await assert.rejects(()=>control.execute('fixture',{id,action:'status'}),/owning primary/);}finally{fs.writeFileSync(lock,lockBytes);}
 for(const [name,bytes] of Object.entries(original))assert.deepEqual(fs.readFileSync(dir+'/'+name),bytes);
 console.log('PASS: resident Pi status/notification use current receipt owner; original blocked uncertainty preserved, single notification, changed failure/judgment/nonce and foreign primary refuse');
}finally{handlers.get('session_shutdown')();}

if(process.env.FM_SHORT_NOTIFICATION_PI_E2E==='1'){
 const {sdkEntry}=await import(pathToFileURL(root+'/bin/fm-short-agent.mjs'));
 const sdk=await import(pathToFileURL(sdkEntry()));
 const real=fixture+'-real-pi';fs.mkdirSync(real+'/.pi/extensions/lib',{recursive:true});fs.mkdirSync(real+'/bin');fs.mkdirSync(real+'/node_modules');fs.symlinkSync(path.resolve(path.dirname(sdkEntry()),'../node_modules/typebox'),real+'/node_modules/typebox');
 for(const name of ['fm-short-agent.ts','lib/fm-async-exec.ts'])fs.copyFileSync(root+'/.pi/extensions/'+name,real+'/.pi/extensions/'+name);
 // Real Pi resolves its extension dependencies. Only the old receipt owner is
 // doubled; the update and subsequent CLI read use the actual candidate.
 fs.writeFileSync(real+'/bin/fm-short-agent.mjs','export class ShortAgents { status(){throw Error("malformed operation settlement");} async reconcile(){throw Error("malformed operation settlement");} }');
 const settings=sdk.SettingsManager.inMemory({compaction:{enabled:false},cacheWarming:'off'});
 const loader=new sdk.DefaultResourceLoader({cwd:home,agentDir:home,settingsManager:settings,noExtensions:true,noSkills:true,noPromptTemplates:true,noThemes:true,noContextFiles:true,additionalExtensionPaths:[real+'/.pi/extensions/fm-short-agent.ts']});
 await loader.reload();assert.deepEqual(loader.getExtensions().errors,[]);
 const realControl=loader.getExtensions().extensions.flatMap(e=>[...e.tools.values()].map(t=>t.definition)).find(t=>t.name==='fm_short_task');assert(realControl);
 fs.cpSync(root+'/bin',real+'/bin',{recursive:true});
 const actual=await realControl.execute('real-fixture',{id,action:'result'});assert.equal(actual.details.state,'blocked');assert.deepEqual(actual.details.operations,[{index:0,action:'cleanup',state:'completed'}]);
 for(const [name,bytes] of Object.entries(original))assert.deepEqual(fs.readFileSync(dir+'/'+name),bytes);
 console.log('PASS real Pi '+JSON.parse(fs.readFileSync(path.resolve(path.dirname(sdkEntry()),'../package.json'))).version+': resident tool loads updated receipt owner without model calls or cleanup replay');
}
