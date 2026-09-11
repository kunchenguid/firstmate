export interface QuotaSource { read(pools: PoolConfig[]): Promise<unknown[]> }
export interface Clock { now(): number; sleep(ms: number): Promise<void> }
export interface Renderer { render(frame: unknown): void }
export interface Telemetry { append(event: string, details?: object): void; read(since: number, event?: 'sample' | 'all'): object[] }
export interface PoolConfig {
  id: string; provider: string; label?: string; expectedEmail?: string; credentialSource?: string;
  env?: { CODEX_HOME?: string; CLAUDE_CONFIG_DIR?: string };
  windows?: Record<string, number>;
}
