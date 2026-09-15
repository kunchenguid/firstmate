// Firstmate Calm for Claude Code: the hooks module of the `firstmate-calm` mod.
//
// A Claude Code "mod" is a plugin whose behavior lives in one hooks module, loaded only
// while Claude Code's default-off early-access function-hooks surface is on
// (`CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`). Claude Code itself never loads this file
// while that flag is off, and the plugin carries no command, skill, agent, or classic
// hook of its own, so the mod is a complete no-op there; the `/calm` command below
// exists only once this module has registered it. docs/calm.md owns the captain-facing
// contract and docs/calm-mode-feasibility.md the version-scoped evidence.
//
// This file is the only place the engine interface `$` is touched: the geometry lives
// in ../lib/fm-calm-working-ship-sprite.ts (shared with the Pi extension), the Raster
// packing in ../lib/fm-calm-ship-raster.ts, and every visibility decision in
// ../lib/fm-calm-presentation.ts, so the policy is testable under Node and the engine
// glue under `claude plugin test`. Nothing here rewrites a message: `ui.render` changes
// drawings and leaves the stored transcript, model context, and session storage alone.
//
// Presentation while Calm is on, matching Pi Calm's policy where the mods API allows:
// the stock working row (`Spinner`) becomes the two-row sailboat, repainted through
// `$.ui.blit` on the sprite's own tick; `ToolUse`, `ToolResult`, and `ToolGroup` rows
// draw as zero-height boxes; a `UserMessage` whose text the canonical operational-input
// classifier recognizes draws as zero height; an `AssistantMessage` block recorded as a
// mid-turn working note draws as zero height. Calm off returns every drawing to the
// engine. A toggle invalidates every hooked drawing, so rows already on screen redraw.
//
// Loading is lazy and cached: a resumed transcript or a hot reload can draw restored
// rows before `session.start`, so every hook awaits the same one-time load of the
// per-home preference and restored working notes rather than trusting a stale "off".
import type { EngineInterface, Register, RenderElement, RenderInput } from "claude-code";
import {
  CALM_WORKING_SHIP_TICK_MS,
  createCalmWorkingShipSprite,
} from "../lib/fm-calm-working-ship-sprite.ts";
import {
  CALM_SHIP_RASTER_KEY,
  calmShipRasterColumns,
  packCalmShipRasterCells,
} from "../lib/fm-calm-ship-raster.ts";
import {
  calmPreferencePath,
  parseCalmPreference,
  restoredWorkingNotes,
  serializeCalmPreference,
  stepTextIsWorkingNote,
  userTextIsOperational,
  workingNoteKey,
} from "../lib/fm-calm-presentation.ts";

/** The slash command the mod serves, the same name as Pi's `/calm`. */
const CALM_COMMAND = "calm";

// One module environment holds one Calm state; a hot reload starts a fresh one, the
// same as a new Pi extension lifetime.
let calm = false;
let preferencePath: string | undefined;
let loading: Promise<void> | undefined;
let ticker: { cancel(): void } | undefined;
const workingNotes = new Set<string>();
const sprite = createCalmWorkingShipSprite();
// Every Spinner site currently drawing the boat, by its requestId, with the mounted
// Raster size a blit must repeat exactly.
const sites = new Map<string, { columns: number; rows: number }>();

async function readPreference($: EngineInterface, path: string): Promise<string | undefined> {
  try {
    return await $.fs.read(path);
  } catch {
    return undefined;
  }
}

async function load($: EngineInterface): Promise<void> {
  preferencePath = calmPreferencePath(
    {
      FM_HOME: await $.env.get("FM_HOME"),
      FM_ROOT_OVERRIDE: await $.env.get("FM_ROOT_OVERRIDE"),
      FM_CONFIG_OVERRIDE: await $.env.get("FM_CONFIG_OVERRIDE"),
    },
    $.plugin.root,
  );
  calm = parseCalmPreference(await readPreference($, preferencePath));
  try {
    for (const note of restoredWorkingNotes(await $.session.messages())) workingNotes.add(note);
  } catch {
    // A transcript that cannot be read leaves restored narration visible; nothing else changes.
  }
  if (ticker === undefined) {
    ticker = $.clock.every(CALM_WORKING_SHIP_TICK_MS, () => {
      void repaintShip($);
    });
  }
  $.ui.invalidate("ui.render");
}

function ensureLoaded($: EngineInterface): Promise<void> {
  if (loading === undefined) loading = load($);
  return loading;
}

