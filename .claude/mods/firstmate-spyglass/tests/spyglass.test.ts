// firstmate-spyglass under `claude plugin test`: the exact opt-in, silence outside a
// Firstmate home, the fleet refresh and its status line, the /fleet pane, the worker
// session pane, the update flag, and the read-only boundary.
import { describe, expect, test, type Engine } from "claude-code/testing";
import {
  BUSY_SNAPSHOT,
  CODE,
  focus,
  HEAD,
  HOME,
  isStock,
  pane,
  PEEK,
  REMOTE,
  SNAPSHOT,
  start,
  shownText,
  world,
} from "./support.ts";

const ORIGIN = "https://github.com/kunchenguid/firstmate.git";

describe("activation", () => {
  async function expectInert($: Engine, on: Parameters<typeof world>[0], functionHooks: string | undefined) {
    const { clock, journal } = world(on, { functionHooks, snapshot: BUSY_SNAPSHOT, origin: ORIGIN });
    await start($);
    expect(isStock(await $.ui.render(pane()))).toBe(true);
    expect(isStock(await $.ui.render(pane("spyglass-session")))).toBe(true);
    await $.ui.focus(focus("view:alpha"));
    await clock.advance(11 * 60_000);
    expect(journal.runs).toHaveLength(0);
    expect(journal.commands).toHaveLength(0);
    expect(journal.opened).toHaveLength(0);
    expect(journal.toasts).toHaveLength(0);
    expect(journal.statuses).toHaveLength(0);
    expect(journal.fsReads).toHaveLength(0);
  }

  test("is fully inert when the function-hooks opt-in is absent", async ($, on) => {
    await expectInert($, on, undefined);
  });

  test("is fully inert when the function-hooks opt-in is not exactly one", async ($, on) => {
    await expectInert($, on, "true");
  });

  test("stays silent outside a Firstmate home", async ($, on) => {
    const { clock, journal } = world(on, { firstmate: false });
    await start($);
    expect(isStock(await $.ui.render(pane()))).toBe(true);
    await clock.advance(11 * 60_000);
    expect(journal.runs).toHaveLength(0);
    expect(journal.commands).toHaveLength(0);
    expect(journal.opened).toHaveLength(0);
    expect(journal.statuses).toHaveLength(0);
  });
});

