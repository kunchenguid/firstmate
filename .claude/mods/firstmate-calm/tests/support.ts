// Shared fixtures for the firstmate-calm plugin test suites under `claude plugin test`.
//
// Each test mocks the world beneath the plugin noun by noun: the environment that
// names the Firstmate home, an in-memory file system for the per-home preference, the
// engine's own draw for every component the mod passes through, and a journal of every
// call the mod makes on `$` (blits, toasts, redraws, transcript lines, the command it
// registers).
import type { On, SessionMessage } from "claude-code";
import { mock, type MockClock } from "claude-code/testing";

export const HOME = "/fm/home";
export const PREFERENCE = `${HOME}/config/calm`;
/** The model a main-loop request names, spelled as Claude Code's own settings key it. */
export const MODEL = "claude-sonnet-5";

export type Journal = {
  /** Every `$.command.register` name, in order. */
  commands: string[];
  /** Every `$.ui.toast` text, in order. */
  toasts: string[];
  /** Every `$.ui.invalidate` event, in order. */
  invalidations: string[];
  /** Every `$.ui.blit`, as `{ requestId, key, columns, rows, cells }`. */
  blits: { requestId: string; key: string; columns?: number; rows?: number; cells: string }[];
  /** Which components reached the engine's own drawing, in order. */
  stock: string[];
  /** Preference reads that reached the mocked filesystem. */
  fsReads: string[];
  /** Number of transcript reads that reached the mocked session. */
  sessionMessageReads: number;
  /** Number of `/config` listings that reached the mocked menu. */
  configLists: number;
  /** Every `$.ui.log` line, in order. */
  logs: string[];
  /** Every command that reached the bottom of a `command.run` chain, as `{ command, args }`. */
  runs: { command: string; args: string }[];
  /** Number of settings reads that reached the mocked settings files. */
  settingsReads: number;
};

export type World = {
  clock: MockClock;
  files: Map<string, string>;
  /** A file's modification time, overriding the default stamp derived from its content. */
  mtimes: Map<string, number>;
  journal: Journal;
  /** Set to deny every `$.ui.blit` from now on, as an unmounted site does. */
  denyBlits: (reason: string | undefined) => void;
  /** Set to reject every `$.fs.write` from now on. */
  failWrites: (reason: string | undefined) => void;
  /** Set the id `$.session.id()` answers from now on, as a new or resumed session has. */
  setSessionId: (id: string) => void;
  /** The level the session is running at, which the next main-loop request carries. */
  effort: () => string;
  /** A reply has arrived, so Claude Code asks to confirm the next effort change. */
  reply: () => void;
  /** Rewrite the settings `$.settings.read()` answers, as another session on the machine does. */
  writeSettings: (settings: unknown) => void;
};

export type WorldOptions = {
  /** The stored preference text; absent means no file. */
  preference?: string;
  /** Extra environment beside FM_HOME; pass `{}` with `home: undefined` to unset FM_HOME. */
  env?: Record<string, string>;
  /** Function-hooks opt-in value; omitted options default to the active value `1`. */
  functionHooks?: string | undefined;
  /** The Firstmate home FM_HOME names; undefined leaves FM_HOME unset. */
  home?: string | undefined;
  /** What `$.session.messages()` answers. */
  messages?: readonly { role: "user" | "assistant"; text: string; toolUses: readonly unknown[] }[];
  /** The `theme` row's value as `$.config.list()` reports it; omitted means `dark`. */
  theme?: unknown;
  /** What `$.settings.read()` answers; omitted means an empty settings object. */
  settings?: unknown;
  /** The model `$.session.model()` answers with until a `/model <name>` switches it. */
  model?: string;
  /** Set to make every `$.command.run` deny with this reason, as a refused command does. */
  commandFailure?: string;
  /**
   * The level the session runs at from launch, as `--effort` sets it whatever is saved;
   * omitted means the level saved for the model, then the saved default, then `high`.
   */
  effort?: string;
  /** The highest level this model and plan allow, which `/effort` sets instead of one above it. */
  effortCap?: string;
  /** Set to answer every effort-change confirmation Claude Code asks with `No, go back`. */
  turnDown?: boolean;
};

