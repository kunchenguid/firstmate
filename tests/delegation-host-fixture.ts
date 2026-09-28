// Deterministic offline provider in a real Pi host; no external transport.
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { appendFileSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
export default function(pi) {
 const home=process.env.FM_HOME,root=process.env.FM_ROOT_OVERRIDE,log=x=>appendFileSync(home+'/events.jsonl',JSON.stringify({at:Date.now(),...x})+'\n');
 pi.registerProvider('delegation-local',{baseUrl:'http://127.0.0.1/unused',apiKey:'offline-fixture',api:'delegation-local-api',models:[{id:'deterministic',name:'deterministic',reasoning:false,input:['text'],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:100000,maxTokens:256}],streamSimple(model,context){
  const branch=context.messages.some(m=>JSON.stringify(m.content).includes('FIRSTMATE TASK CONTINUATION:'));const last=JSON.stringify(context.messages.at(-1)?.content||'');
  log({event:'provider',branch,last:last.slice(0,1500)});
  const stream=createAssistantMessageEventStream();const output={role:'assistant',content:[],api:model.api,provider:model.provider,model:model.id,usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:'stop',timestamp:Date.now()};
  setTimeout(()=>{
   if ((branch || last.includes('Live task continuation obligations')) && context.messages.at(-1)?.role !== 'toolResult') {
    output.stopReason='toolUse';output.content.push({type:'toolCall',id:'check-'+Date.now(),name:'bash',arguments:{command:`python3 '${root}/tests/delegation-host-precheck.py' ${branch?'':'--main'}`,timeout:20}});log({event:'tool',branch,name:'bash'});
   } else if (branch && context.messages.at(-1)?.toolName === 'bash') {
    output.stopReason='toolUse'; output.content.push({type:'toolCall',id:'report-'+Date.now(),name:'fm_branch_report',arguments:{task:'routine',verdict:'routine',summary:'Bounded preliminary progress checked; final acceptance remains MAIN-owned.'}});log({event:'tool',branch,name:'fm_branch_report'});
   }
   else output.content.push({type:'text',text:'fixture complete'});
   stream.push({type:'done',reason:output.stopReason,message:output});stream.end();
  },branch?1500:5);return stream;
 }});
 pi.on('project_trust',()=>({trusted:'yes',remember:false}));
 pi.on('session_start',()=>{writeFileSync(home+'/state/.lock',process.pid+'\n');log({event:'ready'});});
 pi.registerCommand('fixture-start',{description:'Seed isolated comparison',handler(){
  const task='routine';mkdirSync(home+'/data/'+task,{recursive:true});writeFileSync(home+'/data/'+task+'/brief.md','Inspect progress and retain final acceptance for MAIN.\n');writeFileSync(home+'/state/'+task+'.meta','spawn_gen=g1\nkind=scout\nexecutor=local-agent\n');
  function run(...args){const p=spawnSync('bash',[root+'/bin/fm-task-state.sh',...args],{encoding:'utf8'});if(p.status!==0)throw Error(p.stderr);return JSON.parse(p.stdout);}
  const r=run('enroll',task);
  if(process.env.FM_HOST_VARIANT==='after'){
   r.schema='fm-task-lifecycle.v2';r.precheck=null;r.delegation={revision:1,issuer:'main',authority_ref:'data/routine/brief.md',authority_sha256:createHash('sha256').update(readFileSync(home+'/data/routine/brief.md')).digest('hex'),allowed:['inspect','precheck','observe-receipt'],edges:[],expires_at:'2099-01-01T00:00:00Z',revoked:false};
   writeFileSync(home+'/data/proposal.json',JSON.stringify(r),{mode:0o600});run('reconcile',task,'--expected-revision',String(r.revision),'--record',home+'/data/proposal.json');
  }
  pi.sendMessage({customType:'fixture-seed',content:'Fixture seed for same input comparison',display:false},{triggerTurn:true});
 }});
 pi.registerCommand('fixture-question',{description:'Independent status query',handler(){log({event:'question'});pi.sendMessage({customType:'fixture-question',content:'Answer independent fixture question',display:false},{triggerTurn:true});}});
}
