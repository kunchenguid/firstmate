// Firstmate's Calm-only animated spaceship working presentation.
//
// This module is the selectable spaceship counterpart of fm-calm-working-ship.ts and
// follows the same contract shape the redesigned `.pi/extensions/fm-calm.ts` consumes:
// a per-extension-lifetime animation, a temporary TUI widget bound to it, and one
// widget key. Unlike the boat, the spaceship is a persistent banner while Calm is
// active: the saucer is visible when idle, not only while a run is under way.
// `.pi/extensions/fm-calm.ts` owns when either presentation is installed and removed,
// drives setWorking() from the same run-visibility signals the boat consumes, and
// stays the sole caller of setWorkingVisible(). docs/calm.md owns the captain-facing
// contract.
//
// Two modes and one bounded transition:
//
// - IDLE: the saucer drifts slowly and continuously left to right across the banner
//   in the two-row rest pose (the five-cell `( | )` saucer over the three-cell `|^|`
//   hull, centered), one column every IDLE_TICKS_PER_MOVE ticks (~1.5 seconds),
//   wrapping marquee-style back to the left edge when it crosses the right edge,
//   while the hull row's asymmetric `*`/`.` starfield streams one column every
//   IDLE_TICKS_PER_PHASE ticks (~1.3 seconds), so the stars visibly move left past
//   the chasing ship instead of just twinkling in place; and when crew markers are
//   set (setCrew), the marker band drifts right on its own cadence (one column every
//   CREW_DRIFT_TICKS_PER_MOVE ticks), wrapping across the full width, so the crews
//   flow right in a distinct rhythm past the saucer instead of in lockstep with it.
// - WORKING (a run is thinking): the sprite becomes the single-row compact `=( * )`
//   saucer (yellow) on the banner row - the two-row pose is not rendered in warp - the
//   saucer sweeps right one column every TICKS_PER_MOVE ticks (~880ms per column)
//   across the full track, wrapping marquee-style back to the left edge when it
//   crosses the right edge so it never parks, the starfield advances
//   WORKING_PHASES_PER_TICK phases per tick (faster than the idle stream), and the
//   field renders as warp streaks streaming left past the sprite.
// - Settle: setWorking(false) relaxes the sprite back to the two-row rest pose, returns the
//   stars to the idle cadence immediately, and eases the movement pace back into the
//   slow idle drift: the next few moves run at graduated intervals that lengthen by
//   one tick per move until they reach the drift pace, always moving exactly one
//   column per move and never teleporting. The whole ease is bounded to
//   SETTLE_EASE_MOVES moves, after which the marquee drift continues indefinitely.
//
// Ticks, not wall-clock timestamps, drive every state change, so tests can seek time
// exactly. One scheduler drives the star clock and the saucer clock; both stop
// together when the widget is disposed.
//
// Continuity: one extension-owned animation instance survives hide/show within the
// same Pi process and Calm extension lifetime. Disposing the widget freezes column,
// starfield phase, movement countdown, and mode transition state without advancing
// them for hidden wall time. The next working period resumes from that exact logical
// state, including mid-drift and mid-warp. A fresh session or new extension lifetime
// calls reset() and starts at the left edge. State is never a module-level or
// process-global singleton.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { Component, TUI } from "@earendil-works/pi-tui";

// The idle rest pose is two rows: the three-cell `(|)` saucer chevron over the
// three-cell `|^|` hull. The `|` reads as the ship's dome/antenna; the pair are the
// same width, so the hull sits directly beneath the saucer as they sweep.
const SAUCER_IDLE = "(|)";
const SAUCER_IDLE_WIDTH = SAUCER_IDLE.length;
const HULL = "|^|";
const HULL_WIDTH = HULL.length;
// The three-cell hull centers under the three-cell saucer with no offset.
const HULL_CENTER_OFFSET = (SAUCER_IDLE_WIDTH - HULL_WIDTH) / 2;
// The compact single-row working sprite: hull stroke trailing on the left, dome cockpit
// forward on the right, so the saucer reads as facing right while it cruises. The warp
// keeps the starred cockpit `( * )`.
const WARP_SPRITE = "=( * )";
const WARP_WIDTH = WARP_SPRITE.length;