/** The levels `/effort` and a main-loop request share, low to high. */
const EFFORT_RAMP = ["low", "medium", "high", "xhigh", "max"];

/** The engine's own drawing, as the bottom of every `ui.render` chain. */
export const STOCK_TEXT = "STOCK-DRAWING";

export function world(on: On, options: WorldOptions = {}): World {
  const home = "home" in options ? options.home : HOME;
  const functionHooks = "functionHooks" in options ? options.functionHooks : "1";
  mock.env(on, {
    ...(home === undefined ? {} : { FM_HOME: home }),
    ...(options.env ?? {}),
    ...(functionHooks === undefined ? {} : { CLAUDE_CODE_ENABLE_FUNCTION_HOOKS: functionHooks }),
  });
  const clock = mock.clock(on);
  mock.store(on);
  let sessionId = "session-1";
  const files = new Map<string, string>();
  const mtimes = new Map<string, number>();
  if (options.preference !== undefined) files.set(PREFERENCE, options.preference);
  const journal: Journal = {
    commands: [],
    toasts: [],
    invalidations: [],
    blits: [],
    stock: [],
    fsReads: [],
    sessionMessageReads: 0,
    configLists: 0,
    logs: [],
    runs: [],
    settingsReads: 0,
  };
  let theme: unknown = "theme" in options ? options.theme : "dark";
  let blitDenial: string | undefined;
  let writeFailure: string | undefined;

  on("fs.read", async (_$, e) => {
    journal.fsReads.push(e.path);
    return files.has(e.path) ? { value: files.get(e.path)! } : { deny: `ENOENT: ${e.path}` };
  });
  on("fs.exists", async (_$, e) => ({ value: files.has(e.path) }));
  // A file's time is its content's hash unless a test sets it, so every changed content restamps it.
  on("fs.stat", async (_$, e) => {
    const text = files.get(e.path);
    if (text === undefined) return { deny: `ENOENT: ${e.path}` };
    let mtimeMs = 0;
    for (const char of text) mtimeMs = (mtimeMs * 31 + char.codePointAt(0)!) % 2147483647;
    mtimeMs = mtimes.get(e.path) ?? mtimeMs;
    return { value: { kind: "file" as const, size: text.length, mtimeMs } };
  });
  on("ui.log", async (_$, e) => {
    journal.logs.push(e.text);
    return { value: undefined };
  });
  on("fs.write", async (_$, e) => {
    if (writeFailure !== undefined) return { deny: writeFailure };
    files.set(e.path, e.text);
    return { value: undefined };
  });
  on("command.register", async (_$, e) => {
    journal.commands.push(e.name);
    return { value: { command: e.name } };
  });
  on("ui.toast", async (_$, e) => {
    journal.toasts.push(e.text);
    return { value: undefined };
  });
  on("ui.invalidate", async (_$, e) => {
    journal.invalidations.push(e.event);
    return { value: undefined };
  });
  on("ui.blit", async (_$, e) => {
    journal.blits.push({ requestId: e.requestId, key: e.key, columns: e.columns, rows: e.rows, cells: e.cells });
    return { value: blitDenial === undefined ? {} : { deny: blitDenial } };
  });
  on("session.messages", async () => {
    journal.sessionMessageReads += 1;
    return { value: [...(options.messages ?? [])] as SessionMessage[] };
  });
  let model = options.model ?? MODEL;
  on("session.model", async () => ({ value: model }));
  let settings: unknown = options.settings ?? {};
  on("settings.read", async () => {
    journal.settingsReads += 1;
    return { value: settings as never };
  });
  const saved = (settings ?? {}) as { effortLevel?: string; modelSettings?: Record<string, { effortLevel?: string }> };
  let effort = options.effort ?? saved.modelSettings?.[model]?.effortLevel ?? saved.effortLevel ?? "high";
  // Claude Code 2.1.280 asks to confirm an effort change once the conversation holds a reply,
  // and asks again after each later reply; a change it confirmed lets the rest through.
  let replied = (options.messages ?? []).length > 0;
  let confirmed = false;
  // The bottom of every `command.run` chain the mod raises or forwards: what the engine
  // would have run, recorded so a test can read exactly which level the mod selected.
  on("command.run", async (_$, e) => {
    // A command the engine refuses rejects the caller's `$.command.run`, as a host check does.
    if (options.commandFailure !== undefined) throw new Error(options.commandFailure);
    journal.runs.push({ command: e.command, args: e.args });
    // `/model <name>` switches the session's model, which is what `$.session.model()` reports
    // from then on; a bare `/model` opens the picker and switches nothing here.
    if (e.command === "model" && e.args !== "") model = e.args;
    if (e.command === "effort" && EFFORT_RAMP.includes(e.args)) {
      // A level above the cap is set to the cap instead.
      const cap = options.effortCap;
      const capped = cap !== undefined && EFFORT_RAMP.indexOf(e.args) > EFFORT_RAMP.indexOf(cap);
      const level = capped ? cap : e.args;
      if (replied && !confirmed && level !== effort) {
        if (options.turnDown) return { value: {} };
        confirmed = true;
      }
      effort = level;
      // Only low through xhigh are saved as this model's default, and a capped level is not:
      // `max` is this session only.
      if (!capped && level !== "max") {
        const base = (typeof settings === "object" && settings !== null ? settings : {}) as Record<string, unknown>;
        const models = (typeof base.modelSettings === "object" && base.modelSettings !== null
          ? base.modelSettings
          : {}) as Record<string, Record<string, unknown>>;
        settings = { ...base, modelSettings: { ...models, [model]: { ...models[model], effortLevel: level } } };
      }
    }
    return { value: {} };
  });
  on("ui.press", async (_$, e) => ({ value: { element: e.element } }));
  on("session.start", async (_$, e) => ({ cwd: e.cwd }));
  on("session.id", async () => ({ value: sessionId }));
  on("config.list", async () => {
    journal.configLists += 1;
    return {
      value: [
        {
          key: "theme",
          label: "Theme",
          kind: "choice",
          value: theme as never,
          options: ["auto", "dark", "light", "light-daltonized", "dark-daltonized", "light-ansi", "dark-ansi"],
          provider: { plugin: "engine", tier: "core" },
          isLocked: false,
        },
      ],
    };
  });
  // The menu writes the row: the value lands for later listings and the hook above sees it.
  on("config.set", async (_$, e) => {
    if (e.key === "theme") theme = e.value;
    return { value: e.value };
  });
  on("ui.render", async (_$, e) => {
    journal.stock.push(e.component);
    return { type: "Text", props: {}, children: [STOCK_TEXT] };
  });

  return {
    clock,
    files,
    mtimes,
    journal,
    denyBlits: (reason) => {
      blitDenial = reason;
    },
    failWrites: (reason) => {
      writeFailure = reason;
    },
    setSessionId: (id) => {
      sessionId = id;
    },
    effort: () => effort,
    reply: () => {
      replied = true;
      confirmed = false;
    },
    writeSettings: (next) => {
      settings = next;
    },
  };
}

