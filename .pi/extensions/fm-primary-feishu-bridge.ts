// Opt-in Firstmate Feishu bridge for the current live Pi AgentSession.
//
// This extension never creates an AgentSession and never starts Pi.  It binds
// only a trusted local TUI whose persisted session identity and Firstmate lock
// exactly match the active private binding.  Network transport remains in the
// dedicated no-Agent fm-feishu-transport process.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { Box, Text } from "@earendil-works/pi-tui";
import {
  bindSession,
  createPairing,
  disablePairing,
  statusSummary,
} from "../../bin/fm-feishu-state.mjs";
import {
  currentFirstmateSessionIdentity,
  firstmateSessionLockOwnership,
  registerFeishuNativeChannel,
} from "./lib/fm-feishu-native-channel.ts";

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.pi-feishu-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(fileURLToPath(import.meta.url))).digest("hex")}`;
const transportScript = process.env.FM_FEISHU_TRANSPORT_SCRIPT || `${fmRoot}/bin/fm-feishu-transport.sh`;

function requireLocalTui(ctx: ExtensionCommandContext): void {
  if (ctx.mode !== "tui" || !ctx.hasUI) throw new Error("Feishu channel controls are available only in the local Pi TUI");
  if (!ctx.isProjectTrusted()) throw new Error("the current Firstmate project is not trusted");
  if (firstmateSessionLockOwnership() !== "owned") throw new Error("this Pi does not own the verified Firstmate session lock");
}

function stopTransport(): Promise<void> {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(transportScript, ["stop"], {
      cwd: fmRoot,
      env: { ...process.env, FM_HOME: fmHome, FM_ROOT_OVERRIDE: fmRoot },
      stdio: "ignore",
    });
    child.once("error", rejectPromise);
    child.once("close", (code) => {
      if (code === 0) resolvePromise();
      else rejectPromise(new Error(`Feishu transport stop exited ${code ?? "without status"}`));
    });
  });
}

function exactSession(ctx: ExtensionCommandContext) {
  const identity = currentFirstmateSessionIdentity(ctx);
  if (!identity) throw new Error("the current Pi session is ephemeral or its persisted identity cannot be verified");
  return identity;
}

function fullStatus(): string {
  const value = statusSummary(fmHome) as {
    paired?: boolean;
    disabled?: boolean;
    binding_status?: string;
    binding_generation?: number | null;
    home_realpath?: string | null;
    session_id?: string | null;
    session_file?: string | null;
    session_cwd?: string | null;
    chat_id?: string | null;
    allowed_user?: string | null;
    transport_phase?: string;
    transport_healthy?: boolean;
    inbound?: { pending?: number; queued?: number; delivered?: number };
    outbound_pending?: number;
    outbound_uncertain?: number;
  };
  return [
    `paired=${value.paired === true ? "yes" : "no"}`,
    `disabled=${value.disabled === true ? "yes" : "no"}`,
    `binding=${value.binding_status ?? "absent"}`,
    `generation=${value.binding_generation ?? "none"}`,
    `home=${value.home_realpath ?? "none"}`,
    `session_id=${value.session_id ?? "none"}`,
    `session_file=${value.session_file ?? "none"}`,
    `session_cwd=${value.session_cwd ?? "none"}`,
    `chat_id=${value.chat_id ?? "none"}`,
    `allowed_user=${value.allowed_user ?? "none"}`,
    `transport=${value.transport_phase ?? "stopped"}`,
    `transport_healthy=${value.transport_healthy === true ? "yes" : "no"}`,
    `inbox_pending=${value.inbound?.pending ?? 0}`,
    `inbox_queued=${value.inbound?.queued ?? 0}`,
    `inbox_delivered=${value.inbound?.delivered ?? 0}`,
    `outbox_pending=${value.outbound_pending ?? 0}`,
    `outbox_uncertain=${value.outbound_uncertain ?? 0}`,
  ].join("\n");
}

function markLoaded(): void {
  if (firstmateSessionLockOwnership() !== "owned") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`, { mode: 0o600 });
}

