#!/usr/bin/env bash
# Offline causal Pi lifecycle proof; never resolves real credentials or sends prompts.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FM_TRANSPORT_TEST_MODULE="$ROOT/.pi/extensions/lib/fm-transport-recovery.ts"
NODE_NO_WARNINGS=1 node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const { installTransportRecovery } = await import(process.env.FM_TRANSPORT_TEST_MODULE);
const tmp = mkdtempSync(join(tmpdir(), 'fm-transport-'));
let count = 0;
async function fixture(options = {}) {
  const config = join(tmp, String(count++));
  writeFileSync(config, JSON.stringify({mode:'muse-to-gemini', exactGeminiIdentityVerified:true, ...options.config}));
  const handlers = new Map(); const entries = []; const switches = [];
  const source = {provider:'cliproxyapi', id:'muse-spark-1.3'};
  const target = {provider:'antigravity', id:'gemini-3.8-flash'};
  const ctx = {model:source, scopedModels:[], signal:undefined, isIdle:()=>true, hasPendingMessages:()=>false,
    modelRegistry:{find:()=>options.unavailable ? undefined : target}, sessionManager:{getSessionId:()=> 'session-1'}};
  const emit = async (name, event = {}) => { for (const cb of handlers.get(name) ?? []) await cb(event, ctx); };
  const pi = {on:(name, cb)=>handlers.set(name,[...(handlers.get(name)??[]),cb]),
    appendEntry:(type,data)=>entries.push(data),
    setModel:()=>assert.fail('unguarded model switch'), sendUserMessage:()=>assert.fail('prompt replay'),
    setModelIfCurrent:async(model,guard)=>{
      switches.push(guard); assert.equal(guard.thinkingLevel,"high");
      if (options.duringAuth) await options.duringAuth({emit,ctx,guard});
      if (guard.signal.aborted || !guard.isCurrent() || ctx.model !== source || ctx.sessionManager.getSessionId() !== guard.expectedSessionId) return false;
      if (options.noAuth) return false;
      ctx.model=model; await emit('model_select',{model}); return true;
    }};
  if (options.oldPi) delete pi.setModelIfCurrent;
  installTransportRecovery(pi,config,()=>options.lock !== false);
  await emit('session_start'); await emit('before_agent_start');
  const fail = async (details={}, message={}) => emit('message_end',{message:{role:'assistant',provider:source.provider,model:source.id,
    stopReason:'error',content:[], diagnostics:[{type:'provider_transport_failure',error:{message:'SECRET'},details:{
      terminal:true,eventsEmitted:false,phase:'before_message_stream_start',requestBytes:100,...details}}],...message}});
  return {ctx,entries,switches,emit,fail};
}
try {
  const f=await fixture(); await f.fail(); await f.fail();
  assert.equal(f.switches.length,0,'wait for stock retries to settle');
  await f.emit('agent_settled'); await f.emit('agent_settled');
  assert.equal(f.switches.length,1); assert.equal(f.ctx.model.provider,'antigravity');
  assert.equal(f.entries.at(-1).result,'switched-for-next-stock-wake');
  const single=await fixture(); await single.fail(); await single.emit('agent_settled');
  assert.equal(single.switches.length,0); assert.equal(single.entries.at(-1).result,'sustained-failure-threshold-not-met');
  for (const details of [{eventsEmitted:true},{phase:'unknown'},{terminal:false},{terminal:undefined}]) {
    const f=await fixture(); await f.fail(details); await f.emit('agent_settled'); assert.equal(f.switches.length,0);
  }
  const partial=await fixture(); await partial.fail({eventsEmitted:true,phase:'after_message_stream_start'});
  await partial.fail(); await partial.fail(); await partial.emit('agent_settled');
  assert.equal(partial.switches.length,0,'a later pre-stream failure cannot erase earlier effects');
  const auth=await fixture(); await auth.fail(); await auth.fail(); await auth.fail({terminal:undefined},{errorMessage:'HTTP 429'});
  await auth.emit('agent_settled'); assert.equal(auth.switches.length,0,'earlier WS diagnostics cannot turn auth/quota errors into transport');
  for (const effect of ['tool_execution_start','message_update']) {
    const f=await fixture(); await f.emit(effect); await f.fail(); await f.fail(); await f.emit('agent_settled'); assert.equal(f.switches.length,0);
  }
  for (const message of [{stopReason:'aborted'},{stopReason:'stop'},{content:[{type:'text',text:'partial'}]},
    {diagnostics:[]},{provider:'other'}]) {
    const f=await fixture(); await f.fail({},message); await f.emit('agent_settled'); assert.equal(f.switches.length,0);
  }
  for (const options of [{oldPi:true},{unavailable:true},{lock:false},{config:{exactGeminiIdentityVerified:false}},
    {config:{mode:'diagnostics'}},{config:{mode:'disabled'}}]) {
    const f=await fixture(options); await f.fail(); await f.fail(); await f.emit('agent_settled'); assert.equal(f.switches.length,0);
    assert(!JSON.stringify(f.entries).includes('SECRET'));
  }
  const pinned=await fixture(); pinned.ctx.scopedModels=[{model:pinned.ctx.model}];
  await pinned.fail(); await pinned.fail(); await pinned.emit('agent_settled'); assert.equal(pinned.switches.length,0);
  for (const event of ['input','session_shutdown','session_start','model_select']) {
    const f=await fixture({duringAuth:({emit})=>emit(event)}); await f.fail(); await f.fail(); await f.emit('agent_settled');
    assert.equal(f.ctx.model.provider,'cliproxyapi'); assert.equal(f.switches.length,1);
  }
  const aborted=await fixture(); aborted.ctx.signal=AbortSignal.abort(); await aborted.fail();
  await aborted.emit('agent_settled'); assert.equal(aborted.switches.length,0);
  const noAuth=await fixture({noAuth:true}); await noAuth.fail(); await noAuth.fail(); await noAuth.emit('agent_settled');
  await noAuth.emit('before_agent_start'); await noAuth.fail(); await noAuth.fail(); await noAuth.emit('agent_settled');
  assert.equal(noAuth.switches.length,1,'failed auth consumes bounded switch budget');
  let finishAuth;
  const hung=await fixture({duringAuth:()=>new Promise(resolve=>{finishAuth=resolve;})});
  await hung.fail(); await hung.fail(); await hung.emit('agent_settled');
  assert.equal(hung.entries.at(-1).result,'switch-timeout');
  assert.equal(hung.switches[0].signal.aborted,true);
  finishAuth(); await new Promise(resolve=>setImmediate(resolve));
  assert.equal(hung.ctx.model.provider,'cliproxyapi','late auth cannot mutate after timeout');
  const bounded=await fixture({config:{mode:'diagnostics'}});
  for(let i=0;i<100;i++){await bounded.emit('before_agent_start');await bounded.fail();await bounded.fail();await bounded.emit('agent_settled');}
  assert.equal(bounded.entries.length,32,'bounded metadata entries');
  console.log('ok - bounded transport lifecycle, retry settlement, effects, auth, model scope, generation and privacy fences');
} finally { rmSync(tmp,{recursive:true,force:true}); }
JS
