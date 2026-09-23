// fm-branch-mod under `claude plugin test`: the version pin, the presence switch, the durable
// classification log, and the cover row a captain verdict writes for main.
//
// The world beneath the module is mocked noun by noun: the environment names a
// Firstmate home, an in-memory file system (reads, writes, lists, and stats)
// holds the home's state and config, and every process the module runs answers
// from a small table keyed on the script name, with a journal of every call so
// a test can read what the module wrote and to which file.
import { describe, expect, test, type Engine, type On } from "claude-code/testing";
import { mock, type MockClock } from "claude-code/testing";

const HOME = "/fm/home";
const STATE = `${HOME}/state`;
const CONFIG = `${HOME}/config`;
import { CLAUDE_CODE_PIN as PIN } from "../hooks/branch.ts";
const sessionStart = { cwd: "/work", surface: "terminal" as const, isInteractive: true };
const SESSION_ID = "0f3a9c2e-kit-session";

type Run = { argv: string[]; stdin?: string; env?: Record<string, string> };
type World = {
  clock: MockClock;
  files: Map<string, string>;
  runs: Run[];
  logs: string[];
  registered: string[];
  /** Prompts that reached the engine beneath the module, i.e. were not dropped. */
  submitted: string[];
  spawns: { subagentType?: string; name?: string; model?: string; background?: boolean; prompt?: string }[];
  toolCalls: Record<string, unknown>[];
  completions: { model: string; system: string; prompt: string; maxTokens?: number }[];
  /** Lines appended through the module's `sh -c ... cat >> "$f"` append, keyed by path. */
  appended: (path: string) => string[];
};

type WorldOptions = {
  version?: string;
  /** What the running-binary version probe answers; "" simulates a host without /proc. Defaults to `version`. */
  runningBinaryVersion?: string;
  files?: Record<string, string>;
  /** Extra environment variables the module reads beyond the kit's own. */
  env?: Record<string, string>;
  /** One answer per classifier call in order; the last one repeats. */
  classifierAnswer?: string | string[];
  /** One evidence bundle per fm-wake-evidence.sh run in order; the last one repeats. */
  evidence?: string | string[];
  /** One SendMessage result per tool.call in order; the last one repeats. */
  sendAnswer?: string | string[];
  /** When set, every SendMessage tool.call is denied with this string instead of answered. */
  sendDeny?: string;
  /** The first N Monitor tool.calls are denied, so an arm attempt fails with the claim left false. */
  monitorDenyFirst?: number;
};

function nth(values: string | string[] | undefined, index: number, fallback: string): string {
  if (values === undefined) return fallback;
  if (typeof values === "string") return values;
  return values[Math.min(index, values.length - 1)] ?? fallback;
}

/**
 * The in-memory state directory with stat versions: every mutation bumps that
 * key's mtime, so the eligibility scan's stat-version cache keys move even when
 * an edit keeps the byte length identical. The side table lives at module level
 * because Map's own constructor invokes the overridden set before any instance
 * field initializer could run.
 */
const worldFileMtimes = new WeakMap<Map<string, string>, Map<string, number>>();
let worldFileTick = 0;
class WorldFiles extends Map<string, string> {
  override set(key: string, value: string): this {
    let mtimes = worldFileMtimes.get(this);
    if (!mtimes) {
      mtimes = new Map();
      worldFileMtimes.set(this, mtimes);
    }
    mtimes.set(key, 1_700_000_000_000 + ++worldFileTick);
    return super.set(key, value);
  }
  mtime(key: string): number {
    return worldFileMtimes.get(this)?.get(key) ?? 1_700_000_000_000;
  }
}

