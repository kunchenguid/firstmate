import { spawn } from "node:child_process";

let skipNextIdle = false;

function runGuard(root) {
  return new Promise((resolve) => {
    const child = spawn(`${root}/bin/fm-turnend-guard.sh`, {
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolve({ code: 0, stderr: "" }));
    child.on("close", (code) => resolve({ code: code ?? 0, stderr }));
    child.stdin.end('{"stop_hook_active":false}');
  });
}

export const FmPrimaryTurnendGuard = async ({ client, directory }) => ({
  event: async ({ event }) => {
    if (event.type !== "session.idle") return;

    if (skipNextIdle) {
      skipNextIdle = false;
      return;
    }

    const sessionID = event.properties?.sessionID;
    if (!sessionID) return;

    const result = await runGuard(directory);
    if (result.code !== 2) return;

    try {
      await client.session.promptAsync({
        path: { id: sessionID },
        body: {
          parts: [
            {
              type: "text",
              text:
                "TURN WOULD END BLIND - supervision is off. " +
                "Run bin/fm-watch-arm.sh as a background task before ending the turn.\n\n" +
                result.stderr,
            },
          ],
        },
      });
      skipNextIdle = true;
    } catch {
      skipNextIdle = false;
    }
  },
});
