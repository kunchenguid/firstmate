export const safe = value => String(value ?? '').replace(/[^\x20-\x7e]/g, '?').replace(/(?:bearer\s+\S+|(?:token|password|secret|api[_-]?key)\s*[=:]\s*\S+|(?:gh[pousr]_|sk-)[\w-]+)/gi, '[redacted]');
export function completeLines(record) { const lines = (record?.text ?? '').split('\n'); if (record?.truncated) lines.shift(); return lines.filter(line => line.trim()); }
const fields = text => Object.fromEntries([...text.matchAll(/(?:^|\s)([a-z_]+)=([^\s]+)/g)].map(m => [m[1], m[2]]));
export function task(id, meta, status, busy, generation, now) {
  const m = Object.fromEntries(completeLines(meta?.truncated ? null : meta).filter(line => /^[a-z_]+=/.test(line)).map(line => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1).trim()]));
  const b = fields(busy?.truncated ? '' : busy?.text ?? ''), gen = generation?.truncated || meta?.truncated ? '' : generation?.text.trim();
  const lines = completeLines(status).slice(-3).map(safe);
  return { id, harness: safe(m.harness), model: safe(m.model), effort: safe(m.effort), worktree: m.worktree ?? null,
    truncated: [meta, status, busy, generation].some(record => record?.truncated), lines, last: lines.at(-1) ?? 'No status recorded', changed: status?.at ?? null,
    age: Math.max(0, now - (status?.at ?? meta?.at ?? now)),
    busy: gen && gen === b.gen && (!m.busy_gen || gen === m.busy_gen) && ['busy', 'idle'].includes(b.state) ? b.state : 'unknown',
    idleAt: Number.isFinite(Number(b.ts)) ? Number(b.ts) : null };
}
export function ledger(record) {
  if (!record) return { rows: [], malformed: 0, truncated: false };
  const lines = completeLines(record);
  let malformed = 0;
  const rows = lines.filter(line => line.trim()).flatMap(line => { try { return [JSON.parse(line)]; } catch { malformed++; return []; } });
  return { rows, malformed, truncated: record.truncated };
}
export function pool(record) {
  if (!record || record.truncated) return null;
  try {
    const { worktrees } = JSON.parse(record.text);
    if (!Array.isArray(worktrees) || worktrees.some(w => !w || typeof w.leased !== 'boolean')) return null;
    return { used: worktrees.filter(w => w.leased).length, capacity: worktrees.length };
  } catch { return null; }
}
