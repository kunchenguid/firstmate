// Host-owned extension deadlines. A callback over two seconds late gets one
// second to drain work frozen with the host. Ordinary stalls keep their bound,
// and a second suspension cannot renew the grace.
import { performance } from "node:perf_hooks";

const LATE_SLACK_MS = 2000;
const RESUME_GRACE_MS = 1000;

export class ExtensionDeadline {
  constructor(bound, timeoutMs, operation) {
    this.bound = bound;
    this.timeoutMs = timeoutMs;
    this.operation = operation;
    this.started = performance.now();
    this.due = this.started + timeoutMs;
    this.graceMs = 0;
    this.timer = null;
  }

  expired() {
    const now = performance.now();
    if (now < this.due) return false;
    if (!this.graceMs && now - this.due > LATE_SLACK_MS) {
      this.graceMs = RESUME_GRACE_MS;
      this.due = now + RESUME_GRACE_MS;
      return false;
    }
    return true;
  }

  arm(onTimeout) {
    const check = () => {
      if (this.expired()) onTimeout(this.evidence());
      else this.timer = setTimeout(check, Math.max(1, this.due - performance.now()));
    };
    this.timer = setTimeout(check, this.timeoutMs);
    return this;
  }

  cancel() {
    clearTimeout(this.timer);
  }

  evidence() {
    const elapsedMs = Math.max(0, Math.floor(performance.now() - this.started));
    return {
      bound: this.bound,
      operation: this.operation,
      timeout_ms: this.timeoutMs,
      elapsed_ms: elapsedMs,
      overrun_ms: Math.max(0, elapsedMs - this.timeoutMs),
      grace_ms: this.graceMs,
    };
  }
}
