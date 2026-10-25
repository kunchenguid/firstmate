import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const homes = [...new Set([process.env.HOME, homedir()].filter(Boolean).map((h) => h.replace(/\/+$/, "")))];
const sensitive = [
  /(?:^|\/)\.codex(?:\/(?:\*{1,2})?\/?)?$/,
  /(?:^|\/)\.codex\/auth[^/]*$/,
  /(?:^|\/)\.local\/share\/opencode(?:\/(?:\*{1,2})?\/?)?$/,
  /(?:^|\/)\.local\/share\/opencode\/auth[^/]*$/,
  /(?:^|\/)\.pi\/agent(?:\/(?:\*{1,2})?\/?)?$/,
  /(?:^|\/)\.pi\/agent\/auth[^/]*$/,
  /(?:^|\/)\.claude\/(?:\.credentials[^/]*)$/,
  /(?:^|\/)\.claude$/,
  /(?:^|\/)\.muxr\/plans\/[^/]+\/[^/]+\/(?:\.credentials|auth)[^/]*$/,
  /(?:^|\/)\.no-mistakes(?:\/(?:\*{1,2})?\/?)?$/,
  /(?:^|\/)\.no-mistakes\/config\.ya?ml$/,
  /(?:^|\/)\.local\/state\/crewhouse\/people\/[^/]+(?:\/.*)?$/,
  /(?:^|\/)\.local\/share\/byokit\/people\/[^/]+(?:\/.*)?$/,
  /(?:^|\/)\.cache\/o6-tmp\/[^/]*\/people\/[^/]+(?:\/.*)?$/,
];
const protectedFiles = ["~/.codex/auth.json", "~/.local/share/opencode/auth.json", "~/.pi/agent/auth.json", "~/.claude/.credentials.json", "~/.no-mistakes/config.yaml", "~/.no-mistakes/config.yml"];
const metadata = new Set(["ls", "stat", "test", "["]);
const textOnly = new Set(["echo", "printf", "fm-send.sh"]);
const pathFields = new Set(["path", "file_path", "filePath", "paths", "glob"]);

function tokens(command) {
  return (command.match(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s;|&<>]+/g) ?? [])
    .map((s) => s.replace(/^(?:"([\s\S]*)"|'([\s\S]*)')$/, (_, d, q) => d ?? q));
}

function globMatches(pattern, path) {
  // Only a path glob ("~/" or "/" rooted, with a literal segment; "~" counts) is a reference: "**bold**", "why?", "a*b" and a doc-comment "/**" are text.
  if (!/^(~\/|\/)/.test(pattern) || !/[*?]/.test(pattern)) return false;
  if (!pattern.split("/").some((segment) => segment && !/[*?]/.test(segment))) return false;
  const re = pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replaceAll("**", "\0").replaceAll("*", "[^/]*").replaceAll("?", "[^/]").replaceAll("\0", ".*");
  return new RegExp(`^${re}$`).test(path);
}

function protectedReference(text) {
  // Embedded code/string literals can leave a pathname in the middle of a token (open(path).read(), HOME+"/path").
  const fragments = text.match(/[~$\/\w.{}*?\[\]-]+/g) ?? [];
  for (let value of fragments) {
    value = value.replaceAll("${HOME}", "~").replaceAll("$HOME", "~");
    for (const home of homes) if (value === home || value.startsWith(home + "/")) value = "~" + value.slice(home.length);
    if (sensitive.some((rule) => rule.test(value)) || protectedFiles.some((path) => globMatches(value, path) || homes.some((home) => globMatches(value, path.replace("~", home))))) return value;
  }
  return null;
}

function protectedToken(token) { return protectedReference(token) !== null; }

function references(command) {
  const found = [];
  for (const segment of command.split(/(?:&&?|\|\|?|;|\n)/)) {
    const words = tokens(segment);
    if (!words.length) continue;
    const cmd = words[0].split("/").at(-1);
    const target = protectedReference(segment);
    if (target === null) continue;
    const refs = words.slice(1).filter(protectedToken);
    if (metadata.has(cmd) && refs.length && !/[`]|\$\(|<\(|>\(/.test(segment)) continue;
    // Text-only commands print or send their arguments; a pipe, redirect or substitution anywhere in the command can still read a file.
    if (textOnly.has(cmd) && !protectedToken(words[0]) && !/[`<>|]|\$\(/.test(command)) continue;
    found.push(target);
  }
  return found[0] ?? null;
}

export function guard(input) {
  const command = typeof input === "string" ? input : "";
  const target = references(command);
  if (target === null) return null;
  return `BLOCKED by the fleet read guard: protected login/config file reference "${target}". This block is final: do not retry, reword, or work around it.`;
}

export function guardTool(tool, input) {
  if (tool === "bash" || tool === "Bash") {
    const reason = guard(input?.command);
    if (reason) return reason;
    // Recurse through a shell -c command as well.
    const args = tokens(input?.command ?? "");
    const at = args.findIndex((x) => /(^|\/)(ba|z|da)?sh$/.test(x));
    return at >= 0 ? guard(args[at + 2]) : null;
  }
  const scan = (value) => typeof value === "string" ? (protectedToken(value) ? value : null)
    : Array.isArray(value) ? value.map(scan).find(Boolean)
    : value && typeof value === "object" ? Object.values(value).map(scan).find(Boolean) : null;
  // Only path-like fields name a file; body text such as write content or edit strings is never a path.
  const named = Object.entries(input ?? {}).filter(([key]) => pathFields.has(key) || (key === "pattern" && /^(glob|find)$/i.test(tool)));
  return named.some(([, value]) => scan(value)) ? `BLOCKED by the fleet read guard: protected file access. This block is final: do not retry, reword, or work around it.` : null;
}

// Claude PreToolUse entry: inspect only tool arguments; never intercept process/library file reads.
if (process.argv[1] === new URL(import.meta.url).pathname) {
  let payload = {};
  try { payload = JSON.parse(readFileSync(0, "utf8")); } catch {}
  const tool = payload?.tool_name ?? payload?.toolName ?? "Bash";
  const reason = guardTool(tool, payload?.tool_input ?? {});
  if (reason) { process.stderr.write(reason + "\n"); process.exit(2); }
}
