import { answer, digest, episodes, measure, serviceId, thread } from '../core/findings.mjs';
// One serialized observation. The caller supplies I/O, time and request-scoped telemetry.
export async function inspect({ source, forge, journal, publisher, messages, audit, onSnapshot = () => {}, onNotice = () => {} }, config, now) {
  let trace = audit;
  const step = (...args) => trace.step(...args), get = key => step('journal.read', () => journal.get(key), [key]);
  const set = (key, value) => step('journal.write', () => journal.set(key, value), [key]);
  const notices = [], inbox = messages ? await step('message.receive', () => messages.receive()) : [];
  const previous = await get('snapshot.json'), quiet = await get('quiet.json') ?? {}, replies = await get('replies.json') ?? {};
  let prs = previous?.prs ?? [], forgeAt = previous?.forgeAt ?? -Infinity, forgeError = previous?.forgeError ?? '';
  const repos = JSON.stringify(config.repositories);
  if (now - forgeAt >= config.forgeSeconds || inbox.length || repos !== previous?.repositories) {
    try { prs = await step('forge.read', () => forge.read(config.repositories), config.repositories); forgeError = config.repositories.length ? '' : 'PRs: unconfigured'; }
    catch { prs = []; forgeError = 'Forge unavailable; PR findings withheld'; }
    forgeAt = now;
  }
  const raw = await step('state.read', () => source.read(now));
  const loops = episodes(raw.workers, await get('episodes.json') ?? {}, now);
  raw.workers = raw.workers.map(w => ({ ...w, loopSince: loops[w.id]?.since }));
  const current = { ...thread(raw, prs, forgeError), forgeAt, repositories: repos, channel: messages ? 'connected' : 'unavailable' };
  current.findings = measure(current, config);
  await set('episodes.json', loops);
  await set('snapshot.json', current); onSnapshot(current);
  const deliver = async (record, save, to, text, options) => {
    if (record.state === 'sending' && !record.receipt) throw Error('Message delivery uncertain; inspect the shared thread ledger before recovery');
    if (!record.receipt) {
      record.state = 'sending'; await save();
      record.receipt = await step('message.send', () => messages.send(to, text, options), to);
      await save();
    } else if (record.receipt.partial) {
      record.receipt = await step('message.retry', () => messages.retry(record.receipt.id, record.receipt.thread), [record.receipt.id]);
      await save();
    }
    if (record.receipt.partial) throw Error('Message fan-out remains partial; retained receipt will be retried');
  };
  const emit = async event => {
    const key = `events/${event.id}.json`, stored = await get(key);
    if (!stored) await set(key, event);
    else if (stored.id !== event.id) throw Error('Event identity mismatch');
    const notice = `${event.rule}: ${event.task}; default ${event.default}; ${event.id}`;
    if (!(await get(`${key}.sent`)) && !(await step('event.captured', () => publisher.captured(event.id), [event.id]))) {
      await step('event.publish', () => publisher.publish(event.id), [event.id]);
      await set(`${key}.sent`, { at: now });
      notices.push(notice); onNotice(notice);
    }
    if (messages && event.rule !== 'reply') {
      const deliveryKey = `${key}.delivery`, delivery = await get(deliveryKey) ?? {};
      await deliver(delivery, () => set(deliveryKey, delivery), ['supervisor'], `${notice}; evidence: ${event.evidence.join(' | ')}`, { kind: 'note' });
    }
  };
  for (const event of current.findings) {
    const key = `${event.rule}:${event.task}`;
    if (now - (quiet[key] ?? -Infinity) < config.quietSeconds) continue;
    trace.decision('finding', 'proposed', [event.rule], `state/moiras/events/${event.id}.json`);
    await emit(event); quiet[key] = now; await set('quiet.json', quiet);
  }
  for (const { name, message } of inbox) {
    trace = audit.forRequest(message.id, message.thread);
    if (!message.to.includes(serviceId)) throw Error('Misrouted service message');
    if (message.kind !== 'request') {
      trace.decision('message', 'observed', [message.kind]);
      await step('message.acknowledge', () => messages.acknowledge(name), [message.id]); continue;
    }
    const signature = digest(JSON.stringify([message.from, message.to, message.text]));
    let reply = replies[message.id];
    if (reply && reply.signature !== signature) throw Error('Request id reused with different evidence');
    if (!reply) {
      let text;
      try { text = answer(message, current); trace.decision('request', 'recorded', [], message.id); }
      catch (error) { text = error.message; trace.decision('request', 'refused', [text], message.id); }
      reply = replies[message.id] = { signature, text, state: 'prepared', recordedAt: now }; await set('replies.json', replies);
    }
    await deliver(reply, () => set('replies.json', replies), [message.from], reply.text,
      { kind: 'reply', ref: message.id, ...(message.thread ? { thread: message.thread } : {}) });
    await emit({ id: digest(`reply:${message.id}`), rule: 'reply', task: message.from, evidence: [reply.text], default: 'read', at: now });
    await step('message.acknowledge', () => messages.acknowledge(name), [message.id]);
  }
  trace = audit;
  await set('snapshot.json', current);
  return { snapshot: current, notices };
}
