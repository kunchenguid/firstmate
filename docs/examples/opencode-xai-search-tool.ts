// Copy to ~/.config/opencode/tools/xai-search.ts (global) or
// <project>/.opencode/tools/xai-search.ts (project-local).
// Requires firstmate's bin/fm-xsearch.sh on PATH, or set FM_XSEARCH to its path.
// Auth: existing SuperGrok OAuth in OpenCode/Pi auth.json, or XAI_API_KEY.
// See docs/xai-server-search.md.
import { tool } from "@opencode-ai/plugin"

function resolveXsearch(): string {
  return process.env.FM_XSEARCH || "fm-xsearch.sh"
}

export default tool({
  description:
    "Search X (Twitter) and/or the web via xAI server-side tools (Responses API). Uses SuperGrok OAuth or XAI_API_KEY. Not the X Developer API.",
  args: {
    prompt: tool.schema.string().describe("Search question or instruction for Grok"),
    tool: tool.schema
      .enum(["x_search", "web_search", "both"])
      .optional()
      .describe("Which server tools to attach (default both)"),
    maxToolCalls: tool.schema
      .number()
      .optional()
      .describe("Cap server tool rounds (default 3)"),
    allowedHandle: tool.schema
      .string()
      .optional()
      .describe("Optional single X handle allowlist for x_search"),
  },
  async execute(args) {
    const bin = resolveXsearch()
    const argv = [bin, "--tool", args.tool || "both"]
    if (args.maxToolCalls != null) {
      argv.push("--max-tool-calls", String(args.maxToolCalls))
    }
    if (args.allowedHandle) {
      argv.push("--allowed-handle", args.allowedHandle)
    }
    argv.push("--prompt-file", "-")
    const proc = Bun.spawn(argv, {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    })
    proc.stdin.write(args.prompt)
    proc.stdin.end()
    const stdout = await new Response(proc.stdout).text()
    const stderr = await new Response(proc.stderr).text()
    const code = await proc.exited
    if (code !== 0) {
      return `fm-xsearch failed (exit ${code}): ${stderr.trim() || stdout.trim() || "no output"}`
    }
    const usage = stderr
      .split("\n")
      .filter((line) => line.startsWith("fm-xsearch: usage "))
      .join("\n")
    return usage ? `${stdout.trim()}\n\n${usage}` : stdout.trim()
  },
})
