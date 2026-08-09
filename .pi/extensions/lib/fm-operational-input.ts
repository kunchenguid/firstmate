import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const operationalInputOverride = process.env.FM_OPERATIONAL_INPUT_SCRIPT;
const operationalInputScript =
  operationalInputOverride ||
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
  const scriptArgs = command === "encode" ? [command, kind ?? ""] : [command];
  const executable = operationalInputOverride ? operationalInputScript : "/bin/bash";
  const args = operationalInputOverride ? scriptArgs : [operationalInputScript, ...scriptArgs];
  const result = spawnSync(executable, args, {
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
