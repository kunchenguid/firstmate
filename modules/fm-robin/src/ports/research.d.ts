import type { MessagePort, MessageReceipt } from '../../../fm-state-reader/src/ports/messages.d.ts';
export type RetrievalName = 'fetch' | 'gh' | 'scrapling' | 'alphaxiv';
export interface RetrievalPort {
  fetch(url: string, options: { deadline: number; maxBytes: number }): Promise<string>;
}
export interface Source { id: number; url: string; adapter: RetrievalName; publisher: string; content: string; at: string }
export interface Draft { conclusions: { kind: 'observed' | 'inferred' | 'proposed'; statement: string; citations: { source: number; quote: string }[] }[]; unknowns: string[] }
export interface ReasonerPort {
  reason(input: { question: string; scope: string; sources: Source[] }, options: { deadline: number }): Promise<Draft>;
}
export interface Record { report: string; eventId: string; verdict: string; requester: string; receipt?: MessageReceipt; notified?: boolean }
export interface ResearchStore {
  load(id: string): Promise<Record | null>;
  save(id: string, record: Record): Promise<void>;
  finish(id: string, topic: string, markdown: string, result: { verdict: string; requester: string }): Promise<Record>;
  log(event: object): Promise<void>;
}
export interface EventPort { publish(id: string): Promise<void> }
export interface Clock { now(): number }
export interface ResearchPorts {
  messages: MessagePort;
  retrieval: { [name in RetrievalName]: RetrievalPort };
  reasoner: ReasonerPort;
  store: ResearchStore;
  events: EventPort;
  clock: Clock;
}
