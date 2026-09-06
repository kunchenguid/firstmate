// Native Pi fixture for fm-calm-pi-extension.test.sh. No credentials or network.
import assert from "node:assert/strict";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import * as Pi from "@earendil-works/pi-coding-agent";
import { Container, Text } from "@earendil-works/pi-tui";
import { Agent } from "@earendil-works/pi-agent-core";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import pendingExtension from "./.pi/extensions/fm-pending-notifications.ts";
import { installPendingNotificationLayout } from "./.pi/extensions/lib/fm-pending-notification-layout.ts";
import { encodeFirstmateOperationalInput } from "./.pi/extensions/lib/fm-operational-input.ts";
import { setCalmPresentation } from "./.pi/extensions/lib/fm-calm-visibility.ts";

const internal = Array.from({ length: 40 }, (_, i) => encodeFirstmateOperationalInput("watcher", `PENDING_INTERNAL_${i}`));
const genuine = "GENUINE_QUEUED_MESSAGE";
const text = (message) => typeof message.content === "string" ? message.content : message.content.filter(b => b.type === "text").map(b => b.text).join("\n");
const user = (content) => ({ role: "user", content: [{ type: "text", text: content }], timestamp: 1 });

export function componentChecks() {
  Pi.initTheme("dark");
  // Actual installed Pi renderer and Agent queues; no mocked renderer output.
  const prototype = Pi.InteractiveMode.prototype;
  const stockUpdate = prototype.updatePendingMessagesDisplay;
  const agent = new Agent();
  let steering = [];
  let followUp = [...internal, genuine];
  const mode = Object.create(prototype);
  Object.defineProperty(mode, "session", { value: { agent }, configurable: true });
  mode.pendingMessagesContainer = new Container();
  mode.getAllQueuedMessages = () => ({ steering: [...steering], followUp: [...followUp] });
  mode.getAppKeyDisplay = () => "alt+up";
  mode.ui = { requestRender() {} };
  for (const item of followUp) agent.followUp(user(item));
  stockUpdate.call(mode);
  const stock = mode.pendingMessagesContainer.render(100);
  assert.equal(stock.length, 43);
  const before = JSON.stringify(agent);
  let layout = installPendingNotificationLayout();
  mode.updatePendingMessagesDisplay();
  for (const calm of [true, false]) {
    setCalmPresentation(calm);
    for (const width of [40, 100, 180]) {
      const lines = mode.pendingMessagesContainer.render(width);
      assert.equal(lines.length, 3);
      assert(lines.join("\n").includes(genuine));
      assert(!lines.join("\n").includes("PENDING_INTERNAL_"));
      assert(lines.join("\n").includes("edit all queued"));
    }
  }
  assert.equal(JSON.stringify(agent), before);
  layout.dispose();
  assert.deepEqual(mode.pendingMessagesContainer.render(100), stock);
  layout.refresh();
  assert.equal(mode.pendingMessagesContainer.render(100).length, 3);
  const retired = layout;
  layout = installPendingNotificationLayout();
  retired.dispose();
  assert.equal(mode.pendingMessagesContainer.render(100).length, 3);

  // Stock queue edit/dequeue: all internal text remains recoverable, in order.
  let editorText = "draft";
  mode.editor = { getText: () => editorText, setText: value => { editorText = value; } };
  mode.clearAllQueues = () => {
    const result = mode.getAllQueuedMessages();
    steering = []; followUp = []; agent.clearAllQueues();
    return result;
  };
  assert.equal(mode.restoreQueuedMessagesToEditor(), 41);
  assert.equal(editorText, [...internal, genuine, "draft"].join("\n\n"));
  assert.deepEqual(mode.pendingMessagesContainer.render(100), []);

  followUp = [...internal];
  for (const item of followUp) agent.followUp(user(item));
  mode.updatePendingMessagesDisplay();
  assert.deepEqual(mode.pendingMessagesContainer.render(100), []);
  // Pending user-bash components share the container and must remain intact.
  const bash = new Text("PENDING_USER_BASH", 0, 0);
  mode.pendingMessagesContainer.addChild(bash);
  assert(mode.pendingMessagesContainer.render(100).join("\n").includes("PENDING_USER_BASH"));

  const nearMisses = [
    `quoted ${internal[0]}`, internal[0].slice(1), `\u2063Captain note`,
    "\u2063FIRSTMATE_OP: v2 watcher: near miss", "\u2063FIRSTMATE_OP: v1 unknown: near miss",
  ];
  steering = [internal[1], ...nearMisses];
  for (const item of steering) agent.steer(user(item));
  const image = user(internal[0]);
  image.content.push({ type: "image", data: "fixture", mimeType: "image/png" });
  followUp.push(internal[0]); agent.followUp(image);
  mode.updatePendingMessagesDisplay();
  const rendered = mode.pendingMessagesContainer.render(180).join("\n");
  for (const item of nearMisses) assert(rendered.includes(item));
  assert.equal(rendered.split("Follow-up:").length - 1, 2, "identical text with an image must keep both previews");
  assert(!rendered.includes(`Steering: ${internal[1]}`));
  const originalQueue = agent.followUpQueue;
  agent.followUpQueue = undefined;
  const errors = [];
  const originalError = console.error;
  console.error = line => errors.push(line);
  assert(mode.pendingMessagesContainer.render(100).join("\n").includes("PENDING_INTERNAL_39"));
  mode.pendingMessagesContainer.render(100);
  console.error = originalError;
  assert.equal(errors.length, 1);
  assert(errors[0].includes("pending message metadata unavailable"));
  agent.followUpQueue = originalQueue;
  stockUpdate.call(mode);
  const rowChildren = mode.pendingMessagesContainer.children;
  [rowChildren[1], rowChildren[2]] = [rowChildren[2], rowChildren[1]];
  const reorderedStock = mode.pendingMessagesContainer.render(180);
  errors.length = 0;
  console.error = line => errors.push(line);
  layout.refresh();
  console.error = originalError;
  assert.deepEqual(mode.pendingMessagesContainer.render(180), reorderedStock);
  assert(errors.some(line => line.includes("pending row identity changed")));
  layout.dispose();
  const registryKey = Symbol.for("firstmate:pending-notification-layout:v1");
  const savedRegistry = globalThis[registryKey];
  const savedUpdate = prototype.updatePendingMessagesDisplay;
  delete globalThis[registryKey];
  prototype.updatePendingMessagesDisplay = undefined;
  errors.length = 0;
  console.error = line => errors.push(line);
  pendingExtension({ on() { throw new Error("unavailable adapter registered lifecycle handlers"); } });
  console.error = originalError;
  prototype.updatePendingMessagesDisplay = savedUpdate;
  globalThis[registryKey] = savedRegistry;
  assert.equal(errors.length, 1);
  assert(errors[0].includes("presentation adapter unavailable, skipping"));
  console.log("native pending components: 43 stock rows -> 3 mixed rows -> 0 internal-only rows; queues unchanged");
}