export const VIEWPORT = { columns: 40, rows: 24 } as const;

export function spinner(requestId = "agent-main", viewport: { columns: number; rows: number } = VIEWPORT) {
  return {
    surface: "terminal" as const,
    component: "Spinner" as const,
    requestId,
    viewport,
    props: { word: "Sauteing", message: null, mode: "requesting" as const },
  };
}

/** A Spinner drawing before any surface has measured: no viewport at all. */
export function unmeasuredSpinner(requestId = "agent-main") {
  return {
    surface: "terminal" as const,
    component: "Spinner" as const,
    requestId,
    props: { word: "Sauteing", message: null, mode: "requesting" as const },
  };
}

export function toolUse(requestId = "tool-1") {
  return {
    surface: "terminal" as const,
    component: "ToolUse" as const,
    requestId,
    viewport: VIEWPORT,
    props: { tool_use_id: requestId, tool: "Bash", input: { command: "ls" }, isRunning: false, isErrored: false, isInterrupted: false },
  };
}

export function toolResult(requestId = "tool-1") {
  return {
    surface: "terminal" as const,
    component: "ToolResult" as const,
    requestId,
    viewport: VIEWPORT,
    props: { tool_use_id: requestId, tool: "Bash", output: { stdout: "x", stderr: "" }, isErrored: false },
  };
}

