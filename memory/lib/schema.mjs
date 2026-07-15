import { z } from 'zod';

export const REGISTRY_SCHEMA = 'kraken-memory/registry-event/v1';
export const ACTIVITY_SCHEMA = 'kraken-memory/activity-event/v1';
export const ACTIVITY_MANIFEST_SCHEMA = 'kraken-memory/activity-manifest/v1';
export const ACTIVE_INDEX_SCHEMA = 'kraken-memory/active-index/v1';
export const STATUS = ['candidate', 'active', 'quarantined', 'superseded', 'retired', 'rejected'];
export const REGISTRY_EVENTS = ['proposed', 'activated', 'updated', 'superseded', 'retired', 'quarantined', 'revalidated', 'rejected'];
export const MEMORY_TYPES = ['factual', 'procedural'];

const actorSchema = z.object({
  kind: z.string().min(1),
  id: z.string().min(1).optional(),
  session: z.string().optional()
}).passthrough();

const taskIdSchema = z.string().trim().regex(/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/);

const evidenceSchema = z.object({
  type: z.string().min(1),
  ref: z.string().min(1),
  note: z.string().optional()
}).passthrough();

export const recordFieldsSchema = z.object({
  summary: z.string().min(1).max(240).optional(),
  body: z.string().optional(),
  source: z.object({ path: z.string(), anchor: z.string().optional() }).passthrough().optional(),
  memoryType: z.enum(MEMORY_TYPES).optional(),
  scope: z.enum(['fleet', 'project', 'captain', 'environment']).optional(),
  projects: z.array(z.string()).optional(),
  taskKinds: z.array(z.string()).optional(),
  keywords: z.array(z.string()).optional(),
  aliases: z.array(z.string()).optional(),
  entities: z.array(z.string()).optional(),
  commands: z.array(z.string()).optional(),
  failureModes: z.array(z.string()).optional(),
  relatedTerms: z.array(z.string()).optional(),
  validFrom: z.string().optional(),
  validTo: z.string().nullable().optional(),
  confidence: z.enum(['unverified', 'observed', 'reproduced', 'guarded']).optional(),
  contradicts: z.array(z.string()).optional(),
  guard: z.object({ type: z.string(), ref: z.string() }).passthrough().optional(),
  guard_linked: z.boolean().optional(),
  riskClass: z.enum(['low', 'standard', 'high', 'critical']).optional()
}).passthrough();

export const registryEventSchema = z.object({
  schema: z.literal(REGISTRY_SCHEMA),
  eventId: z.string().min(1),
  ts: z.string().datetime(),
  event: z.enum(REGISTRY_EVENTS),
  memId: z.string().regex(/^MEM-\d{4,}$/),
  actor: actorSchema,
  fields: recordFieldsSchema.optional(),
  evidence: z.array(evidenceSchema).default([]),
  reason: z.string().optional(),
  supersedes: z.array(z.string()).optional(),
  successor: z.string().optional(),
  guard_linked: z.boolean().optional(),
  validation: z.object({ method: z.string().min(1), by: z.string().optional(), ref: z.string().optional() }).passthrough().optional()
}).passthrough().superRefine((event, ctx) => {
  // Event-specific structural validation: reject invalid or incomplete rows so a
  // malformed governance event can never fold into canonical state.
  const require = (cond, path, message) => {
    if (!cond) ctx.addIssue({ code: z.ZodIssueCode.custom, path, message });
  };
  if (event.event === 'proposed') {
    require(Boolean(event.fields?.summary), ['fields', 'summary'], 'proposed event requires fields.summary');
  }
  if (event.event === 'activated' || event.event === 'revalidated') {
    require((event.evidence?.length ?? 0) > 0, ['evidence'], `${event.event} event requires at least one evidence entry`);
    require(Boolean(event.validation?.method), ['validation', 'method'], `${event.event} event requires validation.method`);
  }
  if (event.event === 'superseded') {
    require(Boolean(event.successor), ['successor'], 'superseded event requires a successor');
  }
  if (event.event === 'updated') {
    const hasFields = event.fields && Object.keys(event.fields).length > 0;
    const hasEvidence = (event.evidence?.length ?? 0) > 0;
    require(Boolean(hasFields || hasEvidence), ['fields'], 'updated event requires at least one field or evidence entry to change');
  }
});

export const activityEventSchema = z.object({
  schema: z.literal(ACTIVITY_SCHEMA),
  schemaVersion: z.number().int(),
  eventId: z.string().min(1),
  ts: z.string().datetime(),
  event: z.string().min(1),
  actor: actorSchema,
  task: z.string().nullable().optional(),
  order: z.string().nullable().optional(),
  bug: z.string().nullable().optional(),
  detail: z.record(z.any()).default({})
}).passthrough().superRefine((event, ctx) => {
  const require = (cond, path, message) => {
    if (!cond) ctx.addIssue({ code: z.ZodIssueCode.custom, path, message });
  };
  if (event.schemaVersion !== 1) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['schemaVersion'], message: 'unsupported activity schemaVersion' });
  }
  if (event.event === 'registry_recovered') {
    for (const key of ['originalHash', 'sidecarHash', 'repairedHash', 'backup', 'sidecar', 'lastValidPreRecoveryWatermark', 'postRecoveryWatermark']) {
      require(event.detail?.[key] !== undefined, ['detail', key], `registry_recovered requires detail.${key}`);
    }
  }
  if (event.event === 'risk_override') {
    require(typeof event.task === 'string' && taskIdSchema.safeParse(event.task).success, ['task'], 'risk_override requires a valid task');
    for (const key of ['computedMinimum', 'requestedRisk', 'appliedRisk', 'matchedRiskRuleIds', 'reason', 'captainAuthorization', 'outcome']) {
      require(event.detail?.[key] !== undefined, ['detail', key], `risk_override requires detail.${key}`);
    }
  }
});

export function validateRegistryEvent(event) {
  return registryEventSchema.parse(event);
}

export function validateActivityEvent(event) {
  return activityEventSchema.parse(event);
}
