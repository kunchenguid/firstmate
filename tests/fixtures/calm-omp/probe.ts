// Token-free provider and inspection commands for the real installed OMP TUI.
import { AssistantMessageEventStream } from '@oh-my-pi/pi-ai';
import { writeFileSync } from 'node:fs';
export default function (pi: any) {
  let request = 0;
  let cachedMode: any;
  const advisorRows = new Set<any>();
  function getMode(ctx: any) {
    let mode: any;
    ctx.ui.setWidget('calm-fixture-mode', (tui: any) => {
      const seen = new Set();
      function walk(node: any) {
        if (!node || seen.has(node)) return;
        seen.add(node);
        if (node.mode?.todoContainer === node) mode = node.mode;
        for (const child of node.children ?? []) walk(child);
      }
      walk(tui);
      return {render: () => [], invalidate() {}};
    });
    ctx.ui.setWidget('calm-fixture-mode', undefined);
    if (!mode) mode = cachedMode;
    if (!mode) throw Error('OMP live mode unavailable to fixture');
    cachedMode = mode;
    return mode;
  }
  pi.registerCommand('calm-advisor', {description: 'Append native advisor fixture', handler: async (args: string, ctx: any) => {
    const mode = getMode(ctx);
    const before = new Set(mode.chatContainer.children);
    mode.addMessageToChat({role: 'custom', customType: 'advisor', content: `ADVISOR_${args}`, display: true,
      details: {notes: [{note: `ADVISOR_${args}`, severity: 'concern'}]}});
    await new Promise(resolve => setTimeout(resolve, 100));
    for (const row of mode.chatContainer.children) if (!before.has(row)) advisorRows.add(row);
    ctx.ui.notify(`ADVISOR_SAVED_${args}`);
  }});
  pi.registerCommand('calm-todo', {description: 'Seed native session todo fixture', handler: async (_args: string, ctx: any) => {
    const mode = getMode(ctx);
    const phases = [{name: 'Fixture phase', tasks: [{content: 'CALM_TODO_TASK', status: 'pending'}]}];
    // Seed the same persisted result contract used by the native todo tool,
    // then refresh through the native session and TUI interfaces.
    mode.session.sessionManager.appendMessage({role: 'toolResult', toolCallId: 'fixture-todo', toolName: 'todo',
      content: [{type: 'text', text: 'CALM_TODO_TASK'}], details: {op: 'init', phases, storage: 'session'}, isError: false, timestamp: Date.now()});
    mode.session.setTodoPhases(phases);
    mode.setTodos(phases);
    ctx.ui.notify('TODO_SAVED');
  }});
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
    const mode = getMode(ctx);
    const hidden = args === 'true';
    pi.pi.settings.set('display.hideToolActivity', hidden);
    mode.hideToolActivity = hidden;
    mode.chatContainer.setToolActivityVisible(!hidden);
    mode.chatContainer.children.forEach((child: any) => child.setToolActivityVisible?.(!hidden));
    ctx.ui.setWidget('calm-test-redraw', (tui: any) => { tui.requestRender?.(); return {render:()=>[],invalidate(){}}; });
    ctx.ui.setWidget('calm-test-redraw', undefined);
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
    const mode = getMode(ctx);
    const presentation = {advisors: [...advisorRows].map(row => row.render(100)), todo: mode.todoContainer.render(100), compact: mode.renderCompactStatusLine(100, ['WORKING_SENTINEL']), phases: mode.todoPhases, storedPhases: mode.session.getTodoPhases(), chat: mode.chatContainer.render(100), compactMode: mode.isCompactTodoMode()};
    writeFileSync(`${process.env.CALM_LAB}/${args}.json`, JSON.stringify({components, presentation, entries:ctx.sessionManager.getEntries(), tools:pi.getAllTools(), active:pi.getActiveTools()}));
    ctx.ui.notify(`PROBE_SAVED_${args}`);
  }});
}
