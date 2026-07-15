import crypto from 'node:crypto';
import { appendActivity } from './activity.mjs';

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

// General task identifier schema for durable governance activity: printable
// token, no whitespace/path separators, max 128 chars. KrakenLoop task slugs
// such as `memory-pr1-fix-f3` are a subset of this format.
export function normalizeRiskOverrideTaskId(taskId) {
  if (typeof taskId !== 'string') return null;
  const trimmed = taskId.trim();
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(trimmed)) return null;
  return trimmed;
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
  const error = new Error('riskClass downgrade refused: durable Captain override log required');
  error.code = 'RISK_DOWNGRADE_LOG_REQUIRED';
  error.detail = classification;
  throw error;
}

export async function enforceRiskRequestDurably(requested, classification, options = {}) {
  if (!requested) return classification;
  if (!RISK_ORDER.includes(requested)) throw new Error(`unknown requested riskClass: ${requested}`);
  const minimum = classification.riskClass;
  if (rank(requested) >= rank(minimum)) return enforceRiskRequest(requested, classification, options);
  if (!options.captainOverrideToken) {
    const error = new Error(`riskClass downgrade refused: requested ${requested}, minimum ${minimum}`);
    error.code = 'RISK_DOWNGRADE_REFUSED';
    error.detail = classification;
    throw error;
  }
  if (!options.activityDir) {
    const error = new Error('riskClass downgrade refused: activityDir required for durable Captain override log');
    error.code = 'RISK_DOWNGRADE_LOG_REQUIRED';
    error.detail = classification;
    throw error;
  }
  const taskId = normalizeRiskOverrideTaskId(options.taskId);
  if (!taskId) {
    const error = new Error('riskClass downgrade refused: valid taskId required for durable Captain override log');
    error.code = 'RISK_DOWNGRADE_TASK_REQUIRED';
    error.detail = classification;
    throw error;
  }
  const ref = overrideReference(options.captainOverrideToken);
  let event;
  try {
    const append = options.appendActivityFn || appendActivity;
    event = await append(options.activityDir, {
      event: 'risk_override',
      actor: options.actor || { kind: 'captain', id: options.captainId || 'captain' },
      task: taskId,
      detail: {
        ruleVersion: classification.ruleVersion,
        computedMinimum: minimum,
        requestedRisk: requested,
        appliedRisk: requested,
        matchedRiskRuleIds: classification.matchedRules || [],
        reason: options.reason || 'captain-authorized downgrade',
        captainAuthorization: ref,
        target: {
          repository: options.repository || classification.metadata?.repository || null,
          paths: Array.isArray(classification.metadata?.paths) ? classification.metadata.paths : [],
          pathsHash: crypto.createHash('sha256').update(JSON.stringify(classification.metadata?.paths || [])).digest('hex')
        },
        outcome: 'applied'
      }
    });
  } catch (cause) {
    const error = new Error(`riskClass downgrade refused: failed to persist Captain override (${cause.message})`);
    error.code = 'RISK_DOWNGRADE_LOG_FAILED';
    error.cause = cause;
    error.detail = classification;
    throw error;
  }
  const override = {
    ref,
    captainAuthorization: ref,
    eventId: event.eventId,
    computedMinimum: minimum,
    appliedClass: requested,
    reason: options.reason || 'captain-authorized downgrade',
    recordedAt: event.ts
  };
  return {
    ...classification,
    riskClass: requested,
    computedMinimum: minimum,
    appliedClass: requested,
    override
  };
}
