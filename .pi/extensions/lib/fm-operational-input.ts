import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const operationalInputScript =
  process.env.FM_OPERATIONAL_INPUT_SCRIPT ||
  resolve(dirname(fileURLToPath(import.meta.url)), "../../../bin/fm-operational-input.sh");

export const FIRSTMATE_CURRENT_OPERATIONAL_KINDS = [
  "session-start",
  "watcher",
  "turn-end-guard",
  "away-supervisor",
  "from-firstmate",
  "launch-brief",
] as const;

export type FirstmateCurrentOperationalKind =
  (typeof FIRSTMATE_CURRENT_OPERATIONAL_KINDS)[number];

function runOperationalInputCommand(
  command: "encode" | "classify" | "kind",
  content: string,
  kind?: FirstmateCurrentOperationalKind,
): string | undefined {
  const args = command === "encode" ? [command, kind ?? ""] : [command];
  const result = spawnSync(operationalInputScript, args, {
    encoding: "utf8",
    input: content,
    maxBuffer: 1024 * 1024,
  });
  if (result.status !== 0) return undefined;
  return command === "classify" ? result.stdout.replace(/\n$/, "") : result.stdout;
}

export function encodeFirstmateOperationalInput(
  kind: FirstmateCurrentOperationalKind,
  content: string,
): string {
  const encoded = runOperationalInputCommand("encode", content, kind);
  if (encoded === undefined) {
    throw new Error(`could not encode Firstmate operational input kind ${kind}`);
  }
  return encoded;
}

export function classifyFirstmateOperationalText(content: string): string | undefined {
  return runOperationalInputCommand("classify", content);
}

export function classifyFirstmateCurrentOperationalText(
  content: string,
): string | undefined {
  return runOperationalInputCommand("kind", content);
}

// The only legacy operational shape Firstmate presentation authenticates on top of the
// current typed kinds, matching FM_LEGACY_AWAY_PREFIX in bin/fm-operational-input.sh.
// The broader `classify` legacy set stays out: its bare FIRSTMATE_OP and bare prose
// forms are shapes a captain can author, so hiding them would suppress real input.
const LEGACY_OPERATIONAL_PRESENTATION_PREFIX = "\u2063Supervisor escalate (";
// Presentation re-asks the same question for every queued row on every queue change, so
// answers are memoized. Classification is a pure function of the text, and the bound keeps
// a long session from retaining every distinct message.
const PRESENTATION_MEMO_LIMIT = 512;
const presentationMemo = new Map<string, boolean>();

// Single owner of the marker-authenticated question "may Calm presentation hide this exact
// input?", shared by every Calm operational adapter so the marker grammar is stated once.
export function isFirstmateOperationalPresentationText(content: string): boolean {
  // Ordinary captain text and replayed transcript rows never carry the marker, so they
  // answer here without paying for a classifier subprocess.
  if (!content.includes("\u2063")) return false;
  const memoized = presentationMemo.get(content);
  if (memoized !== undefined) return memoized;
  const operational =
    classifyFirstmateCurrentOperationalText(content) !== undefined ||
    content.startsWith(LEGACY_OPERATIONAL_PRESENTATION_PREFIX);
  if (presentationMemo.size >= PRESENTATION_MEMO_LIMIT) presentationMemo.clear();
  presentationMemo.set(content, operational);
  return operational;
}
