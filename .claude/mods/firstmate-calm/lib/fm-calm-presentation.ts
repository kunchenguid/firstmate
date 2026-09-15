// Firstmate Calm presentation policy for the Claude Code mod, kept free of the engine.
//
// This module owns the decisions ../hooks/register.ts applies through `$`: where the
// shared per-home Calm preference lives and how its value reads, which assistant text is
// a mid-turn working note, and which transcript rows Calm hides. It mirrors the Pi
// policy in .pi/extensions/lib/fm-calm-visibility.ts and .pi/extensions/fm-calm.ts:
// genuine user prompts, genuine agent responses, and working activity stay visible;
// tool rows, tool groups, working notes, and canonically classified operational user
// rows hide. docs/calm.md owns the captain-facing contract and docs/configuration.md
// the persisted preference schema. Everything here is pure so tests run it under Node.
import { classifyFirstmateOperationalText } from "./fm-operational-input.ts";

/** The environment variables that select the effective Firstmate home, as the mod reads them. */
export type CalmHomeEnvironment = {
  readonly FM_HOME?: string | undefined;
  readonly FM_ROOT_OVERRIDE?: string | undefined;
  readonly FM_CONFIG_OVERRIDE?: string | undefined;
};

/** The parent of a path, with either separator; a bare name resolves to itself. */
function parentDirectory(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, "");
  const cut = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
  return cut > 0 ? trimmed.slice(0, cut) : trimmed;
}

/**
 * The tracked Firstmate code root the mod belongs to: three levels above the plugin
 * folder, whether Claude Code names it through `.claude/skills/<name>`,
 * `.agents/skills/<name>`, or its physical `.claude/mods/<name>` home, which all sit
 * at that same depth.
 */
export function calmCodeRootFromPluginRoot(pluginRoot: string): string {
  return parentDirectory(parentDirectory(parentDirectory(pluginRoot)));
}

/**
 * The per-home `config/calm` path, resolved exactly as the Pi extension resolves it:
 * `FM_HOME`, then `FM_ROOT_OVERRIDE`, then the tracked code root, with
 * `FM_CONFIG_OVERRIDE` naming the config directory outright when present.
 */
export function calmPreferencePath(env: CalmHomeEnvironment, pluginRoot: string): string {
  const configDirectory =
    env.FM_CONFIG_OVERRIDE ||
    `${env.FM_HOME || env.FM_ROOT_OVERRIDE || calmCodeRootFromPluginRoot(pluginRoot)}/config`;
  return `${configDirectory}/calm`;
}

/**
 * Whether a stored preference reads as Calm on. `max` is the legacy value of a removed
 * third level whose behavior is now ordinary Calm; absent or unrecognized reads as off.
 */
export function parseCalmPreference(stored: string | undefined): boolean {
  if (stored === undefined) return false;
  const value = stored.trim();
  return value === "on" || value === "max";
}

/** The exact file content the Pi extension writes for the same choice. */
export function serializeCalmPreference(active: boolean): string {
  return active ? "on\n" : "off\n";
}

/** The shape of one `turn.step` result this policy reads. */
export type CalmStepOutcome = {
  readonly stopReason: string | null;
  readonly toolUses: readonly unknown[];
};

/**
 * Whether the text of a model step is a mid-turn working note: the model did not end
 * its response there, because it stopped to call tools, or ran out of tokens while
 * calling them. The same rule as Pi Calm's `assistant-working-note` class.
 */
export function stepTextIsWorkingNote(step: CalmStepOutcome): boolean {
  if (step.stopReason === "tool_use") return true;
  return step.stopReason === "max_tokens" && step.toolUses.length > 0;
}

/** The key a working note is remembered under: its trimmed text; empty text is no note. */
export function workingNoteKey(text: string): string {
  return text.trim();
}

/** The shape of one `$.session.messages()` row this policy reads. */
export type CalmSessionRow = {
  readonly role: "user" | "assistant";
  readonly text: string;
  readonly toolUses: readonly unknown[];
};

/**
 * The working notes a restored transcript holds. The stored transcript keeps each
 * content block as its own row, so assistant text is a working note when its own row
 * called tools, or when a tool-calling assistant row follows it before the next user row.
 */
export function restoredWorkingNotes(rows: readonly CalmSessionRow[]): string[] {
  const notes: string[] = [];
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (row.role !== "assistant") continue;
    const key = workingNoteKey(row.text);
    if (key === "") continue;
    if (row.toolUses.length > 0) {
      notes.push(key);
      continue;
    }
    for (let later = index + 1; later < rows.length && rows[later]!.role === "assistant"; later += 1) {
      if (rows[later]!.toolUses.length > 0) {
        notes.push(key);
        break;
      }
    }
  }
  return notes;
}

/** Whether a user row's text is a canonically classified Firstmate operational input. */
export function userTextIsOperational(text: string): boolean {
  return classifyFirstmateOperationalText(text) !== undefined;
}

/** The transcript components Calm hides outright while on. */
export const CALM_HIDDEN_COMPONENTS = ["ToolUse", "ToolResult", "ToolGroup"] as const;
