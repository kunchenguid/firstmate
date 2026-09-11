export interface PullRequest { url: string; head: string; state: 'open' | 'closed'; created: string; merged: string | null; proof: boolean }
export interface StateSource {
  read(now: number): {
    now: number; beaconAt: number | null; beaconAge: number | null;
    wake: { count: number; truncated: boolean } | null;
    pools: { key: string; used?: number; capacity?: number }[];
    workers: { id: string; harness: string; model: string; effort: string; lines: string[]; last: string;
      age: number; changed: number | null; idleAt: number | null; busy: string; truncated: boolean }[];
  };
  watch(changed: (error?: Error) => void): () => void;
}
export interface Forge { read(repositories: string[]): Promise<PullRequest[]> }
export interface Journal {
  get(key: string): unknown;
  set(key: string, value: unknown): void;
  append(record: object): void;
  stats(now: number): Promise<object>;
  claim(): () => void;
}
export interface Publisher { publish(id: string): Promise<unknown>; captured(id: string): boolean }
export interface ReasoningRole { harness: string; model: string; effort: string; persona: string }
export interface Advisory { text: string; model: string | null; tokens: number | null; cost: number | null }
export interface Reasoner { read(role: ReasoningRole, packet: object): Promise<Advisory> }
export type { Message, MessagePort } from '../../../fm-state-reader/src/ports/messages.d.ts';
