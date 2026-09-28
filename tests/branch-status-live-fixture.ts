// Real Pi extension/runtime probe. Only provider transport and wake production
// are synthetic; branch admission, grant, prompt, report and TUI are real.
import { writeFileSync, readFileSync, existsSync, unlinkSync, appendFileSync } from 'node:fs';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { createBranchDispatchOffer, scopeForUnreadWake, dispositionForWakeTrigger,
  appendBranchRoutingTrace, BRANCH_HEALTH_EVENT, BRANCH_HEALTH_REQUEST } from './.pi/extensions/lib/fm-branch-dispatch.ts';
export default function lab(pi: ExtensionAPI) {
  const state = process.env.FM_STATE_OVERRIDE!;
  let calls = 0;
  let released = false;
  let delay: (() => void) | undefined;
  const log = (value: unknown) => appendFileSync(`${state}/probe.jsonl`, JSON.stringify(value)+'\n');
  const health = () => pi.events.emit(BRANCH_HEALTH_REQUEST, {});
  globalThis.fetch = async (input, init) => {
    const url = String(input instanceof Request ? input.url : input);
    if (!url.startsWith('https://branch-status.invalid/')) throw Error('unexpected network request');
    calls++;
    if(readFileSync(`${state}/.branch-eligible-rows`,'utf8') !== '1\n' || readFileSync(`${state}/.main-eligible-rows`,'utf8') !== '0\n') throw Error('mixed grant does not preserve exact MAIN rows');
    if (calls === 1 && !released) await new Promise<void>(resolve => { delay = resolve; });
    const body = JSON.parse(String(init?.body));
    const reported = body.messages.some((m: any) => m.role === 'tool');
    const delta = reported ? {content:'Synthetic branch finished'} : {tool_calls:[{index:0,id:'report-1',type:'function',function:{name:'fm_branch_report',arguments:JSON.stringify({task:'probe',verdict:'routine',summary:'synthetic result',silent:false})}}]};
    const data = [{id:'lab',object:'chat.completion.chunk',created:1,model:'lab',choices:[{index:0,delta,finish_reason:null}]},
      {id:'lab',object:'chat.completion.chunk',created:1,model:'lab',choices:[{index:0,delta:{},finish_reason:reported?'stop':'tool_calls'}]}];
    return new Response(data.map(x=>'data: '+JSON.stringify(x)+'\n\n').join('')+'data: [DONE]\n\n', {headers:{'content-type':'text/event-stream'}});
  };
  pi.on('session_start', () => {
    writeFileSync(`${state}/.lock`,`${process.pid}\n`);
    writeFileSync(`${state}/probe.meta`,`project=synthetic\nwindow=fm-probe\n`);
    writeFileSync(`${state}/.wake-queue`,'');
    log({event:'session',pid:process.pid});
  });
  const dispatch = (token: string) => {
    const scope = scopeForUnreadWake(state,false);
    const offer = createBranchDispatchOffer('signal: probe.status',[],false,scope.eligible,[],token,scope.eligibleSeqs,scope.eligibleTasks,scope.taskBySeq);
    pi.events.emit('fm-branch-supervision:dispatch',offer);
    if(!offer.accepted) throw Error('lab offer declined: '+offer.declineReason);
    void offer.settlement.then(()=>log({event:'settled',token,calls}),error=> {
      appendBranchRoutingTrace(state,{token,actor:'watcher',stage:'fallback',reason:String(error).includes('claimed by main')?'ownership-lost':'branch-settlement-failed'},pi.events);
      log({event:'fallback',token,error:String(error),calls});
    });
  };
  pi.registerCommand('lab-stage', {description:'isolated test input',handler:async(args,ctx)=>{
    if(args==='before') { ctx.ui.notify('LAB_BASELINE_READY', 'info'); }
    else if(args==='process') {
      // Corrected counterfactual: keep an old MAIN row in the same queue,
      // claim only the unrelated new row, and complete real SDK model work.
      writeFileSync(`${state}/old.meta`,'project=synthetic\nwindow=fm-old\n');
      writeFileSync(`${state}/.wake-queue`,'1\t0\tsignal\told.status\told\n1\t1\tsignal\tprobe.status\tsynthetic\n');
      writeFileSync(`${state}/.main-eligible-rows`,'0\n');
      const scope = scopeForUnreadWake(state,false);
      if(scope.eligibleSeqs.join(',') !== '1' || dispositionForWakeTrigger('signal: old.status',scope).reason !== 'main-owned-trigger') throw Error('mixed MAIN claim classification failed');
      log({event:'mixed-claim',eligible:scope.eligibleSeqs,main:'0'});
      dispatch('successful');
    } else if(args==='finish') { released = true; delay?.(); }
    else if(args==='main') {
      const scope=scopeForUnreadWake(state,false);
      const disposition=dispositionForWakeTrigger('check: synthetic-main-only',scope);
      if(disposition.eligible) throw Error('main-only check accepted');
      appendBranchRoutingTrace(state,{token:'expected-main',actor:'watcher',stage:'classify',reason:disposition.reason},pi.events);
      appendBranchRoutingTrace(state,{token:'expected-main',actor:'watcher',stage:'declined',reason:'ineligible-trigger'},pi.events);
    } else if(args==='conflict') {
      dispatch('conflict');
      // MAIN wins after admission but before the asynchronous pre-prompt read.
      writeFileSync(`${state}/.main-eligible-rows`,'0\n1\n');
    } else if(args==='disabled') { writeFileSync(`${state}/.afk`,'away\n'); health(); }
    else if(args==='unknown') { if(existsSync(`${state}/.afk`)) unlinkSync(`${state}/.afk`); unlinkSync(`${state}/.lock`); health(); }
    else if(args==='stale') {
      // Test the published observation expiry with an aged snapshot; does not
      // fabricate success, invoke a model, or change any authority file.
      pi.events.emit(BRANCH_HEALTH_EVENT,{time:Date.now()-121000,generation:2,owned:true,broken:'none'});
    } else if(args==='error') { pi.events.emit(BRANCH_HEALTH_EVENT,{time:Date.now(),generation:1,owned:true,broken:'provider'}); }
    else if(args==='restore') { writeFileSync(`${state}/.lock`,`${process.pid}\n`); health(); }
    log({event:'command',args,calls,mode:ctx.mode});
  }});
}
