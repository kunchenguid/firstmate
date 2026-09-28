export interface ShortRequest {
  key: string; goal: string; acceptance: string; provider?: string; model?: string;
  materials: string[];
  operations?: { expiresAt: number; authority: string; steps: (
    { action: 'sync' | 'recover-sync'; project: string } |
    { action: 'install-shellcheck'; destination: string } |
    { action: 'merge'; task: string; url: string } |
    { action: 'cleanup'; task: string }
  )[] };
}
export interface ShortResult { id: string; state: string; evidence: string; summary?: string }
export class ShortAgents {
  constructor(home: string, root?: string);
  submit(request: ShortRequest, launch?: boolean): ShortResult;
  status(id: string): ShortResult;
  cancel(id: string): ShortResult;
  reconcile(): Promise<number>;
}
