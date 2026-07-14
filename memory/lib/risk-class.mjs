export const RISK_CLASS_RULE_VERSION = 'risk-rules/v1';
export const RISK_ORDER = ['low', 'standard', 'high', 'critical'];

export const RISK_RULES = [
  { id: 'read-only-scout', minimum: 'low', when: (m) => m.kind === 'scout' && m.readOnly === true },
  { id: 'normal-isolated-implementation', minimum: 'standard', when: (m) => m.kind === 'ship' || m.isolatedImplementation === true },
  { id: 'shared-runtime-or-orchestration', minimum: 'high', when: (m) => flag(m, 'sharedRuntime') || flag(m, 'orchestration') || pathHit(m, /^(bin|AGENTS\.md|\.agents\/skills|\.github\/workflows|CONTRIBUTING\.md|README\.md|\.tasks\.toml)(\/|$)/) },
  { id: 'destructive-cleanup', minimum: 'high', when: (m) => flag(m, 'destructive') || flag(m, 'cleanupDestructive') },
  { id: 'canonical-state-migration', minimum: 'critical', when: (m) => flag(m, 'migration') || flag(m, 'canonicalStateMigration') },
  { id: 'memory-registry-writer-schema-activation', minimum: 'critical', when: (m) => flag(m, 'memoryRegistry') || flag(m, 'memoryWriter') || flag(m, 'memorySchema') || flag(m, 'activationPolicy') || pathHit(m, /^memory\/(lib|bin|schemas|test).*registry|^memory\/lib\/schema|^memory\//) },
  { id: 'branch-history-rewrite', minimum: 'critical', when: (m) => flag(m, 'historyRewrite') || flag(m, 'forcePush') || flag(m, 'rebaseShared') },
  { id: 'landing-merge-governance', minimum: 'critical', when: (m) => ['landing', 'merge', 'governance'].includes(m.kind) || flag(m, 'landing') || flag(m, 'mergeGovernance') },
  { id: 'qa-signoff-governance-enforcement', minimum: 'critical', when: (m) => m.kind === 'qa' || flag(m, 'qaSignoff') || flag(m, 'governanceEnforcement') },
  { id: 'credential-permission-production', minimum: 'critical', when: (m) => flag(m, 'credential') || flag(m, 'permission') || flag(m, 'productionEnvironment') },
  { id: 'missing-classification-default', minimum: 'critical', when: (m) => !m || Object.keys(m).length === 0 || m.inspected === false },
  { id: 'unrecognized-operation-flag', minimum: 'critical', when: (m) => hasUnknownFlags(m) }
];

const knownFlags = new Set([
  'sharedRuntime', 'orchestration', 'destructive', 'cleanupDestructive', 'migration',
  'canonicalStateMigration', 'memoryRegistry', 'memoryWriter', 'memorySchema',
  'activationPolicy', 'historyRewrite', 'forcePush', 'rebaseShared', 'landing',
  'mergeGovernance', 'qaSignoff', 'governanceEnforcement', 'credential', 'permission',
  'productionEnvironment'
]);

function flag(metadata, name) {
  return metadata?.operationFlags?.[name] === true || metadata?.[name] === true;
}

function hasUnknownFlags(metadata) {
  if (!metadata?.operationFlags) return false;
  return Object.keys(metadata.operationFlags).some((key) => !knownFlags.has(key));
}

function pathHit(metadata, regex) {
  return (metadata?.paths || []).some((p) => regex.test(String(p)));
}

function rank(riskClass) {
  return RISK_ORDER.indexOf(riskClass);
}

export function classifyRisk(metadata = {}) {
  const matched = RISK_RULES.filter((rule) => rule.when(metadata));
  const effective = matched.length > 0 ? matched : [{ id: 'ambiguous-default', minimum: 'critical' }];
  const highest = effective.reduce((best, rule) => rank(rule.minimum) > rank(best.minimum) ? rule : best, effective[0]);
  return {
    riskClass: highest.minimum,
    ruleVersion: RISK_CLASS_RULE_VERSION,
    matchedRules: effective.map((rule) => rule.id),
    reason: 'highest applicable minimum',
    metadata
  };
}

export function enforceRiskRequest(requested, classification, options = {}) {
  if (!requested) return classification;
  if (!RISK_ORDER.includes(requested)) throw new Error(`unknown requested riskClass: ${requested}`);
  if (rank(requested) < rank(classification.riskClass) && !options.captainOverrideToken) {
    const error = new Error(`riskClass downgrade refused: requested ${requested}, minimum ${classification.riskClass}`);
    error.code = 'RISK_DOWNGRADE_REFUSED';
    error.detail = classification;
    throw error;
  }
  return {
    ...classification,
    riskClass: rank(requested) > rank(classification.riskClass) ? requested : classification.riskClass,
    override: rank(requested) < rank(classification.riskClass) ? { captainOverrideToken: options.captainOverrideToken } : null
  };
}
