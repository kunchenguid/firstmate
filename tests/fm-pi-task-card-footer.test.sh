#!/usr/bin/env bash
# Portable behavior tests for the Pi task-card footer projection, layout, async
# refresh, failure disclosure, and documented non-conflicting shortcuts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-task-card-footer)

node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { renderTaskCardFooter, TaskCardFooterStore } from "./.pi/extensions/lib/fm-task-card-footer.ts";
import { cardsForView, pageCount, projectSnapshot } from "./.pi/extensions/lib/fm-task-card-footer-state.ts";

const snapshot = {
  schema: "fm-fleet-snapshot.v1",
  tasks: [
    { id: "attention-task", current_state: { state: "parked", detail: "needs review" }, hints: { pending_decision: true }, backlog: { state: "in_flight", title: "Review the route" } },
    { id: "working-a", current_state: { state: "working", detail: "Implementing the footer" }, backlog: { state: "in_flight", title: "Build the footer" } },
    { id: "working-b", current_state: { state: "working" }, backlog: { state: "in_flight", title: "Check the layout" } },
    { id: "working-c", current_state: { state: "working" }, backlog: { state: "in_flight", title: "Exercise resize" } },
    { id: "working-d", current_state: { state: "working" }, backlog: { state: "in_flight", title: "Exercise keys" } },
    { id: "waiting-task", current_state: { state: "paused", detail: "waiting for approval" }, backlog: { state: "in_flight", title: "Wait for approval" } },
    { id: "waiting-two", current_state: { state: "paused" }, backlog: { state: "in_flight", title: "Wait for another approval" } },
    { id: "unknown-task", current_state: { state: "unknown" }, backlog: { state: "in_flight", title: "Unavailable state" } },
  ],
  backlog: { records: [
    { structured: true, id: "queued-task", state: "queued", title: "Queued task" },
    { structured: true, id: "done-task", state: "done", title: "Finished task" },
  ] },
  secondmate_current: { records: [] },
};

const projection = projectSnapshot(snapshot);
assert.deepEqual(projection.counts, { Working: 4, Attention: 2, Done: 1, Waiting: 2, Queued: 1 });
assert.deepEqual(projection.cards.map((card) => card.name), [
  "attention-task", "done-task", "queued-task", "unknown-task", "waiting-task", "waiting-two", "working-a", "working-b", "working-c", "working-d",
]);
assert.equal(projection.cards.find((card) => card.name === "unknown-task").status, "Unknown");
assert.equal(cardsForView(projection, "action").length, 3);
assert.equal(cardsForView(projection, "work").length, 7);
assert.equal(pageCount(projection, "work"), 2);
assert.equal(projection.cards.find((card) => card.name === "attention-task").next, "Review the open decision.");
assert.equal(projection.cards.find((card) => card.name === "working-a").summary[0], "Build the footer");
assert.equal(projection.cards.find((card) => card.name === "working-a").summary[1].includes("branch"), false);

for (const width of [120, 80, 60]) {
  const lines = renderTaskCardFooter(width, projection, "work", 0);
  assert.equal(lines.every((line) => Array.from(line).length <= width), true, `line wider than ${width}`);
  const columns = width >= 120 ? 3 : width >= 80 ? 2 : 1;
  assert.equal(lines.filter((line) => line.includes("─")).length, Math.ceil(6 / columns) * 3);
}
const wide = renderTaskCardFooter(120, projection, "work", 0);
assert.equal(wide.filter((line) => line.includes("working-a") || line.includes("working-b") || line.includes("working-c")).length, 1);
assert.equal(wide.filter((line) => line.includes("working-d") || line.includes("waiting-task") || line.includes("queued-task")).length, 1);
assert.equal(renderTaskCardFooter(120, projection, "work", 1).some((line) => line.includes("working-d")), true);
assert.equal(renderTaskCardFooter(60, projection, "action", 0).some((line) => line.includes("attention-task")), true);
assert.equal(renderTaskCardFooter(60, projection, "action", 1).some((line) => line.includes("page 2/2")), true);

let calls = 0;
let release;
const first = new Promise((resolve) => { release = resolve; });
const store = new TaskCardFooterStore({
  snapshotCommand: "snapshot",
  cwd: ".",
  env: {},
  exec: async () => {
    calls += 1;
    if (calls === 1) await first;
    return { status: 0, stdout: JSON.stringify(snapshot), stderr: "" };
  },
});
const refresh = store.refresh();
await new Promise((resolve) => setTimeout(resolve, 5));
await store.refresh();
assert.equal(calls, 1);
release();
await refresh;
await new Promise((resolve) => setTimeout(resolve, 160));
assert.equal(calls, 2);
assert.equal(store.value.cards.length, 10);
store.stop();

const errorStore = new TaskCardFooterStore({
  snapshotCommand: "snapshot",
  cwd: ".",
  env: {},
  exec: async () => ({ status: 1, stdout: "", stderr: "unreadable" }),
});
await errorStore.refresh();
assert.equal(errorStore.value.cards[0].status, "Unknown");
assert.equal(errorStore.value.cards[0].summary[1], "No live state was guessed.");
errorStore.stop();
console.log("ok - task-card projection, fixed-height layout, resize, pagination, async refresh, and unknown-state disclosure");
NODE

FIXTURE="$TMP_ROOT/pi-task-card-shortcuts"
mkdir -p "$FIXTURE/lib" "$FIXTURE/node_modules/@earendil-works/pi-coding-agent" "$FIXTURE/node_modules/@earendil-works/pi-tui"
cp "$ROOT/.pi/extensions/fm-task-card-footer.ts" "$FIXTURE/fm-task-card-footer.ts"
cp "$ROOT/.pi/extensions/lib/fm-task-card-footer.ts" "$FIXTURE/lib/fm-task-card-footer.ts"
cp "$ROOT/.pi/extensions/lib/fm-task-card-footer-state.ts" "$FIXTURE/lib/fm-task-card-footer-state.ts"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$FIXTURE/lib/fm-async-exec.ts"
printf '%s\n' '{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}' > "$FIXTURE/node_modules/@earendil-works/pi-coding-agent/package.json"
cat > "$FIXTURE/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function rawKeyHint(key, description) { return `${key} ${description}`; }
JS
printf '%s\n' '{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}' > "$FIXTURE/node_modules/@earendil-works/pi-tui/package.json"
cat > "$FIXTURE/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export const Key = { ctrlAlt: (key) => `ctrl+alt+${key}` };
JS
FIXTURE="$FIXTURE" node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
const shortcuts = [];
const pi = {
  registerShortcut(key, options) { shortcuts.push({ key, options }); },
  on() {},
};
const mod = await import(`${pathToFileURL(`${process.env.FIXTURE}/fm-task-card-footer.ts`).href}?shortcuts`);
mod.default(pi);
assert.deepEqual(shortcuts.map(({ key }) => key), [
  "ctrl+alt+left", "ctrl+alt+right", "ctrl+alt+up", "ctrl+alt+down",
]);
assert.equal(new Set(shortcuts.map(({ key }) => key)).size, 4);
console.log("ok - task-card footer uses four distinct Ctrl+Alt arrow shortcuts outside Pi's documented defaults");
NODE
