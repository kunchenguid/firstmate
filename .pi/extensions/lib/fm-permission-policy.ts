// Pure, side-effect-free permission-mode policy for the Firstmate Pi primary.
//
// Owned by .pi/extensions/fm-permission-modes.ts, which wires these decisions
// to Pi events. Tested directly by tests/fm-permission-modes.test.sh so the
// classification and mode logic stays decoupled from the Pi runtime.
//
// This is an advisory harness control, not an OS sandbox: Pi extensions execute
// with the user's full privileges, and shell classification is a best-effort
// heuristic because shell is Turing-complete. docs/permission-modes.md owns the
// operator-facing contract and the advisory-only boundary.

/**
 * The three permission modes. `off` is the default and preserves Firstmate
 * behavior exactly: the tool_call handler returns a no-op and nothing is
 * blocked, confirmed, or displayed.
 */
export const PERMISSION_MODES = ["off", "plan", "confirm"] as const;
export type PermissionMode = (typeof PERMISSION_MODES)[number];
export const DEFAULT_PERMISSION_MODE: PermissionMode = "off";

/** The custom session entry type used to persist the active mode. */
export const PERMISSION_ENTRY_TYPE = "fm-permission-modes";

/** A parsed /fm-permissions argument: either a valid mode or an error. */
export type ParsedMode =
  | { ok: true; mode: PermissionMode }
  | { ok: false; error: string };

const MODE_USAGE = "usage: /fm-permissions off|plan|confirm";

/**
 * Parse a single /fm-permissions argument. An empty argument is an error from
 * the pure parser's perspective; the command handler treats a totally empty
 * invocation as a status query instead, so it only calls this with a real token.
 */
export function parsePermissionModeArg(arg: string): ParsedMode {
  const token = arg.trim();
  if (token === "") {
    return { ok: false, error: `missing mode argument; ${MODE_USAGE}` };
  }
  for (const mode of PERMISSION_MODES) {
    if (token === mode) {
      return { ok: true, mode };
    }
  }
  return { ok: false, error: `unknown mode ${JSON.stringify(token)}; ${MODE_USAGE}` };
}

/**
 * The mutation class of a built-in tool name. `shell` (bash) needs command
 * inspection; the others are decided by name alone. Custom and unrecognized
 * tool names are `neutral`: plan and confirm gate only the built-in file and
 * shell tools named in docs/permission-modes.md, so neutral tools pass through.
 */
export type ToolMutationClass = "read" | "mutate" | "shell" | "neutral";

const READ_ONLY_TOOLS = new Set(["read", "ls", "grep", "find"]);
const MUTATING_TOOLS = new Set(["edit", "write"]);

export function classifyToolMutation(toolName: string): ToolMutationClass {
  if (toolName === "bash") return "shell";
  if (READ_ONLY_TOOLS.has(toolName)) return "read";
  if (MUTATING_TOOLS.has(toolName)) return "mutate";
  return "neutral";
}

/**
 * Patterns that mark a bash command as mutating anywhere in the command string.
 * Matched against the whole command so chained, piped, or substituted mutations
 * are caught even when the leading token looks read-only.
 */
export const DESTRUCTIVE_SHELL_PATTERNS: readonly RegExp[] = [
  /\brm\b/i,
  /\brmdir\b/i,
  /\bunlink\b/i,
  /\bmv\b/i,
  /\bcp\b/i,
  /\bmkdir\b/i,
  /\btouch\b/i,
  /\bchmod\b/i,
  /\bchown\b/i,
  /\bchgrp\b/i,
  /\bln\b/i,
  /\btee\b/i,
  /\btruncate\b/i,
  /\bdd\b/i,
  /\bshred\b/i,
  /\bsplit\b/i,
  /\bcut\b/i,
  /(^|[^<])>(?!>)/,
  />>/,
  /\bnpm\s+(install|uninstall|update|ci|link|publish|run\s+script)/i,
  /\bnpx\s+/i,
  /\byarn\s+(add|remove|install|publish|upgrade)/i,
  /\bpnpm\s+(add|remove|install|publish)/i,
  /\bpip3?\s+(install|uninstall)/i,
  /\bpipx\s+(install|uninstall)/i,
  /\buv\s+(pip\s+)?(install|uninstall)/i,
  /\bapt(-get)?\s+(install|remove|purge|update|upgrade|dist-upgrade)/i,
  /\bdnf\s+(install|remove|upgrade)/i,
  /\byum\s+(install|remove|update)/i,
  /\bbrew\s+(install|uninstall|upgrade|cask\s+install)/i,
  /\bcargo\s+(install|uninstall|publish)/i,
  /\bgo\s+(install|build.*-o\b)/i,
  /\bgem\s+install\b/i,
  /\bcomposer\s+(install|update|require|remove)/i,
  /\bgit\s+(add|commit|push|pull|merge|rebase|reset|restore|stash|cherry-pick|revert|tag|init|clone|checkout|switch|branch\s+-[dD]|worktree\s+(add|remove|prune|repair))/i,
  /\bsudo\b/i,
  /\bsu\b/i,
  /\bkill\b/i,
  /\bpkill\b/i,
  /\bkillall\b/i,
  /\breboot\b/i,
  /\bshutdown\b/i,
  /\bhalt\b/i,
  /\bpoweroff\b/i,
  /\bsystemctl\s+(start|stop|restart|reload|enable|disable|mask|unmask)/i,
  /\bservice\s+\S+\s+(start|stop|restart|reload)/i,
  /\blaunchctl\s+(load|unload|start|stop|bootstrap)/i,
  /\bdefaults\s+write\b/i,
  /\bmkfs\b/i,
  /\bmount\b/i,
  /\bumount\b/i,
  /\b(vim?|nano|emacs|code|subl|micro|ed)\b/i,
  /\bfind\b[\s\S]*\s-(delete|exec|execdir|ok|okdir|fprint|fprint0|fprintf|fls)\b/i,
  /\bsed\b[\s\S]*\s(--in-place(?:=\S*)?|-i(?:\S*)?)\b/i,
  /\bsort\b[\s\S]*\s(--output(?:=\S*)?|-o)\b/i,
  /\bgit\s+(log|diff|show|blame|shortlog)[\s\S]*\s--output(?:=|\s)/i,
  /\b(npm|pnpm)\s+audit[\s\S]*\s--fix\b/i,
  /\bdate\b[\s\S]*\s(--set(?:=\S*)?|-s)\b/i,
];

