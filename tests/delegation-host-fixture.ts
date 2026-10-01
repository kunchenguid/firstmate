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
   if (branch && context.messages.at(-1)?.role !== 'toolResult') {
    const message=context.messages.findLast(m=>JSON.stringify(m.content).includes('FIRSTMATE TASK CONTINUATION:'));
    const text=typeof message?.content==='string'?message.content:message?.content?.filter(x=>x.type==='text').map(x=>x.text).join('')||'';
    const admitted=JSON.parse(text.slice(text.lastIndexOf('\n{')+1));
    if(admitted.assessment?.remaining_gap!=='Inspect the prepared current-session readback, then preserve final semantic acceptance for MAIN.'||admitted.next_action?.kind!=='readback'||admitted.next_action?.payload_ref!=='data/readback-action.md')throw Error('branch admission omitted current lifecycle context');
    const evidence=[...new Set([admitted.assessment.authority_ref,...admitted.assessment.evidence.map(item=>item.ref),admitted.next_action.payload_ref])];
    output.stopReason='toolUse';output.content.push({type:'toolCall',id:'check-'+Date.now(),name:'fm_task_continuation',arguments:{action:'inspect',task:'routine',evidence}});log({event:'tool',branch,name:'fm_task_continuation',action:'inspect',evidence});
   } else if (!branch && last.includes('Live task continuation obligations') && context.messages.at(-1)?.role !== 'toolResult') {
    output.stopReason='toolUse';output.content.push({type:'toolCall',id:'check-'+Date.now(),name:'bash',arguments:{command:`python3 '${root}/tests/delegation-host-precheck.py' --main`,timeout:20}});log({event:'tool',branch,name:'bash'});
   } else if (branch && context.messages.at(-1)?.toolName === 'fm_task_continuation') {
    output.stopReason='toolUse'; output.content.push({type:'toolCall',id:'report-'+Date.now(),name:'fm_branch_report',arguments:{task:'routine',verdict:'routine',summary:'Current prepared readback inspected; final semantic acceptance remains MAIN-owned.'}});log({event:'tool',branch,name:'fm_branch_report'});
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
   writeFileSync(home+'/data/routine-policy-authority.md','Standing routine continuation authority for this isolated fixture.\n');
   writeFileSync(home+'/data/historical-report.md','Rollout is inactive pending landing, reload and policy enablement.\n');
   writeFileSync(home+'/data/current-readback.md','Rollout is enabled after reload and the exact task grant is active.\n');
   writeFileSync(home+'/data/readback-action.md','Inspect data/current-readback.md and retain final semantic acceptance for MAIN.\n');
   const policy={schema:'fm-task-continuation-policy.v1',revision:0,issuer:'main',enabled:true,authority_ref:'data/routine-policy-authority.md',authority_sha256:createHash('sha256').update(readFileSync(home+'/data/routine-policy-authority.md')).digest('hex'),allowed:['inspect','precheck','steer-same-intent','observe-receipt'],expires_at:'2099-01-01T00:00:00Z'};
   writeFileSync(home+'/data/policy.json',JSON.stringify(policy),{mode:0o600});run('continuation-policy','--expected-revision','0','--record',home+'/data/policy.json');
   run('refresh',task);
   const inspected=run('inspect',task,'--evidence','data/'+task+'/brief.md','--evidence','data/current-readback.md','--evidence','data/readback-action.md');
   const judgment={disposition:'open',outcome:'Rollout enabled; current branch readback remains pending.',remaining_gap:'Inspect the prepared current-session readback, then preserve final semantic acceptance for MAIN.',authority_ref:'data/'+task+'/brief.md',evidence:['data/'+task+'/brief.md','data/current-readback.md'],next_action:{kind:'readback',payload_ref:'data/readback-action.md',recheck_at:'2000-01-01T00:00:00Z',deadline:'2099-01-01T00:00:00Z',attempt_limit:2}};
   run('assess',task,'--basis',inspected.basis,'--judgment',JSON.stringify(judgment));
  }
  pi.sendMessage({customType:'fixture-seed',content:'Fixture seed for same input comparison',display:false},{triggerTurn:true});
 }});
 pi.registerCommand('fixture-question',{description:'Independent status query',handler(){log({event:'question'});pi.sendMessage({customType:'fixture-question',content:'Answer independent fixture question',display:false},{triggerTurn:true});}});
}