describe("the fleet", () => {
  test("reads the snapshot from the code root for the resolved home and summarizes it in the status line", async ($, on) => {
    const { files, journal } = world(on, { snapshot: BUSY_SNAPSHOT });
    files.set(`${HOME}/state/alpha.meta`, "harness=claude\nmodel=opus\neffort=high\n");
    await start($);
    expect(journal.commands).toEqual(["fleet"]);
    expect(journal.opened).toEqual(["spyglass"]);
    const snapshot = journal.runs.find((run) => run.argv[0] === SNAPSHOT);
    expect(snapshot?.argv).toEqual([SNAPSHOT, "--json"]);
    expect(snapshot?.cwd).toBe(CODE);
    expect(snapshot?.env).toEqual({ FM_HOME: HOME });
    expect(journal.statuses.at(-1)).toBe("⚓ 1 under way · 1 signal · 1 PR ready");
    expect(journal.fsReads).toContain(`${HOME}/state/alpha.meta`);
  });

  test("draws the banner, signals, workers with model and effort, and queued work", async ($, on) => {
    const { files } = world(on, { snapshot: BUSY_SNAPSHOT });
    files.set(`${HOME}/state/alpha.meta`, "model=opus\neffort=high\n");
    await start($);
    const text = shownText(await $.ui.render(pane()));
    for (const expected of [
      "S P Y G L A S S",
      "Signals for the Captain",
      "PR ready · alpha",
      "https://github.com/o/r/pull/7",
      "Pick a name",
      "needs the captain",
      "Under Way",
      "alpha",
      "ship · web",
      "opus · high effort",
      "View session",
      "At Anchor",
      "Later work",
    ]) expect(text).toContain(expected);
  });

  test("passes an overridden state directory on to the snapshot and fm-peek", async ($, on) => {
    const { files, journal } = world(on, { snapshot: BUSY_SNAPSHOT, env: { FM_STATE_OVERRIDE: "/elsewhere/state" } });
    files.set("/elsewhere/state/alpha.meta", "model=opus\neffort=high\n");
    await start($);
    expect(journal.runs.find((run) => run.argv[0] === SNAPSHOT)?.env).toEqual({ FM_HOME: HOME, FM_STATE_OVERRIDE: "/elsewhere/state" });
    expect(shownText(await $.ui.render(pane()))).toContain("opus · high effort");
    const ui = await $.ui.mount({ plugin: "spyglass", ...pane() });
    await ui.press({ key: "view:alpha" });
    expect(journal.runs.find((run) => run.argv[0] === PEEK)?.env).toEqual({ FM_HOME: HOME, FM_STATE_OVERRIDE: "/elsewhere/state" });
  });

  test("counts a PR as ready only once its worker reports done", async ($, on) => {
    const { clock, journal, reply } = world(on, { snapshot: { ...BUSY_SNAPSHOT, tasks: [{ ...BUSY_SNAPSHOT.tasks[0], current_state: { state: "working" } }] } });
    await start($);
    expect(journal.statuses.at(-1)).toBe("⚓ 1 under way · 1 signal");
    expect(shownText(await $.ui.render(pane()))).not.toContain("PR ready");
    reply([SNAPSHOT], { stdout: JSON.stringify(BUSY_SNAPSHOT) });
    await clock.advance(15_000);
    expect(journal.toasts).toContain("🚩 1 new signal for the captain - /fleet");
  });

  test("toasts only for a signal that appears after the first read", async ($, on) => {
    const { clock, journal, reply } = world(on, { snapshot: BUSY_SNAPSHOT });
    await start($);
    expect(journal.toasts.filter((toast) => toast.includes("signal"))).toHaveLength(0);
    reply([SNAPSHOT], {
      stdout: JSON.stringify({
        ...BUSY_SNAPSHOT,
        backlog: { records: [...BUSY_SNAPSHOT.backlog.records, { id: "fresh", title: "New call", captain_actionable: true }] },
      }),
    });
    await clock.advance(15_000);
    expect(journal.toasts).toContain("🚩 1 new signal for the captain - /fleet");
  });

  test("reports an unreadable fleet instead of going silent", async ($, on) => {
    const { journal, reply } = world(on);
    reply([SNAPSHOT], { exitCode: 2, stderr: "boom\n" });
    await start($);
    expect(journal.statuses.at(-1)).toBe("⚓ fleet unreadable");
    expect(shownText(await $.ui.render(pane()))).toContain("Fleet unreadable: boom");
  });
});

