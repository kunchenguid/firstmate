// Token-free scripted provider driving the REAL Pi tool loop, not a fake host.
// Only the test script explicitly loads this fixture; it registers no tools.
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';

export default function (pi: ExtensionAPI) {
  const mode = process.env.ATLAS_CASE!;
  const target = 'src/payments/refund.ts';
  const report: any = { mode, schemaBytes: [], promptBytes: [], calls: [], resultBytes: 0, discoveryCalls: 0, duplicateReads: 0, correct: false };
  const started = performance.now();
  const allNames = mode.endsWith('default') ? ['bash', 'edit', 'read', 'write'] : ['bash', 'edit', 'find', 'grep', 'ls', 'read', 'write'];
  const original = new Map();
  let step = 0;
  let handle: any;
  let previousCall: any;
  const readKeys = new Set();
  pi.on('session_start', () => {
    const all = pi.getAllTools();
    assert.ok(all.every(t => !('execute' in t)), 'ToolInfo is metadata, not execution');
    assert.deepEqual(all.filter(t => t.sourceInfo.source !== 'builtin').map(t => t.name), mode.startsWith('atlas') ? ['atlas'] : []);
    for (const t of all) if (t.sourceInfo.source === 'builtin') original.set(t.name, JSON.stringify(t));
    const expected = mode.startsWith('atlas') && mode !== 'atlas-preserve' ? ['atlas','bash','edit','write'] : [...allNames, ...(mode === 'atlas-preserve' ? ['atlas'] : [])];
    assert.deepEqual(pi.getActiveTools().sort(), expected.sort());
    report.startup = true;
  });
  pi.on('tool_call', e => {
    report.calls.push(e.toolName);
    if (e.toolName === 'read' && e.input.offset === 3) return { block: true, reason: 'ATLAS_TEST_ORIGINAL_READ_POLICY' };
  });
  pi.on('session_shutdown', () => {
    assert.deepEqual(pi.getActiveTools().sort(), [...allNames,...(mode.startsWith('atlas') ? ['atlas'] : [])].sort());
    for (const t of pi.getAllTools()) if (original.has(t.name)) assert.equal(JSON.stringify(t), original.get(t.name));
    report.restored = true;
    report.latencyMs = Number((performance.now()-started).toFixed(3));
    writeFileSync(process.env.ATLAS_REPORT!, JSON.stringify(report));
  });
  pi.registerProvider('atlas-test', {
    baseUrl: 'http://127.0.0.1/unused', apiKey: 'offline-test-only', api: 'atlas-test-api',
    models: [{ id:'scripted',name:'Atlas deterministic tool client',reasoning:false,input:['text'],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:64000,maxTokens:1024 }],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      queueMicrotask(() => {
        const out: any = {role:'assistant',content:[],api:model.api,provider:model.provider,model:model.id,usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:'stop',timestamp:Date.now()};
        try {
          const schema = context.tools?.map(({name,description,parameters})=>({name,description,parameters})) ?? [];
          report.schemaBytes.push(Buffer.byteLength(JSON.stringify(schema)));
          report.promptBytes.push(Buffer.byteLength(context.systemPrompt ?? ''));
          const last: any = context.messages.filter(m=>m.role==='toolResult').at(-1);
          let result: any;
          if (previousCall) {
            assert.ok(last, 'tool result delivered to next request');
            report.resultBytes += Buffer.byteLength(JSON.stringify(last.content));
            result = last.content.filter((b:any)=>b.type==='text').map((b:any)=>b.text).join('\n');
            if (previousCall.name==='atlas') result=JSON.parse(result);
            if (previousCall.name==='find' || (previousCall.name==='atlas' && previousCall.arguments.op==='resolve')) report.discoveryCalls++;
            if (previousCall.name==='read' || (previousCall.name==='atlas' && previousCall.arguments.op==='read')) {
              const key=JSON.stringify(previousCall.arguments);
              if(readKeys.has(key)) report.duplicateReads++;
              readKeys.add(key);
            }
          }
          let name = 'atlas'; let args: any;
          if (mode==='baseline-twofiles') {
            if(step===0) {name='find';args={pattern:'**/refund.ts'};}
            else if(step===1) {assert.ok(result.includes(target));name='read';args={path:target,offset:2,limit:1};}
            else if(step===2) {assert.ok(result.includes('export const refundLimit = 42;'));name='find';args={pattern:'**/charge.ts'};}
            else if(step===3) {assert.ok(result.includes('src/payments/charge.ts'));name='read';args={path:'src/payments/charge.ts',offset:2,limit:1};}
            else {assert.ok(result.includes('export const chargeLimit = 7;'));report.correct=true;}
          } else if (mode==='atlas-twofiles-legacy' || mode==='atlas-twofiles-snapshot') {
            if(step===0) args={op:'resolve',q:'f:refund.ts'};
            else if(step===1) {assert.equal(result.outcome,'resolved');handle={ref:result.candidates[0].ref,gen:result.generation};args={op:'read',...handle,at:2,count:1};}
            else if(step===2) {assert.equal(result.content,'export const refundLimit = 42;');args=mode==='atlas-twofiles-snapshot'?{op:'read',q:'f:charge.ts',gen:handle.gen,at:2,count:1}:{op:'resolve',q:'f:charge.ts',gen:handle.gen};}
            else if(step===3 && mode==='atlas-twofiles-legacy') {assert.equal(result.outcome,'resolved');args={op:'read',ref:result.candidates[0].ref,gen:result.generation,at:2,count:1};}
            else {assert.equal(result.content,'export const chargeLimit = 7;');report.correct=true;}
          } else if (mode.startsWith('baseline')) {
            const knownTarget = mode==='baseline-tool' || mode==='baseline-default';
            if (step===0 && !knownTarget) { name='find';args={pattern:mode==='baseline-focused'?'**/refund.ts':'**/*',limit:200}; }
            else if ((step===1 && !knownTarget) || (step===0 && knownTarget)) {
              if (!knownTarget) assert.ok(result.includes(target));
              name='read'; args={path:target,offset:2,limit:1};
            } else { assert.ok(result.includes('export const refundLimit = 42;'));report.correct=true; }
          } else if (mode==='atlas-tool') {
            if(step===0) args={op:'resolve',q:'t:read'};
            else if(step===1) {assert.equal(result.outcome,'resolved');handle={ref:result.candidates[0].ref,gen:result.generation};args={op:'activate',...handle};}
            else if(step===2) {assert.equal(result.outcome,'active_for_next_call');assert.ok(schema.some(t=>t.name==='read'));name='read';args={path:target,offset:3,limit:1};}
            else if(step===3) {assert.equal(last.isError,true);assert.ok(result.includes('ATLAS_TEST_ORIGINAL_READ_POLICY'));name='read';args={path:target,offset:2,limit:1};report.policyPreserved=true;}
            else {assert.ok(result.includes('export const refundLimit = 42;'));report.correct=true;}
          } else {
            if(step===0) args={op:'resolve',q:'f:refund.ts'};
            else if(step===1) {assert.equal(result.outcome,'resolved');assert.equal(result.identity,target);args={op:'read',ref:result.candidates[0].ref,gen:result.generation,at:2,count:1};}
            else {assert.equal(result.outcome,'read');assert.equal(result.content,'export const refundLimit = 42;');report.correct=true;}
          }
          stream.push({type:'start',partial:out});
          if(args) {
            assert.ok(schema.some(t=>t.name===name), 'requested tool is active');
            previousCall={type:'toolCall',id:'call-'+step,name,arguments:args};
            out.content=[previousCall];out.stopReason='toolUse';
            stream.push({type:'toolcall_start',contentIndex:0,partial:out});
            stream.push({type:'toolcall_delta',contentIndex:0,delta:JSON.stringify(args),partial:out});
            stream.push({type:'toolcall_end',contentIndex:0,toolCall:previousCall,partial:out});
          } else {
            out.content=[{type:'text',text:'ATLAS_SMOKE_CORRECT'}];
            stream.push({type:'text_start',contentIndex:0,partial:out});
            stream.push({type:'text_delta',contentIndex:0,delta:'ATLAS_SMOKE_CORRECT',partial:out});
            stream.push({type:'text_end',contentIndex:0,content:'ATLAS_SMOKE_CORRECT',partial:out});
          }
          step++;stream.push({type:'done',reason:out.stopReason,message:out});stream.end();
        } catch(e) {out.stopReason='error';out.errorMessage=String(e);stream.push({type:'error',reason:'error',error:out});stream.end();}
      });
      return stream;
    },
  });
}