// Bounded deterministic fixed-cell starfield phases. Every entry is exactly one
// column. The unit is deliberately asymmetric (star, dot, gap, dot) so a phase step
// SLIDES the whole pattern one column instead of only inverting it in place: the old
// symmetric `* . * .` unit just blinked (each cell flipped between `*` and `.`), while
// this unit streams, so the idle saucer's row visibly travels left past the saucer.
const STAR_CYCLE = ["*", ".", " ", "."] as const;
// Working-mode warp streaks, one column per entry. The same phase drives both
// cycles: because the phase advances two steps per working tick, each streak glyph
// streams two columns left per tick, past the sprite, while the saucer cruises right.
const STREAK_CYCLE = [" ", "-", ".", "-"] as const;

// Standard ANSI foreground codes only: no theme lookup, bright variant, or 256/RGB.
const BLUE = "\u001b[34m";
const YELLOW = "\u001b[33m";
const GREEN = "\u001b[32m";
const RED = "\u001b[31m";
// Restores the default foreground so color never bleeds into padding or later frames.
const RESET = "\u001b[39m";

export const CALM_WORKING_SPACESHIP_WIDGET_KEY = "firstmate-calm-working-spaceship";
/** Scheduler period. One tick is the base unit for every clock below. */
export const CALM_WORKING_SPACESHIP_TICK_MS = 220;
/** Idle starfield cadence: one twinkle phase every Nth tick (~1.3s at 220ms). */
export const CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_PHASE = 6;
/** Idle drift cadence: one column every Nth tick (~1.5s per column, marquee loop). */
export const CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE = 7;
/** Working starfield cadence: phases advanced per tick (~110ms per phase). */
export const CALM_WORKING_SPACESHIP_WORKING_PHASES_PER_TICK = 2;
/** Working cruise cadence: one column every Nth tick (880ms per column). */
export const CALM_WORKING_SPACESHIP_TICKS_PER_MOVE = 4;
/**
 * Settle ease bound: after settling, the movement pace lengthens by one tick per move
 * for exactly this many moves before it reaches the idle drift pace, so the whole
 * transition is bounded and never jumps.
 */
export const CALM_WORKING_SPACESHIP_SETTLE_EASE_MOVES = 3;
/** Crew markers refresh cadence: one low-cost state-directory read every Nth tick (~11s at 220ms). */
export const CALM_WORKING_SPACESHIP_CREW_REFRESH_TICKS = 50;
/** Blank cells between adjacent crew markers in the idle top row, so they spread out. */
export const CALM_WORKING_SPACESHIP_CREW_MARKER_GAP = 2;
/** Crew-marker drift cadence: the marker band advances one column every Nth tick on
    its own clock, distinct from the saucer's idle sweep, so the crews flow right in a
    different rhythm rather than in lockstep with the saucer. */
export const CALM_WORKING_SPACESHIP_CREW_DRIFT_TICKS_PER_MOVE = 10;

/** Coarse crew state shown as a marker, mapped from the home's own state records. */
export type CalmCrewMarkerState = "working" | "blocked" | "done" | "idle";
export type CalmCrewMarker = { state: CalmCrewMarkerState };

export type CalmWorkingSpaceshipAnimation = {
  /** Render one frame that exactly fits `width`, clamping the track to it first. */
  render(width: number): string[];
  /** Advance one scheduler tick: the mode owns both clocks. */
  tick(): void;
  restoreLastRendered(): void;
  /** Restore the left-edge pose, idle cadence, and no settle ease. */
  reset(): void;
  /**
   * Clamp the frozen column to `width` without advancing time.
   * Used when a terminal resize lands while the working presentation is hidden.
   */
  clampToWidth(width: number): void;
  /** Current sprite column, exposed for deterministic motion assertions. */
  position(): number;
  /** Current starfield phase, exposed for deterministic twinkle and streak assertions. */
  starPhase(): number;
  /** True while a run is thinking: compact warp sprite, cruise, fast streaks. */
  isWorking(): boolean;
  /** True while the settle ease back into the drift pace is still under way. */
  isGliding(): boolean;
  /**
   * Drive the mode from the same run-visibility signals the boat consumes.
   * Settling starts the bounded pace ease back into the idle drift.
   */
  setWorking(active: boolean): void;
  /**
   * Replace the crew markers shown in the idle top row. One marker per crew,
   * colored by a coarse state, spread across the right side of the row.
   */
  setCrew(markers: CalmCrewMarker[]): void;
};