function world(on: On, options: WorldOptions = {}): World {
  mock.env(on, { FM_HOME: HOME, CLAUDE_CODE_ENABLE_FUNCTION_HOOKS: "1", ...options.env });
  const clock = mock.clock(on);
  const files = new WorldFiles(Object.entries(options.files ?? {}));
  const runs: Run[] = [];
  const logs: string[] = [];
  const registered: string[] = [];
  const completions: World["completions"] = [];
  const appends = new Map<string, string[]>();
  const submitted: string[] = [];
  const spawns: World["spawns"] = [];
  const toolCalls: Record<string, unknown>[] = [];
  const version = options.version ?? PIN;
  const runningBinary = options.runningBinaryVersion !== undefined ? options.runningBinaryVersion : version;

  on("fs.read", async (_$, e) => {
    // The classifier system prompt is read from the plugin's own folder.
    if (e.path.endsWith("/classifier-system.txt")) return { value: "SYSTEM PROMPT FIXTURE" };
    return files.has(e.path) ? { value: files.get(e.path)! } : { deny: `ENOENT: ${e.path}` };
  });
  // The eligibility scan's stat seam, answered from the same in-memory files:
  // regular files only (the engine world has no symlinks), so every stat is
  // ok and the per-key mtime version moves on each mutation. Denial for a
  // missing path is the host's ENOENT throw.
  on("fs.stat", async (_$, e) => {
    if (!files.has(e.path)) return { deny: `ENOENT: ${e.path}` };
    return { value: { kind: "file", size: new TextEncoder().encode(files.get(e.path)!).length, mtimeMs: files.mtime(e.path), isLink: false } };
  });
  on("prompt.submit", async (_$, e) => {
    submitted.push(e.text);
    return { text: e.text };
  });
  on("fs.exists", async (_$, e) => ({ value: files.has(e.path) }));
  on("fs.write", async (_$, e) => {
    files.set(e.path, e.text);
    return { value: undefined };
  });
  on("fs.list", async (_$, e) => {
    const prefix = `${e.path.replace(/\/+$/, "")}/`;
    const names = [...files.keys()].filter((p) => p.startsWith(prefix) && !p.slice(prefix.length).includes("/"));
    return { value: names.map((p) => ({ name: p.slice(prefix.length), kind: "file" })) };
  });
  on("ui.log", async (_$, e) => {
    logs.push(e.text);
    return { value: undefined };
  });
  on("tool.register", async (_$, e) => {
    registered.push(e.name);
    return { value: undefined };
  });
  on("model.complete", async (_$, e) => {
    completions.push({ model: e.model, system: e.system, prompt: e.prompt, maxTokens: e.maxTokens });
    return { value: nth(options.classifierAnswer, completions.length - 1, '{"verdict":"routine","reason":"nothing new"}') };
  });
  on("session.start", async (_$, e) => ({ cwd: e.cwd }));
  on("session.id", async () => ({ value: SESSION_ID }));
  on("agent.spawn", async (_$, e) => {
    // The event is Agent-tool shaped: subagent_type and run_in_background.
    spawns.push({ subagentType: e.subagent_type, name: e.name, model: e.model, background: e.run_in_background, prompt: e.prompt });
    // The kit answers a spawn with { model } only (the engine's launch answer
    // maps a `result` agent id to `agentId` for the caller, but the kit's own
    // downstream contract allows just { model } or { deny }); branch absorption
    // in kit tests goes through the SendMessage adoption path instead.
    return { model: e.model };
  });
  on("agent.list", async () => ({ value: [] }));
  let monitorCalls = 0;
  on("tool.call", async (_$, e) => {
    toolCalls.push(e);
    // The continuity Monitor the module arms: one task id per successful call,
    // or a denial for the first N calls a test sets, so the arm triggers can
    // be watched failing and recovering.
    if ((e as { tool?: string }).tool === "Monitor") {
      monitorCalls += 1;
      if (options.monitorDenyFirst !== undefined && monitorCalls <= options.monitorDenyFirst) return { deny: MONITOR_DENY };
      return { result: `Monitor started (task m${monitorCalls})` };
    }
    if (options.sendDeny) return { deny: options.sendDeny };
    // No branch agent exists yet: the harness answers a send to an unknown name this way.
    // The answer table indexes SendMessage calls only; the continuity Monitor
    // is a different tool and never consumes a send answer.
    const sends = toolCalls.filter((c) => (c as { tool?: string }).tool === "SendMessage").length;
    return { result: nth(options.sendAnswer, sends - 1, '{"success":false,"message":"no agent named fm-branch"}') };
  });
  on("process.run", async (_$, e) => {
    const argv = e.argv as string[];
    const init = (e.init ?? {}) as { stdin?: string; env?: Record<string, string> };
    const run: Run = { argv, stdin: init.stdin, env: init.env };
    runs.push(run);
    const answer = (stdout = "", exitCode = 0) => ({ value: { exitCode, stdout, stderr: "" } });
    if (argv[0] === "claude" && argv[1] === "--version") return answer(`${version} (Claude Code)\n`);
    if (argv[0] === "sh" && argv[1] === "-c") {
      // The running-binary version probe: the binary hosting the fake session,
      // which can differ from PATH `claude`; "" answers like a host without
      // /proc so the module must fall back.
      if (String(argv[2] ?? "").includes("/proc/$PPID/exe")) {
        if (runningBinary === "") return answer("", 1);
        return answer(`${runningBinary} (Claude Code)\n`);
      }
      // The module's own append: record the line under the target path.
      const path = argv[4];
      appends.set(path, [...(appends.get(path) ?? []), String(init.stdin ?? "")]);
      return answer();
    }
    const script = String(argv[1] ?? "").split("/").pop() ?? "";
    if (script === "fm-wake-evidence.sh") {
      const index = runs.filter((r) => r.argv[1]?.endsWith("fm-wake-evidence.sh")).length - 1;
      const fallback =
        `## task ${argv[2]} status bytes 0-38\n` +
        `## current state (bin/fm-crew-state.sh ${argv[2]})\n` +
        `state: working\n` +
        `## status lines appended since the last classified wake (NEW - judge these)\n` +
        `  done: PR https://x/1 checks green\n` +
        `## earlier lines, already handled by earlier wakes (HISTORY - never escalate these)\n` +
        `  (none)\n`;
      return answer(nth(options.evidence, index, fallback));
    }
    if (script === "fm-wake-grant.sh") return answer();
    if (script === "fm-branch-outcome.sh") return answer("7\n");
    return answer("", 1);
  });

  return {
    clock,
    files,
    runs,
    logs,
    registered,
    submitted,
    spawns,
    toolCalls,
    completions,
    appended: (path) => appends.get(path) ?? [],
  };
}

const CLASSIFICATIONS = `${STATE}/branch-mod-classifications.jsonl`;

/** A home with the mod switched on by the presence of state/.branch-mod-mode and one signal row queued for task t1. */
function armedHome(): Record<string, string> {
  return {
    [`${STATE}/.branch-mod-mode`]: "",
    [`${STATE}/.lock`]: "4242\n",
    [`${STATE}/t1.meta`]: "project=demo\nwindow=fm-t1\n",
    [`${STATE}/t1.status`]: "working: a\ndone: PR https://x/1 checks green\n",
    [`${STATE}/.wake-queue`]: "1700000000\t12\tsignal\tt1.status\tdone: PR https://x/1 checks green\n",
  };
}

const WAKE = `<summary>Stop hook feedback</summary>\nfirstmate watcher wake\nsignal: ${STATE}/t1.status\n`;

const MONITOR_DENY = "Monitor tool unavailable in this engine";

const startEvent = (w: World) =>
  w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line)).find((e) => e.kind === "session.start");

