// firstmate-calm under `claude plugin test`: the supervision notes, one dim transcript
// line per outcome the store's tail copy gains and per latch change, replayed at session
// start, shown whether Calm is on or off, and never marking anything read.
import { describe, expect, test } from "claude-code/testing";
import { HOME, world } from "./support.ts";

const sessionStart = { cwd: "/work", surface: "terminal" as const, isInteractive: true };
const STATE = `${HOME}/state`;
const TAIL = `${STATE}/.branch-outcomes-tail.jsonl`;
const CURSOR = `${STATE}/.branch-outcomes-cursor`;
const PROCESSED = `${STATE}/.branch-outcomes-processed`;
const HEALTH = `${STATE}/.supervision-host-health`;
const POLL = 3000;

type Row = { seq: number; task: string; verdict: "routine" | "captain"; summary: string; silent?: boolean; epoch?: number };

function tail(rows: readonly Row[]): string {
  return rows
    .map((row) =>
      JSON.stringify({
        seq: row.seq,
        epoch: row.epoch ?? 100,
        task: row.task,
        wake: "",
        verdict: row.verdict,
        summary: row.summary,
        silent: row.silent ?? false,
        statusEndpoint: 0,
        statusIdent: "-",
      }),
    )
    .map((line) => `${line}\n`)
    .join("");
}

function health(key: string, cooldown: number): string {
  return `key=${key}\nerrors=${cooldown > 0 ? 2 : 0}\ncooldown=${cooldown}\nretry_after=0\n`;
}

const history: Row[] = [
  { seq: 1, task: "fm-old", verdict: "captain", summary: "PR merged earlier" },
  { seq: 2, task: "fm-a", verdict: "routine", summary: "read already" },
  { seq: 3, task: "fm-b", verdict: "captain", summary: "decision waiting" },
  { seq: 4, task: "fm-c", verdict: "routine", summary: "worker healthy" },
  { seq: 5, task: "fm-d", verdict: "routine", summary: "no change", silent: true },
];

