import { createHash } from 'node:crypto';
import { safe } from '../../../fm-state-reader/src/index.mjs';
export const serviceId = 'fm-moiras';
export const digest = text => createHash('sha256').update(text).digest('hex').slice(0, 24);
const held = text => /^(done|paused|parked|needs-decision)(?:\s|:)/.test(text);
const busySilentHeld = text => /^blocked \[key=stalled(?:-after-interrupt)?\]/.test(text);
const failures = w => w.lines.map(l => l.match(/(?:^|:\s*)(?:FAIL(?:ED)?|failing test|test failed)[: ]+(.+)/i)?.[1]);
export function episodes(workers, previous, now) {
  return Object.fromEntries(workers.flatMap(w => {
    const attempts = failures(w).filter(Boolean);
    if (w.truncated || held(w.last) || attempts.length < 2 || !attempts.every(x => x === attempts[0])) return [];
    const key = digest(attempts[0]), old = previous[w.id];
    return [[w.id, { key, since: old?.key === key && Number.isFinite(old.since) ? old.since : now }]];
  }));
}
export function thread(source, prs, forgeError = '') {
  const workers = source.workers.map(w => {
    const urls = [...w.lines].reverse().flatMap(line => line.match(/https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+\b/g) ?? []);
    const pr = urls.map(url => prs.find(p => p.url === url)).find(Boolean) ?? prs.find(p => p.head === `fm/${w.id}`);
    return { ...w, pr };
  });
  const knownPools = source.pools.filter(p => Number.isFinite(p.capacity));
  const used = knownPools.reduce((n, p) => n + p.used, 0), capacity = knownPools.reduce((n, p) => n + p.capacity, 0);
  const today = new Date(source.now * 1000).toISOString().slice(0, 10);
  return { ...source, workers, prs, forgeError, used, capacity, poolComplete: knownPools.length === source.pools.length,
    facts: [forgeError || `PRs today (UTC): ${prs.filter(p => p.created?.startsWith(today)).length} opened, ${prs.filter(p => p.merged?.startsWith(today)).length} merged`,
      `Pool: ${source.pools.length && knownPools.length === source.pools.length ? `${used}/${capacity}` : 'unknown'} | beacon: ${source.beaconAge === null ? 'unknown' : `${Math.floor(source.beaconAge)}s`}`] };
}
export function measure(s, c) {
  const findings = [];
  const add = (rule, task, evidence, cut = false) => {
    evidence = evidence.map(safe);
    findings.push({ id: digest(JSON.stringify([rule, task, evidence])), rule, task, evidence: evidence.map(line => line.slice(0, 2048)), cut, default: 'inspect', at: s.now });
  };
  if (s.beaconAge !== null && s.beaconAge > c.beaconSeconds) add('stale-beacon', 'watcher', [`last beat ${s.beaconAt}; grace ${c.beaconSeconds}s`]);
  if (s.poolComplete !== false && s.capacity && s.used / s.capacity >= c.poolRatio) add('pool-near-cap', 'pool', [`${s.used}/${s.capacity} leases; threshold ${c.poolRatio}`]);
  for (const w of s.workers) {
    if (w.truncated) continue;
    if (w.busy === 'busy' && Number.isFinite(w.age) && w.age >= c.busySilentSeconds && !held(w.last) && !busySilentHeld(w.last)) add('busy-but-silent', w.id, [`status at ${w.changed}; busy marker still active for ${Math.floor(w.age)}s`, w.last]);
    if (w.busy === 'idle' && Number.isFinite(w.idleAt) && w.age > c.idleSeconds && s.now - w.idleAt > c.idleSeconds && !held(w.last)) add('silent-idle', w.id, [`status at ${w.changed}; idle since ${w.idleAt}`, w.last]);
    const failed = failures(w), repeated = failed.length === 3 && failed.every(x => x && x === failed[0]);
    if (repeated) add('repeat-failure', w.id, w.lines);
    const attempts = failed.filter(Boolean), looping = attempts.length > 1 && attempts.every(x => x === attempts[0]);
    // Status age is not loop duration; time-based proposals need an observed episode start.
    const elapsed = Number.isFinite(w.loopSince) && s.now - w.loopSince >= c.loopSeconds;
    if (looping && !held(w.last) && (attempts.length >= c.loopAttempts || elapsed)) add('stop-loop', w.id, w.lines, true);
    if (!s.forgeError && /^done: PR https:\/\//.test(w.last) && w.pr && !w.pr.proof) add('missing-pr-proof', w.id, [w.pr.url, 'PR body lacks red, green, or lint markers']);
    if (!s.forgeError && /^done:/.test(w.last) && w.pr?.merged) add('retire-merged', w.id, [w.pr.url, `merged ${w.pr.merged}`], true);
  }
  if (!s.forgeError) for (const p of s.prs) if (p.state === 'open' && !s.workers.some(w => w.pr?.url === p.url)) add('ownerless-pr', p.url, [`${p.url} head ${p.head}; no matching task metadata`], true);
  return findings;
}
export function answer(message, snapshot) {
  if (message.kind !== 'request' || !Array.isArray(message.to) || !message.to.includes(serviceId)) throw Error('Not a Moiras request');
  const [op, value, ...extra] = message.text.trim().split(/\s+/);
  if (extra.length || !value) throw Error('Use ask TASK, confirm ID, or dismiss ID');
  if (op === 'ask') {
    const w = snapshot.workers.find(w => w.id === value);
    return w ? `${w.id}: ${w.busy}; last status ${Math.floor(w.age)}s ago; ${safe(w.last)}` : 'Unknown task; no idle claim is possible';
  }
  if (!['confirm', 'dismiss'].includes(op) || !/^[a-f0-9]{24}$/.test(value)) throw Error('Invalid request');
  if (!snapshot.findings.some(f => f.id === value)) throw Error('Proposal evidence changed; request a fresh proposal');
  return `${op} recorded for ${value}; no task action executed`;
}
