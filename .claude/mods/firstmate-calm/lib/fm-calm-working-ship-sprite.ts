// Firstmate's harness-neutral Calm activity indicator.
//
// This module owns the indicator geometry, bounce track, linked animation cadences,
// and freeze/resume state shared by Pi and Claude Code. The historical file and API
// names remain stable because both harness adapters import them.

export const CALM_WORKING_SHIP_MARKERS = ["●", "◉", "○", "◉"] as const;
export const CALM_WORKING_SHIP_TRACK = "·";

/** Scheduler period. One tick advances the marker pulse. */
export const CALM_WORKING_SHIP_TICK_MS = 220;
/** The marker moves one column every fourth tick: 880ms per column. */
export const CALM_WORKING_SHIP_TICKS_PER_MOVE = 4;

export type CalmWorkingShipColor = "track" | "indicator";

export type CalmWorkingShipRun = {
  readonly text: string;
  readonly color: CalmWorkingShipColor;
};

/** One painted frame whose single row is exactly the requested width. */
export type CalmWorkingShipFrame = readonly (readonly CalmWorkingShipRun[])[];

export type CalmWorkingShipSprite = {
  frame(width: number): CalmWorkingShipFrame;
  tick(): void;
  restoreLastRendered(): void;
  reset(): void;
  clampToWidth(width: number): void;
  position(): number;
  direction(): number;
  /** Historical API name for the current four-step indicator pulse phase. */
  waterPhase(): number;
};

function trackSpan(width: number): number {
  return Math.max(0, width - 1);
}

export function createCalmWorkingShipSprite(): CalmWorkingShipSprite {
  let position = 0;
  let direction = 1;
  let span = 0;
  let phase = 0;
  let ticks = 0;
  let renderedPosition = position;
  let renderedDirection = direction;
  let renderedSpan = span;
  let renderedPhase = phase;
  let renderedTicks = ticks;

  const settleDirectionAtEdges = (): void => {
    if (span <= 0) return;
    if (position >= span) direction = -1;
    else if (position <= 0) direction = 1;
  };

  const applyWidth = (width: number): void => {
    if (width <= 0) {
      span = 0;
      position = 0;
      return;
    }
    span = trackSpan(width);
    position = Math.min(position, span);
    settleDirectionAtEdges();
  };

  const commitRenderedState = (): void => {
    renderedPosition = position;
    renderedDirection = direction;
    renderedSpan = span;
    renderedPhase = phase;
    renderedTicks = ticks;
  };

  return {
    position: () => position,
    direction: () => direction,
    waterPhase: () => phase,

    restoreLastRendered(): void {
      position = renderedPosition;
      direction = renderedDirection;
      span = renderedSpan;
      phase = renderedPhase;
      ticks = renderedTicks;
    },

    reset(): void {
      position = 0;
      direction = 1;
      span = 0;
      phase = 0;
      ticks = 0;
      commitRenderedState();
    },

    clampToWidth(width: number): void {
      applyWidth(width);
    },

    tick(): void {
      ticks += 1;
      phase = (phase + 1) % CALM_WORKING_SHIP_MARKERS.length;
      if (ticks % CALM_WORKING_SHIP_TICKS_PER_MOVE !== 0 || span <= 0) return;
      position += direction;
      settleDirectionAtEdges();
    },

    frame(width: number): CalmWorkingShipFrame {
      if (width <= 0) {
        applyWidth(width);
        commitRenderedState();
        return [];
      }
      applyWidth(width);
      const row: CalmWorkingShipRun[] = [];
      if (position > 0) {
        row.push({ text: CALM_WORKING_SHIP_TRACK.repeat(position), color: "track" });
      }
      row.push({
        text: CALM_WORKING_SHIP_MARKERS[phase] ?? CALM_WORKING_SHIP_MARKERS[0],
        color: "indicator",
      });
      const remaining = width - position - 1;
      if (remaining > 0) {
        row.push({ text: CALM_WORKING_SHIP_TRACK.repeat(remaining), color: "track" });
      }
      commitRenderedState();
      return [row];
    },
  };
}
