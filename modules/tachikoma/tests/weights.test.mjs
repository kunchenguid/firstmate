import assert from 'node:assert/strict';
import { weightedChoice } from '../src/core/weights.mjs';

const candidates = [
  { harness: 'pi', model: 'subscription/a', effort: 'high', spendPriority: 5, quality: { score: 0.9, source: 'profile-prior', observations: 0, meanWallSeconds: null, meanCost: null, currency: null } },
  { harness: 'pi', model: 'subscription/b', effort: 'high', spendPriority: 1, quality: { score: 0.5, source: 'class-card', observations: 12, meanWallSeconds: 60, meanCost: 2, currency: 'USD' } },
];
const options = { seed: 0, explorationRate: 0.1 };
const before = structuredClone(candidates);
const result = weightedChoice(candidates, options);
assert.equal(result.pick.model, 'subscription/a');
assert.equal(result.seed, 0);
assert.equal(result.explorationRate, 0.1);
assert.equal(result.weights[0].quotaWeight, 5);
assert.ok(result.weights.every(row => row.probability > 0));
assert.ok(Math.abs(result.weights.reduce((sum, row) => sum + row.probability, 0) - 1) < 1e-12);
assert.equal(weightedChoice(candidates, { ...options, seed: 0xffffffff }).pick.model, 'subscription/b');
assert.deepEqual(weightedChoice([...candidates].reverse(), options), result);
assert.deepEqual(candidates, before);
const ties = candidates.map(c => ({ ...c, spendPriority: 0, quality: { ...c.quality, score: 0.5, meanWallSeconds: null, meanCost: null } }));
assert.equal(weightedChoice(ties, options).weights[0].probability, 0.5);
assert.equal(weightedChoice(ties, { ...options, seed: 0xffffffff }).pick.model, 'subscription/b');
const lowQuality = structuredClone(candidates); lowQuality[1].quality.score = 0;
assert.equal(weightedChoice(lowQuality, options).weights[1].probability, 0.05);
const measured = structuredClone(candidates);
measured[0].quality.meanWallSeconds = 120; measured[0].quality.meanCost = 4; measured[0].quality.currency = 'USD';
const factors = weightedChoice(measured, options).weights;
assert.ok(factors[0].wallFactor < factors[1].wallFactor);
assert.ok(factors[0].costFactor < factors[1].costFactor);
measured[0].quality.currency = 'EUR';
assert.ok(weightedChoice(measured, options).weights.every(row => row.costFactor === 1));
for (const invalid of [{ seed: -1 }, { seed: 0x100000000 }, { seed: 0.5 }, { explorationRate: 0 }, { explorationRate: 1.1 }]) assert.throws(() => weightedChoice(candidates, { ...options, ...invalid }));
const unmeasured = { ...candidates[1], model: 'subscription/z', pool: 'unmeasured-pool', spendPriority: null };
const explored = weightedChoice([...candidates, unmeasured], { ...options, seed: 0xffffffff, unmeasuredRate: 0.05, unmeasuredDailyCap: 1, dailyPicks: {} });
assert.equal(explored.pick.pool, 'unmeasured-pool');
assert.equal(explored.weights.at(-1).probability, 0.05);
assert.equal(explored.weights.at(-1).runway, 'unmeasured');
const capped = weightedChoice([...candidates, unmeasured], { ...options, seed: 0xffffffff, unmeasuredRate: 0.05, unmeasuredDailyCap: 1, dailyPicks: { 'unmeasured-pool': 1 } });
assert.notEqual(capped.pick.pool, 'unmeasured-pool');
assert.equal(capped.weights.at(-1).probability, 0);
assert.equal(capped.weights.at(-1).reason, 'unmeasured-daily-cap');
const newDay = weightedChoice([...candidates, unmeasured], { ...options, seed: 0xffffffff, unmeasuredDailyCap: 1, dailyPicks: {} });
assert.equal(newDay.pick.pool, 'unmeasured-pool');
const twoModels = weightedChoice([...candidates, unmeasured, { ...unmeasured, model: 'subscription/zz' }], options);
assert.ok(Math.abs(twoModels.weights.filter(row => row.pool === unmeasured.pool).reduce((n, row) => n + row.probability, 0) - 0.05) < 1e-12);
assert.equal(weightedChoice([unmeasured], options).pick, null);
assert.throws(() => weightedChoice([...candidates, unmeasured], { ...options, unmeasuredDailyCap: 0 }));
console.log('ok - quota, class quality, comparable time/cost, positive exploration, and uint32 draw are explicit and reproducible');
console.log('ok - unmeasured pools share a disclosed 5% exploration budget with per-pool daily caps and next-day re-admission');
