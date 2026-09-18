/**
 * Resolve answers.rule confidence for the Gateway evaluate helper.
 *
 * Preference order (never the global max across options):
 * 1. answer.confidence when finite
 * 2. providerMetadata.typesafe.confidence (object.rule or bare number) when finite
 * 3. probabilities[answer.choice] when finite
 * 4. otherwise null (caller fails)
 */
export function resolveRuleConfidence(answer, providerMetadata) {
  if (answer && typeof answer.confidence === 'number' && Number.isFinite(answer.confidence)) {
    return answer.confidence;
  }

  const metaConfidence = providerMetadata?.typesafe?.confidence;
  if (
    metaConfidence &&
    typeof metaConfidence === 'object' &&
    typeof metaConfidence.rule === 'number' &&
    Number.isFinite(metaConfidence.rule)
  ) {
    return metaConfidence.rule;
  }
  if (typeof metaConfidence === 'number' && Number.isFinite(metaConfidence)) {
    return metaConfidence;
  }

  const choice = answer?.choice;
  const probabilities = answer?.probabilities;
  if (
    typeof choice === 'string' &&
    probabilities &&
    typeof probabilities === 'object' &&
    !Array.isArray(probabilities)
  ) {
    const mass = probabilities[choice];
    if (typeof mass === 'number' && Number.isFinite(mass)) {
      return mass;
    }
  }

  return null;
}
