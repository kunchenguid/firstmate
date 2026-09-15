import { expect, test } from "claude-code/testing";
import {
  calmHidesSite,
  calmShipElement,
  calmViewportColumns,
  hiddenCalmRow,
} from "../src/presentation.ts";
import { FM_OPERATIONAL_PREFIX } from "../src/operational-input.ts";

test("a hidden row is an empty column box", () => {
  expect(JSON.stringify(hiddenCalmRow())).toBe('{"type":"Box","props":{"flexDirection":"column"},"children":[]}');
});

test("shading is off for every site while Calm is off", () => {
  for (const site of ["ToolUse", "ToolResult", "UserMessage"] as const) {
    expect(calmHidesSite(site, false, { text: FM_OPERATIONAL_PREFIX + "x" })).toBe(false);
  }
});

test("tool call and tool result rows are shaded whatever they carry", () => {
  expect(calmHidesSite("ToolUse", true, { tool: "Bash" })).toBe(true);
  expect(calmHidesSite("ToolResult", true, { output: "x" })).toBe(true);
});

test("only firstmate operational user rows are shaded", () => {
  expect(calmHidesSite("UserMessage", true, { text: FM_OPERATIONAL_PREFIX + "v1 watcher: hi" })).toBe(true);
  expect(calmHidesSite("UserMessage", true, { text: "a genuine prompt" })).toBe(false);
  expect(calmHidesSite("UserMessage", true, { text: `not at the start ${FM_OPERATIONAL_PREFIX}` })).toBe(false);
  expect(calmHidesSite("UserMessage", true, {})).toBe(false);
  expect(calmHidesSite("UserMessage", true, undefined)).toBe(false);
});

test("the viewport width is read defensively", () => {
  expect(calmViewportColumns({ columns: 80 })).toBe(80);
  expect(calmViewportColumns({ columns: 80.7 })).toBe(80);
  expect(calmViewportColumns({ columns: -5 })).toBe(0);
  expect(calmViewportColumns({ columns: Number.NaN })).toBe(0);
  expect(calmViewportColumns({})).toBe(0);
  expect(calmViewportColumns(undefined)).toBe(0);
  expect(calmViewportColumns(null)).toBe(0);
  expect(calmViewportColumns({ columns: "wide" })).toBe(0);
});

test("the ship element is a column box of coloured rows", () => {
  const element = calmShipElement([
    [
      { text: " ", color: "yellow" },
      { text: "<|", color: "yellow" },
    ],
    [
      { text: "~", color: "blue" },
      { text: "\\__/", color: "yellow" },
    ],
  ]);
  expect(element.type).toBe("Box");
  expect(element.props.flexDirection).toBe("column");
  expect(element.children.length).toBe(2);
  const firstRow = element.children[0] as typeof element;
  expect(firstRow.type).toBe("Box");
  expect(firstRow.props.flexDirection).toBe("row");
  expect(firstRow.children.length).toBe(2);
  expect(JSON.stringify(firstRow.children[1])).toBe('{"type":"Text","props":{"color":"yellow"},"children":["<|"]}');
});