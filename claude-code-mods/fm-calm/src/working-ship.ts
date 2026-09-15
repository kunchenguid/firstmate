export const CALM_SHIP_TICK_MS = 220;
export const CALM_SHIP_TICKS_PER_MOVE = 4;
export const CALM_SHIP_HIDDEN_GAP_MS = 1000;

const HULL = "\\__/";
const SAIL_RIGHT = "<|";
const SAIL_LEFT = "|>";
const SAIL_OFFSET = 1;
const HULL_WIDTH = HULL.length;
const SAIL_WIDTH = SAIL_RIGHT.length;
const WAVE_CYCLE = ["~", "~", "-", "~"] as const;

export type CalmShipColor = "blue" | "yellow";

export type CalmShipSpan = {
  text: string;
  color: CalmShipColor;
};

export type CalmShipState = {
  position: number;
  direction: 1 | -1;
  phase: number;
  ticks: number;
  span: number;
  lastFrameMs: number | undefined;
};

export type CalmShipFrame = {
  state: CalmShipState;
  rows: CalmShipSpan[][];
};

export function initialCalmShipState(): CalmShipState {
  return {
    position: 0,
    direction: 1,
    phase: 0,
    ticks: 0,
    span: 0,
    lastFrameMs: undefined,
  };
}

export function calmShipTrackSpan(width: number): number {
  if (width >= HULL_WIDTH) return width - HULL_WIDTH;
  if (width >= SAIL_WIDTH) return width - SAIL_WIDTH;
  return 0;
}

function settleDirectionAtEdges(state: CalmShipState): 1 | -1 {
  if (state.span <= 0) return state.direction;
  if (state.position >= state.span) return -1;
  if (state.position <= 0) return 1;
  return state.direction;
}

function clampToWidth(state: CalmShipState, width: number): CalmShipState {
  if (width <= 0) {
    return { ...state, span: 0, position: 0 };
  }
  const span = calmShipTrackSpan(width);
  const clamped = { ...state, span, position: Math.min(state.position, span) };
  return { ...clamped, direction: settleDirectionAtEdges(clamped) };
}

function waterCells(from: number, count: number, phase: number): string {
  if (count <= 0) return "";
  let cells = "";
  for (let column = from; column < from + count; column += 1) {
    cells += WAVE_CYCLE[(column + phase) % WAVE_CYCLE.length];
  }
  return cells;
}

function waterSpans(from: number, count: number, phase: number): CalmShipSpan[] {
  const text = waterCells(from, count, phase);
  return text === "" ? [] : [{ text, color: "blue" }];
}

export function advanceCalmShip(state: CalmShipState, nowMs: number): CalmShipState {
  if (state.lastFrameMs === undefined) {
    return { ...state, lastFrameMs: nowMs };
  }

  const wallElapsed = nowMs - state.lastFrameMs;
  const elapsed = wallElapsed > CALM_SHIP_HIDDEN_GAP_MS ? 0 : Math.max(0, wallElapsed);
  const steps = Math.floor(elapsed / CALM_SHIP_TICK_MS);
  if (steps <= 0) {
    return elapsed === 0 ? { ...state, lastFrameMs: nowMs } : state;
  }

  let { position, direction, phase, ticks } = state;
  for (let step = 0; step < steps; step += 1) {
    ticks += 1;
    phase = (phase + 1) % WAVE_CYCLE.length;
    if (ticks % CALM_SHIP_TICKS_PER_MOVE === 0) {
      position = state.span <= 0 ? 0 : Math.min(state.span, Math.max(0, position + direction));
      direction = settleDirectionAtEdges({ ...state, position, direction, span: state.span });
    }
  }

  return {
    position,
    direction,
    phase,
    ticks,
    span: state.span,
    lastFrameMs: nowMs - (elapsed % CALM_SHIP_TICK_MS),
  };
}

export function calmShipRows(state: CalmShipState, width: number): CalmShipSpan[][] {
  if (width <= 0) return [];

  const sail = state.direction >= 0 ? SAIL_RIGHT : SAIL_LEFT;

  if (width < SAIL_WIDTH) {
    return [waterSpans(0, width, state.phase)];
  }

  if (width < HULL_WIDTH) {
    return [
      [
        ...waterSpans(0, state.position, state.phase),
        { text: sail, color: "yellow" },
        ...waterSpans(state.position + SAIL_WIDTH, width - state.position - SAIL_WIDTH, state.phase),
      ],
    ];
  }

  return [
    [
      ...(state.position + SAIL_OFFSET > 0
        ? [{ text: " ".repeat(state.position + SAIL_OFFSET), color: "yellow" as CalmShipColor }]
        : []),
      { text: sail, color: "yellow" },
    ],
    [
      ...waterSpans(0, state.position, state.phase),
      { text: HULL, color: "yellow" },
      ...waterSpans(state.position + HULL_WIDTH, width - state.position - HULL_WIDTH, state.phase),
    ],
  ];
}

export function stepCalmShip(
  state: CalmShipState,
  width: number,
  nowMs: number,
): CalmShipFrame {
  const laidOut = clampToWidth(state, width);
  const advanced = advanceCalmShip(laidOut, nowMs);
  const settled = clampToWidth(advanced, width);
  return { state: settled, rows: calmShipRows(settled, width) };
}

export function calmShipLine(spans: CalmShipSpan[]): string {
  return spans.map((span) => span.text).join("");
}

export function calmShipText(frame: CalmShipFrame): string[] {
  return frame.rows.map(calmShipLine);
}