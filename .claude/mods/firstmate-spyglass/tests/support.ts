// Shared fixtures for the firstmate-spyglass plugin test suites under `claude plugin test`.
//
// Each test mocks the world beneath the plugin noun by noun: the environment that names
// the Firstmate code root and home, an in-memory file system, a scripted process runner,
// and a journal of every call the mod makes on `$` (processes, toasts, status lines, panes
// opened, the command it registers, prompts it submits).
import type { On } from "claude-code";
import { mock, type Engine, type MockClock } from "claude-code/testing";

export const CODE = "/fm/code";
export const HOME = "/fm/home";
export const SNAPSHOT = `${CODE}/bin/fm-fleet-snapshot.sh`;
export const PEEK = `${CODE}/bin/fm-peek.sh`;
export const HEAD = "1111111111111111111111111111111111111111";
export const REMOTE = "2222222222222222222222222222222222222222";

export type Run = { argv: readonly string[]; cwd?: string; env?: Record<string, string> };
export type Reply = { exitCode?: number; stdout?: string; stderr?: string };

export type Journal = {
  /** Every `$.process.run`, in order. */
  runs: Run[];
  toasts: string[];
  /** Every `$.ui.status` text, in order; undefined clears the line. */
  statuses: (string | undefined)[];
  /** Every `$.ui.open` pane id, in order. */
  opened: string[];
  commands: string[];
  /** Every `$.prompt.submit` text, with whether it was submitted as the user. */
  prompts: { text: string; asUser: boolean }[];
  copies: string[];
  /** Every file or environment read that reached the mocks. */
  fsReads: string[];
};

export type World = {
  clock: MockClock;
  files: Map<string, string>;
  journal: Journal;
  /** Replace the answer to the process whose argv starts with these words, longest match first. */
  reply: (prefix: readonly string[], answer: Reply | ((run: Run) => Reply)) => void;
};

export type WorldOptions = {
  /** Function-hooks opt-in value; omitted defaults to the active value `1`. */
  functionHooks?: string | undefined;
  /** Extra environment beside the home variables. */
  env?: Record<string, string>;
  /** Whether the Firstmate snapshot script exists under the code root; defaults to true. */
  firstmate?: boolean;
  /** The snapshot JSON the script prints. */
  snapshot?: unknown;
  /** The origin URL git reports; undefined makes `git remote get-url origin` fail. */
  origin?: string;
  /** Whether `gh` is installed; defaults to true. */
  gh?: boolean;
  /** The commit local HEAD and origin's default branch are at. */
  head?: string;
  remote?: string;
  /** Origin's default branch and the branch HEAD is on; both default to main. */
  defaultBranch?: string;
  branch?: string;
  /** The tracked files `git diff --name-only HEAD` reports as locally edited. */
  edits?: string[];
  /** What the GitHub compare answers when the commits differ. */
  compare?: { n: number; files: string[] };
};

export const EMPTY_SNAPSHOT = { generated: "2026-10-03T10:15:00Z", tasks: [], backlog: { records: [] } };

export function world(on: On, options: WorldOptions = {}): World {
  const functionHooks = "functionHooks" in options ? options.functionHooks : "1";
  mock.env(on, {
    FM_HOME: HOME,
    FM_ROOT_OVERRIDE: CODE,
    ...(options.env ?? {}),
    ...(functionHooks === undefined ? {} : { CLAUDE_CODE_ENABLE_FUNCTION_HOOKS: functionHooks }),
  });
  const clock = mock.clock(on);
  mock.store(on);
  const files = new Map<string, string>();
  if (options.firstmate !== false) files.set(SNAPSHOT, "#!/bin/sh\n");
  files.set(HOME, "");
  const journal: Journal = { runs: [], toasts: [], statuses: [], opened: [], commands: [], prompts: [], copies: [], fsReads: [] };
  const head = options.head ?? HEAD;
  const remote = options.remote ?? REMOTE;
  const replies: { prefix: readonly string[]; answer: Reply | ((run: Run) => Reply) }[] = [
    { prefix: [SNAPSHOT], answer: () => ({ stdout: JSON.stringify(options.snapshot ?? EMPTY_SNAPSHOT) }) },
    { prefix: [PEEK], answer: () => ({ stdout: "worker output\n" }) },
    { prefix: ["git", "-C", CODE, "remote", "get-url", "origin"], answer: () => (options.origin === undefined ? { exitCode: 1, stderr: "no origin" } : { stdout: `${options.origin}\n` }) },
    { prefix: ["/bin/sh", "-c", "command -v gh"], answer: () => (options.gh === false ? { exitCode: 1 } : { stdout: "/usr/bin/gh\n" }) },
    { prefix: ["git", "-C", CODE, "rev-parse", "HEAD"], answer: () => ({ stdout: `${head}\n` }) },
    { prefix: ["git", "-C", CODE, "ls-remote"], answer: () => ({ stdout: `ref: refs/heads/${options.defaultBranch ?? "main"}\tHEAD\n${remote}\tHEAD\n` }) },
    { prefix: ["git", "-C", CODE, "symbolic-ref"], answer: () => ({ stdout: `${options.branch ?? "main"}\n` }) },
    { prefix: ["git", "-C", CODE, "diff"], answer: () => ({ stdout: (options.edits ?? []).map((file) => `${file}\0`).join("") }) },
    { prefix: ["gh", "api"], answer: () => ({ stdout: JSON.stringify(options.compare ?? { n: 0, files: [] }) }) },
  ];
  const world: World = {
    clock,
    files,
    journal,
    reply: (prefix, answer) => {
      replies.unshift({ prefix, answer });
    },
  };

  on("session.start", async (_$, e) => ({ cwd: e.cwd }));
  on("ui.focus", async () => ({}));
  on("turn.complete", async () => ({ text: "" }));
  on("ui.close", async () => ({ value: undefined }));
  on("fs.exists", async (_$, e) => ({ value: files.has(e.path) }));
  on("fs.read", async (_$, e) => {
    journal.fsReads.push(e.path);
    return files.has(e.path) ? { value: files.get(e.path)! } : { deny: `ENOENT: ${e.path}` };
  });
  on("fs.stat", async (_$, e) => (files.has(e.path) ? { value: { kind: "file" as const, size: 0, mtimeMs: 0, isLink: false } } : { deny: `ENOENT: ${e.path}` }));
  on("process.run", async (_$, e) => {
    const run: Run = { argv: e.argv, cwd: e.init?.cwd, env: e.init?.env };
    journal.runs.push(run);
    const match = replies
      .filter((reply) => reply.prefix.every((word, index) => e.argv[index] === word))
      .sort((a, b) => b.prefix.length - a.prefix.length)[0];
    const answer = match === undefined ? { exitCode: 127, stderr: `unmocked: ${e.argv.join(" ")}` } : typeof match.answer === "function" ? match.answer(run) : match.answer;
    return { value: { exitCode: 0, stdout: "", stderr: "", isStdoutTruncated: false, isStderrTruncated: false, ...answer } };
  });
  on("command.register", async (_$, e) => {
    journal.commands.push(e.name);
    return { value: { command: e.name } };
  });
  on("ui.toast", async (_$, e) => {
    journal.toasts.push(e.text);
    return { value: undefined };
  });
  on("ui.status", async (_$, e) => {
    journal.statuses.push(e.text);
    return { value: undefined };
  });
  on("ui.open", async (_$, e) => {
    journal.opened.push(e.id);
    return { value: { isPlaced: true as const } };
  });
  on("ui.copy", async (_$, e) => {
    journal.copies.push(e.text);
    return { value: { isCopied: true } } as never;
  });
  on("prompt.submit", async (_$, e) => {
    journal.prompts.push({ text: e.text, asUser: e.origin.kind === "plugin" && e.origin.asUser === true });
    return { text: e.text };
  });
  on("turn.start", async (_$, e) => ({ turnId: e.turnId }));
  on("ui.render", async (_$, e) => ({ type: "Text", props: {}, children: [STOCK_TEXT] }) as never);

  current = world;
  return world;
}