/** One scheduler tick: advance the sprite, then repaint every mounted boat in place. */
async function repaintShip($: EngineInterface): Promise<void> {
  if (!calm || sites.size === 0) return;
  sprite.tick();
  for (const [requestId, site] of sites) {
    const packed = packCalmShipRasterCells(sprite.frame(site.columns), site.columns);
    const result = await $.ui.blit({
      requestId,
      key: CALM_SHIP_RASTER_KEY,
      cells: packed.cells,
      columns: site.columns,
      rows: site.rows,
    });
    // A denied blit means the site no longer shows this plugin's Raster (the turn
    // settled, or a resize redrew it); forget it until the next Spinner drawing.
    if (result.deny !== undefined && sites.get(requestId) === site) sites.delete(requestId);
  }
}

/** A zero-height drawing: the row contributes nothing to the transcript's layout. */
function hiddenRow($: EngineInterface, e: RenderInput): RenderElement {
  const { Box } = $.ui.resolve(e);
  return Box({ display: "none" });
}

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    // A genuine new session lifetime starts the boat at the normal initial position.
    sprite.reset();
    await ensureLoaded($);
    await $.command.register({
      name: CALM_COMMAND,
      description: "Toggle Firstmate's Calm transcript presentation and working ship.",
    });
    return next(e);
  });

  on("command.run", { command: CALM_COMMAND }, async ($) => {
    await ensureLoaded($);
    const active = !calm;
    // Persist before changing live presentation, so a failed write leaves the current
    // choice unchanged rather than claiming persistence.
    try {
      await $.fs.write(preferencePath ?? "", serializeCalmPreference(active));
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      $.ui.toast(`Calm unchanged: could not save ${preferencePath ?? "the preference"} (${reason})`);
      return {};
    }
    calm = active;
    if (!calm) sites.clear();
    $.ui.invalidate("ui.render");
    $.ui.toast(active ? "Calm on" : "Calm off");
    // No `text`: the toggle leaves no output row in the transcript, as on Pi.
    return {};
  });

  // Record mid-turn narration as it streams: the text blocks of a model step that
  // stopped to call tools. Subagent steps never draw in the main transcript.
  on("turn.step", async function* ($, e, next) {
    const stream = next(e);
    const blocks = new Map<number, string>();
    for await (const chunk of stream) {
      if (chunk.kind === "text") blocks.set(chunk.index, (blocks.get(chunk.index) ?? "") + chunk.text);
      yield chunk;
    }
    const result = await stream.result;
    if (e.agentId === undefined) {
      let changed = false;
      if (stepTextIsWorkingNote(result)) {
        for (const text of [...blocks.values(), result.answer]) {
          const key = workingNoteKey(text);
          if (key === "" || workingNotes.has(key)) continue;
          workingNotes.add(key);
          changed = true;
        }
      } else {
        for (const text of [...blocks.values(), result.answer]) {
          const key = workingNoteKey(text);
          if (key !== "" && workingNotes.delete(key)) changed = true;
        }
      }
      if (changed && calm) $.ui.invalidate("ui.render");
    }
    return result;
  });

  on("ui.render", { component: "Spinner" }, async ($, e, next) => {
    await ensureLoaded($);
    if (!calm || e.surface !== "terminal") {
      sites.delete(e.requestId);
      return next(e);
    }
    const columns = calmShipRasterColumns(e.viewport?.columns);
    const packed = packCalmShipRasterCells(sprite.frame(columns), columns);
    sites.set(e.requestId, { columns, rows: packed.rows });
    const { Box, Raster } = $.ui.resolve(e);
    return Box({
      flexDirection: "column",
      children: Raster({ key: CALM_SHIP_RASTER_KEY, columns, rows: packed.rows, cells: packed.cells }),
    });
  });

  on("ui.render", { component: "ToolUse" }, async ($, e, next) => {
    await ensureLoaded($);
    return calm ? hiddenRow($, e) : next(e);
  });
  on("ui.render", { component: "ToolResult" }, async ($, e, next) => {
    await ensureLoaded($);
    return calm ? hiddenRow($, e) : next(e);
  });
  on("ui.render", { component: "ToolGroup" }, async ($, e, next) => {
    await ensureLoaded($);
    return calm ? hiddenRow($, e) : next(e);
  });

  on("ui.render", { component: "UserMessage" }, async ($, e, next) => {
    await ensureLoaded($);
    return calm && userTextIsOperational(e.props.text) ? hiddenRow($, e) : next(e);
  });

  on("ui.render", { component: "AssistantMessage" }, async ($, e, next) => {
    await ensureLoaded($);
    return calm && workingNotes.has(workingNoteKey(e.props.text)) ? hiddenRow($, e) : next(e);
  });
};
