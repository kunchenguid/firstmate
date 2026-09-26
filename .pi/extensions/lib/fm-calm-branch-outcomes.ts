// Calm's collapsed presentation for the supervision branch's outcome-store
// reader (the fm_branch_outcomes tool of .pi/extensions/fm-branch-supervision.ts).
//
// Calm already hides the "assistant-tool-call" and "tool-result" classes, so
// this module adds no second hiding path: ./fm-calm-visibility.ts stays the one
// owner of whether Calm hides a class. What lives here is the single exception
// Calm makes inside that collapse - the part of a branch-outcome read that must
// survive it, so a failed read or unrecognized output is never hidden.
// Captain-verdict outcomes are not an exception here: the supervision branch
// already delivers each one as its own visible transcript entry.
//
// Deliberately free of every Pi and pi-tui import: the collapse decision is a
// pure function of the tool's own output text, which is what lets the portable
// regression pin it with real store rows and no harness at all.
// bin/fm-branch-outcome.sh's header owns the record format read below.

// The tool's own empty-store text (fm-branch-supervision.ts owns the string).
const NO_OUTCOMES_TEXT = "(no branch outcomes recorded)";

// One line Calm keeps on screen in place of the collapsed row. `glyph` tells the
// caller to print the supervision branch's own glyph. The glyph itself stays
// with the branch extension that owns it, so this module never has to name it.
export type CalmBranchOutcomeLine = {
  glyph: boolean;
  text: string;
};

// The exact key sets the store's own validator accepts, oldest first.
const OUTCOME_KEY_SETS = [
  ["epoch", "seq", "summary", "task", "verdict", "wake"],
  ["epoch", "seq", "silent", "summary", "task", "verdict", "wake"],
  ["epoch", "seq", "silent", "statusEndpoint", "statusIdent", "summary", "task", "verdict", "wake"],
].map((keys) => keys.join(","));

function singleLineText(value: string): string {
  return value.replace(/[\r\n\t]/g, " ").replace(/ +/g, " ").trim();
}

function isOutcomeRecord(line: string): boolean {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return false;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return false;
  const record = parsed as Record<string, unknown>;
  const hasSilent = Object.prototype.hasOwnProperty.call(record, "silent");
  const hasStatus = Object.prototype.hasOwnProperty.call(record, "statusEndpoint");
  if (!OUTCOME_KEY_SETS.includes(Object.keys(record).sort().join(","))) return false;
  if (typeof record.seq !== "number" || !Number.isInteger(record.seq) || record.seq < 1) return false;
  if (typeof record.epoch !== "number" || !Number.isInteger(record.epoch) || record.epoch < 0) return false;
  if (typeof record.task !== "string" || typeof record.wake !== "string") return false;
  if (typeof record.summary !== "string") return false;
  if (record.verdict !== "routine" && record.verdict !== "captain") return false;
  if (hasSilent && typeof record.silent !== "boolean") return false;
  if (hasStatus) {
    const endpoint = record.statusEndpoint;
    if (typeof endpoint !== "number" || !Number.isInteger(endpoint) || endpoint < 0) return false;
    if (typeof record.statusIdent !== "string" || /[\t\n]/.test(record.statusIdent)) return false;
  }
  return true;
}

// What must stay visible when Calm collapses one fm_branch_outcomes row.
// An empty result means the row collapses to nothing, exactly like every other
// tool row Calm hides. A non-empty result is what Calm shows instead.
//
// Two things are never collapsed away:
//   1. A failed read, because a captain who cannot see the fleet must be told.
//   2. Output Calm does not recognize as the store's records, carried through
//      byte-for-byte rather than silently swallowed by a format change.
export function calmBranchOutcomeAttention(
  output: string,
  isError: boolean,
): CalmBranchOutcomeLine[] {
  const trimmedOutput = output.trim();
  if (isError) {
    return [{
      glyph: true,
      text: singleLineText(trimmedOutput || "could not read the outcome store"),
    }];
  }
  if (!trimmedOutput || trimmedOutput === NO_OUTCOMES_TEXT) return [];

  return trimmedOutput
    .split("\n")
    .filter((rawLine) => !isOutcomeRecord(rawLine.trim()))
    .map((rawLine) => ({ glyph: true, text: rawLine }));
}
