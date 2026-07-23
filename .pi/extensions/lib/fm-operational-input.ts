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
  command: "encode" | "classify",
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
