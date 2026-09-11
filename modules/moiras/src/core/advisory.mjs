import { safe } from '../../../fm-state-reader/src/index.mjs';
const number = value => Number.isFinite(value) && value >= 0 ? value : null;
export function advisory(harness, stdout) {
  if (!['pi', 'claude'].includes(harness)) throw Error('Unsupported reasoning harness');
  let rows;
  try { rows = stdout.trim().split('\n').filter(Boolean).map(line => JSON.parse(line)); }
  catch { throw Error('Malformed provider stream'); }
  let text, model = null, tokens = null, cost = null;
  if (harness === 'pi') {
    if (rows.some(row => /^tool_execution/.test(row.type) || row.message?.role === 'toolResult' || row.message?.content?.some(item => item.type === 'toolCall'))) throw Error('Tool use is forbidden');
    const message = rows.filter(row => row.type === 'message_end' && row.message?.role === 'assistant').at(-1)?.message;
    if (!message || message.stopReason === 'error') throw Error(safe(message?.errorMessage ?? 'Provider failed').slice(0, 300));
    if (message.stopReason !== 'stop') throw Error('Incomplete advisory turn');
    text = message.content?.filter(item => item.type === 'text').map(item => item.text).join('');
    model = message.model ?? null; tokens = number(message.usage?.totalTokens); cost = number(message.usage?.cost?.total);
  } else {
    const result = rows.at(-1);
    if (result?.type !== 'result' || result.is_error || result.subtype !== 'success') throw Error('Provider failed');
    if (result.subagent_stats?.spawned > 0 || result.permission_denials?.length || Object.values(result.usage?.server_tool_use ?? {}).some(value => value > 0)) throw Error('Tool use is forbidden');
    text = result.result;
    const models = Object.keys(result.modelUsage ?? {}); model = models.length === 1 ? models[0] : null;
    const usage = ['input_tokens', 'output_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens'].map(key => number(result.usage?.[key]));
    if (usage.every(value => value !== null)) tokens = usage.reduce((sum, value) => sum + value, 0);
    cost = number(result.total_cost_usd);
    // Strip only a whole-answer Markdown wrapper, never extract an answer from other prose.
    if (typeof text === 'string') text = text.trim().replace(/^```(?:[a-z]+)?\r?\n([\s\S]*?)\r?\n```$/i, '$1').replace(/^`([^`\r\n]+)`$/, '$1');
  }
  if (typeof text !== 'string' || !/^MOIRAS\|(observe|uncertain|propose)\|[^\r\n|]{1,500}$/.test(text.trim()) || !/^[\x20-\x7e]+$/.test(text.trim())) throw Error('Malformed advisory response');
  return { text: safe(text.trim()), model, tokens, cost };
}
