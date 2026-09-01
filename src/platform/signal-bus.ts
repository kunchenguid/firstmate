// SignalBus — portable signal handling.
// POSIX uses SIGINT/SIGTERM; Windows lacks SIGTERM delivery, so we rely on
// Ctrl-C (SIGINT) and an explicit shutdown() path. Supervision itself is
// polling + file-based, so signals are a thin courtesy layer.

type Handler = () => void | Promise<void>;

export class SignalBus {
  private handlers: Handler[] = [];
  private readonly boundSigint: () => void;
  private readonly boundSigterm: () => void;

  constructor() {
    this.boundSigint = () => void this.trigger();
    this.boundSigterm = () => void this.trigger();
    process.on('SIGINT', this.boundSigint);
    process.on('SIGTERM', this.boundSigterm);
  }

  /** Register a shutdown handler; returns an unsubscribe function. */
  onShutdown(handler: Handler): () => void {
    this.handlers.push(handler);
    return () => {
      this.handlers = this.handlers.filter((h) => h !== handler);
    };
  }

  async trigger(): Promise<void> {
    // Run handlers once; duplicate signals are ignored while running.
    if (this.triggering) return;
    this.triggering = true;
    try {
      await Promise.all(this.handlers.map((h) => h()));
    } finally {
      this.triggering = false;
    }
  }

  dispose(): void {
    process.off('SIGINT', this.boundSigint);
    process.off('SIGTERM', this.boundSigterm);
  }

  private triggering = false;
}
