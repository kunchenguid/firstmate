import path from 'node:path';
import { appendRegistryEvent, auditRegistry, buildActiveIndex, foldRegistry, recoverRegistry, snapshotRegistry } from './registry.mjs';
import { checkDoctor } from './doctor.mjs';
import { registryDir, registryPaths } from './paths.mjs';

function parseArgs(args) {
  const out = { _: [] };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (!arg.startsWith('--')) out._.push(arg);
    else {
      const key = arg.slice(2);
      const next = args[i + 1];
      if (!next || next.startsWith('--')) out[key] = true;
      else {
        if (out[key] === undefined) out[key] = next;
        else if (Array.isArray(out[key])) out[key].push(next);
        else out[key] = [out[key], next];
        i += 1;
      }
    }
  }
  return out;
}

function list(value) {
  if (value === undefined) return [];
  return Array.isArray(value) ? value : [value];
}

// Full field set for a NEW record: proposal defaults are appropriate here.
function proposeFieldsFromFlags(flags) {
  const fields = {
    summary: flags.summary,
    body: typeof flags.body === 'string' ? flags.body : '',
    memoryType: flags['memory-type'] || 'factual',
    scope: flags.scope || 'fleet',
    projects: list(flags.project).length ? list(flags.project) : ['*'],
    taskKinds: list(flags.kind).length ? list(flags.kind) : ['*'],
    keywords: list(flags.keyword),
    aliases: list(flags.alias),
    entities: list(flags.entity),
    commands: list(flags.command),
    failureModes: list(flags['failure-mode']),
    relatedTerms: list(flags['related-term']),
    confidence: flags.confidence || 'unverified',
    riskClass: flags['risk-class'] || 'standard'
  };
  if ('guard-linked' in flags) fields.guard_linked = flags['guard-linked'] === true || flags['guard-linked'] === 'true';
  return fields;
}

// Sparse field set for an UPDATE: ONLY fields the caller explicitly supplied are
// included. Omitted fields are absent, so the fold preserves them. Proposal
// defaults are never applied to an update.
function updateFieldsFromFlags(flags) {
  const fields = {};
  const setStr = (flag, field) => {
    if (flag in flags && typeof flags[flag] === 'string') fields[field] = flags[flag];
  };
  const setList = (flag, field) => {
    if (flag in flags) fields[field] = list(flags[flag]);
  };
  setStr('summary', 'summary');
  setStr('body', 'body');
  setStr('memory-type', 'memoryType');
  setStr('scope', 'scope');
  setList('project', 'projects');
  setList('kind', 'taskKinds');
  setList('keyword', 'keywords');
  setList('alias', 'aliases');
  setList('entity', 'entities');
  setList('command', 'commands');
  setList('failure-mode', 'failureModes');
  setList('related-term', 'relatedTerms');
  setStr('confidence', 'confidence');
  setStr('risk-class', 'riskClass');
  setStr('valid-to', 'validTo');
  if ('guard-linked' in flags) fields.guard_linked = flags['guard-linked'] === true || flags['guard-linked'] === 'true';
  return fields;
}

function evidence(flags) {
  return list(flags.evidence).map((entry) => {
    const [type, ...rest] = entry.split(':');
    return { type, ref: rest.join(':') || entry };
  });
}

function actor(flags) {
  return { kind: flags['actor-kind'] || 'firstmate', id: flags.actor || 'mem-cli' };
}

function print(value, json = false) {
  if (json) console.log(JSON.stringify(value, null, 2));
  else if (typeof value === 'string') console.log(value);
  else console.log(JSON.stringify(value, null, 2));
}