export default function (pi: ExtensionAPI) {
  registerFeishuNativeChannel(pi);

  pi.registerEntryRenderer<{ kind?: string; message?: string }>("fm-feishu-local-alert", (entry, _options, theme) => {
    const box = new Box(1, 0, (text) => theme.bg("toolErrorBg", text));
    box.addChild(new Text(theme.fg("error", theme.bold("Feishu channel alert")), 0, 0));
    box.addChild(new Text(theme.fg("warning", entry.data?.message ?? "A private Feishu channel action needs local attention."), 0, 0));
    return box;
  });

  pi.registerCommand("fm-feishu-pair", {
    description: "Pair one Feishu app fingerprint, one allowlisted user, and one P2P chat from the local TUI.",
    handler: async (args, ctx) => {
      try {
        requireLocalTui(ctx);
        const [allowedUser, allowedChat, appIdFingerprint, ...extra] = args.trim().split(/\s+/).filter(Boolean);
        if (!allowedUser || !allowedChat || !appIdFingerprint || extra.length > 0) {
          ctx.ui.notify("Usage: /fm-feishu-pair <captain-open-id> <p2p-chat-id> <sha256:app-id-hash>", "warning");
          return;
        }
        createPairing(fmHome, { allowedUser, allowedChat, appIdFingerprint });
        ctx.ui.notify("Feishu direct-SDK pairing stored locally. No network call or authentication was performed. Run /fm-feishu-bind to bind the current persisted Pi session.", "info");
      } catch (error) {
        ctx.ui.notify(`Feishu pairing refused: ${String(error)}`, "error");
      }
    },
  });

  pi.registerCommand("fm-feishu-bind", {
    description: "Bind the active pairing to this exact persisted Pi session from the local TUI.",
    handler: async (_args, ctx) => {
      try {
        requireLocalTui(ctx);
        const identity = exactSession(ctx);
        const binding = bindSession(fmHome, identity);
        ctx.ui.notify(`Feishu bound to session ${binding.session_id}\n${binding.session_file_realpath}\ncwd=${binding.session_cwd_realpath}\ngeneration=${binding.generation}. Reloading this same session to activate the fence.`, "info");
        await ctx.reload();
      } catch (error) {
        ctx.ui.notify(`Feishu bind refused: ${String(error)}`, "error");
      }
    },
  });

  pi.registerCommand("fm-feishu-rebind", {
    description: "Move the Feishu binding to this exact persisted Pi session and increment its generation.",
    handler: async (_args, ctx) => {
      try {
        requireLocalTui(ctx);
        const identity = exactSession(ctx);
        await stopTransport();
        const binding = bindSession(fmHome, identity, { rebind: true });
        ctx.ui.notify(`Feishu explicitly rebound to session ${binding.session_id}\n${binding.session_file_realpath}\ncwd=${binding.session_cwd_realpath}\ngeneration=${binding.generation}. Older callbacks are fenced. Reloading this same session now.`, "info");
        await ctx.reload();
      } catch (error) {
        ctx.ui.notify(`Feishu rebind refused: ${String(error)}`, "error");
      }
    },
  });

  pi.registerCommand("fm-feishu-disable", {
    description: "Disable the local Feishu pairing and stop its no-Agent transport.",
    handler: async (_args, ctx) => {
      try {
        requireLocalTui(ctx);
        await stopTransport();
        const result = disablePairing(fmHome);
        ctx.ui.setStatus("fm-feishu", undefined);
        ctx.ui.notify(result.changed ? "Feishu pairing disabled and transport stop requested." : "Feishu pairing was already absent or disabled.", "info");
      } catch (error) {
        ctx.ui.notify(`Feishu disable refused: ${String(error)}`, "error");
      }
    },
  });

  pi.registerCommand("fm-feishu-status", {
    description: "Show the exact local Feishu pairing, Pi session binding, queue, and transport status.",
    handler: async (_args, ctx) => {
      try {
        requireLocalTui(ctx);
        ctx.ui.notify(fullStatus(), "info");
      } catch (error) {
        ctx.ui.notify(`Feishu status unavailable: ${String(error)}`, "error");
      }
    },
  });

  pi.on("session_start", () => markLoaded());
  markLoaded();
}
