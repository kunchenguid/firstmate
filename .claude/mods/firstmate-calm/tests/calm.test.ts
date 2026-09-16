// firstmate-calm under `claude plugin test`: the Calm toggle, its persisted per-home
// preference, and the transcript rows Calm hides and restores.
import { describe, expect, test, type Engine } from "claude-code/testing";
import {
  assistantMessage,
  calmCommand,
  fromFirstmate,
  HOME,
  isHidden,
  isStock,
  operational,
  PREFERENCE,
  spinner,
  toolGroup,
  toolResult,
  toolUse,
  userMessage,
  world,
} from "./support.ts";

const sessionStart = { cwd: "/work", surface: "terminal" as const, isInteractive: true };

describe("activation", () => {
  async function expectInert($: Engine, on: Parameters<typeof world>[0], functionHooks: string | undefined) {
    const { clock, journal } = world(on, {
      functionHooks,
      preference: "on\n",
      messages: [{ role: "assistant", text: "Working", toolUses: [{ name: "Bash" }] }],
    });
    await $.session.start(sessionStart);
    const drawings = await Promise.all([
      $.ui.render(spinner()),
      $.ui.render(toolUse()),
      $.ui.render(toolResult()),
      $.ui.render(toolGroup()),
      $.ui.render(userMessage(operational("watcher", "signal: x"))),
      $.ui.render(assistantMessage("Working")),
    ]);
    expect(drawings.every(isStock)).toBe(true);
    await clock.advance(220 * 8);
    expect(journal.commands).toHaveLength(0);
    expect(journal.blits).toHaveLength(0);
    expect(journal.invalidations).toHaveLength(0);
    expect(journal.toasts).toHaveLength(0);
    expect(journal.fsReads).toHaveLength(0);
    expect(journal.sessionMessageReads).toBe(0);
    expect(journal.configLists).toBe(0);
  }

  test("is fully inert when the function-hooks opt-in is absent", async ($, on) => {
    await expectInert($, on, undefined);
  });

  test("is fully inert when the function-hooks opt-in is not exactly one", async ($, on) => {
    await expectInert($, on, "true");
  });

  test("registers /calm at session start and stays a pass-through while off", async ($, on) => {
    const { clock, journal } = world(on);
    await $.session.start(sessionStart);
    expect(journal.commands).toEqual(["calm"]);
    expect(isStock(await $.ui.render(spinner()))).toBe(true);
    expect(isStock(await $.ui.render(toolUse()))).toBe(true);
    expect(isStock(await $.ui.render(toolResult()))).toBe(true);
    expect(isStock(await $.ui.render(toolGroup()))).toBe(true);
    expect(isStock(await $.ui.render(userMessage(operational("watcher", "signal: x"))))).toBe(true);
    expect(isStock(await $.ui.render(assistantMessage("hello")))).toBe(true);
    await clock.advance(220 * 8);
    expect(journal.blits).toHaveLength(0);
    expect(journal.toasts).toHaveLength(0);
  });

  test("reads a persisted on before session start, so restored rows never draw with a stale off", async ($, on) => {
    world(on, { preference: "on\n" });
    expect(isHidden(await $.ui.render(toolUse()))).toBe(true);
    expect(isHidden(await $.ui.render(toolGroup()))).toBe(true);
  });

  test("reads the legacy max value as on", async ($, on) => {
    world(on, { preference: "max\n" });
    expect(isHidden(await $.ui.render(toolResult()))).toBe(true);
  });

  test("reads an unrecognized value as off", async ($, on) => {
    world(on, { preference: "maybe\n" });
    expect(isStock(await $.ui.render(toolUse()))).toBe(true);
  });
});

