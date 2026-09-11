// Pure, reproducible exploration after eligibility and known-exhaustion gates.
// quota-axi owns headroom/reset economics. A positive shift preserves its order.
// Uniform exploration keeps low-quality candidates reachable; unmeasured pools
// have a separate, small pool-level share, never fabricated quota headroom.
const finite = value => typeof value === 'number' && Number.isFinite(value);
const positive = value => finite(value) && value >= 0;
const key = row => JSON.stringify([row.harness, row.model, row.effort ?? null, row.accountProfile ?? null]);
const mean = values => values.reduce((sum, value) => sum + value / values.length, 0);

function distribute(rows, mass, explorationRate) {
  const maximum = Math.max(1, ...rows.map(row => row.score));
  const total = rows.reduce((sum, row) => sum + row.score / maximum, 0);
  for (const row of rows) row.probability = mass * (explorationRate / rows.length + (1 - explorationRate) * (total ? row.score / maximum / total : 1 / rows.length));
}

export function weightedChoice(candidates, { seed, explorationRate, unmeasuredRate = 0.05, unmeasuredDailyCap = 1, dailyPicks = {} }) {
  if (!Number.isInteger(seed) || seed < 0 || seed > 0xffffffff) throw new Error('random seed must be uint32');
  if (!finite(explorationRate) || explorationRate <= 0 || explorationRate > 1) throw new Error('explorationRate must be in (0,1]');
  if (!finite(unmeasuredRate) || unmeasuredRate <= 0 || unmeasuredRate >= 1) throw new Error('unmeasuredRate must be in (0,1)');
  if (!Number.isInteger(unmeasuredDailyCap) || unmeasuredDailyCap < 1) throw new Error('unmeasured daily cap must be a positive integer');
  if (new Set(candidates.map(key)).size !== candidates.length) throw new Error('duplicate weighted candidate');
  if (candidates.some(row => !positive(row.quality?.score) || row.quality.score > 1)) throw new Error('unproven task-class quality weight');
  const ordered = [...candidates].sort((a, b) => key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0);
  const measured = ordered.filter(row => finite(row.spendPriority) && row.feasibility !== 'unproven');
  const minimum = Math.min(...measured.map(row => row.spendPriority));
  const times = ordered.map(row => row.quality.meanWallSeconds).filter(positive);
  const costs = ordered.filter(row => positive(row.quality.meanCost) && /^[A-Z]{3}$/.test(row.quality.currency));
  const comparableCost = costs.length > 0 && new Set(costs.map(row => row.quality.currency)).size === 1;
  const typicalTime = mean(times);
  const typicalCost = mean(costs.map(row => row.quality.meanCost));
  const weights = ordered.map(row => {
    const unmeasured = !measured.includes(row);
    if (unmeasured && (typeof row.pool !== 'string' || !row.pool)) throw new Error('unmeasured pool identity required');
    const picks = Object.hasOwn(dailyPicks, row.pool) ? dailyPicks[row.pool] : 0;
    if (!Number.isInteger(picks) || picks < 0) throw new Error('invalid daily pick counter');
    const quotaWeight = unmeasured ? null : 1 + row.spendPriority - minimum;
    const wallFactor = positive(row.quality.meanWallSeconds) ? (1 + typicalTime) / (1 + row.quality.meanWallSeconds) : 1;
    const costFactor = comparableCost && positive(row.quality.meanCost) && /^[A-Z]{3}$/.test(row.quality.currency) ? (1 + typicalCost) / (1 + row.quality.meanCost) : 1;
    // The unmeasured multiplier is only for distribution WITHIN its fixed
    // exploration allocation, not a claim that its pacing is healthy.
    const score = (quotaWeight ?? 1) * row.quality.score * wallFactor * costFactor;
    if (!positive(score)) throw new Error('non-finite selection weight');
    return { harness: row.harness, model: row.model, effort: row.effort ?? null, accountProfile: row.accountProfile ?? null, pool: row.pool ?? null, quotaWeight, quality: row.quality, wallFactor, costFactor, score, probability: 0, runway: unmeasured ? 'unmeasured' : 'proven', dailyPicks: unmeasured ? picks : null, reason: unmeasured && picks >= unmeasuredDailyCap ? 'unmeasured-daily-cap' : null };
  });
  const known = weights.filter(row => row.runway === 'proven');
  const unknown = weights.filter(row => row.runway === 'unmeasured' && !row.reason);
  const pools = [...new Set(unknown.map(row => row.pool))];
  // Do not silently amplify a 5% exploration allocation to 100% when every
  // measurable route is unavailable. That requires a separate explicit route.
  if (known.length) {
    distribute(known, pools.length ? 1 - unmeasuredRate : 1, explorationRate);
    for (const pool of pools) distribute(unknown.filter(row => row.pool === pool), unmeasuredRate / pools.length, explorationRate);
  }
  const draw = seed / 0x100000000;
  let cumulative = 0;
  const index = weights.findIndex(row => { cumulative += row.probability; return draw < cumulative; });
  const fallback = weights.findLastIndex(row => row.probability > 0);
  return { pick: ordered[index < 0 ? fallback : index] ?? null, method: 'quality-quota-cost-mixture-v1', seed, draw, explorationRate, unmeasuredRate, unmeasuredDailyCap, reason: known.length ? null : 'no-measured-baseline', weights };
}