describe("the worker session pane", () => {
  test("shows a sanitized live tail from fm-peek", async ($, on) => {
    const { journal, reply } = world(on, { snapshot: BUSY_SNAPSHOT });
    reply([PEEK], { stdout: "\u001b[32mgreen\u001b[0m line\r\nnext\n" });
    await start($);
    const ui = await $.ui.mount({ plugin: "spyglass", ...pane() });
    await ui.press({ key: "view:alpha" });
    expect(journal.opened).toContain("spyglass-session");
    const peek = journal.runs.find((run) => run.argv[0] === PEEK);
    expect(peek?.argv).toEqual([PEEK, "alpha", "80"]);
    expect(peek?.env).toEqual({ FM_HOME: HOME });
    const text = shownText(await $.ui.render(pane("spyglass-session")));
    expect(text).toContain("alpha");
    expect(text).toContain("green line\nnext");
    expect(text).not.toContain("\u001b");
    expect(text).toContain("Open in terminal");
    expect(text).toContain("Copy attach command");
  });

  test("shows only the newest tail lines that fit the viewport, with a floor", async ($, on) => {
    const { journal, reply } = world(on, { snapshot: BUSY_SNAPSHOT });
    reply([PEEK], { stdout: Array.from({ length: 80 }, (_, i) => `step ${i + 1}`).join("\n") });
    await start($);
    const ui = await $.ui.mount({ plugin: "spyglass", ...pane() });
    await ui.press({ key: "view:alpha" });
    expect(journal.runs.find((run) => run.argv[0] === PEEK)?.argv).toEqual([PEEK, "alpha", "80"]);
    const tall = shownText(await $.ui.render(pane("spyglass-session", 80, 40)));
    expect(tall).toContain("step 61\n");
    expect(tall).toContain("step 80");
    expect(tall).not.toContain("step 60\n");
    const short = shownText(await $.ui.render(pane("spyglass-session", 80, 10)));
    expect(short).toContain("step 73\n");
    expect(short).not.toContain("step 72\n");
  });

  test("copies the attach command for the worker's tmux target", async ($, on) => {
    const { journal } = world(on, { snapshot: BUSY_SNAPSHOT });
    await start($);
    const main = await $.ui.mount({ plugin: "spyglass", ...pane() });
    await main.press({ key: "view:alpha" });
    const side = await $.ui.mount({ plugin: "spyglass", ...pane("spyglass-session") });
    await side.press({ key: "copy" });
    expect(journal.copies).toEqual(["tmux attach -t fm:alpha"]);
  });

  for (const [label, worker] of [
    ["a worker on another backend", { backend: "herdr", endpoint: { target: "herdr-pane-7" } }],
    ["a remote secondmate", { backend: "tmux", remote: { host: "box", root: "/fm" }, endpoint: { target: "fm:alpha" } }],
  ] as const) {
    test(`offers no tmux attach for ${label}`, async ($, on) => {
      const { journal } = world(on, { snapshot: { ...BUSY_SNAPSHOT, tasks: [{ ...BUSY_SNAPSHOT.tasks[0], ...worker }] } });
      await start($);
      const ui = await $.ui.mount({ plugin: "spyglass", ...pane() });
      await ui.press({ key: "view:alpha" });
      const text = shownText(await $.ui.render(pane("spyglass-session")));
      expect(text).toContain("Refresh");
      expect(text).not.toContain("Open in terminal");
      expect(text).not.toContain("Copy attach command");
      expect(journal.copies).toEqual([]);
    });
  }
});

describe("the focus workaround", () => {
  const peeks = (runs: { argv: readonly string[] }[]) => runs.filter((run) => run.argv[0] === PEEK);

  test("opens a session when the ring lands on View session from outside the fleet pane", async ($, on) => {
    const { clock, journal } = world(on, { snapshot: BUSY_SNAPSHOT });
    await start($);
    await $.ui.focus(focus("view:alpha"));
    await clock.settle();
    expect(journal.opened).toContain("spyglass-session");
    expect(peeks(journal.runs)).toHaveLength(1);
    expect(peeks(journal.runs)[0]?.argv).toEqual([PEEK, "alpha", "80"]);
  });

  test("treats a move already inside the fleet pane as an ordinary focus change", async ($, on) => {
    const { clock, journal } = world(on, { snapshot: BUSY_SNAPSHOT });
    await start($);
    await $.ui.focus(focus("check-update"));
    await clock.settle();
    await $.ui.focus(focus("view:alpha"));
    await clock.settle();
    expect(journal.opened).not.toContain("spyglass-session");
    // Leaving the pane forgets the ring, so the next arrival counts as coming from outside.
    await $.ui.focus(focus("refresh", "person", "spyglass-session"));
    await clock.settle();
    await $.ui.focus(focus("view:alpha"));
    await clock.settle();
    expect(journal.opened).toContain("spyglass-session");
  });

  test("ignores a plugin-driven move and a worker that is gone", async ($, on) => {
    const { clock, journal } = world(on, { snapshot: BUSY_SNAPSHOT });
    await start($);
    await $.ui.focus(focus("view:alpha", "plugin"));
    await clock.settle();
    await $.ui.focus(focus(undefined));
    await clock.settle();
    await $.ui.focus(focus("view:missing"));
    await clock.settle();
    expect(journal.opened).not.toContain("spyglass-session");
  });
});

