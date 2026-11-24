import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { cpSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const [pi, lab] = process.argv.slice(2);
const source = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const repo = join(lab, "repo"), agentDir = join(lab, "agent");
mkdirSync(join(repo, ".pi/extensions/lib"), { recursive: true });
mkdirSync(join(repo, "state"));
mkdirSync(join(repo, "config"));
mkdirSync(agentDir);
mkdirSync(join(lab, "home"));
for (const file of ["fm-primary-read-repetition.ts", "lib/fm-primary-read-repetition-policy.ts"])
  cpSync(join(source, ".pi/extensions", file), join(repo, ".pi/extensions", file));
writeFileSync(join(repo, "config/read-repetition.json"), '{"enabled":true}');
writeFileSync(join(repo, "probe.ts"), `
import { writeFileSync } from "node:fs";
import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import { Type } from "typebox";
export default function(pi) {
  let requests = 0, executions = 0;
  const save = () => writeFileSync(process.env.READ_GUARD_RECEIPT, JSON.stringify({ requests, executions }));
  const faux = createFauxCore({ api: "read-guard-probe-api", provider: "read-guard-probe",
    models: [{ id: "scripted", name: "Synthetic read guard probe", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32768, maxTokens: 128 }],
    tokenSize: { min: 1, max: 1 } });
  const calls = (n) => [...Array.from({ length: n }, (_, i) =>
    fauxAssistantMessage([fauxToolCall("bash", { command: "(cd /fixture\\necho counts\\nsed -n '1,20p' fixture | wc -l\\nsed -n '1,20p' fixture | head -c 500 | tail -c 80 | od -An -tx1c\\n)" }, { id: "call-" + requests + "-" + i })], { stopReason: "toolUse" })),
    fauxAssistantMessage([fauxText("Synthetic replay done")])];
  faux.setResponses(calls(6));
  pi.registerProvider("read-guard-probe", { baseUrl: "http://127.0.0.1/unused", apiKey: "synthetic-placeholder",
    api: faux.api, models: faux.models, streamSimple: (...args) => { requests++; save(); return faux.streamSimple(...args); } });
  pi.registerTool({ name: "bash", label: "synthetic bash", description: "Never executes a command",
    parameters: Type.Object({ command: Type.String() }),
    async execute() { executions++; save(); return { content: [{ type: "text", text: "unchanged fixture" }], details: {} }; } });
  pi.on("session_start", () => {
    writeFileSync(process.env.FM_HOME + "/state/.lock", process.pid + "\\n");
    writeFileSync(process.env.FM_HOME + "/state/.pi-turnend-extension-loaded", "sha256:synthetic\\n" + process.pid + "\\n");
  });
  pi.on("input", (event) => { if (event.text === "RESET_ONCE") faux.setResponses(calls(1)); });
}
`);

const receipt = join(lab, "receipt.json");
const child = spawn(pi, ["--mode", "rpc", "--approve", "--offline", "--no-mcp", "--no-context-files", "--no-skills",
  "--no-prompt-templates", "--no-extensions", "-e", join(repo, "probe.ts"), "-e", join(repo, ".pi/extensions/fm-primary-read-repetition.ts"),
  "--model", "read-guard-probe/scripted", "--thinking", "off"], {
  cwd: repo, detached: true, stdio: ["pipe", "pipe", "pipe"],
  env: { PATH: process.env.PATH, HOME: join(lab, "home"), TERM: "dumb", PI_OFFLINE: "1", DISABLE_AUTOUPDATER: "1",
    PI_CODING_AGENT_DIR: agentDir, FM_HOME: repo, READ_GUARD_RECEIPT: receipt },
});
let stderr = "", seq = 0;
const events = [], pending = new Map();
child.stderr.on("data", (data) => { stderr = (stderr + data).slice(-12000); });
const lines = createInterface({ input: child.stdout });
lines.on("line", (line) => {
  let event; try { event = JSON.parse(line); } catch { return; }
  events.push(event);
  if (event.type === "response" && pending.has(event.id)) {
    const settle = pending.get(event.id); pending.delete(event.id); settle(event);
  }
});
const deadline = setTimeout(() => { process.kill(-child.pid, "SIGTERM"); }, 45000);
const exited = once(child, "exit");
const command = (type, fields = {}) => new Promise((settle, reject) => {
  const id = `request-${++seq}`;
  const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Pi RPC ${type} timed out: ${stderr}`)); }, 12000);
  pending.set(id, (event) => { clearTimeout(timer); event.success ? settle(event) : reject(new Error(JSON.stringify(event))); });
  child.stdin.write(JSON.stringify({ id, type, ...fields }) + "\n");
});
const prompt = async (message) => {
  await command("prompt", { message });
  // get_state is ordered after prompt acceptance, but a run may still be busy.
  for (let i = 0; i < 200; i++) {
    const state = await command("get_state");
    if (!state.data.isStreaming) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error("Pi did not settle its owned turn");
};
try {
  await command("get_state");
  await prompt("Run the synthetic read replay");
  assert.deepEqual(JSON.parse(readFileSync(receipt)), { requests: 4, executions: 3 });
  await prompt("\u2063FIRSTMATE_OP: v1 watcher: synthetic wake");
  assert.deepEqual(JSON.parse(readFileSync(receipt)), { requests: 4, executions: 3 });
  await prompt("RESET_ONCE");
  assert.deepEqual(JSON.parse(readFileSync(receipt)), { requests: 6, executions: 4 });
  const sessionDir = join(agentDir, "sessions", `--${repo.slice(1).replaceAll("/", "-")}--`);
  const files = readdirSync(sessionDir).filter((name) => name.endsWith(".jsonl"));
  assert.equal(files.length, 1);
  const entries = readFileSync(join(sessionDir, files[0]), "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.ok(entries.some((e) => e.customType === "fm-read-repetition-activation-v1"));
  assert.equal(entries.filter((e) => e.customType === "fm-read-repetition-stopped").length, 1);
  assert.ok(events.some((e) => e.type === "agent_end"));
  assert.ok(events.some((e) => e.type === "tool_execution_end" && e.isError), "RPC forwards veto/abort result");
  console.log(JSON.stringify({ installedPiRPC: "passed", executionsBeforeStop: 3, requestsBeforeStop: 4,
    operationalResetDenied: true, userResetAllowed: true, durableNotice: true }));
} catch (error) {
  throw new Error(`${error.message}\nPi stderr: ${stderr}`, { cause: error });
} finally {
  clearTimeout(deadline);
  lines.close();
  if (child.exitCode === null) {
    try { process.kill(-child.pid, "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  }
  await exited;
  // No fixture child or descendant may survive this guard.
  try { process.kill(-child.pid, 0); throw new Error("Pi fixture process group survived cleanup"); }
  catch (error) { if (error.code !== "ESRCH") throw error; }
}
