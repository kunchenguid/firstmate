export interface ShortRequest {
  key: string; goal: string; acceptance: string; provider: string; model: string;
  materials: string[];
  budget?: { timeMs?: number; tools?: number; outputTokens?: number; requests?: number };
}
export interface ShortResult { id: string; state: string; evidence: string; summary?: string }
export class ShortAgents {
  constructor(home: string, root?: string);
  submit(request: ShortRequest, launch?: boolean): ShortResult;
  status(id: string): ShortResult;
  cancel(id: string): ShortResult;
  reconcile(): Promise<number>;
}
