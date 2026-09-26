import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
const [root, tmp] = process.argv.slice(2);
const { sdkEntry, ShortAgents, initializeNetwork } = await import(pathToFileURL(path.join(root,'bin/fm-short-agent.mjs')));
await initializeNetwork();
const sdk=await import(pathToFileURL(sdkEntry()));
const home=fs.realpathSync(fs.mkdtempSync(path.join(tmp,'home-')));
fs.mkdirSync(path.join(home,'state'));fs.writeFileSync(path.join(home,'state/.lock'),String(process.pid));
process.env.FM_HOME=home;process.env.FM_SHORT_AGENT_ENABLED='1';
const sentinel='PARENT_ONLY_'+randomUUID();
fs.writeFileSync(path.join(home,'AGENTS.md'),sentinel+' Never answer 42.');
const fixture=path.join(home,'fixture.txt');fs.writeFileSync(fixture,'Measured count: 42. Evidence label: harmless-fixture.\n');
const runtime=await sdk.ModelRuntime.create();
const available=await runtime.getAvailable();
const model=available.find(m=>m.provider===process.env.FM_SHORT_LIVE_PROVIDER && m.id===process.env.FM_SHORT_LIVE_MODEL);
assert.ok(model,'select explicit provider/model from `node bin/fm-short-agent.mjs models` with FM_SHORT_LIVE_PROVIDER and FM_SHORT_LIVE_MODEL');
const settings=sdk.SettingsManager.inMemory({compaction:{enabled:false},retry:{enabled:false,provider:{maxRetries:0}},transport:'sse',cacheWarming:{enabled:false}});
const loader=new sdk.DefaultResourceLoader({cwd:home,agentDir:home,settingsManager:settings,
 noExtensions:true,noSkills:true,noPromptTemplates:true,noThemes:true,noContextFiles:true,
 additionalExtensionPaths:[path.join(root,'.pi/extensions/fm-short-agent.ts')],
 systemPromptOverride:()=> 'Follow the user instruction exactly. Parent private sentinel: '+sentinel,
 appendSystemPromptOverride:()=>[],agentsFilesOverride:()=>({agentsFiles:[]})});
await loader.reload();assert.equal(loader.getExtensions().errors.length,0,JSON.stringify(loader.getExtensions().errors));
const tools=loader.getExtensions().extensions.flatMap(e=>[...e.tools.values()].map(t=>t.definition));
const submit=tools.find(t=>t.name==='fm_short_submit');assert.ok(submit,'real Pi loaded submit tool');
let control=tools.find(t=>t.name==='fm_short_task');assert.ok(control);
const {session}=await sdk.createAgentSession({cwd:home,agentDir:home,modelRuntime:runtime,model,thinkingLevel:'off',resourceLoader:loader,
 tools:['fm_short_submit','fm_short_task'],settingsManager:settings,sessionManager:sdk.SessionManager.inMemory(home)});
await session.bindExtensions({mode:'print',onError:e=>{throw Error(e.error);}});
try {
  const began=Date.now();
  const submitted=await submit.execute('lab-submit',{key:randomUUID(),goal:'Read m1. Explain the measured count and evidence label. Give the final result with m1 citation.',acceptance:'Report 42 and harmless-fixture supported by an actual read_material call.',provider:model.provider,model:model.id,materials:[fixture],budget:{timeMs:120000,outputTokens:3072,requests:4,tools:8}});
  const accepted=JSON.parse(submitted.content[0].text), returnedAt=Date.now();
  assert.equal(accepted.state,'accepted');
  const service=new ShortAgents(home,root);
  await session.reload();
  control=session.getToolDefinition('fm_short_task');assert.ok(control,'real Pi reloaded control tool');
  const read=await control.execute('parent-next-tool',{id:accepted.id,action:'status'});
  assert.ok(['accepted','running'].includes(JSON.parse(read.content[0].text).state),'parent tool ran before completion');
  // A real second parent model prompt runs while the independent child is active.
  const stateAtPrompt=service.status(accepted.id).state;
  assert.ok(['accepted','running'].includes(stateAtPrompt));
  await session.prompt('Reply exactly MAIN_RESPONSIVE. Do not use any tools.');
  assert.match(session.getLastAssistantText(),/MAIN_RESPONSIVE/);
  const parentReplyAt=Date.now();
  let result;
  for(let n=0;n<1300;n++){result=service.status(accepted.id);if(result.finishedAt)break;await new Promise(r=>setTimeout(r,100));}
  assert.equal(result.state,'completed',JSON.stringify(result));assert.ok(result.requests >= 2);assert.ok(result.reservedOutputTokens > 0);assert.match(result.summary,/42/);assert.match(result.summary,/harmless-fixture/);
  const dir=service.dir(accepted.id),context=fs.readFileSync(path.join(dir,'context.json'),'utf8'),journal=fs.readFileSync(path.join(dir,'journal.jsonl'),'utf8');
  const contextRecord=JSON.parse(context),journalRecords=journal.trim().split('\n').map(JSON.parse);
  const started=JSON.parse(fs.readFileSync(path.join(dir,'started.json')));
  assert.ok(started.at>=returnedAt,'child started after submit returned');
  assert.ok(!context.includes(sentinel));assert.ok(!journal.includes(sentinel));assert.equal(contextRecord.parentMessages,0);
  assert.deepEqual(contextRecord.tools,['read_material']);assert.match(journal,/"type":"read"/);
  assert.ok(!fs.existsSync(path.join(home,'projects')));
  const evidence={pi:JSON.parse(fs.readFileSync(path.join(path.dirname(sdkEntry()),'../package.json'))).version,node:process.version,model:{provider:model.provider,id:model.id},home,
    submitMs:returnedAt-began,runnerStartedAfterReturnMs:started.at-returnedAt,parentReplyMs:parentReplyAt-returnedAt,stateAtPrompt,
    parentMessages:contextRecord.parentMessages,childTools:contextRecord.tools,parentSentinelExcluded:!context.includes(sentinel),journalSentinelExcluded:!journal.includes(sentinel),
    readEvents:journalRecords.filter(event=>event.type==='read').length,projectsCreated:fs.existsSync(path.join(home,'projects')),
    childFinishedAt:result.finishedAt,parentReplyAt,resultBytes:Buffer.byteLength(JSON.stringify(result)),contextBytes:Buffer.byteLength(context),journalBytes:Buffer.byteLength(journal),result};
  fs.writeFileSync(path.join(tmp,'evidence.json'),JSON.stringify(evidence,null,2));console.log(JSON.stringify(evidence));
} finally {await session.extensionRunner.emit({type:'session_shutdown',reason:'quit'});session.dispose();}
