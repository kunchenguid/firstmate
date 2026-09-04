// Firstmate's opt-in Claude Code-inspired permission-mode toggle for the Pi
// primary. docs/permission-modes.md owns the operator-facing contract.
//
// Three modes, all session-scoped and off by default so Firstmate behavior is
// preserved exactly until the captain explicitly enables one:
//   off      - no-op gate; the existing PreToolUse seatbelts and turn-end guard
//              run unchanged (this handler returns a no-block result).
//   plan     - block the built-in edit and write tools and any bash command
//              that is not genuinely read-only, while allowing read-only
//              inspection (read, ls, grep, find, and read-only bash).
//   confirm  - require an interactive approval before the built-in mutating
//              file and shell tools (edit, write, and non-read-only bash); if
//              no UI is available, refuse rather than silently permit.
//
// Mode state is session-persisted through Pi's supported extension state API
// (pi.appendEntry), restored on session_start, and never written to a global
// config file. The active mode is shown unobtrusively in the Pi footer.
//
// This is an advisory harness control, not an OS sandbox: Pi extensions execute
// with the user's full privileges, and the bash read-only classifier is a
// best-effort heuristic. The pure classification and decision logic lives in
// ./lib/fm-permission-policy.ts and is tested by tests/fm-permission-modes.test.sh.
//
// Composition with the existing turn-end guard: Pi's tool_call dispatch
// (runner.emitToolCall) runs handlers in load order and short-circuits on the
// first {block: true}, so a no-block result from this handler lets the existing
// PreToolUse seatbelts run afterward. Permission modes therefore never weaken
// the existing seatbelts: a call this gate allows still passes through them, and
// a call this gate blocks is blocked regardless. See docs/permission-modes.md.
import type { ExtensionAPI, ExtensionContext, ToolCallEvent } from "@earendil-works/pi-coding-agent";
import {
  DEFAULT_PERMISSION_MODE,
  PERMISSION_ENTRY_TYPE,
  PERMISSION_MODES,
  type PermissionMode,
  decideToolCall,
  modeStatusLabel,
  parsePermissionModeArg,
} from "./lib/fm-permission-policy.ts";

const STATUS_KEY = "fm-permissions";

type MaybeCustomPermissionEntry = {
  type?: string;
  customType?: string;
  data?: { mode?: string };
};

type MaybeUiTheme = {
  fg?: (color: string, text: string) => string;
} | undefined;

function styleWithTheme(ctx: ExtensionContext, text: string, color: string): string {
  try {
    const theme = ctx.ui.theme as MaybeUiTheme;
    return theme?.fg ? theme.fg(color, text) : text;
  } catch {
    return text;
  }
}

export default function (pi: ExtensionAPI): void {
  let mode: PermissionMode = DEFAULT_PERMISSION_MODE;

  function persist(): void {
    try {
      pi.appendEntry(PERMISSION_ENTRY_TYPE, { mode });
    } catch {
      // appendEntry may be unavailable in synthetic contexts; persistence is best-effort.
    }
  }

  function updateStatus(ctx: ExtensionContext): void {
    const label = modeStatusLabel(mode);
    if (label === undefined) {
      ctx.ui.setStatus(STATUS_KEY, undefined);
      return;
    }
    const color = mode === "plan" ? "warning" : "accent";
    ctx.ui.setStatus(STATUS_KEY, styleWithTheme(ctx, label, color));
  }

  function setMode(next: PermissionMode, ctx: ExtensionContext): void {
    mode = next;
    persist();
    updateStatus(ctx);
  }

  pi.registerCommand("fm-permissions", {
    description: "Set the advisory permission mode: off | plan | confirm (off by default).",
    handler: async (args, ctx) => {
      const trimmed = args.trim();
      if (trimmed === "") {
        ctx.ui.notify(`permission mode: ${mode}`, "info");
        return;
      }
      const parsed = parsePermissionModeArg(trimmed);
      if (!parsed.ok) {
        ctx.ui.notify(parsed.error, "error");
        return;
      }
      setMode(parsed.mode, ctx);
      ctx.ui.notify(`permission mode: ${mode}`, "info");
    },
  });

  pi.on("tool_call", async (event: ToolCallEvent, ctx: ExtensionContext) => {
    if (mode === "off") return {};
    const toolName = event.toolName;
    const command =
      toolName === "bash"
        ? String((event.input as { command?: unknown }).command ?? "")
        : undefined;
    const decision = decideToolCall(mode, toolName, command, ctx.hasUI);
    if (decision.action === "allow") return {};
    if (decision.action === "block") {
      return { block: true, reason: decision.reason };
    }
    // decision.action === "confirm": an interactive prompt is required; the
    // pure policy already guaranteed ctx.hasUI is true on this branch, so a
    // missing UI would have been a block instead of a silent permit.
    const approved = await ctx.ui.confirm("fm-permissions", decision.prompt);
    return approved ? {} : { block: true, reason: decision.denialReason };
  });

  // Restore the persisted mode on session start/resume/reload so the choice
  // survives across Pi session replacements. A fresh session has no persisted
  // entry and stays at the default (off). This is session-persisted state via
  // Pi's appendEntry API, not a global config file.
  pi.on("session_start", async (_event, ctx: ExtensionContext) => {
    mode = DEFAULT_PERMISSION_MODE;
    try {
      const entries = ctx.sessionManager.getEntries();
      let restored: PermissionMode | undefined;
      for (const entry of entries) {
        const custom = entry as MaybeCustomPermissionEntry;
        if (
          custom.type === "custom" &&
          custom.customType === PERMISSION_ENTRY_TYPE &&
          custom.data?.mode
        ) {
          if ((PERMISSION_MODES as readonly string[]).includes(custom.data.mode)) {
            restored = custom.data.mode as PermissionMode;
          }
        }
      }
      mode = restored ?? DEFAULT_PERMISSION_MODE;
    } catch {
      // sessionManager may be unavailable in synthetic contexts; stay at off.
    }
    updateStatus(ctx);
  });
}