/** Longest sprite start column that still fits in `width` usable cells. */
function trackSpan(width: number, working: boolean): number {
  if (working) return width >= WARP_WIDTH ? width - WARP_WIDTH : 0;
  if (width >= SAUCER_IDLE_WIDTH) return width - SAUCER_IDLE_WIDTH;
  // Too narrow for the saucer chevron but wide enough for the hull: the hull alone
  // rides the field, so its own width bounds the track.
  if (width >= HULL_WIDTH) return width - HULL_WIDTH;
  return 0;
}

export function createCalmWorkingSpaceshipAnimation(): CalmWorkingSpaceshipAnimation {
  let position = 0;
  let span = 0;
  let phase = 0;
  let ticks = 0;
  let working = false;
  // Idle movement clock: ticks remaining until the next drift column, and the interval
  // that countdown restarts with after each move. While easing after a settle, the
  // interval lengthens by one tick per move until it reaches the drift pace.
  let nextMoveIn = CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE;
  let moveInterval = CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE;
  let easeMovesRemaining = 0;
  let crew: CalmCrewMarker[] = [];
  // Marker-band drift: the whole crew band slides right one column per idle move,
  // wrapping across the full row width, so the `>` markers flow right past the
  // saucer instead of sitting pinned to the right edge. Independent of the saucer's
  // own track (which wraps at the sprite width, not the full row).
  let crewDrift = 0;
  let crewDriftTicks = 0;
  let width: number | undefined;
  let renderedPosition = position;
  let renderedSpan = span;
  let renderedPhase = phase;
  let renderedTicks = ticks;
  let renderedNextMoveIn = nextMoveIn;
  let renderedMoveInterval = moveInterval;
  let renderedEaseMovesRemaining = easeMovesRemaining;
  let renderedCrewDrift = crewDrift;
  let renderedCrewDriftTicks = crewDriftTicks;

  const applyWidth = (nextWidth: number): void => {
    width = nextWidth;
    if (nextWidth <= 0) {
      span = 0;
      position = 0;
      return;
    }
    span = trackSpan(nextWidth, working);
    position = Math.min(position, span);
  };

  const commitRenderedState = (): void => {
    renderedPosition = position;
    renderedSpan = span;
    renderedPhase = phase;
    renderedTicks = ticks;
    renderedNextMoveIn = nextMoveIn;
    renderedMoveInterval = moveInterval;
    renderedEaseMovesRemaining = easeMovesRemaining;
    renderedCrewDrift = crewDrift;
    renderedCrewDriftTicks = crewDriftTicks;
  };

  const restoreLastRenderedState = (): void => {
    position = renderedPosition;
    span = renderedSpan;
    phase = renderedPhase;
    ticks = renderedTicks;
    nextMoveIn = renderedNextMoveIn;
    moveInterval = renderedMoveInterval;
    easeMovesRemaining = renderedEaseMovesRemaining;
    crewDrift = renderedCrewDrift;
    crewDriftTicks = renderedCrewDriftTicks;
  };

  /** One colored field run covering absolute columns [from, from + count). */
  const field = (from: number, count: number): string => {
    if (count <= 0) return "";
    const cycle = working ? STREAK_CYCLE : STAR_CYCLE;
    let cells = "";
    for (let column = from; column < from + count; column += 1) {
      cells += cycle[(column + phase) % cycle.length];
    }
    return `${BLUE}${cells}${RESET}`;
  };

  /** Sparse dots-only fill for the row the saucer rides: a quiet `.` accent (no `*`)
      every third column, anchored to absolute columns so the sparse pattern stays
      stable as the saucer sweeps instead of sliding with it. */
  const dots = (from: number, count: number): string => {
    if (count <= 0) return "";
    let cells = "";
    for (let column = from; column < from + count; column += 1) {
      cells += column % 3 === 0 ? "." : " ";
    }
    return `${BLUE}${cells}${RESET}`;
  };

  const craft = (text: string): string => `${YELLOW}${text}${RESET}`;

  const markerColor = (state: CalmCrewMarkerState): string => {
    switch (state) {
      case "working":
        return GREEN;
      case "blocked":
        return RED;
      case "done":
        return BLUE;
      case "idle":
      default:
        return RESET;
    }
  };

  // Marker band, right-aligned at drift 0: crew[i] reads left to right, the whole
  // group anchored to the right edge, then slid right by the current crewDrift and
  // wrapped across the full width, so the band flows right over time. When the row
  // is too narrow for every marker, keep the rightmost ones and drop the excess
  // that would crowd the left of the row.
  const crewMarkerColumns = (width: number): { column: number; state: CalmCrewMarkerState }[] => {
    const placed: { column: number; state: CalmCrewMarkerState }[] = [];
    const count = crew.length;
    if (count === 0 || width <= 0) return placed;
    const gap = CALM_WORKING_SPACESHIP_CREW_MARKER_GAP;
    const kept = Math.min(count, Math.max(0, Math.floor((width + gap) / (gap + 1))));
    if (kept === 0) return placed;
    const start = width - (kept + (kept - 1) * gap);
    const tail = crew.slice(-kept);
    for (let i = 0; i < kept; i += 1) {
      placed.push({ column: (start + i * (gap + 1) + crewDrift) % width, state: tail[i].state });
    }
    return placed;
  };

  // The idle top (saucer) row: a sparse blue dot field, with the crew markers overlaid
  // on the right as colored `>` glyphs, and the saucer drawn last so it passes in front
  // of any marker it crosses.
  const saucerRow = (width: number): string => {
    const markers = crewMarkerColumns(width);
    const byColumn = new Map<number, CalmCrewMarkerState>();
    for (const marker of markers) byColumn.set(marker.column, marker.state);
    let cells = "";
    for (let column = 0; column < width; column += 1) {
      if (column >= position && column < position + SAUCER_IDLE_WIDTH) {
        cells += YELLOW + SAUCER_IDLE[column - position] + RESET;
      } else if (byColumn.has(column)) {
        cells += markerColor(byColumn.get(column) as CalmCrewMarkerState) + ">" + RESET;
      } else {
        cells += BLUE + (column % 3 === 0 ? "." : " ") + RESET;
      }
    }
    return cells;
  };

  return {
    position: () => position,
    starPhase: () => phase,
    isWorking: () => working,
    isGliding: () => easeMovesRemaining > 0,

    restoreLastRendered: restoreLastRenderedState,

    reset(): void {
      position = 0;
      span = 0;
      phase = 0;
      ticks = 0;
      working = false;
      nextMoveIn = CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE;
      moveInterval = CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE;
      easeMovesRemaining = 0;
      crewDrift = 0;
      crewDriftTicks = 0;
      width = undefined;
      commitRenderedState();
    },

    clampToWidth(nextWidth: number): void {
      applyWidth(nextWidth);
    },

    setWorking(active: boolean): void {
      if (active === working) {
        // A repeated start inside one logical run must not restart the cruise.
        return;
      }
      working = active;
      if (active) {
        easeMovesRemaining = 0;
      } else {
        // Settle: ease the pace from the cruise cadence back into the drift cadence.
        // The first eased move runs at the cruise pace, then each later move waits one
        // tick longer, so the transition is smooth, bounded, and never teleports.
        easeMovesRemaining = CALM_WORKING_SPACESHIP_SETTLE_EASE_MOVES;
        moveInterval = CALM_WORKING_SPACESHIP_TICKS_PER_MOVE;
        nextMoveIn = CALM_WORKING_SPACESHIP_TICKS_PER_MOVE;
      }
      // The track bound depends on the sprite the mode renders.
      if (width !== undefined) applyWidth(width);
    },

    setCrew(markers: CalmCrewMarker[]): void {
      crew = markers;
    },

    tick(): void {
      ticks += 1;
      if (working) {
        phase = (phase + CALM_WORKING_SPACESHIP_WORKING_PHASES_PER_TICK) % STAR_CYCLE.length;
        if (ticks % CALM_WORKING_SPACESHIP_TICKS_PER_MOVE !== 0) return;
        if (span <= 0) {
          position = 0;
          return;
        }
        // Warp marquee: keep sweeping right across the full track at the working
        // cadence, wrapping back to the left edge after the right edge, so the
        // thinking saucer never parks.
        position += 1;
        if (position > span) position = 0;
        return;
      }
      // Idle and easing share the slow idle twinkle cadence.
      if (ticks % CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_PHASE === 0) {
        phase = (phase + 1) % STAR_CYCLE.length;
      }
      // The crew-marker band drifts right on its own clock, distinct from the saucer's
      // sweep, so the crews flow right in a different rhythm rather than in lockstep
      // with the saucer.
      crewDriftTicks += 1;
      if (crewDriftTicks >= CALM_WORKING_SPACESHIP_CREW_DRIFT_TICKS_PER_MOVE) {
        crewDriftTicks = 0;
        if (width !== undefined && width > 0) {
          crewDrift = (crewDrift + 1) % width;
        }
      }
      nextMoveIn -= 1;
      if (nextMoveIn > 0) return;
      // Marquee drift: always one column right, wrapping to the left edge after the
      // right edge, so the sweep is continuous and never reverses.
      if (span > 0) {
        position += 1;
        if (position > span) position = 0;
      }
      if (easeMovesRemaining > 0) {
        easeMovesRemaining -= 1;
        moveInterval = Math.min(CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE, moveInterval + 1);
      } else {
        moveInterval = CALM_WORKING_SPACESHIP_IDLE_TICKS_PER_MOVE;
      }
      nextMoveIn = moveInterval;
    },

    render(nextWidth: number): string[] {
      if (nextWidth <= 0) return [];

      // A resize lands here before the next frame, so recompute and clamp the track
      // immediately rather than trusting a position measured against the old width.
      applyWidth(nextWidth);

      let frame: string[];
      if (working) {
        // Warp is the compact single-row sprite: streaks stream left past it. Too
        // narrow for even the sprite, the bare streak field remains.
        frame =
          nextWidth >= WARP_WIDTH
            ? [
                field(0, position) +
                  craft(WARP_SPRITE) +
                  field(position + WARP_WIDTH, nextWidth - position - WARP_WIDTH),
              ]
            : [field(0, nextWidth)];
      } else if (nextWidth >= SAUCER_IDLE_WIDTH) {
        // Two-row rest pose: the `(|)` saucer rides a quiet dotted row while the
        // `|^|` hull below keeps the streaming starfield (the asymmetric cycle slides,
        // so the stars visibly move left past the chasing ship). The saucer and hull
        // are both three cells wide, so the hull centers directly beneath the saucer.
        // The crew markers (added by setCrew) overlay the same top row on the right,
        // drawn before the saucer so the sweeping saucer passes in front of them.
        frame = [
          saucerRow(nextWidth),
          field(0, position + HULL_CENTER_OFFSET) +
            craft(HULL) +
            field(
              position + HULL_CENTER_OFFSET + HULL_WIDTH,
              nextWidth - position - HULL_CENTER_OFFSET - HULL_WIDTH,
            ),
        ];
      } else if (nextWidth >= HULL_WIDTH) {
        // Too narrow for the saucer chevron but wide enough for the hull: the hull
        // alone rides the streaming starfield.
        frame = [
          field(0, position) + craft(HULL) + field(position + HULL_WIDTH, nextWidth - position - HULL_WIDTH),
        ];
      } else {
        // Too narrow for even the hull: a bare deterministic starfield stays.
        frame = [field(0, nextWidth)];
      }

      commitRenderedState();
      return frame;
    },
  };
}

