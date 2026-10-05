// firstmate-calm under `claude plugin test`: the Calm toggle, its persisted per-home
// preference, and the transcript rows Calm hides and restores.
import { describe, expect, test, type Engine } from "claude-code/testing";
import {
  abovePrompt,
  assistantMessage,
  calmCommand,
  command,
  doorbell,
  effortCueOf,
  effortCuePress,
  fromFirstmate,
  HOME,
  isHidden,
  isStock,
  MODEL,
  operational,
  PREFERENCE,
  spinner,
  toolGroup,
  toolResult,
  toolUse,
  turnStep,
  userMessage,
  world,
  type World,
} from "./support.ts";

const sessionStart = { cwd: "/work", surface: "terminal" as const, isInteractive: true };

describe("activation", () => {
  async function expectInert($: Engine, on: Parameters<typeof world>[0], functionHooks: string | undefined) {
    const { clock, files, journal } = world(on, {
      functionHooks,
      preference: "on\n",
      messages: [{ role: "assistant", text: "Working", toolUses: [{ name: "Bash" }] }],
    });
    files.set(
      `${HOME}/state/.branch-outcomes-tail.jsonl`,
      '{"seq":1,"epoch":0,"task":"fm-x","wake":"","verdict":"captain","summary":"PR ready","silent":false}\n',
    );
    await $.session.start(sessionStart);
    const drawings = await Promise.all([
      $.ui.render(spinner()),
      $.ui.render(toolUse()),
      $.ui.render(toolResult()),
      $.ui.render(toolGroup()),
      $.ui.render(userMessage(operational("watcher", "signal: x"))),
      $.ui.render(assistantMessage("Working")),
      $.ui.render(abovePrompt()),
    ]);
    expect(drawings.every(isStock)).toBe(true);
    // The effort cue is inert too: the band is the engine's own, so the mod has drawn no
    // Button for a press to reach, and no level was selected.
    await expect($.ui.press(effortCuePress())).rejects.toThrow();
    await clock.advance(220 * 16);
    expect(journal.commands).toHaveLength(0);
    expect(journal.blits).toHaveLength(0);
    expect(journal.invalidations).toHaveLength(0);
    expect(journal.toasts).toHaveLength(0);
    expect(journal.fsReads).toHaveLength(0);
    expect(journal.logs).toHaveLength(0);
    expect(journal.sessionMessageReads).toBe(0);
    expect(journal.configLists).toBe(0);
    expect(journal.settingsReads).toBe(0);
    expect(journal.runs).toHaveLength(0);
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
    expect(journal.commands).toEqual(["calm", "effort-cycle"]);
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

  // A harness that strips U+2063 from submitted prompts receives a plain doorbell naming
  // a record that holds the envelope; only the record makes the row Firstmate's.
  const inbox = `${HOME}/state/operational-inbox`;
  const backed = `${inbox}/1790000000-0123456789abcdef.msg`;
  const unbacked = `${inbox}/1790000000-fedcba9876543210.msg`;
  const asciiRecord = `${inbox}/1790000000-aaaaaaaaaaaaaaaa.msg`;

  test("hides a doorbell only when the record it names holds a current envelope", async ($, on) => {
    const { files, journal } = world(on, { preference: "on\n" });
    files.set(backed, operational("away-supervisor", "Supervisor escalate: done: PR 1"));
    files.set(asciiRecord, "FIRSTMATE_OP: v1 away-supervisor: ascii only");
    expect(isHidden(await $.ui.render(userMessage(doorbell(backed))))).toBe(true);
    expect(isStock(await $.ui.render(userMessage(doorbell(unbacked))))).toBe(true);
    expect(isStock(await $.ui.render(userMessage(doorbell(asciiRecord))))).toBe(true);
    expect(isStock(await $.ui.render(userMessage(`${doorbell(backed)} and more`)))).toBe(true);
    expect(isStock(await $.ui.render(userMessage(doorbell("relative/operational-inbox/1-a.msg"))))).toBe(true);
    // Records are immutable once published, so one read serves every redraw of the row.
    const readsBefore = journal.fsReads.filter((path) => path === backed).length;
    expect(isHidden(await $.ui.render(userMessage(doorbell(backed))))).toBe(true);
    expect(journal.fsReads.filter((path) => path === backed).length).toBe(readsBefore);
  });

  test("shows a hidden doorbell again once a toggle redraws it after its record is pruned", async ($, on) => {
    const { files } = world(on, { preference: "on\n" });
    files.set(backed, operational("away-supervisor", "escalate"));
    expect(isHidden(await $.ui.render(userMessage(doorbell(backed))))).toBe(true);
    files.delete(backed);
    await $.command.run(calmCommand());
    await $.command.run(calmCommand());
    expect(isStock(await $.ui.render(userMessage(doorbell(backed))))).toBe(true);
  });

  test("leaves a backed doorbell to the engine while off, without reading its record", async ($, on) => {
    const { files, journal } = world(on);
    files.set(backed, operational("away-supervisor", "escalate"));
    expect(isStock(await $.ui.render(userMessage(doorbell(backed))))).toBe(true);
    expect(journal.fsReads).not.toContain(backed);
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

  test("hides brief narration but preserves substantive text before tool calls, and forwards the stream untouched", async ($, on) => {
    const { journal } = world(on, { preference: "on\n" });
    const set = stepper(on);
    set({
      chunks: [
        { kind: "text", index: 0, text: "Let me " },
        { kind: "text", index: 0, text: "look first." },
        { kind: "tool", index: 1, id: "t1", name: "Bash" },
        { kind: "text", index: 2, text: "Then I read it.\n" },
        { kind: "stop", stopReason: "tool_use", usage: null },
      ],
      result: { answer: "Let me look first.\nThen I read it.", toolUses: [{ name: "Bash", input: {} }], stopReason: "tool_use" },
    });
    expect(isStock(await $.ui.render(assistantMessage("Let me look first.")))).toBe(true);
    const { seen, result } = await runStep($);
    expect(seen).toHaveLength(5);
    expect(result.answer).toBe("Let me look first.\nThen I read it.");
    expect(journal.invalidations).toContain("ui.render");
    expect(isHidden(await $.ui.render(assistantMessage("Let me look first."))), "brief narration").toBe(true);
    expect(isStock(await $.ui.render(assistantMessage("Then I read it.\n"))), "multi-line block").toBe(true);
    expect(isStock(await $.ui.render(assistantMessage("Let me look first.\nThen I read it."))), "complete answer").toBe(true);
    expect(isStock(await $.ui.render(assistantMessage("Something else"))), "unrelated text").toBe(true);
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
    expect(journal.fsReads.filter((path) => path === PREFERENCE)).toHaveLength(2);
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

  test("preserves substantive mid-turn text restored from the transcript", async ($, on) => {
    const multiLine = "The result is substantive.\nHere is the context needed to continue.";
    const atThreshold = "x".repeat(240);
    const belowThreshold = "x".repeat(239);
    world(on, {
      preference: "on\n",
      messages: [
        { role: "user", text: "multi-line", toolUses: [] },
        { role: "assistant", text: multiLine, toolUses: [] },
        { role: "assistant", text: "", toolUses: [{}] },
        { role: "user", text: "at threshold", toolUses: [] },
        { role: "assistant", text: atThreshold, toolUses: [] },
        { role: "assistant", text: "", toolUses: [{}] },
        { role: "user", text: "below threshold", toolUses: [] },
        { role: "assistant", text: belowThreshold, toolUses: [] },
        { role: "assistant", text: "", toolUses: [{}] },
        { role: "user", text: "newline collision", toolUses: [] },
        { role: "assistant", text: "Checking.\n", toolUses: [] },
        { role: "assistant", text: "", toolUses: [{}] },
        { role: "user", text: "single-line collision", toolUses: [] },
        { role: "assistant", text: "Checking.", toolUses: [] },
        { role: "assistant", text: "", toolUses: [{}] },
      ],
    });
    expect(isStock(await $.ui.render(assistantMessage(multiLine)))).toBe(true);
    expect(isStock(await $.ui.render(assistantMessage(atThreshold)))).toBe(true);
    expect(isHidden(await $.ui.render(assistantMessage(belowThreshold)))).toBe(true);
    expect(isStock(await $.ui.render(assistantMessage("Checking.\n")))).toBe(true);
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

describe("the effort cue", () => {
  const savedFor = (level: string) => ({ modelSettings: { [MODEL]: { effortLevel: level } } });

  // A press reaches a Button only while it is drawn, as the band's own keyboard path does.
  async function press($: Engine): Promise<void> {
    await $.ui.render(abovePrompt());
    await $.ui.press(effortCuePress());
  }

  // The engine's own model request, registered before the test's first call on `$`.
  function stepper(on: Parameters<typeof world>[0]) {
    on("turn.step", async function* (_$, e) {
      return { turnId: e.turnId, index: e.index, answer: "", toolUses: [], stopReason: "end_turn", usage: null } as never;
    });
  }

  // One request of the main loop, carrying the effort the engine resolved for it.
  async function runStep($: Engine, effort: unknown, agentId?: string, model?: string): Promise<void> {
    const stream = $.turn.step(turnStep(effort, agentId, model));
    let step = await stream.next();
    while (!step.done) step = await stream.next();
  }

  // One request of the main loop at the level the world's session runs at, then its reply,
  // after which Claude Code asks to confirm the next effort change.
  async function turn($: Engine, w: World, model?: string): Promise<void> {
    await runStep($, w.effort(), undefined, model);
    w.reply();
  }

  async function cueLabel($: Engine): Promise<string> {
    return effortCueOf(await $.ui.render(abovePrompt()))!.label;
  }

  test("claims no level until a request of the main loop proves one", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    expect(effortCueOf(await $.ui.render(abovePrompt()))).toMatchObject({ label: "◌ effort ?", color: "promptBorder" });
    await runStep($, "high");
    expect(effortCueOf(await $.ui.render(abovePrompt()))).toMatchObject({ label: "◑ high", color: "claude" });
  });

  test("draws the cue with Calm on and with Calm off, and never changes Calm", async ($, on) => {
    const { files } = world(on, { preference: "off\n" });
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "medium");
    const off = effortCueOf(await $.ui.render(abovePrompt()));
    await $.command.run(calmCommand());
    const on_ = effortCueOf(await $.ui.render(abovePrompt()));
    expect(off).toEqual(on_);
    // Cycling the level leaves the Calm preference exactly where the toggle put it.
    await press($);
    expect(files.get(PREFERENCE)).toBe("on\n");
  });

  test("yields the band to a survey the engine put there", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "high");
    expect(isStock(await $.ui.render(abovePrompt(40, "above-prompt", true)))).toBe(true);
    // The band is the cue's again as soon as the survey lets it go.
    expect(await cueLabel($)).toBe("◑ high");
  });

  test("fills the row to the measured width, and draws no rule when the row is too narrow", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "low");
    const wide = effortCueOf(await $.ui.render(abovePrompt(40)));
    // "○ low" is 5 cells, plus the separating space and the engine's 4-cell handle.
    expect(wide?.rule).toBe(` ${"─".repeat(30)}`);
    expect(effortCueOf(await $.ui.render(abovePrompt(4)))?.rule).toBe(" ");
  });

  test("paints every level a request can report in its own theme color", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    const seen = new Map<string, string>();
    for (const level of ["low", "medium", "high", "xhigh", "max"]) {
      await runStep($, level);
      const cue = effortCueOf(await $.ui.render(abovePrompt()));
      seen.set(level, cue!.color);
      expect(cue!.label.endsWith(level)).toBe(true);
    }
    expect(new Set(seen.values()).size).toBe(seen.size);
    // The colors are Claude Code's own theme keys, never a raw ANSI word or hex value.
    for (const color of seen.values()) expect(/^[a-z][A-Za-z]+$/.test(color)).toBe(true);
  });

  test("/effort-cycle steps up one level and wraps at the top", async ($, on) => {
    const { clock, journal } = world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "low");
    for (const expected of ["medium", "high", "xhigh", "max", "low", "medium"]) {
      await $.command.run(command("effort-cycle"));
      await clock.advance(1);
      expect(journal.runs.at(-1)).toEqual({ command: "effort", args: expected });
      // Running /effort is not proof it took, so the cue waits for the request that follows.
      expect(await cueLabel($)).toBe("◌ effort ?");
      await runStep($, expected);
      expect((await cueLabel($)).endsWith(expected)).toBe(true);
    }
  });

  test("keeps climbing when no request confirms the levels it selects", async ($, on) => {
    const { clock, journal } = world(on, { settings: savedFor("low") });
    await $.session.start(sessionStart);
    for (const expected of ["medium", "high", "xhigh"]) {
      await $.command.run(command("effort-cycle"));
      await clock.advance(1);
      expect(journal.runs.at(-1)).toEqual({ command: "effort", args: expected });
      expect(await cueLabel($)).toBe("◌ effort ?");
    }
  });

  test("passes over a level declined before the conversation held any reply", async ($, on) => {
    const w = world(on, { settings: savedFor("xhigh"), effortCap: "xhigh" });
    const { journal } = w;
    stepper(on);
    await $.session.start(sessionStart);
    // With no reply yet nothing can turn the step down, so Claude Code setting the capped `max`
    // to `xhigh` instead is the only way the session's first request can still prove `xhigh`.
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "max" });
    await turn($, w);
    expect(await cueLabel($)).toBe("◕ xhigh");
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "low" });
    await turn($, w);
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "medium" });
  });

  test("keeps offering a level the session does take", async ($, on) => {
    const { journal } = world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "high");
    await press($);
    await runStep($, "xhigh");
    await press($);
    await runStep($, "max");
    await press($);
    await runStep($, "low");
    await press($);
    expect(journal.runs.map((run) => run.args)).toEqual(["xhigh", "max", "low", "medium"]);
  });

  test("keeps offering a level whose change was turned down at Claude Code's confirmation", async ($, on) => {
    const w = world(on, { effort: "medium", turnDown: true });
    const { journal } = w;
    stepper(on);
    await $.session.start(sessionStart);
    await turn($, w);
    // Each change is turned down, so each request proves the session stayed at `medium`, which
    // is also what a model without `high` would prove: none of it passes `high` over.
    for (let lap = 0; lap < 5; lap += 1) {
      await press($);
      await turn($, w);
      expect(await cueLabel($)).toBe("◔ medium");
    }
    expect(journal.runs.map((run) => run.args)).toEqual(["high", "high", "high", "high", "high"]);
    expect(journal.toasts.filter((toast) => toast.startsWith("Effort unchanged"))).toHaveLength(0);
  });

  test("keeps offering a turned-down level that the shared settings already name", async ($, on) => {
    // Launched with `--effort high` while the settings every session shares save `xhigh`.
    const w = world(on, { settings: savedFor("xhigh"), effort: "high", turnDown: true });
    const { journal } = w;
    stepper(on);
    await $.session.start(sessionStart);
    await turn($, w);
    expect(await cueLabel($)).toBe("◑ high");
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "xhigh" });
    await turn($, w);
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "xhigh" });
  });

  test("keeps offering a turned-down level that another session saves meanwhile", async ($, on) => {
    const w = world(on, { effort: "medium", turnDown: true });
    const { journal } = w;
    stepper(on);
    await $.session.start(sessionStart);
    await turn($, w);
    w.writeSettings(savedFor("high"));
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "high" });
    await turn($, w);
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "high" });
  });

  test("offers a capped level again once the conversation holds a reply", async ($, on) => {
    const w = world(on, { settings: savedFor("xhigh"), effortCap: "xhigh" });
    const { journal } = w;
    stepper(on);
    await $.session.start(sessionStart);
    await turn($, w);
    // After a reply, staying at `xhigh` looks the same whether `max` was capped or turned down.
    for (let lap = 0; lap < 2; lap += 1) {
      await press($);
      expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "max" });
      await turn($, w);
      expect(await cueLabel($)).toBe("◕ xhigh");
    }
    // A second press before the next request steps on past it, so the ramp never sticks there.
    await press($);
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "low" });
    expect(journal.toasts.filter((toast) => toast.startsWith("Effort unchanged"))).toHaveLength(0);
  });

  test("names max once a request carries it, although Claude Code saves it nowhere", async ($, on) => {
    const w = world(on, { settings: savedFor("xhigh") });
    const { journal } = w;
    stepper(on);
    await $.session.start(sessionStart);
    await turn($, w);
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "max" });
    await turn($, w);
    expect(effortCueOf(await $.ui.render(abovePrompt()))).toMatchObject({ label: "● max", color: "fastMode" });
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "low" });
  });

  test("reads no decline from the first step of a resumed conversation", async ($, on) => {
    const w = world(on, {
      settings: savedFor("high"),
      turnDown: true,
      messages: [{ role: "assistant", text: "Done.", toolUses: [] }],
    });
    const { journal } = w;
    stepper(on);
    await $.session.start(sessionStart);
    // The restored conversation already holds a reply, so even this first step can be turned down.
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "xhigh" });
    await turn($, w);
    expect(await cueLabel($)).toBe("◑ high");
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "xhigh" });
  });

  test("forgets the declines when a request names another model, and steps again", async ($, on) => {
    const w = world(on, { settings: savedFor("xhigh"), effortCap: "xhigh" });
    const { journal } = w;
    stepper(on);
    await $.session.start(sessionStart);
    await press($);
    await turn($, w);
    expect(journal.runs.map((run) => run.args)).toEqual(["max"]);
    // The next request runs another model, picked without any command, which declined nothing.
    await turn($, w, "claude-opus-5");
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "max" });
  });

  test("/effort-cycle leaves no output row of its own, because /effort draws its own", async ($, on) => {
    const { clock } = world(on);
    await $.session.start(sessionStart);
    expect(await $.command.run(command("effort-cycle"))).toEqual({});
    await clock.advance(1);
  });

  test("steps up from the level saved for this session's model before any turn", async ($, on) => {
    const { journal } = world(on, { settings: savedFor("high") });
    await $.session.start(sessionStart);
    await press($);
    expect(journal.runs).toEqual([{ command: "effort", args: "xhigh" }]);
    // Reading where to step from is not proof of what is in force, so the cue still claims none.
    expect(await cueLabel($)).toBe("◌ effort ?");
  });

  test("steps up from the saved default when this model has none of its own", async ($, on) => {
    const { journal } = world(on, {
      settings: { effortLevel: "medium", modelSettings: { "some-other-model": { effortLevel: "max" } } },
    });
    await $.session.start(sessionStart);
    await press($);
    expect(journal.runs).toEqual([{ command: "effort", args: "high" }]);
  });

  test("changes nothing and says so when no level is known yet", async ($, on) => {
    const { journal } = world(on, { settings: {} });
    await $.session.start(sessionStart);
    await press($);
    expect(journal.runs).toHaveLength(0);
    expect(journal.toasts.at(-1)).toContain("not known");
    expect(await cueLabel($)).toBe("◌ effort ?");
  });

  test("changes nothing when this model's own saved level names nothing on the ramp", async ($, on) => {
    const { journal } = world(on, {
      settings: { effortLevel: "low", modelSettings: { [MODEL]: { effortLevel: "auto" } } },
    });
    await $.session.start(sessionStart);
    await press($);
    // The saved default belongs to models that have none of their own, not to this one.
    expect(journal.runs).toHaveLength(0);
    expect(journal.toasts.at(-1)).toContain("not known");
  });

  test("reads the saved level of the model the session switched to", async ($, on) => {
    const { journal } = world(on, {
      settings: { modelSettings: { [MODEL]: { effortLevel: "high" }, "claude-opus-5": { effortLevel: "low" } } },
    });
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "high");
    await $.command.run(command("model", "claude-opus-5"));
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "medium" });
  });

  test("moves one step per press when two presses overlap one run", async ($, on) => {
    const { journal } = world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "high");
    await $.ui.render(abovePrompt());
    // The chord repeating under the captain's finger: the second press must not repeat the first.
    await Promise.all([$.ui.press(effortCuePress()), $.ui.press(effortCuePress())]);
    expect(journal.runs.map((run) => run.args).sort()).toEqual(["max", "xhigh"]);
  });

  test("pressing the cue steps the level the same way", async ($, on) => {
    const { journal } = world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "high");
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "xhigh" });
    expect(await cueLabel($)).toBe("◌ effort ?");
    await runStep($, "xhigh");
    expect(await cueLabel($)).toBe("◕ xhigh");
  });

  test("says so and keeps the proven level when the run itself is refused", async ($, on) => {
    const { journal } = world(on, { commandFailure: "effort is locked" });
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "high");
    await press($);
    expect(journal.toasts.filter((toast) => toast.startsWith("Effort unchanged: "))).toHaveLength(1);
    expect(journal.runs).toHaveLength(0);
    // The run never happened, so the last proven level is still the level in force.
    expect(await cueLabel($)).toBe("◑ high");
  });

  test("claims no level once a level no request can report is selected", async ($, on) => {
    const { journal } = world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "high");
    await $.command.run(command("effort", "ultracode"));
    expect(await cueLabel($)).toBe("◌ effort ?");
    // A request under ultracode cannot say so, so whatever it reports proves nothing.
    await runStep($, "xhigh");
    expect(await cueLabel($)).toBe("◌ effort ?");
    // The ramp still climbs from there: ultracode is off the cycle, so the next step is its first.
    await press($);
    expect(journal.runs.at(-1)).toEqual({ command: "effort", args: "low" });
    await runStep($, "low");
    expect(await cueLabel($)).toBe("○ low");
  });

  test("claims no level from a session's first request once a level no request can report is selected", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await $.command.run(command("effort", "ultracode"));
    // No request has run before this one, so there is no earlier model for it to differ from.
    await runStep($, "xhigh");
    expect(await cueLabel($)).toBe("◌ effort ?");
  });

  test("names the level a request resolves to under /effort auto", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "high");
    await $.command.run(command("effort", "auto"));
    expect(await cueLabel($)).toBe("◌ effort ?");
    await runStep($, "medium");
    expect(await cueLabel($)).toBe("◔ medium");
  });

  test("follows the captain's own /effort once a request proves it", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "low");
    await $.command.run(command("effort", "xhigh"));
    expect(await cueLabel($)).toBe("◌ effort ?");
    await runStep($, "xhigh");
    expect(effortCueOf(await $.ui.render(abovePrompt()))).toMatchObject({ label: "◕ xhigh", color: "warning" });
  });

  test("ignores a bare /effort, which opens the slider and names no level", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "low");
    await $.command.run(command("effort", ""));
    expect(await cueLabel($)).toBe("○ low");
  });

  test("follows a change made outside any command, from the next request", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "low");
    // The effort slider and the model picker raise no event; the next request carries the change.
    await runStep($, "max");
    expect(effortCueOf(await $.ui.render(abovePrompt()))).toMatchObject({ label: "● max", color: "fastMode" });
  });

  test("keeps the proven level when a subagent's step carries its own", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "low");
    await runStep($, "max", "agent-7");
    expect(await cueLabel($)).toBe("○ low");
  });

  test("claims no level from a step whose effort is a token budget rather than a level", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "high");
    await runStep($, 32000);
    expect(await cueLabel($)).toBe("◌ effort ?");
  });

  test("stops naming a level once a request asks for none, as a model without one does", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "high");
    await runStep($, undefined);
    expect(effortCueOf(await $.ui.render(abovePrompt()))).toMatchObject({ label: "◌ effort ?", color: "promptBorder" });
  });

  test("claims no level after a model switch, until the next request proves one", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "high");
    await $.command.run(command("model", "claude-opus-5"));
    expect(await cueLabel($)).toBe("◌ effort ?");
    await runStep($, "max");
    expect(await cueLabel($)).toBe("● max");
  });

  test("leaves a non-terminal surface's band to the engine", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "high");
    expect(isStock(await $.ui.render({ ...abovePrompt(), surface: "desktop" } as never))).toBe(true);
  });

  test("forgets the level when a new session starts", async ($, on) => {
    world(on);
    stepper(on);
    await $.session.start(sessionStart);
    await runStep($, "max");
    expect(await cueLabel($)).toBe("● max");
    await $.session.start(sessionStart);
    expect(await cueLabel($)).toBe("◌ effort ?");
  });
});
