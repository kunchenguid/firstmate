import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const adapterRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

// Cross-language adapter only. bin/fm-operational-input.sh owns the protocol,
// accepted kinds, marker bytes, and serialization grammar.
export function encodeFirstmateOperationalInput(root, kind, content) {
  return new Promise((resolveResult, reject) => {
    const requested = `${root}/bin/fm-operational-input.sh`;
    const script = existsSync(requested)
      ? requested
      : `${adapterRoot}/bin/fm-operational-input.sh`;
    // Windows has no shebang: CreateProcess cannot execute a .sh at all, so a
    // direct spawn fails there and the encoder would be dead on that platform.
    // Every script reached this way declares `#!/usr/bin/env bash`, and bash
    // reports the same $0 and BASH_SOURCE[0] either way.
    const invocation = process.platform === "win32"
      ? { command: "bash", args: [script, "encode", kind] }
      : { command: script, args: ["encode", kind] };
    const child = spawn(invocation.command, invocation.args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0 && stdout) {
        resolveResult(stdout);
        return;
      }
      reject(new Error(stderr.trim() || `operational-input encoder exited ${code ?? "unknown"}`));
    });
    child.stdin.end(content);
  });
}
