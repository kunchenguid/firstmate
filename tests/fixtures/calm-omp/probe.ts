// Token-free provider and inspection commands for the real installed OMP TUI.
import { AssistantMessageEventStream } from '@oh-my-pi/pi-ai';
import { writeFileSync } from 'node:fs';
export default function (pi: any) {
  let request = 0;
  const phase = (value: string) => writeFileSync(`${process.env.CALM_LAB}/phase`, value);
  pi.registerProvider('calm-fixture', {
    api: 'calm-fixture', apiKey: 'local-fixture', baseUrl: 'http://127.0.0.1:1',
    models: [{ id: 'fixture', name: 'Calm fixture', reasoning: false, input: ['text'], cost: {input:0,output:0,cacheRead:0,cacheWrite:0}, contextWindow: 32000, maxTokens: 1000 }],
    streamSimple(model: any, context: any) {
      const stream = new AssistantMessageEventStream();
      const last = context.messages.at(-1);
      const isResult = last?.role === 'toolResult';
      phase(`${request}:${isResult ? 'continuation' : 'model'}`);
      const message: any = { role: 'assistant', api: model.api, provider: model.provider, model: model.id,
        content: isResult ? [{type:'text', text:'CALM_FIXTURE_COMPLETE'}] : [{type:'toolCall', id:`fixture-${Date.now()}`, name:'bash', arguments:{command:'sleep 4; echo CALM_TOOL_OUTPUT'}}],
        stopReason: isResult ? 'stop' : 'toolUse', timestamp:Date.now(), usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}} };
      setTimeout(() => {stream.push({type:'start',partial:message}); if (isResult) {stream.push({type:'text_start',contentIndex:0,partial:message});stream.push({type:'text_delta',contentIndex:0,delta:message.content[0].text,partial:message});stream.push({type:'text_end',contentIndex:0,content:message.content[0].text,partial:message});} else {stream.push({type:'toolcall_start',contentIndex:0,partial:message});stream.push({type:'toolcall_delta',contentIndex:0,delta:JSON.stringify(message.content[0].arguments),partial:message});stream.push({type:'toolcall_end',contentIndex:0,toolCall:message.content[0],partial:message});} stream.push({type:'done',reason:message.stopReason,message});stream.end();}, isResult ? 1500 : 300);
      return stream;
    },
  });
  pi.on('agent_start', () => { request++; });
  pi.on('agent_end', () => phase(`${request}:idle`));
  pi.registerCommand('calm-setting', { description:'Change native fixture preference', handler: async (args: string, ctx: any) => {
    pi.pi.settings.set('display.hideToolActivity', args === 'true');
    ctx.ui.notify(`SETTING_${args}`);
  }});
  pi.registerCommand('calm-probe', { description:'Save fixture TUI evidence', handler: async (args: string, ctx: any) => {
    let components: any[] = [];
    ctx.ui.setWidget('calm-test-probe', (tui: any) => {
      const seen = new Set();
      function walk(c: any) { if (!c || seen.has(c)) return; seen.add(c);
        const name = c.constructor?.name;
        if (typeof c.setToolActivityVisible === 'function' || /Working|Loader/.test(name)) components.push({name,tool:typeof c.updateArgs === 'function' && typeof c.updateResult === 'function',lines:c.render(100)});
        for (const child of c.children ?? []) walk(child);
      }
      walk(tui); return {render:()=>[],invalidate(){}};
    });
    ctx.ui.setWidget('calm-test-probe', undefined);
    writeFileSync(`${process.env.CALM_LAB}/${args}.json`, JSON.stringify({components, entries:ctx.sessionManager.getEntries(), tools:pi.getAllTools(), active:pi.getActiveTools()}));
    ctx.ui.notify(`PROBE_SAVED_${args}`);
  }});
}
