// Firstmate Calm presentation policy for the Claude Code mod, kept free of the engine.
//
// This module owns the decisions ../hooks/register.ts applies through `$`: where the
// shared per-home Calm preference lives and how its value reads, which assistant text is
// a mid-turn working note, and which transcript rows Calm hides. It shares Pi Calm's
// broad presentation boundary: genuine user prompts, genuine agent responses, and
// working activity stay visible; tool rows, tool groups, classified working notes, and
// canonically classified operational user rows hide. docs/calm.md owns the exact
// captain-facing contract and docs/configuration.md
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
 * Single-line narration in session history topped out around 215 characters, while
 * substantive single-line content began around 270; every multi-line message was
 * substantive, so this empirical boundary stays deliberately tunable.
 */
export const CALM_PRESERVE_MIN_CHARS = 240;

/** Whether text is substantive enough to preserve despite ending alongside a tool call. */
function shouldPreserveMidTurnText(text: string): boolean {
  const trimmedText = text.trim();
  return text.includes("\n") || trimmedText.length >= CALM_PRESERVE_MIN_CHARS;
}

/**
 * Whether text from a model step is a mid-turn working note: the model did not end
 * its response there, because it stopped to call tools, or ran out of tokens while
 * calling them. Short single-line narration stays a note; substantive text is a final
 * reply even when the step also called tools.
 */
export function stepTextIsWorkingNote(step: CalmStepOutcome, text: string): boolean {
  const midTurn = step.stopReason === "tool_use" || (step.stopReason === "max_tokens" && step.toolUses.length > 0);
  return midTurn && !shouldPreserveMidTurnText(text);
}

/** A trimmed text key that retains whether the raw row contained a newline. */
export function workingNoteKey(text: string): string {
  const trimmedText = text.trim();
  if (trimmedText === "") return "";
  return text.includes("\n") ? `${trimmedText}\n` : trimmedText;
}

/** The shape of one `$.session.messages()` row this policy reads. */
export type CalmSessionRow = {
  readonly role: "user" | "assistant";
  readonly text: string;
  readonly toolUses: readonly unknown[];
};

/**
 * The structurally identified working notes and final replies in a restored transcript.
 * The stored transcript keeps each content block as its own row, so assistant text is a
 * working note when its own row called tools, or when a tool-calling assistant row
 * follows it before the next user row. Substantive text in either position is preserved
 * as a final reply, matching the live classifier.
 */
export function classifyRestoredTranscript(rows: readonly CalmSessionRow[]): {
  workingNotes: string[];
  finalReplies: string[];
} {
  const notes = new Set<string>();
  const finalReplies = new Set<string>();
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (row.role !== "assistant") continue;
    const key = workingNoteKey(row.text);
    if (key === "") continue;
    let followedByToolCall = row.toolUses.length > 0;
    for (let later = index + 1; later < rows.length && rows[later]!.role === "assistant"; later += 1) {
      if (rows[later]!.toolUses.length > 0) {
        followedByToolCall = true;
        break;
      }
    }
    if (followedByToolCall && shouldPreserveMidTurnText(row.text)) finalReplies.add(key);
    else if (followedByToolCall) notes.add(key);
    else finalReplies.add(key);
  }
  for (const key of finalReplies) notes.delete(key);
  return { workingNotes: [...notes], finalReplies: [...finalReplies] };
}

/** Whether a user row's text is a canonically classified Firstmate operational input. */
export function userTextIsOperational(text: string): boolean {
  return classifyFirstmateOperationalText(text) !== undefined;
}
