// Opt-in native Pi test instrumentation. Never loaded by a production session.
import { appendFileSync, existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function (pi: ExtensionAPI) {
  const home = process.env.FM_PI_INBOX_LAB!;
  if (!home || home !== process.env.FM_HOME) throw new Error("isolated inbox lab required");
  const root = process.env.FM_ROOT_OVERRIDE!;
  const log = (kind: string, data: unknown = {}) =>
    appendFileSync(`${home}/events.jsonl`, JSON.stringify({ at: Date.now(), kind, data }) + "\n");
  const run = async (script: string, args: string[] = []) => {
    const result = await pi.exec(`${root}/bin/${script}`, args);
    if (result.code !== 0) throw new Error(`${script}: ${result.stderr}`);
    return result;
  };
  pi.on("session_start", async () => {
    await run("fm-lock.sh");
    log("locked", { pid: process.pid });
  });
  pi.on("input", (event) => log("input", {
    text: event.text, source: event.source, streamingBehavior: event.streamingBehavior,
  }));
  pi.on("message_start", (event) => {
    if (event.message.role === "user") log("consumed", event.message.content);
  });
  pi.on("agent_settled", () => log("settled"));
  pi.registerCommand("probe-quit", { description: "Exit this isolated probe", handler: async (_args, ctx) => ctx.shutdown() });
  pi.registerTool({
    name: "probe_read", label: "Read synthetic notes",
    description: "Drain the isolated wake queue and read all pending synthetic inbox notes.",
    parameters: Type.Object({}),
    async execute() {
      const drain = await run("fm-wake-drain.sh");
      const ack = drain.stderr.match(/--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)/);
      if (ack) writeFileSync(`${home}/ack.json`, JSON.stringify(ack.slice(1)));
      const inbox = `${home}/state/inbox`;
      const notes = existsSync(inbox) ? readdirSync(inbox).filter((name) => name.endsWith(".note"))
        .map((name) => ({ id: name.slice(0, -5), body: readFileSync(`${inbox}/${name}`, "utf8") })) : [];
      log("read", notes.map((note) => note.id));
      return { content: [{ type: "text", text: JSON.stringify(notes) }], details: {} };
    },
  });
  pi.registerTool({
    name: "probe_reply", label: "Record synthetic answer",
    description: "Record your calculated answer to an isolated synthetic note, then acknowledge it. No WhatsApp transport is used.",
    parameters: Type.Object({ id: Type.String({ pattern: "^[A-Za-z0-9._-]+$" }), answer: Type.String() }),
    async execute(_id, params) {
      if (!existsSync(`${home}/state/inbox/${params.id}.note`)) throw new Error("pending note missing");
      log("reply", params);
      await run("fm-inbox.sh", ["drain", "--ack", params.id]);
      if (existsSync(`${home}/ack.json`)) {
        const [sequence, generation] = JSON.parse(readFileSync(`${home}/ack.json`, "utf8"));
        await run("fm-wake-drain.sh", ["--ack-through", sequence, "--recovery-generation", generation]);
      }
      log("acknowledged", { id: params.id });
      return { content: [{ type: "text", text: "Answer recorded. Finish this turn." }], details: {} };
    },
  });
  pi.registerTool({
    name: "probe_busy", label: "Controlled busy turn",
    description: "Hold a bounded tool call until the native-delivery test releases it, then finish the original task.",
    parameters: Type.Object({}),
    async execute() {
      log("busy-start");
      for (let i = 0; i < 1200 && !existsSync(`${home}/release-busy`); i++) {
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      if (!existsSync(`${home}/release-busy`)) throw new Error("busy probe timed out");
      log("busy-end");
      return { content: [{ type: "text", text: "Controlled work finished. End this task now." }], details: {} };
    },
  });
}
