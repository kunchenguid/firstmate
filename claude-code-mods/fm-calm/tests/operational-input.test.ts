import { expect, test } from "claude-code/testing";
import {
  FM_FROMFIRST_MARK,
  FM_LEGACY_AWAY_PREFIX,
  FM_OPERATIONAL_PREFIX,
  isFirstmateOperationalRow,
  isFirstmateOperationalText,
} from "../src/operational-input.ts";

test("the v1 header marker is recognized", () => {
  expect(isFirstmateOperationalText(`${FM_OPERATIONAL_PREFIX}v1 watcher: fleet is idle`)).toBe(true);
});

test("the from-firstmate marker is recognized", () => {
  expect(isFirstmateOperationalText(`${FM_FROMFIRST_MARK}captain says go`)).toBe(true);
});

test("the legacy supervisor-escalate marker is recognized", () => {
  expect(isFirstmateOperationalText(`${FM_LEGACY_AWAY_PREFIX}away)`)).toBe(true);
});

test("a genuine typed prompt is not operational", () => {
  expect(isFirstmateOperationalText("can you fix the login bug")).toBe(false);
});

test("non-string and empty text are not operational", () => {
  expect(isFirstmateOperationalText(undefined)).toBe(false);
  expect(isFirstmateOperationalText(42)).toBe(false);
  expect(isFirstmateOperationalText("")).toBe(false);
});

test("row detection defers to text detection", () => {
  expect(isFirstmateOperationalRow(undefined)).toBe(false);
  expect(isFirstmateOperationalRow({})).toBe(false);
  expect(isFirstmateOperationalRow({ text: `${FM_FROMFIRST_MARK}hi` })).toBe(true);
  expect(isFirstmateOperationalRow({ text: "a genuine prompt" })).toBe(false);
});
