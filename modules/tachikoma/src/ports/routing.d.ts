import type { decide, synchronize } from '../core/routing.mjs';

export interface Request {
  task?: string; class?: string; repo?: string; brief?: string; snapshot?: string;
  seed?: number; requestId: string; threadId?: string; requireEnabled?: boolean;
}
export type Decision = ReturnType<typeof decide> & {
  schemaVersion: 1; decisionId: string; recordedAt: string; requestId: string;
  task: string; taskClass: string; repo: string; briefSha256: string; policySha256: string;
};
export interface RoutingEvidence {
  read(request: Request): Promise<{ input: Parameters<typeof decide>[0]; stamp: Omit<Decision, keyof ReturnType<typeof decide>> }>;
}
export interface ModelTelemetry {
  readAttempts(): Promise<Parameters<typeof synchronize>[0]>;
}
export interface RoutingJournal {
  exclusive<T>(work: () => Promise<T>): Promise<T>;
  readDecisions(): Promise<Decision[]>;
  readCards(): Promise<object[]>;
  appendDecision(decision: Decision): Promise<void>;
  replaceCards(cards: object[], receipt: object): Promise<void>;
}
export interface ServiceTelemetry {
  emit(event: object): void;
  readDay(day: string): object[];
}
