import crypto from 'node:crypto';

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
  { id: 'credential-permission-production', minimum: 'critical', when: (m) => flag(m, 'credential') || flag(m, 'permission') || flag(m, 'productionEnvironment') }
];

// Fail-safe escalators. These force `critical` whenever classification inputs are
// ambiguous, unverified, or incomplete - the risk floor must default UPWARD.
export const RISK_FAILSAFE_RULES = [
  { id: 'missing-metadata-default-critical', when: (m) => !m || Object.keys(m).length === 0 },
  { id: 'explicit-uninspected-default-critical', when: (m) => m.inspected === false },
  { id: 'unrecognized-operation-flag', when: (m) => hasUnknownFlags(m) },
  { id: 'target-paths-not-inspected', when: (m) => requiresInspection(m) && m.inspected !== true },
  { id: 'missing-or-empty-target-paths', when: (m) => requiresInspection(m) && m.inspected === true && (!Array.isArray(m.paths) || m.paths.length === 0) }
];

const knownFlags = new Set([
  'sharedRuntime', 'orchestration', 'destructive', 'cleanupDestructive', 'migration',
  'canonicalStateMigration', 'memoryRegistry', 'memoryWriter', 'memorySchema',
  'activationPolicy', 'historyRewrite', 'forcePush', 'rebaseShared', 'landing',
  'mergeGovernance', 'qaSignoff', 'governanceEnforcement', 'credential', 'permission',
  'productionEnvironment'
]);

// A pure read-only scout inspects nothing by design. Every other operation is
// expected to have inspected its target paths before a class is assigned.
function requiresInspection(metadata) {
  if (!metadata) return true;
  if (metadata.kind === 'scout' && metadata.readOnly === true) return false;
  return true;
}

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
  const failsafe = RISK_FAILSAFE_RULES.filter((rule) => rule.when(metadata)).map((rule) => ({ id: rule.id, minimum: 'critical' }));
  const effective = [...matched, ...failsafe];
  // No rule fired at all: ambiguous input defaults upward to critical.
  const pool = effective.length > 0 ? effective : [{ id: 'ambiguous-default', minimum: 'critical' }];
  const highest = pool.reduce((best, rule) => (rank(rule.minimum) > rank(best.minimum) ? rule : best), pool[0]);
  return {
    riskClass: highest.minimum,
    ruleVersion: RISK_CLASS_RULE_VERSION,
    matchedRules: pool.map((rule) => rule.id),
    reason: 'highest applicable minimum',
    metadata
  };
}

// One-way opaque reference derived from the captain override token. The raw token
// is never returned, stored, or logged - only this reference and the classification.
function overrideReference(token) {
  return `ovr-${crypto.createHash('sha256').update(String(token)).digest('hex').slice(0, 16)}`;
}

export function enforceRiskRequest(requested, classification, options = {}) {
  if (!requested) return classification;
  if (!RISK_ORDER.includes(requested)) throw new Error(`unknown requested riskClass: ${requested}`);
  const minimum = classification.riskClass;

  // Raising (or matching) the class needs no override.
  if (rank(requested) >= rank(minimum)) {
    const applied = rank(requested) > rank(minimum) ? requested : minimum;
    return { ...classification, riskClass: applied, computedMinimum: minimum, appliedClass: applied, override: null };
  }

  // Lowering below the computed minimum requires a logged Captain override.
  if (!options.captainOverrideToken) {
    const error = new Error(`riskClass downgrade refused: requested ${requested}, minimum ${minimum}`);
    error.code = 'RISK_DOWNGRADE_REFUSED';
    error.detail = classification;
    throw error;
  }
  const ref = overrideReference(options.captainOverrideToken);
  const override = {
    ref,
    captainAuthorization: ref,
    computedMinimum: minimum,
    appliedClass: requested,
    reason: options.reason || 'captain-authorized downgrade',
    recordedAt: options.recordedAt || null
  };
  return {
    ...classification,
    riskClass: requested,
    computedMinimum: minimum,
    appliedClass: requested,
    override
  };
}
