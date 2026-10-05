// Effort-level policy for the Claude Code mod, kept free of the engine.
//
// Claude Code calls the reasoning budget the effort level, shows it in the footer as
// `think:<level>`, and moves it with `/effort <level>`, the effort slider, or the model
// picker. This module owns every decision ../hooks/register.ts applies through `$`: which
// levels the cue can show, which subset one keystroke cycles through, which of Claude
// Code's own theme colors names each level, when a request proves what level is in force,
// and which saved level a first keystroke steps up from.
// docs/calm.md owns the captain-facing contract and
// docs/calm-mode-feasibility.md the version-scoped evidence. Everything here is pure so
// tests run it under Node.

/** Every effort level Claude Code 2.1.274 accepts, in the order its own slider draws them. */
export const EFFORT_LEVELS = ["low", "medium", "high", "xhigh", "max", "ultracode"] as const;

export type EffortLevel = (typeof EFFORT_LEVELS)[number];

/**
 * The levels one keystroke cycles through, low to max and back to low.
 *
 * `ultracode` is left out because it is not only more thinking: Claude Code's own slider
 * describes it as `xhigh + workflows`, so a blind cycle would turn multi-agent
 * orchestration on and off as a side effect. `auto` is left out because it is a choice to
 * let Claude Code pick per turn rather than a point on the ramp. Both stay reachable
 * through `/effort`, and neither is ever drawn as itself: under `auto` the cue names the
 * level each request resolves to, and no request can report `ultracode` at all, so the cue
 * names no level while that one is in force.
 */
export const EFFORT_CYCLE = ["low", "medium", "high", "xhigh", "max"] as const;

/**
 * Claude Code's own theme color key per level, resolved by the engine against the live
 * theme rather than painted as a fixed ANSI or RGB value, so the cue follows every built-in
 * theme, its daltonized and ANSI variants, and a custom one.
 *
 * The ramp runs quiet to loud in the app's own vocabulary: `inactive` for the level that
 * thinks least, the permission blue and the Claude orange through the middle, the warning
 * amber at `xhigh`, the fast-mode red at `max`, and Claude Code's own `effortUltra` for
 * `ultracode`, whose entry completes the map rather than reaching the cue, since no request
 * can report that level. An unknown level takes the prompt's own border color, which is what
 * the input already draws in, so nothing claims a level the mod has not established.
 */
const EFFORT_LEVEL_COLORS: Readonly<Record<EffortLevel, string>> = {
  low: "inactive",
  medium: "permission",
  high: "claude",
  xhigh: "warning",
  max: "fastMode",
  ultracode: "effortUltra",
};

/** The theme color key for an unestablished level: the prompt's own border color. */
export const EFFORT_UNKNOWN_COLOR = "promptBorder";

/** The glyph per level, filling as the level rises, in the shape Claude Code marks its own list with. */
const EFFORT_LEVEL_GLYPHS: Readonly<Record<EffortLevel, string>> = {
  low: "○",
  medium: "◔",
  high: "◑",
  xhigh: "◕",
  max: "●",
  ultracode: "◉",
};

/** The glyph for an unestablished level. */
export const EFFORT_UNKNOWN_GLYPH = "◌";

/** The word the cue shows before any level is established. */
export const EFFORT_UNKNOWN_LABEL = "effort ?";

/** Whether an arbitrary value is one of the levels Claude Code accepts. */
export function isEffortLevel(value: unknown): value is EffortLevel {
  return typeof value === "string" && (EFFORT_LEVELS as readonly string[]).includes(value);
}

/**
 * A level read from anywhere outside the mod, or undefined when the value names none.
 *
 * Claude Code reports a level as a lower-case word, but `turn.step` may also carry an
 * integer token budget for a model configured that way; a budget is a real effort setting
 * the mod cannot place on the ramp, so it reads as unestablished rather than as a guess.
 */
export function normalizeEffortLevel(value: unknown): EffortLevel | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim().toLowerCase();
  return isEffortLevel(trimmed) ? trimmed : undefined;
}

/**
 * The next level one cycle step selects, wrapping from the top back to the bottom.
 *
 * A step always starts from a level, never from nothing: a caller that does not know where
 * the session is must find that out rather than pass a guess, because a guessed start would
 * step the session somewhere the captain did not ask for. A level outside the cycle, such as
 * `ultracode`, is a known place off the ramp, and the ramp resumes at its first entry.
 *
 * Every level on the ramp stays on it. Claude Code reports a level it will not take only in
 * its own output, which no event carries, so nothing here can know a level is refused, and a
 * level a model does not offer costs one press per lap rather than being passed over on a
 * guess. This decides only what to ask for next and says nothing about what is in force.
 */
export function cycleEffortLevel(current: EffortLevel): EffortLevel {
  const at = (EFFORT_CYCLE as readonly string[]).indexOf(current);
  return EFFORT_CYCLE[(at + 1) % EFFORT_CYCLE.length] ?? EFFORT_CYCLE[0];
}

