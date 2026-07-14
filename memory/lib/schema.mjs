import { z } from 'zod';

export const REGISTRY_SCHEMA = 'kraken-memory/registry-event/v1';
export const ACTIVITY_SCHEMA = 'kraken-memory/activity-event/v1';
export const STATUS = ['candidate', 'active', 'quarantined', 'superseded', 'retired', 'rejected'];
export const REGISTRY_EVENTS = ['proposed', 'activated', 'updated', 'superseded', 'retired', 'quarantined', 'revalidated', 'rejected'];

const actorSchema = z.object({
  kind: z.string().min(1),
  id: z.string().min(1).optional(),
  session: z.string().optional()
}).passthrough();

const evidenceSchema = z.object({
  type: z.string().min(1),
  ref: z.string().min(1),
  note: z.string().optional()
}).passthrough();

export const recordFieldsSchema = z.object({
  summary: z.string().min(1).max(240).optional(),
  body: z.string().optional(),
  source: z.object({ path: z.string(), anchor: z.string().optional() }).passthrough().optional(),
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
  validation: z.object({ method: z.string().min(1), by: z.string().optional(), ref: z.string().optional() }).passthrough().optional()
}).passthrough();

export const activityEventSchema = z.object({
  schema: z.literal(ACTIVITY_SCHEMA),
  eventId: z.string().min(1),
  ts: z.string().datetime(),
  event: z.string().min(1),
  actor: actorSchema.optional(),
  task: z.string().nullable().optional(),
  order: z.string().nullable().optional(),
  bug: z.string().nullable().optional(),
  detail: z.record(z.any()).default({})
}).passthrough();

export function validateRegistryEvent(event) {
  return registryEventSchema.parse(event);
}

export function validateActivityEvent(event) {
  return activityEventSchema.parse(event);
}