/**
 * Build the persistent Calm banner widget bound to one caller-owned animation.
 * Pi disposes the previous component before installing a replacement under the same
 * key and when it clears extension widgets, so the single scheduler driving both
 * cadences cannot outlive the widget or duplicate. Disposing freezes the shared
 * animation in place; the next widget bound to the same animation resumes without
 * applying hidden wall time.
 */
export function createCalmWorkingSpaceshipWidget(
  tui: TUI,
  animation: CalmWorkingSpaceshipAnimation = createCalmWorkingSpaceshipAnimation(),
  crewSource?: () => CalmCrewMarker[],
): Component & { dispose(): void } {
  let disposed = false;
  let crewTicks = 0;
  const refreshCrew = (): void => {
    if (!crewSource) return;
    try {
      animation.setCrew(crewSource());
    } catch {
      // A crew-state read must never break the banner; leave the last markers.
    }
  };
  refreshCrew();
  const timer = setInterval(() => {
    if (disposed) return;
    animation.tick();
    crewTicks += 1;
    if (crewSource && crewTicks % CALM_WORKING_SPACESHIP_CREW_REFRESH_TICKS === 0) {
      refreshCrew();
    }
    tui.requestRender();
  }, CALM_WORKING_SPACESHIP_TICK_MS);
  // The animation must never keep Pi's process alive on its own.
  timer.unref?.();

  return {
    render: (widgetWidth) => (disposed ? [] : animation.render(widgetWidth)),
    // Every frame is rebuilt from fixed standard ANSI codes, so there is no cache.
    invalidate: () => {},
    dispose: () => {
      if (disposed) return;
      disposed = true;
      clearInterval(timer);
      animation.restoreLastRendered();
    },
  };
}

