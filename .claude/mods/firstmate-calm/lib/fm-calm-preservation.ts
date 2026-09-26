// Shared Calm policy for deciding whether mid-turn assistant text is substantive.
// Claude Code imports this file directly, while the Pi extension reaches the same
// implementation through its tracked symlink so both harnesses keep one threshold and rule.

/** The minimum trimmed text length preserved from a mid-turn assistant message. */
export const CALM_PRESERVE_MIN_CHARS = 240;

// Working narration is the model narrating its own next step or reporting a routine
// monitoring state: the lines the mid-turn hide exists to drop. A tool call in the
// same assistant message is not proof that its text was disposable - the run can put a
// completed-work confirmation, its caveats, or the captain-facing report there and then
// keep working, or end on that message - so a short single-line block is hidden only
// when every sentence in it reads as working narration. The check deliberately errs
// toward showing: unrecognized text is preserved, because hiding a reply is worse than
// briefly showing a line of narration. docs/calm.md owns the user-facing contract.
const WORKING_NARRATION_ADDRESS =
  /^(?:(?:ok(?:ay)?|alright|right|good|great|nice|perfect|aye|understood|noted|got it|sure|captain|so|and|but|well)[\s,.:;!—–-]+)+/i;
const WORKING_NARRATION_GERUNDS =
  "checking|looking|reading|running|searching|grepping|inspecting|examining|reviewing|analy[sz](?:ing|e)|testing|waiting|monitoring|preparing|refreshing|fetching|querying|scanning|verifying|confirming|comparing|updating|writing|editing|building|installing|draining|cleaning|restoring|sweeping|polling|pulling|merging|spawning|dispatching|filing|recording|drafting|filling|loading|opening|repairing|tracking|gathering|applying";
const WORKING_NARRATION_SENTENCE = [
  // Announcing the model's own next step, optionally behind an acknowledgment address.
  new RegExp(
    `^(?:let me(?! know\\b)|let's|let us|i'?ll|i will|i'?m going to|i am going to|i'?m about to|now let me|now i'?ll|now i will|now (?:${WORKING_NARRATION_GERUNDS})\\b|next,? (?:let me|i'?ll|i will)|then,? (?:let me|i'?ll|i will)|first,? (?:let me|i'?ll|i will)|finally,? (?:let me|i'?ll|i will)|time to|going to)\\b`,
    "i",
  ),
  // Ongoing progress.
  new RegExp(`^(?:${WORKING_NARRATION_GERUNDS})\\b`, "i"),
  // Routine monitoring state.
  /^(?:no (?:changes?|updates?|new information|action needed)|nothing (?:new|to report|further)|all (?:quiet|clear|good|green)|still (?:waiting|running|monitoring|pending|in progress)|continuing to (?:monitor|wait|watch)|waiting (?:on|for)|standing by|on track)\b/i,
];
const WORKING_NARRATION_TRAILING_VOCATIVE = /[\s,;—–-]*\bcaptain\b\s*[.!?…]*$/i;
const WORKING_NARRATION_OUTCOME_VERB = "confirms?|confirmed|shows?|showed|shown|finds?|found|reveals?|revealed|indicates?|indicated|proves?|proved|succeeds?|succeeded|works?|worked|fails?|failed";
const WORKING_NARRATION_OUTCOME_REPORT = new RegExp(`^\\w+ing\\b(?:\\s+(?:the|a|an|both|these|those|this|that|my|our|his|her|their|its|[A-Za-z0-9_-]+))*\\s+(?:${WORKING_NARRATION_OUTCOME_VERB})\\b`, "i");
const WORKING_NARRATION_ACK =
  /^(?:ok(?:ay)?|alright|right|good|great|nice|perfect|aye|understood|noted|got it|sure|on it|will do|sounds good|captain)[.!…]?$/i;
// A second-person or captain-directed sentence is addressed to the reader rather than
// describing the model's own work, so it is never disposable narration even when it
// looks like one - an offer ("Let me know if you'd like that") and a wait on the
// captain ("Still waiting on your reply") are both replies the captain must be able
// to read.
const WORKING_NARRATION_CAPTAIN_DIRECTED = /\b(?:you|your|yours|you're|captain)\b/i;

function workingNarrationFragments(text: string): string[] {
  return text
    .split(/\n+/)
    .flatMap((line) => line.split(/(?<=[.!?…])\s+/))
    .map((fragment) => fragment.replace(/^[\s>]+/, "").trim())
    .filter((fragment) => fragment.length > 0);
}

function fragmentIsWorkingNarration(fragment: string): boolean {
  if (WORKING_NARRATION_ACK.test(fragment.replace(/[,;—–-]+$/, "").trim())) return true;
  const withoutAddress = fragment.replace(WORKING_NARRATION_ADDRESS, "").trim();
  if (withoutAddress.length === 0) return true;
  const withoutVocative = withoutAddress.replace(WORKING_NARRATION_TRAILING_VOCATIVE, "").trim();
  const directedTarget = withoutVocative.length > 0 ? withoutVocative : withoutAddress;
  if (WORKING_NARRATION_CAPTAIN_DIRECTED.test(directedTarget)) return false;
  for (const pattern of WORKING_NARRATION_SENTENCE) {
    if (!pattern.test(withoutAddress)) continue;
    if (pattern === WORKING_NARRATION_SENTENCE[1]) {
      const core = directedTarget;
      if (/:\s*\S/.test(core)) return false;
      if (WORKING_NARRATION_OUTCOME_REPORT.test(core)) return false;
    }
    return true;
  }
  return false;
}

function midTurnTextIsWorkingNarration(text: string): boolean {
  const fragments = workingNarrationFragments(text);
  return fragments.length > 0 && fragments.every(fragmentIsWorkingNarration);
}

/** Whether mid-turn assistant text is substantive enough to remain visible. */
export function calmTextIsSubstantive(text: string): boolean {
  if (text.includes("\n") || text.trim().length >= CALM_PRESERVE_MIN_CHARS) return true;
  return !midTurnTextIsWorkingNarration(text);
}