describe("/calm", () => {
  test("toggles on: persists on, toasts, redraws every hooked drawing, and leaves no output row", async ($, on) => {
    const { files, journal } = world(on);
    await $.session.start(sessionStart);
    expect(isStock(await $.ui.render(toolUse()))).toBe(true);
    const answer = await $.command.run(calmCommand());
    expect(answer.text).toBeUndefined();
    expect(files.get(PREFERENCE)).toBe("on\n");
    expect(journal.toasts).toEqual(["Calm on"]);
    expect(journal.invalidations).toContain("ui.render");
    expect(isHidden(await $.ui.render(toolUse()))).toBe(true);
    expect(isHidden(await $.ui.render(toolResult()))).toBe(true);
    expect(isHidden(await $.ui.render(toolGroup("g", true)))).toBe(true);
  });

  test("toggles off: persists off and restores the engine's drawings", async ($, on) => {
    const { files, journal } = world(on, { preference: "on\n" });
    await $.session.start(sessionStart);
    expect(isHidden(await $.ui.render(toolUse()))).toBe(true);
    await $.command.run(calmCommand());
    expect(files.get(PREFERENCE)).toBe("off\n");
    expect(journal.toasts).toEqual(["Calm off"]);
    expect(isStock(await $.ui.render(toolUse()))).toBe(true);
    expect(isStock(await $.ui.render(spinner()))).toBe(true);
  });

  test("keeps the current choice when the preference cannot be written", async ($, on) => {
    const { files, journal, failWrites } = world(on, { preference: "on\n" });
    await $.session.start(sessionStart);
    const redrawsBefore = journal.invalidations.length;
    failWrites("EACCES: read-only");
    await $.command.run(calmCommand());
    expect(files.get(PREFERENCE)).toBe("on\n");
    expect(isHidden(await $.ui.render(toolUse()))).toBe(true);
    expect(journal.toasts).toHaveLength(1);
    expect(journal.toasts[0]).toContain("Calm unchanged");
    expect(journal.toasts[0]).toContain(PREFERENCE);
    expect(journal.invalidations).toHaveLength(redrawsBefore);
  });

  test("writes under FM_CONFIG_OVERRIDE when that override names the config directory", async ($, on) => {
    const { files } = world(on, { env: { FM_CONFIG_OVERRIDE: "/elsewhere/cfg" } });
    await $.command.run(calmCommand());
    expect(files.get("/elsewhere/cfg/calm")).toBe("on\n");
    expect(files.has(PREFERENCE)).toBe(false);
  });

  test("falls back to FM_ROOT_OVERRIDE, then the tracked code root above the plugin, when FM_HOME is unset", async ($, on) => {
    const { files } = world(on, { home: undefined, env: { FM_ROOT_OVERRIDE: "/root/override" } });
    await $.command.run(calmCommand());
    expect(files.get("/root/override/config/calm")).toBe("on\n");
  });

  test("derives the home from the plugin folder when nothing names it", async ($, on) => {
    const { files } = world(on, { home: undefined });
    await $.command.run(calmCommand());
    const [path] = [...files.keys()];
    expect(path).toBeDefined();
    expect(path!).toEndWith("/config/calm");
    expect(path!.startsWith(HOME)).toBe(false);
    // Three levels above the plugin folder: the tracked code root, above `.claude/`.
    expect(path!).not.toContain("firstmate-calm/");
    expect(path!).not.toContain("/.claude/");
    expect(path!).not.toContain("/mods/");
  });
});

describe("operational user rows", () => {
  const hiddenTexts = [
    operational("session-start", "Run bin/fm-session-start.sh"),
    operational("watcher", "signal: /tmp/x.status changed"),
    operational("turn-end-guard", "supervision is off"),
    operational("away-supervisor", "escalate"),
    operational("launch-brief", "# Task"),
    operational("branch-outcome", "note"),
    operational("watcher", "multi\nline\n\nbody"),
    fromFirstmate("please look at the report"),
    // An unknown kind under the current prefix is the untyped legacy envelope.
    "\u2063FIRSTMATE_OP: unknown shape",
    "Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.",
    "FIRSTMATE WATCHER WAKE: signal: x\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.",
    "\u2063Supervisor escalate (needs you)",
    // A current prefix with no readable kind or body is the untyped legacy envelope.
    operational("watcher", "").replace(/ $/, ""),
  ];
  const visibleTexts = [
    "hello there",
    "'\u2063FIRSTMATE_OP: v1 watcher: quoted'",
    "FIRSTMATE_OP: v1 watcher: ascii only",
    "look: \u2063FIRSTMATE_OP: v1 watcher: text before the marker",
    "[fm-from-firstmate]\u2063",
    "\u2063FIRSTMATE_OP: ",
    "FIRSTMATE WATCHER WAKE: \n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.",
  ];

  test("hides every canonically classified operational input while on", async ($, on) => {
    world(on, { preference: "on\n" });
    for (const text of hiddenTexts) {
      expect(isHidden(await $.ui.render(userMessage(text))), JSON.stringify(text)).toBe(true);
    }
  });

  test("keeps every near miss and genuine prompt visible while on", async ($, on) => {
    world(on, { preference: "on\n" });
    for (const text of visibleTexts) {
      expect(isStock(await $.ui.render(userMessage(text))), JSON.stringify(text)).toBe(true);
    }
  });

  test("leaves every user row to the engine while off", async ($, on) => {
    world(on);
    for (const text of [...hiddenTexts, ...visibleTexts]) {
      expect(isStock(await $.ui.render(userMessage(text))), JSON.stringify(text)).toBe(true);
    }
  });
});

