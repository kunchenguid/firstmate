export interface FileRecord { text: string; at: number; truncated: boolean }
export interface StateFiles {
  taskIds(): string[];
  readonly pools: readonly string[];
  read(key: string): FileRecord | null;
  watch(changed: (error?: Error) => void): () => void;
}