const UNSAFE_SHELL_SYNTAX = /[\n\r;&|`<>]|\$\(|\$\{|\\\n/;

const READ_ONLY_COMMANDS = new Set([
  "basename",
  "cal",
  "cat",
  "cmp",
  "comm",
  "df",
  "dirname",
  "du",
  "echo",
  "egrep",
  "fgrep",
  "free",
  "grep",
  "head",
  "id",
  "iostat",
  "jq",
  "ls",
  "printenv",
  "ps",
  "pwd",
  "readlink",
  "realpath",
  "seq",
  "stat",
  "tail",
  "type",
  "uname",
  "uptime",
  "vmstat",
  "wc",
  "whereis",
  "which",
  "whoami",
]);

function parseSimpleShellWords(command: string): string[] | undefined {
  if (UNSAFE_SHELL_SYNTAX.test(command) || command.includes("$")) return undefined;

  const words: string[] = [];
  let word = "";
  let quote: "'" | '"' | undefined;
  let escaped = false;
  let started = false;

  for (const character of command) {
    if (escaped) {
      word += character;
      escaped = false;
      started = true;
      continue;
    }
    if (character === "\\" && quote !== "'") {
      escaped = true;
      started = true;
      continue;
    }
    if (quote !== undefined) {
      if (character === quote) quote = undefined;
      else word += character;
      started = true;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      started = true;
      continue;
    }
    if (/\s/.test(character)) {
      if (started) {
        words.push(word);
        word = "";
        started = false;
      }
      continue;
    }
    word += character;
    started = true;
  }

  if (escaped || quote !== undefined) return undefined;
  if (started) words.push(word);
  return words;
}

function hasOption(args: readonly string[], ...options: readonly string[]): boolean {
  return args.some((arg) => options.some((option) => arg === option || arg.startsWith(`${option}=`)));
}

function isReadOnlyFind(args: readonly string[]): boolean {
  return !hasOption(
    args,
    "-delete",
    "-exec",
    "-execdir",
    "-fls",
    "-fprint",
    "-fprint0",
    "-fprintf",
    "-ok",
    "-okdir",
  );
}

function isReadOnlyRipgrep(args: readonly string[]): boolean {
  return !hasOption(args, "--hostname-bin", "--pre");
}

function isReadOnlyGit(args: readonly string[]): boolean {
  const [subcommand, ...rest] = args;
  if (subcommand === "--version") return rest.length === 0;
  if (["describe", "ls-files", "rev-parse", "status"].includes(subcommand ?? "")) return true;
  if (["blame", "diff", "log", "shortlog", "show"].includes(subcommand ?? "")) {
    return !hasOption(rest, "--ext-diff", "--output", "--textconv");
  }
  if (subcommand === "branch") {
    return rest.every((arg) =>
      /^(--list|--show-current|-a|-r|-v|-vv|--contains(?:=\S+)?|--no-contains(?:=\S+)?|--merged(?:=\S+)?|--no-merged(?:=\S+)?|--sort=\S+|--format=\S+|--color(?:=\S+)?|--no-color)$/.test(
        arg,
      ),
    );
  }
  if (subcommand === "remote") {
    return (
      rest.length === 0 ||
      (rest.length === 1 && rest[0] === "-v") ||
      (rest[0] === "show" && rest.length <= 2) ||
      (rest[0] === "get-url" && rest.length >= 2 && rest.length <= 3 && rest[1] === "--all") ||
      (rest[0] === "get-url" && rest.length === 2)
    );
  }
  if (subcommand === "config") {
    return rest.length >= 2 && rest.length <= 3 && /^--get(?:-all|-regexp)?$/.test(rest[0] ?? "");
  }
  if (subcommand === "symbolic-ref") {
    const references = rest.filter((arg) => !["--quiet", "-q", "--short"].includes(arg));
    return references.length === 1;
  }
  return false;
}

function hasExactVersionArgs(command: string, args: readonly string[]): boolean {
  if (["bash", "cargo", "rustc", "zsh"].includes(command)) {
    return args.length === 1 && args[0] === "--version";
  }
  if (command === "go") return args.length === 1 && args[0] === "version";
  if (command === "node") return args.length === 1 && ["--version", "-v"].includes(args[0] ?? "");
  if (/^python3?$/.test(command)) {
    return args.length === 1 && ["--version", "-V"].includes(args[0] ?? "");
  }
  return false;
}

/**
 * Whether a bash command is genuinely read-only. Advisory heuristic, not a
 * sandbox: shell is Turing-complete, so this can only recognize known-safe and
 * known-unsafe shapes. The safe direction is conservative - an unrecognized
 * command is treated as non-read-only, so plan mode blocks it and confirm mode
 * prompts for it rather than silently allowing a possible mutation.
 */
export function isReadOnlyShellCommand(command: string | undefined): boolean {
  if (typeof command !== "string" || command.trim() === "") {
    return false;
  }
  const isDestructive = DESTRUCTIVE_SHELL_PATTERNS.some((p) => p.test(command));
  if (isDestructive) return false;
  const words = parseSimpleShellWords(command);
  if (words === undefined || words.length === 0) return false;
  const [executable, ...args] = words;
  if (READ_ONLY_COMMANDS.has(executable ?? "")) return true;
  if (executable === "command") return args.length >= 2 && args[0] === "-v";
  if (executable === "find") return isReadOnlyFind(args);
  if (executable === "rg") return isReadOnlyRipgrep(args);
  if (executable === "git") return isReadOnlyGit(args);
  return hasExactVersionArgs(executable ?? "", args);
}

/**
 * A short, unobtrusive footer label for the active mode, or undefined to clear
 * the footer. The extension styles this with the active theme before calling
 * ctx.ui.setStatus.
 */
export function modeStatusLabel(mode: PermissionMode): string | undefined {
  if (mode === "off") return undefined;
  return `permission: ${mode}`;
}

/**
 * A decision returned to the extension's tool_call handler. The extension
 * translates `allow` to a no-op, `block` to a Pi block result, and `confirm` to
 * an interactive ctx.ui.confirm prompt that itself resolves to allow or block.
 */
export type ToolCallDecision =
  | { action: "allow" }
  | { action: "block"; reason: string }
  | { action: "confirm"; prompt: string; denialReason: string };

function describeBash(command: string | undefined): string {
  const trimmed = typeof command === "string" ? command.trim() : "";
  if (trimmed === "") return "bash command";
  const single = trimmed.replace(/\s+/g, " ");
  return single.length > 120 ? `${single.slice(0, 117)}...` : single;
}

/**
 * The complete mode decision for a tool_call. `command` is only consulted for
 * the bash tool; other tools decide by name. `hasUI` makes noninteractive
 * refusal a pure-function decision: confirm mode with no UI blocks a mutating
 * call instead of silently allowing it.
 */
export function decideToolCall(
  mode: PermissionMode,
  toolName: string,
  command: string | undefined,
  hasUI: boolean,
): ToolCallDecision {
  if (mode === "off") {
    return { action: "allow" };
  }

  const mutation = classifyToolMutation(toolName);

  if (mode === "plan") {
    if (mutation === "mutate") {
      return {
        action: "block",
        reason: `plan mode blocks the ${toolName} tool; use /fm-permissions off to allow mutations`,
      };
    }
    if (mutation === "shell" && !isReadOnlyShellCommand(command)) {
      return {
        action: "block",
        reason: `plan mode blocks non-read-only shell; use /fm-permissions off to allow mutations. Command: ${describeBash(command)}`,
      };
    }
    return { action: "allow" };
  }

  // mode === "confirm"
  if (mutation === "mutate" || (mutation === "shell" && !isReadOnlyShellCommand(command))) {
    if (!hasUI) {
      const target = mutation === "shell" ? describeBash(command) : `the ${toolName} tool`;
      return {
        action: "block",
        reason: `confirm mode requires interactive approval for ${target}, but no UI is available; use /fm-permissions off in noninteractive runs`,
      };
    }
    const prompt =
      mutation === "shell"
        ? `confirm mode: allow this command?\n\n${describeBash(command)}`
        : `confirm mode: allow the ${toolName} tool?`;
    return {
      action: "confirm",
      prompt,
      denialReason: `${toolName} denied by user in confirm mode`,
    };
  }
  return { action: "allow" };
}