/**
 * The levels a main-loop request can report, which is what Claude Code 2.1.274 checks the
 * effort of its own `turn.step` against: `low`, `medium`, `high`, `xhigh`, `max`, or an
 * internal token budget.
 *
 * `ultracode` is not among them, so a request sent while the session is at `ultracode`
 * reports one of these or nothing, and no event says which. A report is therefore proof of
 * the level in force only while the last level a command selected is one this list can
 * express.
 */
export const TURN_STEP_LEVELS = ["low", "medium", "high", "xhigh", "max"] as const;

/**
 * The level a main-loop request confirms is in force, given the last level a command
 * selected, or undefined when nothing can be concluded honestly.
 *
 * The request is the one source that says what effort the engine actually asked for, so its
 * level is taken as it stands. It cannot report `ultracode` at all, so once a command has
 * selected a level no request can express, every report is ambiguous and confirms nothing
 * until another command selects a level that can be reported.
 */
export function confirmedEffortLevel(
  selected: EffortLevel | undefined,
  reported: EffortLevel | undefined,
): EffortLevel | undefined {
  if (selected !== undefined && !(TURN_STEP_LEVELS as readonly string[]).includes(selected)) return undefined;
  return reported;
}

/** The settings shape a saved effort level is read out of. */
export type EffortSettings = {
  readonly effortLevel?: unknown;
  readonly modelSettings?: Readonly<Record<string, { readonly effortLevel?: unknown } | undefined>> | undefined;
};

/**
 * The level Claude Code has saved for `model`, or undefined when none is saved.
 *
 * This is where a new session starts rather than proof of what this one is running, so
 * nothing drawn is ever taken from it. It answers one question that is not a claim: which
 * level the first cycle step of a session steps up from, before any request has carried one.
 * Claude Code's own order is read: the entry saved for this model decides whenever the model
 * has one, and the saved default applies only to a model with none of its own. An entry that
 * is there but names nothing on the ramp, such as `auto` or a token budget, leaves the answer
 * unknown rather than falling through to a default this model is not running, because a step
 * from a level the session is not at is a step the captain did not ask for.
 */
export function savedEffortLevel(settings: EffortSettings | undefined, model: string | undefined): EffortLevel | undefined {
  if (settings === null || typeof settings !== "object") return undefined;
  const perModel = model === undefined ? undefined : settings.modelSettings?.[model]?.effortLevel;
  if (perModel !== undefined) return normalizeEffortLevel(perModel);
  return normalizeEffortLevel(settings.effortLevel);
}

/** Claude Code's own `auto`: a choice to let it pick per turn, not a point on the ramp. */
const EFFORT_AUTO = "auto";

/**
 * What a run of `/effort` selects, or undefined when its argument names nothing the cue can
 * act on, as a bare `/effort` that opens the slider does.
 *
 * `auto` selects no point on the ramp, so it reads as a selection whose level is undefined:
 * the cue holds no level for it until a turn reports the one Claude Code resolved.
 */
export function parseEffortSelection(args: unknown): { readonly level: EffortLevel | undefined } | undefined {
  if (typeof args !== "string") return undefined;
  if (args.trim().toLowerCase() === EFFORT_AUTO) return { level: undefined };
  const level = normalizeEffortLevel(args);
  return level === undefined ? undefined : { level };
}

/** The theme color key that names a level, or the unknown color when none is established. */
export function effortLevelColor(level: EffortLevel | undefined): string {
  return level === undefined ? EFFORT_UNKNOWN_COLOR : EFFORT_LEVEL_COLORS[level];
}

/** The glyph that marks a level, or the unknown glyph when none is established. */
export function effortLevelGlyph(level: EffortLevel | undefined): string {
  return level === undefined ? EFFORT_UNKNOWN_GLYPH : EFFORT_LEVEL_GLYPHS[level];
}

/** The cue's label for a level: its glyph and its word, or the unestablished label. */
export function effortCueLabel(level: EffortLevel | undefined): string {
  return level === undefined
    ? `${EFFORT_UNKNOWN_GLYPH} ${EFFORT_UNKNOWN_LABEL}`
    : `${effortLevelGlyph(level)} ${level}`;
}

/**
 * How many cells of rule the cue draws after its label on a row of `bodyColumns`.
 *
 * The band reserves its right edge for the engine's own collapse handle, and a row too
 * narrow for any rule draws none rather than wrapping the cue onto a second line.
 */
export function effortRuleColumns(bodyColumns: unknown, labelColumns: number): number {
  const measured = typeof bodyColumns === "number" && Number.isFinite(bodyColumns) ? Math.floor(bodyColumns) : 0;
  const HANDLE_COLUMNS = 4;
  return Math.max(0, measured - labelColumns - HANDLE_COLUMNS);
}

