// CrewState — reconcile a task's current state.
// Reads the task's live backend state, the status-log tail, and pending
// steers, producing a single current-state record.

import type { TerminalBackend } from '../backend/types.js';
import { TaskMetaStore } from '../records/task-meta.js';
import { SteeringInbox } from '../records/steering-inbox.js';
import { ensureHomeDirs } from '../platform/home.js';

export interface CrewState {
  taskId: string;
  backend: string;
  endpoint: string;
  agent: Awaited<ReturnType<TerminalBackend['agentState']>>;
  lastEvents: string[];
  pendingSteers: number;
}

export class CrewStateService {
  constructor(
    private readonly backend: TerminalBackend,
    private readonly env: NodeJS.ProcessEnv,
  ) {}

  async state(taskId: string): Promise<CrewState> {
    const paths = await ensureHomeDirs(this.env);
    const store = new TaskMetaStore(paths.state);
    const meta = await store.read(taskId);
    if (!meta) throw new Error(`no task ${taskId}`);

    const agent = await this.backend.agentState(taskId);
    const events = await store.statusLog(taskId).tail(10);
    const inbox = new SteeringInbox(`${store.stateDir}/${taskId}.inbox`);
    const pending = await inbox.pending();

    return {
      taskId,
      backend: meta.backend,
      endpoint: meta.endpoint,
      agent,
      lastEvents: events.map((e) => `${e.state}: ${e.note}`),
      pendingSteers: pending.length,
    };
  }
}
