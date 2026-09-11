import { request, conclusion, brief } from '../core/research.mjs';

const refusalCodes = new Set(['adapter_disabled', 'source_not_allowed', 'invalid_source_url', 'public_scope_required', 'fetch_limit', 'invalid_fields', 'invalid_text', 'invalid_deadline', 'deadline_exceeded', 'unverified_quote', 'unsupported_conclusion', 'independent_sources_required', 'invalid_draft', 'retrieval_unready', 'harness_failed', 'fetch_failed', 'private_destination', 'redirect_refused']);
export const refusal = error => refusalCodes.has(error?.message) ? error.message : 'operation_failed';

/** Process one shared message, preserving unrelated messages and durable delivery phases. */
export async function research({ messages, store, retrieval, reasoner, events, clock }, config) {
  const entries = await messages.receive();
  // This service receives only routed research requests, never control chatter.
  const entry = entries.find(entry => entry.message.kind === 'request');
  if (!entry) return { state: 'idle', queued: entries.length };
  const id = entry.message.id;
  let record = await store.load(id);
  const log = async (event, outcome = null, reasons = [], counters = {}) => store.log({
    ts: new Date(clock.now()).toISOString(), module: 'robin', event, requestId: id,
    threadId: entry.message.thread, actor: 'robin', inputs: { ids: [id], bytes: Buffer.byteLength(entry.message.text) },
    decision: null, reasons, stepsMs: {}, ...config.roles.researcher, persona: undefined,
    tokens: null, cost: null, outcome, evidencePath: record?.report ?? null, counters,
  });
  if (!record) {
    let input;
    try { input = request(entry.message, config); }
    catch (error) {
      await log('request.exit', 'rejected', [refusal(error)]);
      // No payload or raw exception is echoed back, stored in telemetry, or sent to a model.
      record = await store.finish(id, 'unclassified', brief({ verdict: 'unverified', conclusions: [], unknowns: [`Request refused: ${refusal(error)}.`] }, []), { verdict: 'unverified', requester: entry.message.from });
    }
    if (input) {
      const deadline = Math.min(Date.parse(input.deadline), clock.now() + config.maxSeconds * 1000);
      const sources = [], failures = [];
      let fetches = 0, draft;
      for (const source of input.allowedSources) {
        if (clock.now() >= deadline) { failures.push('deadline_exceeded'); break; }
        await log('retrieval.enter', null, [], { fetches });
        try {
          fetches++;
          const content = await retrieval[source.adapter].fetch(source.url, { deadline, maxBytes: config.maxBytes });
          if (typeof content !== 'string' || !content.trim() || Buffer.byteLength(content) > config.maxBytes) throw Error('fetch_failed');
          sources.push({ ...source, id: sources.length + 1, content, at: new Date(clock.now()).toISOString() });
          await log('retrieval.exit', 'accepted', [], { fetches });
        } catch (error) {
          failures.push(refusal(error));
          await log('retrieval.exit', 'error', [refusal(error)], { fetches });
        }
      }
      try {
        if (clock.now() >= deadline) throw Error('deadline_exceeded');
        if (new Set(sources.map(source => source.publisher)).size < 2) throw Error('independent_sources_required');
        await log('reasoner.enter');
        // Deliberately exclude routing IDs, local paths and the surrounding conversation.
        const output = await reasoner.reason({ question: input.question, scope: input.scope, sources }, { deadline });
        draft = conclusion(output, sources);
        draft.unknowns.push(...failures.map(code => `Retrieval incomplete: ${code}.`));
        if (failures.length && draft.verdict === 'supported') draft.verdict = 'partial';
        await log('reasoner.exit', 'accepted');
      } catch (error) {
        draft = { verdict: 'unverified', conclusions: [], unknowns: [...failures.map(code => `Retrieval incomplete: ${code}.`), `Conclusion withheld: ${refusal(error)}.`] };
        await log('reasoner.exit', 'error', [refusal(error)]);
      }
      record = await store.finish(id, input.topic, brief(draft, sources), { verdict: draft.verdict, requester: input.requester });
      await log('request.exit', draft.verdict === 'unverified' ? 'rejected' : 'accepted', [], { fetches, sources: sources.length });
    }
  }
  // Resumption starts from the durable report, never from another model call.
  if (!record.receipt) {
    const receipt = await messages.reply(id, `Research ${record.verdict}: ${record.report}`);
    record = { ...record, receipt };
    await store.save(id, record);
  }
  if (record.receipt.partial) {
    const receipt = await messages.retry(record.receipt.id, record.receipt.thread);
    record = { ...record, receipt };
    await store.save(id, record);
    if (receipt.partial) throw Error('reply_incomplete');
  }
  if (!record.notified) {
    await events.publish(record.eventId);
    record = { ...record, notified: true };
    await store.save(id, record);
  }
  await messages.acknowledge(entry.name);
  await log('delivery.exit', 'accepted');
  return { state: 'answered', id, report: record.report, verdict: record.verdict };
}
