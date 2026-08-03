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

// bin/fm-operational-input.sh answers a data command with exit 0, reports an authoritative
// non-match with exit 1, and reserves exit 2 for invalid use. Anything else - including a
// spawn that never ran the script, which leaves status null - is no answer at all, so the
// two are kept apart rather than collapsed into one "not operational".
type OperationalInputAnswer =
  | { outcome: "matched"; value: string }
  | { outcome: "no-match" }
  | { outcome: "unavailable" };

function askOperationalInputCommand(
  command: "encode" | "kind",
  content: string,
  kind?: FirstmateCurrentOperationalKind,
): OperationalInputAnswer {
  const args = command === "encode" ? [command, kind ?? ""] : [command];
  const result = spawnSync(operationalInputScript, args, {
    encoding: "utf8",
    input: content,
    maxBuffer: 1024 * 1024,
  });
  if (result.status === 0) return { outcome: "matched", value: result.stdout };
  return result.status === 1 ? { outcome: "no-match" } : { outcome: "unavailable" };
}

export function encodeFirstmateOperationalInput(
  kind: FirstmateCurrentOperationalKind,
  content: string,
): string {
  const encoded = askOperationalInputCommand("encode", content, kind);
  if (encoded.outcome !== "matched") {
    throw new Error(`could not encode Firstmate operational input kind ${kind}`);
  }
  return encoded.value;
}

// The only legacy operational shape Firstmate presentation authenticates on top of the
// current typed kinds, matching FM_LEGACY_AWAY_PREFIX in bin/fm-operational-input.sh.
// The broader `classify` legacy set stays out: its bare FIRSTMATE_OP and bare prose
// forms are shapes a captain can author, so hiding them would suppress real input.
const LEGACY_OPERATIONAL_PRESENTATION_PREFIX = "\u2063Supervisor escalate (";
// Presentation re-asks the same question for every queued row on every queue change, so
// answers are memoized. Classification is a pure function of the text, and the bound keeps
// a long session from retaining every distinct message. Only an answer the owner actually
// gave is memoized: a classifier that could not run at all leaves the question open, so a
// transient failure cannot pin one message to "visible" for the rest of the session.
const PRESENTATION_MEMO_LIMIT = 512;
const presentationMemo = new Map<string, boolean>();

function rememberPresentationAnswer(content: string, operational: boolean): boolean {
  if (presentationMemo.size >= PRESENTATION_MEMO_LIMIT) presentationMemo.clear();
  presentationMemo.set(content, operational);
  return operational;
}

// Single owner of the marker-authenticated question "may Calm presentation hide this exact
// input?", shared by every Calm operational adapter so the marker grammar is stated once.
export function isFirstmateOperationalPresentationText(content: string): boolean {
  // Ordinary captain text and replayed transcript rows never carry the marker, so they
  // answer here without paying for a classifier subprocess.
  if (!content.includes("\u2063")) return false;
  const memoized = presentationMemo.get(content);
  if (memoized !== undefined) return memoized;
  if (content.startsWith(LEGACY_OPERATIONAL_PRESENTATION_PREFIX)) {
    return rememberPresentationAnswer(content, true);
  }
  const classified = askOperationalInputCommand("kind", content);
  // No answer means presentation keeps the row visible for now and asks again next time,
  // because hiding real captain input is the one outcome that must never be guessed.
  if (classified.outcome === "unavailable") return false;
  return rememberPresentationAnswer(content, classified.outcome === "matched");
}