export default function (pi) {
  let mode;
  const prototype = Pi.InteractiveMode.prototype;
  const originalContext = prototype.createExtensionUIContext;
  prototype.createExtensionUIContext = function (...args) {
    mode = this;
    return originalContext.apply(this, args);
  };
  const originalUpdate = prototype.updatePendingMessagesDisplay;
  prototype.updatePendingMessagesDisplay = function (...args) {
    mode = this;
    return originalUpdate.apply(this, args);
  };
  const dir = process.env.PENDING_TEST_DIR;
  let release;
  let expected = [];
  let initial = true;
  let consumed = [];
  pi.on("session_start", (event) => writeFileSync(join(dir, "ready"), event.reason));
  pi.on("message_start", event => {
    if (event.message.role === "user") consumed.push(text(event.message));
  });
  pi.on("agent_settled", () => writeFileSync(join(dir, "settled.json"), JSON.stringify(consumed)));
  pi.registerProvider("pending-test", {
    baseUrl: "http://127.0.0.1/unused", apiKey: "test-only", api: "pending-test-api",
    models: [{ id: "deterministic", name: "Pending test", reasoning: false, input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 131072, maxTokens: 64 }],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      const gated = initial; initial = false;
      const output = { role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id,
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: "stop", timestamp: Date.now() };
      void (async () => {
        stream.push({ type: "start", partial: output });
        if (gated) await new Promise(resolve => { release = resolve; writeFileSync(join(dir, "streaming"), "yes"); });
        appendFileSync(join(dir, "contexts.jsonl"), JSON.stringify(context.messages.filter(m => m.role === "user").map(text)) + "\n");
        output.content.push({ type: "text", text: "PENDING_TEST_RESPONSE" });
        stream.push({ type: "done", reason: "stop", message: output }); stream.end();
      })();
      return stream;
    },
  });
  pi.registerShortcut("alt+e", {
    handler: async ctx => {
      try {
        assert.equal(ctx.ui.getEditorText(), expected.join("\n\n"));
        assert.deepEqual(mode.getAllQueuedMessages(), { steering: [], followUp: [] });
        ctx.ui.setEditorText("");
        writeFileSync(join(dir, "edited"), "yes");
      } catch (error) { writeFileSync(join(dir, "failure"), String(error.stack)); }
    },
  });
  pi.registerCommand("pending-test", {
    handler: async (args, ctx) => {
      const [command, label] = args.trim().split(/\s+/);
      try {
        if (command === "start") {
          expected = []; consumed = []; initial = true;
          await pi.setModel(ctx.modelRegistry.find("pending-test", "deterministic"));
          pi.sendUserMessage("PENDING_TEST_START");
        } else if (command === "seed") {
          for (const item of internal) pi.sendUserMessage(item, { deliverAs: "followUp" });
          if (label !== "internal") pi.sendUserMessage(genuine, { deliverAs: "followUp" });
          expected = [...internal, ...(label === "internal" ? [] : [genuine])];
        } else if (command === "inspect") {
          const before = JSON.stringify(mode.getAllQueuedMessages());
          const sessionBefore = JSON.stringify(ctx.sessionManager.getEntries());
          const lines = mode.pendingMessagesContainer.render(100);
          assert.equal(JSON.stringify(mode.getAllQueuedMessages()), before);
          assert.equal(JSON.stringify(ctx.sessionManager.getEntries()), sessionBefore);
          assert.deepEqual(mode.getAllQueuedMessages().followUp, expected);
          writeFileSync(join(dir, `${label}.json`), JSON.stringify({ lines, queue: JSON.parse(before), session: ctx.sessionManager.getSessionFile() }));
        } else if (command === "release") {
          release();
        } else if (command === "check") {
          assert.deepEqual(consumed, ["PENDING_TEST_START", ...expected]);
          const persisted = ctx.sessionManager.getEntries().filter(e => e.type === "message" && e.message.role === "user").map(e => text(e.message));
          assert.deepEqual(persisted, consumed);
          const contexts = readFileSync(join(dir, "contexts.jsonl"), "utf8").trim().split("\n").map(line => JSON.parse(line));
          assert.deepEqual(contexts.at(-1), consumed);
          assert.equal(contexts.length, expected.length + 1);
          writeFileSync(join(dir, "checked"), "yes");
        }
      } catch (error) {
        writeFileSync(join(dir, "failure"), String(error.stack));
        throw error;
      }
    },
  });
}
