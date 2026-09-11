// The dispatch profile supplies a reviewed prior; learning never changes a gate.
// Six prior observations damp small samples. Current model/CLI versions and
// task class must match exactly; unrelated history never silently fills a gap.
export function qualityForClass(card, candidate, taskClass, prior) {
  if (!Number.isFinite(prior) || prior < 0 || prior > 1) throw new Error('reviewed quality prior required');
  const result = { score: prior, prior, priorObservations: 6, source: 'profile-prior', observations: 0, acceptanceRate: null, relaunchRate: null, meanReviewFindings: null, meanWallSeconds: null, meanCost: null, currency: null };
  if (!candidate.modelVersion || !candidate.cliVersion) return result;
  const cells = Object.values(card?.classes || {}).filter(cell => cell.taskClass === taskClass && cell.harness === candidate.harness && cell.effort === candidate.effort && cell.modelVersion === candidate.modelVersion && cell.cliVersion === candidate.cliVersion && cell.quality?.attempts > 0);
  if (!cells.length) return result;
  const sum = field => cells.reduce((n, cell) => n + cell.quality[field], 0);
  const attempts = sum('attempts');
  result.observations = sum('independentTasks');
  if (!result.observations) return result;
  result.source = 'class-card';
  result.acceptanceRate = sum('accepted') / attempts;
  result.relaunchRate = sum('relaunches') / attempts;
  result.meanReviewFindings = sum('findingObservations') ? sum('findings') / sum('findingObservations') : null;
  result.meanWallSeconds = sum('wallObservations') ? sum('wallSeconds') / sum('wallObservations') : null;
  const costs = new Map();
  for (const cell of cells) for (const [currency, value] of Object.entries(cell.quality.costs)) {
    const total = costs.get(currency) || { observations: 0, total: 0 };
    total.observations += value.observations; total.total += value.total; costs.set(currency, total);
  }
  if (costs.size === 1) {
    const [currency, cost] = [...costs][0];
    if (cost.observations) { result.currency = currency; result.meanCost = cost.total / cost.observations; }
  }
  const measured = result.acceptanceRate * (1 - result.relaunchRate) / (1 + (result.meanReviewFindings ?? 0));
  result.score = (6 * prior + result.observations * measured) / (6 + result.observations);
  return result;
}
