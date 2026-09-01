// TerminalBackend — the interface every session backend implements.
// Mirrors the dispatch arms of bin/fm-backend.sh: create, capture, send,
// kill, probe. The spawn/supervise layers talk only to this interface, so a
// new backend (conpty, tmux, herdr...) plugs in without touching the fleet.

export type AgentState = 'alive' | 'dead' | 'missing' | 'ambiguous' | 'unreadable';

export interface BackendCreateOptions {
  /** Task id. */
  taskId: string;
  /** Working directory for the session. */
  cwd: string;
  /** Command to run (e.g. the harness CLI). */
  command: string;
  /** Arguments to the command. */
  args: string[];
  /** Extra environment (merged over process.env). */
  env?: NodeJS.ProcessEnv;
  /** Number of scrollback lines to retain. */
  scrollback?: number;
}

export interface TerminalBackend {
  readonly name: string;

  /** Create a session and start the command. Returns the endpoint id. */
  create(opts: BackendCreateOptions): Promise<string>;

  /** Whether a session for the task still exists. */
  exists(taskId: string): Promise<boolean>;

  /** Capture the most recent N lines of the session. */
  capture(taskId: string, lines?: number): Promise<string>;

  /** Send literal text (no newline). */
  sendText(taskId: string, text: string): Promise<void>;

  /** Send text followed by Enter. */
  sendTextSubmit(taskId: string, text: string): Promise<void>;

  /** Send a control key (e.g. 'C-c'). */
  sendKey(taskId: string, key: string): Promise<void>;

  /** Get the session's current working directory, if known. */
  cwd(taskId: string): Promise<string | null>;

  /** Classify the session's foreground process (agent vs shell). */
  agentState(taskId: string): Promise<AgentState>;

  /** Kill the session and its process tree. */
  kill(taskId: string): Promise<void>;
}

/** A backend that can attach a live terminal for the captain. */
export interface AttachableBackend extends TerminalBackend {
  /** Attach to the session, bridging the local stdio to the remote terminal. */
  attach(taskId: string): Promise<number>;
}
