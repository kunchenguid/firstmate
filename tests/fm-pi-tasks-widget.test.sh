#!/usr/bin/env bash
# Deterministic component and lifecycle tests for Pi's live /tasks widget.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-tasks-widget)
repo="$TMP_ROOT/repo"
mkdir -p "$repo/.pi/extensions" "$repo/node_modules/@earendil-works/pi-tui"
cp "$ROOT/.pi/extensions/fm-tasks.ts" "$repo/.pi/extensions/fm-tasks.ts"
cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export function visibleWidth(value) { return Array.from(value).length; }
export function truncateToWidth(value, width, ellipsis = "...") {
  const chars = Array.from(value);
  if (chars.length <= width) return value;
  if (width <= 0) return "";
  const tail = Array.from(ellipsis);
  if (tail.length >= width) return tail.slice(0, width).join("");
  return chars.slice(0, width - tail.length).join("") + ellipsis;
}
JS

out=$(PLUGIN="$repo/.pi/extensions/fm-tasks.ts" FM_ROOT_OVERRIDE="$repo" \
  FM_PI_TASKS_REFRESH_MS=10000 FM_PI_TASKS_EVENT_REFRESH_MIN_MS=40 \
  node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

let now = Date.parse("2026-09-16T10:00:05Z");
const realDateNow = Date.now;
Date.now = () => now;
const realSetInterval = globalThis.setInterval;
const realClearInterval = globalThis.clearInterval;
let nextTimer = 0;
const intervals = new Map();
globalThis.setInterval = (callback, ms) => {
  const timer = { id: ++nextTimer, callback, ms, active: true, unref() {} };
  intervals.set(timer.id, timer);
  return timer;
};
globalThis.clearInterval = (timer) => {
  if (timer?.id && intervals.has(timer.id)) intervals.get(timer.id).active = false;
};

const handlers = new Map();
const commands = new Map();
const widgetCalls = [];
let component;
let renderRequests = 0;
let execCalls = 0;
let aborts = 0;
let transcriptWrites = 0;
let modelStarts = 0;
const sentMessages = [];
const responses = [];
const tui = { terminal: { rows: 24 }, requestRender() { renderRequests += 1; } };
const ui = {
  setWidget(key, content, options) {
    widgetCalls.push({ key, content, options });
    component?.dispose?.();
    component = typeof content === "function" ? content(tui, {}) : undefined;
  },
  notify() { transcriptWrites += 1; },
};
const pi = {
  on(event, handler) {
    const list = handlers.get(event) ?? [];
    list.push(handler);
    handlers.set(event, list);
  },
  registerCommand(name, options) { commands.set(name, options); },
  sendMessage() { transcriptWrites += 1; },
  sendUserMessage(message) { sentMessages.push(message); transcriptWrites += 1; },
  appendEntry() { transcriptWrites += 1; },
  async exec(command, args, options) {
    execCalls += 1;
    if (command !== "bash" || args[1] !== "--json") throw new Error(`unexpected exec: ${command} ${args.join(" ")}`);
    const response = responses.shift();
    if (response?.pending) {
      return await new Promise((resolve, reject) => {
        options.signal.addEventListener("abort", () => {
          aborts += 1;
          reject(new Error("aborted"));
        }, { once: true });
      });
    }
    return response ?? { code: 0, stdout: "[]\n", stderr: "", killed: false };
  },
};
const emit = async (event, payload = {}) => {
  for (const handler of handlers.get(event) ?? []) await handler(payload, context);
};
const settle = async () => {
  for (let i = 0; i < 8; i += 1) await Promise.resolve();
};
const context = {
  mode: "tui",
  ui,
  sessionManager: { getEntries() { return []; } },
};

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
for (const status of ["working", "reviewing", "delivering", "monitoring"]) {
  const elapsed = mod.formatTaskElapsed({ id: status, ref: "t1", name: status, status, outcome: "", started_at: "2026-09-16T10:00:00Z" }, now);
  if (elapsed !== "00:00:05") throw new Error(`${status} did not expose phase elapsed time: ${elapsed}`);
}
if (mod.formatTaskElapsed({ id: "done", ref: "t2", name: "done", status: "done", outcome: "", started_at: "2026-09-16T10:00:00Z" }, now) !== "—") {
  throw new Error("Done candidate exposed an active elapsed timer");
}
mod.default(pi);
if (!commands.has("tasks") || !commands.has("t")) throw new Error("task dashboard commands were not registered");
if (commands.get("tasks").description !== "Toggle Firstmate's live current-task table.") {
  throw new Error(`unexpected command description: ${commands.get("tasks").description}`);
}

await emit("session_start", { reason: "startup" });
if (component !== undefined) throw new Error("startup did not leave the task widget hidden");
if (widgetCalls.at(-1)?.content !== undefined) throw new Error("startup did not explicitly clear the keyed widget");
if ([...intervals.values()].some((timer) => timer.active)) throw new Error("startup created a hidden timer");
if (commands.get("t").description !== "Open the task dashboard or route to one task.") {
  throw new Error(`unexpected /t command description: ${commands.get("t").description}`);
}

responses.push({
  code: 0,
  stderr: "",
  killed: false,
  stdout: JSON.stringify([
    { id: "active", ref: "t1", name: "active-work", status: "working", outcome: "implementing", started_at: "2026-09-16T10:00:00Z" },
    { id: "unknown", ref: "t2", name: "unknown-clock", status: "working", outcome: "waiting for timestamp", started_at: null },
    { id: "done", ref: "t3", name: "done-work", status: "done", outcome: "candidate ready for review", started_at: "2026-09-16T09:00:00Z" },
  ]),
});
const entriesBefore = context.sessionManager.getEntries().length;
await commands.get("t").handler("", context);
await settle();
if (!component) throw new Error("bare /t did not open the dashboard widget");
if (widgetCalls.at(-1)?.key !== "firstmate-live-tasks") throw new Error("widget key changed");
if (widgetCalls.at(-1)?.options?.placement !== "belowEditor") throw new Error("task widget is not isolated below Calm's above-editor rows");
if (execCalls !== 1) throw new Error(`bare /t ran ${execCalls} task subprocesses`);
if (transcriptWrites !== 0 || context.sessionManager.getEntries().length !== entriesBefore || modelStarts !== 0) {
  throw new Error("bare /t wrote transcript state or started a model turn");
}
await commands.get("t").handler("t1", context);
if (sentMessages.at(-1) !== "/task t1") throw new Error("/t selector did not route to /task");
let wide = component.render(80);
if (!wide.some((line) => line.includes("Elapsed")) || !wide.some((line) => line.includes("00:00:05"))) {
  throw new Error(`wide table omitted elapsed counter: ${wide.join("\n")}`);
}
const unknownLine = wide.find((line) => line.includes("unknown-clock"));
const doneLine = wide.find((line) => line.includes("done-work"));
if (!unknownLine?.includes("—") || !doneLine?.includes("—")) {
  throw new Error(`unknown or inactive timestamps were inferred: ${wide.join("\n")}`);
}
if (!wide.every((line) => Array.from(line).length === 80)) throw new Error("wide render was not exactly width-aware");
tui.terminal.rows = 6;
const capped = component.render(80);
if (!capped.some((line) => line.includes("+2 more")) || capped.some((line) => line.includes("done-work"))) {
  throw new Error(`short terminal did not cap rows with a +N summary: ${capped.join("\\n")}`);
}
tui.terminal.rows = 24;
const narrow = component.render(30);
if (!narrow.some((line) => line.includes("Current outcome")) || !narrow.every((line) => Array.from(line).length === 30)) {
  throw new Error(`narrow render was unusable or exceeded width: ${narrow.join("\n")}`);
}

const localTick = [...intervals.values()].find((timer) => timer.active && timer.ms === 1000);
if (!localTick) throw new Error("visible widget did not start its one-second local tick");
const callsBeforeTicks = execCalls;
now += 1000;
localTick.callback();
if (!component.render(80).some((line) => line.includes("00:00:06"))) throw new Error("first local elapsed tick did not advance");
now += 1000;
localTick.callback();
if (!component.render(80).some((line) => line.includes("00:00:07"))) throw new Error("second local elapsed tick did not advance");
if (execCalls !== callsBeforeTicks) throw new Error("local elapsed ticks reran fleet discovery");

responses.push({
  code: 0,
  stderr: "",
  killed: false,
  stdout: JSON.stringify([
    { id: "active", ref: "t1", name: "active-work", status: "reviewing", outcome: "state changed live", started_at: "2026-09-16T10:00:00Z" },
  ]),
});
now += 2000;
await emit("agent_settled");
await settle();
if (!component.render(80).some((line) => line.includes("state changed live"))) throw new Error("extension-visible event did not refresh task data");

responses.push({ code: 0, stdout: "[]\n", stderr: "", killed: false });
now += 2000;
await emit("message_end");
await settle();
if (!component.render(80).some((line) => line.includes("No current tasks"))) throw new Error("empty fleet did not render explicitly");

responses.push({ code: 7, stdout: "", stderr: "snapshot unavailable", killed: false });
now += 2000;
await emit("tool_execution_end");
await settle();
if (!component.render(80).some((line) => line.includes("snapshot unavailable"))) throw new Error("refresh error was not rendered in the component");

const burstStart = execCalls;
responses.push({ code: 0, stdout: "[]", stderr: "", killed: false });
responses.push({ code: 0, stdout: "[]", stderr: "", killed: false });
now += 2000;
await Promise.all([
  emit("agent_start"), emit("agent_settled"), emit("message_end"), emit("tool_execution_end"),
]);
await settle();
await new Promise((resolve) => setTimeout(resolve, 60));
await settle();
if (execCalls - burstStart > 2) throw new Error(`event burst launched ${execCalls - burstStart} subprocesses`);

responses.push({ pending: true });
now += 2000;
await emit("agent_start");
await settle();
await commands.get("tasks").handler("", context);
await settle();
if (component !== undefined) throw new Error("second /tasks did not hide the widget");
if (aborts !== 1) throw new Error(`hide did not abort the in-flight task process: ${aborts}`);
if ([...intervals.values()].some((timer) => timer.active)) throw new Error("hide leaked an interval");

responses.push({ code: 0, stdout: "[]", stderr: "", killed: false });
await commands.get("tasks").handler("", context);
await settle();
if (!component) throw new Error("third /tasks did not reopen the widget");
await emit("session_start", { reason: "reload" });
if (component !== undefined) throw new Error("reload did not restore startup-hidden state");
if ([...intervals.values()].some((timer) => timer.active)) throw new Error("reload leaked a timer");
await emit("session_shutdown", { reason: "quit" });
if ([...intervals.values()].some((timer) => timer.active)) throw new Error("shutdown leaked a timer");

Date.now = realDateNow;
globalThis.setInterval = realSetInterval;
globalThis.clearInterval = realClearInterval;
console.log("ok: Pi /tasks toggles one live component with local elapsed ticks and bounded refresh lifecycle");
EOF
)
status=$?
expect_code 0 "$status" "Pi task widget component and lifecycle contract must hold"
assert_contains "$out" "ok: Pi /tasks toggles one live component" "Pi task widget test did not complete"

frontmatter=$(awk 'NR == 2 { print }' "$ROOT/.agents/skills/task-list/SKILL.md")
[ "$frontmatter" = "name: task-list" ] || fail "natural-language task-list skill did not relinquish /tasks ownership"
[ ! -e "$ROOT/.agents/skills/tasks/SKILL.md" ] || fail "legacy /tasks skill owner remains present"
pass "Pi live task widget has one command owner and preserves a separate natural-language table path"