/**
 * The last non-empty event line from a crew's `state/<id>.status` log, split into its
 * leading keyword (working/blocked/done/...) and the full text. The log is append-only
 * wake-event history, not current state, so this is an at-a-glance signal only.
 */
function lastCrewEvent(stateDir: string, id: string): { event: string; text: string } {
  try {
    const content = readFileSync(join(stateDir, `${id}.status`), "utf8");
    const lines = content.split("\n").filter((line) => line.trim().length > 0);
    const line = lines[lines.length - 1] ?? "";
    const match = /^([A-Za-z-]+)/.exec(line.trim());
    return { event: match ? match[1].toLowerCase() : "", text: line };
  } catch {
    return { event: "", text: "" };
  }
}

/** Map a crew's leading status keyword to the marker colour the banner shows. */
function stateFromCrewEvent(event: string): CalmCrewMarkerState {
  switch (event) {
    case "working":
      return "working";
    case "blocked":
    case "needs-decision":
    case "failed":
      return "blocked";
    case "done":
    case "ready":
      return "done";
    default:
      return "idle";
  }
}

/**
 * A crew is live (shown as a marker) only while its work is on the go right now:
 * actively working, or needing the captain (blocked / needs-decision / failed). A
 * concluded-and-reported job, a deliverable that merely awaits review, and a paused
 * or held crew are not active, so they drop off the banner. This keeps the banner to
 * the crews actually doing something rather than every dispatch the home has tracked.
 */