/** The engine's own drawing, as the bottom of every `ui.render` chain. */
export const STOCK_TEXT = "STOCK-DRAWING";

export const sessionStart = { cwd: "/work", surface: "terminal" as const, isInteractive: true };

/** Start the session and let the background update check finish, so no work outlives the test. */
export async function start($: Engine): Promise<void> {
  await $.session.start(sessionStart);
  await current!.clock.settle();
}

// The world the running test built last: each test builds exactly one.
let current: World | undefined;

export function pane(requestId = "spyglass", columns = 80, rows = 40) {
  return {
    surface: "terminal" as const,
    component: "Pane" as const,
    requestId,
    viewport: { columns, rows },
    props: { title: "Spyglass", isFocused: false, bodyColumns: columns, placement: "inline", scroll: {}, view: {} } as never,
  };
}

/** Every text a drawing shows: one line per Text element, plus each Button label and Link target. */
export function shownText(tree: unknown): string {
  const lines: string[] = [];
  const flat = (node: unknown): string => {
    if (typeof node === "string" || typeof node === "number") return String(node);
    if (Array.isArray(node)) return node.map(flat).join("");
    if (node === null || typeof node !== "object") return "";
    const element = node as { props?: Record<string, unknown>; children?: unknown };
    return flat(element.children) + (element.props !== undefined && "children" in element.props ? flat(element.props.children) : "");
  };
  const walk = (node: unknown) => {
    if (Array.isArray(node)) return node.forEach(walk);
    if (node === null || typeof node !== "object") return;
    const element = node as { type?: string; props?: Record<string, unknown>; children?: unknown };
    if (element.type === "Text") return void lines.push(flat(element));
    if (typeof element.props?.label === "string") lines.push(element.props.label);
    if (typeof element.props?.href === "string") lines.push(element.props.href);
    if (typeof element.props?.source === "string") lines.push(element.props.source);
    walk(element.children);
    if (element.props !== undefined && "children" in element.props) walk(element.props.children);
  };
  walk(tree);
  return lines.join("\n");
}

export function isStock(tree: unknown): boolean {
  return JSON.stringify(tree).includes(STOCK_TEXT);
}

/** One snapshot with a worker, a ready PR, a captain hold, and queued work. */
export const BUSY_SNAPSHOT = {
  generated: "2026-10-03T10:15:00Z",
  tasks: [
    {
      id: "alpha",
      kind: "ship",
      current_state: { state: "done" },
      backlog: { repo: "web" },
      pr: { url: "https://github.com/o/r/pull/7" },
      backend: "tmux",
      remote: null,
      endpoint: { target: "fm:alpha" },
    },
  ],
  backlog: {
    records: [
      { id: "held", title: "Pick a name", hold_reason: "needs the captain", captain_actionable: true, state: "queued" },
      { id: "later", title: "Later work", state: "queued" },
    ],
  },
};

/** A focus-ring move onto an element of the fleet pane, as the engine raises it. */
export function focus(element: string | undefined, origin: "person" | "plugin" = "person", requestId = "spyglass") {
  return {
    component: "Pane" as const,
    requestId,
    plugin: element === undefined ? undefined : "spyglass",
    element,
    origin: origin === "person" ? { kind: "person" as const } : { kind: "plugin" as const, name: "spyglass" },
  };
}
