#!/usr/bin/env bash
# Behavior tests for completing a hung Cursor replay tool without aborting the Pi turn.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/.pi/extensions/lib/fm-cursor-replay-execute.ts"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

LIB="$LIB" node --experimental-strip-types --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";

const {
  CURSOR_REPLAY_INCOMPLETE_ERROR,
  cursorReplayInputIsIncomplete,
  isCursorReplayToolCallId,
  wrapCursorReplayToolExecute,
} = await import(pathToFileURL(process.env.LIB).href);

const fail = (message) => {
  console.error(`not ok - ${message}`);
  process.exit(1);
};

if (!isCursorReplayToolCallId("cursor-replay-shell")) fail("cursor replay id should match");
if (isCursorReplayToolCallId("bash-1")) fail("non-cursor replay id should not match");
if (!cursorReplayInputIsIncomplete({ incomplete: true })) fail("incomplete args should match");
if (cursorReplayInputIsIncomplete({ activityTitle: "Cursor shell" })) fail("live args should not be incomplete");

const hungExecute = async () => new Promise(() => {});
const hung = wrapCursorReplayToolExecute(hungExecute);
await hung("cursor-replay-shell-hung", {}, undefined, undefined, {}).then(
  () => fail("silent hung cursor-replay should fail the tool"),
  (error) => {
    if (String(error?.message) !== CURSOR_REPLAY_INCOMPLETE_ERROR) {
      fail(`hung error was ${error?.message}`);
    }
  },
);

let abortedSignal = false;
const hungWithSignal = wrapCursorReplayToolExecute((_id, _params, signal) => {
  signal?.addEventListener("abort", () => {
    abortedSignal = true;
  }, { once: true });
  return new Promise(() => {});
});
await hungWithSignal("cursor-replay-shell-hung", {}, undefined, undefined, {}).then(
  () => fail("hung cursor-replay with signal should fail the tool"),
  () => {},
);
if (!abortedSignal) fail("hung cursor-replay must abort the SDK waiter signal");

const recordedExecute = async () => ({ content: [{ type: "text", text: "ok" }] });
const recorded = wrapCursorReplayToolExecute(recordedExecute);
const recordedResult = await recorded("cursor-replay-shell-recorded", {}, undefined, undefined, {});
if (recordedResult?.content?.[0]?.text !== "ok") fail("recorded cursor-replay must return the stored result");

let updates = 0;
const streamingExecute = async (_id, _params, _signal, onUpdate) => {
  for (let i = 0; i < 5; i += 1) {
    onUpdate?.({ i });
    updates += 1;
    await new Promise(() => {});
  }
  return { content: [{ type: "text", text: "ok" }] };
};
const streaming = wrapCursorReplayToolExecute(streamingExecute);
await streaming("cursor-replay-shell-live", {}, undefined, undefined, {}).then(
  () => fail("a still-pending cursor-replay execute is missing completion, not a live shell"),
  (error) => {
    if (String(error?.message) !== CURSOR_REPLAY_INCOMPLETE_ERROR) {
      fail(`streaming error was ${error?.message}`);
    }
  },
);
if (updates !== 1) fail("cursor-replay must not wait on live onUpdate progress");

const incomplete = wrapCursorReplayToolExecute(hungExecute);
await incomplete("cursor-replay-shell", { incomplete: true }, undefined, undefined, {}).then(
  () => fail("incomplete args should fail the tool immediately"),
  (error) => {
    if (String(error?.message) !== CURSOR_REPLAY_INCOMPLETE_ERROR) {
      fail(`incomplete error was ${error?.message}`);
    }
  },
);

const passthrough = wrapCursorReplayToolExecute(async () => "bash-ok");
if ((await passthrough("bash-1", {}, undefined, undefined, {})) !== "bash-ok") {
  fail("non-replay tools must be unchanged");
}

const nativeExecute = async (args, ctx) => `${args.kind}:${ctx.id}`;
const native = wrapCursorReplayToolExecute(nativeExecute);
if ((await native({ kind: "arm" }, { id: "watch" })) !== "arm:watch") {
  fail("native two-arg tools must keep their original execute shape");
}

console.log("ok - cursor replay execute completes hung tools without a turn abort");
EOF
