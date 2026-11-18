import { spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { readFile, writeFile, rename } from "node:fs/promises";
import { dirname, isAbsolute, join, relative } from "node:path";
import type { CustomTool } from "@oh-my-pi/pi-coding-agent/extensibility/custom-tools/types";
import type { ExtensionUIContext } from "@oh-my-pi/pi-coding-agent/extensibility/extensions/types";
import { ApprovalBroker, type MutationPreview, type SignedReceipt, canonical } from "./contract";

function canonicalExistingPath(value: string): string {
  if (typeof value !== "string" || !isAbsolute(value) || realpathSync(value) !== value) throw Error("filesystem_boundary_refused");
  return value;
}
function overlaps(left: string, right: string): boolean {
  const distance = relative(left, right);
  return distance === "" || (!distance.startsWith("..") && !isAbsolute(distance));
}
export function fileOperation(python: string, helper: string, root: string, mode: string, args: unknown, expected?: MutationPreview): unknown {
  const canonicalHelper = canonicalExistingPath(helper);
  const canonicalRoot = canonicalExistingPath(root);
  if (overlaps(dirname(canonicalHelper), canonicalRoot)) throw Error("filesystem_boundary_refused");
  const result = spawnSync(python, ["-I", canonicalHelper], {input: canonical({root: canonicalRoot, mode, args, ...(expected ? {expected} : {})}),
    encoding: "utf8", timeout: 3000, maxBuffer: 131072, env: {PATH: "/usr/bin:/bin", LANG: "C.UTF-8"}});
  if (result.status !== 0 || result.error) throw Error("filesystem_boundary_refused");
  const response = JSON.parse(result.stdout);
  if (response.ok !== true) throw Error("filesystem_boundary_refused");
  return response.result;
}
type FileArgs = {operation: string; path: string; content?: string; oldText?: string; newText?: string; text?: string};
export function createConfinedTools(broker: ApprovalBroker, python: string, helper: string): CustomTool[] {
  const schema = (name: string) => ({type: "object", properties: {path: {type: "string"},
    ...(name === "write" ? {content: {type: "string"}} : name === "edit" ? {oldText: {type: "string"}, newText: {type: "string"}} : name === "grep" ? {text: {type: "string"}} : {})},
    required: ["path", ...(name === "write" ? ["content"] : name === "edit" ? ["oldText", "newText"] : name === "grep" ? ["text"] : [])], additionalProperties: false});
  return broker.c.tools.map(name => {
    const args = (raw: unknown): FileArgs => ({...(raw as Omit<FileArgs, "operation">), operation: name});
    return {
      name, label: name, description: `Confined ${name} inside the assigned worktree. Paths are relative; grep is literal and bounded.`,
      parameters: schema(name), strict: true, loadMode: "essential",
      approval: (raw: unknown) => {
        if (["read", "grep"].includes(name)) return {tier: "read", policy: "allow"};
        const preview = fileOperation(python, helper, broker.c.worktree, "preview", args(raw)) as MutationPreview;
        const request = broker.request(name, preview, args(raw));
        return {tier: "write", policy: "prompt", reason: `FM_MUTATION ${canonical(request)}`};
      },
      execute: async (_id, raw, _update, _ctx, signal) => {
        if (signal?.aborted || Date.now() / 1000 >= broker.c.deadline) throw Error("tool_cancelled");
        const request = args(raw);
        const preview = ["write", "edit"].includes(name) ? broker.take((fileOperation(python, helper, broker.c.worktree, "preview", request) as MutationPreview).argsDigest) : undefined;
        const output = fileOperation(python, helper, broker.c.worktree, "execute", request, preview);
        return {content: [{type: "text", text: String(output)}], details: {confined: true}};
      },
    } satisfies CustomTool;
  });
}

export function approvalOnlyUI(broker: ApprovalBroker, queue: string, theme: ExtensionUIContext["theme"]): ExtensionUIContext {
  return {
    select: async (title, options, dialog) => {
      if (canonical(options) !== canonical(["Approve", "Deny"])) return undefined;
      const reason = title.indexOf("FM_MUTATION ");
      if (reason < 0) return "Deny";
      const json = title.slice(reason + "FM_MUTATION ".length).split("\n")[0];
      let request;
      try { request = JSON.parse(json); } catch { return "Deny"; }
      if (canonical(broker.pending.get(request.nonce)) !== canonical(request)) return "Deny";
      await writeFile(join(queue, `${request.nonce}.request.json`), canonical(request), {mode: 0o600, flag: "wx"});
      while (Date.now() / 1000 < request.expiresAt && !dialog?.signal?.aborted) {
        try {
          const path = join(queue, `${request.nonce}.receipt.json`);
          const envelope: SignedReceipt = JSON.parse(await readFile(path, "utf8"));
          const accepted = broker.consume(envelope);
          await rename(path, join(queue, `${request.nonce}.consumed.json`));
          return accepted ? "Approve" : "Deny";
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") return "Deny";
        }
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      return "Deny";
    },
    confirm: async () => false, input: async () => undefined, notify: () => {}, onTerminalInput: () => () => {},
    setStatus: () => {}, setWorkingMessage: () => {}, setWidget: () => {}, setFooter: () => {}, setHeader: () => {}, setTitle: () => {},
    custom: async () => { throw Error("arbitrary_ui_refused"); }, setEditorText: () => {}, pasteToEditor: () => {}, getEditorText: () => "",
    editor: async () => undefined, addAutocompleteProvider: () => {}, setEditorComponent: () => {}, theme,
    getAllThemes: async () => [], getTheme: async () => undefined, setTheme: async () => ({success: false, error: "fixed_approval_ui"}),
    getToolsExpanded: () => false, setToolsExpanded: () => {},
  };
}
