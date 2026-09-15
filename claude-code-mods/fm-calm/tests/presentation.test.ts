import { expect, test } from "claude-code/testing";
import { calmHidesSite, hiddenCalmRow } from "../src/presentation.ts";
import { FM_OPERATIONAL_PREFIX } from "../src/operational-input.ts";

test("a hidden row is an empty column box", () => {
  expect(JSON.stringify(hiddenCalmRow())).toBe('{"type":"Box","props":{"flexDirection":"column"},"children":[]}');
});

test("shading is off for every site while Calm is off", () => {
  for (const site of ["ToolUse", "ToolResult", "ToolGroup", "UserMessage"] as const) {
    expect(calmHidesSite(site, false, { text: FM_OPERATIONAL_PREFIX + "x" })).toBe(false);
  }
});

test("tool call, tool result and folded tool group rows are shaded whatever they carry", () => {
  expect(calmHidesSite("ToolUse", true, { tool: "Bash" })).toBe(true);
  expect(calmHidesSite("ToolResult", true, { output: "x" })).toBe(true);
  expect(calmHidesSite("ToolGroup", true, { calls: [], isActive: true, isExpanded: false })).toBe(true);
});

test("only firstmate operational user rows are shaded", () => {
  expect(calmHidesSite("UserMessage", true, { text: FM_OPERATIONAL_PREFIX + "v1 watcher: hi" })).toBe(true);
  expect(calmHidesSite("UserMessage", true, { text: "a genuine prompt" })).toBe(false);
  expect(calmHidesSite("UserMessage", true, { text: `not at the start ${FM_OPERATIONAL_PREFIX}` })).toBe(false);
  expect(calmHidesSite("UserMessage", true, {})).toBe(false);
  expect(calmHidesSite("UserMessage", true, undefined)).toBe(false);
});