/** Detached helper work only shares the microtask queue with delivery; two macrotask turns drain it. */
async function drained(): Promise<void> {
  await new Promise((r) => setTimeout(r, 0));
  await new Promise((r) => setTimeout(r, 0));
}

describe("version pin", () => {
  test("refuses to load on any other Claude Code version and passes every wake through", async ($: Engine, on: On) => {
    const w = world(on, { version: "2.1.271", files: armedHome() });
    await $.session.start(sessionStart);
    expect(w.logs.some((l) => l.includes("refusing to load on Claude Code 2.1.271") && l.includes(PIN))).toBe(true);
    expect(w.registered).toEqual([]);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.submitted).toEqual([WAKE]);
    expect(w.completions.length).toBe(0);
    expect(w.appended(CLASSIFICATIONS)).toEqual([]);
  });

  test("loads on the pinned version and registers the report tools", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome() });
    await $.session.start(sessionStart);
    expect(w.logs.some((l) => l.includes(`loaded (enabled, home ${HOME}, Claude Code ${PIN})`))).toBe(true);
    expect(w.registered).toEqual(["fm_branch_report", "fm_branch_processed"]);
  });

  test("the binary hosting the session decides the pin when PATH claude differs", async ($: Engine, on: On) => {
    // The launcher execs the pinned binary by absolute path while the installer
    // symlink moved on: PATH answers a later release, the running binary the pin.
    const w = world(on, { version: "2.1.999", runningBinaryVersion: PIN, files: armedHome() });
    await $.session.start(sessionStart);
    expect(w.logs.some((l) => l.includes(`loaded (enabled, home ${HOME}, Claude Code ${PIN})`))).toBe(true);
    expect(w.registered).toEqual(["fm_branch_report", "fm_branch_processed"]);
    // The probe is issued first and answers, so PATH claude is never asked.
    expect(w.runs[0]?.argv).toEqual(["sh", "-c", 'exec "$(readlink /proc/$PPID/exe)" --version']);
    expect(w.runs.some((r) => r.argv[0] === "claude" && r.argv[1] === "--version")).toBe(false);
    // The load record names the source that decided and the probe's raw answer.
    const start = startEvent(w);
    expect(start?.data.version).toBe(PIN);
    expect(start?.data.pinSource).toBe("running binary");
    expect(start?.data.probe).toBe(`${PIN} (Claude Code)`);
  });

  test("a refusal records which source decided against the pin", async ($: Engine, on: On) => {
    const w = world(on, { version: PIN, runningBinaryVersion: "2.1.1", files: armedHome() });
    await $.session.start(sessionStart);
    const events = w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line));
    const refused = events.find((e) => e.kind === "pin.refused");
    expect(refused?.data).toEqual({ version: "2.1.1", pin: PIN, pinSource: "running binary", probe: "2.1.1 (Claude Code)" });
    expect(w.registered).toEqual([]);
  });

  test("PATH claude decides when the running binary's version is unavailable", async ($: Engine, on: On) => {
    // /proc is Linux-only: on a host without it the probe fails and the old
    // PATH call must still carry the pin check.
    const w = world(on, { version: PIN, runningBinaryVersion: "", files: armedHome() });
    await $.session.start(sessionStart);
    expect(w.logs.some((l) => l.includes(`loaded (enabled, home ${HOME}, Claude Code ${PIN})`))).toBe(true);
    expect(w.runs[0]?.argv[2]).toContain("/proc/$PPID/exe");
    expect(w.runs.some((r) => r.argv[0] === "claude" && r.argv[1] === "--version")).toBe(true);
    const start = startEvent(w);
    expect(start?.data.pinSource).toBe("PATH claude");
    expect(start?.data.probe).toBe("");
  });

  test("without state/.branch-mod-mode the module loads inert and passes every wake through unclassified", async ($: Engine, on: On) => {
    const files = armedHome();
    delete files[`${STATE}/.branch-mod-mode`];
    const w = world(on, { files });
    await $.session.start(sessionStart);
    expect(w.logs.some((l) => l.includes("loaded (inert: no state/.branch-mod-mode"))).toBe(true);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.submitted).toEqual([WAKE]);
    expect(w.completions.length).toBe(0);
  });
});

describe("transcript persistence log", () => {
  const persistence = (w: World) => {
    const start = startEvent(w);
    return { on: start?.data.persistenceOn, cause: start?.data.persistenceCause };
  };

  test("session.start logs the persistence state and its cause", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome() });
    await $.session.start(sessionStart);
    expect(persistence(w)).toEqual({ on: true, cause: "default" });
  });

  test("an inherited CLAUDE_CODE_CHILD_SESSION marker logs persistence off", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome(), env: { CLAUDE_CODE_CHILD_SESSION: "1" } });
    await $.session.start(sessionStart);
    expect(persistence(w)).toEqual({ on: false, cause: "inherited CLAUDE_CODE_CHILD_SESSION marker" });
  });

  test("CLAUDE_CODE_FORCE_SESSION_PERSISTENCE logs persistence on over the marker", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome(), env: { CLAUDE_CODE_CHILD_SESSION: "1", CLAUDE_CODE_FORCE_SESSION_PERSISTENCE: "1" } });
    await $.session.start(sessionStart);
    expect(persistence(w)).toEqual({ on: true, cause: "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE" });
  });
});