function crewEventIsLive(event: string): boolean {
  switch (event) {
    case "working":
    case "blocked":
    case "needs-decision":
    case "failed":
      return true;
    default:
      return false;
  }
}

/**
 * Coarse crew-state classification from a crew's own `state/<id>.status` event log.
 * The last event's leading keyword names the state the banner shows (working green,
 * blocked/needs-you red, done blue, idle dim).
 */
export function classifyCrewMarkerState(stateDir: string, id: string): CalmCrewMarkerState {
  return stateFromCrewEvent(lastCrewEvent(stateDir, id).event);
}

/**
 * One marker per active crew from the home's own state records: each `state/<id>.meta`
 * is read and included only when its status shows work on the go right now (working,
 * blocked, needs-decision, or failed). Cheap file reads on a slow tick, backend-
 * agnostic - Herdr supplies only the colour *language*, never the data. A missing or
 * unreadable state directory yields an empty marker list.
 */
export function readCalmCrewMarkers(stateDir: string): CalmCrewMarker[] {
  let entries: string[];
  try {
    entries = readdirSync(stateDir);
  } catch {
    return [];
  }
  const ids = entries.filter((entry) => entry.endsWith(".meta")).map((entry) => entry.slice(0, -5)).sort();
  const markers: CalmCrewMarker[] = [];
  for (const id of ids) {
    const { event } = lastCrewEvent(stateDir, id);
    if (!crewEventIsLive(event)) continue;
    markers.push({ state: stateFromCrewEvent(event) });
  }
  return markers;
}