export function toolGroup(requestId = "group-1", isExpanded = false) {
  return {
    surface: "terminal" as const,
    component: "ToolGroup" as const,
    requestId,
    viewport: VIEWPORT,
    props: { calls: [], isActive: false, isExpanded },
  };
}

export function userMessage(text: string, requestId = "user-1") {
  return {
    surface: "terminal" as const,
    component: "UserMessage" as const,
    requestId,
    viewport: VIEWPORT,
    props: { text, origin: { kind: "composer" as const } },
  };
}

export function assistantMessage(text: string, requestId = "assistant-1") {
  return {
    surface: "terminal" as const,
    component: "AssistantMessage" as const,
    requestId,
    viewport: VIEWPORT,
    props: { text, isFirstOfReply: true },
  };
}

export function calmCommand() {
  return {
    command: "calm",
    args: "",
    origin: { kind: "composer" as const },
    presentation: { layout: "main" as const, isFullscreen: false, columns: 80 },
  };
}

/** A run of a slash command as the composer raises it. */
export function command(name: string, args = "") {
  return {
    command: name,
    args,
    origin: { kind: "composer" as const },
    presentation: { layout: "main" as const, isFullscreen: false, columns: 80 },
  };
}

/** The band above the composer, the site the effort cue draws in. */
export function abovePrompt(bodyColumns = 40, requestId = "above-prompt", hasSurvey = false) {
  return {
    surface: "terminal" as const,
    component: "AbovePrompt" as const,
    requestId,
    viewport: VIEWPORT,
    props: {
      hasSurvey,
      isWorking: false,
      maxRows: VIEWPORT.rows,
      bodyColumns,
      scroll: { offset: 0, bodyRows: VIEWPORT.rows - 1 },
      view: {},
    },
  };
}

/** A press of the effort cue's Button, as `$.ui.press` names one. */
export function effortCuePress(key = "firstmate-effort-cue") {
  return { plugin: "fm", key };
}

/** One model request of the main loop, carrying the effort the engine resolved for it. */
export function turnStep(effort?: unknown, agentId?: string, model = MODEL) {
  return {
    turnId: `turn-${model}`,
    index: 0,
    model,
    messageCount: 1,
    ...(effort === undefined ? {} : { effort: effort as never }),
    ...(agentId === undefined ? {} : { agentId }),
  };
}

/** The effort cue inside an `AbovePrompt` drawing: the Button's label and the rule's color. */
export function effortCueOf(tree: unknown): { label: string; color: string; rule: string } | undefined {
  const seen: unknown[] = [tree];
  let label: string | undefined;
  let color: string | undefined;
  let rule: string | undefined;
  while (seen.length > 0) {
    const node = seen.pop();
    if (node === null || typeof node !== "object") continue;
    const element = node as { type?: unknown; props?: Record<string, unknown>; children?: unknown };
    if (element.type === "Button" && typeof element.props?.label === "string") label = element.props.label;
    if (element.type === "Text" && typeof element.props?.color === "string") {
      color = element.props.color;
      // The renderer lifts a Text's children out of its props and onto the element.
      const text = element.children ?? element.props.children;
      if (typeof text === "string") rule = text;
      else if (Array.isArray(text) && text.every((part) => typeof part === "string")) rule = text.join("");
    }
    if (Array.isArray(element.children)) seen.push(...element.children);
    else if (element.children !== undefined) seen.push(element.children);
    if (element.props !== undefined && "children" in element.props) seen.push(element.props.children);
  }
  return label === undefined || color === undefined ? undefined : { label, color, rule: rule ?? "" };
}