export async function main(args, options = {}) {
  const flags = parseArgs(args);
  const verb = flags._[0];
  const dir = registryDir(process.env);
  try {
    if (verb === 'propose') {
      if (!flags.summary) throw new Error('propose requires --summary');
      const result = await appendRegistryEvent(dir, { event: 'proposed', actor: actor(flags), fields: proposeFieldsFromFlags(flags), evidence: evidence(flags), reason: flags.reason });
      print({ memId: result.event.memId, eventId: result.event.eventId, skipped: result.skipped }, flags.json);
    } else if (verb === 'activate') {
      const memId = flags._[1];
      if (!memId) throw new Error('activate requires MEM id');
      const result = await appendRegistryEvent(dir, { event: 'activated', memId, actor: actor(flags), fields: { confidence: flags.confidence || 'observed' }, evidence: evidence(flags), validation: { method: flags.method || 'captain', by: flags.actor || 'mem-cli', ref: flags.validation || flags.evidence }, reason: flags.reason });
      print({ memId, eventId: result.event.eventId }, flags.json);
    } else if (verb === 'revalidate') {
      const memId = flags._[1];
      if (!memId) throw new Error('revalidate requires MEM id');
      const result = await appendRegistryEvent(dir, { event: 'revalidated', memId, actor: actor(flags), evidence: evidence(flags), validation: { method: flags.method || 'captain', by: flags.actor || 'mem-cli', ref: flags.validation || flags.evidence }, reason: flags.reason });
      print({ memId, eventId: result.event.eventId }, flags.json);
    } else if (verb === 'update') {
      const memId = flags._[1];
      if (!memId) throw new Error('update requires MEM id');
      const fields = updateFieldsFromFlags(flags);
      const result = await appendRegistryEvent(dir, { event: 'updated', memId, actor: actor(flags), fields, evidence: evidence(flags), reason: flags.reason });
      print({ memId, eventId: result.event.eventId }, flags.json);
    } else if (['supersede', 'retire', 'quarantine'].includes(verb)) {
      const memId = flags._[1];
      if (!memId) throw new Error(`${verb} requires MEM id`);
      const event = verb === 'supersede' ? 'superseded' : `${verb}d`;
      const result = await appendRegistryEvent(dir, { event, memId, actor: actor(flags), successor: flags.successor, evidence: evidence(flags), reason: flags.reason });
      print({ memId, eventId: result.event.eventId }, flags.json);
    } else if (verb === 'show') {
      // `mem show` is intentionally READ-ONLY in PR-1: it emits no `opened`
      // activity event. Compatibility contract: the activity event schema accepts
      // any event name (`event: z.string().min(1)`), so adding an `opened` event in
      // a later PR requires no activity schema migration.
      const memId = flags._[1];
      const fold = foldRegistry(dir);
      const record = fold.records.get(memId);
      if (!record) throw new Error(`record not found: ${memId}`);
      if (flags.chain) {
        const chain = [record, ...[...(record.supersedes || []), record.supersededBy].filter(Boolean).map((id) => fold.records.get(id)).filter(Boolean)];
        print({ record, chain, registry: fold.watermark, health: fold.health }, flags.json);
      } else print(flags.json ? { record, registry: fold.watermark, health: fold.health } : `${record.id} [${record.status}] ${record.summary}\n${record.body}`, flags.json);
    } else if (verb === 'audit') {
      const audit = auditRegistry(dir);
      if (flags.json) print(audit, true);
      else {
        console.log(`Registry: ${audit.registry.health} ${audit.registry.watermark.seq}:${audit.registry.watermark.eventId || 'none'}`);
        console.log(`Records: ${audit.records.total} total, ${audit.records.active} active`);
        console.log(`Active index: ${audit.activeIndex.status}`);
        if (audit.activeIndex.issues?.length) console.log(`Index issues: ${audit.activeIndex.issues.join('; ')}`);
        console.log(`Snapshots: ${audit.snapshots.health}`);
        if (audit.snapshots.issues?.length) console.log(`Snapshot issues: ${audit.snapshots.issues.join('; ')}`);
        if (audit.registry.corrupt) console.log(`CRITICAL: ${audit.registry.corrupt.reason}`);
      }
      process.exitCode = audit.ok ? 0 : 1;
    } else if (verb === 'project' || (verb === 'index' && flags._[1] === 'rebuild')) {
      const index = buildActiveIndex(dir);
      print({ index: registryPaths(dir).index, registry: index.registry, records: index.recordCount }, flags.json);
    } else if (verb === 'snapshot') {
      print(snapshotRegistry(dir), flags.json);
    } else if (verb === 'recover') {
      print(await recoverRegistry(dir), flags.json);
    } else if (verb === 'doctor') {
      const doctor = checkDoctor(options.root || path.resolve('.', 'memory'), process.env);
      if (flags.json) print(doctor, true);
      else {
        console.log(`Memory CLI: ${doctor.cli.available ? 'available' : 'missing'} (${doctor.cli.path})`);
        console.log(`Canonical checkout: ${doctor.canonicalCheckout.path}`);
        console.log(`Node: ${doctor.node.version} (${doctor.node.compatible ? 'compatible' : 'incompatible'})`);
        console.log(`Package lock: ${doctor.packageLock.current ? 'current' : 'not current'}`);
        console.log(`Required dependencies: ${doctor.requiredDependencies.ok ? 'available' : `missing ${[...doctor.requiredDependencies.missing, ...(doctor.requiredDependencies.mismatched || [])].join(', ')}`}`);
        console.log(`PGlite: ${doctor.pglite.available ? 'available' : doctor.pglite.status}`);
        console.log(`Vector extension: ${doctor.vectorExtension.available ? 'available' : doctor.vectorExtension.status}`);
        console.log(`Embedding provider: ${doctor.embeddingProvider.configured ? 'configured' : 'not configured (optional)'}`);
        console.log(`Registry: ${doctor.registry.status} (${doctor.registry.path})`);
        console.log(`Snapshots: ${doctor.snapshots.health || 'unknown'}`);
        console.log(`Active-memory index: ${doctor.activeIndex.status}`);
      }
      process.exitCode = doctor.ok ? 0 : 1;
    } else if (verb === 'help' || !verb) {
      console.log('Usage: mem propose|activate|revalidate|show|update|supersede|retire|quarantine|audit|project|index rebuild|snapshot|recover|doctor');
    } else {
      throw new Error(`unknown command: ${verb}`);
    }
  } catch (error) {
    if (flags.json) console.log(JSON.stringify({ ok: false, error: error.message, code: error.code || null }, null, 2));
    else console.error(`mem: ${error.message}`);
    process.exitCode = 1;
  }
}
