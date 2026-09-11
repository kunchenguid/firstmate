// Availability timestamps are observations, never authority to clear a gate.
import { tupleKey } from './routing.mjs';
const instant = value => typeof value === 'string' && Number.isFinite(Date.parse(value));
const latest = values => values.filter(instant).sort((a, b) => Date.parse(b) - Date.parse(a))[0] ?? null;
const same = (a, b) => String(a).trim().toLowerCase() === String(b).trim().toLowerCase();

export function poolRecovery(policy, candidates, quota, cooldowns, observedAt) {
  const rows = new Map();
  for (const candidate of candidates) {
    const binding = policy.bindings.find(row => tupleKey(row) === tupleKey(candidate));
    const row = rows.get(binding.pool) || { pool: binding.pool, observedAt, models: [], quota: [], quotaResetAt: null, cooldownUntil: null, pacingRecoveryAt: null, recheckAt: null, recoveryUnmeasured: false };
    if (!row.models.includes(binding.model)) row.models.push(binding.model);
    const applicable = quota.quota.filter(q => q.provider === binding.quotaProvider && (['all_models','all_products'].includes(q.scope) || binding.quotaScopes.includes(q.scope)));
    for (const q of applicable) if (!row.quota.some(item => item.provider === q.provider && item.scope === q.scope)) row.quota.push({ provider: q.provider, scope: q.scope, headroom: typeof q.effectivePercentRemaining === 'number' ? q.effectivePercentRemaining : null, spendPriority: typeof q.spendPriority === 'number' ? q.spendPriority : null, runway: q.runway, resetsAt: q.resetsAt ?? null });
    row.quotaResetAt = latest([row.quotaResetAt, ...applicable.map(q => q.resetsAt)]);
    const exhausted = applicable.filter(q => q.runway === 'exhausted_now' || (typeof q.effectivePercentRemaining === 'number' && q.effectivePercentRemaining <= 0));
    const matches = cooldowns.filter(entry => same(entry.scope.provider, binding.provider ?? binding.quotaProvider) && (entry.scope.kind === 'provider' || (same(entry.scope.harness, binding.harness) && same(entry.scope.model_family, binding.modelFamily))) && Date.parse(entry.expires_at) > Date.parse(observedAt));
    row.cooldownUntil = latest([row.cooldownUntil, ...matches.map(entry => entry.expires_at)]);
    row.pacingRecoveryAt = latest([row.pacingRecoveryAt, ...applicable.map(q => q.pacingRecoveryAt)]);
    row.recheckAt = latest([row.recheckAt, row.cooldownUntil, ...exhausted.map(q => q.resetsAt)]);
    row.recoveryUnmeasured ||= !applicable.length || exhausted.some(q => !instant(q.resetsAt));
    rows.set(binding.pool, row);
  }
  return [...rows.values()];
}
export function withDailyCaps(rows, decision, observedAt) {
  const weights = decision.selection?.weights || [];
  const selected = weights.find(weight => tupleKey(weight) === tupleKey(decision));
  const tomorrow = new Date(`${observedAt.slice(0, 10)}T00:00:00Z`);
  tomorrow.setUTCDate(tomorrow.getUTCDate() + 1);
  return rows.map(row => {
    const consumed = Number(selected?.runway === 'unmeasured' && selected.pool === row.pool);
    const capped = weights.some(weight => weight.pool === row.pool && weight.runway === 'unmeasured' && weight.dailyPicks + consumed >= decision.selection.unmeasuredDailyCap);
    const unmeasuredCapResetAt = capped ? tomorrow.toISOString() : null;
    return { ...row, unmeasuredCapResetAt, recheckAt: latest([row.recheckAt, unmeasuredCapResetAt]) };
  });
}
export function latestPoolRecovery(decisions) {
  const pools = new Map();
  for (const decision of decisions) for (const row of decision.poolRecovery || []) {
    if (!pools.has(row.pool) || Date.parse(row.observedAt) >= Date.parse(pools.get(row.pool).observedAt)) pools.set(row.pool, row);
  }
  return [...pools.values()];
}
export function recoveryCounters(rows, now) {
  return rows.map(row => ({ ...row, secondsUntilRecheck: row.recheckAt ? Math.max(0, Math.ceil((Date.parse(row.recheckAt) - now) / 1000)) : null, recheckDue: row.recheckAt ? Date.parse(row.recheckAt) <= now : false }));
}