describe("classification log", () => {
  test("every classifier call appends one record with task, evidence byte offsets, verdict, and model", async ($: Engine, on: On) => {
    const w = world(on, {
      files: { ...armedHome(), [`${CONFIG}/classifier-model`]: "haiku-4-5\n" },
      classifierAnswer: 'Sure. {"verdict":"captain","reason":"a done line with a PR URL"}',
    });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });

    expect(w.completions.length).toBe(1);
    expect(w.completions[0].model).toBe("haiku-4-5");
    expect(w.completions[0].maxTokens).toBe(200);

    const records = w.appended(CLASSIFICATIONS).map((line) => JSON.parse(line));
    expect(records.length).toBe(1);
    expect(records[0].tasks).toEqual(["t1"]);
    expect(records[0].seqs).toEqual(["12"]);
    expect(records[0].evidence).toEqual([{ task: "t1", from: 0, to: 38 }]);
    expect(records[0].verdict).toBe("captain");
    expect(records[0].model).toBe("haiku-4-5");
    expect(records[0].reason).toBe("a done line with a PR URL");
  });

  test("the classifier model defaults to haiku when config/classifier-model is absent", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome() });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.completions[0].model).toBe("haiku");
    const records = w.appended(CLASSIFICATIONS).map((line) => JSON.parse(line));
    expect(records[0].model).toBe("haiku");
  });

  test("a captain verdict passes the wake to main and writes a covering captain outcome row", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome(), classifierAnswer: '{"verdict":"captain","reason":"terminal line"}' });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    expect(cover !== undefined).toBe(true);
    expect(cover!.argv).toContain("--task");
    expect(cover!.argv[cover!.argv.indexOf("--task") + 1]).toBe("t1");
    expect(cover!.argv[cover!.argv.indexOf("--verdict") + 1]).toBe("captain");
    // No wake was granted here, so there is no in-flight wake identity to stamp.
    expect(cover!.argv).not.toContain("--wake-key");
    // Main handles the wake itself, so the branch was never granted or spawned.
    expect(w.submitted).toEqual([WAKE]);
    expect(w.runs.some((r) => r.argv[1]?.endsWith("fm-wake-grant.sh") && r.argv[2] === "publish")).toBe(false);
  });

  test("a passed wake main never acknowledged is passed again once the dedupe window has elapsed", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome(), classifierAnswer: '{"verdict":"captain","reason":"terminal line"}' });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.submitted).toEqual([WAKE]);
    // The Stop hook re-blocks with the same banner while row 12 still sits in the queue.
    await w.clock.advance(91_000);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(1);
    expect(w.submitted).toEqual([WAKE, WAKE]);
  });

  test("a passed row still queued after a restart goes back to main unclassified, even though its line is HISTORY to the classifier now", async ($: Engine, on: On) => {
    const w = world(on, {
      files: armedHome(),
      classifierAnswer: ['{"verdict":"captain","reason":"terminal line"}', '{"verdict":"routine","reason":"only a working line is new"}'],
      evidence: ["## task t1 status bytes 0-38\nNEW\n  done: PR https://x/1 checks green\n", "## task t1 status bytes 38-49\nHISTORY\n  done: PR https://x/1 checks green\nNEW\n  working: b\n"],
    });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.submitted).toEqual([WAKE]);
    expect(w.completions.length).toBe(1);
    // Main's turn was interrupted before its drain: row 12 is still queued when
    // the next close adds row 13, and the session restarts in between.
    w.files.set(`${STATE}/t1.status`, "working: a\ndone: PR https://x/1 checks green\nworking: b\n");
    w.files.set(`${STATE}/.wake-queue`, "1700000000\t12\tsignal\tt1.status\tdone: PR https://x/1 checks green\n1700000060\t13\tsignal\tt1.status\tworking: b\n");
    await w.clock.advance(91_000);
    await $.session.start(sessionStart);
    const before = w.runs.length;
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.submitted).toEqual([WAKE, WAKE]);
    expect(w.completions.length).toBe(1);
    expect(w.runs.some((r) => r.argv[1]?.endsWith("fm-wake-grant.sh") && r.argv[2] === "publish")).toBe(false);
    // The re-pass hands row 13 to main as a classifier pass would: its offset advances and a cover row is written.
    const after = w.runs.slice(before);
    expect(after.some((r) => r.argv[1]?.endsWith("fm-wake-evidence.sh") && r.argv[2] === "t1")).toBe(true);
    const cover = after.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    expect(cover !== undefined).toBe(true);
    expect(cover!.argv[cover!.argv.indexOf("--task") + 1]).toBe("t1");
    expect(cover!.argv[cover!.argv.indexOf("--verdict") + 1]).toBe("captain");
    expect(JSON.parse(w.files.get(`${STATE}/.branch-mod-passed`) ?? "[]")).toEqual(["12", "13"]);
    // Once main acknowledges (the rows leave the queue) the record is pruned and the classifier runs again.
    w.files.set(`${STATE}/.wake-queue`, "1700000120\t14\tsignal\tt1.status\tworking: c\n");
    await w.clock.advance(91_000);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(2);
    expect(JSON.parse(w.files.get(`${STATE}/.branch-mod-passed`) ?? "[]")).toEqual([]);
  });

  test("an unsafe scan keeps the durable passed guard, so main still owns the passed rows once the queue reads cleanly again", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome(), classifierAnswer: '{"verdict":"captain","reason":"terminal line"}' });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(1);
    expect(JSON.parse(w.files.get(`${STATE}/.branch-mod-passed`) ?? "[]")).toEqual(["12"]);
    // A partially written row lands behind the still-queued passed row.
    w.files.set(`${STATE}/.wake-queue`, "1700000000\t12\tsignal\tt1.status\tdone: PR https://x/1 checks green\nnot-an-epoch\t13\tsignal\tt1.status\tworking: b\n");
    await w.clock.advance(91_000);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.submitted).toEqual([WAKE, WAKE]);
    expect(w.completions.length).toBe(1);
    expect(JSON.parse(w.files.get(`${STATE}/.branch-mod-passed`) ?? "[]")).toEqual(["12"]);
  });

  test("a stale row keyed by the task's window resolves to the task id for the offset advance and the cover row", async ($: Engine, on: On) => {
    const files = {
      ...armedHome(),
      [`${STATE}/t1.status`]: "working: a\nneeds-decision: [key=choice-1] pick one\n",
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    };
    const w = world(on, { files });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: `<summary>Stop hook feedback</summary>\nfirstmate watcher wake\nstale: fm-t1\n`, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(0);
    const evidence = w.runs.filter((r) => r.argv[1]?.endsWith("fm-wake-evidence.sh"));
    expect(evidence.map((r) => r.argv[2])).toEqual(["t1"]);
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    expect(cover !== undefined).toBe(true);
    expect(cover!.argv[cover!.argv.indexOf("--task") + 1]).toBe("t1");
    expect(w.runs.some((r) => r.argv.includes("fm-t1"))).toBe(false);
  });
});