describe("the update flag", () => {
  const behind = { head: HEAD, remote: REMOTE, origin: ORIGIN, compare: { n: 3, files: ["AGENTS.md", "bin/fm-spawn.sh"] } };

  test("is absent while origin's main is not ahead, leaving a Check for updates control", async ($, on) => {
    const { journal } = world(on, { snapshot: BUSY_SNAPSHOT, origin: ORIGIN, head: HEAD, remote: HEAD });
    await start($);
    const text = shownText(await $.ui.render(pane()));
    expect(text).not.toContain("Firstmate update available");
    expect(text).toContain("Firstmate up to date");
    expect(text).toContain("Check for updates");
    expect(journal.runs.some((run) => run.argv[0] === "gh")).toBe(false);
    expect(journal.statuses.at(-1)).not.toContain("update");
  });

  test("shows the commit count and the local edit the update would collide with", async ($, on) => {
    const { journal } = world(on, { snapshot: BUSY_SNAPSHOT, ...behind, edits: ["AGENTS.md", "README.md"] });
    await start($);
    const text = shownText(await $.ui.render(pane()));
    expect(text).toContain("Firstmate update available - 3 commits behind");
    expect(text).toContain("Your local change to AGENTS.md is in the way: the update changes it too.");
    expect(text).toContain("Update Firstmate");
    // The status line picks the flag up as soon as the check finishes, not at the next fleet refresh.
    expect(journal.statuses.at(-1)).toBe("⚓ 1 under way · 1 signal · 1 PR ready · ⬆ update");
    const compare = journal.runs.find((run) => run.argv[0] === "gh");
    expect(compare?.argv.slice(0, 3)).toEqual(["gh", "api", `repos/kunchenguid/firstmate/compare/${HEAD}...${REMOTE}`]);
  });

  test("derives the upstream from origin, so a fork compares against itself", async ($, on) => {
    const { journal } = world(on, { snapshot: BUSY_SNAPSHOT, ...behind, origin: "git@github.com:someone/firstmate.git" });
    await start($);
    expect(journal.runs.find((run) => run.argv[0] === "gh")?.argv[2]).toBe(`repos/someone/firstmate/compare/${HEAD}...${REMOTE}`);
  });

  test("matches a local edit whose name git status would quote", async ($, on) => {
    world(on, { snapshot: BUSY_SNAPSHOT, ...behind, compare: { n: 1, files: ["docs/my notes é.md"] }, edits: ["docs/my notes é.md"] });
    await start($);
    expect(shownText(await $.ui.render(pane()))).toContain("Your local change to docs/my notes é.md is in the way: the update changes it too.");
  });

  test("compares against origin's default branch when it is not main", async ($, on) => {
    const { journal } = world(on, { snapshot: BUSY_SNAPSHOT, ...behind, defaultBranch: "trunk", branch: "trunk" });
    await start($);
    expect(shownText(await $.ui.render(pane()))).toContain("Firstmate update available - 3 commits behind");
    expect(journal.runs.find((run) => run.argv[0] === "gh")?.argv[2]).toBe(`repos/kunchenguid/firstmate/compare/${HEAD}...${REMOTE}`);
  });

  for (const [label, branch] of [["another branch", "feature"], ["a detached HEAD", ""]] as const) {
    test(`shows no flag when HEAD is on ${label}, which the update would skip`, async ($, on) => {
      const { journal } = world(on, { snapshot: BUSY_SNAPSHOT, ...behind, branch });
      await start($);
      expect(shownText(await $.ui.render(pane()))).not.toContain("Firstmate update available");
      expect(journal.runs.some((run) => run.argv[0] === "gh")).toBe(false);
      expect(journal.statuses.at(-1)).toBe("⚓ 1 under way · 1 signal · 1 PR ready");
    });
  }

  test("starts no second update check while one is running", async ($, on) => {
    const { journal } = world(on, { snapshot: BUSY_SNAPSHOT, origin: ORIGIN, head: HEAD, remote: HEAD });
    await start($);
    const checks = () => journal.runs.filter((run) => run.argv[3] === "ls-remote").length;
    const before = checks();
    const ui = await $.ui.mount({ plugin: "spyglass", ...pane() });
    await Promise.all([ui.press({ key: "check-update" }), ui.press({ key: "check-update" })]);
    expect(checks()).toBe(before + 1);
  });

  test("notes an untouched local edit without calling it a conflict", async ($, on) => {
    world(on, { snapshot: BUSY_SNAPSHOT, ...behind, edits: ["README.md"] });
    await start($);
    const text = shownText(await $.ui.render(pane()));
    expect(text).toContain("Your local change to README.md is not touched by this update.");
    expect(text).not.toContain("is in the way");
  });

  test("submits the captain's own words when Update Firstmate is pressed, and shows it queued then updating", async ($, on) => {
    const { journal } = world(on, { snapshot: BUSY_SNAPSHOT, ...behind });
    await start($);
    const ui = await $.ui.mount({ plugin: "spyglass", ...pane() });
    await ui.press({ key: "update" });
    expect(journal.prompts).toEqual([{ text: "update firstmate", asUser: true }]);
    expect(journal.toasts).toContain("⬆ Update queued - the first mate runs it as soon as it is free");
    expect(shownText(await $.ui.render(pane()))).toContain("Update queued - starts as soon as the first mate is free");
    await $.turn.start({ text: "update firstmate", turnId: "update" });
    expect(shownText(await $.ui.render(pane()))).toContain("Updating Firstmate...");
  });

  test("clears the flag and reports done once local main reaches the commit it was behind", async ($, on) => {
    const { clock, journal, reply } = world(on, { snapshot: BUSY_SNAPSHOT, ...behind });
    await start($);
    const ui = await $.ui.mount({ plugin: "spyglass", ...pane() });
    await ui.press({ key: "update" });
    reply(["git", "-C", CODE, "rev-parse", "HEAD"], { stdout: `${REMOTE}\n` });
    await clock.advance(15_000);
    expect(journal.toasts).toContain("✓ Firstmate updated to the latest");
    const text = shownText(await $.ui.render(pane()));
    expect(text).toContain("✓ Firstmate updated to the latest");
    expect(text).not.toContain("Firstmate update available");
  });

  test("brings the Update button back when the first mate's turn ends with main still behind", async ($, on) => {
    const { clock, journal } = world(on, { snapshot: BUSY_SNAPSHOT, ...behind });
    await start($);
    const ui = await $.ui.mount({ plugin: "spyglass", ...pane() });
    await ui.press({ key: "update" });
    await $.turn.start({ text: "update firstmate", turnId: "update" });
    // A subagent's turn ending mid-update leaves the update running.
    await $.turn.complete({ answer: "", durationMs: 1, isAborted: false, turnId: "sub", agentId: "helper", reason: "answer" });
    await clock.settle();
    expect(shownText(await $.ui.render(pane()))).toContain("Updating Firstmate...");
    await $.turn.complete({ answer: "", durationMs: 1, isAborted: false, turnId: "update", reason: "answer" });
    await clock.settle();
    const text = shownText(await $.ui.render(pane()));
    expect(text).toContain("Firstmate update available - 3 commits behind");
    expect(text).not.toContain("Updating Firstmate...");
    expect(text).toContain("Update Firstmate");
    expect(journal.toasts).toContain("⬆ Firstmate update did not land - see the first mate's reply");
  });

  test("keeps the update queued while the first mate finishes the turn it was busy on", async ($, on) => {
    const { clock, journal } = world(on, { snapshot: BUSY_SNAPSHOT, ...behind });
    await start($);
    const ui = await $.ui.mount({ plugin: "spyglass", ...pane() });
    await ui.press({ key: "update" });
    await $.turn.complete({ answer: "", durationMs: 1, isAborted: false, turnId: "busy", reason: "answer" });
    await clock.settle();
    const text = shownText(await $.ui.render(pane()));
    expect(text).toContain("Update queued - starts as soon as the first mate is free");
    expect(journal.toasts).not.toContain("⬆ Firstmate update did not land - see the first mate's reply");
    expect(journal.prompts).toHaveLength(1);
  });

  test("keeps Update Firstmate pressable while queued, so a lost queued prompt can be sent again", async ($, on) => {
    const { journal } = world(on, { snapshot: BUSY_SNAPSHOT, ...behind });
    await start($);
    const ui = await $.ui.mount({ plugin: "spyglass", ...pane() });
    await ui.press({ key: "update" });
    await ui.press({ key: "update" });
    expect(journal.prompts).toEqual([
      { text: "update firstmate", asUser: true },
      { text: "update firstmate", asUser: true },
    ]);
    await $.turn.start({ text: "update firstmate", turnId: "update" });
    const text = shownText(await $.ui.render(pane()));
    expect(text).toContain("Updating Firstmate...");
    expect(text).not.toContain("Update queued");
  });

  test("skips the flag and the control when origin is not a GitHub remote", async ($, on) => {
    const { journal } = world(on, { snapshot: BUSY_SNAPSHOT, ...behind, origin: "https://gitlab.com/o/r.git" });
    await start($);
    const text = shownText(await $.ui.render(pane()));
    expect(text).not.toContain("update");
    expect(text).not.toContain("Check for updates");
    expect(journal.runs.some((run) => run.argv[0] === "gh")).toBe(false);
    expect(journal.statuses.at(-1)).toBe("⚓ 1 under way · 1 signal · 1 PR ready");
  });

  test("skips the flag and the control when gh is unavailable", async ($, on) => {
    const { journal } = world(on, { snapshot: BUSY_SNAPSHOT, ...behind, gh: false });
    await start($);
    const text = shownText(await $.ui.render(pane()));
    expect(text).not.toContain("update");
    expect(text).not.toContain("Check for updates");
    expect(journal.runs.some((run) => run.argv[0] === "gh")).toBe(false);
  });
});

