// Pure domain rules. Inputs are snapshots; no filesystem, clock, or process I/O.
import { qualityForClass } from './quality.mjs';
import { weightedChoice } from './weights.mjs';
export const tupleKey = value => JSON.stringify([value.harness, value.model, value.effort ?? null, value.accountProfile ?? null]);
const number = value => typeof value === 'number' && Number.isFinite(value);

export function decide({ policy, rule, candidates, snapshot, machine, cooldowns, repo, taskClass, cards = [], seed, dailyPicks = {} }) {
  const assessments = candidates.map(candidate => {
    const b = policy.bindings.find(binding => tupleKey(binding) === tupleKey(candidate));
    const reasons = [`pool:${b.pool}`, `rule:${rule.matchedRule}`];
    const uncertainties = [];
    let blocked = false;
    const reject = reason => { blocked = true; reasons.push(reason); };
    if (!policy.allowedHarnesses.includes(b.harness)) reject('adapter-disabled');
    if (policy.disabledPools.includes(b.pool)) reject('pool-disabled');
    if ((rule.strongestOnly || repo.toLowerCase() === 'artemis') && !b.strongest) reject('strongest-class-required');
    if (cooldowns[tupleKey(b)]) reject('cooldown-active');
    const applicable = snapshot.quota.filter(q => q.provider === b.quotaProvider && (['all_models', 'all_products'].includes(q.scope) || b.quotaScopes.includes(q.scope)));
    if (!applicable.length || b.quotaScopes.some(scope => !applicable.some(q => q.scope === scope))) uncertainties.push('quota-scope-unknown');
    for (const q of applicable) {
      if (!number(q.effectivePercentRemaining)) uncertainties.push('quota-headroom-unknown');
      else if (q.effectivePercentRemaining <= 0) reject('quota-exhausted');
      const runway = snapshot.exhaustion.find(row => row.provider === q.provider && row.scope === q.scope)?.usableRunwaySeconds;
      if (q.runway === 'exhausted_now') reject('runway-exhausted');
      else if (q.runway === 'projected_exhaustion' && number(runway)) {
        if (runway - snapshot.ageSeconds < rule.horizonSeconds) reject('runway-insufficient');
      } else if (q.runway !== 'through_reset') uncertainties.push('runway-unknown');
      if (!number(q.spendPriority)) uncertainties.push('spend-priority-unknown');
    }
    if (machine.loadAverage1m / machine.logicalCpuCount > policy.maxLoadPerCpu) reject('machine-overloaded');
    const priority = applicable.length && applicable.every(q => number(q.spendPriority)) ? Math.min(...applicable.map(q => q.spendPriority)) : null;
    reasons.push(...uncertainties, `spendPriority:${priority ?? 'unknown'}`, `horizonSeconds:${rule.horizonSeconds}`);
    return { harness: b.harness, model: b.model, effort: b.effort, pool: b.pool, provider: b.provider ?? b.quotaProvider, accountProfile: b.accountProfile ?? null, modelFamily: b.modelFamily, eligibility: blocked ? 'blocked' : 'eligible', feasibility: blocked ? 'failed' : uncertainties.length ? 'unproven' : 'proven', uncertainties, spendPriority: priority, reasons };
  });
  if (rule.selectionStrategy === 'quota-weighted') {
    const eligible = assessments.filter(a => a.eligibility === 'eligible').map(a => {
      const binding = policy.bindings.find(b => tupleKey(b) === tupleKey(a));
      return { ...a, quality: qualityForClass(cards.find(card => card.model === a.model), { ...a, modelVersion: binding.modelVersion, cliVersion: binding.cliVersion }, taskClass, binding.qualityPrior) };
    });
    const selection = weightedChoice(eligible, { seed, explorationRate: policy.explorationRate, unmeasuredRate: policy.unmeasuredRate, unmeasuredDailyCap: policy.unmeasuredDailyCap, dailyPicks });
    const { pick, ...trace } = selection;
    return { harness: pick?.harness ?? null, model: pick?.model ?? null, effort: pick?.effort ?? null, provider: pick?.provider ?? null, modelFamily: pick?.modelFamily ?? null, pool: pick?.pool ?? null, accountProfile: pick?.accountProfile ?? null, reasons: pick ? [...pick.reasons, 'quality-quota-cost-weighted-exploration'] : [selection.reason || 'no-provable-candidate'], confidence: pick ? 'weighted-policy' : 'unresolved', alternatives: assessments, selection: trace };
  }
  const viable = assessments.filter(a => a.eligibility === 'eligible' && a.feasibility === 'proven').sort((a, b) => b.spendPriority - a.spendPriority);
  const tied = viable.length > 1 && viable[0].spendPriority === viable[1].spendPriority;
  const pick = tied ? null : viable[0];
  return { harness: pick?.harness ?? null, model: pick?.model ?? null, effort: pick?.effort ?? null, provider: pick?.provider ?? null, modelFamily: pick?.modelFamily ?? null, pool: pick?.pool ?? null, accountProfile: pick?.accountProfile ?? null, reasons: pick?.reasons ?? [tied ? 'spend-priority-tie' : 'no-provable-candidate'], confidence: pick ? 'deterministic-policy' : 'unresolved', alternatives: assessments };
}