// The open-decision fold v8 rules the mod ports from bin/fm-classify-lib.sh
// (_fm_decision_fold_line, last_status_line): a done:/failed: declaration closes
// the whole open set for ship and scout tasks but never for a secondmate, and
// the captain-held verdict reads the latest RECOGNIZED status event, not the
// last non-blank line. A stale wake on an owned task is passed straight to main
// (never classified, one covering captain outcome row); an unowned one is
// eligible and reaches the classifier.
describe("open-decision fold v8", () => {
  const STALE_WAKE = `<summary>Stop hook feedback</summary>\nfirstmate watcher wake\nstale: fm-t1\n`;

  function staleHome(status: string, kind?: string): Record<string, string> {
    return {
      [`${STATE}/.branch-mod-mode`]: "",
      [`${STATE}/.lock`]: "4242\n",
      [`${STATE}/t1.meta`]: `project=demo\nwindow=fm-t1\n${kind ? `kind=${kind}\n` : ""}`,
      [`${STATE}/t1.status`]: status,
      [`${STATE}/.wake-queue`]: "1700000000\t13\tstale\tfm-t1\tpane quiet\n",
    };
  }

  test("a done: line closes an open decision for a ship task, so the stale wake is classified instead of passed", async ($: Engine, on: On) => {
    const w = world(on, { files: staleHome("needs-decision: [key=c1] pick one\ndone: shipped the branch\n") });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(1);
    expect(w.runs.some((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append")).toBe(false);
  });

  test("a failed: line closes an open decision for a scout task", async ($: Engine, on: On) => {
    const w = world(on, { files: staleHome("needs-decision: [key=c1] pick one\nfailed: upstream rejected the approach\n", "scout") });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(1);
    expect(w.runs.some((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append")).toBe(false);
  });

  test("a secondmate's done: line cannot close an open decision", async ($: Engine, on: On) => {
    const w = world(on, { files: staleHome("needs-decision: [key=c1] pick one\ndone: other work finished\n", "secondmate") });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(0);
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    expect(cover !== undefined).toBe(true);
    expect(cover!.argv[cover!.argv.indexOf("--task") + 1]).toBe("t1");
    expect(cover!.argv[cover!.argv.indexOf("--verdict") + 1]).toBe("captain");
  });

  test("continuation prose after a captain-held: line does not un-hold the task (latest event, not last line)", async ($: Engine, on: On) => {
    const w = world(on, { files: staleHome("needs-decision: [key=c1] pick one\ncaptain-held [key=c1]: filed for the captain\nwaiting on the captain to pick\n") });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(0);
    const cover = w.runs.find((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append");
    expect(cover !== undefined).toBe(true);
    expect(cover!.argv[cover!.argv.indexOf("--verdict") + 1]).toBe("captain");
  });

  test("a working: line after a captain-held: line un-holds the task", async ($: Engine, on: On) => {
    const w = world(on, { files: staleHome("captain-held [key=c1]: filed for the captain\nworking: resumed while the captain thinks\n") });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: STALE_WAKE, origin: { kind: "task-notification" } });
    expect(w.completions.length).toBe(1);
    expect(w.runs.some((r) => r.argv[1]?.endsWith("fm-branch-outcome.sh") && r.argv[2] === "append")).toBe(false);
  });
});

describe("routine wake", () => {
  test("a routine verdict grants the wake and spawns the one persistent branch agent", async ($: Engine, on: On) => {
    const w = world(on, { files: armedHome() });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    // The kit's spawn answer carries no agentId, so the module cannot adopt
    // the agent here and hands the wake back to main; the live test
    // (tests/fm-branch-claude-mod-live-e2e.test.sh) is where the drop is
    // asserted. What the kit can prove is the grant and the spawn request.
    const publish = w.runs.find((r) => r.argv[1]?.endsWith("fm-wake-grant.sh") && r.argv[2] === "publish");
    expect(publish !== undefined).toBe(true);
    expect(publish!.argv.slice(-1)).toEqual(["12"]);
    expect(w.spawns.length).toBe(1);
    expect(w.spawns[0].subagentType).toBe("fm-branch-mod:fm-branch");
    expect(w.spawns[0].name).toBe("fm-branch");
    expect(w.spawns[0].background).toBe(true);
    expect(w.spawns[0].prompt?.startsWith("FIRSTMATE SUPERVISION WAKE: signal:")).toBe(true);
    expect(w.spawns[0].prompt?.includes("No earlier outcome exists for t1")).toBe(true);
    const records = w.appended(CLASSIFICATIONS).map((line) => JSON.parse(line));
    expect(records.length).toBe(1);
    expect(records[0].verdict).toBe("routine");
  });

  test("an unresumable branch agent rotates to a fresh named agent instead of re-sending to the dead one", async ($: Engine, on: On) => {
    // A bridge primary runs with transcript saving off, so SendMessage answers
    // this for every later wake; the module must rotate, not re-send or pass.
    const unresumable = '{"success":false,"message":"Agent \\"fm-branch\\" could not be resumed: No transcript found for agent ID: ade34056fb4d9ab91"}';
    const counters = { lockPid: "4242", wakeCounter: 1, spawnCount: 1, sendCount: 1, branchGeneration: 1, branchAgentId: "ade34056fb4d9ab91" };
    const w = world(on, {
      files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: JSON.stringify(counters) },
      sendAnswer: unresumable,
    });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    // Exactly one send against the dead agent, then one rotation spawn under
    // the next generation name (branchName() suffixes every generation above
    // 1). The kit's spawn answer carries no agentId, so the wake then passes
    // via the rotation's own spawn failure, exactly as a failed rotation must.
    const sends = w.toolCalls.filter((c) => (c as { tool?: string }).tool === "SendMessage");
    expect(sends.length).toBe(1);
    expect(w.spawns.length).toBe(1);
    expect(w.spawns[0].subagentType).toBe("fm-branch-mod:fm-branch");
    expect(w.spawns[0].name).toBe("fm-branch-2");
    expect(w.spawns[0].prompt?.startsWith("FIRSTMATE SUPERVISION WAKE: signal:")).toBe(true);
    const events = w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line));
    const rotated = events.find((e) => e.kind === "agent.rotated");
    // The send log names the resume target: the dead agent's id and the
    // primary session whose transcript resume would read.
    const send = events.find((e) => e.kind === "agent.send");
    expect(send?.data.agentId).toBe("ade34056fb4d9ab91");
    expect(send?.data.sessionId).toBe(SESSION_ID);
    expect(rotated?.data.why).toBe("unresumable");
    expect(rotated?.data.name).toBe("fm-branch-2");
    expect(rotated?.data.branchGeneration).toBe(2);
    expect(rotated?.data.sendDetail).toContain("could not be resumed");
    // The defect this pins: an unresumable agent never passes the wake to main
    // as a failed send again; only the rotation's own spawn failure can.
    expect(events.some((e) => e.kind === "wake.passed" && String(e.data.why).includes("delivery failed via send"))).toBe(false);
    // The dead agent id is dropped durably and the generation advanced, so the
    // next wake cannot re-adopt the unresumable agent.
    const saved = JSON.parse(w.files.get(`${STATE}/.branch-mod-counters`) ?? "{}");
    expect(saved.branchAgentId).toBe("");
    expect(saved.branchGeneration).toBe(2);
  });

  test("a SendMessage denied with the unresumable text also rotates", async ($: Engine, on: On) => {
    // The same resume failure surfaced as a hook deny (or thrown error) has no
    // result text; the deny string must be classified, not the empty text.
    const counters = { lockPid: "4242", wakeCounter: 1, spawnCount: 1, sendCount: 1, branchGeneration: 1, branchAgentId: "ade34056fb4d9ab91" };
    const w = world(on, {
      files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: JSON.stringify(counters) },
      sendDeny: 'Agent "fm-branch" could not be resumed: No transcript found for agent ID: ade34056fb4d9ab91',
    });
    await $.session.start(sessionStart);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    expect(w.toolCalls.filter((c) => (c as { tool?: string }).tool === "SendMessage").length).toBe(1);
    expect(w.spawns.length).toBe(1);
    expect(w.spawns[0].name).toBe("fm-branch-2");
    const events = w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line));
    expect(events.find((e) => e.kind === "agent.rotated")?.data.why).toBe("unresumable");
    expect(events.some((e) => e.kind === "wake.passed" && String(e.data.why).includes("delivery failed via send"))).toBe(false);
  });
});

