import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

let skipNextTurnEnd = false;

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");

function runGuard(): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/fm-turnend-guard.sh`, {
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
    child.stdin.end('{"stop_hook_active":false}');
  });
}

export default function (pi: ExtensionAPI) {
  pi.on("turn_end", async () => {
    if (skipNextTurnEnd) {
      skipNextTurnEnd = false;
      return;
    }

    const result = await runGuard();
    if (result.code !== 2) return;

    try {
      pi.sendUserMessage(
        "TURN WOULD END BLIND - supervision is off. " +
          "Run bin/fm-watch-arm.sh as a background task before ending the turn.\n\n" +
          result.stderr,
        { deliverAs: "followUp" },
      );
      skipNextTurnEnd = true;
    } catch {
      skipNextTurnEnd = false;
    }
  });
}
