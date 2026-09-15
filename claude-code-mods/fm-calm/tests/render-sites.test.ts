import type { On, RenderElement } from "claude-code";
import { expect, mock, test, type Engine } from "claude-code/testing";
import { FM_OPERATIONAL_PREFIX } from "../src/operational-input.ts";

const FM_HOME = "/home/fm";
const CALM_CONFIG = `${FM_HOME}/config/calm`;

const COMPOSER = { kind: "composer" } as const;
const PRESENTATION = { isFullscreen: false, columns: 80 } as const;

const TOOL_USE = {
  surface: "terminal",
  component: "ToolUse",
  requestId: "main",
  props: {
    tool: "Bash",
    tool_use_id: "toolu_1",
    input: { command: "ls" },
    isRunning: false,
    isErrored: false,
    isInterrupted: false,
  },
  viewport: { columns: 80, rows: 40 },
} as const;

const TOOL_RESULT = {
  surface: "terminal",
  component: "ToolResult",
  requestId: "main",
  props: { tool: "Bash", tool_use_id: "toolu_1", output: "x", isErrored: false },
  viewport: { columns: 80, rows: 40 },
} as const;

const TOOL_GROUP = {
  surface: "terminal",
  component: "ToolGroup",
  requestId: "main",
  props: { calls: [], isActive: true, isExpanded: false },
  viewport: { columns: 80, rows: 40 },
} as const;

type World = {
  files: Map<string, string>;
  invalidated: string[];
  commands: string[];
};

function world(on: On, seed?: Record<string, string>): World {
  const files = new Map<string, string>(Object.entries(seed ?? {}));
  const invalidated: string[] = [];
  const commands: string[] = [];

  mock.env(on, { FM_HOME });

  on("session.start", (_$, e) => ({ cwd: e.cwd }));
  on("command.register", (_$, e) => {
    commands.push(e.name);
    return { value: { command: e.name } };
  });

  on("fs.exists", (_$, e) => ({ value: files.has(e.path) }));
  on("fs.read", (_$, e) => {
    const text = files.get(e.path);
    if (text === undefined) throw new Error(`no such file: ${e.path}`);
    return { value: text };
  });
  on("fs.write", (_$, e) => {
    files.set(e.path, e.text);
    return { value: undefined };
  });
  on("ui.invalidate", (_$, e) => {
    invalidated.push(e.event);
    return { value: undefined };
  });

  return { files, invalidated, commands };
}

function box(element: RenderElement) {
  if (element.type !== "Box") throw new Error(`expected a Box, got ${element.type}`);
  return element;
}

async function startSession($: Engine): Promise<void> {
  await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
}

async function toggle($: Engine): Promise<string> {
  const result = await $.command.run({
    command: "calm",
    args: "",
    origin: COMPOSER,
    presentation: PRESENTATION,
  });
  return result?.text ?? "";
}

async function delegated(call: () => Promise<unknown>): Promise<boolean> {
  try {
    await call();
    return false;
  } catch {
    return true;
  }
}

test("Calm starts off, and /calm reports each new state", {}, async ($, on) => {
  const seen = world(on);
  mock.clock(on, { now: 100000 });
  await startSession($);

  expect(seen.commands).toEqual(["calm"]);
  expect((await toggle($)).startsWith("Calm on")).toBe(true);
  expect((await toggle($)).startsWith("Calm off")).toBe(true);
});

test("the stored choice is read back at session start", {}, async ($, on) => {
  world(on, { [CALM_CONFIG]: "on\n" });
  mock.clock(on, { now: 100000 });
  await startSession($);

  expect(box(await $.ui.render(TOOL_USE)).children?.length).toBe(0);
});

test("an unreadable stored choice leaves Calm off rather than failing the session", {}, async ($, on) => {
  world(on, { [CALM_CONFIG]: "nonsense" });
  mock.clock(on, { now: 100000 });
  await startSession($);

  expect(await delegated(() => $.ui.render(TOOL_USE))).toBe(true);
});

test("toggling writes the choice through and asks for one redraw", {}, async ($, on) => {
  const seen = world(on);
  mock.clock(on, { now: 100000 });
  await startSession($);

  await toggle($);
  expect(seen.files.get(CALM_CONFIG)).toBe("on\n");
  expect(seen.invalidated).toEqual(["ui.render"]);

  await toggle($);
  expect(seen.files.get(CALM_CONFIG)).toBe("off\n");
  expect(seen.invalidated).toEqual(["ui.render", "ui.render"]);
});

test("tool call and tool result rows are replaced by an empty row while Calm is on", {}, async ($, on) => {
  world(on);
  mock.clock(on, { now: 100000 });
  await startSession($);

  expect(await delegated(() => $.ui.render(TOOL_USE))).toBe(true);

  await toggle($);

  expect(box(await $.ui.render(TOOL_USE)).children?.length).toBe(0);
  expect(box(await $.ui.render(TOOL_RESULT)).children?.length).toBe(0);

  await toggle($);
  expect(await delegated(() => $.ui.render(TOOL_USE))).toBe(true);
});

test("a genuine prompt row survives and an operational row does not", {}, async ($, on) => {
  world(on);
  mock.clock(on, { now: 100000 });
  await startSession($);
  await toggle($);

  const genuine = await delegated(() =>
    $.ui.render({
      surface: "terminal",
      component: "UserMessage",
      requestId: "main",
      props: { text: "a genuine prompt", origin: COMPOSER },
      viewport: { columns: 80, rows: 40 },
    }),
  );
  expect(genuine).toBe(true);

  const operational = await $.ui.render({
    surface: "terminal",
    component: "UserMessage",
    requestId: "main",
    props: { text: `${FM_OPERATIONAL_PREFIX}v1 watcher: fleet is idle`, origin: COMPOSER },
    viewport: { columns: 80, rows: 40 },
  });
  expect(box(operational).children?.length).toBe(0);
});

test("the folded tool group, thinking summary and all, is replaced by an empty row", {}, async ($, on) => {
  world(on);
  mock.clock(on, { now: 100000 });
  await startSession($);

  expect(await delegated(() => $.ui.render(TOOL_GROUP))).toBe(true);

  await toggle($);
  expect(box(await $.ui.render(TOOL_GROUP)).children?.length).toBe(0);

  await toggle($);
  expect(await delegated(() => $.ui.render(TOOL_GROUP))).toBe(true);
});

test("the working row is left to Claude Code's own spinner", {}, async ($, on) => {
  world(on);
  mock.clock(on, { now: 100000 });
  await startSession($);
  await toggle($);

  const spinner = await delegated(() =>
    $.ui.render({
      surface: "terminal",
      component: "Spinner",
      requestId: "main",
      props: { word: "Working", message: "Working", mode: "requesting" },
      viewport: { columns: 24, rows: 40 },
    }),
  );
  expect(spinner).toBe(true);
});