// Watcher continuity must not depend on a captain prompt: the Monitor is armed
// at session start (mode file present, session lock held), re-checked on every
// handled prompt.submit so a lost expiry notice recovers, and re-armed from the
// branch's own settlement - a branch-absorbed wake always leaves one live cycle
// behind. The 2026-09-19 gap: a module reload with no captain prompt after it
// left no Monitor at all, the Stop-hook wake was absorbed and acknowledged by
// the branch, main's Stop hook never fired, and no watcher cycle ran for hours.
describe("watcher continuity", () => {
  const monitorEvents = (w: World) =>
    w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line)).filter((e) => e.kind === "monitor.armed");

  // The kit's branch-absorption path: counters from a prior spawn plus a send
  // answer that names the resumed agent id let deliverToBranch adopt the named
  // agent, so a wake is truly absorbed and its turn.complete is a branch turn.
  const adoptionCounters = JSON.stringify({ lockPid: "4242", wakeCounter: 1, spawnCount: 1, sendCount: 1, branchGeneration: 1, branchAgentId: "" });
  const SEND_ADOPTS = '{"success":true,"resumedAgentId":"branch-agent-1"}';
  const REPORT_CALL = { tool: "mcp__fm-branch-mod__fm_branch_report", agentId: "branch-agent-1", task: "t1", verdict: "routine", summary: "handled" } as const;

  test("a stop-hook wake routed to the branch leaves one armed monitor behind, with no captain prompt ever submitted", async ($: Engine, on: On) => {
    // evidence "" keeps the routine backstop silent after the branch reports.
    const w = world(on, { files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: adoptionCounters }, sendAnswer: SEND_ADOPTS, evidence: [""] });
    await $.session.start(sessionStart);
    await drained();
    // Armed at session start, before any prompt exists to arm from.
    expect(monitorEvents(w).map((e) => e.data.why)).toEqual(["session start"]);
    // The wake is absorbed by the branch agent via the adoption send.
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    expect(monitorEvents(w).map((e) => e.data.why)).toEqual(["session start"]);
    expect(w.submitted).toEqual([]);
    // The branch reports the wake handled through the mod's report tool. Its
    // settlement is a branch turn: the claim stays true, nothing double-arms.
    await $.tool.call(REPORT_CALL);
    try {
      await $.turn.complete({ agentId: "branch-agent-1", reason: "stop", usage: { input_tokens: 10 }, answer: "handled" });
    } catch {
      // The kit has no turn.complete implementation to stub - the real one is
      // the engine's own model loop - but the module's hook above already ran.
    }
    await drained();
    expect(monitorEvents(w).map((e) => e.data.why)).toEqual(["session start"]);
    // The wake never opened a main turn.
    expect(w.submitted).toEqual([]);
  });

  test("a session start that cannot arm records why in the event log", async ($: Engine, on: On) => {
    // The mode file is on but the SessionStart shell hook has not written the
    // lock yet: no arm, and the log says so instead of leaving no trace.
    const { [`${STATE}/.lock`]: _lock, ...noLock } = armedHome();
    const w = world(on, { files: noLock });
    await $.session.start(sessionStart);
    await drained();
    expect(monitorEvents(w)).toEqual([]);
    const skipped = w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line)).filter((e) => e.kind === "monitor.skipped");
    expect(skipped.map((e) => e.data)).toEqual([{ why: "session start", mode: true, lockPid: "" }]);
  });

  test("a lost expiry notice recovers at the next prompt.submit once the armed claim is older than the monitor timeout", async ($: Engine, on: On) => {
    const w = world(on, { files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: adoptionCounters }, sendAnswer: SEND_ADOPTS, evidence: [""] });
    await $.session.start(sessionStart);
    await drained();
    expect(monitorEvents(w).map((e) => e.data.taskId)).toEqual(["m1"]);
    // Inside the monitor's lifetime the claim holds: no second loop.
    await w.clock.advance(10 * 60_000);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    expect(monitorEvents(w).map((e) => e.data.taskId)).toEqual(["m1"]);
    // m1 has long since expired and its notice never arrived: the claim is
    // stale, so the next wake arms a fresh cycle instead of honouring it.
    await w.clock.advance(30 * 60_000);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    expect(monitorEvents(w).map((e) => [e.data.why, e.data.taskId])).toEqual([
      ["session start", "m1"],
      ["stop-hook wake without monitor", "m2"],
    ]);
    expect(JSON.parse(w.files.get(`${STATE}/.branch-mod-counters`) ?? "{}").monitorTaskId).toBe("m2");
    expect(w.submitted).toEqual([]);
  });

  test("a restored claim with no recorded arm time is honoured for one monitor lifetime, never expired at once", async ($: Engine, on: On) => {
    // Counters written by the previous module version name the live monitor
    // but carry no monitorArmedAt: session start must not start a second loop.
    const legacy = JSON.stringify({ ...JSON.parse(adoptionCounters), monitorTaskId: "m-old" });
    const w = world(on, { files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: legacy }, sendAnswer: SEND_ADOPTS, evidence: [""] });
    await $.session.start(sessionStart);
    await drained();
    expect(monitorEvents(w)).toEqual([]);
    await w.clock.advance(40 * 60_000);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    expect(monitorEvents(w).map((e) => [e.data.why, e.data.taskId])).toEqual([["stop-hook wake without monitor", "m1"]]);
  });

  test("a monitor arm that failed recovers at the next prompt.submit, with no expiry notice ever arriving", async ($: Engine, on: On) => {
    // The session-start arm is denied: the claim is false and, the monitor
    // never having started, no expiry notice will ever arrive to re-arm it.
    const w = world(on, { files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: adoptionCounters }, sendAnswer: SEND_ADOPTS, monitorDenyFirst: 1 });
    await $.session.start(sessionStart);
    await drained();
    expect(monitorEvents(w)).toHaveLength(1);
    expect(monitorEvents(w)[0].data.why).toBe("session start");
    expect(monitorEvents(w)[0].data.deny).toBe(MONITOR_DENY);
    // The next prompt.submit is the wake itself: it re-arms before routing.
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    const events = monitorEvents(w);
    expect(events).toHaveLength(2);
    expect(events[1].data.why).toBe("stop-hook wake without monitor");
    expect(events[1].data.deny).toBeUndefined();
    // The wake was still routed to the branch, not passed to main.
    expect(w.submitted).toEqual([]);
  });

  test("a branch-absorbed wake settled with the claim still false arms from the settlement path", async ($: Engine, on: On) => {
    // Both the session-start arm and the wake's own arm fail; an arm failure
    // never blocks routing, so the branch still absorbs the wake. Settlement
    // is the last hand that can leave a live cycle behind, and it does.
    const w = world(on, { files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: adoptionCounters }, sendAnswer: SEND_ADOPTS, monitorDenyFirst: 2 });
    await $.session.start(sessionStart);
    // Let the session-start arm settle before the wake, so the wake's own arm
    // is a distinct attempt and not swallowed by the arming claim.
    await drained();
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    try {
      await $.turn.complete({ agentId: "branch-agent-1", reason: "stop", usage: { input_tokens: 10 }, answer: "handled" });
    } catch {
      // The kit has no turn.complete implementation to stub; the hook above ran.
    }
    await drained();
    expect(monitorEvents(w).map((e) => [e.data.why, e.data.deny ?? null])).toEqual([
      ["session start", MONITOR_DENY],
      ["stop-hook wake without monitor", MONITOR_DENY],
      ["branch settled without monitor", null],
    ]);
    // The durable claim now names the live monitor task.
    expect(JSON.parse(w.files.get(`${STATE}/.branch-mod-counters`) ?? "{}").monitorTaskId).toBe("m3");
  });
});