describe("supervision notes", () => {
  test("session start replays unprocessed captain rows and unread visible routine rows with Calm off", async ($, on) => {
    const { files, journal } = world(on);
    files.set(TAIL, tail(history));
    files.set(CURSOR, "3\n");
    files.set(PROCESSED, "1\n");
    await $.session.start(sessionStart);
    expect(journal.logs).toEqual(["⚓ [seq 3] fm-b: decision waiting", "⛵ fm-c: worker healthy"]);
    // Only reads: the markers the drain owns are exactly as they were.
    expect(files.get(CURSOR)).toBe("3\n");
    expect(files.get(PROCESSED)).toBe("1\n");
  });

  test("each new row becomes one line on the next slow tick, a silent row none, and none twice", async ($, on) => {
    const { clock, files, journal } = world(on, { preference: "on\n" });
    files.set(TAIL, tail(history));
    files.set(CURSOR, "5\n");
    files.set(PROCESSED, "3\n");
    await $.session.start(sessionStart);
    expect(journal.logs).toEqual([]);
    files.set(
      TAIL,
      tail([
        ...history,
        { seq: 6, task: "fm-e", verdict: "routine", summary: "reconciled\nthe backlog" },
        { seq: 7, task: "fm-f", verdict: "routine", summary: "nothing new", silent: true },
        { seq: 8, task: "fm-g", verdict: "captain", summary: "PR https://example.test/pr/1 checks green" },
      ]),
    );
    await clock.advance(POLL - 1);
    expect(journal.logs).toEqual([]);
    await clock.advance(1);
    expect(journal.logs).toEqual(["⛵ fm-e: reconciled the backlog", "⚓ [seq 8] fm-g: PR https://example.test/pr/1 checks green"]);
    await clock.advance(POLL * 3);
    expect(journal.logs).toHaveLength(2);
  });

  test("a tail copy that first appears after session start replays against the session-start markers, even within the same second", async ($, on) => {
    const { clock, files, journal } = world(on);
    await clock.set(100_000);
    files.set(CURSOR, "5\n");
    files.set(PROCESSED, "1\n");
    await $.session.start(sessionStart);
    expect(journal.logs).toEqual([]);
    // Session start seeds the copy, or an append in the session's first second creates it, with every
    // earlier row; the drain then reads the new routine row before the mod's first poll.
    files.set(TAIL, tail([...history, { seq: 6, task: "fm-new", verdict: "routine", summary: "fresh" }]));
    files.set(CURSOR, "6\n");
    await clock.advance(POLL);
    expect(journal.logs).toEqual(["⚓ [seq 3] fm-b: decision waiting", "⛵ fm-new: fresh"]);
    await clock.advance(POLL);
    expect(journal.logs).toHaveLength(2);
  });

  test("rows that arrive faster than the tail copy holds are counted in one line, not dropped silently", async ($, on) => {
    const { clock, files, journal } = world(on);
    files.set(TAIL, tail(history));
    files.set(CURSOR, "5\n");
    files.set(PROCESSED, "3\n");
    await $.session.start(sessionStart);
    files.set(
      TAIL,
      tail([
        { seq: 9, task: "fm-i", verdict: "routine", summary: "kept" },
        { seq: 10, task: "fm-j", verdict: "captain", summary: "newest" },
      ]),
    );
    await clock.advance(POLL);
    expect(journal.logs).toEqual([
      "⛵ 3 earlier supervision outcomes not shown; bin/fm-branch-outcome.sh list shows them",
      "⛵ fm-i: kept",
      "⚓ [seq 10] fm-j: newest",
    ]);
  });

  test("a same-size replacement within one timestamp tick is still read and shown", async ($, on) => {
    const { clock, files, mtimes, journal } = world(on);
    await clock.set(1_000_000);
    mtimes.set(TAIL, 1_000_000);
    files.set(TAIL, tail(history));
    files.set(CURSOR, "5\n");
    files.set(PROCESSED, "3\n");
    await $.session.start(sessionStart);
    expect(journal.logs).toEqual([]);
    const replaced = tail([...history.slice(1), { seq: 6, task: "fm-new", verdict: "captain", summary: "fresh anchor here" }]);
    expect(replaced.length).toBe(tail(history).length);
    files.set(TAIL, replaced);
    await clock.advance(POLL);
    expect(journal.logs).toEqual(["⚓ [seq 6] fm-new: fresh anchor here"]);
    await clock.advance(POLL * 3);
    expect(journal.logs).toHaveLength(1);
  });

  test("a latch trip and its recovery each write Pi's health note, and a new session key alone writes none", async ($, on) => {
    const { clock, files, journal } = world(on);
    files.set(HEALTH, health("s1", 0));
    await $.session.start(sessionStart);
    files.set(HEALTH, health("s1", 300));
    await clock.advance(POLL);
    expect(journal.logs).toEqual([
      "⛵ Supervision session paused after repeated engine errors; main will handle wakes while it cools down.",
    ]);
    files.set(HEALTH, health("s1", 0));
    await clock.advance(POLL);
    expect(journal.logs[1]).toBe("⛵ Supervision session recovered after a successful cooldown probe.");
    files.set(HEALTH, health("s2", 0));
    await clock.advance(POLL);
    expect(journal.logs).toHaveLength(2);
  });

  test("a resumed session replays only outcomes it has not shown, and a new session replays every due one", async ($, on) => {
    const { clock, files, journal, setSessionId } = world(on);
    files.set(TAIL, tail(history));
    files.set(CURSOR, "5\n");
    files.set(PROCESSED, "2\n");
    await $.session.start(sessionStart);
    expect(journal.logs).toEqual(["⚓ [seq 3] fm-b: decision waiting"]);
    // Resumed (or hot reloaded): its restored transcript already holds seq 3.
    files.set(TAIL, tail([...history, { seq: 6, task: "fm-h", verdict: "captain", summary: "while closed" }]));
    await $.session.start(sessionStart);
    expect(journal.logs).toEqual(["⚓ [seq 3] fm-b: decision waiting", "⚓ [seq 6] fm-h: while closed"]);
    await clock.advance(POLL);
    expect(journal.logs).toHaveLength(2);
    setSessionId("session-2");
    await $.session.start(sessionStart);
    expect(journal.logs.slice(2)).toEqual(["⚓ [seq 3] fm-b: decision waiting", "⚓ [seq 6] fm-h: while closed"]);
  });
});