describe("mid-turn working notes", () => {
  type Chunk =
    | { kind: "text"; index: number; text: string }
    | { kind: "tool"; index: number; id: string; name: string }
    | { kind: "stop"; stopReason: string | null; usage: null };

  type Scenario = {
    chunks: Chunk[];
    result: { answer: string; toolUses: { name: string; input: unknown }[]; stopReason: string | null };
  };

  // The hooks beneath the plugin must exist before the test first calls `$`, so one
  // bottom step serves every scenario a test sets before each run.
  function stepper(on: Parameters<typeof world>[0]) {
    const scenario: Scenario = { chunks: [], result: { answer: "", toolUses: [], stopReason: null } };
    on("turn.step", async function* (_$, e) {
      for (const chunk of scenario.chunks) yield chunk as never;
      return { turnId: e.turnId, index: e.index, usage: null, ...scenario.result } as never;
    });
    return (next: Scenario) => {
      scenario.chunks = next.chunks;
      scenario.result = next.result;
    };
  }

  async function runStep($: Engine, agentId?: string) {
    const stream = $.turn.step({ turnId: "turn-1", index: 0, model: "haiku", messageCount: 1, ...(agentId === undefined ? {} : { agentId }) });
    const seen: unknown[] = [];
    let step = await stream.next();
    while (!step.done) {
      seen.push(step.value);
      step = await stream.next();
    }
    return { seen, result: step.value as { answer: string; stopReason: string | null } };
  }

  test("hides the text blocks of a step that stopped to call tools, and forwards the stream untouched", async ($, on) => {
    const { journal } = world(on, { preference: "on\n" });
    const set = stepper(on);
    set({
      chunks: [
        { kind: "text", index: 0, text: "Let me " },
        { kind: "text", index: 0, text: "look first." },
        { kind: "tool", index: 1, id: "t1", name: "Bash" },
        { kind: "text", index: 2, text: "Then I read it." },
        { kind: "stop", stopReason: "tool_use", usage: null },
      ],
      result: { answer: "Let me look first.\nThen I read it.", toolUses: [{ name: "Bash", input: {} }], stopReason: "tool_use" },
    });
    expect(isStock(await $.ui.render(assistantMessage("Let me look first.")))).toBe(true);
    const { seen, result } = await runStep($);
    expect(seen).toHaveLength(5);
    expect(result.answer).toBe("Let me look first.\nThen I read it.");
    expect(journal.invalidations).toContain("ui.render");
    expect(isHidden(await $.ui.render(assistantMessage("Let me look first.")))).toBe(true);
    expect(isHidden(await $.ui.render(assistantMessage("Then I read it.\n")))).toBe(true);
    expect(isHidden(await $.ui.render(assistantMessage("Let me look first.\nThen I read it.")))).toBe(true);
    expect(isStock(await $.ui.render(assistantMessage("Something else")))).toBe(true);
  });

  test("keeps a final reply visible when its text matches an earlier working note", async ($, on) => {
    const { journal } = world(on, { preference: "on\n" });
    const set = stepper(on);
    set({
      chunks: [
        { kind: "text", index: 0, text: "Done." },
        { kind: "tool", index: 1, id: "t1", name: "Bash" },
        { kind: "stop", stopReason: "tool_use", usage: null },
      ],
      result: { answer: "Done.", toolUses: [{ name: "Bash", input: {} }], stopReason: "tool_use" },
    });
    await runStep($);
    expect(isHidden(await $.ui.render(assistantMessage("Done.", "working-note")))).toBe(true);

    set({
      chunks: [{ kind: "text", index: 0, text: "Done." }, { kind: "stop", stopReason: "end_turn", usage: null }],
      result: { answer: "Done.", toolUses: [], stopReason: "end_turn" },
    });
    const redrawsBeforeFinal = journal.invalidations.length;
    const { result } = await runStep($);
    expect(result.stopReason).toBe("end_turn");
    expect(journal.invalidations.length).toBeGreaterThan(redrawsBeforeFinal);
    expect(isStock(await $.ui.render(assistantMessage("Done.", "final-reply")))).toBe(true);
  });

  test("keeps an earlier final reply visible when a later working note reuses its text", async ($, on) => {
    world(on, { preference: "on\n" });
    const set = stepper(on);
    set({
      chunks: [{ kind: "text", index: 0, text: "Done." }, { kind: "stop", stopReason: "end_turn", usage: null }],
      result: { answer: "Done.", toolUses: [], stopReason: "end_turn" },
    });
    await runStep($);
    expect(isStock(await $.ui.render(assistantMessage("Done.", "final-reply")))).toBe(true);

    set({
      chunks: [
        { kind: "text", index: 0, text: "Done." },
        { kind: "tool", index: 1, id: "t1", name: "Bash" },
        { kind: "stop", stopReason: "tool_use", usage: null },
      ],
      result: { answer: "Done.", toolUses: [{ name: "Bash", input: {} }], stopReason: "tool_use" },
    });
    await runStep($);
    expect(isStock(await $.ui.render(assistantMessage("Done.", "earlier-final")))).toBe(true);
    expect(isStock(await $.ui.render(assistantMessage("Done.", "later-note")))).toBe(true);
  });

  test("resets final-reply classifications when a new session starts", async ($, on) => {
    const { journal } = world(on, { preference: "on\n" });
    const set = stepper(on);
    await $.session.start(sessionStart);
    set({
      chunks: [{ kind: "text", index: 0, text: "Done." }, { kind: "stop", stopReason: "end_turn", usage: null }],
      result: { answer: "Done.", toolUses: [], stopReason: "end_turn" },
    });
    await runStep($);
    expect(isStock(await $.ui.render(assistantMessage("Done.", "session-one-final")))).toBe(true);

    await $.session.start(sessionStart);
    set({
      chunks: [
        { kind: "text", index: 0, text: "Done." },
        { kind: "tool", index: 1, id: "t2", name: "Bash" },
        { kind: "stop", stopReason: "tool_use", usage: null },
      ],
      result: { answer: "Done.", toolUses: [{ name: "Bash", input: {} }], stopReason: "tool_use" },
    });
    await runStep($);
    expect(journal.fsReads).toHaveLength(2);
    expect(journal.sessionMessageReads).toBe(2);
    expect(isHidden(await $.ui.render(assistantMessage("Done.", "session-two-note")))).toBe(true);
  });

  test("treats a response cut off while calling tools as a working note, but not a plain cut-off", async ($, on) => {
    world(on, { preference: "on\n" });
    const set = stepper(on);
    set({
      chunks: [{ kind: "text", index: 0, text: "Partial" }, { kind: "stop", stopReason: "max_tokens", usage: null }],
      result: { answer: "Partial", toolUses: [{ name: "Read", input: {} }], stopReason: "max_tokens" },
    });
    await runStep($);
    expect(isHidden(await $.ui.render(assistantMessage("Partial")))).toBe(true);
    set({
      chunks: [{ kind: "text", index: 0, text: "Truncated final" }, { kind: "stop", stopReason: "max_tokens", usage: null }],
      result: { answer: "Truncated final", toolUses: [], stopReason: "max_tokens" },
    });
    await runStep($);
    expect(isStock(await $.ui.render(assistantMessage("Truncated final")))).toBe(true);
  });

  test("ignores subagent steps, which never draw in the main transcript", async ($, on) => {
    world(on, { preference: "on\n" });
    const set = stepper(on);
    set({
      chunks: [{ kind: "text", index: 0, text: "Sub note" }, { kind: "stop", stopReason: "tool_use", usage: null }],
      result: { answer: "Sub note", toolUses: [{ name: "Bash", input: {} }], stopReason: "tool_use" },
    });
    await runStep($, "agent-2");
    expect(isStock(await $.ui.render(assistantMessage("Sub note")))).toBe(true);
  });

  test("records notes while off and hides them retroactively when toggled on", async ($, on) => {
    world(on);
    const set = stepper(on);
    set({
      chunks: [{ kind: "text", index: 0, text: "Checking." }, { kind: "stop", stopReason: "tool_use", usage: null }],
      result: { answer: "Checking.", toolUses: [{ name: "Bash", input: {} }], stopReason: "tool_use" },
    });
    await runStep($);
    expect(isStock(await $.ui.render(assistantMessage("Checking.")))).toBe(true);
    await $.command.run(calmCommand());
    expect(isHidden(await $.ui.render(assistantMessage("Checking.")))).toBe(true);
  });

  test("seeds notes from a restored transcript without hiding a colliding final reply", async ($, on) => {
    world(on, {
      preference: "on\n",
      messages: [
        { role: "user", text: "do it", toolUses: [] },
        { role: "assistant", text: "Narration with its own call", toolUses: [{ name: "Bash" }] },
        { role: "assistant", text: "Narration before a tool row", toolUses: [] },
        { role: "assistant", text: "", toolUses: [{ name: "Read" }] },
        { role: "assistant", text: "The final answer", toolUses: [] },
        { role: "user", text: "again", toolUses: [] },
        { role: "assistant", text: "Done.", toolUses: [{ name: "Bash" }] },
        { role: "assistant", text: "Done.", toolUses: [] },
        { role: "user", text: "thanks", toolUses: [] },
        { role: "assistant", text: "Welcome", toolUses: [] },
      ],
    });
    expect(isHidden(await $.ui.render(assistantMessage("Narration with its own call")))).toBe(true);
    expect(isHidden(await $.ui.render(assistantMessage("Narration before a tool row")))).toBe(true);
    expect(isStock(await $.ui.render(assistantMessage("The final answer")))).toBe(true);
    expect(isStock(await $.ui.render(assistantMessage("Done.")))).toBe(true);
    expect(isStock(await $.ui.render(assistantMessage("Welcome")))).toBe(true);
  });
});
