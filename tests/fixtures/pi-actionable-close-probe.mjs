import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let deliveryStarted = false;
let rowsAtDelivery = 0;
let deliveredPrompt = "";
let releaseDelivery = () => {};
const deliveryBlocked = new Promise((resolve) => {
  releaseDelivery = resolve;
});

function assertWakeContext(prompt) {
  if (process.env.FM_EXPECT_WAKE_CONTEXT === "disabled") {
    if (!prompt.includes("WAKE_CONTEXT_FALLBACK: automatic wake context is disabled")) throw new Error(`Pi omitted the default-off fallback: ${prompt}`);
    if (prompt.includes("WAKE_CONTEXT_PRESENTED:") || prompt.includes("WAKE_ACK_REQUIRED:")) throw new Error(`Pi presented or acknowledged default-off context: ${prompt}`);
    return;
  }
  if (!prompt.includes("WAKE_CONTEXT_PRESENTED: durable presentation complete")) throw new Error(`Pi omitted the common post-presentation result: ${prompt}`);
  if (!prompt.includes("Wake context packet could not be built after the durable presentation.")) throw new Error(`Pi omitted wake-context fallback: ${prompt}`);
  if (!prompt.includes("--ack-through 7 --recovery-generation fixture-7")) throw new Error(`Pi lost the delayed wake-context ACK: ${prompt}`);
  if (prompt.includes("WAKE_CONTEXT_FALLBACK: run bin/fm-wake-drain.sh once.")) throw new Error(`Pi added a conflicting generic fallback: ${prompt}`);
}
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    deliveredPrompt = message;
    rowsAtDelivery = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter((row) => row.startsWith("arm=")).length
      : 0;
    deliveryStarted = true;
    await deliveryBlocked;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-continuity", {}, undefined, undefined, {});
for (let i = 0; i < 800; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
    : [];
  if (rows.length >= 2 && deliveryStarted) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
const armRows = rows.filter((row) => row.startsWith("arm="));
if (armRows.length !== 2) throw new Error(`expected one successor arm, got ${armRows.length}: ${rows.join(" | ")}`);
if (!deliveryStarted) throw new Error("wake delivery did not begin");
assertWakeContext(deliveredPrompt);
if (!deliveredPrompt.includes("packet or fallback instruction")) throw new Error(`Pi wake omitted the conditional handling contract: ${deliveredPrompt}`);
if (rowsAtDelivery !== 2) throw new Error(`wake delivery began before successor establishment (${rowsAtDelivery} arm rows)`);
if (!/predecessor=[0-9]+/.test(armRows[1])) throw new Error(`successor did not receive predecessor identity: ${armRows[1]}`);
if (!rows.some((row) => row.startsWith("confirmed generation=fixture-generation"))) {
  throw new Error(`handling delivery was not confirmed before the follow-up: ${rows.join(" | ")}`);
}
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.filter((row) => row.startsWith("arm=")).length !== 2) {
  throw new Error(`blocked follow-up started extra arm work: ${stableRows.join(" | ")}`);
}
if (stableRows.filter((row) => row.startsWith("confirmed ")).length !== 1) {
  throw new Error(`successful prompt delivery was not confirmed exactly once: ${stableRows.join(" | ")}`);
}
releaseDelivery();
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
