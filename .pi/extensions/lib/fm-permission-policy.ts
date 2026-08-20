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
];

/**
 * Patterns that mark a bash command as genuinely read-only. Anchored at the
 * start so a mutation chained after a read-only leader is still caught by the
 * destructive patterns above. A command is read-only only when it matches one
 * of these AND no destructive pattern matches.
 */
export const READ_ONLY_SHELL_PATTERNS: readonly RegExp[] = [
  /^\s*cat\b/,
  /^\s*head\b/,
  /^\s*tail\b/,
  /^\s*less\b/,
  /^\s*more\b/,
  /^\s*grep\b/,
  /^\s*egrep\b/,
  /^\s*fgrep\b/,
  /^\s*rg\b/,
  /^\s*find\b/,
  /^\s*fd\b/,
  /^\s*ls\b/,
  /^\s*pwd\b/,
  /^\s*echo\b/,
  /^\s*printf\b/,
  /^\s*wc\b/,
  /^\s*sort\b/,
  /^\s*uniq\b/,
  /^\s*diff\b/,
  /^\s*comm\b/,
  /^\s*cmp\b/,
  /^\s*file\b/,
  /^\s*stat\b/,
  /^\s*du\b/,
  /^\s*df\b/,
  /^\s*tree\b/,
  /^\s*which\b/,
  /^\s*whereis\b/,
  /^\s*type\b/,
  /^\s*command\s+-v\b/,
  /^\s*env\b/,
  /^\s*printenv\b/,
  /^\s*uname\b/,
  /^\s*whoami\b/,
  /^\s*id\b/,
  /^\s*date\b/,
  /^\s*cal\b/,
  /^\s*uptime\b/,
  /^\s*hostname\b/,
  /^\s*ps\b/,
  /^\s*top\b/,
  /^\s*htop\b/,
  /^\s*free\b/,
  /^\s*vmstat\b/,
  /^\s*iostat\b/,
  /^\s*git\s+(status|log|diff|show|blame|branch|remote|describe|rev-parse|shortlog|ls-files|ls-remote|config\s+--get|symbolic-ref)\b/i,
  /^\s*git\s+rev-parse\b/i,
  /^\s*npm\s+(list|ls|view|info|search|outdated|audit|ping)/i,
  /^\s*yarn\s+(list|info|why|audit)/i,
  /^\s*pnpm\s+(list|why|audit)/i,
  /^\s*node\s+--version/i,
  /^\s*node\s+-v\b/i,
  /^\s*python3?\s+--version/i,
  /^\s*python3?\s+-V\b/i,
  /^\s*rustc\s+--version/i,
  /^\s*cargo\s+--version/i,
  /^\s*go\s+version\b/i,
  /^\s*git\s+--version/i,
  /^\s*jq\b/,
  /^\s*sed\s+-n\b/,
  /^\s*awk\b/,
  /^\s*bash\s+--version/i,
  /^\s*zsh\s+--version/i,
  /^\s*realpath\b/,
  /^\s*readlink\b/,
  /^\s*basename\b/,
  /^\s*dirname\b/,
  /^\s*seq\b/,
  /^\s*yes\s+--help/i,
  /^\s*man\b/,
  /^\s*help\b/,
];

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
  return READ_ONLY_SHELL_PATTERNS.some((p) => p.test(command));
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