describe("the read-only boundary", () => {
  test("runs only read-only commands: the snapshot, a peek, git reads, the compare, and a terminal launcher", async ($, on) => {
    const { clock, journal } = world(on, {
      snapshot: BUSY_SNAPSHOT,
      origin: ORIGIN,
      head: HEAD,
      remote: REMOTE,
      compare: { n: 1, files: [] },
    });
    await start($);
    const ui = await $.ui.mount({ plugin: "spyglass", ...pane() });
    await ui.press({ key: "view:alpha" });
    const side = await $.ui.mount({ plugin: "spyglass", ...pane("spyglass-session") });
    await side.press({ key: "terminal" });
    await clock.advance(11 * 60_000);
    const allowed = (argv: readonly string[]) =>
      argv[0] === SNAPSHOT ||
      argv[0] === PEEK ||
      (argv[0] === "git" && argv[1] === "-C" && ["remote", "rev-parse", "ls-remote", "symbolic-ref", "diff"].includes(argv[3] ?? "")) ||
      (argv[0] === "gh" && argv[1] === "api") ||
      (argv[0] === "/bin/sh" && /^command -v (gh|tmux)$/.test(argv[argv.length - 1] ?? "")) ||
      argv[0] === "open" ||
      argv[0] === "osascript";
    for (const run of journal.runs) expect(allowed(run.argv)).toBe(true);
    expect(journal.runs.some((run) => run.argv[0] === "open" || run.argv[0] === "osascript")).toBe(true);
    // Nothing the mod runs is a mutating fm-* script, and nothing is sent to a worker.
    for (const run of journal.runs) {
      if (run.argv[0]?.startsWith(`${CODE}/bin/`)) expect([SNAPSHOT, PEEK]).toContain(run.argv[0]);
    }
    expect(journal.prompts).toHaveLength(0);
  });

  test("refuses to hand an unexpected tmux target to a terminal launcher", async ($, on) => {
    const { journal } = world(on, {
      snapshot: { ...BUSY_SNAPSHOT, tasks: [{ ...BUSY_SNAPSHOT.tasks[0], endpoint: { target: 'x" & do shell script "id' } }] },
    });
    await start($);
    const ui = await $.ui.mount({ plugin: "spyglass", ...pane() });
    await ui.press({ key: "view:alpha" });
    const side = await $.ui.mount({ plugin: "spyglass", ...pane("spyglass-session") });
    await side.press({ key: "terminal" });
    expect(journal.runs.some((run) => run.argv[0] === "open" || run.argv[0] === "osascript")).toBe(false);
    expect(journal.toasts.some((toast) => toast.startsWith("Could not open a terminal: unexpected session name"))).toBe(true);
  });
});
