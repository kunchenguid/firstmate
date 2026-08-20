// Secondmate compartment child-spawn intent tool (R2/R3 design section B.5).
//
// Staged onto the Azure worker by the compartment monitor (PR 4) and loaded
// into each pi turn with `-e <path>` by bin/fm-secondmate-session.py.  The
// tool does NO blob I/O and reaches no network: it only writes one intent
// FILE into the spool directory the session runner names through
// FM_SECONDMATE_SPOOL_DIR.  The runner sweeps the spool after each turn,
// validates the closed schema, and emits the chained child-request message;
// the local controller is the only authority that can admit the child.
//
// Tool contract (proven by the D.1 probe, pi 0.84.2): registerTool with
// plain JSON-schema parameters and execute(toolCallId, params, signal,
// onUpdate, ctx) returning {content:[{type:"text",...}], details:{}}.
import { createHash } from "node:crypto";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const VALID_KINDS = ["ship", "scout"];
const MAX_BRIEF_BYTES = 256 * 1024;
const MAX_OPTION_CHARS = 128;

function spoolIntent(intent: Record<string, string>): string {
  const spool = process.env.FM_SECONDMATE_SPOOL_DIR || "";
  if (!spool) {
    throw new Error("FM_SECONDMATE_SPOOL_DIR is not set; no spool directory to write to");
  }
  mkdirSync(spool, { recursive: true, mode: 0o700 });
  const body = JSON.stringify(intent);
  const digest = createHash("sha256").update(body).digest("hex");
  const final = join(spool, `${digest}.json`);
  const temporary = join(spool, `.${digest}.tmp`);
  writeFileSync(temporary, body, { mode: 0o600 });
  renameSync(temporary, final);
  return digest;
}

export default function (pi: any) {
  pi.registerTool?.({
    name: "fm_cloud_spawn",
    label: "Request a cloud crewmate",
    description:
      "Ask the local Firstmate controller to spawn one cloud crewmate (kind ship or scout) " +
      "with the given brief. This only records the request; the local controller decides " +
      "admission under its own bounds and reports the outcome back into this session.",
    parameters: {
      type: "object",
      properties: {
        kind: { type: "string", enum: VALID_KINDS },
        brief: { type: "string" },
        model: { type: "string" },
        effort: { type: "string" },
      },
      required: ["kind", "brief"],
      additionalProperties: false,
    },
    execute: async (_toolCallId: any, params: any) => {
      const kind = String(params?.kind ?? "");
      const brief = String(params?.brief ?? "");
      if (!VALID_KINDS.includes(kind)) {
        return {
          content: [{ type: "text", text: "refused: kind must be ship or scout" }],
          details: {},
        };
      }
      if (!brief || Buffer.byteLength(brief, "utf8") > MAX_BRIEF_BYTES) {
        return {
          content: [{ type: "text", text: "refused: brief is empty or exceeds 256KiB" }],
          details: {},
        };
      }
      const intent: Record<string, string> = { kind, brief };
      for (const key of ["model", "effort"]) {
        const value = params?.[key];
        if (value === undefined || value === null || value === "") continue;
        const text = String(value);
        if (text.length > MAX_OPTION_CHARS) {
          return {
            content: [{ type: "text", text: `refused: ${key} exceeds ${MAX_OPTION_CHARS} characters` }],
            details: {},
          };
        }
        intent[key] = text;
      }
      const digest = spoolIntent(intent);
      return {
        content: [
          {
            type: "text",
            text:
              `child request ${digest.slice(0, 12)} spooled (${kind}); the session runner will ` +
              "relay it after this turn and the local controller will report admission or refusal.",
          },
        ],
        details: { digest, kind },
      };
    },
  });
}
