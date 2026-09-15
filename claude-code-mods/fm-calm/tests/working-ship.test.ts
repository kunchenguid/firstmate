import { expect, test } from "claude-code/testing";
import {
  CALM_SHIP_HIDDEN_GAP_MS,
  CALM_SHIP_TICK_MS,
  CALM_SHIP_TICKS_PER_MOVE,
  calmShipText,
  initialCalmShipState,
  stepCalmShip,
  type CalmShipState,
} from "../src/working-ship.ts";

const WIDE = 40;

function clock(startMs = 100000) {
  let now = startMs;
  return {
    at: () => now,
    prime: (state: CalmShipState, width = WIDE) => stepCalmShip(state, width, now).state,
    tick: (state: CalmShipState, width = WIDE) => {
      now += CALM_SHIP_TICK_MS;
      return stepCalmShip(state, width, now).state;
    },
    ticks: (state: CalmShipState, count: number, width = WIDE) => {
      let next = state;
      for (let index = 0; index < count; index += 1) {
        now += CALM_SHIP_TICK_MS;
        next = stepCalmShip(next, width, now).state;
      }
      return next;
    },
    idle: (state: CalmShipState, ms: number, width = WIDE) => {
      now += ms;
      return stepCalmShip(state, width, now).state;
    },
    frame: (state: CalmShipState, width = WIDE) => stepCalmShip(state, width, now),
  };
}

test("a fresh state starts at the left edge travelling right", () => {
  const state = initialCalmShipState();
  expect(state.position).toBe(0);
  expect(state.direction).toBe(1);
  expect(state.phase).toBe(0);
  expect(state.ticks).toBe(0);
});

test("the water ripples on every tick and the boat moves once per four", () => {
  const time = clock();
  let state = time.tick(time.prime(initialCalmShipState()));
  expect(state.ticks).toBe(1);
  expect(state.phase).toBe(1);
  expect(state.position).toBe(0);

  state = time.ticks(state, CALM_SHIP_TICKS_PER_MOVE - 1);
  expect(state.ticks).toBe(CALM_SHIP_TICKS_PER_MOVE);
  expect(state.position).toBe(1);
  expect(state.direction).toBe(1);
});

test("a hidden gap freezes the animation, and the next frame resumes from it", () => {
  const time = clock();
  const moved = time.ticks(time.prime(initialCalmShipState()), CALM_SHIP_TICKS_PER_MOVE);
  expect(moved.position).toBe(1);

  const hidden = time.idle(moved, CALM_SHIP_HIDDEN_GAP_MS + CALM_SHIP_TICK_MS * 10);
  expect(hidden.position).toBe(moved.position);
  expect(hidden.phase).toBe(moved.phase);
  expect(hidden.ticks).toBe(moved.ticks);
  expect(hidden.direction).toBe(moved.direction);

  const resumed = time.ticks(hidden, CALM_SHIP_TICKS_PER_MOVE);
  expect(resumed.position).toBe(moved.position + 1);
  expect(resumed.direction).toBe(moved.direction);
});

test("the sail flips on the frame the boat reaches an edge", () => {
  const time = clock();
  const width = 8;
  let state = time.frame(initialCalmShipState(), width).state;
  expect(state.span).toBe(4);

  state = time.ticks(state, CALM_SHIP_TICKS_PER_MOVE * 4, width);
  expect(state.position).toBe(4);
  expect(state.direction).toBe(-1);
  expect(calmShipText(time.frame(state, width))[0]).toContain("|>");

  state = time.ticks(state, CALM_SHIP_TICKS_PER_MOVE, width);
  expect(state.position).toBe(3);
});

test("very narrow terminals fall back to a smaller deterministic sprite", () => {
  const time = clock();
  const oneColumn = time.frame(initialCalmShipState(), 1);
  expect(oneColumn.rows.length).toBe(1);
  expect(calmShipText(oneColumn)).toEqual(["~"]);

  const sailOnly = time.frame(initialCalmShipState(), 3);
  expect(sailOnly.rows.length).toBe(1);
  expect(calmShipText(sailOnly)[0]).toContain("<|");

  const full = time.frame(initialCalmShipState(), 10);
  expect(full.rows.length).toBe(2);
  expect(calmShipText(full)[1]).toContain("\\__/");
});

test("every row fits the requested width", () => {
  const time = clock();
  for (const width of [0, 1, 2, 3, 4, 5, 12, 40, 120]) {
    let state = time.frame(initialCalmShipState(), width).state;
    state = time.ticks(state, CALM_SHIP_TICKS_PER_MOVE * 3, width);
    for (const line of calmShipText(time.frame(state, width))) {
      expect(line.length).toBeLessThanOrEqual(width);
    }
  }
});

test("a resize clamps the frozen boat and keeps its heading when the track vanishes", () => {
  const time = clock();
  const moving = time.ticks(initialCalmShipState(), CALM_SHIP_TICKS_PER_MOVE * 3);
  expect(moving.direction).toBe(1);

  const narrowed = time.frame(moving, 4);
  expect(narrowed.state.position).toBe(0);
  expect(narrowed.state.span).toBe(0);
  expect(narrowed.state.direction).toBe(moving.direction);

  const stillWide = time.frame(moving, 40);
  expect(stillWide.state.position).toBe(moving.position);
  expect(stillWide.state.direction).toBe(moving.direction);
});

test("the boat sails left after it has bounced", () => {
  const time = clock();
  let state = time.frame(initialCalmShipState(), 8).state;
  state = time.ticks(state, CALM_SHIP_TICKS_PER_MOVE * 5, 8);
  expect(state.position).toBe(3);
  expect(state.direction).toBe(-1);
  expect(calmShipText(time.frame(state, 8))[0]).toContain("|>");
});