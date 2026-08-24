// Calm's collapsed presentation for the supervision branch's outcome-store
// reader (the fm_branch_outcomes tool of .pi/extensions/fm-branch-supervision.ts).
//
// Calm already hides the "assistant-tool-call" and "tool-result" classes, so
// this module adds no second hiding path: ./fm-calm-visibility.ts stays the one
// owner of whether Calm hides a class. What lives here is the single exception
// Calm makes inside that collapse - the part of a branch-outcome read that must
// survive it, so a failure or a captain-relevant outcome is never hidden.
//
// Deliberately free of every Pi and pi-tui import: the collapse decision is a
// pure function of the tool's own output text, which is what lets the portable
// regression pin it with real store rows and no harness at all.
// bin/fm-branch-outcome.sh's header owns the record format read below.

// The tool's own empty-store text (fm-branch-supervision.ts owns the string).
const NO_OUTCOMES_TEXT = "(no branch outcomes recorded)";

// One line Calm keeps on screen in place of the collapsed row. `glyph` marks the
// lines Calm authored from a recognized record, which the caller prints with the
// supervision branch's own glyph; a line Calm did not recognize is carried
// through unchanged and unmarked. The glyph itself stays with the branch
// extension that owns it, so this module never has to name it.
export type CalmBranchOutcomeLine = {
  glyph: boolean;
  text: string;
};

type BranchOutcomeRecord = {
  task: string;
  verdict: "routine" | "captain";
  summary: string;
};

function parseOutcomeRecord(line: string): BranchOutcomeRecord | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return undefined;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return undefined;
  const record = parsed as Record<string, unknown>;
  if (typeof record.task !== "string" || typeof record.summary !== "string") return undefined;
  if (record.verdict !== "routine" && record.verdict !== "captain") return undefined;
  return { task: record.task, verdict: record.verdict, summary: record.summary };
}

// What must stay visible when Calm collapses one fm_branch_outcomes row.
// An empty result means the row collapses to nothing, exactly like every other
// tool row Calm hides. A non-empty result is what Calm shows instead.
//
// Three things are never collapsed away, in this order:
//   1. A failed read, because a captain who cannot see the fleet must be told.
//   2. Output Calm does not recognize as the store's records, carried through
//      byte-for-byte rather than silently swallowed by a format change.
//   3. A captain-verdict outcome, which is the store's own marker for an event
//      that needs the captain; a routine outcome is one the branch handled.
export function calmBranchOutcomeAttention(
  output: string,
  isError: boolean,
): CalmBranchOutcomeLine[] {
  const text = output.trim();
  if (isError) {
    return [{ glyph: true, text: text || "could not read the outcome store" }];
  }
  if (!text || text === NO_OUTCOMES_TEXT) return [];

  const lines: CalmBranchOutcomeLine[] = [];
  for (const rawLine of text.split("\n")) {
    if (rawLine.trim() === "") continue;
    const record = parseOutcomeRecord(rawLine.trim());
    if (!record) {
      lines.push({ glyph: false, text: rawLine });
      continue;
    }
    if (record.verdict !== "captain") continue;
    lines.push({ glyph: true, text: `${record.task}: ${record.summary}` });
  }
  return lines;
}