// The provider-error latch's wiring: turn.complete feeds the shared machine
// (../lib/fm-branch-provider-latch.ts, the canonical copy the repo's lib/
// symlinks to), turn.start honours its admission verdict, and the ui log
// renders from the machine's structured verdicts - never from host-side
// counting. The machine's own schedules (threshold, doubling, probes,
// recovery) are pinned against the repo's lib leg in
// tests/fm-branch-report-sequence.test.sh; only the host wiring lives here.
describe("provider-error latch", () => {
  // Same adoption pattern as watcher continuity: counters plus a send answer
  // naming the resumed agent let the wake be absorbed, so its turn.complete is
  // a branch turn.
  const latchCounters = JSON.stringify({ lockPid: "4242", wakeCounter: 1, spawnCount: 1, sendCount: 1, branchGeneration: 1, branchAgentId: "" });
  const SEND_ADOPTS_LATCH = '{"success":true,"resumedAgentId":"branch-agent-1"}';
  const REPORT_HANDLED = { tool: "mcp__fm-branch-mod__fm_branch_report", agentId: "branch-agent-1", task: "t1", verdict: "routine", summary: "handled" } as const;

  const settle = async ($: Engine, reason: string) => {
    try {
      await $.turn.complete({ agentId: "branch-agent-1", reason, usage: { input_tokens: 10 }, answer: "settled" });
    } catch {
      // The kit has no turn.complete implementation to stub; the hook above ran.
    }
    await drained();
  };
  const passReasons = (w: World) =>
    w.appended(`${STATE}/branch-mod-events.jsonl`).map((line) => JSON.parse(line)).filter((e) => e.kind === "wake.passed").map((e) => `${e.data.why}:${e.data.source}`);
  const sendCalls = (w: World) => w.toolCalls.filter((c) => c.tool === "SendMessage");

  test("two provider-error turns latch the branch off, latched wakes pass to main, and the cooldown and a clean settlement both recover it", async ($: Engine, on: On) => {
    const w = world(on, { files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: latchCounters }, sendAnswer: SEND_ADOPTS_LATCH, evidence: [""] });
    await $.session.start(sessionStart);
    await drained();

    // First provider-error turn: counted, not latched - the next wake still
    // reaches the branch.
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    await settle($, "error");
    expect(passReasons(w)).toEqual([]);

    // Second provider-error turn: the machine latches and the host renders its
    // note from the structured verdict. The failure path's fallback prompt
    // embeds the wake text and re-routes; the admission gate sits above reason
    // parsing in routeWake, so that fallback passes as latched too.
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    await settle($, "error");
    expect(w.logs.join("\n")).toContain("branch latched off for 5 minutes after 2 consecutive failures; wakes go to main");
    expect(passReasons(w)).toEqual(["latched:post-release"]);

    // While latched, the next wake passes to main unclassified and no branch
    // send is attempted beyond the two adoptions above.
    const sendsWhenLatched = sendCalls(w).length;
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    expect(passReasons(w)).toEqual(["latched:post-release", "latched:stop-hook"]);
    expect(sendCalls(w).length).toBe(sendsWhenLatched);

    // Inside the cooldown nothing changes.
    await w.clock.advance(60_000);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    expect(passReasons(w)).toEqual(["latched:post-release", "latched:stop-hook", "latched:stop-hook"]);
    expect(sendCalls(w).length).toBe(sendsWhenLatched);

    // Well past the fixed five-minute deadline (clock advances include the
    // engine's simulated latencies, so overshoot), the branch is admitted
    // again, and a clean settlement recovers it fully.
    await w.clock.advance(400_000);
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    expect(passReasons(w)).toEqual(["latched:post-release", "latched:stop-hook", "latched:stop-hook"]);
    await $.tool.call(REPORT_HANDLED);
    await settle($, "stop");
    expect(passReasons(w)).toEqual(["latched:post-release", "latched:stop-hook", "latched:stop-hook"]);

    // A recovered latch starts counting from zero: one failure stays open (its
    // fallback re-route finds no unread rows and is dropped, not passed).
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    await settle($, "error");
    expect(passReasons(w)).toEqual(["latched:post-release", "latched:stop-hook", "latched:stop-hook"]);
    expect(w.logs.join("\n")).not.toContain("after 3 consecutive failures");

    // And two fresh failures latch again with a fresh five-minute term.
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    await settle($, "error");
    expect(w.logs.join("\n")).toContain("branch latched off for 5 minutes after 2 consecutive failures; wakes go to main");
  });

  test("a failed turn that still reported is a provider error; a report-less stop is also a failure; a healthy report resets", async ($: Engine, on: On) => {
    const w = world(on, { files: { ...armedHome(), [`${STATE}/.branch-mod-counters`]: latchCounters }, sendAnswer: SEND_ADOPTS_LATCH, evidence: [""] });
    await $.session.start(sessionStart);
    await drained();

    // A report-less stop counts as one failure (the no-report seam).
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    await settle($, "stop");
    expect(passReasons(w)).toEqual([]);

    // A healthy reported turn resets the count: the next report-less stop is
    // failure one again, so the branch never latches across these three turns.
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    await $.tool.call(REPORT_HANDLED);
    await settle($, "stop");
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    await settle($, "stop");
    await $.prompt.submit({ text: WAKE, origin: { kind: "task-notification" } });
    await drained();
    await settle($, "stop");
    expect(passReasons(w)).toEqual([]);
    expect(w.logs.join("\n")).not.toContain("branch latched off");
  });
});
