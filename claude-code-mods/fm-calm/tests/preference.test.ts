import { expect, test } from "claude-code/testing";
import { formatCalmPreference, parseCalmPreference, resolveCalmConfigPath } from "../src/preference.ts";

test("preference values match the shared config/calm contract", () => {
  expect(parseCalmPreference("on")).toBe("on");
  expect(parseCalmPreference("off")).toBe("off");
  expect(parseCalmPreference("max")).toBe("on");
  expect(parseCalmPreference("ON\n")).toBe("off");
  expect(parseCalmPreference("  max  ")).toBe("on");
  expect(parseCalmPreference("")).toBe("off");
  expect(parseCalmPreference("nonsense")).toBe("off");
  expect(parseCalmPreference(undefined)).toBe("off");
  expect(formatCalmPreference(true)).toBe("on\n");
  expect(formatCalmPreference(false)).toBe("off\n");
});

test("config path resolution mirrors the Pi extension order", () => {
  expect(resolveCalmConfigPath({})).toBe(undefined);
  expect(resolveCalmConfigPath({ home: "/home/fm" })).toBe("/home/fm/config/calm");
  expect(resolveCalmConfigPath({ rootOverride: "/src/fm" })).toBe("/src/fm/config/calm");
  expect(resolveCalmConfigPath({ home: "/home/fm", configOverride: "/tmp/cfg" })).toBe("/tmp/cfg/calm");
  expect(resolveCalmConfigPath({ home: "/home/fm/", configOverride: "/tmp/cfg/" })).toBe("/tmp/cfg/calm");
  expect(resolveCalmConfigPath({ home: "  " })).toBe(undefined);
});