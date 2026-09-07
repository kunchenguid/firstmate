import { spawn } from "node:child_process";

// Pi runs extensions, their tools, and their event handlers on the single
// JavaScript thread that also draws the TUI and reads the keyboard, and it
// starts no worker for them. A spawnSync call from an extension therefore
// stops repaint and key echo for the child's whole lifetime, which a
// supervision outcome made visible as a subsecond freeze every time one
// arrived (docs/pi-supervision-branch.md "Off-thread delivery").
//
// This is the one owner of that replacement: the status, UTF-8 stdout, and
// UTF-8 stderr fields these callers consumed from spawnSync, produced by an
// awaited spawn so the event loop keeps running while the child does. Callers
// keep their own ordering guarantees - awaiting here
// yields the thread, so anything that must not interleave belongs behind a
// serializing queue in the caller.
//
// Like spawnSync, a spawn that never starts and a child killed by a signal
// both report a null status rather than throwing, so a caller's existing
// "status !== 0" failure branch keeps its meaning unchanged.

export interface AsyncExecResult {
  /** Exit code, or null when the child was signalled or never started. */
  status: number | null;
  stdout: string;
  stderr: string;
}

export interface AsyncExecOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  /** Written to the child's stdin, which is closed either way. */
  input?: string;
  /**
   * Upper bound on each captured output stream, mirroring spawnSync's
   * maxBuffer. Defaults to 1 MiB.
   */
  maxBuffer?: number;
  /**
   * Kill the child after this many milliseconds and resolve a null status -
   * the same answer a signalled child already reports - so a stalled child
   * can never hold a caller's await open forever. The caller still sees the
   * child's partial output. Unset means unbounded, the historical behavior.
   */
  timeoutMs?: number;
}

const DEFAULT_MAX_BUFFER = 1024 * 1024;

export function runCommandAsync(
  command: string,
  args: readonly string[],
  options: AsyncExecOptions = {},
): Promise<AsyncExecResult> {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let stdoutBytes = 0;
    let stderrBytes = 0;
    const maxBuffer = options.maxBuffer ?? DEFAULT_MAX_BUFFER;
    let settled = false;
    let timeout: ReturnType<typeof setTimeout> | null = null;
    const finish = (status: number | null, detail = ""): void => {
      if (settled) return;
      settled = true;
      if (timeout) clearTimeout(timeout);
      resolve({ status, stdout, stderr: detail ? `${stderr}${detail}` : stderr });
    };
    let child;
    try {
      child = spawn(command, [...args], {
        cwd: options.cwd,
        env: options.env,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      finish(null, error instanceof Error ? error.message : String(error));
      return;
    }
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      if (settled) return;
      const bytes = Buffer.byteLength(chunk, "utf8");
      if (stdoutBytes + bytes > maxBuffer) {
        child.kill();
        finish(null, `stdout exceeded ${maxBuffer} bytes`);
        return;
      }
      stdout += chunk;
      stdoutBytes += bytes;
    });
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk: string) => {
      if (settled) return;
      const bytes = Buffer.byteLength(chunk, "utf8");
      if (stderrBytes + bytes > maxBuffer) {
        child.kill();
        finish(null, `stderr exceeded ${maxBuffer} bytes`);
        return;
      }
      stderr += chunk;
      stderrBytes += bytes;
    });
    // "close" rather than "exit": it fires once the captured stdio streams are
    // drained, so no output is lost the way an early "exit" would lose it.
    child.on("close", (code) => finish(code));
    child.on("error", (error: Error) => finish(null, error.message));
    if (options.timeoutMs !== undefined) {
      timeout = setTimeout(() => {
        child.kill();
        finish(null, `timed out after ${options.timeoutMs}ms`);
      }, options.timeoutMs);
      // Killing a stalled child on exit must not keep the host process alive
      // just to do it.
      timeout.unref();
    }
    if (child.stdin) {
      // A child that exits before reading stdin makes the write fail with
      // EPIPE, which is its answer, not this helper's failure.
      child.stdin.on("error", () => {});
      child.stdin.end(options.input ?? "");
    }
  });
}