export function synchronize(attempts, decisions) {
  const cards = new Map();
  const roots = new Map();
  const relaunched = new Set(attempts.map(attempt => attempt.parentAttemptId).filter(Boolean));
  for (const attempt of attempts) {
    if (attempt.recordType !== 'attempt' || attempt.state !== 'terminal' || attempt.attemptClass !== 'real' || !attempt.model) continue;
    // Exact decision identity for new dispatches. Pre-router observations are
    // still useful history, but never attributed by task name or time guesses.
    const decision = decisions.find(d => d.decisionId === attempt.tachikomaDecision && tupleKey(d) === tupleKey(attempt));
    let card = cards.get(attempt.model);
    if (!card) { card = { schemaVersion: 1, model: attempt.model, classes: {}, attempts: 0, joinedDecisions: 0, lastSeenFailure: null }; cards.set(attempt.model, card); }
    card.attempts++; if (decision) card.joinedDecisions++;
    const key = JSON.stringify([attempt.taskClass, attempt.harness, attempt.effort, attempt.modelVersion, attempt.cliVersion]);
    const cell = card.classes[key] ||= { taskClass: attempt.taskClass, harness: attempt.harness, effort: attempt.effort, modelVersion: attempt.modelVersion, cliVersion: attempt.cliVersion, attempts: 0, accepted: 0, relaunches: 0, wallObservations: 0, wallTotal: 0, costByCurrency: {} };
    cell.attempts++; cell.accepted += Number(attempt.classification === 'accepted'); cell.relaunches += Number(Boolean(attempt.parentAttemptId));
    const quality = cell.quality ||= { attempts: 0, independentTasks: 0, accepted: 0, relaunches: 0, wallObservations: 0, wallSeconds: 0, findingObservations: 0, findings: 0, costs: {} };
    const modelOutcome = attempt.classification === 'accepted' || (['failed', 'rejected', 'refused', 'timed-out'].includes(attempt.classification) && ['none', 'capability', 'refusal', 'timeout', 'unknown', 'outcome-observed-cause-unobserved'].includes(attempt.primaryFailureClass));
    if (modelOutcome) {
      const seen = roots.get(cell) || new Set();
      if (attempt.taskRootId) seen.add(attempt.taskRootId);
      roots.set(cell, seen); quality.independentTasks = seen.size;
      quality.attempts++; quality.accepted += Number(attempt.classification === 'accepted'); quality.relaunches += Number(relaunched.has(attempt.attemptId));
      if (number(attempt.wallSeconds)) { quality.wallObservations++; quality.wallSeconds += attempt.wallSeconds; }
      if (number(attempt.metrics?.reviewFindings)) { quality.findingObservations++; quality.findings += attempt.metrics.reviewFindings; }
      if (number(attempt.cost) && /^[A-Z]{3}$/.test(attempt.currency)) {
        const cost = quality.costs[attempt.currency] ||= { observations: 0, total: 0 };
        cost.observations++; cost.total += attempt.cost;
      }
    }
    if (number(attempt.wallSeconds)) { cell.wallObservations++; cell.wallTotal += attempt.wallSeconds; }
    if (number(attempt.cost) && attempt.currency) cell.costByCurrency[attempt.currency] = (cell.costByCurrency[attempt.currency] || 0) + attempt.cost;
    cell.successRate = cell.accepted / cell.attempts;
    cell.relaunchRate = cell.relaunches / cell.attempts;
    cell.meanWallSeconds = cell.wallObservations ? cell.wallTotal / cell.wallObservations : null;
    if (['failed', 'rejected', 'refused', 'timed-out', 'quota-stopped'].includes(attempt.classification) && (!card.lastSeenFailure || attempt.endedAt > card.lastSeenFailure.at)) card.lastSeenFailure = { at: attempt.endedAt, classification: attempt.classification, cause: attempt.primaryFailureClass };
  }
  return cards;
}
