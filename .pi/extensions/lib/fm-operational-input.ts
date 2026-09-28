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
  "branch-outcome",
] as const;

export type FirstmateCurrentOperationalKind =
  (typeof FIRSTMATE_CURRENT_OPERATIONAL_KINDS)[number];

type OperationalInputCommand = "encode" | "classify" | "kind";

export function firstmateShellInvocation(
  script: string,
  args: readonly string[],
): { command: string; args: string[] } {
  return process.platform === "win32"
    ? { command: "bash", args: [script, ...args] }
    : { command: script, args: [...args] };
}

// The one owner of how each command is invoked and how its exit status and
// stdout become an answer, shared by the synchronous and awaited callers
// below so the two can never drift.
function operationalInputArgs(
  command: OperationalInputCommand,
  kind?: FirstmateCurrentOperationalKind,
): string[] {
  return command === "encode" ? [command, kind ?? ""] : [command];
}

function operationalInputAnswer(
  command: OperationalInputCommand,
  status: number | null,
  stdout: string,
): string | undefined {
  if (status !== 0) return undefined;
  return command === "classify" ? stdout.replace(/\n$/, "") : stdout;
}

function runOperationalInputCommand(
  command: OperationalInputCommand,
  content: string,
  kind?: FirstmateCurrentOperationalKind,
): string | undefined {
  const invocation = firstmateShellInvocation(
    operationalInputScript,
    operationalInputArgs(command, kind),
  );
  try {
    const result = spawnSync(invocation.command, invocation.args, {
      encoding: "utf8",
      input: content,
      maxBuffer: 1024 * 1024,
    });
    return operationalInputAnswer(command, result.status, result.stdout ?? "");
  } catch {
    return undefined;
  }
}

function encodeFailure(kind: FirstmateCurrentOperationalKind): Error {
  return new Error(`could not encode Firstmate operational input kind ${kind}`);
}

export function encodeFirstmateOperationalInput(
  kind: FirstmateCurrentOperationalKind,
  content: string,
): string {
  const encoded = runOperationalInputCommand("encode", content, kind);
  if (encoded === undefined) throw encodeFailure(kind);
  return encoded;
}

// The supervision branch encodes on Pi's render thread while a captain
// outcome is being delivered, so that one caller must await the child rather
// than stop the TUI for it. It supplies the wait; everything that makes this
// an encode - the script, its argument shape, and how its exit status and
// stdout become an answer - stays owned here, so the two forms cannot drift.
// The runner is a parameter rather than an import so that every extension
// already carrying this module does not also have to carry a spawn helper it
// never calls.
export type OperationalInputRunner = (
  command: string,
  args: readonly string[],
  options: { input: string },
) => Promise<{ status: number | null; stdout: string }>;

export async function encodeFirstmateOperationalInputWith(
  run: OperationalInputRunner,
  kind: FirstmateCurrentOperationalKind,
  content: string,
): Promise<string> {
  const invocation = firstmateShellInvocation(
    operationalInputScript,
    operationalInputArgs("encode", kind),
  );
  const result = await run(invocation.command, invocation.args, { input: content });
  const encoded = operationalInputAnswer("encode", result.status, result.stdout);
  if (encoded === undefined) throw encodeFailure(kind);
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

// The only legacy operational shape Calm presentation hides on top of the current
// typed kinds. The broader `classify` legacy set stays out: its bare forms are text a
// captain can type, so hiding them would hide real input.
const LEGACY_CALM_OPERATIONAL_PREFIX = "\u2063Supervisor escalate (";

// Single owner of "may Calm presentation hide this exact input?", shared by the
// transcript-row and queued-row adapters so the two can never disagree about a message.
// Text without the U+2063 marker answers here without spawning the classifier.
export function isFirstmateOperationalPresentationText(text: string): boolean {
  if (!text.includes("\u2063")) return false;
  return (
    classifyFirstmateCurrentOperationalText(text) !== undefined ||
    text.startsWith(LEGACY_CALM_OPERATIONAL_PREFIX)
  );
}