/** Whether a drawing is the mod's zero-height box. */
export function isHidden(tree: unknown): boolean {
  return JSON.stringify(tree).includes('"display":"none"');
}

/** Whether a drawing is the engine's own. */
export function isStock(tree: unknown): boolean {
  return JSON.stringify(tree).includes(STOCK_TEXT);
}

/** The Raster element inside a Spinner drawing, or undefined when the drawing has none. */
export function rasterOf(tree: unknown): { columns: number; rows: number; cells: string; key: string } | undefined {
  const seen: unknown[] = [tree];
  while (seen.length > 0) {
    const node = seen.pop();
    if (node === null || typeof node !== "object") continue;
    const element = node as { type?: unknown; props?: Record<string, unknown>; children?: unknown };
    if (element.type === "Raster" && element.props !== undefined) {
      return element.props as { columns: number; rows: number; cells: string; key: string };
    }
    if (Array.isArray(element.children)) seen.push(...element.children);
    else if (element.children !== undefined) seen.push(element.children);
    if (element.props !== undefined && "children" in element.props) seen.push(element.props.children);
  }
  return undefined;
}

const BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/** Decode packed cells back into rows of glyphs and foregrounds, the way the surface reads them. */
export function decodeCells(cells: string, columns: number, rows: number): { glyphs: string[]; foregrounds: number[][]; backgrounds: number[][] } {
  const clean = cells.replace(/=+$/, "");
  const bytes: number[] = [];
  let buffer = 0;
  let bits = 0;
  for (const char of clean) {
    buffer = (buffer << 6) | BASE64.indexOf(char);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes.push((buffer >> bits) & 0xff);
    }
  }
  const words = new Uint32Array(new Uint8Array(bytes).buffer);
  if (words.length !== columns * rows * 3) {
    throw new Error(`cells decode to ${words.length} words, not ${columns * rows * 3}`);
  }
  const glyphs: string[] = [];
  const foregrounds: number[][] = [];
  const backgrounds: number[][] = [];
  for (let row = 0; row < rows; row += 1) {
    let text = "";
    const fg: number[] = [];
    const bg: number[] = [];
    for (let column = 0; column < columns; column += 1) {
      const offset = (row * columns + column) * 3;
      text += String.fromCodePoint(words[offset]!);
      fg.push(words[offset + 1]!);
      bg.push(words[offset + 2]!);
    }
    glyphs.push(text);
    foregrounds.push(fg);
    backgrounds.push(bg);
  }
  return { glyphs, foregrounds, backgrounds };
}

/** The exact current operational envelope for one kind, as bin/fm-operational-input.sh encodes it. */
export function operational(kind: string, body: string): string {
  return `\u2063FIRSTMATE_OP: v1 ${kind}: ${body}`;
}

/** The record-backed doorbell bin/fm-operational-input.sh types for a named record. */
export function doorbell(record: string): string {
  return `: Firstmate operational input waiting: read '${record}' and handle its contents as Firstmate operational input.`;
}

/** The established from-firstmate routing carrier. */
export function fromFirstmate(body: string): string {
  return `[fm-from-firstmate]\u2063${body}`;
}

/** A `config.set` of the `theme` row from the `/config` menu, as the engine raises it. */
export function themeChange(value: string, previous: string) {
  return {
    key: "theme",
    value,
    previous,
    provider: { plugin: "engine", tier: "core" as const },
    origin: { kind: "composer" as const },
  };
}
