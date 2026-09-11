export const adapters = ['fetch', 'gh', 'scrapling', 'alphaxiv'];
export function object(value, keys, required = keys) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(key => !keys.includes(key)) || required.some(key => !Object.hasOwn(value, key))) throw Error('invalid_fields');
}
export function text(value, max = 2000) {
  if (typeof value !== 'string' || !value.trim() || value.length > max || /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value)) throw Error('invalid_text');
  return value;
}
export function sourceUrl(value) {
  text(value, 2048);
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || url.port || url.hash || !/^[a-z0-9.-]+$/.test(url.hostname) || !url.hostname.includes('.') || url.hostname.endsWith('.')) throw Error('invalid_source_url');
  return url.href;
}
export function configuration(config) {
  object(config, ['maxSeconds', 'maxFetches', 'maxBytes', 'enabledAdapters', 'sources', 'roles']);
  for (const [key, min, max] of [['maxSeconds', 1, 600], ['maxFetches', 1, 20], ['maxBytes', 1024, 262144]]) {
    if (!Number.isInteger(config[key]) || config[key] < min || config[key] > max) throw Error('invalid_limit');
  }
  if (!Array.isArray(config.enabledAdapters) || config.enabledAdapters.some(name => !adapters.includes(name)) || new Set(config.enabledAdapters).size !== config.enabledAdapters.length) throw Error('invalid_adapters');
  if (!Array.isArray(config.sources) || config.sources.length > 100) throw Error('invalid_sources');
  const origins = new Set();
  for (const source of config.sources) {
    object(source, ['origin', 'publisher']);
    if (new URL(sourceUrl(source.origin)).origin !== source.origin || origins.has(source.origin)) throw Error('invalid_origin');
    origins.add(source.origin);
    if (!/^[a-z][a-z0-9-]{0,63}$/.test(source.publisher)) throw Error('invalid_publisher');
  }
  object(config.roles, ['researcher']);
  const role = config.roles.researcher;
  object(role, ['harness', 'model', 'effort', 'persona']);
  if (!['pi', 'pi-signed'].includes(role.harness) || !['low', 'medium', 'high', 'xhigh'].includes(role.effort)) throw Error('unsupported_harness_or_effort');
  text(role.model, 200);
  if (!/^personas\/[a-z0-9-]+\.md$/.test(role.persona)) throw Error('invalid_persona');
  return structuredClone(config);
}

// Application data inside Message.text; sender, id and routing stay in MessagePort.
export function request(message, config) {
  if (message.schema !== 'fm-message.v1' || message.kind !== 'request' || !/^msg-[a-f0-9]{32}$/.test(message.id)) throw Error('not_research_request');
  text(message.text, 16000);
  const value = JSON.parse(message.text);
  object(value, ['question', 'scope', 'topic', 'allowedSources', 'deadline', 'publicOnly']);
  text(value.question); text(value.scope);
  if (!/^[a-z][a-z0-9-]{0,63}$/.test(value.topic) || value.publicOnly !== true) throw Error('public_scope_required');
  if (typeof value.deadline !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(value.deadline) || !Number.isFinite(Date.parse(value.deadline))) throw Error('invalid_deadline');
  if (!Array.isArray(value.allowedSources) || !value.allowedSources.length || value.allowedSources.length > config.maxFetches) throw Error('fetch_limit');
  const urls = new Set();
  const allowedSources = value.allowedSources.map(source => {
    object(source, ['adapter', 'url']);
    if (!config.enabledAdapters.includes(source.adapter)) throw Error('adapter_disabled');
    const url = sourceUrl(source.url), origin = new URL(url).origin;
    const publisher = config.sources.find(source => source.origin === origin)?.publisher;
    if (!publisher || urls.has(url)) throw Error('source_not_allowed');
    urls.add(url);
    return { adapter: source.adapter, url, publisher };
  });
  return { ...value, allowedSources, id: message.id, requester: message.from, thread: message.thread };
}

export function conclusion(draft, sources) {
  object(draft, ['conclusions', 'unknowns']);
  if (!Array.isArray(draft.conclusions) || draft.conclusions.length > 8 || !Array.isArray(draft.unknowns) || draft.unknowns.length > 12) throw Error('invalid_draft');
  const unknowns = draft.unknowns.map(value => text(value, 1000));
  const conclusions = draft.conclusions.map(claim => {
    object(claim, ['kind', 'statement', 'citations']);
    if (!['observed', 'inferred', 'proposed'].includes(claim.kind) || !Array.isArray(claim.citations) || claim.citations.length < 2 || claim.citations.length > 20) throw Error('unsupported_conclusion');
    text(claim.statement, 1200);
    if (/https?:|\[[^\]]*\]|<|>/.test(claim.statement)) throw Error('unsupported_conclusion');
    const publishers = new Set(), ids = new Set();
    const citations = claim.citations.map(citation => {
      object(citation, ['source', 'quote']);
      const source = sources.find(item => item.id === citation.source);
      if (!source || ids.has(source.id) || !text(citation.quote, 1000) || citation.quote.trim().length < 12 || !source.content.includes(citation.quote)) throw Error('unverified_quote');
      publishers.add(source.publisher); ids.add(source.id);
      return { ...citation };
    });
    if (publishers.size < 2) throw Error('independent_sources_required');
    return { ...claim, citations };
  });
  return { verdict: conclusions.length ? (unknowns.length ? 'partial' : 'supported') : 'unverified', conclusions, unknowns };
}

const prose = value => String(value).replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '').replace(/[&<>\[\]`]/g, char => `&#${char.charCodeAt(0)};`);
export function brief(result, sources) {
  const evidence = result.conclusions.map(claim => `- **${claim.kind}**: ${prose(claim.statement)} ${claim.citations.map(c => `[${c.source}]`).join(' ')}`).join('\n');
  const citations = result.conclusions.flatMap(claim => claim.citations);
  const used = sources.filter(source => citations.some(c => c.source === source.id));
  return `# Verdict: ${result.verdict}\n\n## Evidence\n\n${evidence || 'No conclusion met the evidence requirements.'}\n\n## Sources\n\n` + used.map(source => `### [${source.id}] ${source.url}\n\nRetrieved: ${source.at}; publication group: ${source.publisher}.\n\n` + [...new Set(citations.filter(c => c.source === source.id).map(c => c.quote))].map(quote => quote.split('\n').map(line => `> ${prose(line)}`).join('\n')).join('\n\n')).join('\n\n') + `\n\n## Could not verify\n\n${result.unknowns.map(value => `- ${prose(value)}`).join('\n') || '- No additional gaps reported by the reasoning step.'}\n\nQuoted text was matched against retrieved content; semantic support and whether sources are independent still require reader judgment.\n`;
}
