import { decide, synchronize } from '../core/routing.mjs';
import { latestPoolRecovery, withDailyCaps } from '../core/recovery.mjs';

export async function routeTask(request, { evidence, journal, telemetry }) {
  const context = await evidence.read(request);
  return journal.exclusive(async () => {
    const decisions = await journal.readDecisions();
    const previous = decisions.find(row => row.requestId === request.requestId);
    if (previous) {
      if (previous.briefSha256 !== context.stamp.briefSha256 || previous.policySha256 !== context.stamp.policySha256 || previous.task !== request.task || previous.taskClass !== request.class || previous.repo !== request.repo) throw new Error('request identity conflicts with its recorded decision');
      return previous;
    }
    const dailyPicks = {};
    for (const decision of decisions) {
      if (decision.recordedAt?.slice(0, 10) !== context.stamp.recordedAt.slice(0, 10) || !decision.model) continue;
      const weight = decision.selection?.weights?.find(row => row.model === decision.model && row.harness === decision.harness && row.effort === decision.effort);
      if (weight?.runway === 'unmeasured') dailyPicks[weight.pool] = (Object.hasOwn(dailyPicks, weight.pool) ? dailyPicks[weight.pool] : 0) + 1;
    }
    const result = decide({ ...context.input, taskClass: request.class, cards: await journal.readCards(), dailyPicks });
    const decision = { schemaVersion: 1, ...context.stamp, ...result, poolRecovery: withDailyCaps(context.stamp.poolRecovery || [], result, context.stamp.recordedAt) };
    telemetry.emit({ event: 'decision', decision: result, reasons: result.reasons, model: result.model, harness: result.harness, effort: result.effort, outcome: result.model ? 'accepted' : 'rejected', counters: { candidates: result.alternatives.length, refusals: result.alternatives.filter(row => row.eligibility === 'blocked').length }, evidencePath: 'data/tachikoma/decisions.jsonl' });
    await journal.appendDecision(decision);
    return decision;
  });
}

export async function learn({ journal, modelTelemetry, telemetry }, observedAt) {
  return journal.exclusive(async () => {
    const attempts = await modelTelemetry.readAttempts();
    const decisions = await journal.readDecisions();
    const pools = latestPoolRecovery(decisions);
    const cards = [...synchronize(attempts, decisions).values()].map(card => ({ ...card, pools: pools.filter(pool => pool.models.includes(card.model)) }));
    const receipt = { schemaVersion: 1, syncedAt: observedAt, pools, sealedAttempts: cards.reduce((n, card) => n + card.attempts, 0), models: cards.map(card => card.model), joinedDecisions: cards.reduce((n, card) => n + card.joinedDecisions, 0) };
    await journal.replaceCards(cards, receipt);
    telemetry.emit({ event: 'decision', decision: receipt, reasons: ['sealed-real-outcomes-only'], counters: { attempts: receipt.sealedAttempts, models: cards.length }, outcome: 'accepted', evidencePath: 'data/tachikoma/sync.json' });
    return receipt;
  });
}
