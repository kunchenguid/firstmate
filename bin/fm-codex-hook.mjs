#!/usr/bin/env node
// Cross-platform Codex project-hook transport.
// Usage: fm-codex-hook.mjs <session-start|arm|cd|stop>
// POSIX delegates to the established shell owner. Native Windows performs the
// same Codex transport, project-root checks, policy invocation, and Stop safety
// decision without requiring Bash.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { decision as armDecision } from "./fm-arm-command-policy.mjs";
import { decision as cdDecision } from "./fm-cd-command-policy.mjs";

const mode = process.argv[2];
if (!new Set(["session-start", "arm", "cd", "stop"]).has(mode)) process.exit(0);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const payloadText = fs.readFileSync(0, "utf8");
if (!payloadText.trim()) process.exit(0);

function shapedRoot() {
  try {
    const hooks = JSON.parse(fs.readFileSync(path.join(root, ".codex", "hooks.json"), "utf8"));
    const commands = Object.values(hooks.hooks ?? {}).flatMap((groups) =>
      (groups ?? []).flatMap((group) => (group.hooks ?? []).map((hook) => hook.command ?? "")),
    );
    return fs.existsSync(path.join(root, "AGENTS.md"))
      && fs.existsSync(path.join(root, "bin"))
      && commands.some((command) => command.includes("fm-codex-hook.mjs"));
  } catch {
    return false;
  }
}
if (!shapedRoot()) process.exit(0);

function delegate(script) {
  const result = spawnSync("bash", [path.join(root, "bin", script)], {
    cwd: root, input: payloadText, encoding: "utf8", windowsHide: true,
  });
  if (result.error) process.exit(0);
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  process.exit(result.status ?? 0);
}
if (process.platform !== "win32") {
  delegate({
    "session-start": "fm-sessionstart-run.sh",
    arm: "fm-arm-pretool-check.sh",
    cd: "fm-cd-pretool-check.sh",
    stop: "fm-turnend-guard.sh",
  }[mode]);
}

function parsePayload() {
  try {
    const payload = JSON.parse(payloadText);
    return payload && typeof payload === "object" && !Array.isArray(payload) ? payload : null;
  } catch {
    return null;
  }
}

function deny(code, reason) {
  const detail = `[${code}] ${reason}`;
  process.stderr.write(`${JSON.stringify({
    hookSpecificOutput: { hookEventName: mode === "stop" ? "Stop" : "PreToolUse", permissionDecision: "deny" },
    systemMessage: detail,
  })}\n`);
  if (mode !== "stop") process.stdout.write(`${JSON.stringify({ decision: "deny", reason: detail })}\n`);
  process.exit(2);
}

const payload = parsePayload();
if (!payload) process.exit(0);
if (mode === "session-start") {
  process.stdout.write(
    "NATIVE_WINDOWS_RUNTIME: Codex hooks are active without Bash. "
    + "The Firstmate fleet bootstrap remains POSIX-only, so no session lock, wake drain, or fleet mutation was performed. "
    + "Native PowerShell repository work remains available; do not install or invoke WSL as a workaround.\n",
  );
  process.exit(0);
}
if (mode === "arm" || mode === "cd") {
  const command = payload.tool_input?.command ?? payload.toolInput?.command;
  if (typeof command !== "string" || !command) process.exit(0);
  if (mode === "cd" && !primaryScope(null, false)) process.exit(0);
  const verdict = mode === "arm"
    ? armDecision(command, root, process.env.FM_HOME ?? root)
    : cdDecision(command);
  if (verdict.decision === "deny") deny(verdict.code, verdict.reason);
  process.exit(0);
}

const active = Object.hasOwn(payload, "stopHookActive") ? payload.stopHookActive : payload.stop_hook_active;
if (active !== undefined && typeof active !== "boolean") process.exit(0);
if (active === true) process.exit(0);
const home = path.resolve(process.env.FM_HOME ?? root);
const state = path.resolve(process.env.FM_STATE_OVERRIDE ?? path.join(home, "state"));
if (!primaryScope(state, true) || !supervisionNeeded(state)) process.exit(0);
deny("turn-would-end-blind", "supervision is required, but native Windows has no identity-matched live Firstmate watcher; repair supervision before ending the turn");

function primaryScope(state, markerAware) {
  if (!fs.existsSync(path.join(root, "AGENTS.md")) || !fs.existsSync(path.join(root, "bin"))) return false;
  if (state && !fs.existsSync(state)) return false;
  if (markerAware && validSecondmateMarker()) return true;
  try {
    return fs.lstatSync(path.join(root, ".git")).isDirectory();
  } catch {
    return false;
  }
}

function validSecondmateMarker() {
  const marker = path.join(root, ".fm-secondmate-home");
  try {
    if (fs.lstatSync(marker).isSymbolicLink()) return false;
    const id = fs.readFileSync(marker, "utf8").split(/\r?\n/, 1)[0].replace(/\s/g, "");
    return /^[A-Za-z0-9._-]+$/.test(id);
  } catch {
    return false;
  }
}

function supervisionNeeded(state) {
  try {
    if (fs.readdirSync(state).some((name) => name.endsWith(".meta"))) return true;
    if (fs.existsSync(path.join(state, "x-watch.check.sh"))) return true;
    const sources = path.join(state, "procevent");
    return fs.existsSync(sources) && fs.readdirSync(sources).some((name) => name.endsWith(".source"));
  } catch {
    return false;
  }
}
